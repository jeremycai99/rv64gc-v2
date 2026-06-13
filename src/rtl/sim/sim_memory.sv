/* file: sim_memory.sv
 Description: Simulation memory model with configurable latency.
 Author: Jeremy Cai
 Date: Apr. 09, 2026 (v3 latency model: Jun. 11, 2026)
 Version: 3.0
*/
module sim_memory
    import rv64gc_pkg::*;
#(
    parameter int MEM_SIZE_BYTES = 2 * 1024 * 1024,
    // Read-response latency in cycles.  Default 1 reproduces the historical
    // single-register model bit-exactly (resp_valid exactly 1 cycle after the
    // request).  Overridable at runtime with +MEM_LATENCY=<n> so one binary
    // can sweep latency without rebuilds.
    parameter int MEM_LATENCY_CYCLES = 1
)
(
    input  wire        clk,
    input  wire        rst_n,

    // L2 cache to memory interface
    input  wire        mem_req_valid,
    input  wire [63:0] mem_req_addr,
    input  wire        mem_req_we,
    input  wire [511:0] mem_req_wdata,
    output reg        mem_req_ready,
    output reg        mem_resp_valid,
    output reg [511:0] mem_resp_data
);

    // =========================================================================
    // Parameters
    // =========================================================================
    // Default remains 2 MB for benchmark simulations. Linux tb instances can
    // raise this parameter to hold firmware, kernel, initramfs, and FDT images.
    localparam int MEM_SIZE  = MEM_SIZE_BYTES;
    localparam int ADDR_BITS = $clog2(MEM_SIZE);

    // =========================================================================
    // Byte-addressed storage
    // =========================================================================
    logic [7:0] mem [0:MEM_SIZE-1];

    // =========================================================================
    // Hex file loading via plusarg
    //
    // Zero-initialize the entire memory BEFORE $readmemh so that any load
    // to an address outside the hex file's initialized range returns 0
    // rather than X.  xsim uses 4-state logic; without explicit init the
    // untouched array entries are X, and any read propagates X through the
    // pipeline (dcache compares short-circuit silently, ROB head stalls
    // because load_wb_valid never fires).  Verilator's 2-state logic
    // default-initializes to 0, which is why this issue is xsim-specific.
    // =========================================================================
    string memfile;
    initial begin
        // Zero-init before $readmemh.  Use blocking assignment (initial is not
        // an always_ff, so no multi-driver conflict with the write path).
        for (int i = 0; i < MEM_SIZE; i++) mem[i] = 8'h00;
        if ($value$plusargs("MEMFILE=%s", memfile)) begin
            $readmemh(memfile, mem);
        end
    end

    // =========================================================================
    // Latency configuration
    //
    // Effective read latency is MEM_LATENCY_CYCLES, overridable at runtime
    // with +MEM_LATENCY=<n> (clamped to [1, MAX_MEM_LATENCY]).  The delay
    // structure is a timestamped FIFO, so its depth is independent of the
    // latency value; the cap is a sanity bound on the plusarg.
    // =========================================================================
    localparam int MAX_MEM_LATENCY  = 512;
    localparam int RESP_FIFO_DEPTH  = 64;   // > L2_MSHR_DEPTH (32) = max
                                            // outstanding reads the L2 can have
    localparam int RESP_PTR_BITS    = $clog2(RESP_FIFO_DEPTH);

    int unsigned latency;
    initial begin
        int unsigned lat_plus;
        latency = MEM_LATENCY_CYCLES;
        if ($value$plusargs("MEM_LATENCY=%d", lat_plus)) begin
            latency = lat_plus;
        end
        if (latency < 1) begin
            $display("[sim_memory] MEM_LATENCY=%0d below minimum, clamping to 1",
                     latency);
            latency = 1;
        end
        if (latency > MAX_MEM_LATENCY) begin
            $fatal(1, "[sim_memory] MEM_LATENCY=%0d exceeds cap %0d",
                   latency, MAX_MEM_LATENCY);
        end
        if (latency != 1) begin
            $display("[sim_memory] read latency = %0d cycles", latency);
        end
    end

    // =========================================================================
    // Request handling
    //
    // Request-time processing + delayed response:
    //   - Accepted read : read the array immediately, push {data, due-cycle =
    //     now + latency} into the delay FIFO.  The head pops to
    //     resp_valid/resp_data when its due-cycle matures, one response per
    //     cycle, strictly in request order.
    //   - Accepted write: commits to the array immediately at request time
    //     (request-time ordering, deterministic).  Writes get no response.
    //   - mem_req_ready : 1 unless the delay FIFO is full (backpressure, never
    //     drop).  At latency 1 the FIFO occupancy never exceeds 0 (same-edge
    //     passthrough), so ready is constantly 1 exactly as the historical
    //     model.
    //
    // Latency-1 bit-exactness: an empty-FIFO read with latency 1 is consumed
    // by the same-edge passthrough below -- resp_valid_r/resp_data_r are
    // written at the request edge with the request-time array read, which is
    // the identical single-register path of the historical model.
    // =========================================================================
    // Always ready to accept unless the delay FIFO is full
    logic [RESP_PTR_BITS:0] fifo_count_q;
    assign mem_req_ready = (fifo_count_q < (RESP_PTR_BITS+1)'(RESP_FIFO_DEPTH));

    // Line-aligned address for read/write
    logic [ADDR_BITS-1:0] mem_line_addr;
    assign mem_line_addr = mem_req_addr[ADDR_BITS-1:0] & {{(ADDR_BITS-6){1'b1}}, 6'b0};

    // Delay FIFO
    logic [511:0] fifo_data [0:RESP_FIFO_DEPTH-1];
    logic [63:0]  fifo_due  [0:RESP_FIFO_DEPTH-1];
    logic [RESP_PTR_BITS-1:0] fifo_head_q;
    logic [RESP_PTR_BITS-1:0] fifo_tail_q;

    logic [63:0] cycle_q;
    int          fifo_hiwater;   // statistic only

    // Response registers
    logic        resp_valid_r;
    logic [511:0] resp_data_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            resp_valid_r <= 1'b0;
            resp_data_r  <= '0;
            cycle_q      <= 64'd0;
            fifo_head_q  <= '0;
            fifo_tail_q  <= '0;
            fifo_count_q <= '0;
        end else begin
            automatic logic         accept_read;
            automatic logic [511:0] rd_line;
            automatic logic         pop_head;     // pop a stored FIFO entry
            automatic logic         pop_thru;     // same-edge passthrough (L=1)
            automatic logic         push;
            automatic logic [511:0] pop_data;
            automatic int           occ_next;

            accept_read = mem_req_valid && mem_req_ready && !mem_req_we;

            // Request-time array read (pre-edge contents, same sampling as
            // the historical single-register model)
            rd_line = '0;
            if (accept_read) begin
                for (int i = 0; i < 64; i++) begin
                    rd_line[i*8 +: 8] = mem[mem_line_addr + ADDR_BITS'(i)];
                end
            end

            // Pop decision: stored head if matured; else same-edge
            // passthrough of the incoming read when the FIFO is empty and
            // latency is 1 (response 1 cycle after request, as today).
            pop_head = (fifo_count_q != '0) &&
                       (fifo_due[fifo_head_q] <= (cycle_q + 64'd1));
            pop_thru = (fifo_count_q == '0) && accept_read && (latency == 1);
            pop_data = pop_head ? fifo_data[fifo_head_q] : rd_line;

            // Push every accepted read not consumed by the passthrough
            push = accept_read && !pop_thru;
            if (push) begin
                if (fifo_count_q >= (RESP_PTR_BITS+1)'(RESP_FIFO_DEPTH)) begin
                    // Unreachable (ready backpressures first); loud if broken
                    $fatal(1, "[sim_memory] delay FIFO overflow (depth %0d)",
                           RESP_FIFO_DEPTH);
                end
                fifo_data[fifo_tail_q] <= rd_line;
                fifo_due[fifo_tail_q]  <= cycle_q + 64'(latency);
                fifo_tail_q            <= RESP_PTR_BITS'(fifo_tail_q + 1'b1);
            end
            if (pop_head) begin
                fifo_head_q <= RESP_PTR_BITS'(fifo_head_q + 1'b1);
            end
            fifo_count_q <= fifo_count_q
                          + ((RESP_PTR_BITS+1)'(push ? 1 : 0))
                          - ((RESP_PTR_BITS+1)'(pop_head ? 1 : 0));

            occ_next = int'(fifo_count_q) + (push ? 1 : 0) - (pop_head ? 1 : 0);
            if (occ_next > fifo_hiwater) fifo_hiwater = occ_next;

            // Response: one per cycle, in request order
            resp_valid_r <= pop_head || pop_thru;
            if (pop_head || pop_thru) begin
                resp_data_r <= pop_data;
            end

            // Write request: update 64 bytes in memory at request time
            if (mem_req_valid && mem_req_ready && mem_req_we) begin
                for (int i = 0; i < 64; i++) begin
                    mem[mem_line_addr + ADDR_BITS'(i)] <= mem_req_wdata[i*8 +: 8];
                end
            end

            cycle_q <= cycle_q + 64'd1;
        end
    end

    assign mem_resp_valid = resp_valid_r;
    assign mem_resp_data  = resp_data_r;

    final begin
        $display("[sim_memory] read-delay FIFO high-water = %0d / %0d (latency=%0d)",
                 fifo_hiwater, RESP_FIFO_DEPTH, latency);
    end

endmodule

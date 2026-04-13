/* file: sim_memory.sv
 Description: Simulation memory model with configurable latency.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
module sim_memory
    import rv64gc_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // L2 cache to memory interface
    input  logic        mem_req_valid,
    input  logic [63:0] mem_req_addr,
    input  logic        mem_req_we,
    input  logic [511:0] mem_req_wdata,
    output logic        mem_req_ready,
    output logic        mem_resp_valid,
    output logic [511:0] mem_resp_data,

    // Tohost monitoring (for test pass/fail)
    input  logic [63:0] tohost_addr,
    output logic        tohost_valid,
    output logic [63:0] tohost_value
);

    // =========================================================================
    // Parameters
    // =========================================================================
    localparam int MEM_SIZE  = 256 * 1024 * 1024;  // 256 MB
    localparam int ADDR_BITS = $clog2(MEM_SIZE);    // 28

    // =========================================================================
    // Byte-addressed storage
    // =========================================================================
    logic [7:0] mem [0:MEM_SIZE-1];

    // =========================================================================
    // Hex file loading via plusarg
    // =========================================================================
    string memfile;
    initial begin
        if ($value$plusargs("MEMFILE=%s", memfile)) begin
            $readmemh(memfile, mem);
        end
    end

    // =========================================================================
    // Request handling
    // =========================================================================
    // Always ready to accept (1-cycle latency model)
    assign mem_req_ready = 1'b1;

    // Line-aligned address for read/write
    logic [ADDR_BITS-1:0] mem_line_addr;
    assign mem_line_addr = mem_req_addr[ADDR_BITS-1:0] & {{(ADDR_BITS-6){1'b1}}, 6'b0};

    // Response pipeline register
    logic        resp_valid_r;
    logic [511:0] resp_data_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            resp_valid_r <= 1'b0;
            resp_data_r  <= '0;
        end else begin
            if (mem_req_valid && !mem_req_we) begin
                // Read request: return 64-byte cache line
                resp_valid_r <= 1'b1;
                for (int i = 0; i < 64; i++) begin
                    resp_data_r[i*8 +: 8] <= mem[mem_line_addr + ADDR_BITS'(i)];
                end
            end else begin
                resp_valid_r <= 1'b0;
            end

            // Write request: update 64 bytes in memory
            if (mem_req_valid && mem_req_we) begin
                for (int i = 0; i < 64; i++) begin
                    mem[mem_line_addr + ADDR_BITS'(i)] <= mem_req_wdata[i*8 +: 8];
                end
            end
        end
    end

    assign mem_resp_valid = resp_valid_r;
    assign mem_resp_data  = resp_data_r;

    // =========================================================================
    // Tohost monitoring
    // =========================================================================
    logic [ADDR_BITS-1:0] tohost_local_addr;
    assign tohost_local_addr = tohost_addr[ADDR_BITS-1:0];

    logic [63:0] tohost_current;
    always_comb begin
        for (int i = 0; i < 8; i++) begin
            tohost_current[i*8 +: 8] = mem[tohost_local_addr + ADDR_BITS'(i)];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tohost_valid <= 1'b0;
            tohost_value <= 64'd0;
        end else begin
            tohost_value <= tohost_current;
            tohost_valid <= (tohost_current != 64'd0);
        end
    end

endmodule

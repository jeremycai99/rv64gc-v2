/* file: icache_resp_queue.sv
 Description: Buffer between the icache (1-cycle pipelined response) and
              F2 stage, allowing F1 to fire icache requests at its own
              rate (BPU-runahead) without losing ic_resp data when F2 is
              processing slower. Each entry carries the request's PC and
              FTQ owner identity so F2 can consume in order with correct
              owner tracking.

              Depth-parameterized FIFO. flush clears all entries
              (used on backend redirect).

              This queue is an elasticity boundary only. It preserves
              response data and owner metadata, but it does not make
              queue-head state authoritative for frontend correctness.
              Any future F2 line latch or BPU runahead must remain
              qualified by the FTQ/IBuffer owner contract.

 Author: Jeremy Cai
 Date: 2026-05-05
 Version: 1.0
*/
module icache_resp_queue
    import rv64gc_pkg::*;
    import uarch_pkg::*;
#(
    parameter int DEPTH = 4
)(
    input  logic                          clk,
    input  logic                          rst_n,
    input  logic                          flush,

    // From icache (registered response, 1 cycle after request)
    input  logic                          resp_valid_i,
    input  logic [511:0]                  resp_data_i,
    input  logic                          resp_hit_i,
    // Caller is responsible for capturing the PC of the request that
    // produced this response and the FTQ identity that allocated it.
    input  logic [63:0]                   resp_pc_i,
    input  logic                          resp_ftq_valid_i,
    input  logic [FTQ_IDX_BITS-1:0]       resp_ftq_idx_i,
    input  logic [FTQ_EPOCH_BITS-1:0]     resp_ftq_epoch_i,
    input  logic [FTQ_ALLOC_TAG_BITS-1:0] resp_ftq_alloc_tag_i,

    // To F2 (FIFO order)
    input  logic                          deq_ready_i,
    output logic                          deq_valid_o,
    output logic [511:0]                  deq_data_o,
    output logic                          deq_hit_o,
    output logic [63:0]                   deq_pc_o,
    output logic [63:LINE_BITS]           deq_line_addr_o,
    output logic                          deq_ftq_valid_o,
    output logic [FTQ_IDX_BITS-1:0]       deq_ftq_idx_o,
    output logic [FTQ_EPOCH_BITS-1:0]     deq_ftq_epoch_o,
    output logic [FTQ_ALLOC_TAG_BITS-1:0] deq_ftq_alloc_tag_o,

    // Status (for backpressure to F1 fire)
    output logic                          full,
    output logic                          empty,
    output logic [$clog2(DEPTH+1)-1:0]    count
);

    typedef struct packed {
        logic [511:0]                  data;
        logic                          hit;
        logic [63:0]                   pc;
        logic                          ftq_valid;
        logic [FTQ_IDX_BITS-1:0]       ftq_idx;
        logic [FTQ_EPOCH_BITS-1:0]     ftq_epoch;
        logic [FTQ_ALLOC_TAG_BITS-1:0] ftq_alloc_tag;
    } resp_entry_t;

    localparam int PTR_W = (DEPTH > 1) ? $clog2(DEPTH) : 1;

    resp_entry_t mem_r [0:DEPTH-1];
    logic [PTR_W-1:0] rd_ptr_r, wr_ptr_r;
    logic [$clog2(DEPTH+1)-1:0] count_r;

    logic enq_fire_c;
    logic deq_fire_c;

    assign empty       = (count_r == '0);
    assign full        = (count_r == DEPTH);
    assign count       = count_r;

    // Bypass: when empty + enq_valid + deq_ready, pass through combinationally
    // so the queue acts like a wire for the steady-state F1/F2-lockstep case.
    // Storage only fires for genuine buffering (decode backpressure or runahead).
    logic bypass_path_c;
    assign bypass_path_c = empty && resp_valid_i && deq_ready_i;

    assign deq_valid_o = !empty || resp_valid_i;

    // A response can arrive while the queue is full in the same cycle F2
    // retires the head line. Accept that replacement response; otherwise a
    // one-cycle icache response can be dropped even though a slot is freed at
    // the clock edge.
    assign enq_fire_c = resp_valid_i && (!full || deq_fire_c) && !bypass_path_c;
    assign deq_fire_c = !empty && deq_ready_i;  // pop only from mem; bypass uses no slot

    // Output the head entry (combinational, with bypass when empty)
    always_comb begin
        if (!empty) begin
            deq_data_o          = mem_r[rd_ptr_r].data;
            deq_hit_o           = mem_r[rd_ptr_r].hit;
            deq_pc_o            = mem_r[rd_ptr_r].pc;
            deq_ftq_valid_o     = mem_r[rd_ptr_r].ftq_valid;
            deq_ftq_idx_o       = mem_r[rd_ptr_r].ftq_idx;
            deq_ftq_epoch_o     = mem_r[rd_ptr_r].ftq_epoch;
            deq_ftq_alloc_tag_o = mem_r[rd_ptr_r].ftq_alloc_tag;
        end else if (resp_valid_i) begin
            // Bypass: empty queue passes the incoming response straight to F2
            deq_data_o          = resp_data_i;
            deq_hit_o           = resp_hit_i;
            deq_pc_o            = resp_pc_i;
            deq_ftq_valid_o     = resp_ftq_valid_i;
            deq_ftq_idx_o       = resp_ftq_idx_i;
            deq_ftq_epoch_o     = resp_ftq_epoch_i;
            deq_ftq_alloc_tag_o = resp_ftq_alloc_tag_i;
        end else begin
            deq_data_o          = '0;
            deq_hit_o           = 1'b0;
            deq_pc_o            = '0;
            deq_ftq_valid_o     = 1'b0;
            deq_ftq_idx_o       = '0;
            deq_ftq_epoch_o     = '0;
            deq_ftq_alloc_tag_o = '0;
        end
    end
    assign deq_line_addr_o = deq_pc_o[63:LINE_BITS];

    function automatic logic [PTR_W-1:0] ptr_next(input logic [PTR_W-1:0] p);
        if (DEPTH == 1) begin
            ptr_next = '0;
        end else if (p == PTR_W'(DEPTH - 1)) begin
            ptr_next = '0;
        end else begin
            ptr_next = p + PTR_W'(1);
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr_r <= '0;
            wr_ptr_r <= '0;
            count_r  <= '0;
        end else if (flush) begin
            rd_ptr_r <= '0;
            wr_ptr_r <= '0;
            count_r  <= '0;
        end else begin
            // Update memory on enq
            if (enq_fire_c) begin
                mem_r[wr_ptr_r].data          <= resp_data_i;
                mem_r[wr_ptr_r].hit           <= resp_hit_i;
                mem_r[wr_ptr_r].pc            <= resp_pc_i;
                mem_r[wr_ptr_r].ftq_valid     <= resp_ftq_valid_i;
                mem_r[wr_ptr_r].ftq_idx       <= resp_ftq_idx_i;
                mem_r[wr_ptr_r].ftq_epoch     <= resp_ftq_epoch_i;
                mem_r[wr_ptr_r].ftq_alloc_tag <= resp_ftq_alloc_tag_i;
            end

            // Update pointers
            case ({enq_fire_c, deq_fire_c})
                2'b10: begin
                    wr_ptr_r <= ptr_next(wr_ptr_r);
                    count_r  <= count_r + {{$clog2(DEPTH+1)-1{1'b0}}, 1'b1};
                end
                2'b01: begin
                    rd_ptr_r <= ptr_next(rd_ptr_r);
                    count_r  <= count_r - {{$clog2(DEPTH+1)-1{1'b0}}, 1'b1};
                end
                2'b11: begin
                    wr_ptr_r <= ptr_next(wr_ptr_r);
                    rd_ptr_r <= ptr_next(rd_ptr_r);
                end
                default: begin end
            endcase
        end
    end

endmodule

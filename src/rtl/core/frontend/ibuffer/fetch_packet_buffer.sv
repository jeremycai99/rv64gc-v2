/* file: fetch_packet_buffer.sv
 Description: Owner-aware instruction buffer between IFU and decode.
 Author: Jeremy Cai
 Date: Apr. 18, 2026
 Version: 2.0
*/
module fetch_packet_buffer
    import rv64gc_pkg::*;
    import uarch_pkg::*;
(
    input  logic          clk,
    input  logic          rst_n,
    input  logic          flush,

    input  logic          enq_valid,
    input  fetch_packet_t enq_packet,
    output logic          enq_ready,
    output logic          enq_fire,

    input  logic          deq_ready,
    output logic          deq_valid,
    output fetch_packet_t deq_packet,
    output logic          deq_fire,
    output logic          deq_flowthrough,

    input  logic                          owner_valid,
    input  logic [FTQ_IDX_BITS-1:0]       owner_idx,
    input  logic [FTQ_EPOCH_BITS-1:0]     owner_epoch,
    input  logic [FTQ_ALLOC_TAG_BITS-1:0] owner_tag,
    output logic                          deq_owner_match,
    output logic                          deq_stale_owner,
    output logic                          deq_owner_complete,

    output logic          full,
    output logic          empty,
    output logic [3:0]    count
);

    localparam int DEPTH = 8;
    localparam int PTR_W = $clog2(DEPTH);
    localparam int PKT_W = $bits(fetch_packet_t);

    logic [PKT_W-1:0] mem_r [0:DEPTH-1];
    logic [PTR_W-1:0] rd_ptr_r, wr_ptr_r;
    logic [PTR_W:0]   count_r;
    fetch_packet_t    head_packet_c;
    logic             deq_owner_ready_c;

    assign empty     = (count_r == '0);
    assign full      = (count_r == DEPTH);
    assign deq_valid = !empty || (enq_valid && empty);
    assign enq_fire  = enq_valid && enq_ready;
    assign count     = count_r;

    always_comb begin
        if (!empty) begin
            head_packet_c = fetch_packet_t'(mem_r[rd_ptr_r]);
        end else if (enq_valid) begin
            head_packet_c = enq_packet;
        end else begin
            head_packet_c = '0;
        end
    end
    assign deq_packet = head_packet_c;
    assign deq_owner_complete =
        deq_valid && head_packet_c.valid && head_packet_c.ftq_owner_complete;
    assign deq_owner_match =
        deq_valid &&
        head_packet_c.valid &&
        owner_valid &&
        (head_packet_c.ftq_idx == owner_idx) &&
        (head_packet_c.ftq_epoch == owner_epoch) &&
        (head_packet_c.ftq_alloc_tag == owner_tag);
    assign deq_stale_owner =
        deq_valid &&
        head_packet_c.valid &&
        (!owner_valid ||
         (head_packet_c.ftq_idx != owner_idx) ||
         (head_packet_c.ftq_epoch != owner_epoch) ||
         (head_packet_c.ftq_alloc_tag != owner_tag));
    assign deq_owner_ready_c = deq_ready && deq_owner_match;
    assign enq_ready = !full || deq_owner_ready_c;
    assign deq_fire  = deq_valid && deq_owner_ready_c;
    assign deq_flowthrough = empty && enq_valid && deq_owner_ready_c;

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
            case ({enq_fire, deq_fire, empty})
                3'b100,
                3'b101: begin
                    mem_r[wr_ptr_r] <= PKT_W'(enq_packet);
                    wr_ptr_r        <= wr_ptr_r + PTR_W'(1);
                    count_r         <= count_r + {{PTR_W{1'b0}}, 1'b1};
                end
                3'b010,
                3'b011: begin
                    rd_ptr_r        <= rd_ptr_r + PTR_W'(1);
                    count_r         <= count_r - {{PTR_W{1'b0}}, 1'b1};
                end
                3'b110: begin
                    mem_r[wr_ptr_r] <= PKT_W'(enq_packet);
                    wr_ptr_r        <= wr_ptr_r + PTR_W'(1);
                    rd_ptr_r        <= rd_ptr_r + PTR_W'(1);
                end
                3'b111: begin
                    // Empty-buffer flow-through: delivered directly from
                    // enq_packet, so no storage state changes.
                end
                default: begin
                end
            endcase
        end
    end

endmodule

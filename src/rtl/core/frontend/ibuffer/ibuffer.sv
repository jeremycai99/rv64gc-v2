/* file: ibuffer.sv
 Description: Architectural IBuffer wrapper around the current fetch packet FIFO.
 Author: Jeremy Cai
 Date: May 06, 2026
 Version: 1.0
*/
module ibuffer
    import rv64gc_pkg::*;
    import uarch_pkg::*;
(
    input  wire          clk,
    input  wire          rst_n,
    input  wire          flush,

    input  wire          enq_valid,
    input  fetch_packet_t enq_packet,
    output reg          enq_ready,
    output reg          enq_fire,

    input  wire          backend_stall_i,
    input  wire          frontend_hold_i,
    output reg          deq_ready,
    output reg          deq_valid,
    output fetch_packet_t deq_packet,
    output reg          deq_fire,
    output reg                         deq_flowthrough,
    output reg                         flowthrough_candidate,
    output reg                         flowthrough_owner_match,
    output reg                         flowthrough_valid,
    output reg                         commit_pop_valid,
    output reg                         packet_out_valid,
    output fetch_packet_t                packet_out,
    output reg [2:0]                   decode_fetch_count,
    output reg [31:0]                  decode_fetch_insn [0:PIPE_WIDTH-1],
    output reg [63:0]                  decode_fetch_pc [0:PIPE_WIDTH-1],
    output reg [PIPE_WIDTH-1:0]        decode_fetch_is_rvc,
    output reg [PIPE_WIDTH-1:0]        decode_fetch_bp_taken,
    output reg [63:0]                  decode_fetch_bp_target [0:PIPE_WIDTH-1],
    output reg                         decode_fetch_bp_owner_valid,
    output reg [2:0]                   decode_fetch_bp_owner_slot,
    output reg                         decode_fetch_bp_owner_from_subgroup,
    output reg [63:0]                  decode_fetch_bp_lookup_pc,
    output reg [4:0]                   decode_fetch_bp_ras_tos,
    output reg [63:0]                  decode_fetch_bp_ras_top,
    output reg [GHR_BITS-1:0]          decode_fetch_bp_ghr,

    input  wire                          owner_valid,
    input  wire [FTQ_IDX_BITS-1:0]       owner_idx,
    input  wire [FTQ_EPOCH_BITS-1:0]     owner_epoch,
    input  wire [FTQ_ALLOC_TAG_BITS-1:0] owner_tag,
    output reg                          deq_owner_match,
    output reg                          deq_stale_owner,
    output reg                          deq_owner_complete,

    output reg          full,
    output reg          empty,
    output reg [3:0]    count
);

    assign deq_ready = !backend_stall_i && !frontend_hold_i;

    fetch_packet_buffer u_fetch_packet_buffer (
        .clk               (clk),
        .rst_n             (rst_n),
        .flush             (flush),
        .enq_valid         (enq_valid),
        .enq_packet        (enq_packet),
        .enq_ready         (enq_ready),
        .enq_fire          (enq_fire),
        .deq_ready         (deq_ready),
        .deq_valid         (deq_valid),
        .deq_packet        (deq_packet),
        .deq_fire          (deq_fire),
        .deq_flowthrough   (deq_flowthrough),
        .owner_valid       (owner_valid),
        .owner_idx         (owner_idx),
        .owner_epoch       (owner_epoch),
        .owner_tag         (owner_tag),
        .deq_owner_match   (deq_owner_match),
        .deq_stale_owner   (deq_stale_owner),
        .deq_owner_complete(deq_owner_complete),
        .full              (full),
        .empty             (empty),
        .count             (count)
    );

    assign packet_out_valid = deq_fire && deq_owner_match;
    assign packet_out       = deq_packet;
    assign flowthrough_candidate   = deq_flowthrough;
    assign flowthrough_owner_match = deq_flowthrough && deq_owner_match;
    assign flowthrough_valid       = deq_flowthrough;
    assign commit_pop_valid        =
        deq_fire && deq_owner_match && deq_owner_complete;

    always_comb begin
        decode_fetch_count                  = 3'd0;
        decode_fetch_bp_owner_valid         = 1'b0;
        decode_fetch_bp_owner_slot          = 3'd0;
        decode_fetch_bp_owner_from_subgroup = 1'b0;
        decode_fetch_bp_lookup_pc           = 64'd0;
        decode_fetch_bp_ras_tos             = 5'd0;
        decode_fetch_bp_ras_top             = 64'd0;
        decode_fetch_bp_ghr                 = '0;
        decode_fetch_is_rvc                 = '0;
        decode_fetch_bp_taken               = '0;

        for (int i = 0; i < PIPE_WIDTH; i++) begin
            decode_fetch_insn[i]      = 32'h0000_0013;
            decode_fetch_pc[i]        = '0;
            decode_fetch_bp_target[i] = '0;
        end

        if (packet_out_valid) begin
            decode_fetch_count                  = deq_packet.fetch_count;
            decode_fetch_bp_owner_valid         = deq_packet.pd_ctl_valid;
            decode_fetch_bp_owner_slot          = deq_packet.pd_ctl_slot;
            decode_fetch_bp_owner_from_subgroup =
                deq_packet.pd_ctl_valid &&
                deq_packet.ftq_pred_from_subgroup;
            decode_fetch_bp_lookup_pc           = deq_packet.ftq_bp_lookup_pc;
            decode_fetch_bp_ras_tos             = deq_packet.fetch_bp_ras_tos;
            decode_fetch_bp_ras_top             = deq_packet.fetch_bp_ras_top;
            decode_fetch_bp_ghr                 = deq_packet.fetch_bp_ghr;
            decode_fetch_is_rvc                 = deq_packet.fetch_is_rvc;
            decode_fetch_bp_taken               = deq_packet.fetch_bp_taken;

            for (int i = 0; i < PIPE_WIDTH; i++) begin
                decode_fetch_insn[i]      = deq_packet.fetch_insn[i];
                decode_fetch_pc[i]        = deq_packet.fetch_pc[i];
                decode_fetch_bp_target[i] = deq_packet.fetch_bp_target[i];
            end
        end
    end

endmodule

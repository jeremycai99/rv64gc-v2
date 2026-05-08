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
    input  logic          clk,
    input  logic          rst_n,
    input  logic          flush,

    input  logic          enq_valid,
    input  fetch_packet_t enq_packet,
    output logic          enq_ready,
    output logic          enq_fire,

    input  logic          backend_stall_i,
    input  logic          frontend_hold_i,
    output logic          deq_ready,
    output logic          deq_valid,
    output fetch_packet_t deq_packet,
    output logic          deq_fire,
    output logic                         deq_flowthrough,
    output logic                         flowthrough_candidate,
    output logic                         flowthrough_owner_match,
    output logic                         flowthrough_valid,
    output logic                         commit_pop_valid,
    output logic                         packet_out_valid,
    output fetch_packet_t                packet_out,
    output logic [2:0]                   decode_fetch_count,
    output logic [31:0]                  decode_fetch_insn [0:PIPE_WIDTH-1],
    output logic [63:0]                  decode_fetch_pc [0:PIPE_WIDTH-1],
    output logic [PIPE_WIDTH-1:0]        decode_fetch_is_rvc,
    output logic [PIPE_WIDTH-1:0]        decode_fetch_bp_taken,
    output logic [63:0]                  decode_fetch_bp_target [0:PIPE_WIDTH-1],
    output logic                         decode_fetch_bp_owner_valid,
    output logic [2:0]                   decode_fetch_bp_owner_slot,
    output logic                         decode_fetch_bp_owner_from_subgroup,
    output logic [63:0]                  decode_fetch_bp_lookup_pc,
    output logic [4:0]                   decode_fetch_bp_ras_tos,
    output logic [63:0]                  decode_fetch_bp_ras_top,
    output logic [GHR_BITS-1:0]          decode_fetch_bp_ghr,

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

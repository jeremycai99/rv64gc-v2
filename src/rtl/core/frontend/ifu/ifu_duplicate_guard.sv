/* file: ifu_duplicate_guard.sv
 Description: Legacy IFU packet duplicate and replay suppression guard.
 Author: Jeremy Cai
 Date: May 06, 2026
 Version: 1.0
*/
module ifu_duplicate_guard
    import rv64gc_pkg::*;
(
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          redirect_i,
    input  wire                          bpu_redirect_i,
    input  wire                          stall_i,
    input  wire                          will_emit_i,
    input  wire                          has_emit_payload_i,
    input  wire                          bp_branch_found_i,
    input  wire                          bp_taken_i,
    input  wire                          subgroup_split_before_ctl_i,
    input  wire [63:0]                   bp_target_i,
    input  wire                          seq_valid_i,
    input  wire [63:0]                   seq_next_pc_i,
    input  wire [63:0]                   f1_pc_i,
    input  wire [63:0]                   bpu_target_i,
    input  wire                          work_ftq_valid_i,
    input  wire [63:0]                   work_pc_i,
    input  wire [FTQ_IDX_BITS-1:0]       work_ftq_idx_i,
    input  wire [FTQ_EPOCH_BITS-1:0]     work_ftq_epoch_i,
    input  wire [FTQ_ALLOC_TAG_BITS-1:0] work_ftq_alloc_tag_i,

    output logic                          duplicate_suppressed_o,
    output logic [63:0]                   duplicate_next_pc_o,
    output logic                          last_emit_hit_o,
    output logic                          replay_block_hit_o,
    output logic                          last_emit_valid_o,
    output logic [63:0]                   last_emit_pc_o,
    output logic [63:0]                   last_emit_next_pc_o,
    output logic [63:0]                   replay_block_pc_o,
    output logic [1:0]                    replay_block_age_o
);

    logic        last_emit_valid_r;
    logic [63:0] last_emit_pc_r;
    logic [63:0] last_emit_next_pc_r;
    logic        last_emit_ftq_valid_r;
    logic [FTQ_IDX_BITS-1:0] last_emit_ftq_idx_r;
    logic [FTQ_EPOCH_BITS-1:0] last_emit_ftq_epoch_r;
    logic [FTQ_ALLOC_TAG_BITS-1:0] last_emit_ftq_alloc_tag_r;
    logic        replay_block_valid_r;
    logic [63:0] replay_block_pc_r;
    logic        replay_block_ftq_valid_r;
    logic [FTQ_IDX_BITS-1:0] replay_block_ftq_idx_r;
    logic [FTQ_EPOCH_BITS-1:0] replay_block_ftq_epoch_r;
    logic [FTQ_ALLOC_TAG_BITS-1:0] replay_block_ftq_alloc_tag_r;
    logic [1:0]  replay_block_age_r;
    logic        last_emit_owner_match_c;
    logic        replay_block_owner_match_c;

    assign last_emit_owner_match_c =
        (last_emit_ftq_valid_r && work_ftq_valid_i &&
         (last_emit_ftq_idx_r == work_ftq_idx_i) &&
         (last_emit_ftq_epoch_r == work_ftq_epoch_i) &&
         (last_emit_ftq_alloc_tag_r == work_ftq_alloc_tag_i)) ||
        (!last_emit_ftq_valid_r && !work_ftq_valid_i);
    assign last_emit_hit_o =
        last_emit_valid_r &&
        (last_emit_pc_r == work_pc_i) &&
        last_emit_owner_match_c;
    assign replay_block_owner_match_c =
        (replay_block_ftq_valid_r && work_ftq_valid_i &&
         (replay_block_ftq_idx_r == work_ftq_idx_i) &&
         (replay_block_ftq_epoch_r == work_ftq_epoch_i) &&
         (replay_block_ftq_alloc_tag_r == work_ftq_alloc_tag_i)) ||
        (!replay_block_ftq_valid_r && !work_ftq_valid_i);
    assign replay_block_hit_o =
        replay_block_valid_r &&
        (replay_block_pc_r == work_pc_i) &&
        replay_block_owner_match_c;
    assign duplicate_suppressed_o =
        has_emit_payload_i &&
        (last_emit_hit_o || replay_block_hit_o);
    assign duplicate_next_pc_o =
        last_emit_hit_o
            ? last_emit_next_pc_r
            : (seq_valid_i ? seq_next_pc_i : f1_pc_i);
    assign last_emit_valid_o = last_emit_valid_r;
    assign last_emit_pc_o = last_emit_pc_r;
    assign last_emit_next_pc_o = last_emit_next_pc_r;
    assign replay_block_pc_o = replay_block_pc_r;
    assign replay_block_age_o = replay_block_age_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            last_emit_valid_r <= 1'b0;
            last_emit_pc_r <= '0;
            last_emit_next_pc_r <= '0;
            last_emit_ftq_valid_r <= 1'b0;
            last_emit_ftq_idx_r <= '0;
            last_emit_ftq_epoch_r <= '0;
            last_emit_ftq_alloc_tag_r <= '0;
            replay_block_valid_r <= 1'b0;
            replay_block_pc_r <= '0;
            replay_block_ftq_valid_r <= 1'b0;
            replay_block_ftq_idx_r <= '0;
            replay_block_ftq_epoch_r <= '0;
            replay_block_ftq_alloc_tag_r <= '0;
            replay_block_age_r <= '0;
        end else if (redirect_i) begin
            last_emit_valid_r <= 1'b0;
            last_emit_ftq_valid_r <= 1'b0;
            replay_block_valid_r <= 1'b0;
            replay_block_ftq_valid_r <= 1'b0;
            last_emit_next_pc_r <= '0;
            replay_block_pc_r <= '0;
            replay_block_age_r <= '0;
        end else if (bpu_redirect_i && !stall_i) begin
            last_emit_valid_r <= (bpu_target_i != work_pc_i);
            last_emit_pc_r <= work_pc_i;
            last_emit_next_pc_r <= bpu_target_i;
            last_emit_ftq_valid_r <= work_ftq_valid_i;
            last_emit_ftq_idx_r <= work_ftq_idx_i;
            last_emit_ftq_epoch_r <= work_ftq_epoch_i;
            last_emit_ftq_alloc_tag_r <= work_ftq_alloc_tag_i;
            replay_block_valid_r <= (bpu_target_i != work_pc_i);
            replay_block_pc_r <= work_pc_i;
            replay_block_ftq_valid_r <= work_ftq_valid_i;
            replay_block_ftq_idx_r <= work_ftq_idx_i;
            replay_block_ftq_epoch_r <= work_ftq_epoch_i;
            replay_block_ftq_alloc_tag_r <= work_ftq_alloc_tag_i;
            replay_block_age_r <= 2'd2;
        end else begin
            if (will_emit_i) begin
                last_emit_valid_r <= 1'b1;
                last_emit_pc_r <= work_pc_i;
                last_emit_ftq_valid_r <= work_ftq_valid_i;
                last_emit_ftq_idx_r <= work_ftq_idx_i;
                last_emit_ftq_epoch_r <= work_ftq_epoch_i;
                last_emit_ftq_alloc_tag_r <= work_ftq_alloc_tag_i;
                if (bp_branch_found_i && bp_taken_i &&
                    !subgroup_split_before_ctl_i && !redirect_i) begin
                    last_emit_next_pc_r <= bp_target_i;
                end else if (seq_valid_i) begin
                    last_emit_next_pc_r <= seq_next_pc_i;
                end else begin
                    last_emit_next_pc_r <= f1_pc_i;
                end
            end
            if (replay_block_valid_r && !stall_i) begin
                if (will_emit_i &&
                    ((work_pc_i != replay_block_pc_r) ||
                     !replay_block_owner_match_c)) begin
                    replay_block_valid_r <= 1'b0;
                    replay_block_ftq_valid_r <= 1'b0;
                    replay_block_age_r <= '0;
                end else if (replay_block_hit_o && has_emit_payload_i) begin
                    replay_block_valid_r <= 1'b0;
                    replay_block_ftq_valid_r <= 1'b0;
                    replay_block_age_r <= '0;
                end else if (replay_block_age_r == 2'd0) begin
                    replay_block_valid_r <= 1'b0;
                    replay_block_ftq_valid_r <= 1'b0;
                end else begin
                    replay_block_age_r <= replay_block_age_r - 2'd1;
                end
            end
        end
    end

endmodule

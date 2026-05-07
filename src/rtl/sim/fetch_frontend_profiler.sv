/* file: fetch_frontend_profiler.sv
 Description: Simulation-only frontend performance profiler.
 Author: Jeremy Cai
 Date: May 07, 2026
 Version: 1.0
*/
`ifdef SIMULATION
module fetch_frontend_profiler
    import rv64gc_pkg::*;
    import uarch_pkg::*;
(
    input logic                             clk,
    input logic                             rst_n,
    input logic                             f2_duplicate_suppressed_c,
    input logic                             f2_last_emit_hit_c,
    input logic                             f1_valid,
    input logic [63:0]                      f1_pc,
    input logic [63:0]                      f2_last_emit_next_pc_r,
    input logic                             packet_buf_empty,
    input logic                             redirect_valid,
    input logic                             backend_stall,
    input logic                             frontend_hold,
    input logic                             fe_stall,
    input logic [2:0]                       fetch_count,
    input logic [63:0]                      f2_work_pc_c,
    input logic                             nlpb_aux_hit_comb,
    input logic                             f1_aux_pred_ctl_valid_c,
    input logic                             f1_aux_pred_ctl_taken_c,
    input logic [2:0]                       f1_aux_pred_ctl_type_c,
    input logic [63:0]                      f1_aux_pred_ctl_target_c,
    input logic                             f2_last_emit_valid_r,
    input logic [63:0]                      f2_last_emit_pc_r,
    input logic                             f2_replay_block_hit_c,
    input logic                             f2_work_ftq_valid_c,
    input logic [FTQ_IDX_BITS-1:0]          f2_work_ftq_idx_c,
    input logic [FTQ_EPOCH_BITS-1:0]        f2_work_ftq_epoch_c,
    input logic [FTQ_ALLOC_TAG_BITS-1:0]    f2_work_ftq_alloc_tag_c,
    input logic                             ftq_ifu_wb_owner_valid,
    input logic [FTQ_IDX_BITS-1:0]          ftq_ifu_wb_owner_idx,
    input logic [FTQ_ALLOC_TAG_BITS-1:0]    ftq_ifu_wb_owner_tag,
    input logic [FTQ_EPOCH_BITS-1:0]        ftq_current_epoch,
    input logic                             f2_owner_completion_candidate_c,
    input logic                             packet_buf_valid,
    input fetch_packet_t                    packet_buf_head,
    input logic                             ftq_commit_owner_valid,
    input logic [FTQ_IDX_BITS-1:0]          ftq_commit_owner_idx,
    input logic [FTQ_ALLOC_TAG_BITS-1:0]    ftq_commit_owner_tag,
    input logic                             packet_flowthrough_owner_match_c,
    input logic                             f2_work_owner_complete_c,
    input logic                             ftq_empty,
    input logic                             ftq_full,
    input logic [FTQ_IDX_BITS:0]            ftq_count,
    input logic                             packet_buf_full,
    input logic [3:0]                       packet_buf_count,
    input logic                             ftq_enq_valid,
    input logic                             ftq_pop_valid,
    input logic                             ic_req_valid,
    input logic                             ftq_need_alloc_c,
    input logic                             f2_ftq_owner_live_c,
    input logic                             f2_same_owner_continue_c,
    input logic                             f2_seq_valid,
    input logic [63:0]                      f2_seq_next_pc,
    input logic                             f2_will_emit_c,
    input logic                             packet_buf_enq,
    input logic                             line_straddle_advance_c,
    input logic                             consume_remainder_c,
    input logic                             consumed_remainder_r,
    input ftq_entry_t                       f2_work_ftq_entry_c,
    input logic [63:LINE_BITS]              f2_work_line_addr_c,
    input logic                             ifu_work_same_owner_advance_c,
    input logic                             packet_flowthrough_candidate,
    input logic                             packet_flowthrough_valid,
    input logic                             packet_buf_stale_owner_c,
    input logic [FTQ_IDX_BITS:0]            ftq_count_alloc_to_ifu,
    input logic [FTQ_IDX_BITS:0]            ftq_count_ifu_to_wb,
    input logic                             icq_deq_valid,
    input logic [63:LINE_BITS]              icq_deq_line_addr,
    input logic                             f2_work_line_valid_c,
    input logic                             ifu_runahead_req_valid_c,
    input logic                             ifu_runahead_req_fire_c,
    input logic                             ifu_runahead_cancel_next_c,
    input logic                             ifu_runahead_pending_c,
    input logic                             ifu_runahead_redirect_match_c,
    input logic                             ifu_runahead_duplicate_alloc_blocked_c,
    input logic                             ifu_runahead_depth_gt1_c
);

    localparam logic [2:0] BT_RET = 3'd4;
    localparam int XS_CATCHUP_TOPN = 8;

    logic xs_catchup_probe_en;
    logic xs_catchup_trace_en;
    logic xs_catchup_base_c;
    logic xs_catchup_fetch0_c;
    logic xs_catchup_crossline_c;
    logic xs_catchup_nlpb_c;
    logic xs_catchup_aux_taken_c;
    logic xs_catchup_recoverable_c;
    logic xs_catchup_target_last_c;

    integer xs_catchup_base_cycles;
    integer xs_catchup_fetch0_cycles;
    integer xs_catchup_crossline_cycles;
    integer xs_catchup_nlpb_cycles;
    integer xs_catchup_aux_taken_cycles;
    integer xs_catchup_recoverable_cycles;
    integer xs_catchup_target_last_cycles;
    integer xs_catchup_ret_cycles;
    integer xs_packet_buf_stale_owner_cycles;
    integer xs_ftq_empty_cycles;
    integer xs_ftq_full_cycles;
    integer xs_ftq_occ_sum;
    integer xs_ftq_occ_max;
    integer xs_ftq_occ_hist [0:5];
    integer xs_packet_buf_empty_cycles;
    integer xs_packet_buf_full_cycles;
    integer xs_packet_buf_occ_sum;
    integer xs_packet_buf_occ_max;
    integer xs_packet_buf_occ_hist [0:4];
    integer xs_ftq_alloc_cycles;
    integer xs_ftq_pop_cycles;
    integer xs_ftq_alloc_pop_cycles;
    integer xs_ic_req_valid_cycles;
    integer xs_ic_req_stall_frontend_hold_cycles;
    integer xs_ic_req_stall_packet_full_cycles;
    integer xs_ic_req_stall_ftq_full_cycles;
    integer xs_backend_stall_cycles;
    integer xs_backend_stall_packet_ready_cycles;
    integer xs_frontend_hold_cycles;
    integer xs_dup_last_emit_cycles;
    integer xs_dup_replay_guard_cycles;
    integer xs_dup_both_reasons_cycles;
    integer xs_f2_owner_no_head_cycles;
    integer xs_f2_owner_idx_mismatch_cycles;
    integer xs_f2_owner_epoch_mismatch_cycles;
    integer xs_f2_owner_tag_mismatch_cycles;
    integer xs_f2_owner_live_cycles;
    integer xs_f2_cursor_wb_no_head_cycles;
    integer xs_f2_cursor_wb_idx_skew_cycles;
    integer xs_f2_cursor_wb_epoch_skew_cycles;
    integer xs_f2_cursor_wb_tag_skew_cycles;
    integer xs_packet_stale_no_head_cycles;
    integer xs_packet_stale_idx_mismatch_cycles;
    integer xs_packet_stale_epoch_mismatch_cycles;
    integer xs_packet_stale_tag_mismatch_cycles;
    integer xs_flowthrough_candidate_cycles;
    integer xs_flowthrough_owner_miss_cycles;
    integer xs_flowthrough_incomplete_owner_cycles;
    integer xs_flowthrough_valid_cycles;
    integer xs_same_owner_candidate_cycles;
    integer xs_same_owner_emit_candidate_cycles;
    integer xs_same_owner_advanced_cycles;
    integer xs_same_owner_block_no_emit_cycles;
    integer xs_same_owner_block_no_enq_cycles;
    integer xs_same_owner_block_owner_not_live_cycles;
    integer xs_same_owner_block_owner_complete_cycles;
    integer xs_same_owner_block_pred_ctl_cycles;
    integer xs_same_owner_block_remainder_cycles;
    integer xs_same_owner_block_crossline_cycles;
    integer xs_same_owner_block_other_cycles;
    integer xs_runahead_req_valid_cycles;
    integer xs_runahead_req_fire_cycles;
    integer xs_runahead_cancel_next_cycles;
    integer xs_runahead_pending_cycles;
    integer xs_runahead_redirect_match_cycles;
    integer xs_runahead_duplicate_alloc_blocked_cycles;
    integer xs_ftq_depth_gt1_cycles;
    integer xs_icq_future_head_block_cycles;

    logic [63:0] xs_catchup_top_pc [0:XS_CATCHUP_TOPN-1];
    integer xs_catchup_top_count [0:XS_CATCHUP_TOPN-1];
    logic [63:0] xs_dup_top_pc [0:XS_CATCHUP_TOPN-1];
    integer xs_dup_top_count [0:XS_CATCHUP_TOPN-1];

    logic xs_dup_last_emit_c;
    logic xs_dup_replay_guard_c;
    logic xs_f2_owner_no_head_c;
    logic xs_f2_owner_idx_mismatch_c;
    logic xs_f2_owner_epoch_mismatch_c;
    logic xs_f2_owner_tag_mismatch_c;
    logic xs_f2_cursor_wb_no_head_c;
    logic xs_f2_cursor_wb_idx_skew_c;
    logic xs_f2_cursor_wb_epoch_skew_c;
    logic xs_f2_cursor_wb_tag_skew_c;
    logic xs_packet_stale_no_head_c;
    logic xs_packet_stale_idx_mismatch_c;
    logic xs_packet_stale_epoch_mismatch_c;
    logic xs_packet_stale_tag_mismatch_c;
    logic xs_flowthrough_incomplete_owner_c;
    logic xs_same_owner_candidate_c;
    logic xs_same_owner_emit_candidate_c;
    logic xs_same_owner_crossline_c;
    logic xs_same_owner_pred_ctl_window_c;
    logic xs_same_owner_remainder_hold_c;
    logic xs_same_owner_block_no_emit_c;
    logic xs_same_owner_block_no_enq_c;
    logic xs_same_owner_block_owner_not_live_c;
    logic xs_same_owner_block_owner_complete_c;
    logic xs_same_owner_block_pred_ctl_c;
    logic xs_same_owner_block_remainder_c;
    logic xs_same_owner_block_crossline_c;
    logic xs_same_owner_block_other_c;
    logic xs_icq_future_head_block_c;

    initial begin
        xs_catchup_probe_en = 1'b0;
        xs_catchup_trace_en = 1'b0;
        if ($test$plusargs("PERF_PROFILE") ||
            $test$plusargs("STAT_DUMP") ||
            $test$plusargs("TRACE_XS_CATCHUP")) begin
            xs_catchup_probe_en = 1'b1;
        end
        if ($test$plusargs("TRACE_XS_CATCHUP"))
            xs_catchup_trace_en = 1'b1;
    end

    assign xs_catchup_base_c =
        f2_duplicate_suppressed_c &&
        f2_last_emit_hit_c &&
        f1_valid &&
        (f1_pc == f2_last_emit_next_pc_r) &&
        packet_buf_empty &&
        !redirect_valid &&
        !backend_stall &&
        !frontend_hold &&
        !fe_stall;
    assign xs_catchup_fetch0_c =
        xs_catchup_base_c && (fetch_count == 3'd0);
    assign xs_catchup_crossline_c =
        xs_catchup_base_c &&
        (f1_pc[63:LINE_BITS] != f2_work_pc_c[63:LINE_BITS]);
    assign xs_catchup_nlpb_c =
        xs_catchup_base_c && nlpb_aux_hit_comb;
    assign xs_catchup_aux_taken_c =
        xs_catchup_base_c &&
        f1_aux_pred_ctl_valid_c &&
        f1_aux_pred_ctl_taken_c;
    assign xs_catchup_recoverable_c =
        xs_catchup_fetch0_c &&
        xs_catchup_crossline_c &&
        nlpb_aux_hit_comb &&
        f1_aux_pred_ctl_valid_c &&
        f1_aux_pred_ctl_taken_c;
    assign xs_catchup_target_last_c =
        xs_catchup_recoverable_c &&
        (f1_aux_pred_ctl_target_c == f2_last_emit_pc_r);
    assign xs_dup_last_emit_c =
        f2_duplicate_suppressed_c &&
        f2_last_emit_valid_r &&
        (f2_last_emit_pc_r == f2_work_pc_c);
    assign xs_dup_replay_guard_c =
        f2_duplicate_suppressed_c &&
        f2_replay_block_hit_c;
    assign xs_f2_cursor_wb_no_head_c =
        f2_work_ftq_valid_c && !ftq_ifu_wb_owner_valid;
    assign xs_f2_cursor_wb_idx_skew_c =
        f2_work_ftq_valid_c && ftq_ifu_wb_owner_valid &&
        (f2_work_ftq_idx_c != ftq_ifu_wb_owner_idx);
    assign xs_f2_cursor_wb_epoch_skew_c =
        f2_work_ftq_valid_c && ftq_ifu_wb_owner_valid &&
        (f2_work_ftq_idx_c == ftq_ifu_wb_owner_idx) &&
        (f2_work_ftq_epoch_c != ftq_current_epoch);
    assign xs_f2_cursor_wb_tag_skew_c =
        f2_work_ftq_valid_c && ftq_ifu_wb_owner_valid &&
        (f2_work_ftq_idx_c == ftq_ifu_wb_owner_idx) &&
        (f2_work_ftq_epoch_c == ftq_current_epoch) &&
        (f2_work_ftq_alloc_tag_c != ftq_ifu_wb_owner_tag);
    assign xs_f2_owner_no_head_c =
        f2_owner_completion_candidate_c && !ftq_ifu_wb_owner_valid;
    assign xs_f2_owner_idx_mismatch_c =
        f2_owner_completion_candidate_c && ftq_ifu_wb_owner_valid &&
        (f2_work_ftq_idx_c != ftq_ifu_wb_owner_idx);
    assign xs_f2_owner_epoch_mismatch_c =
        f2_owner_completion_candidate_c && ftq_ifu_wb_owner_valid &&
        (f2_work_ftq_idx_c == ftq_ifu_wb_owner_idx) &&
        (f2_work_ftq_epoch_c != ftq_current_epoch);
    assign xs_f2_owner_tag_mismatch_c =
        f2_owner_completion_candidate_c && ftq_ifu_wb_owner_valid &&
        (f2_work_ftq_idx_c == ftq_ifu_wb_owner_idx) &&
        (f2_work_ftq_epoch_c == ftq_current_epoch) &&
        (f2_work_ftq_alloc_tag_c != ftq_ifu_wb_owner_tag);
    assign xs_packet_stale_no_head_c =
        packet_buf_valid && packet_buf_head.valid && !ftq_commit_owner_valid;
    assign xs_packet_stale_idx_mismatch_c =
        packet_buf_valid && packet_buf_head.valid && ftq_commit_owner_valid &&
        (packet_buf_head.ftq_idx != ftq_commit_owner_idx);
    assign xs_packet_stale_epoch_mismatch_c =
        packet_buf_valid && packet_buf_head.valid && ftq_commit_owner_valid &&
        (packet_buf_head.ftq_idx == ftq_commit_owner_idx) &&
        (packet_buf_head.ftq_epoch != ftq_current_epoch);
    assign xs_packet_stale_tag_mismatch_c =
        packet_buf_valid && packet_buf_head.valid && ftq_commit_owner_valid &&
        (packet_buf_head.ftq_idx == ftq_commit_owner_idx) &&
        (packet_buf_head.ftq_epoch == ftq_current_epoch) &&
        (packet_buf_head.ftq_alloc_tag != ftq_commit_owner_tag);
    assign xs_flowthrough_incomplete_owner_c =
        packet_flowthrough_owner_match_c &&
        !f2_work_owner_complete_c;
    assign xs_same_owner_candidate_c =
        f2_same_owner_continue_c &&
        f2_seq_valid &&
        f2_work_ftq_valid_c;
    assign xs_same_owner_emit_candidate_c =
        xs_same_owner_candidate_c &&
        f2_will_emit_c;
    assign xs_same_owner_crossline_c =
        xs_same_owner_emit_candidate_c &&
        (f2_seq_next_pc[63:LINE_BITS] != f2_work_line_addr_c);
    assign xs_same_owner_pred_ctl_window_c =
        xs_same_owner_emit_candidate_c &&
        f2_work_ftq_entry_c.pred_ctl_valid &&
        ({1'b0, f2_seq_next_pc[5:0]} !=
         {1'b0, f2_work_ftq_entry_c.pred_ctl_offset}) &&
        (({1'b0, f2_seq_next_pc[5:0]} + 7'd16) >
         {1'b0, f2_work_ftq_entry_c.pred_ctl_offset});
    assign xs_same_owner_remainder_hold_c =
        xs_same_owner_emit_candidate_c &&
        (line_straddle_advance_c ||
         consume_remainder_c ||
         consumed_remainder_r);
    assign xs_same_owner_block_no_emit_c =
        xs_same_owner_candidate_c &&
        !f2_will_emit_c &&
        !ifu_work_same_owner_advance_c;
    assign xs_same_owner_block_no_enq_c =
        xs_same_owner_emit_candidate_c &&
        !packet_buf_enq;
    assign xs_same_owner_block_owner_not_live_c =
        xs_same_owner_emit_candidate_c &&
        packet_buf_enq &&
        !f2_ftq_owner_live_c;
    assign xs_same_owner_block_owner_complete_c =
        xs_same_owner_emit_candidate_c &&
        packet_buf_enq &&
        f2_ftq_owner_live_c &&
        f2_work_owner_complete_c;
    assign xs_same_owner_block_pred_ctl_c =
        xs_same_owner_emit_candidate_c &&
        packet_buf_enq &&
        f2_ftq_owner_live_c &&
        !f2_work_owner_complete_c &&
        xs_same_owner_pred_ctl_window_c;
    assign xs_same_owner_block_remainder_c =
        xs_same_owner_emit_candidate_c &&
        packet_buf_enq &&
        f2_ftq_owner_live_c &&
        !f2_work_owner_complete_c &&
        !xs_same_owner_pred_ctl_window_c &&
        xs_same_owner_remainder_hold_c;
    assign xs_same_owner_block_crossline_c =
        xs_same_owner_emit_candidate_c &&
        packet_buf_enq &&
        f2_ftq_owner_live_c &&
        !f2_work_owner_complete_c &&
        !xs_same_owner_pred_ctl_window_c &&
        !xs_same_owner_remainder_hold_c &&
        xs_same_owner_crossline_c;
    assign xs_same_owner_block_other_c =
        xs_same_owner_emit_candidate_c &&
        packet_buf_enq &&
        f2_ftq_owner_live_c &&
        !f2_work_owner_complete_c &&
        !xs_same_owner_pred_ctl_window_c &&
        !xs_same_owner_remainder_hold_c &&
        !xs_same_owner_crossline_c &&
        !ifu_work_same_owner_advance_c;
    assign xs_icq_future_head_block_c =
        icq_deq_valid &&
        f2_work_line_valid_c &&
        (icq_deq_line_addr != f2_work_line_addr_c);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            xs_catchup_base_cycles        <= 0;
            xs_catchup_fetch0_cycles      <= 0;
            xs_catchup_crossline_cycles   <= 0;
            xs_catchup_nlpb_cycles        <= 0;
            xs_catchup_aux_taken_cycles   <= 0;
            xs_catchup_recoverable_cycles <= 0;
            xs_catchup_target_last_cycles <= 0;
            xs_catchup_ret_cycles         <= 0;
            xs_packet_buf_stale_owner_cycles <= 0;
            xs_ftq_empty_cycles           <= 0;
            xs_ftq_full_cycles            <= 0;
            xs_ftq_occ_sum                <= 0;
            xs_ftq_occ_max                <= 0;
            xs_packet_buf_empty_cycles    <= 0;
            xs_packet_buf_full_cycles     <= 0;
            xs_packet_buf_occ_sum         <= 0;
            xs_packet_buf_occ_max         <= 0;
            xs_ftq_alloc_cycles           <= 0;
            xs_ftq_pop_cycles             <= 0;
            xs_ftq_alloc_pop_cycles       <= 0;
            xs_ic_req_valid_cycles        <= 0;
            xs_ic_req_stall_frontend_hold_cycles <= 0;
            xs_ic_req_stall_packet_full_cycles   <= 0;
            xs_ic_req_stall_ftq_full_cycles      <= 0;
            xs_backend_stall_cycles       <= 0;
            xs_backend_stall_packet_ready_cycles <= 0;
            xs_frontend_hold_cycles       <= 0;
            xs_dup_last_emit_cycles       <= 0;
            xs_dup_replay_guard_cycles    <= 0;
            xs_dup_both_reasons_cycles    <= 0;
            xs_f2_owner_no_head_cycles    <= 0;
            xs_f2_owner_idx_mismatch_cycles <= 0;
            xs_f2_owner_epoch_mismatch_cycles <= 0;
            xs_f2_owner_tag_mismatch_cycles <= 0;
            xs_f2_owner_live_cycles       <= 0;
            xs_f2_cursor_wb_no_head_cycles <= 0;
            xs_f2_cursor_wb_idx_skew_cycles <= 0;
            xs_f2_cursor_wb_epoch_skew_cycles <= 0;
            xs_f2_cursor_wb_tag_skew_cycles <= 0;
            xs_packet_stale_no_head_cycles <= 0;
            xs_packet_stale_idx_mismatch_cycles <= 0;
            xs_packet_stale_epoch_mismatch_cycles <= 0;
            xs_packet_stale_tag_mismatch_cycles <= 0;
            xs_flowthrough_candidate_cycles    <= 0;
            xs_flowthrough_owner_miss_cycles   <= 0;
            xs_flowthrough_incomplete_owner_cycles <= 0;
            xs_flowthrough_valid_cycles        <= 0;
            xs_same_owner_candidate_cycles     <= 0;
            xs_same_owner_emit_candidate_cycles <= 0;
            xs_same_owner_advanced_cycles      <= 0;
            xs_same_owner_block_no_emit_cycles <= 0;
            xs_same_owner_block_no_enq_cycles  <= 0;
            xs_same_owner_block_owner_not_live_cycles <= 0;
            xs_same_owner_block_owner_complete_cycles <= 0;
            xs_same_owner_block_pred_ctl_cycles <= 0;
            xs_same_owner_block_remainder_cycles <= 0;
            xs_same_owner_block_crossline_cycles <= 0;
            xs_same_owner_block_other_cycles   <= 0;
            xs_runahead_req_valid_cycles       <= 0;
            xs_runahead_req_fire_cycles        <= 0;
            xs_runahead_cancel_next_cycles      <= 0;
            xs_runahead_pending_cycles         <= 0;
            xs_runahead_redirect_match_cycles  <= 0;
            xs_runahead_duplicate_alloc_blocked_cycles <= 0;
            xs_ftq_depth_gt1_cycles            <= 0;
            xs_icq_future_head_block_cycles    <= 0;
            for (int i = 0; i < XS_CATCHUP_TOPN; i++) begin
                xs_catchup_top_pc[i]    <= 64'd0;
                xs_catchup_top_count[i] <= 0;
                xs_dup_top_pc[i]        <= 64'd0;
                xs_dup_top_count[i]     <= 0;
            end
            for (int i = 0; i < 6; i++) begin
                xs_ftq_occ_hist[i] <= 0;
            end
            for (int i = 0; i < 5; i++) begin
                xs_packet_buf_occ_hist[i] <= 0;
            end
        end else if (xs_catchup_probe_en) begin
            if (ftq_empty)
                xs_ftq_empty_cycles <= xs_ftq_empty_cycles + 1;
            if (ftq_full)
                xs_ftq_full_cycles <= xs_ftq_full_cycles + 1;
            xs_ftq_occ_sum <= xs_ftq_occ_sum + int'(ftq_count);
            if (int'(ftq_count) > xs_ftq_occ_max)
                xs_ftq_occ_max <= int'(ftq_count);
            if (ftq_count == '0)
                xs_ftq_occ_hist[0] <= xs_ftq_occ_hist[0] + 1;
            else if (ftq_count == (FTQ_IDX_BITS+1)'(1))
                xs_ftq_occ_hist[1] <= xs_ftq_occ_hist[1] + 1;
            else if (ftq_count <= (FTQ_IDX_BITS+1)'(3))
                xs_ftq_occ_hist[2] <= xs_ftq_occ_hist[2] + 1;
            else if (ftq_count <= (FTQ_IDX_BITS+1)'(7))
                xs_ftq_occ_hist[3] <= xs_ftq_occ_hist[3] + 1;
            else if (ftq_count <= (FTQ_IDX_BITS+1)'(15))
                xs_ftq_occ_hist[4] <= xs_ftq_occ_hist[4] + 1;
            else
                xs_ftq_occ_hist[5] <= xs_ftq_occ_hist[5] + 1;

            if (packet_buf_empty)
                xs_packet_buf_empty_cycles <= xs_packet_buf_empty_cycles + 1;
            if (packet_buf_full)
                xs_packet_buf_full_cycles <= xs_packet_buf_full_cycles + 1;
            xs_packet_buf_occ_sum <=
                xs_packet_buf_occ_sum + int'(packet_buf_count);
            if (int'(packet_buf_count) > xs_packet_buf_occ_max)
                xs_packet_buf_occ_max <= int'(packet_buf_count);
            if (packet_buf_count == 4'd0)
                xs_packet_buf_occ_hist[0] <= xs_packet_buf_occ_hist[0] + 1;
            else if (packet_buf_count == 4'd1)
                xs_packet_buf_occ_hist[1] <= xs_packet_buf_occ_hist[1] + 1;
            else if (packet_buf_count <= 4'd3)
                xs_packet_buf_occ_hist[2] <= xs_packet_buf_occ_hist[2] + 1;
            else if (packet_buf_count <= 4'd7)
                xs_packet_buf_occ_hist[3] <= xs_packet_buf_occ_hist[3] + 1;
            else
                xs_packet_buf_occ_hist[4] <= xs_packet_buf_occ_hist[4] + 1;

            if (ftq_enq_valid)
                xs_ftq_alloc_cycles <= xs_ftq_alloc_cycles + 1;
            if (ftq_pop_valid)
                xs_ftq_pop_cycles <= xs_ftq_pop_cycles + 1;
            if (ftq_enq_valid && ftq_pop_valid)
                xs_ftq_alloc_pop_cycles <= xs_ftq_alloc_pop_cycles + 1;
            if (ic_req_valid)
                xs_ic_req_valid_cycles <= xs_ic_req_valid_cycles + 1;
            if (f1_valid && frontend_hold)
                xs_ic_req_stall_frontend_hold_cycles <=
                    xs_ic_req_stall_frontend_hold_cycles + 1;
            if (f1_valid && packet_buf_full)
                xs_ic_req_stall_packet_full_cycles <=
                    xs_ic_req_stall_packet_full_cycles + 1;
            if (f1_valid && ftq_full && ftq_need_alloc_c)
                xs_ic_req_stall_ftq_full_cycles <=
                    xs_ic_req_stall_ftq_full_cycles + 1;
            if (backend_stall)
                xs_backend_stall_cycles <= xs_backend_stall_cycles + 1;
            if (backend_stall && (packet_buf_valid || packet_flowthrough_valid))
                xs_backend_stall_packet_ready_cycles <=
                    xs_backend_stall_packet_ready_cycles + 1;
            if (frontend_hold)
                xs_frontend_hold_cycles <= xs_frontend_hold_cycles + 1;

            if (xs_dup_last_emit_c)
                xs_dup_last_emit_cycles <= xs_dup_last_emit_cycles + 1;
            if (f2_duplicate_suppressed_c) begin : xs_dup_top_update
                int hit_idx;
                int empty_idx;
                int min_idx;
                int use_idx;
                int min_count;

                hit_idx = -1;
                empty_idx = -1;
                min_idx = 0;
                use_idx = -1;
                min_count = xs_dup_top_count[0];
                for (int i = 0; i < XS_CATCHUP_TOPN; i++) begin
                    if ((xs_dup_top_count[i] != 0) &&
                        (xs_dup_top_pc[i] == f2_work_pc_c) &&
                        (hit_idx < 0)) begin
                        hit_idx = i;
                    end
                    if ((xs_dup_top_count[i] == 0) &&
                        (empty_idx < 0)) begin
                        empty_idx = i;
                    end
                    if (xs_dup_top_count[i] < min_count) begin
                        min_count = xs_dup_top_count[i];
                        min_idx = i;
                    end
                end
                if (hit_idx >= 0)
                    use_idx = hit_idx;
                else if (empty_idx >= 0)
                    use_idx = empty_idx;
                else
                    use_idx = min_idx;

                xs_dup_top_pc[use_idx] <= f2_work_pc_c;
                if (hit_idx >= 0)
                    xs_dup_top_count[use_idx] <=
                        xs_dup_top_count[use_idx] + 1;
                else
                    xs_dup_top_count[use_idx] <= 1;
            end
            if (xs_dup_replay_guard_c)
                xs_dup_replay_guard_cycles <= xs_dup_replay_guard_cycles + 1;
            if (xs_dup_last_emit_c && xs_dup_replay_guard_c)
                xs_dup_both_reasons_cycles <= xs_dup_both_reasons_cycles + 1;
            if (xs_f2_owner_no_head_c)
                xs_f2_owner_no_head_cycles <= xs_f2_owner_no_head_cycles + 1;
            if (xs_f2_owner_idx_mismatch_c)
                xs_f2_owner_idx_mismatch_cycles <=
                    xs_f2_owner_idx_mismatch_cycles + 1;
            if (xs_f2_owner_epoch_mismatch_c)
                xs_f2_owner_epoch_mismatch_cycles <=
                    xs_f2_owner_epoch_mismatch_cycles + 1;
            if (xs_f2_owner_tag_mismatch_c)
                xs_f2_owner_tag_mismatch_cycles <=
                    xs_f2_owner_tag_mismatch_cycles + 1;
            if (f2_ftq_owner_live_c)
                xs_f2_owner_live_cycles <= xs_f2_owner_live_cycles + 1;
            if (xs_f2_cursor_wb_no_head_c)
                xs_f2_cursor_wb_no_head_cycles <=
                    xs_f2_cursor_wb_no_head_cycles + 1;
            if (xs_f2_cursor_wb_idx_skew_c)
                xs_f2_cursor_wb_idx_skew_cycles <=
                    xs_f2_cursor_wb_idx_skew_cycles + 1;
            if (xs_f2_cursor_wb_epoch_skew_c)
                xs_f2_cursor_wb_epoch_skew_cycles <=
                    xs_f2_cursor_wb_epoch_skew_cycles + 1;
            if (xs_f2_cursor_wb_tag_skew_c)
                xs_f2_cursor_wb_tag_skew_cycles <=
                    xs_f2_cursor_wb_tag_skew_cycles + 1;
            if (xs_packet_stale_no_head_c)
                xs_packet_stale_no_head_cycles <=
                    xs_packet_stale_no_head_cycles + 1;
            if (xs_packet_stale_idx_mismatch_c)
                xs_packet_stale_idx_mismatch_cycles <=
                    xs_packet_stale_idx_mismatch_cycles + 1;
            if (xs_packet_stale_epoch_mismatch_c)
                xs_packet_stale_epoch_mismatch_cycles <=
                    xs_packet_stale_epoch_mismatch_cycles + 1;
            if (xs_packet_stale_tag_mismatch_c)
                xs_packet_stale_tag_mismatch_cycles <=
                    xs_packet_stale_tag_mismatch_cycles + 1;
            if (packet_flowthrough_candidate)
                xs_flowthrough_candidate_cycles <=
                    xs_flowthrough_candidate_cycles + 1;
            if (packet_flowthrough_candidate && !packet_flowthrough_owner_match_c)
                xs_flowthrough_owner_miss_cycles <=
                    xs_flowthrough_owner_miss_cycles + 1;
            if (xs_flowthrough_incomplete_owner_c)
                xs_flowthrough_incomplete_owner_cycles <=
                    xs_flowthrough_incomplete_owner_cycles + 1;
            if (packet_flowthrough_valid)
                xs_flowthrough_valid_cycles <=
                    xs_flowthrough_valid_cycles + 1;
            if (xs_same_owner_candidate_c)
                xs_same_owner_candidate_cycles <=
                    xs_same_owner_candidate_cycles + 1;
            if (xs_same_owner_emit_candidate_c)
                xs_same_owner_emit_candidate_cycles <=
                    xs_same_owner_emit_candidate_cycles + 1;
            if (ifu_work_same_owner_advance_c)
                xs_same_owner_advanced_cycles <=
                    xs_same_owner_advanced_cycles + 1;
            if (xs_same_owner_block_no_emit_c)
                xs_same_owner_block_no_emit_cycles <=
                    xs_same_owner_block_no_emit_cycles + 1;
            if (xs_same_owner_block_no_enq_c)
                xs_same_owner_block_no_enq_cycles <=
                    xs_same_owner_block_no_enq_cycles + 1;
            if (xs_same_owner_block_owner_not_live_c)
                xs_same_owner_block_owner_not_live_cycles <=
                    xs_same_owner_block_owner_not_live_cycles + 1;
            if (xs_same_owner_block_owner_complete_c)
                xs_same_owner_block_owner_complete_cycles <=
                    xs_same_owner_block_owner_complete_cycles + 1;
            if (xs_same_owner_block_pred_ctl_c)
                xs_same_owner_block_pred_ctl_cycles <=
                    xs_same_owner_block_pred_ctl_cycles + 1;
            if (xs_same_owner_block_remainder_c)
                xs_same_owner_block_remainder_cycles <=
                    xs_same_owner_block_remainder_cycles + 1;
            if (xs_same_owner_block_crossline_c)
                xs_same_owner_block_crossline_cycles <=
                    xs_same_owner_block_crossline_cycles + 1;
            if (xs_same_owner_block_other_c)
                xs_same_owner_block_other_cycles <=
                    xs_same_owner_block_other_cycles + 1;
            if (ifu_runahead_req_valid_c)
                xs_runahead_req_valid_cycles <=
                    xs_runahead_req_valid_cycles + 1;
            if (ifu_runahead_req_fire_c)
                xs_runahead_req_fire_cycles <=
                    xs_runahead_req_fire_cycles + 1;
            if (ifu_runahead_cancel_next_c)
                xs_runahead_cancel_next_cycles <=
                    xs_runahead_cancel_next_cycles + 1;
            if (ifu_runahead_pending_c)
                xs_runahead_pending_cycles <=
                    xs_runahead_pending_cycles + 1;
            if (ifu_runahead_redirect_match_c)
                xs_runahead_redirect_match_cycles <=
                    xs_runahead_redirect_match_cycles + 1;
            if (ifu_runahead_duplicate_alloc_blocked_c)
                xs_runahead_duplicate_alloc_blocked_cycles <=
                    xs_runahead_duplicate_alloc_blocked_cycles + 1;
            if (ifu_runahead_depth_gt1_c ||
                (({1'b0, ftq_count_alloc_to_ifu} +
                  {1'b0, ftq_count_ifu_to_wb}) >
                 (FTQ_IDX_BITS+2)'(2)))
                xs_ftq_depth_gt1_cycles <=
                    xs_ftq_depth_gt1_cycles + 1;
            if (xs_icq_future_head_block_c)
                xs_icq_future_head_block_cycles <=
                    xs_icq_future_head_block_cycles + 1;

            if (xs_catchup_base_c)
                xs_catchup_base_cycles <= xs_catchup_base_cycles + 1;
            if (xs_catchup_fetch0_c)
                xs_catchup_fetch0_cycles <= xs_catchup_fetch0_cycles + 1;
            if (xs_catchup_crossline_c)
                xs_catchup_crossline_cycles <=
                    xs_catchup_crossline_cycles + 1;
            if (xs_catchup_nlpb_c)
                xs_catchup_nlpb_cycles <= xs_catchup_nlpb_cycles + 1;
            if (xs_catchup_aux_taken_c)
                xs_catchup_aux_taken_cycles <=
                    xs_catchup_aux_taken_cycles + 1;
            if (xs_catchup_recoverable_c) begin
                xs_catchup_recoverable_cycles <=
                    xs_catchup_recoverable_cycles + 1;
                if (f1_aux_pred_ctl_type_c == BT_RET)
                    xs_catchup_ret_cycles <= xs_catchup_ret_cycles + 1;
                begin : xs_catchup_top_update
                    int hit_idx;
                    int empty_idx;
                    int min_idx;
                    int use_idx;
                    int min_count;

                    hit_idx = -1;
                    empty_idx = -1;
                    min_idx = 0;
                    use_idx = -1;
                    min_count = xs_catchup_top_count[0];
                    for (int i = 0; i < XS_CATCHUP_TOPN; i++) begin
                        if ((xs_catchup_top_count[i] != 0) &&
                            (xs_catchup_top_pc[i] == f1_pc) &&
                            (hit_idx < 0)) begin
                            hit_idx = i;
                        end
                        if ((xs_catchup_top_count[i] == 0) &&
                            (empty_idx < 0)) begin
                            empty_idx = i;
                        end
                        if (xs_catchup_top_count[i] < min_count) begin
                            min_count = xs_catchup_top_count[i];
                            min_idx = i;
                        end
                    end
                    if (hit_idx >= 0)
                        use_idx = hit_idx;
                    else if (empty_idx >= 0)
                        use_idx = empty_idx;
                    else
                        use_idx = min_idx;

                    xs_catchup_top_pc[use_idx] <= f1_pc;
                    if (hit_idx >= 0)
                        xs_catchup_top_count[use_idx] <=
                            xs_catchup_top_count[use_idx] + 1;
                    else
                        xs_catchup_top_count[use_idx] <= 1;
                end
            end
            if (xs_catchup_target_last_c) begin
                xs_catchup_target_last_cycles <=
                    xs_catchup_target_last_cycles + 1;
            end
            if (packet_buf_stale_owner_c)
                xs_packet_buf_stale_owner_cycles <=
                    xs_packet_buf_stale_owner_cycles + 1;

            if (xs_catchup_trace_en && xs_catchup_base_c) begin
                $display("[XS_CATCHUP] pc=%016h f2_pc=%016h last_next=%016h fetch0=%b cross=%b nlpb=%b aux_v=%b aux_t=%b aux_type=%0d aux_tgt=%016h target_last=%b",
                         f1_pc,
                         f2_work_pc_c,
                         f2_last_emit_next_pc_r,
                         xs_catchup_fetch0_c,
                         xs_catchup_crossline_c,
                         nlpb_aux_hit_comb,
                         f1_aux_pred_ctl_valid_c,
                         f1_aux_pred_ctl_taken_c,
                         f1_aux_pred_ctl_type_c,
                         f1_aux_pred_ctl_target_c,
                         xs_catchup_target_last_c);
            end
        end
    end

    final begin
        if (xs_catchup_probe_en) begin
            $display("");
            $display("=== XS NLPB CATCH-UP PROBE ===");
            $display("base duplicate cycles       : %0d",
                     xs_catchup_base_cycles);
            $display("base with fetch_out=0       : %0d",
                     xs_catchup_fetch0_cycles);
            $display("base cross-line             : %0d",
                     xs_catchup_crossline_cycles);
            $display("base with NLPB aux hit      : %0d",
                     xs_catchup_nlpb_cycles);
            $display("base with aux taken predict : %0d",
                     xs_catchup_aux_taken_cycles);
            $display("recoverable cross-line      : %0d",
                     xs_catchup_recoverable_cycles);
            $display("recoverable target=last pc  : %0d",
                     xs_catchup_target_last_cycles);
            $display("recoverable RET cycles      : %0d",
                     xs_catchup_ret_cycles);
            $display("xs packet-buffer stale owner: %0d",
                     xs_packet_buf_stale_owner_cycles);
            $display("xs ftq empty cycles         : %0d",
                     xs_ftq_empty_cycles);
            $display("xs ftq full cycles          : %0d",
                     xs_ftq_full_cycles);
            $display("xs ftq occ sum              : %0d",
                     xs_ftq_occ_sum);
            $display("xs ftq occ max              : %0d",
                     xs_ftq_occ_max);
            $display("xs ftq occ hist 0           : %0d",
                     xs_ftq_occ_hist[0]);
            $display("xs ftq occ hist 1           : %0d",
                     xs_ftq_occ_hist[1]);
            $display("xs ftq occ hist 2to3        : %0d",
                     xs_ftq_occ_hist[2]);
            $display("xs ftq occ hist 4to7        : %0d",
                     xs_ftq_occ_hist[3]);
            $display("xs ftq occ hist 8to15       : %0d",
                     xs_ftq_occ_hist[4]);
            $display("xs ftq occ hist 16plus      : %0d",
                     xs_ftq_occ_hist[5]);
            $display("xs runahead req valid       : %0d",
                     xs_runahead_req_valid_cycles);
            $display("xs runahead req fire        : %0d",
                     xs_runahead_req_fire_cycles);
            $display("xs runahead cancel next     : %0d",
                     xs_runahead_cancel_next_cycles);
            $display("xs runahead pending cycles  : %0d",
                     xs_runahead_pending_cycles);
            $display("xs runahead redirect match  : %0d",
                     xs_runahead_redirect_match_cycles);
            $display("xs runahead dup alloc block : %0d",
                     xs_runahead_duplicate_alloc_blocked_cycles);
            $display("xs ftq depth gt1 cycles     : %0d",
                     xs_ftq_depth_gt1_cycles);
            $display("xs icq future head block    : %0d",
                     xs_icq_future_head_block_cycles);
            $display("xs packet buf empty cycles  : %0d",
                     xs_packet_buf_empty_cycles);
            $display("xs packet buf full cycles   : %0d",
                     xs_packet_buf_full_cycles);
            $display("xs packet buf occ sum       : %0d",
                     xs_packet_buf_occ_sum);
            $display("xs packet buf occ max       : %0d",
                     xs_packet_buf_occ_max);
            $display("xs packet buf occ hist 0    : %0d",
                     xs_packet_buf_occ_hist[0]);
            $display("xs packet buf occ hist 1    : %0d",
                     xs_packet_buf_occ_hist[1]);
            $display("xs packet buf occ hist 2to3 : %0d",
                     xs_packet_buf_occ_hist[2]);
            $display("xs packet buf occ hist 4to7 : %0d",
                     xs_packet_buf_occ_hist[3]);
            $display("xs packet buf occ hist 8    : %0d",
                     xs_packet_buf_occ_hist[4]);
            $display("xs ftq alloc cycles         : %0d",
                     xs_ftq_alloc_cycles);
            $display("xs ftq pop cycles           : %0d",
                     xs_ftq_pop_cycles);
            $display("xs ftq alloc pop cycles     : %0d",
                     xs_ftq_alloc_pop_cycles);
            $display("xs ic req valid cycles      : %0d",
                     xs_ic_req_valid_cycles);
            $display("xs ic stall frontend hold   : %0d",
                     xs_ic_req_stall_frontend_hold_cycles);
            $display("xs ic stall packet full     : %0d",
                     xs_ic_req_stall_packet_full_cycles);
            $display("xs ic stall ftq full        : %0d",
                     xs_ic_req_stall_ftq_full_cycles);
            $display("xs backend stall cycles     : %0d",
                     xs_backend_stall_cycles);
            $display("xs backend stall pkt ready  : %0d",
                     xs_backend_stall_packet_ready_cycles);
            $display("xs frontend hold cycles     : %0d",
                     xs_frontend_hold_cycles);
            $display("xs dup last emit            : %0d",
                     xs_dup_last_emit_cycles);
            $display("xs dup replay guard         : %0d",
                     xs_dup_replay_guard_cycles);
            $display("xs dup both reasons         : %0d",
                     xs_dup_both_reasons_cycles);
            $display("xs f2 owner live            : %0d",
                     xs_f2_owner_live_cycles);
            $display("xs f2 owner no head         : %0d",
                     xs_f2_owner_no_head_cycles);
            $display("xs f2 owner idx mismatch    : %0d",
                     xs_f2_owner_idx_mismatch_cycles);
            $display("xs f2 owner epoch mismatch  : %0d",
                     xs_f2_owner_epoch_mismatch_cycles);
            $display("xs f2 owner tag mismatch    : %0d",
                     xs_f2_owner_tag_mismatch_cycles);
            $display("xs f2 cursor wb no head     : %0d",
                     xs_f2_cursor_wb_no_head_cycles);
            $display("xs f2 cursor wb idx skew    : %0d",
                     xs_f2_cursor_wb_idx_skew_cycles);
            $display("xs f2 cursor wb epoch skew  : %0d",
                     xs_f2_cursor_wb_epoch_skew_cycles);
            $display("xs f2 cursor wb tag skew    : %0d",
                     xs_f2_cursor_wb_tag_skew_cycles);
            $display("xs packet stale no head     : %0d",
                     xs_packet_stale_no_head_cycles);
            $display("xs packet stale idx mismatch: %0d",
                     xs_packet_stale_idx_mismatch_cycles);
            $display("xs packet stale epoch mismatch: %0d",
                     xs_packet_stale_epoch_mismatch_cycles);
            $display("xs packet stale tag mismatch: %0d",
                     xs_packet_stale_tag_mismatch_cycles);
            $display("xs flowthrough candidate    : %0d",
                     xs_flowthrough_candidate_cycles);
            $display("xs flowthrough owner miss   : %0d",
                     xs_flowthrough_owner_miss_cycles);
            $display("xs flowthrough incomplete owner: %0d",
                     xs_flowthrough_incomplete_owner_cycles);
            $display("xs flowthrough valid        : %0d",
                     xs_flowthrough_valid_cycles);
            $display("xs same owner candidate     : %0d",
                     xs_same_owner_candidate_cycles);
            $display("xs same owner emit cand     : %0d",
                     xs_same_owner_emit_candidate_cycles);
            $display("xs same owner advanced      : %0d",
                     xs_same_owner_advanced_cycles);
            $display("xs same owner block no emit : %0d",
                     xs_same_owner_block_no_emit_cycles);
            $display("xs same owner block no enq  : %0d",
                     xs_same_owner_block_no_enq_cycles);
            $display("xs same owner block no owner: %0d",
                     xs_same_owner_block_owner_not_live_cycles);
            $display("xs same owner block complete: %0d",
                     xs_same_owner_block_owner_complete_cycles);
            $display("xs same owner block pred ctl: %0d",
                     xs_same_owner_block_pred_ctl_cycles);
            $display("xs same owner block rem     : %0d",
                     xs_same_owner_block_remainder_cycles);
            $display("xs same owner block crossln : %0d",
                     xs_same_owner_block_crossline_cycles);
            $display("xs same owner block other   : %0d",
                     xs_same_owner_block_other_cycles);
            $display("recoverable top F1 PCs:");
            for (int i = 0; i < XS_CATCHUP_TOPN; i++) begin
                if (xs_catchup_top_count[i] != 0) begin
                    $display("  %016h %0d",
                             xs_catchup_top_pc[i],
                             xs_catchup_top_count[i]);
                end
            end
            $display("duplicate-suppressed top F2 PCs:");
            for (int i = 0; i < XS_CATCHUP_TOPN; i++) begin
                if (xs_dup_top_count[i] != 0) begin
                    $display("  %016h %0d",
                             xs_dup_top_pc[i],
                             xs_dup_top_count[i]);
                end
            end
        end
    end

endmodule

bind fetch_top fetch_frontend_profiler u_fetch_frontend_profiler (
    .clk                             (clk),
    .rst_n                           (rst_n),
    .f2_duplicate_suppressed_c       (f2_duplicate_suppressed_c),
    .f2_last_emit_hit_c              (f2_last_emit_hit_c),
    .f1_valid                        (f1_valid),
    .f1_pc                           (f1_pc),
    .f2_last_emit_next_pc_r          (f2_last_emit_next_pc_r),
    .packet_buf_empty                (packet_buf_empty),
    .redirect_valid                  (redirect_valid),
    .backend_stall                   (backend_stall),
    .frontend_hold                   (frontend_hold),
    .fe_stall                        (fe_stall),
    .fetch_count                     (fetch_count),
    .f2_work_pc_c                    (f2_work_pc_c),
    .nlpb_aux_hit_comb               (nlpb_aux_hit_comb),
    .f1_aux_pred_ctl_valid_c         (f1_aux_pred_ctl_valid_c),
    .f1_aux_pred_ctl_taken_c         (f1_aux_pred_ctl_taken_c),
    .f1_aux_pred_ctl_type_c          (f1_aux_pred_ctl_type_c),
    .f1_aux_pred_ctl_target_c        (f1_aux_pred_ctl_target_c),
    .f2_last_emit_valid_r            (f2_last_emit_valid_r),
    .f2_last_emit_pc_r               (f2_last_emit_pc_r),
    .f2_replay_block_hit_c           (f2_replay_block_hit_c),
    .f2_work_ftq_valid_c             (f2_work_ftq_valid_c),
    .f2_work_ftq_idx_c               (f2_work_ftq_idx_c),
    .f2_work_ftq_epoch_c             (f2_work_ftq_epoch_c),
    .f2_work_ftq_alloc_tag_c         (f2_work_ftq_alloc_tag_c),
    .ftq_ifu_wb_owner_valid          (ftq_ifu_wb_owner_valid),
    .ftq_ifu_wb_owner_idx            (ftq_ifu_wb_owner_idx),
    .ftq_ifu_wb_owner_tag            (ftq_ifu_wb_owner_tag),
    .ftq_current_epoch               (ftq_current_epoch),
    .f2_owner_completion_candidate_c (f2_owner_completion_candidate_c),
    .packet_buf_valid                (packet_buf_valid),
    .packet_buf_head                 (packet_buf_head),
    .ftq_commit_owner_valid          (ftq_commit_owner_valid),
    .ftq_commit_owner_idx            (ftq_commit_owner_idx),
    .ftq_commit_owner_tag            (ftq_commit_owner_tag),
    .packet_flowthrough_owner_match_c(packet_flowthrough_owner_match_c),
    .f2_work_owner_complete_c        (f2_work_owner_complete_c),
    .ftq_empty                       (ftq_empty),
    .ftq_full                        (ftq_full),
    .ftq_count                       (ftq_count),
    .packet_buf_full                 (packet_buf_full),
    .packet_buf_count                (packet_buf_count),
    .ftq_enq_valid                   (ftq_enq_valid),
    .ftq_pop_valid                   (ftq_ifu_pop_valid),
    .ic_req_valid                    (ic_req_valid),
    .ftq_need_alloc_c                (ftq_need_alloc_c),
    .f2_ftq_owner_live_c             (f2_ftq_owner_live_c),
    .f2_same_owner_continue_c        (f2_same_owner_continue_c),
    .f2_seq_valid                    (f2_seq_valid),
    .f2_seq_next_pc                  (f2_seq_next_pc),
    .f2_will_emit_c                  (f2_will_emit_c),
    .packet_buf_enq                  (packet_buf_enq),
    .line_straddle_advance_c         (line_straddle_advance_c),
    .consume_remainder_c             (consume_remainder_c),
    .consumed_remainder_r            (consumed_remainder_r),
    .f2_work_ftq_entry_c             (f2_work_ftq_entry_c),
    .f2_work_line_addr_c             (f2_work_line_addr_c),
    .ifu_work_same_owner_advance_c   (ifu_work_same_owner_advance_c),
    .packet_flowthrough_candidate    (packet_flowthrough_candidate),
    .packet_flowthrough_valid        (packet_flowthrough_valid),
    .packet_buf_stale_owner_c        (packet_buf_stale_owner_c),
    .ftq_count_alloc_to_ifu          (ftq_count_alloc_to_ifu),
    .ftq_count_ifu_to_wb             (ftq_count_ifu_to_wb),
    .icq_deq_valid                   (icq_deq_valid),
    .icq_deq_line_addr               (icq_deq_line_addr),
    .f2_work_line_valid_c            (f2_work_line_valid_c),
    .ifu_runahead_req_valid_c        (ifu_runahead_req_valid_c),
    .ifu_runahead_req_fire_c         (ifu_runahead_req_fire_c),
    .ifu_runahead_cancel_next_c      (ifu_runahead_cancel_next_c),
    .ifu_runahead_pending_c          (ifu_runahead_pending_c),
    .ifu_runahead_redirect_match_c   (ifu_runahead_redirect_match_c),
    .ifu_runahead_duplicate_alloc_blocked_c(ifu_runahead_duplicate_alloc_blocked_c),
    .ifu_runahead_depth_gt1_c        (ifu_runahead_depth_gt1_c)
);
`endif

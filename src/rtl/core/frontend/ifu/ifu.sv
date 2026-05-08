/* file: ifu.sv
 Description: IFU work cursor and fetch-owner handoff policy.
 Author: Jeremy Cai
 Date: May 06, 2026
 Version: 1.0
*/
module ifu
    import rv64gc_pkg::*;
    import uarch_pkg::*;
(
    input  logic                          clk,
    input  logic                          rst_n,
    input  logic                          redirect_i,
    input  logic [63:0]                   redirect_pc_i,

    input  logic                          frontend_hold_i,
    input  logic                          packet_buf_full_i,
    input  logic                          icq_full_i,
    input  logic                          ftq_enq_ready_i,
    input  logic                          remainder_valid_i,
    input  logic                          same_owner_continue_i,
    input  logic                          req_redirect_i,
    input  logic                          duplicate_suppressed_i,
    input  logic [63:0]                   duplicate_next_pc_i,
    input  logic                          pc_consumed_i,
    input  logic                          will_emit_i,

    input  logic [FTQ_IDX_BITS-1:0]       req_owner_idx_i,
    input  logic [FTQ_EPOCH_BITS-1:0]     req_owner_epoch_i,
    input  logic [FTQ_ALLOC_TAG_BITS-1:0] req_owner_tag_i,
    input  ftq_entry_t                    req_owner_entry_i,

    input  logic                          bpu_redirect_i,
    input  logic [63:0]                   bpu_target_i,

    input  logic                          ftq_next_owner_valid_i,
    input  logic [FTQ_IDX_BITS-1:0]       ftq_next_owner_idx_i,
    input  logic [FTQ_ALLOC_TAG_BITS-1:0] ftq_next_owner_tag_i,
    input  ftq_entry_t                    ftq_next_owner_entry_i,
    input  logic                          ftq_wb_owner_valid_i,
    input  logic [FTQ_IDX_BITS-1:0]       ftq_wb_owner_idx_i,
    input  logic [FTQ_ALLOC_TAG_BITS-1:0] ftq_wb_owner_tag_i,
    input  logic [FTQ_EPOCH_BITS-1:0]     ftq_current_epoch_i,
    input  logic [FTQ_IDX_BITS:0]         ftq_count_ifu_to_wb_i,
    input  logic [FTQ_IDX_BITS:0]         ftq_count_alloc_to_ifu_i,

    input  logic                          seq_valid_i,
    input  logic [63:0]                   seq_next_pc_i,
    input  logic                          successor_req_valid_i,
    input  logic [63:0]                   successor_req_pc_i,
    input  logic                          line_straddle_advance_i,
    input  logic                          consume_remainder_i,
    input  logic                          owner_complete_i,
    input  logic                          packet_valid_i,
    input  logic                          packet_enq_i,

    output logic                          f1_valid_o,
    output logic [63:0]                   f1_pc_o,
    output logic [63:0]                   req_pc_o,
    output logic [63:0]                   req_block_pc_o,
    output logic                          ftq_need_alloc_o,
    output logic                          ifu_req_valid_o,
    output logic                          ifu_req_ready_o,
    output logic                          ifu_req_fire_o,
    output logic                          ftq_enq_valid_o,
    output logic                          ftq_ifu_req_pop_valid_o,
    output logic                          ftq_delivery_push_valid_o,
    output logic                          ftq_ifu_pop_valid_o,
    output logic                          ic_req_valid_o,
    output logic [63:0]                   ic_req_addr_o,
    output logic                          fe_stall_o,
    output logic                          consumed_remainder_o,
    output logic                          owner_live_o,
    output logic                          redirect_without_owner_successor_o,
    output logic                          owner_completion_candidate_o,
    output logic                          owner_delivery_push_o,

    output logic                          work_valid_o,
    output logic [63:0]                   work_pc_o,
    output logic                          work_ftq_valid_o,
    output logic [FTQ_IDX_BITS-1:0]       work_ftq_idx_o,
    output logic [FTQ_EPOCH_BITS-1:0]     work_ftq_epoch_o,
    output logic [FTQ_ALLOC_TAG_BITS-1:0] work_ftq_alloc_tag_o,
    output ftq_entry_t                    work_ftq_entry_o,
    output logic                          work_line_valid_o,
    output logic [63:LINE_BITS]           work_line_addr_o,
    output logic                          work_owner_delivered_o,

    output logic                          work_redirect_o,
    output logic                          work_redirect_next_owner_match_o,
    output logic                          work_redirect_enq_owner_o,
    output logic                          work_redirect_keep_owner_o,
    output logic                          work_take_ftq_next_owner_o,
    output logic                          work_take_request_owner_o,
    output logic                          work_take_remainder_request_owner_o,
    output logic                          work_same_owner_advance_o,

    output logic                          runahead_req_valid_o,
    output logic                          runahead_req_fire_o,
    output logic                          runahead_cancel_next_o,
    output logic                          runahead_pending_o,
    output logic [63:0]                   runahead_pending_pc_o,
    output logic [FTQ_IDX_BITS-1:0]       runahead_pending_idx_o,
    output logic [FTQ_EPOCH_BITS-1:0]     runahead_pending_epoch_o,
    output logic [FTQ_ALLOC_TAG_BITS-1:0] runahead_pending_tag_o,
    output logic                          runahead_redirect_match_o,
    output logic                          runahead_duplicate_alloc_blocked_o,
    output logic                          runahead_depth_gt1_o
);

    localparam int MAX_DEMAND_RUNAHEAD = 1;

    localparam logic [2:0] BT_JALR = 3'd2;
    localparam logic [2:0] BT_RET  = 3'd4;

    typedef struct packed {
        logic                          valid;
        logic [63:0]                   pc;
        logic                          ftq_valid;
        logic [FTQ_IDX_BITS-1:0]       ftq_idx;
        logic [FTQ_EPOCH_BITS-1:0]     ftq_epoch;
        logic [FTQ_ALLOC_TAG_BITS-1:0] ftq_alloc_tag;
        ftq_entry_t                    ftq_entry;
        logic                          line_valid;
        logic [63:LINE_BITS]           line_addr;
        logic                          owner_delivered;
    } ifu_work_item_t;

    ifu_work_item_t work_r;
    ifu_work_item_t work_next_c;
    logic [63:0] f1_pc_r;
    logic        f1_valid_r;
    logic        last_alloc_valid_r;
    logic [63:0] last_alloc_req_pc_r;
    logic        consumed_remainder_r;
    logic [63:0] post_remainder_pc_r;
    logic [63:0] next_pc_c;
    logic        next_valid_c;
    logic [63:0] normal_req_pc_c;
    logic [63:0] runahead_req_pc_c;
    logic [63:0] req_pc_c;
    logic [63:0] req_block_pc_c;
    logic        required_ftq_need_alloc_c;
    logic        ftq_need_alloc_c;
    logic        ftq_enq_valid_c;
    logic        ifu_req_ready_c;
    logic        ifu_req_fire_c;
    logic        fe_stall_c;
    logic        owner_live_c;
    logic        owner_live_registered_c;
    logic        redirect_without_owner_successor_c;
    logic        owner_completion_candidate_c;
    logic        owner_delivery_push_c;
    logic        ftq_ifu_pop_valid_c;
    logic        work_same_owner_emit_advance_c;
    logic        work_same_owner_dup_advance_c;
    logic        work_same_owner_advance_c;
    logic        work_same_owner_event_c;
    logic        work_undelivered_owner_hold_c;
    logic        pred_control_outside_next_packet_c;
    logic        same_owner_next_owner_safe_c;
    logic        ftq_next_owner_stable_c;
    logic [63:0] ftq_next_owner_start_pc_c;
    logic        redirect_next_owner_match_c;
    logic [FTQ_IDX_BITS+1:0] frontend_owner_depth_c;
    logic        runahead_pending_r;
    logic [63:0] runahead_pending_pc_r;
    logic [FTQ_IDX_BITS-1:0] runahead_pending_idx_r;
    logic [FTQ_EPOCH_BITS-1:0] runahead_pending_epoch_r;
    logic [FTQ_ALLOC_TAG_BITS-1:0] runahead_pending_tag_r;
    logic        runahead_budget_avail_c;
    logic        runahead_target_valid_c;
    logic        runahead_target_direct_c;
    logic        runahead_target_before_ctl_c;
    logic        runahead_next_owner_match_c;
    logic        successor_next_owner_match_c;
    logic        successor_req_allowed_c;
    logic        runahead_candidate_c;
    logic        selected_req_is_runahead_c;
    logic        runahead_cancel_next_c;
    logic        runahead_pending_match_next_c;
    logic        runahead_pending_target_match_c;
    logic        runahead_pending_clear_c;

    assign f1_valid_o              = f1_valid_r;
    assign f1_pc_o                 = f1_pc_r;
    assign req_pc_o                = req_pc_c;
    assign req_block_pc_o          = req_block_pc_c;
    assign ftq_need_alloc_o        = ftq_need_alloc_c;
    assign ifu_req_valid_o         = ftq_enq_valid_c;
    assign ifu_req_ready_o         = ifu_req_ready_c;
    assign ifu_req_fire_o          = ifu_req_fire_c;
    assign ftq_enq_valid_o         = ftq_enq_valid_c;
    assign ftq_ifu_req_pop_valid_o = ifu_req_fire_c;
    assign ftq_delivery_push_valid_o = owner_delivery_push_c;
    assign ftq_ifu_pop_valid_o     = ftq_ifu_pop_valid_c;
    assign ic_req_valid_o          = f1_valid_r && !fe_stall_c;
    assign ic_req_addr_o           = req_pc_c;
    assign fe_stall_o              = fe_stall_c;
    assign consumed_remainder_o    = consumed_remainder_r;
    assign owner_live_o            = owner_live_c;
    assign redirect_without_owner_successor_o =
        redirect_without_owner_successor_c;
    assign owner_completion_candidate_o = owner_completion_candidate_c;
    assign owner_delivery_push_o        = owner_delivery_push_c;
    assign work_same_owner_advance_o    = work_same_owner_event_c;
    assign runahead_req_valid_o =
        selected_req_is_runahead_c && f1_valid_r && !fe_stall_c;
    assign runahead_req_fire_o =
        ifu_req_fire_c && selected_req_is_runahead_c;
    assign runahead_cancel_next_o = runahead_cancel_next_c;
    assign runahead_pending_o       = runahead_pending_r;
    assign runahead_pending_pc_o    = runahead_pending_pc_r;
    assign runahead_pending_idx_o   = runahead_pending_idx_r;
    assign runahead_pending_epoch_o = runahead_pending_epoch_r;
    assign runahead_pending_tag_o   = runahead_pending_tag_r;
    assign runahead_redirect_match_o =
        work_redirect_o &&
        runahead_pending_target_match_c;
    assign runahead_duplicate_alloc_blocked_o =
        work_redirect_o &&
        req_redirect_i &&
        redirect_next_owner_match_c &&
        runahead_pending_target_match_c;
    assign runahead_depth_gt1_o =
        frontend_owner_depth_c >
        (FTQ_IDX_BITS+2)'(MAX_DEMAND_RUNAHEAD + 1);

    assign work_valid_o         = work_r.valid;
    assign work_pc_o            = work_r.pc;
    assign work_ftq_valid_o     = work_r.ftq_valid;
    assign work_ftq_idx_o       = work_r.ftq_idx;
    assign work_ftq_epoch_o     = work_r.ftq_epoch;
    assign work_ftq_alloc_tag_o = work_r.ftq_alloc_tag;
    assign work_ftq_entry_o     = work_r.ftq_entry;
    assign work_line_valid_o    = work_r.line_valid;
    assign work_line_addr_o     = work_r.line_addr;
    assign work_owner_delivered_o = work_r.owner_delivered;

    assign normal_req_pc_c = (req_redirect_i && !redirect_i)
                             ? bpu_target_i
                             : (line_straddle_advance_i
                                   ? seq_next_pc_i
                                   : (successor_req_allowed_c
                                         ? successor_req_pc_i
                                         : f1_pc_r));
    assign runahead_req_pc_c = work_r.ftq_entry.pred_ctl_target;
    assign req_pc_c = selected_req_is_runahead_c
                      ? runahead_req_pc_c
                      : normal_req_pc_c;
    assign req_block_pc_c = {req_pc_c[63:LINE_BITS], {LINE_BITS{1'b0}}};
    assign ftq_next_owner_stable_c =
        ftq_count_ifu_to_wb_i > {{FTQ_IDX_BITS{1'b0}}, 1'b1};
    assign ftq_next_owner_start_pc_c =
        ftq_next_owner_entry_i.block_pc +
        64'(ftq_next_owner_entry_i.start_offset);
    assign redirect_next_owner_match_c =
        ftq_next_owner_stable_c &&
        ftq_next_owner_valid_i &&
        (ftq_next_owner_entry_i.block_pc ==
         {bpu_target_i[63:LINE_BITS], {LINE_BITS{1'b0}}}) &&
        (ftq_next_owner_entry_i.start_offset == bpu_target_i[5:0]);
    assign required_ftq_need_alloc_c =
        !redirect_i &&
        f1_valid_r &&
        !remainder_valid_i &&
        !line_straddle_advance_i &&
        !same_owner_continue_i &&
        !(req_redirect_i && redirect_next_owner_match_c) &&
        (req_redirect_i ||
         successor_req_allowed_c ||
         !(work_r.valid && (normal_req_pc_c == work_r.pc))) &&
        (req_redirect_i || !last_alloc_valid_r ||
         (normal_req_pc_c != last_alloc_req_pc_r));
    assign frontend_owner_depth_c =
        {1'b0, ftq_count_alloc_to_ifu_i} +
        {1'b0, ftq_count_ifu_to_wb_i};
    assign runahead_budget_avail_c =
        frontend_owner_depth_c <
        (FTQ_IDX_BITS+2)'(MAX_DEMAND_RUNAHEAD + 1);
    assign runahead_target_valid_c =
        work_r.ftq_entry.pred_ctl_valid &&
        work_r.ftq_entry.pred_ctl_taken &&
        (work_r.ftq_entry.pred_ctl_target != 64'd0) &&
        (work_r.ftq_entry.pred_ctl_target != work_r.pc);
    assign runahead_target_direct_c =
        (work_r.ftq_entry.pred_ctl_type != BT_JALR) &&
        (work_r.ftq_entry.pred_ctl_type != BT_RET);
    assign runahead_target_before_ctl_c =
        (work_r.pc[63:LINE_BITS] ==
         work_r.ftq_entry.block_pc[63:LINE_BITS]) &&
        ({1'b0, work_r.pc[5:0]} <=
         {1'b0, work_r.ftq_entry.pred_ctl_offset});
    assign runahead_next_owner_match_c =
        ftq_next_owner_stable_c &&
        ftq_next_owner_valid_i &&
        (ftq_next_owner_entry_i.block_pc ==
         {runahead_req_pc_c[63:LINE_BITS], {LINE_BITS{1'b0}}}) &&
        (ftq_next_owner_entry_i.start_offset == runahead_req_pc_c[5:0]);
    assign successor_next_owner_match_c =
        ftq_next_owner_stable_c &&
        ftq_next_owner_valid_i &&
        (ftq_next_owner_entry_i.block_pc ==
         {successor_req_pc_i[63:LINE_BITS], {LINE_BITS{1'b0}}}) &&
        (ftq_next_owner_entry_i.start_offset == successor_req_pc_i[5:0]);
    assign successor_req_allowed_c =
        successor_req_valid_i &&
        runahead_budget_avail_c &&
        !runahead_pending_r &&
        !successor_next_owner_match_c;
    assign runahead_candidate_c =
        !required_ftq_need_alloc_c &&
        !redirect_i &&
        !req_redirect_i &&
        f1_valid_r &&
        !frontend_hold_i &&
        !packet_buf_full_i &&
        !icq_full_i &&
        ftq_enq_ready_i &&
        !remainder_valid_i &&
        !line_straddle_advance_i &&
        !consume_remainder_i &&
        !consumed_remainder_r &&
        work_r.valid &&
        work_r.ftq_valid &&
        work_r.owner_delivered &&
        owner_live_registered_c &&
        !owner_complete_i &&
        runahead_target_valid_c &&
        runahead_target_direct_c &&
        runahead_target_before_ctl_c &&
        runahead_budget_avail_c &&
        !runahead_pending_r &&
        !runahead_next_owner_match_c;
    assign selected_req_is_runahead_c = runahead_candidate_c;
    assign ftq_need_alloc_c =
        required_ftq_need_alloc_c ||
        selected_req_is_runahead_c;
    assign fe_stall_c = frontend_hold_i ||
                        packet_buf_full_i ||
                        icq_full_i ||
                        (required_ftq_need_alloc_c && !ftq_enq_ready_i);
    assign ftq_enq_valid_c = f1_valid_r && !fe_stall_c && ftq_need_alloc_c;
    assign ifu_req_ready_c = ftq_enq_ready_i && !icq_full_i && !packet_buf_full_i;
    assign ifu_req_fire_c = ftq_enq_valid_c && ifu_req_ready_c;
    assign redirect_without_owner_successor_c =
        req_redirect_i &&
        !ftq_enq_valid_c &&
        (ftq_count_ifu_to_wb_i <= {{FTQ_IDX_BITS{1'b0}}, 1'b1});
    assign owner_completion_candidate_c =
        will_emit_i &&
        packet_valid_i &&
        owner_complete_i &&
        work_r.ftq_valid &&
        !redirect_i &&
        !frontend_hold_i;
    assign owner_delivery_push_c =
        packet_enq_i &&
        work_r.ftq_valid &&
        owner_live_c &&
        !work_r.owner_delivered &&
        !redirect_i &&
        !frontend_hold_i;
    assign ftq_ifu_pop_valid_c =
        owner_completion_candidate_c &&
        owner_live_c;
    assign pred_control_outside_next_packet_c =
        !work_r.ftq_entry.pred_ctl_valid ||
        ({1'b0, seq_next_pc_i[5:0]} <=
         {1'b0, work_r.ftq_entry.pred_ctl_offset});
    assign same_owner_next_owner_safe_c =
        (!ftq_next_owner_stable_c ||
         !ftq_next_owner_valid_i ||
         (seq_next_pc_i < ftq_next_owner_start_pc_c));
    assign work_same_owner_emit_advance_c =
        same_owner_continue_i &&
        seq_valid_i &&
        will_emit_i &&
        packet_enq_i &&
        owner_live_c &&
        work_r.ftq_valid &&
        !owner_complete_i &&
        pred_control_outside_next_packet_c &&
        same_owner_next_owner_safe_c &&
        !line_straddle_advance_i &&
        !consume_remainder_i &&
        !consumed_remainder_r &&
        (seq_next_pc_i[63:LINE_BITS] == work_r.line_addr);
    assign work_same_owner_dup_advance_c =
        same_owner_continue_i &&
        seq_valid_i &&
        duplicate_suppressed_i &&
        owner_live_c &&
        work_r.ftq_valid &&
        !owner_complete_i &&
        pred_control_outside_next_packet_c &&
        same_owner_next_owner_safe_c &&
        !line_straddle_advance_i &&
        !consume_remainder_i &&
        !consumed_remainder_r &&
        (duplicate_next_pc_i == seq_next_pc_i) &&
        (seq_next_pc_i[63:LINE_BITS] == work_r.line_addr);
    assign work_same_owner_advance_c =
        work_same_owner_emit_advance_c ||
        work_same_owner_dup_advance_c;
    assign work_undelivered_owner_hold_c =
        work_r.valid &&
        work_r.ftq_valid &&
        !work_r.owner_delivered &&
        !owner_delivery_push_c;

    assign owner_live_c =
        work_r.ftq_valid &&
        ftq_wb_owner_valid_i &&
        (work_r.ftq_idx == ftq_wb_owner_idx_i) &&
        (work_r.ftq_epoch == ftq_current_epoch_i) &&
        (work_r.ftq_alloc_tag == ftq_wb_owner_tag_i);
    assign owner_live_registered_c =
        work_r.ftq_valid &&
        (ftq_count_ifu_to_wb_i != '0) &&
        ftq_wb_owner_valid_i &&
        (work_r.ftq_idx == ftq_wb_owner_idx_i) &&
        (work_r.ftq_epoch == ftq_current_epoch_i) &&
        (work_r.ftq_alloc_tag == ftq_wb_owner_tag_i);

    assign work_redirect_o =
        bpu_redirect_i && !fe_stall_c;
    assign work_redirect_next_owner_match_o =
        work_redirect_o &&
        redirect_next_owner_match_c;
    assign work_redirect_enq_owner_o =
        work_redirect_o &&
        !work_redirect_next_owner_match_o &&
        ftq_enq_valid_c;
    assign work_redirect_keep_owner_o =
        work_redirect_o &&
        !work_redirect_next_owner_match_o &&
        !ftq_enq_valid_c;
    assign work_take_ftq_next_owner_o =
        !work_redirect_o &&
        !fe_stall_c &&
        ftq_ifu_pop_valid_c &&
        ftq_next_owner_valid_i &&
        seq_valid_i;
    assign work_take_remainder_request_owner_o =
        !work_redirect_o &&
        !fe_stall_c &&
        consumed_remainder_r &&
        ftq_enq_valid_c &&
        !selected_req_is_runahead_c;
    assign work_take_request_owner_o =
        !work_redirect_o &&
        !fe_stall_c &&
        !(line_straddle_advance_i ||
          consume_remainder_i ||
          consumed_remainder_r) &&
        ftq_enq_valid_c &&
        !selected_req_is_runahead_c;
    assign work_same_owner_event_c =
        work_same_owner_advance_c &&
        !redirect_i &&
        !work_redirect_o &&
        !work_take_ftq_next_owner_o &&
        !work_take_request_owner_o &&
        !work_take_remainder_request_owner_o &&
        !fe_stall_c;
    assign runahead_pending_match_next_c =
        runahead_pending_r &&
        ftq_next_owner_valid_i &&
        (ftq_next_owner_idx_i == runahead_pending_idx_r) &&
        (ftq_current_epoch_i == runahead_pending_epoch_r) &&
        (ftq_next_owner_tag_i == runahead_pending_tag_r) &&
        (ftq_next_owner_entry_i.block_pc ==
         {runahead_pending_pc_r[63:LINE_BITS], {LINE_BITS{1'b0}}}) &&
        (ftq_next_owner_entry_i.start_offset == runahead_pending_pc_r[5:0]);
    assign runahead_pending_target_match_c =
        runahead_pending_r &&
        ({bpu_target_i[63:LINE_BITS], {LINE_BITS{1'b0}}} ==
         {runahead_pending_pc_r[63:LINE_BITS], {LINE_BITS{1'b0}}}) &&
        (bpu_target_i[5:0] == runahead_pending_pc_r[5:0]);
    assign runahead_cancel_next_c =
        work_redirect_o &&
        ftq_enq_valid_c &&
        (ftq_count_ifu_to_wb_i > {{FTQ_IDX_BITS{1'b0}}, 1'b1}) &&
        runahead_pending_r &&
        !runahead_pending_target_match_c;
    assign runahead_pending_clear_c =
        redirect_i ||
        runahead_cancel_next_c ||
        runahead_redirect_match_o ||
        (work_take_ftq_next_owner_o && runahead_pending_match_next_c);

    always_comb begin
        if (redirect_i) begin
            next_pc_c    = redirect_pc_i;
            next_valid_c = 1'b1;
        end else if (bpu_redirect_i) begin
            next_pc_c    = bpu_target_i;
            next_valid_c = 1'b1;
        end else if (successor_req_allowed_c) begin
            next_pc_c    = successor_req_pc_i;
            next_valid_c = 1'b1;
        end else if (duplicate_suppressed_i) begin
            next_pc_c    = duplicate_next_pc_i;
            next_valid_c = 1'b1;
        end else if (seq_valid_i && pc_consumed_i) begin
            next_pc_c    = seq_next_pc_i;
            next_valid_c = 1'b1;
        end else begin
            next_pc_c    = f1_pc_r;
            next_valid_c = f1_valid_r;
        end
    end

    always_comb begin
        logic [63:0]                   work_pc_next;
        logic                          work_ftq_valid_next;
        logic [FTQ_IDX_BITS-1:0]       work_ftq_idx_next;
        logic [FTQ_EPOCH_BITS-1:0]     work_ftq_epoch_next;
        logic [FTQ_ALLOC_TAG_BITS-1:0] work_ftq_alloc_tag_next;
        ftq_entry_t                    work_ftq_entry_next;
        logic                          work_owner_delivered_next;

        work_next_c = work_r;

        work_pc_next            = f1_pc_r;
        work_ftq_valid_next     = work_r.ftq_valid;
        work_ftq_idx_next       = work_r.ftq_idx;
        work_ftq_epoch_next     = work_r.ftq_epoch;
        work_ftq_alloc_tag_next = work_r.ftq_alloc_tag;
        work_ftq_entry_next     = work_r.ftq_entry;
        work_owner_delivered_next =
            work_r.owner_delivered || owner_delivery_push_c;

        if (redirect_i) begin
            work_next_c = '0;
        end else if (work_redirect_o) begin
            work_next_c = '0;
            work_next_c.valid      = 1'b1;
            work_next_c.pc         = bpu_target_i;
            work_next_c.line_valid = 1'b1;
            work_next_c.line_addr  = bpu_target_i[63:LINE_BITS];
            if (work_redirect_next_owner_match_o) begin
                work_next_c.ftq_valid     = 1'b1;
                work_next_c.ftq_idx       = ftq_next_owner_idx_i;
                work_next_c.ftq_epoch     = ftq_current_epoch_i;
                work_next_c.ftq_alloc_tag = ftq_next_owner_tag_i;
                work_next_c.ftq_entry     = ftq_next_owner_entry_i;
            end else if (work_redirect_enq_owner_o) begin
                work_next_c.ftq_valid     = 1'b1;
                work_next_c.ftq_idx       = req_owner_idx_i;
                work_next_c.ftq_epoch     = req_owner_epoch_i;
                work_next_c.ftq_alloc_tag = req_owner_tag_i;
                work_next_c.ftq_entry     = req_owner_entry_i;
            end else begin
                work_next_c.ftq_valid     = work_r.ftq_valid;
                work_next_c.ftq_idx       = work_r.ftq_idx;
                work_next_c.ftq_epoch     = work_r.ftq_epoch;
                work_next_c.ftq_alloc_tag = work_r.ftq_alloc_tag;
                work_next_c.ftq_entry     = work_r.ftq_entry;
                work_next_c.owner_delivered = work_owner_delivered_next;
            end
        end else if (!fe_stall_c) begin
            if (work_take_ftq_next_owner_o) begin
                work_next_c = '0;
                work_next_c.valid         = 1'b1;
                work_next_c.pc            = ftq_next_owner_start_pc_c;
                work_next_c.ftq_valid     = 1'b1;
                work_next_c.ftq_idx       = ftq_next_owner_idx_i;
                work_next_c.ftq_epoch     = ftq_current_epoch_i;
                work_next_c.ftq_alloc_tag = ftq_next_owner_tag_i;
                work_next_c.ftq_entry     = ftq_next_owner_entry_i;
                work_next_c.line_valid    = 1'b1;
                work_next_c.line_addr     =
                    ftq_next_owner_start_pc_c[63:LINE_BITS];
            end else begin
                if (line_straddle_advance_i)
                    work_pc_next = seq_next_pc_i;
                else if (consume_remainder_i)
                    work_pc_next = seq_next_pc_i;
                else if (consumed_remainder_r)
                    work_pc_next = post_remainder_pc_r;
                else if (work_same_owner_advance_c)
                    work_pc_next = seq_next_pc_i;
                else if (work_undelivered_owner_hold_c)
                    work_pc_next = work_r.pc;
                else
                    work_pc_next = f1_pc_r;

                if (line_straddle_advance_i ||
                    consume_remainder_i ||
                    consumed_remainder_r) begin
                    if (work_take_remainder_request_owner_o) begin
                        work_pc_next            = req_pc_c;
                        work_ftq_valid_next     = 1'b1;
                        work_ftq_idx_next       = req_owner_idx_i;
                        work_ftq_epoch_next     = req_owner_epoch_i;
                        work_ftq_alloc_tag_next = req_owner_tag_i;
                        work_ftq_entry_next     = req_owner_entry_i;
                        work_owner_delivered_next = 1'b0;
                    end
                end else if (work_take_request_owner_o) begin
                    work_pc_next            = req_pc_c;
                    work_ftq_valid_next     = 1'b1;
                    work_ftq_idx_next       = req_owner_idx_i;
                    work_ftq_epoch_next     = req_owner_epoch_i;
                    work_ftq_alloc_tag_next = req_owner_tag_i;
                    work_ftq_entry_next     = req_owner_entry_i;
                    work_owner_delivered_next = 1'b0;
                end else if (!f1_valid_r) begin
                    work_ftq_valid_next     = 1'b0;
                    work_ftq_idx_next       = '0;
                    work_ftq_epoch_next     = '0;
                    work_ftq_alloc_tag_next = '0;
                    work_ftq_entry_next     = '0;
                    work_owner_delivered_next = 1'b0;
                end

                work_next_c = '0;
                work_next_c.valid         = f1_valid_r;
                work_next_c.pc            = work_pc_next;
                work_next_c.ftq_valid     = work_ftq_valid_next;
                work_next_c.ftq_idx       = work_ftq_idx_next;
                work_next_c.ftq_epoch     = work_ftq_epoch_next;
                work_next_c.ftq_alloc_tag = work_ftq_alloc_tag_next;
                work_next_c.ftq_entry     = work_ftq_entry_next;
                work_next_c.line_valid    = f1_valid_r;
                work_next_c.line_addr     = work_pc_next[63:LINE_BITS];
                work_next_c.owner_delivered = work_owner_delivered_next;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f1_pc_r    <= RESET_VECTOR;
            f1_valid_r <= 1'b1;
            work_r <= '0;
            last_alloc_valid_r  <= 1'b0;
            last_alloc_req_pc_r <= '0;
            consumed_remainder_r <= 1'b0;
            post_remainder_pc_r  <= '0;
            runahead_pending_r       <= 1'b0;
            runahead_pending_pc_r    <= '0;
            runahead_pending_idx_r   <= '0;
            runahead_pending_epoch_r <= '0;
            runahead_pending_tag_r   <= '0;
        end else begin
            if (redirect_i) begin
                f1_pc_r    <= redirect_pc_i;
                f1_valid_r <= 1'b1;
                last_alloc_valid_r    <= 1'b0;
                last_alloc_req_pc_r   <= '0;
                consumed_remainder_r  <= 1'b0;
                runahead_pending_r       <= 1'b0;
                runahead_pending_pc_r    <= '0;
                runahead_pending_idx_r   <= '0;
                runahead_pending_epoch_r <= '0;
                runahead_pending_tag_r   <= '0;
            end else begin
                if (ftq_enq_valid_c) begin
                    last_alloc_valid_r  <= 1'b1;
                    last_alloc_req_pc_r <= req_pc_c;
                end else if (ftq_ifu_pop_valid_c && !ftq_next_owner_valid_i) begin
                    last_alloc_valid_r  <= 1'b0;
                    last_alloc_req_pc_r <= '0;
                end

                if (runahead_req_fire_o) begin
                    runahead_pending_r       <= 1'b1;
                    runahead_pending_pc_r    <= req_pc_c;
                    runahead_pending_idx_r   <= req_owner_idx_i;
                    runahead_pending_epoch_r <= req_owner_epoch_i;
                    runahead_pending_tag_r   <= req_owner_tag_i;
                end else if (runahead_pending_clear_c) begin
                    runahead_pending_r       <= 1'b0;
                    runahead_pending_pc_r    <= '0;
                    runahead_pending_idx_r   <= '0;
                    runahead_pending_epoch_r <= '0;
                    runahead_pending_tag_r   <= '0;
                end

                if (!fe_stall_c) begin
                    if (bpu_redirect_i)
                        f1_pc_r <= bpu_target_i;
                    else if (consumed_remainder_r)
                        f1_pc_r <= post_remainder_pc_r;
                    else
                        f1_pc_r <= next_pc_c;
                    f1_valid_r <= next_valid_c;

                    if (bpu_redirect_i) begin
                        consumed_remainder_r <= 1'b0;
                    end else if (consume_remainder_i) begin
                        consumed_remainder_r <= 1'b1;
                        post_remainder_pc_r  <= seq_next_pc_i;
                    end else begin
                        consumed_remainder_r <= 1'b0;
                    end
                end
            end
            work_r <= work_next_c;
        end
    end

endmodule

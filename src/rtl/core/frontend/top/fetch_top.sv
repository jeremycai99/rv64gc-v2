/* file: fetch_top.sv
 Description: Frontend integration top for branch prediction, IFU, FTQ, and I-cache.
 Author: Jeremy Cai
 Date: Apr 09, 2026
 Version: 2.0
*/
module fetch_top
    import rv64gc_pkg::*;
    import isa_pkg::*;
    import uarch_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // Output to decode
    output logic [2:0]  fetch_count,
    output logic [31:0] fetch_insn [0:PIPE_WIDTH-1],
    output logic [63:0] fetch_pc [0:PIPE_WIDTH-1],
    output logic [PIPE_WIDTH-1:0] fetch_is_rvc,
    output logic [PIPE_WIDTH-1:0] fetch_bp_taken,
    output logic [63:0] fetch_bp_target [0:PIPE_WIDTH-1],
    output logic        fetch_bp_owner_valid,
    output logic [2:0]  fetch_bp_owner_slot,
    output logic        fetch_bp_owner_from_subgroup,
    output logic [63:0] fetch_bp_lookup_pc,
    output logic [4:0]  fetch_bp_ras_tos,
    output logic [63:0] fetch_bp_ras_top,
    output logic [GHR_BITS-1:0] fetch_bp_ghr,

    // Stall from downstream (decode/rename backpressure)
    input  logic        backend_stall,
    // Frontend quiesce while decoded-op replay owns rename input.
    input  logic        frontend_hold,
    // Avoid packet fast-pathing while a replay structure is forming a
    // candidate, including the cycle that starts a replay window.
    input  logic        frontend_replay_blocking,
    input  logic        frontend_replay_start,

    // Redirect (from commit -- mispredict or exception)
    input  logic        redirect_valid,
    input  logic [63:0] redirect_pc,

    // BPU update (from commit -- actual branch outcome)
    input  logic        bpu_update_valid,
    input  logic [63:0] bpu_update_pc,
    input  logic        bpu_tage_update_valid,
    input  logic [63:0] bpu_tage_update_pc,
    input  logic        bpu_tage_update_taken,
    input  logic        bpu_tage_update_mispredict,
    input  logic [63:0] bpu_tage_update_target,
    input  logic [GHR_BITS-1:0] bpu_tage_update_ghr,
    input  logic        bpu_update_taken,
    input  logic        bpu_update_mispredict,
    input  logic [63:0] bpu_update_target,
    input  logic [2:0]  bpu_update_type,     // branch type for BTB
    input  logic [GHR_BITS-1:0] bpu_update_ghr,

    // GHR checkpoint restore
    input  logic        ghr_restore_valid,
    input  logic [GHR_BITS-1:0] ghr_restore_val,
    output logic [GHR_BITS-1:0] ghr_out,

    // RAS restore
    input  logic        ras_restore_valid,
    input  logic [4:0]  ras_restore_tos,
    input  logic        ras_restore_top_valid,
    input  logic [63:0] ras_restore_top_addr,

    // Memory interface (I-cache to L2)
    output logic        icache_fill_req_valid,
    output logic [63:0] icache_fill_req_addr,
    input  logic        icache_fill_resp_valid,
    input  logic [63:0] icache_fill_resp_addr,
    input  logic [511:0] icache_fill_resp_data,

    // Invalidate (FENCE.I)
    input  logic        fence_i,
    // Prefetch L2 interface (from NLPB)
    output logic         pf_l2_req_valid,
    output logic [63:0]  pf_l2_req_addr,
    input  logic         pf_l2_req_ready,
    input  logic         pf_l2_resp_valid,
    input  logic [63:0]  pf_l2_resp_addr,
    input  logic [511:0] pf_l2_resp_data
);

    // =========================================================================
    // Branch type encoding (BTB)
    //   0 = conditional, 1 = JAL, 2 = JALR, 3 = CALL, 4 = RET
    // =========================================================================
    localparam logic [2:0] BT_COND = 3'd0;
    localparam logic [2:0] BT_JAL  = 3'd1;
    localparam logic [2:0] BT_JALR = 3'd2;
    localparam logic [2:0] BT_CALL = 3'd3;
    localparam logic [2:0] BT_RET  = 3'd4;
    localparam int ICQ_DEPTH = 4;
    localparam int ICQ_COUNT_BITS = $clog2(ICQ_DEPTH + 1);

    // =========================================================================
    // F1 stage signals
    // =========================================================================
    logic [63:0] f1_pc;
    logic        f1_valid;

    // BPU redirect from F2 (predicted-taken branch)
    logic        f2_bpu_redirect;
    logic [63:0] f2_bpu_target;
    logic        req_redirect_c;
    logic        line_straddle_advance_c;

    // Sequential next PC: computed from how many bytes F2 consumed
    logic [63:0] f2_seq_next_pc;
    logic        f2_seq_valid;
    logic        f2_will_emit_c;
    logic        f2_pc_consumed_c;
    logic        consume_remainder_c;
    logic        f2_duplicate_suppressed_c;
    logic [63:0] f2_duplicate_next_pc_c;
    logic        f2_ftq_owner_live_c;
    logic        f2_owner_completion_candidate_c;
    logic        f2_same_owner_continue_c;
    logic        bp_branch_found;
    logic        bp_taken;
    logic [63:0] bp_target_addr;
    logic [2:0]  bp_branch_slot;
    logic [2:0]  bp_type;
    logic [2:0]  final_count;
    logic        subgroup_split_before_ctl_c;

    // consumed_remainder_r: latched when the current cycle's extraction
    // consumed a straddle remainder AND emitted at least one instruction.
    // The following cycle must bypass the normal f1->f2 pipeline
    // (which otherwise leaves the IFU work cursor pointing at the
    // already-processed cache-line base) and instead advance it directly to the
    // f2_seq_next_pc captured on the consume cycle.
    logic        consumed_remainder_r;
    logic [63:0] post_remainder_pc_r;

    logic        fe_stall;

    // =========================================================================
    // I-Cache instance
    // =========================================================================
    logic        ic_req_valid;
    logic [63:0] ic_req_addr;
    logic [63:0] req_pc_c;
    logic [63:0] req_block_pc_c;
    logic        ic_resp_valid;
    logic [511:0] ic_resp_data;
    logic        ic_resp_hit;
    logic        icq_full;
    logic        icq_empty;
    logic [ICQ_COUNT_BITS-1:0] icq_count;
    logic        ic_invalidate_busy;
    logic        f2_data_valid;
    logic [511:0] f2_data_line;
    logic        packet_buf_enq;
    logic        packet_buf_enq_ready;
    logic        packet_buf_enq_fire;
    logic        packet_buf_deq;
    logic        packet_buf_deq_fire;
    logic        packet_buf_flowthrough_c;
    logic        packet_buf_valid;
    logic        packet_buf_full;
    logic        packet_buf_empty;
    logic [3:0]  packet_buf_count;
    logic        packet_buf_stale_owner_c;
    logic        packet_flowthrough_candidate;
    logic        packet_flowthrough_valid;
    logic        packet_flowthrough_owner_match_c;
    logic        fetch_packet_out_valid;
    fetch_packet_t fetch_packet_out;
    logic        ftq_need_alloc_c;
    logic        ftq_enq_valid;
    logic        ftq_enq_ready;
    logic        ifu_req_valid_c;
    logic        ifu_req_ready_c;
    logic        ifu_req_fire_c;
    logic        ftq_pop_valid;
    logic        ftq_ifu_req_pop_valid;
    logic        ftq_delivery_push_valid;
    logic        ftq_ifu_pop_valid;
    logic        ftq_commit_pop_valid;
    logic        ftq_head_valid;
    logic        ftq_ifu_owner_valid;
    logic        ftq_ifu_wb_owner_valid;
    logic        ftq_next_ifu_owner_valid;
    logic        ftq_commit_head_valid;
    logic        ftq_commit_owner_valid;
    logic        ftq_full;
    logic        ftq_empty;
    logic [FTQ_IDX_BITS-1:0]   ftq_enq_idx;
    logic [FTQ_IDX_BITS-1:0]   ftq_head_idx;
    logic [FTQ_IDX_BITS-1:0]   ftq_ifu_owner_idx;
    logic [FTQ_IDX_BITS-1:0]   ftq_ifu_wb_owner_idx;
    logic [FTQ_IDX_BITS-1:0]   ftq_next_ifu_owner_idx;
    logic [FTQ_IDX_BITS-1:0]   ftq_commit_head_idx;
    logic [FTQ_IDX_BITS-1:0]   ftq_commit_owner_idx;
    logic [FTQ_EPOCH_BITS-1:0] ftq_enq_epoch;
    logic [FTQ_ALLOC_TAG_BITS-1:0] ftq_enq_tag;
    logic [FTQ_ALLOC_TAG_BITS-1:0] ftq_head_tag;
    logic [FTQ_ALLOC_TAG_BITS-1:0] ftq_ifu_owner_tag;
    logic [FTQ_ALLOC_TAG_BITS-1:0] ftq_ifu_wb_owner_tag;
    logic [FTQ_ALLOC_TAG_BITS-1:0] ftq_next_ifu_owner_tag;
    logic [FTQ_ALLOC_TAG_BITS-1:0] ftq_commit_head_tag;
    logic [FTQ_ALLOC_TAG_BITS-1:0] ftq_commit_owner_tag;
    logic [FTQ_EPOCH_BITS-1:0] ftq_current_epoch;
    logic [FTQ_IDX_BITS:0]     ftq_count;
    logic [FTQ_IDX_BITS:0]     ftq_count_alloc_to_ifu;
    logic [FTQ_IDX_BITS:0]     ftq_count_ifu_to_wb;
    logic [FTQ_IDX_BITS:0]     ftq_count_ifu_to_commit;
    // Forward declarations used by FTQ allocation and completion wiring before
    // the IFU work cursor is declared later in the file.
    logic        f2_work_valid_c;
    logic [63:0] f2_work_pc_c;
    logic        f2_work_line_valid_c;
    logic [63:LINE_BITS] f2_work_line_addr_c;
    logic        f2_work_owner_complete_c;
    logic        f2_work_owner_delivered_c;
    logic        f2_owner_delivery_push_c;
    logic        f2_redirect_without_owner_successor_c;
    logic        ftq_last_alloc_valid_r;
    logic [63:0] ftq_last_alloc_req_pc_r;
    logic        subgroup_seed_valid_r;
    logic [63:0] subgroup_seed_pc_r;
    logic [63:0] subgroup_seed_parent_pc_r;
    logic [63:0] subgroup_seed_owner_pc_r;
    logic        subgroup_seed_pred_valid_r;
    logic        subgroup_seed_pred_taken_r;
    logic [5:0]  subgroup_seed_pred_offset_r;
    logic [2:0]  subgroup_seed_pred_type_r;
    logic [63:0] subgroup_seed_pred_target_r;
    logic        subgroup_seed_hit_c;
    logic        subgroup_seed_load_c;
    logic        subgroup_seed_pred_taken_c;
    ftq_entry_t  req_ftq_entry_c;
    ftq_entry_t  ftq_head_entry;
    ftq_entry_t  ftq_ifu_owner_entry;
    ftq_entry_t  ftq_ifu_wb_owner_entry;
    ftq_entry_t  ftq_next_ifu_owner_entry;
    ftq_entry_t  ftq_commit_head_entry;
    ftq_entry_t  ftq_commit_owner_entry;
    ftq_entry_t  ftq_enq_entry_c;
    fetch_packet_t packet_buf_in;
    fetch_packet_t packet_buf_head;
    logic        packet_buf_owner_match_c;
    logic        packet_buf_head_owner_complete_c;
    logic        remainder_valid_r;
    logic        subgroup_split_second_ctl_en;
    logic        subgroup_split_any_second_ctl_en;
    logic        subgroup_split_owner_cond_en;
    logic        subgroup_split_slot3_ftq_taken_only_en;

`ifdef SIMULATION
    logic sim_subgroup_split_second_ctl_en;
    logic sim_subgroup_split_any_second_ctl_en;
    logic sim_subgroup_split_owner_cond_en;
    logic sim_subgroup_split_slot3_ftq_taken_only_en;
    initial begin
        sim_subgroup_split_second_ctl_en =
            !$test$plusargs("DISABLE_SUBGROUP_SPLIT_SECOND_CTL");
        sim_subgroup_split_any_second_ctl_en =
            !$test$plusargs("DISABLE_SPLIT_ANY_SECOND_CTL");
        sim_subgroup_split_owner_cond_en =
            !$test$plusargs("DISABLE_SUBGROUP_SPLIT_OWNER_COND");
        sim_subgroup_split_slot3_ftq_taken_only_en =
            $test$plusargs("SPLIT_SLOT3_FTQ_TAKEN_ONLY");
    end
    assign subgroup_split_second_ctl_en =
        sim_subgroup_split_second_ctl_en;
    assign subgroup_split_any_second_ctl_en =
        sim_subgroup_split_any_second_ctl_en;
    assign subgroup_split_owner_cond_en =
        sim_subgroup_split_owner_cond_en;
    assign subgroup_split_slot3_ftq_taken_only_en =
        sim_subgroup_split_slot3_ftq_taken_only_en;
`else
    assign subgroup_split_second_ctl_en = 1'b1;
    assign subgroup_split_any_second_ctl_en = 1'b1;
    assign subgroup_split_owner_cond_en = 1'b1;
    assign subgroup_split_slot3_ftq_taken_only_en = 1'b0;
`endif

    // IFU owns the conservative F1 request and FTQ allocation boundary. It
    // still issues only under the existing lockstep conditions; this slice only
    // moves the boundary out of the integration wrapper.
    assign ftq_enq_entry_c = req_ftq_entry_c;

    // I-cache, NLPB, ICQ association, and same-line line-state reuse now live
    // behind ifu_line_fetch. The IFU work cursor remains here until the next
    // stateful IFU slice.
    logic        nlpb_hit_comb;
    logic        nlpb_aux_hit_comb;

    // ICQ head fields remain visible here because the IFU work cursor and
    // line-state reuse policy have not moved yet.
    logic                                  icq_deq_valid;
    logic [511:0]                          icq_deq_data;
    logic                                  icq_deq_hit;
    logic [63:0]                           icq_deq_pc;
    logic [63:LINE_BITS]                   icq_deq_line_addr;
    logic                                  icq_deq_ftq_valid;
    logic [FTQ_IDX_BITS-1:0]               icq_deq_ftq_idx;
    logic [FTQ_EPOCH_BITS-1:0]             icq_deq_ftq_epoch;
    logic [FTQ_ALLOC_TAG_BITS-1:0]         icq_deq_ftq_alloc_tag;
    ftq_entry_t                            icq_deq_ftq_entry;
    logic                                  icq_deq_owner_match_c;
    logic                                  f2_line_state_valid_c;
    logic [63:LINE_BITS]                   f2_line_state_addr_c;
    logic [FTQ_EPOCH_BITS-1:0]             f2_line_state_epoch_c;
    logic                                  f2_line_state_use_c;
    logic [63:LINE_BITS]                   f2_ifu_line_addr_c;
    logic                                  f2_work_ftq_valid_c;
    logic [FTQ_IDX_BITS-1:0]               f2_work_ftq_idx_c;
    logic [FTQ_EPOCH_BITS-1:0]             f2_work_ftq_epoch_c;
    logic [FTQ_ALLOC_TAG_BITS-1:0]         f2_work_ftq_alloc_tag_c;
    ftq_entry_t                            f2_work_ftq_entry_c;
    logic                                  ifu_work_redirect_c;
    logic                                  ifu_work_redirect_next_owner_match_c;
    logic                                  ifu_work_redirect_enq_owner_c;
    logic                                  ifu_work_redirect_keep_owner_c;
    logic                                  ifu_work_take_ftq_next_owner_c;
    logic                                  ifu_work_take_request_owner_c;
    logic                                  ifu_work_take_remainder_request_owner_c;

    ifu u_ifu (
        .clk                                      (clk),
        .rst_n                                    (rst_n),
        .redirect_i                               (redirect_valid),
        .redirect_pc_i                            (redirect_pc),
        .frontend_hold_i                          (frontend_hold),
        .packet_buf_full_i                        (packet_buf_full),
        .icq_full_i                               (icq_full),
        .ftq_enq_ready_i                          (ftq_enq_ready),
        .remainder_valid_i                        (remainder_valid_r),
        .same_owner_continue_i                    (f2_same_owner_continue_c),
        .last_alloc_valid_i                       (ftq_last_alloc_valid_r),
        .last_alloc_req_pc_i                      (ftq_last_alloc_req_pc_r),
        .req_redirect_i                           (req_redirect_c),
        .duplicate_suppressed_i                   (f2_duplicate_suppressed_c),
        .duplicate_next_pc_i                      (f2_duplicate_next_pc_c),
        .pc_consumed_i                            (f2_pc_consumed_c),
        .will_emit_i                              (f2_will_emit_c),
        .req_owner_idx_i                          (ftq_enq_idx),
        .req_owner_epoch_i                        (ftq_enq_epoch),
        .req_owner_tag_i                          (ftq_enq_tag),
        .req_owner_entry_i                        (ftq_enq_entry_c),
        .bpu_redirect_i                           (f2_bpu_redirect),
        .bpu_target_i                             (f2_bpu_target),
        .ftq_next_owner_valid_i                   (ftq_next_ifu_owner_valid),
        .ftq_next_owner_idx_i                     (ftq_next_ifu_owner_idx),
        .ftq_next_owner_tag_i                     (ftq_next_ifu_owner_tag),
        .ftq_next_owner_entry_i                   (ftq_next_ifu_owner_entry),
        .ftq_current_epoch_i                      (ftq_current_epoch),
        .ftq_count_ifu_to_wb_i                    (ftq_count_ifu_to_wb),
        .seq_valid_i                              (f2_seq_valid),
        .seq_next_pc_i                            (f2_seq_next_pc),
        .line_straddle_advance_i                  (line_straddle_advance_c),
        .consume_remainder_i                      (consume_remainder_c),
        .consumed_remainder_i                     (consumed_remainder_r),
        .post_remainder_pc_i                      (post_remainder_pc_r),
        .owner_complete_i                         (f2_work_owner_complete_c),
        .packet_valid_i                           (packet_buf_in.valid),
        .packet_enq_i                             (packet_buf_enq),
        .owner_live_i                             (f2_ftq_owner_live_c),
        .f1_valid_o                               (f1_valid),
        .f1_pc_o                                  (f1_pc),
        .req_pc_o                                 (req_pc_c),
        .req_block_pc_o                           (req_block_pc_c),
        .ftq_need_alloc_o                         (ftq_need_alloc_c),
        .ifu_req_valid_o                          (ifu_req_valid_c),
        .ifu_req_ready_o                          (ifu_req_ready_c),
        .ifu_req_fire_o                           (ifu_req_fire_c),
        .ftq_enq_valid_o                          (ftq_enq_valid),
        .ftq_ifu_req_pop_valid_o                  (ftq_ifu_req_pop_valid),
        .ftq_delivery_push_valid_o                (ftq_delivery_push_valid),
        .ftq_ifu_pop_valid_o                      (ftq_ifu_pop_valid),
        .ic_req_valid_o                           (ic_req_valid),
        .ic_req_addr_o                            (ic_req_addr),
        .fe_stall_o                               (fe_stall),
        .redirect_without_owner_successor_o       (f2_redirect_without_owner_successor_c),
        .owner_completion_candidate_o             (f2_owner_completion_candidate_c),
        .owner_delivery_push_o                    (f2_owner_delivery_push_c),
        .work_valid_o                             (f2_work_valid_c),
        .work_pc_o                                (f2_work_pc_c),
        .work_ftq_valid_o                         (f2_work_ftq_valid_c),
        .work_ftq_idx_o                           (f2_work_ftq_idx_c),
        .work_ftq_epoch_o                         (f2_work_ftq_epoch_c),
        .work_ftq_alloc_tag_o                     (f2_work_ftq_alloc_tag_c),
        .work_ftq_entry_o                         (f2_work_ftq_entry_c),
        .work_line_valid_o                        (f2_work_line_valid_c),
        .work_line_addr_o                         (f2_work_line_addr_c),
        .work_owner_delivered_o                   (f2_work_owner_delivered_c),
        .work_redirect_o                          (ifu_work_redirect_c),
        .work_redirect_next_owner_match_o         (ifu_work_redirect_next_owner_match_c),
        .work_redirect_enq_owner_o                (ifu_work_redirect_enq_owner_c),
        .work_redirect_keep_owner_o               (ifu_work_redirect_keep_owner_c),
        .work_take_ftq_next_owner_o               (ifu_work_take_ftq_next_owner_c),
        .work_take_request_owner_o                (ifu_work_take_request_owner_c),
        .work_take_remainder_request_owner_o      (ifu_work_take_remainder_request_owner_c)
    );

    ifu_line_fetch #(.ICQ_DEPTH(ICQ_DEPTH)) u_ifu_line_fetch (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .flush_i                (redirect_valid),
        .fence_i                (fence_i),
        .req_valid_i            (ic_req_valid),
        .req_addr_i             (ic_req_addr),
        .aux_lookup_addr_i      (f1_pc),
        .f1_valid_i             (f1_valid),
        .stall_i                (fe_stall),
        .work_valid_i           (f2_work_valid_c),
        .work_line_valid_i      (f2_work_line_valid_c),
        .work_line_addr_i       (f2_work_line_addr_c),
        .current_epoch_i        (ftq_current_epoch),
        .req_owner_valid_i      (ftq_enq_valid),
        .req_owner_idx_i        (ftq_enq_idx),
        .req_owner_epoch_i      (ftq_enq_epoch),
        .req_owner_alloc_tag_i  (ftq_enq_tag),
        .req_owner_entry_i      (ftq_enq_entry_c),
        .icq_deq_valid_o        (icq_deq_valid),
        .icq_deq_data_o         (icq_deq_data),
        .icq_deq_hit_o          (icq_deq_hit),
        .icq_deq_pc_o           (icq_deq_pc),
        .icq_deq_line_addr_o    (icq_deq_line_addr),
        .icq_deq_ftq_valid_o    (icq_deq_ftq_valid),
        .icq_deq_ftq_idx_o      (icq_deq_ftq_idx),
        .icq_deq_ftq_epoch_o    (icq_deq_ftq_epoch),
        .icq_deq_ftq_alloc_tag_o(icq_deq_ftq_alloc_tag),
        .icq_deq_ftq_entry_o    (icq_deq_ftq_entry),
        .icq_full_o             (icq_full),
        .icq_empty_o            (icq_empty),
        .icq_count_o            (icq_count),
        .line_resp_valid_o      (ic_resp_valid),
        .line_resp_data_o       (ic_resp_data),
        .line_resp_hit_o        (ic_resp_hit),
        .data_valid_o           (f2_data_valid),
        .data_line_o            (f2_data_line),
        .data_line_addr_o       (f2_ifu_line_addr_c),
        .data_line_reused_o     (f2_line_state_use_c),
        .line_state_valid_o     (f2_line_state_valid_c),
        .line_state_addr_o      (f2_line_state_addr_c),
        .line_state_epoch_o     (f2_line_state_epoch_c),
        .nlpb_hit_o             (nlpb_hit_comb),
        .nlpb_aux_hit_o         (nlpb_aux_hit_comb),
        .icache_fill_req_valid  (icache_fill_req_valid),
        .icache_fill_req_addr   (icache_fill_req_addr),
        .icache_fill_resp_valid (icache_fill_resp_valid),
        .icache_fill_resp_addr  (icache_fill_resp_addr),
        .icache_fill_resp_data  (icache_fill_resp_data),
        .icache_invalidate_busy (ic_invalidate_busy),
        .pf_l2_req_valid        (pf_l2_req_valid),
        .pf_l2_req_addr         (pf_l2_req_addr),
        .pf_l2_req_ready        (pf_l2_req_ready),
        .pf_l2_resp_valid       (pf_l2_resp_valid),
        .pf_l2_resp_addr        (pf_l2_resp_addr),
        .pf_l2_resp_data        (pf_l2_resp_data)
    );

    assign icq_deq_owner_match_c =
        icq_deq_valid &&
        icq_deq_ftq_valid &&
        ftq_ifu_wb_owner_valid &&
        (icq_deq_ftq_idx == ftq_ifu_wb_owner_idx) &&
        (icq_deq_ftq_epoch == ftq_current_epoch) &&
        (icq_deq_ftq_alloc_tag == ftq_ifu_wb_owner_tag);
    assign f2_ftq_owner_live_c =
        f2_work_ftq_valid_c &&
        ftq_ifu_wb_owner_valid &&
        (f2_work_ftq_idx_c == ftq_ifu_wb_owner_idx) &&
        (f2_work_ftq_epoch_c == ftq_current_epoch) &&
        (f2_work_ftq_alloc_tag_c == ftq_ifu_wb_owner_tag);
    assign packet_buf_deq = !backend_stall && !frontend_hold;

    ftq u_ftq (
        .clk          (clk),
        .rst_n        (rst_n),
        .flush        (redirect_valid),
        .enq_valid    (ftq_enq_valid),
        .enq_entry    (ftq_enq_entry_c),
        .enq_ready    (ftq_enq_ready),
        .enq_idx      (ftq_enq_idx),
        .enq_epoch    (ftq_enq_epoch),
        .enq_tag      (ftq_enq_tag),
        .ifu_req_pop_valid(ftq_ifu_req_pop_valid),
        .delivery_push_valid(ftq_delivery_push_valid),
        .pop_valid    (ftq_ifu_pop_valid),
        .head_valid   (ftq_head_valid),
        .head_entry   (ftq_head_entry),
        .head_idx     (ftq_head_idx),
        .head_tag     (ftq_head_tag),
        .ifu_owner_valid(ftq_ifu_owner_valid),
        .ifu_owner_entry(ftq_ifu_owner_entry),
        .ifu_owner_idx(ftq_ifu_owner_idx),
        .ifu_owner_tag(ftq_ifu_owner_tag),
        .ifu_wb_owner_valid(ftq_ifu_wb_owner_valid),
        .ifu_wb_owner_entry(ftq_ifu_wb_owner_entry),
        .ifu_wb_owner_idx(ftq_ifu_wb_owner_idx),
        .ifu_wb_owner_tag(ftq_ifu_wb_owner_tag),
        .next_ifu_owner_valid(ftq_next_ifu_owner_valid),
        .next_ifu_owner_entry(ftq_next_ifu_owner_entry),
        .next_ifu_owner_idx(ftq_next_ifu_owner_idx),
        .next_ifu_owner_tag(ftq_next_ifu_owner_tag),
        .commit_pop_valid(ftq_commit_pop_valid),
        .commit_head_valid(ftq_commit_head_valid),
        .commit_head_entry(ftq_commit_head_entry),
        .commit_head_idx(ftq_commit_head_idx),
        .commit_head_tag(ftq_commit_head_tag),
        .commit_owner_valid(ftq_commit_owner_valid),
        .commit_owner_entry(ftq_commit_owner_entry),
        .commit_owner_idx(ftq_commit_owner_idx),
        .commit_owner_tag(ftq_commit_owner_tag),
        .current_epoch(ftq_current_epoch),
        .count        (ftq_count),
        .count_alloc_to_ifu(ftq_count_alloc_to_ifu),
        .count_ifu_to_wb(ftq_count_ifu_to_wb),
        .count_ifu_to_commit(ftq_count_ifu_to_commit),
        .full         (ftq_full),
        .empty        (ftq_empty)
    );

    ibuffer u_ibuffer (
        .clk                             (clk),
        .rst_n                           (rst_n),
        .flush                           (redirect_valid),
        .enq_valid                       (packet_buf_enq),
        .enq_packet                      (packet_buf_in),
        .enq_ready                       (packet_buf_enq_ready),
        .enq_fire                        (packet_buf_enq_fire),
        .deq_ready                       (packet_buf_deq),
        .deq_valid                       (packet_buf_valid),
        .deq_packet                      (packet_buf_head),
        .deq_fire                        (packet_buf_deq_fire),
        .deq_flowthrough                 (packet_buf_flowthrough_c),
        .packet_out_valid                (fetch_packet_out_valid),
        .packet_out                      (fetch_packet_out),
        .decode_fetch_count              (fetch_count),
        .decode_fetch_insn               (fetch_insn),
        .decode_fetch_pc                 (fetch_pc),
        .decode_fetch_is_rvc             (fetch_is_rvc),
        .decode_fetch_bp_taken           (fetch_bp_taken),
        .decode_fetch_bp_target          (fetch_bp_target),
        .decode_fetch_bp_owner_valid     (fetch_bp_owner_valid),
        .decode_fetch_bp_owner_slot      (fetch_bp_owner_slot),
        .decode_fetch_bp_owner_from_subgroup(fetch_bp_owner_from_subgroup),
        .decode_fetch_bp_lookup_pc       (fetch_bp_lookup_pc),
        .decode_fetch_bp_ras_tos         (fetch_bp_ras_tos),
        .decode_fetch_bp_ras_top         (fetch_bp_ras_top),
        .decode_fetch_bp_ghr             (fetch_bp_ghr),
        .owner_valid                     (ftq_commit_owner_valid),
        .owner_idx                       (ftq_commit_owner_idx),
        .owner_epoch                     (ftq_current_epoch),
        .owner_tag                       (ftq_commit_owner_tag),
        .deq_owner_match                 (packet_buf_owner_match_c),
        .deq_stale_owner                 (packet_buf_stale_owner_c),
        .deq_owner_complete              (packet_buf_head_owner_complete_c),
        .full                            (packet_buf_full),
        .empty                           (packet_buf_empty),
        .count                           (packet_buf_count)
    );

    // =========================================================================
    // BPU wrapper: BTB, TAGE, and RAS lookup/update
    // =========================================================================
    logic        btb_hit;
    logic [63:0] btb_target;
    logic [2:0]  btb_branch_type;
    logic [5:0]  btb_branch_offset;
    logic        btb_alt_hit;
    logic [63:0] btb_alt_target;
    logic [2:0]  btb_alt_branch_type;
    logic [5:0]  btb_alt_branch_offset;
    logic        f1_aux_btb_hit;
    logic [63:0] f1_aux_btb_target;
    logic [2:0]  f1_aux_btb_type;
    logic [5:0]  f1_aux_btb_offset;
    logic        f1_aux_btb_alt_hit;
    logic [63:0] f1_aux_btb_alt_target;
    logic [2:0]  f1_aux_btb_alt_type;
    logic [5:0]  f1_aux_btb_alt_offset;
    logic [63:0] predecode_ctl_pc;
    logic [63:0] predecode_ctl_target;
    logic [GHR_BITS-1:0] f2_ghr_snapshot_r;
    logic        tage_pred_taken;
    logic        tage_pred_confident;
    logic        owner_tage_pred_taken;
    logic        owner_tage_pred_confident;
    logic        ras_push_valid;
    logic [63:0] ras_push_addr;
    logic        ras_pop_valid;
    logic [63:0] ras_pop_addr;
    logic [4:0]  ras_tos;
    logic        tage_spec_update_valid;
    logic        tage_spec_taken;
    logic        f1_aux_pred_ctl_valid_c;
    logic        f1_aux_pred_ctl_taken_c;
    logic [5:0]  f1_aux_pred_ctl_offset_c;
    logic [2:0]  f1_aux_pred_ctl_type_c;
    logic [63:0] f1_aux_pred_ctl_target_c;

    bpu u_bpu (
        .clk                         (clk),
        .rst_n                       (rst_n),
        .flush_i                     (redirect_valid),
        .lookup_pc_i                 (ic_req_addr),
        .lookup_block_pc_i           (req_block_pc_c),
        .aux_lookup_pc_i             (f1_pc),
        .btb_hit_o                   (btb_hit),
        .btb_target_o                (btb_target),
        .btb_type_o                  (btb_branch_type),
        .btb_offset_o                (btb_branch_offset),
        .btb_alt_hit_o               (btb_alt_hit),
        .btb_alt_target_o            (btb_alt_target),
        .btb_alt_type_o              (btb_alt_branch_type),
        .btb_alt_offset_o            (btb_alt_branch_offset),
        .aux_btb_hit_o               (f1_aux_btb_hit),
        .aux_btb_target_o            (f1_aux_btb_target),
        .aux_btb_type_o              (f1_aux_btb_type),
        .aux_btb_offset_o            (f1_aux_btb_offset),
        .aux_btb_alt_hit_o           (f1_aux_btb_alt_hit),
        .aux_btb_alt_target_o        (f1_aux_btb_alt_target),
        .aux_btb_alt_type_o          (f1_aux_btb_alt_type),
        .aux_btb_alt_offset_o        (f1_aux_btb_alt_offset),
        .tage_pred_taken_o           (tage_pred_taken),
        .tage_pred_confident_o       (tage_pred_confident),
        .aux_tage_pc_i               (predecode_ctl_pc),
        .aux_tage_target_i           (predecode_ctl_target),
        .aux_tage_ghr_i              (f2_ghr_snapshot_r),
        .aux_tage_pred_taken_o       (owner_tage_pred_taken),
        .aux_tage_pred_confident_o   (owner_tage_pred_confident),
        .btb_update_valid_i          (bpu_update_valid),
        .btb_update_pc_i             (bpu_update_pc),
        .btb_update_target_i         (bpu_update_target),
        .btb_update_type_i           (bpu_update_type),
        .tage_update_valid_i         (bpu_tage_update_valid),
        .tage_update_pc_i            (bpu_tage_update_pc),
        .tage_update_target_i        (bpu_tage_update_target),
        .tage_update_taken_i         (bpu_tage_update_taken),
        .tage_update_mispredict_i    (bpu_tage_update_mispredict),
        .tage_update_ghr_i           (bpu_tage_update_ghr),
        .tage_spec_update_valid_i    (tage_spec_update_valid),
        .tage_spec_taken_i           (tage_spec_taken),
        .tage_spec_pc_i              (predecode_ctl_pc),
        .tage_spec_target_i          (predecode_ctl_target),
        .ghr_restore_valid_i         (ghr_restore_valid),
        .ghr_restore_val_i           (ghr_restore_val),
        .ghr_o                       (ghr_out),
        .subgroup_seed_hit_i         (subgroup_seed_hit_c),
        .subgroup_seed_pred_valid_i  (subgroup_seed_pred_valid_r),
        .subgroup_seed_pred_taken_i  (subgroup_seed_pred_taken_r),
        .subgroup_seed_pred_offset_i (subgroup_seed_pred_offset_r),
        .subgroup_seed_pred_type_i   (subgroup_seed_pred_type_r),
        .subgroup_seed_pred_target_i (subgroup_seed_pred_target_r),
        .req_ftq_entry_o             (req_ftq_entry_c),
        .aux_pred_ctl_valid_o        (f1_aux_pred_ctl_valid_c),
        .aux_pred_ctl_taken_o        (f1_aux_pred_ctl_taken_c),
        .aux_pred_ctl_offset_o       (f1_aux_pred_ctl_offset_c),
        .aux_pred_ctl_type_o         (f1_aux_pred_ctl_type_c),
        .aux_pred_ctl_target_o       (f1_aux_pred_ctl_target_c),
        .ras_push_valid_i            (ras_push_valid),
        .ras_push_addr_i             (ras_push_addr),
        .ras_pop_valid_i             (ras_pop_valid),
        .ras_pop_addr_o              (ras_pop_addr),
        .ras_tos_o                   (ras_tos),
        .ras_restore_valid_i         (ras_restore_valid),
        .ras_restore_tos_i           (ras_restore_tos),
        .ras_restore_top_valid_i     (ras_restore_top_valid),
        .ras_restore_top_addr_i      (ras_restore_top_addr)
    );

    // =========================================================================
    // F1 -> F2 pipeline registers
    // =========================================================================
    logic        f2_btb_hit_r;
    logic [63:0] f2_btb_target_r;
    logic [2:0]  f2_btb_type_r;
    logic [5:0]  f2_btb_offset_r;
    logic        f2_btb_alt_hit_r;
    logic [63:0] f2_btb_alt_target_r;
    logic [2:0]  f2_btb_alt_type_r;
    logic [5:0]  f2_btb_alt_offset_r;
    logic        f2_tage_taken_r;
    // Boundary outputs are driven by instr_boundary and consumed by the IFU
    // cursor policy before the leaf instance appears later in the file.
    logic [2:0]  extract_count;
    logic [5:0]  start_offset;

    // Track the most recent F2 PC emitted to decode. The current f1->f2
    // pipeline can hold the work cursor on the same fetch group for back-to-back
    // cycles while the frontend catches up; without a duplicate filter,
    // decode/rename can consume the same group twice.
    logic        f2_has_emit_payload_c;
    logic        f2_last_emit_valid_r;
    logic [63:0] f2_last_emit_pc_r;
    logic [63:0] f2_last_emit_next_pc_r;
    logic [63:0] f2_replay_block_pc_r;
    logic [1:0]  f2_replay_block_age_r;
    logic        f2_last_emit_hit_c;
    logic        f2_replay_block_hit_c;
    assign f2_has_emit_payload_c = f2_work_valid_c && f2_data_valid &&
                                   (extract_count > 3'd0);

    ifu_duplicate_guard u_ifu_duplicate_guard (
        .clk                          (clk),
        .rst_n                        (rst_n),
        .redirect_i                   (redirect_valid),
        .bpu_redirect_i               (f2_bpu_redirect),
        .stall_i                      (fe_stall),
        .will_emit_i                  (f2_will_emit_c),
        .has_emit_payload_i           (f2_has_emit_payload_c),
        .bp_branch_found_i            (bp_branch_found),
        .bp_taken_i                   (bp_taken),
        .subgroup_split_before_ctl_i  (subgroup_split_before_ctl_c),
        .bp_target_i                  (bp_target_addr),
        .seq_valid_i                  (f2_seq_valid),
        .seq_next_pc_i                (f2_seq_next_pc),
        .f1_pc_i                      (f1_pc),
        .bpu_target_i                 (f2_bpu_target),
        .work_ftq_valid_i             (f2_work_ftq_valid_c),
        .work_pc_i                    (f2_work_pc_c),
        .work_ftq_idx_i               (f2_work_ftq_idx_c),
        .work_ftq_epoch_i             (f2_work_ftq_epoch_c),
        .work_ftq_alloc_tag_i         (f2_work_ftq_alloc_tag_c),
        .duplicate_suppressed_o       (f2_duplicate_suppressed_c),
        .duplicate_next_pc_o          (f2_duplicate_next_pc_c),
        .last_emit_hit_o              (f2_last_emit_hit_c),
        .replay_block_hit_o           (f2_replay_block_hit_c),
        .last_emit_valid_o            (f2_last_emit_valid_r),
        .last_emit_pc_o               (f2_last_emit_pc_r),
        .last_emit_next_pc_o          (f2_last_emit_next_pc_r),
        .replay_block_pc_o            (f2_replay_block_pc_r),
        .replay_block_age_o           (f2_replay_block_age_r)
    );
    // Iteration alpha' (2026-05-05): explicit packet-buffer backpressure.
    // F2 must not emit unless the IBuffer can accept the packet. The buffer can
    // now accept on a full+dequeue cycle and can flow through when empty, so use
    // its ready rather than the raw full flag.
    assign f2_will_emit_c = f2_has_emit_payload_c &&
                             !f2_duplicate_suppressed_c &&
                             packet_buf_enq_ready;
    // A duplicate-suppressed F2 group must not advance F1 using the current
    // group's sequential PC. The bytes were already consumed by the original
    // emission; advancing again starts the next request inside that packet.
    assign f2_pc_consumed_c = f2_will_emit_c || line_straddle_advance_c;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ftq_last_alloc_valid_r    <= 1'b0;
            ftq_last_alloc_req_pc_r   <= '0;
        end else if (redirect_valid) begin
            ftq_last_alloc_valid_r    <= 1'b0;
            ftq_last_alloc_req_pc_r   <= '0;
        end else if (ftq_enq_valid) begin
            ftq_last_alloc_valid_r    <= 1'b1;
            ftq_last_alloc_req_pc_r   <= req_pc_c;
        end else if (ftq_ifu_pop_valid && !ftq_next_ifu_owner_valid) begin
            ftq_last_alloc_valid_r    <= 1'b0;
            ftq_last_alloc_req_pc_r   <= '0;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f2_btb_hit_r        <= 1'b0;
            f2_btb_target_r     <= '0;
            f2_btb_type_r       <= '0;
            f2_btb_offset_r     <= '0;
            f2_btb_alt_hit_r    <= 1'b0;
            f2_btb_alt_target_r <= '0;
            f2_btb_alt_type_r   <= '0;
            f2_btb_alt_offset_r <= '0;
            f2_tage_taken_r     <= 1'b0;
            f2_ghr_snapshot_r   <= '0;
            consumed_remainder_r <= 1'b0;
            post_remainder_pc_r  <= '0;
        end else if (redirect_valid) begin
            // Flush cursor-adjacent state on redirect.
            consumed_remainder_r <= 1'b0;
        end else if (f2_bpu_redirect && !fe_stall) begin
            // BPU redirect: the IFU work cursor is redirected to the target.
            // Latch predictor metadata for the redirected-to fetch group.
            // BTB/TAGE lookup follows ic_req_addr, which already points at
            // f2_bpu_target in this cycle.
            f2_btb_hit_r        <= btb_hit;
            f2_btb_target_r     <= btb_target;
            f2_btb_type_r       <= btb_branch_type;
            f2_btb_offset_r     <= btb_branch_offset;
            f2_btb_alt_hit_r    <= btb_alt_hit;
            f2_btb_alt_target_r <= btb_alt_target;
            f2_btb_alt_type_r   <= btb_alt_branch_type;
            f2_btb_alt_offset_r <= btb_alt_branch_offset;
            f2_tage_taken_r     <= tage_pred_taken;
            f2_ghr_snapshot_r   <= ghr_out;
            consumed_remainder_r <= 1'b0;
        end else begin
            if (!fe_stall) begin
                f2_btb_hit_r        <= btb_hit;
                f2_btb_target_r     <= btb_target;
                f2_btb_type_r       <= btb_branch_type;
                f2_btb_offset_r     <= btb_branch_offset;
                f2_btb_alt_hit_r    <= btb_alt_hit;
                f2_btb_alt_target_r <= btb_alt_target;
                f2_btb_alt_type_r   <= btb_alt_branch_type;
                f2_btb_alt_offset_r <= btb_alt_branch_offset;
                f2_tage_taken_r     <= tage_pred_taken;
                if (line_straddle_advance_c || consume_remainder_c ||
                    consumed_remainder_r) begin
                    f2_ghr_snapshot_r <= f2_ghr_snapshot_r;
                end else begin
                    f2_ghr_snapshot_r <= ghr_out;
                end

                // Latch the consume event and the post-remainder PC so the
                // next cycle can also advance f1_pc in lock-step.
                if (consume_remainder_c) begin
                    consumed_remainder_r <= 1'b1;
                    post_remainder_pc_r  <= f2_seq_next_pc;
                end else begin
                    consumed_remainder_r <= 1'b0;
                end
            end
        end
    end

    // =========================================================================
    // F2: Instruction extraction from cache line
    //
    // The I-cache returns a full 512-bit (64-byte) line. We extract up to
    // PIPE_WIDTH=4 instructions starting at the byte offset indicated by
    // f2_work_pc_c[5:0]. Each instruction is either 16-bit compressed (bits[1:0]
    // != 2'b11) or 32-bit.
    // =========================================================================
    // Raw extracted halfwords and full instruction words before decompression
    logic [15:0] raw_hw [0:PIPE_WIDTH-1];        // raw 16-bit parcel
    logic [31:0] raw_insn [0:PIPE_WIDTH-1];      // 32-bit (either native or zero-extended)
    logic        slot_is_rvc [0:PIPE_WIDTH-1];
    logic        slot_valid [0:PIPE_WIDTH-1];
    logic [63:0] slot_pc [0:PIPE_WIDTH-1];
    logic        predecode_ctl_found;
    logic [2:0]  predecode_ctl_slot;
    logic [2:0]  predecode_ctl_type;
    logic        second_ctl_found;
    logic [2:0]  second_ctl_slot;
    logic [2:0]  second_ctl_type;
    logic [63:0] second_ctl_pc;
    logic [63:0] second_ctl_target;
    logic        ftq_pred_ctl_valid;
    logic        ftq_pred_ctl_slot_match;
    logic        ftq_pred_ctl_taken;
    logic [2:0]  ftq_pred_ctl_slot;
    logic [2:0]  ftq_pred_ctl_type;
    logic [63:0] ftq_pred_ctl_target;
    logic        pd_pred_mismatch;
    logic        owner_cond_pred_found;
    logic [2:0]  owner_cond_pred_slot;
    logic [63:0] owner_cond_pred_target;
    logic        subgroup_split_seed_c;
    logic [2:0]  subgroup_split_slot_c;
    logic [2:0]  subgroup_split_type_c;
    logic [63:0] subgroup_split_pc_c;
    logic [63:0] subgroup_split_target_c;
    logic        straddle_detected;
    logic [63:0] straddle_pc;

    instr_boundary u_instr_boundary (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .redirect_i             (redirect_valid),
        .bpu_redirect_i         (f2_bpu_redirect && !fe_stall),
        .stall_i                (fe_stall),
        .work_valid_i           (f2_work_valid_c),
        .work_pc_i              (f2_work_pc_c),
        .data_valid_i           (f2_data_valid),
        .data_line_i            (f2_data_line),
        .final_count_i          (final_count),
        .start_offset_o         (start_offset),
        .raw_hw_o               (raw_hw),
        .raw_insn_o             (raw_insn),
        .slot_is_rvc_o          (slot_is_rvc),
        .slot_valid_o           (slot_valid),
        .slot_pc_o              (slot_pc),
        .extract_count_o        (extract_count),
        .straddle_detected_o    (straddle_detected),
        .straddle_pc_o          (straddle_pc),
        .seq_valid_o            (f2_seq_valid),
        .seq_next_pc_o          (f2_seq_next_pc),
        .line_straddle_advance_o(line_straddle_advance_c),
        .consume_remainder_o    (consume_remainder_c),
        .remainder_valid_o      (remainder_valid_r)
    );

    // =========================================================================
    // RVC decompression: 6 instances (one per slot)
    // =========================================================================
    logic [31:0] decomp_out [0:PIPE_WIDTH-1];
    logic        decomp_is_rvc [0:PIPE_WIDTH-1];
    logic        decomp_illegal [0:PIPE_WIDTH-1];

    rvc_expander u_rvc_expander (
        .raw_hw_i        (raw_hw),
        .decomp_out_o    (decomp_out),
        .decomp_is_rvc_o (decomp_is_rvc),
        .decomp_illegal_o(decomp_illegal)
    );

    // =========================================================================
    // IFU predecode: derive the earliest control-flow instruction from the
    // extracted packet, compare it against the FTQ's predicted earliest CFI,
    // and compute an auxiliary branch-PC direction hint for owner conditionals.
    // The hint may be used to split the packet before the control so the next
    // request starts at the branch PC, but it must not create a live redirect
    // unless the full owner-redirect path is explicitly enabled.
    // =========================================================================
    predecode u_predecode (
        .valid_i                 (f2_work_valid_c && f2_data_valid),
        .extract_count_i         (extract_count),
        .raw_insn_i              (raw_insn),
        .decomp_insn_i           (decomp_out),
        .slot_is_rvc_i           (slot_is_rvc),
        .slot_valid_i            (slot_valid),
        .slot_pc_i               (slot_pc),
        .ras_tos_i               (ras_tos),
        .ras_pop_addr_i          (ras_pop_addr),
        .owner_tage_pred_taken_i (owner_tage_pred_taken),
        .ctl_found_o             (predecode_ctl_found),
        .ctl_slot_o              (predecode_ctl_slot),
        .ctl_type_o              (predecode_ctl_type),
        .ctl_pc_o                (predecode_ctl_pc),
        .ctl_target_o            (predecode_ctl_target),
        .second_ctl_found_o      (second_ctl_found),
        .second_ctl_slot_o       (second_ctl_slot),
        .second_ctl_type_o       (second_ctl_type),
        .second_ctl_pc_o         (second_ctl_pc),
        .second_ctl_target_o     (second_ctl_target),
        .owner_cond_pred_found_o (owner_cond_pred_found),
        .owner_cond_pred_slot_o  (owner_cond_pred_slot),
        .owner_cond_pred_target_o(owner_cond_pred_target)
    );

    pred_checker u_pred_checker (
        .clk                                      (clk),
        .rst_n                                    (rst_n),
        .valid_i                                  (f2_work_valid_c && f2_data_valid),
        .will_emit_i                              (f2_will_emit_c),
        .redirect_i                               (redirect_valid),
        .stall_i                                  (fe_stall),
        .seed_clear_i                             (redirect_valid),
        .seed_consume_i                           (!fe_stall && ic_req_valid),
        .req_pc_i                                 (req_pc_c),
        .seq_next_pc_i                            (f2_seq_next_pc),
        .work_pc_i                                (f2_work_pc_c),
        .extract_count_i                          (extract_count),
        .slot_valid_i                             (slot_valid),
        .slot_is_rvc_i                            (slot_is_rvc),
        .slot_pc_i                                (slot_pc),
        .ftq_valid_i                              (f2_work_ftq_valid_c),
        .ftq_entry_i                              (f2_work_ftq_entry_c),
        .btb_hit_i                                (f2_btb_hit_r),
        .btb_target_i                             (f2_btb_target_r),
        .btb_type_i                               (f2_btb_type_r),
        .btb_offset_i                             (f2_btb_offset_r),
        .btb_alt_hit_i                            (f2_btb_alt_hit_r),
        .btb_alt_target_i                         (f2_btb_alt_target_r),
        .btb_alt_type_i                           (f2_btb_alt_type_r),
        .btb_alt_offset_i                         (f2_btb_alt_offset_r),
        .tage_taken_i                             (f2_tage_taken_r),
        .ras_tos_i                                (ras_tos),
        .ras_pop_addr_i                           (ras_pop_addr),
        .pd_ctl_found_i                           (predecode_ctl_found),
        .pd_ctl_slot_i                            (predecode_ctl_slot),
        .pd_ctl_type_i                            (predecode_ctl_type),
        .pd_ctl_pc_i                              (predecode_ctl_pc),
        .pd_ctl_target_i                          (predecode_ctl_target),
        .second_ctl_found_i                       (second_ctl_found),
        .second_ctl_slot_i                        (second_ctl_slot),
        .second_ctl_type_i                        (second_ctl_type),
        .second_ctl_pc_i                          (second_ctl_pc),
        .second_ctl_target_i                      (second_ctl_target),
        .owner_cond_pred_found_i                  (owner_cond_pred_found),
        .subgroup_split_second_ctl_en_i           (subgroup_split_second_ctl_en),
        .subgroup_split_any_second_ctl_en_i       (subgroup_split_any_second_ctl_en),
        .subgroup_split_owner_cond_en_i           (subgroup_split_owner_cond_en),
        .subgroup_split_slot3_ftq_taken_only_en_i (subgroup_split_slot3_ftq_taken_only_en),
        .seq_valid_i                              (f2_seq_valid),
        .consume_remainder_i                      (consume_remainder_c),
        .redirect_without_owner_successor_i       (f2_redirect_without_owner_successor_c),
        .same_owner_continue_i                    (f2_same_owner_continue_c),
        .straddle_detected_i                      (straddle_detected),
        .ftq_pred_ctl_valid_o                     (ftq_pred_ctl_valid),
        .ftq_pred_ctl_slot_match_o                (ftq_pred_ctl_slot_match),
        .ftq_pred_ctl_taken_o                     (ftq_pred_ctl_taken),
        .ftq_pred_ctl_slot_o                      (ftq_pred_ctl_slot),
        .ftq_pred_ctl_type_o                      (ftq_pred_ctl_type),
        .ftq_pred_ctl_target_o                    (ftq_pred_ctl_target),
        .pd_pred_mismatch_o                       (pd_pred_mismatch),
        .bp_branch_found_o                        (bp_branch_found),
        .bp_taken_o                               (bp_taken),
        .bp_branch_slot_o                         (bp_branch_slot),
        .bp_type_o                                (bp_type),
        .bp_target_o                              (bp_target_addr),
        .subgroup_split_before_ctl_o              (subgroup_split_before_ctl_c),
        .subgroup_split_seed_o                    (subgroup_split_seed_c),
        .subgroup_split_slot_o                    (subgroup_split_slot_c),
        .subgroup_split_type_o                    (subgroup_split_type_c),
        .subgroup_split_pc_o                      (subgroup_split_pc_c),
        .subgroup_split_target_o                  (subgroup_split_target_c),
        .subgroup_seed_load_o                     (subgroup_seed_load_c),
        .subgroup_seed_pred_taken_o               (subgroup_seed_pred_taken_c),
        .subgroup_seed_hit_o                      (subgroup_seed_hit_c),
        .subgroup_seed_valid_o                    (subgroup_seed_valid_r),
        .subgroup_seed_pc_o                       (subgroup_seed_pc_r),
        .subgroup_seed_parent_pc_o                (subgroup_seed_parent_pc_r),
        .subgroup_seed_owner_pc_o                 (subgroup_seed_owner_pc_r),
        .subgroup_seed_pred_valid_o               (subgroup_seed_pred_valid_r),
        .subgroup_seed_pred_taken_state_o         (subgroup_seed_pred_taken_r),
        .subgroup_seed_pred_offset_o              (subgroup_seed_pred_offset_r),
        .subgroup_seed_pred_type_o                (subgroup_seed_pred_type_r),
        .subgroup_seed_pred_target_o              (subgroup_seed_pred_target_r),
        .final_count_o                            (final_count),
        .owner_complete_o                         (f2_work_owner_complete_c),
        .req_redirect_o                           (req_redirect_c),
        .bpu_target_o                             (f2_bpu_target),
        .ras_push_valid_o                         (ras_push_valid),
        .ras_push_addr_o                          (ras_push_addr),
        .ras_pop_valid_o                          (ras_pop_valid),
        .tage_spec_update_valid_o                 (tage_spec_update_valid),
        .tage_spec_taken_o                        (tage_spec_taken)
    );

    // A straight-line continuation within the current cache line remains part
    // of the same fetch-block owner. Allocate a new FTQ owner only at a real
    // ownership boundary: control transfer, explicit subgroup split, line end,
    // or straddle handling.
    assign f2_same_owner_continue_c =
        f2_work_valid_c &&
        f2_data_valid &&
        f2_seq_valid &&
        (final_count > 3'd0) &&
        !straddle_detected &&
        !predecode_ctl_found &&
        !subgroup_split_before_ctl_c &&
        !(bp_branch_found && bp_taken) &&
        (f2_seq_next_pc[63:LINE_BITS] == f2_work_pc_c[63:LINE_BITS]);

    // Decode no longer consumes a separate packet_buf_in bypass. Flow-through
    // is an IBuffer-owned empty-buffer delivery observation.
    assign packet_flowthrough_candidate = packet_buf_flowthrough_c;
    assign packet_flowthrough_owner_match_c =
        packet_flowthrough_candidate &&
        packet_buf_owner_match_c;
    assign packet_flowthrough_valid = packet_buf_flowthrough_c;

    assign ftq_commit_pop_valid =
        (packet_buf_deq_fire &&
         packet_buf_owner_match_c &&
         packet_buf_head_owner_complete_c);
    assign ftq_pop_valid = ftq_ifu_pop_valid;

    // =========================================================================
    // BPU redirect to F1
    // =========================================================================
    assign f2_bpu_redirect = req_redirect_c && !fe_stall;

    // =========================================================================
    // Fetch packet construction and fetch-buffered output to decode
    // =========================================================================
    instr_compact u_instr_compact (
        .will_emit_i                  (f2_will_emit_c),
        .redirect_i                   (redirect_valid),
        .frontend_hold_i              (frontend_hold),
        .ftq_idx_i                    (f2_work_ftq_idx_c),
        .ftq_epoch_i                  (f2_work_ftq_epoch_c),
        .ftq_alloc_tag_i              (f2_work_ftq_alloc_tag_c),
        .ftq_owner_complete_i         (f2_work_owner_complete_c),
        .ftq_entry_i                  (f2_work_ftq_entry_c),
        .ftq_valid_i                  (f2_work_ftq_valid_c),
        .ifu_line_addr_i              (f2_ifu_line_addr_c),
        .ifu_line_reused_i            (f2_line_state_use_c),
        .subgroup_seed_valid_i        (subgroup_seed_valid_r),
        .subgroup_seed_parent_pc_i    (subgroup_seed_parent_pc_r),
        .subgroup_seed_owner_pc_i     (subgroup_seed_owner_pc_r),
        .work_pc_i                    (f2_work_pc_c),
        .pd_ctl_found_i               (predecode_ctl_found),
        .pd_ctl_slot_i                (predecode_ctl_slot),
        .pd_ctl_type_i                (predecode_ctl_type),
        .pd_ctl_pc_i                  (predecode_ctl_pc),
        .pd_ctl_target_i              (predecode_ctl_target),
        .final_count_i                (final_count),
        .slot_valid_i                 (slot_valid),
        .raw_insn_i                   (raw_insn),
        .decomp_insn_i                (decomp_out),
        .slot_is_rvc_i                (slot_is_rvc),
        .slot_pc_i                    (slot_pc),
        .bp_branch_found_i            (bp_branch_found),
        .bp_taken_i                   (bp_taken),
        .bp_branch_slot_i             (bp_branch_slot),
        .bp_target_i                  (bp_target_addr),
        .subgroup_split_before_ctl_i  (subgroup_split_before_ctl_c),
        .ras_tos_i                    (ras_tos),
        .ras_top_i                    (ras_pop_addr),
        .ghr_i                        (f2_ghr_snapshot_r),
        .packet_enq_o                 (packet_buf_enq),
        .packet_o                     (packet_buf_in)
    );

    // =========================================================================
    // Optional fetch-path trace (debug only)
    // =========================================================================
    logic trace_fetch_en;
    logic trace_fetch_split_en;
    logic trace_fetch_dup_en;
    logic trace_fetch_owner_en;
    integer trace_fetch_cycle;
    initial begin
        trace_fetch_en = 1'b0;
        trace_fetch_split_en = 1'b0;
        trace_fetch_dup_en = 1'b0;
        trace_fetch_owner_en = 1'b0;
        if ($test$plusargs("TRACE_FETCH")) trace_fetch_en = 1'b1;
        if ($test$plusargs("TRACE_FETCH_SPLIT")) trace_fetch_split_en = 1'b1;
        if ($test$plusargs("FETCH_DUP_TRACE")) trace_fetch_dup_en = 1'b1;
        if ($test$plusargs("TRACE_FETCH_OWNER")) trace_fetch_owner_en = 1'b1;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            trace_fetch_cycle <= 0;
        end else begin
            trace_fetch_cycle <= trace_fetch_cycle + 1;
            if (trace_fetch_en &&
                ((trace_fetch_cycle < 600) ||
                 ((f1_pc >= 64'h0000_0000_8000_2000) &&
                  (f1_pc <  64'h0000_0000_8000_2470)) ||
                 ((f1_pc >= 64'h0000_0000_8000_2500) &&
                  (f1_pc <  64'h0000_0000_8000_2560)) ||
                 ((f1_pc >= 64'h0000_0000_8000_3100) &&
                  (f1_pc <  64'h0000_0000_8000_3400)) ||
                 ((f1_pc >= 64'h0000_0000_8000_39f0) &&
                  (f1_pc <  64'h0000_0000_8000_3a80)) ||
                 ((f2_work_pc_c >= 64'h0000_0000_8000_2000) &&
                  (f2_work_pc_c <  64'h0000_0000_8000_2470)) ||
                 ((f2_work_pc_c >= 64'h0000_0000_8000_2500) &&
                  (f2_work_pc_c <  64'h0000_0000_8000_2560)) ||
                 ((f2_work_pc_c >= 64'h0000_0000_8000_3100) &&
                  (f2_work_pc_c <  64'h0000_0000_8000_3400)) ||
                 ((f2_work_pc_c >= 64'h0000_0000_8000_39f0) &&
                  (f2_work_pc_c <  64'h0000_0000_8000_3a80)))) begin
                $display("[FETCH] cyc=%0d f1_pc=%016h ic_req_v=%b ic_req=%016h ic_resp_v=%b ic_hit=%b nlpb_hit=%b f2_v=%b f2_pc=%016h f2_hit=%b f2_type=%0d f2_off=%0d f2_alt_hit=%b f2_alt_type=%0d f2_alt_off=%0d ext=%0d final=%0d emit=%b dup=%b seq_v=%b seq_pc=%016h line_reuse=%b bp=%b bp_taken=%b bp_type=%0d bp_slot=%0d bp_tgt=%016h pd_v=%b pd_slot=%0d pd_type=%0d pd_tgt=%016h ftq_pred_v=%b ftq_pred_t=%b ftq_pred_slot=%0d ftq_pred_type=%0d ftq_sub=%b pd_mm=%b sg_v=%b sg_pc=%016h sg_t=%b sg_parent=%016h sg_owner=%016h ras_tos=%0d ras_push=%b ras_push_addr=%016h ras_pop=%b ras_pop_addr=%016h redir=%b redir_pc=%016h cmt_redir=%b cmt_pc=%016h rem_v=%b cons_rem=%b consd_rem=%b ftq_need=%b ftq_enq=%b ftq_enq_tag=%0d ftq_pop=%b ftq_cnt=%0d ftq_head_v=%b ftq_head=%0d ftq_head_tag=%0d f2_ftq_v=%b f2_ftq=%0d f2_ftq_tag=%0d f2_ftq_blk=%016h pkt_live=%b pkt_ftq_tag=%0d fe_hold=%b fe_stall=%b fetch_out=%0d",
                    trace_fetch_cycle,
                    f1_pc,
                    ic_req_valid,
                    ic_req_addr,
                    ic_resp_valid,
                    ic_resp_hit,
                    nlpb_hit_comb,
                    f2_work_valid_c,
                    f2_work_pc_c,
                    f2_btb_hit_r,
                    f2_btb_type_r,
                    f2_btb_offset_r,
                    f2_btb_alt_hit_r,
                    f2_btb_alt_type_r,
                    f2_btb_alt_offset_r,
                    extract_count,
                    final_count,
                    f2_will_emit_c,
                    f2_duplicate_suppressed_c,
                    f2_seq_valid,
                    f2_seq_next_pc,
                    f2_line_state_use_c,
                    bp_branch_found,
                    bp_taken,
                    bp_type,
                    bp_branch_slot,
                    bp_target_addr,
                    predecode_ctl_found,
                    predecode_ctl_slot,
                    predecode_ctl_type,
                    predecode_ctl_target,
                    ftq_pred_ctl_valid,
                    ftq_pred_ctl_taken,
                    ftq_pred_ctl_slot,
                    ftq_pred_ctl_type,
                    f2_work_ftq_entry_c.pred_from_subgroup,
                    pd_pred_mismatch,
                    subgroup_seed_valid_r,
                    subgroup_seed_pc_r,
                    subgroup_seed_pred_taken_r,
                    subgroup_seed_parent_pc_r,
                    subgroup_seed_owner_pc_r,
                    ras_tos,
                    ras_push_valid,
                    ras_push_addr,
                    ras_pop_valid,
                    ras_pop_addr,
                    f2_bpu_redirect,
                    f2_bpu_target,
                    redirect_valid,
                    redirect_pc,
                    remainder_valid_r,
                    consume_remainder_c,
                    consumed_remainder_r,
                    ftq_need_alloc_c,
                    ftq_enq_valid,
                    ftq_enq_tag,
                    ftq_pop_valid,
                    ftq_count,
                    ftq_head_valid,
                    ftq_head_idx,
                    ftq_head_tag,
                    f2_work_ftq_valid_c,
                    f2_work_ftq_idx_c,
                    f2_work_ftq_alloc_tag_c,
                    f2_work_ftq_entry_c.block_pc,
                    packet_buf_owner_match_c,
                    packet_buf_valid ? packet_buf_head.ftq_alloc_tag : '0,
                    frontend_hold,
                    fe_stall,
                    fetch_count);
            end
            if (trace_fetch_dup_en &&
                f2_has_emit_payload_c &&
                !f2_will_emit_c) begin
                $display("[FETCH_DUP] cyc=%0d pc=%016h last_v=%b last_pc=%016h last_next=%016h replay_hit=%b replay_pc=%016h replay_age=%0d seq_v=%b seq=%016h ext=%0d final=%0d f2_ftq_v=%b f2_ftq=%0d f2_tag=%0d block=%016h pred_v=%b pred_t=%b pred_off=%0d pred_type=%0d pred_target=%016h pd_v=%b pd_slot=%0d pd_type=%0d pd_target=%016h bp=%b bp_taken=%b bp_slot=%0d bp_type=%0d bp_target=%016h rem_v=%b straddle=%b fe_stall=%b fe_hold=%b pkt_v=%b pkt_tag=%0d ftq_head_v=%b ftq_head=%0d ftq_head_tag=%0d ftq_cnt=%0d fetch_out=%0d out_pc0=%016h out_pc1=%016h out_pc2=%016h out_pc3=%016h",
                    trace_fetch_cycle,
                    f2_work_pc_c,
                    f2_last_emit_valid_r,
                    f2_last_emit_pc_r,
                    f2_last_emit_next_pc_r,
                    f2_replay_block_hit_c,
                    f2_replay_block_pc_r,
                    f2_replay_block_age_r,
                    f2_seq_valid,
                    f2_seq_next_pc,
                    extract_count,
                    final_count,
                    f2_work_ftq_valid_c,
                    f2_work_ftq_idx_c,
                    f2_work_ftq_alloc_tag_c,
                    f2_work_ftq_entry_c.block_pc,
                    f2_work_ftq_entry_c.pred_ctl_valid,
                    f2_work_ftq_entry_c.pred_ctl_taken,
                    f2_work_ftq_entry_c.pred_ctl_offset,
                    f2_work_ftq_entry_c.pred_ctl_type,
                    f2_work_ftq_entry_c.pred_ctl_target,
                    predecode_ctl_found,
                    predecode_ctl_slot,
                    predecode_ctl_type,
                    predecode_ctl_target,
                    bp_branch_found,
                    bp_taken,
                    bp_branch_slot,
                    bp_type,
                    bp_target_addr,
                    remainder_valid_r,
                    straddle_detected,
                    fe_stall,
                    frontend_hold,
                    packet_buf_valid,
                    packet_buf_valid ? packet_buf_head.ftq_alloc_tag : '0,
                    ftq_head_valid,
                    ftq_head_idx,
                    ftq_head_tag,
                    ftq_count,
                    fetch_count,
                    fetch_pc[0],
                    fetch_pc[1],
                    fetch_pc[2],
                    fetch_pc[3]);
            end
            if (trace_fetch_owner_en &&
                f2_owner_completion_candidate_c &&
                !f2_ftq_owner_live_c) begin
                $display("[FETCH_OWNER_TRACE] cyc=%0d pc=%016h seq=%016h final=%0d straddle=%b bp=%b bp_taken=%b bp_slot=%0d bp_type=%0d target=%016h work_idx=%0d work_tag=%0d wb_valid=%b wb_idx=%0d wb_tag=%0d ftq_cnt=%0d ftq_alloc_to_ifu=%0d ftq_ifu_to_wb=%0d ftq_ifu_to_commit=%0d icq_valid=%b icq_line=%014h line_reuse=%b pkt_valid=%b pkt_match=%b pkt_complete=%b fetch_out=%0d out_pc0=%016h",
                    trace_fetch_cycle,
                    f2_work_pc_c,
                    f2_seq_next_pc,
                    final_count,
                    straddle_detected,
                    bp_branch_found,
                    bp_taken,
                    bp_branch_slot,
                    bp_type,
                    bp_target_addr,
                    f2_work_ftq_idx_c,
                    f2_work_ftq_alloc_tag_c,
                    ftq_ifu_wb_owner_valid,
                    ftq_ifu_wb_owner_idx,
                    ftq_ifu_wb_owner_tag,
                    ftq_count,
                    ftq_count_alloc_to_ifu,
                    ftq_count_ifu_to_wb,
                    ftq_count_ifu_to_commit,
                    icq_deq_valid,
                    icq_deq_line_addr,
                    f2_line_state_use_c,
                    packet_buf_valid,
                    packet_buf_owner_match_c,
                    packet_buf_head_owner_complete_c,
                    fetch_count,
                    fetch_pc[0]);
            end
            if (trace_fetch_split_en && subgroup_seed_load_c) begin
                $display("[FETCH_SPLIT] cyc=%0d parent_pc=%016h split_pc=%016h split_tgt=%016h split_slot=%0d split_type=%0d reason=%s pre_pc=%016h pre_tgt=%016h second_pc=%016h second_tgt=%016h ftq_pred_v=%b ftq_pred_t=%b ftq_pred_slot=%0d ftq_pred_type=%0d owner_pred=%b bp_found=%b bp_taken=%b bp_slot=%0d final=%0d ext=%0d",
                    trace_fetch_cycle,
                    f2_work_pc_c,
                    subgroup_split_pc_c,
                    subgroup_split_target_c,
                    subgroup_split_slot_c,
                    subgroup_split_type_c,
                    subgroup_split_seed_c ? "owner" : "second",
                    predecode_ctl_pc,
                    predecode_ctl_target,
                    second_ctl_pc,
                    second_ctl_target,
                    ftq_pred_ctl_valid,
                    ftq_pred_ctl_taken,
                    ftq_pred_ctl_slot,
                    ftq_pred_ctl_type,
                    owner_cond_pred_found,
                    bp_branch_found,
                    bp_taken,
                    bp_branch_slot,
                    final_count,
                    extract_count);
            end
        end
    end

    // ====================================================================
    // Pipeline timing invariants (SVA assertions)
    // ====================================================================
    // Codifies the timing relationships that the current design depends
    // on. Any RTL change that violates one fires immediately during
    // simulation, telling us which invariant the change broke before
    // benchmarks run. This is the "design validation" layer the harness
    // was missing -- counters tell WHAT is wrong; assertions tell WHICH
    // architectural property the change violated.
    //
    // Per AGENTS.md SVA discipline: gated on `ifndef SYNTHESIS` so they
    // only fire in simulation; cleared during reset and 1 cycle after
    // redirect_valid (when state is in transition).

`ifndef SYNTHESIS

    // Invariant A: any queue response accepted by the IFU work cursor must name
    // the same physical cache line as the current work PC. A queued response may
    // be older than the current request pipe once response elasticity exists, so
    // the response-line metadata is the authoritative timing source here.
    property p_f2_pc_matches_resp_source;
        @(posedge clk) disable iff (!rst_n || redirect_valid ||
                                     consumed_remainder_r)
        (ic_resp_valid && f2_work_line_valid_c) |->
        (f2_work_line_addr_c == icq_deq_line_addr);
    endproperty
    a_f2_pc_matches_resp_source: assert property (p_f2_pc_matches_resp_source)
        else $error("[INVARIANT_A] IFU work/data line mismatch: work_line=%014h work_pc=%016h icq_line=%014h",
                    f2_work_line_addr_c, f2_work_pc_c, icq_deq_line_addr);

    // Invariant B: the IFU work owner's epoch must equal current FTQ epoch when
    // the work cursor has a valid owner. A stale epoch means the frontend is
    // processing data from a flushed FTQ entry. The owner epoch mismatch counter
    // tracks this; this assertion makes the counter movement a hard correctness
    // property.
    property p_f2_owner_epoch_current;
        @(posedge clk) disable iff (!rst_n || redirect_valid)
        f2_work_ftq_valid_c |->
        (f2_work_ftq_epoch_c == ftq_current_epoch);
    endproperty
    a_f2_owner_epoch_current: assert property (p_f2_owner_epoch_current)
        else $error("[INVARIANT_B] IFU work owner epoch stale: work_epoch=%h ftq_epoch=%h",
                    f2_work_ftq_epoch_c, ftq_current_epoch);

    // Invariant C: when F2 emits, f2_pc_consumed_c must be 1 (semantic
    // tautology that catches any future change accidentally clearing
    // f2_pc_consumed_c on emit, which would break F1's case 4 advance).
    property p_emit_implies_consumed;
        @(posedge clk) disable iff (!rst_n || redirect_valid)
        f2_will_emit_c |-> f2_pc_consumed_c;
    endproperty
    a_emit_implies_consumed: assert property (p_emit_implies_consumed)
        else $error("[INVARIANT_C] F2 emitted but pc_consumed_c=0");

    // Invariant D: an accepted queue head must match the line of the IFU work
    // cursor. A future-line queue head may be visible while the frontend is
    // consuming the local line-state record, but it must not be popped or used
    // as data.
    property p_queue_pc_matches_f2;
        @(posedge clk) disable iff (!rst_n || redirect_valid)
        (ic_resp_valid && f2_work_line_valid_c) |->
        (icq_deq_line_addr == f2_work_line_addr_c);
    endproperty
    a_queue_pc_matches_f2: assert property (p_queue_pc_matches_f2)
        else $error("[INVARIANT_D] queue line/IFU work line mismatch: deq_line=%014h work_line=%014h work_pc=%016h",
                    icq_deq_line_addr, f2_work_line_addr_c, f2_work_pc_c);

    // Invariant D1: when an ICQ head names the current FTQ IFU-writeback
    // owner, its carried FTQ entry snapshot must match the FTQ owner view. This
    // proves the response queue has a coherent request object before the IFU
    // cursor starts consuming entries directly from it.
    property p_icq_owner_entry_matches_ftq_wb;
        @(posedge clk) disable iff (!rst_n || redirect_valid)
        icq_deq_owner_match_c |->
        (icq_deq_ftq_entry == ftq_ifu_wb_owner_entry);
    endproperty
    a_icq_owner_entry_matches_ftq_wb:
        assert property (p_icq_owner_entry_matches_ftq_wb)
        else $error("[INVARIANT_D1] ICQ carried FTQ entry mismatch: deq_idx=%h deq_tag=%h wb_idx=%h wb_tag=%h",
                    icq_deq_ftq_idx,
                    icq_deq_ftq_alloc_tag,
                    ftq_ifu_wb_owner_idx,
                    ftq_ifu_wb_owner_tag);

    // Invariant D2: if the frontend is reusing a same-line response, the
    // line-state record must still name the same line as the work cursor's PC.
    property p_same_line_reuse_has_line_state;
        @(posedge clk) disable iff (!rst_n || redirect_valid)
        f2_line_state_use_c |->
        (f2_line_state_valid_c &&
         f2_work_line_valid_c &&
         (f2_line_state_addr_c == f2_work_line_addr_c) &&
         (f2_line_state_epoch_c == ftq_current_epoch));
    endproperty
    a_same_line_reuse_has_line_state:
        assert property (p_same_line_reuse_has_line_state)
        else $error("[INVARIANT_D2] same-line reuse missing line state: state_v=%b state_line=%014h work_line=%014h work_pc=%016h state_epoch=%h ftq_epoch=%h",
                    f2_line_state_valid_c,
                    f2_line_state_addr_c,
                    f2_work_line_addr_c,
                    f2_work_pc_c,
                    f2_line_state_epoch_c,
                    ftq_current_epoch);

    // Invariant D3: the IFU work cursor's cached line identity must describe
    // the cursor PC while the cursor is valid. This replaces the retired raw
    // F2 mirror-register check and keeps the cursor as the single F2 work
    // state until later runahead slices intentionally advance it independently.
    property p_ifu_work_cursor_line_self_consistent;
        @(posedge clk) disable iff (!rst_n || redirect_valid)
        (f2_work_line_valid_c == f2_work_valid_c) &&
        (!f2_work_valid_c ||
         (f2_work_line_addr_c == f2_work_pc_c[63:LINE_BITS]));
    endproperty
    a_ifu_work_cursor_line_self_consistent:
        assert property (p_ifu_work_cursor_line_self_consistent)
        else $error("[INVARIANT_D3] IFU work cursor line identity mismatch: valid=%b line_valid=%b pc=%016h line=%014h",
                    f2_work_valid_c,
                    f2_work_line_valid_c,
                    f2_work_pc_c,
                    f2_work_line_addr_c);

    // Invariant E: the FTQ IFU-writeback pointer may advance only when the IFU
    // work owner being completed is the current IFU-writeback owner. Plain F2
    // packet emission can be ahead of or behind the writeback pointer while
    // same-line data sharing and IBuffer delivery are still monolithic.
    property p_f2_pop_matches_ftq_wb_owner;
        @(posedge clk) disable iff (!rst_n || redirect_valid)
        ftq_ifu_pop_valid |->
        (f2_work_ftq_valid_c &&
         ftq_ifu_wb_owner_valid &&
         (f2_work_ftq_idx_c == ftq_ifu_wb_owner_idx) &&
         (f2_work_ftq_epoch_c == ftq_current_epoch) &&
         (f2_work_ftq_alloc_tag_c == ftq_ifu_wb_owner_tag));
    endproperty
    a_f2_pop_matches_ftq_wb_owner:
        assert property (p_f2_pop_matches_ftq_wb_owner)
        else $error("[INVARIANT_E] IFU work FTQ pop owner mismatch: work_idx=%h work_tag=%h wb_idx=%h wb_tag=%h",
                    f2_work_ftq_idx_c,
                    f2_work_ftq_alloc_tag_c,
                    ftq_ifu_wb_owner_idx,
                    ftq_ifu_wb_owner_tag);

    // Invariant E2: a completed IFU work item that is not the current FTQ
    // IFU-writeback owner must remain blocked from popping the FTQ. The
    // candidate counters expose this residual skew; the invariant protects the
    // structural guard while later slices remove the skew itself.
    property p_f2_wrong_owner_completion_candidate_does_not_pop;
        @(posedge clk) disable iff (!rst_n || redirect_valid)
        (f2_owner_completion_candidate_c && !f2_ftq_owner_live_c) |->
        !ftq_ifu_pop_valid;
    endproperty
    a_f2_wrong_owner_completion_candidate_does_not_pop:
        assert property (p_f2_wrong_owner_completion_candidate_does_not_pop)
        else $error("[INVARIANT_E2] wrong-owner IFU completion candidate popped FTQ: work_idx=%h work_tag=%h wb_valid=%b wb_idx=%h wb_tag=%h",
                    f2_work_ftq_idx_c,
                    f2_work_ftq_alloc_tag_c,
                    ftq_ifu_wb_owner_valid,
                    ftq_ifu_wb_owner_idx,
                    ftq_ifu_wb_owner_tag);

    // Invariant F: the IFU request-pop into the FTQ must be a real
    // allocation/request handshake. This keeps request-owner progress tied to
    // FTQ enqueue readiness and downstream response/IBuffer capacity.
    property p_ifu_req_pop_is_ready_enq;
        @(posedge clk) disable iff (!rst_n || redirect_valid)
        ftq_ifu_req_pop_valid |->
        (ftq_enq_valid && ftq_enq_ready && !icq_full && !packet_buf_full);
    endproperty
    a_ifu_req_pop_is_ready_enq:
        assert property (p_ifu_req_pop_is_ready_enq)
        else $error("[INVARIANT_F] IFU request-pop without ready enqueue: enq_v=%b enq_r=%b icq_full=%b pkt_full=%b",
                    ftq_enq_valid,
                    ftq_enq_ready,
                    icq_full,
                    packet_buf_full);

    // Invariant G: when the cursor policy selects the FTQ next IFU-writeback
    // owner, the registered cursor must load that owner identity and the
    // cursor-computed next PC on the following cycle.
    property p_ifu_cursor_loads_ftq_next_owner;
        @(posedge clk) disable iff (!rst_n || redirect_valid)
        ifu_work_take_ftq_next_owner_c |=>
        (f2_work_valid_c &&
         f2_work_ftq_valid_c &&
         (f2_work_pc_c == $past(f2_seq_next_pc)) &&
         (f2_work_ftq_idx_c == $past(ftq_next_ifu_owner_idx)) &&
         (f2_work_ftq_epoch_c == $past(ftq_current_epoch)) &&
         (f2_work_ftq_alloc_tag_c == $past(ftq_next_ifu_owner_tag)));
    endproperty
    a_ifu_cursor_loads_ftq_next_owner:
        assert property (p_ifu_cursor_loads_ftq_next_owner)
        else $error("[INVARIANT_G] IFU cursor failed FTQ next-owner load: pc=%016h idx=%h tag=%h",
                    f2_work_pc_c,
                    f2_work_ftq_idx_c,
                    f2_work_ftq_alloc_tag_c);

    // Invariant H: if a redirect target is already the FTQ next owner, the
    // redirect handoff must load that next-owner identity rather than relying
    // on direct request-allocation metadata.
    property p_ifu_redirect_loads_matching_next_owner;
        @(posedge clk) disable iff (!rst_n || redirect_valid)
        ifu_work_redirect_next_owner_match_c |=>
        (f2_work_valid_c &&
         f2_work_ftq_valid_c &&
         (f2_work_pc_c == $past(f2_bpu_target)) &&
         (f2_work_ftq_idx_c == $past(ftq_next_ifu_owner_idx)) &&
         (f2_work_ftq_epoch_c == $past(ftq_current_epoch)) &&
         (f2_work_ftq_alloc_tag_c == $past(ftq_next_ifu_owner_tag)));
    endproperty
    a_ifu_redirect_loads_matching_next_owner:
        assert property (p_ifu_redirect_loads_matching_next_owner)
        else $error("[INVARIANT_H] IFU redirect failed matching next-owner load: pc=%016h idx=%h tag=%h",
                    f2_work_pc_c,
                    f2_work_ftq_idx_c,
                    f2_work_ftq_alloc_tag_c);

`endif

endmodule

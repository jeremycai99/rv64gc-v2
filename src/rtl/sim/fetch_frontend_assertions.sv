/* file: fetch_frontend_assertions.sv
 Description: Simulation-only frontend timing invariants.
 Author: Jeremy Cai
 Date: May 07, 2026
 Version: 1.0
*/
`ifdef SIMULATION
module fetch_frontend_assertions
    import rv64gc_pkg::*;
    import uarch_pkg::*;
(
    input logic                             clk,
    input logic                             rst_n,
    input logic                             redirect_valid,
    input logic                             consumed_remainder_r,
    input logic                             ic_resp_valid,
    input logic                             f2_work_line_valid_c,
    input logic [63:LINE_BITS]              f2_work_line_addr_c,
    input logic [63:LINE_BITS]              icq_deq_line_addr,
    input logic [63:0]                      f2_work_pc_c,
    input logic                             f2_work_ftq_valid_c,
    input logic [FTQ_EPOCH_BITS-1:0]        f2_work_ftq_epoch_c,
    input logic [FTQ_EPOCH_BITS-1:0]        ftq_current_epoch,
    input logic                             f2_will_emit_c,
    input logic                             f2_pc_consumed_c,
    input logic                             icq_deq_owner_match_c,
    input ftq_entry_t                       icq_deq_ftq_entry,
    input ftq_entry_t                       ftq_ifu_wb_owner_entry,
    input logic [FTQ_IDX_BITS-1:0]          icq_deq_ftq_idx,
    input logic [FTQ_ALLOC_TAG_BITS-1:0]    icq_deq_ftq_alloc_tag,
    input logic [FTQ_IDX_BITS-1:0]          ftq_ifu_wb_owner_idx,
    input logic [FTQ_ALLOC_TAG_BITS-1:0]    ftq_ifu_wb_owner_tag,
    input logic                             f2_line_state_use_c,
    input logic                             f2_line_state_valid_c,
    input logic [63:LINE_BITS]              f2_line_state_addr_c,
    input logic [FTQ_EPOCH_BITS-1:0]        f2_line_state_epoch_c,
    input logic                             f2_work_valid_c,
    input logic                             ftq_ifu_pop_valid,
    input logic                             ftq_ifu_wb_owner_valid,
    input logic [FTQ_IDX_BITS-1:0]          f2_work_ftq_idx_c,
    input logic [FTQ_ALLOC_TAG_BITS-1:0]    f2_work_ftq_alloc_tag_c,
    input logic                             f2_owner_delivery_push_c,
    input fetch_packet_t                    packet_buf_in,
    input logic                             f2_owner_completion_candidate_c,
    input logic                             f2_ftq_owner_live_c,
    input logic                             ftq_ifu_req_pop_valid,
    input logic                             ftq_enq_valid,
    input logic                             ftq_enq_ready,
    input logic                             icq_full,
    input logic                             packet_buf_full,
    input logic                             ifu_work_take_ftq_next_owner_c,
    input logic                             ifu_work_take_request_owner_c,
    input logic                             ifu_work_take_remainder_request_owner_c,
    input logic [63:0]                      f2_seq_next_pc,
    input logic [FTQ_IDX_BITS-1:0]          ftq_next_ifu_owner_idx,
    input logic [FTQ_ALLOC_TAG_BITS-1:0]    ftq_next_ifu_owner_tag,
    input logic                             ftq_next_ifu_owner_valid,
    input ftq_entry_t                       ftq_next_ifu_owner_entry,
    input logic                             ifu_work_redirect_next_owner_match_c,
    input logic [63:0]                      f2_bpu_target,
    input logic                             ifu_work_same_owner_advance_c,
    input logic [FTQ_IDX_BITS:0]            ftq_count_alloc_to_ifu,
    input logic [FTQ_IDX_BITS:0]            ftq_count_ifu_to_wb,
    input logic                             ifu_runahead_req_fire_c,
    input logic                             ifu_runahead_cancel_next_c,
    input logic                             ifu_runahead_pending_c,
    input logic [63:0]                      ifu_runahead_pending_pc_c,
    input logic [FTQ_IDX_BITS-1:0]          ifu_runahead_pending_idx_c,
    input logic [FTQ_EPOCH_BITS-1:0]        ifu_runahead_pending_epoch_c,
    input logic [FTQ_ALLOC_TAG_BITS-1:0]    ifu_runahead_pending_tag_c,
    input logic                             ifu_runahead_duplicate_alloc_blocked_c,
    input logic                             ifu_runahead_depth_gt1_c
);

    logic [63:0] ftq_next_owner_start_pc_c;

    assign ftq_next_owner_start_pc_c =
        ftq_next_ifu_owner_entry.block_pc +
        64'(ftq_next_ifu_owner_entry.start_offset);

    property p_f2_pc_matches_resp_source;
        @(posedge clk) disable iff (!rst_n || redirect_valid ||
                                     consumed_remainder_r)
        (ic_resp_valid && f2_work_line_valid_c) |->
        (f2_work_line_addr_c == icq_deq_line_addr);
    endproperty
    a_f2_pc_matches_resp_source: assert property (p_f2_pc_matches_resp_source)
        else $error("[INVARIANT_A] IFU work/data line mismatch: work_line=%014h work_pc=%016h icq_line=%014h",
                    f2_work_line_addr_c, f2_work_pc_c, icq_deq_line_addr);

    property p_f2_owner_epoch_current;
        @(posedge clk) disable iff (!rst_n || redirect_valid)
        f2_work_ftq_valid_c |->
        (f2_work_ftq_epoch_c == ftq_current_epoch);
    endproperty
    a_f2_owner_epoch_current: assert property (p_f2_owner_epoch_current)
        else $error("[INVARIANT_B] IFU work owner epoch stale: work_epoch=%h ftq_epoch=%h",
                    f2_work_ftq_epoch_c, ftq_current_epoch);

    property p_emit_implies_consumed;
        @(posedge clk) disable iff (!rst_n || redirect_valid)
        f2_will_emit_c |-> f2_pc_consumed_c;
    endproperty
    a_emit_implies_consumed: assert property (p_emit_implies_consumed)
        else $error("[INVARIANT_C] F2 emitted but pc_consumed_c=0");

    property p_queue_pc_matches_f2;
        @(posedge clk) disable iff (!rst_n || redirect_valid)
        (ic_resp_valid && f2_work_line_valid_c) |->
        (icq_deq_line_addr == f2_work_line_addr_c);
    endproperty
    a_queue_pc_matches_f2: assert property (p_queue_pc_matches_f2)
        else $error("[INVARIANT_D] queue line/IFU work line mismatch: deq_line=%014h work_line=%014h work_pc=%016h",
                    icq_deq_line_addr, f2_work_line_addr_c, f2_work_pc_c);

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

    property p_ifu_cursor_loads_ftq_next_owner;
        @(posedge clk) disable iff (!rst_n || redirect_valid)
        ifu_work_take_ftq_next_owner_c |=>
        (f2_work_valid_c &&
         f2_work_ftq_valid_c &&
         (f2_work_pc_c == $past(ftq_next_owner_start_pc_c)) &&
         (f2_work_ftq_idx_c == $past(ftq_next_ifu_owner_idx)) &&
         (f2_work_ftq_epoch_c == $past(ftq_current_epoch)) &&
         (f2_work_ftq_alloc_tag_c == $past(ftq_next_ifu_owner_tag)));
    endproperty
    a_ifu_cursor_loads_ftq_next_owner:
        assert property (p_ifu_cursor_loads_ftq_next_owner)
        else $error("[INVARIANT_G] IFU cursor failed FTQ next-owner load: pc=%016h expected_start=%016h idx=%h tag=%h",
                    f2_work_pc_c,
                    $past(ftq_next_owner_start_pc_c),
                    f2_work_ftq_idx_c,
                    f2_work_ftq_alloc_tag_c);

    property p_first_owner_packet_starts_at_owner_pc;
        @(posedge clk) disable iff (!rst_n || redirect_valid)
        f2_owner_delivery_push_c |->
        (packet_buf_in.valid &&
         (packet_buf_in.fetch_count != 3'd0) &&
         (packet_buf_in.fetch_pc[0] ==
          (packet_buf_in.ftq_block_pc +
           64'(packet_buf_in.ftq_start_offset))));
    endproperty
    a_first_owner_packet_starts_at_owner_pc:
        assert property (p_first_owner_packet_starts_at_owner_pc)
        else $error("[INVARIANT_G1] first owner packet does not start at FTQ owner PC: pc0=%016h owner_start=%016h idx=%h tag=%h",
                    packet_buf_in.fetch_pc[0],
                    packet_buf_in.ftq_block_pc +
                    64'(packet_buf_in.ftq_start_offset),
                    packet_buf_in.ftq_idx,
                    packet_buf_in.ftq_alloc_tag);

    property p_first_owner_packet_matches_work_owner;
        @(posedge clk) disable iff (!rst_n || redirect_valid)
        f2_owner_delivery_push_c |->
        (packet_buf_in.valid &&
         (packet_buf_in.ftq_idx == f2_work_ftq_idx_c) &&
         (packet_buf_in.ftq_epoch == f2_work_ftq_epoch_c) &&
         (packet_buf_in.ftq_alloc_tag == f2_work_ftq_alloc_tag_c));
    endproperty
    a_first_owner_packet_matches_work_owner:
        assert property (p_first_owner_packet_matches_work_owner)
        else $error("[INVARIANT_G2] first owner packet metadata does not match IFU work owner: pkt_idx=%h pkt_tag=%h work_idx=%h work_tag=%h",
                    packet_buf_in.ftq_idx,
                    packet_buf_in.ftq_alloc_tag,
                    f2_work_ftq_idx_c,
                    f2_work_ftq_alloc_tag_c);

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

    property p_ifu_same_owner_advance_keeps_owner;
        @(posedge clk) disable iff (!rst_n || redirect_valid)
        ifu_work_same_owner_advance_c |=>
        ((ftq_current_epoch != $past(ftq_current_epoch)) ||
        (f2_work_valid_c &&
         f2_work_ftq_valid_c &&
         (f2_work_pc_c == $past(f2_seq_next_pc)) &&
         (f2_work_ftq_idx_c == $past(f2_work_ftq_idx_c)) &&
         (f2_work_ftq_epoch_c == $past(f2_work_ftq_epoch_c)) &&
         (f2_work_ftq_alloc_tag_c == $past(f2_work_ftq_alloc_tag_c))));
    endproperty
    a_ifu_same_owner_advance_keeps_owner:
        assert property (p_ifu_same_owner_advance_keeps_owner)
        else $error("[INVARIANT_I] IFU same-owner advance lost owner: pc=%016h exp_pc=%016h idx=%h exp_idx=%h epoch=%h exp_epoch=%h tag=%h exp_tag=%h take_next=%b take_req=%b take_rem=%b",
                    f2_work_pc_c,
                    $past(f2_seq_next_pc),
                    f2_work_ftq_idx_c,
                    $past(f2_work_ftq_idx_c),
                    f2_work_ftq_epoch_c,
                    $past(f2_work_ftq_epoch_c),
                    f2_work_ftq_alloc_tag_c,
                    $past(f2_work_ftq_alloc_tag_c),
                    $past(ifu_work_take_ftq_next_owner_c),
                    $past(ifu_work_take_request_owner_c),
                    $past(ifu_work_take_remainder_request_owner_c));

    property p_runahead_depth_is_bounded;
        @(posedge clk) disable iff (!rst_n || redirect_valid)
        !ifu_runahead_depth_gt1_c &&
        (({1'b0, ftq_count_alloc_to_ifu} +
          {1'b0, ftq_count_ifu_to_wb}) <= (FTQ_IDX_BITS+2)'(2));
    endproperty
    a_runahead_depth_is_bounded:
        assert property (p_runahead_depth_is_bounded)
        else $error("[INVARIANT_J] demand runahead depth exceeded: alloc_to_ifu=%0d ifu_to_wb=%0d",
                    ftq_count_alloc_to_ifu,
                    ftq_count_ifu_to_wb);

    property p_runahead_pending_matches_next_owner;
        @(posedge clk) disable iff (!rst_n || redirect_valid)
        (ifu_runahead_pending_c &&
         (ifu_runahead_pending_pc_c != 64'd0)) |->
        (redirect_valid ||
         ifu_runahead_cancel_next_c ||
         ifu_work_redirect_next_owner_match_c ||
         (ftq_next_ifu_owner_valid &&
         (ftq_next_ifu_owner_idx == ifu_runahead_pending_idx_c) &&
         (ftq_current_epoch == ifu_runahead_pending_epoch_c) &&
         (ftq_next_ifu_owner_tag == ifu_runahead_pending_tag_c) &&
         (ftq_next_ifu_owner_entry.block_pc ==
          {ifu_runahead_pending_pc_c[63:LINE_BITS], {LINE_BITS{1'b0}}}) &&
         (ftq_next_ifu_owner_entry.start_offset ==
          ifu_runahead_pending_pc_c[5:0])));
    endproperty
    a_runahead_pending_matches_next_owner:
        assert property (p_runahead_pending_matches_next_owner)
        else $error("[INVARIANT_K] runahead pending owner does not match FTQ next owner: pc=%016h idx=%h tag=%h",
                    ifu_runahead_pending_pc_c,
                    ifu_runahead_pending_idx_c,
                    ifu_runahead_pending_tag_c);

    property p_redirect_match_does_not_enqueue_duplicate;
        @(posedge clk) disable iff (!rst_n || redirect_valid)
        ifu_work_redirect_next_owner_match_c |-> !ftq_enq_valid;
    endproperty
    a_redirect_match_does_not_enqueue_duplicate:
        assert property (p_redirect_match_does_not_enqueue_duplicate)
        else $error("[INVARIANT_L] redirect consumed existing next owner and also enqueued duplicate");

    property p_runahead_future_owner_not_current_work;
        @(posedge clk) disable iff (!rst_n || redirect_valid)
        (ifu_runahead_pending_c &&
         f2_work_ftq_valid_c &&
         (f2_work_ftq_idx_c == ifu_runahead_pending_idx_c) &&
         (f2_work_ftq_alloc_tag_c == ifu_runahead_pending_tag_c)) |->
        ifu_work_redirect_next_owner_match_c;
    endproperty
    a_runahead_future_owner_not_current_work:
        assert property (p_runahead_future_owner_not_current_work)
        else $error("[INVARIANT_M] future runahead owner became current IFU work before redirect: pc=%016h pending_pc=%016h idx=%h tag=%h",
                    f2_work_pc_c,
                    ifu_runahead_pending_pc_c,
                    ifu_runahead_pending_idx_c,
                    ifu_runahead_pending_tag_c);

    property p_runahead_duplicate_block_has_no_enqueue;
        @(posedge clk) disable iff (!rst_n || redirect_valid)
        ifu_runahead_duplicate_alloc_blocked_c |-> !ftq_enq_valid;
    endproperty
    a_runahead_duplicate_block_has_no_enqueue:
        assert property (p_runahead_duplicate_block_has_no_enqueue)
        else $error("[INVARIANT_N] runahead duplicate-allocation block still enqueued");

    property p_runahead_fire_has_clean_request_pop;
        @(posedge clk) disable iff (!rst_n || redirect_valid)
        ifu_runahead_req_fire_c |->
        (ftq_ifu_req_pop_valid && ftq_enq_valid && ftq_enq_ready &&
         !icq_full && !packet_buf_full);
    endproperty
    a_runahead_fire_has_clean_request_pop:
        assert property (p_runahead_fire_has_clean_request_pop)
        else $error("[INVARIANT_O] runahead request fired without clean FTQ/ICQ handoff");

    property p_runahead_cancel_has_current_pop_and_enqueue;
        @(posedge clk) disable iff (!rst_n || redirect_valid)
        ifu_runahead_cancel_next_c |->
        ftq_enq_valid;
    endproperty
    a_runahead_cancel_has_current_pop_and_enqueue:
        assert property (p_runahead_cancel_has_current_pop_and_enqueue)
        else $error("[INVARIANT_P] runahead cancel did not enqueue replacement redirect target");

endmodule

bind fetch_top fetch_frontend_assertions u_fetch_frontend_assertions (
    .clk                                  (clk),
    .rst_n                                (rst_n),
    .redirect_valid                       (redirect_valid),
    .consumed_remainder_r                 (consumed_remainder_r),
    .ic_resp_valid                        (ic_resp_valid),
    .f2_work_line_valid_c                 (f2_work_line_valid_c),
    .f2_work_line_addr_c                  (f2_work_line_addr_c),
    .icq_deq_line_addr                    (icq_deq_line_addr),
    .f2_work_pc_c                         (f2_work_pc_c),
    .f2_work_ftq_valid_c                  (f2_work_ftq_valid_c),
    .f2_work_ftq_epoch_c                  (f2_work_ftq_epoch_c),
    .ftq_current_epoch                    (ftq_current_epoch),
    .f2_will_emit_c                       (f2_will_emit_c),
    .f2_pc_consumed_c                     (f2_pc_consumed_c),
    .icq_deq_owner_match_c                (icq_deq_owner_match_c),
    .icq_deq_ftq_entry                    (icq_deq_ftq_entry),
    .ftq_ifu_wb_owner_entry               (ftq_ifu_wb_owner_entry),
    .icq_deq_ftq_idx                      (icq_deq_ftq_idx),
    .icq_deq_ftq_alloc_tag                (icq_deq_ftq_alloc_tag),
    .ftq_ifu_wb_owner_idx                 (ftq_ifu_wb_owner_idx),
    .ftq_ifu_wb_owner_tag                 (ftq_ifu_wb_owner_tag),
    .f2_line_state_use_c                  (f2_line_state_use_c),
    .f2_line_state_valid_c                (f2_line_state_valid_c),
    .f2_line_state_addr_c                 (f2_line_state_addr_c),
    .f2_line_state_epoch_c                (f2_line_state_epoch_c),
    .f2_work_valid_c                      (f2_work_valid_c),
    .ftq_ifu_pop_valid                    (ftq_ifu_pop_valid),
    .ftq_ifu_wb_owner_valid               (ftq_ifu_wb_owner_valid),
    .f2_work_ftq_idx_c                    (f2_work_ftq_idx_c),
    .f2_work_ftq_alloc_tag_c              (f2_work_ftq_alloc_tag_c),
    .f2_owner_delivery_push_c             (f2_owner_delivery_push_c),
    .packet_buf_in                        (packet_buf_in),
    .f2_owner_completion_candidate_c      (f2_owner_completion_candidate_c),
    .f2_ftq_owner_live_c                  (f2_ftq_owner_live_c),
    .ftq_ifu_req_pop_valid                (ftq_ifu_req_pop_valid),
    .ftq_enq_valid                        (ftq_enq_valid),
    .ftq_enq_ready                        (ftq_enq_ready),
    .icq_full                             (icq_full),
    .packet_buf_full                      (packet_buf_full),
    .ifu_work_take_ftq_next_owner_c       (ifu_work_take_ftq_next_owner_c),
    .ifu_work_take_request_owner_c        (ifu_work_take_request_owner_c),
    .ifu_work_take_remainder_request_owner_c(ifu_work_take_remainder_request_owner_c),
    .f2_seq_next_pc                       (f2_seq_next_pc),
    .ftq_next_ifu_owner_idx               (ftq_next_ifu_owner_idx),
    .ftq_next_ifu_owner_tag               (ftq_next_ifu_owner_tag),
    .ftq_next_ifu_owner_valid             (ftq_next_ifu_owner_valid),
    .ftq_next_ifu_owner_entry             (ftq_next_ifu_owner_entry),
    .ifu_work_redirect_next_owner_match_c (ifu_work_redirect_next_owner_match_c),
    .f2_bpu_target                        (f2_bpu_target),
    .ifu_work_same_owner_advance_c        (ifu_work_same_owner_advance_c),
    .ftq_count_alloc_to_ifu               (ftq_count_alloc_to_ifu),
    .ftq_count_ifu_to_wb                  (ftq_count_ifu_to_wb),
    .ifu_runahead_req_fire_c              (ifu_runahead_req_fire_c),
    .ifu_runahead_cancel_next_c           (ifu_runahead_cancel_next_c),
    .ifu_runahead_pending_c               (ifu_runahead_pending_c),
    .ifu_runahead_pending_pc_c            (ifu_runahead_pending_pc_c),
    .ifu_runahead_pending_idx_c           (ifu_runahead_pending_idx_c),
    .ifu_runahead_pending_epoch_c         (ifu_runahead_pending_epoch_c),
    .ifu_runahead_pending_tag_c           (ifu_runahead_pending_tag_c),
    .ifu_runahead_duplicate_alloc_blocked_c(ifu_runahead_duplicate_alloc_blocked_c),
    .ifu_runahead_depth_gt1_c             (ifu_runahead_depth_gt1_c)
);
`endif

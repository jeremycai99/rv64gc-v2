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

    input  logic                          seq_valid_i,
    input  logic [63:0]                   seq_next_pc_i,
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
    output logic                          work_same_owner_advance_o
);

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
    logic [63:0] req_pc_c;
    logic [63:0] req_block_pc_c;
    logic        ftq_need_alloc_c;
    logic        ftq_enq_valid_c;
    logic        ifu_req_ready_c;
    logic        ifu_req_fire_c;
    logic        fe_stall_c;
    logic        owner_live_c;
    logic        redirect_without_owner_successor_c;
    logic        owner_completion_candidate_c;
    logic        owner_delivery_push_c;
    logic        ftq_ifu_pop_valid_c;
    logic        work_same_owner_advance_c;
    logic        pred_control_outside_next_packet_c;

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
    assign work_same_owner_advance_o    = work_same_owner_advance_c;

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

    assign req_pc_c = (req_redirect_i && !redirect_i)
                      ? bpu_target_i
                      : (line_straddle_advance_i
                            ? seq_next_pc_i
                            : f1_pc_r);
    assign req_block_pc_c = {req_pc_c[63:LINE_BITS], {LINE_BITS{1'b0}}};
    assign ftq_need_alloc_c =
        !redirect_i &&
        f1_valid_r &&
        !remainder_valid_i &&
        !line_straddle_advance_i &&
        !same_owner_continue_i &&
        (req_redirect_i || !(work_r.valid && (req_pc_c == work_r.pc))) &&
        (req_redirect_i || !last_alloc_valid_r ||
         (req_pc_c != last_alloc_req_pc_r));
    assign fe_stall_c = frontend_hold_i ||
                        packet_buf_full_i ||
                        icq_full_i ||
                        (ftq_need_alloc_c && !ftq_enq_ready_i);
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
        (({1'b0, seq_next_pc_i[5:0]} + 7'd16) <=
         {1'b0, work_r.ftq_entry.pred_ctl_offset});
    assign work_same_owner_advance_c =
        same_owner_continue_i &&
        seq_valid_i &&
        will_emit_i &&
        packet_enq_i &&
        owner_live_c &&
        work_r.ftq_valid &&
        !owner_complete_i &&
        pred_control_outside_next_packet_c &&
        !line_straddle_advance_i &&
        !consume_remainder_i &&
        !consumed_remainder_r &&
        (seq_next_pc_i[63:LINE_BITS] == work_r.line_addr);

    assign owner_live_c =
        work_r.ftq_valid &&
        ftq_wb_owner_valid_i &&
        (work_r.ftq_idx == ftq_wb_owner_idx_i) &&
        (work_r.ftq_epoch == ftq_current_epoch_i) &&
        (work_r.ftq_alloc_tag == ftq_wb_owner_tag_i);

    assign work_redirect_o =
        bpu_redirect_i && !fe_stall_c;
    assign work_redirect_next_owner_match_o =
        work_redirect_o &&
        ftq_next_owner_valid_i &&
        (ftq_next_owner_entry_i.block_pc ==
         {bpu_target_i[63:LINE_BITS], {LINE_BITS{1'b0}}}) &&
        (ftq_next_owner_entry_i.start_offset == bpu_target_i[5:0]);
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
        ftq_enq_valid_c;
    assign work_take_request_owner_o =
        !work_redirect_o &&
        !fe_stall_c &&
        !(line_straddle_advance_i ||
          consume_remainder_i ||
          consumed_remainder_r) &&
        ftq_enq_valid_c;

    always_comb begin
        if (redirect_i) begin
            next_pc_c    = redirect_pc_i;
            next_valid_c = 1'b1;
        end else if (bpu_redirect_i) begin
            next_pc_c    = bpu_target_i;
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
                work_next_c.pc            = seq_next_pc_i;
                work_next_c.ftq_valid     = 1'b1;
                work_next_c.ftq_idx       = ftq_next_owner_idx_i;
                work_next_c.ftq_epoch     = ftq_current_epoch_i;
                work_next_c.ftq_alloc_tag = ftq_next_owner_tag_i;
                work_next_c.ftq_entry     = ftq_next_owner_entry_i;
                work_next_c.line_valid    = 1'b1;
                work_next_c.line_addr     = seq_next_pc_i[63:LINE_BITS];
            end else begin
                if (line_straddle_advance_i)
                    work_pc_next = seq_next_pc_i;
                else if (consume_remainder_i)
                    work_pc_next = seq_next_pc_i;
                else if (consumed_remainder_r)
                    work_pc_next = post_remainder_pc_r;
                else if (work_same_owner_advance_c)
                    work_pc_next = seq_next_pc_i;
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
        end else begin
            if (redirect_i) begin
                f1_pc_r    <= redirect_pc_i;
                f1_valid_r <= 1'b1;
                last_alloc_valid_r    <= 1'b0;
                last_alloc_req_pc_r   <= '0;
                consumed_remainder_r  <= 1'b0;
            end else begin
                if (ftq_enq_valid_c) begin
                    last_alloc_valid_r  <= 1'b1;
                    last_alloc_req_pc_r <= req_pc_c;
                end else if (ftq_ifu_pop_valid_c && !ftq_next_owner_valid_i) begin
                    last_alloc_valid_r  <= 1'b0;
                    last_alloc_req_pc_r <= '0;
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

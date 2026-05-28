/* file: fetch_delivery_checker.sv
 Description: Simulation-only fetch delivery stream checker.
 Author: Jeremy Cai
 Date: May 07, 2026
 Version: 1.0
*/
`ifdef SIMULATION
module fetch_delivery_checker
    import rv64gc_pkg::*;
    import uarch_pkg::*;
(
    input  wire                             clk,
    input  wire                             rst_n,
    input  wire                             redirect_valid,
    input  wire                             fetch_packet_out_valid,
    input fetch_packet_t                    fetch_packet_out,
    input  wire                             backend_stall,
    input  wire                             frontend_hold,
    input  wire                             packet_flowthrough_valid,
    input  wire                             packet_buf_deq,
    input  wire [63:0]                      f2_work_pc_c,
    input  wire                             f2_work_ftq_valid_c,
    input  wire [FTQ_IDX_BITS-1:0]          f2_work_ftq_idx_c,
    input  wire [FTQ_EPOCH_BITS-1:0]        f2_work_ftq_epoch_c,
    input  wire [FTQ_ALLOC_TAG_BITS-1:0]    f2_work_ftq_alloc_tag_c,
    input ftq_entry_t                       f2_work_ftq_entry_c,
    input  wire                             f2_ftq_owner_live_c,
    input  wire                             f2_work_valid_c,
    input  wire                             f2_data_valid,
    input  wire                             f2_has_emit_payload_c,
    input  wire                             f2_will_emit_c,
    input  wire                             f2_duplicate_suppressed_c,
    input  wire [63:0]                      f2_duplicate_next_pc_c,
    input  wire                             f2_seq_valid,
    input  wire [63:0]                      f2_seq_next_pc,
    input  wire                             req_redirect_c,
    input  wire                             f2_bpu_redirect_c,
    input  wire [63:0]                      f2_bpu_target_c,
    input  wire                             successor_req_valid_c,
    input  wire [63:0]                      successor_req_pc_c,
    input  wire [63:0]                      req_pc_c,
    input  wire                             ifu_runahead_pending_c,
    input  wire [63:0]                      ifu_runahead_pending_pc_c,
    input  wire                             packet_buf_enq_ready,
    input  wire                             fe_stall,
    input  wire                             line_straddle_advance_c,
    input  wire                             consume_remainder_c,
    input  wire                             consumed_remainder_r,
    input  wire                             predecode_ctl_found_c,
    input  wire                             bp_branch_found_c,
    input  wire                             bp_taken_c,
    input  wire                             f2_work_line_valid_c,
    input  wire [63:LINE_BITS]              f2_work_line_addr_c,
    input  wire                             icq_deq_valid,
    input  wire [63:LINE_BITS]              icq_deq_line_addr,
    input  wire                             ftq_enq_valid,
    input  wire [FTQ_IDX_BITS-1:0]          ftq_enq_idx,
    input  wire [FTQ_ALLOC_TAG_BITS-1:0]    ftq_enq_tag,
    input ftq_entry_t                       ftq_enq_entry_c,
    input  wire                             ftq_ifu_pop_valid,
    input  wire [FTQ_IDX_BITS:0]            ftq_count_ifu_to_wb,
    input  wire                             ftq_next_ifu_owner_valid,
    input  wire [FTQ_IDX_BITS-1:0]          ftq_next_ifu_owner_idx,
    input  wire [FTQ_ALLOC_TAG_BITS-1:0]    ftq_next_ifu_owner_tag,
    input ftq_entry_t                       ftq_next_ifu_owner_entry
);

    localparam logic [2:0] BT_COND = 3'd0;
    localparam logic [2:0] BT_JAL  = 3'd1;
    localparam logic [2:0] BT_JALR = 3'd2;
    localparam logic [2:0] BT_CALL = 3'd3;
    localparam logic [2:0] BT_RET  = 3'd4;
    localparam int DELIVERY_CHECK_PRINT_LIMIT = 16;

    logic delivery_check_en;
    logic delivery_strict_en;
    logic delivery_score_valid_r;
    logic [FTQ_IDX_BITS-1:0] delivery_score_idx_r;
    logic [FTQ_EPOCH_BITS-1:0] delivery_score_epoch_r;
    logic [FTQ_ALLOC_TAG_BITS-1:0] delivery_score_tag_r;
    logic [63:0] delivery_score_next_pc_r;
    logic delivery_score_complete_r;
    logic delivery_fire_c;
    logic delivery_score_owner_match_c;
    logic delivery_score_active_c;
    logic delivery_score_f2_owner_match_c;
    logic delivery_score_f2_expected_pc_c;
    logic delivery_score_f2_other_pc_c;
    logic delivery_no_emit_c;
    logic delivery_no_emit_score_active_c;
    logic delivery_no_emit_no_score_c;
    logic delivery_no_emit_owner_match_c;
    logic delivery_no_emit_owner_mismatch_c;
    logic delivery_no_emit_expected_pc_c;
    logic delivery_no_emit_already_delivered_c;
    logic delivery_no_emit_after_complete_c;
    logic delivery_no_emit_dup_expected_c;
    logic delivery_no_emit_dup_already_delivered_c;
    logic delivery_no_emit_redirect_hold_c;
    logic delivery_no_emit_pkt_not_ready_c;
    logic delivery_no_emit_frontend_hold_c;
    logic delivery_no_emit_fe_stall_c;
    logic delivery_no_emit_straddle_c;
    logic delivery_no_emit_remainder_c;
    logic delivery_no_emit_control_c;
    logic delivery_no_emit_taken_control_c;
    logic delivery_no_emit_other_c;
    logic delivery_cursor_same_line_c;
    logic delivery_cursor_cross_line_c;
    logic delivery_cursor_seq_next_match_c;
    logic delivery_cursor_dup_next_match_c;
    logic delivery_cursor_req_pc_match_c;
    logic delivery_cursor_successor_match_c;
    logic delivery_cursor_runahead_match_c;
    logic delivery_cursor_bpu_redirect_match_c;
    logic delivery_cursor_req_redirect_c;
    logic delivery_cursor_bpu_redirect_c;
    logic delivery_cursor_commit_redirect_c;
    logic delivery_cursor_line_state_match_c;
    logic delivery_cursor_icq_match_c;
    logic delivery_cursor_ftq_next_start_match_c;
    logic [63:0] ftq_next_ifu_owner_start_pc_c;
    integer delivery_check_owner_switch_count;
    integer delivery_check_noncontig_count;
    integer delivery_score_active_cycles;
    integer delivery_no_emit_cycles;
    integer delivery_no_emit_score_active_cycles;
    integer delivery_no_emit_no_score_cycles;
    integer delivery_no_emit_owner_match_cycles;
    integer delivery_no_emit_owner_mismatch_cycles;
    integer delivery_no_emit_expected_pc_cycles;
    integer delivery_no_emit_already_delivered_cycles;
    integer delivery_no_emit_after_complete_cycles;
    integer delivery_no_emit_dup_expected_cycles;
    integer delivery_no_emit_dup_already_delivered_cycles;
    integer delivery_no_emit_redirect_hold_cycles;
    integer delivery_no_emit_pkt_not_ready_cycles;
    integer delivery_no_emit_frontend_hold_cycles;
    integer delivery_no_emit_fe_stall_cycles;
    integer delivery_no_emit_straddle_cycles;
    integer delivery_no_emit_remainder_cycles;
    integer delivery_no_emit_control_cycles;
    integer delivery_no_emit_taken_control_cycles;
    integer delivery_no_emit_other_cycles;
    integer delivery_cursor_same_line_cycles;
    integer delivery_cursor_cross_line_cycles;
    integer delivery_cursor_seq_next_match_cycles;
    integer delivery_cursor_dup_next_match_cycles;
    integer delivery_cursor_req_pc_match_cycles;
    integer delivery_cursor_successor_match_cycles;
    integer delivery_cursor_runahead_match_cycles;
    integer delivery_cursor_bpu_redirect_match_cycles;
    integer delivery_cursor_req_redirect_cycles;
    integer delivery_cursor_bpu_redirect_cycles;
    integer delivery_cursor_commit_redirect_cycles;
    integer delivery_cursor_line_state_match_cycles;
    integer delivery_cursor_icq_match_cycles;
    integer delivery_cursor_ftq_next_start_match_cycles;

    initial begin
        delivery_check_en = $test$plusargs("FETCH_DELIVERY_CHECK");
        delivery_strict_en = $test$plusargs("FETCH_DELIVERY_STRICT");
    end

    assign delivery_fire_c =
        fetch_packet_out_valid &&
        fetch_packet_out.valid &&
        (fetch_packet_out.fetch_count != 3'd0) &&
        !backend_stall &&
        !frontend_hold;
    assign delivery_score_owner_match_c =
        delivery_score_valid_r &&
        (fetch_packet_out.ftq_idx == delivery_score_idx_r) &&
        (fetch_packet_out.ftq_epoch == delivery_score_epoch_r) &&
        (fetch_packet_out.ftq_alloc_tag == delivery_score_tag_r);
    assign delivery_score_active_c =
        delivery_score_valid_r &&
        !delivery_score_complete_r;
    assign delivery_score_f2_owner_match_c =
        delivery_score_active_c &&
        f2_work_ftq_valid_c &&
        (f2_work_ftq_idx_c == delivery_score_idx_r) &&
        (f2_work_ftq_epoch_c == delivery_score_epoch_r) &&
        (f2_work_ftq_alloc_tag_c == delivery_score_tag_r);
    assign delivery_score_f2_expected_pc_c =
        delivery_score_f2_owner_match_c &&
        (f2_work_pc_c == delivery_score_next_pc_r);
    assign delivery_score_f2_other_pc_c =
        delivery_score_f2_owner_match_c &&
        (f2_work_pc_c != delivery_score_next_pc_r);
    assign delivery_no_emit_c =
        f2_work_valid_c &&
        f2_data_valid &&
        f2_has_emit_payload_c &&
        !f2_will_emit_c;
    assign delivery_no_emit_score_active_c =
        delivery_no_emit_c &&
        delivery_score_active_c;
    assign delivery_no_emit_no_score_c =
        delivery_no_emit_c &&
        !delivery_score_valid_r;
    assign delivery_no_emit_owner_match_c =
        delivery_no_emit_c &&
        delivery_score_f2_owner_match_c;
    assign delivery_no_emit_owner_mismatch_c =
        delivery_no_emit_score_active_c &&
        !delivery_score_f2_owner_match_c;
    assign delivery_no_emit_expected_pc_c =
        delivery_no_emit_c &&
        delivery_score_f2_expected_pc_c;
    assign delivery_no_emit_already_delivered_c =
        delivery_no_emit_c &&
        delivery_score_f2_other_pc_c;
    assign delivery_no_emit_after_complete_c =
        delivery_no_emit_c &&
        delivery_score_valid_r &&
        delivery_score_complete_r;
    assign delivery_no_emit_dup_expected_c =
        delivery_no_emit_expected_pc_c &&
        f2_duplicate_suppressed_c;
    assign delivery_no_emit_dup_already_delivered_c =
        delivery_no_emit_already_delivered_c &&
        f2_duplicate_suppressed_c;
    assign delivery_no_emit_redirect_hold_c =
        delivery_no_emit_expected_pc_c &&
        !f2_duplicate_suppressed_c &&
        redirect_valid;
    assign delivery_no_emit_pkt_not_ready_c =
        delivery_no_emit_expected_pc_c &&
        !f2_duplicate_suppressed_c &&
        !redirect_valid &&
        !packet_buf_enq_ready;
    assign delivery_no_emit_frontend_hold_c =
        delivery_no_emit_expected_pc_c &&
        !f2_duplicate_suppressed_c &&
        !redirect_valid &&
        packet_buf_enq_ready &&
        frontend_hold;
    assign delivery_no_emit_fe_stall_c =
        delivery_no_emit_expected_pc_c &&
        !f2_duplicate_suppressed_c &&
        !redirect_valid &&
        packet_buf_enq_ready &&
        !frontend_hold &&
        fe_stall;
    assign delivery_no_emit_straddle_c =
        delivery_no_emit_expected_pc_c &&
        line_straddle_advance_c;
    assign delivery_no_emit_remainder_c =
        delivery_no_emit_expected_pc_c &&
        (consume_remainder_c || consumed_remainder_r);
    assign delivery_no_emit_control_c =
        delivery_no_emit_expected_pc_c &&
        predecode_ctl_found_c;
    assign delivery_no_emit_taken_control_c =
        delivery_no_emit_expected_pc_c &&
        bp_branch_found_c &&
        bp_taken_c;
    assign delivery_no_emit_other_c =
        delivery_no_emit_expected_pc_c &&
        !delivery_no_emit_dup_expected_c &&
        !delivery_no_emit_redirect_hold_c &&
        !delivery_no_emit_pkt_not_ready_c &&
        !delivery_no_emit_frontend_hold_c &&
        !delivery_no_emit_fe_stall_c;
    assign ftq_next_ifu_owner_start_pc_c =
        ftq_next_ifu_owner_entry.block_pc +
        64'(ftq_next_ifu_owner_entry.start_offset);
    assign delivery_cursor_same_line_c =
        delivery_no_emit_already_delivered_c &&
        (delivery_score_next_pc_r[63:LINE_BITS] ==
         f2_work_pc_c[63:LINE_BITS]);
    assign delivery_cursor_cross_line_c =
        delivery_no_emit_already_delivered_c &&
        (delivery_score_next_pc_r[63:LINE_BITS] !=
         f2_work_pc_c[63:LINE_BITS]);
    assign delivery_cursor_seq_next_match_c =
        delivery_no_emit_already_delivered_c &&
        f2_seq_valid &&
        (f2_seq_next_pc == delivery_score_next_pc_r);
    assign delivery_cursor_dup_next_match_c =
        delivery_no_emit_already_delivered_c &&
        (f2_duplicate_next_pc_c == delivery_score_next_pc_r);
    assign delivery_cursor_req_pc_match_c =
        delivery_no_emit_already_delivered_c &&
        (req_pc_c == delivery_score_next_pc_r);
    assign delivery_cursor_successor_match_c =
        delivery_no_emit_already_delivered_c &&
        successor_req_valid_c &&
        (successor_req_pc_c == delivery_score_next_pc_r);
    assign delivery_cursor_runahead_match_c =
        delivery_no_emit_already_delivered_c &&
        ifu_runahead_pending_c &&
        (ifu_runahead_pending_pc_c == delivery_score_next_pc_r);
    assign delivery_cursor_bpu_redirect_match_c =
        delivery_no_emit_already_delivered_c &&
        f2_bpu_redirect_c &&
        (f2_bpu_target_c == delivery_score_next_pc_r);
    assign delivery_cursor_req_redirect_c =
        delivery_no_emit_already_delivered_c &&
        req_redirect_c;
    assign delivery_cursor_bpu_redirect_c =
        delivery_no_emit_already_delivered_c &&
        f2_bpu_redirect_c;
    assign delivery_cursor_commit_redirect_c =
        delivery_no_emit_already_delivered_c &&
        redirect_valid;
    assign delivery_cursor_line_state_match_c =
        delivery_no_emit_already_delivered_c &&
        f2_work_line_valid_c &&
        (f2_work_line_addr_c == delivery_score_next_pc_r[63:LINE_BITS]);
    assign delivery_cursor_icq_match_c =
        delivery_no_emit_already_delivered_c &&
        icq_deq_valid &&
        (icq_deq_line_addr == delivery_score_next_pc_r[63:LINE_BITS]);
    assign delivery_cursor_ftq_next_start_match_c =
        delivery_no_emit_already_delivered_c &&
        ftq_next_ifu_owner_valid &&
        (ftq_next_ifu_owner_start_pc_c == delivery_score_next_pc_r);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            delivery_score_valid_r   <= 1'b0;
            delivery_score_idx_r     <= '0;
            delivery_score_epoch_r   <= '0;
            delivery_score_tag_r     <= '0;
            delivery_score_next_pc_r <= '0;
            delivery_score_complete_r <= 1'b0;
            delivery_check_owner_switch_count <= 0;
            delivery_check_noncontig_count <= 0;
            delivery_score_active_cycles <= 0;
            delivery_no_emit_cycles <= 0;
            delivery_no_emit_score_active_cycles <= 0;
            delivery_no_emit_no_score_cycles <= 0;
            delivery_no_emit_owner_match_cycles <= 0;
            delivery_no_emit_owner_mismatch_cycles <= 0;
            delivery_no_emit_expected_pc_cycles <= 0;
            delivery_no_emit_already_delivered_cycles <= 0;
            delivery_no_emit_after_complete_cycles <= 0;
            delivery_no_emit_dup_expected_cycles <= 0;
            delivery_no_emit_dup_already_delivered_cycles <= 0;
            delivery_no_emit_redirect_hold_cycles <= 0;
            delivery_no_emit_pkt_not_ready_cycles <= 0;
            delivery_no_emit_frontend_hold_cycles <= 0;
            delivery_no_emit_fe_stall_cycles <= 0;
            delivery_no_emit_straddle_cycles <= 0;
            delivery_no_emit_remainder_cycles <= 0;
            delivery_no_emit_control_cycles <= 0;
            delivery_no_emit_taken_control_cycles <= 0;
            delivery_no_emit_other_cycles <= 0;
            delivery_cursor_same_line_cycles <= 0;
            delivery_cursor_cross_line_cycles <= 0;
            delivery_cursor_seq_next_match_cycles <= 0;
            delivery_cursor_dup_next_match_cycles <= 0;
            delivery_cursor_req_pc_match_cycles <= 0;
            delivery_cursor_successor_match_cycles <= 0;
            delivery_cursor_runahead_match_cycles <= 0;
            delivery_cursor_bpu_redirect_match_cycles <= 0;
            delivery_cursor_req_redirect_cycles <= 0;
            delivery_cursor_bpu_redirect_cycles <= 0;
            delivery_cursor_commit_redirect_cycles <= 0;
            delivery_cursor_line_state_match_cycles <= 0;
            delivery_cursor_icq_match_cycles <= 0;
            delivery_cursor_ftq_next_start_match_cycles <= 0;
        end else begin
            if (delivery_check_en) begin
                if (delivery_score_active_c)
                    delivery_score_active_cycles <=
                        delivery_score_active_cycles + 1;
                if (delivery_no_emit_c)
                    delivery_no_emit_cycles <= delivery_no_emit_cycles + 1;
                if (delivery_no_emit_score_active_c)
                    delivery_no_emit_score_active_cycles <=
                        delivery_no_emit_score_active_cycles + 1;
                if (delivery_no_emit_no_score_c)
                    delivery_no_emit_no_score_cycles <=
                        delivery_no_emit_no_score_cycles + 1;
                if (delivery_no_emit_owner_match_c)
                    delivery_no_emit_owner_match_cycles <=
                        delivery_no_emit_owner_match_cycles + 1;
                if (delivery_no_emit_owner_mismatch_c)
                    delivery_no_emit_owner_mismatch_cycles <=
                        delivery_no_emit_owner_mismatch_cycles + 1;
                if (delivery_no_emit_expected_pc_c)
                    delivery_no_emit_expected_pc_cycles <=
                        delivery_no_emit_expected_pc_cycles + 1;
                if (delivery_no_emit_already_delivered_c)
                    delivery_no_emit_already_delivered_cycles <=
                        delivery_no_emit_already_delivered_cycles + 1;
                if (delivery_no_emit_after_complete_c)
                    delivery_no_emit_after_complete_cycles <=
                        delivery_no_emit_after_complete_cycles + 1;
                if (delivery_no_emit_dup_expected_c)
                    delivery_no_emit_dup_expected_cycles <=
                        delivery_no_emit_dup_expected_cycles + 1;
                if (delivery_no_emit_dup_already_delivered_c)
                    delivery_no_emit_dup_already_delivered_cycles <=
                        delivery_no_emit_dup_already_delivered_cycles + 1;
                if (delivery_no_emit_redirect_hold_c)
                    delivery_no_emit_redirect_hold_cycles <=
                        delivery_no_emit_redirect_hold_cycles + 1;
                if (delivery_no_emit_pkt_not_ready_c)
                    delivery_no_emit_pkt_not_ready_cycles <=
                        delivery_no_emit_pkt_not_ready_cycles + 1;
                if (delivery_no_emit_frontend_hold_c)
                    delivery_no_emit_frontend_hold_cycles <=
                        delivery_no_emit_frontend_hold_cycles + 1;
                if (delivery_no_emit_fe_stall_c)
                    delivery_no_emit_fe_stall_cycles <=
                        delivery_no_emit_fe_stall_cycles + 1;
                if (delivery_no_emit_straddle_c)
                    delivery_no_emit_straddle_cycles <=
                        delivery_no_emit_straddle_cycles + 1;
                if (delivery_no_emit_remainder_c)
                    delivery_no_emit_remainder_cycles <=
                        delivery_no_emit_remainder_cycles + 1;
                if (delivery_no_emit_control_c)
                    delivery_no_emit_control_cycles <=
                        delivery_no_emit_control_cycles + 1;
                if (delivery_no_emit_taken_control_c)
                    delivery_no_emit_taken_control_cycles <=
                        delivery_no_emit_taken_control_cycles + 1;
                if (delivery_no_emit_other_c)
                    delivery_no_emit_other_cycles <=
                        delivery_no_emit_other_cycles + 1;
                if (delivery_cursor_same_line_c)
                    delivery_cursor_same_line_cycles <=
                        delivery_cursor_same_line_cycles + 1;
                if (delivery_cursor_cross_line_c)
                    delivery_cursor_cross_line_cycles <=
                        delivery_cursor_cross_line_cycles + 1;
                if (delivery_cursor_seq_next_match_c)
                    delivery_cursor_seq_next_match_cycles <=
                        delivery_cursor_seq_next_match_cycles + 1;
                if (delivery_cursor_dup_next_match_c)
                    delivery_cursor_dup_next_match_cycles <=
                        delivery_cursor_dup_next_match_cycles + 1;
                if (delivery_cursor_req_pc_match_c)
                    delivery_cursor_req_pc_match_cycles <=
                        delivery_cursor_req_pc_match_cycles + 1;
                if (delivery_cursor_successor_match_c)
                    delivery_cursor_successor_match_cycles <=
                        delivery_cursor_successor_match_cycles + 1;
                if (delivery_cursor_runahead_match_c)
                    delivery_cursor_runahead_match_cycles <=
                        delivery_cursor_runahead_match_cycles + 1;
                if (delivery_cursor_bpu_redirect_match_c)
                    delivery_cursor_bpu_redirect_match_cycles <=
                        delivery_cursor_bpu_redirect_match_cycles + 1;
                if (delivery_cursor_req_redirect_c)
                    delivery_cursor_req_redirect_cycles <=
                        delivery_cursor_req_redirect_cycles + 1;
                if (delivery_cursor_bpu_redirect_c)
                    delivery_cursor_bpu_redirect_cycles <=
                        delivery_cursor_bpu_redirect_cycles + 1;
                if (delivery_cursor_commit_redirect_c)
                    delivery_cursor_commit_redirect_cycles <=
                        delivery_cursor_commit_redirect_cycles + 1;
                if (delivery_cursor_line_state_match_c)
                    delivery_cursor_line_state_match_cycles <=
                        delivery_cursor_line_state_match_cycles + 1;
                if (delivery_cursor_icq_match_c)
                    delivery_cursor_icq_match_cycles <=
                        delivery_cursor_icq_match_cycles + 1;
                if (delivery_cursor_ftq_next_start_match_c)
                    delivery_cursor_ftq_next_start_match_cycles <=
                        delivery_cursor_ftq_next_start_match_cycles + 1;
            end

            if (redirect_valid) begin
                delivery_score_valid_r   <= 1'b0;
                delivery_score_idx_r     <= '0;
                delivery_score_epoch_r   <= '0;
                delivery_score_tag_r     <= '0;
                delivery_score_next_pc_r <= '0;
                delivery_score_complete_r <= 1'b0;
            end else if (delivery_check_en && delivery_fire_c) begin
                automatic logic [63:0] expected_pc;
                automatic logic packet_redirect_taken;
                automatic logic [63:0] packet_redirect_target;

                if (delivery_score_valid_r &&
                    !delivery_score_owner_match_c &&
                    !delivery_score_complete_r) begin
                    if (delivery_check_owner_switch_count <
                        DELIVERY_CHECK_PRINT_LIMIT) begin
                        $display("[FETCH_DELIVERY_CHECK] owner switched before complete old_idx=%0d old_tag=%0d old_next=%016h new_idx=%0d new_tag=%0d new_pc0=%016h",
                                 delivery_score_idx_r,
                                 delivery_score_tag_r,
                                 delivery_score_next_pc_r,
                                 fetch_packet_out.ftq_idx,
                                 fetch_packet_out.ftq_alloc_tag,
                                 fetch_packet_out.fetch_pc[0]);
                    end
                    delivery_check_owner_switch_count <=
                        delivery_check_owner_switch_count + 1;
                end

                expected_pc = delivery_score_owner_match_c
                    ? delivery_score_next_pc_r
                    : (fetch_packet_out.ftq_block_pc +
                       64'(fetch_packet_out.ftq_start_offset));
                packet_redirect_taken = 1'b0;
                packet_redirect_target = '0;

                if (fetch_packet_out.pd_ctl_valid &&
                    (fetch_packet_out.pd_ctl_slot <
                     fetch_packet_out.fetch_count)) begin
                    case (fetch_packet_out.pd_ctl_type)
                        BT_COND: begin
                            if (fetch_packet_out.ftq_pred_valid &&
                                fetch_packet_out.ftq_pred_taken &&
                                (fetch_packet_out.ftq_pred_target ==
                                 fetch_packet_out.pd_ctl_target)) begin
                                packet_redirect_taken = 1'b1;
                                packet_redirect_target =
                                    fetch_packet_out.pd_ctl_target;
                            end
                        end
                        BT_JAL,
                        BT_CALL: begin
                            packet_redirect_taken = 1'b1;
                            packet_redirect_target =
                                fetch_packet_out.pd_ctl_target;
                        end
                        BT_JALR,
                        BT_RET: begin
                            if (fetch_packet_out.pd_ctl_target != 64'd0) begin
                                packet_redirect_taken = 1'b1;
                                packet_redirect_target =
                                    fetch_packet_out.pd_ctl_target;
                            end
                        end
                        default: begin
                        end
                    endcase
                end

                for (int i = 0; i < PIPE_WIDTH; i++) begin
                    if (i < int'(fetch_packet_out.fetch_count)) begin
                        if (fetch_packet_out.fetch_pc[i] != expected_pc) begin
                            if (delivery_check_noncontig_count <
                                DELIVERY_CHECK_PRINT_LIMIT) begin
                                $display("[FETCH_DELIVERY_CHECK] non-contiguous owner stream idx=%0d tag=%0d slot=%0d expected=%016h got=%016h count=%0d complete=%b flowthrough=%b deq=%b",
                                         fetch_packet_out.ftq_idx,
                                         fetch_packet_out.ftq_alloc_tag,
                                         i,
                                         expected_pc,
                                         fetch_packet_out.fetch_pc[i],
                                         fetch_packet_out.fetch_count,
                                         fetch_packet_out.ftq_owner_complete,
                                         packet_flowthrough_valid,
                                         packet_buf_deq);
                                $display("[FETCH_DELIVERY_CHECK_DETAIL] pkt_block=%016h pkt_start=%0d pkt_lookup=%016h ifu_line=%014h reused=%b pred_valid=%b pred_taken=%b pred_off=%0d pred_type=%0d pred_target=%016h pd_valid=%b pd_slot=%0d pd_type=%0d pd_target=%016h",
                                         fetch_packet_out.ftq_block_pc,
                                         fetch_packet_out.ftq_start_offset,
                                         fetch_packet_out.ftq_bp_lookup_pc,
                                         fetch_packet_out.ifu_line_addr,
                                         fetch_packet_out.ifu_line_reused,
                                         fetch_packet_out.ftq_pred_valid,
                                         fetch_packet_out.ftq_pred_taken,
                                         fetch_packet_out.ftq_pred_offset,
                                         fetch_packet_out.ftq_pred_type,
                                         fetch_packet_out.ftq_pred_target,
                                         fetch_packet_out.pd_ctl_valid,
                                         fetch_packet_out.pd_ctl_slot,
                                         fetch_packet_out.pd_ctl_type,
                                         fetch_packet_out.pd_ctl_target);
                                $display("[FETCH_DELIVERY_CHECK_F2] work_pc=%016h work_valid=%b work_idx=%0d work_tag=%0d work_block=%016h work_start=%0d owner_live=%b ftq_enq=%b enq_idx=%0d enq_tag=%0d enq_block=%016h enq_start=%0d ftq_pop=%b count_ifu_wb=%0d next_owner=%b next_idx=%0d next_tag=%0d next_block=%016h next_start=%0d",
                                         f2_work_pc_c,
                                         f2_work_ftq_valid_c,
                                         f2_work_ftq_idx_c,
                                         f2_work_ftq_alloc_tag_c,
                                         f2_work_ftq_entry_c.block_pc,
                                         f2_work_ftq_entry_c.start_offset,
                                         f2_ftq_owner_live_c,
                                         ftq_enq_valid,
                                         ftq_enq_idx,
                                         ftq_enq_tag,
                                         ftq_enq_entry_c.block_pc,
                                         ftq_enq_entry_c.start_offset,
                                         ftq_ifu_pop_valid,
                                         ftq_count_ifu_to_wb,
                                         ftq_next_ifu_owner_valid,
                                         ftq_next_ifu_owner_idx,
                                         ftq_next_ifu_owner_tag,
                                         ftq_next_ifu_owner_entry.block_pc,
                                         ftq_next_ifu_owner_entry.start_offset);
                            end
                            delivery_check_noncontig_count <=
                                delivery_check_noncontig_count + 1;
                            if (delivery_strict_en)
                                $fatal(1, "fetch delivery PC stream is non-contiguous");
                        end
                        if (fetch_packet_out.fetch_bp_taken[i]) begin
                            expected_pc = fetch_packet_out.fetch_bp_target[i];
                        end else begin
                            expected_pc = fetch_packet_out.fetch_pc[i] +
                                (fetch_packet_out.fetch_is_rvc[i] ? 64'd2 : 64'd4);
                        end
                    end
                end
                if (packet_redirect_taken) begin
                    expected_pc = packet_redirect_target;
                end

                delivery_score_valid_r   <= 1'b1;
                delivery_score_idx_r     <= fetch_packet_out.ftq_idx;
                delivery_score_epoch_r   <= fetch_packet_out.ftq_epoch;
                delivery_score_tag_r     <= fetch_packet_out.ftq_alloc_tag;
                delivery_score_next_pc_r <= expected_pc;
                delivery_score_complete_r <= fetch_packet_out.ftq_owner_complete;
            end
        end
    end

    final begin
        if (delivery_check_en) begin
            $display("");
            $display("=== FETCH DELIVERY CHECK ===");
            $display("strict mode                  : %0d", delivery_strict_en);
            $display("owner switch before complete : %0d",
                     delivery_check_owner_switch_count);
            $display("non-contiguous packet PCs    : %0d",
                     delivery_check_noncontig_count);
            $display("xs delivery owner switch     : %0d",
                     delivery_check_owner_switch_count);
            $display("xs delivery noncontig pcs    : %0d",
                     delivery_check_noncontig_count);
            $display("xs delivery score active     : %0d",
                     delivery_score_active_cycles);
            $display("xs delivery no emit          : %0d",
                     delivery_no_emit_cycles);
            $display("xs delivery no emit score active: %0d",
                     delivery_no_emit_score_active_cycles);
            $display("xs delivery no emit no score : %0d",
                     delivery_no_emit_no_score_cycles);
            $display("xs delivery no emit owner match: %0d",
                     delivery_no_emit_owner_match_cycles);
            $display("xs delivery no emit owner mismatch: %0d",
                     delivery_no_emit_owner_mismatch_cycles);
            $display("xs delivery no emit expected pc: %0d",
                     delivery_no_emit_expected_pc_cycles);
            $display("xs delivery no emit already delivered: %0d",
                     delivery_no_emit_already_delivered_cycles);
            $display("xs delivery no emit after complete: %0d",
                     delivery_no_emit_after_complete_cycles);
            $display("xs delivery no emit dup expected: %0d",
                     delivery_no_emit_dup_expected_cycles);
            $display("xs delivery no emit dup already delivered: %0d",
                     delivery_no_emit_dup_already_delivered_cycles);
            $display("xs delivery no emit redirect hold: %0d",
                     delivery_no_emit_redirect_hold_cycles);
            $display("xs delivery no emit pkt not ready: %0d",
                     delivery_no_emit_pkt_not_ready_cycles);
            $display("xs delivery no emit frontend hold: %0d",
                     delivery_no_emit_frontend_hold_cycles);
            $display("xs delivery no emit fe stall: %0d",
                     delivery_no_emit_fe_stall_cycles);
            $display("xs delivery no emit straddle: %0d",
                     delivery_no_emit_straddle_cycles);
            $display("xs delivery no emit remainder: %0d",
                     delivery_no_emit_remainder_cycles);
            $display("xs delivery no emit control : %0d",
                     delivery_no_emit_control_cycles);
            $display("xs delivery no emit taken control: %0d",
                     delivery_no_emit_taken_control_cycles);
            $display("xs delivery no emit other   : %0d",
                     delivery_no_emit_other_cycles);
            $display("xs delivery cursor same line: %0d",
                     delivery_cursor_same_line_cycles);
            $display("xs delivery cursor cross line: %0d",
                     delivery_cursor_cross_line_cycles);
            $display("xs delivery cursor seq match: %0d",
                     delivery_cursor_seq_next_match_cycles);
            $display("xs delivery cursor dup next match: %0d",
                     delivery_cursor_dup_next_match_cycles);
            $display("xs delivery cursor req pc match: %0d",
                     delivery_cursor_req_pc_match_cycles);
            $display("xs delivery cursor successor match: %0d",
                     delivery_cursor_successor_match_cycles);
            $display("xs delivery cursor runahead match: %0d",
                     delivery_cursor_runahead_match_cycles);
            $display("xs delivery cursor bpu target match: %0d",
                     delivery_cursor_bpu_redirect_match_cycles);
            $display("xs delivery cursor req redirect: %0d",
                     delivery_cursor_req_redirect_cycles);
            $display("xs delivery cursor bpu redirect: %0d",
                     delivery_cursor_bpu_redirect_cycles);
            $display("xs delivery cursor commit redirect: %0d",
                     delivery_cursor_commit_redirect_cycles);
            $display("xs delivery cursor line state match: %0d",
                     delivery_cursor_line_state_match_cycles);
            $display("xs delivery cursor icq match: %0d",
                     delivery_cursor_icq_match_cycles);
            $display("xs delivery cursor ftq next start match: %0d",
                     delivery_cursor_ftq_next_start_match_cycles);
        end
    end

endmodule

bind fetch_top fetch_delivery_checker u_fetch_delivery_checker (
    .clk                         (clk),
    .rst_n                       (rst_n),
    .redirect_valid              (redirect_valid),
    .fetch_packet_out_valid      (fetch_packet_out_valid),
    .fetch_packet_out            (fetch_packet_out),
    .backend_stall               (backend_stall),
    .frontend_hold               (frontend_hold),
    .packet_flowthrough_valid    (packet_flowthrough_valid),
    .packet_buf_deq              (packet_buf_deq),
    .f2_work_pc_c                (f2_work_pc_c),
    .f2_work_ftq_valid_c         (f2_work_ftq_valid_c),
    .f2_work_ftq_idx_c           (f2_work_ftq_idx_c),
    .f2_work_ftq_epoch_c         (f2_work_ftq_epoch_c),
    .f2_work_ftq_alloc_tag_c     (f2_work_ftq_alloc_tag_c),
    .f2_work_ftq_entry_c         (f2_work_ftq_entry_c),
    .f2_ftq_owner_live_c         (f2_ftq_owner_live_c),
    .f2_work_valid_c             (f2_work_valid_c),
    .f2_data_valid               (f2_data_valid),
    .f2_has_emit_payload_c       (f2_has_emit_payload_c),
    .f2_will_emit_c              (f2_will_emit_c),
    .f2_duplicate_suppressed_c   (f2_duplicate_suppressed_c),
    .f2_duplicate_next_pc_c      (f2_duplicate_next_pc_c),
    .f2_seq_valid                (f2_seq_valid),
    .f2_seq_next_pc              (f2_seq_next_pc),
    .req_redirect_c              (req_redirect_c),
    .f2_bpu_redirect_c           (f2_bpu_redirect),
    .f2_bpu_target_c             (f2_bpu_target),
    .successor_req_valid_c       (successor_req_valid_c),
    .successor_req_pc_c          (successor_req_pc_c),
    .req_pc_c                    (req_pc_c),
    .ifu_runahead_pending_c      (ifu_runahead_pending_c),
    .ifu_runahead_pending_pc_c   (ifu_runahead_pending_pc_c),
    .packet_buf_enq_ready        (packet_buf_enq_ready),
    .fe_stall                    (fe_stall),
    .line_straddle_advance_c     (line_straddle_advance_c),
    .consume_remainder_c         (consume_remainder_c),
    .consumed_remainder_r        (consumed_remainder_r),
    .predecode_ctl_found_c       (predecode_ctl_found),
    .bp_branch_found_c           (bp_branch_found),
    .bp_taken_c                  (bp_taken),
    .f2_work_line_valid_c        (f2_work_line_valid_c),
    .f2_work_line_addr_c         (f2_work_line_addr_c),
    .icq_deq_valid               (icq_deq_valid),
    .icq_deq_line_addr           (icq_deq_line_addr),
    .ftq_enq_valid               (ftq_enq_valid),
    .ftq_enq_idx                 (ftq_enq_idx),
    .ftq_enq_tag                 (ftq_enq_tag),
    .ftq_enq_entry_c             (req_ftq_entry_c),
    .ftq_ifu_pop_valid           (ftq_ifu_pop_valid),
    .ftq_count_ifu_to_wb         (ftq_count_ifu_to_wb),
    .ftq_next_ifu_owner_valid    (ftq_next_ifu_owner_valid),
    .ftq_next_ifu_owner_idx      (ftq_next_ifu_owner_idx),
    .ftq_next_ifu_owner_tag      (ftq_next_ifu_owner_tag),
    .ftq_next_ifu_owner_entry    (ftq_next_ifu_owner_entry)
);
`endif

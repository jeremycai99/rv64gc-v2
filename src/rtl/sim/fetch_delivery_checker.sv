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
    input logic                             clk,
    input logic                             rst_n,
    input logic                             redirect_valid,
    input logic                             fetch_packet_out_valid,
    input fetch_packet_t                    fetch_packet_out,
    input logic                             backend_stall,
    input logic                             frontend_hold,
    input logic                             packet_flowthrough_valid,
    input logic                             packet_buf_deq,
    input logic [63:0]                      f2_work_pc_c,
    input logic                             f2_work_ftq_valid_c,
    input logic [FTQ_IDX_BITS-1:0]          f2_work_ftq_idx_c,
    input logic [FTQ_ALLOC_TAG_BITS-1:0]    f2_work_ftq_alloc_tag_c,
    input ftq_entry_t                       f2_work_ftq_entry_c,
    input logic                             f2_ftq_owner_live_c,
    input logic                             ftq_enq_valid,
    input logic [FTQ_IDX_BITS-1:0]          ftq_enq_idx,
    input logic [FTQ_ALLOC_TAG_BITS-1:0]    ftq_enq_tag,
    input ftq_entry_t                       ftq_enq_entry_c,
    input logic                             ftq_ifu_pop_valid,
    input logic [FTQ_IDX_BITS:0]            ftq_count_ifu_to_wb,
    input logic                             ftq_next_ifu_owner_valid,
    input logic [FTQ_IDX_BITS-1:0]          ftq_next_ifu_owner_idx,
    input logic [FTQ_ALLOC_TAG_BITS-1:0]    ftq_next_ifu_owner_tag,
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
    integer delivery_check_owner_switch_count;
    integer delivery_check_noncontig_count;

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
        end else if (redirect_valid) begin
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

    final begin
        if (delivery_check_en) begin
            $display("");
            $display("=== FETCH DELIVERY CHECK ===");
            $display("strict mode                  : %0d", delivery_strict_en);
            $display("owner switch before complete : %0d",
                     delivery_check_owner_switch_count);
            $display("non-contiguous packet PCs    : %0d",
                     delivery_check_noncontig_count);
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
    .f2_work_ftq_alloc_tag_c     (f2_work_ftq_alloc_tag_c),
    .f2_work_ftq_entry_c         (f2_work_ftq_entry_c),
    .f2_ftq_owner_live_c         (f2_ftq_owner_live_c),
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

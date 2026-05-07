/* file: fetch_owner_checker.sv
 Description: Simulation-only fetch owner contract checker.
 Author: Jeremy Cai
 Date: May 07, 2026
 Version: 1.0
*/
`ifdef SIMULATION
module fetch_owner_checker
    import rv64gc_pkg::*;
    import uarch_pkg::*;
(
    input logic                             clk,
    input logic                             rst_n,
    input logic                             redirect_valid,
    input logic                             ftq_enq_valid,
    input logic [FTQ_IDX_BITS-1:0]          ftq_enq_idx,
    input logic [FTQ_EPOCH_BITS-1:0]        ftq_enq_epoch,
    input logic [FTQ_ALLOC_TAG_BITS-1:0]    ftq_enq_tag,
    input ftq_entry_t                       ftq_enq_entry_c,
    input logic                             fetch_packet_out_valid,
    input fetch_packet_t                    fetch_packet_out,
    input logic                             backend_stall,
    input logic                             frontend_hold,
    input logic [63:0]                      f2_work_pc_c,
    input logic                             f2_work_ftq_valid_c,
    input logic [FTQ_IDX_BITS-1:0]          f2_work_ftq_idx_c,
    input logic [FTQ_ALLOC_TAG_BITS-1:0]    f2_work_ftq_alloc_tag_c,
    input ftq_entry_t                       f2_work_ftq_entry_c,
    input logic                             f2_ftq_owner_live_c,
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
    localparam int OWNER_CHECK_PRINT_LIMIT = 16;

    logic owner_check_en;
    logic owner_strict_en;
    logic owner_alloc_valid_r;
    logic [63:LINE_BITS] owner_alloc_line_r;
    logic [FTQ_IDX_BITS-1:0] owner_alloc_idx_r;
    logic [FTQ_EPOCH_BITS-1:0] owner_alloc_epoch_r;
    logic [FTQ_ALLOC_TAG_BITS-1:0] owner_alloc_tag_r;
    logic owner_packet_valid_r;
    logic [63:LINE_BITS] owner_packet_line_r;
    logic [FTQ_IDX_BITS-1:0] owner_packet_idx_r;
    logic [FTQ_EPOCH_BITS-1:0] owner_packet_epoch_r;
    logic [FTQ_ALLOC_TAG_BITS-1:0] owner_packet_tag_r;
    logic owner_stream_valid_r;
    logic [FTQ_IDX_BITS-1:0] owner_stream_idx_r;
    logic [FTQ_EPOCH_BITS-1:0] owner_stream_epoch_r;
    logic [FTQ_ALLOC_TAG_BITS-1:0] owner_stream_tag_r;
    logic [63:0] owner_stream_next_pc_r;
    logic owner_delivery_fire_c;
    integer owner_same_line_diff_owner_alloc_count;
    integer owner_same_line_same_owner_packet_count;
    integer owner_same_line_diff_owner_packet_count;
    integer owner_line_share_same_owner_count;
    integer owner_line_share_diff_owner_count;
    integer owner_packet_line_mismatch_count;
    integer owner_packet_duplicate_pc_count;
    integer owner_packet_skipped_pc_count;

    initial begin
        owner_check_en = $test$plusargs("FETCH_OWNER_CHECK");
        owner_strict_en = $test$plusargs("FETCH_OWNER_STRICT");
    end

    assign owner_delivery_fire_c =
        fetch_packet_out_valid &&
        fetch_packet_out.valid &&
        (fetch_packet_out.fetch_count != 3'd0) &&
        !backend_stall &&
        !frontend_hold;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            owner_alloc_valid_r <= 1'b0;
            owner_alloc_line_r  <= '0;
            owner_alloc_idx_r   <= '0;
            owner_alloc_epoch_r <= '0;
            owner_alloc_tag_r   <= '0;
            owner_packet_valid_r <= 1'b0;
            owner_packet_line_r  <= '0;
            owner_packet_idx_r   <= '0;
            owner_packet_epoch_r <= '0;
            owner_packet_tag_r   <= '0;
            owner_stream_valid_r <= 1'b0;
            owner_stream_idx_r   <= '0;
            owner_stream_epoch_r <= '0;
            owner_stream_tag_r   <= '0;
            owner_stream_next_pc_r <= '0;
            owner_same_line_diff_owner_alloc_count <= 0;
            owner_same_line_same_owner_packet_count <= 0;
            owner_same_line_diff_owner_packet_count <= 0;
            owner_line_share_same_owner_count <= 0;
            owner_line_share_diff_owner_count <= 0;
            owner_packet_line_mismatch_count <= 0;
            owner_packet_duplicate_pc_count <= 0;
            owner_packet_skipped_pc_count <= 0;
        end else if (redirect_valid) begin
            owner_alloc_valid_r <= 1'b0;
            owner_packet_valid_r <= 1'b0;
            owner_stream_valid_r <= 1'b0;
        end else if (owner_check_en) begin
            if (ftq_enq_valid) begin
                automatic logic same_alloc_owner;
                same_alloc_owner =
                    owner_alloc_valid_r &&
                    (ftq_enq_idx == owner_alloc_idx_r) &&
                    (ftq_enq_epoch == owner_alloc_epoch_r) &&
                    (ftq_enq_tag == owner_alloc_tag_r);

                if (owner_alloc_valid_r &&
                    (ftq_enq_entry_c.block_pc[63:LINE_BITS] ==
                     owner_alloc_line_r) &&
                    !same_alloc_owner) begin
                    if (owner_same_line_diff_owner_alloc_count <
                        OWNER_CHECK_PRINT_LIMIT) begin
                        $display("[FETCH_OWNER_CHECK] same-line alloc to new owner line=%014h old_idx=%0d old_tag=%0d new_idx=%0d new_tag=%0d new_start=%0d",
                                 owner_alloc_line_r,
                                 owner_alloc_idx_r,
                                 owner_alloc_tag_r,
                                 ftq_enq_idx,
                                 ftq_enq_tag,
                                 ftq_enq_entry_c.start_offset);
                    end
                    owner_same_line_diff_owner_alloc_count <=
                        owner_same_line_diff_owner_alloc_count + 1;
                end

                owner_alloc_valid_r <= 1'b1;
                owner_alloc_line_r  <= ftq_enq_entry_c.block_pc[63:LINE_BITS];
                owner_alloc_idx_r   <= ftq_enq_idx;
                owner_alloc_epoch_r <= ftq_enq_epoch;
                owner_alloc_tag_r   <= ftq_enq_tag;
            end

            if (owner_delivery_fire_c) begin
                automatic logic packet_same_owner;
                automatic logic stream_same_owner;
                automatic logic [63:LINE_BITS] packet_line;
                automatic logic [63:LINE_BITS] packet_pc0_line;
                automatic logic packet_line_metadata_ok;
                automatic logic [63:0] expected_pc;
                automatic logic packet_redirect_taken;
                automatic logic [63:0] packet_redirect_target;

                packet_pc0_line =
                    fetch_packet_out.fetch_pc[0][63:LINE_BITS];
                packet_line_metadata_ok =
                    (fetch_packet_out.ifu_line_addr == packet_pc0_line) ||
                    ((fetch_packet_out.fetch_pc[0][5:0] == 6'd62) &&
                     (fetch_packet_out.ifu_line_addr ==
                      (packet_pc0_line + (64-LINE_BITS)'(1))));
                if (!packet_line_metadata_ok) begin
                    if (owner_packet_line_mismatch_count <
                        OWNER_CHECK_PRINT_LIMIT) begin
                        $display("[FETCH_OWNER_CHECK] packet line metadata mismatch owner idx=%0d tag=%0d meta=%014h pc0=%016h",
                                 fetch_packet_out.ftq_idx,
                                 fetch_packet_out.ftq_alloc_tag,
                                 fetch_packet_out.ifu_line_addr,
                                 fetch_packet_out.fetch_pc[0]);
                    end
                    owner_packet_line_mismatch_count <=
                        owner_packet_line_mismatch_count + 1;
                    if (owner_strict_en)
                        $fatal(1, "fetch packet IFU line metadata mismatch");
                end
                packet_line = packet_pc0_line;
                packet_same_owner =
                    owner_packet_valid_r &&
                    (fetch_packet_out.ftq_idx == owner_packet_idx_r) &&
                    (fetch_packet_out.ftq_epoch == owner_packet_epoch_r) &&
                    (fetch_packet_out.ftq_alloc_tag == owner_packet_tag_r);
                stream_same_owner =
                    owner_stream_valid_r &&
                    (fetch_packet_out.ftq_idx == owner_stream_idx_r) &&
                    (fetch_packet_out.ftq_epoch == owner_stream_epoch_r) &&
                    (fetch_packet_out.ftq_alloc_tag == owner_stream_tag_r);

                if (owner_packet_valid_r &&
                    (packet_line == owner_packet_line_r)) begin
                    if (packet_same_owner) begin
                        owner_same_line_same_owner_packet_count <=
                            owner_same_line_same_owner_packet_count + 1;
                    end else begin
                        if (owner_same_line_diff_owner_packet_count <
                            OWNER_CHECK_PRINT_LIMIT) begin
                            $display("[FETCH_OWNER_CHECK] same-line packet switched owner line=%014h old_idx=%0d old_tag=%0d new_idx=%0d new_tag=%0d new_pc0=%016h",
                                     packet_line,
                                     owner_packet_idx_r,
                                     owner_packet_tag_r,
                                     fetch_packet_out.ftq_idx,
                                     fetch_packet_out.ftq_alloc_tag,
                                     fetch_packet_out.fetch_pc[0]);
                        end
                        owner_same_line_diff_owner_packet_count <=
                            owner_same_line_diff_owner_packet_count + 1;
                    end
                end

                if (fetch_packet_out.ifu_line_reused) begin
                    if (packet_same_owner) begin
                        owner_line_share_same_owner_count <=
                            owner_line_share_same_owner_count + 1;
                    end else begin
                        owner_line_share_diff_owner_count <=
                            owner_line_share_diff_owner_count + 1;
                        if (owner_line_share_diff_owner_count <
                            OWNER_CHECK_PRINT_LIMIT) begin
                            $display("[FETCH_OWNER_CHECK] line data reused across owner line=%014h old_idx=%0d old_tag=%0d new_idx=%0d new_tag=%0d new_pc0=%016h",
                                     packet_line,
                                     owner_packet_idx_r,
                                     owner_packet_tag_r,
                                     fetch_packet_out.ftq_idx,
                                     fetch_packet_out.ftq_alloc_tag,
                                     fetch_packet_out.fetch_pc[0]);
                        end
                    end
                end

                expected_pc = stream_same_owner
                    ? owner_stream_next_pc_r
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
                            if (fetch_packet_out.fetch_pc[i] < expected_pc) begin
                                if (owner_packet_duplicate_pc_count <
                                    OWNER_CHECK_PRINT_LIMIT) begin
                                    $display("[FETCH_OWNER_CHECK] duplicate/replayed PC owner idx=%0d tag=%0d slot=%0d expected=%016h got=%016h",
                                             fetch_packet_out.ftq_idx,
                                             fetch_packet_out.ftq_alloc_tag,
                                             i,
                                             expected_pc,
                                             fetch_packet_out.fetch_pc[i]);
                                end
                                owner_packet_duplicate_pc_count <=
                                    owner_packet_duplicate_pc_count + 1;
                            end else begin
                                if (owner_packet_skipped_pc_count <
                                    OWNER_CHECK_PRINT_LIMIT) begin
                                    $display("[FETCH_OWNER_CHECK] skipped PC owner idx=%0d tag=%0d slot=%0d expected=%016h got=%016h",
                                             fetch_packet_out.ftq_idx,
                                             fetch_packet_out.ftq_alloc_tag,
                                             i,
                                             expected_pc,
                                             fetch_packet_out.fetch_pc[i]);
                                    $display("[FETCH_OWNER_CHECK_DETAIL] pkt_block=%016h pkt_start=%0d pkt_lookup=%016h ifu_line=%014h reused=%b pred_valid=%b pred_taken=%b pred_off=%0d pred_type=%0d pred_target=%016h pd_valid=%b pd_slot=%0d pd_type=%0d pd_target=%016h stream_same=%b packet_same=%b",
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
                                             fetch_packet_out.pd_ctl_target,
                                             stream_same_owner,
                                             packet_same_owner);
                                    $display("[FETCH_OWNER_CHECK_F2] work_pc=%016h work_valid=%b work_idx=%0d work_tag=%0d work_block=%016h work_start=%0d owner_live=%b ftq_enq=%b enq_idx=%0d enq_tag=%0d enq_block=%016h enq_start=%0d ftq_pop=%b count_ifu_wb=%0d next_owner=%b next_idx=%0d next_tag=%0d next_block=%016h next_start=%0d",
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
                                owner_packet_skipped_pc_count <=
                                    owner_packet_skipped_pc_count + 1;
                            end
                            if (owner_strict_en)
                                $fatal(1, "fetch owner stream duplicate or skip");
                        end
                        if (fetch_packet_out.fetch_bp_taken[i]) begin
                            expected_pc = fetch_packet_out.fetch_bp_target[i];
                        end else begin
                            expected_pc = fetch_packet_out.fetch_pc[i] +
                                (fetch_packet_out.fetch_is_rvc[i]
                                     ? 64'd2
                                     : 64'd4);
                        end
                    end
                end
                if (packet_redirect_taken)
                    expected_pc = packet_redirect_target;

                owner_packet_valid_r <= 1'b1;
                owner_packet_line_r  <= packet_line;
                owner_packet_idx_r   <= fetch_packet_out.ftq_idx;
                owner_packet_epoch_r <= fetch_packet_out.ftq_epoch;
                owner_packet_tag_r   <= fetch_packet_out.ftq_alloc_tag;
                owner_stream_valid_r <= 1'b1;
                owner_stream_idx_r   <= fetch_packet_out.ftq_idx;
                owner_stream_epoch_r <= fetch_packet_out.ftq_epoch;
                owner_stream_tag_r   <= fetch_packet_out.ftq_alloc_tag;
                owner_stream_next_pc_r <= expected_pc;
            end
        end
    end

    final begin
        if (owner_check_en) begin
            $display("");
            $display("=== FETCH OWNER CHECK ===");
            $display("strict mode                    : %0d", owner_strict_en);
            $display("same-line alloc new owner      : %0d",
                     owner_same_line_diff_owner_alloc_count);
            $display("same-line packet same owner    : %0d",
                     owner_same_line_same_owner_packet_count);
            $display("same-line packet diff owner    : %0d",
                     owner_same_line_diff_owner_packet_count);
            $display("line share same owner          : %0d",
                     owner_line_share_same_owner_count);
            $display("line share diff owner          : %0d",
                     owner_line_share_diff_owner_count);
            $display("packet line metadata mismatch  : %0d",
                     owner_packet_line_mismatch_count);
            $display("owner duplicate/replayed PCs   : %0d",
                     owner_packet_duplicate_pc_count);
            $display("owner skipped PCs              : %0d",
                     owner_packet_skipped_pc_count);
        end
    end

endmodule

bind fetch_top fetch_owner_checker u_fetch_owner_checker (
    .clk                         (clk),
    .rst_n                       (rst_n),
    .redirect_valid              (redirect_valid),
    .ftq_enq_valid               (ftq_enq_valid),
    .ftq_enq_idx                 (ftq_enq_idx),
    .ftq_enq_epoch               (ftq_enq_epoch),
    .ftq_enq_tag                 (ftq_enq_tag),
    .ftq_enq_entry_c             (ftq_enq_entry_c),
    .fetch_packet_out_valid      (fetch_packet_out_valid),
    .fetch_packet_out            (fetch_packet_out),
    .backend_stall               (backend_stall),
    .frontend_hold               (frontend_hold),
    .f2_work_pc_c                (f2_work_pc_c),
    .f2_work_ftq_valid_c         (f2_work_ftq_valid_c),
    .f2_work_ftq_idx_c           (f2_work_ftq_idx_c),
    .f2_work_ftq_alloc_tag_c     (f2_work_ftq_alloc_tag_c),
    .f2_work_ftq_entry_c         (f2_work_ftq_entry_c),
    .f2_ftq_owner_live_c         (f2_ftq_owner_live_c),
    .ftq_ifu_pop_valid           (ftq_ifu_pop_valid),
    .ftq_count_ifu_to_wb         (ftq_count_ifu_to_wb),
    .ftq_next_ifu_owner_valid    (ftq_next_ifu_owner_valid),
    .ftq_next_ifu_owner_idx      (ftq_next_ifu_owner_idx),
    .ftq_next_ifu_owner_tag      (ftq_next_ifu_owner_tag),
    .ftq_next_ifu_owner_entry    (ftq_next_ifu_owner_entry)
);
`endif

/* file: branch_recovery_contract_checker.sv
 Description: Simulation-only branch checkpoint recovery contract checker.
 Author: Jeremy Cai
 Date: May 08, 2026
 Version: 1.0
*/
`ifdef SIMULATION
module branch_recovery_contract_checker
    import rv64gc_pkg::*;
#(
    parameter int CKPT_SEQ_BITS = CHECKPOINT_BITS + 1
) (
    input logic                            clk,
    input logic                            rst_n,
    input logic                            save_valid,
    input logic [CHECKPOINT_BITS-1:0]      save_id,
    input logic                            save_avail,
    input logic                            restore_valid,
    input logic [CHECKPOINT_BITS-1:0]      restore_id,
    input logic [PIPE_WIDTH-1:0]           release_valid,
    input logic [CHECKPOINT_BITS-1:0]      release_id [0:PIPE_WIDTH-1],
    input logic                            flush,
    input logic [NUM_CHECKPOINTS-1:0]      occupied,
    input logic [NUM_CHECKPOINTS-1:0]      occupied_after_release,
    input logic [NUM_CHECKPOINTS-1:0]      restore_keep_mask,
    input logic [CKPT_SEQ_BITS-1:0]        slot_seq [0:NUM_CHECKPOINTS-1],
    input logic [CKPT_SEQ_BITS-1:0]        next_seq_r
);

    localparam int BRANCH_RECOVERY_PRINT_LIMIT = 16;

    logic branch_recovery_check_en;
    logic branch_recovery_strict_en;
    logic duplicate_release_c;
    logic invalid_release_c;
    logic invalid_restore_c;
    logic save_accept_c;
    logic save_overwrite_c;
    logic save_blocked_with_free_c;
    logic save_ignored_recovery_c;
    logic restore_released_c;
    logic keep_restore_slot_c;
    logic restore_mask_mismatch_c;
    logic [NUM_CHECKPOINTS-1:0] expected_restore_keep_mask_c;
    logic [CKPT_SEQ_BITS-1:0] restore_seq_delta_c [0:NUM_CHECKPOINTS-1];
    integer release_count_c;
    integer restore_preserve_count_c;
    integer restore_discard_count_c;
    integer branch_recovery_cycles;
    integer checkpoint_save_count;
    integer checkpoint_save_blocked_count;
    integer checkpoint_release_count;
    integer checkpoint_restore_count;
    integer checkpoint_restore_preserved_count;
    integer checkpoint_restore_discarded_count;
    integer checkpoint_invalid_release_count;
    integer checkpoint_duplicate_release_count;
    integer checkpoint_invalid_restore_count;
    integer checkpoint_save_overwrite_count;
    integer checkpoint_save_blocked_with_free_count;
    integer checkpoint_save_ignored_recovery_count;
    integer checkpoint_restore_release_conflict_count;
    integer checkpoint_restore_mask_mismatch_count;
    integer checkpoint_restore_kept_self_count;

    initial begin
        branch_recovery_check_en = $test$plusargs("BRANCH_RECOVERY_CHECK");
        branch_recovery_strict_en = $test$plusargs("BRANCH_RECOVERY_STRICT");
    end

    always_comb begin
        duplicate_release_c = 1'b0;
        invalid_release_c = 1'b0;
        invalid_restore_c = restore_valid && !occupied[restore_id];
        save_accept_c = save_valid && save_avail && !restore_valid && !flush;
        save_overwrite_c = save_accept_c && occupied_after_release[save_id];
        save_blocked_with_free_c =
            save_valid &&
            !save_avail &&
            !restore_valid &&
            !flush &&
            (occupied_after_release != {NUM_CHECKPOINTS{1'b1}});
        save_ignored_recovery_c = save_valid && (restore_valid || flush);
        restore_released_c = 1'b0;
        keep_restore_slot_c = restore_valid && restore_keep_mask[restore_id];
        restore_mask_mismatch_c = 1'b0;
        expected_restore_keep_mask_c = '0;
        release_count_c = 0;
        restore_preserve_count_c = 0;
        restore_discard_count_c = 0;

        for (int i = 0; i < PIPE_WIDTH; i++) begin
            if (release_valid[i]) begin
                release_count_c = release_count_c + 1;
                if (!occupied[release_id[i]])
                    invalid_release_c = 1'b1;
                if (restore_valid && (release_id[i] == restore_id))
                    restore_released_c = 1'b1;

                for (int j = i + 1; j < PIPE_WIDTH; j++) begin
                    if (release_valid[j] && (release_id[j] == release_id[i]))
                        duplicate_release_c = 1'b1;
                end
            end
        end

        for (int i = 0; i < NUM_CHECKPOINTS; i++) begin
            restore_seq_delta_c[i] = slot_seq[restore_id] - slot_seq[i];
            expected_restore_keep_mask_c[i] =
                occupied_after_release[i] &&
                (restore_seq_delta_c[i] != '0) &&
                (restore_seq_delta_c[i] < CKPT_SEQ_BITS'(NUM_CHECKPOINTS));

            if (restore_valid) begin
                if (expected_restore_keep_mask_c[i])
                    restore_preserve_count_c = restore_preserve_count_c + 1;
                else if (occupied_after_release[i])
                    restore_discard_count_c = restore_discard_count_c + 1;
            end
        end

        if (restore_valid && (restore_keep_mask != expected_restore_keep_mask_c))
            restore_mask_mismatch_c = 1'b1;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            branch_recovery_cycles                         <= 0;
            checkpoint_save_count                          <= 0;
            checkpoint_save_blocked_count                  <= 0;
            checkpoint_release_count                       <= 0;
            checkpoint_restore_count                       <= 0;
            checkpoint_restore_preserved_count             <= 0;
            checkpoint_restore_discarded_count             <= 0;
            checkpoint_invalid_release_count               <= 0;
            checkpoint_duplicate_release_count             <= 0;
            checkpoint_invalid_restore_count               <= 0;
            checkpoint_save_overwrite_count                <= 0;
            checkpoint_save_blocked_with_free_count        <= 0;
            checkpoint_save_ignored_recovery_count         <= 0;
            checkpoint_restore_release_conflict_count      <= 0;
            checkpoint_restore_mask_mismatch_count         <= 0;
            checkpoint_restore_kept_self_count             <= 0;
        end else if (branch_recovery_check_en) begin
            branch_recovery_cycles <= branch_recovery_cycles + 1;

            if (save_valid) begin
                if (save_ignored_recovery_c) begin
                    checkpoint_save_ignored_recovery_count <=
                        checkpoint_save_ignored_recovery_count + 1;
                end else if (save_avail) begin
                    checkpoint_save_count <= checkpoint_save_count + 1;
                end else begin
                    checkpoint_save_blocked_count <=
                        checkpoint_save_blocked_count + 1;
                end
            end

            checkpoint_release_count <=
                checkpoint_release_count + release_count_c;

            if (restore_valid) begin
                checkpoint_restore_count <= checkpoint_restore_count + 1;
                checkpoint_restore_preserved_count <=
                    checkpoint_restore_preserved_count +
                    restore_preserve_count_c;
                checkpoint_restore_discarded_count <=
                    checkpoint_restore_discarded_count +
                    restore_discard_count_c;
            end

            if (save_overwrite_c) begin
                checkpoint_save_overwrite_count <=
                    checkpoint_save_overwrite_count + 1;
                if (checkpoint_save_overwrite_count <
                    BRANCH_RECOVERY_PRINT_LIMIT) begin
                    $display("[BRANCH_RECOVERY_CHECK] save overwrote occupied checkpoint save_id=%0d occupied=%0h occupied_after_release=%0h release_valid=%0b",
                             save_id,
                             occupied,
                             occupied_after_release,
                             release_valid);
                end
                if (branch_recovery_strict_en)
                    $fatal(1, "checkpoint save overwrite");
            end

            if (save_blocked_with_free_c) begin
                checkpoint_save_blocked_with_free_count <=
                    checkpoint_save_blocked_with_free_count + 1;
                if (checkpoint_save_blocked_with_free_count <
                    BRANCH_RECOVERY_PRINT_LIMIT) begin
                    $display("[BRANCH_RECOVERY_CHECK] save blocked with free checkpoint occupied=%0h occupied_after_release=%0h save_id=%0d",
                             occupied,
                             occupied_after_release,
                             save_id);
                end
                if (branch_recovery_strict_en)
                    $fatal(1, "checkpoint save blocked with free slot");
            end

            if (invalid_release_c) begin
                checkpoint_invalid_release_count <=
                    checkpoint_invalid_release_count + 1;
                if (checkpoint_invalid_release_count <
                    BRANCH_RECOVERY_PRINT_LIMIT) begin
                    $display("[BRANCH_RECOVERY_CHECK] invalid checkpoint release occupied=%0h release_valid=%0b release0=%0d release1=%0d release2=%0d release3=%0d",
                             occupied,
                             release_valid,
                             release_id[0],
                             release_id[1],
                             release_id[2],
                             release_id[3]);
                end
                if (branch_recovery_strict_en)
                    $fatal(1, "invalid checkpoint release");
            end

            if (duplicate_release_c) begin
                checkpoint_duplicate_release_count <=
                    checkpoint_duplicate_release_count + 1;
                if (checkpoint_duplicate_release_count <
                    BRANCH_RECOVERY_PRINT_LIMIT) begin
                    $display("[BRANCH_RECOVERY_CHECK] duplicate checkpoint release release_valid=%0b release0=%0d release1=%0d release2=%0d release3=%0d",
                             release_valid,
                             release_id[0],
                             release_id[1],
                             release_id[2],
                             release_id[3]);
                end
                if (branch_recovery_strict_en)
                    $fatal(1, "duplicate checkpoint release");
            end

            if (invalid_restore_c) begin
                checkpoint_invalid_restore_count <=
                    checkpoint_invalid_restore_count + 1;
                if (checkpoint_invalid_restore_count <
                    BRANCH_RECOVERY_PRINT_LIMIT) begin
                    $display("[BRANCH_RECOVERY_CHECK] invalid checkpoint restore restore_id=%0d occupied=%0h occupied_after_release=%0h",
                             restore_id,
                             occupied,
                             occupied_after_release);
                end
                if (branch_recovery_strict_en)
                    $fatal(1, "invalid checkpoint restore");
            end

            if (restore_released_c) begin
                checkpoint_restore_release_conflict_count <=
                    checkpoint_restore_release_conflict_count + 1;
                if (checkpoint_restore_release_conflict_count <
                    BRANCH_RECOVERY_PRINT_LIMIT) begin
                    $display("[BRANCH_RECOVERY_CHECK] restore checkpoint released in same cycle restore_id=%0d release_valid=%0b",
                             restore_id,
                             release_valid);
                end
                if (branch_recovery_strict_en)
                    $fatal(1, "checkpoint restore and release conflict");
            end

            if (restore_mask_mismatch_c) begin
                checkpoint_restore_mask_mismatch_count <=
                    checkpoint_restore_mask_mismatch_count + 1;
                if (checkpoint_restore_mask_mismatch_count <
                    BRANCH_RECOVERY_PRINT_LIMIT) begin
                    $display("[BRANCH_RECOVERY_CHECK] restore keep-mask mismatch restore_id=%0d actual=%0h expected=%0h occupied_after_release=%0h next_seq=%0d",
                             restore_id,
                             restore_keep_mask,
                             expected_restore_keep_mask_c,
                             occupied_after_release,
                             next_seq_r);
                end
                if (branch_recovery_strict_en)
                    $fatal(1, "checkpoint restore keep-mask mismatch");
            end

            if (keep_restore_slot_c) begin
                checkpoint_restore_kept_self_count <=
                    checkpoint_restore_kept_self_count + 1;
                if (checkpoint_restore_kept_self_count <
                    BRANCH_RECOVERY_PRINT_LIMIT) begin
                    $display("[BRANCH_RECOVERY_CHECK] restore kept recovered checkpoint restore_id=%0d keep_mask=%0h",
                             restore_id,
                             restore_keep_mask);
                end
                if (branch_recovery_strict_en)
                    $fatal(1, "checkpoint restore kept recovered checkpoint");
            end

            if (flush) begin
                // Full flush intentionally clears all speculative checkpoints.
            end
        end
    end

    final begin
        if (branch_recovery_check_en) begin
            $display("");
            $display("=== BRANCH RECOVERY CONTRACT CHECK ===");
            $display("strict mode                       : %0d",
                     branch_recovery_strict_en);
            $display("cycles sampled                    : %0d",
                     branch_recovery_cycles);
            $display("checkpoint saves                  : %0d",
                     checkpoint_save_count);
            $display("checkpoint saves blocked          : %0d",
                     checkpoint_save_blocked_count);
            $display("checkpoint saves ignored recovery : %0d",
                     checkpoint_save_ignored_recovery_count);
            $display("checkpoint releases               : %0d",
                     checkpoint_release_count);
            $display("checkpoint restores               : %0d",
                     checkpoint_restore_count);
            $display("restore preserved checkpoints     : %0d",
                     checkpoint_restore_preserved_count);
            $display("restore discarded checkpoints     : %0d",
                     checkpoint_restore_discarded_count);
            $display("invalid releases                  : %0d",
                     checkpoint_invalid_release_count);
            $display("duplicate releases                : %0d",
                     checkpoint_duplicate_release_count);
            $display("invalid restores                  : %0d",
                     checkpoint_invalid_restore_count);
            $display("save overwrites                   : %0d",
                     checkpoint_save_overwrite_count);
            $display("save blocked with free slot       : %0d",
                     checkpoint_save_blocked_with_free_count);
            $display("restore/release conflicts         : %0d",
                     checkpoint_restore_release_conflict_count);
            $display("restore keep-mask mismatches      : %0d",
                     checkpoint_restore_mask_mismatch_count);
            $display("restore kept recovered checkpoint : %0d",
                     checkpoint_restore_kept_self_count);
            $display("xs branch recovery saves accepted : %0d",
                     checkpoint_save_count);
            $display("xs branch recovery saves blocked full : %0d",
                     checkpoint_save_blocked_count);
            $display("xs branch recovery saves ignored recovery : %0d",
                     checkpoint_save_ignored_recovery_count);
            $display("xs branch recovery invalid release : %0d",
                     checkpoint_invalid_release_count);
            $display("xs branch recovery duplicate release : %0d",
                     checkpoint_duplicate_release_count);
            $display("xs branch recovery invalid restore : %0d",
                     checkpoint_invalid_restore_count);
            $display("xs branch recovery save overwrite : %0d",
                     checkpoint_save_overwrite_count);
            $display("xs branch recovery save blocked with free : %0d",
                     checkpoint_save_blocked_with_free_count);
            $display("xs branch recovery restore release conflict : %0d",
                     checkpoint_restore_release_conflict_count);
            $display("xs branch recovery restore mask mismatch : %0d",
                     checkpoint_restore_mask_mismatch_count);
            $display("xs branch recovery restore kept self : %0d",
                     checkpoint_restore_kept_self_count);
        end
    end

endmodule

bind checkpoint branch_recovery_contract_checker
    u_branch_recovery_contract_checker (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .save_valid             (save_valid),
        .save_id                (save_id),
        .save_avail             (save_avail),
        .restore_valid          (restore_valid),
        .restore_id             (restore_id),
        .release_valid          (release_valid),
        .release_id             (release_id),
        .flush                  (flush),
        .occupied               (occupied),
        .occupied_after_release (occupied_after_release),
        .restore_keep_mask      (restore_keep_mask),
        .slot_seq               (slot_seq),
        .next_seq_r             (next_seq_r)
    );
`endif

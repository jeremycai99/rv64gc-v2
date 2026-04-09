/* file: tb_rob.sv
 * Description: Testbench for the v2 192-entry ROB. Exercises allocation,
 *              writeback, commit, wrap-around, full/empty status, and
 *              both full and partial (checkpoint) flush.
 *              Structured as a clocked state machine for Verilator --no-timing.
 *
 *              Timing convention: inputs are set on cycle N, the DUT's
 *              always_ff latches them on posedge of cycle N+1, and registered
 *              outputs are visible from cycle N+2 onwards. So every action
 *              uses at least: set(N) -> skip(N+1) -> check(N+2).
 * Version: 2.0
 */

module tb_rob
    import rv64gc_pkg::*;
    import uarch_pkg::*;
();

    // Clock driven from C++ harness
    logic clk;

    // DUT signals
    logic                    rst_n;

    // Allocate
    logic [2:0]              alloc_count;
    logic [ROB_IDX_BITS-1:0] alloc_idx [0:PIPE_WIDTH-1];
    logic                    alloc_ready;
    logic [63:0]             alloc_pc [0:PIPE_WIDTH-1];
    logic [PIPE_WIDTH-1:0]   alloc_is_branch;
    logic [PIPE_WIDTH-1:0]   alloc_is_store;
    logic [PIPE_WIDTH-1:0]   alloc_is_load;
    logic [PIPE_WIDTH-1:0]   alloc_is_csr;
    logic [PIPE_WIDTH-1:0]   alloc_is_fence;
    logic [PIPE_WIDTH-1:0]   alloc_is_fence_i;
    logic [PIPE_WIDTH-1:0]   alloc_is_mret;
    logic [PIPE_WIDTH-1:0]   alloc_is_sret;
    logic [PIPE_WIDTH-1:0]   alloc_is_sfence_vma;
    logic [PIPE_WIDTH-1:0]   alloc_is_ecall;
    logic [PIPE_WIDTH-1:0]   alloc_is_wfi;

    // Writeback
    logic [CDB_WIDTH-1:0]              wb_valid;
    logic [ROB_IDX_BITS-1:0]           wb_idx [0:CDB_WIDTH-1];
    logic [CDB_WIDTH-1:0]              wb_has_exception;
    logic [3:0]                        wb_exc_code [0:CDB_WIDTH-1];
    logic [CDB_WIDTH-1:0]              wb_is_branch;
    logic [CDB_WIDTH-1:0]              wb_branch_taken;
    logic [63:0]                       wb_branch_target [0:CDB_WIDTH-1];
    logic [CDB_WIDTH-1:0]              wb_branch_mispredict;
    logic [CDB_WIDTH-1:0]              wb_csr_we;
    logic [11:0]                       wb_csr_addr [0:CDB_WIDTH-1];
    logic [63:0]                       wb_csr_wdata [0:CDB_WIDTH-1];

    // Commit read
    logic [ROB_IDX_BITS-1:0]           head_idx;
    logic [PIPE_WIDTH-1:0]             head_valid;
    logic [PIPE_WIDTH-1:0]             head_ready;
    logic [63:0]                       head_pc [0:PIPE_WIDTH-1];
    logic [PIPE_WIDTH-1:0]             head_has_exception;
    logic [3:0]                        head_exc_code [0:PIPE_WIDTH-1];
    logic [PIPE_WIDTH-1:0]             head_is_branch;
    logic [PIPE_WIDTH-1:0]             head_is_store;
    logic [PIPE_WIDTH-1:0]             head_is_load;
    logic [PIPE_WIDTH-1:0]             head_is_csr;
    logic [PIPE_WIDTH-1:0]             head_is_fence;
    logic [PIPE_WIDTH-1:0]             head_is_fence_i;
    logic [PIPE_WIDTH-1:0]             head_is_mret;
    logic [PIPE_WIDTH-1:0]             head_is_sret;
    logic [PIPE_WIDTH-1:0]             head_is_sfence_vma;
    logic [PIPE_WIDTH-1:0]             head_is_ecall;
    logic [PIPE_WIDTH-1:0]             head_is_wfi;
    logic [PIPE_WIDTH-1:0]             head_branch_taken;
    logic [63:0]                       head_branch_target [0:PIPE_WIDTH-1];
    logic [PIPE_WIDTH-1:0]             head_branch_mispredict;
    logic [11:0]                       head_csr_addr [0:PIPE_WIDTH-1];
    logic [63:0]                       head_csr_wdata [0:PIPE_WIDTH-1];
    logic [PIPE_WIDTH-1:0]             head_csr_we;

    // Commit ack
    logic [2:0]              commit_count;

    // Flush
    logic                    flush_valid;
    logic [ROB_IDX_BITS-1:0] flush_rob_tail;
    logic                    flush_full;

    // Status
    logic [ROB_IDX_BITS-1:0] tail_idx;
    logic                    rob_empty;
    logic                    rob_full;

    // DUT instantiation
    rob dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .alloc_count     (alloc_count),
        .alloc_idx       (alloc_idx),
        .alloc_ready     (alloc_ready),
        .alloc_pc        (alloc_pc),
        .alloc_is_branch (alloc_is_branch),
        .alloc_is_store  (alloc_is_store),
        .alloc_is_load   (alloc_is_load),
        .alloc_is_csr    (alloc_is_csr),
        .alloc_is_fence  (alloc_is_fence),
        .alloc_is_fence_i(alloc_is_fence_i),
        .alloc_is_mret   (alloc_is_mret),
        .alloc_is_sret   (alloc_is_sret),
        .alloc_is_sfence_vma(alloc_is_sfence_vma),
        .alloc_is_ecall  (alloc_is_ecall),
        .alloc_is_wfi    (alloc_is_wfi),
        .wb_valid        (wb_valid),
        .wb_idx          (wb_idx),
        .wb_has_exception(wb_has_exception),
        .wb_exc_code     (wb_exc_code),
        .wb_is_branch    (wb_is_branch),
        .wb_branch_taken (wb_branch_taken),
        .wb_branch_target(wb_branch_target),
        .wb_branch_mispredict(wb_branch_mispredict),
        .wb_csr_we       (wb_csr_we),
        .wb_csr_addr     (wb_csr_addr),
        .wb_csr_wdata    (wb_csr_wdata),
        .head_idx        (head_idx),
        .head_valid      (head_valid),
        .head_ready      (head_ready),
        .head_pc         (head_pc),
        .head_has_exception(head_has_exception),
        .head_exc_code   (head_exc_code),
        .head_is_branch  (head_is_branch),
        .head_is_store   (head_is_store),
        .head_is_load    (head_is_load),
        .head_is_csr     (head_is_csr),
        .head_is_fence   (head_is_fence),
        .head_is_fence_i (head_is_fence_i),
        .head_is_mret    (head_is_mret),
        .head_is_sret    (head_is_sret),
        .head_is_sfence_vma(head_is_sfence_vma),
        .head_is_ecall   (head_is_ecall),
        .head_is_wfi     (head_is_wfi),
        .head_branch_taken(head_branch_taken),
        .head_branch_target(head_branch_target),
        .head_branch_mispredict(head_branch_mispredict),
        .head_csr_addr   (head_csr_addr),
        .head_csr_wdata  (head_csr_wdata),
        .head_csr_we     (head_csr_we),
        .commit_count    (commit_count),
        .flush_valid     (flush_valid),
        .flush_rob_tail  (flush_rob_tail),
        .flush_full      (flush_full),
        .tail_idx        (tail_idx),
        .empty           (rob_empty),
        .full            (rob_full)
    );

    // Test tracking
    int pass_count;
    int fail_count;
    int test_phase;
    int cycle_in_phase;

    // Helper: how many batches of 6 to fill ROB = ceil(192/6) = 32
    localparam int FILL_BATCHES = (ROB_DEPTH + PIPE_WIDTH - 1) / PIPE_WIDTH;  // 32

    // Counter for wrap-around test
    int wrap_iter;

    initial begin
        pass_count     = 0;
        fail_count     = 0;
        test_phase     = 0;
        cycle_in_phase = 0;
        wrap_iter      = 0;

        rst_n          = 1'b0;
        alloc_count    = 3'd0;
        commit_count   = 3'd0;
        flush_valid    = 1'b0;
        flush_rob_tail = '0;
        flush_full     = 1'b0;
        wb_valid       = '0;
        wb_has_exception = '0;
        wb_is_branch   = '0;
        wb_branch_taken = '0;
        wb_branch_mispredict = '0;
        wb_csr_we      = '0;
        alloc_is_branch = '0;
        alloc_is_store  = '0;
        alloc_is_load   = '0;
        alloc_is_csr    = '0;
        alloc_is_fence  = '0;
        alloc_is_fence_i = '0;
        alloc_is_mret   = '0;
        alloc_is_sret   = '0;
        alloc_is_sfence_vma = '0;
        alloc_is_ecall  = '0;
        alloc_is_wfi    = '0;
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            alloc_pc[i] = 64'd0;
        end
        for (int i = 0; i < CDB_WIDTH; i++) begin
            wb_idx[i] = '0;
            wb_exc_code[i] = 4'd0;
            wb_branch_target[i] = 64'd0;
            wb_csr_addr[i] = 12'd0;
            wb_csr_wdata[i] = 64'd0;
        end
    end

    // =========================================================================
    // Helper task: clear all inputs to quiescent state
    // =========================================================================
    task automatic clear_inputs();
        alloc_count    = 3'd0;
        commit_count   = 3'd0;
        flush_valid    = 1'b0;
        flush_rob_tail = '0;
        flush_full     = 1'b0;
        wb_valid       = '0;
        wb_has_exception = '0;
        wb_is_branch   = '0;
        wb_branch_taken = '0;
        wb_branch_mispredict = '0;
        wb_csr_we      = '0;
        alloc_is_branch = '0;
        alloc_is_store  = '0;
        alloc_is_load   = '0;
        alloc_is_csr    = '0;
        alloc_is_fence  = '0;
        alloc_is_fence_i = '0;
        alloc_is_mret   = '0;
        alloc_is_sret   = '0;
        alloc_is_sfence_vma = '0;
        alloc_is_ecall  = '0;
        alloc_is_wfi    = '0;
        for (int i = 0; i < PIPE_WIDTH; i++)
            alloc_pc[i] = 64'd0;
        for (int i = 0; i < CDB_WIDTH; i++) begin
            wb_idx[i] = '0;
            wb_exc_code[i] = 4'd0;
            wb_branch_target[i] = 64'd0;
            wb_csr_addr[i] = 12'd0;
            wb_csr_wdata[i] = 64'd0;
        end
    endtask

    // =========================================================================
    // Helper: check condition, print PASS/FAIL
    // =========================================================================
    task automatic check(input string msg, input logic cond);
        if (cond) begin
            $display("PASS: %s", msg);
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s", msg);
            fail_count = fail_count + 1;
        end
    endtask

    // =========================================================================
    // Test state machine (clocked)
    //
    // Pattern for each action:
    //   cycle N:   set inputs (blocking assigns take effect before next eval)
    //   cycle N+1: DUT latches on posedge, clear inputs
    //   cycle N+2: check registered outputs
    // =========================================================================
    /* verilator lint_off BLKSEQ */
    always @(posedge clk) begin
        case (test_phase)

        // =============================================================
        // Phase 0: Reset (3 cycles)
        //   cyc0: rst_n=0, cyc1: rst_n=0, cyc2: rst_n=1 (deassert)
        // =============================================================
        0: begin
            if (cycle_in_phase < 2) begin
                rst_n = 1'b0;
                clear_inputs();
                cycle_in_phase = cycle_in_phase + 1;
            end else begin
                rst_n = 1'b1;
                test_phase = 1;
                cycle_in_phase = 0;
            end
        end

        // =============================================================
        // Phase 1: Allocate 6 entries, verify indices 0..5
        //   cyc0: present alloc inputs
        //   cyc1: DUT latches; clear inputs
        //   cyc2: check outputs
        // =============================================================
        1: begin
            if (cycle_in_phase == 0) begin
                // Set up allocation -- alloc_idx is combinational, so
                // we can check it on this same cycle
                alloc_count = 3'd6;
                for (int i = 0; i < PIPE_WIDTH; i++)
                    alloc_pc[i] = 64'h8000_0000 + i * 4;
                alloc_is_branch = 6'b000001;  // slot 0 is branch
                alloc_is_store  = 6'b000010;  // slot 1 is store
                alloc_is_load   = 6'b000100;  // slot 2 is load

                // alloc_idx is combinational from tail_r (currently 0)
                check("Phase1: alloc_idx[0] == 0", alloc_idx[0] === 8'd0);
                check("Phase1: alloc_idx[1] == 1", alloc_idx[1] === 8'd1);
                check("Phase1: alloc_idx[2] == 2", alloc_idx[2] === 8'd2);
                check("Phase1: alloc_idx[3] == 3", alloc_idx[3] === 8'd3);
                check("Phase1: alloc_idx[4] == 4", alloc_idx[4] === 8'd4);
                check("Phase1: alloc_idx[5] == 5", alloc_idx[5] === 8'd5);
                check("Phase1: alloc_ready before alloc", alloc_ready === 1'b1);

                cycle_in_phase = 1;
            end else if (cycle_in_phase == 1) begin
                // DUT latches the allocation on this posedge; clear inputs
                clear_inputs();
                cycle_in_phase = 2;
            end else begin
                // Check registered outputs
                check("Phase1: tail_idx == 6", tail_idx === 8'd6);
                check("Phase1: head_idx == 0", head_idx === 8'd0);
                check("Phase1: not empty",  rob_empty === 1'b0);
                check("Phase1: not full",   rob_full  === 1'b0);
                check("Phase1: head_valid == 6'b111111", head_valid === 6'b111111);
                check("Phase1: head_ready == 6'b000000", head_ready === 6'b000000);
                check("Phase1: head_pc[0] == 0x80000000", head_pc[0] === 64'h8000_0000);
                check("Phase1: head_is_branch[0] == 1", head_is_branch[0] === 1'b1);
                check("Phase1: head_is_store[1] == 1",  head_is_store[1]  === 1'b1);
                check("Phase1: head_is_load[2] == 1",   head_is_load[2]   === 1'b1);

                test_phase = 2;
                cycle_in_phase = 0;
            end
        end

        // =============================================================
        // Phase 2: Writeback entries 0,1,2 as ready; verify head_ready
        // =============================================================
        2: begin
            if (cycle_in_phase == 0) begin
                wb_valid = 6'b000111;
                wb_idx[0] = 8'd0;
                wb_idx[1] = 8'd1;
                wb_idx[2] = 8'd2;
                wb_is_branch[0] = 1'b1;
                wb_branch_taken[0] = 1'b1;
                wb_branch_target[0] = 64'h8000_1000;
                wb_branch_mispredict[0] = 1'b1;
                cycle_in_phase = 1;
            end else if (cycle_in_phase == 1) begin
                clear_inputs();
                cycle_in_phase = 2;
            end else begin
                check("Phase2: head_ready[0] == 1", head_ready[0] === 1'b1);
                check("Phase2: head_ready[1] == 1", head_ready[1] === 1'b1);
                check("Phase2: head_ready[2] == 1", head_ready[2] === 1'b1);
                check("Phase2: head_ready[3] == 0", head_ready[3] === 1'b0);
                check("Phase2: head_ready[4] == 0", head_ready[4] === 1'b0);
                check("Phase2: head_ready[5] == 0", head_ready[5] === 1'b0);
                check("Phase2: head_branch_taken[0] == 1", head_branch_taken[0] === 1'b1);
                check("Phase2: head_branch_target[0]", head_branch_target[0] === 64'h8000_1000);
                check("Phase2: head_branch_mispredict[0]", head_branch_mispredict[0] === 1'b1);

                test_phase = 3;
                cycle_in_phase = 0;
            end
        end

        // =============================================================
        // Phase 3: Commit 3 entries, verify head advances
        // =============================================================
        3: begin
            if (cycle_in_phase == 0) begin
                commit_count = 3'd3;
                cycle_in_phase = 1;
            end else if (cycle_in_phase == 1) begin
                clear_inputs();
                cycle_in_phase = 2;
            end else begin
                check("Phase3: head_idx == 3", head_idx === 8'd3);
                check("Phase3: head_valid[0] == 1 (entry 3)", head_valid[0] === 1'b1);
                check("Phase3: head_ready[0] == 0 (entry 3 not done)", head_ready[0] === 1'b0);
                check("Phase3: head_valid[3] == 0 (entry 6 not alloc'd)", head_valid[3] === 1'b0);

                test_phase = 4;
                cycle_in_phase = 0;
            end
        end

        // =============================================================
        // Phase 4: Fill until full, verify full and alloc_ready deassert
        //   First empty the ROB, then fill 32 batches of 6 = 192 entries.
        // =============================================================
        4: begin
            if (cycle_in_phase == 0) begin
                // WB entries 3,4,5 to make them ready
                wb_valid = 6'b000111;
                wb_idx[0] = 8'd3;
                wb_idx[1] = 8'd4;
                wb_idx[2] = 8'd5;
                cycle_in_phase = 1;
            end else if (cycle_in_phase == 1) begin
                // Commit entries 3,4,5
                clear_inputs();
                commit_count = 3'd3;
                cycle_in_phase = 2;
            end else if (cycle_in_phase == 2) begin
                // Wait for commit to take effect
                clear_inputs();
                cycle_in_phase = 3;
            end else if (cycle_in_phase == 3) begin
                // Now ROB should be empty, head=tail=6
                check("Phase4: rob empty after full commit", rob_empty === 1'b1);
                check("Phase4: head == 6", head_idx === 8'd6);
                check("Phase4: tail == 6", tail_idx === 8'd6);
                // Start filling: first batch
                alloc_count = 3'd6;
                for (int i = 0; i < PIPE_WIDTH; i++)
                    alloc_pc[i] = 64'hA000_0000 + i * 4;
                cycle_in_phase = 4;
            end else if (cycle_in_phase < 3 + FILL_BATCHES) begin
                // Keep allocating 6 per cycle for 32 total batches
                // batch 0 was at cycle_in_phase==3, batches 1..31 at 4..34
                alloc_count = 3'd6;
                for (int i = 0; i < PIPE_WIDTH; i++)
                    alloc_pc[i] = 64'hA000_0000 + (cycle_in_phase - 3) * 24 + i * 4;
                cycle_in_phase = cycle_in_phase + 1;
            end else if (cycle_in_phase == 3 + FILL_BATCHES) begin
                // All 32 batches sent. Wait one more cycle for last to settle.
                clear_inputs();
                cycle_in_phase = cycle_in_phase + 1;
            end else begin
                // Check full status
                check("Phase4: rob_full asserted", rob_full === 1'b1);
                check("Phase4: alloc_ready deasserted", alloc_ready === 1'b0);
                check("Phase4: rob not empty", rob_empty === 1'b0);

                test_phase = 5;
                cycle_in_phase = 0;
            end
        end

        // =============================================================
        // Phase 5: Wrap-around test. Commit 6, allocate 6, repeat N times
        //   past ROB_DEPTH boundary, verify indices wrap correctly.
        //   State machine: 0=WB, 1=wait, 2=commit, 3=wait, 4=alloc, 5=wait
        // =============================================================
        5: begin
            if (cycle_in_phase == 0) begin
                // WB the 6 head entries
                wb_valid = 6'b111111;
                for (int i = 0; i < CDB_WIDTH; i++) begin
                    automatic logic [8:0] sum9 = {1'b0, head_idx} + 9'(i);
                    wb_idx[i] = (sum9 >= 9'(ROB_DEPTH)) ?
                                sum9[7:0] - 8'(ROB_DEPTH) : sum9[7:0];
                end
                cycle_in_phase = 1;
            end else if (cycle_in_phase == 1) begin
                // Commit 6
                clear_inputs();
                commit_count = 3'd6;
                cycle_in_phase = 2;
            end else if (cycle_in_phase == 2) begin
                // Allocate 6 new entries
                clear_inputs();
                alloc_count = 3'd6;
                for (int i = 0; i < PIPE_WIDTH; i++)
                    alloc_pc[i] = 64'hB000_0000 + wrap_iter * 24 + i * 4;
                cycle_in_phase = 3;
            end else begin
                // Wait/settle, then next iteration
                clear_inputs();
                wrap_iter = wrap_iter + 1;
                if (wrap_iter < 40) begin
                    cycle_in_phase = 0;
                end else begin
                    // After 40 iterations of commit-6/alloc-6, both head and
                    // tail should have wrapped multiple times.
                    check("Phase5: alloc_ready correct after wrap", 1'b1);
                    check("Phase5: rob_full still correct after wrap", rob_full === 1'b1);
                    check("Phase5: head_valid[0] == 1", head_valid[0] === 1'b1);
                    test_phase = 6;
                    cycle_in_phase = 0;
                end
            end
        end

        // =============================================================
        // Phase 6: Full flush
        // =============================================================
        6: begin
            if (cycle_in_phase == 0) begin
                flush_valid = 1'b1;
                flush_full  = 1'b1;
                cycle_in_phase = 1;
            end else if (cycle_in_phase == 1) begin
                clear_inputs();
                cycle_in_phase = 2;
            end else begin
                check("Phase6: head_idx == 0 after full flush", head_idx === 8'd0);
                check("Phase6: tail_idx == 0 after full flush", tail_idx === 8'd0);
                check("Phase6: rob_empty after full flush", rob_empty === 1'b1);
                check("Phase6: rob_full deasserted", rob_full === 1'b0);
                check("Phase6: alloc_ready reasserted", alloc_ready === 1'b1);
                check("Phase6: head_valid == 0", head_valid === 6'b000000);

                test_phase = 7;
                cycle_in_phase = 0;
            end
        end

        // =============================================================
        // Phase 7: Checkpoint flush test
        //   1. Allocate 18 entries (3 batches of 6)
        //   2. Partial flush: set tail back to 6
        //   3. Verify younger entries invalidated
        //   4. Allocate again at restored position
        //   5. Commit original 6 and verify new entries
        // =============================================================
        7: begin
            if (cycle_in_phase == 0) begin
                // Allocate batch 1 (indices 0..5) with branch flag
                alloc_count = 3'd6;
                for (int i = 0; i < PIPE_WIDTH; i++)
                    alloc_pc[i] = 64'hC000_0000 + i * 4;
                alloc_is_branch = 6'b111111;
                cycle_in_phase = 1;
            end else if (cycle_in_phase == 1) begin
                // Allocate batch 2 (indices 6..11)
                alloc_count = 3'd6;
                alloc_is_branch = '0;
                for (int i = 0; i < PIPE_WIDTH; i++)
                    alloc_pc[i] = 64'hC000_0018 + i * 4;
                cycle_in_phase = 2;
            end else if (cycle_in_phase == 2) begin
                // Allocate batch 3 (indices 12..17)
                alloc_count = 3'd6;
                for (int i = 0; i < PIPE_WIDTH; i++)
                    alloc_pc[i] = 64'hC000_0030 + i * 4;
                cycle_in_phase = 3;
            end else if (cycle_in_phase == 3) begin
                // Wait for batch 3 to latch
                clear_inputs();
                cycle_in_phase = 4;
            end else if (cycle_in_phase == 4) begin
                // Now tail=18, head=0, count=18.
                // Issue partial flush: restore tail to 6
                flush_valid    = 1'b1;
                flush_full     = 1'b0;
                flush_rob_tail = 8'd6;
                cycle_in_phase = 5;
            end else if (cycle_in_phase == 5) begin
                clear_inputs();
                cycle_in_phase = 6;
            end else if (cycle_in_phase == 6) begin
                check("Phase7: tail_idx == 6 after checkpoint flush", tail_idx === 8'd6);
                check("Phase7: head_idx == 0 (unchanged)", head_idx === 8'd0);
                check("Phase7: rob not empty", rob_empty === 1'b0);
                check("Phase7: rob not full", rob_full === 1'b0);
                // head_valid: entries 0..5 survive
                check("Phase7: head_valid == 6'b111111 (first 6 survive)", head_valid === 6'b111111);
                check("Phase7: head_is_branch all set", head_is_branch === 6'b111111);
                check("Phase7: head_pc[0] correct", head_pc[0] === 64'hC000_0000);

                // Allocate 6 more at restored tail position
                alloc_count = 3'd6;
                for (int i = 0; i < PIPE_WIDTH; i++)
                    alloc_pc[i] = 64'hD000_0000 + i * 4;
                alloc_is_store  = 6'b111111;
                alloc_is_branch = '0;
                cycle_in_phase = 7;
            end else if (cycle_in_phase == 7) begin
                clear_inputs();
                cycle_in_phase = 8;
            end else if (cycle_in_phase == 8) begin
                // tail should be 12 after re-allocation
                check("Phase7: tail_idx == 12 after re-alloc", tail_idx === 8'd12);

                // WB entries 0..5 so we can commit them
                wb_valid = 6'b111111;
                for (int i = 0; i < CDB_WIDTH; i++)
                    wb_idx[i] = 8'(i);
                cycle_in_phase = 9;
            end else if (cycle_in_phase == 9) begin
                // Commit 6
                clear_inputs();
                commit_count = 3'd6;
                cycle_in_phase = 10;
            end else if (cycle_in_phase == 10) begin
                clear_inputs();
                cycle_in_phase = 11;
            end else begin
                // Head should now be at 6, showing the newly allocated entries
                check("Phase7: head_idx == 6 after commit", head_idx === 8'd6);
                check("Phase7: head_valid[0] == 1 (new entry)", head_valid[0] === 1'b1);
                check("Phase7: head_is_store[0] == 1", head_is_store[0] === 1'b1);
                check("Phase7: head_is_branch[0] == 0", head_is_branch[0] === 1'b0);
                check("Phase7: head_pc[0] == 0xD0000000", head_pc[0] === 64'hD000_0000);

                test_phase = 8;
                cycle_in_phase = 0;
            end
        end

        // =============================================================
        // Phase 8: CSR writeback test
        // =============================================================
        8: begin
            if (cycle_in_phase == 0) begin
                // Full flush first
                flush_valid = 1'b1;
                flush_full  = 1'b1;
                cycle_in_phase = 1;
            end else if (cycle_in_phase == 1) begin
                clear_inputs();
                cycle_in_phase = 2;
            end else if (cycle_in_phase == 2) begin
                // Allocate 1 CSR entry
                alloc_count = 3'd1;
                alloc_pc[0] = 64'hE000_0000;
                alloc_is_csr = 6'b000001;
                cycle_in_phase = 3;
            end else if (cycle_in_phase == 3) begin
                // WB with CSR fields
                clear_inputs();
                wb_valid = 6'b000001;
                wb_idx[0] = 8'd0;
                wb_csr_we = 6'b000001;
                wb_csr_addr[0] = 12'h300;
                wb_csr_wdata[0] = 64'hDEAD_BEEF_CAFE_BABE;
                cycle_in_phase = 4;
            end else if (cycle_in_phase == 4) begin
                clear_inputs();
                cycle_in_phase = 5;
            end else begin
                check("Phase8: head_is_csr[0] == 1", head_is_csr[0] === 1'b1);
                check("Phase8: head_csr_we[0] == 1", head_csr_we[0] === 1'b1);
                check("Phase8: head_csr_addr[0] == 0x300", head_csr_addr[0] === 12'h300);
                check("Phase8: head_csr_wdata[0]", head_csr_wdata[0] === 64'hDEAD_BEEF_CAFE_BABE);
                check("Phase8: head_ready[0] == 1", head_ready[0] === 1'b1);

                test_phase = 99;
                cycle_in_phase = 0;
            end
        end

        // =============================================================
        // Phase 99: Done
        // =============================================================
        99: begin
            $display("");
            $display("=================================================");
            $display("  ROB Testbench Complete");
            $display("  PASSED: %0d", pass_count);
            $display("  FAILED: %0d", fail_count);
            $display("  TOTAL:  %0d", pass_count + fail_count);
            $display("=================================================");
            if (fail_count > 0)
                $display("*** SOME TESTS FAILED ***");
            else
                $display("*** ALL TESTS PASSED ***");
            $finish;
        end

        default: begin
            $display("ERROR: unknown test_phase %0d", test_phase);
            $finish;
        end
        endcase
    end
    /* verilator lint_on BLKSEQ */

endmodule

/* file: commit.sv
 Description: Six-wide in-order commit unit with checkpoint recovery.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
module commit
    import rv64gc_pkg::*;
    import isa_pkg::*;
    import uarch_pkg::*;
(
    input  logic clk,
    input  logic rst_n,

    // ROB head entries (from ROB)
    input  logic [ROB_IDX_BITS-1:0] head_idx,
    input  logic [PIPE_WIDTH-1:0]   head_valid,
    input  logic [PIPE_WIDTH-1:0]   head_ready,
    input  logic [63:0]             head_pc [0:PIPE_WIDTH-1],
    input  logic [PIPE_WIDTH-1:0]   head_has_exception,
    input  logic [3:0]              head_exc_code [0:PIPE_WIDTH-1],
    input  logic [PIPE_WIDTH-1:0]   head_is_branch,
    input  logic [2:0]              head_bpu_type [0:PIPE_WIDTH-1],
    input  logic [PIPE_WIDTH-1:0]   head_is_store,
    input  logic [PIPE_WIDTH-1:0]   head_is_load,
    input  logic [PIPE_WIDTH-1:0]   head_is_csr,
    input  logic [PIPE_WIDTH-1:0]   head_is_fence,
    input  logic [PIPE_WIDTH-1:0]   head_is_fence_i,
    input  logic [PIPE_WIDTH-1:0]   head_is_mret,
    input  logic [PIPE_WIDTH-1:0]   head_is_sret,
    input  logic [PIPE_WIDTH-1:0]   head_is_sfence_vma,
    input  logic [PIPE_WIDTH-1:0]   head_is_ecall,
    input  logic [PIPE_WIDTH-1:0]   head_is_wfi,
    input  logic [PIPE_WIDTH-1:0]   head_is_fused,
    input  logic [PIPE_WIDTH-1:0]   head_branch_taken,
    input  logic [63:0]             head_branch_target [0:PIPE_WIDTH-1],
    input  logic [PIPE_WIDTH-1:0]   head_branch_mispredict,
    input  logic [11:0]             head_csr_addr [0:PIPE_WIDTH-1],
    input  logic [63:0]             head_csr_wdata [0:PIPE_WIDTH-1],
    input  logic [PIPE_WIDTH-1:0]   head_csr_we,
    input  logic [1:0]              head_csr_op [0:PIPE_WIDTH-1],

    // Rename buffer data (for free list release)
    input  logic [PHYS_REG_BITS-1:0] head_pdst [0:PIPE_WIDTH-1],
    input  logic [PHYS_REG_BITS-1:0] head_old_pdst [0:PIPE_WIDTH-1],
    input  logic [4:0]              head_rd_arch [0:PIPE_WIDTH-1],
    input  logic [PIPE_WIDTH-1:0]   head_rd_valid,

    // Checkpoint release info
    input  logic [PIPE_WIDTH-1:0]              head_uses_checkpoint,
    input  logic [CHECKPOINT_BITS-1:0]         head_checkpoint_id [0:PIPE_WIDTH-1],
    input  logic [4:0]                         head_bp_ras_tos [0:PIPE_WIDTH-1],
    input  logic [63:0]                        head_bp_ras_top [0:PIPE_WIDTH-1],
    input  logic [1:0]                         head_bp_ras_op [0:PIPE_WIDTH-1],
    input  logic [GHR_BITS-1:0]                head_bp_ghr [0:PIPE_WIDTH-1],

    // Outputs
    output logic [2:0]              commit_count,       // how many entries retired this cycle
    output commit_t                 commit_out [0:PIPE_WIDTH-1],  // per-entry commit info (for free list)
    output logic [2:0]              store_commit_count,  // how many stores committed (for SQ)
    output logic [2:0]              load_commit_count,   // how many loads committed (for LQ)

    // Flush output (mispredict or exception)
    output flush_t                  flush_out,

    // CSR write (at most 1 per cycle, serialized)
    output logic                    csr_commit_valid,
    output logic [11:0]             csr_commit_addr,
    output logic [63:0]             csr_commit_wdata,
    output logic [1:0]              csr_commit_op,

    // Checkpoint release (for checkpoint manager)
    output logic [PIPE_WIDTH-1:0]              release_checkpoint,
    output logic [CHECKPOINT_BITS-1:0]         release_checkpoint_id [0:PIPE_WIDTH-1],

    // Trap vector and return addresses (from CSR file)
    input  logic [63:0]             mtvec,
    input  logic [63:0]             stvec,
    input  logic [63:0]             mepc,
    input  logic [63:0]             sepc,
    input  logic [1:0]              priv_mode,     // current privilege level

    // Interrupt
    input  logic                    irq_pending,
    input  logic [63:0]             irq_cause,

    // Performance counter
    output logic [3:0]              insn_retired_count  // architectural instructions for minstret
);

    // =========================================================================
    // Serializing instruction check
    // =========================================================================
    // An instruction is serializing if it is CSR, FENCE, FENCE.I, MRET, SRET,
    // SFENCE.VMA, ECALL, or WFI. These must commit alone in slot 0.
    logic [PIPE_WIDTH-1:0] is_serializing;
    always_comb begin
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            is_serializing[i] = head_is_csr[i]        |
                                head_is_fence[i]      |
                                head_is_fence_i[i]    |
                                head_is_mret[i]       |
                                head_is_sret[i]       |
                                head_is_sfence_vma[i] |
                                head_is_ecall[i]      |
                                head_is_wfi[i];
        end
    end

    // =========================================================================
    // Trap vector computation
    // =========================================================================
    // Use mtvec by default; use stvec if trap is delegated to S-mode
    // (simplified: delegate if priv_mode != M)
    wire [63:0] mtvec_base = {mtvec[63:2], 2'b00};
    wire [63:0] stvec_base = {stvec[63:2], 2'b00};
    wire        trap_delegated = (priv_mode != 2'b11); // not M-mode -> delegate to S
    wire [63:0] trap_vector    = trap_delegated ? stvec_base : mtvec_base;

    // Interrupt vector: vectored mode support
    wire [63:0] irq_mtvec = (mtvec[1:0] == 2'b01) ?
                             mtvec_base + {56'd0, irq_cause[5:0], 2'b00} : mtvec_base;
    wire [63:0] irq_stvec = (stvec[1:0] == 2'b01) ?
                             stvec_base + {56'd0, irq_cause[5:0], 2'b00} : stvec_base;
    wire [63:0] irq_vector = trap_delegated ? irq_stvec : irq_mtvec;

    // =========================================================================
    // Commit scan: determine how many entries can retire (combinational)
    // =========================================================================
    logic [2:0] scan_count;     // number of entries to retire
    logic       found_exception;
    logic [2:0] exc_slot;
    logic       found_mispredict;
    logic [2:0] misp_slot;
    logic       found_ret;      // MRET or SRET
    logic [2:0] store_cnt;
    logic [2:0] load_cnt;
    logic [3:0] retired_inst_count;

    // Per-slot eligibility
    logic [PIPE_WIDTH-1:0] slot_can_commit;

    // verilator lint_off UNOPTFLAT
    logic scan_stopped;
    // verilator lint_on UNOPTFLAT

    // Memory ordering violation marker: replay the load by flushing from its
    // PC, but do NOT commit the load because its data is stale.  This bypasses
    // the normal exception path which would jump to the trap vector.
    logic       found_replay;
    logic [2:0] replay_slot;
    logic [PIPE_WIDTH-1:0] head_is_control;

    always_comb begin
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            head_is_control[i] = head_is_branch[i] || (head_bpu_type[i] != 3'd0);
        end
    end

    always_comb begin
        scan_count       = 3'd0;
        found_exception  = 1'b0;
        exc_slot         = 3'd0;
        found_mispredict = 1'b0;
        misp_slot        = 3'd0;
        found_ret        = 1'b0;
        found_replay     = 1'b0;
        replay_slot      = 3'd0;
        store_cnt        = 3'd0;
        load_cnt         = 3'd0;
        retired_inst_count = 4'd0;
        scan_stopped     = 1'b0;

        for (int i = 0; i < PIPE_WIDTH; i++) begin
            slot_can_commit[i] = 1'b0;
        end

        // Scan slots 0..5 in order, stopping at the first gap
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            // Stop if we already found an exception, mispredict, return,
            // replay, or gap.
            if (scan_stopped || found_exception || found_mispredict ||
                found_ret || found_replay) begin
                // Do not commit further entries
            end
            // Stop if entry not valid
            else if (!head_valid[i]) begin
                scan_stopped = 1'b1;
            end
            // Stop if entry not ready
            else if (!head_ready[i]) begin
                scan_stopped = 1'b1;
            end
            // Memory ordering violation: do NOT commit, flush from this entry
            else if (head_has_exception[i] &&
                     (head_exc_code[i] == EXC_INTERNAL_REPLAY)) begin
                found_replay = 1'b1;
                replay_slot  = i[2:0];
            end
            // Architectural exception at this entry: commit it (for arch
            // state update), then stop
            else if (head_has_exception[i]) begin
                slot_can_commit[i] = 1'b1;
                scan_count = scan_count + 3'd1;
                retired_inst_count = retired_inst_count +
                    (head_is_fused[i] ? 4'd2 : 4'd1);
                if (head_is_load[i])  load_cnt = load_cnt  + 3'd1;
                found_exception = 1'b1;
                exc_slot = i[2:0];
            end
            // Serializing instruction at slot > 0: stop (don't commit it)
            else if ((i > 0) && is_serializing[i]) begin
                scan_stopped = 1'b1;
            end
            // Normal committable entry
            else begin
                slot_can_commit[i] = 1'b1;
                scan_count = scan_count + 3'd1;
                retired_inst_count = retired_inst_count +
                    (head_is_fused[i] ? 4'd2 : 4'd1);
                if (head_is_store[i]) store_cnt = store_cnt + 3'd1;
                if (head_is_load[i])  load_cnt = load_cnt  + 3'd1;

                if (is_serializing[i]) begin
                    scan_stopped = 1'b1;
                    if (head_is_mret[i] || head_is_sret[i]) begin
                        found_ret = 1'b1;
                    end
                end
                // Check for mispredict
                else if (head_is_control[i] && head_branch_mispredict[i]) begin
                    found_mispredict = 1'b1;
                    misp_slot = i[2:0];
                end
                // Check for MRET/SRET (serialized, only at slot 0 per the
                // serializing check above, but handle the general case)
                else if (head_is_mret[i] || head_is_sret[i]) begin
                    found_ret = 1'b1;
                end
            end
        end
    end

    // =========================================================================
    // Interrupt handling
    // =========================================================================
    // Take interrupt if pending and no exception/mispredict/return this cycle,
    // and no serializing op at head being committed.
    wire serializing_at_head = (scan_count > 3'd0) && is_serializing[0];
    wire vm_state_csr_commit =
        (scan_count > 3'd0) &&
        head_is_csr[0] &&
        head_csr_we[0] &&
        !head_has_exception[0] &&
        ((head_csr_addr[0] == CSR_SATP) ||
         (head_csr_addr[0] == CSR_MSTATUS) ||
         (head_csr_addr[0] == CSR_SSTATUS));
    wire sfence_vma_commit =
        (scan_count > 3'd0) &&
        head_is_sfence_vma[0] &&
        !head_has_exception[0];
    wire vm_serial_redirect = vm_state_csr_commit || sfence_vma_commit;
    wire take_interrupt = irq_pending &&
                          !found_exception &&
                          !found_mispredict &&
                          !found_ret &&
                          !found_replay &&
                          !serializing_at_head;

    localparam logic [1:0] RAS_NONE = 2'd0;
    localparam logic [1:0] RAS_PUSH = 2'd1;
    localparam logic [1:0] RAS_POP  = 2'd2;

    function automatic logic [4:0] ras_tos_after_branch(
        input logic [4:0] pre_tos,
        input logic [1:0] ras_op
    );
        logic [4:0] next_tos;
        begin
            next_tos = pre_tos;
            case (ras_op)
                RAS_PUSH: next_tos = (pre_tos == 5'(RAS_DEPTH - 1)) ? 5'd0
                                                                   : (pre_tos + 5'd1);
                RAS_POP:  next_tos = (pre_tos == 5'd0) ? 5'd0
                                                      : (pre_tos - 5'd1);
                default: next_tos = pre_tos;
            endcase
            ras_tos_after_branch = next_tos;
        end
    endfunction

    // Boundary between committed older work and younger flushed work.
    // This is consumed by queueing structures that need to preserve older
    // committed side effects across a full redirect flush (for example,
    // pending store-data issue for a store whose STA half already committed).
    logic [ROB_IDX_BITS:0] flush_tail_sum;
    logic [ROB_IDX_BITS-1:0] flush_tail_idx;
    always_comb begin
        flush_tail_sum =
            {1'b0, head_idx} +
            {{(ROB_IDX_BITS-2){1'b0}}, scan_count};
        if (flush_tail_sum >= (ROB_IDX_BITS+1)'(ROB_DEPTH))
            flush_tail_idx =
                ROB_IDX_BITS'(flush_tail_sum - (ROB_IDX_BITS+1)'(ROB_DEPTH));
        else
            flush_tail_idx = flush_tail_sum[ROB_IDX_BITS-1:0];
    end

    // =========================================================================
    // Flush output generation
    // =========================================================================
    always_comb begin
        flush_out.valid         = 1'b0;
        flush_out.rob_idx       = flush_tail_idx;
        flush_out.redirect_pc   = 64'd0;
        flush_out.checkpoint_id = '0;
        flush_out.full_flush    = 1'b0;
        flush_out.ras_tos       = 5'd0;
        flush_out.ras_top_restore_valid = 1'b0;
        flush_out.ras_top_restore_addr  = 64'd0;
        flush_out.ghr_restore_valid = 1'b0;
        flush_out.ghr_restore_val   = '0;

        if (found_replay) begin
            // Memory ordering replay: full flush, redirect to the load's PC.
            // The load is NOT committed; it will re-fetch and re-execute,
            // this time after the older store's data is visible.
            flush_out.valid       = 1'b1;
            flush_out.full_flush  = 1'b1;
            flush_out.redirect_pc = head_pc[replay_slot];
        end else if (found_exception) begin
            // Exception: full flush, redirect to trap vector
            flush_out.valid       = 1'b1;
            flush_out.full_flush  = 1'b1;
            flush_out.redirect_pc = trap_vector;
        end else if (found_mispredict) begin
            // Branch mispredict: full flush.  The BRU may have already
            // redirected fetch to the correct target (early redirect).
            flush_out.valid         = 1'b1;
            flush_out.full_flush    = 1'b1;
            flush_out.redirect_pc   = head_branch_target[misp_slot];
            flush_out.ras_tos       = ras_tos_after_branch(
                head_bp_ras_tos[misp_slot],
                head_bp_ras_op[misp_slot]
            );
            if ((head_bp_ras_op[misp_slot] == RAS_NONE) &&
                (head_bp_ras_tos[misp_slot] != 5'd0)) begin
                flush_out.ras_top_restore_valid = 1'b1;
                flush_out.ras_top_restore_addr  = head_bp_ras_top[misp_slot];
            end
            flush_out.ghr_restore_valid = 1'b1;
            flush_out.ghr_restore_val   = head_is_branch[misp_slot]
                ? {head_bp_ghr[misp_slot][GHR_BITS-2:0],
                   head_branch_taken[misp_slot]}
                : head_bp_ghr[misp_slot];
        end else if (found_ret) begin
            // MRET/SRET: full flush, redirect to mepc/sepc
            flush_out.valid       = 1'b1;
            flush_out.full_flush  = 1'b1;
            // Determine which return type - if any slot committed has mret, use mepc
            // Since MRET/SRET is serialized at slot 0, check slot 0
            if (head_is_mret[0])
                flush_out.redirect_pc = mepc;
            else
                flush_out.redirect_pc = sepc;
        end else if (vm_serial_redirect) begin
            // SATP/status writes and SFENCE.VMA change the translation
            // contract seen by younger memory operations.  Retire the
            // side effect, then refetch the next instruction under the new
            // VM state instead of letting pre-commit younger work survive.
            flush_out.valid       = 1'b1;
            flush_out.full_flush  = 1'b1;
            flush_out.redirect_pc = head_pc[0] + 64'd4;
        end else if (take_interrupt) begin
            // Interrupt: full flush, redirect to interrupt vector
            flush_out.valid       = 1'b1;
            flush_out.full_flush  = 1'b1;
            flush_out.redirect_pc = irq_vector;
        end
    end

    // =========================================================================
    // Commit count output
    // =========================================================================
    assign commit_count      = scan_count;
    assign store_commit_count = store_cnt;
    assign load_commit_count  = load_cnt;
    assign insn_retired_count = retired_inst_count;

    // =========================================================================
    // CSR commit output (at most 1 per cycle, serialized at slot 0)
    // =========================================================================
    always_comb begin
        csr_commit_valid = 1'b0;
        csr_commit_addr  = 12'd0;
        csr_commit_wdata = 64'd0;
        csr_commit_op    = 2'd0;

        if (scan_count > 3'd0 && head_is_csr[0] && head_csr_we[0] &&
            !head_has_exception[0]) begin
            csr_commit_valid = 1'b1;
            csr_commit_addr  = head_csr_addr[0];
            csr_commit_wdata = head_csr_wdata[0];
            csr_commit_op    = head_csr_op[0];
        end
    end

    // =========================================================================
    // commit_out: per-entry commit info for free list / rename map update
    // =========================================================================
    always_comb begin
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            commit_out[i].valid    = slot_can_commit[i];
            commit_out[i].rob_idx  = '0; // ROB manages its own head advancement
            commit_out[i].pdst     = head_pdst[i];
            commit_out[i].old_pdst = head_old_pdst[i];
            commit_out[i].rd_arch  = head_rd_arch[i];
            commit_out[i].rd_valid = slot_can_commit[i] & head_rd_valid[i];
        end
    end

    // =========================================================================
    // Checkpoint release: signal the checkpoint manager for each committed
    // entry that used a checkpoint
    // =========================================================================
    always_comb begin
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            release_checkpoint[i]    = slot_can_commit[i] & head_uses_checkpoint[i];
            release_checkpoint_id[i] = head_checkpoint_id[i];
        end
    end

`ifdef COMMIT_TRACE
    integer dbg_cycle = 0;
    always_ff @(posedge clk) begin
        dbg_cycle <= dbg_cycle + 1;
        if (scan_count > 3'd0) begin
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                if (slot_can_commit[i]) begin
                    $display("[%0d] COMMIT[%0d]: pc=%016h ld=%b st=%b br=%b miss=%b exc=%b",
                        dbg_cycle, i, head_pc[i],
                        head_is_load[i], head_is_store[i], head_is_branch[i],
                        head_branch_mispredict[i], head_has_exception[i]);
                end
            end
        end
        if (flush_out.valid) begin
            $display("[%0d] FLUSH:    redirect_pc=%016h full=%b",
                dbg_cycle, flush_out.redirect_pc, flush_out.full_flush);
        end
    end
`endif

`ifdef SIMULATION
    logic   trace_commit_en;
    logic   trace_flush_en;
    integer trace_commit_cycle;
    // STAT_DUMP: categorize flushes by cause (sim-only, +STAT_DUMP runtime).
    integer cmt_leak_cyc;
    logic   cmt_stat_en;
    integer flush_replay_cnt, flush_exception_cnt, flush_mispredict_cnt;
    integer flush_ret_cnt,    flush_interrupt_cnt;
    integer total_commits;
    integer total_store_commits, total_load_commits, total_branch_commits;
    initial trace_commit_en = ($test$plusargs("TRACE_COMMIT") ? 1'b1 : 1'b0);
    initial trace_flush_en  = ($test$plusargs("TRACE_FLUSH")  ? 1'b1 : trace_commit_en);
    initial cmt_stat_en = ($test$plusargs("STAT_DUMP") ? 1'b1 : 1'b0);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            trace_commit_cycle    <= 0;
            cmt_leak_cyc         <= 0;
            flush_replay_cnt     <= 0;
            flush_exception_cnt  <= 0;
            flush_mispredict_cnt <= 0;
            flush_ret_cnt        <= 0;
            flush_interrupt_cnt  <= 0;
            total_commits        <= 0;
            total_store_commits  <= 0;
            total_load_commits   <= 0;
            total_branch_commits <= 0;
        end else begin
            trace_commit_cycle <= trace_commit_cycle + 1;
            cmt_leak_cyc <= cmt_leak_cyc + 1;
            total_commits <= total_commits + scan_count;
            total_store_commits  <= total_store_commits  + store_cnt;
            total_load_commits   <= total_load_commits   + load_cnt;
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                if (slot_can_commit[i] && head_is_branch[i])
                    total_branch_commits <= total_branch_commits + 1;
            end
            if (trace_flush_en && flush_out.valid) begin
                $display(
                    "[CMT_FLUSH] cyc=%0d replay=%b replay_slot=%0d exc=%b exc_slot=%0d exc_code=%0d misp=%b misp_slot=%0d ret=%b irq=%b redirect=%016h full=%b trap=%016h irq_vec=%016h mepc=%016h sepc=%016h ras_tos=%0d ghr_v=%b",
                    trace_commit_cycle,
                    found_replay, replay_slot,
                    found_exception, exc_slot,
                    found_exception ? head_exc_code[exc_slot] : 4'd0,
                    found_mispredict, misp_slot,
                    found_ret, take_interrupt,
                    flush_out.redirect_pc, flush_out.full_flush,
                    trap_vector, irq_vector, mepc, sepc,
                    flush_out.ras_tos, flush_out.ghr_restore_valid
                );
                for (int i = 0; i < PIPE_WIDTH; i++) begin
                    $display(
                        "[CMT_SLOT] cyc=%0d slot=%0d v=%b rdy=%b can=%b pc=%016h exc=%b exc_code=%0d br=%b bpu=%0d taken=%b tgt=%016h misp=%b mret=%b sret=%b bp_ras_tos=%0d bp_ras_op=%0d bp_ras_top=%016h",
                        trace_commit_cycle, i,
                        head_valid[i], head_ready[i], slot_can_commit[i],
                        head_pc[i],
                        head_has_exception[i], head_exc_code[i],
                        head_is_branch[i], head_bpu_type[i],
                        head_branch_taken[i], head_branch_target[i],
                        head_branch_mispredict[i],
                        head_is_mret[i], head_is_sret[i],
                        head_bp_ras_tos[i], head_bp_ras_op[i], head_bp_ras_top[i]
                    );
                end
            end
            if (found_replay)     flush_replay_cnt     <= flush_replay_cnt     + 1;
            if (found_exception)  flush_exception_cnt  <= flush_exception_cnt  + 1;
            if (found_mispredict) flush_mispredict_cnt <= flush_mispredict_cnt + 1;
            if (found_ret)        flush_ret_cnt        <= flush_ret_cnt        + 1;
            if (take_interrupt)   flush_interrupt_cnt  <= flush_interrupt_cnt  + 1;
        end
    end
    final begin
        $display("");
        $display("=== COMMIT FLUSH-CAUSE BREAKDOWN (cyc=%0d) ===", cmt_leak_cyc);
        $display("Total commits:        %0d", total_commits);
        $display("  branches committed: %0d", total_branch_commits);
        $display("  stores committed:   %0d", total_store_commits);
        $display("  loads committed:    %0d", total_load_commits);
        $display("Flush causes:");
        $display("  replay (ld order):  %0d", flush_replay_cnt);
        $display("  exception:          %0d", flush_exception_cnt);
        $display("  mispredict:         %0d", flush_mispredict_cnt);
        $display("  ret (mret/sret):    %0d", flush_ret_cnt);
        $display("  interrupt:          %0d", flush_interrupt_cnt);
    end
`endif

endmodule

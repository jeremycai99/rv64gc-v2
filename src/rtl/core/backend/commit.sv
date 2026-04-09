/* file: commit.sv
 Description: Six-wide in-order commit unit with checkpoint recovery.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
module commit
    import rv64gc_pkg::*;
    import uarch_pkg::*;
(
    input  logic clk,
    input  logic rst_n,

    // ROB head entries (from ROB)
    input  logic [PIPE_WIDTH-1:0]   head_valid,
    input  logic [PIPE_WIDTH-1:0]   head_ready,
    input  logic [63:0]             head_pc [0:PIPE_WIDTH-1],
    input  logic [PIPE_WIDTH-1:0]   head_has_exception,
    input  logic [3:0]              head_exc_code [0:PIPE_WIDTH-1],
    input  logic [PIPE_WIDTH-1:0]   head_is_branch,
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
    input  logic [PIPE_WIDTH-1:0]   head_branch_taken,
    input  logic [63:0]             head_branch_target [0:PIPE_WIDTH-1],
    input  logic [PIPE_WIDTH-1:0]   head_branch_mispredict,
    input  logic [11:0]             head_csr_addr [0:PIPE_WIDTH-1],
    input  logic [63:0]             head_csr_wdata [0:PIPE_WIDTH-1],
    input  logic [PIPE_WIDTH-1:0]   head_csr_we,

    // Rename buffer data (for free list release)
    input  logic [PHYS_REG_BITS-1:0] head_pdst [0:PIPE_WIDTH-1],
    input  logic [PHYS_REG_BITS-1:0] head_old_pdst [0:PIPE_WIDTH-1],
    input  logic [4:0]              head_rd_arch [0:PIPE_WIDTH-1],
    input  logic [PIPE_WIDTH-1:0]   head_rd_valid,

    // Checkpoint release info
    input  logic [PIPE_WIDTH-1:0]              head_uses_checkpoint,
    input  logic [CHECKPOINT_BITS-1:0]         head_checkpoint_id [0:PIPE_WIDTH-1],

    // Outputs
    output logic [2:0]              commit_count,       // how many entries retired this cycle
    output commit_t                 commit_out [0:PIPE_WIDTH-1],  // per-entry commit info (for free list)
    output logic [2:0]              store_commit_count,  // how many stores committed (for SQ)

    // Flush output (mispredict or exception)
    output flush_t                  flush_out,

    // CSR write (at most 1 per cycle, serialized)
    output logic                    csr_commit_valid,
    output logic [11:0]             csr_commit_addr,
    output logic [63:0]             csr_commit_wdata,

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
    output logic [2:0]              insn_retired_count  // for minstret
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

    // Per-slot eligibility
    logic [PIPE_WIDTH-1:0] slot_can_commit;

    always_comb begin
        scan_count       = 3'd0;
        found_exception  = 1'b0;
        exc_slot         = 3'd0;
        found_mispredict = 1'b0;
        misp_slot        = 3'd0;
        found_ret        = 1'b0;
        store_cnt        = 3'd0;

        for (int i = 0; i < PIPE_WIDTH; i++) begin
            slot_can_commit[i] = 1'b0;
        end

        // Scan slots 0..5 in order
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            // Stop if we already found an exception, mispredict, or return
            if (found_exception || found_mispredict || found_ret) begin
                // Do not commit further entries
            end
            // Stop if entry not valid
            else if (!head_valid[i]) begin
                // No more entries; break out of scan
                found_exception = found_exception; // no-op to stay in else-if
            end
            // Stop if entry not ready
            else if (!head_ready[i]) begin
                found_exception = found_exception; // no-op
            end
            // Exception at this entry: commit it (for arch state update), then stop
            else if (head_has_exception[i]) begin
                slot_can_commit[i] = 1'b1;
                scan_count = scan_count + 3'd1;
                if (head_is_store[i]) store_cnt = store_cnt + 3'd1;
                found_exception = 1'b1;
                exc_slot = i[2:0];
            end
            // Serializing instruction at slot > 0: stop (don't commit it)
            else if ((i > 0) && is_serializing[i]) begin
                found_exception = found_exception; // no-op, stop scanning
            end
            // Normal committable entry
            else begin
                slot_can_commit[i] = 1'b1;
                scan_count = scan_count + 3'd1;
                if (head_is_store[i]) store_cnt = store_cnt + 3'd1;

                // Check for mispredict
                if (head_branch_mispredict[i]) begin
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
    wire take_interrupt = irq_pending &&
                          !found_exception &&
                          !found_mispredict &&
                          !found_ret &&
                          !serializing_at_head;

    // =========================================================================
    // Flush output generation
    // =========================================================================
    always_comb begin
        flush_out.valid         = 1'b0;
        flush_out.rob_idx       = '0;
        flush_out.redirect_pc   = 64'd0;
        flush_out.checkpoint_id = '0;
        flush_out.full_flush    = 1'b0;
        flush_out.ras_tos       = 5'd0;

        if (found_exception) begin
            // Exception: full flush, redirect to trap vector
            flush_out.valid       = 1'b1;
            flush_out.full_flush  = 1'b1;
            flush_out.redirect_pc = trap_vector;
        end else if (found_mispredict) begin
            // Branch mispredict: partial flush via checkpoint restore
            flush_out.valid         = 1'b1;
            flush_out.full_flush    = 1'b0;
            flush_out.redirect_pc   = head_branch_target[misp_slot];
            flush_out.checkpoint_id = head_checkpoint_id[misp_slot];
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
    assign insn_retired_count = scan_count;

    // =========================================================================
    // CSR commit output (at most 1 per cycle, serialized at slot 0)
    // =========================================================================
    always_comb begin
        csr_commit_valid = 1'b0;
        csr_commit_addr  = 12'd0;
        csr_commit_wdata = 64'd0;

        if (scan_count > 3'd0 && head_is_csr[0] && head_csr_we[0] &&
            !head_has_exception[0]) begin
            csr_commit_valid = 1'b1;
            csr_commit_addr  = head_csr_addr[0];
            csr_commit_wdata = head_csr_wdata[0];
        end
    end

    // =========================================================================
    // commit_out: per-entry commit info for free list / rename map update
    // =========================================================================
    always_comb begin
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            commit_out[i].valid    = slot_can_commit[i];
            commit_out[i].rob_idx  = '0; // ROB manages its own head advancement
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

endmodule

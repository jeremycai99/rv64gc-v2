/* file: rob.sv
 Description: 128-entry circular reorder buffer with 4-wide alloc/commit.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
module rob
    import rv64gc_pkg::*;
    import uarch_pkg::*;
(
    input  logic clk,
    input  logic rst_n,

    // Allocate: up to 6 entries per cycle from rename
    input  logic [2:0]              alloc_count,     // 0..6 valid entries to allocate
    output logic [ROB_IDX_BITS-1:0] alloc_idx [0:PIPE_WIDTH-1],  // allocated ROB indices
    output logic                    alloc_ready,     // can accept alloc_count entries
    input  logic [PIPE_WIDTH-1:0]   alloc_ready_now, // entries complete at rename
    input  logic [PIPE_WIDTH-1:0]   alloc_has_exception,
    input  logic [3:0]              alloc_exc_code [0:PIPE_WIDTH-1],
    // Data to write at allocation time (per-entry fields)
    input  logic [63:0]             alloc_pc [0:PIPE_WIDTH-1],
    input  logic [PIPE_WIDTH-1:0]   alloc_is_branch,
    input  logic [2:0]             alloc_bpu_type [0:PIPE_WIDTH-1],
    input  logic [PIPE_WIDTH-1:0]   alloc_is_store,
    input  logic [PIPE_WIDTH-1:0]   alloc_is_load,
    input  logic [PIPE_WIDTH-1:0]   alloc_is_csr,
    input  logic [PIPE_WIDTH-1:0]   alloc_is_fence,
    input  logic [PIPE_WIDTH-1:0]   alloc_is_fence_i,
    input  logic [PIPE_WIDTH-1:0]   alloc_is_mret,
    input  logic [PIPE_WIDTH-1:0]   alloc_is_sret,
    input  logic [PIPE_WIDTH-1:0]   alloc_is_sfence_vma,
    input  logic [PIPE_WIDTH-1:0]   alloc_is_ecall,
    input  logic [PIPE_WIDTH-1:0]   alloc_is_wfi,
    input  logic [PIPE_WIDTH-1:0]   alloc_is_fused,
    input  logic [PIPE_WIDTH-1:0]   alloc_is_fp_instr,
    // Sub-classification of the head-stall "other" bucket
    // (perf-instr only; sim-only path uses these arrays).
    input  logic [PIPE_WIDTH-1:0]   alloc_is_mul,
    input  logic [PIPE_WIDTH-1:0]   alloc_is_div,
    input  logic [PIPE_WIDTH-1:0]   alloc_is_bru,

    // Writeback: CDB marks entries as complete (up to 6 per cycle)
    input  logic [CDB_WIDTH-1:0]              wb_valid,
    input  logic [ROB_IDX_BITS-1:0]           wb_idx [0:CDB_WIDTH-1],
    input  logic [CDB_WIDTH-1:0]              wb_has_exception,
    input  logic [3:0]                        wb_exc_code [0:CDB_WIDTH-1],
    // Branch resolution fields
    input  logic [CDB_WIDTH-1:0]              wb_is_branch,
    input  logic [CDB_WIDTH-1:0]              wb_branch_taken,
    input  logic [63:0]                       wb_branch_target [0:CDB_WIDTH-1],
    input  logic [63:0]                       wb_branch_taken_target [0:CDB_WIDTH-1],
    input  logic [CDB_WIDTH-1:0]              wb_branch_mispredict,
    // CSR writeback fields
    input  logic [CDB_WIDTH-1:0]              wb_csr_we,
    input  logic [11:0]                       wb_csr_addr [0:CDB_WIDTH-1],
    input  logic [63:0]                       wb_csr_wdata [0:CDB_WIDTH-1],
    input  logic [1:0]                        wb_csr_op [0:CDB_WIDTH-1],
    input  logic [CDB_WIDTH-1:0]              wb_fp_fflags_valid,
    input  logic [4:0]                        wb_fp_fflags [0:CDB_WIDTH-1],

    // STA sideband writeback (marks store ROB entry as ready, no data)
    input  logic                              sta_wb_valid,
    input  logic [ROB_IDX_BITS-1:0]           sta_wb_rob_idx,
    input  logic                              std_wb_valid,
    input  logic [ROB_IDX_BITS-1:0]           std_wb_rob_idx,

    // Load writeback sideband (separate from CDB[0:CDB_WIDTH-1]; loads use
    // speculative wakeup so they do not need a CDB broadcast slot but still
    // need to mark the ROB entry complete and report exceptions).
    // 2 load ports: load_wb_valid[0]=Load0, load_wb_valid[1]=Load1.
    input  logic [1:0]               load_wb_valid_r,
    input  logic [ROB_IDX_BITS-1:0]  load_wb_idx_r    [0:1],
    input  logic [1:0]               load_wb_has_exception_r,
    input  logic [3:0]               load_wb_exc_code_r [0:1],

    // Sideband exception write: used by long-latency walkers or units that
    // discover an exception after issue without producing a normal CDB result.
    input  logic                              sideband_exc_valid,
    input  logic [ROB_IDX_BITS-1:0]           sideband_exc_rob_idx,
    input  logic [3:0]                        sideband_exc_code,
    input  logic [63:0]                       sideband_exc_tval,

    // Memory ordering violation: a younger load executed before an older
    // store with overlapping bytes was visible.  Mark the violating load
    // ready with the internal replay marker so commit
    // flushes to the load's own PC and re-executes it against the
    // now-visible store.  replay_valid stays on the port list for the
    // future partial-replay design, but is intentionally unused here.
    input  logic                              ordering_violation_valid,
    input  logic [ROB_IDX_BITS-1:0]           ordering_violation_rob_idx,

    // Partial-replay bus reserved for the future Phase-3 design
    // (doc/partial_replay_spec.md).  The ports remain in place so the
    // LSU/commit interfaces do not churn, but the current ROB fix does
    // not consume them; ordering violations use the legacy exc_code=15
    // path above.
    input  logic                              replay_valid,
    input  logic [ROB_IDX_BITS-1:0]           replay_rob_idx_from,

    // Commit: read head entries for commit unit
    output logic [ROB_IDX_BITS-1:0]           head_idx,
    output logic [PIPE_WIDTH-1:0]             head_valid,     // which of the 6 head entries are valid
    output logic [PIPE_WIDTH-1:0]             head_ready,     // which are completed (ready to retire)
    output logic [63:0]                       head_pc [0:PIPE_WIDTH-1],
    output logic [PIPE_WIDTH-1:0]             head_has_exception,
    output logic [3:0]                        head_exc_code [0:PIPE_WIDTH-1],
    output logic [63:0]                       head_exc_tval [0:PIPE_WIDTH-1],
    output logic [PIPE_WIDTH-1:0]             head_is_branch,
    output logic [2:0]                       head_bpu_type [0:PIPE_WIDTH-1],
    output logic [PIPE_WIDTH-1:0]             head_is_store,
    output logic [PIPE_WIDTH-1:0]             head_is_load,
    output logic [PIPE_WIDTH-1:0]             head_is_csr,
    output logic [PIPE_WIDTH-1:0]             head_is_fence,
    output logic [PIPE_WIDTH-1:0]             head_is_fence_i,
    output logic [PIPE_WIDTH-1:0]             head_is_mret,
    output logic [PIPE_WIDTH-1:0]             head_is_sret,
    output logic [PIPE_WIDTH-1:0]             head_is_sfence_vma,
    output logic [PIPE_WIDTH-1:0]             head_is_ecall,
    output logic [PIPE_WIDTH-1:0]             head_is_wfi,
    output logic [PIPE_WIDTH-1:0]             head_is_fused,
    output logic [PIPE_WIDTH-1:0]             head_is_fp_instr,
    output logic [PIPE_WIDTH-1:0]             head_branch_taken,
    output logic [63:0]                       head_branch_target [0:PIPE_WIDTH-1],
    output logic [63:0]                       head_branch_taken_target [0:PIPE_WIDTH-1],
    output logic [PIPE_WIDTH-1:0]             head_branch_mispredict,
    output logic [11:0]                       head_csr_addr [0:PIPE_WIDTH-1],
    output logic [63:0]                       head_csr_wdata [0:PIPE_WIDTH-1],
    output logic [PIPE_WIDTH-1:0]             head_csr_we,
    output logic [1:0]                        head_csr_op [0:PIPE_WIDTH-1],
    output logic [4:0]                        head_fp_fflags [0:PIPE_WIDTH-1],

    // Commit acknowledgment: advance head pointer
    input  logic [2:0]              commit_count,    // 0..6 entries committed this cycle

    // Flush
    input  logic                    flush_valid,
    input  logic [ROB_IDX_BITS-1:0] flush_rob_tail,  // restore tail to this value (from checkpoint)
    input  logic                    flush_full,       // full flush: reset head and tail to 0
    input  logic                    flush_clear_branch_mispredict,

    // Status
    output logic [ROB_IDX_BITS-1:0] tail_idx,
    output logic [ROB_IDX_BITS:0]   free_count_o,
    output logic                    empty,
    output logic                    full
);

    // =========================================================================
    // Constants for modular arithmetic (ROB_DEPTH=128 is power of 2)
    // ROB_DEPTH_U8 is one bit wider than ROB_IDX_BITS so that ROB_DEPTH=128
    // (= 2^ROB_IDX_BITS) fits without overflow: 7'(128)=0 is wrong;
    // 8'(128)=8'b1000_0000 = 128 is correct.
    // =========================================================================
    localparam logic [ROB_IDX_BITS:0] ROB_DEPTH_U8 = (ROB_IDX_BITS+1)'(ROB_DEPTH);
    localparam int LOAD_CDB_FIRST = 4;

    // =========================================================================
    // Head and tail pointers, entry count
    //
    // Declaration-site init to 0 so xsim (4-state) does not read these as
    // X at Time 0 Iteration 0.  Core top reads head_r via hierarchical
    // port and indexes unpacked arrays with it combinationally; an X
    // index is FATAL in xsim.  The reset path below still drives '0 on
    // rst_n deassertion, so synthesis sees only the reset-write path.
    // =========================================================================
    reg [ROB_IDX_BITS-1:0] head_r  = '0;
    reg [ROB_IDX_BITS-1:0] tail_r  = '0;
    reg [ROB_IDX_BITS:0] count_r = '0;

    assign head_idx = head_r;
    assign tail_idx = tail_r;
    assign empty    = (count_r == (ROB_IDX_BITS+1)'(0));
    assign full     = (count_r + (ROB_IDX_BITS+1)'(PIPE_WIDTH) > ROB_DEPTH_U8);

    // alloc_ready: true when free entries >= PIPE_WIDTH
    // free_count is one bit wider to hold ROB_DEPTH_U8 without truncation.
    wire [ROB_IDX_BITS:0] free_count = ROB_DEPTH_U8 - count_r;
    assign alloc_ready = (free_count >= (ROB_IDX_BITS+1)'(PIPE_WIDTH));
    assign free_count_o = free_count;

    // =========================================================================
    // Allocation indices: combinational output (inline wrap-add)
    // ROB_DEPTH=128 is power-of-2, so wrap is just truncation to ROB_IDX_BITS.
    // =========================================================================
    logic [ROB_IDX_BITS:0] alloc_sum [0:PIPE_WIDTH-1];
    always_comb begin
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            alloc_sum[i] = {1'b0, tail_r} + (ROB_IDX_BITS+1)'(i);
            alloc_idx[i] = (alloc_sum[i] >= (ROB_IDX_BITS+1)'(ROB_DEPTH))
                           ? alloc_sum[i][ROB_IDX_BITS-1:0] - ROB_DEPTH_U8
                           : alloc_sum[i][ROB_IDX_BITS-1:0];
        end
    end

    // =========================================================================
    // Head read indices: combinational (inline wrap-add)
    // =========================================================================
    logic [ROB_IDX_BITS:0] head_sum_w [0:PIPE_WIDTH-1];
    logic [ROB_IDX_BITS-1:0] head_idx_w [0:PIPE_WIDTH-1];
    always_comb begin
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            head_sum_w[i] = {1'b0, head_r} + (ROB_IDX_BITS+1)'(i);
            head_idx_w[i] = (head_sum_w[i] >= (ROB_IDX_BITS+1)'(ROB_DEPTH))
                            ? head_sum_w[i][ROB_IDX_BITS-1:0] - ROB_DEPTH_U8
                            : head_sum_w[i][ROB_IDX_BITS-1:0];
        end
    end

    // =========================================================================
    // Storage: flat arrays (Verilator-friendly)
    // =========================================================================
    reg [ROB_DEPTH-1:0]          valid_r;
    reg [ROB_DEPTH-1:0]          ready_r;
    reg [ROB_DEPTH-1:0]          store_addr_done_r;
    reg [ROB_DEPTH-1:0]          store_data_done_r;
    // Watchdog: counts cycles the ROB head has been valid-but-not-ready.
    // Fires an exception at saturation to recover from stuck-entry deadlocks
    // (e.g. an IQ entry flushed without the corresponding ROB entry being
    // invalidated — the CDB writeback never arrives).
    reg [11:0]                   rob_head_watchdog;
    reg [64*ROB_DEPTH-1:0]       pc_packed;
    reg [ROB_DEPTH-1:0]          has_exc_r;
    reg [4*ROB_DEPTH-1:0]        exc_code_packed;
    reg [64*ROB_DEPTH-1:0]       exc_tval_packed;
    reg [ROB_DEPTH-1:0]          is_branch_r;
    reg [2:0]                    bpu_type_r [0:ROB_DEPTH-1];
    reg [ROB_DEPTH-1:0]          is_store_r;
    reg [ROB_DEPTH-1:0]          is_load_r;
    reg [ROB_DEPTH-1:0]          is_csr_r;
    reg [ROB_DEPTH-1:0]          is_fence_r;
    reg [ROB_DEPTH-1:0]          is_fence_i_r;
    reg [ROB_DEPTH-1:0]          is_mret_r;
    reg [ROB_DEPTH-1:0]          is_sret_r;
    reg [ROB_DEPTH-1:0]          is_sfence_vma_r;
    reg [ROB_DEPTH-1:0]          is_ecall_r;
    reg [ROB_DEPTH-1:0]          is_wfi_r;
    reg [ROB_DEPTH-1:0]          is_fused_r;
    reg [ROB_DEPTH-1:0]          is_fp_instr_r;
    // Per-uop FU-type tags used only by SIMULATION head-stall
    // sub-classification (decompose the "other" bucket into
    // mul/div/csr/bru/unknown).  Not used by functional logic.
    reg [ROB_DEPTH-1:0]          is_mul_r;
    reg [ROB_DEPTH-1:0]          is_div_r;
    reg [ROB_DEPTH-1:0]          is_bru_r;
    reg [ROB_DEPTH-1:0]          branch_taken_r;
    reg [64*ROB_DEPTH-1:0]       branch_target_packed;
    reg [64*ROB_DEPTH-1:0]       branch_taken_target_packed;
    reg [ROB_DEPTH-1:0]          branch_mispredict_r;
    reg [12*ROB_DEPTH-1:0]       csr_addr_packed;
    reg [64*ROB_DEPTH-1:0]       csr_wdata_packed;
    reg [ROB_DEPTH-1:0]          csr_we_r;
    reg [1:0]                    csr_op_r [0:ROB_DEPTH-1];
    reg [5*ROB_DEPTH-1:0]        fp_fflags_packed;

    // Same-cycle ready bypass into commit for simple writebacks.
    //
    // ROB ready_r is normally updated at the clock edge after CDB writeback,
    // so a head instruction whose result arrives this cycle otherwise costs an
    // extra commit bubble.  Only bypass simple, non-control, non-exception
    // writebacks; branches, CSR/serializing ops, stores, and replay-marked
    // loads still wait for their registered ROB side effects.
    logic [PIPE_WIDTH-1:0] head_ready_wb_bypass;
    always_comb begin
        head_ready_wb_bypass = '0;
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            for (int w = 0; w < CDB_WIDTH; w++) begin
                if (wb_valid[w] &&
                    (wb_idx[w] == head_idx_w[i][ROB_IDX_BITS-1:0]) &&
                    !wb_has_exception[w] &&
                    !wb_is_branch[w] &&
                    !wb_csr_we[w] &&
                    !is_store_r[head_idx_w[i]] &&
                    !is_csr_r[head_idx_w[i]] &&
                    !is_fence_r[head_idx_w[i]] &&
                    !is_fence_i_r[head_idx_w[i]] &&
                    !is_mret_r[head_idx_w[i]] &&
                    !is_sret_r[head_idx_w[i]] &&
                    !is_sfence_vma_r[head_idx_w[i]] &&
                    !is_ecall_r[head_idx_w[i]] &&
                    !is_wfi_r[head_idx_w[i]] &&
                    !(ordering_violation_valid &&
                      (ordering_violation_rob_idx == head_idx_w[i][ROB_IDX_BITS-1:0]))) begin
                    head_ready_wb_bypass[i] = 1'b1;
                end
            end
        end
    end

    // Default-on, narrow version of the bypass above: only allow the ROB head
    // slot to retire a normal load whose registered load CDB writeback is
    // present in this cycle.  This trims the common one-cycle load-at-head
    // bubble without changing wider commit-group ordering.
    logic head_ready_head_load_wb_bypass;
    always_comb begin
        head_ready_head_load_wb_bypass = 1'b0;
        // Stage 2: loads use sideband load_wb_valid_r instead of CDB slots.
        for (int lw = 0; lw < 2; lw++) begin
            if (load_wb_valid_r[lw] &&
                (count_r != (ROB_IDX_BITS+1)'(0)) &&
                valid_r[head_idx_w[0]] &&
                !ready_r[head_idx_w[0]] &&
                is_load_r[head_idx_w[0]] &&
                !has_exc_r[head_idx_w[0]] &&
                !load_wb_has_exception_r[lw] &&
                (load_wb_idx_r[lw] == head_idx_w[0][ROB_IDX_BITS-1:0]) &&
                !(ordering_violation_valid &&
                  (ordering_violation_rob_idx == head_idx_w[0][ROB_IDX_BITS-1:0]))) begin
                head_ready_head_load_wb_bypass = 1'b1;
            end
        end
    end

    // Default-on, narrow bypass for non-load arithmetic (ALU / MUL / DIV)
    // writebacks at the ROB head.  Mirror image of head_ready_head_load_wb_bypass:
    // head slot only, scans CDB[0..LOAD_CDB_FIRST-1], and excludes the same
    // control/side-effect classes as the existing bypasses.  Targets the
    // per-cycle head-other wait cycles measured in CoreMark matrix MUL and
    // Dhrystone divw.
    logic head_ready_head_arith_wb_bypass;
    always_comb begin
        head_ready_head_arith_wb_bypass = 1'b0;
        for (int w = 0; w < CDB_WIDTH; w++) begin
            if ((w < LOAD_CDB_FIRST) &&
                (count_r != (ROB_IDX_BITS+1)'(0)) &&
                valid_r[head_idx_w[0]] &&
                !ready_r[head_idx_w[0]] &&
                !is_load_r[head_idx_w[0]] &&
                !is_store_r[head_idx_w[0]] &&
                !is_csr_r[head_idx_w[0]] &&
                !is_branch_r[head_idx_w[0]] &&
                !is_fence_r[head_idx_w[0]] &&
                !is_fence_i_r[head_idx_w[0]] &&
                !is_mret_r[head_idx_w[0]] &&
                !is_sret_r[head_idx_w[0]] &&
                !is_sfence_vma_r[head_idx_w[0]] &&
                !is_ecall_r[head_idx_w[0]] &&
                !is_wfi_r[head_idx_w[0]] &&
                !has_exc_r[head_idx_w[0]] &&
                wb_valid[w] &&
                (wb_idx[w] == head_idx_w[0][ROB_IDX_BITS-1:0]) &&
                !wb_has_exception[w] &&
                !wb_is_branch[w] &&
                !wb_csr_we[w] &&
                !(ordering_violation_valid &&
                  (ordering_violation_rob_idx == head_idx_w[0][ROB_IDX_BITS-1:0]))) begin
                head_ready_head_arith_wb_bypass = 1'b1;
            end
        end
    end

    // Slot-1 symmetric bypasses (load + arith), same safety envelope as the
    // slot-0 bypasses.  Only matters when slot 0 is also committing this
    // cycle (commit scanner stops at the first not-ready slot).  This lets
    // the pipeline retire 2 instructions on cycles where slot-0 bypasses
    // and slot-1 has its writeback arriving in parallel.
    logic head_ready_slot1_load_wb_bypass;
    always_comb begin
        head_ready_slot1_load_wb_bypass = 1'b0;
        for (int lw = 0; lw < 2; lw++) begin
            if (load_wb_valid_r[lw] &&
                (count_r > (ROB_IDX_BITS+1)'(1)) &&
                valid_r[head_idx_w[1]] &&
                !ready_r[head_idx_w[1]] &&
                is_load_r[head_idx_w[1]] &&
                !has_exc_r[head_idx_w[1]] &&
                !load_wb_has_exception_r[lw] &&
                (load_wb_idx_r[lw] == head_idx_w[1][ROB_IDX_BITS-1:0]) &&
                !(ordering_violation_valid &&
                  (ordering_violation_rob_idx == head_idx_w[1][ROB_IDX_BITS-1:0]))) begin
                head_ready_slot1_load_wb_bypass = 1'b1;
            end
        end
    end

    logic head_ready_slot1_arith_wb_bypass;
    always_comb begin
        head_ready_slot1_arith_wb_bypass = 1'b0;
        for (int w = 0; w < CDB_WIDTH; w++) begin
            if ((w < LOAD_CDB_FIRST) &&
                (count_r > (ROB_IDX_BITS+1)'(1)) &&
                valid_r[head_idx_w[1]] &&
                !ready_r[head_idx_w[1]] &&
                !is_load_r[head_idx_w[1]] &&
                !is_store_r[head_idx_w[1]] &&
                !is_csr_r[head_idx_w[1]] &&
                !is_branch_r[head_idx_w[1]] &&
                !is_fence_r[head_idx_w[1]] &&
                !is_fence_i_r[head_idx_w[1]] &&
                !is_mret_r[head_idx_w[1]] &&
                !is_sret_r[head_idx_w[1]] &&
                !is_sfence_vma_r[head_idx_w[1]] &&
                !is_ecall_r[head_idx_w[1]] &&
                !is_wfi_r[head_idx_w[1]] &&
                !has_exc_r[head_idx_w[1]] &&
                wb_valid[w] &&
                (wb_idx[w] == head_idx_w[1][ROB_IDX_BITS-1:0]) &&
                !wb_has_exception[w] &&
                !wb_is_branch[w] &&
                !wb_csr_we[w] &&
                !(ordering_violation_valid &&
                  (ordering_violation_rob_idx == head_idx_w[1][ROB_IDX_BITS-1:0]))) begin
                head_ready_slot1_arith_wb_bypass = 1'b1;
            end
        end
    end

    // Slot-2 symmetric bypasses (load + arith), same safety envelope.  Only
    // matters when slots 0 and 1 are also committing this cycle; further
    // shifts commit=2 cycles to commit=3 in the commit histogram.
    logic head_ready_slot2_load_wb_bypass;
    always_comb begin
        head_ready_slot2_load_wb_bypass = 1'b0;
        for (int lw = 0; lw < 2; lw++) begin
            if (load_wb_valid_r[lw] &&
                (count_r > (ROB_IDX_BITS+1)'(2)) &&
                valid_r[head_idx_w[2]] &&
                !ready_r[head_idx_w[2]] &&
                is_load_r[head_idx_w[2]] &&
                !has_exc_r[head_idx_w[2]] &&
                !load_wb_has_exception_r[lw] &&
                (load_wb_idx_r[lw] == head_idx_w[2][ROB_IDX_BITS-1:0]) &&
                !(ordering_violation_valid &&
                  (ordering_violation_rob_idx == head_idx_w[2][ROB_IDX_BITS-1:0]))) begin
                head_ready_slot2_load_wb_bypass = 1'b1;
            end
        end
    end

    logic head_ready_slot2_arith_wb_bypass;
    always_comb begin
        head_ready_slot2_arith_wb_bypass = 1'b0;
        for (int w = 0; w < CDB_WIDTH; w++) begin
            if ((w < LOAD_CDB_FIRST) &&
                (count_r > (ROB_IDX_BITS+1)'(2)) &&
                valid_r[head_idx_w[2]] &&
                !ready_r[head_idx_w[2]] &&
                !is_load_r[head_idx_w[2]] &&
                !is_store_r[head_idx_w[2]] &&
                !is_csr_r[head_idx_w[2]] &&
                !is_branch_r[head_idx_w[2]] &&
                !is_fence_r[head_idx_w[2]] &&
                !is_fence_i_r[head_idx_w[2]] &&
                !is_mret_r[head_idx_w[2]] &&
                !is_sret_r[head_idx_w[2]] &&
                !is_sfence_vma_r[head_idx_w[2]] &&
                !is_ecall_r[head_idx_w[2]] &&
                !is_wfi_r[head_idx_w[2]] &&
                !has_exc_r[head_idx_w[2]] &&
                wb_valid[w] &&
                (wb_idx[w] == head_idx_w[2][ROB_IDX_BITS-1:0]) &&
                !wb_has_exception[w] &&
                !wb_is_branch[w] &&
                !wb_csr_we[w] &&
                !(ordering_violation_valid &&
                  (ordering_violation_rob_idx == head_idx_w[2][ROB_IDX_BITS-1:0]))) begin
                head_ready_slot2_arith_wb_bypass = 1'b1;
            end
        end
    end

`ifdef SIMULATION
    logic sim_rob_commit_wb_bypass_en;
    logic sim_rob_commit_wb_bypass_load_only;

    initial begin
        sim_rob_commit_wb_bypass_en =
            $test$plusargs("ROB_COMMIT_WB_BYPASS") ? 1'b1 : 1'b0;
        sim_rob_commit_wb_bypass_load_only =
            $test$plusargs("ROB_COMMIT_WB_BYPASS_LOAD_ONLY") ? 1'b1 : 1'b0;
    end

    logic [PIPE_WIDTH-1:0] head_ready_wb_bypass_allowed;
    always_comb begin
        head_ready_wb_bypass_allowed = head_ready_wb_bypass;
        if (sim_rob_commit_wb_bypass_load_only) begin
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                head_ready_wb_bypass_allowed[i] =
                    head_ready_wb_bypass[i] && is_load_r[head_idx_w[i]];
            end
        end
    end
`endif

    // =========================================================================
    // Commit read: combinational from head
    // Gate head_valid on count_r to prevent reading stale valid bits after
    // partial flush (partial flush resets tail/count but does NOT eagerly
    // clear valid_r for every squashed entry).
    // =========================================================================
    always_comb begin
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            head_valid[i]            = valid_r[head_idx_w[i]] && (count_r > (ROB_IDX_BITS+1)'(i));
            head_ready[i]            = ready_r[head_idx_w[i]];
            if (i == 0)
                head_ready[i] = head_ready[i] |
                                head_ready_head_load_wb_bypass |
                                head_ready_head_arith_wb_bypass;
            else if (i == 1)
                head_ready[i] = head_ready[i] |
                                head_ready_slot1_load_wb_bypass |
                                head_ready_slot1_arith_wb_bypass;
`ifdef SIMULATION
            if (sim_rob_commit_wb_bypass_en)
                head_ready[i] = head_ready[i] | head_ready_wb_bypass_allowed[i];
`endif
            head_pc[i]               = pc_packed[head_idx_w[i]*64 +: 64];
            head_has_exception[i]    = has_exc_r[head_idx_w[i]];
            head_exc_code[i]         = exc_code_packed[head_idx_w[i]*4 +: 4];
            head_exc_tval[i]         = exc_tval_packed[head_idx_w[i]*64 +: 64];
            head_is_branch[i]        = is_branch_r[head_idx_w[i]];
            head_bpu_type[i]         = bpu_type_r[head_idx_w[i]];
            head_is_store[i]         = is_store_r[head_idx_w[i]];
            head_is_load[i]          = is_load_r[head_idx_w[i]];
            head_is_csr[i]           = is_csr_r[head_idx_w[i]];
            head_is_fence[i]         = is_fence_r[head_idx_w[i]];
            head_is_fence_i[i]       = is_fence_i_r[head_idx_w[i]];
            head_is_mret[i]          = is_mret_r[head_idx_w[i]];
            head_is_sret[i]          = is_sret_r[head_idx_w[i]];
            head_is_sfence_vma[i]    = is_sfence_vma_r[head_idx_w[i]];
            head_is_ecall[i]         = is_ecall_r[head_idx_w[i]];
            head_is_wfi[i]           = is_wfi_r[head_idx_w[i]];
            head_is_fused[i]         = is_fused_r[head_idx_w[i]];
            head_is_fp_instr[i]      = is_fp_instr_r[head_idx_w[i]];
            head_branch_taken[i]     = branch_taken_r[head_idx_w[i]];
            head_branch_target[i]    = branch_target_packed[head_idx_w[i]*64 +: 64];
            head_branch_taken_target[i] =
                branch_taken_target_packed[head_idx_w[i]*64 +: 64];
            head_branch_mispredict[i]= branch_mispredict_r[head_idx_w[i]];
            head_csr_addr[i]         = csr_addr_packed[head_idx_w[i]*12 +: 12];
            head_csr_wdata[i]        = csr_wdata_packed[head_idx_w[i]*64 +: 64];
            head_csr_we[i]           = csr_we_r[head_idx_w[i]];
            head_csr_op[i]           = csr_op_r[head_idx_w[i]];
            head_fp_fflags[i]        = fp_fflags_packed[head_idx_w[i]*5 +: 5];
        end
    end

    // =========================================================================
    // Flush helper: precompute in-range for every entry (inline)
    // rob_in_range[i] = 1 when entry i is in [flush_rob_tail, tail_r)
    // =========================================================================
    logic [ROB_DEPTH-1:0] rob_in_range;
    logic [ROB_IDX_BITS-1:0] flush_prev_idx;
    always_comb begin
        for (int i = 0; i < ROB_DEPTH; i++) begin
            if (flush_rob_tail == tail_r)
                rob_in_range[i] = 1'b0;
            else if (flush_rob_tail < tail_r)
                rob_in_range[i] = (ROB_IDX_BITS'(i) >= flush_rob_tail) && (ROB_IDX_BITS'(i) < tail_r);
            else
                rob_in_range[i] = (ROB_IDX_BITS'(i) >= flush_rob_tail) || (ROB_IDX_BITS'(i) < tail_r);
        end
    end
    assign flush_prev_idx = (flush_rob_tail == ROB_IDX_BITS'(0))
                            ? (ROB_DEPTH_U8 - ROB_IDX_BITS'(1))
                            : (flush_rob_tail - ROB_IDX_BITS'(1));

    // =========================================================================
    // Combinational signals replacing automatic variables in always_ff
    // =========================================================================

    // --- Next-head computation (commit pointer advance) ---
    logic [ROB_IDX_BITS:0] nh_sum;
    logic [ROB_IDX_BITS-1:0] nh;
    assign nh_sum = {1'b0, head_r} + {(ROB_IDX_BITS-2)'(0), commit_count};
    assign nh     = (nh_sum >= (ROB_IDX_BITS+1)'(ROB_DEPTH))
                    ? nh_sum[ROB_IDX_BITS-1:0] - ROB_DEPTH_U8
                    : nh_sum[ROB_IDX_BITS-1:0];

    // --- Flush count recomputation (partial flush + commit) ---
    logic [ROB_IDX_BITS:0] max_valid;
    logic [ROB_IDX_BITS:0] raw_count;
    assign max_valid = count_r - (ROB_IDX_BITS+1)'(commit_count);
    always_comb begin
        if (flush_rob_tail >= nh)
            raw_count = flush_rob_tail - nh;
        else
            raw_count = ROB_DEPTH_U8 - nh + flush_rob_tail;
    end

    // --- Next-tail computation (alloc pointer advance) ---
    logic [ROB_IDX_BITS:0] nt_sum;
    logic [ROB_IDX_BITS-1:0] nt;
    assign nt_sum = {1'b0, tail_r} + {(ROB_IDX_BITS-2)'(0), alloc_count};
    assign nt     = (nt_sum >= (ROB_IDX_BITS+1)'(ROB_DEPTH))
                    ? nt_sum[ROB_IDX_BITS-1:0] - ROB_DEPTH_U8
                    : nt_sum[ROB_IDX_BITS-1:0];

    // --- Per-slot alloc index (inside for loop) ---
    logic [ROB_IDX_BITS:0] ai_sum_w [0:PIPE_WIDTH-1];
    logic [ROB_IDX_BITS-1:0] ai_w    [0:PIPE_WIDTH-1];
    always_comb begin
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            ai_sum_w[i] = {1'b0, tail_r} + (ROB_IDX_BITS+1)'(i);
            ai_w[i]     = (ai_sum_w[i] >= (ROB_IDX_BITS+1)'(ROB_DEPTH))
                          ? ai_sum_w[i][ROB_IDX_BITS-1:0] - ROB_DEPTH_U8
                          : ai_sum_w[i][ROB_IDX_BITS-1:0];
        end
    end

    // =========================================================================
    // Sequential logic: allocate, writeback, commit, flush
    // Pointer updates (next_tail, next_head) are computed inline to avoid
    // evaluation-order issues with external combinational wires.
    // =========================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            head_r   <= '0;
            tail_r   <= '0;
            count_r  <= '0;
            valid_r  <= '0;
            ready_r  <= '0;
            store_addr_done_r <= '0;
            store_data_done_r <= '0;
            rob_head_watchdog <= 12'd0;
            has_exc_r        <= '0;
            is_branch_r      <= '0;
            is_store_r       <= '0;
            is_load_r        <= '0;
            is_csr_r         <= '0;
            is_fence_r       <= '0;
            is_fence_i_r     <= '0;
            is_mret_r        <= '0;
            is_sret_r        <= '0;
            is_sfence_vma_r  <= '0;
            is_ecall_r       <= '0;
            is_wfi_r         <= '0;
            is_fused_r       <= '0;
            is_fp_instr_r    <= '0;
            is_mul_r         <= '0;
            is_div_r         <= '0;
            is_bru_r         <= '0;
            branch_taken_r       <= '0;
            branch_mispredict_r  <= '0;
            csr_we_r             <= '0;
            for (int i = 0; i < ROB_DEPTH; i++) csr_op_r[i] <= 2'd0;
            fp_fflags_packed     <= '0;
            /* verilator lint_off WIDTHCONCAT */
            pc_packed            <= '0;
            exc_code_packed      <= '0;
            exc_tval_packed      <= '0;
            branch_target_packed <= '0;
            branch_taken_target_packed <= '0;
            csr_addr_packed      <= '0;
            csr_wdata_packed     <= '0;
            fp_fflags_packed     <= '0;
            /* verilator lint_on WIDTHCONCAT */
        end else if (flush_valid && flush_full) begin
            head_r   <= '0;
            tail_r   <= '0;
            rob_head_watchdog <= 12'd0;
            count_r  <= '0;
            valid_r  <= '0;
            ready_r  <= '0;
            store_addr_done_r <= '0;
            store_data_done_r <= '0;
            has_exc_r        <= '0;
            is_branch_r      <= '0;
            is_store_r       <= '0;
            is_load_r        <= '0;
            is_csr_r         <= '0;
            is_fence_r       <= '0;
            is_fence_i_r     <= '0;
            is_mret_r        <= '0;
            is_sret_r        <= '0;
            is_sfence_vma_r  <= '0;
            is_ecall_r       <= '0;
            is_wfi_r         <= '0;
            is_fused_r       <= '0;
            is_fp_instr_r    <= '0;
            is_mul_r         <= '0;
            is_div_r         <= '0;
            is_bru_r         <= '0;
            branch_taken_r       <= '0;
            branch_mispredict_r  <= '0;
            csr_we_r             <= '0;
            for (int i = 0; i < ROB_DEPTH; i++) csr_op_r[i] <= 2'd0;
            exc_tval_packed      <= '0;
        end else if (flush_valid) begin
            // Partial flush (checkpoint restore)
            for (int i = 0; i < ROB_DEPTH; i++) begin
                if (rob_in_range[i]) begin
                    valid_r[i]  <= 1'b0;
                    ready_r[i]  <= 1'b0;
                    store_addr_done_r[i] <= 1'b0;
                    store_data_done_r[i] <= 1'b0;
                    is_branch_r[i]     <= 1'b0;
                    is_store_r[i]      <= 1'b0;
                    is_load_r[i]       <= 1'b0;
                    is_csr_r[i]        <= 1'b0;
                    is_fence_r[i]      <= 1'b0;
                    is_fence_i_r[i]    <= 1'b0;
                    is_mret_r[i]       <= 1'b0;
                    is_sret_r[i]       <= 1'b0;
                    is_sfence_vma_r[i] <= 1'b0;
                    is_ecall_r[i]      <= 1'b0;
                    is_wfi_r[i]        <= 1'b0;
                    is_fused_r[i]      <= 1'b0;
                    is_fp_instr_r[i]   <= 1'b0;
                    is_mul_r[i]        <= 1'b0;
                    is_div_r[i]        <= 1'b0;
                    is_bru_r[i]        <= 1'b0;
                    has_exc_r[i]       <= 1'b0;
                    exc_tval_packed[i*64 +: 64] <= 64'd0;
                    branch_taken_r[i]      <= 1'b0;
                    branch_mispredict_r[i] <= 1'b0;
                    csr_we_r[i]            <= 1'b0;
                    csr_op_r[i]            <= 2'd0;
                    fp_fflags_packed[i*5 +: 5] <= 5'd0;
                end
            end
            tail_r <= flush_rob_tail;

            // Commit on same cycle as partial flush
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                if (commit_count > i[2:0]) begin
                    valid_r[head_idx_w[i]]      <= 1'b0;
                    ready_r[head_idx_w[i]]      <= 1'b0;
                    store_addr_done_r[head_idx_w[i]] <= 1'b0;
                    store_data_done_r[head_idx_w[i]] <= 1'b0;
                    is_branch_r[head_idx_w[i]]  <= 1'b0;
                    is_store_r[head_idx_w[i]]   <= 1'b0;
                    is_load_r[head_idx_w[i]]    <= 1'b0;
                    is_csr_r[head_idx_w[i]]     <= 1'b0;
                    is_fence_r[head_idx_w[i]]   <= 1'b0;
                    is_fence_i_r[head_idx_w[i]] <= 1'b0;
                    is_mret_r[head_idx_w[i]]    <= 1'b0;
                    is_sret_r[head_idx_w[i]]    <= 1'b0;
                    is_sfence_vma_r[head_idx_w[i]] <= 1'b0;
                    is_ecall_r[head_idx_w[i]]   <= 1'b0;
                    is_wfi_r[head_idx_w[i]]     <= 1'b0;
                    is_fused_r[head_idx_w[i]]   <= 1'b0;
                    is_fp_instr_r[head_idx_w[i]] <= 1'b0;
                    is_mul_r[head_idx_w[i]]     <= 1'b0;
                    is_div_r[head_idx_w[i]]     <= 1'b0;
                    is_bru_r[head_idx_w[i]]     <= 1'b0;
                    exc_tval_packed[head_idx_w[i]*64 +: 64] <= 64'd0;
                    fp_fflags_packed[head_idx_w[i]*5 +: 5] <= 5'd0;
                end
            end
            if (commit_count > 0)
                head_r <= nh;

            // Recompute count — cap at pre-flush occupancy to avoid
            // wrap-around error when head advances past restored tail
            if (raw_count <= max_valid) begin
                count_r <= raw_count;
            end else begin
                count_r <= (ROB_IDX_BITS+1)'(0);
                head_r  <= flush_rob_tail;  // head=tail when empty
            end

            // Writebacks to surviving entries
            // (do not clobber a previously-marked ordering violation; see
            // the same comment in the normal-path block below.)
            for (int i = 0; i < CDB_WIDTH; i++) begin
                if (wb_valid[i]) begin
                    ready_r[wb_idx[i]] <= 1'b1;
                    if (wb_has_exception[i]) begin
                        has_exc_r[wb_idx[i]] <= 1'b1;
                        exc_code_packed[wb_idx[i]*4 +: 4] <= wb_exc_code[i];
                        exc_tval_packed[wb_idx[i]*64 +: 64] <= 64'd0;
                    end
                    if (!branch_mispredict_r[wb_idx[i]]) begin
                        branch_taken_r[wb_idx[i]]                <= wb_branch_taken[i];
                        branch_target_packed[wb_idx[i]*64 +: 64] <= wb_branch_target[i];
                        branch_taken_target_packed[wb_idx[i]*64 +: 64] <=
                            wb_branch_taken_target[i];
                        branch_mispredict_r[wb_idx[i]]           <= wb_branch_mispredict[i];
                    end
                    csr_we_r[wb_idx[i]]                     <= wb_csr_we[i];
                    csr_addr_packed[wb_idx[i]*12 +: 12]     <= wb_csr_addr[i];
                    csr_wdata_packed[wb_idx[i]*64 +: 64]    <= wb_csr_wdata[i];
                    csr_op_r[wb_idx[i]]                     <= wb_csr_op[i];
                    if (wb_fp_fflags_valid[i]) begin
                        fp_fflags_packed[wb_idx[i]*5 +: 5] <=
                            fp_fflags_packed[wb_idx[i]*5 +: 5] |
                            wb_fp_fflags[i];
                    end
                end
            end

            if (sta_wb_valid) begin
                store_addr_done_r[sta_wb_rob_idx] <= 1'b1;
                if (store_data_done_r[sta_wb_rob_idx] ||
                    (std_wb_valid && (std_wb_rob_idx == sta_wb_rob_idx)))
                    ready_r[sta_wb_rob_idx] <= 1'b1;
            end
            if (std_wb_valid) begin
                store_data_done_r[std_wb_rob_idx] <= 1'b1;
                if (store_addr_done_r[std_wb_rob_idx] ||
                    (sta_wb_valid && (sta_wb_rob_idx == std_wb_rob_idx)))
                    ready_r[std_wb_rob_idx] <= 1'b1;
            end

            // Load writeback sideband on flush path (surviving entries only).
            for (int lw = 0; lw < 2; lw++) begin
                if (load_wb_valid_r[lw]) begin
                    ready_r[load_wb_idx_r[lw]] <= 1'b1;
                    if (load_wb_has_exception_r[lw]) begin
                        has_exc_r[load_wb_idx_r[lw]] <= 1'b1;
                        exc_code_packed[load_wb_idx_r[lw]*4 +: 4] <= load_wb_exc_code_r[lw];
                        exc_tval_packed[load_wb_idx_r[lw]*64 +: 64] <= 64'd0;
                    end
                end
            end

            if (sideband_exc_valid) begin
                ready_r[sideband_exc_rob_idx] <= 1'b1;
                has_exc_r[sideband_exc_rob_idx] <= 1'b1;
                exc_code_packed[sideband_exc_rob_idx*4 +: 4] <= sideband_exc_code;
                exc_tval_packed[sideband_exc_rob_idx*64 +: 64] <= sideband_exc_tval;
            end

            // Ordering violation: see comment in normal-path block below.
            if (ordering_violation_valid) begin
                ready_r[ordering_violation_rob_idx]                <= 1'b1;
                has_exc_r[ordering_violation_rob_idx]              <= 1'b1;
                exc_code_packed[ordering_violation_rob_idx*4 +: 4] <=
                    EXC_INTERNAL_REPLAY;
                exc_tval_packed[ordering_violation_rob_idx*64 +: 64] <= 64'd0;
            end

            if (flush_clear_branch_mispredict &&
                valid_r[flush_prev_idx] &&
                is_branch_r[flush_prev_idx]) begin
                ready_r[flush_prev_idx]             <= 1'b1;
                branch_mispredict_r[flush_prev_idx] <= 1'b0;
            end
        end else begin
            // Normal operation

            // Allocate new entries at tail
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                if (alloc_count > i[2:0]) begin
                    valid_r[ai_w[i]]  <= 1'b1;
                    ready_r[ai_w[i]]  <= alloc_ready_now[i];
                    store_addr_done_r[ai_w[i]] <= 1'b0;
                    store_data_done_r[ai_w[i]] <= 1'b0;
                    pc_packed[ai_w[i]*64 +: 64]       <= alloc_pc[i];
                    has_exc_r[ai_w[i]]                <= alloc_has_exception[i];
                    exc_code_packed[ai_w[i]*4 +: 4]   <= alloc_exc_code[i];
                    exc_tval_packed[ai_w[i]*64 +: 64] <= 64'd0;
                    is_branch_r[ai_w[i]]      <= alloc_is_branch[i];
                    bpu_type_r[ai_w[i]]       <= alloc_bpu_type[i];
                    is_store_r[ai_w[i]]       <= alloc_is_store[i];
                    is_load_r[ai_w[i]]        <= alloc_is_load[i];
                    is_csr_r[ai_w[i]]         <= alloc_is_csr[i];
                    is_fence_r[ai_w[i]]       <= alloc_is_fence[i];
                    is_fence_i_r[ai_w[i]]     <= alloc_is_fence_i[i];
                    is_mret_r[ai_w[i]]        <= alloc_is_mret[i];
                    is_sret_r[ai_w[i]]        <= alloc_is_sret[i];
                    is_sfence_vma_r[ai_w[i]]  <= alloc_is_sfence_vma[i];
                    is_ecall_r[ai_w[i]]       <= alloc_is_ecall[i];
                    is_wfi_r[ai_w[i]]         <= alloc_is_wfi[i];
                    is_fused_r[ai_w[i]]       <= alloc_is_fused[i];
                    is_fp_instr_r[ai_w[i]]    <= alloc_is_fp_instr[i];
                    is_mul_r[ai_w[i]]         <= alloc_is_mul[i];
                    is_div_r[ai_w[i]]         <= alloc_is_div[i];
                    is_bru_r[ai_w[i]]         <= alloc_is_bru[i];
                    branch_taken_r[ai_w[i]]       <= 1'b0;
                    branch_target_packed[ai_w[i]*64 +: 64] <= 64'd0;
                    branch_taken_target_packed[ai_w[i]*64 +: 64] <= 64'd0;
                    branch_mispredict_r[ai_w[i]]  <= 1'b0;
                    csr_we_r[ai_w[i]]             <= 1'b0;
                    csr_addr_packed[ai_w[i]*12 +: 12]   <= 12'd0;
                    csr_wdata_packed[ai_w[i]*64 +: 64]  <= 64'd0;
                    csr_op_r[ai_w[i]]             <= 2'd0;
                    fp_fflags_packed[ai_w[i]*5 +: 5] <= 5'd0;
                end
            end
            if (alloc_count > 0)
                tail_r <= nt;

            // Writeback: mark entries as ready
            // NB: do NOT clobber branch_mispredict_r/branch_target/branch_taken
            // for an entry that has already been marked by an ordering
            // violation in a previous cycle.  The load's normal CDB writeback
            // arrives 1 cycle later (registered cdb_r) and would otherwise
            // overwrite the violation marking.
            for (int i = 0; i < CDB_WIDTH; i++) begin
                if (wb_valid[i]) begin
                    ready_r[wb_idx[i]] <= 1'b1;
                    if (wb_has_exception[i]) begin
                        has_exc_r[wb_idx[i]] <= 1'b1;
                        exc_code_packed[wb_idx[i]*4 +: 4] <= wb_exc_code[i];
                        exc_tval_packed[wb_idx[i]*64 +: 64] <= 64'd0;
                    end
                    if (!branch_mispredict_r[wb_idx[i]]) begin
                        branch_taken_r[wb_idx[i]]                <= wb_branch_taken[i];
                        branch_target_packed[wb_idx[i]*64 +: 64] <= wb_branch_target[i];
                        branch_taken_target_packed[wb_idx[i]*64 +: 64] <=
                            wb_branch_taken_target[i];
                        branch_mispredict_r[wb_idx[i]]           <= wb_branch_mispredict[i];
                    end
                    csr_we_r[wb_idx[i]]                     <= wb_csr_we[i];
                    csr_addr_packed[wb_idx[i]*12 +: 12]     <= wb_csr_addr[i];
                    csr_wdata_packed[wb_idx[i]*64 +: 64]    <= wb_csr_wdata[i];
                    csr_op_r[wb_idx[i]]                     <= wb_csr_op[i];
                    if (wb_fp_fflags_valid[i]) begin
                        fp_fflags_packed[wb_idx[i]*5 +: 5] <=
                            fp_fflags_packed[wb_idx[i]*5 +: 5] |
                            wb_fp_fflags[i];
                    end
                end
            end

            if (sta_wb_valid) begin
                store_addr_done_r[sta_wb_rob_idx] <= 1'b1;
                if (store_data_done_r[sta_wb_rob_idx] ||
                    (std_wb_valid && (std_wb_rob_idx == sta_wb_rob_idx)))
                    ready_r[sta_wb_rob_idx] <= 1'b1;
            end
            if (std_wb_valid) begin
                store_data_done_r[std_wb_rob_idx] <= 1'b1;
                if (store_addr_done_r[std_wb_rob_idx] ||
                    (sta_wb_valid && (sta_wb_rob_idx == std_wb_rob_idx)))
                    ready_r[std_wb_rob_idx] <= 1'b1;
            end

            // Load writeback sideband (Stage 2: loads removed from CDB broadcast).
            // Marks load ROB entries complete and forwards exception status.
            for (int lw = 0; lw < 2; lw++) begin
                if (load_wb_valid_r[lw]) begin
                    ready_r[load_wb_idx_r[lw]] <= 1'b1;
                    if (load_wb_has_exception_r[lw]) begin
                        has_exc_r[load_wb_idx_r[lw]] <= 1'b1;
                        exc_code_packed[load_wb_idx_r[lw]*4 +: 4] <= load_wb_exc_code_r[lw];
                        exc_tval_packed[load_wb_idx_r[lw]*64 +: 64] <= 64'd0;
                    end
                end
            end

            if (sideband_exc_valid) begin
                ready_r[sideband_exc_rob_idx] <= 1'b1;
                has_exc_r[sideband_exc_rob_idx] <= 1'b1;
                exc_code_packed[sideband_exc_rob_idx*4 +: 4] <= sideband_exc_code;
                exc_tval_packed[sideband_exc_rob_idx*64 +: 64] <= sideband_exc_tval;
            end

            // Ordering violation: mark the violating load as ready, flag it
            // with the internal replay marker so the
            // commit unit can recognise it and redirect to the load's own
            // PC without committing the load (its data is wrong; it must
            // re-execute against the now-visible store).
            if (ordering_violation_valid) begin
                ready_r[ordering_violation_rob_idx]                <= 1'b1;
                has_exc_r[ordering_violation_rob_idx]              <= 1'b1;
                exc_code_packed[ordering_violation_rob_idx*4 +: 4] <=
                    EXC_INTERNAL_REPLAY;
                exc_tval_packed[ordering_violation_rob_idx*64 +: 64] <= 64'd0;
            end

            // ROB head watchdog: diagnostic only.  A real core must not
            // manufacture a replay exception for an arbitrary not-ready head,
            // because stores and AMOs may already have issued side effects.
            if (valid_r[head_r] && !ready_r[head_r])
                rob_head_watchdog <= rob_head_watchdog + 12'd1;
            else
                rob_head_watchdog <= 12'd0;

            // Commit: advance head, clear valid and instruction-type flags
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                if (commit_count > i[2:0]) begin
                    valid_r[head_idx_w[i]]      <= 1'b0;
                    ready_r[head_idx_w[i]]      <= 1'b0;
                    store_addr_done_r[head_idx_w[i]] <= 1'b0;
                    store_data_done_r[head_idx_w[i]] <= 1'b0;
                    is_branch_r[head_idx_w[i]]  <= 1'b0;
                    is_store_r[head_idx_w[i]]   <= 1'b0;
                    is_load_r[head_idx_w[i]]    <= 1'b0;
                    is_csr_r[head_idx_w[i]]     <= 1'b0;
                    is_fence_r[head_idx_w[i]]   <= 1'b0;
                    is_fence_i_r[head_idx_w[i]] <= 1'b0;
                    is_mret_r[head_idx_w[i]]    <= 1'b0;
                    is_sret_r[head_idx_w[i]]    <= 1'b0;
                    is_sfence_vma_r[head_idx_w[i]] <= 1'b0;
                    is_ecall_r[head_idx_w[i]]   <= 1'b0;
                    is_wfi_r[head_idx_w[i]]     <= 1'b0;
                    is_fused_r[head_idx_w[i]]   <= 1'b0;
                    is_fp_instr_r[head_idx_w[i]] <= 1'b0;
                    is_mul_r[head_idx_w[i]]     <= 1'b0;
                    is_div_r[head_idx_w[i]]     <= 1'b0;
                    is_bru_r[head_idx_w[i]]     <= 1'b0;
                    exc_tval_packed[head_idx_w[i]*64 +: 64] <= 64'd0;
                    fp_fflags_packed[head_idx_w[i]*5 +: 5] <= 5'd0;
                end
            end
            if (commit_count > 0)
                head_r <= nh;

            // Update count
            count_r <= count_r + {(ROB_IDX_BITS-2)'(0), alloc_count} - {(ROB_IDX_BITS-2)'(0), commit_count};
        end
    end

`ifdef SIMULATION
    logic rob_stat_en;
    logic rob_trace_wdog_en;
    integer rob_stat_cyc;
    integer rob_head_not_ready_cyc;
    integer rob_head_not_ready_load_cyc;
    integer rob_head_not_ready_store_cyc;
    integer rob_head_not_ready_branch_cyc;
    integer rob_head_not_ready_serial_cyc;
    integer rob_head_not_ready_other_cyc;
    // Sub-decomposition of "other" head-stall bucket (Phase A.2).
    // mul/div/csr/bru/unknown sum to rob_head_not_ready_other_cyc.
    integer rob_head_not_ready_mul_cyc;
    integer rob_head_not_ready_div_cyc;
    integer rob_head_not_ready_csr_cyc;
    integer rob_head_not_ready_bru_cyc;
    integer rob_head_not_ready_unknown_cyc;
    integer rob_wdog_fire_cnt;
    integer rob_wdog_load_cnt;
    integer rob_wdog_store_cnt;
    integer rob_wdog_branch_cnt;
    integer rob_wdog_serial_cnt;
    integer rob_wdog_other_cnt;
    integer rob_head_wait_run;
    integer rob_head_wait_max;
    integer rob_head_wb_bypass_cand_cnt;
    integer rob_head_wb_bypass_load_cnt;
    integer rob_head_wb_bypass_store_cnt;
    integer rob_head_wb_bypass_branch_cnt;
    integer rob_head_wb_bypass_serial_cnt;
    integer rob_head_wb_bypass_other_cnt;
    integer rob_head_load_wb_bypass_fire_cnt;
    integer rob_head_arith_wb_bypass_fire_cnt;
    integer rob_slot1_load_wb_bypass_fire_cnt;
    integer rob_slot1_arith_wb_bypass_fire_cnt;
    integer rob_slot2_load_wb_bypass_fire_cnt;
    integer rob_slot2_arith_wb_bypass_fire_cnt;
    localparam int ROB_HEAD_PC_HIST_SLOTS = 32;
    logic [63:0] rob_head_pc_hist_pc [0:ROB_HEAD_PC_HIST_SLOTS-1];
    integer rob_head_pc_hist_count [0:ROB_HEAD_PC_HIST_SLOTS-1];
    integer rob_head_pc_hist_load [0:ROB_HEAD_PC_HIST_SLOTS-1];
    integer rob_head_pc_hist_store [0:ROB_HEAD_PC_HIST_SLOTS-1];
    integer rob_head_pc_hist_branch [0:ROB_HEAD_PC_HIST_SLOTS-1];
    integer rob_head_pc_hist_serial [0:ROB_HEAD_PC_HIST_SLOTS-1];
    integer rob_head_pc_hist_other [0:ROB_HEAD_PC_HIST_SLOTS-1];

    wire rob_head_serial =
        is_csr_r[head_r] | is_fence_r[head_r] | is_fence_i_r[head_r] |
        is_mret_r[head_r] | is_sret_r[head_r] | is_sfence_vma_r[head_r] |
        is_ecall_r[head_r] | is_wfi_r[head_r];

    logic rob_head_wb_bypass_cand;
    always_comb begin
        rob_head_wb_bypass_cand = head_ready_wb_bypass[0];
    end

    initial begin
        rob_stat_en = ($test$plusargs("PERF_PROFILE") || $test$plusargs("STAT_DUMP")) ? 1'b1 : 1'b0;
        rob_trace_wdog_en = ($test$plusargs("TRACE_WDOG") ? 1'b1 : 1'b0);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rob_stat_cyc                   <= 0;
            rob_head_not_ready_cyc         <= 0;
            rob_head_not_ready_load_cyc    <= 0;
            rob_head_not_ready_store_cyc   <= 0;
            rob_head_not_ready_branch_cyc  <= 0;
            rob_head_not_ready_serial_cyc  <= 0;
            rob_head_not_ready_other_cyc   <= 0;
            rob_head_not_ready_mul_cyc     <= 0;
            rob_head_not_ready_div_cyc     <= 0;
            rob_head_not_ready_csr_cyc     <= 0;
            rob_head_not_ready_bru_cyc     <= 0;
            rob_head_not_ready_unknown_cyc <= 0;
            rob_wdog_fire_cnt              <= 0;
            rob_wdog_load_cnt              <= 0;
            rob_wdog_store_cnt             <= 0;
            rob_wdog_branch_cnt            <= 0;
            rob_wdog_serial_cnt            <= 0;
            rob_wdog_other_cnt             <= 0;
            rob_head_wait_run              <= 0;
            rob_head_wait_max              <= 0;
            rob_head_wb_bypass_cand_cnt    <= 0;
            rob_head_wb_bypass_load_cnt    <= 0;
            rob_head_wb_bypass_store_cnt   <= 0;
            rob_head_wb_bypass_branch_cnt  <= 0;
            rob_head_wb_bypass_serial_cnt  <= 0;
            rob_head_wb_bypass_other_cnt   <= 0;
            rob_head_load_wb_bypass_fire_cnt <= 0;
            rob_head_arith_wb_bypass_fire_cnt <= 0;
            rob_slot1_load_wb_bypass_fire_cnt <= 0;
            rob_slot1_arith_wb_bypass_fire_cnt <= 0;
            rob_slot2_load_wb_bypass_fire_cnt <= 0;
            rob_slot2_arith_wb_bypass_fire_cnt <= 0;
            for (int i = 0; i < ROB_HEAD_PC_HIST_SLOTS; i++) begin
                rob_head_pc_hist_pc[i]     <= 64'd0;
                rob_head_pc_hist_count[i]  <= 0;
                rob_head_pc_hist_load[i]   <= 0;
                rob_head_pc_hist_store[i]  <= 0;
                rob_head_pc_hist_branch[i] <= 0;
                rob_head_pc_hist_serial[i] <= 0;
                rob_head_pc_hist_other[i]  <= 0;
            end
        end else if (rob_stat_en || rob_trace_wdog_en) begin
            rob_stat_cyc <= rob_stat_cyc + 1;

            if (valid_r[head_r] && !ready_r[head_r]) begin
                begin : head_pc_hist_sample
                    int hit_idx;
                    int free_idx;
                    int min_idx;
                    int min_count;
                    int use_idx;
                    logic [63:0] stall_pc;

                    hit_idx = -1;
                    free_idx = -1;
                    min_idx = 0;
                    min_count = rob_head_pc_hist_count[0];
                    use_idx = -1;
                    stall_pc = pc_packed[head_r*64 +: 64];
                    for (int i = 0; i < ROB_HEAD_PC_HIST_SLOTS; i++) begin
                        if ((rob_head_pc_hist_count[i] != 0) &&
                            (rob_head_pc_hist_pc[i] == stall_pc) &&
                            (hit_idx < 0)) begin
                            hit_idx = i;
                        end
                        if ((rob_head_pc_hist_count[i] == 0) &&
                            (free_idx < 0)) begin
                            free_idx = i;
                        end
                        if (rob_head_pc_hist_count[i] < min_count) begin
                            min_idx = i;
                            min_count = rob_head_pc_hist_count[i];
                        end
                    end

                    if (hit_idx >= 0)
                        use_idx = hit_idx;
                    else if (free_idx >= 0)
                        use_idx = free_idx;
                    else
                        use_idx = min_idx;

                    if (hit_idx < 0) begin
                        rob_head_pc_hist_pc[use_idx] <= stall_pc;
                        rob_head_pc_hist_count[use_idx] <= 1;
                        rob_head_pc_hist_load[use_idx] <=
                            is_load_r[head_r] ? 1 : 0;
                        rob_head_pc_hist_store[use_idx] <=
                            is_store_r[head_r] ? 1 : 0;
                        rob_head_pc_hist_branch[use_idx] <=
                            is_branch_r[head_r] ? 1 : 0;
                        rob_head_pc_hist_serial[use_idx] <=
                            rob_head_serial ? 1 : 0;
                        rob_head_pc_hist_other[use_idx] <=
                            (!is_load_r[head_r] &&
                             !is_store_r[head_r] &&
                             !is_branch_r[head_r] &&
                             !rob_head_serial) ? 1 : 0;
                    end else begin
                        rob_head_pc_hist_count[use_idx] <=
                            rob_head_pc_hist_count[use_idx] + 1;
                        if (is_load_r[head_r])
                            rob_head_pc_hist_load[use_idx] <=
                                rob_head_pc_hist_load[use_idx] + 1;
                        else if (is_store_r[head_r])
                            rob_head_pc_hist_store[use_idx] <=
                                rob_head_pc_hist_store[use_idx] + 1;
                        else if (is_branch_r[head_r])
                            rob_head_pc_hist_branch[use_idx] <=
                                rob_head_pc_hist_branch[use_idx] + 1;
                        else if (rob_head_serial)
                            rob_head_pc_hist_serial[use_idx] <=
                                rob_head_pc_hist_serial[use_idx] + 1;
                        else
                            rob_head_pc_hist_other[use_idx] <=
                                rob_head_pc_hist_other[use_idx] + 1;
                    end
                end

                rob_head_not_ready_cyc <= rob_head_not_ready_cyc + 1;
                rob_head_wait_run <= rob_head_wait_run + 1;
                if ((rob_head_wait_run + 1) > rob_head_wait_max)
                    rob_head_wait_max <= rob_head_wait_run + 1;

                if (is_load_r[head_r])
                    rob_head_not_ready_load_cyc <= rob_head_not_ready_load_cyc + 1;
                else if (is_store_r[head_r])
                    rob_head_not_ready_store_cyc <= rob_head_not_ready_store_cyc + 1;
                else if (is_branch_r[head_r])
                    rob_head_not_ready_branch_cyc <= rob_head_not_ready_branch_cyc + 1;
                else if (rob_head_serial)
                    rob_head_not_ready_serial_cyc <= rob_head_not_ready_serial_cyc + 1;
                else begin
                    // Catch-all: increment total "other" AND decompose into
                    // mul/div/csr/bru/unknown sub-buckets (sub-counters sum
                    // back to other_cyc).  CSR is already absorbed by the
                    // serial path above so the csr sub-counter is expected
                    // to remain 0 in practice; kept for symmetry.
                    rob_head_not_ready_other_cyc <= rob_head_not_ready_other_cyc + 1;
                    if (is_mul_r[head_r])
                        rob_head_not_ready_mul_cyc <= rob_head_not_ready_mul_cyc + 1;
                    else if (is_div_r[head_r])
                        rob_head_not_ready_div_cyc <= rob_head_not_ready_div_cyc + 1;
                    else if (is_csr_r[head_r])
                        rob_head_not_ready_csr_cyc <= rob_head_not_ready_csr_cyc + 1;
                    else if (is_bru_r[head_r])
                        rob_head_not_ready_bru_cyc <= rob_head_not_ready_bru_cyc + 1;
                    else
                        rob_head_not_ready_unknown_cyc <= rob_head_not_ready_unknown_cyc + 1;
                end

                if (rob_head_wb_bypass_cand) begin
                    rob_head_wb_bypass_cand_cnt <= rob_head_wb_bypass_cand_cnt + 1;
                    if (is_load_r[head_r])
                        rob_head_wb_bypass_load_cnt <= rob_head_wb_bypass_load_cnt + 1;
                    else if (is_store_r[head_r])
                        rob_head_wb_bypass_store_cnt <= rob_head_wb_bypass_store_cnt + 1;
                    else if (is_branch_r[head_r])
                        rob_head_wb_bypass_branch_cnt <= rob_head_wb_bypass_branch_cnt + 1;
                    else if (rob_head_serial)
                        rob_head_wb_bypass_serial_cnt <= rob_head_wb_bypass_serial_cnt + 1;
                    else
                        rob_head_wb_bypass_other_cnt <= rob_head_wb_bypass_other_cnt + 1;
                end

                if (head_ready_head_load_wb_bypass)
                    rob_head_load_wb_bypass_fire_cnt <=
                        rob_head_load_wb_bypass_fire_cnt + 1;
                if (head_ready_head_arith_wb_bypass)
                    rob_head_arith_wb_bypass_fire_cnt <=
                        rob_head_arith_wb_bypass_fire_cnt + 1;
                if (head_ready_slot1_load_wb_bypass)
                    rob_slot1_load_wb_bypass_fire_cnt <=
                        rob_slot1_load_wb_bypass_fire_cnt + 1;
                if (head_ready_slot1_arith_wb_bypass)
                    rob_slot1_arith_wb_bypass_fire_cnt <=
                        rob_slot1_arith_wb_bypass_fire_cnt + 1;
                if (head_ready_slot2_load_wb_bypass)
                    rob_slot2_load_wb_bypass_fire_cnt <=
                        rob_slot2_load_wb_bypass_fire_cnt + 1;
                if (head_ready_slot2_arith_wb_bypass)
                    rob_slot2_arith_wb_bypass_fire_cnt <=
                        rob_slot2_arith_wb_bypass_fire_cnt + 1;
            end else begin
                rob_head_wait_run <= 0;
            end

            if (rob_head_watchdog == 12'd62) begin
                rob_wdog_fire_cnt <= rob_wdog_fire_cnt + 1;
                if (is_load_r[head_r])
                    rob_wdog_load_cnt <= rob_wdog_load_cnt + 1;
                else if (is_store_r[head_r])
                    rob_wdog_store_cnt <= rob_wdog_store_cnt + 1;
                else if (is_branch_r[head_r])
                    rob_wdog_branch_cnt <= rob_wdog_branch_cnt + 1;
                else if (rob_head_serial)
                    rob_wdog_serial_cnt <= rob_wdog_serial_cnt + 1;
                else
                    rob_wdog_other_cnt <= rob_wdog_other_cnt + 1;

                if (rob_trace_wdog_en) begin
                    $display("[ROB_WDOG] cyc=%0d head=%0d pc=%016h load=%b store=%b branch=%b serial=%b sta_done=%b std_done=%b count=%0d tail=%0d",
                        rob_stat_cyc,
                        head_r,
                        pc_packed[head_r*64 +: 64],
                        is_load_r[head_r],
                        is_store_r[head_r],
                        is_branch_r[head_r],
                        rob_head_serial,
                        store_addr_done_r[head_r],
                        store_data_done_r[head_r],
                        count_r,
                        tail_r);
                end
            end
        end
    end

    final begin
        if (rob_stat_en || rob_trace_wdog_en) begin
            $display("");
            $display("=== ROB HEAD STALL SUMMARY ===");
            $display("Cycles sampled:             %0d", rob_stat_cyc);
            $display("Head valid-not-ready cycles:%0d", rob_head_not_ready_cyc);
            $display("  load/store/branch/serial/other: %0d / %0d / %0d / %0d / %0d",
                rob_head_not_ready_load_cyc,
                rob_head_not_ready_store_cyc,
                rob_head_not_ready_branch_cyc,
                rob_head_not_ready_serial_cyc,
                rob_head_not_ready_other_cyc);
            $display("  other-class: mul/div/csr/bru/unknown: %0d / %0d / %0d / %0d / %0d",
                rob_head_not_ready_mul_cyc,
                rob_head_not_ready_div_cyc,
                rob_head_not_ready_csr_cyc,
                rob_head_not_ready_bru_cyc,
                rob_head_not_ready_unknown_cyc);
            $display("Max contiguous head wait:   %0d", rob_head_wait_max);
            $display("Same-cycle WB ready bypass candidates: %0d", rob_head_wb_bypass_cand_cnt);
            $display("  load/store/branch/serial/other: %0d / %0d / %0d / %0d / %0d",
                rob_head_wb_bypass_load_cnt,
                rob_head_wb_bypass_store_cnt,
                rob_head_wb_bypass_branch_cnt,
                rob_head_wb_bypass_serial_cnt,
                rob_head_wb_bypass_other_cnt);
            $display("Head-load WB bypass fires: %0d",
                rob_head_load_wb_bypass_fire_cnt);
            $display("Head-arith WB bypass fires: %0d",
                rob_head_arith_wb_bypass_fire_cnt);
            $display("Slot1-load WB bypass fires: %0d",
                rob_slot1_load_wb_bypass_fire_cnt);
            $display("Slot1-arith WB bypass fires: %0d",
                rob_slot1_arith_wb_bypass_fire_cnt);
            $display("Slot2-load WB bypass fires: %0d",
                rob_slot2_load_wb_bypass_fire_cnt);
            $display("Slot2-arith WB bypass fires: %0d",
                rob_slot2_arith_wb_bypass_fire_cnt);
            $display("Watchdog fires total:       %0d", rob_wdog_fire_cnt);
            $display("  load/store/branch/serial/other: %0d / %0d / %0d / %0d / %0d",
                rob_wdog_load_cnt,
                rob_wdog_store_cnt,
                rob_wdog_branch_cnt,
                rob_wdog_serial_cnt,
                rob_wdog_other_cnt);
            $display("Head valid-not-ready PC samples (approx top %0d PCs):",
                     ROB_HEAD_PC_HIST_SLOTS);
            for (int i = 0; i < ROB_HEAD_PC_HIST_SLOTS; i++) begin
                if (rob_head_pc_hist_count[i] != 0) begin
                    $display("  pc=%016h total=%0d load/store/branch/serial/other=%0d/%0d/%0d/%0d/%0d",
                        rob_head_pc_hist_pc[i],
                        rob_head_pc_hist_count[i],
                        rob_head_pc_hist_load[i],
                        rob_head_pc_hist_store[i],
                        rob_head_pc_hist_branch[i],
                        rob_head_pc_hist_serial[i],
                        rob_head_pc_hist_other[i]);
                end
            end
        end
    end
`endif

endmodule

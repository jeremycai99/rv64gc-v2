/* file: rv64gc_core_top.sv
 Description: RV64GC v2 core top-level integration module.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
module rv64gc_core_top
    import rv64gc_pkg::*;
    import isa_pkg::*;
    import uarch_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // L2-to-memory interface
    output logic        mem_req_valid,
    output logic [63:0] mem_req_addr,
    output logic        mem_req_we,
    output logic [511:0] mem_req_wdata,
    input  logic        mem_req_ready,
    input  logic        mem_resp_valid,
    input  logic [511:0] mem_resp_data,

    // External interrupts
    input  logic        mtip, msip, meip,
    input  logic        stip, ssip, seip,

    // Timer
    input  logic [63:0] time_val,

    // Tohost address (for test pass/fail monitoring)
    input  logic [63:0] tohost_addr,

    // Tohost detection (snoops committed store buffer drain to D-cache)
    output logic        tohost_wr_valid,
    output logic [63:0] tohost_wr_data,

    // Performance counters (for IPC measurement / benchmarking)
    output logic [63:0] perf_mcycle,
    output logic [63:0] perf_minstret
);

    // =========================================================================
    // Flush signals
    // =========================================================================
    // commit_flush: from commit module (exceptions, ordering violations)
    // bru_flush:    from BRU at execute time (branch mispredicts — early redirect)
    // flush_out:    merged signal broadcast everywhere
    flush_t commit_flush;
    flush_t bru_flush;
    flush_t flush_out;

    // Forward declarations for BRU signals used in fetch_unit port connections
    logic        bru_early_redirect;
    logic [63:0] bru_target;

    // =========================================================================
    // PRF Ready Table
    // =========================================================================
    logic [INT_PRF_DEPTH-1:0] preg_ready_table;
    logic [INT_PRF_DEPTH-1:0] preg_ready_table_comb;

    // =========================================================================
    // CDB signals (6 writeback buses)
    // =========================================================================
    logic [CDB_WIDTH-1:0]     cdb_valid;
    logic [PHYS_REG_BITS-1:0] cdb_tag  [0:CDB_WIDTH-1];
    logic [63:0]              cdb_data [0:CDB_WIDTH-1];
    // Extended CDB fields for ROB writeback
    logic [ROB_IDX_BITS-1:0]  cdb_rob_idx      [0:CDB_WIDTH-1];
    logic [CDB_WIDTH-1:0]     cdb_has_exception;
    logic [3:0]               cdb_exc_code     [0:CDB_WIDTH-1];
    logic [CDB_WIDTH-1:0]     cdb_is_branch;
    logic [CDB_WIDTH-1:0]     cdb_branch_taken;
    logic [63:0]              cdb_branch_target [0:CDB_WIDTH-1];
    logic [63:0]              cdb_branch_taken_target [0:CDB_WIDTH-1];
    logic [CDB_WIDTH-1:0]     cdb_branch_mispredict;
    logic [CDB_WIDTH-1:0]     cdb_csr_we;
    logic [11:0]              cdb_csr_addr     [0:CDB_WIDTH-1];
    logic [63:0]              cdb_csr_wdata    [0:CDB_WIDTH-1];
    logic [1:0]               cdb_csr_op       [0:CDB_WIDTH-1];

    // =========================================================================
    // Registered CDB (1-cycle delayed) for wakeup / ROB writeback / preg_ready
    // The combinational CDB drives bypass (same-cycle forwarding) + PRF writes.
    // The registered CDB drives IQ wakeup, ROB writeback, and preg_ready_table
    // to break the combinational loop:
    //   IQ issue -> PRF read -> ALU -> CDB -> IQ wakeup -> IQ re-select
    // =========================================================================
    logic [CDB_WIDTH-1:0]     cdb_valid_r;
    logic [PHYS_REG_BITS-1:0] cdb_tag_r  [0:CDB_WIDTH-1];
    logic [63:0]              cdb_data_r [0:CDB_WIDTH-1];
    logic [ROB_IDX_BITS-1:0]  cdb_rob_idx_r      [0:CDB_WIDTH-1];
    logic [CDB_WIDTH-1:0]     cdb_has_exception_r;
    logic [3:0]               cdb_exc_code_r     [0:CDB_WIDTH-1];
    logic [CDB_WIDTH-1:0]     cdb_is_branch_r;
    logic [CDB_WIDTH-1:0]     cdb_branch_taken_r;
    logic [63:0]              cdb_branch_target_r [0:CDB_WIDTH-1];
    logic [63:0]              cdb_branch_taken_target_r [0:CDB_WIDTH-1];
    logic [CDB_WIDTH-1:0]     cdb_branch_mispredict_r;
    logic [CDB_WIDTH-1:0]     cdb_csr_we_r;
    logic [11:0]              cdb_csr_addr_r     [0:CDB_WIDTH-1];
    logic [63:0]              cdb_csr_wdata_r    [0:CDB_WIDTH-1];
    logic [1:0]               cdb_csr_op_r       [0:CDB_WIDTH-1];

    // =========================================================================
    // Bypass sources (6 sources: ALU0, ALU1, ALU2, ALU3, MUL, Load0)
    // =========================================================================
    logic [5:0]               bypass_valid;
    logic [PHYS_REG_BITS-1:0] bypass_tag  [0:5];
    logic [63:0]              bypass_data [0:5];

    // =========================================================================
    // 1. FETCH UNIT
    // =========================================================================
    logic [2:0]  fetch_count;
    logic [31:0] fetch_insn      [0:PIPE_WIDTH-1];
    logic [63:0] fetch_pc        [0:PIPE_WIDTH-1];
    logic [PIPE_WIDTH-1:0] fetch_is_rvc;
    logic [PIPE_WIDTH-1:0] fetch_bp_taken;
    logic [63:0] fetch_bp_target [0:PIPE_WIDTH-1];
    logic        fetch_bp_owner_valid;
    logic [2:0]  fetch_bp_owner_slot;
    logic        fetch_bp_owner_from_subgroup;
    logic [63:0] fetch_bp_lookup_pc;
    logic [4:0]  fetch_bp_ras_tos;
    logic [63:0] fetch_bp_ras_top;
    logic [GHR_BITS-1:0] fetch_bp_ghr;
    logic          lb_active;
    logic [GHR_BITS-1:0] ghr_out;
    logic                ghr_restore_valid_fe;
    logic [GHR_BITS-1:0] ghr_restore_val_fe;
    logic                ras_restore_valid_fe;
    logic [4:0]          ras_restore_tos_fe;
    logic                ras_restore_top_valid_fe;
    logic [63:0]         ras_restore_top_addr_fe;
    logic        icache_fill_req_valid;
    logic [63:0] icache_fill_req_addr;
    logic        icache_fill_resp_valid;
    logic [63:0] icache_fill_resp_addr;
    logic [511:0] icache_fill_resp_data;

    // Prefetch L2 signals (from fetch_unit NLPB to L2 prefetch port).
    // Declared here because fetch_unit instantiation below uses them as
    // port connections; an explicit declaration must precede first use
    // under IEEE 1800 strict semantics (DSim rejects implicit-net
    // declarations; xsim was lenient).  L2 cache instantiation consumes
    // them later at the L2 block.
    logic        pf_l2_req_valid;
    logic [63:0] pf_l2_req_addr;
    logic        pf_l2_req_ready;
    logic        pf_l2_resp_valid;
    logic [63:0] pf_l2_resp_addr;
    logic [511:0] pf_l2_resp_data;

    // BPU update signals (from commit)
    logic        bpu_update_valid;
    logic [63:0] bpu_update_pc;
    logic        bpu_tage_update_valid;
    logic [63:0] bpu_tage_update_pc;
    logic        bpu_update_taken;
    logic        bpu_update_mispredict;
    logic [63:0] bpu_update_target;
    logic [2:0]  bpu_update_type;
    logic [GHR_BITS-1:0] bpu_update_ghr;

    // Stall from decode/rename
    logic        backend_stall;

    // FENCE.I signal
    logic        fence_i_signal;

    fetch_unit u_fetch_unit (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .fetch_count            (fetch_count),
        .fetch_insn             (fetch_insn),
        .fetch_pc               (fetch_pc),
        .fetch_is_rvc           (fetch_is_rvc),
        .fetch_bp_taken         (fetch_bp_taken),
        .fetch_bp_target        (fetch_bp_target),
        .fetch_bp_owner_valid   (fetch_bp_owner_valid),
        .fetch_bp_owner_slot    (fetch_bp_owner_slot),
        .fetch_bp_owner_from_subgroup(fetch_bp_owner_from_subgroup),
        .fetch_bp_lookup_pc     (fetch_bp_lookup_pc),
        .fetch_bp_ras_tos       (fetch_bp_ras_tos),
        .fetch_bp_ras_top       (fetch_bp_ras_top),
        .fetch_bp_ghr           (fetch_bp_ghr),
        .backend_stall          (backend_stall),
        // Phase-5 convergence: when loop-buffer playback owns rename input,
        // quiesce fetch traffic and let redirect/flush restart the frontend.
        .frontend_hold          (lb_active),
        // Redirect from commit flush OR BRU early redirect (commit wins).
        .redirect_valid         (flush_out.valid || bru_early_redirect),
        .redirect_pc            (flush_out.valid ? flush_out.redirect_pc : bru_target),
        .bpu_update_valid       (bpu_update_valid),
        .bpu_update_pc          (bpu_update_pc),
        .bpu_tage_update_valid  (bpu_tage_update_valid),
        .bpu_tage_update_pc     (bpu_tage_update_pc),
        .bpu_update_taken       (bpu_update_taken),
        .bpu_update_mispredict  (bpu_update_mispredict),
        .bpu_update_target      (bpu_update_target),
        .bpu_update_type        (bpu_update_type),
        .bpu_update_ghr         (bpu_update_ghr),
        .ghr_restore_valid      (ghr_restore_valid_fe),
        .ghr_restore_val        (ghr_restore_val_fe),
        .ghr_out                (ghr_out),
        .ras_restore_valid      (ras_restore_valid_fe),
        .ras_restore_tos        (ras_restore_tos_fe),
        .ras_restore_top_valid  (ras_restore_top_valid_fe),
        .ras_restore_top_addr   (ras_restore_top_addr_fe),
        .icache_fill_req_valid  (icache_fill_req_valid),
        .icache_fill_req_addr   (icache_fill_req_addr),
        .icache_fill_resp_valid (icache_fill_resp_valid),
        .icache_fill_resp_addr  (icache_fill_resp_addr),
        .icache_fill_resp_data  (icache_fill_resp_data),
        .fence_i                (fence_i_signal),
        .pf_l2_req_valid        (pf_l2_req_valid),
        .pf_l2_req_addr         (pf_l2_req_addr),
        .pf_l2_req_ready        (pf_l2_req_ready),
        .pf_l2_resp_valid       (pf_l2_resp_valid),
        .pf_l2_resp_addr        (pf_l2_resp_addr),
        .pf_l2_resp_data        (pf_l2_resp_data)
    );

    // =========================================================================
    // 2. DECODE
    // =========================================================================
    decoded_insn_t dec_insn_out [0:PIPE_WIDTH-1];
    logic [2:0]    dec_count_out;

    decode u_decode (
        .clk            (clk),
        .rst_n          (rst_n),
        .fetch_count    (fetch_count),
        .fetch_insn     (fetch_insn),
        .fetch_pc       (fetch_pc),
        .fetch_is_rvc   (fetch_is_rvc),
        .fetch_bp_taken (fetch_bp_taken),
        .fetch_bp_target(fetch_bp_target),
        .fetch_bp_owner_valid(fetch_bp_owner_valid),
        .fetch_bp_owner_slot(fetch_bp_owner_slot),
        .fetch_bp_owner_from_subgroup(fetch_bp_owner_from_subgroup),
        .fetch_bp_lookup_pc(fetch_bp_lookup_pc),
        .fetch_bp_ras_tos(fetch_bp_ras_tos),
        .fetch_bp_ras_top(fetch_bp_ras_top),
        .fetch_bp_ghr   (fetch_bp_ghr),
        .dec_insn       (dec_insn_out),
        .dec_count      (dec_count_out),
        .stall          (backend_stall),
        .flush          (flush_out.valid)
    );

    // =========================================================================
    // 3. FUSION DETECTOR
    // =========================================================================
    decoded_insn_t fused_insn [0:PIPE_WIDTH-1];
    logic [2:0]    fused_count;

    fusion_detector u_fusion_detector (
        .dec_in         (dec_insn_out),
        .dec_count_in   (dec_count_out),
        .dec_out        (fused_insn),
        .dec_count_out  (fused_count)
    );

    // =========================================================================
    // 4. LOOP BUFFER
    // =========================================================================
    decoded_insn_t lb_insn [0:PIPE_WIDTH-1];
    logic [2:0]    lb_count;

    // Detect backward taken branch for loop buffer trigger.
    // Combinational: must fire same cycle as the branch is decoded so the
    // loop buffer captures the loop body starting from the correct PC.
    // (A prior registered version was a Verilator eval-scheduling workaround;
    //  on xsim that workaround dropped loop-buffer activation to ~0% and
    //  starved fetch 52% of cycles on CoreMark.)
    logic backward_branch_taken;
    always_comb begin
        backward_branch_taken = 1'b0;
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            if (3'(i) < fused_count &&
                fused_insn[i].bp_taken &&
                fused_insn[i].is_branch &&
                !fused_insn[i].bp_from_subgroup &&
                (fused_insn[i].bp_target < fused_insn[i].pc)) begin
                backward_branch_taken = 1'b1;
            end
        end
    end

    // Rename stall signal
    logic rename_stall;

    loop_buffer u_loop_buffer (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .dec_insn               (fused_insn),
        .dec_count              (fused_count),
        .backward_branch_taken  (backward_branch_taken),
        .lb_insn                (lb_insn),
        .lb_count               (lb_count),
        .active                 (lb_active),
        // Phase-5 convergence: loop-buffer playback must obey the same
        // frontend redirect epoch as fetch. Commit flushes and BRU early
        // redirects both terminate the current playback/capture state.
        .invalidate             (flush_out.valid || bru_early_redirect),
        .stall                  (rename_stall)
    );

    // Mux: loop buffer playback or normal decode path
    decoded_insn_t rename_dec_in [0:PIPE_WIDTH-1];
    logic [2:0]    rename_dec_count;

    always_comb begin
        if (lb_active) begin
            for (int i = 0; i < PIPE_WIDTH; i++)
                rename_dec_in[i] = lb_insn[i];
            rename_dec_count = lb_count;
        end else begin
            for (int i = 0; i < PIPE_WIDTH; i++)
                rename_dec_in[i] = fused_insn[i];
            rename_dec_count = fused_count;
        end
    end

    // =========================================================================
    // 5. ROB (declare early since rename needs alloc_idx)
    // =========================================================================
    logic [ROB_IDX_BITS-1:0] rob_alloc_idx [0:PIPE_WIDTH-1];
    logic                    rob_alloc_ready;
    logic [ROB_IDX_BITS-1:0] rob_head_idx;
    logic [ROB_IDX_BITS-1:0] rob_tail_idx;
    logic                    rob_empty;
    logic                    rob_full;

    // ROB head readout signals for commit
    logic [PIPE_WIDTH-1:0]   rob_head_valid;
    logic [PIPE_WIDTH-1:0]   rob_head_ready;
    logic [63:0]             rob_head_pc          [0:PIPE_WIDTH-1];
    logic [PIPE_WIDTH-1:0]   rob_head_has_exception;
    logic [3:0]              rob_head_exc_code    [0:PIPE_WIDTH-1];
    logic [PIPE_WIDTH-1:0]   rob_head_is_branch;
    logic [2:0]              rob_head_bpu_type [0:PIPE_WIDTH-1];
    logic [PIPE_WIDTH-1:0]   rob_head_is_store;
    logic [PIPE_WIDTH-1:0]   rob_head_is_load;
    logic [PIPE_WIDTH-1:0]   rob_head_is_csr;
    logic [PIPE_WIDTH-1:0]   rob_head_is_fence;
    logic [PIPE_WIDTH-1:0]   rob_head_is_fence_i;
    logic [PIPE_WIDTH-1:0]   rob_head_is_mret;
    logic [PIPE_WIDTH-1:0]   rob_head_is_sret;
    logic [PIPE_WIDTH-1:0]   rob_head_is_sfence_vma;
    logic [PIPE_WIDTH-1:0]   rob_head_is_ecall;
    logic [PIPE_WIDTH-1:0]   rob_head_is_wfi;
    logic [PIPE_WIDTH-1:0]   rob_head_branch_taken;
    logic [63:0]             rob_head_branch_target [0:PIPE_WIDTH-1];
    logic [63:0]             rob_head_branch_taken_target [0:PIPE_WIDTH-1];
    logic [PIPE_WIDTH-1:0]   rob_head_branch_mispredict;
    logic [11:0]             rob_head_csr_addr    [0:PIPE_WIDTH-1];
    logic [63:0]             rob_head_csr_wdata   [0:PIPE_WIDTH-1];
    logic [PIPE_WIDTH-1:0]   rob_head_csr_we;
    logic [1:0]              rob_head_csr_op      [0:PIPE_WIDTH-1];

    // Commit signals
    logic [2:0]              commit_count;
    commit_t                 commit_out [0:PIPE_WIDTH-1];
    logic [2:0]              store_commit_count;
    logic [2:0]              load_commit_count;
    logic [2:0]              insn_retired_count;

    // =========================================================================
    // Rename buffer: parallel to ROB, stores pdst/old_pdst/rd_arch
    // =========================================================================
    rename_buf_entry_t rename_buf [0:ROB_DEPTH-1];

    // Checkpoint storage parallel to ROB (declarations hoisted from later
    // so the ifdef SIMULATION init block below can reach them)
    logic                       rob_uses_checkpoint [0:ROB_DEPTH-1];
    logic [CHECKPOINT_BITS-1:0] rob_checkpoint_id   [0:ROB_DEPTH-1];

`ifdef SIMULATION
    // Zero-initialize these unpacked arrays at t=0.  The commit-read
    // combinational block below indexes rename_buf / rob_*_checkpoint*
    // with (rob_head_idx + i) mod ROB_DEPTH.  rob_head_idx is a reset-
    // initialized flop, but at Time 0 Iteration 0 — before the first
    // negedge rst_n has propagated — it is still X in a 4-state
    // simulator like xsim.  An X index into an unpacked array is
    // out-of-range, and xsim treats that as a FATAL kernel error.
    // DSim silently returns X for the same read.  Initializing the
    // data array so every element is 0 means any X-indexed read at
    // t=0 still returns 0 and combinational evaluation converges.
    // See doc/xsim_lessons_learned.md for the general rule (array
    // control flops get reset; wide data arrays get ifdef-SIM zero
    // init to avoid X propagation without loading the synthesis
    // reset net).
    initial begin
        for (int i = 0; i < ROB_DEPTH; i++) begin
            rename_buf[i]          = '{default: '0};
            rob_uses_checkpoint[i] = 1'b0;
            rob_checkpoint_id[i]   = '0;
        end
    end
`endif
    logic [2:0] ren_count_raw;
    // Suppress rename output on a commit-driven flush so stale pre-flush
    // instructions cannot enter the ROB, DQ, or ready table.
    logic [2:0] ren_count_w;
    assign ren_count_w = flush_out.valid ? 3'd0 : ren_count_raw;

    // Read rename buffer at head for commit
    logic [PHYS_REG_BITS-1:0] rb_head_pdst      [0:PIPE_WIDTH-1];
    logic [PHYS_REG_BITS-1:0] rb_head_old_pdst   [0:PIPE_WIDTH-1];
    logic [4:0]               rb_head_rd_arch    [0:PIPE_WIDTH-1];
    logic [PIPE_WIDTH-1:0]    rb_head_rd_valid;
    logic [4:0]               rb_head_bp_ras_tos [0:PIPE_WIDTH-1];
    logic [63:0]              rb_head_bp_ras_top [0:PIPE_WIDTH-1];
    logic [1:0]               rb_head_bp_ras_op  [0:PIPE_WIDTH-1];
    logic [PIPE_WIDTH-1:0]    rb_head_bp_owner;
    logic [63:0]              rb_head_bp_lookup_pc [0:PIPE_WIDTH-1];
    logic [GHR_BITS-1:0]      rb_head_bp_ghr [0:PIPE_WIDTH-1];
    logic [PIPE_WIDTH-1:0]    rb_head_uses_checkpoint;
    logic [CHECKPOINT_BITS-1:0] rb_head_checkpoint_id [0:PIPE_WIDTH-1];

    // Checkpoint storage parallel to ROB — declarations hoisted above
    // alongside rename_buf so the ifdef SIMULATION init block can reach
    // them.

    // Read at head for commit
    always_comb begin
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            automatic logic [ROB_IDX_BITS-1:0] idx;
            // Compute wrapped index: (head + i) % ROB_DEPTH
            if ((rob_head_idx + ROB_IDX_BITS'(i)) >= ROB_IDX_BITS'(ROB_DEPTH))
                idx = rob_head_idx + ROB_IDX_BITS'(i) - ROB_IDX_BITS'(ROB_DEPTH);
            else
                idx = rob_head_idx + ROB_IDX_BITS'(i);
            rb_head_pdst[i]          = rename_buf[idx].pdst;
            rb_head_old_pdst[i]      = rename_buf[idx].old_pdst;
            rb_head_rd_arch[i]       = rename_buf[idx].rd_arch;
            rb_head_rd_valid[i]      = rename_buf[idx].rd_valid;
            rb_head_bp_owner[i]      = rename_buf[idx].bp_owner;
            rb_head_bp_lookup_pc[i]  = rename_buf[idx].bp_lookup_pc;
            rb_head_bp_ras_tos[i]    = rename_buf[idx].bp_ras_tos;
            rb_head_bp_ras_top[i]    = rename_buf[idx].bp_ras_top;
            rb_head_bp_ras_op[i]     = rename_buf[idx].bp_ras_op;
            rb_head_bp_ghr[i]        = rename_buf[idx].bp_ghr;
            rb_head_uses_checkpoint[i] = rob_uses_checkpoint[idx];
            rb_head_checkpoint_id[i]   = rob_checkpoint_id[idx];
        end
    end

    // =========================================================================
    // 5a. RENAME
    // =========================================================================
    renamed_insn_t ren_insn [0:PIPE_WIDTH-1];
    // LQ/SQ allocation signals
    logic [LQ_IDX_BITS-1:0] lq_alloc_idx [0:PIPE_WIDTH-1];
    logic [SQ_IDX_BITS-1:0] sq_alloc_idx [0:PIPE_WIDTH-1];
    logic                   lq_full;
    logic                   sq_full;
    // Dispatch queue backpressure
    logic                   dq_full;

    // Commit-to-rename signals
    logic [PHYS_REG_BITS-1:0] commit_old_pdst [0:PIPE_WIDTH-1];
    logic [PIPE_WIDTH-1:0]    commit_rd_valid;
    logic [4:0]               commit_rd_arch_w  [0:PIPE_WIDTH-1];
    logic [PHYS_REG_BITS-1:0] commit_pdst_w     [0:PIPE_WIDTH-1];
    logic [PIPE_WIDTH-1:0]    commit_release_cp;
    logic [CHECKPOINT_BITS-1:0] commit_cp_id [0:PIPE_WIDTH-1];

    // Move/zero elimination flags from rename (per output slot)
    logic [PIPE_WIDTH-1:0] ren_move_eliminated;
    logic [PIPE_WIDTH-1:0] ren_zero_eliminated;
    // Combined: instruction was eliminated and must not be dispatched
    logic [PIPE_WIDTH-1:0] ren_eliminated;
    assign ren_eliminated = ren_move_eliminated | ren_zero_eliminated;

    rename u_rename (
        .clk              (clk),
        .rst_n            (rst_n),
        .dec_insn         (rename_dec_in),
        .dec_count        (rename_dec_count),
        .ren_insn         (ren_insn),
        .ren_count        (ren_count_raw),
        .ren_move_eliminated (ren_move_eliminated),
        .ren_zero_eliminated (ren_zero_eliminated),
        .rob_alloc_idx    (rob_alloc_idx),
        .rob_alloc_ready  (rob_alloc_ready),
        .stall            (rename_stall),
        .dq_full          (dq_full),
        .lq_alloc_idx     (lq_alloc_idx),
        .sq_alloc_idx     (sq_alloc_idx),
        .lq_full          (lq_full),
        .sq_full          (sq_full),
        .preg_ready_table (preg_ready_table),
        .flush_in         (flush_out),
        .commit_count     (commit_count),
        .commit_old_pdst  (commit_old_pdst),
        .commit_rd_valid  (commit_rd_valid),
        .commit_rd_arch   (commit_rd_arch_w),
        .commit_pdst      (commit_pdst_w),
        .commit_release_cp(commit_release_cp),
        .commit_cp_id     (commit_cp_id)
    );

    // Backend stall: rename cannot accept or loop buffer stalls
    assign backend_stall = rename_stall;

    // =========================================================================
    // Write rename buffer at allocation time
    // =========================================================================
    localparam logic [1:0] RAS_NONE = 2'd0;
    localparam logic [1:0] RAS_PUSH = 2'd1;
    localparam logic [1:0] RAS_POP  = 2'd2;

    function automatic logic [4:0] ras_tos_after_redirect(
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
            ras_tos_after_redirect = next_tos;
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || (flush_out.valid && flush_out.full_flush)) begin
            // Clear on reset AND on full flush.  Stale entries in rename_buf
            // would survive a full flush (ROB clears valid_r to 0 but leaves
            // the metadata untouched).  On commit-wrap-around after a flush,
            // a stale entry's rd_valid=1 plus its leftover pdst/rd_arch from
            // a prior life would cause commit to write committed_rat with the
            // wrong (stale) mapping — the observed RAT aliasing bug.
            for (int i = 0; i < ROB_DEPTH; i++) begin
                rename_buf[i]          <= '0;
                rob_uses_checkpoint[i] <= 1'b0;
                rob_checkpoint_id[i]   <= '0;
            end
        end else begin
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                if (3'(i) < ren_count_w) begin
                    rename_buf[ren_insn[i].rob_idx].pdst     <= ren_insn[i].pdst;
                    rename_buf[ren_insn[i].rob_idx].old_pdst <= ren_insn[i].old_pdst;
                    rename_buf[ren_insn[i].rob_idx].rd_arch  <= ren_insn[i].base.rd_arch;
                    rename_buf[ren_insn[i].rob_idx].rd_valid <= ren_insn[i].base.rd_valid;
                    rename_buf[ren_insn[i].rob_idx].bp_owner <= ren_insn[i].base.bp_owner;
                    rename_buf[ren_insn[i].rob_idx].bp_lookup_pc <= ren_insn[i].base.bp_lookup_pc;
                    rename_buf[ren_insn[i].rob_idx].bp_ras_tos <= ren_insn[i].base.bp_ras_tos;
                    rename_buf[ren_insn[i].rob_idx].bp_ras_top <= ren_insn[i].base.bp_ras_top;
                    rename_buf[ren_insn[i].rob_idx].bp_ghr <= ren_insn[i].base.bp_ghr;
                    rename_buf[ren_insn[i].rob_idx].bp_ras_op <=
                        ((ren_insn[i].base.is_jal &&
                          ((ren_insn[i].base.rd_arch == 5'd1) ||
                           (ren_insn[i].base.rd_arch == 5'd5))) ||
                         (ren_insn[i].base.is_jalr &&
                          ((ren_insn[i].base.rd_arch == 5'd1) ||
                           (ren_insn[i].base.rd_arch == 5'd5))))
                            ? RAS_PUSH
                            : ((ren_insn[i].base.is_jalr &&
                                (ren_insn[i].base.rd_arch == 5'd0) &&
                                ((ren_insn[i].base.rs1_arch == 5'd1) ||
                                 (ren_insn[i].base.rs1_arch == 5'd5)))
                                   ? RAS_POP
                                   : RAS_NONE);
                    rob_uses_checkpoint[ren_insn[i].rob_idx] <= ren_insn[i].uses_checkpoint;
                    rob_checkpoint_id[ren_insn[i].rob_idx]   <= ren_insn[i].checkpoint_id;
                end
            end
        end
    end

    // Extract commit data
    always_comb begin
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            commit_old_pdst[i] = commit_out[i].old_pdst;
            commit_rd_valid[i] = commit_out[i].rd_valid;
            commit_rd_arch_w[i] = commit_out[i].rd_arch;
            commit_pdst_w[i]    = commit_out[i].pdst;
        end
    end

    // =========================================================================
    // 5b. ROB alloc data from rename
    // =========================================================================
    logic [63:0]            rob_alloc_pc         [0:PIPE_WIDTH-1];
    logic [PIPE_WIDTH-1:0]  rob_alloc_is_branch;
    logic [PIPE_WIDTH-1:0]  rob_alloc_is_store;
    logic [PIPE_WIDTH-1:0]  rob_alloc_is_load;
    logic [PIPE_WIDTH-1:0]  rob_alloc_is_csr;
    logic [PIPE_WIDTH-1:0]  rob_alloc_is_fence;
    logic [PIPE_WIDTH-1:0]  rob_alloc_is_fence_i;
    logic [PIPE_WIDTH-1:0]  rob_alloc_is_mret;
    logic [PIPE_WIDTH-1:0]  rob_alloc_is_sret;
    logic [PIPE_WIDTH-1:0]  rob_alloc_is_sfence_vma;
    logic [PIPE_WIDTH-1:0]  rob_alloc_is_ecall;
    logic [PIPE_WIDTH-1:0]  rob_alloc_is_wfi;
    logic [2:0]             rob_alloc_bpu_type [0:PIPE_WIDTH-1];

    always_comb begin
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            rob_alloc_pc[i]          = ren_insn[i].base.pc;
            rob_alloc_is_branch[i]   = ren_insn[i].base.is_branch;

            // Compute BTB branch type for BPU update at commit:
            //   BT_COND=0 BT_JAL=1 BT_JALR=2 BT_CALL=3 BT_RET=4
            if (ren_insn[i].base.fu_type == FU_BRU) begin
                case (ren_insn[i].base.br_op)
                    BR_JAL: begin
                        if (ren_insn[i].base.rd_arch == 5'd1 ||
                            ren_insn[i].base.rd_arch == 5'd5)
                            rob_alloc_bpu_type[i] = 3'd3; // BT_CALL
                        else
                            rob_alloc_bpu_type[i] = 3'd1; // BT_JAL
                    end
                    BR_JALR: begin
                        // RET if rs1 = x1 or x5, rd = x0
                        if ((ren_insn[i].base.rs1_arch == 5'd1 ||
                             ren_insn[i].base.rs1_arch == 5'd5) &&
                            ren_insn[i].base.rd_arch == 5'd0)
                            rob_alloc_bpu_type[i] = 3'd4; // BT_RET
                        // CALL if rd = x1 or x5
                        else if (ren_insn[i].base.rd_arch == 5'd1 ||
                                 ren_insn[i].base.rd_arch == 5'd5)
                            rob_alloc_bpu_type[i] = 3'd3; // BT_CALL
                        else
                            rob_alloc_bpu_type[i] = 3'd2; // BT_JALR
                    end
                    default:
                        rob_alloc_bpu_type[i] = 3'd0; // BT_COND
                endcase
            end else begin
                rob_alloc_bpu_type[i] = 3'd0;
            end
            rob_alloc_is_store[i]    = ren_insn[i].base.is_store;
            rob_alloc_is_load[i]     = ren_insn[i].base.is_load;
            rob_alloc_is_csr[i]      = ren_insn[i].base.is_csr;
            rob_alloc_is_fence[i]    = ren_insn[i].base.is_fence;
            rob_alloc_is_fence_i[i]  = ren_insn[i].base.is_fence_i;
            rob_alloc_is_mret[i]     = ren_insn[i].base.is_mret;
            rob_alloc_is_sret[i]     = ren_insn[i].base.is_sret;
            rob_alloc_is_sfence_vma[i] = ren_insn[i].base.is_sfence_vma;
            rob_alloc_is_ecall[i]    = ren_insn[i].base.is_ecall;
            rob_alloc_is_wfi[i]      = ren_insn[i].base.is_wfi;
        end
    end

    // STA writeback register declarations (used in ROB port connections below)
    logic                     lsu_sta_wb_valid_r;
    logic [ROB_IDX_BITS-1:0]  lsu_sta_wb_rob_idx_r;
    logic                     lsu_std_wb_valid_r;
    logic [ROB_IDX_BITS-1:0]  lsu_std_wb_rob_idx_r;

    // LSU → ROB forwarded signals used in the ROB port list below.
    // Declared up here (not next to the LSU instantiation) so that the
    // ROB port connections at lines ~563-566 have an explicit declaration
    // in scope — IEEE 1800 strict (DSim) rejects implicit-net declarations;
    // xsim was lenient.
    logic                     lsu_ordering_violation;
    logic [ROB_IDX_BITS-1:0]  lsu_violation_rob_idx;
    logic                     replay_valid;
    logic [ROB_IDX_BITS-1:0]  replay_rob_idx_from;
    // LSU-driven per-port load issue suppression (consumed by the load IQ
    // before the LSU instantiation below).
    logic [1:0]               lsu_load_issue_suppress_raw;
    logic [1:0]               lsu_load_issue_suppress;
    // D-cache fill snoop (produced by dcache, consumed by LSU instantiated
    // earlier in the file).
    logic        dc_fill_snoop_valid;
    logic [63:0] dc_fill_snoop_addr;
    logic [511:0] dc_fill_snoop_data;

    rob u_rob (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .alloc_count            (ren_count_w),
        .alloc_idx              (rob_alloc_idx),
        .alloc_ready            (rob_alloc_ready),
        .alloc_pc               (rob_alloc_pc),
        .alloc_is_branch        (rob_alloc_is_branch),
        .alloc_bpu_type         (rob_alloc_bpu_type),
        .alloc_is_store         (rob_alloc_is_store),
        .alloc_is_load          (rob_alloc_is_load),
        .alloc_is_csr           (rob_alloc_is_csr),
        .alloc_is_fence         (rob_alloc_is_fence),
        .alloc_is_fence_i       (rob_alloc_is_fence_i),
        .alloc_is_mret          (rob_alloc_is_mret),
        .alloc_is_sret          (rob_alloc_is_sret),
        .alloc_is_sfence_vma    (rob_alloc_is_sfence_vma),
        .alloc_is_ecall         (rob_alloc_is_ecall),
        .alloc_is_wfi           (rob_alloc_is_wfi),
        .wb_valid               (cdb_valid_r),
        .wb_idx                 (cdb_rob_idx_r),
        .wb_has_exception       (cdb_has_exception_r),
        .wb_exc_code            (cdb_exc_code_r),
        .wb_is_branch           (cdb_is_branch_r),
        .wb_branch_taken        (cdb_branch_taken_r),
        .wb_branch_target       (cdb_branch_target_r),
        .wb_branch_taken_target (cdb_branch_taken_target_r),
        .wb_branch_mispredict   (cdb_branch_mispredict_r),
        .wb_csr_we              (cdb_csr_we_r),
        .wb_csr_addr            (cdb_csr_addr_r),
        .wb_csr_wdata           (cdb_csr_wdata_r),
        .wb_csr_op              (cdb_csr_op_r),
        .sta_wb_valid           (lsu_sta_wb_valid_r),
        .sta_wb_rob_idx         (lsu_sta_wb_rob_idx_r),
        .std_wb_valid           (lsu_std_wb_valid_r),
        .std_wb_rob_idx         (lsu_std_wb_rob_idx_r),
        .ordering_violation_valid   (lsu_ordering_violation),
        .ordering_violation_rob_idx (lsu_violation_rob_idx),
        .replay_valid               (replay_valid),
        .replay_rob_idx_from        (replay_rob_idx_from),
        .head_idx               (rob_head_idx),
        .head_valid             (rob_head_valid),
        .head_ready             (rob_head_ready),
        .head_pc                (rob_head_pc),
        .head_has_exception     (rob_head_has_exception),
        .head_exc_code          (rob_head_exc_code),
        .head_is_branch         (rob_head_is_branch),
        .head_bpu_type          (rob_head_bpu_type),
        .head_is_store          (rob_head_is_store),
        .head_is_load           (rob_head_is_load),
        .head_is_csr            (rob_head_is_csr),
        .head_is_fence          (rob_head_is_fence),
        .head_is_fence_i        (rob_head_is_fence_i),
        .head_is_mret           (rob_head_is_mret),
        .head_is_sret           (rob_head_is_sret),
        .head_is_sfence_vma     (rob_head_is_sfence_vma),
        .head_is_ecall          (rob_head_is_ecall),
        .head_is_wfi            (rob_head_is_wfi),
        .head_branch_taken      (rob_head_branch_taken),
        .head_branch_target     (rob_head_branch_target),
        .head_branch_taken_target (rob_head_branch_taken_target),
        .head_branch_mispredict (rob_head_branch_mispredict),
        .head_csr_addr          (rob_head_csr_addr),
        .head_csr_wdata         (rob_head_csr_wdata),
        .head_csr_we            (rob_head_csr_we),
        .head_csr_op            (rob_head_csr_op),
        .commit_count           (commit_count),
        .flush_valid            (flush_out.valid),
        .flush_rob_tail         (flush_out.rob_idx),
        .flush_full             (flush_out.full_flush),
        .tail_idx               (rob_tail_idx),
        .empty                  (rob_empty),
        .full                   (rob_full)
    );

    // =========================================================================
    // 6. DISPATCH QUEUE
    // =========================================================================
    logic [2:0]    dq_deq_count;
    renamed_insn_t dq_deq_data [0:PIPE_WIDTH-1];
    logic [1:0]    dq_deq_iq_target [0:PIPE_WIDTH-1];
    logic [NUM_INT_IQS-1:0] iq_full_vec;

    // Per-IQ occupancy forward-declared here (IQ modules are instantiated
    // further below; dispatch routing needs the values earlier).
    logic [$clog2(IQ_INT_DEPTH+1)-1:0] iq0_occ;
    logic [$clog2(IQ_INT_DEPTH+1)-1:0] iq1_occ;
    logic [$clog2(IQ_INT_DEPTH+1)-1:0] iq2_occ;

    // Pack per-IQ occupancy into an array for dispatch routing.
    logic [5:0] iq_occ_vec [0:NUM_INT_IQS-1];
    assign iq_occ_vec[0] = 6'(iq0_occ);
    assign iq_occ_vec[1] = 6'(iq1_occ);
    assign iq_occ_vec[2] = 6'(iq2_occ);

    dispatch_queue u_dispatch_queue (
        .clk         (clk),
        .rst_n       (rst_n),
        .enq_count   (ren_count_w),
        .enq_data    (ren_insn),
        .full        (dq_full),
        .deq_count   (dq_deq_count),
        .deq_data    (dq_deq_data),
        .deq_iq_target(dq_deq_iq_target),
        .iq_full     (iq_full_vec),
        .iq_occ      (iq_occ_vec),
        .flush_valid (flush_out.valid),
        .flush_full  (flush_out.full_flush)
    );

    // =========================================================================
    // 7. ISSUE QUEUES (3 integer + 1 load + 1 store)
    // =========================================================================
    // Build IQ enqueue data from dispatch output

    // --- IQ0: ALU0 + ALU1 + BRU ---
    logic [1:0]  iq0_enq_valid;
    iq_entry_t   iq0_enq_data [0:1];
    logic        iq0_full;
    // iq0_occ declared earlier (before dispatch_queue)
    logic [1:0]  iq0_issue_valid;
    iq_entry_t   iq0_issue_data [0:1];

    // --- IQ1: ALU2 + MUL ---
    logic [1:0]  iq1_enq_valid;
    iq_entry_t   iq1_enq_data [0:1];
    logic        iq1_full;
    // iq1_occ declared earlier (before dispatch_queue)
    logic [1:0]  iq1_issue_valid;
    iq_entry_t   iq1_issue_data [0:1];
    // Single-issue wrapper signals for IQ1 (NUM_SELECT=1)
    logic [0:0]  iq1_issue_valid_s;
    iq_entry_t   iq1_issue_data_s [0:0];

    // --- IQ2: ALU3 + DIV + CSR ---
    logic [1:0]  iq2_enq_valid;
    iq_entry_t   iq2_enq_data [0:1];
    logic        iq2_full;
    // iq2_occ declared earlier (before dispatch_queue)
    logic [1:0]  iq2_issue_valid;
    iq_entry_t   iq2_issue_data [0:1];
    // Single-issue wrapper signals for IQ2 (NUM_SELECT=1)
    logic [0:0]  iq2_issue_valid_s;
    iq_entry_t   iq2_issue_data_s [0:0];

    // --- Load IQ ---
    logic [1:0]  iq_load_enq_valid;
    iq_entry_t   iq_load_enq_data [0:1];
    logic        iq_load_full;
    logic [1:0]  iq_load_issue_candidate_valid;
    logic [1:0]  iq_load_issue_valid;
    iq_entry_t   iq_load_issue_data [0:1];
    logic [1:0]  store_iq_older_than_load;
    logic [1:0]  issueq_probe_none_valid;
    logic [ROB_IDX_BITS-1:0] issueq_probe_none_rob_idx [0:1];
    logic [ROB_IDX_BITS-1:0] store_iq_load_probe_rob_idx [0:1];

    // --- Store address IQ (STA) ---
    logic [1:0]  iq_store_enq_valid;
    iq_entry_t   iq_store_enq_data [0:1];
    logic        iq_store_full;
    logic [1:0]  iq_store_issue_valid;
    iq_entry_t   iq_store_issue_data [0:1];
    // Single-issue wrapper signals for store IQ (NUM_SELECT=1)
    logic [0:0]  iq_store_issue_valid_s;
    iq_entry_t   iq_store_issue_data_s [0:0];

    // --- Store data IQ (STD) ---
    logic [1:0]  iq_std_enq_valid;
    iq_entry_t   iq_std_enq_data [0:1];
    logic        iq_std_full;
    logic [0:0]  iq_std_issue_valid_s;
    iq_entry_t   iq_std_issue_data_s [0:0];

    assign iq_full_vec = {iq2_full, iq1_full, iq0_full};

    // Speculative wakeup / cancel signals (from LSU)
    logic [1:0]               lsu_spec_wakeup_valid;
    logic [PHYS_REG_BITS-1:0] lsu_spec_wakeup_tag [0:1];
    logic [1:0]               lsu_spec_cancel_valid;
    logic [PHYS_REG_BITS-1:0] lsu_spec_cancel_tag [0:1];

    assign issueq_probe_none_valid = 2'b00;
    assign issueq_probe_none_rob_idx[0] = '0;
    assign issueq_probe_none_rob_idx[1] = '0;
    assign store_iq_load_probe_rob_idx[0] = iq_load_issue_data[0].rob_idx;
    assign store_iq_load_probe_rob_idx[1] = iq_load_issue_data[1].rob_idx;
    assign lsu_load_issue_suppress = lsu_load_issue_suppress_raw |
                                     store_iq_older_than_load;

    // =========================================================================
    // Dispatch routing: precompute renamed_insn_t to iq_entry_t conversion
    // =========================================================================
    iq_entry_t dq_iq_entry [0:PIPE_WIDTH-1];

    always_comb begin
        for (int s = 0; s < PIPE_WIDTH; s++) begin
            dq_iq_entry[s]._pad         = '0;
            dq_iq_entry[s].valid        = dq_deq_data[s].base.valid;
            dq_iq_entry[s].rob_idx      = dq_deq_data[s].rob_idx;
            dq_iq_entry[s].pdst         = dq_deq_data[s].pdst;
            dq_iq_entry[s].rs1_phys     = dq_deq_data[s].rs1_phys;
            dq_iq_entry[s].rs2_phys     = dq_deq_data[s].rs2_phys;
            dq_iq_entry[s].rs1_ready    = dq_deq_data[s].rs1_ready;
            dq_iq_entry[s].rs2_ready    = dq_deq_data[s].rs2_ready;
            dq_iq_entry[s].imm          = dq_deq_data[s].base.imm;
            dq_iq_entry[s].fu_type      = dq_deq_data[s].base.fu_type;
            dq_iq_entry[s].alu_op       = dq_deq_data[s].base.alu_op;
            dq_iq_entry[s].br_op        = dq_deq_data[s].base.br_op;
            dq_iq_entry[s].mul_op       = dq_deq_data[s].base.mul_op;
            dq_iq_entry[s].div_op       = dq_deq_data[s].base.div_op;
            dq_iq_entry[s].mem_size     = dq_deq_data[s].base.mem_size;
            dq_iq_entry[s].csr_op       = dq_deq_data[s].base.csr_op;
            dq_iq_entry[s].csr_addr     = dq_deq_data[s].base.csr_addr;
            dq_iq_entry[s].is_w_op      = dq_deq_data[s].base.is_w_op;
            dq_iq_entry[s].is_unsigned  = dq_deq_data[s].base.is_unsigned;
            dq_iq_entry[s].use_imm      = dq_deq_data[s].base.use_imm;
            dq_iq_entry[s].pc           = dq_deq_data[s].base.pc;
            dq_iq_entry[s].bp_taken     = dq_deq_data[s].base.bp_taken;
            dq_iq_entry[s].bp_target    = dq_deq_data[s].base.bp_target;
            dq_iq_entry[s].bp_ras_tos   = dq_deq_data[s].base.bp_ras_tos;
            dq_iq_entry[s].bp_ras_op    =
                ((dq_deq_data[s].base.is_jal &&
                  ((dq_deq_data[s].base.rd_arch == 5'd1) ||
                   (dq_deq_data[s].base.rd_arch == 5'd5))) ||
                 (dq_deq_data[s].base.is_jalr &&
                  ((dq_deq_data[s].base.rd_arch == 5'd1) ||
                   (dq_deq_data[s].base.rd_arch == 5'd5))))
                    ? RAS_PUSH
                    : ((dq_deq_data[s].base.is_jalr &&
                        (dq_deq_data[s].base.rd_arch == 5'd0) &&
                        ((dq_deq_data[s].base.rs1_arch == 5'd1) ||
                         (dq_deq_data[s].base.rs1_arch == 5'd5)))
                           ? RAS_POP
                           : RAS_NONE);
            dq_iq_entry[s].bp_ghr       = dq_deq_data[s].base.bp_ghr;
            dq_iq_entry[s].is_fused     = dq_deq_data[s].base.is_fused;
            dq_iq_entry[s].fusion_type  = dq_deq_data[s].base.fusion_type;
            dq_iq_entry[s].fused_imm    = dq_deq_data[s].base.fused_imm;
            dq_iq_entry[s].is_amo       = dq_deq_data[s].base.is_amo;
            dq_iq_entry[s].amo_op       = dq_deq_data[s].base.amo_op;
            dq_iq_entry[s].amo_aq       = dq_deq_data[s].base.amo_aq;
            dq_iq_entry[s].amo_rl       = dq_deq_data[s].base.amo_rl;
            dq_iq_entry[s].is_rvc       = dq_deq_data[s].base.is_rvc;
            dq_iq_entry[s].checkpoint_id   = dq_deq_data[s].checkpoint_id;
            dq_iq_entry[s].uses_checkpoint = dq_deq_data[s].uses_checkpoint;
            dq_iq_entry[s].sq_idx       = dq_deq_data[s].sq_idx;
            dq_iq_entry[s].lq_idx       = dq_deq_data[s].lq_idx;
        end
    end

    // Per-IQ enqueue counters for routing
    logic [2:0] iq0_enq_cnt, iq1_enq_cnt, iq2_enq_cnt;
    logic [2:0] iq_ld_enq_cnt, iq_st_enq_cnt;

    always_comb begin
        // Default: no enqueues
        iq0_enq_valid = 2'b00;
        iq1_enq_valid = 2'b00;
        iq2_enq_valid = 2'b00;
        iq_load_enq_valid  = 2'b00;
        iq_store_enq_valid = 2'b00;
        iq_std_enq_valid   = 2'b00;
        for (int i = 0; i < 2; i++) begin
            iq0_enq_data[i] = '0;
            iq1_enq_data[i] = '0;
            iq2_enq_data[i] = '0;
            iq_load_enq_data[i]  = '0;
            iq_store_enq_data[i] = '0;
            iq_std_enq_data[i]   = '0;
        end
        iq0_enq_cnt = 3'd0;
        iq1_enq_cnt = 3'd0;
        iq2_enq_cnt = 3'd0;
        iq_ld_enq_cnt = 3'd0;
        iq_st_enq_cnt = 3'd0;

        for (int i = 0; i < PIPE_WIDTH; i++) begin
            if (3'(i) < dq_deq_count) begin
                case (dq_deq_iq_target[i])
                    2'd0: begin // IQ0
                        if (iq0_enq_cnt < 3'd2) begin
                            iq0_enq_data[iq0_enq_cnt[0]] = dq_iq_entry[i];
                            iq0_enq_valid[iq0_enq_cnt[0]] = 1'b1;
                            iq0_enq_cnt = iq0_enq_cnt + 3'd1;
                        end
                    end
                    2'd1: begin // IQ1
                        if (iq1_enq_cnt < 3'd2) begin
                            iq1_enq_data[iq1_enq_cnt[0]] = dq_iq_entry[i];
                            iq1_enq_valid[iq1_enq_cnt[0]] = 1'b1;
                            iq1_enq_cnt = iq1_enq_cnt + 3'd1;
                        end
                    end
                    2'd2: begin // IQ2
                        if (iq2_enq_cnt < 3'd2) begin
                            iq2_enq_data[iq2_enq_cnt[0]] = dq_iq_entry[i];
                            iq2_enq_valid[iq2_enq_cnt[0]] = 1'b1;
                            iq2_enq_cnt = iq2_enq_cnt + 3'd1;
                        end
                    end
                    2'd3: begin // Memory IQ: split load/store
                        if (dq_deq_data[i].base.is_load) begin
                            if (iq_ld_enq_cnt < 3'd2) begin
                                iq_load_enq_data[iq_ld_enq_cnt[0]] = dq_iq_entry[i];
                                iq_load_enq_valid[iq_ld_enq_cnt[0]] = 1'b1;
                                iq_ld_enq_cnt = iq_ld_enq_cnt + 3'd1;
                            end
                        end else begin
                            // Split stores into independent STA and STD issue
                            // queues.  Both halves carry the same sq_idx/rob_idx
                            // payload, but each queue ignores the non-local
                            // source dependency so address publication can run
                            // ahead of late store-data wakeup.
                            if (iq_st_enq_cnt < 3'd2) begin
                                iq_store_enq_data[iq_st_enq_cnt[0]]          = dq_iq_entry[i];
                                iq_store_enq_data[iq_st_enq_cnt[0]].fu_type  = FU_STA;
                                iq_store_enq_data[iq_st_enq_cnt[0]].rs2_phys = '0;
                                iq_store_enq_data[iq_st_enq_cnt[0]].rs2_ready = 1'b1;
                                iq_store_enq_valid[iq_st_enq_cnt[0]]         = 1'b1;

                                iq_std_enq_data[iq_st_enq_cnt[0]]            = dq_iq_entry[i];
                                iq_std_enq_data[iq_st_enq_cnt[0]].fu_type    = FU_STD;
                                iq_std_enq_data[iq_st_enq_cnt[0]].pdst       = '0;
                                iq_std_enq_data[iq_st_enq_cnt[0]].rs1_phys   = '0;
                                iq_std_enq_data[iq_st_enq_cnt[0]].rs1_ready  = 1'b1;
                                iq_std_enq_valid[iq_st_enq_cnt[0]]           = 1'b1;
                                iq_st_enq_cnt = iq_st_enq_cnt + 3'd1;
                            end
                        end
                    end
                endcase
            end
        end
    end

    // =========================================================================
    // IQ instances
    // =========================================================================
    issue_queue #(.DEPTH(IQ_INT_DEPTH), .NUM_ENQUEUE(2), .NUM_SELECT(2),
                  .PORT0_ONLY_FU(3'd0))  // BRU can issue from either port
    u_iq0 (
        .clk             (clk),
        .rst_n           (rst_n),
        .enq_valid       (iq0_enq_valid),
        .enq_data        (iq0_enq_data),
        .full            (iq0_full),
        .cdb_valid       (cdb_valid_r),
        .cdb_tag         (cdb_tag_r),
        .spec_wk_valid   (lsu_spec_wakeup_valid[0]),
        .spec_wk_tag     (lsu_spec_wakeup_tag[0]),
        .spec_cancel_valid(lsu_spec_cancel_valid[0]),
        .spec_cancel_tag (lsu_spec_cancel_tag[0]),
        .preg_ready_table(preg_ready_table_comb),
        .issue_candidate_valid(),
        .issue_valid     (iq0_issue_valid),
        .issue_data      (iq0_issue_data),
        .older_probe_valid(issueq_probe_none_valid),
        .older_probe_rob_idx(issueq_probe_none_rob_idx),
        .has_older_entry (),
        .rob_head        (rob_head_idx),
        .flush_valid     (flush_out.valid),
        .flush_rob_tail  (flush_out.rob_idx),
        .flush_full      (flush_out.full_flush),
        .issue_suppress  ('0),
        .occupancy       (iq0_occ)
    );

    // IQ1 and IQ2 are single-issue: only port 0 is wired to ALU2/MUL and
    // ALU3/DIV/CSR respectively.  NUM_SELECT=1 prevents the IQ from
    // retiring entries on port 1 that no functional unit executes
    // (which would cause the ROB to fill up with orphaned entries).
    issue_queue #(.DEPTH(IQ_INT_DEPTH), .NUM_ENQUEUE(2), .NUM_SELECT(1))
    u_iq1 (
        .clk             (clk),
        .rst_n           (rst_n),
        .enq_valid       (iq1_enq_valid),
        .enq_data        (iq1_enq_data),
        .full            (iq1_full),
        .cdb_valid       (cdb_valid_r),
        .cdb_tag         (cdb_tag_r),
        .spec_wk_valid   (lsu_spec_wakeup_valid[0]),
        .spec_wk_tag     (lsu_spec_wakeup_tag[0]),
        .spec_cancel_valid(lsu_spec_cancel_valid[0]),
        .spec_cancel_tag (lsu_spec_cancel_tag[0]),
        .preg_ready_table(preg_ready_table_comb),
        .issue_candidate_valid(),
        .issue_valid     (iq1_issue_valid_s),
        .issue_data      (iq1_issue_data_s),
        .older_probe_valid(issueq_probe_none_valid),
        .older_probe_rob_idx(issueq_probe_none_rob_idx),
        .has_older_entry (),
        .rob_head        (rob_head_idx),
        .flush_valid     (flush_out.valid),
        .flush_rob_tail  (flush_out.rob_idx),
        .flush_full      (flush_out.full_flush),
        .issue_suppress  ('0),
        .occupancy       (iq1_occ)
    );
    assign iq1_issue_valid[0] = iq1_issue_valid_s[0];
    assign iq1_issue_valid[1] = 1'b0;
    assign iq1_issue_data[0]  = iq1_issue_data_s[0];
    assign iq1_issue_data[1]  = '0;

    issue_queue #(.DEPTH(IQ_INT_DEPTH), .NUM_ENQUEUE(2), .NUM_SELECT(1))
    u_iq2 (
        .clk             (clk),
        .rst_n           (rst_n),
        .enq_valid       (iq2_enq_valid),
        .enq_data        (iq2_enq_data),
        .full            (iq2_full),
        .cdb_valid       (cdb_valid_r),
        .cdb_tag         (cdb_tag_r),
        .spec_wk_valid   (lsu_spec_wakeup_valid[0]),
        .spec_wk_tag     (lsu_spec_wakeup_tag[0]),
        .spec_cancel_valid(lsu_spec_cancel_valid[0]),
        .spec_cancel_tag (lsu_spec_cancel_tag[0]),
        .preg_ready_table(preg_ready_table_comb),
        .issue_candidate_valid(),
        .issue_valid     (iq2_issue_valid_s),
        .issue_data      (iq2_issue_data_s),
        .older_probe_valid(issueq_probe_none_valid),
        .older_probe_rob_idx(issueq_probe_none_rob_idx),
        .has_older_entry (),
        .rob_head        (rob_head_idx),
        .flush_valid     (flush_out.valid),
        .flush_rob_tail  (flush_out.rob_idx),
        .flush_full      (flush_out.full_flush),
        .issue_suppress  ('0),
        .occupancy       (iq2_occ)
    );
    assign iq2_issue_valid[0] = iq2_issue_valid_s[0];
    assign iq2_issue_valid[1] = 1'b0;
    assign iq2_issue_data[0]  = iq2_issue_data_s[0];
    assign iq2_issue_data[1]  = '0;

    // Dual-select: dcache tag/data RAMs are dual-ported.
    issue_queue #(.DEPTH(IQ_MEM_DEPTH), .NUM_ENQUEUE(2), .NUM_SELECT(2))
    u_iq_load (
        .clk             (clk),
        .rst_n           (rst_n),
        .enq_valid       (iq_load_enq_valid),
        .enq_data        (iq_load_enq_data),
        .full            (iq_load_full),
        .cdb_valid       (cdb_valid_r),
        .cdb_tag         (cdb_tag_r),
        .spec_wk_valid   (lsu_spec_wakeup_valid[0]),
        .spec_wk_tag     (lsu_spec_wakeup_tag[0]),
        .spec_cancel_valid(lsu_spec_cancel_valid[0]),
        .spec_cancel_tag (lsu_spec_cancel_tag[0]),
        .preg_ready_table(preg_ready_table_comb),
        .issue_candidate_valid(iq_load_issue_candidate_valid),
        .issue_valid     (iq_load_issue_valid),
        .issue_data      (iq_load_issue_data),
        .older_probe_valid(issueq_probe_none_valid),
        .older_probe_rob_idx(issueq_probe_none_rob_idx),
        .has_older_entry (),
        .rob_head        (rob_head_idx),
        .flush_valid     (flush_out.valid),
        .flush_rob_tail  (flush_out.rob_idx),
        .flush_full      (flush_out.full_flush),
        .issue_suppress  (lsu_load_issue_suppress),
        .occupancy       (/* unused */)
    );

    // Store address IQ (STA): address publish depends only on rs1 readiness.
    issue_queue #(.DEPTH(IQ_MEM_DEPTH), .NUM_ENQUEUE(2), .NUM_SELECT(1))
    u_iq_store (
        .clk             (clk),
        .rst_n           (rst_n),
        .enq_valid       (iq_store_enq_valid),
        .enq_data        (iq_store_enq_data),
        .full            (iq_store_full),
        .cdb_valid       (cdb_valid_r),
        .cdb_tag         (cdb_tag_r),
        .spec_wk_valid   (lsu_spec_wakeup_valid[0]),
        .spec_wk_tag     (lsu_spec_wakeup_tag[0]),
        .spec_cancel_valid(lsu_spec_cancel_valid[0]),
        .spec_cancel_tag (lsu_spec_cancel_tag[0]),
        .preg_ready_table(preg_ready_table_comb),
        .issue_candidate_valid(),
        .issue_valid     (iq_store_issue_valid_s),
        .issue_data      (iq_store_issue_data_s),
        .older_probe_valid(iq_load_issue_candidate_valid),
        .older_probe_rob_idx(store_iq_load_probe_rob_idx),
        .has_older_entry (store_iq_older_than_load),
        .rob_head        (rob_head_idx),
        .flush_valid     (flush_out.valid),
        .flush_rob_tail  (flush_out.rob_idx),
        .flush_full      (flush_out.full_flush),
        .issue_suppress  ('0),
        .occupancy       (/* unused */)
    );
    assign iq_store_issue_valid[0] = iq_store_issue_valid_s[0];
    assign iq_store_issue_valid[1] = 1'b0;
    assign iq_store_issue_data[0]  = iq_store_issue_data_s[0];
    assign iq_store_issue_data[1]  = '0;

    // Store data IQ (STD): full flushes can now discard the queue because the
    // ROB no longer retires stores until both STA and STD have completed.
    issue_queue #(.DEPTH(IQ_MEM_DEPTH), .NUM_ENQUEUE(2), .NUM_SELECT(1))
    u_iq_store_data (
        .clk             (clk),
        .rst_n           (rst_n),
        .enq_valid       (iq_std_enq_valid),
        .enq_data        (iq_std_enq_data),
        .full            (iq_std_full),
        .cdb_valid       (cdb_valid_r),
        .cdb_tag         (cdb_tag_r),
        .spec_wk_valid   (lsu_spec_wakeup_valid[0]),
        .spec_wk_tag     (lsu_spec_wakeup_tag[0]),
        .spec_cancel_valid(lsu_spec_cancel_valid[0]),
        .spec_cancel_tag (lsu_spec_cancel_tag[0]),
        .preg_ready_table(preg_ready_table_comb),
        .issue_candidate_valid(),
        .issue_valid     (iq_std_issue_valid_s),
        .issue_data      (iq_std_issue_data_s),
        .older_probe_valid(issueq_probe_none_valid),
        .older_probe_rob_idx(issueq_probe_none_rob_idx),
        .has_older_entry (),
        .rob_head        (rob_head_idx),
        .flush_valid     (flush_out.valid),
        .flush_rob_tail  (flush_out.rob_idx),
        .flush_full      (flush_out.full_flush),
        .issue_suppress  ('0),
        .occupancy       (/* unused */)
    );

    // =========================================================================
    // Store IQ issue → STA/STD routing
    //
    // STA and STD now issue independently.  SQ state is joined through sq_idx.
    // =========================================================================
    logic       routed_sta_valid;
    iq_entry_t  routed_sta_data;
    logic       routed_std_valid;
    iq_entry_t  routed_std_data;

    always_comb begin
        routed_sta_valid = iq_store_issue_valid[0];
        routed_sta_data  = iq_store_issue_data[0];
        routed_sta_data.fu_type = FU_STA;
        routed_std_valid = iq_std_issue_valid_s[0];
        routed_std_data  = iq_std_issue_data_s[0];
        routed_std_data.fu_type = FU_STD;
        routed_std_data.pdst    = '0;
    end

    // =========================================================================
    // 8. INTEGER PRF (12R6W)
    // =========================================================================
    logic [PHYS_REG_BITS-1:0] prf_raddr [0:11];
    logic [63:0]              prf_rdata [0:11];
    logic [5:0]               prf_wen;
    logic [PHYS_REG_BITS-1:0] prf_waddr [0:5];
    logic [63:0]              prf_wdata [0:5];

    int_prf u_int_prf (
        .clk   (clk),
        .rst_n (rst_n),
        .raddr (prf_raddr),
        .rdata (prf_rdata),
        .wen   (prf_wen),
        .waddr (prf_waddr),
        .wdata (prf_wdata)
    );

    // =========================================================================
    // PRF Read Port Assignment
    //   [0:1]   ALU0/BRU operands (rs1, rs2)
    //   [2:3]   ALU1 operands
    //   [4:5]   ALU2/MUL operands
    //   [6:7]   ALU3/DIV operands
    //   [8:9]   Load AGU0 rs1, Load AGU1 rs1
    //   [10:11] Store AGU rs1, Store Data rs2
    // =========================================================================
    // IQ0 port 0 -> ALU0/BRU
    assign prf_raddr[0] = iq0_issue_data[0].rs1_phys;
    assign prf_raddr[1] = iq0_issue_data[0].rs2_phys;
    // IQ0 port 1 -> ALU1
    assign prf_raddr[2] = iq0_issue_data[1].rs1_phys;
    assign prf_raddr[3] = iq0_issue_data[1].rs2_phys;
    // IQ1 port 0 -> ALU2/MUL
    assign prf_raddr[4] = iq1_issue_data[0].rs1_phys;
    assign prf_raddr[5] = iq1_issue_data[0].rs2_phys;
    // IQ2 port 0 -> ALU3/DIV
    assign prf_raddr[6] = iq2_issue_data[0].rs1_phys;
    assign prf_raddr[7] = iq2_issue_data[0].rs2_phys;
    // Load IQ -> Load AGU rs1 x2
    assign prf_raddr[8]  = iq_load_issue_data[0].rs1_phys;
    assign prf_raddr[9]  = iq_load_issue_data[1].rs1_phys;
    // Store IQ -> STA rs1, STD rs2 (routed by fu_type)
    assign prf_raddr[10] = routed_sta_data.rs1_phys;
    assign prf_raddr[11] = routed_std_data.rs2_phys;

    // =========================================================================
    // 9. BYPASS NETWORK (12 instances, one per operand)
    // =========================================================================
    logic [63:0] bypassed_data [0:11];
    logic [11:0] bypass_hit;

    genvar bi;
    generate
        for (bi = 0; bi < 12; bi++) begin : gen_bypass
            bypass_network u_bypass (
                .bypass_valid (bypass_valid),
                .bypass_tag   (bypass_tag),
                .bypass_data  (bypass_data),
                .need_tag     (prf_raddr[bi]),
                .prf_data     (prf_rdata[bi]),
                .result_data  (bypassed_data[bi]),
                .hit          (bypass_hit[bi])
            );
        end
    endgenerate

    // =========================================================================
    // 10. ALUs x4
    // =========================================================================
    // ALU0 (IQ0 port 0)
    logic [63:0] alu0_result;
    logic [63:0] alu0_op_a, alu0_op_b;
    assign alu0_op_a = (iq0_issue_data[0].use_imm && (iq0_issue_data[0].alu_op == ALU_PASS2))
                       ? iq0_issue_data[0].pc : bypassed_data[0];
    assign alu0_op_b = iq0_issue_data[0].use_imm ? iq0_issue_data[0].imm : bypassed_data[1];

    alu u_alu0 (
        .operand_a (alu0_op_a),
        .operand_b (alu0_op_b),
        .op        (iq0_issue_data[0].alu_op),
        .is_w_op   (iq0_issue_data[0].is_w_op),
        .result    (alu0_result)
    );

    // ALU1 (IQ0 port 1)
    logic [63:0] alu1_result;
    logic [63:0] alu1_op_a, alu1_op_b;
    assign alu1_op_a = (iq0_issue_data[1].use_imm && (iq0_issue_data[1].alu_op == ALU_PASS2))
                       ? iq0_issue_data[1].pc : bypassed_data[2];
    assign alu1_op_b = iq0_issue_data[1].use_imm ? iq0_issue_data[1].imm : bypassed_data[3];

    alu u_alu1 (
        .operand_a (alu1_op_a),
        .operand_b (alu1_op_b),
        .op        (iq0_issue_data[1].alu_op),
        .is_w_op   (iq0_issue_data[1].is_w_op),
        .result    (alu1_result)
    );

    // ALU2 (IQ1 port 0)
    logic [63:0] alu2_result;
    logic [63:0] alu2_op_a, alu2_op_b;
    assign alu2_op_a = (iq1_issue_data[0].use_imm && (iq1_issue_data[0].alu_op == ALU_PASS2))
                       ? iq1_issue_data[0].pc : bypassed_data[4];
    assign alu2_op_b = iq1_issue_data[0].use_imm ? iq1_issue_data[0].imm : bypassed_data[5];

    alu u_alu2 (
        .operand_a (alu2_op_a),
        .operand_b (alu2_op_b),
        .op        (iq1_issue_data[0].alu_op),
        .is_w_op   (iq1_issue_data[0].is_w_op),
        .result    (alu2_result)
    );

    // ALU3 (IQ2 port 0)
    logic [63:0] alu3_result;
    logic [63:0] alu3_op_a, alu3_op_b;
    assign alu3_op_a = (iq2_issue_data[0].use_imm && (iq2_issue_data[0].alu_op == ALU_PASS2))
                       ? iq2_issue_data[0].pc : bypassed_data[6];
    assign alu3_op_b = iq2_issue_data[0].use_imm ? iq2_issue_data[0].imm : bypassed_data[7];

    alu u_alu3 (
        .operand_a (alu3_op_a),
        .operand_b (alu3_op_b),
        .op        (iq2_issue_data[0].alu_op),
        .is_w_op   (iq2_issue_data[0].is_w_op),
        .result    (alu3_result)
    );

    // =========================================================================
    // 11. BRU (shared with ALU0 on IQ0 port 0)
    // =========================================================================
    logic [63:0] bru_result;
    logic        bru_taken;
    // bru_target declared earlier (forward decl for fetch_unit port)
    logic [63:0] bru_taken_target;
    logic        bru_mispredict;

    logic        bru_issue;
    assign bru_issue = iq0_issue_valid[0] && (iq0_issue_data[0].fu_type == FU_BRU);

    bru u_bru (
        .operand_a   (bypassed_data[0]),
        .operand_b   (bypassed_data[1]),
        .pc          (iq0_issue_data[0].pc),
        .imm         (iq0_issue_data[0].imm),
        .op          (iq0_issue_data[0].br_op),
        .is_fused    (iq0_issue_data[0].is_fused),
        .fusion_type (iq0_issue_data[0].fusion_type),
        .bp_taken    (iq0_issue_data[0].bp_taken),
        .bp_target   (iq0_issue_data[0].bp_target),
        .is_rvc      (iq0_issue_data[0].is_rvc),
        .result      (bru_result),
        .taken       (bru_taken),
        .target      (bru_target),
        .taken_target(bru_taken_target),
        .mispredict  (bru_mispredict)
    );

    // BRU1: second branch unit on IQ0 port 1
    logic [63:0] bru1_result;
    logic        bru1_taken;
    logic [63:0] bru1_target;
    logic [63:0] bru1_taken_target;
    logic        bru1_mispredict;

    logic        bru1_issue;
    assign bru1_issue = iq0_issue_valid[1] && (iq0_issue_data[1].fu_type == FU_BRU);

    bru u_bru1 (
        .operand_a   (bypassed_data[2]),
        .operand_b   (bypassed_data[3]),
        .pc          (iq0_issue_data[1].pc),
        .imm         (iq0_issue_data[1].imm),
        .op          (iq0_issue_data[1].br_op),
        .is_fused    (iq0_issue_data[1].is_fused),
        .fusion_type (iq0_issue_data[1].fusion_type),
        .bp_taken    (iq0_issue_data[1].bp_taken),
        .bp_target   (iq0_issue_data[1].bp_target),
        .is_rvc      (iq0_issue_data[1].is_rvc),
        .result      (bru1_result),
        .taken       (bru1_taken),
        .target      (bru1_target),
        .taken_target(bru1_taken_target),
        .mispredict  (bru1_mispredict)
    );

    // =========================================================================
    // BRU early fetch redirect (fetch-only, no pipeline flush)
    // =========================================================================
    // Only BRU0 (port 0, oldest branch) triggers early redirect.
    // BRU1 (port 1, younger branch) uses the normal commit flush path.
    // This prevents early-redirect storms from wrong-path branches on port 1.
    // bru_early_redirect declared earlier (forward decl for fetch_unit port)
    assign bru_early_redirect = bru_issue && bru_mispredict;
    assign ghr_restore_valid_fe =
        bru_early_redirect ||
        (flush_out.valid && flush_out.ghr_restore_valid);
    assign ghr_restore_val_fe =
        bru_early_redirect ? iq0_issue_data[0].bp_ghr
                           : flush_out.ghr_restore_val;
    assign ras_restore_valid_fe = bru_early_redirect || flush_out.valid;
    assign ras_restore_tos_fe =
        flush_out.valid ? flush_out.ras_tos
                        : ras_tos_after_redirect(
                              iq0_issue_data[0].bp_ras_tos,
                              iq0_issue_data[0].bp_ras_op
                          );
    assign ras_restore_top_valid_fe =
        flush_out.valid && flush_out.ras_top_restore_valid;
    assign ras_restore_top_addr_fe = flush_out.ras_top_restore_addr;

`ifdef SIMULATION
    logic trace_bru_en;
    integer trace_bru_cycle;
    always_comb begin
        trace_bru_en = 1'b0;
        if ($test$plusargs("TRACE_BRU")) trace_bru_en = 1'b1;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            trace_bru_cycle <= 0;
        end else if (trace_bru_en) begin
            trace_bru_cycle <= trace_bru_cycle + 1;
            if (bru_issue &&
                ((trace_bru_cycle < 1600) ||
                 ((iq0_issue_data[0].pc >= 64'h0000_0000_8000_2000) &&
                  (iq0_issue_data[0].pc <  64'h0000_0000_8000_2440)))) begin
                $display("[BRU0] cyc=%0d pc=%016h op=%0d rvc=%b rs1=%016h rs2=%016h imm=%016h bp_taken=%b bp_tgt=%016h taken=%b tgt=%016h taken_tgt=%016h link=%016h misp=%b pdst=%0d rob=%0d",
                    trace_bru_cycle,
                    iq0_issue_data[0].pc,
                    iq0_issue_data[0].br_op,
                    iq0_issue_data[0].is_rvc,
                    bypassed_data[0],
                    bypassed_data[1],
                    iq0_issue_data[0].imm,
                    iq0_issue_data[0].bp_taken,
                    iq0_issue_data[0].bp_target,
                    bru_taken,
                    bru_target,
                    bru_taken_target,
                    bru_result,
                    bru_mispredict,
                    iq0_issue_data[0].pdst,
                    iq0_issue_data[0].rob_idx);
            end
            if (bru1_issue &&
                ((trace_bru_cycle < 1600) ||
                 ((iq0_issue_data[1].pc >= 64'h0000_0000_8000_2000) &&
                  (iq0_issue_data[1].pc <  64'h0000_0000_8000_2440)))) begin
                $display("[BRU1] cyc=%0d pc=%016h op=%0d rvc=%b rs1=%016h rs2=%016h imm=%016h bp_taken=%b bp_tgt=%016h taken=%b tgt=%016h taken_tgt=%016h link=%016h misp=%b pdst=%0d rob=%0d",
                    trace_bru_cycle,
                    iq0_issue_data[1].pc,
                    iq0_issue_data[1].br_op,
                    iq0_issue_data[1].is_rvc,
                    bypassed_data[2],
                    bypassed_data[3],
                    iq0_issue_data[1].imm,
                    iq0_issue_data[1].bp_taken,
                    iq0_issue_data[1].bp_target,
                    bru1_taken,
                    bru1_target,
                    bru1_taken_target,
                    bru1_result,
                    bru1_mispredict,
                    iq0_issue_data[1].pdst,
                    iq0_issue_data[1].rob_idx);
            end
        end
    end
`endif

    // Merge: commit flush takes priority.  BRU redirect only applies to
    // the fetch unit's redirect_valid / redirect_pc.
    assign flush_out = commit_flush;

    // The fetch unit sees redirect from EITHER commit_flush OR bru_redirect.
    // This is wired in the fetch_unit instantiation below.

    // =========================================================================
    // 12. MULTIPLIER (shared with ALU2 on IQ1 port 0)
    // =========================================================================
    logic        mul_valid_out;
    logic [63:0] mul_result;
    logic        mul_issue;
    assign mul_issue = iq1_issue_valid[0] && (iq1_issue_data[0].fu_type == FU_MUL);

    // Track ROB idx and pdst through multiplier pipeline stages
    logic [ROB_IDX_BITS-1:0]  mul_rob_idx_s1, mul_rob_idx_s2, mul_rob_idx_s3;
    logic [PHYS_REG_BITS-1:0] mul_pdst_s1, mul_pdst_s2, mul_pdst_s3;

    always_ff @(posedge clk) begin
        if (!rst_n || flush_out.valid) begin
            mul_rob_idx_s1 <= '0;
            mul_pdst_s1    <= '0;
            mul_rob_idx_s2 <= '0;
            mul_pdst_s2    <= '0;
            mul_rob_idx_s3 <= '0;
            mul_pdst_s3    <= '0;
        end else begin
            mul_rob_idx_s1 <= iq1_issue_data[0].rob_idx;
            mul_pdst_s1    <= iq1_issue_data[0].pdst;
            mul_rob_idx_s2 <= mul_rob_idx_s1;
            mul_pdst_s2    <= mul_pdst_s1;
            mul_rob_idx_s3 <= mul_rob_idx_s2;
            mul_pdst_s3    <= mul_pdst_s2;
        end
    end

    multiplier u_multiplier (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (mul_issue),
        .operand_a (bypassed_data[4]),
        .operand_b (bypassed_data[5]),
        .op        (iq1_issue_data[0].mul_op),
        .is_w_op   (iq1_issue_data[0].is_w_op),
        .flush     (flush_out.valid),
        .valid_out (mul_valid_out),
        .result    (mul_result)
    );

    // =========================================================================
    // 13. DIVIDER (shared with ALU3 on IQ2 port 0)
    // =========================================================================
    logic        div_busy;
    logic        div_valid_out;
    logic [63:0] div_result;
    logic        div_issue;
    assign div_issue = iq2_issue_valid[0] && (iq2_issue_data[0].fu_type == FU_DIV);

    // Track ROB idx and pdst for divider (capture at issue, hold until done)
    logic [ROB_IDX_BITS-1:0]  div_rob_idx_r;
    logic [PHYS_REG_BITS-1:0] div_pdst_r;

    always_ff @(posedge clk) begin
        if (!rst_n || flush_out.valid) begin
            div_rob_idx_r <= '0;
            div_pdst_r    <= '0;
        end else if (div_issue && !div_busy) begin
            div_rob_idx_r <= iq2_issue_data[0].rob_idx;
            div_pdst_r    <= iq2_issue_data[0].pdst;
        end
    end

    divider u_divider (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (div_issue),
        .operand_a (bypassed_data[6]),
        .operand_b (bypassed_data[7]),
        .op        (iq2_issue_data[0].div_op),
        .is_w_op   (iq2_issue_data[0].is_w_op),
        .flush     (flush_out.valid),
        .busy      (div_busy),
        .valid_out (div_valid_out),
        .result    (div_result)
    );

    // =========================================================================
    // 14. CDB (Common Data Bus) Assembly
    //
    //   CDB[0]: ALU0/BRU result
    //   CDB[1]: ALU1 result
    //   CDB[2]: ALU2/MUL result (ALU2 wins if both, MUL on delayed cycle)
    //   CDB[3]: ALU3/DIV result (ALU3 wins if both, DIV on delayed cycle)
    //   CDB[4]: Load 0 result (from LSU)
    //   CDB[5]: Load 1 result (from LSU)
    // =========================================================================
    // LSU writeback signals
    logic [1:0]               lsu_load_wb_valid;
    logic [ROB_IDX_BITS-1:0]  lsu_load_wb_rob_idx [0:1];
    logic [PHYS_REG_BITS-1:0] lsu_load_wb_pdst    [0:1];
    logic [63:0]              lsu_load_wb_data    [0:1];
    logic [1:0]               lsu_load_wb_has_exception;
    logic [3:0]               lsu_load_wb_exc_code [0:1];
    logic                     lsu_sta_wb_valid;
    logic [ROB_IDX_BITS-1:0]  lsu_sta_wb_rob_idx;
    logic                     lsu_std_wb_valid;
    logic [ROB_IDX_BITS-1:0]  lsu_std_wb_rob_idx;

    // Build the LSU's load_rs1 unpacked-array port using explicit indexing
    // (a packed concat would be silently re-ordered by Verilator).
    logic [63:0] lsu_load_rs1_arr [0:1];
    assign lsu_load_rs1_arr[0] = bypassed_data[8];
    assign lsu_load_rs1_arr[1] = bypassed_data[9];

    // ALU0 is used when not BRU
    logic alu0_issue;
    assign alu0_issue = iq0_issue_valid[0] && (iq0_issue_data[0].fu_type == FU_ALU);

    // ALU2 is used when not MUL
    logic alu2_issue;
    assign alu2_issue = iq1_issue_valid[0] && (iq1_issue_data[0].fu_type == FU_ALU);

    // ALU3 is used when not DIV
    logic alu3_issue;
    assign alu3_issue = iq2_issue_valid[0] && (iq2_issue_data[0].fu_type == FU_ALU ||
                                                iq2_issue_data[0].fu_type == FU_CSR);

    // CDB[0]: ALU0/BRU
    always_comb begin
        cdb_valid[0]            = iq0_issue_valid[0];
        cdb_tag[0]              = iq0_issue_data[0].pdst;
        cdb_rob_idx[0]          = iq0_issue_data[0].rob_idx;
        cdb_has_exception[0]    = 1'b0;
        cdb_exc_code[0]         = 4'd0;
        cdb_is_branch[0]        = bru_issue;
        cdb_branch_taken[0]     = bru_issue ? bru_taken : 1'b0;
        cdb_branch_target[0]    = bru_issue ? bru_target : 64'd0;
        cdb_branch_taken_target[0] =
            bru_issue ? bru_taken_target : 64'd0;
        cdb_branch_mispredict[0] = bru_issue ? bru_mispredict : 1'b0;
        cdb_csr_we[0]           = 1'b0;
        cdb_csr_addr[0]         = 12'd0;
        cdb_csr_wdata[0]        = 64'd0;
        cdb_csr_op[0]           = 2'd0;
        if (bru_issue) begin
            cdb_data[0] = bru_result;
        end else begin
            cdb_data[0] = alu0_result;
        end
    end

    // CDB[1]: ALU1 / BRU1
    always_comb begin
        cdb_valid[1]            = iq0_issue_valid[1];
        cdb_tag[1]              = iq0_issue_data[1].pdst;
        cdb_rob_idx[1]          = iq0_issue_data[1].rob_idx;
        cdb_has_exception[1]    = 1'b0;
        cdb_exc_code[1]         = 4'd0;
        cdb_is_branch[1]        = bru1_issue;
        cdb_branch_taken[1]     = bru1_issue ? bru1_taken : 1'b0;
        cdb_branch_target[1]    = bru1_issue ? bru1_target : 64'd0;
        cdb_branch_taken_target[1] =
            bru1_issue ? bru1_taken_target : 64'd0;
        cdb_branch_mispredict[1] = bru1_issue ? bru1_mispredict : 1'b0;
        cdb_csr_we[1]           = 1'b0;
        cdb_csr_addr[1]         = 12'd0;
        cdb_csr_wdata[1]        = 64'd0;
        cdb_csr_op[1]           = 2'd0;
        if (bru1_issue)
            cdb_data[1] = bru1_result;
        else
            cdb_data[1] = alu1_result;
    end

    // MUL output hold register: when MUL completes but ALU2 takes the CDB,
    // latch the MUL result and replay next cycle. Without this, the MUL
    // result is silently dropped and the ROB entry never becomes ready.
    logic        mul_hold_valid_r;
    logic [ROB_IDX_BITS-1:0]  mul_hold_rob_idx_r;
    logic [PHYS_REG_BITS-1:0] mul_hold_pdst_r;
    logic [63:0] mul_hold_data_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush_out.valid) begin
            mul_hold_valid_r <= 1'b0;
        end else if (mul_valid_out && alu2_issue) begin
            // MUL ready but ALU2 wins - hold until drain
            mul_hold_valid_r   <= 1'b1;
            mul_hold_rob_idx_r <= mul_rob_idx_s3;
            mul_hold_pdst_r    <= mul_pdst_s3;
            mul_hold_data_r    <= mul_result;
        end else if (mul_hold_valid_r && !alu2_issue) begin
            // Drain: held MUL result goes to CDB this cycle
            mul_hold_valid_r <= 1'b0;
        end
        // else: keep holding while ALU2 continues to occupy the port
    end

    // Effective MUL output: fresh MUL result OR held result from last cycle
    logic        mul_eff_valid;
    logic [ROB_IDX_BITS-1:0]  mul_eff_rob_idx;
    logic [PHYS_REG_BITS-1:0] mul_eff_pdst;
    logic [63:0] mul_eff_data;

    assign mul_eff_valid   = mul_valid_out || mul_hold_valid_r;
    assign mul_eff_rob_idx = mul_valid_out ? mul_rob_idx_s3 : mul_hold_rob_idx_r;
    assign mul_eff_pdst    = mul_valid_out ? mul_pdst_s3    : mul_hold_pdst_r;
    assign mul_eff_data    = mul_valid_out ? mul_result     : mul_hold_data_r;

    // CDB[2]: ALU2 (same cycle) or MUL (3-cycle latency, with hold)
    always_comb begin
        if (alu2_issue) begin
            cdb_valid[2]         = 1'b1;
            cdb_tag[2]           = iq1_issue_data[0].pdst;
            cdb_rob_idx[2]       = iq1_issue_data[0].rob_idx;
            cdb_data[2]          = alu2_result;
        end else begin
            cdb_valid[2]         = mul_eff_valid;
            cdb_tag[2]           = mul_eff_pdst;
            cdb_rob_idx[2]       = mul_eff_rob_idx;
            cdb_data[2]          = mul_eff_data;
        end
        cdb_has_exception[2]     = 1'b0;
        cdb_exc_code[2]          = 4'd0;
        cdb_is_branch[2]        = 1'b0;
        cdb_branch_taken[2]     = 1'b0;
        cdb_branch_target[2]    = 64'd0;
        cdb_branch_taken_target[2] = 64'd0;
        cdb_branch_mispredict[2] = 1'b0;
        cdb_csr_we[2]           = 1'b0;
        cdb_csr_addr[2]         = 12'd0;
        cdb_csr_wdata[2]        = 64'd0;
        cdb_csr_op[2]           = 2'd0;
    end

    // DIV output hold register (same pattern as MUL hold)
    logic        div_hold_valid_r;
    logic [ROB_IDX_BITS-1:0]  div_hold_rob_idx_r;
    logic [PHYS_REG_BITS-1:0] div_hold_pdst_r;
    logic [63:0] div_hold_data_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush_out.valid) begin
            div_hold_valid_r <= 1'b0;
        end else if (div_valid_out && alu3_issue) begin
            div_hold_valid_r   <= 1'b1;
            div_hold_rob_idx_r <= div_rob_idx_r;
            div_hold_pdst_r    <= div_pdst_r;
            div_hold_data_r    <= div_result;
        end else if (div_hold_valid_r && !alu3_issue) begin
            div_hold_valid_r <= 1'b0;
        end
    end

    logic        div_eff_valid;
    logic [ROB_IDX_BITS-1:0]  div_eff_rob_idx;
    logic [PHYS_REG_BITS-1:0] div_eff_pdst;
    logic [63:0] div_eff_data;

    assign div_eff_valid   = div_valid_out || div_hold_valid_r;
    assign div_eff_rob_idx = div_valid_out ? div_rob_idx_r : div_hold_rob_idx_r;
    assign div_eff_pdst    = div_valid_out ? div_pdst_r    : div_hold_pdst_r;
    assign div_eff_data    = div_valid_out ? div_result    : div_hold_data_r;

    // CDB[3]: ALU3 (same cycle) or DIV (multi-cycle, with hold)
    always_comb begin
        if (alu3_issue) begin
            cdb_valid[3]         = 1'b1;
            cdb_tag[3]           = iq2_issue_data[0].pdst;
            cdb_rob_idx[3]       = iq2_issue_data[0].rob_idx;
            cdb_data[3]          = alu3_result;
            // CSR write enable: only set for CSRRW (always writes) or
            // CSRRS/CSRRC with rs1 != x0 (rs1=x0 is a read-only alias).
            // The csr_op encodes: 0=RW, 1=RS, 2=RC, 3=NONE.
            // For RS/RC with rs1=x0, the write is a no-op per RISC-V spec
            // section 9.1: "shall not write to the CSR at all".
            cdb_csr_we[3]        = (iq2_issue_data[0].fu_type == FU_CSR &&
                                    iq2_issue_data[0].csr_op != 2'd3 &&
                                    (iq2_issue_data[0].csr_op == 2'd0 ||
                                     bypassed_data[6] != 64'd0)) ? 1'b1 : 1'b0;
            cdb_csr_addr[3]      = iq2_issue_data[0].csr_addr;
            cdb_csr_wdata[3]     = bypassed_data[6];  // rs1 value (the write mask)
            cdb_csr_op[3]        = iq2_issue_data[0].csr_op;
        end else begin
            cdb_valid[3]         = div_eff_valid;
            cdb_tag[3]           = div_eff_pdst;
            cdb_rob_idx[3]       = div_eff_rob_idx;
            cdb_data[3]          = div_eff_data;
            cdb_csr_we[3]        = 1'b0;
            cdb_csr_addr[3]      = 12'd0;
            cdb_csr_wdata[3]     = 64'd0;
            cdb_csr_op[3]        = 2'd0;
        end
        cdb_has_exception[3]     = 1'b0;
        cdb_exc_code[3]          = 4'd0;
        cdb_is_branch[3]        = 1'b0;
        cdb_branch_taken[3]     = 1'b0;
        cdb_branch_target[3]    = 64'd0;
        cdb_branch_taken_target[3] = 64'd0;
        cdb_branch_mispredict[3] = 1'b0;
    end

    // CDB[4]: Load 0
    always_comb begin
        cdb_valid[4]            = lsu_load_wb_valid[0];
        cdb_tag[4]              = lsu_load_wb_pdst[0];
        cdb_rob_idx[4]          = lsu_load_wb_rob_idx[0];
        cdb_data[4]             = lsu_load_wb_data[0];
        cdb_has_exception[4]    = lsu_load_wb_has_exception[0];
        cdb_exc_code[4]         = lsu_load_wb_exc_code[0];
        cdb_is_branch[4]       = 1'b0;
        cdb_branch_taken[4]    = 1'b0;
        cdb_branch_target[4]   = 64'd0;
        cdb_branch_taken_target[4] = 64'd0;
        cdb_branch_mispredict[4] = 1'b0;
        cdb_csr_we[4]          = 1'b0;
        cdb_csr_addr[4]        = 12'd0;
        cdb_csr_wdata[4]       = 64'd0;
        cdb_csr_op[4]          = 2'd0;
    end

    // CDB[5]: Load 1
    always_comb begin
        cdb_valid[5]            = lsu_load_wb_valid[1];
        cdb_tag[5]              = lsu_load_wb_pdst[1];
        cdb_rob_idx[5]          = lsu_load_wb_rob_idx[1];
        cdb_data[5]             = lsu_load_wb_data[1];
        cdb_has_exception[5]    = lsu_load_wb_has_exception[1];
        cdb_exc_code[5]         = lsu_load_wb_exc_code[1];
        cdb_is_branch[5]       = 1'b0;
        cdb_branch_taken[5]    = 1'b0;
        cdb_branch_target[5]   = 64'd0;
        cdb_branch_taken_target[5] = 64'd0;
        cdb_branch_mispredict[5] = 1'b0;
        cdb_csr_we[5]          = 1'b0;
        cdb_csr_addr[5]        = 12'd0;
        cdb_csr_wdata[5]       = 64'd0;
        cdb_csr_op[5]          = 2'd0;
    end

    // =========================================================================
    // CDB Pipeline Register — break the combinational loop
    //   IQ issue -> PRF read -> ALU -> CDB -> IQ wakeup -> IQ re-select
    // Registered version feeds: IQ wakeup, ROB writeback, preg_ready_table.
    // Combinational version feeds: bypass network, PRF writes.
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush_out.valid) begin
            cdb_valid_r            <= '0;
            cdb_has_exception_r    <= '0;
            cdb_is_branch_r        <= '0;
            cdb_branch_taken_r     <= '0;
            cdb_branch_mispredict_r <= '0;
            cdb_csr_we_r           <= '0;
            for (int i = 0; i < CDB_WIDTH; i++) begin
                cdb_tag_r[i]            <= '0;
                cdb_data_r[i]           <= '0;
                cdb_rob_idx_r[i]        <= '0;
                cdb_exc_code_r[i]       <= '0;
                cdb_branch_target_r[i]  <= '0;
                cdb_branch_taken_target_r[i] <= '0;
                cdb_csr_addr_r[i]       <= '0;
                cdb_csr_wdata_r[i]      <= '0;
                cdb_csr_op_r[i]         <= '0;
            end
        end else begin
            cdb_valid_r            <= cdb_valid;
            cdb_has_exception_r    <= cdb_has_exception;
            cdb_is_branch_r        <= cdb_is_branch;
            cdb_branch_taken_r     <= cdb_branch_taken;
            cdb_branch_mispredict_r <= cdb_branch_mispredict;
            cdb_csr_we_r           <= cdb_csr_we;
            for (int i = 0; i < CDB_WIDTH; i++) begin
                cdb_tag_r[i]            <= cdb_tag[i];
                cdb_data_r[i]           <= cdb_data[i];
                cdb_rob_idx_r[i]        <= cdb_rob_idx[i];
                cdb_exc_code_r[i]       <= cdb_exc_code[i];
                cdb_branch_target_r[i]  <= cdb_branch_target[i];
                cdb_branch_taken_target_r[i] <= cdb_branch_taken_target[i];
                cdb_csr_addr_r[i]       <= cdb_csr_addr[i];
                cdb_csr_wdata_r[i]      <= cdb_csr_wdata[i];
                cdb_csr_op_r[i]         <= cdb_csr_op[i];
            end
        end
    end

    // =========================================================================
    // Store sideband writeback register (1-cycle delay, matches CDB register stage)
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lsu_sta_wb_valid_r   <= 1'b0;
            lsu_sta_wb_rob_idx_r <= '0;
            lsu_std_wb_valid_r   <= 1'b0;
            lsu_std_wb_rob_idx_r <= '0;
        end else if (flush_out.valid) begin
            lsu_sta_wb_valid_r   <= 1'b0;
            lsu_std_wb_valid_r   <= 1'b0;
        end else begin
            lsu_sta_wb_valid_r   <= lsu_sta_wb_valid;
            lsu_sta_wb_rob_idx_r <= lsu_sta_wb_rob_idx;
            lsu_std_wb_valid_r   <= lsu_std_wb_valid;
            lsu_std_wb_rob_idx_r <= lsu_std_wb_rob_idx;
        end
    end

    // =========================================================================
    // PRF Write Port Assignment
    //   Write[0]: ALU0/BRU
    //   Write[1]: ALU1
    //   Write[2]: ALU2/MUL
    //   Write[3]: ALU3/DIV
    //   Write[4]: Load 0
    //   Write[5]: Load 1
    // =========================================================================
    assign prf_wen[0]   = cdb_valid[0] && (cdb_tag[0] != '0);
    assign prf_waddr[0] = cdb_tag[0];
    assign prf_wdata[0] = cdb_data[0];

    assign prf_wen[1]   = cdb_valid[1] && (cdb_tag[1] != '0);
    assign prf_waddr[1] = cdb_tag[1];
    assign prf_wdata[1] = cdb_data[1];

    assign prf_wen[2]   = cdb_valid[2] && (cdb_tag[2] != '0);
    assign prf_waddr[2] = cdb_tag[2];
    assign prf_wdata[2] = cdb_data[2];

    assign prf_wen[3]   = cdb_valid[3] && (cdb_tag[3] != '0);
    assign prf_waddr[3] = cdb_tag[3];
    assign prf_wdata[3] = cdb_data[3];

    assign prf_wen[4]   = cdb_valid[4] && (cdb_tag[4] != '0);
    assign prf_waddr[4] = cdb_tag[4];
    assign prf_wdata[4] = cdb_data[4];

    assign prf_wen[5]   = cdb_valid[5] && (cdb_tag[5] != '0);
    assign prf_waddr[5] = cdb_tag[5];
    assign prf_wdata[5] = cdb_data[5];

    // =========================================================================
    // Bypass source wiring
    //   [0]: ALU0/BRU  [1]: ALU1  [2]: ALU2/MUL  [3]: ALU3/DIV
    //   [4]: Load 0    [5]: Load 1
    // =========================================================================
    // For ALU sources [0..3]: use REGISTERED CDB.  ALU producers wake their
    // consumers via the registered cdb_r path (1 cycle after compute), and
    // by then the PRF write has already latched, so bypass-from-cdb_r is
    // semantically equivalent to PRF read but cuts the read mux.  No
    // combinational loop because cdb_r is registered.
    //
    // For LOAD sources [4..5]: use COMBINATIONAL CDB.  A load AGU at T+0
    // sets spec_wakeup at T+1 (load _r stage), the IQ latches src1_ready at
    // T+2 (next clock edge), and the consumer issues at T+2 — exactly the
    // cycle the load result is on the combinational CDB (load_wb fires at
    // the _rr stage = T+2).  The PRF write does not latch until T+3, so
    // the consumer's PRF read at T+2 still returns the OLD value; the
    // combinational bypass is the only path that delivers the load value
    // to the consumer at T+2.  No combinational loop because loads do not
    // chain into a same-cycle producer (the load result drives consumers,
    // and consumer ALUs only feed cdb_r the next cycle).
    //
    // Suppress bypass for p0 (hardwired zero register) — CDB may carry
    // non-zero data for instructions with pdst=p0 (e.g., JAL x0).
    // Bypass sources [0..3] (ALU): REGISTERED CDB.
    // Bypass sources [4..5] (Load): COMBINATIONAL CDB for 2-cycle latency.
    assign bypass_valid = {cdb_valid[5]   && (cdb_tag[5]   != '0),
                           cdb_valid[4]   && (cdb_tag[4]   != '0),
                           cdb_valid_r[3] && (cdb_tag_r[3] != '0),
                           cdb_valid_r[2] && (cdb_tag_r[2] != '0),
                           cdb_valid_r[1] && (cdb_tag_r[1] != '0),
                           cdb_valid_r[0] && (cdb_tag_r[0] != '0)};
    assign bypass_tag[0] = cdb_tag_r[0];
    assign bypass_tag[1] = cdb_tag_r[1];
    assign bypass_tag[2] = cdb_tag_r[2];
    assign bypass_tag[3] = cdb_tag_r[3];
    assign bypass_tag[4] = cdb_tag[4];
    assign bypass_tag[5] = cdb_tag[5];
    assign bypass_data[0] = cdb_data_r[0];
    assign bypass_data[1] = cdb_data_r[1];
    assign bypass_data[2] = cdb_data_r[2];
    assign bypass_data[3] = cdb_data_r[3];
    assign bypass_data[4] = cdb_data[4];
    assign bypass_data[5] = cdb_data[5];

    // =========================================================================
    // PRF Ready Table
    //
    // Set bit when CDB writes a register.
    // Clear bit when rename allocates a new destination.
    // p0 is always ready (hardwired zero).
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            preg_ready_table <= {INT_PRF_DEPTH{1'b1}};
        end else if (flush_out.valid && flush_out.full_flush) begin
            // Full flush: reset all pregs to ready.
            // After flush the RAT maps arch regs 0-31 to phys 0-31 (committed
            // state) and the free list marks 32-255 as free. No in-flight
            // writers exist, so every physical register is ready.
            preg_ready_table <= {INT_PRF_DEPTH{1'b1}};
        end else begin
            // Clear on new rename allocation.
            //
            // Skip move-eliminated and zero-eliminated instructions: those
            // share their pdst with the source (move-elim: pdst = rs1_phys;
            // zero-elim: pdst = 0). Clearing preg_ready_table for them would
            // invalidate a register whose DATA IS ALREADY VALID (the source's
            // data never changes under move-elim; zero is a constant). With
            // no new CDB writeback scheduled for these pdsts, the ready bit
            // would never get re-asserted, and any consumer depending on
            // that pdst would wait forever. (This was the Dhrystone
            // store-deadlock root cause: stores in the hot loop have rs2
            // mapped to pdst=16/etc, whose prior writer was move-eliminated;
            // the clear here invalidated the ready bit and the store's
            // src2_ready never fired.)
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                if (3'(i) < ren_count_w && ren_insn[i].base.rd_valid &&
                    ren_insn[i].pdst != '0 &&
                    !ren_move_eliminated[i] && !ren_zero_eliminated[i]) begin
                    preg_ready_table[ren_insn[i].pdst] <= 1'b0;
                end
            end
            // Set on CDB writeback — use COMBINATIONAL CDB so the table
            // is current when rename reads it next cycle. This path
            // (ready_table -> rename -> IQ) is one-way, not part of
            // the IQ -> ALU -> CDB -> IQ wakeup loop.
            for (int i = 0; i < CDB_WIDTH; i++) begin
                if (cdb_valid[i] && cdb_tag[i] != '0) begin
                    preg_ready_table[cdb_tag[i]] <= 1'b1;
                end
            end
            // p0 always ready
            preg_ready_table[0] <= 1'b1;
        end
    end

    // Combinational ready table: includes THIS cycle's rename clears.
    // Same move/zero-elim exclusion as the registered update below — a
    // move-eliminated pdst aliases the source, whose data is already valid.
    always_comb begin
        preg_ready_table_comb = preg_ready_table;
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            if (3'(i) < ren_count_w && ren_insn[i].base.rd_valid &&
                ren_insn[i].pdst != '0 &&
                !ren_move_eliminated[i] && !ren_zero_eliminated[i]) begin
                preg_ready_table_comb[ren_insn[i].pdst] = 1'b0;
            end
        end
    end

    // =========================================================================
    // 15. LSU (Load/Store Unit)
    // =========================================================================
    // D-cache interface signals
    logic [1:0]  dc_load_req_valid;
    logic [63:0] dc_load_req_addr  [0:1];
    logic [1:0]  dc_load_req_size  [0:1];
    logic [1:0]  dc_load_req_is_unsigned;
    logic [1:0]  dc_load_resp_valid;
    logic [63:0] dc_load_resp_data [0:1];
    logic [1:0]  dc_load_resp_hit;
    logic        dc_store_req_valid;
    logic [63:0] dc_store_req_addr;
    logic [63:0] dc_store_req_data;
    logic [7:0]  dc_store_req_byte_mask;
    logic        dc_store_ack;

    // LSU ordering violation
    // (lsu_ordering_violation / lsu_violation_rob_idx / lsu_port0_suppress
    //  hoisted to near the ROB instantiation above for declaration-before-use.)

    // =========================================================================
    // PARTIAL REPLAY BUS (partial_replay_spec.md — Phase 2 signal plumbing)
    //
    // Separate from the full_flush path used for branch mispredicts and
    // architectural exceptions.  A 1-cycle pulse fires from the LSU on a
    // memory-ordering violation; the handlers (IQ / ROB / PRF-ready) perform
    // SELECTIVE invalidation — fetch/decode/rename stay intact.
    //
    // Phase 2 step 1:  signals declared and registered here; handlers are
    // added by Phase 3 edits in issue_queue.sv / rob.sv / the PRF-ready-table
    // block in this file.  Until then the bus is a no-op: the existing
    // commit.found_replay path still turns the ordering violation into a
    // full_flush, which remains the safety fallback.
    // =========================================================================
    // (replay_valid / replay_rob_idx_from hoisted near the ROB instantiation
    //  above for declaration-before-use — see the LSU-forwarded signals
    //  section there.)

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            replay_valid         <= 1'b0;
            replay_rob_idx_from  <= '0;
        end else begin
            // 1-cycle pulse registered from the LSU's combinational
            // ordering_violation signal.  Gated off during branch/exception
            // flush to avoid double-processing when full_flush has already
            // squashed the pipeline.
            replay_valid <= lsu_ordering_violation &&
                            !(flush_out.valid && flush_out.full_flush);
            replay_rob_idx_from <= lsu_violation_rob_idx;
        end
    end

    // =========================================================================
    // pdst_producer_rob[] — per-pdst metadata (Phase 2 step 2)
    //
    // Records, for every physical register, the rob_idx of the in-flight
    // instruction that allocated it at rename.  Phase 3's replay handlers
    // read this to decide which consumers' src_ready bits must be cleared
    // ("is producer in replay range?").  Written on every rename; flushed
    // to 0 on full_flush (mirrors rename_buf).
    // =========================================================================
    logic [ROB_IDX_BITS-1:0] pdst_producer_rob [0:INT_PRF_DEPTH-1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || (flush_out.valid && flush_out.full_flush)) begin
            for (int p = 0; p < INT_PRF_DEPTH; p++)
                pdst_producer_rob[p] <= '0;
        end else begin
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                if ((3'(i) < ren_count_w) &&
                    ren_insn[i].base.rd_valid &&
                    (ren_insn[i].pdst != '0)) begin
                    pdst_producer_rob[ren_insn[i].pdst] <= ren_insn[i].rob_idx;
                end
            end
        end
    end

`ifdef SIMULATION
    // =========================================================================
    // SVA — Partial-replay mechanism (observational + safety invariants)
    //
    // Guarded by +ifdef SIMULATION so synthesis never sees these.  They
    // verify the Phase-2 plumbing today and will flag Phase-3 handler bugs
    // instantly (fail at the exact cycle + signal) once handlers are added.
    //
    // Note: xsim 2024.1 does not support SV `cover property`.  Instead of
    // cover statements we use lightweight counter flops that tally each
    // interesting event; a final $display at simulation end reports them.
    // Note: xsim action blocks do not infer the property's clocking for
    // $past, so the assertion properties carry their own auxiliary
    // signals (captured via pipelined flops) which are safe to read from
    // $error without needing $past.
    // =========================================================================

    // Pipelined 1-cycle-delayed copies of violation signals, used in A1/A2/A4.
    logic                    sva_prev_violation;
    logic [ROB_IDX_BITS-1:0] sva_prev_viol_rob;
    logic                    sva_prev_flush_full;
    logic                    sva_prev_ren0_rdvalid;
    logic [PHYS_REG_BITS-1:0] sva_prev_ren0_pdst;
    logic [ROB_IDX_BITS-1:0] sva_prev_ren0_robidx;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sva_prev_violation    <= 1'b0;
            sva_prev_viol_rob     <= '0;
            sva_prev_flush_full   <= 1'b0;
            sva_prev_ren0_rdvalid <= 1'b0;
            sva_prev_ren0_pdst    <= '0;
            sva_prev_ren0_robidx  <= '0;
        end else begin
            sva_prev_violation    <= lsu_ordering_violation;
            sva_prev_viol_rob     <= lsu_violation_rob_idx;
            sva_prev_flush_full   <= flush_out.valid && flush_out.full_flush;
            sva_prev_ren0_rdvalid <= (ren_count_w != 0) &&
                                      ren_insn[0].base.rd_valid &&
                                      (ren_insn[0].pdst != '0);
            sva_prev_ren0_pdst    <= ren_insn[0].pdst;
            sva_prev_ren0_robidx  <= ren_insn[0].rob_idx;
        end
    end

    // Cycle counter for $error location messages.
    integer sva_cycle;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sva_cycle <= 0;
        else        sva_cycle <= sva_cycle + 1;
    end

    // A1 — PLUMBING: replay_valid must be a registered copy of the gated
    //                lsu_ordering_violation signal from the previous cycle.
    //                If the gate (!full_flush) is open in cycle N, then
    //                replay_valid must be high in cycle N+1.
    property p_replay_valid_registered_from_violation;
        @(posedge clk) disable iff (!rst_n)
        (lsu_ordering_violation && !(flush_out.valid && flush_out.full_flush))
            |=> replay_valid;
    endproperty
    a_replay_valid_registered_from_violation:
        assert property (p_replay_valid_registered_from_violation)
        else $error("[SVA A1] cyc=%0d replay_valid did NOT follow ordering_violation (prev_viol_rob=%0d)",
                    sva_cycle, sva_prev_viol_rob);

    // A2 — PLUMBING: replay_rob_idx_from must latch the violation rob_idx.
    property p_replay_rob_idx_follows_violation;
        @(posedge clk) disable iff (!rst_n)
        (lsu_ordering_violation && !(flush_out.valid && flush_out.full_flush))
            |=> (replay_rob_idx_from == sva_prev_viol_rob);
    endproperty
    a_replay_rob_idx_follows_violation:
        assert property (p_replay_rob_idx_follows_violation)
        else $error("[SVA A2] cyc=%0d replay_rob_idx_from mismatch got=%0d expected=%0d",
                    sva_cycle, replay_rob_idx_from, sva_prev_viol_rob);

    // A4 — METADATA: whenever rename produces an advancing rd_valid slot
    //                with a non-zero pdst, pdst_producer_rob[pdst] must hold
    //                that rob_idx on the following cycle.
    property p_pdst_producer_rob_tracks_rename;
        @(posedge clk) disable iff (!rst_n)
        ((ren_count_w != 0) &&
         ren_insn[0].base.rd_valid &&
         (ren_insn[0].pdst != '0) &&
         !(flush_out.valid && flush_out.full_flush))
            |=> (pdst_producer_rob[sva_prev_ren0_pdst] == sva_prev_ren0_robidx);
    endproperty
    a_pdst_producer_rob_tracks_rename_slot0:
        assert property (p_pdst_producer_rob_tracks_rename)
        else $error("[SVA A4] cyc=%0d pdst_producer_rob[%0d] mismatch got=%0d expected=%0d",
                    sva_cycle, sva_prev_ren0_pdst,
                    pdst_producer_rob[sva_prev_ren0_pdst],
                    sva_prev_ren0_robidx);

    // A5 — CORRECTNESS: replay_rob_idx_from should always point at a
    //                   currently-valid ROB entry (otherwise the replay
    //                   range is meaningless).  Fires only on replay_valid.
    property p_replay_target_is_valid_rob_entry;
        @(posedge clk) disable iff (!rst_n)
        replay_valid |-> u_rob.valid_r[replay_rob_idx_from];
    endproperty
    a_replay_target_is_valid_rob_entry:
        assert property (p_replay_target_is_valid_rob_entry)
        else $error("[SVA A5] cyc=%0d replay target rob=%0d is not a valid ROB entry",
                    sva_cycle, replay_rob_idx_from);

    // A6 — PHASE-3 CORRECTNESS: on replay_valid, NO instruction whose
    //                            rob_idx is in the replay range may commit
    //                            in that cycle.  If any slot_can_commit
    //                            hits the replay range while replay_valid
    //                            pulses, the partial-replay handler has
    //                            let a wrong-data load through.
    // Helper function: is commit_slot s's rob_idx in the replay range?
    // Range: [replay_rob_idx_from, u_rob.tail_r) in wrap-safe modular order.
    function automatic logic rob_in_replay_range
        (input logic [ROB_IDX_BITS-1:0] idx,
         input logic [ROB_IDX_BITS-1:0] from,
         input logic [ROB_IDX_BITS-1:0] tail);
        logic [ROB_IDX_BITS-1:0] rd, td;
        rd = idx  - from;
        td = tail - from;
        return (rd < td);
    endfunction

    // Per-slot commit-in-replay-range probe.
    logic [PIPE_WIDTH-1:0] sva_commit_in_replay;
    always_comb begin
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            sva_commit_in_replay[i] =
                replay_valid
                && commit_out[i].valid
                && rob_in_replay_range(
                     {{(ROB_IDX_BITS-3){1'b0}}, 3'(i)} + u_rob.head_r,
                     replay_rob_idx_from, u_rob.tail_r);
        end
    end

    property p_no_commit_in_replay_range;
        @(posedge clk) disable iff (!rst_n)
        replay_valid |-> (sva_commit_in_replay == '0);
    endproperty
    a_no_commit_in_replay_range:
        assert property (p_no_commit_in_replay_range)
        else $error("[SVA A6] cyc=%0d commit tried to retire rob in replay range: mask=%b replay_from=%0d head=%0d tail=%0d",
                    sva_cycle, sva_commit_in_replay, replay_rob_idx_from,
                    u_rob.head_r, u_rob.tail_r);

    // A7 — PHASE-3 PROGRESS: after a replay_valid pulse, the ROB head
    //                         must either advance (commits happen) or a
    //                         full_flush fires, within REPLAY_DEADLOCK_CYC
    //                         cycles.  If neither happens, the replay
    //                         mechanism deadlocked the pipeline.
    localparam int REPLAY_DEADLOCK_CYC = 256;
    integer sva_replay_stuck_cnt;
    logic [ROB_IDX_BITS-1:0] sva_head_at_replay;
    logic sva_replay_armed;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sva_replay_stuck_cnt <= 0;
            sva_head_at_replay   <= '0;
            sva_replay_armed     <= 1'b0;
        end else if (replay_valid && !sva_replay_armed) begin
            // Arm the deadlock watchdog on the first replay.
            sva_replay_stuck_cnt <= 0;
            sva_head_at_replay   <= u_rob.head_r;
            sva_replay_armed     <= 1'b1;
        end else if (sva_replay_armed) begin
            if (flush_out.valid && flush_out.full_flush) begin
                // full_flush counts as "progress"; re-arm on next replay.
                sva_replay_armed <= 1'b0;
            end else if (u_rob.head_r != sva_head_at_replay) begin
                // Head advanced; good, disarm.
                sva_replay_armed <= 1'b0;
            end else begin
                sva_replay_stuck_cnt <= sva_replay_stuck_cnt + 1;
            end
        end
    end
    a_replay_progress_bound:
        assert property (
            @(posedge clk) disable iff (!rst_n)
            (sva_replay_armed |-> (sva_replay_stuck_cnt < REPLAY_DEADLOCK_CYC))
        ) else $error("[SVA A7] cyc=%0d replay stuck %0d cycles without commit or flush (head stayed at %0d)",
                      sva_cycle, sva_replay_stuck_cnt, sva_head_at_replay);

    // -- Event counters (substitute for unsupported cover property) --
    integer sva_cnt_ord_violation;
    integer sva_cnt_replay_valid;
    integer sva_cnt_violation_gated_by_flush;
    integer sva_cnt_adjacent_violations;
    logic   sva_violation_prev_r;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sva_cnt_ord_violation           <= 0;
            sva_cnt_replay_valid            <= 0;
            sva_cnt_violation_gated_by_flush <= 0;
            sva_cnt_adjacent_violations     <= 0;
            sva_violation_prev_r            <= 1'b0;
        end else begin
            if (lsu_ordering_violation) begin
                sva_cnt_ord_violation <= sva_cnt_ord_violation + 1;
                if (flush_out.valid && flush_out.full_flush)
                    sva_cnt_violation_gated_by_flush <= sva_cnt_violation_gated_by_flush + 1;
                if (sva_violation_prev_r)
                    sva_cnt_adjacent_violations <= sva_cnt_adjacent_violations + 1;
            end
            if (replay_valid)
                sva_cnt_replay_valid <= sva_cnt_replay_valid + 1;
            sva_violation_prev_r <= lsu_ordering_violation;
        end
    end

    // -----------------------------------------------------------------------
    // A10..A16 — classification counters for CoreMark's ordering_violations.
    // Monitoring-only (no DUT effect).  Distinguishes legitimate RAW hazards
    // from artifacts (stale-executed, post-flush, burst retries) and
    // measures how often the ROB watchdog converts a replay to a full_flush.
    // -----------------------------------------------------------------------
    integer sva_cnt_viol_any_flush;
    integer sva_cnt_viol_post_flush;
    integer sva_cnt_viol_burst;
    integer sva_cnt_viol_same_rob;
    integer sva_cnt_viol_then_mispred;
    integer sva_cnt_watchdog_fire;
    integer sva_cnt_watchdog_post_replay;

    logic [4:0] sva_post_flush_cnt;
    logic [4:0] sva_post_viol_cnt;
    logic [7:0] sva_post_replay_cnt;
    logic [ROB_IDX_BITS-1:0] sva_last_viol_rob_idx_r;
    logic                    sva_last_viol_valid_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sva_cnt_viol_any_flush       <= 0;
            sva_cnt_viol_post_flush      <= 0;
            sva_cnt_viol_burst           <= 0;
            sva_cnt_viol_same_rob        <= 0;
            sva_cnt_viol_then_mispred    <= 0;
            sva_cnt_watchdog_fire        <= 0;
            sva_cnt_watchdog_post_replay <= 0;
            sva_post_flush_cnt           <= 5'd31;
            sva_post_viol_cnt            <= 5'd31;
            sva_post_replay_cnt          <= 8'd255;
            sva_last_viol_rob_idx_r      <= '0;
            sva_last_viol_valid_r        <= 1'b0;
        end else begin
            if (flush_out.valid)
                sva_post_flush_cnt <= 5'd0;
            else if (sva_post_flush_cnt != 5'd31)
                sva_post_flush_cnt <= sva_post_flush_cnt + 5'd1;

            if (lsu_ordering_violation)
                sva_post_viol_cnt <= 5'd0;
            else if (sva_post_viol_cnt != 5'd31)
                sva_post_viol_cnt <= sva_post_viol_cnt + 5'd1;

            if (replay_valid)
                sva_post_replay_cnt <= 8'd0;
            else if (sva_post_replay_cnt != 8'd255)
                sva_post_replay_cnt <= sva_post_replay_cnt + 8'd1;

            if (lsu_ordering_violation) begin
                if (flush_out.valid)
                    sva_cnt_viol_any_flush <= sva_cnt_viol_any_flush + 1;
                if (sva_post_flush_cnt < 5'd5)
                    sva_cnt_viol_post_flush <= sva_cnt_viol_post_flush + 1;
                if (sva_post_viol_cnt < 5'd5)
                    sva_cnt_viol_burst <= sva_cnt_viol_burst + 1;
                if (sva_last_viol_valid_r
                    && (lsu_violation_rob_idx == sva_last_viol_rob_idx_r)
                    && (sva_post_viol_cnt < 5'd20))
                    sva_cnt_viol_same_rob <= sva_cnt_viol_same_rob + 1;
                sva_last_viol_rob_idx_r <= lsu_violation_rob_idx;
                sva_last_viol_valid_r   <= 1'b1;
            end

            if (flush_out.valid && !flush_out.full_flush && sva_post_viol_cnt < 5'd20)
                sva_cnt_viol_then_mispred <= sva_cnt_viol_then_mispred + 1;

            if (u_rob.rob_head_watchdog == 12'd62) begin
                sva_cnt_watchdog_fire <= sva_cnt_watchdog_fire + 1;
                if (sva_post_replay_cnt < 8'd100)
                    sva_cnt_watchdog_post_replay <= sva_cnt_watchdog_post_replay + 1;
            end
        end
    end

    a_cover_viol_then_flush:
        cover property (@(posedge clk) disable iff (!rst_n)
                        lsu_ordering_violation |=> flush_out.valid);
    a_cover_replay_then_flush:
        cover property (@(posedge clk) disable iff (!rst_n)
                        replay_valid |=> flush_out.valid);

    final begin
        $display("[SVA SUMMARY]");
        $display("  ordering_violations fired:        %0d", sva_cnt_ord_violation);
        $display("  replay_valid fired:               %0d", sva_cnt_replay_valid);
        $display("  violations gated by full_flush:   %0d", sva_cnt_violation_gated_by_flush);
        $display("  adjacent-cycle violations:        %0d", sva_cnt_adjacent_violations);
        $display("  [A10] violations w/ flush in flight:   %0d", sva_cnt_viol_any_flush);
        $display("  [A11] violations within 5 cyc of flush:%0d", sva_cnt_viol_post_flush);
        $display("  [A12] violations in burst (<5 cyc):    %0d", sva_cnt_viol_burst);
        $display("  [A13] same rob_idx repeated (<20 cyc): %0d", sva_cnt_viol_same_rob);
        $display("  [A14] viol followed by mispred(<20cyc):%0d", sva_cnt_viol_then_mispred);
        $display("  [A15] watchdog fires (force-exc 15):   %0d", sva_cnt_watchdog_fire);
        $display("  [A16] watchdog fires post-replay(<100):%0d", sva_cnt_watchdog_post_replay);
    end
    // =========================================================================
    // End of partial-replay SVA
    // =========================================================================
`endif

    // LQ/SQ alloc counts from rename
    logic [2:0] lq_alloc_count;
    logic [2:0] sq_alloc_count;

    always_comb begin
        lq_alloc_count = 3'd0;
        sq_alloc_count = 3'd0;
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            if (3'(i) < ren_count_w) begin
                if (ren_insn[i].base.is_load) lq_alloc_count = lq_alloc_count + 3'd1;
                if (ren_insn[i].base.is_store) sq_alloc_count = sq_alloc_count + 3'd1;
            end
        end
    end

    lsu u_lsu (
        .clk                    (clk),
        .rst_n                  (rst_n),
        // Issue inputs
        .load_issue_candidate_valid(iq_load_issue_candidate_valid),
        .load_issue_valid       (iq_load_issue_valid),
        .load_issue_data        (iq_load_issue_data),
        .sta_issue_valid        (routed_sta_valid),
        .sta_issue_data         (routed_sta_data),
        .std_issue_valid        (routed_std_valid),
        .std_issue_data         (routed_std_data),
        // PRF read data
        // NOTE: load_rs1 is an unpacked array [0:1].  The packed concat
        // {bypassed_data[9], bypassed_data[8]} maps the first element of
        // the brace list to index [0], so we MUST list bypassed_data[8]
        // (= load port 0's rs1 in the bypass network) first.  The previous
        // ordering crossed port 0 and port 1 sources, causing every port-0
        // load to read its base register from the speculative-port-1 load —
        // the root cause of the CoreMark divergence bug.
        .load_rs1               (lsu_load_rs1_arr),
        .sta_rs1                (bypassed_data[10]),
        .std_rs2                (bypassed_data[11]),
        // Writeback
        .load_wb_valid          (lsu_load_wb_valid),
        .load_wb_rob_idx        (lsu_load_wb_rob_idx),
        .load_wb_pdst           (lsu_load_wb_pdst),
        .load_wb_data           (lsu_load_wb_data),
        .load_wb_has_exception  (lsu_load_wb_has_exception),
        .load_wb_exc_code       (lsu_load_wb_exc_code),
        .sta_wb_valid           (lsu_sta_wb_valid),
        .sta_wb_rob_idx         (lsu_sta_wb_rob_idx),
        .std_wb_valid           (lsu_std_wb_valid),
        .std_wb_rob_idx         (lsu_std_wb_rob_idx),
        // Commit counts
        .store_commit_count     (store_commit_count),
        .load_commit_count      (load_commit_count),
        // Speculative wakeup
        .spec_wakeup_valid      (lsu_spec_wakeup_valid),
        .spec_wakeup_tag        (lsu_spec_wakeup_tag),
        .spec_cancel_valid      (lsu_spec_cancel_valid),
        .spec_cancel_tag        (lsu_spec_cancel_tag),
        // LQ/SQ allocation
        .lq_alloc_count         (lq_alloc_count),
        .sq_alloc_count         (sq_alloc_count),
        .lq_alloc_idx           (lq_alloc_idx),
        .sq_alloc_idx           (sq_alloc_idx),
        .lq_full                (lq_full),
        .sq_full                (sq_full),
        .rob_head               (rob_head_idx),
        // Ordering violation
        .ordering_violation     (lsu_ordering_violation),
        .load_issue_suppress    (lsu_load_issue_suppress_raw),
        .violation_rob_idx      (lsu_violation_rob_idx),
        // D-cache interface
        .dcache_load_req_valid  (dc_load_req_valid),
        .dcache_load_req_addr   (dc_load_req_addr),
        .dcache_load_req_size   (dc_load_req_size),
        .dcache_load_req_is_unsigned(dc_load_req_is_unsigned),
        .dcache_load_resp_valid (dc_load_resp_valid),
        .dcache_load_resp_data  (dc_load_resp_data),
        .dcache_load_resp_hit   (dc_load_resp_hit),
        .dcache_store_req_valid (dc_store_req_valid),
        .dcache_store_req_addr  (dc_store_req_addr),
        .dcache_store_req_data  (dc_store_req_data),
        .dcache_store_req_byte_mask(dc_store_req_byte_mask),
        .dcache_store_ack       (dc_store_ack),
        // D-cache fill snoop (for load miss late response)
        .dcache_fill_valid      (dc_fill_snoop_valid),
        .dcache_fill_addr       (dc_fill_snoop_addr),
        .dcache_fill_data       (dc_fill_snoop_data),
        // Flush
        .flush_in               (flush_out)
    );

    // =========================================================================
    // 16. D-CACHE
    // =========================================================================
    logic        dc_l2_req_valid;
    logic [63:0] dc_l2_req_addr;
    logic        dc_l2_req_we;
    logic [511:0] dc_l2_req_wdata;
    logic        dc_l2_req_ready;
    logic        dc_l2_resp_valid;
    logic [63:0] dc_l2_resp_addr;
    logic [511:0] dc_l2_resp_data;
    logic        dc_invalidate_busy;

    // D-cache fill snoop (to LSU for missed-load late response) —
    // (dc_fill_snoop_* signals hoisted to before the LSU instantiation
    //  above for declaration-before-use under DSim strict semantics.)

    dcache u_dcache (
        .clk                (clk),
        .rst_n              (rst_n),
        .load_req_valid     (dc_load_req_valid),
        .load_req_addr      (dc_load_req_addr),
        .load_req_size      (dc_load_req_size),
        .load_req_is_unsigned(dc_load_req_is_unsigned),
        .load_resp_valid    (dc_load_resp_valid),
        .load_resp_data     (dc_load_resp_data),
        .load_resp_hit      (dc_load_resp_hit),
        .store_req_valid    (dc_store_req_valid),
        .store_req_addr     (dc_store_req_addr),
        .store_req_data     (dc_store_req_data),
        .store_req_byte_mask(dc_store_req_byte_mask),
        .store_ack          (dc_store_ack),
        .l2_req_valid       (dc_l2_req_valid),
        .l2_req_addr        (dc_l2_req_addr),
        .l2_req_we          (dc_l2_req_we),
        .l2_req_wdata       (dc_l2_req_wdata),
        .l2_req_ready       (dc_l2_req_ready),
        .l2_resp_valid      (dc_l2_resp_valid),
        .l2_resp_addr       (dc_l2_resp_addr),
        .l2_resp_data       (dc_l2_resp_data),
        .fill_snoop_valid   (dc_fill_snoop_valid),
        .fill_snoop_addr    (dc_fill_snoop_addr),
        .fill_snoop_data    (dc_fill_snoop_data),
        .invalidate_all     (1'b0),
        .invalidate_busy    (dc_invalidate_busy)
    );

    // =========================================================================
    // 17. L2 CACHE
    // =========================================================================
    logic l2_icache_req_ready;
    logic l2_icache_resp_valid;
    logic [63:0] l2_icache_resp_addr;
    logic [511:0] l2_icache_resp_data;
    logic l2_invalidate_busy;

    // (pf_l2_* signals are forward-declared near the fetch_unit section above.)

    // The L2 hit pipeline does not invalidate stages after delivery, so a
    // response for an earlier icache fetch reappears L2_HIT_LATENCY cycles
    // later as a stale "fill_resp_valid" pulse with the OLD line data.
    // Forward the L2's response address to the icache so it can filter
    // those replays by comparing against its own miss_addr_q.
    assign icache_fill_resp_addr = l2_icache_resp_addr;

    l2_cache u_l2_cache (
        .clk                (clk),
        .rst_n              (rst_n),
        // D-cache port
        .dcache_req_valid   (dc_l2_req_valid),
        .dcache_req_addr    (dc_l2_req_addr),
        .dcache_req_we      (dc_l2_req_we),
        .dcache_req_wdata   (dc_l2_req_wdata),
        .dcache_req_ready   (dc_l2_req_ready),
        .dcache_resp_valid  (dc_l2_resp_valid),
        .dcache_resp_addr   (dc_l2_resp_addr),
        .dcache_resp_data   (dc_l2_resp_data),
        // I-cache port
        .icache_req_valid   (icache_fill_req_valid),
        .icache_req_addr    (icache_fill_req_addr),
        .icache_req_ready   (l2_icache_req_ready),
        .icache_resp_valid  (icache_fill_resp_valid),
        .icache_resp_addr   (l2_icache_resp_addr),
        .icache_resp_data   (icache_fill_resp_data),
        // Prefetch port (from NLPB via fetch_unit)
        .prefetch_req_valid (pf_l2_req_valid),
        .prefetch_req_addr  (pf_l2_req_addr),
        .prefetch_req_ready (pf_l2_req_ready),
        .prefetch_resp_valid(pf_l2_resp_valid),
        .prefetch_resp_addr (pf_l2_resp_addr),
        .prefetch_resp_data (pf_l2_resp_data),
        // Main memory interface
        .mem_req_valid      (mem_req_valid),
        .mem_req_addr       (mem_req_addr),
        .mem_req_we         (mem_req_we),
        .mem_req_wdata      (mem_req_wdata),
        .mem_req_ready      (mem_req_ready),
        .mem_resp_valid     (mem_resp_valid),
        .mem_resp_data      (mem_resp_data),
        // Invalidate
        .invalidate_all     (fence_i_signal),
        .invalidate_busy    (l2_invalidate_busy)
    );

    // =========================================================================
    // 18. COMMIT UNIT
    // =========================================================================
    logic        csr_commit_valid;
    logic [11:0] csr_commit_addr;
    logic [63:0] csr_commit_wdata;
    logic [1:0]  csr_commit_op;
    logic [PIPE_WIDTH-1:0] release_checkpoint;
    logic [CHECKPOINT_BITS-1:0] release_checkpoint_id [0:PIPE_WIDTH-1];

    // CSR file outputs
    logic [63:0] csr_mtvec, csr_stvec, csr_mepc, csr_sepc;
    logic [1:0]  csr_priv_mode;
    logic        csr_irq_pending;
    logic [63:0] csr_irq_cause;

    commit u_commit (
        .clk                    (clk),
        .rst_n                  (rst_n),
        // ROB head
        .head_idx               (rob_head_idx),
        .head_valid             (rob_head_valid),
        .head_ready             (rob_head_ready),
        .head_pc                (rob_head_pc),
        .head_has_exception     (rob_head_has_exception),
        .head_exc_code          (rob_head_exc_code),
        .head_is_branch         (rob_head_is_branch),
        .head_bpu_type          (rob_head_bpu_type),
        .head_is_store          (rob_head_is_store),
        .head_is_load           (rob_head_is_load),
        .head_is_csr            (rob_head_is_csr),
        .head_is_fence          (rob_head_is_fence),
        .head_is_fence_i        (rob_head_is_fence_i),
        .head_is_mret           (rob_head_is_mret),
        .head_is_sret           (rob_head_is_sret),
        .head_is_sfence_vma     (rob_head_is_sfence_vma),
        .head_is_ecall          (rob_head_is_ecall),
        .head_is_wfi            (rob_head_is_wfi),
        .head_branch_taken      (rob_head_branch_taken),
        .head_branch_target     (rob_head_branch_target),
        .head_branch_mispredict (rob_head_branch_mispredict),
        .head_csr_addr          (rob_head_csr_addr),
        .head_csr_wdata         (rob_head_csr_wdata),
        .head_csr_we            (rob_head_csr_we),
        .head_csr_op            (rob_head_csr_op),
        // Rename buffer data
        .head_pdst              (rb_head_pdst),
        .head_old_pdst          (rb_head_old_pdst),
        .head_rd_arch           (rb_head_rd_arch),
        .head_rd_valid          (rb_head_rd_valid),
        .head_uses_checkpoint   (rb_head_uses_checkpoint),
        .head_checkpoint_id     (rb_head_checkpoint_id),
        .head_bp_ras_tos        (rb_head_bp_ras_tos),
        .head_bp_ras_top        (rb_head_bp_ras_top),
        .head_bp_ras_op         (rb_head_bp_ras_op),
        .head_bp_ghr            (rb_head_bp_ghr),
        // Outputs
        .commit_count           (commit_count),
        .commit_out             (commit_out),
        .store_commit_count     (store_commit_count),
        .load_commit_count      (load_commit_count),
        .flush_out              (commit_flush),
        .csr_commit_valid       (csr_commit_valid),
        .csr_commit_addr        (csr_commit_addr),
        .csr_commit_wdata       (csr_commit_wdata),
        .csr_commit_op          (csr_commit_op),
        .release_checkpoint     (release_checkpoint),
        .release_checkpoint_id  (release_checkpoint_id),
        // Trap vectors
        .mtvec                  (csr_mtvec),
        .stvec                  (csr_stvec),
        .mepc                   (csr_mepc),
        .sepc                   (csr_sepc),
        .priv_mode              (csr_priv_mode),
        .irq_pending            (csr_irq_pending),
        .irq_cause              (csr_irq_cause),
        .insn_retired_count     (insn_retired_count)
    );

    // Checkpoint release -> rename
    assign commit_release_cp = release_checkpoint;
    always_comb begin
        for (int i = 0; i < PIPE_WIDTH; i++)
            commit_cp_id[i] = release_checkpoint_id[i];
    end

    // =========================================================================
    // BPU update from commit (branch resolution)
    // =========================================================================
    always_comb begin
        logic found_update;
        logic is_control;

        bpu_update_valid     = 1'b0;
        bpu_update_pc        = 64'd0;
        bpu_tage_update_valid = 1'b0;
        bpu_tage_update_pc   = 64'd0;
        bpu_update_taken     = 1'b0;
        bpu_update_mispredict = 1'b0;
        bpu_update_target    = 64'd0;
        bpu_update_type      = 3'd0;
        bpu_update_ghr       = '0;
        found_update         = 1'b0;

        // A block-based frontend must train the oldest qualifying control in
        // the commit batch: later control transfers in the same fetch block
        // otherwise starve the earliest branch/jump that actually owns the
        // next-block decision.
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            is_control = rob_head_is_branch[i] || (rob_head_bpu_type[i] != 3'd0);
            if (!found_update &&
                commit_out[i].valid &&
                is_control &&
                rob_head_branch_mispredict[i]) begin
                bpu_update_valid     = 1'b1;
                bpu_update_pc        = rob_head_pc[i];
                bpu_tage_update_valid = rb_head_bp_owner[i] &&
                                        rob_head_is_branch[i];
                bpu_tage_update_pc   = rb_head_bp_lookup_pc[i];
                bpu_update_taken     = rob_head_branch_taken[i];
                bpu_update_mispredict = rob_head_branch_mispredict[i];
                bpu_update_target    = rob_head_is_branch[i]
                                       ? rob_head_branch_taken_target[i]
                                       : rob_head_branch_target[i];
                bpu_update_type      = rob_head_bpu_type[i];
                bpu_update_ghr       = rb_head_bp_ghr[i];
                found_update         = 1'b1;
            end
        end

        // If nothing mispredicted this cycle, still train the oldest
        // committed control transfer so BTB state stays aligned with the
        // earliest CFI in each fetch block.
        if (!bpu_update_valid) begin
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                is_control = rob_head_is_branch[i] || (rob_head_bpu_type[i] != 3'd0);
                if (!found_update &&
                    commit_out[i].valid &&
                    is_control) begin
                    bpu_update_valid      = 1'b1;
                    bpu_update_pc         = rob_head_pc[i];
                    bpu_tage_update_valid = rb_head_bp_owner[i] &&
                                            rob_head_is_branch[i];
                    bpu_tage_update_pc    = rb_head_bp_lookup_pc[i];
                    bpu_update_taken      = rob_head_branch_taken[i];
                    bpu_update_mispredict = rob_head_branch_mispredict[i];
                    bpu_update_target     = rob_head_is_branch[i]
                                            ? rob_head_branch_taken_target[i]
                                            : rob_head_branch_target[i];
                    bpu_update_type       = rob_head_bpu_type[i];
                    bpu_update_ghr        = rb_head_bp_ghr[i];
                    found_update          = 1'b1;
                end
            end
        end
    end

    // FENCE.I: generate when a FENCE.I commits
    assign fence_i_signal = (commit_count > 3'd0) && rob_head_is_fence_i[0] &&
                            commit_out[0].valid;

    // =========================================================================
    // 19. CSR FILE
    // =========================================================================
    logic [63:0] csr_read_data;
    logic [63:0] csr_mcycle_val, csr_minstret_val;
    logic [63:0] csr_satp;

    // Trap signals (from commit flush)
    logic        trap_valid;
    logic [63:0] trap_cause;
    logic [63:0] trap_pc;
    logic [63:0] trap_val;
    logic        trap_is_interrupt;

    // Generate trap signals from commit flush
    always_comb begin
        trap_valid        = 1'b0;
        trap_cause        = 64'd0;
        trap_pc           = 64'd0;
        trap_val          = 64'd0;
        trap_is_interrupt = 1'b0;

        if (flush_out.valid && flush_out.full_flush) begin
            // Check if this is an exception commit
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                if (commit_out[i].valid && rob_head_has_exception[i] && !trap_valid) begin
                    trap_valid  = 1'b1;
                    trap_cause  = {60'd0, rob_head_exc_code[i]};
                    trap_pc     = rob_head_pc[i];
                    trap_val    = 64'd0;
                end
            end
            // Check for interrupt
            if (csr_irq_pending && !trap_valid) begin
                trap_valid        = 1'b1;
                trap_cause        = csr_irq_cause;
                trap_pc           = rob_head_pc[0];
                trap_val          = 64'd0;
                trap_is_interrupt = 1'b1;
            end
        end
    end

    // MRET/SRET signals
    logic mret_commit, sret_commit;
    assign mret_commit = (commit_count > 3'd0) && rob_head_is_mret[0] && commit_out[0].valid;
    assign sret_commit = (commit_count > 3'd0) && rob_head_is_sret[0] && commit_out[0].valid;

    csr_file u_csr_file (
        .clk                (clk),
        .rst_n              (rst_n),
        .read_addr          (12'd0),
        .read_data          (csr_read_data),
        .write_valid        (csr_commit_valid),
        .write_addr         (csr_commit_addr),
        .write_data         (csr_commit_wdata),
        .write_op           (csr_commit_op),
        .trap_valid         (trap_valid),
        .trap_cause         (trap_cause),
        .trap_pc            (trap_pc),
        .trap_val           (trap_val),
        .trap_is_interrupt  (trap_is_interrupt),
        .mret_valid         (mret_commit),
        .sret_valid         (sret_commit),
        .mtvec              (csr_mtvec),
        .stvec              (csr_stvec),
        .mepc               (csr_mepc),
        .sepc               (csr_sepc),
        .priv_mode          (csr_priv_mode),
        .irq_pending        (csr_irq_pending),
        .irq_cause          (csr_irq_cause),
        .insn_retired_count (insn_retired_count),
        .mcycle_val         (csr_mcycle_val),
        .minstret_val       (csr_minstret_val),
        .time_val           (time_val),
        .mtip               (mtip),
        .msip               (msip),
        .meip               (meip),
        .stip               (stip),
        .ssip               (ssip),
        .seip               (seip),
        .satp               (csr_satp)
    );

    // =========================================================================
    // STA writeback to ROB (store address completion)
    // =========================================================================
    // The STA writeback marks the store as "ready" in the ROB.
    // This is handled via the CDB or a side channel. For now we use a
    // dedicated ROB writeback for STA that only sets ready, no data.
    // This is already handled by the CDB if we route STA through it.
    // For simplicity, STA address completion is handled via the existing
    // LSU-to-CDB interface (lsu_sta_wb_valid goes through the ordering
    // violation path, not through CDB for register writeback).

    // =========================================================================
    // Tohost detection: snoop CSB drain to D-cache for tohost writes
    // =========================================================================
    // Compare only lower 32 bits: on RV64, LUI sign-extends bit 31,
    // so software generates 0xFFFFFFFF_80001000 while TOHOST_ADDR is
    // 0x00000000_80001000. Both refer to the same physical address.
    assign tohost_wr_valid = dc_store_req_valid &&
                             (dc_store_req_addr[31:3] == tohost_addr[31:3]);
    assign tohost_wr_data  = dc_store_req_data;

    // =========================================================================
    // Performance counter outputs (mcycle / minstret) for IPC measurement
    // =========================================================================
    assign perf_mcycle   = csr_mcycle_val;
    assign perf_minstret = csr_minstret_val;

    // =========================================================================
    // Debug tracing (simulation only)
    // =========================================================================
    // (debug traces removed for clean test runs)

endmodule

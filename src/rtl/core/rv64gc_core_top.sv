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
    import fpu_pkg::*;
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

    // Uncached data MMIO interface
    output logic        data_mmio_req_valid,
    output logic        data_mmio_req_we,
    output logic [63:0] data_mmio_req_addr,
    output logic [63:0] data_mmio_req_wdata,
    output logic [7:0]  data_mmio_req_wmask,
    output logic [1:0]  data_mmio_req_size,
    input  logic        data_mmio_req_ready,
    input  logic        data_mmio_resp_valid,
    input  logic [63:0] data_mmio_resp_data,

    // External interrupts
    input  logic        mtip, msip, meip,
    input  logic        stip, ssip, seip,

    // Timer
    input  logic [63:0] time_val,

    // Optional DSE controls
    input  logic        backend_admission_throttle_enable,
    input  logic        iq_ready_enq_bypass_enable,
    input  logic        iq_ready_enq_bypass_alu_only,

    // Performance counters (for IPC measurement / benchmarking)
    output logic [63:0] perf_mcycle,
    output logic [63:0] perf_minstret
);

    // =========================================================================
    // Flush signals
    // =========================================================================
    // commit_flush: from commit module (exceptions, ordering violations)
    // bru_flush:    from BRU0 at execute time (oldest-branch mispredict)
    // flush_out:    merged signal broadcast everywhere
    flush_t commit_flush;
    flush_t bru_flush;
    flush_t flush_out;

    // Forward declarations for BRU signals used in fetch_top port connections
    logic        bru_early_redirect;
    logic        bru0_early_redirect;
    logic        bru1_early_redirect;
    logic        bru_partial_recovery_valid;
    logic        bru_partial_candidate_valid;
    logic        bru_partial_cdb_mispredict_valid;
    logic        bru_partial_candidate_from_cdb1;
    logic [ROB_IDX_BITS-1:0] bru_partial_candidate_rob_idx;
    logic        branch_recovery_burst_ready;
    logic        selective_branch_recovery_resource_ok;
    logic        frontend_recovery_headroom_ok;
    logic        rename_recovery_headroom_ok;
    logic [63:0] bru_early_target;
    logic [63:0] bru_target;
    logic        frontend_backend_stall;
    logic        frontend_late_flush_redundant;
    logic        frontend_flush_valid;
    logic [63:0] frontend_flush_pc;

    // =========================================================================
    // PRF Ready Table
    // =========================================================================
    logic [PHYS_TAG_COUNT-1:0] preg_ready_table;
    logic [PHYS_TAG_COUNT-1:0] preg_ready_table_comb;

    // =========================================================================
    // CDB signals (CDB_WIDTH=4 wakeup broadcast buses: ALU0,ALU1,ALU2,ALU3/DIV)
    // Load writeback is separate: loads use speculative wakeup, so they do not
    // need a CDB broadcast slot; they write PRF via prf_wen[4:5] directly.
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
    logic [CDB_WIDTH-1:0]     cdb_fp_fflags_valid;
    logic [4:0]               cdb_fp_fflags    [0:CDB_WIDTH-1];

    // =========================================================================
    // Load writeback signals (separate from CDB wakeup broadcast)
    // Loads use speculative wakeup (spec_wk) for IQ wake-up, so they do not
    // need slots in the CDB broadcast array.  These signals drive:
    //   - PRF write ports [4:5] (load result writeback)
    //   - ROB writeback (load completion + exception status)
    //   - Bypass network source [3] (Load0 combinational, for 2-cycle load)
    // =========================================================================
    logic [1:0]               load_wb_valid;      // [0]=Load0, [1]=Load1
    logic [PHYS_REG_BITS-1:0] load_wb_pdst  [0:1];
    logic [ROB_IDX_BITS-1:0]  load_wb_rob_idx [0:1];
    logic [63:0]              load_wb_data  [0:1];
    mem_size_e                load_wb_mem_size [0:1];
    logic [1:0]               load_wb_has_exception;
    logic [3:0]               load_wb_exc_code [0:1];

    // Recovery-filtered writeback valids.  Full flush drops every in-flight
    // result; partial flush keeps only results older than the restored tail.
    logic [CDB_WIDTH-1:0]     cdb_valid_live;
    logic [1:0]               load_wb_valid_live;
    logic                     lsu_sta_wb_valid_live;
    logic                     lsu_std_wb_valid_live;

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
    logic [CDB_WIDTH-1:0]     cdb_fp_fflags_valid_r;
    logic [4:0]               cdb_fp_fflags_r    [0:CDB_WIDTH-1];

    // =========================================================================
    // Registered load writeback sideband (1-cycle delay for ROB writeback).
    // Combinational load_wb_* declared below (after load_wb_valid assignment block).
    // =========================================================================
    logic [1:0]               load_wb_valid_r;
    logic [PHYS_REG_BITS-1:0] load_wb_pdst_r   [0:1];
    logic [ROB_IDX_BITS-1:0]  load_wb_rob_idx_r [0:1];
    logic [1:0]               load_wb_has_exception_r;
    logic [3:0]               load_wb_exc_code_r [0:1];

    // =========================================================================
    // Bypass sources (NUM_BYPASS_SRCS=5: ALU0/BRU, ALU1/BRU1, ALU2/MUL, Load0, Load1)
    // ALU3/DIV/CSR is not bypassed; consumers fall back to PRF.
    // =========================================================================
    logic [NUM_BYPASS_SRCS-1:0]    bypass_valid;
    logic [PHYS_REG_BITS-1:0]      bypass_tag  [0:NUM_BYPASS_SRCS-1];
    logic [63:0]                    bypass_data [0:NUM_BYPASS_SRCS-1];

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
    // Standalone UOP-cache decoded-op replay path. Disabled for Stage 1 signoff
    // until decoded delivery is tied to live BPU/FTQ validation.
    logic          uoc_active;
    logic          uoc_handoff_valid;
    logic [63:0]   uoc_handoff_pc;
    decoded_insn_t uoc_insn [0:PIPE_WIDTH-1];
    logic [2:0]    uoc_count;
    logic          uoc_ev_lookup, uoc_ev_hit, uoc_ev_miss;
    logic          uoc_ev_fill, uoc_ev_fill_evict_valid;
    logic          uoc_ev_enter_playing, uoc_ev_exit_playing_miss;
    logic          uoc_ev_exit_playing_nohit, uoc_ev_exit_playing_unsafe;
    logic          uoc_ev_emit, uoc_ev_emit_control;
    logic          uoc_ev_emit_cond, uoc_ev_emit_jal, uoc_ev_emit_jalr;
    logic          uoc_ev_emit_pred_taken;
    logic          uoc_ev_invalidate;
    logic [GHR_BITS-1:0] ghr_out;
    logic                ghr_restore_valid_fe;
    logic [GHR_BITS-1:0] ghr_restore_val_fe;
    logic                ras_restore_valid_fe;
    logic [4:0]          ras_restore_tos_fe;
    logic                ras_restore_top_valid_fe;
    logic [63:0]         ras_restore_top_addr_fe;
    logic        icache_fill_req_valid;
    logic [63:0] icache_fill_req_addr;
    logic        l2_icache_req_accepted;
    logic        icache_fill_resp_valid;
    logic [63:0] icache_fill_resp_addr;
    logic [511:0] icache_fill_resp_data;
    logic        instr_vm_active;
    logic        itlb_lookup_valid;
    logic [63:0] itlb_lookup_va;
    logic        itlb_miss_valid;
    logic [63:0] itlb_miss_va;
    logic        itlb_hit;
    logic [63:0] itlb_pa;
    logic        itlb_fault;
    logic [3:0]  itlb_fault_code;

    // Prefetch L2 signals (from fetch_top NLPB to L2 prefetch port).
    // Declared here because fetch_top instantiation below uses them as
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

    // BPU update signals to fetch.  Commit remains the default source; an
    // opt-in simulation knob can source mispredicted branches from execute to
    // measure predictor update-lag effects without changing default RTL.
    logic        bpu_update_valid;
    logic [63:0] bpu_update_pc;
    logic        bpu_tage_update_valid;
    logic [63:0] bpu_tage_update_pc;
    logic        bpu_tage_update_taken;
    logic        bpu_tage_update_mispredict;
    logic [63:0] bpu_tage_update_target;
    logic [GHR_BITS-1:0] bpu_tage_update_ghr;
    logic        bpu_update_taken;
    logic        bpu_update_mispredict;
    logic [63:0] bpu_update_target;
    logic [2:0]  bpu_update_type;
    logic [GHR_BITS-1:0] bpu_update_ghr;
    logic        commit_bpu_update_valid;
    logic [63:0] commit_bpu_update_pc;
    logic        commit_bpu_tage_update_valid;
    logic [63:0] commit_bpu_tage_update_pc;
    logic        commit_bpu_tage_update_taken;
    logic        commit_bpu_tage_update_mispredict;
    logic [63:0] commit_bpu_tage_update_target;
    logic [GHR_BITS-1:0] commit_bpu_tage_update_ghr;
    logic        commit_bpu_update_taken;
    logic        commit_bpu_update_mispredict;
    logic [63:0] commit_bpu_update_target;
    logic [2:0]  commit_bpu_update_type;
    logic [GHR_BITS-1:0] commit_bpu_update_ghr;
    logic        exec_bpu_update_valid;
    logic [63:0] exec_bpu_update_pc;
    logic        exec_bpu_tage_update_valid;
    logic [63:0] exec_bpu_tage_update_pc;
    logic        exec_bpu_tage_update_taken;
    logic        exec_bpu_tage_update_mispredict;
    logic [63:0] exec_bpu_tage_update_target;
    logic [GHR_BITS-1:0] exec_bpu_tage_update_ghr;
    logic        exec_bpu_update_taken;
    logic        exec_bpu_update_mispredict;
    logic [63:0] exec_bpu_update_target;
    logic [2:0]  exec_bpu_update_type;
    logic [GHR_BITS-1:0] exec_bpu_update_ghr;

`ifndef SYNTHESIS
    bit sim_bpu_exec_misp_update;
    bit sim_exec_partial_branch_recovery;
    bit sim_selective_branch_recovery;
    bit sim_tage_train_misp_cond_first;
    bit sim_bru0_early_redirect_en;
    bit sim_bru1_early_redirect_en;
    bit sim_uoc_enable;
    initial sim_bpu_exec_misp_update =
        $test$plusargs("BPU_EXEC_MISP_UPDATE");
    initial sim_exec_partial_branch_recovery =
        $test$plusargs("EXEC_PARTIAL_BRANCH_RECOVERY");
    initial sim_selective_branch_recovery =
        $test$plusargs("SELECTIVE_BRANCH_RECOVERY");
    initial sim_tage_train_misp_cond_first =
        $test$plusargs("TAGE_TRAIN_MISP_COND_FIRST");
    initial sim_bru0_early_redirect_en =
        $test$plusargs("ENABLE_BRU_EARLY_REDIRECT") &&
        !$test$plusargs("DISABLE_BRU_EARLY_REDIRECT") &&
        !$test$plusargs("DISABLE_BRU0_EARLY_REDIRECT");
    initial sim_bru1_early_redirect_en =
        $test$plusargs("ENABLE_BRU_EARLY_REDIRECT") &&
        !$test$plusargs("DISABLE_BRU_EARLY_REDIRECT") &&
        !$test$plusargs("DISABLE_BRU1_EARLY_REDIRECT");
    // Stage 1 signs off the FTQ/IFU/fetch-packet frontend path. The UOP cache
    // remains an explicit unsafe research path until replay is tied to live
    // BPU/FTQ validation.
    initial sim_uoc_enable =
        $test$plusargs("ENABLE_UOC") &&
        $test$plusargs("UOC_UNSAFE_STREAM") &&
        !$test$plusargs("DISABLE_UOC");
`else
    localparam logic sim_bpu_exec_misp_update = 1'b0;
    localparam logic sim_exec_partial_branch_recovery = 1'b0;
    localparam logic sim_selective_branch_recovery = 1'b0;
    localparam logic sim_tage_train_misp_cond_first = 1'b0;
    localparam logic sim_bru0_early_redirect_en = 1'b0;
    localparam logic sim_bru1_early_redirect_en = 1'b0;
    localparam logic sim_uoc_enable = 1'b0;
`endif

    // Stall from decode/rename
    logic        backend_stall;
    logic        bru_redirect_quarantine_r;
    logic        bru_redirect_quarantine;
    logic        keep_early_frontend;
    localparam int SELECTIVE_RECOVERY_COOLDOWN_CYCLES = 32;
    localparam int SELECTIVE_RECOVERY_COOLDOWN_BITS =
        $clog2(SELECTIVE_RECOVERY_COOLDOWN_CYCLES + 1);
    logic [SELECTIVE_RECOVERY_COOLDOWN_BITS-1:0]
        selective_recovery_cooldown_r;

    // FENCE.I signal
    logic        fence_i_signal;

    fetch_top u_fetch_top (
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
        .backend_stall          (frontend_backend_stall),
        // When UOP-cache playback owns rename input, quiesce fetch traffic and
        // let the stream-exit redirect restart the live frontend.
        .frontend_hold          (uoc_active),
        .frontend_replay_blocking(1'b0),
        .frontend_replay_start   (1'b0),
        .recovery_headroom_ok   (frontend_recovery_headroom_ok),
        // Redirect priority: commit/BRU flush > UOP-cache stream handoff.
        .redirect_valid         (frontend_flush_valid || uoc_handoff_valid),
        .redirect_pc            (frontend_flush_valid ? frontend_flush_pc :
                                                        uoc_handoff_pc),
        .instr_vm_active        (instr_vm_active),
        .itlb_hit               (itlb_hit),
        .itlb_pa                (itlb_pa),
        .itlb_fault             (itlb_fault),
        .itlb_lookup_valid      (itlb_lookup_valid),
        .itlb_lookup_va         (itlb_lookup_va),
        .itlb_miss_valid        (itlb_miss_valid),
        .itlb_miss_va           (itlb_miss_va),
        .bpu_update_valid       (bpu_update_valid),
        .bpu_update_pc          (bpu_update_pc),
        .bpu_tage_update_valid  (bpu_tage_update_valid),
        .bpu_tage_update_pc     (bpu_tage_update_pc),
        .bpu_tage_update_taken  (bpu_tage_update_taken),
        .bpu_tage_update_mispredict(bpu_tage_update_mispredict),
        .bpu_tage_update_target (bpu_tage_update_target),
        .bpu_tage_update_ghr    (bpu_tage_update_ghr),
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
        .icache_fill_req_accepted(l2_icache_req_accepted),
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
        .stall          (frontend_backend_stall),
        .flush          (frontend_flush_valid || uoc_handoff_valid)
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

    // Rename stall signal
    logic rename_stall;

    // =========================================================================
    // 4. UOP CACHE / DECODED-OP CACHE
    // =========================================================================
    uop_cache u_uop_cache (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .en                     (sim_uoc_enable),
        .fused_insn             (fused_insn),
        .fused_count            (fused_count),
        .uoc_insn               (uoc_insn),
        .uoc_count              (uoc_count),
        .active                 (uoc_active),
        .handoff_valid          (uoc_handoff_valid),
        .handoff_pc             (uoc_handoff_pc),
        .redirect_valid         (frontend_flush_valid),
        .redirect_pc            (frontend_flush_pc),
        .invalidate             (fence_i_signal),
        .stall                  (rename_stall),
        .ev_lookup              (uoc_ev_lookup),
        .ev_hit                 (uoc_ev_hit),
        .ev_miss                (uoc_ev_miss),
        .ev_fill                (uoc_ev_fill),
        .ev_fill_evict_valid    (uoc_ev_fill_evict_valid),
        .ev_enter_playing       (uoc_ev_enter_playing),
        .ev_exit_playing_miss   (uoc_ev_exit_playing_miss),
        .ev_exit_playing_nohit  (uoc_ev_exit_playing_nohit),
        .ev_exit_playing_unsafe (uoc_ev_exit_playing_unsafe),
        .ev_emit                (uoc_ev_emit),
        .ev_emit_control        (uoc_ev_emit_control),
        .ev_emit_cond           (uoc_ev_emit_cond),
        .ev_emit_jal            (uoc_ev_emit_jal),
        .ev_emit_jalr           (uoc_ev_emit_jalr),
        .ev_emit_pred_taken     (uoc_ev_emit_pred_taken),
        .ev_invalidate          (uoc_ev_invalidate)
    );

    // Mux: bru-quarantine > UOP-cache > fused.
    decoded_insn_t rename_dec_in [0:PIPE_WIDTH-1];
    logic [2:0]    rename_dec_count;

    always_comb begin
        if (bru_redirect_quarantine) begin
            for (int i = 0; i < PIPE_WIDTH; i++)
                rename_dec_in[i] = '0;
            rename_dec_count = 3'd0;
        end else if (uoc_active) begin
            for (int i = 0; i < PIPE_WIDTH; i++)
                rename_dec_in[i] = uoc_insn[i];
            rename_dec_count = uoc_count;
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
    logic [ROB_IDX_BITS:0]   rob_free_count;
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
    logic [63:0]             rob_head_exc_tval    [0:PIPE_WIDTH-1];
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
    logic [PIPE_WIDTH-1:0]   rob_head_is_fused;
    logic [PIPE_WIDTH-1:0]   rob_head_is_fp_instr;
    logic [PIPE_WIDTH-1:0]   rob_head_branch_taken;
    logic [63:0]             rob_head_branch_target [0:PIPE_WIDTH-1];
    logic [63:0]             rob_head_branch_taken_target [0:PIPE_WIDTH-1];
    logic [PIPE_WIDTH-1:0]   rob_head_branch_mispredict;
    logic [11:0]             rob_head_csr_addr    [0:PIPE_WIDTH-1];
    logic [63:0]             rob_head_csr_wdata   [0:PIPE_WIDTH-1];
    logic [PIPE_WIDTH-1:0]   rob_head_csr_we;
    logic [1:0]              rob_head_csr_op      [0:PIPE_WIDTH-1];
    logic [4:0]              rob_head_fp_fflags   [0:PIPE_WIDTH-1];

    // Commit signals
    logic [2:0]              commit_count;
    commit_t                 commit_out [0:PIPE_WIDTH-1];
    logic [2:0]              store_commit_count;
    logic [2:0]              load_commit_count;
    logic [3:0]              insn_retired_count;

    // =========================================================================
    // Rename buffer: parallel to ROB, stores pdst/old_pdst/rd_arch
    // =========================================================================
    rename_buf_entry_t rename_buf [0:ROB_DEPTH-1];

    // Checkpoint storage parallel to ROB (declarations hoisted from later
    // so the ifdef SIMULATION init block below can reach them)
    logic                       rob_uses_checkpoint [0:ROB_DEPTH-1];
    logic [CHECKPOINT_BITS-1:0] rob_checkpoint_id   [0:ROB_DEPTH-1];
    // Checkpoint branch boundary parallel to ROB. A branch can use
    // execute-time partial recovery only when the checkpoint image was taken
    // at that branch boundary, so older same-batch mappings are preserved.
    logic [ROB_IDX_BITS-1:0]    rob_checkpoint_tail [0:ROB_DEPTH-1];
    logic [ROB_DEPTH-1:0]       rename_buf_partial_clear;
    logic [ROB_IDX_BITS-1:0]    partial_recovered_rob_idx;

    assign partial_recovered_rob_idx =
        (flush_out.rob_idx == ROB_IDX_BITS'(0))
            ? ROB_IDX_BITS'(ROB_DEPTH - 1)
            : (flush_out.rob_idx - ROB_IDX_BITS'(1));

    always_comb begin
        rename_buf_partial_clear = '0;
        if (flush_out.valid && !flush_out.full_flush) begin
            for (int i = 0; i < ROB_DEPTH; i++) begin
                if (flush_out.rob_idx == rob_tail_idx) begin
                    rename_buf_partial_clear[i] = 1'b0;
                end else if (flush_out.rob_idx < rob_tail_idx) begin
                    rename_buf_partial_clear[i] =
                        (ROB_IDX_BITS'(i) >= flush_out.rob_idx) &&
                        (ROB_IDX_BITS'(i) < rob_tail_idx);
                end else begin
                    rename_buf_partial_clear[i] =
                        (ROB_IDX_BITS'(i) >= flush_out.rob_idx) ||
                        (ROB_IDX_BITS'(i) < rob_tail_idx);
                end
            end
        end
    end

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
            rob_checkpoint_tail[i] = '0;
        end
    end
`endif
    logic [2:0] ren_count_raw;
    // Suppress rename output on a commit-driven flush so stale pre-flush
    // instructions cannot enter the ROB, DQ, or ready table.
    logic [2:0] ren_count_w;
    assign ren_count_w = flush_out.valid ? 3'd0 : ren_count_raw;
    logic [PHYS_REG_BITS:0] rename_free_preg_count;

    // Read rename buffer at head for commit
    logic [PHYS_REG_BITS-1:0] rb_head_pdst      [0:PIPE_WIDTH-1];
    logic [PHYS_REG_BITS-1:0] rb_head_old_pdst   [0:PIPE_WIDTH-1];
    logic [4:0]               rb_head_rd_arch    [0:PIPE_WIDTH-1];
    logic [PIPE_WIDTH-1:0]    rb_head_rd_valid;
    logic [PIPE_WIDTH-1:0]    rb_head_rd_is_fp;
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
            rb_head_rd_is_fp[i]      = rename_buf[idx].rd_is_fp;
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
    logic [PIPE_WIDTH-1:0]    commit_is_fp_dst;
    logic [4:0]               commit_rd_arch_w  [0:PIPE_WIDTH-1];
    logic [PHYS_REG_BITS-1:0] commit_pdst_w     [0:PIPE_WIDTH-1];
    logic [PIPE_WIDTH-1:0]    commit_release_cp;
    logic [CHECKPOINT_BITS-1:0] commit_cp_id [0:PIPE_WIDTH-1];

    // Move/zero elimination flags from rename (per output slot)
    logic [PIPE_WIDTH-1:0] ren_move_eliminated;
    logic [PIPE_WIDTH-1:0] ren_zero_eliminated;
    // Combined: instruction was eliminated and must not be dispatched
    logic [PIPE_WIDTH-1:0] ren_eliminated;
    logic [PIPE_WIDTH-1:0] ren_decoded_exception;
    logic [PIPE_WIDTH-1:0] rob_alloc_ready_now;
    assign ren_eliminated = ren_move_eliminated | ren_zero_eliminated;
    always_comb begin
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            ren_decoded_exception[i] = ren_insn[i].base.has_exception;
        end
    end
    assign rob_alloc_ready_now = ren_eliminated | ren_decoded_exception;

    localparam logic [ROB_IDX_BITS:0] BACKEND_THROTTLE_ROB_ENTER =
        (ROB_IDX_BITS+1)'(16);
    localparam logic [ROB_IDX_BITS:0] BACKEND_THROTTLE_ROB_EXIT =
        (ROB_IDX_BITS+1)'(32);
    localparam logic [PHYS_REG_BITS:0] BACKEND_THROTTLE_PREG_ENTER =
        (PHYS_REG_BITS+1)'(24);
    localparam logic [PHYS_REG_BITS:0] BACKEND_THROTTLE_PREG_EXIT =
        (PHYS_REG_BITS+1)'(48);

    logic backend_admission_throttle_r;
    logic backend_admission_pressure;
    logic backend_admission_recovered;
    logic backend_admission_head_block;
    logic backend_admission_throttle_enter;
    logic backend_admission_throttle_exit;
    logic backend_admission_throttle_active;

    assign backend_admission_pressure =
        (rob_free_count <= BACKEND_THROTTLE_ROB_ENTER) ||
        (rename_free_preg_count <= BACKEND_THROTTLE_PREG_ENTER);
    assign backend_admission_recovered =
        (rob_free_count >= BACKEND_THROTTLE_ROB_EXIT) &&
        (rename_free_preg_count >= BACKEND_THROTTLE_PREG_EXIT);
    assign backend_admission_head_block =
        rob_head_valid[0] && !rob_head_ready[0];
    assign backend_admission_throttle_enter =
        backend_admission_throttle_enable &&
        !flush_out.valid &&
        !rob_empty &&
        backend_admission_pressure;
    assign backend_admission_throttle_exit =
        !backend_admission_throttle_enable ||
        flush_out.valid ||
        rob_empty ||
        backend_admission_recovered;
    assign backend_admission_throttle_active = backend_admission_throttle_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            backend_admission_throttle_r <= 1'b0;
        end else if (backend_admission_throttle_exit) begin
            backend_admission_throttle_r <= 1'b0;
        end else if (backend_admission_throttle_enter) begin
            backend_admission_throttle_r <= 1'b1;
        end
    end

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
        .free_preg_count  (rename_free_preg_count),
        .backend_admission_throttle(backend_admission_throttle_active),
        .stall            (rename_stall),
        .recovery_headroom_ok(rename_recovery_headroom_ok),
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
        .commit_is_fp_dst (commit_is_fp_dst),
        .commit_rd_arch   (commit_rd_arch_w),
        .commit_pdst      (commit_pdst_w),
        .commit_release_cp(commit_release_cp),
        .commit_cp_id     (commit_cp_id)
    );

    logic [63:0]             bru_redirect_target_r;
    logic [ROB_IDX_BITS-1:0] bru_redirect_rob_r;
    logic                    bru_redirect_is_cond_r;
    logic                    commit_mispredict_branch_valid;
    logic [ROB_IDX_BITS-1:0] commit_mispredict_branch_rob;

`ifdef SIMULATION
    logic sim_keep_early_frontend;
    initial begin
        sim_keep_early_frontend = $test$plusargs("KEEP_EARLY_FRONTEND");
    end
    assign keep_early_frontend = sim_keep_early_frontend;
`else
    assign keep_early_frontend = 1'b0;
`endif

    always_comb begin
        commit_mispredict_branch_valid = 1'b0;
        commit_mispredict_branch_rob   = rob_head_idx;
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            automatic logic [ROB_IDX_BITS:0] idx_sum;
            automatic logic [ROB_IDX_BITS-1:0] idx_w;

            idx_sum = {1'b0, rob_head_idx} +
                      {{(ROB_IDX_BITS-2){1'b0}}, i[2:0]};
            if (idx_sum >= (ROB_IDX_BITS+1)'(ROB_DEPTH))
                idx_w = ROB_IDX_BITS'(idx_sum - (ROB_IDX_BITS+1)'(ROB_DEPTH));
            else
                idx_w = idx_sum[ROB_IDX_BITS-1:0];

            if (!commit_mispredict_branch_valid &&
                commit_out[i].valid &&
                rob_head_branch_mispredict[i]) begin
                commit_mispredict_branch_valid = 1'b1;
                commit_mispredict_branch_rob   = idx_w;
            end
        end
    end

    assign frontend_late_flush_redundant =
        keep_early_frontend &&
        bru_redirect_quarantine_r &&
        bru_redirect_is_cond_r &&
        flush_out.valid &&
        flush_out.full_flush &&
        commit_mispredict_branch_valid &&
        (commit_mispredict_branch_rob == bru_redirect_rob_r) &&
        (flush_out.redirect_pc == bru_redirect_target_r);

    assign frontend_flush_valid =
        (flush_out.valid && !frontend_late_flush_redundant) ||
        bru_early_redirect;
    assign frontend_flush_pc =
        (flush_out.valid && !frontend_late_flush_redundant)
            ? flush_out.redirect_pc
            : bru_early_target;

    // Backend stall: rename cannot accept.  In the opt-in early-frontend
    // retention mode, a BRU quarantine also stalls packet dequeue/decode so
    // correct-path packets fetched by the execute-time redirect are not
    // consumed and dropped while rename is forced to zero.
    assign bru_redirect_quarantine = bru_early_redirect || bru_redirect_quarantine_r;
    assign backend_stall = rename_stall;
    assign frontend_backend_stall =
        rename_stall || (keep_early_frontend && bru_redirect_quarantine);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush_out.valid) begin
            bru_redirect_quarantine_r <= 1'b0;
            bru_redirect_target_r     <= 64'd0;
            bru_redirect_rob_r        <= '0;
            bru_redirect_is_cond_r    <= 1'b0;
        end else if (bru_early_redirect) begin
            bru_redirect_quarantine_r <= 1'b1;
            bru_redirect_target_r     <= bru_early_target;
            bru_redirect_rob_r        <= bru1_early_redirect
                ? iq0_issue_data[1].rob_idx
                : iq0_issue_data[0].rob_idx;
            bru_redirect_is_cond_r    <= bru1_early_redirect
                ? br_op_is_cond(iq0_issue_data[1].br_op)
                : br_op_is_cond(iq0_issue_data[0].br_op);
        end
    end

`ifdef SIMULATION
    // Observability for the current fetch-only BRU redirect contract.
    // After execute redirects fetch, rename is intentionally quarantined until
    // the mispredicting branch reaches commit and performs the architectural
    // flush.  These counters quantify that remaining recovery penalty.
    logic sim_bru_recovery_en;
    logic sim_bru_recovery_trace_en;
    logic sim_bru_flush_is_mispredict;
    integer sim_bru_early_cnt;
    integer sim_bru0_early_cnt;
    integer sim_bru1_early_cnt;
    integer sim_bru_quarantine_cycles;
    integer sim_bru_quarantine_runs;
    integer sim_bru_quarantine_sum;
    integer sim_bru_quarantine_max;
    integer sim_bru_quarantine_run;
    integer sim_bru_quarantine_misp_end;
    integer sim_bru_quarantine_other_end;
    integer sim_bru_quarantine_fused_suppressed;
    integer sim_bru_quarantine_age;
    integer sim_bru_quarantine_age_sum;
    integer sim_bru_quarantine_age_max;
    integer sim_bru_quarantine_ckpt_runs;
    integer sim_bru_quarantine_ckpt_at_branch_runs;
    integer sim_bru_quarantine_no_ckpt_runs;
    integer sim_bru_quarantine_ckpt_at_branch_cycles;
    logic [63:0] sim_bru_quarantine_pc;
    logic [63:0] sim_bru_quarantine_target;
    logic [ROB_IDX_BITS-1:0] sim_bru_quarantine_rob;
    logic [2:0] sim_bru_quarantine_type;
    logic sim_bru_quarantine_uses_checkpoint;
    logic sim_bru_quarantine_ckpt_at_branch;

    localparam int SIM_BRU_RECOVERY_TOPN = 16;
    logic [63:0] sim_bru_top_pc [0:SIM_BRU_RECOVERY_TOPN-1];
    integer sim_bru_top_count [0:SIM_BRU_RECOVERY_TOPN-1];
    integer sim_bru_top_cycles [0:SIM_BRU_RECOVERY_TOPN-1];
    integer sim_bru_top_max [0:SIM_BRU_RECOVERY_TOPN-1];
    integer sim_bru_top_age_sum [0:SIM_BRU_RECOVERY_TOPN-1];
    integer sim_bru_top_age_max [0:SIM_BRU_RECOVERY_TOPN-1];
    integer sim_bru_top_cond [0:SIM_BRU_RECOVERY_TOPN-1];
    integer sim_bru_top_jal [0:SIM_BRU_RECOVERY_TOPN-1];
    integer sim_bru_top_jalr [0:SIM_BRU_RECOVERY_TOPN-1];
    integer sim_bru_top_uses_ckpt [0:SIM_BRU_RECOVERY_TOPN-1];
    integer sim_bru_top_ckpt_at_branch [0:SIM_BRU_RECOVERY_TOPN-1];

    logic [63:0] sim_bru_selected_pc;
    logic [ROB_IDX_BITS-1:0] sim_bru_selected_rob;
    logic [2:0] sim_bru_selected_type;
    logic sim_bru_selected_uses_checkpoint;
    logic sim_bru_selected_ckpt_at_branch;
    logic [ROB_IDX_BITS:0] sim_bru_selected_age;

    initial begin
        sim_bru_recovery_en =
            $test$plusargs("PERF_PROFILE") ||
            $test$plusargs("STAT_DUMP") ||
            $test$plusargs("TRACE_BRU_RECOVERY");
        sim_bru_recovery_trace_en = $test$plusargs("TRACE_BRU_RECOVERY");
    end

    always_comb begin
        sim_bru_flush_is_mispredict = 1'b0;
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            if (commit_out[i].valid && rob_head_branch_mispredict[i])
                sim_bru_flush_is_mispredict = 1'b1;
        end
    end

    always_comb begin
        sim_bru_selected_pc = bru1_early_redirect
            ? iq0_issue_data[1].pc
            : iq0_issue_data[0].pc;
        sim_bru_selected_rob = bru1_early_redirect
            ? iq0_issue_data[1].rob_idx
            : iq0_issue_data[0].rob_idx;
        sim_bru_selected_type = bru1_early_redirect
            ? iq0_issue_data[1].br_op
            : iq0_issue_data[0].br_op;
        sim_bru_selected_uses_checkpoint = bru1_early_redirect
            ? iq0_issue_data[1].uses_checkpoint
            : iq0_issue_data[0].uses_checkpoint;
        sim_bru_selected_ckpt_at_branch =
            sim_bru_selected_uses_checkpoint &&
            (rob_checkpoint_tail[sim_bru_selected_rob] == sim_bru_selected_rob);

        if (sim_bru_selected_rob >= rob_head_idx) begin
            sim_bru_selected_age =
                {1'b0, sim_bru_selected_rob} - {1'b0, rob_head_idx};
        end else begin
            sim_bru_selected_age =
                (ROB_IDX_BITS+1)'(ROB_DEPTH) -
                {1'b0, rob_head_idx} + {1'b0, sim_bru_selected_rob};
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sim_bru_early_cnt                  <= 0;
            sim_bru0_early_cnt                 <= 0;
            sim_bru1_early_cnt                 <= 0;
            sim_bru_quarantine_cycles          <= 0;
            sim_bru_quarantine_runs            <= 0;
            sim_bru_quarantine_sum             <= 0;
            sim_bru_quarantine_max             <= 0;
            sim_bru_quarantine_run             <= 0;
            sim_bru_quarantine_misp_end        <= 0;
            sim_bru_quarantine_other_end       <= 0;
            sim_bru_quarantine_fused_suppressed <= 0;
            sim_bru_quarantine_age             <= 0;
            sim_bru_quarantine_age_sum         <= 0;
            sim_bru_quarantine_age_max         <= 0;
            sim_bru_quarantine_ckpt_runs       <= 0;
            sim_bru_quarantine_ckpt_at_branch_runs <= 0;
            sim_bru_quarantine_no_ckpt_runs    <= 0;
            sim_bru_quarantine_ckpt_at_branch_cycles <= 0;
            sim_bru_quarantine_pc              <= 64'd0;
            sim_bru_quarantine_target          <= 64'd0;
            sim_bru_quarantine_rob             <= '0;
            sim_bru_quarantine_type            <= 3'd0;
            sim_bru_quarantine_uses_checkpoint <= 1'b0;
            sim_bru_quarantine_ckpt_at_branch  <= 1'b0;
            for (int i = 0; i < SIM_BRU_RECOVERY_TOPN; i++) begin
                sim_bru_top_pc[i]             <= 64'd0;
                sim_bru_top_count[i]          <= 0;
                sim_bru_top_cycles[i]         <= 0;
                sim_bru_top_max[i]            <= 0;
                sim_bru_top_age_sum[i]        <= 0;
                sim_bru_top_age_max[i]        <= 0;
                sim_bru_top_cond[i]           <= 0;
                sim_bru_top_jal[i]            <= 0;
                sim_bru_top_jalr[i]           <= 0;
                sim_bru_top_uses_ckpt[i]      <= 0;
                sim_bru_top_ckpt_at_branch[i] <= 0;
            end
        end else if (sim_bru_recovery_en) begin
            if (bru0_early_redirect) begin
                sim_bru0_early_cnt <= sim_bru0_early_cnt + 1;
            end
            if (bru1_early_redirect) begin
                sim_bru1_early_cnt <= sim_bru1_early_cnt + 1;
            end
            if (bru_early_redirect) begin
                sim_bru_early_cnt <= sim_bru_early_cnt + 1;
                if (!bru_redirect_quarantine_r) begin
                    sim_bru_quarantine_pc <= sim_bru_selected_pc;
                    sim_bru_quarantine_target <= bru_early_target;
                    sim_bru_quarantine_rob <= sim_bru_selected_rob;
                    sim_bru_quarantine_type <= sim_bru_selected_type;
                    sim_bru_quarantine_age <= int'(sim_bru_selected_age);
                    sim_bru_quarantine_uses_checkpoint <=
                        sim_bru_selected_uses_checkpoint;
                    sim_bru_quarantine_ckpt_at_branch <=
                        sim_bru_selected_ckpt_at_branch;
                end
            end

            if (bru_redirect_quarantine) begin
                sim_bru_quarantine_cycles <= sim_bru_quarantine_cycles + 1;
                sim_bru_quarantine_fused_suppressed <=
                    sim_bru_quarantine_fused_suppressed + fused_count;
            end

            if (flush_out.valid && bru_redirect_quarantine_r) begin
                sim_bru_quarantine_runs <= sim_bru_quarantine_runs + 1;
                sim_bru_quarantine_sum  <= sim_bru_quarantine_sum +
                                           sim_bru_quarantine_run + 1;
                if ((sim_bru_quarantine_run + 1) > sim_bru_quarantine_max)
                    sim_bru_quarantine_max <= sim_bru_quarantine_run + 1;
                if (sim_bru_flush_is_mispredict)
                    sim_bru_quarantine_misp_end <= sim_bru_quarantine_misp_end + 1;
                else
                    sim_bru_quarantine_other_end <= sim_bru_quarantine_other_end + 1;
                sim_bru_quarantine_age_sum <= sim_bru_quarantine_age_sum +
                                               sim_bru_quarantine_age;
                if (sim_bru_quarantine_age > sim_bru_quarantine_age_max)
                    sim_bru_quarantine_age_max <= sim_bru_quarantine_age;
                if (sim_bru_quarantine_uses_checkpoint)
                    sim_bru_quarantine_ckpt_runs <= sim_bru_quarantine_ckpt_runs + 1;
                else
                    sim_bru_quarantine_no_ckpt_runs <= sim_bru_quarantine_no_ckpt_runs + 1;
                if (sim_bru_quarantine_ckpt_at_branch) begin
                    sim_bru_quarantine_ckpt_at_branch_runs <=
                        sim_bru_quarantine_ckpt_at_branch_runs + 1;
                    sim_bru_quarantine_ckpt_at_branch_cycles <=
                        sim_bru_quarantine_ckpt_at_branch_cycles +
                        sim_bru_quarantine_run + 1;
                end

                begin : sim_bru_top_update
                    int hit_idx;
                    int empty_idx;
                    int min_idx;
                    int use_idx;
                    int min_cycles;

                    hit_idx = -1;
                    empty_idx = -1;
                    min_idx = 0;
                    min_cycles = sim_bru_top_cycles[0];
                    for (int i = 0; i < SIM_BRU_RECOVERY_TOPN; i++) begin
                        if ((sim_bru_top_count[i] != 0) &&
                            (sim_bru_top_pc[i] == sim_bru_quarantine_pc) &&
                            (hit_idx < 0)) begin
                            hit_idx = i;
                        end
                        if ((sim_bru_top_count[i] == 0) &&
                            (empty_idx < 0)) begin
                            empty_idx = i;
                        end
                        if (sim_bru_top_cycles[i] < min_cycles) begin
                            min_cycles = sim_bru_top_cycles[i];
                            min_idx = i;
                        end
                    end

                    if (hit_idx >= 0) begin
                        use_idx = hit_idx;
                        sim_bru_top_count[use_idx] <=
                            sim_bru_top_count[use_idx] + 1;
                        sim_bru_top_cycles[use_idx] <=
                            sim_bru_top_cycles[use_idx] +
                            sim_bru_quarantine_run + 1;
                        if ((sim_bru_quarantine_run + 1) >
                            sim_bru_top_max[use_idx]) begin
                            sim_bru_top_max[use_idx] <=
                                sim_bru_quarantine_run + 1;
                        end
                        sim_bru_top_age_sum[use_idx] <=
                            sim_bru_top_age_sum[use_idx] +
                            sim_bru_quarantine_age;
                        if (sim_bru_quarantine_age >
                            sim_bru_top_age_max[use_idx]) begin
                            sim_bru_top_age_max[use_idx] <=
                                sim_bru_quarantine_age;
                        end
                        if (br_op_is_cond(br_op_e'(sim_bru_quarantine_type)))
                            sim_bru_top_cond[use_idx] <=
                                sim_bru_top_cond[use_idx] + 1;
                        else if (sim_bru_quarantine_type == BR_JAL)
                            sim_bru_top_jal[use_idx] <=
                                sim_bru_top_jal[use_idx] + 1;
                        else if (sim_bru_quarantine_type == BR_JALR)
                            sim_bru_top_jalr[use_idx] <=
                                sim_bru_top_jalr[use_idx] + 1;
                        if (sim_bru_quarantine_uses_checkpoint)
                            sim_bru_top_uses_ckpt[use_idx] <=
                                sim_bru_top_uses_ckpt[use_idx] + 1;
                        if (sim_bru_quarantine_ckpt_at_branch)
                            sim_bru_top_ckpt_at_branch[use_idx] <=
                                sim_bru_top_ckpt_at_branch[use_idx] + 1;
                    end else begin
                        use_idx = (empty_idx >= 0) ? empty_idx : min_idx;
                        sim_bru_top_pc[use_idx] <= sim_bru_quarantine_pc;
                        sim_bru_top_count[use_idx] <= 1;
                        sim_bru_top_cycles[use_idx] <=
                            sim_bru_quarantine_run + 1;
                        sim_bru_top_max[use_idx] <=
                            sim_bru_quarantine_run + 1;
                        sim_bru_top_age_sum[use_idx] <=
                            sim_bru_quarantine_age;
                        sim_bru_top_age_max[use_idx] <=
                            sim_bru_quarantine_age;
                        sim_bru_top_cond[use_idx] <=
                            br_op_is_cond(br_op_e'(sim_bru_quarantine_type))
                                ? 1 : 0;
                        sim_bru_top_jal[use_idx] <=
                            (sim_bru_quarantine_type == BR_JAL) ? 1 : 0;
                        sim_bru_top_jalr[use_idx] <=
                            (sim_bru_quarantine_type == BR_JALR) ? 1 : 0;
                        sim_bru_top_uses_ckpt[use_idx] <=
                            sim_bru_quarantine_uses_checkpoint ? 1 : 0;
                        sim_bru_top_ckpt_at_branch[use_idx] <=
                            sim_bru_quarantine_ckpt_at_branch ? 1 : 0;
                    end
                end

                if (sim_bru_recovery_trace_en) begin
                    $display("[BRU_RECOVERY] pc=%016h rob=%0d type=%0d target=%016h quarantine_cycles=%0d end_misp=%b flush_pc=%016h age=%0d uses_ckpt=%b ckpt_at_branch=%b",
                             sim_bru_quarantine_pc,
                             sim_bru_quarantine_rob,
                             sim_bru_quarantine_type,
                             sim_bru_quarantine_target,
                             sim_bru_quarantine_run + 1,
                             sim_bru_flush_is_mispredict,
                             flush_out.redirect_pc,
                             sim_bru_quarantine_age,
                             sim_bru_quarantine_uses_checkpoint,
                             sim_bru_quarantine_ckpt_at_branch);
                end

                sim_bru_quarantine_run <= 0;
            end else if (bru_redirect_quarantine) begin
                sim_bru_quarantine_run <= sim_bru_quarantine_run + 1;
            end else begin
                sim_bru_quarantine_run <= 0;
            end
        end
    end

    final begin
        if (sim_bru_recovery_en) begin
            $display("");
            $display("=== BRU EARLY REDIRECT RECOVERY SUMMARY ===");
            $display("Early redirects total / BRU0 / BRU1: %0d / %0d / %0d",
                     sim_bru_early_cnt, sim_bru0_early_cnt, sim_bru1_early_cnt);
            $display("Quarantine cycles:                   %0d", sim_bru_quarantine_cycles);
            $display("Quarantine runs ended:               %0d", sim_bru_quarantine_runs);
            $display("  ended by branch mispredict flush:  %0d", sim_bru_quarantine_misp_end);
            $display("  ended by other flush:              %0d", sim_bru_quarantine_other_end);
            $display("  open at simulation end:            %0d",
                     (sim_bru_quarantine_run != 0) ? 1 : 0);
            $display("Quarantine avg cycles/run x100:      %0d",
                     (sim_bru_quarantine_runs != 0)
                         ? (sim_bru_quarantine_sum * 100 / sim_bru_quarantine_runs)
                         : 0);
            $display("Quarantine max cycles/run:           %0d", sim_bru_quarantine_max);
            $display("Quarantine avg ROB age x100:         %0d",
                     (sim_bru_quarantine_runs != 0)
                         ? (sim_bru_quarantine_age_sum * 100 /
                            sim_bru_quarantine_runs)
                         : 0);
            $display("Quarantine max ROB age:              %0d",
                     sim_bru_quarantine_age_max);
            $display("Checkpoint runs any/safe-boundary/no:%0d / %0d / %0d",
                     sim_bru_quarantine_ckpt_runs,
                     sim_bru_quarantine_ckpt_at_branch_runs,
                     sim_bru_quarantine_no_ckpt_runs);
            $display("Safe-boundary quarantine cycles:     %0d",
                     sim_bru_quarantine_ckpt_at_branch_cycles);
            $display("Correct-path fused insns suppressed: %0d",
                     sim_bru_quarantine_fused_suppressed);
            $display("Upper-bound rename slots suppressed: %0d",
                     sim_bru_quarantine_cycles * PIPE_WIDTH);
            $display("BRU recovery PC attribution (approx top %0d by cycles):",
                     SIM_BRU_RECOVERY_TOPN);
            $display("  pc               count cycles avg_x100 max avg_age_x100 max_age cond/jal/jalr ckpt/safe");
            for (int i = 0; i < SIM_BRU_RECOVERY_TOPN; i++) begin
                if (sim_bru_top_count[i] != 0) begin
                    $display("  %016h %0d %0d %0d %0d %0d %0d %0d/%0d/%0d %0d/%0d",
                             sim_bru_top_pc[i],
                             sim_bru_top_count[i],
                             sim_bru_top_cycles[i],
                             sim_bru_top_cycles[i] * 100 /
                                 sim_bru_top_count[i],
                             sim_bru_top_max[i],
                             sim_bru_top_age_sum[i] * 100 /
                                 sim_bru_top_count[i],
                             sim_bru_top_age_max[i],
                             sim_bru_top_cond[i],
                             sim_bru_top_jal[i],
                             sim_bru_top_jalr[i],
                             sim_bru_top_uses_ckpt[i],
                             sim_bru_top_ckpt_at_branch[i]);
                end
            end
        end
    end
`endif

    // =========================================================================
    // Write rename buffer at allocation time
    // =========================================================================
    localparam logic [1:0] RAS_NONE = 2'd0;
    localparam logic [1:0] RAS_PUSH = 2'd1;
    localparam logic [1:0] RAS_POP  = 2'd2;
    localparam logic [2:0] BT_COND = 3'd0;
    localparam logic [2:0] BT_JAL  = 3'd1;
    localparam logic [2:0] BT_JALR = 3'd2;
    localparam logic [2:0] BT_CALL = 3'd3;
    localparam logic [2:0] BT_RET  = 3'd4;

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

    function automatic logic br_op_is_cond(input br_op_e op);
        begin
            case (op)
                BR_EQ, BR_NE, BR_LT, BR_GE, BR_LTU, BR_GEU:
                    br_op_is_cond = 1'b1;
                default:
                    br_op_is_cond = 1'b0;
            endcase
        end
    endfunction

    function automatic logic [2:0] bpu_type_from_iq(input iq_entry_t issue);
        begin
            case (issue.br_op)
                BR_JAL:
                    bpu_type_from_iq =
                        (issue.bp_ras_op == RAS_PUSH) ? BT_CALL : BT_JAL;
                BR_JALR:
                    bpu_type_from_iq =
                        (issue.bp_ras_op == RAS_POP)  ? BT_RET  :
                        (issue.bp_ras_op == RAS_PUSH) ? BT_CALL : BT_JALR;
                default:
                    bpu_type_from_iq = BT_COND;
            endcase
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
                rob_checkpoint_tail[i] <= '0;
            end
        end else begin
            if (flush_out.valid && !flush_out.full_flush) begin
                for (int i = 0; i < ROB_DEPTH; i++) begin
                    if (rename_buf_partial_clear[i]) begin
                        rename_buf[i]          <= '0;
                        rob_uses_checkpoint[i] <= 1'b0;
                        rob_checkpoint_id[i]   <= '0;
                        rob_checkpoint_tail[i] <= '0;
                    end
                end
                if (bru_partial_recovery_valid) begin
                    rob_uses_checkpoint[partial_recovered_rob_idx] <= 1'b0;
                    rob_checkpoint_id[partial_recovered_rob_idx]   <= '0;
                    rob_checkpoint_tail[partial_recovered_rob_idx] <= '0;
                end
            end
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                if (3'(i) < ren_count_w) begin
                    rename_buf[ren_insn[i].rob_idx].pdst     <= ren_insn[i].pdst;
                    rename_buf[ren_insn[i].rob_idx].old_pdst <= ren_insn[i].old_pdst;
                    rename_buf[ren_insn[i].rob_idx].rd_arch  <= ren_insn[i].base.rd_arch;
                    rename_buf[ren_insn[i].rob_idx].rd_valid <= ren_insn[i].base.rd_valid;
                    rename_buf[ren_insn[i].rob_idx].rd_is_fp <= ren_insn[i].base.rd_is_fp;
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
                    rob_checkpoint_tail[ren_insn[i].rob_idx] <= ren_insn[i].rob_idx;
                end
            end
        end
    end

    // Extract commit data
    always_comb begin
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            commit_old_pdst[i] = commit_out[i].old_pdst;
            commit_rd_valid[i] = commit_out[i].rd_valid;
            commit_is_fp_dst[i] = rb_head_rd_is_fp[i];
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
    logic [PIPE_WIDTH-1:0]  rob_alloc_is_fused;
    logic [PIPE_WIDTH-1:0]  rob_alloc_is_fp_instr;
    logic [PIPE_WIDTH-1:0]  rob_alloc_has_exception;
    logic [3:0]             rob_alloc_exc_code [0:PIPE_WIDTH-1];
    // Per-uop FU-type tags driven into the ROB to support sub-classification
    // of the SIMULATION-only "other" head-stall bucket (mul/div/bru).
    logic [PIPE_WIDTH-1:0]  rob_alloc_is_mul;
    logic [PIPE_WIDTH-1:0]  rob_alloc_is_div;
    logic [PIPE_WIDTH-1:0]  rob_alloc_is_bru;
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
            rob_alloc_is_fused[i]    = ren_insn[i].base.is_fused;
            rob_alloc_is_fp_instr[i] = ren_insn[i].base.is_fp_op;
            rob_alloc_has_exception[i] = ren_insn[i].base.has_exception;
            rob_alloc_exc_code[i]      = ren_insn[i].base.exc_code;
            rob_alloc_is_mul[i]      = ren_insn[i].base.is_mul;
            rob_alloc_is_div[i]      = ren_insn[i].base.is_div;
            rob_alloc_is_bru[i]      = (ren_insn[i].base.fu_type == FU_BRU);
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
    logic                     rob_sideband_exc_valid;
    logic [ROB_IDX_BITS-1:0]  rob_sideband_exc_rob_idx;
    logic [3:0]               rob_sideband_exc_code;
    logic [63:0]              rob_sideband_exc_tval;
    // LSU-driven per-port load issue suppression (consumed by the load IQ
    // before the LSU instantiation below).
    logic [1:0]               lsu_load_issue_suppress_raw;
    logic [1:0]               lsu_load_issue_suppress;
    logic [0:0]               lsu_sta_issue_suppress;
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
        .alloc_ready_now        (rob_alloc_ready_now),
        .alloc_has_exception    (rob_alloc_has_exception),
        .alloc_exc_code         (rob_alloc_exc_code),
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
        .alloc_is_fused         (rob_alloc_is_fused),
        .alloc_is_fp_instr      (rob_alloc_is_fp_instr),
        .alloc_is_mul           (rob_alloc_is_mul),
        .alloc_is_div           (rob_alloc_is_div),
        .alloc_is_bru           (rob_alloc_is_bru),
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
        .wb_fp_fflags_valid     (cdb_fp_fflags_valid_r),
        .wb_fp_fflags           (cdb_fp_fflags_r),
        .sta_wb_valid           (lsu_sta_wb_valid_r),
        .sta_wb_rob_idx         (lsu_sta_wb_rob_idx_r),
        .std_wb_valid           (lsu_std_wb_valid_r),
        .std_wb_rob_idx         (lsu_std_wb_rob_idx_r),
        .load_wb_valid_r        (load_wb_valid_r),
        .load_wb_idx_r          (load_wb_rob_idx_r),
        .load_wb_has_exception_r (load_wb_has_exception_r),
        .load_wb_exc_code_r     (load_wb_exc_code_r),
        .sideband_exc_valid     (rob_sideband_exc_valid),
        .sideband_exc_rob_idx   (rob_sideband_exc_rob_idx),
        .sideband_exc_code      (rob_sideband_exc_code),
        .sideband_exc_tval      (rob_sideband_exc_tval),
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
        .head_exc_tval          (rob_head_exc_tval),
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
        .head_is_fused          (rob_head_is_fused),
        .head_is_fp_instr       (rob_head_is_fp_instr),
        .head_branch_taken      (rob_head_branch_taken),
        .head_branch_target     (rob_head_branch_target),
        .head_branch_taken_target (rob_head_branch_taken_target),
        .head_branch_mispredict (rob_head_branch_mispredict),
        .head_csr_addr          (rob_head_csr_addr),
        .head_csr_wdata         (rob_head_csr_wdata),
        .head_csr_we            (rob_head_csr_we),
        .head_csr_op            (rob_head_csr_op),
        .head_fp_fflags         (rob_head_fp_fflags),
        .commit_count           (commit_count),
        .flush_valid            (flush_out.valid),
        .flush_rob_tail         (flush_out.rob_idx),
        .flush_full             (flush_out.full_flush),
        .flush_clear_branch_mispredict(bru_partial_recovery_valid),
        .tail_idx               (rob_tail_idx),
        .free_count_o           (rob_free_count),
        .empty                  (rob_empty),
        .full                   (rob_full)
    );

    // =========================================================================
    // 6. DISPATCH QUEUE
    // =========================================================================
    logic [2:0]    dq_enq_count;
    renamed_insn_t dq_enq_data [0:PIPE_WIDTH-1];
    logic [2:0]    dq_deq_count;
    renamed_insn_t dq_deq_data [0:PIPE_WIDTH-1];
    logic [1:0]    dq_deq_iq_target [0:PIPE_WIDTH-1];
    logic [NUM_INT_IQS-1:0] iq_full_vec;

    // Per-IQ occupancy forward-declared here (IQ modules are instantiated
    // further below; dispatch routing needs the values earlier).
    logic [$clog2(IQ_INT_DEPTH+1)-1:0] iq0_occ;
    logic [$clog2(IQ_INT_DEPTH+1)-1:0] iq1_occ;
    logic [$clog2(IQ_INT_DEPTH+1)-1:0] iq2_occ;
    logic [$clog2(IQ_MEM_DEPTH+1)-1:0] iq_load_occ;
    logic [$clog2(IQ_MEM_DEPTH+1)-1:0] iq_store_occ;
    logic [$clog2(IQ_MEM_DEPTH+1)-1:0] iq_std_occ;
    logic [1:0] dq_load_iq_credit;
    logic [1:0] dq_store_iq_credit;

    // Pack per-IQ occupancy into an array for dispatch routing.
    logic [5:0] iq_occ_vec [0:NUM_INT_IQS-1];
    assign iq_occ_vec[0] = 6'(iq0_occ);
    assign iq_occ_vec[1] = 6'(iq1_occ);
    assign iq_occ_vec[2] = 6'(iq2_occ);

    function automatic logic [1:0] cap_mem_free2(input logic [5:0] occ);
        int free_slots;
        begin
            free_slots = IQ_MEM_DEPTH - int'(occ);
            if (free_slots <= 0)
                cap_mem_free2 = 2'd0;
            else if (free_slots == 1)
                cap_mem_free2 = 2'd1;
            else
                cap_mem_free2 = 2'd2;
        end
    endfunction

    assign dq_load_iq_credit = cap_mem_free2(6'(iq_load_occ));
    assign dq_store_iq_credit =
        (cap_mem_free2(6'(iq_store_occ)) < cap_mem_free2(6'(iq_std_occ)))
            ? cap_mem_free2(6'(iq_store_occ))
            : cap_mem_free2(6'(iq_std_occ));

    // Rename still allocates a ROB entry for eliminated uops so commit/minstret
    // stays precise, but they are already complete and need no IQ/FU work.
    always_comb begin
        dq_enq_count = 3'd0;
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            dq_enq_data[i] = '0;
        end

        for (int i = 0; i < PIPE_WIDTH; i++) begin
            if ((3'(i) < ren_count_w) &&
                !ren_eliminated[i] &&
                !ren_insn[i].base.has_exception) begin
                dq_enq_data[dq_enq_count] = ren_insn[i];
                dq_enq_count = dq_enq_count + 3'd1;
            end
        end
    end

    dispatch_queue u_dispatch_queue (
        .clk         (clk),
        .rst_n       (rst_n),
        .enq_count   (dq_enq_count),
        .enq_data    (dq_enq_data),
        .full        (dq_full),
        .deq_count   (dq_deq_count),
        .deq_data    (dq_deq_data),
        .deq_iq_target(dq_deq_iq_target),
        .iq_full     (iq_full_vec),
        .iq_occ      (iq_occ_vec),
        .load_iq_credit(dq_load_iq_credit),
        .store_iq_credit(dq_store_iq_credit),
        .flush_valid (flush_out.valid),
        .flush_full  (flush_out.full_flush),
        .flush_rob_tail(flush_out.rob_idx),
        .rob_head    (rob_head_idx)
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

    // --- IQ2: ALU3 + DIV + CSR + serialized FPU ---
    logic [1:0]  iq2_enq_valid;
    iq_entry_t   iq2_enq_data [0:1];
    logic        iq2_full;
    // iq2_occ declared earlier (before dispatch_queue)
    logic [1:0]  iq2_issue_valid;
    iq_entry_t   iq2_issue_data [0:1];
    // Single-issue wrapper signals for IQ2 (NUM_SELECT=1)
    logic [0:0]  iq2_issue_candidate_valid_s;
    logic [0:0]  iq2_issue_valid_s;
    iq_entry_t   iq2_issue_data_s [0:0];
    logic [0:0]  iq2_issue_suppress_s;
    logic        fpu_ready;
    logic        fpu_req_valid_r;
    logic        fpu_out_valid;
    logic        fpu_unsupported;
    logic        div_busy;
    logic        div_valid_out;
    logic        div_hold_valid_r;
    logic [2:0]  csr_frm;

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
    logic [0:0]  iq_store_issue_candidate_valid_s;
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

    assign lsu_load_issue_suppress =
        lsu_load_issue_suppress_raw | store_iq_older_than_load;

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
            dq_iq_entry[s].rs3_phys     = dq_deq_data[s].rs3_phys;
            dq_iq_entry[s].rs1_ready    = dq_deq_data[s].rs1_ready;
            dq_iq_entry[s].rs2_ready    = dq_deq_data[s].rs2_ready;
            dq_iq_entry[s].rs3_ready    = dq_deq_data[s].rs3_ready;
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
            dq_iq_entry[s].bp_ras_top   = dq_deq_data[s].base.bp_ras_top;
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
            dq_iq_entry[s].is_fp_op     = dq_deq_data[s].base.is_fp_op;
            dq_iq_entry[s].rs1_is_fp    = dq_deq_data[s].base.rs1_is_fp;
            dq_iq_entry[s].rs2_is_fp    = dq_deq_data[s].base.rs2_is_fp;
            dq_iq_entry[s].rs3_is_fp    = dq_deq_data[s].base.rs3_is_fp;
            dq_iq_entry[s].rd_is_fp     = dq_deq_data[s].base.rd_is_fp;
            dq_iq_entry[s].fp_fmt       = dq_deq_data[s].base.fp_fmt;
            dq_iq_entry[s].fp_dst_fmt   = dq_deq_data[s].base.fp_dst_fmt;
            dq_iq_entry[s].fp_int_fmt   = dq_deq_data[s].base.fp_int_fmt;
            dq_iq_entry[s].fp_rm        = dq_deq_data[s].base.fp_rm;
            dq_iq_entry[s].fp_pipe      = dq_deq_data[s].base.fp_pipe;
            dq_iq_entry[s].fp_op        = dq_deq_data[s].base.fp_op;
            dq_iq_entry[s].fp_op_mod    = dq_deq_data[s].base.fp_op_mod;
            dq_iq_entry[s].fp_misc_op   = dq_deq_data[s].base.fp_misc_op;
            dq_iq_entry[s].fmv_op       = dq_deq_data[s].base.fmv_op;
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
                  .SUPPORT_ENQ_ISSUE_BYPASS(1),
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
        .spec_wk_valid1  (lsu_spec_wakeup_valid[1]),
        .spec_wk_tag1    (lsu_spec_wakeup_tag[1]),
        .spec_cancel_valid(lsu_spec_cancel_valid[0]),
        .spec_cancel_tag (lsu_spec_cancel_tag[0]),
        .spec_cancel_valid1(lsu_spec_cancel_valid[1]),
        .spec_cancel_tag1(lsu_spec_cancel_tag[1]),
        .load_wb_wk_valid0(load_wb_valid_live[0] && (load_wb_pdst[0] != '0)),
        .load_wb_wk_tag0  (load_wb_pdst[0]),
        .load_wb_wk_valid1(load_wb_valid_live[1] && (load_wb_pdst[1] != '0)),
        .load_wb_wk_tag1  (load_wb_pdst[1]),
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
        .enq_issue_bypass_enable(iq_ready_enq_bypass_enable),
        .enq_issue_bypass_alu_only(iq_ready_enq_bypass_alu_only),
        .occupancy       (iq0_occ)
    );

    // IQ1 and IQ2 are single-issue: only port 0 is wired to ALU2/MUL and
    // ALU3/DIV/CSR respectively.  NUM_SELECT=1 prevents the IQ from
    // retiring entries on port 1 that no functional unit executes
    // (which would cause the ROB to fill up with orphaned entries).
    issue_queue #(.DEPTH(IQ_INT_DEPTH), .NUM_ENQUEUE(2), .NUM_SELECT(1),
                  .SUPPORT_ENQ_ISSUE_BYPASS(1))
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
        .spec_wk_valid1  (lsu_spec_wakeup_valid[1]),
        .spec_wk_tag1    (lsu_spec_wakeup_tag[1]),
        .spec_cancel_valid(lsu_spec_cancel_valid[0]),
        .spec_cancel_tag (lsu_spec_cancel_tag[0]),
        .spec_cancel_valid1(lsu_spec_cancel_valid[1]),
        .spec_cancel_tag1(lsu_spec_cancel_tag[1]),
        .load_wb_wk_valid0(load_wb_valid_live[0] && (load_wb_pdst[0] != '0)),
        .load_wb_wk_tag0  (load_wb_pdst[0]),
        .load_wb_wk_valid1(load_wb_valid_live[1] && (load_wb_pdst[1] != '0)),
        .load_wb_wk_tag1  (load_wb_pdst[1]),
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
        .enq_issue_bypass_enable(iq_ready_enq_bypass_enable),
        .enq_issue_bypass_alu_only(iq_ready_enq_bypass_alu_only),
        .occupancy       (iq1_occ)
    );
    assign iq1_issue_valid[0] = iq1_issue_valid_s[0];
    assign iq1_issue_valid[1] = 1'b0;
    assign iq1_issue_data[0]  = iq1_issue_data_s[0];
    assign iq1_issue_data[1]  = '0;

    // CSR operations read committed CSR state. Keep them resident until
    // their ROB entry reaches the head so older CSR writes are visible.
	    assign iq2_issue_suppress_s[0] =
	        iq2_issue_candidate_valid_s[0] &&
         (((iq2_issue_data_s[0].fu_type == FU_CSR) &&
           (iq2_issue_data_s[0].rob_idx != rob_head_idx)) ||
          ((iq2_issue_data_s[0].fu_type == FU_DIV) &&
           div_busy) ||
          fpu_req_valid_r ||
          fpu_out_valid ||
          div_valid_out ||
          div_hold_valid_r);

    issue_queue #(.DEPTH(IQ_INT_DEPTH), .NUM_ENQUEUE(2), .NUM_SELECT(1),
                  .SUPPORT_ENQ_ISSUE_BYPASS(1))
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
        .spec_wk_valid1  (lsu_spec_wakeup_valid[1]),
        .spec_wk_tag1    (lsu_spec_wakeup_tag[1]),
        .spec_cancel_valid(lsu_spec_cancel_valid[0]),
        .spec_cancel_tag (lsu_spec_cancel_tag[0]),
        .spec_cancel_valid1(lsu_spec_cancel_valid[1]),
        .spec_cancel_tag1(lsu_spec_cancel_tag[1]),
        .load_wb_wk_valid0(load_wb_valid_live[0] && (load_wb_pdst[0] != '0)),
        .load_wb_wk_tag0  (load_wb_pdst[0]),
        .load_wb_wk_valid1(load_wb_valid_live[1] && (load_wb_pdst[1] != '0)),
        .load_wb_wk_tag1  (load_wb_pdst[1]),
        .preg_ready_table(preg_ready_table_comb),
        .issue_candidate_valid(iq2_issue_candidate_valid_s),
        .issue_valid     (iq2_issue_valid_s),
        .issue_data      (iq2_issue_data_s),
        .older_probe_valid(issueq_probe_none_valid),
        .older_probe_rob_idx(issueq_probe_none_rob_idx),
        .has_older_entry (),
        .rob_head        (rob_head_idx),
        .flush_valid     (flush_out.valid),
        .flush_rob_tail  (flush_out.rob_idx),
        .flush_full      (flush_out.full_flush),
        .issue_suppress  (iq2_issue_suppress_s),
        .enq_issue_bypass_enable(1'b0),
        .enq_issue_bypass_alu_only(iq_ready_enq_bypass_alu_only),
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
        .spec_wk_valid1  (lsu_spec_wakeup_valid[1]),
        .spec_wk_tag1    (lsu_spec_wakeup_tag[1]),
        .spec_cancel_valid(lsu_spec_cancel_valid[0]),
        .spec_cancel_tag (lsu_spec_cancel_tag[0]),
        .spec_cancel_valid1(lsu_spec_cancel_valid[1]),
        .spec_cancel_tag1(lsu_spec_cancel_tag[1]),
        .load_wb_wk_valid0(load_wb_valid_live[0] && (load_wb_pdst[0] != '0)),
        .load_wb_wk_tag0  (load_wb_pdst[0]),
        .load_wb_wk_valid1(load_wb_valid_live[1] && (load_wb_pdst[1] != '0)),
        .load_wb_wk_tag1  (load_wb_pdst[1]),
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
        .enq_issue_bypass_enable(1'b0),
        .enq_issue_bypass_alu_only(1'b0),
        .occupancy       (iq_load_occ)
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
        .spec_wk_valid1  (lsu_spec_wakeup_valid[1]),
        .spec_wk_tag1    (lsu_spec_wakeup_tag[1]),
        .spec_cancel_valid(lsu_spec_cancel_valid[0]),
        .spec_cancel_tag (lsu_spec_cancel_tag[0]),
        .spec_cancel_valid1(lsu_spec_cancel_valid[1]),
        .spec_cancel_tag1(lsu_spec_cancel_tag[1]),
        .load_wb_wk_valid0(load_wb_valid_live[0] && (load_wb_pdst[0] != '0)),
        .load_wb_wk_tag0  (load_wb_pdst[0]),
        .load_wb_wk_valid1(load_wb_valid_live[1] && (load_wb_pdst[1] != '0)),
        .load_wb_wk_tag1  (load_wb_pdst[1]),
        .preg_ready_table(preg_ready_table_comb),
        .issue_candidate_valid(iq_store_issue_candidate_valid_s),
        .issue_valid     (iq_store_issue_valid_s),
        .issue_data      (iq_store_issue_data_s),
        .older_probe_valid(iq_load_issue_candidate_valid),
        .older_probe_rob_idx(store_iq_load_probe_rob_idx),
        .has_older_entry (store_iq_older_than_load),
        .rob_head        (rob_head_idx),
        .flush_valid     (flush_out.valid),
        .flush_rob_tail  (flush_out.rob_idx),
        .flush_full      (flush_out.full_flush),
        .issue_suppress  (lsu_sta_issue_suppress),
        .enq_issue_bypass_enable(1'b0),
        .enq_issue_bypass_alu_only(1'b0),
        .occupancy       (iq_store_occ)
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
        .spec_wk_valid1  (lsu_spec_wakeup_valid[1]),
        .spec_wk_tag1    (lsu_spec_wakeup_tag[1]),
        .spec_cancel_valid(lsu_spec_cancel_valid[0]),
        .spec_cancel_tag (lsu_spec_cancel_tag[0]),
        .spec_cancel_valid1(lsu_spec_cancel_valid[1]),
        .spec_cancel_tag1(lsu_spec_cancel_tag[1]),
        .load_wb_wk_valid0(load_wb_valid_live[0] && (load_wb_pdst[0] != '0)),
        .load_wb_wk_tag0  (load_wb_pdst[0]),
        .load_wb_wk_valid1(load_wb_valid_live[1] && (load_wb_pdst[1] != '0)),
        .load_wb_wk_tag1  (load_wb_pdst[1]),
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
        .enq_issue_bypass_enable(1'b0),
        .enq_issue_bypass_alu_only(1'b0),
        .occupancy       (iq_std_occ)
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
    // 12 read ports: 4 IQ pairs × 2 operands + 2 load AGU + 2 store (AGU+data)
    // 6 write ports: CDB[0:3] (ALU/MUL/DIV/CSR) + 2 load writeback
    //   PRF_WRITE_PORTS=6 is kept independent of CDB_WIDTH=4 because:
    //   - The CDB_WIDTH=4 broadcast covers ALU0/BRU, ALU1/BRU1, ALU2/MUL,
    //     ALU3/DIV/CSR (wakeup broadcast reduced to 4 tags/cycle).
    //   - Load0 and Load1 writeback through separate prf_wen[4:5] signals
    //     (loads use speculative wakeup, not the main CDB broadcast path).
    //   - Read count: IQ0×2+IQ1×1+IQ2×1=4 FU slots × 2 srcs=8R for ALU/BRU,
    //     plus 2 load AGU reads + STA rs1 + STD rs2 = 12R structurally required.
    //   Planning-doc target of 8R was incorrect; 12R kept to avoid port starvation.
    // =========================================================================
    logic [PHYS_REG_BITS-1:0] prf_raddr [0:11];
    logic [PHYS_REG_BITS-1:0] int_prf_raddr [0:11];
    logic [63:0]              prf_rdata [0:11];
    logic [PRF_WRITE_PORTS-1:0] prf_wen;
    logic [PHYS_REG_BITS-1:0] prf_waddr [0:PRF_WRITE_PORTS-1];
    logic [63:0]              prf_wdata [0:PRF_WRITE_PORTS-1];
    logic [6:0]               fp_prf_raddr [0:7];
    logic [63:0]              fp_prf_rdata [0:7];
    logic [3:0]               fp_prf_wen;
    logic [6:0]               fp_prf_waddr [0:3];
    logic [63:0]              fp_prf_wdata [0:3];

    always_comb begin
        for (int i = 0; i < 12; i++) begin
            if (prf_raddr[i] >= PHYS_REG_BITS'(FP_PHYS_BASE))
                int_prf_raddr[i] = '0;
            else
                int_prf_raddr[i] = prf_raddr[i];
        end
    end

    int_prf u_int_prf (
        .clk   (clk),
        .rst_n (rst_n),
        .raddr (int_prf_raddr),
        .rdata (prf_rdata),
        .wen   (prf_wen),
        .waddr (prf_waddr),
        .wdata (prf_wdata)
    );

    fp_prf u_fp_prf (
        .clk     (clk),
        .rd_addr (fp_prf_raddr),
        .rd_data (fp_prf_rdata),
        .wr_en   (fp_prf_wen),
        .wr_addr (fp_prf_waddr),
        .wr_data (fp_prf_wdata)
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
    // Load IQ -> Load AGU rs1 x2.  AMO on load port 0 borrows the
    // port-1 read slot for rs2; LSU suppresses load port 1 in that cycle.
    assign prf_raddr[8]  = iq_load_issue_data[0].rs1_phys;
    assign prf_raddr[9]  = iq_load_issue_data[0].is_amo
                          ? iq_load_issue_data[0].rs2_phys
                          : iq_load_issue_data[1].rs1_phys;
    // Store IQ -> STA rs1, STD rs2 (routed by fu_type)
    assign prf_raddr[10] = routed_sta_data.rs1_phys;
    assign prf_raddr[11] = routed_std_data.rs2_phys;

    always_comb begin
        for (int i = 0; i < 8; i++) begin
            fp_prf_raddr[i] = 7'd0;
        end
        if (iq2_issue_data[0].rs1_is_fp)
            fp_prf_raddr[0] =
                7'(iq2_issue_data[0].rs1_phys - PHYS_REG_BITS'(FP_PHYS_BASE));
        if (iq2_issue_data[0].rs2_is_fp)
            fp_prf_raddr[1] =
                7'(iq2_issue_data[0].rs2_phys - PHYS_REG_BITS'(FP_PHYS_BASE));
        if (iq2_issue_data[0].rs3_is_fp)
            fp_prf_raddr[2] =
                7'(iq2_issue_data[0].rs3_phys - PHYS_REG_BITS'(FP_PHYS_BASE));
        if (routed_std_data.rs2_is_fp)
            fp_prf_raddr[3] =
                7'(routed_std_data.rs2_phys - PHYS_REG_BITS'(FP_PHYS_BASE));
    end

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
        .is_unsigned(iq0_issue_data[0].is_unsigned),
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
        .is_unsigned(iq0_issue_data[1].is_unsigned),
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
        .is_unsigned(iq1_issue_data[0].is_unsigned),
        .result    (alu2_result)
    );

    // ALU3 (IQ2 port 0)
    logic [63:0] alu3_result;
    logic [63:0] alu3_op_a, alu3_op_b;
    logic [11:0] csr_read_addr;
    logic [63:0] csr_read_data;
    logic [63:0] csr_exec_wdata;
    assign alu3_op_a = (iq2_issue_data[0].use_imm && (iq2_issue_data[0].alu_op == ALU_PASS2))
                       ? iq2_issue_data[0].pc : bypassed_data[6];
    assign alu3_op_b = iq2_issue_data[0].use_imm ? iq2_issue_data[0].imm : bypassed_data[7];
    assign csr_read_addr =
        (iq2_issue_valid[0] && (iq2_issue_data[0].fu_type == FU_CSR))
            ? iq2_issue_data[0].csr_addr
            : 12'd0;
    assign csr_exec_wdata =
        iq2_issue_data[0].use_imm ? iq2_issue_data[0].imm : bypassed_data[6];

    alu u_alu3 (
        .operand_a (alu3_op_a),
        .operand_b (alu3_op_b),
        .op        (iq2_issue_data[0].alu_op),
        .is_w_op   (iq2_issue_data[0].is_w_op),
        .is_unsigned(iq2_issue_data[0].is_unsigned),
        .result    (alu3_result)
    );

    // =========================================================================
	    // 10a. FPU (serialized on IQ2 port 0)
	    // =========================================================================
	    logic        fpu_issue;
	    logic        fpu_valid_in;
	    iq_entry_t   fpu_req_data_r;
	    logic [63:0] fpu_req_rs1_data_r;
	    logic [63:0] fpu_req_rs2_data_r;
	    logic [63:0] fpu_req_rs3_data_r;
	    fp_rm_e      fpu_req_rm_r;
	    logic [63:0] fpu_issue_rs1_data;
	    logic [63:0] fpu_issue_rs2_data;
	    logic [63:0] fpu_issue_rs3_data;
	    fp_rm_e      fpu_issue_rm;
	    logic [63:0] fpu_rs1_data;
	    logic [63:0] fpu_rs2_data;
	    logic [63:0] fpu_rs3_data;
	    logic [ROB_IDX_BITS-1:0]  fpu_out_rob_idx;
	    logic [PHYS_REG_BITS-1:0] fpu_out_pdst;
	    logic [63:0] fpu_out_data;
	    fp_status_t  fpu_out_status;

	    assign fpu_issue =
	        iq2_issue_valid[0] && iq2_issue_data[0].is_fp_op;
	    assign fpu_valid_in = fpu_req_valid_r;
	    assign fpu_issue_rs1_data =
	        iq2_issue_data[0].rs1_is_fp ? fp_prf_rdata[0] : bypassed_data[6];
	    assign fpu_issue_rs2_data =
	        iq2_issue_data[0].rs2_is_fp ? fp_prf_rdata[1] : bypassed_data[7];
	    assign fpu_issue_rs3_data =
	        iq2_issue_data[0].rs3_is_fp ? fp_prf_rdata[2] : 64'd0;
	    assign fpu_rs1_data = fpu_req_rs1_data_r;
	    assign fpu_rs2_data = fpu_req_rs2_data_r;
	    assign fpu_rs3_data = fpu_req_rs3_data_r;

	    always_comb begin
	        if (iq2_issue_data[0].fp_rm == FP_RM_DYN) begin
	            case (csr_frm)
	                3'd0:    fpu_issue_rm = FP_RM_RNE;
	                3'd1:    fpu_issue_rm = FP_RM_RTZ;
	                3'd2:    fpu_issue_rm = FP_RM_RDN;
	                3'd3:    fpu_issue_rm = FP_RM_RUP;
	                3'd4:    fpu_issue_rm = FP_RM_RMM;
	                default: fpu_issue_rm = FP_RM_DYN;
	            endcase
	        end else begin
	            fpu_issue_rm = iq2_issue_data[0].fp_rm;
	        end
	    end

	    always_ff @(posedge clk or negedge rst_n) begin
	        if (!rst_n || flush_out.valid) begin
	            fpu_req_valid_r    <= 1'b0;
	            fpu_req_data_r     <= '0;
	            fpu_req_rs1_data_r <= 64'd0;
	            fpu_req_rs2_data_r <= 64'd0;
	            fpu_req_rs3_data_r <= 64'd0;
	            fpu_req_rm_r       <= FP_RM_RNE;
	        end else begin
	            if (fpu_req_valid_r && fpu_ready)
	                fpu_req_valid_r <= 1'b0;

	            if (fpu_issue) begin
	                fpu_req_valid_r    <= 1'b1;
	                fpu_req_data_r     <= iq2_issue_data[0];
	                fpu_req_rs1_data_r <= fpu_issue_rs1_data;
	                fpu_req_rs2_data_r <= fpu_issue_rs2_data;
	                fpu_req_rs3_data_r <= fpu_issue_rs3_data;
	                fpu_req_rm_r       <= fpu_issue_rm;
	            end
	        end
	    end

	    fpu_top u_fpu_top (
	        .clk_i        (clk),
	        .rst_ni       (rst_n),
	        .flush_i      (flush_out.valid),
	        .valid_i      (fpu_valid_in),
	        .use_fpnew_i  (1'b1),
	        .pipe_i       (fpu_req_data_r.fp_pipe),
	        .op_i         (fpu_req_data_r.fp_op),
	        .op_mod_i     (fpu_req_data_r.fp_op_mod),
	        .misc_op_i    (fpu_req_data_r.fp_misc_op),
	        .fmv_op_i     (fpu_req_data_r.fmv_op),
	        .src_fmt_i    (fpu_req_data_r.fp_fmt),
	        .dst_fmt_i    (fpu_req_data_r.fp_dst_fmt),
	        .int_fmt_i    (fpu_req_data_r.fp_int_fmt),
	        .rm_i         (fpu_req_rm_r),
	        .rs1_data_i   (fpu_rs1_data),
	        .rs2_data_i   (fpu_rs2_data),
	        .rs3_data_i   (fpu_rs3_data),
	        .rob_idx_i    (fpu_req_data_r.rob_idx),
	        .pdst_i       (fpu_req_data_r.pdst),
	        .ready_o      (fpu_ready),
	        .out_valid_o  (fpu_out_valid),
	        .out_rob_idx_o(fpu_out_rob_idx),
        .out_pdst_o   (fpu_out_pdst),
        .out_data_o   (fpu_out_data),
        .out_status_o (fpu_out_status),
        .unsupported_o(fpu_unsupported)
    );

    // =========================================================================
    // 11. BRU (shared with ALU0 on IQ0 port 0)
    // =========================================================================
    logic [63:0] bru_result;
    logic        bru_taken;
    // bru_target declared earlier (forward decl for fetch_top port)
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
        .fused_imm   (iq0_issue_data[0].fused_imm),
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
        .fused_imm   (iq0_issue_data[1].fused_imm),
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
    // BRU0 is the oldest branch issue slot; BRU1 is the second-oldest issue
    // slot.  Allow either resolved mispredict to restart fetch immediately,
    // choosing BRU0 if both mispredict in the same cycle.
    // Once an execute-time redirect is pending, rename is quarantined until
    // commit performs the architectural flush. Suppress nested BRU redirects in
    // that window so younger wrong-path branches cannot keep restarting fetch.
    // This path is opt-in because CoreMark exposes a correctness hazard in the
    // current fetch-only recovery contract; commit-time flush remains the safe
    // default until backend recovery is completed.
    assign bru0_early_redirect =
        sim_bru0_early_redirect_en &&
        !bru_redirect_quarantine_r && !commit_flush.valid &&
        bru_issue && bru_mispredict;
    assign bru1_early_redirect =
        sim_bru1_early_redirect_en &&
        !bru0_early_redirect &&
        !bru_redirect_quarantine_r && !commit_flush.valid &&
        bru1_issue && bru1_mispredict;
    assign bru_early_redirect  = bru0_early_redirect || bru1_early_redirect;
    assign bru_early_target    = bru0_early_redirect ? bru_target : bru1_target;
    assign branch_recovery_burst_ready =
        (selective_recovery_cooldown_r == '0);
    assign selective_branch_recovery_resource_ok =
        rename_recovery_headroom_ok &&
        frontend_recovery_headroom_ok &&
        branch_recovery_burst_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            selective_recovery_cooldown_r <= '0;
        end else if (sim_selective_branch_recovery &&
                     bru_partial_recovery_valid) begin
            selective_recovery_cooldown_r <=
                SELECTIVE_RECOVERY_COOLDOWN_BITS'(SELECTIVE_RECOVERY_COOLDOWN_CYCLES);
        end else if (selective_recovery_cooldown_r != '0) begin
            selective_recovery_cooldown_r <= selective_recovery_cooldown_r - 1'b1;
        end
    end

    always_comb begin
        bru_partial_candidate_from_cdb1 = 1'b0;
        bru_partial_candidate_rob_idx   = cdb_rob_idx_r[0];
        if (cdb_valid_r[0] && cdb_is_branch_r[0] &&
            cdb_branch_mispredict_r[0]) begin
            bru_partial_candidate_rob_idx = cdb_rob_idx_r[0];
        end else if (cdb_valid_r[1] && cdb_is_branch_r[1] &&
                     cdb_branch_mispredict_r[1]) begin
            bru_partial_candidate_from_cdb1 = 1'b1;
            bru_partial_candidate_rob_idx   = cdb_rob_idx_r[1];
        end

        bru_partial_cdb_mispredict_valid =
            ((cdb_valid_r[0] && cdb_is_branch_r[0] &&
              cdb_branch_mispredict_r[0]) ||
             (cdb_valid_r[1] && cdb_is_branch_r[1] &&
              cdb_branch_mispredict_r[1]));

        bru_partial_candidate_valid =
            !commit_flush.valid &&
            !rename_stall &&
            // Partial recovery must not suppress the later commit flush while
            // UOP-cache replay is active; that full flush is the safety valve
            // that breaks stale speculative hot-loop paths.
            !uoc_active &&
            bru_partial_cdb_mispredict_valid &&
            !rename_buf[bru_partial_candidate_rob_idx].rd_valid &&
            rob_uses_checkpoint[bru_partial_candidate_rob_idx] &&
            (rob_checkpoint_tail[bru_partial_candidate_rob_idx] ==
             bru_partial_candidate_rob_idx);

        bru_partial_recovery_valid =
            bru_partial_candidate_valid &&
            (sim_exec_partial_branch_recovery ||
             (sim_selective_branch_recovery &&
              selective_branch_recovery_resource_ok));

        bru_flush = '0;
        if (bru_partial_recovery_valid) begin
            bru_flush.valid         = 1'b1;
            bru_flush.full_flush    = 1'b0;
            bru_flush.redirect_pc   = bru_partial_candidate_from_cdb1
                                      ? cdb_branch_target_r[1]
                                      : cdb_branch_target_r[0];
            bru_flush.checkpoint_id =
                rob_checkpoint_id[bru_partial_candidate_rob_idx];
            bru_flush.ras_tos       = ras_tos_after_redirect(
                rename_buf[bru_partial_candidate_rob_idx].bp_ras_tos,
                rename_buf[bru_partial_candidate_rob_idx].bp_ras_op
            );
            if ((rename_buf[bru_partial_candidate_rob_idx].bp_ras_op == RAS_NONE) &&
                (rename_buf[bru_partial_candidate_rob_idx].bp_ras_tos != 5'd0)) begin
                bru_flush.ras_top_restore_valid = 1'b1;
                bru_flush.ras_top_restore_addr  =
                    rename_buf[bru_partial_candidate_rob_idx].bp_ras_top;
            end
            bru_flush.ghr_restore_valid = 1'b1;
            bru_flush.ghr_restore_val =
                {rename_buf[bru_partial_candidate_rob_idx].bp_ghr[GHR_BITS-2:0],
                 bru_partial_candidate_from_cdb1 ? cdb_branch_taken_r[1]
                                                 : cdb_branch_taken_r[0]};
            if (bru_partial_candidate_rob_idx == ROB_IDX_BITS'(ROB_DEPTH - 1))
                bru_flush.rob_idx = '0;
            else
                bru_flush.rob_idx = bru_partial_candidate_rob_idx + 1'b1;
        end
    end

`ifdef SIMULATION
    logic sim_branch_opportunity_en;
    logic [CDB_WIDTH-1:0] sim_a0_cdb_mispredict_slot;
    logic [2:0] sim_a0_candidate_type_c;
    logic [ROB_IDX_BITS:0] sim_a0_candidate_age_c;
    logic [ROB_IDX_BITS:0] sim_a0_entry_age_c [0:ROB_DEPTH-1];
    logic [ROB_IDX_BITS:0] sim_a0_rob_occ_c;
    logic [ROB_IDX_BITS:0] sim_a0_younger_count_c;
    integer sim_a0_ready_younger_count_c;
    integer sim_a0_cdb_mispredict_cycles;
    integer sim_a0_cdb_mispredict_slots;
    integer sim_a0_type_cond;
    integer sim_a0_type_jal;
    integer sim_a0_type_jalr;
    integer sim_a0_type_call;
    integer sim_a0_type_ret;
    integer sim_a0_age_head;
    integer sim_a0_age_near;
    integer sim_a0_age_mid;
    integer sim_a0_age_far;
    integer sim_a0_age_older;
    integer sim_a0_age_sum;
    integer sim_a0_age_max;
    integer sim_a0_checkpoint_any;
    integer sim_a0_checkpoint_at_branch;
    integer sim_a0_checkpoint_missing;
    integer sim_a0_side_effect;
    integer sim_a0_partial_candidate;
    integer sim_a0_partial_resource_ok;
    integer sim_a0_reject_commit;
    integer sim_a0_reject_rename;
    integer sim_a0_reject_uoc;
    integer sim_a0_reject_side_effect;
    integer sim_a0_reject_checkpoint;
    integer sim_a0_reject_rename_headroom;
    integer sim_a0_reject_frontend_headroom;
    integer sim_a0_reject_burst;
    integer sim_a0_younger_sum;
    integer sim_a0_younger_ready_sum;
    integer sim_a0_younger_max;
    integer sim_a0_younger_ready_max;
    integer sim_sel_rec_cdb_mispredict;
    integer sim_sel_rec_candidate;
    integer sim_sel_rec_accepted;
    integer sim_sel_rec_reject_commit;
    integer sim_sel_rec_reject_rename;
    integer sim_sel_rec_reject_uoc;
    integer sim_sel_rec_reject_side_effect;
    integer sim_sel_rec_reject_checkpoint;
    integer sim_sel_rec_reject_rename_headroom;
    integer sim_sel_rec_reject_frontend_headroom;
    integer sim_sel_rec_reject_burst;

    initial begin
        sim_branch_opportunity_en =
            $test$plusargs("PERF_PROFILE") ||
            $test$plusargs("STAT_DUMP") ||
            $test$plusargs("TRACE_BRANCH_OPPORTUNITY");
    end

    always_comb begin
        sim_a0_cdb_mispredict_slot = '0;
        for (int i = 0; i < CDB_WIDTH; i++) begin
            sim_a0_cdb_mispredict_slot[i] =
                cdb_valid_r[i] && cdb_is_branch_r[i] &&
                cdb_branch_mispredict_r[i];
        end

        sim_a0_candidate_type_c = u_rob.bpu_type_r[bru_partial_candidate_rob_idx];

        if (bru_partial_candidate_rob_idx >= rob_head_idx) begin
            sim_a0_candidate_age_c =
                {1'b0, bru_partial_candidate_rob_idx} - {1'b0, rob_head_idx};
        end else begin
            sim_a0_candidate_age_c =
                (ROB_IDX_BITS+1)'(ROB_DEPTH) -
                {1'b0, rob_head_idx} + {1'b0, bru_partial_candidate_rob_idx};
        end

        sim_a0_rob_occ_c = (ROB_IDX_BITS+1)'(ROB_DEPTH) - rob_free_count;
        sim_a0_younger_count_c =
            (sim_a0_rob_occ_c > (sim_a0_candidate_age_c + 1'b1))
                ? (sim_a0_rob_occ_c - sim_a0_candidate_age_c - 1'b1)
                : '0;
        sim_a0_ready_younger_count_c = 0;
        for (int i = 0; i < ROB_DEPTH; i++) begin
            if (ROB_IDX_BITS'(i) >= rob_head_idx) begin
                sim_a0_entry_age_c[i] =
                    {1'b0, ROB_IDX_BITS'(i)} - {1'b0, rob_head_idx};
            end else begin
                sim_a0_entry_age_c[i] =
                    (ROB_IDX_BITS+1)'(ROB_DEPTH) -
                    {1'b0, rob_head_idx} + {1'b0, ROB_IDX_BITS'(i)};
            end

            if (u_rob.valid_r[i] &&
                (sim_a0_entry_age_c[i] > sim_a0_candidate_age_c) &&
                (sim_a0_entry_age_c[i] < sim_a0_rob_occ_c) &&
                u_rob.ready_r[i]) begin
                sim_a0_ready_younger_count_c =
                    sim_a0_ready_younger_count_c + 1;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sim_a0_cdb_mispredict_cycles       <= 0;
            sim_a0_cdb_mispredict_slots        <= 0;
            sim_a0_type_cond                   <= 0;
            sim_a0_type_jal                    <= 0;
            sim_a0_type_jalr                   <= 0;
            sim_a0_type_call                   <= 0;
            sim_a0_type_ret                    <= 0;
            sim_a0_age_head                    <= 0;
            sim_a0_age_near                    <= 0;
            sim_a0_age_mid                     <= 0;
            sim_a0_age_far                     <= 0;
            sim_a0_age_older                   <= 0;
            sim_a0_age_sum                     <= 0;
            sim_a0_age_max                     <= 0;
            sim_a0_checkpoint_any              <= 0;
            sim_a0_checkpoint_at_branch        <= 0;
            sim_a0_checkpoint_missing          <= 0;
            sim_a0_side_effect                 <= 0;
            sim_a0_partial_candidate           <= 0;
            sim_a0_partial_resource_ok         <= 0;
            sim_a0_reject_commit               <= 0;
            sim_a0_reject_rename               <= 0;
            sim_a0_reject_uoc                  <= 0;
            sim_a0_reject_side_effect          <= 0;
            sim_a0_reject_checkpoint           <= 0;
            sim_a0_reject_rename_headroom      <= 0;
            sim_a0_reject_frontend_headroom    <= 0;
            sim_a0_reject_burst                <= 0;
            sim_a0_younger_sum                 <= 0;
            sim_a0_younger_ready_sum           <= 0;
            sim_a0_younger_max                 <= 0;
            sim_a0_younger_ready_max           <= 0;
            sim_sel_rec_cdb_mispredict       <= 0;
            sim_sel_rec_candidate            <= 0;
            sim_sel_rec_accepted             <= 0;
            sim_sel_rec_reject_commit        <= 0;
            sim_sel_rec_reject_rename        <= 0;
            sim_sel_rec_reject_uoc           <= 0;
            sim_sel_rec_reject_side_effect   <= 0;
            sim_sel_rec_reject_checkpoint    <= 0;
            sim_sel_rec_reject_rename_headroom <= 0;
            sim_sel_rec_reject_frontend_headroom <= 0;
            sim_sel_rec_reject_burst         <= 0;
        end else begin
            if (sim_branch_opportunity_en &&
                bru_partial_cdb_mispredict_valid) begin
                sim_a0_cdb_mispredict_cycles <=
                    sim_a0_cdb_mispredict_cycles + 1;
                sim_a0_cdb_mispredict_slots <=
                    sim_a0_cdb_mispredict_slots +
                    (sim_a0_cdb_mispredict_slot[0] ? 1 : 0) +
                    (sim_a0_cdb_mispredict_slot[1] ? 1 : 0);

                case (sim_a0_candidate_type_c)
                    BT_JAL:  sim_a0_type_jal  <= sim_a0_type_jal + 1;
                    BT_JALR: sim_a0_type_jalr <= sim_a0_type_jalr + 1;
                    BT_CALL: sim_a0_type_call <= sim_a0_type_call + 1;
                    BT_RET:  sim_a0_type_ret  <= sim_a0_type_ret + 1;
                    default: sim_a0_type_cond <= sim_a0_type_cond + 1;
                endcase

                if (sim_a0_candidate_age_c == '0) begin
                    sim_a0_age_head <= sim_a0_age_head + 1;
                end else if (sim_a0_candidate_age_c <= (ROB_IDX_BITS+1)'(3)) begin
                    sim_a0_age_near <= sim_a0_age_near + 1;
                end else if (sim_a0_candidate_age_c <= (ROB_IDX_BITS+1)'(15)) begin
                    sim_a0_age_mid <= sim_a0_age_mid + 1;
                end else if (sim_a0_candidate_age_c <= (ROB_IDX_BITS+1)'(63)) begin
                    sim_a0_age_far <= sim_a0_age_far + 1;
                end else begin
                    sim_a0_age_older <= sim_a0_age_older + 1;
                end
                sim_a0_age_sum <= sim_a0_age_sum + int'(sim_a0_candidate_age_c);
                if (int'(sim_a0_candidate_age_c) > sim_a0_age_max) begin
                    sim_a0_age_max <= int'(sim_a0_candidate_age_c);
                end

                if (rob_uses_checkpoint[bru_partial_candidate_rob_idx]) begin
                    sim_a0_checkpoint_any <= sim_a0_checkpoint_any + 1;
                end else begin
                    sim_a0_checkpoint_missing <= sim_a0_checkpoint_missing + 1;
                end
                if (rob_uses_checkpoint[bru_partial_candidate_rob_idx] &&
                    (rob_checkpoint_tail[bru_partial_candidate_rob_idx] ==
                     bru_partial_candidate_rob_idx)) begin
                    sim_a0_checkpoint_at_branch <=
                        sim_a0_checkpoint_at_branch + 1;
                end
                if (rename_buf[bru_partial_candidate_rob_idx].rd_valid) begin
                    sim_a0_side_effect <= sim_a0_side_effect + 1;
                end

                sim_a0_younger_sum <=
                    sim_a0_younger_sum + int'(sim_a0_younger_count_c);
                sim_a0_younger_ready_sum <=
                    sim_a0_younger_ready_sum + sim_a0_ready_younger_count_c;
                if (int'(sim_a0_younger_count_c) > sim_a0_younger_max) begin
                    sim_a0_younger_max <= int'(sim_a0_younger_count_c);
                end
                if (sim_a0_ready_younger_count_c >
                    sim_a0_younger_ready_max) begin
                    sim_a0_younger_ready_max <= sim_a0_ready_younger_count_c;
                end

                if (bru_partial_candidate_valid) begin
                    sim_a0_partial_candidate <= sim_a0_partial_candidate + 1;
                    if (selective_branch_recovery_resource_ok) begin
                        sim_a0_partial_resource_ok <=
                            sim_a0_partial_resource_ok + 1;
                    end else if (!rename_recovery_headroom_ok) begin
                        sim_a0_reject_rename_headroom <=
                            sim_a0_reject_rename_headroom + 1;
                    end else if (!frontend_recovery_headroom_ok) begin
                        sim_a0_reject_frontend_headroom <=
                            sim_a0_reject_frontend_headroom + 1;
                    end else if (!branch_recovery_burst_ready) begin
                        sim_a0_reject_burst <= sim_a0_reject_burst + 1;
                    end
                end else if (commit_flush.valid) begin
                    sim_a0_reject_commit <= sim_a0_reject_commit + 1;
                end else if (rename_stall) begin
                    sim_a0_reject_rename <= sim_a0_reject_rename + 1;
                end else if (uoc_active) begin
                    sim_a0_reject_uoc <= sim_a0_reject_uoc + 1;
                end else if (rename_buf[bru_partial_candidate_rob_idx].rd_valid) begin
                    sim_a0_reject_side_effect <=
                        sim_a0_reject_side_effect + 1;
                end else begin
                    sim_a0_reject_checkpoint <= sim_a0_reject_checkpoint + 1;
                end
            end

            if (sim_selective_branch_recovery) begin
                if (bru_partial_cdb_mispredict_valid) begin
                    sim_sel_rec_cdb_mispredict <=
                        sim_sel_rec_cdb_mispredict + 1;

                    if (bru_partial_candidate_valid) begin
                        sim_sel_rec_candidate <= sim_sel_rec_candidate + 1;
                    end else if (commit_flush.valid) begin
                        sim_sel_rec_reject_commit <=
                            sim_sel_rec_reject_commit + 1;
                    end else if (rename_stall) begin
                        sim_sel_rec_reject_rename <=
                            sim_sel_rec_reject_rename + 1;
                    end else if (uoc_active) begin
                        sim_sel_rec_reject_uoc <=
                            sim_sel_rec_reject_uoc + 1;
                    end else if (rename_buf[bru_partial_candidate_rob_idx].rd_valid) begin
                        sim_sel_rec_reject_side_effect <=
                            sim_sel_rec_reject_side_effect + 1;
                    end else begin
                        sim_sel_rec_reject_checkpoint <=
                            sim_sel_rec_reject_checkpoint + 1;
                    end
                end

                if (bru_partial_candidate_valid) begin
                    if (bru_partial_recovery_valid) begin
                        sim_sel_rec_accepted <= sim_sel_rec_accepted + 1;
                    end else if (!rename_recovery_headroom_ok) begin
                        sim_sel_rec_reject_rename_headroom <=
                            sim_sel_rec_reject_rename_headroom + 1;
                    end else if (!frontend_recovery_headroom_ok) begin
                        sim_sel_rec_reject_frontend_headroom <=
                            sim_sel_rec_reject_frontend_headroom + 1;
                    end else if (!branch_recovery_burst_ready) begin
                        sim_sel_rec_reject_burst <=
                            sim_sel_rec_reject_burst + 1;
                    end
                end
            end
        end
    end

    final begin
        if (sim_branch_opportunity_en) begin
            $display("");
            $display("=== BRANCH RECOVERY OPPORTUNITY PROFILE ===");
            $display("xs branch opportunity cdb mispredict cycles : %0d",
                     sim_a0_cdb_mispredict_cycles);
            $display("xs branch opportunity cdb mispredict slots : %0d",
                     sim_a0_cdb_mispredict_slots);
            $display("xs branch opportunity type cond : %0d",
                     sim_a0_type_cond);
            $display("xs branch opportunity type jal : %0d",
                     sim_a0_type_jal);
            $display("xs branch opportunity type jalr : %0d",
                     sim_a0_type_jalr);
            $display("xs branch opportunity type call : %0d",
                     sim_a0_type_call);
            $display("xs branch opportunity type ret : %0d",
                     sim_a0_type_ret);
            $display("xs branch opportunity age head : %0d",
                     sim_a0_age_head);
            $display("xs branch opportunity age near : %0d",
                     sim_a0_age_near);
            $display("xs branch opportunity age mid : %0d",
                     sim_a0_age_mid);
            $display("xs branch opportunity age far : %0d",
                     sim_a0_age_far);
            $display("xs branch opportunity age older : %0d",
                     sim_a0_age_older);
            $display("xs branch opportunity age sum : %0d",
                     sim_a0_age_sum);
            $display("xs branch opportunity age max : %0d",
                     sim_a0_age_max);
            $display("xs branch opportunity checkpoint any : %0d",
                     sim_a0_checkpoint_any);
            $display("xs branch opportunity checkpoint at branch : %0d",
                     sim_a0_checkpoint_at_branch);
            $display("xs branch opportunity checkpoint missing : %0d",
                     sim_a0_checkpoint_missing);
            $display("xs branch opportunity side effect : %0d",
                     sim_a0_side_effect);
            $display("xs branch opportunity partial candidate : %0d",
                     sim_a0_partial_candidate);
            $display("xs branch opportunity partial resource ok : %0d",
                     sim_a0_partial_resource_ok);
            $display("xs branch opportunity reject commit : %0d",
                     sim_a0_reject_commit);
            $display("xs branch opportunity reject rename : %0d",
                     sim_a0_reject_rename);
            $display("xs branch opportunity reject uoc : %0d",
                     sim_a0_reject_uoc);
            $display("xs branch opportunity reject side effect : %0d",
                     sim_a0_reject_side_effect);
            $display("xs branch opportunity reject checkpoint : %0d",
                     sim_a0_reject_checkpoint);
            $display("xs branch opportunity reject rename headroom : %0d",
                     sim_a0_reject_rename_headroom);
            $display("xs branch opportunity reject frontend headroom : %0d",
                     sim_a0_reject_frontend_headroom);
            $display("xs branch opportunity reject burst : %0d",
                     sim_a0_reject_burst);
            $display("xs branch opportunity younger sum : %0d",
                     sim_a0_younger_sum);
            $display("xs branch opportunity younger ready sum : %0d",
                     sim_a0_younger_ready_sum);
            $display("xs branch opportunity younger max : %0d",
                     sim_a0_younger_max);
            $display("xs branch opportunity younger ready max : %0d",
                     sim_a0_younger_ready_max);
        end

        if (sim_selective_branch_recovery) begin
            $display("");
            $display("=== SELECTIVE BRANCH RECOVERY SUMMARY ===");
            $display("CDB mispredict cycles:           %0d",
                     sim_sel_rec_cdb_mispredict);
            $display("Recovery candidates / accepted:  %0d / %0d",
                     sim_sel_rec_candidate,
                     sim_sel_rec_accepted);
            $display("Candidate rejects commit/rename/uoc/side/ckpt: %0d / %0d / %0d / %0d / %0d",
                     sim_sel_rec_reject_commit,
                     sim_sel_rec_reject_rename,
                     sim_sel_rec_reject_uoc,
                     sim_sel_rec_reject_side_effect,
                     sim_sel_rec_reject_checkpoint);
            $display("Headroom rejects rename/frontend/burst: %0d / %0d / %0d",
                     sim_sel_rec_reject_rename_headroom,
                     sim_sel_rec_reject_frontend_headroom,
                     sim_sel_rec_reject_burst);
        end
    end
`endif

    assign ghr_restore_valid_fe =
        bru_early_redirect ||
        (flush_out.valid && flush_out.ghr_restore_valid);
    assign ghr_restore_val_fe =
        flush_out.valid ? flush_out.ghr_restore_val
                        : (bru1_early_redirect
                           ? (br_op_is_cond(iq0_issue_data[1].br_op)
                              ? {iq0_issue_data[1].bp_ghr[GHR_BITS-2:0],
                                 bru1_taken}
                              : iq0_issue_data[1].bp_ghr)
                           : (br_op_is_cond(iq0_issue_data[0].br_op)
                              ? {iq0_issue_data[0].bp_ghr[GHR_BITS-2:0],
                                 bru_taken}
                              : iq0_issue_data[0].bp_ghr));
    assign ras_restore_valid_fe = bru_early_redirect || flush_out.valid;
    assign ras_restore_tos_fe =
        flush_out.valid ? flush_out.ras_tos
                        : (bru1_early_redirect
                           ? ras_tos_after_redirect(
                                 iq0_issue_data[1].bp_ras_tos,
                                 iq0_issue_data[1].bp_ras_op
                             )
                           : ras_tos_after_redirect(
                                 iq0_issue_data[0].bp_ras_tos,
                                 iq0_issue_data[0].bp_ras_op
                             ));
    assign ras_restore_top_valid_fe =
        flush_out.valid
            ? flush_out.ras_top_restore_valid
            : (bru1_early_redirect
               ? ((iq0_issue_data[1].bp_ras_op == RAS_NONE) &&
                  (iq0_issue_data[1].bp_ras_tos != 5'd0))
               : (bru0_early_redirect &&
                  (iq0_issue_data[0].bp_ras_op == RAS_NONE) &&
                  (iq0_issue_data[0].bp_ras_tos != 5'd0)));
    assign ras_restore_top_addr_fe =
        flush_out.valid ? flush_out.ras_top_restore_addr
                        : (bru1_early_redirect ? iq0_issue_data[1].bp_ras_top
                                               : iq0_issue_data[0].bp_ras_top);

    always_comb begin
        logic        exec_from_bru1;
        iq_entry_t   exec_issue;
        logic        exec_taken;
        logic [63:0] exec_redirect_target;
        logic [63:0] exec_taken_target;

        exec_from_bru1       = bru1_early_redirect;
        exec_issue           = exec_from_bru1 ? iq0_issue_data[1]
                                              : iq0_issue_data[0];
        exec_taken           = exec_from_bru1 ? bru1_taken : bru_taken;
        exec_redirect_target = exec_from_bru1 ? bru1_target : bru_target;
        exec_taken_target    = exec_from_bru1 ? bru1_taken_target
                                              : bru_taken_target;

        exec_bpu_update_valid      =
            sim_bpu_exec_misp_update && bru_early_redirect;
        exec_bpu_update_pc         = exec_issue.pc;
        exec_bpu_tage_update_valid =
            exec_bpu_update_valid && br_op_is_cond(exec_issue.br_op);
        exec_bpu_tage_update_pc    = exec_issue.pc;
        exec_bpu_tage_update_taken = exec_taken;
        exec_bpu_tage_update_mispredict = exec_bpu_update_valid;
        exec_bpu_tage_update_target =
            br_op_is_cond(exec_issue.br_op) ? exec_taken_target
                                            : exec_redirect_target;
        exec_bpu_tage_update_ghr   = exec_issue.bp_ghr;
        exec_bpu_update_taken      = exec_taken;
        exec_bpu_update_mispredict = exec_bpu_update_valid;
        exec_bpu_update_target     = br_op_is_cond(exec_issue.br_op)
                                     ? exec_taken_target
                                     : exec_redirect_target;
        exec_bpu_update_type       = bpu_type_from_iq(exec_issue);
        exec_bpu_update_ghr        = exec_issue.bp_ghr;
    end

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

    assign flush_out = commit_flush.valid ? commit_flush : bru_flush;

    // =========================================================================
    // 12. MULTIPLIER (shared with ALU2 on IQ1 port 0)
    // =========================================================================
    logic        mul_valid_out;
    logic [63:0] mul_result;
    logic        mul_issue;
    logic        mul_issue_live;
    logic        mul_result_flushed;
    logic        mul_valid_live;
    assign mul_issue = iq1_issue_valid[0] && (iq1_issue_data[0].fu_type == FU_MUL);
    assign mul_issue_live =
        mul_issue &&
        !(flush_out.valid && !flush_out.full_flush &&
          rename_buf_partial_clear[iq1_issue_data[0].rob_idx]);

    // Track ROB idx and pdst through multiplier pipeline stages.
    // Multiplier is now 2-stage (s3 removed); s2 holds the rob_idx/pdst
    // aligned with the new valid_out.  s3 signals retained but driven from
    // s2 so downstream consumers continue to work unchanged.
    logic [ROB_IDX_BITS-1:0]  mul_rob_idx_s1, mul_rob_idx_s2, mul_rob_idx_s3;
    logic [PHYS_REG_BITS-1:0] mul_pdst_s1, mul_pdst_s2, mul_pdst_s3;

    always_ff @(posedge clk) begin
        if (!rst_n || (flush_out.valid && flush_out.full_flush)) begin
            mul_rob_idx_s1 <= '0;
            mul_pdst_s1    <= '0;
            mul_rob_idx_s2 <= '0;
            mul_pdst_s2    <= '0;
        end else begin
            mul_rob_idx_s1 <= iq1_issue_data[0].rob_idx;
            mul_pdst_s1    <= iq1_issue_data[0].pdst;
            mul_rob_idx_s2 <= mul_rob_idx_s1;
            mul_pdst_s2    <= mul_pdst_s1;
        end
    end

    // Multiplier is now 1-stage; valid_out fires at cycle N+1.  Alias s3
    // wires to s1 so existing consumers (mul_eff_*, mul_hold_*) track the
    // rob_idx/pdst aligned with the new valid_out timing.
    assign mul_rob_idx_s3 = mul_rob_idx_s1;
    assign mul_pdst_s3    = mul_pdst_s1;

    multiplier u_multiplier (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (mul_issue_live),
        .operand_a (bypassed_data[4]),
        .operand_b (bypassed_data[5]),
        .op        (iq1_issue_data[0].mul_op),
        .is_w_op   (iq1_issue_data[0].is_w_op),
        .flush     (flush_out.valid && flush_out.full_flush),
        .valid_out (mul_valid_out),
        .result    (mul_result)
    );
    assign mul_result_flushed =
        flush_out.valid && !flush_out.full_flush &&
        rename_buf_partial_clear[mul_rob_idx_s3];
    assign mul_valid_live = mul_valid_out && !mul_result_flushed;

    // =========================================================================
    // 13. DIVIDER (shared with ALU3 on IQ2 port 0)
    // =========================================================================
    logic [63:0] div_result;
    logic        div_issue;
    assign div_issue =
        iq2_issue_valid[0] &&
        !iq2_issue_data[0].is_fp_op &&
        (iq2_issue_data[0].fu_type == FU_DIV);

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
    mem_size_e                lsu_load_wb_mem_size [0:1];
    logic [1:0]               lsu_load_wb_has_exception;
    logic [3:0]               lsu_load_wb_exc_code [0:1];
    logic                     lsu_sta_wb_valid;
    logic [ROB_IDX_BITS-1:0]  lsu_sta_wb_rob_idx;
    logic                     lsu_std_wb_valid;
    logic [ROB_IDX_BITS-1:0]  lsu_std_wb_rob_idx;

    // Build the LSU's load_rs1 unpacked-array port using explicit indexing
    // (a packed concat would be silently re-ordered by Verilator).
    logic [63:0] lsu_load_rs1_arr [0:1];
    logic [63:0] lsu_load_rs2_arr [0:1];
    assign lsu_load_rs1_arr[0] = bypassed_data[8];
    assign lsu_load_rs1_arr[1] = bypassed_data[9];
    assign lsu_load_rs2_arr[0] = bypassed_data[9];
    assign lsu_load_rs2_arr[1] = 64'd0;

    // ALU0 is used when not BRU
    logic alu0_issue;
    assign alu0_issue = iq0_issue_valid[0] && (iq0_issue_data[0].fu_type == FU_ALU);

    // ALU2 is used when not MUL
    logic alu2_issue;
    assign alu2_issue = iq1_issue_valid[0] && (iq1_issue_data[0].fu_type == FU_ALU);

    // ALU3 is used when not DIV
    logic alu3_issue;
    assign alu3_issue =
        iq2_issue_valid[0] &&
        !iq2_issue_data[0].is_fp_op &&
        ((iq2_issue_data[0].fu_type == FU_ALU) ||
         (iq2_issue_data[0].fu_type == FU_CSR));

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
        cdb_fp_fflags_valid[0]  = 1'b0;
        cdb_fp_fflags[0]        = 5'd0;
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
        cdb_fp_fflags_valid[1]  = 1'b0;
        cdb_fp_fflags[1]        = 5'd0;
        if (bru1_issue)
            cdb_data[1] = bru1_result;
        else
            cdb_data[1] = alu1_result;
    end

    // MUL completion queue: IQ1 can issue back-to-back MULs, and their
    // completions can overlap later ALU2 traffic on the shared CDB[2] port.
    // A single hold register is insufficient because an older held result can
    // be overwritten by a younger completion before it drains.  With a 3-stage
    // multiplier and a single IQ1 issue slot, at most 3 MUL results can be
    // outstanding while ALU2 occupies the port, so a 3-entry FIFO is enough.
    logic                    mul_hold_valid_r;
    logic [ROB_IDX_BITS-1:0] mul_hold_rob_idx_r;
    logic [PHYS_REG_BITS-1:0] mul_hold_pdst_r;
    logic [63:0]             mul_hold_data_r;
    logic                    mul_hold1_valid_r;
    logic [ROB_IDX_BITS-1:0] mul_hold1_rob_idx_r;
    logic [PHYS_REG_BITS-1:0] mul_hold1_pdst_r;
    logic [63:0]             mul_hold1_data_r;
    logic                    mul_hold2_valid_r;
    logic [ROB_IDX_BITS-1:0] mul_hold2_rob_idx_r;
    logic [PHYS_REG_BITS-1:0] mul_hold2_pdst_r;
    logic [63:0]             mul_hold2_data_r;

    logic                    mul_hold_valid_n;
    logic [ROB_IDX_BITS-1:0] mul_hold_rob_idx_n;
    logic [PHYS_REG_BITS-1:0] mul_hold_pdst_n;
    logic [63:0]             mul_hold_data_n;
    logic                    mul_hold1_valid_n;
    logic [ROB_IDX_BITS-1:0] mul_hold1_rob_idx_n;
    logic [PHYS_REG_BITS-1:0] mul_hold1_pdst_n;
    logic [63:0]             mul_hold1_data_n;
    logic                    mul_hold2_valid_n;
    logic [ROB_IDX_BITS-1:0] mul_hold2_rob_idx_n;
    logic [PHYS_REG_BITS-1:0] mul_hold2_pdst_n;
    logic [63:0]             mul_hold2_data_n;

    logic                    mul_take_hold;
    logic                    mul_take_fresh;
    logic                    mul_enqueue_fresh;
    logic                    mul_hold_overflow;

    assign mul_take_hold    = !alu2_issue && mul_hold_valid_r;
    assign mul_take_fresh   = !alu2_issue && !mul_hold_valid_r && mul_valid_live;
    assign mul_enqueue_fresh = mul_valid_live && !mul_take_fresh;

    always_comb begin
        mul_hold_valid_n    = mul_hold_valid_r;
        mul_hold_rob_idx_n  = mul_hold_rob_idx_r;
        mul_hold_pdst_n     = mul_hold_pdst_r;
        mul_hold_data_n     = mul_hold_data_r;
        mul_hold1_valid_n   = mul_hold1_valid_r;
        mul_hold1_rob_idx_n = mul_hold1_rob_idx_r;
        mul_hold1_pdst_n    = mul_hold1_pdst_r;
        mul_hold1_data_n    = mul_hold1_data_r;
        mul_hold2_valid_n   = mul_hold2_valid_r;
        mul_hold2_rob_idx_n = mul_hold2_rob_idx_r;
        mul_hold2_pdst_n    = mul_hold2_pdst_r;
        mul_hold2_data_n    = mul_hold2_data_r;
        mul_hold_overflow   = 1'b0;

        if (mul_take_hold) begin
            mul_hold_valid_n    = mul_hold1_valid_r;
            mul_hold_rob_idx_n  = mul_hold1_rob_idx_r;
            mul_hold_pdst_n     = mul_hold1_pdst_r;
            mul_hold_data_n     = mul_hold1_data_r;
            mul_hold1_valid_n   = mul_hold2_valid_r;
            mul_hold1_rob_idx_n = mul_hold2_rob_idx_r;
            mul_hold1_pdst_n    = mul_hold2_pdst_r;
            mul_hold1_data_n    = mul_hold2_data_r;
            mul_hold2_valid_n   = 1'b0;
            mul_hold2_rob_idx_n = '0;
            mul_hold2_pdst_n    = '0;
            mul_hold2_data_n    = '0;
        end

        if (mul_enqueue_fresh) begin
            if (!mul_hold_valid_n) begin
                mul_hold_valid_n   = 1'b1;
                mul_hold_rob_idx_n = mul_rob_idx_s3;
                mul_hold_pdst_n    = mul_pdst_s3;
                mul_hold_data_n    = mul_result;
            end else if (!mul_hold1_valid_n) begin
                mul_hold1_valid_n   = 1'b1;
                mul_hold1_rob_idx_n = mul_rob_idx_s3;
                mul_hold1_pdst_n    = mul_pdst_s3;
                mul_hold1_data_n    = mul_result;
            end else if (!mul_hold2_valid_n) begin
                mul_hold2_valid_n   = 1'b1;
                mul_hold2_rob_idx_n = mul_rob_idx_s3;
                mul_hold2_pdst_n    = mul_pdst_s3;
                mul_hold2_data_n    = mul_result;
            end else begin
                mul_hold_overflow = 1'b1;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || (flush_out.valid && flush_out.full_flush)) begin
            mul_hold_valid_r  <= 1'b0;
            mul_hold_rob_idx_r <= '0;
            mul_hold_pdst_r   <= '0;
            mul_hold_data_r   <= '0;
            mul_hold1_valid_r <= 1'b0;
            mul_hold1_rob_idx_r <= '0;
            mul_hold1_pdst_r  <= '0;
            mul_hold1_data_r  <= '0;
            mul_hold2_valid_r <= 1'b0;
            mul_hold2_rob_idx_r <= '0;
            mul_hold2_pdst_r  <= '0;
            mul_hold2_data_r  <= '0;
        end else begin
            mul_hold_valid_r  <= mul_hold_valid_n;
            mul_hold_rob_idx_r <= mul_hold_rob_idx_n;
            mul_hold_pdst_r   <= mul_hold_pdst_n;
            mul_hold_data_r   <= mul_hold_data_n;
            mul_hold1_valid_r <= mul_hold1_valid_n;
            mul_hold1_rob_idx_r <= mul_hold1_rob_idx_n;
            mul_hold1_pdst_r  <= mul_hold1_pdst_n;
            mul_hold1_data_r  <= mul_hold1_data_n;
            mul_hold2_valid_r <= mul_hold2_valid_n;
            mul_hold2_rob_idx_r <= mul_hold2_rob_idx_n;
            mul_hold2_pdst_r  <= mul_hold2_pdst_n;
            mul_hold2_data_r  <= mul_hold2_data_n;
`ifndef SYNTHESIS
            if (mul_hold_overflow) begin
                $error("[MUL_HOLD] completion queue overflow");
            end
`endif
        end
    end

    // Effective MUL output: older queued result has priority; otherwise a
    // fresh completion may use the port directly when ALU2 is idle.
    logic        mul_eff_valid;
    logic [ROB_IDX_BITS-1:0]  mul_eff_rob_idx;
    logic [PHYS_REG_BITS-1:0] mul_eff_pdst;
    logic [63:0] mul_eff_data;

    assign mul_eff_valid   = mul_take_hold || mul_take_fresh;
    assign mul_eff_rob_idx = mul_take_hold ? mul_hold_rob_idx_r : mul_rob_idx_s3;
    assign mul_eff_pdst    = mul_take_hold ? mul_hold_pdst_r    : mul_pdst_s3;
    assign mul_eff_data    = mul_take_hold ? mul_hold_data_r    : mul_result;

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
        cdb_fp_fflags_valid[2]  = 1'b0;
        cdb_fp_fflags[2]        = 5'd0;
    end

    // DIV output hold register (same pattern as MUL hold)
    logic [ROB_IDX_BITS-1:0]  div_hold_rob_idx_r;
    logic [PHYS_REG_BITS-1:0] div_hold_pdst_r;
    logic [63:0] div_hold_data_r;
    logic        div_port_busy;
    logic        div_take_hold;
    logic        div_take_fresh;

    assign div_port_busy =
        alu3_issue || fpu_out_valid || fpu_unsupported;
    assign div_take_hold =
        div_hold_valid_r && !div_port_busy;
    assign div_take_fresh =
        div_valid_out && !div_hold_valid_r && !div_port_busy;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush_out.valid) begin
            div_hold_valid_r <= 1'b0;
        end else if (div_valid_out && !div_take_fresh) begin
            div_hold_valid_r   <= 1'b1;
            div_hold_rob_idx_r <= div_rob_idx_r;
            div_hold_pdst_r    <= div_pdst_r;
            div_hold_data_r    <= div_result;
        end else if (div_take_hold) begin
            div_hold_valid_r <= 1'b0;
        end
    end

    logic        div_eff_valid;
    logic [ROB_IDX_BITS-1:0]  div_eff_rob_idx;
    logic [PHYS_REG_BITS-1:0] div_eff_pdst;
    logic [63:0] div_eff_data;

    assign div_eff_valid   = div_take_hold || div_take_fresh;
    assign div_eff_rob_idx = div_take_hold ? div_hold_rob_idx_r : div_rob_idx_r;
    assign div_eff_pdst    = div_take_hold ? div_hold_pdst_r    : div_pdst_r;
    assign div_eff_data    = div_take_hold ? div_hold_data_r    : div_result;

    // CDB[3]: FPU, ALU3 (same cycle), or DIV (multi-cycle, with hold)
	    always_comb begin
	        if (fpu_out_valid || fpu_unsupported) begin
	            cdb_valid[3]         = 1'b1;
	            cdb_tag[3]           = fpu_unsupported ? fpu_req_data_r.pdst
	                                                    : fpu_out_pdst;
	            cdb_rob_idx[3]       = fpu_unsupported ? fpu_req_data_r.rob_idx
	                                                    : fpu_out_rob_idx;
	            cdb_data[3]          = fpu_unsupported ? 64'd0 : fpu_out_data;
            cdb_csr_we[3]        = 1'b0;
            cdb_csr_addr[3]      = 12'd0;
            cdb_csr_wdata[3]     = 64'd0;
            cdb_csr_op[3]        = 2'd0;
        end else if (alu3_issue) begin
            cdb_valid[3]         = 1'b1;
            cdb_tag[3]           = iq2_issue_data[0].pdst;
            cdb_rob_idx[3]       = iq2_issue_data[0].rob_idx;
            cdb_data[3]          = (iq2_issue_data[0].fu_type == FU_CSR)
                                   ? csr_read_data : alu3_result;
            // CSR write enable: only set for CSRRW (always writes) or
            // CSRRS/CSRRC with rs1 != x0 (rs1=x0 is a read-only alias).
            // The csr_op encodes: 0=RW, 1=RS, 2=RC, 3=NONE.
            // For RS/RC with rs1=x0, the write is a no-op per RISC-V spec
            // section 9.1: "shall not write to the CSR at all".
            cdb_csr_we[3]        = (iq2_issue_data[0].fu_type == FU_CSR &&
                                    iq2_issue_data[0].csr_op != 2'd3 &&
                                    (iq2_issue_data[0].csr_op == 2'd0 ||
                                     csr_exec_wdata != 64'd0)) ? 1'b1 : 1'b0;
            cdb_csr_addr[3]      = iq2_issue_data[0].csr_addr;
            cdb_csr_wdata[3]     = csr_exec_wdata;  // rs1/zimm write mask
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
        cdb_has_exception[3]     = fpu_unsupported;
        cdb_exc_code[3]          = fpu_unsupported ? EXC_ILLEGAL_INSN : 4'd0;
        cdb_is_branch[3]        = 1'b0;
        cdb_branch_taken[3]     = 1'b0;
        cdb_branch_target[3]    = 64'd0;
        cdb_branch_taken_target[3] = 64'd0;
        cdb_branch_mispredict[3] = 1'b0;
        cdb_fp_fflags_valid[3]  =
            fpu_out_valid && |{fpu_out_status.nv, fpu_out_status.dz,
                               fpu_out_status.of, fpu_out_status.uf,
                               fpu_out_status.nx};
        cdb_fp_fflags[3]        = {fpu_out_status.nv, fpu_out_status.dz,
                                   fpu_out_status.of, fpu_out_status.uf,
                                   fpu_out_status.nx};
    end

    // Load writeback: separate from CDB wakeup broadcast (loads use spec_wk)
    // These drive PRF write ports [4:5] and ROB completion directly.
    always_comb begin
        load_wb_valid[0]         = lsu_load_wb_valid[0];
        load_wb_pdst[0]          = lsu_load_wb_pdst[0];
        load_wb_rob_idx[0]       = lsu_load_wb_rob_idx[0];
        load_wb_data[0]          = lsu_load_wb_data[0];
        load_wb_mem_size[0]      = lsu_load_wb_mem_size[0];
        load_wb_has_exception[0] = lsu_load_wb_has_exception[0];
        load_wb_exc_code[0]      = lsu_load_wb_exc_code[0];
        load_wb_valid[1]         = lsu_load_wb_valid[1];
        load_wb_pdst[1]          = lsu_load_wb_pdst[1];
        load_wb_rob_idx[1]       = lsu_load_wb_rob_idx[1];
        load_wb_data[1]          = lsu_load_wb_data[1];
        load_wb_mem_size[1]      = lsu_load_wb_mem_size[1];
        load_wb_has_exception[1] = lsu_load_wb_has_exception[1];
        load_wb_exc_code[1]      = lsu_load_wb_exc_code[1];
    end

    always_comb begin
        cdb_valid_live        = cdb_valid;
        load_wb_valid_live    = load_wb_valid;
        lsu_sta_wb_valid_live = lsu_sta_wb_valid;
        lsu_std_wb_valid_live = lsu_std_wb_valid;

        if (flush_out.valid && flush_out.full_flush) begin
            cdb_valid_live        = '0;
            load_wb_valid_live    = '0;
            lsu_sta_wb_valid_live = 1'b0;
            lsu_std_wb_valid_live = 1'b0;
        end else if (flush_out.valid) begin
            for (int i = 0; i < CDB_WIDTH; i++) begin
                if (cdb_valid_live[i]) begin
                    if (rename_buf_partial_clear[cdb_rob_idx[i]]) begin
                        cdb_valid_live[i] = 1'b0;
                    end
                end
            end
            for (int i = 0; i < 2; i++) begin
                if (load_wb_valid_live[i]) begin
                    if (rename_buf_partial_clear[load_wb_rob_idx[i]]) begin
                        load_wb_valid_live[i] = 1'b0;
                    end
                end
            end
            if (lsu_sta_wb_valid_live) begin
                if (rename_buf_partial_clear[lsu_sta_wb_rob_idx]) begin
                    lsu_sta_wb_valid_live = 1'b0;
                end
            end
            if (lsu_std_wb_valid_live) begin
                if (rename_buf_partial_clear[lsu_std_wb_rob_idx]) begin
                    lsu_std_wb_valid_live = 1'b0;
                end
            end
        end
    end

    // =========================================================================
    // CDB Pipeline Register — break the combinational loop
    //   IQ issue -> PRF read -> ALU -> CDB -> IQ wakeup -> IQ re-select
    // Registered version feeds: IQ wakeup, ROB writeback, preg_ready_table.
    // Combinational version feeds: bypass network, PRF writes.
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || (flush_out.valid && flush_out.full_flush)) begin
            cdb_valid_r            <= '0;
            cdb_has_exception_r    <= '0;
            cdb_is_branch_r        <= '0;
            cdb_branch_taken_r     <= '0;
            cdb_branch_mispredict_r <= '0;
            cdb_csr_we_r           <= '0;
            cdb_fp_fflags_valid_r  <= '0;
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
                cdb_fp_fflags_r[i]      <= '0;
            end
        end else begin
            cdb_valid_r            <= cdb_valid_live;
            cdb_has_exception_r    <= cdb_has_exception;
            cdb_is_branch_r        <= cdb_is_branch;
            cdb_branch_taken_r     <= cdb_branch_taken;
            cdb_branch_mispredict_r <= cdb_branch_mispredict;
            cdb_csr_we_r           <= cdb_csr_we;
            cdb_fp_fflags_valid_r  <= cdb_fp_fflags_valid & cdb_valid_live;
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
                cdb_fp_fflags_r[i]      <= cdb_fp_fflags[i];
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
        end else if (flush_out.valid && flush_out.full_flush) begin
            lsu_sta_wb_valid_r   <= 1'b0;
            lsu_std_wb_valid_r   <= 1'b0;
        end else begin
            lsu_sta_wb_valid_r   <= lsu_sta_wb_valid_live;
            lsu_sta_wb_rob_idx_r <= lsu_sta_wb_rob_idx;
            lsu_std_wb_valid_r   <= lsu_std_wb_valid_live;
            lsu_std_wb_rob_idx_r <= lsu_std_wb_rob_idx;
        end
    end

    // =========================================================================
    // Load writeback sideband register (1-cycle delay, for ROB writeback)
    // Stage 2: loads use load_wb sideband instead of CDB broadcast.
    // Combinational load_wb feeds: bypass network, PRF writes, preg_ready_table.
    // Registered load_wb_r feeds: ROB ready-bit updates.
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || (flush_out.valid && flush_out.full_flush)) begin
            load_wb_valid_r         <= 2'b00;
            load_wb_has_exception_r <= 2'b00;
        end else begin
            load_wb_valid_r[0]         <= load_wb_valid_live[0];
            load_wb_pdst_r[0]          <= load_wb_pdst[0];
            load_wb_rob_idx_r[0]       <= load_wb_rob_idx[0];
            load_wb_has_exception_r[0] <= load_wb_has_exception[0];
            load_wb_exc_code_r[0]      <= load_wb_exc_code[0];
            load_wb_valid_r[1]         <= load_wb_valid_live[1];
            load_wb_pdst_r[1]          <= load_wb_pdst[1];
            load_wb_rob_idx_r[1]       <= load_wb_rob_idx[1];
            load_wb_has_exception_r[1] <= load_wb_has_exception[1];
            load_wb_exc_code_r[1]      <= load_wb_exc_code[1];
        end
    end

    // =========================================================================
    // PRF Write Port Assignment (PRF_WRITE_PORTS=6)
    //   Write[0]: ALU0/BRU         (CDB[0])
    //   Write[1]: ALU1/BRU1        (CDB[1])
    //   Write[2]: ALU2/MUL         (CDB[2])
    //   Write[3]: ALU3/DIV/CSR     (CDB[3])
    //   Write[4]: Load 0           (load_wb[0] — separate from CDB broadcast)
    //   Write[5]: Load 1           (load_wb[1] — separate from CDB broadcast)
    // =========================================================================
    assign prf_wen[0]   =
        cdb_valid_live[0] && (cdb_tag[0] != '0) &&
        (cdb_tag[0] < PHYS_REG_BITS'(FP_PHYS_BASE));
    assign prf_waddr[0] = cdb_tag[0];
    assign prf_wdata[0] = cdb_data[0];

    assign prf_wen[1]   =
        cdb_valid_live[1] && (cdb_tag[1] != '0) &&
        (cdb_tag[1] < PHYS_REG_BITS'(FP_PHYS_BASE));
    assign prf_waddr[1] = cdb_tag[1];
    assign prf_wdata[1] = cdb_data[1];

    assign prf_wen[2]   =
        cdb_valid_live[2] && (cdb_tag[2] != '0) &&
        (cdb_tag[2] < PHYS_REG_BITS'(FP_PHYS_BASE));
    assign prf_waddr[2] = cdb_tag[2];
    assign prf_wdata[2] = cdb_data[2];

    assign prf_wen[3]   =
        cdb_valid_live[3] && (cdb_tag[3] != '0) &&
        (cdb_tag[3] < PHYS_REG_BITS'(FP_PHYS_BASE));
    assign prf_waddr[3] = cdb_tag[3];
    assign prf_wdata[3] = cdb_data[3];

    assign prf_wen[4]   =
        load_wb_valid_live[0] && (load_wb_pdst[0] != '0) &&
        (load_wb_pdst[0] < PHYS_REG_BITS'(FP_PHYS_BASE));
    assign prf_waddr[4] = load_wb_pdst[0];
    assign prf_wdata[4] = load_wb_data[0];

    assign prf_wen[5]   =
        load_wb_valid_live[1] && (load_wb_pdst[1] != '0) &&
        (load_wb_pdst[1] < PHYS_REG_BITS'(FP_PHYS_BASE));
    assign prf_waddr[5] = load_wb_pdst[1];
    assign prf_wdata[5] = load_wb_data[1];

    assign fp_prf_wen[0] =
        cdb_valid_live[3] &&
        (cdb_tag[3] >= PHYS_REG_BITS'(FP_PHYS_BASE));
    assign fp_prf_waddr[0] = 7'(cdb_tag[3] - PHYS_REG_BITS'(FP_PHYS_BASE));
    assign fp_prf_wdata[0] = cdb_data[3];

    assign fp_prf_wen[1] =
        load_wb_valid_live[0] &&
        (load_wb_pdst[0] >= PHYS_REG_BITS'(FP_PHYS_BASE));
    assign fp_prf_waddr[1] =
        7'(load_wb_pdst[0] - PHYS_REG_BITS'(FP_PHYS_BASE));
    assign fp_prf_wdata[1] =
        (load_wb_mem_size[0] == MEM_WORD) ?
        {32'hffff_ffff, load_wb_data[0][31:0]} : load_wb_data[0];

    assign fp_prf_wen[2] =
        load_wb_valid_live[1] &&
        (load_wb_pdst[1] >= PHYS_REG_BITS'(FP_PHYS_BASE));
    assign fp_prf_waddr[2] =
        7'(load_wb_pdst[1] - PHYS_REG_BITS'(FP_PHYS_BASE));
    assign fp_prf_wdata[2] =
        (load_wb_mem_size[1] == MEM_WORD) ?
        {32'hffff_ffff, load_wb_data[1][31:0]} : load_wb_data[1];

    assign fp_prf_wen[3]   = 1'b0;
    assign fp_prf_waddr[3] = 7'd0;
    assign fp_prf_wdata[3] = 64'd0;

    // =========================================================================
    // Bypass source wiring (4-wide: NUM_BYPASS_SRCS=5)
    //   [0]: ALU0/BRU (registered CDB[0])
    //   [1]: ALU1/BRU1 (registered CDB[1])
    //   [2]: ALU2/MUL (registered CDB[2])
    //   [3]: Load0 (combinational load_wb[0] — 2-cycle load latency)
    //   [4]: Load1 (combinational load_wb[1] — 2-cycle load latency)
    //
    // Dropped vs 6-wide:
    //   - ALU3/DIV/CSR (CDB[3]): DIV is multi-cycle, bypass rarely fires;
    //     CSR is infrequent and serialised; consumers fall back to PRF read.
    //   - Load1 (CDB[5]): second load port consumers fall back to PRF read
    //     (adds 1 cycle latency on load-use for the second load port only).
    //
    // For ALU sources [0..2]: use REGISTERED CDB.  ALU producers wake their
    // consumers via the registered cdb_r path (1 cycle after compute), and
    // by then the PRF write has already latched, so bypass-from-cdb_r is
    // semantically equivalent to PRF read but cuts the read mux.  No
    // combinational loop because cdb_r is registered.
    //
    // For LOAD source [3]: use COMBINATIONAL CDB.  A load AGU at T+0
    // sets spec_wakeup at T+1 (load _r stage), the IQ latches src1_ready at
    // T+2 (next clock edge), and the consumer issues at T+2 — exactly the
    // cycle the load result is on the combinational CDB (load_wb fires at
    // the _rr stage = T+2).  The PRF write does not latch until T+3, so
    // the consumer's PRF read at T+2 still returns the OLD value; the
    // combinational bypass is the only path that delivers the load value.
    //
    // Suppress bypass for p0 (hardwired zero register) — CDB may carry
    // non-zero data for instructions with pdst=p0 (e.g., JAL x0).
    assign bypass_valid = {load_wb_valid_live[1] && (load_wb_pdst[1]  != '0),  // [4] Load1
                           load_wb_valid_live[0] && (load_wb_pdst[0]  != '0),  // [3] Load0
                           cdb_valid_r[2]   && (cdb_tag_r[2]    != '0),  // [2] ALU2/MUL
                           cdb_valid_r[1]   && (cdb_tag_r[1]    != '0),  // [1] ALU1/BRU1
                           cdb_valid_r[0]   && (cdb_tag_r[0]    != '0)}; // [0] ALU0/BRU
    assign bypass_tag[0]  = cdb_tag_r[0];
    assign bypass_tag[1]  = cdb_tag_r[1];
    assign bypass_tag[2]  = cdb_tag_r[2];
    assign bypass_tag[3]  = load_wb_pdst[0];    // Load0 combinational
    assign bypass_tag[4]  = load_wb_pdst[1];    // Load1 combinational
    assign bypass_data[0] = cdb_data_r[0];
    assign bypass_data[1] = cdb_data_r[1];
    assign bypass_data[2] = cdb_data_r[2];
    assign bypass_data[3] = load_wb_data[0];    // Load0 combinational
    assign bypass_data[4] = load_wb_data[1];    // Load1 combinational

    // =========================================================================
    // PRF Ready Table
    //
    // Set bit when CDB writes a register.
    // Clear bit when rename allocates a new destination.
    // p0 is always ready (hardwired zero).
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            preg_ready_table <= {PHYS_TAG_COUNT{1'b1}};
        end else if (flush_out.valid && flush_out.full_flush) begin
            // Full flush: reset all pregs to ready.
            // After flush the RAT maps arch regs 0-31 to phys 0-31 (committed
            // state) and the free list marks 32-255 as free. No in-flight
            // writers exist, so every physical register is ready.
            preg_ready_table <= {PHYS_TAG_COUNT{1'b1}};
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
            // Set on CDB writeback (ALU/MUL/DIV/CSR) — use COMBINATIONAL CDB so
            // the table is current when rename reads it next cycle. This path
            // (ready_table -> rename -> IQ) is one-way, not part of
            // the IQ -> ALU -> CDB -> IQ wakeup loop.
            for (int i = 0; i < CDB_WIDTH; i++) begin
                if (cdb_valid_live[i] && cdb_tag[i] != '0) begin
                    preg_ready_table[cdb_tag[i]] <= 1'b1;
                end
            end
            // Set on load writeback (Stage 2: loads removed from CDB broadcast).
            for (int lw = 0; lw < 2; lw++) begin
                if (load_wb_valid_live[lw] && load_wb_pdst[lw] != '0) begin
                    preg_ready_table[load_wb_pdst[lw]] <= 1'b1;
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
	    logic [ROB_IDX_BITS-1:0] pdst_producer_rob [0:PHYS_TAG_COUNT-1];

	    always_ff @(posedge clk or negedge rst_n) begin
	        if (!rst_n || (flush_out.valid && flush_out.full_flush)) begin
	            for (int p = 0; p < PHYS_TAG_COUNT; p++)
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

    // A1/A2 -- procedural simulation checks. DSim can iterate heavily on
    // quiet SVA implication properties in long CoreMark runs, so keep the
    // same one-cycle contracts as clocked checks.
    always_ff @(posedge clk) begin
        if (rst_n && sva_prev_violation && !sva_prev_flush_full) begin
            if (!replay_valid) begin
                $error("[SVA A1] cyc=%0d replay_valid did NOT follow ordering_violation (prev_viol_rob=%0d)",
                       sva_cycle, sva_prev_viol_rob);
            end
            if (replay_rob_idx_from !== sva_prev_viol_rob) begin
                $error("[SVA A2] cyc=%0d replay_rob_idx_from mismatch got=%0d expected=%0d",
                       sva_cycle, replay_rob_idx_from, sva_prev_viol_rob);
            end
        end
    end

    // A4 — METADATA: whenever rename produces an advancing rd_valid slot
    //                with a non-zero pdst, pdst_producer_rob[pdst] must hold
    //                that rob_idx on the following cycle. Keep this procedural
    //                because DSim's SVA engine can iterate heavily on variable
    //                array-index properties after the FP tag-space widening.
    always_ff @(posedge clk) begin
        if (rst_n && sva_prev_ren0_rdvalid &&
            !(sva_prev_flush_full) &&
            (pdst_producer_rob[sva_prev_ren0_pdst] !== sva_prev_ren0_robidx)) begin
            $error("[SVA A4] cyc=%0d pdst_producer_rob[%0d] mismatch got=%0d expected=%0d",
                   sva_cycle, sva_prev_ren0_pdst,
                   pdst_producer_rob[sva_prev_ren0_pdst],
                   sva_prev_ren0_robidx);
        end
    end

    // A5 -- replay_rob_idx_from should always point at a currently-valid ROB
    // entry. Fires only on replay_valid.
    always_ff @(posedge clk) begin
        if (rst_n && replay_valid &&
            !u_rob.valid_r[replay_rob_idx_from]) begin
            $error("[SVA A5] cyc=%0d replay target rob=%0d is not a valid ROB entry",
                   sva_cycle, replay_rob_idx_from);
        end
    end

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

    always_ff @(posedge clk) begin
        if (rst_n && replay_valid && (sva_commit_in_replay != '0)) begin
            $error("[SVA A6] cyc=%0d commit tried to retire rob in replay range: mask=%b replay_from=%0d head=%0d tail=%0d",
                   sva_cycle, sva_commit_in_replay, replay_rob_idx_from,
                   u_rob.head_r, u_rob.tail_r);
        end
    end

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
    always_ff @(posedge clk) begin
        if (rst_n && sva_replay_armed &&
            (sva_replay_stuck_cnt >= REPLAY_DEADLOCK_CYC)) begin
            $error("[SVA A7] cyc=%0d replay stuck %0d cycles without commit or flush (head stayed at %0d)",
                   sva_cycle, sva_replay_stuck_cnt, sva_head_at_replay);
        end
    end

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
    // measures ROB head timeout diagnostic hits.
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
        $display("  [A15] head-timeout diagnostic hits:    %0d", sva_cnt_watchdog_fire);
        $display("  [A16] watchdog fires post-replay(<100):%0d", sva_cnt_watchdog_post_replay);
    end
    // =========================================================================
    // End of partial-replay SVA
    // =========================================================================
`endif

    // LQ/SQ alloc counts from rename
    logic [2:0] lq_alloc_count;
    logic [2:0] sq_alloc_count;
    logic [ROB_IDX_BITS-1:0] lq_alloc_rob_idx [0:PIPE_WIDTH-1];
    logic [ROB_IDX_BITS-1:0] sq_alloc_rob_idx [0:PIPE_WIDTH-1];
    logic                    data_vm_active;
    logic                    dtlb_lookup_valid;
    logic [63:0]             dtlb_lookup_va;
    logic                    dtlb_lookup_is_store;
    logic                    dtlb_miss_valid;
    logic [63:0]             dtlb_miss_va;
    logic [ROB_IDX_BITS-1:0] dtlb_miss_rob_idx;
    logic                    dtlb_miss_is_store;
    logic                    lsu_dtlb_exc_valid;
    logic [63:0]             lsu_dtlb_exc_va;
    logic [ROB_IDX_BITS-1:0] lsu_dtlb_exc_rob_idx;
    logic [3:0]              lsu_dtlb_exc_code;
    logic                    dtlb_hit;
    logic [63:0]             dtlb_pa;
    logic                    dtlb_fault;
    logic [3:0]              dtlb_fault_code;

    always_comb begin
        lq_alloc_count = 3'd0;
        sq_alloc_count = 3'd0;
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            lq_alloc_rob_idx[i] = '0;
            sq_alloc_rob_idx[i] = '0;
        end
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            if (3'(i) < ren_count_w) begin
                if (ren_insn[i].base.is_load) begin
                    lq_alloc_rob_idx[lq_alloc_count] = ren_insn[i].rob_idx;
                    lq_alloc_count = lq_alloc_count + 3'd1;
                end
                if (ren_insn[i].base.is_store) begin
                    sq_alloc_rob_idx[sq_alloc_count] = ren_insn[i].rob_idx;
                    sq_alloc_count = sq_alloc_count + 3'd1;
                end
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
        .sta_issue_candidate_valid(iq_store_issue_candidate_valid_s[0]),
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
        .load_rs2               (lsu_load_rs2_arr),
        .sta_rs1                (bypassed_data[10]),
        .std_rs2                (routed_std_data.rs2_is_fp
                                  ? fp_prf_rdata[3]
                                  : bypassed_data[11]),
        // Writeback
        .load_wb_valid          (lsu_load_wb_valid),
        .load_wb_rob_idx        (lsu_load_wb_rob_idx),
        .load_wb_pdst           (lsu_load_wb_pdst),
        .load_wb_data           (lsu_load_wb_data),
        .load_wb_mem_size       (lsu_load_wb_mem_size),
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
        .lq_alloc_rob_idx       (lq_alloc_rob_idx),
        .sq_alloc_rob_idx       (sq_alloc_rob_idx),
        .lq_alloc_idx           (lq_alloc_idx),
        .sq_alloc_idx           (sq_alloc_idx),
        .lq_full                (lq_full),
        .sq_full                (sq_full),
        .rob_head               (rob_head_idx),
        // Ordering violation
        .ordering_violation     (lsu_ordering_violation),
        .load_issue_suppress    (lsu_load_issue_suppress_raw),
        .sta_issue_suppress     (lsu_sta_issue_suppress[0]),
        .violation_rob_idx      (lsu_violation_rob_idx),
        // DTLB sideband
        .data_vm_active_i       (data_vm_active),
        .dtlb_hit_i             (dtlb_hit),
        .dtlb_pa_i              (dtlb_pa),
        .dtlb_fault_i           (dtlb_fault),
        .dtlb_fault_code_i      (dtlb_fault_code),
        .dtlb_lookup_valid_o    (dtlb_lookup_valid),
        .dtlb_lookup_va_o       (dtlb_lookup_va),
        .dtlb_lookup_is_store_o (dtlb_lookup_is_store),
        .dtlb_miss_valid_o      (dtlb_miss_valid),
        .dtlb_miss_va_o         (dtlb_miss_va),
        .dtlb_miss_rob_idx_o    (dtlb_miss_rob_idx),
        .dtlb_miss_is_store_o   (dtlb_miss_is_store),
        .dtlb_exc_valid_o       (lsu_dtlb_exc_valid),
        .dtlb_exc_va_o          (lsu_dtlb_exc_va),
        .dtlb_exc_rob_idx_o     (lsu_dtlb_exc_rob_idx),
        .dtlb_exc_code_o        (lsu_dtlb_exc_code),
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
        // Uncached data MMIO
        .data_mmio_req_valid    (data_mmio_req_valid),
        .data_mmio_req_we       (data_mmio_req_we),
        .data_mmio_req_addr     (data_mmio_req_addr),
        .data_mmio_req_wdata    (data_mmio_req_wdata),
        .data_mmio_req_wmask    (data_mmio_req_wmask),
        .data_mmio_req_size     (data_mmio_req_size),
        .data_mmio_req_ready    (data_mmio_req_ready),
        .data_mmio_resp_valid   (data_mmio_resp_valid),
        .data_mmio_resp_data    (data_mmio_resp_data),
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
    logic        ptw_l2_req_valid;
    logic [63:0] ptw_l2_req_addr;
    logic        ptw_l2_req_ready;
    logic        ptw_l2_req_accepted;
    logic        ptw_l2_resp_valid;
    logic [63:0] ptw_l2_resp_addr;
    logic [511:0] ptw_l2_resp_data;

    // (pf_l2_* signals are forward-declared near the fetch_top section above.)

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
        .icache_req_accepted(l2_icache_req_accepted),
        .icache_resp_valid  (icache_fill_resp_valid),
        .icache_resp_addr   (l2_icache_resp_addr),
        .icache_resp_data   (icache_fill_resp_data),
        // Prefetch port (from NLPB via fetch_top)
        .prefetch_req_valid (pf_l2_req_valid),
        .prefetch_req_addr  (pf_l2_req_addr),
        .prefetch_req_ready (pf_l2_req_ready),
        .prefetch_resp_valid(pf_l2_resp_valid),
        .prefetch_resp_addr (pf_l2_resp_addr),
        .prefetch_resp_data (pf_l2_resp_data),
        // PTW port (wired in the Sv48 PTW/TLB slice)
        .ptw_req_valid      (ptw_l2_req_valid),
        .ptw_req_addr       (ptw_l2_req_addr),
        .ptw_req_ready      (ptw_l2_req_ready),
        .ptw_req_accepted   (ptw_l2_req_accepted),
        .ptw_resp_valid     (ptw_l2_resp_valid),
        .ptw_resp_addr      (ptw_l2_resp_addr),
        .ptw_resp_data      (ptw_l2_resp_data),
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
        .head_is_fused          (rob_head_is_fused),
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
        logic found_tage_update;
        logic found_tage_misp_update;
        logic is_control;
        logic is_cond_branch;

        commit_bpu_update_valid      = 1'b0;
        commit_bpu_update_pc         = 64'd0;
        commit_bpu_tage_update_valid = 1'b0;
        commit_bpu_tage_update_pc    = 64'd0;
        commit_bpu_tage_update_taken = 1'b0;
        commit_bpu_tage_update_mispredict = 1'b0;
        commit_bpu_tage_update_target = 64'd0;
        commit_bpu_tage_update_ghr   = '0;
        commit_bpu_update_taken      = 1'b0;
        commit_bpu_update_mispredict = 1'b0;
        commit_bpu_update_target     = 64'd0;
        commit_bpu_update_type       = 3'd0;
        commit_bpu_update_ghr        = '0;
        found_update                 = 1'b0;
        found_tage_update            = 1'b0;
        found_tage_misp_update       = 1'b0;

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
                commit_bpu_update_valid      = 1'b1;
                commit_bpu_update_pc         = rob_head_pc[i];
                commit_bpu_update_taken      = rob_head_branch_taken[i];
                commit_bpu_update_mispredict = rob_head_branch_mispredict[i];
                commit_bpu_update_target     = rob_head_is_branch[i]
                                               ? rob_head_branch_taken_target[i]
                                               : rob_head_branch_target[i];
                commit_bpu_update_type       = rob_head_bpu_type[i];
                commit_bpu_update_ghr        = rb_head_bp_ghr[i];
                found_update         = 1'b1;
            end
        end

        // If nothing mispredicted this cycle, still train the oldest
        // committed control transfer so BTB state stays aligned with the
        // earliest CFI in each fetch block.
        if (!commit_bpu_update_valid) begin
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                is_control = rob_head_is_branch[i] || (rob_head_bpu_type[i] != 3'd0);
                if (!found_update &&
                    commit_out[i].valid &&
                    is_control) begin
                    commit_bpu_update_valid      = 1'b1;
                    commit_bpu_update_pc         = rob_head_pc[i];
                    commit_bpu_update_taken      = rob_head_branch_taken[i];
                    commit_bpu_update_mispredict = rob_head_branch_mispredict[i];
                    commit_bpu_update_target     = rob_head_is_branch[i]
                                                    ? rob_head_branch_taken_target[i]
                                                    : rob_head_branch_target[i];
                    commit_bpu_update_type       = rob_head_bpu_type[i];
                    commit_bpu_update_ghr        = rb_head_bp_ghr[i];
                    found_update          = 1'b1;
                end
            end
        end

        // Direction training is independent from BTB target training.  A wide
        // commit group may start with an unconditional jump or an older loop
        // branch, but a younger conditional in the same group still needs a
        // TAGE update so forward branches do not only learn on mispredicts.
        //
        // Optional sim experiment: prioritize a mispredicted conditional in the
        // batch before falling back to the oldest committed conditional.  This
        // does not change the default RTL contract unless the plusarg is used.
        if (sim_tage_train_misp_cond_first) begin
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                is_cond_branch = rob_head_is_branch[i] &&
                                 (rob_head_bpu_type[i] == BT_COND);
                if (!found_tage_misp_update &&
                    commit_out[i].valid &&
                    is_cond_branch &&
                    rob_head_branch_mispredict[i]) begin
                    commit_bpu_tage_update_valid = 1'b1;
                    commit_bpu_tage_update_pc = rob_head_pc[i];
                    commit_bpu_tage_update_taken = rob_head_branch_taken[i];
                    commit_bpu_tage_update_mispredict =
                        rob_head_branch_mispredict[i];
                    commit_bpu_tage_update_target =
                        rob_head_branch_taken_target[i];
                    commit_bpu_tage_update_ghr = rb_head_bp_ghr[i];
                    found_tage_misp_update = 1'b1;
                end
            end
        end

        if (!commit_bpu_tage_update_valid) begin
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                is_cond_branch = rob_head_is_branch[i] &&
                                 (rob_head_bpu_type[i] == BT_COND);
                if (!found_tage_update &&
                    commit_out[i].valid &&
                    is_cond_branch) begin
                    commit_bpu_tage_update_valid = 1'b1;
                    commit_bpu_tage_update_pc = rob_head_pc[i];
                    commit_bpu_tage_update_taken = rob_head_branch_taken[i];
                    commit_bpu_tage_update_mispredict =
                        rob_head_branch_mispredict[i];
                    commit_bpu_tage_update_target =
                        rob_head_branch_taken_target[i];
                    commit_bpu_tage_update_ghr = rb_head_bp_ghr[i];
                    found_tage_update = 1'b1;
                end
            end
        end
    end


    always_comb begin
        if (exec_bpu_update_valid) begin
            bpu_update_valid      = exec_bpu_update_valid;
            bpu_update_pc         = exec_bpu_update_pc;
            bpu_tage_update_valid = exec_bpu_tage_update_valid;
            bpu_tage_update_pc    = exec_bpu_tage_update_pc;
            bpu_tage_update_taken = exec_bpu_tage_update_taken;
            bpu_tage_update_mispredict = exec_bpu_tage_update_mispredict;
            bpu_tage_update_target = exec_bpu_tage_update_target;
            bpu_tage_update_ghr   = exec_bpu_tage_update_ghr;
            bpu_update_taken      = exec_bpu_update_taken;
            bpu_update_mispredict = exec_bpu_update_mispredict;
            bpu_update_target     = exec_bpu_update_target;
            bpu_update_type       = exec_bpu_update_type;
            bpu_update_ghr        = exec_bpu_update_ghr;
        end else begin
            bpu_update_valid      = commit_bpu_update_valid;
            bpu_update_pc         = commit_bpu_update_pc;
            bpu_tage_update_valid = commit_bpu_tage_update_valid;
            bpu_tage_update_pc    = commit_bpu_tage_update_pc;
            bpu_tage_update_taken = commit_bpu_tage_update_taken;
            bpu_tage_update_mispredict = commit_bpu_tage_update_mispredict;
            bpu_tage_update_target = commit_bpu_tage_update_target;
            bpu_tage_update_ghr   = commit_bpu_tage_update_ghr;
            bpu_update_taken      = commit_bpu_update_taken;
            bpu_update_mispredict = commit_bpu_update_mispredict;
            bpu_update_target     = commit_bpu_update_target;
            bpu_update_type       = commit_bpu_update_type;
            bpu_update_ghr        = commit_bpu_update_ghr;
        end
    end

    // FENCE.I: generate when a FENCE.I commits
    assign fence_i_signal = (commit_count > 3'd0) && rob_head_is_fence_i[0] &&
                            commit_out[0].valid;

    // =========================================================================
    // 19. CSR FILE
    // =========================================================================
    logic [63:0] csr_mcycle_val, csr_minstret_val;
    logic [63:0] csr_satp;
    logic        csr_mstatus_mprv;
    logic [1:0]  csr_mstatus_mpp;
    logic        csr_mstatus_sum;
    logic        csr_mstatus_mxr;
    logic        fp_fflags_commit_valid;
    logic [4:0]  fp_fflags_commit_bits;
    logic        fp_state_dirty_commit;

    always_comb begin
        fp_fflags_commit_bits  = 5'd0;
        fp_state_dirty_commit  = 1'b0;
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            if (commit_out[i].valid) begin
                fp_fflags_commit_bits =
                    fp_fflags_commit_bits | rob_head_fp_fflags[i];
                fp_state_dirty_commit =
                    fp_state_dirty_commit | rob_head_is_fp_instr[i];
            end
        end
        fp_fflags_commit_valid = (fp_fflags_commit_bits != 5'd0);
    end

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
                    trap_val    = rob_head_exc_tval[i];
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
        .read_addr          (csr_read_addr),
        .read_data          (csr_read_data),
        .write_valid        (csr_commit_valid),
        .write_addr         (csr_commit_addr),
        .write_data         (csr_commit_wdata),
        .write_op           (csr_commit_op),
        .fflags_acc_valid_i (fp_fflags_commit_valid),
        .fflags_acc_bits_i  (fp_fflags_commit_bits),
        .fp_state_dirty_i   (fp_state_dirty_commit),
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
        .frm_out            (csr_frm),
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
        .mstatus_mprv       (csr_mstatus_mprv),
        .mstatus_mpp        (csr_mstatus_mpp),
        .mstatus_sum        (csr_mstatus_sum),
        .mstatus_mxr        (csr_mstatus_mxr),
        .satp               (csr_satp)
    );

    // =========================================================================
    // 20. PAGE TABLE WALKER
    // =========================================================================
    logic                    satp_vm_enabled;
    logic [1:0]              csr_data_priv_mode;
    logic                    sfence_vma_commit;
    logic                    satp_commit_valid;
    logic                    translation_tlb_invalidate;
    logic                    dtlb_dirty_wb_valid;
    logic [63:0]             dtlb_dirty_wb_pte_pa;
    logic [63:0]             dtlb_dirty_wb_pte_value;
    logic                    ptw_dtlb_req_ready;
    logic                    ptw_itlb_req_ready;
    logic                    ptw_dtlb_fill_valid;
    logic                    ptw_itlb_fill_valid;
    logic [35:0]             ptw_fill_vpn;
    logic [43:0]             ptw_fill_ppn;
    logic [15:0]             ptw_fill_asid;
    logic [1:0]              ptw_fill_page_size;
    logic [7:0]              ptw_fill_perm;
    logic [63:0]             ptw_fill_pte_pa;
    logic                    ptw_fault_valid;
    logic                    ptw_fault_is_itlb;
    logic                    ptw_fault_is_store;
    logic [ROB_IDX_BITS-1:0] ptw_fault_rob_idx;
    logic [63:0]             ptw_fault_va;
    logic                    ptw_data_fault_valid;

    assign ptw_data_fault_valid =
        ptw_fault_valid && !ptw_fault_is_itlb;
    assign rob_sideband_exc_valid =
        ptw_data_fault_valid || lsu_dtlb_exc_valid;
    assign rob_sideband_exc_rob_idx =
        ptw_data_fault_valid ? ptw_fault_rob_idx : lsu_dtlb_exc_rob_idx;
    assign rob_sideband_exc_code =
        ptw_data_fault_valid
            ? (ptw_fault_is_store ? EXC_STORE_PAGE_FAULT : EXC_LOAD_PAGE_FAULT)
            : lsu_dtlb_exc_code;
    assign rob_sideband_exc_tval =
        ptw_data_fault_valid ? ptw_fault_va : lsu_dtlb_exc_va;

    assign satp_vm_enabled = (csr_satp[63:60] == 4'd8) ||
                             (csr_satp[63:60] == 4'd9);
    assign csr_data_priv_mode = (csr_priv_mode == PRIV_M && csr_mstatus_mprv)
                              ? csr_mstatus_mpp
                              : csr_priv_mode;
    assign instr_vm_active = satp_vm_enabled && (csr_priv_mode != PRIV_M);
    assign data_vm_active  = satp_vm_enabled && (csr_data_priv_mode != PRIV_M);
    assign sfence_vma_commit = (commit_count > 3'd0) &&
                               commit_out[0].valid &&
                               rob_head_is_sfence_vma[0];
    assign satp_commit_valid = csr_commit_valid && (csr_commit_addr == CSR_SATP);
    assign translation_tlb_invalidate = sfence_vma_commit || satp_commit_valid;

    itlb u_itlb (
        .clk                 (clk),
        .rst_n               (rst_n),
        .lookup_valid_i      (itlb_lookup_valid),
        .va_i                (itlb_lookup_va),
        .priv_i              (csr_priv_mode),
        .asid_i              (csr_satp[59:44]),
        .hit_o               (itlb_hit),
        .pa_o                (itlb_pa),
        .fault_o             (itlb_fault),
        .fault_code_o        (itlb_fault_code),
        .fill_valid_i        (ptw_itlb_fill_valid),
        .fill_vpn_i          (ptw_fill_vpn),
        .fill_ppn_i          (ptw_fill_ppn),
        .fill_asid_i         (ptw_fill_asid),
        .fill_page_size_i    (ptw_fill_page_size),
        .fill_perm_i         (ptw_fill_perm),
        .inv_all_i           (translation_tlb_invalidate),
        .inv_va_valid_i      (1'b0),
        .inv_va_i            (64'd0),
        .inv_asid_valid_i    (1'b0),
        .inv_asid_i          (16'd0),
        .flush_i             (1'b0)
    );

    dtlb u_dtlb (
        .clk                 (clk),
        .rst_n               (rst_n),
        .lookup_valid_i      (dtlb_lookup_valid),
        .va_i                (dtlb_lookup_va),
        .is_store_i          (dtlb_lookup_is_store),
        .priv_i              (csr_data_priv_mode),
        .asid_i              (csr_satp[59:44]),
        .sum_i               (csr_mstatus_sum),
        .mxr_i               (csr_mstatus_mxr),
        .hit_o               (dtlb_hit),
        .pa_o                (dtlb_pa),
        .fault_o             (dtlb_fault),
        .fault_code_o        (dtlb_fault_code),
        .fill_valid_i        (ptw_dtlb_fill_valid),
        .fill_vpn_i          (ptw_fill_vpn),
        .fill_ppn_i          (ptw_fill_ppn),
        .fill_asid_i         (ptw_fill_asid),
        .fill_page_size_i    (ptw_fill_page_size),
        .fill_perm_i         (ptw_fill_perm),
        .fill_pte_pa_i       (ptw_fill_pte_pa),
        .dirty_wb_valid_o    (dtlb_dirty_wb_valid),
        .dirty_wb_pte_pa_o   (dtlb_dirty_wb_pte_pa),
        .dirty_wb_pte_value_o(dtlb_dirty_wb_pte_value),
        .inv_all_i           (translation_tlb_invalidate),
        .inv_va_valid_i      (1'b0),
        .inv_va_i            (64'd0),
        .inv_asid_valid_i    (1'b0),
        .inv_asid_i          (16'd0),
        .flush_i             (1'b0)
    );

    ptw u_ptw (
        .clk                 (clk),
        .rst_n               (rst_n),
        .satp_i              (csr_satp),
        .dtlb_req_valid_i    (dtlb_miss_valid),
        .dtlb_req_va_i       (dtlb_miss_va),
        .dtlb_req_rob_idx_i  (dtlb_miss_rob_idx),
        .dtlb_req_is_store_i (dtlb_miss_is_store),
        .dtlb_req_ready_o    (ptw_dtlb_req_ready),
        .itlb_req_valid_i    (itlb_miss_valid),
        .itlb_req_va_i       (itlb_miss_va),
        .itlb_req_ready_o    (ptw_itlb_req_ready),
        .dtlb_fill_valid_o   (ptw_dtlb_fill_valid),
        .itlb_fill_valid_o   (ptw_itlb_fill_valid),
        .fill_vpn_o          (ptw_fill_vpn),
        .fill_ppn_o          (ptw_fill_ppn),
        .fill_asid_o         (ptw_fill_asid),
        .fill_page_size_o    (ptw_fill_page_size),
        .fill_perm_o         (ptw_fill_perm),
        .fill_pte_pa_o       (ptw_fill_pte_pa),
        .fault_valid_o       (ptw_fault_valid),
        .fault_is_itlb_o     (ptw_fault_is_itlb),
        .fault_is_store_o    (ptw_fault_is_store),
        .fault_rob_idx_o     (ptw_fault_rob_idx),
        .fault_va_o          (ptw_fault_va),
        .l2_req_valid_o      (ptw_l2_req_valid),
        .l2_req_addr_o       (ptw_l2_req_addr),
        .l2_req_ready_i      (ptw_l2_req_ready),
        .l2_req_accepted_i   (ptw_l2_req_accepted),
        .l2_resp_valid_i     (ptw_l2_resp_valid),
        .l2_resp_addr_i      (ptw_l2_resp_addr),
        .l2_resp_data_i      (ptw_l2_resp_data),
        .flush_i             (flush_out.valid),
        .translation_flush_i (translation_tlb_invalidate)
    );

    // =========================================================================
    // 21. STA writeback to ROB (store address completion)
    // =========================================================================
    // The STA writeback marks the store as "ready" in the ROB.
    // This is handled via the CDB or a side channel. For now we use a
    // dedicated ROB writeback for STA that only sets ready, no data.
    // This is already handled by the CDB if we route STA through it.
    // For simplicity, STA address completion is handled via the existing
    // LSU-to-CDB interface (lsu_sta_wb_valid goes through the ordering
    // violation path, not through CDB for register writeback).

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

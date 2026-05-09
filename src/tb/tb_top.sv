/* file: tb_top.sv
 * Description: Top-level simulation testbench.  Instantiates rv64gc_core_top
 *              and sim_memory, wires them together, and exposes simulation
 *              endpoint pass/fail signals to the simulator driver.
 * Version: 2.0
 */

module tb_top
    import rv64gc_pkg::*;
    import uarch_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,
    output logic        tohost_valid,
    output logic [63:0] tohost_value,

    // Performance counters (for benchmark IPC reporting)
    output logic [63:0] perf_mcycle,
    output logic [63:0] perf_minstret
);

    // =========================================================================
    // Cycle counter used as time_val for the CSR file
    // =========================================================================
    logic [63:0] cycle_count;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            cycle_count <= '0;
        else
            cycle_count <= cycle_count + 64'd1;
    end

    // =========================================================================
    // L2-to-memory wires
    // =========================================================================
    logic        mem_req_valid;
    logic [63:0] mem_req_addr;
    logic        mem_req_we;
    logic [511:0] mem_req_wdata;
    logic        mem_req_ready;
    logic        mem_resp_valid;
    logic [511:0] mem_resp_data;

    // =========================================================================
    // Core instantiation
    // =========================================================================
    logic [63:0] sim_tohost_addr;
    logic        backend_admission_throttle_enable = 1'b0;
    logic        iq_ready_enq_bypass_enable = 1'b0;
    logic        iq_ready_enq_bypass_alu_only = 1'b0;

    initial begin
        sim_tohost_addr = TOHOST_ADDR;
        backend_admission_throttle_enable =
            $test$plusargs("BACKEND_ADMISSION_THROTTLE");
        iq_ready_enq_bypass_enable =
            $test$plusargs("IQ_READY_ENQ_BYPASS") ||
            $test$plusargs("IQ_READY_ENQ_BYPASS_ALU_ONLY");
        iq_ready_enq_bypass_alu_only =
            $test$plusargs("IQ_READY_ENQ_BYPASS_ALU_ONLY");
        if ($value$plusargs("TOHOST_ADDR=%h", sim_tohost_addr)) begin
            $display("[SIM_PLATFORM] TOHOST_ADDR=%016h", sim_tohost_addr);
        end
        if (backend_admission_throttle_enable) begin
            $display("[SIM_PLATFORM] BACKEND_ADMISSION_THROTTLE=1");
        end
        if (iq_ready_enq_bypass_enable) begin
            $display("[SIM_PLATFORM] IQ_READY_ENQ_BYPASS=1");
        end
        if (iq_ready_enq_bypass_alu_only) begin
            $display("[SIM_PLATFORM] IQ_READY_ENQ_BYPASS_ALU_ONLY=1");
        end
    end

    rv64gc_core_top u_core (
        .clk             (clk),
        .rst_n           (rst_n),

        // L2-to-memory interface
        .mem_req_valid   (mem_req_valid),
        .mem_req_addr    (mem_req_addr),
        .mem_req_we      (mem_req_we),
        .mem_req_wdata   (mem_req_wdata),
        .mem_req_ready   (mem_req_ready),
        .mem_resp_valid  (mem_resp_valid),
        .mem_resp_data   (mem_resp_data),

        // External interrupts — tied off for simulation
        .mtip            (1'b0),
        .msip            (1'b0),
        .meip            (1'b0),
        .stip            (1'b0),
        .ssip            (1'b0),
        .seip            (1'b0),

        // Timer
        .time_val        (cycle_count),

        // Optional DSE controls
        .backend_admission_throttle_enable(backend_admission_throttle_enable),
        .iq_ready_enq_bypass_enable(iq_ready_enq_bypass_enable),
        .iq_ready_enq_bypass_alu_only(iq_ready_enq_bypass_alu_only),

        // Performance counters
        .perf_mcycle     (perf_mcycle),
        .perf_minstret   (perf_minstret)
    );

    // Simulation endpoint detection lives in the harness, not in the CPU RTL.
    // The harness observes ordinary committed-store traffic leaving the LSU.
    logic        tb_tohost_store_valid;
    logic [63:0] tb_tohost_store_data;
    assign tb_tohost_store_valid =
        u_core.dc_store_req_valid &&
        (u_core.dc_store_req_addr[31:3] == sim_tohost_addr[31:3]);
    assign tb_tohost_store_data = u_core.dc_store_req_data;

    // Latch the endpoint pulse into a sticky flop so external drivers can
    // observe it even if they sample in a later half-cycle.
    logic        tb_tohost_seen_q;
    logic [63:0] tb_tohost_data_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tb_tohost_seen_q <= 1'b0;
            tb_tohost_data_q <= 64'd0;
        end else if (tb_tohost_store_valid && !tb_tohost_seen_q) begin
            tb_tohost_seen_q <= 1'b1;
            tb_tohost_data_q <= tb_tohost_store_data;
        end
    end

    assign tohost_valid = tb_tohost_seen_q;
    assign tohost_value = tb_tohost_data_q;

    // Benchmark result block snoop. Bare-metal benchmarks write these registers
    // before tohost so host scripts can calculate CoreMark/MHz, DMIPS/MHz, or
    // SPEC ratio-per-MHz from the core's own cycle counters.
    localparam logic [63:0] BENCH_RESULT_BASE = 64'h8000_1080;
    localparam logic [63:0] BENCH_RESULT_END  = 64'h8000_1140;
    localparam logic [63:0] BENCH_CTRL_START  = 64'd1;
    localparam logic [63:0] BENCH_CTRL_STOP   = 64'd2;

    logic        bench_timer_active;
    logic [63:0] bench_start_mcycle;
    logic [63:0] bench_start_minstret;

    function automatic string bench_result_field_name(input int index);
        case (index)
            0: bench_result_field_name = "magic";
            1: bench_result_field_name = "bench_id";
            2: bench_result_field_name = "iterations";
            3: bench_result_field_name = "cycles";
            4: bench_result_field_name = "instret";
            5: bench_result_field_name = "checksum";
            6: bench_result_field_name = "flags";
            7: bench_result_field_name = "control";
            8: bench_result_field_name = "debug_seedcrc";
            9: bench_result_field_name = "debug_known_id";
            10: bench_result_field_name = "debug_crclist";
            11: bench_result_field_name = "debug_crclist_expected";
            12: bench_result_field_name = "debug_crcmatrix";
            13: bench_result_field_name = "debug_crcmatrix_expected";
            14: bench_result_field_name = "debug_crcstate";
            15: bench_result_field_name = "debug_crcstate_expected";
            16: bench_result_field_name = "debug_result_err";
            17: bench_result_field_name = "debug_data_type_err";
            18: bench_result_field_name = "debug_total_after_crc";
            19: bench_result_field_name = "debug_total_after_dtype";
            20: bench_result_field_name = "debug_time_secs";
            21: bench_result_field_name = "debug_total_final";
            22: bench_result_field_name = "debug_crcfinal";
            default: bench_result_field_name = "reserved";
        endcase
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bench_timer_active <= 1'b0;
            bench_start_mcycle <= 64'd0;
            bench_start_minstret <= 64'd0;
        end else if (u_core.dc_store_req_valid && u_core.dc_store_ack &&
                     (u_core.dc_store_req_addr >= BENCH_RESULT_BASE) &&
                     (u_core.dc_store_req_addr < BENCH_RESULT_END)) begin
            automatic int bench_result_index;
            bench_result_index =
                int'((u_core.dc_store_req_addr - BENCH_RESULT_BASE) >> 3);
            $display("[BENCH_RESULT] index=%0d field=%s value=%0d hex=%016h",
                     bench_result_index,
                     bench_result_field_name(bench_result_index),
                     u_core.dc_store_req_data,
                     u_core.dc_store_req_data);
            if ((bench_result_index == 7) &&
                (u_core.dc_store_req_data == BENCH_CTRL_START)) begin
                bench_timer_active <= 1'b1;
                bench_start_mcycle <= perf_mcycle;
                bench_start_minstret <= perf_minstret;
            end else if ((bench_result_index == 7) &&
                         (u_core.dc_store_req_data == BENCH_CTRL_STOP)) begin
                automatic logic [63:0] bench_cycles;
                automatic logic [63:0] bench_instret;
                bench_cycles =
                    bench_timer_active ? (perf_mcycle - bench_start_mcycle) : 64'd0;
                bench_instret =
                    bench_timer_active ? (perf_minstret - bench_start_minstret) : 64'd0;
                bench_timer_active <= 1'b0;
                $display("[BENCH_RESULT] index=3 field=cycles value=%0d hex=%016h",
                         bench_cycles, bench_cycles);
                $display("[BENCH_RESULT] index=4 field=instret value=%0d hex=%016h",
                         bench_instret, bench_instret);
            end
        end
    end

    // =========================================================================
    // Commit PC tracing (enabled with +TRACE_COMMIT)
    // =========================================================================
    // Dumps every committed PC to stdout so we can post-process in Python.
    // Enabled only when +TRACE_COMMIT is passed on the simulator command line.
    logic trace_commit_en;
    logic trace_dep_en;
    logic trace_uoplife_en;
    logic trace_pipeline_en;
    logic trace_bru_en;
    logic trace_a0map_en;
    logic trace_a5map_en;
    logic trace_spmap_en;
    logic trace_uoc_en;
    logic trace_ordv_en;
    logic trace_wdog_en;
    logic trace_lsu_fwd_en;
    logic trace_lsu_p1_en;
    logic trace_listptr_en;
    logic trace_iqld_watch_en;
    logic trace_head_stall_en;
    logic trace_coremark_progress_en;
    logic trace_coremark_exit_en;
    logic trace_matrix_branch_en;
    logic trace_commit_hotspots_en;
    logic trace_ralink_en;
    int   trace_iqld_watch_rob;
    int   trace_listptr_start;
    // ----------------------------------------------------------------
    // Golden PC scoreboard (commit-aligned, run_class-independent).
    //   +EMIT_COMMIT_PC_HEX=<path>  emits one $readmemh-format hex line
    //                                per committed PC (slot order).
    //   +CHECK_GOLDEN_PCS=<path>    loads that file and asserts every
    //                                committed PC matches; emits one
    //                                [GOLDEN_PC TRIP ...] line on first
    //                                divergence and $finish(2).
    // ----------------------------------------------------------------
    logic        golden_check_en;
    logic        golden_emit_en;
    string       golden_check_path;
    string       golden_emit_path;
    integer      golden_emit_fd;
    logic [63:0] golden_q [$];
    longint      golden_size;
    longint      golden_seq_r;
    logic        golden_tripped_r;
    initial begin
        trace_commit_en = 0;
        trace_dep_en    = 0;
        trace_uoplife_en = 0;
        trace_pipeline_en = 0;
        trace_bru_en    = 0;
        trace_a0map_en  = 0;
        trace_a5map_en  = 0;
        trace_spmap_en  = 0;
        trace_uoc_en    = 0;
        trace_ordv_en   = 0;
        trace_wdog_en   = 0;
        trace_lsu_fwd_en = 0;
        trace_lsu_p1_en = 0;
        trace_listptr_en = 0;
        trace_iqld_watch_en = 0;
        trace_head_stall_en = 0;
        trace_coremark_progress_en = 0;
        trace_coremark_exit_en = 0;
        trace_matrix_branch_en = 0;
        trace_commit_hotspots_en = 0;
        trace_ralink_en = 0;
        trace_iqld_watch_rob = -1;
        trace_listptr_start = 0;
        if ($test$plusargs("TRACE_COMMIT")) trace_commit_en = 1;
        if ($test$plusargs("TRACE_DEP"))    trace_dep_en    = 1;
        if ($test$plusargs("TRACE_UOPLIFE")) trace_uoplife_en = 1;
        if ($test$plusargs("TRACE_PIPELINE")) trace_pipeline_en = 1;
        if ($test$plusargs("TRACE_BRU"))    trace_bru_en    = 1;
        if ($test$plusargs("TRACE_A0MAP"))  trace_a0map_en  = 1;
        if ($test$plusargs("TRACE_A5MAP"))  trace_a5map_en  = 1;
        if ($test$plusargs("TRACE_SPMAP"))  trace_spmap_en  = 1;
        if ($test$plusargs("TRACE_UOC"))
            trace_uoc_en = 1;
        if ($test$plusargs("TRACE_ORDV"))   trace_ordv_en   = 1;
        if ($test$plusargs("TRACE_WDOG"))   trace_wdog_en   = 1;
        if ($test$plusargs("TRACE_LSU_FWD")) trace_lsu_fwd_en = 1;
        if ($test$plusargs("TRACE_LSU_P1"))  trace_lsu_p1_en  = 1;
        if ($test$plusargs("TRACE_LISTPTR")) trace_listptr_en = 1;
        if ($value$plusargs("TRACE_LISTPTR_START=%d", trace_listptr_start))
            trace_listptr_en = 1;
        if ($test$plusargs("TRACE_HEAD_STALL")) trace_head_stall_en = 1;
        if ($test$plusargs("TRACE_COREMARK_PROGRESS")) trace_coremark_progress_en = 1;
        if ($test$plusargs("TRACE_COREMARK_EXIT")) trace_coremark_exit_en = 1;
        if ($test$plusargs("TRACE_MATRIX_BRANCH")) trace_matrix_branch_en = 1;
        if ($test$plusargs("TRACE_COMMIT_HOTSPOTS")) trace_commit_hotspots_en = 1;
        if ($test$plusargs("TRACE_RALINK")) trace_ralink_en = 1;
        if ($test$plusargs("TRACE_IQLD")) begin
            trace_iqld_watch_en = 1;
            trace_iqld_watch_rob = 113;
        end
        if ($value$plusargs("TRACE_IQLD_ROB=%d", trace_iqld_watch_rob))
            trace_iqld_watch_en = 1;
        if (trace_iqld_watch_en)
            $display("[TRACE_CFG] iqld_watch_rob=%0d", trace_iqld_watch_rob);

        // Golden PC scoreboard plusargs
        golden_check_en  = 0;
        golden_emit_en   = 0;
        golden_emit_fd   = 0;
        golden_seq_r     = 0;
        golden_tripped_r = 0;
        golden_size      = 0;
        if ($value$plusargs("CHECK_GOLDEN_PCS=%s", golden_check_path)) begin
            integer       fd;
            logic [63:0]  tmp_pc;
            int           rc;
            fd = $fopen(golden_check_path, "r");
            if (fd == 0) begin
                $display("[GOLDEN_PC ERROR] cannot open %s for read",
                    golden_check_path);
                $finish(2);
            end
            while (!$feof(fd)) begin
                rc = $fscanf(fd, "%h", tmp_pc);
                if (rc == 1) golden_q.push_back(tmp_pc);
            end
            $fclose(fd);
            golden_size = golden_q.size();
            golden_check_en = (golden_size > 0);
            $display("[GOLDEN_PC LOADED] path=%s entries=%0d",
                golden_check_path, golden_size);
        end
        if ($value$plusargs("EMIT_COMMIT_PC_HEX=%s", golden_emit_path)) begin
            golden_emit_fd = $fopen(golden_emit_path, "w");
            if (golden_emit_fd == 0) begin
                $display("[GOLDEN_PC ERROR] cannot open %s for write",
                    golden_emit_path);
                $finish(2);
            end
            golden_emit_en = 1;
            $display("[GOLDEN_PC EMITTING] path=%s", golden_emit_path);
        end
    end

    function automatic logic [7:0] tb_byte_mask(
        input logic [1:0] size,
        input logic [63:0] addr
    );
        logic [2:0] off;
        begin
            off = addr[2:0];
            case (size)
                2'd0:    tb_byte_mask = 8'h01 << off;
                2'd1:    tb_byte_mask = 8'h03 << off;
                2'd2:    tb_byte_mask = 8'h0F << off;
                default: tb_byte_mask = 8'hFF;
            endcase
        end
    endfunction

    function automatic logic [ROB_IDX_BITS:0] tb_rob_age_from_head(
        input logic [ROB_IDX_BITS-1:0] idx,
        input logic [ROB_IDX_BITS-1:0] head
    );
        begin
            if (idx >= head)
                tb_rob_age_from_head = {1'b0, idx} - {1'b0, head};
            else
                tb_rob_age_from_head = ROB_DEPTH[ROB_IDX_BITS:0]
                                     - {1'b0, head}
                                     + {1'b0, idx};
        end
    endfunction

    function automatic logic [5:0] tb_pc_div_hash(input logic [63:0] pc);
        begin
            tb_pc_div_hash = pc[7:2] ^ pc[13:8] ^ pc[19:14] ^ pc[25:20];
        end
    endfunction

    function automatic int tb_count_ones64(input logic [63:0] value);
        int count;
        begin
            count = 0;
            for (int i = 0; i < 64; i++) begin
                if (value[i])
                    count++;
            end
            tb_count_ones64 = count;
        end
    endfunction

    function automatic int tb_coremark_progress_index(input logic [63:0] pc);
        begin
            case (pc)
                64'h0000_0000_8000_2012: tb_coremark_progress_index = 0;  // rv64gc_bench_stop
                64'h0000_0000_8000_2070: tb_coremark_progress_index = 1;  // start_time
                64'h0000_0000_8000_208a: tb_coremark_progress_index = 2;  // stop_time
                64'h0000_0000_8000_274e: tb_coremark_progress_index = 3;  // iterate
                64'h0000_0000_8000_29d2: tb_coremark_progress_index = 4;  // calibration start_time
                64'h0000_0000_8000_29d8: tb_coremark_progress_index = 5;  // calibration iterate
                64'h0000_0000_8000_29dc: tb_coremark_progress_index = 6;  // calibration stop_time
                64'h0000_0000_8000_2a0a: tb_coremark_progress_index = 7;  // timed start_time
                64'h0000_0000_8000_2a22: tb_coremark_progress_index = 8;  // timed iterate call
                64'h0000_0000_8000_2a26: tb_coremark_progress_index = 9;  // timed stop_time call
                64'h0000_0000_8000_23d2: tb_coremark_progress_index = 10; // core_bench_list
                64'h0000_0000_8000_34b4: tb_coremark_progress_index = 11; // core_bench_matrix
                64'h0000_0000_8000_380a: tb_coremark_progress_index = 12; // core_bench_state
                64'h0000_0000_8000_31f4: tb_coremark_progress_index = 13; // matrix_test
                64'h0000_0000_8000_30dc: tb_coremark_progress_index = 14; // matrix_mul_vect
                64'h0000_0000_8000_311a: tb_coremark_progress_index = 15; // matrix_mul_matrix
                64'h0000_0000_8000_317e: tb_coremark_progress_index = 16; // matrix_mul_matrix_bitextract
                64'h0000_0000_8000_31f0: tb_coremark_progress_index = 17; // matrix_mul_matrix_bitextract ret
                64'h0000_0000_8000_33b6: tb_coremark_progress_index = 18; // after bitextract return
                64'h0000_0000_8000_343c: tb_coremark_progress_index = 19; // matrix_test epilogue
                64'h0000_0000_8000_34ca: tb_coremark_progress_index = 20; // after matrix_test return
                default:                  tb_coremark_progress_index = -1;
            endcase
        end
    endfunction

    function automatic logic tb_coremark_exit_pc(input logic [63:0] pc);
        begin
            tb_coremark_exit_pc =
                ((pc >= 64'h0000_0000_8000_2000) &&
                 (pc <  64'h0000_0000_8000_2100)) || // bench write/report/time helpers
                ((pc >= 64'h0000_0000_8000_2a00) &&
                 (pc <  64'h0000_0000_8000_2f40)) || // main validation and epilogue
                ((pc >= 64'h0000_0000_8000_029c) &&
                 (pc <  64'h0000_0000_8000_02c0));   // _start after main returns
        end
    endfunction

    function automatic logic tb_coremark_bad_fetch_pc(input logic [63:0] pc);
        begin
            tb_coremark_bad_fetch_pc =
                (pc >= 64'h0000_0000_8000_20e0) &&
                (pc <  64'h0000_0000_8000_20f8);
        end
    endfunction

    function automatic logic tb_coremark_mmio_addr(input logic [63:0] addr);
        begin
            tb_coremark_mmio_addr =
                ((addr >= BENCH_RESULT_BASE) && (addr < BENCH_RESULT_END)) ||
                (addr[31:3] == sim_tohost_addr[31:3]);
        end
    endfunction

    function automatic logic tb_low_text_pc(input logic [63:0] pc);
        begin
            tb_low_text_pc =
                (pc != 64'd0) &&
                (pc[63:32] == 32'd0) &&
                (pc[31:0] < 32'h0010_0000);
        end
    endfunction

    function automatic logic tb_coremark_ra_path_pc(input logic [63:0] pc);
        begin
            tb_coremark_ra_path_pc =
                ((pc >= 64'h0000_0000_8000_22d0) &&
                 (pc <  64'h0000_0000_8000_23d0)) || // calc_func / cmp_complex
                ((pc >= 64'h0000_0000_8000_2550) &&
                 (pc <  64'h0000_0000_8000_2580));   // indirect cmp_complex caller
        end
    endfunction

    function automatic logic tb_coremark_list_ptr_pc(input logic [63:0] pc);
        begin
            tb_coremark_list_ptr_pc =
                (pc >= 64'h0000_0000_8000_250c) &&
                (pc <  64'h0000_0000_8000_2580);
        end
    endfunction

    // =========================================================================
    // Per-stage pipeline counters (enabled with +PERF_PROFILE)
    // =========================================================================
    logic pp_en;
    logic btl_en;
    initial begin
        pp_en = 0;
        btl_en = 0;
        if ($test$plusargs("PERF_PROFILE")) pp_en = 1;
        if ($test$plusargs("BOTTLENECK_PROFILE")) begin
            pp_en = 1;
            btl_en = 1;
        end
    end

    // Raw fetch histogram: cycles where fetch_count = N from fetch_top
    integer fetch_hist [0:6];
    // Effective frontend histogram: cycles where rename sees N instructions
    integer frontend_hist [0:6];
    // Split the effective frontend histogram by source
    integer fused_hist [0:6];
    integer uoc_replay_hist [0:6];
    // Decoded-op replay group-size histogram while active; bucket 6 means >=6
    integer uoc_group_hist [0:6];
    // Commit histogram: cycles where commit_count = N
    integer commit_hist [0:6];
    // Standalone decoded-op replay active cycles. Scoreable Stage 1 rows
    // require this to remain zero.
    integer uoc_active_cycles;
    // µop cache counters
    integer uoc_lookup_total;
    integer uoc_hit_total;
    integer uoc_miss_total;
    integer uoc_fill_total;
    integer uoc_fill_evict_total;
    integer uoc_enter_playing_total;
    integer uoc_exit_miss_total;
    integer uoc_exit_nohit_total;
    integer uoc_exit_unsafe_total;
    integer uoc_emit_total;
    integer uoc_emit_control_total;
    integer uoc_emit_cond_total;
    integer uoc_emit_jal_total;
    integer uoc_emit_jalr_total;
    integer uoc_emit_pred_taken_total;
    integer uoc_emit_uops_total;
    integer uoc_emit_control_uops_total;
    integer uoc_active_flush_total;
    integer uoc_invalidate_total;
    // Stall counters
    integer rename_stall_cyc;
    integer rob_full_cyc;
    integer dq_full_cyc;
    integer lq_full_cyc;
    integer sq_full_cyc;
    integer iq0_full_cyc;
    integer iq1_full_cyc;
    integer iq2_full_cyc;
    integer iq0_cnt_sum, iq1_cnt_sum, iq2_cnt_sum;
    // Issue-stall classification (Phase A.2): per-cycle bucketing of why
    // issued count was less than peak. OR semantics across all 3 IQs.
    integer issue_stall_operand_cyc;   // entries valid but no src ready
    integer issue_stall_fu_cyc;        // operands ready but FU suppress dropped grant
    integer issue_stall_arb_cyc;       // eligible_count > NUM_SELECT (selection ceiling)
    integer iq0_operand_stall_cyc, iq1_operand_stall_cyc, iq2_operand_stall_cyc;
    integer iq0_arb_loss_cyc, iq1_arb_loss_cyc, iq2_arb_loss_cyc;
    integer iq0_issue_uops, iq1_issue_uops, iq2_issue_uops;
    integer iq0_eligible_sum, iq1_eligible_sum, iq2_eligible_sum;
    localparam int BTL_IQ0 = 0;
    localparam int BTL_IQ1 = 1;
    localparam int BTL_IQ2 = 2;
    localparam int BTL_IQ_LOAD = 3;
    localparam int BTL_IQ_STORE = 4;
    localparam int BTL_IQ_STD = 5;
    localparam int BTL_IQ_COUNT = 6;
    localparam int BTL_PROD_UNKNOWN = 0;
    localparam int BTL_PROD_ALU = 1;
    localparam int BTL_PROD_LOAD = 2;
    localparam int BTL_PROD_BRANCH = 3;
    localparam int BTL_PROD_MUL = 4;
    localparam int BTL_PROD_DIV = 5;
    localparam int BTL_PROD_STORE = 6;
    localparam int BTL_PROD_CSR = 7;
    integer btl_iq_valid_entry_sum [0:BTL_IQ_COUNT-1];
    integer btl_iq_ready_entry_sum [0:BTL_IQ_COUNT-1];
    integer btl_iq_not_ready_entry_sum [0:BTL_IQ_COUNT-1];
    integer btl_iq_eligible_zero_cycles [0:BTL_IQ_COUNT-1];
    integer btl_iq_eligible_one_cycles [0:BTL_IQ_COUNT-1];
    integer btl_iq_eligible_multi_cycles [0:BTL_IQ_COUNT-1];
    integer btl_iq_selected_uops [0:BTL_IQ_COUNT-1];
    integer btl_iq_arb_loss [0:BTL_IQ_COUNT-1];
    integer btl_iq_oldest_not_ready_age_max [0:BTL_IQ_COUNT-1];
    integer btl_iq_enq_ready_hidden [0:BTL_IQ_COUNT-1];
    integer btl_iq_enq_ready_issued_bypass [0:BTL_IQ_COUNT-1];
    integer btl_iq_enq_wakeup_hit [0:BTL_IQ_COUNT-1];
    integer btl_iq_enq_bypass_suppressed [0:BTL_IQ_COUNT-1];
    integer btl_iq_enq_bypass_fu_blocked [0:BTL_IQ_COUNT-1];
    integer btl_iq_enq_bypass_fu_blocked_bru_cond [0:BTL_IQ_COUNT-1];
    integer btl_iq_enq_bypass_fu_blocked_bru_backedge [0:BTL_IQ_COUNT-1];
    integer btl_iq_enq_bypass_fu_blocked_bru_jal [0:BTL_IQ_COUNT-1];
    integer btl_iq_enq_bypass_fu_blocked_bru_jalr [0:BTL_IQ_COUNT-1];
    integer btl_iq_enq_bypass_fu_blocked_serial [0:BTL_IQ_COUNT-1];
    integer btl_dep_src1_wait;
    integer btl_dep_src2_wait;
    integer btl_dep_both_src_wait;
    integer btl_dep_wait_on_alu;
    integer btl_dep_wait_on_load;
    integer btl_dep_wait_on_branch;
    integer btl_dep_wait_on_mul;
    integer btl_dep_wait_on_div;
    integer btl_dep_wait_on_store;
    integer btl_dep_wait_on_csr;
    integer btl_dep_wait_on_unknown;
    integer btl_wakeup_same_cycle_candidate;
    integer btl_wakeup_same_cycle_missed;
    integer btl_rename_slots_lost_total;
    integer btl_rename_free_preg_min;
    integer btl_rename_rob_free_min;
    integer btl_backend_throttle_active_cycles;
    integer btl_backend_throttle_enter_cycles;
    integer btl_backend_throttle_pressure_cycles;
    integer btl_backend_throttle_head_block_cycles;
    integer btl_backend_throttle_limited_slots;
    integer btl_rob_younger_ready_behind_head;
    integer btl_rob_commit_slots_lost_head_block;
    integer btl_preg_class [0:INT_PRF_DEPTH-1];
    integer macro_fused_rename_total;
    integer macro_fused_commit_total;
    integer macro_fused_commit_alu;
    integer macro_fused_commit_branch;
    integer macro_fused_commit_load;
    integer macro_fused_commit_store;
    integer rename_move_candidate_total;
    integer rename_zero_elim_total;
    integer backend_stall_cyc;
    integer flush_cyc;
    integer perf_total_cyc;
    integer uoc_commit_no_load_cyc;
    integer uoc_commit_no_load_run;
    integer uoc_commit_no_load_run_max;
    integer fetch_zero_total_cyc;
    integer fetch_zero_frontend_hold_cyc;
    integer fetch_zero_redirect_cyc;
    integer fetch_zero_pkt_empty_cyc;
    integer fetch_zero_pkt_valid_cyc;
    integer fetch_zero_ftq_full_cyc;
    integer fetch_zero_pkt_full_cyc;
    integer fetch_zero_wait_icresp_cyc;
    integer fetch_zero_icreq_live_cyc;
    integer fetch_zero_f2_wait_cyc;
    integer fetch_zero_pkt_empty_enq_cyc;
    integer fetch_zero_enq_ctl_cyc;
    integer fetch_zero_enq_noctl_cyc;
    integer fetch_zero_enq_ctl_cond_cyc;
    integer fetch_zero_enq_ctl_cond_nt_cyc;
    integer fetch_zero_enq_ctl_taken_cyc;
    integer fetch_zero_enq_ctl_callret_cyc;
    integer fetch_zero_enq_ctl_other_cyc;
    integer fetch_zero_enq_owner_done_cyc;
    integer fetch_zero_enq_ftq_match_cyc;
    integer fetch_zero_f2_data_cyc;
    integer fetch_zero_f2_emit_cyc;
    integer fetch_zero_no_emit_dup_cyc;
    integer fetch_zero_no_emit_extract0_cyc;
    integer fetch_zero_no_emit_other_cyc;
    integer fetch_zero_other_cyc;
    integer ld0_candidate_cyc, ld0_issue_cyc, ld0_suppress_cyc;
    integer ld1_candidate_cyc, ld1_issue_cyc, ld1_suppress_cyc;
    integer sq_fwd_wait_cyc, sq_wait_p1_cyc;
    integer storeiq_block_ld0_cyc, storeiq_block_ld1_cyc;
    integer storeiq_block_ld0_with_sta_issue_cyc, storeiq_block_ld1_with_sta_issue_cyc;
    integer p0_fwd_req_cyc;
    integer p0_sq_ready_full_cyc, p0_sq_ready_partial_cyc;
    integer p0_sq_wait_only_cyc;
    integer p0_same_cycle_hit_cyc, p0_csb_hit_cyc;
    integer p1_wait_req_cyc;
    integer p1_sq_ready_full_cyc, p1_sq_ready_partial_cyc;
    integer p1_sq_wait_only_cyc;
    integer p1_dcache_conflict_cyc;
    integer p1_retry_valid_cyc, p1_retry_capture_cyc;
    localparam int LOAD_LAT_BUCKETS = 10;
    localparam int LOAD_LAT_PC_HIST_SLOTS = 24;
    localparam int LOAD_SRC_DCHIT  = 0;
    localparam int LOAD_SRC_FWD    = 1;
    localparam int LOAD_SRC_LMB    = 2;
    localparam int LOAD_SRC_MISALN = 3;
    localparam int LOAD_SRC_UNK    = 4;
    logic   load_lat_track_valid [0:ROB_DEPTH-1];
    integer load_lat_issue_cycle [0:ROB_DEPTH-1];
    logic [63:0] load_lat_issue_pc [0:ROB_DEPTH-1];
    logic        load_lat_issue_port [0:ROB_DEPTH-1];
    integer load_lat_issue_total, load_lat_reissue_total;
    integer load_lat_wb_total, load_lat_wb_untracked_total;
    integer load_lat_hist [0:LOAD_LAT_BUCKETS-1];
    integer load_lat_src_count [0:LOAD_SRC_UNK];
    integer load_lat_pending_sum, load_lat_pending_max;
    logic [63:0] load_lat_pc_hist_pc [0:LOAD_LAT_PC_HIST_SLOTS-1];
    integer load_lat_pc_hist_count [0:LOAD_LAT_PC_HIST_SLOTS-1];
    integer load_lat_pc_hist_sum [0:LOAD_LAT_PC_HIST_SLOTS-1];
    integer load_lat_pc_hist_max [0:LOAD_LAT_PC_HIST_SLOTS-1];
    integer load_lat_pc_hist_dchit [0:LOAD_LAT_PC_HIST_SLOTS-1];
    integer load_lat_pc_hist_fwd [0:LOAD_LAT_PC_HIST_SLOTS-1];
    integer load_lat_pc_hist_lmb [0:LOAD_LAT_PC_HIST_SLOTS-1];
    integer load_lat_pc_hist_other [0:LOAD_LAT_PC_HIST_SLOTS-1];
    integer spec_wk_p0_cyc, spec_wk_p1_cyc;
    integer std_spec_match_p0_cyc, std_spec_match_p1_cyc;
    integer sta_issue_cyc, std_issue_cyc, dc_store_req_cyc;
    integer sq_addr_only_pending_sum, sq_addr_only_pending_max;
    integer sq_addr_to_data_lag_hist [0:4];
    integer sq_addr_to_data_drop_cyc;
    integer ctl_commit_cond_cyc, ctl_commit_jal_cyc, ctl_commit_jalr_cyc;
    integer ctl_commit_call_cyc, ctl_commit_ret_cyc;
    integer ctl_misp_cond_cyc, ctl_misp_jal_cyc, ctl_misp_jalr_cyc;
    integer ctl_misp_call_cyc, ctl_misp_ret_cyc;
    localparam int MISP_PC_HIST_SLOTS = 256;
    logic [63:0] misp_pc_hist_pc [0:MISP_PC_HIST_SLOTS-1];
    integer misp_pc_hist_count [0:MISP_PC_HIST_SLOTS-1];
    integer misp_pc_hist_cond [0:MISP_PC_HIST_SLOTS-1];
    integer misp_pc_hist_jal [0:MISP_PC_HIST_SLOTS-1];
    integer misp_pc_hist_jalr [0:MISP_PC_HIST_SLOTS-1];
    integer misp_pc_hist_call [0:MISP_PC_HIST_SLOTS-1];
    integer misp_pc_hist_ret [0:MISP_PC_HIST_SLOTS-1];
    integer misp_pc_hist_taken [0:MISP_PC_HIST_SLOTS-1];
    integer misp_pc_hist_ntaken [0:MISP_PC_HIST_SLOTS-1];
    integer ghr_restore_cyc, ghr_restore_nonzero_cyc;
    integer ras_restore_cyc;
    localparam int PC_DIV_WINDOW_CYC = 1024;
    localparam int PC_DIV_LOW_UNIQUE_THRESH = 8;
    logic [63:0] pc_div_bitmap;
    integer pc_div_window_cyc;
    integer pc_div_windows_total;
    integer pc_div_low_windows;
    integer pc_div_min_unique;
    integer pc_div_max_unique;
`ifdef SIMULATION
    integer uoc_mixedpath_cyc;
`endif
    // Rename stall source breakdown: fires when rename stalls, tags the
    // first missing resource on slot 0 (other slots typically cascade).
    integer stall_preg_cyc, stall_ckpt_cyc, stall_rob_cyc, stall_dq_cyc;
    integer stall_backend_throttle_cyc, stall_other_cyc;
    logic   prev_p1_retry_valid;
    logic   dbg_p0_sq_ready_full;
    logic   dbg_p0_sq_ready_partial;
    logic   dbg_p0_sq_wait_missing;
    logic   dbg_p1_sq_ready_full;
    logic   dbg_p1_sq_ready_partial;
    logic   dbg_p1_sq_wait_missing;
    logic   dbg_std_spec_match_p0;
    logic   dbg_std_spec_match_p1;
    logic   sq_addr_only_track_valid [0:SQ_DEPTH-1];
    integer sq_addr_only_track_age   [0:SQ_DEPTH-1];

    always_comb begin
        logic [7:0] req0_mask;
        logic [ROB_IDX_BITS:0] req0_age;
        logic [7:0] req_mask;
        logic [ROB_IDX_BITS:0] req_age;

        dbg_p0_sq_ready_full    = 1'b0;
        dbg_p0_sq_ready_partial = 1'b0;
        dbg_p0_sq_wait_missing  = 1'b0;
        dbg_p1_sq_ready_full    = 1'b0;
        dbg_p1_sq_ready_partial = 1'b0;
        dbg_p1_sq_wait_missing  = 1'b0;
        dbg_std_spec_match_p0   = 1'b0;
        dbg_std_spec_match_p1   = 1'b0;

        req0_mask = tb_byte_mask(u_core.u_lsu.load_issue_data[0].mem_size,
                                 u_core.u_lsu.load_eff_addr[0]);
        req0_age  = tb_rob_age_from_head(u_core.u_lsu.load_issue_data[0].rob_idx,
                                         u_core.rob_head_idx);
        req_mask = tb_byte_mask(u_core.u_lsu.p1_wait_req_size,
                                u_core.u_lsu.p1_wait_req_addr);
        req_age  = tb_rob_age_from_head(u_core.u_lsu.p1_wait_req_rob_idx,
                                        u_core.rob_head_idx);

        for (int sqe = 0; sqe < SQ_DEPTH; sqe++) begin
            logic [7:0] ent_mask;
            logic [7:0] overlap0;
            logic [7:0] overlap;
            logic [ROB_IDX_BITS:0] store_age0;
            logic [ROB_IDX_BITS:0] store_age;
            logic store0_is_older;
            logic store_is_older;
            logic addr0_match;
            logic addr_match;

            ent_mask = tb_byte_mask(u_core.u_lsu.u_store_queue.queue[sqe].size,
                                    u_core.u_lsu.u_store_queue.queue[sqe].addr);
            store_age0 = tb_rob_age_from_head(
                u_core.u_lsu.u_store_queue.queue[sqe].rob_idx,
                u_core.rob_head_idx
            );
            store_age = tb_rob_age_from_head(
                u_core.u_lsu.u_store_queue.queue[sqe].rob_idx,
                u_core.rob_head_idx
            );
            store0_is_older =
                u_core.iq_load_issue_candidate_valid[0] &&
                !u_core.u_lsu.load_addr_misaligned[0] &&
                !u_core.flush_out.valid &&
                u_core.u_lsu.u_store_queue.queue[sqe].valid &&
                (u_core.u_lsu.u_store_queue.queue[sqe].committed ||
                 (store_age0 < req0_age));
            store_is_older =
                u_core.u_lsu.p1_wait_req_valid &&
                u_core.u_lsu.u_store_queue.queue[sqe].valid &&
                (u_core.u_lsu.u_store_queue.queue[sqe].committed ||
                 (store_age < req_age));
            addr0_match =
                store0_is_older &&
                u_core.u_lsu.u_store_queue.queue[sqe].addr_valid &&
                (u_core.u_lsu.u_store_queue.queue[sqe].addr[63:3] ==
                 u_core.u_lsu.load_eff_addr[0][63:3]);
            addr_match =
                store_is_older &&
                u_core.u_lsu.u_store_queue.queue[sqe].addr_valid &&
                (u_core.u_lsu.u_store_queue.queue[sqe].addr[63:3] ==
                 u_core.u_lsu.p1_wait_req_addr[63:3]);
            overlap0 = addr0_match ? (ent_mask & req0_mask) : 8'h00;
            overlap = addr_match ? (ent_mask & req_mask) : 8'h00;

            if (u_core.u_lsu.u_store_queue.queue[sqe].data_valid ||
                (u_core.routed_std_valid &&
                 (u_core.routed_std_data.sq_idx == SQ_IDX_BITS'(sqe)))) begin
                if (overlap0 == req0_mask && req0_mask != 8'h00)
                    dbg_p0_sq_ready_full = 1'b1;
                else if (overlap0 != 8'h00)
                    dbg_p0_sq_ready_partial = 1'b1;
                if (overlap == req_mask && req_mask != 8'h00)
                    dbg_p1_sq_ready_full = 1'b1;
                else if (overlap != 8'h00)
                    dbg_p1_sq_ready_partial = 1'b1;
            end else if (overlap0 != 8'h00) begin
                dbg_p0_sq_wait_missing = 1'b1;
            end else if (overlap != 8'h00) begin
                dbg_p1_sq_wait_missing = 1'b1;
            end
        end

        for (int e = 0; e < IQ_MEM_DEPTH; e++) begin
            if (u_core.u_iq_store_data.entry_valid[e] &&
                !u_core.u_iq_store_data.src2_ready[e]) begin
                if (u_core.lsu_spec_wakeup_valid[0] &&
                    (u_core.u_iq_store_data.rs2_phys_r[e] ==
                     u_core.lsu_spec_wakeup_tag[0]))
                    dbg_std_spec_match_p0 = 1'b1;
                if (u_core.lsu_spec_wakeup_valid[1] &&
                    (u_core.u_iq_store_data.rs2_phys_r[e] ==
                     u_core.lsu_spec_wakeup_tag[1]))
                    dbg_std_spec_match_p1 = 1'b1;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 7; i++) begin
                fetch_hist[i]     <= 0;
                frontend_hist[i]  <= 0;
                fused_hist[i]     <= 0;
                uoc_replay_hist[i] <= 0;
                uoc_group_hist[i]  <= 0;
                commit_hist[i]    <= 0;
            end
            uoc_active_cycles  <= 0;
            uoc_lookup_total          <= 0;
            uoc_hit_total             <= 0;
            uoc_miss_total            <= 0;
            uoc_fill_total            <= 0;
            uoc_fill_evict_total      <= 0;
            uoc_enter_playing_total   <= 0;
            uoc_exit_miss_total       <= 0;
            uoc_exit_nohit_total      <= 0;
            uoc_exit_unsafe_total     <= 0;
            uoc_emit_total            <= 0;
            uoc_emit_control_total    <= 0;
            uoc_emit_cond_total       <= 0;
            uoc_emit_jal_total        <= 0;
            uoc_emit_jalr_total       <= 0;
            uoc_emit_pred_taken_total <= 0;
            uoc_emit_uops_total       <= 0;
            uoc_emit_control_uops_total <= 0;
            uoc_active_flush_total    <= 0;
            uoc_invalidate_total      <= 0;
            rename_stall_cyc   <= 0;
            rob_full_cyc       <= 0;
            dq_full_cyc        <= 0;
            lq_full_cyc        <= 0;
            sq_full_cyc        <= 0;
            iq0_full_cyc       <= 0;
            iq1_full_cyc       <= 0;
            iq2_full_cyc       <= 0;
            iq0_cnt_sum        <= 0;
            iq1_cnt_sum        <= 0;
            iq2_cnt_sum        <= 0;
            backend_stall_cyc  <= 0;
            flush_cyc          <= 0;
            perf_total_cyc     <= 0;
            uoc_commit_no_load_cyc <= 0;
            uoc_commit_no_load_run <= 0;
            uoc_commit_no_load_run_max <= 0;
            fetch_zero_total_cyc <= 0;
            fetch_zero_frontend_hold_cyc <= 0;
            fetch_zero_redirect_cyc <= 0;
            fetch_zero_pkt_empty_cyc <= 0;
            fetch_zero_pkt_valid_cyc <= 0;
            fetch_zero_ftq_full_cyc <= 0;
            fetch_zero_pkt_full_cyc <= 0;
            fetch_zero_wait_icresp_cyc <= 0;
            fetch_zero_icreq_live_cyc <= 0;
            fetch_zero_f2_wait_cyc <= 0;
            fetch_zero_pkt_empty_enq_cyc <= 0;
            fetch_zero_enq_ctl_cyc <= 0;
            fetch_zero_enq_noctl_cyc <= 0;
            fetch_zero_enq_ctl_cond_cyc <= 0;
            fetch_zero_enq_ctl_cond_nt_cyc <= 0;
            fetch_zero_enq_ctl_taken_cyc <= 0;
            fetch_zero_enq_ctl_callret_cyc <= 0;
            fetch_zero_enq_ctl_other_cyc <= 0;
            fetch_zero_enq_owner_done_cyc <= 0;
            fetch_zero_enq_ftq_match_cyc <= 0;
            fetch_zero_f2_data_cyc <= 0;
            fetch_zero_f2_emit_cyc <= 0;
            fetch_zero_no_emit_dup_cyc <= 0;
            fetch_zero_no_emit_extract0_cyc <= 0;
            fetch_zero_no_emit_other_cyc <= 0;
            fetch_zero_other_cyc <= 0;
            ld0_candidate_cyc  <= 0;
            ld0_issue_cyc      <= 0;
            ld0_suppress_cyc   <= 0;
            ld1_candidate_cyc  <= 0;
            ld1_issue_cyc      <= 0;
            ld1_suppress_cyc   <= 0;
            sq_fwd_wait_cyc    <= 0;
            sq_wait_p1_cyc     <= 0;
            storeiq_block_ld0_cyc <= 0;
            storeiq_block_ld1_cyc <= 0;
            storeiq_block_ld0_with_sta_issue_cyc <= 0;
            storeiq_block_ld1_with_sta_issue_cyc <= 0;
            p0_fwd_req_cyc     <= 0;
            p0_sq_ready_full_cyc <= 0;
            p0_sq_ready_partial_cyc <= 0;
            p0_sq_wait_only_cyc <= 0;
            p0_same_cycle_hit_cyc <= 0;
            p0_csb_hit_cyc <= 0;
            p1_wait_req_cyc    <= 0;
            p1_sq_ready_full_cyc <= 0;
            p1_sq_ready_partial_cyc <= 0;
            p1_sq_wait_only_cyc <= 0;
            p1_dcache_conflict_cyc <= 0;
            p1_retry_valid_cyc <= 0;
            p1_retry_capture_cyc <= 0;
            load_lat_issue_total <= 0;
            load_lat_reissue_total <= 0;
            load_lat_wb_total <= 0;
            load_lat_wb_untracked_total <= 0;
            load_lat_pending_sum <= 0;
            load_lat_pending_max <= 0;
            for (int i = 0; i < ROB_DEPTH; i++) begin
                load_lat_track_valid[i] <= 1'b0;
                load_lat_issue_cycle[i] <= 0;
                load_lat_issue_pc[i]    <= 64'd0;
                load_lat_issue_port[i]  <= 1'b0;
            end
            for (int i = 0; i < LOAD_LAT_BUCKETS; i++) begin
                load_lat_hist[i] <= 0;
            end
            for (int i = 0; i <= LOAD_SRC_UNK; i++) begin
                load_lat_src_count[i] <= 0;
            end
            for (int i = 0; i < LOAD_LAT_PC_HIST_SLOTS; i++) begin
                load_lat_pc_hist_pc[i]    <= 64'd0;
                load_lat_pc_hist_count[i] <= 0;
                load_lat_pc_hist_sum[i]   <= 0;
                load_lat_pc_hist_max[i]   <= 0;
                load_lat_pc_hist_dchit[i] <= 0;
                load_lat_pc_hist_fwd[i]   <= 0;
                load_lat_pc_hist_lmb[i]   <= 0;
                load_lat_pc_hist_other[i] <= 0;
            end
            spec_wk_p0_cyc <= 0;
            spec_wk_p1_cyc <= 0;
            std_spec_match_p0_cyc <= 0;
            std_spec_match_p1_cyc <= 0;
            sta_issue_cyc      <= 0;
            std_issue_cyc      <= 0;
            dc_store_req_cyc   <= 0;
            sq_addr_only_pending_sum <= 0;
            sq_addr_only_pending_max <= 0;
            sq_addr_to_data_drop_cyc <= 0;
            for (int i = 0; i < 5; i++) begin
                sq_addr_to_data_lag_hist[i] <= 0;
            end
            for (int i = 0; i < SQ_DEPTH; i++) begin
                sq_addr_only_track_valid[i] <= 1'b0;
                sq_addr_only_track_age[i]   <= 0;
            end
            ctl_commit_cond_cyc <= 0;
            ctl_commit_jal_cyc  <= 0;
            ctl_commit_jalr_cyc <= 0;
            ctl_commit_call_cyc <= 0;
            ctl_commit_ret_cyc  <= 0;
            ctl_misp_cond_cyc   <= 0;
            ctl_misp_jal_cyc    <= 0;
            ctl_misp_jalr_cyc   <= 0;
            ctl_misp_call_cyc   <= 0;
            ctl_misp_ret_cyc    <= 0;
            for (int i = 0; i < MISP_PC_HIST_SLOTS; i++) begin
                misp_pc_hist_pc[i]     <= 64'd0;
                misp_pc_hist_count[i]  <= 0;
                misp_pc_hist_cond[i]   <= 0;
                misp_pc_hist_jal[i]    <= 0;
                misp_pc_hist_jalr[i]   <= 0;
                misp_pc_hist_call[i]   <= 0;
                misp_pc_hist_ret[i]    <= 0;
                misp_pc_hist_taken[i]  <= 0;
                misp_pc_hist_ntaken[i] <= 0;
            end
            ghr_restore_cyc     <= 0;
            ghr_restore_nonzero_cyc <= 0;
            ras_restore_cyc     <= 0;
            pc_div_bitmap       <= '0;
            pc_div_window_cyc   <= 0;
            pc_div_windows_total <= 0;
            pc_div_low_windows  <= 0;
            pc_div_min_unique   <= 64;
            pc_div_max_unique   <= 0;
`ifdef SIMULATION
            uoc_mixedpath_cyc   <= 0;
`endif
            stall_preg_cyc     <= 0;
            stall_ckpt_cyc     <= 0;
            stall_rob_cyc      <= 0;
            stall_dq_cyc       <= 0;
            stall_backend_throttle_cyc <= 0;
            stall_other_cyc    <= 0;
            issue_stall_operand_cyc <= 0;
            issue_stall_fu_cyc      <= 0;
            issue_stall_arb_cyc     <= 0;
            iq0_operand_stall_cyc   <= 0;
            iq1_operand_stall_cyc   <= 0;
            iq2_operand_stall_cyc   <= 0;
            iq0_arb_loss_cyc        <= 0;
            iq1_arb_loss_cyc        <= 0;
            iq2_arb_loss_cyc        <= 0;
            iq0_issue_uops          <= 0;
            iq1_issue_uops          <= 0;
            iq2_issue_uops          <= 0;
            iq0_eligible_sum        <= 0;
            iq1_eligible_sum        <= 0;
            iq2_eligible_sum        <= 0;
            for (int i = 0; i < BTL_IQ_COUNT; i++) begin
                btl_iq_valid_entry_sum[i] <= 0;
                btl_iq_ready_entry_sum[i] <= 0;
                btl_iq_not_ready_entry_sum[i] <= 0;
                btl_iq_eligible_zero_cycles[i] <= 0;
                btl_iq_eligible_one_cycles[i] <= 0;
                btl_iq_eligible_multi_cycles[i] <= 0;
                btl_iq_selected_uops[i] <= 0;
                btl_iq_arb_loss[i] <= 0;
                btl_iq_oldest_not_ready_age_max[i] <= 0;
                btl_iq_enq_ready_hidden[i] <= 0;
                btl_iq_enq_ready_issued_bypass[i] <= 0;
                btl_iq_enq_wakeup_hit[i] <= 0;
                btl_iq_enq_bypass_suppressed[i] <= 0;
                btl_iq_enq_bypass_fu_blocked[i] <= 0;
                btl_iq_enq_bypass_fu_blocked_bru_cond[i] <= 0;
                btl_iq_enq_bypass_fu_blocked_bru_backedge[i] <= 0;
                btl_iq_enq_bypass_fu_blocked_bru_jal[i] <= 0;
                btl_iq_enq_bypass_fu_blocked_bru_jalr[i] <= 0;
                btl_iq_enq_bypass_fu_blocked_serial[i] <= 0;
            end
            btl_dep_src1_wait <= 0;
            btl_dep_src2_wait <= 0;
            btl_dep_both_src_wait <= 0;
            btl_dep_wait_on_alu <= 0;
            btl_dep_wait_on_load <= 0;
            btl_dep_wait_on_branch <= 0;
            btl_dep_wait_on_mul <= 0;
            btl_dep_wait_on_div <= 0;
            btl_dep_wait_on_store <= 0;
            btl_dep_wait_on_csr <= 0;
            btl_dep_wait_on_unknown <= 0;
            btl_wakeup_same_cycle_candidate <= 0;
            btl_wakeup_same_cycle_missed <= 0;
            btl_rename_slots_lost_total <= 0;
            btl_rename_free_preg_min <= INT_PRF_DEPTH;
            btl_rename_rob_free_min <= ROB_DEPTH;
            btl_backend_throttle_active_cycles <= 0;
            btl_backend_throttle_enter_cycles <= 0;
            btl_backend_throttle_pressure_cycles <= 0;
            btl_backend_throttle_head_block_cycles <= 0;
            btl_backend_throttle_limited_slots <= 0;
            btl_rob_younger_ready_behind_head <= 0;
            btl_rob_commit_slots_lost_head_block <= 0;
            for (int i = 0; i < INT_PRF_DEPTH; i++) begin
                btl_preg_class[i] <= BTL_PROD_UNKNOWN;
            end
            macro_fused_rename_total <= 0;
            macro_fused_commit_total <= 0;
            macro_fused_commit_alu <= 0;
            macro_fused_commit_branch <= 0;
            macro_fused_commit_load <= 0;
            macro_fused_commit_store <= 0;
            rename_move_candidate_total <= 0;
            rename_zero_elim_total <= 0;
            prev_p1_retry_valid <= 1'b0;
        end else if (pp_en) begin
            automatic int frontend_bin;
            automatic int body_bin;
            automatic int sq_addr_only_pending_now;
            automatic int load_lat_pending_now;
            automatic logic [63:0] pc_div_next_bitmap;
            automatic int pc_div_unique_now;
            automatic int iq0_elig_cnt, iq1_elig_cnt, iq2_elig_cnt;
            automatic int iq0_issue_cnt, iq1_issue_cnt, iq2_issue_cnt;
            automatic int iq0_valid_cnt, iq1_valid_cnt, iq2_valid_cnt;
            automatic int fused_rename_cyc;
            automatic int fused_commit_cyc;
            automatic int fused_commit_alu_cyc;
            automatic int fused_commit_branch_cyc;
            automatic int fused_commit_load_cyc;
            automatic int fused_commit_store_cyc;
            automatic int move_candidate_cyc;
            automatic int zero_elim_cyc;
            automatic int misp_hit_idx;
            automatic int misp_free_idx;
            automatic int misp_min_idx;
            automatic int misp_min_count;
            automatic int misp_use_idx;
            automatic int btl_iq_valid_now [0:BTL_IQ_COUNT-1];
            automatic int btl_iq_ready_now [0:BTL_IQ_COUNT-1];
            automatic int btl_iq_eligible_now [0:BTL_IQ_COUNT-1];
            automatic int btl_iq_selected_now [0:BTL_IQ_COUNT-1];
            automatic int btl_iq_oldest_wait_now [0:BTL_IQ_COUNT-1];
            automatic int btl_iq_enq_ready_hidden_now [0:BTL_IQ_COUNT-1];
            automatic int btl_iq_enq_ready_issued_bypass_now [0:BTL_IQ_COUNT-1];
            automatic int btl_iq_enq_wakeup_hit_now [0:BTL_IQ_COUNT-1];
            automatic int btl_iq_enq_bypass_suppressed_now [0:BTL_IQ_COUNT-1];
            automatic int btl_iq_enq_bypass_fu_blocked_now [0:BTL_IQ_COUNT-1];
            automatic int btl_iq_enq_bypass_fu_blocked_bru_cond_now [0:BTL_IQ_COUNT-1];
            automatic int btl_iq_enq_bypass_fu_blocked_bru_backedge_now [0:BTL_IQ_COUNT-1];
            automatic int btl_iq_enq_bypass_fu_blocked_bru_jal_now [0:BTL_IQ_COUNT-1];
            automatic int btl_iq_enq_bypass_fu_blocked_bru_jalr_now [0:BTL_IQ_COUNT-1];
            automatic int btl_iq_enq_bypass_fu_blocked_serial_now [0:BTL_IQ_COUNT-1];
            automatic int btl_src1_wait_now;
            automatic int btl_src2_wait_now;
            automatic int btl_both_src_wait_now;
            automatic int btl_wait_alu_now;
            automatic int btl_wait_load_now;
            automatic int btl_wait_branch_now;
            automatic int btl_wait_mul_now;
            automatic int btl_wait_div_now;
            automatic int btl_wait_store_now;
            automatic int btl_wait_csr_now;
            automatic int btl_wait_unknown_now;
            automatic int btl_wakeup_candidate_now;
            automatic int btl_wakeup_missed_now;
            automatic int btl_younger_ready_now;

            perf_total_cyc    <= perf_total_cyc + 1;
            frontend_bin = int'(u_core.rename_dec_count);
            if (frontend_bin > 6) frontend_bin = 6;
            body_bin = int'(u_core.uoc_count);
            if (body_bin > 6) body_bin = 6;
            sq_addr_only_pending_now = 0;
            load_lat_pending_now = 0;
            pc_div_next_bitmap = pc_div_bitmap;
            pc_div_unique_now = 0;
            iq0_elig_cnt = $countones(u_core.u_iq0.eligible);
            iq1_elig_cnt = $countones(u_core.u_iq1.eligible);
            iq2_elig_cnt = $countones(u_core.u_iq2.eligible);
            iq0_issue_cnt = $countones(u_core.u_iq0.issue_valid);
            iq1_issue_cnt = $countones(u_core.u_iq1.issue_valid);
            iq2_issue_cnt = $countones(u_core.u_iq2.issue_valid);
            iq0_valid_cnt = u_core.u_iq0.count_r;
            iq1_valid_cnt = u_core.u_iq1.count_r;
            iq2_valid_cnt = u_core.u_iq2.count_r;
            fused_rename_cyc = 0;
            fused_commit_cyc = 0;
            fused_commit_alu_cyc = 0;
            fused_commit_branch_cyc = 0;
            fused_commit_load_cyc = 0;
            fused_commit_store_cyc = 0;
            move_candidate_cyc = 0;
            zero_elim_cyc = 0;
            for (int i = 0; i < BTL_IQ_COUNT; i++) begin
                btl_iq_valid_now[i] = 0;
                btl_iq_ready_now[i] = 0;
                btl_iq_eligible_now[i] = 0;
                btl_iq_selected_now[i] = 0;
                btl_iq_oldest_wait_now[i] = 0;
                btl_iq_enq_ready_hidden_now[i] = 0;
                btl_iq_enq_ready_issued_bypass_now[i] = 0;
                btl_iq_enq_wakeup_hit_now[i] = 0;
                btl_iq_enq_bypass_suppressed_now[i] = 0;
                btl_iq_enq_bypass_fu_blocked_now[i] = 0;
                btl_iq_enq_bypass_fu_blocked_bru_cond_now[i] = 0;
                btl_iq_enq_bypass_fu_blocked_bru_backedge_now[i] = 0;
                btl_iq_enq_bypass_fu_blocked_bru_jal_now[i] = 0;
                btl_iq_enq_bypass_fu_blocked_bru_jalr_now[i] = 0;
                btl_iq_enq_bypass_fu_blocked_serial_now[i] = 0;
            end
            btl_src1_wait_now = 0;
            btl_src2_wait_now = 0;
            btl_both_src_wait_now = 0;
            btl_wait_alu_now = 0;
            btl_wait_load_now = 0;
            btl_wait_branch_now = 0;
            btl_wait_mul_now = 0;
            btl_wait_div_now = 0;
            btl_wait_store_now = 0;
            btl_wait_csr_now = 0;
            btl_wait_unknown_now = 0;
            btl_wakeup_candidate_now = 0;
            btl_wakeup_missed_now = 0;
            btl_younger_ready_now = 0;

            fetch_hist[u_core.fetch_count]        <= fetch_hist[u_core.fetch_count] + 1;
            frontend_hist[frontend_bin]           <= frontend_hist[frontend_bin] + 1;
            commit_hist[u_core.commit_count]      <= commit_hist[u_core.commit_count] + 1;
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                if ((3'(i) < u_core.ren_count_w) &&
                    u_core.ren_insn[i].base.valid &&
                    u_core.ren_insn[i].base.is_fused)
                    fused_rename_cyc++;
                if ((3'(i) < u_core.ren_count_w) &&
                    u_core.ren_insn[i].base.valid &&
                    u_core.ren_insn[i].base.rd_valid &&
                    (u_core.ren_insn[i].base.rd_arch != 5'd0) &&
                    (u_core.ren_insn[i].base.fu_type == FU_ALU) &&
                    (u_core.ren_insn[i].base.alu_op == ALU_ADD) &&
                    u_core.ren_insn[i].base.use_imm &&
                    (u_core.ren_insn[i].base.imm == 64'd0) &&
                    (u_core.ren_insn[i].base.rs1_arch != 5'd0))
                    move_candidate_cyc++;
                if (u_core.ren_zero_eliminated[i])
                    zero_elim_cyc++;
                if (u_core.commit_out[i].valid && u_core.rob_head_is_fused[i]) begin
                    fused_commit_cyc++;
                    if (u_core.rob_head_is_branch[i] ||
                        (u_core.rob_head_bpu_type[i] != 3'd0))
                        fused_commit_branch_cyc++;
                    else if (u_core.rob_head_is_load[i])
                        fused_commit_load_cyc++;
                    else if (u_core.rob_head_is_store[i])
                        fused_commit_store_cyc++;
                    else
                        fused_commit_alu_cyc++;
                end
            end
            macro_fused_rename_total <=
                macro_fused_rename_total + fused_rename_cyc;
            macro_fused_commit_total <=
                macro_fused_commit_total + fused_commit_cyc;
            macro_fused_commit_alu <=
                macro_fused_commit_alu + fused_commit_alu_cyc;
            macro_fused_commit_branch <=
                macro_fused_commit_branch + fused_commit_branch_cyc;
            macro_fused_commit_load <=
                macro_fused_commit_load + fused_commit_load_cyc;
            macro_fused_commit_store <=
                macro_fused_commit_store + fused_commit_store_cyc;
            rename_move_candidate_total <=
                rename_move_candidate_total + move_candidate_cyc;
            rename_zero_elim_total <=
                rename_zero_elim_total + zero_elim_cyc;
            if (u_core.uoc_active)
                uoc_active_cycles <= uoc_active_cycles + 1;
            // µop cache telemetry
            if (u_core.uoc_ev_lookup)            uoc_lookup_total        <= uoc_lookup_total + 1;
            if (u_core.uoc_ev_hit)               uoc_hit_total           <= uoc_hit_total + 1;
            if (u_core.uoc_ev_miss)              uoc_miss_total          <= uoc_miss_total + 1;
            if (u_core.uoc_ev_fill)              uoc_fill_total          <= uoc_fill_total + 1;
            if (u_core.uoc_ev_fill_evict_valid)  uoc_fill_evict_total    <= uoc_fill_evict_total + 1;
            if (u_core.uoc_ev_enter_playing)     uoc_enter_playing_total <= uoc_enter_playing_total + 1;
            if (u_core.uoc_ev_exit_playing_miss) uoc_exit_miss_total     <= uoc_exit_miss_total + 1;
            if (u_core.uoc_ev_exit_playing_nohit)  uoc_exit_nohit_total  <= uoc_exit_nohit_total + 1;
            if (u_core.uoc_ev_exit_playing_unsafe) uoc_exit_unsafe_total <= uoc_exit_unsafe_total + 1;
            if (u_core.uoc_ev_emit)                uoc_emit_total        <= uoc_emit_total + 1;
            if (u_core.uoc_ev_emit_control)        uoc_emit_control_total <= uoc_emit_control_total + 1;
            if (u_core.uoc_ev_emit_cond)           uoc_emit_cond_total   <= uoc_emit_cond_total + 1;
            if (u_core.uoc_ev_emit_jal)            uoc_emit_jal_total    <= uoc_emit_jal_total + 1;
            if (u_core.uoc_ev_emit_jalr)           uoc_emit_jalr_total   <= uoc_emit_jalr_total + 1;
            if (u_core.uoc_ev_emit_pred_taken)     uoc_emit_pred_taken_total <= uoc_emit_pred_taken_total + 1;
            if (u_core.uoc_active && u_core.flush_out.valid)
                uoc_active_flush_total <= uoc_active_flush_total + 1;
            if (u_core.uoc_ev_invalidate)        uoc_invalidate_total    <= uoc_invalidate_total + 1;
            if (u_core.uoc_active) begin
                uoc_replay_hist[u_core.uoc_count] <=
                    uoc_replay_hist[u_core.uoc_count] + 1;
                uoc_group_hist[body_bin] <= uoc_group_hist[body_bin] + 1;
                for (int u = 0; u < PIPE_WIDTH; u++) begin
                    if ((3'(u) < u_core.uoc_count) && u_core.uoc_insn[u].valid) begin
                        uoc_emit_uops_total <= uoc_emit_uops_total + 1;
                        if (u_core.uoc_insn[u].is_branch ||
                            u_core.uoc_insn[u].is_jal ||
                            u_core.uoc_insn[u].is_jalr) begin
                            uoc_emit_control_uops_total <= uoc_emit_control_uops_total + 1;
                        end
                    end
                end
            end else begin
                fused_hist[int'(u_core.fused_count)] <=
                    fused_hist[int'(u_core.fused_count)] + 1;
            end
            if (u_core.rename_stall)    rename_stall_cyc  <= rename_stall_cyc + 1;
            if (u_core.rob_full)        rob_full_cyc      <= rob_full_cyc + 1;
            if (u_core.dq_full)         dq_full_cyc       <= dq_full_cyc + 1;
            if (u_core.lq_full)         lq_full_cyc       <= lq_full_cyc + 1;
            if (u_core.sq_full)         sq_full_cyc       <= sq_full_cyc + 1;
            if (u_core.iq0_full)        iq0_full_cyc      <= iq0_full_cyc + 1;
            if (u_core.iq1_full)        iq1_full_cyc      <= iq1_full_cyc + 1;
            if (u_core.iq2_full)        iq2_full_cyc      <= iq2_full_cyc + 1;
            iq0_cnt_sum <= iq0_cnt_sum + u_core.u_iq0.count_r;
            iq1_cnt_sum <= iq1_cnt_sum + u_core.u_iq1.count_r;
            iq2_cnt_sum <= iq2_cnt_sum + u_core.u_iq2.count_r;
            iq0_eligible_sum <= iq0_eligible_sum + iq0_elig_cnt;
            iq1_eligible_sum <= iq1_eligible_sum + iq1_elig_cnt;
            iq2_eligible_sum <= iq2_eligible_sum + iq2_elig_cnt;
            iq0_issue_uops <= iq0_issue_uops + iq0_issue_cnt;
            iq1_issue_uops <= iq1_issue_uops + iq1_issue_cnt;
            iq2_issue_uops <= iq2_issue_uops + iq2_issue_cnt;
            // Per-IQ issue-stall classification (Phase A.2). Cycle-OR semantics:
            // a cycle counts toward a bucket if ANY IQ matches that bucket.
            // NUM_SELECT: u_iq0=2, u_iq1=1, u_iq2=1.
            begin
                automatic logic any_iq_operand_stall;
                automatic logic any_iq_fu_stall;
                automatic logic any_iq_arb_stall;

                any_iq_operand_stall = 1'b0;
                any_iq_fu_stall      = 1'b0;
                any_iq_arb_stall     = 1'b0;

                // IQ0 (NUM_SELECT=2)
                if (iq0_valid_cnt > 0 && iq0_elig_cnt == 0) begin
                    any_iq_operand_stall = 1'b1;
                    iq0_operand_stall_cyc <= iq0_operand_stall_cyc + 1;
                end
                if (iq0_elig_cnt > 0 && iq0_issue_cnt < iq0_elig_cnt && iq0_issue_cnt < 2)
                    any_iq_fu_stall = 1'b1;
                if (iq0_elig_cnt > 2) begin
                    any_iq_arb_stall = 1'b1;
                    iq0_arb_loss_cyc <= iq0_arb_loss_cyc + 1;
                end

                // IQ1 (NUM_SELECT=1)
                if (iq1_valid_cnt > 0 && iq1_elig_cnt == 0) begin
                    any_iq_operand_stall = 1'b1;
                    iq1_operand_stall_cyc <= iq1_operand_stall_cyc + 1;
                end
                if (iq1_elig_cnt > 0 && iq1_issue_cnt < iq1_elig_cnt && iq1_issue_cnt < 1)
                    any_iq_fu_stall = 1'b1;
                if (iq1_elig_cnt > 1) begin
                    any_iq_arb_stall = 1'b1;
                    iq1_arb_loss_cyc <= iq1_arb_loss_cyc + 1;
                end

                // IQ2 (NUM_SELECT=1)
                if (iq2_valid_cnt > 0 && iq2_elig_cnt == 0) begin
                    any_iq_operand_stall = 1'b1;
                    iq2_operand_stall_cyc <= iq2_operand_stall_cyc + 1;
                end
                if (iq2_elig_cnt > 0 && iq2_issue_cnt < iq2_elig_cnt && iq2_issue_cnt < 1)
                    any_iq_fu_stall = 1'b1;
                if (iq2_elig_cnt > 1) begin
                    any_iq_arb_stall = 1'b1;
                    iq2_arb_loss_cyc <= iq2_arb_loss_cyc + 1;
                end

                if (any_iq_operand_stall) issue_stall_operand_cyc <= issue_stall_operand_cyc + 1;
                if (any_iq_fu_stall)      issue_stall_fu_cyc      <= issue_stall_fu_cyc + 1;
                if (any_iq_arb_stall)     issue_stall_arb_cyc     <= issue_stall_arb_cyc + 1;
            end

            begin : bottleneck_profile
                automatic logic selected_now;
                automatic logic ready_now;
                automatic logic wakeup_now;

                btl_iq_eligible_now[BTL_IQ0] = $countones(u_core.u_iq0.eligible);
                btl_iq_eligible_now[BTL_IQ1] = $countones(u_core.u_iq1.eligible);
                btl_iq_eligible_now[BTL_IQ2] = $countones(u_core.u_iq2.eligible);
                btl_iq_eligible_now[BTL_IQ_LOAD] = $countones(u_core.u_iq_load.eligible);
                btl_iq_eligible_now[BTL_IQ_STORE] = $countones(u_core.u_iq_store.eligible);
                btl_iq_eligible_now[BTL_IQ_STD] = $countones(u_core.u_iq_store_data.eligible);
                btl_iq_selected_now[BTL_IQ0] = $countones(u_core.u_iq0.issue_valid);
                btl_iq_selected_now[BTL_IQ1] = $countones(u_core.u_iq1.issue_valid);
                btl_iq_selected_now[BTL_IQ2] = $countones(u_core.u_iq2.issue_valid);
                btl_iq_selected_now[BTL_IQ_LOAD] = $countones(u_core.u_iq_load.issue_valid);
                btl_iq_selected_now[BTL_IQ_STORE] = $countones(u_core.u_iq_store.issue_valid);
                btl_iq_selected_now[BTL_IQ_STD] = $countones(u_core.u_iq_store_data.issue_valid);
                btl_iq_enq_ready_hidden_now[BTL_IQ0] =
                    $countones(u_core.u_iq0.enq_ready_hidden);
                btl_iq_enq_ready_hidden_now[BTL_IQ1] =
                    $countones(u_core.u_iq1.enq_ready_hidden);
                btl_iq_enq_ready_hidden_now[BTL_IQ2] =
                    $countones(u_core.u_iq2.enq_ready_hidden);
                btl_iq_enq_ready_hidden_now[BTL_IQ_LOAD] =
                    $countones(u_core.u_iq_load.enq_ready_hidden);
                btl_iq_enq_ready_hidden_now[BTL_IQ_STORE] =
                    $countones(u_core.u_iq_store.enq_ready_hidden);
                btl_iq_enq_ready_hidden_now[BTL_IQ_STD] =
                    $countones(u_core.u_iq_store_data.enq_ready_hidden);
                btl_iq_enq_ready_issued_bypass_now[BTL_IQ0] =
                    $countones(u_core.u_iq0.enq_ready_issued_bypass);
                btl_iq_enq_ready_issued_bypass_now[BTL_IQ1] =
                    $countones(u_core.u_iq1.enq_ready_issued_bypass);
                btl_iq_enq_ready_issued_bypass_now[BTL_IQ2] =
                    $countones(u_core.u_iq2.enq_ready_issued_bypass);
                btl_iq_enq_ready_issued_bypass_now[BTL_IQ_LOAD] =
                    $countones(u_core.u_iq_load.enq_ready_issued_bypass);
                btl_iq_enq_ready_issued_bypass_now[BTL_IQ_STORE] =
                    $countones(u_core.u_iq_store.enq_ready_issued_bypass);
                btl_iq_enq_ready_issued_bypass_now[BTL_IQ_STD] =
                    $countones(u_core.u_iq_store_data.enq_ready_issued_bypass);
                btl_iq_enq_wakeup_hit_now[BTL_IQ0] =
                    $countones(u_core.u_iq0.enq_wakeup_hit);
                btl_iq_enq_wakeup_hit_now[BTL_IQ1] =
                    $countones(u_core.u_iq1.enq_wakeup_hit);
                btl_iq_enq_wakeup_hit_now[BTL_IQ2] =
                    $countones(u_core.u_iq2.enq_wakeup_hit);
                btl_iq_enq_wakeup_hit_now[BTL_IQ_LOAD] =
                    $countones(u_core.u_iq_load.enq_wakeup_hit);
                btl_iq_enq_wakeup_hit_now[BTL_IQ_STORE] =
                    $countones(u_core.u_iq_store.enq_wakeup_hit);
                btl_iq_enq_wakeup_hit_now[BTL_IQ_STD] =
                    $countones(u_core.u_iq_store_data.enq_wakeup_hit);
                btl_iq_enq_bypass_suppressed_now[BTL_IQ0] =
                    $countones(u_core.u_iq0.enq_bypass_suppressed);
                btl_iq_enq_bypass_suppressed_now[BTL_IQ1] =
                    $countones(u_core.u_iq1.enq_bypass_suppressed);
                btl_iq_enq_bypass_suppressed_now[BTL_IQ2] =
                    $countones(u_core.u_iq2.enq_bypass_suppressed);
                btl_iq_enq_bypass_suppressed_now[BTL_IQ_LOAD] =
                    $countones(u_core.u_iq_load.enq_bypass_suppressed);
                btl_iq_enq_bypass_suppressed_now[BTL_IQ_STORE] =
                    $countones(u_core.u_iq_store.enq_bypass_suppressed);
                btl_iq_enq_bypass_suppressed_now[BTL_IQ_STD] =
                    $countones(u_core.u_iq_store_data.enq_bypass_suppressed);
                btl_iq_enq_bypass_fu_blocked_now[BTL_IQ0] =
                    $countones(u_core.u_iq0.enq_bypass_fu_blocked);
                btl_iq_enq_bypass_fu_blocked_now[BTL_IQ1] =
                    $countones(u_core.u_iq1.enq_bypass_fu_blocked);
                btl_iq_enq_bypass_fu_blocked_now[BTL_IQ2] =
                    $countones(u_core.u_iq2.enq_bypass_fu_blocked);
                btl_iq_enq_bypass_fu_blocked_now[BTL_IQ_LOAD] =
                    $countones(u_core.u_iq_load.enq_bypass_fu_blocked);
                btl_iq_enq_bypass_fu_blocked_now[BTL_IQ_STORE] =
                    $countones(u_core.u_iq_store.enq_bypass_fu_blocked);
                btl_iq_enq_bypass_fu_blocked_now[BTL_IQ_STD] =
                    $countones(u_core.u_iq_store_data.enq_bypass_fu_blocked);
                btl_iq_enq_bypass_fu_blocked_bru_cond_now[BTL_IQ0] =
                    $countones(u_core.u_iq0.enq_bypass_fu_blocked_bru_cond);
                btl_iq_enq_bypass_fu_blocked_bru_cond_now[BTL_IQ1] =
                    $countones(u_core.u_iq1.enq_bypass_fu_blocked_bru_cond);
                btl_iq_enq_bypass_fu_blocked_bru_cond_now[BTL_IQ2] =
                    $countones(u_core.u_iq2.enq_bypass_fu_blocked_bru_cond);
                btl_iq_enq_bypass_fu_blocked_bru_backedge_now[BTL_IQ0] =
                    $countones(u_core.u_iq0.enq_bypass_fu_blocked_bru_backedge);
                btl_iq_enq_bypass_fu_blocked_bru_backedge_now[BTL_IQ1] =
                    $countones(u_core.u_iq1.enq_bypass_fu_blocked_bru_backedge);
                btl_iq_enq_bypass_fu_blocked_bru_backedge_now[BTL_IQ2] =
                    $countones(u_core.u_iq2.enq_bypass_fu_blocked_bru_backedge);
                btl_iq_enq_bypass_fu_blocked_bru_jal_now[BTL_IQ0] =
                    $countones(u_core.u_iq0.enq_bypass_fu_blocked_bru_jal);
                btl_iq_enq_bypass_fu_blocked_bru_jal_now[BTL_IQ1] =
                    $countones(u_core.u_iq1.enq_bypass_fu_blocked_bru_jal);
                btl_iq_enq_bypass_fu_blocked_bru_jal_now[BTL_IQ2] =
                    $countones(u_core.u_iq2.enq_bypass_fu_blocked_bru_jal);
                btl_iq_enq_bypass_fu_blocked_bru_jalr_now[BTL_IQ0] =
                    $countones(u_core.u_iq0.enq_bypass_fu_blocked_bru_jalr);
                btl_iq_enq_bypass_fu_blocked_bru_jalr_now[BTL_IQ1] =
                    $countones(u_core.u_iq1.enq_bypass_fu_blocked_bru_jalr);
                btl_iq_enq_bypass_fu_blocked_bru_jalr_now[BTL_IQ2] =
                    $countones(u_core.u_iq2.enq_bypass_fu_blocked_bru_jalr);
                btl_iq_enq_bypass_fu_blocked_serial_now[BTL_IQ0] =
                    $countones(u_core.u_iq0.enq_bypass_fu_blocked_serial);
                btl_iq_enq_bypass_fu_blocked_serial_now[BTL_IQ1] =
                    $countones(u_core.u_iq1.enq_bypass_fu_blocked_serial);
                btl_iq_enq_bypass_fu_blocked_serial_now[BTL_IQ2] =
                    $countones(u_core.u_iq2.enq_bypass_fu_blocked_serial);

                for (int e = 0; e < IQ_INT_DEPTH; e++) begin
                    if (u_core.u_iq0.entry_valid[e]) begin
                        btl_iq_valid_now[BTL_IQ0]++;
                        ready_now = u_core.u_iq0.next_src1_ready[e] &&
                                    u_core.u_iq0.next_src2_ready[e];
                        if (ready_now) begin
                            btl_iq_ready_now[BTL_IQ0]++;
                        end else begin
                            if (int'(u_core.u_iq0.entry_age[e]) >
                                btl_iq_oldest_wait_now[BTL_IQ0])
                                btl_iq_oldest_wait_now[BTL_IQ0] =
                                    int'(u_core.u_iq0.entry_age[e]);
                        end
                        if (!u_core.u_iq0.next_src1_ready[e]) begin
                            btl_src1_wait_now++;
                            case (btl_preg_class[u_core.u_iq0.rs1_phys_r[e]])
                                BTL_PROD_ALU:    btl_wait_alu_now++;
                                BTL_PROD_LOAD:   btl_wait_load_now++;
                                BTL_PROD_BRANCH: btl_wait_branch_now++;
                                BTL_PROD_MUL:    btl_wait_mul_now++;
                                BTL_PROD_DIV:    btl_wait_div_now++;
                                BTL_PROD_STORE:  btl_wait_store_now++;
                                BTL_PROD_CSR:    btl_wait_csr_now++;
                                default:         btl_wait_unknown_now++;
                            endcase
                        end
                        if (!u_core.u_iq0.next_src2_ready[e]) begin
                            btl_src2_wait_now++;
                            case (btl_preg_class[u_core.u_iq0.rs2_phys_r[e]])
                                BTL_PROD_ALU:    btl_wait_alu_now++;
                                BTL_PROD_LOAD:   btl_wait_load_now++;
                                BTL_PROD_BRANCH: btl_wait_branch_now++;
                                BTL_PROD_MUL:    btl_wait_mul_now++;
                                BTL_PROD_DIV:    btl_wait_div_now++;
                                BTL_PROD_STORE:  btl_wait_store_now++;
                                BTL_PROD_CSR:    btl_wait_csr_now++;
                                default:         btl_wait_unknown_now++;
                            endcase
                        end
                        if (!u_core.u_iq0.next_src1_ready[e] &&
                            !u_core.u_iq0.next_src2_ready[e])
                            btl_both_src_wait_now++;
                        wakeup_now =
                            (!u_core.u_iq0.src1_ready[e] ||
                             !u_core.u_iq0.src2_ready[e]) &&
                            u_core.u_iq0.eligible[e];
                        if (wakeup_now) begin
                            selected_now = 1'b0;
                            for (int p = 0; p < 2; p++) begin
                                if (u_core.u_iq0.sel_found[p] &&
                                    !u_core.u_iq0.issue_suppress[p] &&
                                    (u_core.u_iq0.sel_idx[p] == e[$clog2(IQ_INT_DEPTH)-1:0]))
                                    selected_now = 1'b1;
                            end
                            btl_wakeup_candidate_now++;
                            if (!selected_now)
                                btl_wakeup_missed_now++;
                        end
                    end

                    if (u_core.u_iq1.entry_valid[e]) begin
                        btl_iq_valid_now[BTL_IQ1]++;
                        ready_now = u_core.u_iq1.next_src1_ready[e] &&
                                    u_core.u_iq1.next_src2_ready[e];
                        if (ready_now) begin
                            btl_iq_ready_now[BTL_IQ1]++;
                        end else begin
                            if (int'(u_core.u_iq1.entry_age[e]) >
                                btl_iq_oldest_wait_now[BTL_IQ1])
                                btl_iq_oldest_wait_now[BTL_IQ1] =
                                    int'(u_core.u_iq1.entry_age[e]);
                        end
                        if (!u_core.u_iq1.next_src1_ready[e]) begin
                            btl_src1_wait_now++;
                            case (btl_preg_class[u_core.u_iq1.rs1_phys_r[e]])
                                BTL_PROD_ALU:    btl_wait_alu_now++;
                                BTL_PROD_LOAD:   btl_wait_load_now++;
                                BTL_PROD_BRANCH: btl_wait_branch_now++;
                                BTL_PROD_MUL:    btl_wait_mul_now++;
                                BTL_PROD_DIV:    btl_wait_div_now++;
                                BTL_PROD_STORE:  btl_wait_store_now++;
                                BTL_PROD_CSR:    btl_wait_csr_now++;
                                default:         btl_wait_unknown_now++;
                            endcase
                        end
                        if (!u_core.u_iq1.next_src2_ready[e]) begin
                            btl_src2_wait_now++;
                            case (btl_preg_class[u_core.u_iq1.rs2_phys_r[e]])
                                BTL_PROD_ALU:    btl_wait_alu_now++;
                                BTL_PROD_LOAD:   btl_wait_load_now++;
                                BTL_PROD_BRANCH: btl_wait_branch_now++;
                                BTL_PROD_MUL:    btl_wait_mul_now++;
                                BTL_PROD_DIV:    btl_wait_div_now++;
                                BTL_PROD_STORE:  btl_wait_store_now++;
                                BTL_PROD_CSR:    btl_wait_csr_now++;
                                default:         btl_wait_unknown_now++;
                            endcase
                        end
                        if (!u_core.u_iq1.next_src1_ready[e] &&
                            !u_core.u_iq1.next_src2_ready[e])
                            btl_both_src_wait_now++;
                        wakeup_now =
                            (!u_core.u_iq1.src1_ready[e] ||
                             !u_core.u_iq1.src2_ready[e]) &&
                            u_core.u_iq1.eligible[e];
                        if (wakeup_now) begin
                            selected_now =
                                u_core.u_iq1.sel_found[0] &&
                                !u_core.u_iq1.issue_suppress[0] &&
                                (u_core.u_iq1.sel_idx[0] == e[$clog2(IQ_INT_DEPTH)-1:0]);
                            btl_wakeup_candidate_now++;
                            if (!selected_now)
                                btl_wakeup_missed_now++;
                        end
                    end

                    if (u_core.u_iq2.entry_valid[e]) begin
                        btl_iq_valid_now[BTL_IQ2]++;
                        ready_now = u_core.u_iq2.next_src1_ready[e] &&
                                    u_core.u_iq2.next_src2_ready[e];
                        if (ready_now) begin
                            btl_iq_ready_now[BTL_IQ2]++;
                        end else begin
                            if (int'(u_core.u_iq2.entry_age[e]) >
                                btl_iq_oldest_wait_now[BTL_IQ2])
                                btl_iq_oldest_wait_now[BTL_IQ2] =
                                    int'(u_core.u_iq2.entry_age[e]);
                        end
                        if (!u_core.u_iq2.next_src1_ready[e]) begin
                            btl_src1_wait_now++;
                            case (btl_preg_class[u_core.u_iq2.rs1_phys_r[e]])
                                BTL_PROD_ALU:    btl_wait_alu_now++;
                                BTL_PROD_LOAD:   btl_wait_load_now++;
                                BTL_PROD_BRANCH: btl_wait_branch_now++;
                                BTL_PROD_MUL:    btl_wait_mul_now++;
                                BTL_PROD_DIV:    btl_wait_div_now++;
                                BTL_PROD_STORE:  btl_wait_store_now++;
                                BTL_PROD_CSR:    btl_wait_csr_now++;
                                default:         btl_wait_unknown_now++;
                            endcase
                        end
                        if (!u_core.u_iq2.next_src2_ready[e]) begin
                            btl_src2_wait_now++;
                            case (btl_preg_class[u_core.u_iq2.rs2_phys_r[e]])
                                BTL_PROD_ALU:    btl_wait_alu_now++;
                                BTL_PROD_LOAD:   btl_wait_load_now++;
                                BTL_PROD_BRANCH: btl_wait_branch_now++;
                                BTL_PROD_MUL:    btl_wait_mul_now++;
                                BTL_PROD_DIV:    btl_wait_div_now++;
                                BTL_PROD_STORE:  btl_wait_store_now++;
                                BTL_PROD_CSR:    btl_wait_csr_now++;
                                default:         btl_wait_unknown_now++;
                            endcase
                        end
                        if (!u_core.u_iq2.next_src1_ready[e] &&
                            !u_core.u_iq2.next_src2_ready[e])
                            btl_both_src_wait_now++;
                        wakeup_now =
                            (!u_core.u_iq2.src1_ready[e] ||
                             !u_core.u_iq2.src2_ready[e]) &&
                            u_core.u_iq2.eligible[e];
                        if (wakeup_now) begin
                            selected_now =
                                u_core.u_iq2.sel_found[0] &&
                                !u_core.u_iq2.issue_suppress[0] &&
                                (u_core.u_iq2.sel_idx[0] == e[$clog2(IQ_INT_DEPTH)-1:0]);
                            btl_wakeup_candidate_now++;
                            if (!selected_now)
                                btl_wakeup_missed_now++;
                        end
                    end
                end

                for (int e = 0; e < IQ_MEM_DEPTH; e++) begin
                    if (u_core.u_iq_load.entry_valid[e]) begin
                        btl_iq_valid_now[BTL_IQ_LOAD]++;
                        ready_now = u_core.u_iq_load.next_src1_ready[e] &&
                                    u_core.u_iq_load.next_src2_ready[e];
                        if (ready_now) begin
                            btl_iq_ready_now[BTL_IQ_LOAD]++;
                        end else begin
                            if (int'(u_core.u_iq_load.entry_age[e]) >
                                btl_iq_oldest_wait_now[BTL_IQ_LOAD])
                                btl_iq_oldest_wait_now[BTL_IQ_LOAD] =
                                    int'(u_core.u_iq_load.entry_age[e]);
                        end
                        if (!u_core.u_iq_load.next_src1_ready[e]) begin
                            btl_src1_wait_now++;
                            case (btl_preg_class[u_core.u_iq_load.rs1_phys_r[e]])
                                BTL_PROD_ALU:    btl_wait_alu_now++;
                                BTL_PROD_LOAD:   btl_wait_load_now++;
                                BTL_PROD_BRANCH: btl_wait_branch_now++;
                                BTL_PROD_MUL:    btl_wait_mul_now++;
                                BTL_PROD_DIV:    btl_wait_div_now++;
                                BTL_PROD_STORE:  btl_wait_store_now++;
                                BTL_PROD_CSR:    btl_wait_csr_now++;
                                default:         btl_wait_unknown_now++;
                            endcase
                        end
                        if (!u_core.u_iq_load.next_src2_ready[e]) begin
                            btl_src2_wait_now++;
                            case (btl_preg_class[u_core.u_iq_load.rs2_phys_r[e]])
                                BTL_PROD_ALU:    btl_wait_alu_now++;
                                BTL_PROD_LOAD:   btl_wait_load_now++;
                                BTL_PROD_BRANCH: btl_wait_branch_now++;
                                BTL_PROD_MUL:    btl_wait_mul_now++;
                                BTL_PROD_DIV:    btl_wait_div_now++;
                                BTL_PROD_STORE:  btl_wait_store_now++;
                                BTL_PROD_CSR:    btl_wait_csr_now++;
                                default:         btl_wait_unknown_now++;
                            endcase
                        end
                        if (!u_core.u_iq_load.next_src1_ready[e] &&
                            !u_core.u_iq_load.next_src2_ready[e])
                            btl_both_src_wait_now++;
                        wakeup_now =
                            (!u_core.u_iq_load.src1_ready[e] ||
                             !u_core.u_iq_load.src2_ready[e]) &&
                            u_core.u_iq_load.eligible[e];
                        if (wakeup_now) begin
                            selected_now = 1'b0;
                            for (int p = 0; p < 2; p++) begin
                                if (u_core.u_iq_load.sel_found[p] &&
                                    !u_core.u_iq_load.issue_suppress[p] &&
                                    (u_core.u_iq_load.sel_idx[p] == e[$clog2(IQ_MEM_DEPTH)-1:0]))
                                    selected_now = 1'b1;
                            end
                            btl_wakeup_candidate_now++;
                            if (!selected_now)
                                btl_wakeup_missed_now++;
                        end
                    end

                    if (u_core.u_iq_store.entry_valid[e]) begin
                        btl_iq_valid_now[BTL_IQ_STORE]++;
                        ready_now = u_core.u_iq_store.next_src1_ready[e] &&
                                    u_core.u_iq_store.next_src2_ready[e];
                        if (ready_now) begin
                            btl_iq_ready_now[BTL_IQ_STORE]++;
                        end else begin
                            if (int'(u_core.u_iq_store.entry_age[e]) >
                                btl_iq_oldest_wait_now[BTL_IQ_STORE])
                                btl_iq_oldest_wait_now[BTL_IQ_STORE] =
                                    int'(u_core.u_iq_store.entry_age[e]);
                        end
                        if (!u_core.u_iq_store.next_src1_ready[e]) begin
                            btl_src1_wait_now++;
                            case (btl_preg_class[u_core.u_iq_store.rs1_phys_r[e]])
                                BTL_PROD_ALU:    btl_wait_alu_now++;
                                BTL_PROD_LOAD:   btl_wait_load_now++;
                                BTL_PROD_BRANCH: btl_wait_branch_now++;
                                BTL_PROD_MUL:    btl_wait_mul_now++;
                                BTL_PROD_DIV:    btl_wait_div_now++;
                                BTL_PROD_STORE:  btl_wait_store_now++;
                                BTL_PROD_CSR:    btl_wait_csr_now++;
                                default:         btl_wait_unknown_now++;
                            endcase
                        end
                        if (!u_core.u_iq_store.next_src2_ready[e]) begin
                            btl_src2_wait_now++;
                            case (btl_preg_class[u_core.u_iq_store.rs2_phys_r[e]])
                                BTL_PROD_ALU:    btl_wait_alu_now++;
                                BTL_PROD_LOAD:   btl_wait_load_now++;
                                BTL_PROD_BRANCH: btl_wait_branch_now++;
                                BTL_PROD_MUL:    btl_wait_mul_now++;
                                BTL_PROD_DIV:    btl_wait_div_now++;
                                BTL_PROD_STORE:  btl_wait_store_now++;
                                BTL_PROD_CSR:    btl_wait_csr_now++;
                                default:         btl_wait_unknown_now++;
                            endcase
                        end
                        if (!u_core.u_iq_store.next_src1_ready[e] &&
                            !u_core.u_iq_store.next_src2_ready[e])
                            btl_both_src_wait_now++;
                        wakeup_now =
                            (!u_core.u_iq_store.src1_ready[e] ||
                             !u_core.u_iq_store.src2_ready[e]) &&
                            u_core.u_iq_store.eligible[e];
                        if (wakeup_now) begin
                            selected_now =
                                u_core.u_iq_store.sel_found[0] &&
                                !u_core.u_iq_store.issue_suppress[0] &&
                                (u_core.u_iq_store.sel_idx[0] == e[$clog2(IQ_MEM_DEPTH)-1:0]);
                            btl_wakeup_candidate_now++;
                            if (!selected_now)
                                btl_wakeup_missed_now++;
                        end
                    end

                    if (u_core.u_iq_store_data.entry_valid[e]) begin
                        btl_iq_valid_now[BTL_IQ_STD]++;
                        ready_now = u_core.u_iq_store_data.next_src1_ready[e] &&
                                    u_core.u_iq_store_data.next_src2_ready[e];
                        if (ready_now) begin
                            btl_iq_ready_now[BTL_IQ_STD]++;
                        end else begin
                            if (int'(u_core.u_iq_store_data.entry_age[e]) >
                                btl_iq_oldest_wait_now[BTL_IQ_STD])
                                btl_iq_oldest_wait_now[BTL_IQ_STD] =
                                    int'(u_core.u_iq_store_data.entry_age[e]);
                        end
                        if (!u_core.u_iq_store_data.next_src1_ready[e]) begin
                            btl_src1_wait_now++;
                            case (btl_preg_class[u_core.u_iq_store_data.rs1_phys_r[e]])
                                BTL_PROD_ALU:    btl_wait_alu_now++;
                                BTL_PROD_LOAD:   btl_wait_load_now++;
                                BTL_PROD_BRANCH: btl_wait_branch_now++;
                                BTL_PROD_MUL:    btl_wait_mul_now++;
                                BTL_PROD_DIV:    btl_wait_div_now++;
                                BTL_PROD_STORE:  btl_wait_store_now++;
                                BTL_PROD_CSR:    btl_wait_csr_now++;
                                default:         btl_wait_unknown_now++;
                            endcase
                        end
                        if (!u_core.u_iq_store_data.next_src2_ready[e]) begin
                            btl_src2_wait_now++;
                            case (btl_preg_class[u_core.u_iq_store_data.rs2_phys_r[e]])
                                BTL_PROD_ALU:    btl_wait_alu_now++;
                                BTL_PROD_LOAD:   btl_wait_load_now++;
                                BTL_PROD_BRANCH: btl_wait_branch_now++;
                                BTL_PROD_MUL:    btl_wait_mul_now++;
                                BTL_PROD_DIV:    btl_wait_div_now++;
                                BTL_PROD_STORE:  btl_wait_store_now++;
                                BTL_PROD_CSR:    btl_wait_csr_now++;
                                default:         btl_wait_unknown_now++;
                            endcase
                        end
                        if (!u_core.u_iq_store_data.next_src1_ready[e] &&
                            !u_core.u_iq_store_data.next_src2_ready[e])
                            btl_both_src_wait_now++;
                        wakeup_now =
                            (!u_core.u_iq_store_data.src1_ready[e] ||
                             !u_core.u_iq_store_data.src2_ready[e]) &&
                            u_core.u_iq_store_data.eligible[e];
                        if (wakeup_now) begin
                            selected_now =
                                u_core.u_iq_store_data.sel_found[0] &&
                                !u_core.u_iq_store_data.issue_suppress[0] &&
                                (u_core.u_iq_store_data.sel_idx[0] == e[$clog2(IQ_MEM_DEPTH)-1:0]);
                            btl_wakeup_candidate_now++;
                            if (!selected_now)
                                btl_wakeup_missed_now++;
                        end
                    end
                end

                for (int i = 0; i < BTL_IQ_COUNT; i++) begin
                    btl_iq_valid_entry_sum[i] <=
                        btl_iq_valid_entry_sum[i] + btl_iq_valid_now[i];
                    btl_iq_ready_entry_sum[i] <=
                        btl_iq_ready_entry_sum[i] + btl_iq_ready_now[i];
                    btl_iq_not_ready_entry_sum[i] <=
                        btl_iq_not_ready_entry_sum[i] +
                        (btl_iq_valid_now[i] - btl_iq_ready_now[i]);
                    btl_iq_selected_uops[i] <=
                        btl_iq_selected_uops[i] + btl_iq_selected_now[i];
                    if (btl_iq_valid_now[i] != 0) begin
                        if (btl_iq_eligible_now[i] == 0)
                            btl_iq_eligible_zero_cycles[i] <=
                                btl_iq_eligible_zero_cycles[i] + 1;
                        else if (btl_iq_eligible_now[i] == 1)
                            btl_iq_eligible_one_cycles[i] <=
                                btl_iq_eligible_one_cycles[i] + 1;
                        else
                            btl_iq_eligible_multi_cycles[i] <=
                                btl_iq_eligible_multi_cycles[i] + 1;
                    end
                    if (btl_iq_eligible_now[i] > btl_iq_selected_now[i])
                        btl_iq_arb_loss[i] <= btl_iq_arb_loss[i] +
                            (btl_iq_eligible_now[i] - btl_iq_selected_now[i]);
                    if (btl_iq_oldest_wait_now[i] >
                        btl_iq_oldest_not_ready_age_max[i])
                        btl_iq_oldest_not_ready_age_max[i] <=
                            btl_iq_oldest_wait_now[i];
                    btl_iq_enq_ready_hidden[i] <=
                        btl_iq_enq_ready_hidden[i] +
                        btl_iq_enq_ready_hidden_now[i];
                    btl_iq_enq_ready_issued_bypass[i] <=
                        btl_iq_enq_ready_issued_bypass[i] +
                        btl_iq_enq_ready_issued_bypass_now[i];
                    btl_iq_enq_wakeup_hit[i] <=
                        btl_iq_enq_wakeup_hit[i] +
                        btl_iq_enq_wakeup_hit_now[i];
                    btl_iq_enq_bypass_suppressed[i] <=
                        btl_iq_enq_bypass_suppressed[i] +
                        btl_iq_enq_bypass_suppressed_now[i];
                    btl_iq_enq_bypass_fu_blocked[i] <=
                        btl_iq_enq_bypass_fu_blocked[i] +
                        btl_iq_enq_bypass_fu_blocked_now[i];
                    btl_iq_enq_bypass_fu_blocked_bru_cond[i] <=
                        btl_iq_enq_bypass_fu_blocked_bru_cond[i] +
                        btl_iq_enq_bypass_fu_blocked_bru_cond_now[i];
                    btl_iq_enq_bypass_fu_blocked_bru_backedge[i] <=
                        btl_iq_enq_bypass_fu_blocked_bru_backedge[i] +
                        btl_iq_enq_bypass_fu_blocked_bru_backedge_now[i];
                    btl_iq_enq_bypass_fu_blocked_bru_jal[i] <=
                        btl_iq_enq_bypass_fu_blocked_bru_jal[i] +
                        btl_iq_enq_bypass_fu_blocked_bru_jal_now[i];
                    btl_iq_enq_bypass_fu_blocked_bru_jalr[i] <=
                        btl_iq_enq_bypass_fu_blocked_bru_jalr[i] +
                        btl_iq_enq_bypass_fu_blocked_bru_jalr_now[i];
                    btl_iq_enq_bypass_fu_blocked_serial[i] <=
                        btl_iq_enq_bypass_fu_blocked_serial[i] +
                        btl_iq_enq_bypass_fu_blocked_serial_now[i];
                end

                btl_dep_src1_wait <= btl_dep_src1_wait + btl_src1_wait_now;
                btl_dep_src2_wait <= btl_dep_src2_wait + btl_src2_wait_now;
                btl_dep_both_src_wait <=
                    btl_dep_both_src_wait + btl_both_src_wait_now;
                btl_dep_wait_on_alu <= btl_dep_wait_on_alu + btl_wait_alu_now;
                btl_dep_wait_on_load <= btl_dep_wait_on_load + btl_wait_load_now;
                btl_dep_wait_on_branch <=
                    btl_dep_wait_on_branch + btl_wait_branch_now;
                btl_dep_wait_on_mul <= btl_dep_wait_on_mul + btl_wait_mul_now;
                btl_dep_wait_on_div <= btl_dep_wait_on_div + btl_wait_div_now;
                btl_dep_wait_on_store <=
                    btl_dep_wait_on_store + btl_wait_store_now;
                btl_dep_wait_on_csr <= btl_dep_wait_on_csr + btl_wait_csr_now;
                btl_dep_wait_on_unknown <=
                    btl_dep_wait_on_unknown + btl_wait_unknown_now;
                btl_wakeup_same_cycle_candidate <=
                    btl_wakeup_same_cycle_candidate + btl_wakeup_candidate_now;
                btl_wakeup_same_cycle_missed <=
                    btl_wakeup_same_cycle_missed + btl_wakeup_missed_now;

                if (u_core.rename_dec_count > u_core.ren_count_w)
                    btl_rename_slots_lost_total <=
                        btl_rename_slots_lost_total +
                        (u_core.rename_dec_count - u_core.ren_count_w);
                if (int'(u_core.u_rename.fl_free_count) <
                    btl_rename_free_preg_min)
                    btl_rename_free_preg_min <=
                        int'(u_core.u_rename.fl_free_count);
                if (int'(u_core.u_rob.free_count) < btl_rename_rob_free_min)
                    btl_rename_rob_free_min <= int'(u_core.u_rob.free_count);
                if (u_core.backend_admission_pressure)
                    btl_backend_throttle_pressure_cycles <=
                        btl_backend_throttle_pressure_cycles + 1;
                if (u_core.backend_admission_head_block)
                    btl_backend_throttle_head_block_cycles <=
                        btl_backend_throttle_head_block_cycles + 1;
                if (u_core.backend_admission_throttle_enter)
                    btl_backend_throttle_enter_cycles <=
                        btl_backend_throttle_enter_cycles + 1;
                if (u_core.backend_admission_throttle_active) begin
                    btl_backend_throttle_active_cycles <=
                        btl_backend_throttle_active_cycles + 1;
                    if (u_core.rename_dec_count > u_core.ren_count_w) begin
                        btl_backend_throttle_limited_slots <=
                            btl_backend_throttle_limited_slots +
                            (u_core.rename_dec_count - u_core.ren_count_w);
                    end
                end

                if (u_core.rob_head_valid[0] && !u_core.rob_head_ready[0]) begin
                    for (int i = 1; i < PIPE_WIDTH; i++) begin
                        if (u_core.rob_head_valid[i] && u_core.rob_head_ready[i])
                            btl_younger_ready_now++;
                    end
                    btl_rob_younger_ready_behind_head <=
                        btl_rob_younger_ready_behind_head +
                        btl_younger_ready_now;
                    btl_rob_commit_slots_lost_head_block <=
                        btl_rob_commit_slots_lost_head_block +
                        btl_younger_ready_now;
                end

                if (u_core.flush_out.valid && u_core.flush_out.full_flush) begin
                    for (int i = 0; i < INT_PRF_DEPTH; i++) begin
                        btl_preg_class[i] <= BTL_PROD_UNKNOWN;
                    end
                end else begin
                    for (int i = 0; i < PIPE_WIDTH; i++) begin
                        if ((3'(i) < u_core.ren_count_w) &&
                            u_core.ren_insn[i].base.valid &&
                            u_core.ren_insn[i].base.rd_valid &&
                            (u_core.ren_insn[i].pdst != '0) &&
                            !u_core.ren_move_eliminated[i] &&
                            !u_core.ren_zero_eliminated[i]) begin
                            case (u_core.ren_insn[i].base.fu_type)
                                FU_ALU:
                                    btl_preg_class[u_core.ren_insn[i].pdst] <=
                                        BTL_PROD_ALU;
                                FU_LOAD:
                                    btl_preg_class[u_core.ren_insn[i].pdst] <=
                                        BTL_PROD_LOAD;
                                FU_BRU:
                                    btl_preg_class[u_core.ren_insn[i].pdst] <=
                                        BTL_PROD_BRANCH;
                                FU_MUL:
                                    btl_preg_class[u_core.ren_insn[i].pdst] <=
                                        BTL_PROD_MUL;
                                FU_DIV:
                                    btl_preg_class[u_core.ren_insn[i].pdst] <=
                                        BTL_PROD_DIV;
                                FU_STA, FU_STD:
                                    btl_preg_class[u_core.ren_insn[i].pdst] <=
                                        BTL_PROD_STORE;
                                FU_CSR:
                                    btl_preg_class[u_core.ren_insn[i].pdst] <=
                                        BTL_PROD_CSR;
                                default:
                                    btl_preg_class[u_core.ren_insn[i].pdst] <=
                                        BTL_PROD_UNKNOWN;
                            endcase
                        end
                    end
                end
            end
            if (u_core.backend_stall)   backend_stall_cyc <= backend_stall_cyc + 1;
            if (u_core.flush_out.valid) flush_cyc         <= flush_cyc + 1;
            if (u_core.uoc_active &&
                (u_core.commit_count != 3'd0) &&
                (u_core.load_commit_count == 3'd0)) begin
                uoc_commit_no_load_cyc <= uoc_commit_no_load_cyc + 1;
                uoc_commit_no_load_run <= uoc_commit_no_load_run + 1;
                if ((uoc_commit_no_load_run + 1) > uoc_commit_no_load_run_max)
                    uoc_commit_no_load_run_max <= uoc_commit_no_load_run + 1;
            end else begin
                uoc_commit_no_load_run <= 0;
            end
`ifdef SIMULATION
            if (u_core.uoc_active && 1'b0)
                uoc_mixedpath_cyc <= uoc_mixedpath_cyc + 1;
`endif
            if (u_core.fetch_count == 3'd0) begin
                fetch_zero_total_cyc <= fetch_zero_total_cyc + 1;
                if (u_core.u_fetch_top.frontend_hold) begin
                    fetch_zero_frontend_hold_cyc <=
                        fetch_zero_frontend_hold_cyc + 1;
                end else if (u_core.flush_out.valid || u_core.bru_early_redirect) begin
                    fetch_zero_redirect_cyc <= fetch_zero_redirect_cyc + 1;
                end else if (!u_core.u_fetch_top.packet_buf_valid) begin
                    fetch_zero_pkt_empty_cyc <= fetch_zero_pkt_empty_cyc + 1;
                    if (u_core.u_fetch_top.ftq_full)
                        fetch_zero_ftq_full_cyc <= fetch_zero_ftq_full_cyc + 1;
                    if (u_core.u_fetch_top.packet_buf_full)
                        fetch_zero_pkt_full_cyc <= fetch_zero_pkt_full_cyc + 1;
                    if (u_core.u_fetch_top.ic_req_valid)
                        fetch_zero_icreq_live_cyc <= fetch_zero_icreq_live_cyc + 1;
                    if (u_core.u_fetch_top.packet_buf_enq) begin
                        fetch_zero_pkt_empty_enq_cyc <= fetch_zero_pkt_empty_enq_cyc + 1;
                        if (u_core.u_fetch_top.packet_buf_in.pd_ctl_valid) begin
                            fetch_zero_enq_ctl_cyc <= fetch_zero_enq_ctl_cyc + 1;
                            if ((u_core.u_fetch_top.packet_buf_in.pd_ctl_type == 3'd0) &&
                                !u_core.u_fetch_top.packet_buf_in.ftq_pred_taken &&
                                !(|u_core.u_fetch_top.packet_buf_in.fetch_bp_taken)) begin
                                fetch_zero_enq_ctl_cond_nt_cyc <=
                                    fetch_zero_enq_ctl_cond_nt_cyc + 1;
                            end
                            if (u_core.u_fetch_top.packet_buf_in.pd_ctl_type == 3'd0)
                                fetch_zero_enq_ctl_cond_cyc <=
                                    fetch_zero_enq_ctl_cond_cyc + 1;
                            else if ((u_core.u_fetch_top.packet_buf_in.pd_ctl_type == 3'd3) ||
                                     (u_core.u_fetch_top.packet_buf_in.pd_ctl_type == 3'd4))
                                fetch_zero_enq_ctl_callret_cyc <=
                                    fetch_zero_enq_ctl_callret_cyc + 1;
                            else
                                fetch_zero_enq_ctl_other_cyc <=
                                    fetch_zero_enq_ctl_other_cyc + 1;
                            if (u_core.u_fetch_top.packet_buf_in.ftq_pred_taken ||
                                (|u_core.u_fetch_top.packet_buf_in.fetch_bp_taken))
                                fetch_zero_enq_ctl_taken_cyc <=
                                    fetch_zero_enq_ctl_taken_cyc + 1;
                        end else begin
                            fetch_zero_enq_noctl_cyc <= fetch_zero_enq_noctl_cyc + 1;
                        end
                        if (u_core.u_fetch_top.packet_buf_in.ftq_owner_complete)
                            fetch_zero_enq_owner_done_cyc <=
                                fetch_zero_enq_owner_done_cyc + 1;
                        if (u_core.u_fetch_top.ftq_head_valid &&
                            (u_core.u_fetch_top.packet_buf_in.ftq_idx ==
                             u_core.u_fetch_top.ftq_head_idx) &&
                            (u_core.u_fetch_top.packet_buf_in.ftq_epoch ==
                             u_core.u_fetch_top.ftq_current_epoch) &&
                            (u_core.u_fetch_top.packet_buf_in.ftq_alloc_tag ==
                             u_core.u_fetch_top.ftq_head_tag))
                            fetch_zero_enq_ftq_match_cyc <=
                                fetch_zero_enq_ftq_match_cyc + 1;
                    end
                    if (!u_core.u_fetch_top.ic_resp_valid &&
                        !u_core.u_fetch_top.fe_stall &&
                        u_core.u_fetch_top.f1_valid)
                        fetch_zero_wait_icresp_cyc <= fetch_zero_wait_icresp_cyc + 1;
                    if (u_core.u_fetch_top.f2_work_valid_c &&
                        !u_core.u_fetch_top.f2_data_valid)
                        fetch_zero_f2_wait_cyc <= fetch_zero_f2_wait_cyc + 1;
                    if (u_core.u_fetch_top.f2_work_valid_c &&
                        u_core.u_fetch_top.f2_data_valid) begin
                        fetch_zero_f2_data_cyc <= fetch_zero_f2_data_cyc + 1;
                        if (u_core.u_fetch_top.f2_will_emit_c) begin
                            fetch_zero_f2_emit_cyc <= fetch_zero_f2_emit_cyc + 1;
                        end else if (u_core.u_fetch_top.extract_count == 3'd0) begin
                            fetch_zero_no_emit_extract0_cyc <=
                                fetch_zero_no_emit_extract0_cyc + 1;
                        end else if (u_core.u_fetch_top.f2_last_emit_valid_r &&
                                     (u_core.u_fetch_top.f2_last_emit_pc_r ==
                                      u_core.u_fetch_top.f2_work_pc_c)) begin
                            fetch_zero_no_emit_dup_cyc <=
                                fetch_zero_no_emit_dup_cyc + 1;
                        end else begin
                            fetch_zero_no_emit_other_cyc <=
                                fetch_zero_no_emit_other_cyc + 1;
                        end
                    end
                    if (!u_core.u_fetch_top.ftq_full &&
                        !u_core.u_fetch_top.packet_buf_full &&
                        !u_core.u_fetch_top.ic_req_valid &&
                        !( !u_core.u_fetch_top.ic_resp_valid &&
                           !u_core.u_fetch_top.fe_stall &&
                           u_core.u_fetch_top.f1_valid) &&
                        !(u_core.u_fetch_top.f2_work_valid_c &&
                          !u_core.u_fetch_top.f2_data_valid))
                        fetch_zero_other_cyc <= fetch_zero_other_cyc + 1;
                end else begin
                    fetch_zero_pkt_valid_cyc <= fetch_zero_pkt_valid_cyc + 1;
                end
            end
            if (u_core.iq_load_issue_candidate_valid[0]) ld0_candidate_cyc <= ld0_candidate_cyc + 1;
            if (u_core.iq_load_issue_valid[0])           ld0_issue_cyc     <= ld0_issue_cyc + 1;
            if (u_core.lsu_load_issue_suppress[0])       ld0_suppress_cyc  <= ld0_suppress_cyc + 1;
            if (u_core.iq_load_issue_candidate_valid[1]) ld1_candidate_cyc <= ld1_candidate_cyc + 1;
            if (u_core.iq_load_issue_valid[1])           ld1_issue_cyc     <= ld1_issue_cyc + 1;
            if (u_core.lsu_load_issue_suppress[1])       ld1_suppress_cyc  <= ld1_suppress_cyc + 1;
            if (u_core.u_lsu.sq_fwd_wait)                sq_fwd_wait_cyc   <= sq_fwd_wait_cyc + 1;
            if (u_core.u_lsu.sq_wait_p1)                 sq_wait_p1_cyc    <= sq_wait_p1_cyc + 1;
            if (u_core.store_iq_older_than_load[0])      storeiq_block_ld0_cyc <= storeiq_block_ld0_cyc + 1;
            if (u_core.store_iq_older_than_load[1])      storeiq_block_ld1_cyc <= storeiq_block_ld1_cyc + 1;
            if (u_core.store_iq_older_than_load[0] &&
                u_core.routed_sta_valid)
                storeiq_block_ld0_with_sta_issue_cyc <= storeiq_block_ld0_with_sta_issue_cyc + 1;
            if (u_core.store_iq_older_than_load[1] &&
                u_core.routed_sta_valid)
                storeiq_block_ld1_with_sta_issue_cyc <= storeiq_block_ld1_with_sta_issue_cyc + 1;
            if (u_core.iq_load_issue_candidate_valid[0] &&
                !u_core.u_lsu.load_addr_misaligned[0] &&
                !u_core.flush_out.valid)
                p0_fwd_req_cyc <= p0_fwd_req_cyc + 1;
            if (u_core.iq_load_issue_candidate_valid[0] &&
                !u_core.u_lsu.load_addr_misaligned[0] &&
                !u_core.flush_out.valid &&
                dbg_p0_sq_ready_full)
                p0_sq_ready_full_cyc <= p0_sq_ready_full_cyc + 1;
            if (u_core.iq_load_issue_candidate_valid[0] &&
                !u_core.u_lsu.load_addr_misaligned[0] &&
                !u_core.flush_out.valid &&
                dbg_p0_sq_ready_partial)
                p0_sq_ready_partial_cyc <= p0_sq_ready_partial_cyc + 1;
            if (u_core.iq_load_issue_candidate_valid[0] &&
                !u_core.u_lsu.load_addr_misaligned[0] &&
                !u_core.flush_out.valid &&
                dbg_p0_sq_wait_missing &&
                !dbg_p0_sq_ready_full &&
                !dbg_p0_sq_ready_partial)
                p0_sq_wait_only_cyc <= p0_sq_wait_only_cyc + 1;
            if (u_core.u_lsu.same_cycle_fwd_hit)
                p0_same_cycle_hit_cyc <= p0_same_cycle_hit_cyc + 1;
            if (u_core.u_lsu.csb_fwd_hit)
                p0_csb_hit_cyc <= p0_csb_hit_cyc + 1;
            if (u_core.u_lsu.p1_wait_req_valid)          p1_wait_req_cyc   <= p1_wait_req_cyc + 1;
            if (u_core.u_lsu.p1_wait_req_valid && dbg_p1_sq_ready_full)
                p1_sq_ready_full_cyc <= p1_sq_ready_full_cyc + 1;
            if (u_core.u_lsu.p1_wait_req_valid && dbg_p1_sq_ready_partial)
                p1_sq_ready_partial_cyc <= p1_sq_ready_partial_cyc + 1;
            if (u_core.u_lsu.p1_wait_req_valid &&
                dbg_p1_sq_wait_missing &&
                !dbg_p1_sq_ready_full &&
                !dbg_p1_sq_ready_partial)
                p1_sq_wait_only_cyc <= p1_sq_wait_only_cyc + 1;
            if (u_core.u_lsu.dcache_conflict)
                p1_dcache_conflict_cyc <= p1_dcache_conflict_cyc + 1;
            if (u_core.u_lsu.p1_retry_valid_r)           p1_retry_valid_cyc <= p1_retry_valid_cyc + 1;
            if (u_core.u_lsu.p1_retry_valid_r && !prev_p1_retry_valid)
                p1_retry_capture_cyc <= p1_retry_capture_cyc + 1;

            begin : load_latency_profile
                int issue_idx;
                int wb_idx;
                int lat;
                int bucket;
                int wb_src;
                int hit_idx;
                int free_idx;
                int min_idx;
                int min_count;
                int use_idx;
                logic [63:0] wb_pc;
                int cyc_issue_count;
                int cyc_reissue_count;
                int cyc_wb_count;
                int cyc_untracked_count;
                int cyc_hist [0:LOAD_LAT_BUCKETS-1];
                int cyc_src [0:LOAD_SRC_UNK];

                cyc_issue_count = 0;
                cyc_reissue_count = 0;
                cyc_wb_count = 0;
                cyc_untracked_count = 0;
                for (int i = 0; i < LOAD_LAT_BUCKETS; i++)
                    cyc_hist[i] = 0;
                for (int i = 0; i <= LOAD_SRC_UNK; i++)
                    cyc_src[i] = 0;

                for (int r = 0; r < ROB_DEPTH; r++) begin
                    if (load_lat_track_valid[r])
                        load_lat_pending_now++;
                end
                load_lat_pending_sum <= load_lat_pending_sum + load_lat_pending_now;
                if (load_lat_pending_now > load_lat_pending_max)
                    load_lat_pending_max <= load_lat_pending_now;

                for (int p = 0; p < 2; p++) begin
                    if (u_core.iq_load_issue_valid[p]) begin
                        issue_idx = int'(u_core.iq_load_issue_data[p].rob_idx);
                        if (issue_idx < ROB_DEPTH) begin
                            if (load_lat_track_valid[issue_idx])
                                cyc_reissue_count++;
                            load_lat_track_valid[issue_idx] <= 1'b1;
                            load_lat_issue_cycle[issue_idx] <= perf_total_cyc;
                            load_lat_issue_pc[issue_idx]    <= u_core.iq_load_issue_data[p].pc;
                            load_lat_issue_port[issue_idx]  <= (p != 0);
                            cyc_issue_count++;
                        end
                    end
                end

                for (int p = 0; p < 2; p++) begin
                    if (u_core.lsu_load_wb_valid[p]) begin
                        wb_idx = int'(u_core.lsu_load_wb_rob_idx[p]);
                        wb_src = LOAD_SRC_UNK;

                        if (p == 0) begin
                            if (u_core.u_lsu.p0_dcache_hit_valid &&
                                (int'(u_core.u_lsu.load_issue_data_r[0].rob_idx) == wb_idx))
                                wb_src = LOAD_SRC_DCHIT;
                            else if (u_core.u_lsu.fwd_hold_valid_r &&
                                     (int'(u_core.u_lsu.fwd_hold_rob_idx_r) == wb_idx))
                                wb_src = LOAD_SRC_FWD;
                            else if (u_core.u_lsu.lmb_wb_port_free &&
                                     u_core.u_lsu.lmb_any_match &&
                                     (int'(u_core.u_lsu.lmb[u_core.u_lsu.lmb_match_idx].rob_idx) == wb_idx))
                                wb_src = LOAD_SRC_LMB;
                            else if (u_core.u_lsu.lmb_wb_port_free &&
                                     !u_core.u_lsu.lmb_any_match &&
                                     u_core.u_lsu.lmb_ready_any &&
                                     (int'(u_core.u_lsu.lmb[u_core.u_lsu.lmb_ready_idx].rob_idx) == wb_idx))
                                wb_src = LOAD_SRC_LMB;
                        end else begin
                            if (u_core.u_lsu.load_issue_valid[1] &&
                                u_core.u_lsu.load_addr_misaligned[1] &&
                                !u_core.u_lsu.flush_in.valid &&
                                (int'(u_core.u_lsu.load_issue_data[1].rob_idx) == wb_idx))
                                wb_src = LOAD_SRC_MISALN;
                            else if (u_core.u_lsu.dcache_load_resp_valid[1] &&
                                     u_core.u_lsu.load_issue_valid_r[1] &&
                                     !u_core.u_lsu.load_nocache_r[1] &&
                                     (int'(u_core.u_lsu.load_issue_data_r[1].rob_idx) == wb_idx))
                                wb_src = LOAD_SRC_DCHIT;
                            else if (u_core.u_lsu.p0_fwd_spill_to_p1 &&
                                     (int'(u_core.u_lsu.fwd_hold_rob_idx_r) == wb_idx))
                                wb_src = LOAD_SRC_FWD;
                            else if (u_core.u_lsu.p1_fwd_hold_valid_r &&
                                     (int'(u_core.u_lsu.p1_fwd_hold_rob_idx_r) == wb_idx))
                                wb_src = LOAD_SRC_FWD;
                        end

                        cyc_wb_count++;
                        if ((wb_idx < ROB_DEPTH) && load_lat_track_valid[wb_idx]) begin
                            lat = perf_total_cyc - load_lat_issue_cycle[wb_idx];
                            wb_pc = load_lat_issue_pc[wb_idx];
                            if (lat <= 0)
                                bucket = 0;
                            else if (lat == 1)
                                bucket = 1;
                            else if (lat == 2)
                                bucket = 2;
                            else if (lat == 3)
                                bucket = 3;
                            else if (lat == 4)
                                bucket = 4;
                            else if (lat == 5)
                                bucket = 5;
                            else if (lat <= 7)
                                bucket = 6;
                            else if (lat <= 15)
                                bucket = 7;
                            else if (lat <= 31)
                                bucket = 8;
                            else
                                bucket = 9;

                            cyc_hist[bucket]++;
                            cyc_src[wb_src]++;

                            hit_idx = -1;
                            free_idx = -1;
                            min_idx = 0;
                            min_count = load_lat_pc_hist_count[0];
                            use_idx = -1;
                            for (int i = 0; i < LOAD_LAT_PC_HIST_SLOTS; i++) begin
                                if ((load_lat_pc_hist_count[i] != 0) &&
                                    (load_lat_pc_hist_pc[i] == wb_pc) &&
                                    (hit_idx < 0))
                                    hit_idx = i;
                                if ((load_lat_pc_hist_count[i] == 0) &&
                                    (free_idx < 0))
                                    free_idx = i;
                                if (load_lat_pc_hist_count[i] < min_count) begin
                                    min_idx = i;
                                    min_count = load_lat_pc_hist_count[i];
                                end
                            end
                            if (hit_idx >= 0)
                                use_idx = hit_idx;
                            else if (free_idx >= 0)
                                use_idx = free_idx;
                            else
                                use_idx = min_idx;

                            if (hit_idx < 0) begin
                                load_lat_pc_hist_pc[use_idx]    <= wb_pc;
                                load_lat_pc_hist_count[use_idx] <= 1;
                                load_lat_pc_hist_sum[use_idx]   <= lat;
                                load_lat_pc_hist_max[use_idx]   <= lat;
                                load_lat_pc_hist_dchit[use_idx] <=
                                    (wb_src == LOAD_SRC_DCHIT) ? 1 : 0;
                                load_lat_pc_hist_fwd[use_idx]   <=
                                    (wb_src == LOAD_SRC_FWD) ? 1 : 0;
                                load_lat_pc_hist_lmb[use_idx]   <=
                                    (wb_src == LOAD_SRC_LMB) ? 1 : 0;
                                load_lat_pc_hist_other[use_idx] <=
                                    ((wb_src != LOAD_SRC_DCHIT) &&
                                     (wb_src != LOAD_SRC_FWD) &&
                                     (wb_src != LOAD_SRC_LMB)) ? 1 : 0;
                            end else begin
                                load_lat_pc_hist_count[use_idx] <=
                                    load_lat_pc_hist_count[use_idx] + 1;
                                load_lat_pc_hist_sum[use_idx] <=
                                    load_lat_pc_hist_sum[use_idx] + lat;
                                if (lat > load_lat_pc_hist_max[use_idx])
                                    load_lat_pc_hist_max[use_idx] <= lat;
                                if (wb_src == LOAD_SRC_DCHIT)
                                    load_lat_pc_hist_dchit[use_idx] <=
                                        load_lat_pc_hist_dchit[use_idx] + 1;
                                else if (wb_src == LOAD_SRC_FWD)
                                    load_lat_pc_hist_fwd[use_idx] <=
                                        load_lat_pc_hist_fwd[use_idx] + 1;
                                else if (wb_src == LOAD_SRC_LMB)
                                    load_lat_pc_hist_lmb[use_idx] <=
                                        load_lat_pc_hist_lmb[use_idx] + 1;
                                else
                                    load_lat_pc_hist_other[use_idx] <=
                                        load_lat_pc_hist_other[use_idx] + 1;
                            end

                            load_lat_track_valid[wb_idx] <= 1'b0;
                        end else begin
                            cyc_untracked_count++;
                        end
                    end
                end

                load_lat_issue_total <= load_lat_issue_total + cyc_issue_count;
                load_lat_reissue_total <= load_lat_reissue_total + cyc_reissue_count;
                load_lat_wb_total <= load_lat_wb_total + cyc_wb_count;
                load_lat_wb_untracked_total <=
                    load_lat_wb_untracked_total + cyc_untracked_count;
                for (int i = 0; i < LOAD_LAT_BUCKETS; i++)
                    load_lat_hist[i] <= load_lat_hist[i] + cyc_hist[i];
                for (int i = 0; i <= LOAD_SRC_UNK; i++)
                    load_lat_src_count[i] <= load_lat_src_count[i] + cyc_src[i];

                if (u_core.flush_out.valid) begin
                    for (int r = 0; r < ROB_DEPTH; r++)
                        load_lat_track_valid[r] <= 1'b0;
                end
            end
            if (u_core.lsu_spec_wakeup_valid[0])         spec_wk_p0_cyc <= spec_wk_p0_cyc + 1;
            if (u_core.lsu_spec_wakeup_valid[1])         spec_wk_p1_cyc <= spec_wk_p1_cyc + 1;
            if (dbg_std_spec_match_p0)                   std_spec_match_p0_cyc <= std_spec_match_p0_cyc + 1;
            if (dbg_std_spec_match_p1)                   std_spec_match_p1_cyc <= std_spec_match_p1_cyc + 1;
            if (u_core.routed_sta_valid)                 sta_issue_cyc     <= sta_issue_cyc + 1;
            if (u_core.routed_std_valid)                 std_issue_cyc     <= std_issue_cyc + 1;
            if (u_core.dc_store_req_valid)               dc_store_req_cyc  <= dc_store_req_cyc + 1;
            for (int sqe = 0; sqe < SQ_DEPTH; sqe++) begin
                if (u_core.u_lsu.u_store_queue.queue[sqe].valid &&
                    u_core.u_lsu.u_store_queue.queue[sqe].addr_valid &&
                    !u_core.u_lsu.u_store_queue.queue[sqe].data_valid) begin
                    sq_addr_only_pending_now = sq_addr_only_pending_now + 1;
                    if (!sq_addr_only_track_valid[sqe]) begin
                        sq_addr_only_track_valid[sqe] <= 1'b1;
                        sq_addr_only_track_age[sqe]   <= 1;
                    end else begin
                        sq_addr_only_track_age[sqe] <= sq_addr_only_track_age[sqe] + 1;
                    end
                end else if (sq_addr_only_track_valid[sqe]) begin
                    if (u_core.u_lsu.u_store_queue.queue[sqe].valid &&
                        u_core.u_lsu.u_store_queue.queue[sqe].data_valid) begin
                        if (sq_addr_only_track_age[sqe] <= 1)
                            sq_addr_to_data_lag_hist[0] <= sq_addr_to_data_lag_hist[0] + 1;
                        else if (sq_addr_only_track_age[sqe] == 2)
                            sq_addr_to_data_lag_hist[1] <= sq_addr_to_data_lag_hist[1] + 1;
                        else if (sq_addr_only_track_age[sqe] == 3)
                            sq_addr_to_data_lag_hist[2] <= sq_addr_to_data_lag_hist[2] + 1;
                        else if (sq_addr_only_track_age[sqe] <= 5)
                            sq_addr_to_data_lag_hist[3] <= sq_addr_to_data_lag_hist[3] + 1;
                        else
                            sq_addr_to_data_lag_hist[4] <= sq_addr_to_data_lag_hist[4] + 1;
                    end else begin
                        sq_addr_to_data_drop_cyc <= sq_addr_to_data_drop_cyc + 1;
                    end
                    sq_addr_only_track_valid[sqe] <= 1'b0;
                    sq_addr_only_track_age[sqe]   <= 0;
                end
            end
            sq_addr_only_pending_sum <= sq_addr_only_pending_sum + sq_addr_only_pending_now;
            if (sq_addr_only_pending_now > sq_addr_only_pending_max)
                sq_addr_only_pending_max <= sq_addr_only_pending_now;
            prev_p1_retry_valid <= u_core.u_lsu.p1_retry_valid_r;
            if (u_core.flush_out.valid && u_core.flush_out.ghr_restore_valid) begin
                ghr_restore_cyc <= ghr_restore_cyc + 1;
                if (u_core.flush_out.ghr_restore_val != '0)
                    ghr_restore_nonzero_cyc <= ghr_restore_nonzero_cyc + 1;
            end
            if (u_core.ras_restore_valid_fe)
                ras_restore_cyc <= ras_restore_cyc + 1;
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                if (u_core.commit_out[i].valid)
                    pc_div_next_bitmap[tb_pc_div_hash(u_core.rob_head_pc[i])] = 1'b1;
                if (u_core.commit_out[i].valid &&
                    (u_core.rob_head_is_branch[i] || (u_core.rob_head_bpu_type[i] != 3'd0))) begin
                    case (u_core.rob_head_bpu_type[i])
                        3'd1: ctl_commit_jal_cyc  <= ctl_commit_jal_cyc + 1;
                        3'd2: ctl_commit_jalr_cyc <= ctl_commit_jalr_cyc + 1;
                        3'd3: ctl_commit_call_cyc <= ctl_commit_call_cyc + 1;
                        3'd4: ctl_commit_ret_cyc  <= ctl_commit_ret_cyc + 1;
                        default: ctl_commit_cond_cyc <= ctl_commit_cond_cyc + 1;
                    endcase
                    if (u_core.rob_head_branch_mispredict[i]) begin
                        misp_hit_idx = -1;
                        misp_free_idx = -1;
                        misp_min_idx = 0;
                        misp_min_count = misp_pc_hist_count[0];
                        misp_use_idx = -1;
                        for (int j = 0; j < MISP_PC_HIST_SLOTS; j++) begin
                            if ((misp_pc_hist_count[j] != 0) &&
                                (misp_pc_hist_pc[j] == u_core.rob_head_pc[i]) &&
                                (misp_hit_idx < 0))
                                misp_hit_idx = j;
                            if ((misp_pc_hist_count[j] == 0) &&
                                (misp_free_idx < 0))
                                misp_free_idx = j;
                            if (misp_pc_hist_count[j] < misp_min_count) begin
                                misp_min_idx = j;
                                misp_min_count = misp_pc_hist_count[j];
                            end
                        end
                        if (misp_hit_idx >= 0)
                            misp_use_idx = misp_hit_idx;
                        else if (misp_free_idx >= 0)
                            misp_use_idx = misp_free_idx;
                        else
                            misp_use_idx = misp_min_idx;

                        if (misp_hit_idx < 0) begin
                            misp_pc_hist_pc[misp_use_idx]     <= u_core.rob_head_pc[i];
                            misp_pc_hist_count[misp_use_idx]  <= 1;
                            misp_pc_hist_cond[misp_use_idx]   <=
                                (u_core.rob_head_bpu_type[i] == 3'd0) ? 1 : 0;
                            misp_pc_hist_jal[misp_use_idx]    <=
                                (u_core.rob_head_bpu_type[i] == 3'd1) ? 1 : 0;
                            misp_pc_hist_jalr[misp_use_idx]   <=
                                (u_core.rob_head_bpu_type[i] == 3'd2) ? 1 : 0;
                            misp_pc_hist_call[misp_use_idx]   <=
                                (u_core.rob_head_bpu_type[i] == 3'd3) ? 1 : 0;
                            misp_pc_hist_ret[misp_use_idx]    <=
                                (u_core.rob_head_bpu_type[i] == 3'd4) ? 1 : 0;
                            misp_pc_hist_taken[misp_use_idx]  <=
                                u_core.rob_head_branch_taken[i] ? 1 : 0;
                            misp_pc_hist_ntaken[misp_use_idx] <=
                                u_core.rob_head_branch_taken[i] ? 0 : 1;
                        end else begin
                            misp_pc_hist_count[misp_use_idx] <=
                                misp_pc_hist_count[misp_use_idx] + 1;
                            case (u_core.rob_head_bpu_type[i])
                                3'd1: misp_pc_hist_jal[misp_use_idx] <=
                                          misp_pc_hist_jal[misp_use_idx] + 1;
                                3'd2: misp_pc_hist_jalr[misp_use_idx] <=
                                          misp_pc_hist_jalr[misp_use_idx] + 1;
                                3'd3: misp_pc_hist_call[misp_use_idx] <=
                                          misp_pc_hist_call[misp_use_idx] + 1;
                                3'd4: misp_pc_hist_ret[misp_use_idx] <=
                                          misp_pc_hist_ret[misp_use_idx] + 1;
                                default: misp_pc_hist_cond[misp_use_idx] <=
                                             misp_pc_hist_cond[misp_use_idx] + 1;
                            endcase
                            if (u_core.rob_head_branch_taken[i])
                                misp_pc_hist_taken[misp_use_idx] <=
                                    misp_pc_hist_taken[misp_use_idx] + 1;
                            else
                                misp_pc_hist_ntaken[misp_use_idx] <=
                                    misp_pc_hist_ntaken[misp_use_idx] + 1;
                        end

                        case (u_core.rob_head_bpu_type[i])
                            3'd1: ctl_misp_jal_cyc  <= ctl_misp_jal_cyc + 1;
                            3'd2: ctl_misp_jalr_cyc <= ctl_misp_jalr_cyc + 1;
                            3'd3: ctl_misp_call_cyc <= ctl_misp_call_cyc + 1;
                            3'd4: ctl_misp_ret_cyc  <= ctl_misp_ret_cyc + 1;
                            default: ctl_misp_cond_cyc <= ctl_misp_cond_cyc + 1;
                        endcase
                    end
                end
            end
            // Rename stall source classification (slot 0 sufficient to attribute)
            if (u_core.rename_stall) begin
                if      (!u_core.u_rename.has_preg[0])  stall_preg_cyc  <= stall_preg_cyc + 1;
                else if (!u_core.u_rename.has_ckpt[0])  stall_ckpt_cyc  <= stall_ckpt_cyc + 1;
                else if (!u_core.u_rename.has_rob[0])   stall_rob_cyc   <= stall_rob_cyc + 1;
                else if (!u_core.u_rename.has_dq[0])    stall_dq_cyc    <= stall_dq_cyc + 1;
                else if (u_core.backend_admission_throttle_active)
                    stall_backend_throttle_cyc <= stall_backend_throttle_cyc + 1;
                else                                     stall_other_cyc <= stall_other_cyc + 1;
            end
            if (pc_div_window_cyc == (PC_DIV_WINDOW_CYC - 1)) begin
                pc_div_unique_now = tb_count_ones64(pc_div_next_bitmap);
                pc_div_windows_total <= pc_div_windows_total + 1;
                if (pc_div_unique_now <= PC_DIV_LOW_UNIQUE_THRESH)
                    pc_div_low_windows <= pc_div_low_windows + 1;
                if (pc_div_unique_now < pc_div_min_unique)
                    pc_div_min_unique <= pc_div_unique_now;
                if (pc_div_unique_now > pc_div_max_unique)
                    pc_div_max_unique <= pc_div_unique_now;
                pc_div_bitmap <= '0;
                pc_div_window_cyc <= 0;
            end else begin
                pc_div_bitmap <= pc_div_next_bitmap;
                pc_div_window_cyc <= pc_div_window_cyc + 1;
            end
        end
    end

    final begin
        if (pp_en) begin
            $display("==== PERF PROFILE ====");
            $display("Total cycles: %0d", perf_total_cyc);
            $display("Raw fetch histogram (cycles with N instr from fetch_top):");
            for (int i = 0; i <= 6; i++)
                $display("  fetch=%0d : %0d (%0d%%)", i, fetch_hist[i],
                         (perf_total_cyc > 0) ? (fetch_hist[i] * 100 / perf_total_cyc) : 0);
            $display("Effective frontend histogram (cycles with N instr to rename):");
            for (int i = 0; i <= 6; i++)
                $display("  frontend=%0d : %0d (%0d%%)", i, frontend_hist[i],
                         (perf_total_cyc > 0) ? (frontend_hist[i] * 100 / perf_total_cyc) : 0);
            $display("Decode-path histogram (non-UOC cycles, fused_count):");
            for (int i = 0; i <= 6; i++)
                $display("  fused=%0d : %0d", i, fused_hist[i]);
            $display("Decoded-op replay histogram (UOC-active cycles, uoc_count):");
            for (int i = 0; i <= 6; i++)
                $display("  uoc_emit=%0d : %0d", i, uoc_replay_hist[i]);
            $display("Decoded-op replay group-size histogram (UOC-active cycles, 6=>=6):");
            for (int i = 0; i <= 6; i++)
                if (i < 6)
                    $display("  uoc_group=%0d : %0d", i, uoc_group_hist[i]);
                else
                    $display("  uoc_group>=6 : %0d", uoc_group_hist[i]);
            $display("Fetch=0 breakdown:");
            $display("  total                     : %0d", fetch_zero_total_cyc);
            $display("  frontend_hold             : %0d", fetch_zero_frontend_hold_cyc);
            $display("  redirect_recovery         : %0d", fetch_zero_redirect_cyc);
            $display("  packet_empty              : %0d", fetch_zero_pkt_empty_cyc);
            $display("  packet_valid_zeroout      : %0d", fetch_zero_pkt_valid_cyc);
            $display("  packet_empty_ftq_full     : %0d", fetch_zero_ftq_full_cyc);
            $display("  packet_empty_pkt_full     : %0d", fetch_zero_pkt_full_cyc);
            $display("  packet_empty_icreq_live   : %0d", fetch_zero_icreq_live_cyc);
            $display("  packet_empty_wait_icresp  : %0d", fetch_zero_wait_icresp_cyc);
            $display("  packet_empty_f2_wait      : %0d", fetch_zero_f2_wait_cyc);
            $display("  packet_empty_enq          : %0d", fetch_zero_pkt_empty_enq_cyc);
            $display("  packet_empty_enq_ctl      : %0d", fetch_zero_enq_ctl_cyc);
            $display("  packet_empty_enq_noctl    : %0d", fetch_zero_enq_noctl_cyc);
            $display("  packet_empty_enq_ctl_cond : %0d", fetch_zero_enq_ctl_cond_cyc);
            $display("  packet_empty_enq_ctl_nt   : %0d", fetch_zero_enq_ctl_cond_nt_cyc);
            $display("  packet_empty_enq_ctl_taken: %0d", fetch_zero_enq_ctl_taken_cyc);
            $display("  packet_empty_enq_ctl_callret: %0d", fetch_zero_enq_ctl_callret_cyc);
            $display("  packet_empty_enq_ctl_other: %0d", fetch_zero_enq_ctl_other_cyc);
            $display("  packet_empty_enq_done     : %0d", fetch_zero_enq_owner_done_cyc);
            $display("  packet_empty_enq_ftq_match: %0d", fetch_zero_enq_ftq_match_cyc);
            $display("  packet_empty_f2_data      : %0d", fetch_zero_f2_data_cyc);
            $display("  packet_empty_f2_emit      : %0d", fetch_zero_f2_emit_cyc);
            $display("  packet_empty_noemit_dup   : %0d", fetch_zero_no_emit_dup_cyc);
            $display("  packet_empty_noemit_ext0  : %0d", fetch_zero_no_emit_extract0_cyc);
            $display("  packet_empty_noemit_other : %0d", fetch_zero_no_emit_other_cyc);
            $display("  packet_empty_other        : %0d", fetch_zero_other_cyc);
            $display("Commit histogram (cycles with N instr committed):");
            for (int i = 0; i <= 6; i++)
                $display("  commit=%0d: %0d (%0d%%)", i, commit_hist[i],
                         (perf_total_cyc > 0) ? (commit_hist[i] * 100 / perf_total_cyc) : 0);
            // Kept for the benchmark harness gate. The legacy loop buffer RTL
            // is not instantiated in the pipeline, so this must remain zero.
            $display("Loop buffer active: 0 cycles (0%%)");
            $display("Standalone decoded-op replay active: %0d cycles (%0d%%)",
                     uoc_active_cycles,
                     (perf_total_cyc > 0) ? (uoc_active_cycles * 100 / perf_total_cyc) : 0);
            $display("UOC telemetry:");
            $display("  lookups        : %0d", uoc_lookup_total);
            $display("  hits           : %0d (%0d%%)",
                     uoc_hit_total,
                     (uoc_lookup_total > 0) ? (uoc_hit_total * 100 / uoc_lookup_total) : 0);
            $display("  misses         : %0d", uoc_miss_total);
            $display("  fills          : %0d", uoc_fill_total);
            $display("  fills_evicting : %0d", uoc_fill_evict_total);
            $display("  enter_playing  : %0d", uoc_enter_playing_total);
            $display("  exit_on_miss   : %0d", uoc_exit_miss_total);
            $display("  exit_nohit/unsafe: %0d / %0d",
                     uoc_exit_nohit_total,
                     uoc_exit_unsafe_total);
            $display("  emit groups/control: %0d / %0d",
                     uoc_emit_total,
                     uoc_emit_control_total);
            $display("  emit cond/jal/jalr : %0d / %0d / %0d",
                     uoc_emit_cond_total,
                     uoc_emit_jal_total,
                     uoc_emit_jalr_total);
            $display("  emit pred_taken    : %0d", uoc_emit_pred_taken_total);
            $display("  emit uops/control  : %0d / %0d",
                     uoc_emit_uops_total,
                     uoc_emit_control_uops_total);
            $display("  active_flush_cycles: %0d", uoc_active_flush_total);
            $display("  invalidates    : %0d", uoc_invalidate_total);
            $display("Decoded-op replay forward-progress summary:");
            $display("  commit_no_load cycles       : %0d", uoc_commit_no_load_cyc);
            $display("  commit_no_load max run      : %0d", uoc_commit_no_load_run_max);
`ifdef SIMULATION
            $display("  mixed-path replay cycles    : %0d", uoc_mixedpath_cyc);
`endif
            $display("Committed PC diversity (%0d-cycle 64-bin windows):",
                     PC_DIV_WINDOW_CYC);
            $display("  windows total / low<=%0d    : %0d / %0d",
                     PC_DIV_LOW_UNIQUE_THRESH,
                     pc_div_windows_total,
                     pc_div_low_windows);
            $display("  min / max unique bins       : %0d / %0d",
                     (pc_div_windows_total > 0) ? pc_div_min_unique : 0,
                     pc_div_max_unique);
            $display("Stall breakdown (cycle-based):");
            $display("  rename_stall : %0d", rename_stall_cyc);
            $display("  backend_stall: %0d", backend_stall_cyc);
            $display("  rob_full     : %0d", rob_full_cyc);
            $display("  dq_full      : %0d", dq_full_cyc);
            $display("  lq_full      : %0d", lq_full_cyc);
            $display("  sq_full      : %0d", sq_full_cyc);
            $display("  iq0_full     : %0d", iq0_full_cyc);
            $display("  iq1_full     : %0d", iq1_full_cyc);
            $display("  iq2_full     : %0d", iq2_full_cyc);
            $display("Rename stall attribution (slot-0 resource):");
            $display("  stall_preg   : %0d", stall_preg_cyc);
            $display("  stall_ckpt   : %0d", stall_ckpt_cyc);
            $display("  stall_rob    : %0d", stall_rob_cyc);
            $display("  stall_dq     : %0d", stall_dq_cyc);
            $display("  stall_backend_throttle: %0d", stall_backend_throttle_cyc);
            $display("  stall_other  : %0d", stall_other_cyc);
            $display("Issue-stall classification (cycle-based, OR across all IQs):");
            $display("  operand_not_ready: %0d", issue_stall_operand_cyc);
            $display("  fu_contention   : %0d", issue_stall_fu_cyc);
            $display("  arb_loss        : %0d", issue_stall_arb_cyc);
            $display("Issue queue detail:");
            $display("  iq0 operand/arb/issued/eligible_avg: %0d / %0d / %0d / %0d.%02d",
                     iq0_operand_stall_cyc, iq0_arb_loss_cyc, iq0_issue_uops,
                     iq0_eligible_sum / perf_total_cyc,
                     ((iq0_eligible_sum * 100) / perf_total_cyc) % 100);
            $display("  iq1 operand/arb/issued/eligible_avg: %0d / %0d / %0d / %0d.%02d",
                     iq1_operand_stall_cyc, iq1_arb_loss_cyc, iq1_issue_uops,
                     iq1_eligible_sum / perf_total_cyc,
                     ((iq1_eligible_sum * 100) / perf_total_cyc) % 100);
            $display("  iq2 operand/arb/issued/eligible_avg: %0d / %0d / %0d / %0d.%02d",
                     iq2_operand_stall_cyc, iq2_arb_loss_cyc, iq2_issue_uops,
                     iq2_eligible_sum / perf_total_cyc,
                     ((iq2_eligible_sum * 100) / perf_total_cyc) % 100);
            $display("Macro-fusion accounting:");
            $display("  rename_fused_uops: %0d", macro_fused_rename_total);
            $display("  commit_fused_uops: %0d", macro_fused_commit_total);
            $display("  commit fused alu/branch/load/store: %0d / %0d / %0d / %0d",
                     macro_fused_commit_alu,
                     macro_fused_commit_branch,
                     macro_fused_commit_load,
                     macro_fused_commit_store);
            $display("Rename elimination accounting:");
            $display("  move_candidates: %0d", rename_move_candidate_total);
            $display("  zero_eliminated: %0d", rename_zero_elim_total);
            $display("Average IQ occupancy (of 32):");
            $display("  iq0_avg: %0d.%02d", iq0_cnt_sum / perf_total_cyc,
                     ((iq0_cnt_sum * 100) / perf_total_cyc) % 100);
            $display("  iq1_avg: %0d.%02d", iq1_cnt_sum / perf_total_cyc,
                     ((iq1_cnt_sum * 100) / perf_total_cyc) % 100);
            $display("  iq2_avg: %0d.%02d", iq2_cnt_sum / perf_total_cyc,
                     ((iq2_cnt_sum * 100) / perf_total_cyc) % 100);
            $display("Flushes: %0d", flush_cyc);
            $display("LSU pressure summary:");
            $display("  ld0 candidate/issue/suppress: %0d / %0d / %0d",
                     ld0_candidate_cyc, ld0_issue_cyc, ld0_suppress_cyc);
            $display("  ld1 candidate/issue/suppress: %0d / %0d / %0d",
                     ld1_candidate_cyc, ld1_issue_cyc, ld1_suppress_cyc);
            $display("  sq_fwd_wait cycles          : %0d", sq_fwd_wait_cyc);
            $display("  storeIQ block ld0/ld1       : %0d / %0d",
                     storeiq_block_ld0_cyc, storeiq_block_ld1_cyc);
            $display("  block+STA issue ld0/ld1     : %0d / %0d",
                     storeiq_block_ld0_with_sta_issue_cyc,
                     storeiq_block_ld1_with_sta_issue_cyc);
            $display("  p0 req/full/partial/waitonly: %0d / %0d / %0d / %0d",
                     p0_fwd_req_cyc, p0_sq_ready_full_cyc,
                     p0_sq_ready_partial_cyc, p0_sq_wait_only_cyc);
            $display("  p0 same_cycle/csb hits      : %0d / %0d",
                     p0_same_cycle_hit_cyc, p0_csb_hit_cyc);
            $display("  sq_wait_p1 cycles           : %0d", sq_wait_p1_cyc);
            $display("  p1 wait_req cycles          : %0d", p1_wait_req_cyc);
            $display("  p1 sq ready full / partial  : %0d / %0d",
                     p1_sq_ready_full_cyc, p1_sq_ready_partial_cyc);
            $display("  p1 sq wait-only / conflict  : %0d / %0d",
                     p1_sq_wait_only_cyc, p1_dcache_conflict_cyc);
            $display("  p1_retry live/captures      : %0d / %0d",
                     p1_retry_valid_cyc, p1_retry_capture_cyc);
            $display("Load issue-to-WB latency summary:");
            $display("  issue/reissue/wb/untracked  : %0d / %0d / %0d / %0d",
                     load_lat_issue_total, load_lat_reissue_total,
                     load_lat_wb_total, load_lat_wb_untracked_total);
            $display("  pending avg/max             : %0d.%02d / %0d",
                     load_lat_pending_sum / perf_total_cyc,
                     ((load_lat_pending_sum * 100) / perf_total_cyc) % 100,
                     load_lat_pending_max);
            $display("  latency buckets 0/1/2/3/4/5/6-7/8-15/16-31/32+: %0d / %0d / %0d / %0d / %0d / %0d / %0d / %0d / %0d / %0d",
                     load_lat_hist[0], load_lat_hist[1], load_lat_hist[2],
                     load_lat_hist[3], load_lat_hist[4], load_lat_hist[5],
                     load_lat_hist[6], load_lat_hist[7], load_lat_hist[8],
                     load_lat_hist[9]);
            $display("  source dchit/fwd/lmb/misalign/unknown: %0d / %0d / %0d / %0d / %0d",
                     load_lat_src_count[LOAD_SRC_DCHIT],
                     load_lat_src_count[LOAD_SRC_FWD],
                     load_lat_src_count[LOAD_SRC_LMB],
                     load_lat_src_count[LOAD_SRC_MISALN],
                     load_lat_src_count[LOAD_SRC_UNK]);
            $display("  top load WB PCs: pc count avg_lat max_lat dchit/fwd/lmb/other");
            for (int i = 0; i < LOAD_LAT_PC_HIST_SLOTS; i++) begin
                if (load_lat_pc_hist_count[i] != 0) begin
                    $display("    %016h %0d %0d.%02d %0d %0d/%0d/%0d/%0d",
                        load_lat_pc_hist_pc[i],
                        load_lat_pc_hist_count[i],
                        load_lat_pc_hist_sum[i] / load_lat_pc_hist_count[i],
                        ((load_lat_pc_hist_sum[i] * 100) /
                            load_lat_pc_hist_count[i]) % 100,
                        load_lat_pc_hist_max[i],
                        load_lat_pc_hist_dchit[i],
                        load_lat_pc_hist_fwd[i],
                        load_lat_pc_hist_lmb[i],
                        load_lat_pc_hist_other[i]);
                end
            end
            $display("  spec wake p0/p1             : %0d / %0d",
                     spec_wk_p0_cyc, spec_wk_p1_cyc);
            $display("  std IQ spec match p0/p1     : %0d / %0d",
                     std_spec_match_p0_cyc, std_spec_match_p1_cyc);
            $display("  sta_issue/std_issue/store_req: %0d / %0d / %0d",
                     sta_issue_cyc, std_issue_cyc, dc_store_req_cyc);
            $display("  SQ addr-only pending avg/max: %0d.%02d / %0d",
                     sq_addr_only_pending_sum / perf_total_cyc,
                     ((sq_addr_only_pending_sum * 100) / perf_total_cyc) % 100,
                     sq_addr_only_pending_max);
            $display("  SQ addr->data lag 1/2/3/4-5/6+: %0d / %0d / %0d / %0d / %0d",
                     sq_addr_to_data_lag_hist[0], sq_addr_to_data_lag_hist[1],
                     sq_addr_to_data_lag_hist[2], sq_addr_to_data_lag_hist[3],
                     sq_addr_to_data_lag_hist[4]);
            $display("  SQ addr-only drops          : %0d", sq_addr_to_data_drop_cyc);
            $display("Committed control summary:");
            $display("  cond/jal/jalr/call/ret      : %0d / %0d / %0d / %0d / %0d",
                     ctl_commit_cond_cyc, ctl_commit_jal_cyc, ctl_commit_jalr_cyc,
                     ctl_commit_call_cyc, ctl_commit_ret_cyc);
            $display("Committed mispredict summary:");
            $display("  cond/jal/jalr/call/ret      : %0d / %0d / %0d / %0d / %0d",
                     ctl_misp_cond_cyc, ctl_misp_jal_cyc, ctl_misp_jalr_cyc,
                     ctl_misp_call_cyc, ctl_misp_ret_cyc);
            $display("  top mispredict PCs: pc count cond/jal/jalr/call/ret taken/not_taken");
            for (int i = 0; i < MISP_PC_HIST_SLOTS; i++) begin
                if (misp_pc_hist_count[i] != 0) begin
                    $display("    %016h %0d %0d/%0d/%0d/%0d/%0d %0d/%0d",
                        misp_pc_hist_pc[i],
                        misp_pc_hist_count[i],
                        misp_pc_hist_cond[i],
                        misp_pc_hist_jal[i],
                        misp_pc_hist_jalr[i],
                        misp_pc_hist_call[i],
                        misp_pc_hist_ret[i],
                        misp_pc_hist_taken[i],
                        misp_pc_hist_ntaken[i]);
                end
            end
            $display("GHR restore summary:");
            $display("  total/nonzero               : %0d / %0d",
                     ghr_restore_cyc, ghr_restore_nonzero_cyc);
            $display("RAS restore summary:");
            $display("  total                       : %0d", ras_restore_cyc);
            if (btl_en) begin
                $display("");
                $display("=== BOTTLENECK DSE COUNTERS ===");
                $display("xs bottleneck_fe_zero_cycles : %0d", frontend_hist[0]);
                $display("xs bottleneck_fe_redirect_recovery : %0d", fetch_zero_redirect_cyc);
                $display("xs bottleneck_fe_packet_empty : %0d", fetch_zero_pkt_empty_cyc);
                $display("xs bottleneck_fe_packet_empty_wait_icresp : %0d", fetch_zero_wait_icresp_cyc);
                $display("xs bottleneck_fe_packet_empty_f2_data : %0d", fetch_zero_f2_data_cyc);
                $display("xs bottleneck_fe_packet_empty_noemit_dup : %0d", fetch_zero_no_emit_dup_cyc);
                $display("xs bottleneck_rename_stall_preg : %0d", stall_preg_cyc);
                $display("xs bottleneck_rename_stall_rob : %0d", stall_rob_cyc);
                $display("xs bottleneck_rename_stall_dq : %0d", stall_dq_cyc);
                $display("xs bottleneck_rename_stall_ckpt : %0d", stall_ckpt_cyc);
                $display("xs bottleneck_rename_stall_backend_throttle : %0d", stall_backend_throttle_cyc);
                $display("xs bottleneck_rename_stall_other : %0d", stall_other_cyc);
                $display("xs bottleneck_rename_slots_lost_total : %0d", btl_rename_slots_lost_total);
                $display("xs bottleneck_rename_free_preg_min : %0d", btl_rename_free_preg_min);
                $display("xs bottleneck_rename_rob_free_min : %0d", btl_rename_rob_free_min);
                $display("xs bottleneck_backend_throttle_active_cycles : %0d", btl_backend_throttle_active_cycles);
                $display("xs bottleneck_backend_throttle_enter_cycles : %0d", btl_backend_throttle_enter_cycles);
                $display("xs bottleneck_backend_throttle_pressure_cycles : %0d", btl_backend_throttle_pressure_cycles);
                $display("xs bottleneck_backend_throttle_head_block_cycles : %0d", btl_backend_throttle_head_block_cycles);
                $display("xs bottleneck_backend_throttle_limited_slots : %0d", btl_backend_throttle_limited_slots);
                $display("xs bottleneck_iq0_valid_entry_sum : %0d", btl_iq_valid_entry_sum[BTL_IQ0]);
                $display("xs bottleneck_iq0_ready_entry_sum : %0d", btl_iq_ready_entry_sum[BTL_IQ0]);
                $display("xs bottleneck_iq0_not_ready_entry_sum : %0d", btl_iq_not_ready_entry_sum[BTL_IQ0]);
                $display("xs bottleneck_iq0_eligible_zero_cycles : %0d", btl_iq_eligible_zero_cycles[BTL_IQ0]);
                $display("xs bottleneck_iq0_eligible_one_cycles : %0d", btl_iq_eligible_one_cycles[BTL_IQ0]);
                $display("xs bottleneck_iq0_eligible_multi_cycles : %0d", btl_iq_eligible_multi_cycles[BTL_IQ0]);
                $display("xs bottleneck_iq0_selected_uops : %0d", btl_iq_selected_uops[BTL_IQ0]);
                $display("xs bottleneck_iq0_arb_loss : %0d", btl_iq_arb_loss[BTL_IQ0]);
                $display("xs bottleneck_iq0_oldest_not_ready_age_max : %0d", btl_iq_oldest_not_ready_age_max[BTL_IQ0]);
                $display("xs bottleneck_iq0_enq_ready_hidden : %0d", btl_iq_enq_ready_hidden[BTL_IQ0]);
                $display("xs bottleneck_iq0_enq_ready_issued_bypass : %0d", btl_iq_enq_ready_issued_bypass[BTL_IQ0]);
                $display("xs bottleneck_iq0_enq_wakeup_hit : %0d", btl_iq_enq_wakeup_hit[BTL_IQ0]);
                $display("xs bottleneck_iq0_enq_bypass_suppressed : %0d", btl_iq_enq_bypass_suppressed[BTL_IQ0]);
                $display("xs bottleneck_iq0_enq_bypass_fu_blocked : %0d", btl_iq_enq_bypass_fu_blocked[BTL_IQ0]);
                $display("xs bottleneck_iq0_enq_bypass_fu_blocked_bru_cond : %0d", btl_iq_enq_bypass_fu_blocked_bru_cond[BTL_IQ0]);
                $display("xs bottleneck_iq0_enq_bypass_fu_blocked_bru_backedge : %0d", btl_iq_enq_bypass_fu_blocked_bru_backedge[BTL_IQ0]);
                $display("xs bottleneck_iq0_enq_bypass_fu_blocked_bru_jal : %0d", btl_iq_enq_bypass_fu_blocked_bru_jal[BTL_IQ0]);
                $display("xs bottleneck_iq0_enq_bypass_fu_blocked_bru_jalr : %0d", btl_iq_enq_bypass_fu_blocked_bru_jalr[BTL_IQ0]);
                $display("xs bottleneck_iq0_enq_bypass_fu_blocked_serial : %0d", btl_iq_enq_bypass_fu_blocked_serial[BTL_IQ0]);
                $display("xs bottleneck_iq1_valid_entry_sum : %0d", btl_iq_valid_entry_sum[BTL_IQ1]);
                $display("xs bottleneck_iq1_ready_entry_sum : %0d", btl_iq_ready_entry_sum[BTL_IQ1]);
                $display("xs bottleneck_iq1_not_ready_entry_sum : %0d", btl_iq_not_ready_entry_sum[BTL_IQ1]);
                $display("xs bottleneck_iq1_eligible_zero_cycles : %0d", btl_iq_eligible_zero_cycles[BTL_IQ1]);
                $display("xs bottleneck_iq1_eligible_one_cycles : %0d", btl_iq_eligible_one_cycles[BTL_IQ1]);
                $display("xs bottleneck_iq1_eligible_multi_cycles : %0d", btl_iq_eligible_multi_cycles[BTL_IQ1]);
                $display("xs bottleneck_iq1_selected_uops : %0d", btl_iq_selected_uops[BTL_IQ1]);
                $display("xs bottleneck_iq1_arb_loss : %0d", btl_iq_arb_loss[BTL_IQ1]);
                $display("xs bottleneck_iq1_oldest_not_ready_age_max : %0d", btl_iq_oldest_not_ready_age_max[BTL_IQ1]);
                $display("xs bottleneck_iq1_enq_ready_hidden : %0d", btl_iq_enq_ready_hidden[BTL_IQ1]);
                $display("xs bottleneck_iq1_enq_ready_issued_bypass : %0d", btl_iq_enq_ready_issued_bypass[BTL_IQ1]);
                $display("xs bottleneck_iq1_enq_wakeup_hit : %0d", btl_iq_enq_wakeup_hit[BTL_IQ1]);
                $display("xs bottleneck_iq1_enq_bypass_suppressed : %0d", btl_iq_enq_bypass_suppressed[BTL_IQ1]);
                $display("xs bottleneck_iq1_enq_bypass_fu_blocked : %0d", btl_iq_enq_bypass_fu_blocked[BTL_IQ1]);
                $display("xs bottleneck_iq1_enq_bypass_fu_blocked_bru_cond : %0d", btl_iq_enq_bypass_fu_blocked_bru_cond[BTL_IQ1]);
                $display("xs bottleneck_iq1_enq_bypass_fu_blocked_bru_backedge : %0d", btl_iq_enq_bypass_fu_blocked_bru_backedge[BTL_IQ1]);
                $display("xs bottleneck_iq1_enq_bypass_fu_blocked_bru_jal : %0d", btl_iq_enq_bypass_fu_blocked_bru_jal[BTL_IQ1]);
                $display("xs bottleneck_iq1_enq_bypass_fu_blocked_bru_jalr : %0d", btl_iq_enq_bypass_fu_blocked_bru_jalr[BTL_IQ1]);
                $display("xs bottleneck_iq1_enq_bypass_fu_blocked_serial : %0d", btl_iq_enq_bypass_fu_blocked_serial[BTL_IQ1]);
                $display("xs bottleneck_iq2_valid_entry_sum : %0d", btl_iq_valid_entry_sum[BTL_IQ2]);
                $display("xs bottleneck_iq2_ready_entry_sum : %0d", btl_iq_ready_entry_sum[BTL_IQ2]);
                $display("xs bottleneck_iq2_not_ready_entry_sum : %0d", btl_iq_not_ready_entry_sum[BTL_IQ2]);
                $display("xs bottleneck_iq2_eligible_zero_cycles : %0d", btl_iq_eligible_zero_cycles[BTL_IQ2]);
                $display("xs bottleneck_iq2_eligible_one_cycles : %0d", btl_iq_eligible_one_cycles[BTL_IQ2]);
                $display("xs bottleneck_iq2_eligible_multi_cycles : %0d", btl_iq_eligible_multi_cycles[BTL_IQ2]);
                $display("xs bottleneck_iq2_selected_uops : %0d", btl_iq_selected_uops[BTL_IQ2]);
                $display("xs bottleneck_iq2_arb_loss : %0d", btl_iq_arb_loss[BTL_IQ2]);
                $display("xs bottleneck_iq2_oldest_not_ready_age_max : %0d", btl_iq_oldest_not_ready_age_max[BTL_IQ2]);
                $display("xs bottleneck_iq2_enq_ready_hidden : %0d", btl_iq_enq_ready_hidden[BTL_IQ2]);
                $display("xs bottleneck_iq2_enq_ready_issued_bypass : %0d", btl_iq_enq_ready_issued_bypass[BTL_IQ2]);
                $display("xs bottleneck_iq2_enq_wakeup_hit : %0d", btl_iq_enq_wakeup_hit[BTL_IQ2]);
                $display("xs bottleneck_iq2_enq_bypass_suppressed : %0d", btl_iq_enq_bypass_suppressed[BTL_IQ2]);
                $display("xs bottleneck_iq2_enq_bypass_fu_blocked : %0d", btl_iq_enq_bypass_fu_blocked[BTL_IQ2]);
                $display("xs bottleneck_iq2_enq_bypass_fu_blocked_bru_cond : %0d", btl_iq_enq_bypass_fu_blocked_bru_cond[BTL_IQ2]);
                $display("xs bottleneck_iq2_enq_bypass_fu_blocked_bru_backedge : %0d", btl_iq_enq_bypass_fu_blocked_bru_backedge[BTL_IQ2]);
                $display("xs bottleneck_iq2_enq_bypass_fu_blocked_bru_jal : %0d", btl_iq_enq_bypass_fu_blocked_bru_jal[BTL_IQ2]);
                $display("xs bottleneck_iq2_enq_bypass_fu_blocked_bru_jalr : %0d", btl_iq_enq_bypass_fu_blocked_bru_jalr[BTL_IQ2]);
                $display("xs bottleneck_iq2_enq_bypass_fu_blocked_serial : %0d", btl_iq_enq_bypass_fu_blocked_serial[BTL_IQ2]);
                $display("xs bottleneck_iq_load_valid_entry_sum : %0d", btl_iq_valid_entry_sum[BTL_IQ_LOAD]);
                $display("xs bottleneck_iq_load_ready_entry_sum : %0d", btl_iq_ready_entry_sum[BTL_IQ_LOAD]);
                $display("xs bottleneck_iq_load_not_ready_entry_sum : %0d", btl_iq_not_ready_entry_sum[BTL_IQ_LOAD]);
                $display("xs bottleneck_iq_load_eligible_zero_cycles : %0d", btl_iq_eligible_zero_cycles[BTL_IQ_LOAD]);
                $display("xs bottleneck_iq_load_eligible_one_cycles : %0d", btl_iq_eligible_one_cycles[BTL_IQ_LOAD]);
                $display("xs bottleneck_iq_load_eligible_multi_cycles : %0d", btl_iq_eligible_multi_cycles[BTL_IQ_LOAD]);
                $display("xs bottleneck_iq_load_selected_uops : %0d", btl_iq_selected_uops[BTL_IQ_LOAD]);
                $display("xs bottleneck_iq_load_arb_loss : %0d", btl_iq_arb_loss[BTL_IQ_LOAD]);
                $display("xs bottleneck_iq_load_oldest_not_ready_age_max : %0d", btl_iq_oldest_not_ready_age_max[BTL_IQ_LOAD]);
                $display("xs bottleneck_iq_load_enq_ready_hidden : %0d", btl_iq_enq_ready_hidden[BTL_IQ_LOAD]);
                $display("xs bottleneck_iq_load_enq_ready_issued_bypass : %0d", btl_iq_enq_ready_issued_bypass[BTL_IQ_LOAD]);
                $display("xs bottleneck_iq_load_enq_wakeup_hit : %0d", btl_iq_enq_wakeup_hit[BTL_IQ_LOAD]);
                $display("xs bottleneck_iq_load_enq_bypass_suppressed : %0d", btl_iq_enq_bypass_suppressed[BTL_IQ_LOAD]);
                $display("xs bottleneck_iq_load_enq_bypass_fu_blocked : %0d", btl_iq_enq_bypass_fu_blocked[BTL_IQ_LOAD]);
                $display("xs bottleneck_iq_store_valid_entry_sum : %0d", btl_iq_valid_entry_sum[BTL_IQ_STORE]);
                $display("xs bottleneck_iq_store_ready_entry_sum : %0d", btl_iq_ready_entry_sum[BTL_IQ_STORE]);
                $display("xs bottleneck_iq_store_not_ready_entry_sum : %0d", btl_iq_not_ready_entry_sum[BTL_IQ_STORE]);
                $display("xs bottleneck_iq_store_eligible_zero_cycles : %0d", btl_iq_eligible_zero_cycles[BTL_IQ_STORE]);
                $display("xs bottleneck_iq_store_eligible_one_cycles : %0d", btl_iq_eligible_one_cycles[BTL_IQ_STORE]);
                $display("xs bottleneck_iq_store_eligible_multi_cycles : %0d", btl_iq_eligible_multi_cycles[BTL_IQ_STORE]);
                $display("xs bottleneck_iq_store_selected_uops : %0d", btl_iq_selected_uops[BTL_IQ_STORE]);
                $display("xs bottleneck_iq_store_arb_loss : %0d", btl_iq_arb_loss[BTL_IQ_STORE]);
                $display("xs bottleneck_iq_store_oldest_not_ready_age_max : %0d", btl_iq_oldest_not_ready_age_max[BTL_IQ_STORE]);
                $display("xs bottleneck_iq_store_enq_ready_hidden : %0d", btl_iq_enq_ready_hidden[BTL_IQ_STORE]);
                $display("xs bottleneck_iq_store_enq_ready_issued_bypass : %0d", btl_iq_enq_ready_issued_bypass[BTL_IQ_STORE]);
                $display("xs bottleneck_iq_store_enq_wakeup_hit : %0d", btl_iq_enq_wakeup_hit[BTL_IQ_STORE]);
                $display("xs bottleneck_iq_store_enq_bypass_suppressed : %0d", btl_iq_enq_bypass_suppressed[BTL_IQ_STORE]);
                $display("xs bottleneck_iq_store_enq_bypass_fu_blocked : %0d", btl_iq_enq_bypass_fu_blocked[BTL_IQ_STORE]);
                $display("xs bottleneck_iq_std_valid_entry_sum : %0d", btl_iq_valid_entry_sum[BTL_IQ_STD]);
                $display("xs bottleneck_iq_std_ready_entry_sum : %0d", btl_iq_ready_entry_sum[BTL_IQ_STD]);
                $display("xs bottleneck_iq_std_not_ready_entry_sum : %0d", btl_iq_not_ready_entry_sum[BTL_IQ_STD]);
                $display("xs bottleneck_iq_std_eligible_zero_cycles : %0d", btl_iq_eligible_zero_cycles[BTL_IQ_STD]);
                $display("xs bottleneck_iq_std_eligible_one_cycles : %0d", btl_iq_eligible_one_cycles[BTL_IQ_STD]);
                $display("xs bottleneck_iq_std_eligible_multi_cycles : %0d", btl_iq_eligible_multi_cycles[BTL_IQ_STD]);
                $display("xs bottleneck_iq_std_selected_uops : %0d", btl_iq_selected_uops[BTL_IQ_STD]);
                $display("xs bottleneck_iq_std_arb_loss : %0d", btl_iq_arb_loss[BTL_IQ_STD]);
                $display("xs bottleneck_iq_std_oldest_not_ready_age_max : %0d", btl_iq_oldest_not_ready_age_max[BTL_IQ_STD]);
                $display("xs bottleneck_iq_std_enq_ready_hidden : %0d", btl_iq_enq_ready_hidden[BTL_IQ_STD]);
                $display("xs bottleneck_iq_std_enq_ready_issued_bypass : %0d", btl_iq_enq_ready_issued_bypass[BTL_IQ_STD]);
                $display("xs bottleneck_iq_std_enq_wakeup_hit : %0d", btl_iq_enq_wakeup_hit[BTL_IQ_STD]);
                $display("xs bottleneck_iq_std_enq_bypass_suppressed : %0d", btl_iq_enq_bypass_suppressed[BTL_IQ_STD]);
                $display("xs bottleneck_iq_std_enq_bypass_fu_blocked : %0d", btl_iq_enq_bypass_fu_blocked[BTL_IQ_STD]);
                $display("xs bottleneck_dep_src1_wait : %0d", btl_dep_src1_wait);
                $display("xs bottleneck_dep_src2_wait : %0d", btl_dep_src2_wait);
                $display("xs bottleneck_dep_both_src_wait : %0d", btl_dep_both_src_wait);
                $display("xs bottleneck_dep_wait_on_alu : %0d", btl_dep_wait_on_alu);
                $display("xs bottleneck_dep_wait_on_load : %0d", btl_dep_wait_on_load);
                $display("xs bottleneck_dep_wait_on_branch : %0d", btl_dep_wait_on_branch);
                $display("xs bottleneck_dep_wait_on_mul : %0d", btl_dep_wait_on_mul);
                $display("xs bottleneck_dep_wait_on_div : %0d", btl_dep_wait_on_div);
                $display("xs bottleneck_dep_wait_on_store : %0d", btl_dep_wait_on_store);
                $display("xs bottleneck_dep_wait_on_csr : %0d", btl_dep_wait_on_csr);
                $display("xs bottleneck_dep_wait_on_unknown : %0d", btl_dep_wait_on_unknown);
                $display("xs bottleneck_wakeup_same_cycle_candidate : %0d", btl_wakeup_same_cycle_candidate);
                $display("xs bottleneck_wakeup_same_cycle_missed : %0d", btl_wakeup_same_cycle_missed);
                $display("xs bottleneck_rob_commit_zero_cycles : %0d", commit_hist[0]);
                $display("xs bottleneck_rob_younger_ready_behind_head : %0d", btl_rob_younger_ready_behind_head);
                $display("xs bottleneck_rob_commit_slots_lost_head_block : %0d", btl_rob_commit_slots_lost_head_block);
                $display("xs bottleneck_lsu_load_issue_total : %0d", load_lat_issue_total);
                $display("xs bottleneck_lsu_load_reissue_total : %0d", load_lat_reissue_total);
                $display("xs bottleneck_lsu_load_wb_total : %0d", load_lat_wb_total);
                $display("xs bottleneck_lsu_load_wb_untracked : %0d", load_lat_wb_untracked_total);
                $display("xs bottleneck_lsu_load_latency_0 : %0d", load_lat_hist[0]);
                $display("xs bottleneck_lsu_load_latency_1 : %0d", load_lat_hist[1]);
                $display("xs bottleneck_lsu_load_latency_2 : %0d", load_lat_hist[2]);
                $display("xs bottleneck_lsu_load_latency_3 : %0d", load_lat_hist[3]);
                $display("xs bottleneck_lsu_load_latency_4 : %0d", load_lat_hist[4]);
                $display("xs bottleneck_lsu_load_latency_5 : %0d", load_lat_hist[5]);
                $display("xs bottleneck_lsu_load_latency_6_7 : %0d", load_lat_hist[6]);
                $display("xs bottleneck_lsu_load_latency_8_15 : %0d", load_lat_hist[7]);
                $display("xs bottleneck_lsu_load_latency_16_31 : %0d", load_lat_hist[8]);
                $display("xs bottleneck_lsu_load_latency_32plus : %0d", load_lat_hist[9]);
                $display("xs bottleneck_lsu_load_src_dchit : %0d", load_lat_src_count[LOAD_SRC_DCHIT]);
                $display("xs bottleneck_lsu_load_src_fwd : %0d", load_lat_src_count[LOAD_SRC_FWD]);
                $display("xs bottleneck_lsu_load_src_lmb : %0d", load_lat_src_count[LOAD_SRC_LMB]);
                $display("xs bottleneck_lsu_store_forward_wait : %0d", sq_fwd_wait_cyc);
                $display("xs bottleneck_lsu_store_queue_wait : %0d", sq_wait_p1_cyc);
                $display("xs bottleneck_lsu_store_commit_backlog : %0d", dc_store_req_cyc);
                $display("xs bottleneck_lsu_dcache_port_wait : %0d", p1_dcache_conflict_cyc);
                $display("xs bottleneck_lsu_dual_load_conflict : %0d", p1_dcache_conflict_cyc);
                $display("xs bottleneck_lsu_p1_retry_live : %0d", p1_retry_valid_cyc);
                $display("xs bottleneck_branch_mispredicts : %0d",
                         ctl_misp_cond_cyc + ctl_misp_jal_cyc +
                         ctl_misp_jalr_cyc + ctl_misp_call_cyc +
                         ctl_misp_ret_cyc);
                $display("xs bottleneck_branch_cond_mispredicts : %0d", ctl_misp_cond_cyc);
                $display("xs bottleneck_branch_jal_mispredicts : %0d", ctl_misp_jal_cyc);
                $display("xs bottleneck_branch_jalr_mispredicts : %0d", ctl_misp_jalr_cyc);
                $display("xs bottleneck_branch_call_mispredicts : %0d", ctl_misp_call_cyc);
                $display("xs bottleneck_branch_ret_mispredicts : %0d", ctl_misp_ret_cyc);
                $display("xs bottleneck_branch_ghr_restore : %0d", ghr_restore_cyc);
                $display("xs bottleneck_branch_ras_restore : %0d", ras_restore_cyc);
            end
        end
    end

    integer trace_cycle;
    // -------------------------------------------------------------------------
    // dep.v1 / pipe.v1 trace state
    // -------------------------------------------------------------------------
    // Per-ROB-entry shadow buffer captured at rename time.  Holds the few
    // decode/rename fields needed for the dep.v1 trace that are not already
    // exposed via rob_head_* (raw insn, src arch regs, src physical regs,
    // FU class, mem access size).  A separate sibling array avoids bloating
    // the synthesizable rename_buf; the snoop reads u_core.ren_insn[].
    logic [31:0] dep_raw       [0:ROB_DEPTH-1];
    logic [4:0]  dep_rs1_arch  [0:ROB_DEPTH-1];
    logic [4:0]  dep_rs2_arch  [0:ROB_DEPTH-1];
    logic [PHYS_REG_BITS-1:0] dep_rs1_phys [0:ROB_DEPTH-1];
    logic [PHYS_REG_BITS-1:0] dep_rs2_phys [0:ROB_DEPTH-1];
    logic [2:0]  dep_fu        [0:ROB_DEPTH-1]; // fu_type_e (3-bit enum)
    logic [1:0]  dep_mem_size  [0:ROB_DEPTH-1]; // mem_size_e
    // Monotonic global commit sequence number (across all slots, all cycles).
    longint dep_seq_counter;
    // Branch epoch: increments on each commit-side full-flush event.
    longint dep_epoch_counter;

    // -------------------------------------------------------------------------
    // UOPLIFE: per-uop lifecycle tracking (gated on +TRACE_UOPLIFE).
    //
    // Sim-only.  Captures a per-ROB-entry timestamp at each pipeline stage
    // (rename, dispatch, issue, write-back) and emits one [UOPLIFE ...] line
    // at commit, including total time-in-ROB and per-stage deltas.  All
    // tracker arrays are indexed by ROB index (128 entries).
    //
    // Stage definitions:
    //   rename_cyc   = trace_cycle when rename allocated rob_idx for the slot
    //   dispatch_cyc = trace_cycle when uop dequeued from dispatch queue into
    //                  an issue queue
    //   issue_cyc    = trace_cycle when uop was selected by IQ scheduler and
    //                  dispatched to its FU (or load/store address-gen pipe)
    //   wb_cyc       = trace_cycle when CDB carried this rob_idx (or load_wb
    //                  sideband fired for loads)
    //   commit_cyc   = trace_cycle when ROB retired this entry
    // -------------------------------------------------------------------------
    integer     uoplife_rename_cyc   [0:ROB_DEPTH-1];
    integer     uoplife_dispatch_cyc [0:ROB_DEPTH-1];
    integer     uoplife_issue_cyc    [0:ROB_DEPTH-1];
    integer     uoplife_wb_cyc       [0:ROB_DEPTH-1];
    logic [63:0] uoplife_pc          [0:ROB_DEPTH-1];
    logic [2:0]  uoplife_fu          [0:ROB_DEPTH-1];
    logic        uoplife_is_load     [0:ROB_DEPTH-1];
    logic        uoplife_is_store    [0:ROB_DEPTH-1];
    logic        uoplife_is_branch   [0:ROB_DEPTH-1];
    logic [PHYS_REG_BITS-1:0] uoplife_pdst [0:ROB_DEPTH-1];
    logic       uoplife_valid        [0:ROB_DEPTH-1];
    longint     uoplife_seq_counter;

    logic [7:0] trace_prev_rat_a0;
    logic [7:0] trace_prev_crat_a0;
    logic [7:0] trace_prev_rat_a5;
    logic [7:0] trace_prev_crat_a5;
    logic [63:0] trace_prev_rat_a5_data;
    logic [63:0] trace_prev_crat_a5_data;
    logic [7:0] trace_prev_rat_sp;
    logic [7:0] trace_prev_crat_sp;
    logic [63:0] trace_prev_rat_sp_data;
    logic [63:0] trace_prev_crat_sp_data;
    logic [7:0] trace_prev_rat_ra;
    logic [7:0] trace_prev_crat_ra;
    logic [63:0] trace_prev_rat_ra_data;
    logic [63:0] trace_prev_crat_ra_data;
    logic [7:0] trace_prev_rat_s10;
    logic [7:0] trace_prev_crat_s10;
    logic [63:0] trace_prev_rat_s10_data;
    logic [63:0] trace_prev_crat_s10_data;
    logic       trace_prev_free2;
    logic       trace_prev_cmt2;
    logic [1:0] trace_prev_uoc_state;
    logic       trace_prev_uoc_active;
    logic [63:0] trace_sq_alloc_pc [0:SQ_DEPTH-1];
    logic [ROB_IDX_BITS-1:0] trace_sq_alloc_rob [0:SQ_DEPTH-1];
    logic [63:0] trace_csb_pc [0:CSB_DEPTH-1];
    logic [ROB_IDX_BITS-1:0] trace_csb_rob [0:CSB_DEPTH-1];
    integer     cm_progress_count [0:20];
    integer     matrix_branch_trace_count;
    integer     trace_lowpc_count;
    localparam logic [63:0] COMMIT_HOTSPOT_BASE = 64'h0000_0000_8000_2000;
    localparam int COMMIT_HOTSPOT_BINS = 4096;
    integer     commit_pc_hist [0:COMMIT_HOTSPOT_BINS-1];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            trace_cycle <= 0;
            trace_prev_rat_a0  <= 8'd10;
            trace_prev_crat_a0 <= 8'd10;
            trace_prev_rat_a5  <= 8'd15;
            trace_prev_crat_a5 <= 8'd15;
            trace_prev_rat_a5_data  <= 64'd0;
            trace_prev_crat_a5_data <= 64'd0;
            trace_prev_rat_sp  <= 8'd2;
            trace_prev_crat_sp <= 8'd2;
            trace_prev_rat_sp_data  <= 64'd0;
            trace_prev_crat_sp_data <= 64'd0;
            trace_prev_rat_ra  <= 8'd1;
            trace_prev_crat_ra <= 8'd1;
            trace_prev_rat_ra_data  <= 64'd0;
            trace_prev_crat_ra_data <= 64'd0;
            trace_prev_rat_s10  <= 8'd26;
            trace_prev_crat_s10 <= 8'd26;
            trace_prev_rat_s10_data  <= 64'd0;
            trace_prev_crat_s10_data <= 64'd0;
            trace_prev_free2   <= 1'b0;
            trace_prev_cmt2    <= 1'b0;
            trace_prev_uoc_state  <= 2'd0;
            trace_prev_uoc_active <= 1'b0;
            for (int i = 0; i <= 20; i++) begin
                cm_progress_count[i] <= 0;
            end
            for (int i = 0; i < SQ_DEPTH; i++) begin
                trace_sq_alloc_pc[i]  <= 64'd0;
                trace_sq_alloc_rob[i] <= '0;
            end
            for (int i = 0; i < CSB_DEPTH; i++) begin
                trace_csb_pc[i]  <= 64'd0;
                trace_csb_rob[i] <= '0;
            end
            for (int i = 0; i < COMMIT_HOTSPOT_BINS; i++) begin
                commit_pc_hist[i] <= 0;
            end
            matrix_branch_trace_count <= 0;
            trace_lowpc_count <= 0;
            // dep.v1 shadow buffer + counters reset
            for (int i = 0; i < ROB_DEPTH; i++) begin
                dep_raw[i]      <= 32'd0;
                dep_rs1_arch[i] <= 5'd0;
                dep_rs2_arch[i] <= 5'd0;
                dep_rs1_phys[i] <= '0;
                dep_rs2_phys[i] <= '0;
                dep_fu[i]       <= 3'd0;
                dep_mem_size[i] <= 2'd0;
            end
            dep_seq_counter   <= 0;
            dep_epoch_counter <= 0;
            // UOPLIFE tracker reset
            for (int i = 0; i < ROB_DEPTH; i++) begin
                uoplife_rename_cyc[i]   <= 0;
                uoplife_dispatch_cyc[i] <= 0;
                uoplife_issue_cyc[i]    <= 0;
                uoplife_wb_cyc[i]       <= 0;
                uoplife_pc[i]           <= 64'd0;
                uoplife_fu[i]           <= 3'd0;
                uoplife_is_load[i]      <= 1'b0;
                uoplife_is_store[i]     <= 1'b0;
                uoplife_is_branch[i]    <= 1'b0;
                uoplife_pdst[i]         <= '0;
                uoplife_valid[i]        <= 1'b0;
            end
            uoplife_seq_counter <= 0;
        end else begin
            trace_cycle <= trace_cycle + 1;
            // -----------------------------------------------------------------
            // dep.v1: snoop rename-stage outputs and stash per-ROB metadata
            // for use at commit time.  Mirrors the same gating that
            // rv64gc_core_top uses to write rename_buf.
            // -----------------------------------------------------------------
            if (trace_dep_en) begin
                for (int i = 0; i < PIPE_WIDTH; i++) begin
                    if (3'(i) < u_core.ren_count_w) begin
                        dep_raw[u_core.ren_insn[i].rob_idx]      <= u_core.ren_insn[i].base.insn;
                        dep_rs1_arch[u_core.ren_insn[i].rob_idx] <= u_core.ren_insn[i].base.rs1_arch;
                        dep_rs2_arch[u_core.ren_insn[i].rob_idx] <= u_core.ren_insn[i].base.rs2_arch;
                        dep_rs1_phys[u_core.ren_insn[i].rob_idx] <= u_core.ren_insn[i].rs1_phys;
                        dep_rs2_phys[u_core.ren_insn[i].rob_idx] <= u_core.ren_insn[i].rs2_phys;
                        dep_fu[u_core.ren_insn[i].rob_idx]       <= u_core.ren_insn[i].base.fu_type;
                        dep_mem_size[u_core.ren_insn[i].rob_idx] <= u_core.ren_insn[i].base.mem_size;
                    end
                end
            end
            // Increment branch epoch on commit-side full flush.
            if (trace_dep_en && u_core.flush_out.valid && u_core.flush_out.full_flush) begin
                dep_epoch_counter <= dep_epoch_counter + 1;
            end
            // UOPLIFE: invalidate all in-flight tracker entries on a full
            // flush so squashed uops don't pollute future allocations at the
            // same rob_idx.  (Commit retires happen prior to the flush in
            // the same cycle, so cleared entries here are squashed-only.)
            if (trace_uoplife_en && u_core.flush_out.valid && u_core.flush_out.full_flush) begin
                for (int r = 0; r < ROB_DEPTH; r++) begin
                    uoplife_valid[r]        <= 1'b0;
                    uoplife_rename_cyc[r]   <= 0;
                    uoplife_dispatch_cyc[r] <= 0;
                    uoplife_issue_cyc[r]    <= 0;
                    uoplife_wb_cyc[r]       <= 0;
                end
            end
            // -----------------------------------------------------------------
            // UOPLIFE: rename hook — capture rename_cyc + static fields when
            // rename allocates a rob_idx for slot i.
            // -----------------------------------------------------------------
            if (trace_uoplife_en) begin
                for (int i = 0; i < PIPE_WIDTH; i++) begin
                    if (3'(i) < u_core.ren_count_w) begin
                        uoplife_rename_cyc[u_core.ren_insn[i].rob_idx]   <= trace_cycle;
                        uoplife_dispatch_cyc[u_core.ren_insn[i].rob_idx] <= 0;
                        uoplife_issue_cyc[u_core.ren_insn[i].rob_idx]    <= 0;
                        uoplife_wb_cyc[u_core.ren_insn[i].rob_idx]       <= 0;
                        uoplife_pc[u_core.ren_insn[i].rob_idx]           <= u_core.ren_insn[i].base.pc;
                        uoplife_fu[u_core.ren_insn[i].rob_idx]           <= u_core.ren_insn[i].base.fu_type;
                        uoplife_is_load[u_core.ren_insn[i].rob_idx]      <= u_core.ren_insn[i].base.is_load;
                        uoplife_is_store[u_core.ren_insn[i].rob_idx]     <= u_core.ren_insn[i].base.is_store;
                        uoplife_is_branch[u_core.ren_insn[i].rob_idx]    <= u_core.ren_insn[i].base.is_branch;
                        uoplife_pdst[u_core.ren_insn[i].rob_idx]         <= u_core.ren_insn[i].pdst;
                        uoplife_valid[u_core.ren_insn[i].rob_idx]        <= 1'b1;
                    end
                end
                // Dispatch hook: capture dispatch_cyc when uop dequeues from
                // dispatch queue toward IQ array.
                for (int i = 0; i < PIPE_WIDTH; i++) begin
                    if ((i < int'(u_core.dq_deq_count)) &&
                        u_core.dq_deq_data[i].base.valid) begin
                        if (uoplife_valid[u_core.dq_deq_data[i].rob_idx])
                            uoplife_dispatch_cyc[u_core.dq_deq_data[i].rob_idx] <= trace_cycle;
                    end
                end
                // Issue hook: capture issue_cyc when an IQ port issues.  Cover
                // IQ0 (2 ports), IQ1 (1), IQ2 (1), load IQ (2), store IQ (1),
                // and the std issue side (1).
                for (int s = 0; s < 2; s++) begin
                    if (u_core.iq0_issue_valid[s] &&
                        uoplife_valid[u_core.iq0_issue_data[s].rob_idx])
                        uoplife_issue_cyc[u_core.iq0_issue_data[s].rob_idx] <= trace_cycle;
                end
                if (u_core.iq1_issue_valid[0] &&
                    uoplife_valid[u_core.iq1_issue_data[0].rob_idx])
                    uoplife_issue_cyc[u_core.iq1_issue_data[0].rob_idx] <= trace_cycle;
                if (u_core.iq2_issue_valid[0] &&
                    uoplife_valid[u_core.iq2_issue_data[0].rob_idx])
                    uoplife_issue_cyc[u_core.iq2_issue_data[0].rob_idx] <= trace_cycle;
                for (int p = 0; p < 2; p++) begin
                    if (u_core.iq_load_issue_valid[p] &&
                        uoplife_valid[u_core.iq_load_issue_data[p].rob_idx])
                        uoplife_issue_cyc[u_core.iq_load_issue_data[p].rob_idx] <= trace_cycle;
                end
                if (u_core.iq_store_issue_valid[0] &&
                    uoplife_valid[u_core.iq_store_issue_data[0].rob_idx])
                    uoplife_issue_cyc[u_core.iq_store_issue_data[0].rob_idx] <= trace_cycle;
                // Writeback hook: CDB carries rob_idx + pdst; load_wb sideband
                // covers load returns that go around the CDB-only pdst path.
                for (int c = 0; c < CDB_WIDTH; c++) begin
                    if (u_core.cdb_valid[c] &&
                        uoplife_valid[u_core.cdb_rob_idx[c]])
                        uoplife_wb_cyc[u_core.cdb_rob_idx[c]] <= trace_cycle;
                end
                for (int p = 0; p < 2; p++) begin
                    if (u_core.lsu_load_wb_valid[p] &&
                        uoplife_valid[u_core.lsu_load_wb_rob_idx[p]])
                        uoplife_wb_cyc[u_core.lsu_load_wb_rob_idx[p]] <= trace_cycle;
                end
            end
            if (trace_ordv_en && u_core.lsu_ordering_violation) begin
                $display("[ORDV] cyc=%0d viol_rob=%0d replay_valid=%b flush=%b head=%0d tail=%0d count=%0d",
                    trace_cycle,
                    u_core.lsu_violation_rob_idx,
                    u_core.replay_valid,
                    u_core.flush_out.valid,
                    u_core.u_rob.head_r,
                    u_core.u_rob.tail_r,
                    u_core.u_rob.count_r);
                $display("[ORDV_STA] cyc=%0d rob=%0d pc=%016h addr=%016h size=%0d rs2=%016h",
                    trace_cycle,
                    u_core.u_lsu.sta_issue_data.rob_idx,
                    u_core.u_lsu.sta_issue_data.pc,
                    u_core.u_lsu.sta_eff_addr,
                    u_core.u_lsu.sta_issue_data.mem_size,
                    u_core.u_lsu.std_rs2);
                for (int q = 0; q < 64; q++) begin
                    if (u_core.u_lsu.u_load_queue.queue[q].valid &&
                        u_core.u_lsu.u_load_queue.queue[q].executed) begin
                        $display("[ORDV_LQ] cyc=%0d idx=%0d rob=%0d addr=%016h size=%0d has_result=%b data=%016h",
                            trace_cycle,
                            q,
                            u_core.u_lsu.u_load_queue.queue[q].rob_idx,
                            u_core.u_lsu.u_load_queue.queue[q].addr,
                            u_core.u_lsu.u_load_queue.queue[q].size,
                            u_core.u_lsu.u_load_queue.queue[q].has_result,
                            u_core.u_lsu.u_load_queue.queue[q].data);
                    end
                end
            end
            if (trace_ordv_en && u_core.replay_valid) begin
                $display("[REPLAY] cyc=%0d rob=%0d flush=%b redirect=%016h full=%b",
                    trace_cycle,
                    u_core.replay_rob_idx_from,
                    u_core.flush_out.valid,
                    u_core.flush_out.redirect_pc,
                    u_core.flush_out.full_flush);
            end
            if (trace_uoc_en) begin
                automatic logic hot_uoc_window;
                hot_uoc_window = 1'b0;
                for (int i = 0; i < PIPE_WIDTH; i++) begin
                    if (u_core.fused_insn[i].valid &&
                        (((u_core.fused_insn[i].pc >= 64'h0000_0000_8000_2000) &&
                          (u_core.fused_insn[i].pc <= 64'h0000_0000_8000_202a)) ||
	                         ((u_core.fused_insn[i].pc >= 64'h0000_0000_8000_2290) &&
	                          (u_core.fused_insn[i].pc <= 64'h0000_0000_8000_2320)) ||
	                         ((u_core.fused_insn[i].pc >= 64'h0000_0000_8000_2150) &&
	                          (u_core.fused_insn[i].pc <= 64'h0000_0000_8000_21a0)) ||
	                         ((u_core.fused_insn[i].pc >= 64'h0000_0000_8000_2440) &&
	                          (u_core.fused_insn[i].pc <= 64'h0000_0000_8000_24d0)))) begin
                        hot_uoc_window = 1'b1;
                    end
                end
                if (hot_uoc_window ||
`ifdef SIMULATION
                    1'b0 ||
`endif
                    1'b0 ||
                    (u_core.uoc_active != trace_prev_uoc_active) ||
                    (u_core.u_uop_cache.state_r != trace_prev_uoc_state) ||
                    u_core.bru_early_redirect ||
                    u_core.flush_out.valid) begin
                    $display("[UOCDBG] cyc=%0d state=%0d active=%b fused_count=%0d uoc_count=%0d bru_redir=%b bru_pc=%016h flush=%b fl_pc=%016h",
                        trace_cycle,
                        u_core.u_uop_cache.state_r,
                        u_core.uoc_active,
                        u_core.fused_count,
                        u_core.uoc_count,
                        u_core.bru_early_redirect,
                        u_core.bru_target,
                        u_core.flush_out.valid,
                        u_core.flush_out.redirect_pc);
                    for (int i = 0; i < PIPE_WIDTH; i++) begin
                        automatic decoded_insn_t trace_insn;
                        automatic logic trace_valid;
                        automatic logic trace_from_uoc;

                        trace_from_uoc = u_core.uoc_active;
                        trace_insn = trace_from_uoc ? u_core.uoc_insn[i]
                                                    : u_core.fused_insn[i];
                        trace_valid = trace_from_uoc ? (i < int'(u_core.uoc_count))
                                                     : u_core.fused_insn[i].valid;

                        if (trace_valid) begin
                            $display("[UOCSLOT%0d] cyc=%0d src=%s pc=%016h br=%b jal=%b jalr=%b bp_tk=%b bp_tgt=%016h fused=%b",
                                i,
                                trace_cycle,
                                trace_from_uoc ? "uoc" : "fe",
                                trace_insn.pc,
                                trace_insn.is_branch,
                                trace_insn.is_jal,
                                trace_insn.is_jalr,
                                trace_insn.bp_taken,
                                trace_insn.bp_target,
                                trace_insn.is_fused);
                        end
                    end
                end
                trace_prev_uoc_state  <= u_core.u_uop_cache.state_r;
                trace_prev_uoc_active <= u_core.uoc_active;
            end
            if (trace_a0map_en) begin
                if ((u_core.u_rename.u_rat.rat_table[10] != trace_prev_rat_a0) ||
                    (u_core.u_rename.u_rat.committed_rat[10] != trace_prev_crat_a0) ||
                    (u_core.u_rename.u_free_list.free_bitmap[2] != trace_prev_free2) ||
                    (u_core.u_rename.u_free_list.committed_bitmap[2] != trace_prev_cmt2) ||
                    (u_core.u_rename.u_rat.rat_table[10] == 8'd2) ||
                    (u_core.u_rename.u_rat.committed_rat[10] == 8'd2)) begin
                    $display("[A0MAP] cyc=%0d rat10=%0d crat10=%0d free2=%b cmt2=%b ren_count=%0d commit_count=%0d flush=%b flush_pc=%016h",
                        trace_cycle,
                        u_core.u_rename.u_rat.rat_table[10],
                        u_core.u_rename.u_rat.committed_rat[10],
                        u_core.u_rename.u_free_list.free_bitmap[2],
                        u_core.u_rename.u_free_list.committed_bitmap[2],
                        u_core.ren_count_w,
                        u_core.commit_count,
                        u_core.flush_out.valid,
                        u_core.flush_out.redirect_pc);
                end
                trace_prev_rat_a0  <= u_core.u_rename.u_rat.rat_table[10];
                trace_prev_crat_a0 <= u_core.u_rename.u_rat.committed_rat[10];
                trace_prev_free2   <= u_core.u_rename.u_free_list.free_bitmap[2];
                trace_prev_cmt2    <= u_core.u_rename.u_free_list.committed_bitmap[2];
            end
            if (trace_a5map_en) begin
                automatic logic [7:0] rat_a5_phys;
                automatic logic [7:0] crat_a5_phys;
                automatic logic [63:0] rat_a5_data;
                automatic logic [63:0] crat_a5_data;

                rat_a5_phys  = u_core.u_rename.u_rat.rat_table[15];
                crat_a5_phys = u_core.u_rename.u_rat.committed_rat[15];
                rat_a5_data  = (rat_a5_phys == 8'd0)  ? 64'd0 : u_core.u_int_prf.regfile_copy0[rat_a5_phys];
                crat_a5_data = (crat_a5_phys == 8'd0) ? 64'd0 : u_core.u_int_prf.regfile_copy0[crat_a5_phys];

                if ((rat_a5_phys != trace_prev_rat_a5) ||
                    (crat_a5_phys != trace_prev_crat_a5) ||
                    (rat_a5_data != trace_prev_rat_a5_data) ||
                    (crat_a5_data != trace_prev_crat_a5_data) ||
                    u_core.flush_out.valid) begin
                    $display("[A5MAP] cyc=%0d rat15=%0d rat15_data=%016h crat15=%0d crat15_data=%016h ren_count=%0d commit_count=%0d flush=%b flush_pc=%016h",
                        trace_cycle,
                        rat_a5_phys,
                        rat_a5_data,
                        crat_a5_phys,
                        crat_a5_data,
                        u_core.ren_count_w,
                        u_core.commit_count,
                        u_core.flush_out.valid,
                        u_core.flush_out.redirect_pc);
                end
                trace_prev_rat_a5       <= rat_a5_phys;
                trace_prev_crat_a5      <= crat_a5_phys;
                trace_prev_rat_a5_data  <= rat_a5_data;
                trace_prev_crat_a5_data <= crat_a5_data;
            end
            if (trace_spmap_en) begin
                automatic logic [7:0] rat_sp_phys;
                automatic logic [7:0] crat_sp_phys;
                automatic logic [63:0] rat_sp_data;
                automatic logic [63:0] crat_sp_data;

                rat_sp_phys  = u_core.u_rename.u_rat.rat_table[2];
                crat_sp_phys = u_core.u_rename.u_rat.committed_rat[2];
                rat_sp_data  = (rat_sp_phys == 8'd0)  ? 64'd0 : u_core.u_int_prf.regfile_copy0[rat_sp_phys];
                crat_sp_data = (crat_sp_phys == 8'd0) ? 64'd0 : u_core.u_int_prf.regfile_copy0[crat_sp_phys];

                if ((rat_sp_phys != trace_prev_rat_sp) ||
                    (crat_sp_phys != trace_prev_crat_sp) ||
                    (rat_sp_data != trace_prev_rat_sp_data) ||
                    (crat_sp_data != trace_prev_crat_sp_data) ||
                    u_core.flush_out.valid) begin
                    $display("[SPMAP] cyc=%0d rat2=%0d rat2_data=%016h crat2=%0d crat2_data=%016h ren_count=%0d commit_count=%0d flush=%b full=%b flush_pc=%016h",
                        trace_cycle,
                        rat_sp_phys,
                        rat_sp_data,
                        crat_sp_phys,
                        crat_sp_data,
                        u_core.ren_count_w,
                        u_core.commit_count,
                        u_core.flush_out.valid,
                        u_core.flush_out.full_flush,
                        u_core.flush_out.redirect_pc);
                end
                for (int i = 0; i < PIPE_WIDTH; i++) begin
                    if (u_core.commit_out[i].valid &&
                        u_core.commit_out[i].rd_valid &&
                        (u_core.commit_out[i].rd_arch == 5'd2)) begin
                        $display("[SPCMT] cyc=%0d slot=%0d pc=%016h pdst=%0d old_pdst=%0d pdst_data=%016h commit_count=%0d flush=%b full=%b",
                            trace_cycle,
                            i,
                            u_core.rob_head_pc[i],
                            u_core.commit_out[i].pdst,
                            u_core.commit_out[i].old_pdst,
                            (u_core.commit_out[i].pdst == 8'd0) ? 64'd0 : u_core.u_int_prf.regfile_copy0[u_core.commit_out[i].pdst],
                            u_core.commit_count,
                            u_core.flush_out.valid,
                            u_core.flush_out.full_flush);
                    end
                end
                trace_prev_rat_sp       <= rat_sp_phys;
                trace_prev_crat_sp      <= crat_sp_phys;
                trace_prev_rat_sp_data  <= rat_sp_data;
                trace_prev_crat_sp_data <= crat_sp_data;
            end
            if (trace_ralink_en) begin
                automatic logic [7:0]  rat_ra_phys;
                automatic logic [7:0]  crat_ra_phys;
                automatic logic [63:0] rat_ra_data;
                automatic logic [63:0] crat_ra_data;
                automatic logic [7:0]  rat_s10_phys;
                automatic logic [7:0]  crat_s10_phys;
                automatic logic [63:0] rat_s10_data;
                automatic logic [63:0] crat_s10_data;

                rat_ra_phys  = u_core.u_rename.u_rat.rat_table[1];
                crat_ra_phys = u_core.u_rename.u_rat.committed_rat[1];
                rat_ra_data  = (rat_ra_phys == 8'd0) ? 64'd0 : u_core.u_int_prf.regfile_copy0[rat_ra_phys];
                crat_ra_data = (crat_ra_phys == 8'd0) ? 64'd0 : u_core.u_int_prf.regfile_copy0[crat_ra_phys];
                rat_s10_phys  = u_core.u_rename.u_rat.rat_table[26];
                crat_s10_phys = u_core.u_rename.u_rat.committed_rat[26];
                rat_s10_data  = (rat_s10_phys == 8'd0) ? 64'd0 : u_core.u_int_prf.regfile_copy0[rat_s10_phys];
                crat_s10_data = (crat_s10_phys == 8'd0) ? 64'd0 : u_core.u_int_prf.regfile_copy0[crat_s10_phys];

                if ((rat_ra_phys != trace_prev_rat_ra) ||
                    (crat_ra_phys != trace_prev_crat_ra) ||
                    (rat_ra_data != trace_prev_rat_ra_data) ||
                    (crat_ra_data != trace_prev_crat_ra_data) ||
                    u_core.flush_out.valid) begin
	                        $display("[RAMAP] cyc=%0d rat1=%0d rat1_data=%016h crat1=%0d crat1_data=%016h ren_count=%0d commit_count=%0d flush=%b full=%b redir=%016h",
                        trace_cycle,
                        rat_ra_phys,
                        rat_ra_data,
                        crat_ra_phys,
                        crat_ra_data,
                        u_core.ren_count_w,
                        u_core.commit_count,
                        u_core.flush_out.valid,
                        u_core.flush_out.full_flush,
	                            u_core.flush_out.redirect_pc);
	                end
	                if ((rat_s10_phys != trace_prev_rat_s10) ||
	                    (crat_s10_phys != trace_prev_crat_s10) ||
	                    (rat_s10_data != trace_prev_rat_s10_data) ||
	                    (crat_s10_data != trace_prev_crat_s10_data) ||
	                    u_core.flush_out.valid) begin
	                    $display("[S10MAP] cyc=%0d rat26=%0d rat26_data=%016h crat26=%0d crat26_data=%016h ren_count=%0d commit_count=%0d flush=%b full=%b redir=%016h",
	                        trace_cycle,
	                        rat_s10_phys,
	                        rat_s10_data,
	                        crat_s10_phys,
	                        crat_s10_data,
	                        u_core.ren_count_w,
	                        u_core.commit_count,
	                        u_core.flush_out.valid,
	                        u_core.flush_out.full_flush,
	                        u_core.flush_out.redirect_pc);
	                end
	                for (int w = 0; w < PIPE_WIDTH; w++) begin
	                    if (u_core.u_rename.rat_wr_en[w] &&
	                        ((u_core.u_rename.rat_wr_arch[w] == 5'd26) ||
	                         (u_core.u_rename.rat_wr_phys[w] == 8'd10))) begin
	                        $display("[RATWR] cyc=%0d slot=%0d arch=%0d phys=%0d pc=%016h ren_count=%0d flush=%b full=%b",
	                            trace_cycle,
	                            w,
	                            u_core.u_rename.rat_wr_arch[w],
	                            u_core.u_rename.rat_wr_phys[w],
	                            u_core.u_rename.work_insn[w].pc,
	                            u_core.ren_count_w,
	                            u_core.flush_out.valid,
	                            u_core.flush_out.full_flush);
	                    end
	                end

                for (int i = 0; i < PIPE_WIDTH; i++) begin
                    if ((i < int'(u_core.ren_count_w)) &&
                        u_core.ren_insn[i].base.valid &&
                        (tb_coremark_ra_path_pc(u_core.ren_insn[i].base.pc) ||
                         (u_core.ren_insn[i].base.rd_arch == 5'd1) ||
                         (u_core.ren_insn[i].base.rs1_arch == 5'd1) ||
                         (u_core.ren_insn[i].base.rs2_arch == 5'd1))) begin
                        $display("[RAREN] cyc=%0d slot=%0d pc=%016h insn=%08h rob=%0d fu=%0d br=%0d rdv=%b rd=%0d pdst=%0d old=%0d rs1v=%b rs1=%0d rs1p=%0d rs1r=%b rs2v=%b rs2=%0d rs2p=%0d rs2r=%b rat1=%0d crat1=%0d",
                            trace_cycle,
                            i,
                            u_core.ren_insn[i].base.pc,
                            u_core.ren_insn[i].base.insn,
                            u_core.ren_insn[i].rob_idx,
                            u_core.ren_insn[i].base.fu_type,
                            u_core.ren_insn[i].base.br_op,
                            u_core.ren_insn[i].base.rd_valid,
                            u_core.ren_insn[i].base.rd_arch,
                            u_core.ren_insn[i].pdst,
                            u_core.ren_insn[i].old_pdst,
                            u_core.ren_insn[i].base.rs1_valid,
                            u_core.ren_insn[i].base.rs1_arch,
                            u_core.ren_insn[i].rs1_phys,
                            u_core.ren_insn[i].rs1_ready,
                            u_core.ren_insn[i].base.rs2_valid,
                            u_core.ren_insn[i].base.rs2_arch,
                            u_core.ren_insn[i].rs2_phys,
                            u_core.ren_insn[i].rs2_ready,
                            rat_ra_phys,
                            crat_ra_phys);
                    end
                    if ((i < int'(u_core.dq_deq_count)) &&
                        u_core.dq_deq_data[i].base.valid &&
                        tb_coremark_ra_path_pc(u_core.dq_deq_data[i].base.pc)) begin
                        $display("[RADQ] cyc=%0d slot=%0d pc=%016h rob=%0d iq=%0d rdv=%b rd=%0d pdst=%0d rs1p=%0d rs1r=%b rs2p=%0d rs2r=%b",
                            trace_cycle,
                            i,
                            u_core.dq_deq_data[i].base.pc,
                            u_core.dq_deq_data[i].rob_idx,
                            u_core.dq_deq_iq_target[i],
                            u_core.dq_deq_data[i].base.rd_valid,
                            u_core.dq_deq_data[i].base.rd_arch,
                            u_core.dq_deq_data[i].pdst,
                            u_core.dq_deq_data[i].rs1_phys,
                            u_core.dq_deq_data[i].rs1_ready,
                            u_core.dq_deq_data[i].rs2_phys,
                            u_core.dq_deq_data[i].rs2_ready);
                    end
                    if (u_core.commit_out[i].valid &&
                        (tb_coremark_ra_path_pc(u_core.rob_head_pc[i]) ||
                         (u_core.commit_out[i].rd_valid &&
                          (u_core.commit_out[i].rd_arch == 5'd1)) ||
                         (u_core.rob_head_is_branch[i] &&
                          u_core.rob_head_branch_taken[i] &&
                          (u_core.rob_head_branch_target[i] == 64'd0)))) begin
                        $display("[RACMT] cyc=%0d slot=%0d pc=%016h cc=%0d rdv=%b rd=%0d pdst=%0d pdst_data=%016h old=%0d br=%b tk=%b tgt=%016h mis=%b rat1=%0d rat1_data=%016h crat1=%0d crat1_data=%016h",
                            trace_cycle,
                            i,
                            u_core.rob_head_pc[i],
                            u_core.commit_count,
                            u_core.commit_out[i].rd_valid,
                            u_core.commit_out[i].rd_arch,
                            u_core.commit_out[i].pdst,
                            (u_core.commit_out[i].pdst == 8'd0) ? 64'd0 : u_core.u_int_prf.regfile_copy0[u_core.commit_out[i].pdst],
                            u_core.commit_out[i].old_pdst,
                            u_core.rob_head_is_branch[i],
                            u_core.rob_head_branch_taken[i],
                            u_core.rob_head_branch_target[i],
                            u_core.rob_head_branch_mispredict[i],
                            rat_ra_phys,
                            rat_ra_data,
                            crat_ra_phys,
                            crat_ra_data);
                    end
                end

                for (int c = 0; c < CDB_WIDTH; c++) begin
                    if (u_core.cdb_valid[c] &&
                        (u_core.cdb_tag[c] != 8'd0) &&
                        ((u_core.cdb_tag[c] == rat_ra_phys) ||
                         (u_core.cdb_tag[c] == crat_ra_phys) ||
                         ((u_core.cdb_data[c] >= 64'h0000_0000_8000_0000) &&
                          (u_core.cdb_data[c] <  64'h0000_0000_8001_0000)))) begin
                        $display("[RACDB] cyc=%0d cdb=%0d rob=%0d tag=%0d data=%016h is_br=%b br_tgt=%016h mis=%b rat1=%0d crat1=%0d",
                            trace_cycle,
                            c,
                            u_core.cdb_rob_idx[c],
                            u_core.cdb_tag[c],
                            u_core.cdb_data[c],
                            u_core.cdb_is_branch[c],
                            u_core.cdb_branch_target[c],
                            u_core.cdb_branch_mispredict[c],
                            rat_ra_phys,
                            crat_ra_phys);
                    end
                end

                if (u_core.bru_issue &&
                    tb_coremark_ra_path_pc(u_core.iq0_issue_data[0].pc)) begin
                    $display("[RABRU0] cyc=%0d pc=%016h rob=%0d op=%0d rvc=%b rd_pdst=%0d rs1p=%0d rs1r=%b prf=%016h byp=%016h bhit=%b imm=%016h bp_tk=%b bp_tgt=%016h taken=%b tgt=%016h link=%016h mis=%b",
                        trace_cycle,
                        u_core.iq0_issue_data[0].pc,
                        u_core.iq0_issue_data[0].rob_idx,
                        u_core.iq0_issue_data[0].br_op,
                        u_core.iq0_issue_data[0].is_rvc,
                        u_core.iq0_issue_data[0].pdst,
                        u_core.iq0_issue_data[0].rs1_phys,
                        u_core.iq0_issue_data[0].rs1_ready,
                        u_core.prf_rdata[0],
                        u_core.bypassed_data[0],
                        u_core.bypass_hit[0],
                        u_core.iq0_issue_data[0].imm,
                        u_core.iq0_issue_data[0].bp_taken,
                        u_core.iq0_issue_data[0].bp_target,
                        u_core.bru_taken,
                        u_core.bru_target,
                        u_core.bru_result,
                        u_core.bru_mispredict);
                end
                if (u_core.bru1_issue &&
                    tb_coremark_ra_path_pc(u_core.iq0_issue_data[1].pc)) begin
                    $display("[RABRU1] cyc=%0d pc=%016h rob=%0d op=%0d rvc=%b rd_pdst=%0d rs1p=%0d rs1r=%b prf=%016h byp=%016h bhit=%b imm=%016h bp_tk=%b bp_tgt=%016h taken=%b tgt=%016h link=%016h mis=%b",
                        trace_cycle,
                        u_core.iq0_issue_data[1].pc,
                        u_core.iq0_issue_data[1].rob_idx,
                        u_core.iq0_issue_data[1].br_op,
                        u_core.iq0_issue_data[1].is_rvc,
                        u_core.iq0_issue_data[1].pdst,
                        u_core.iq0_issue_data[1].rs1_phys,
                        u_core.iq0_issue_data[1].rs1_ready,
                        u_core.prf_rdata[2],
                        u_core.bypassed_data[2],
                        u_core.bypass_hit[2],
                        u_core.iq0_issue_data[1].imm,
                        u_core.iq0_issue_data[1].bp_taken,
                        u_core.iq0_issue_data[1].bp_target,
                        u_core.bru1_taken,
                        u_core.bru1_target,
                        u_core.bru1_result,
                        u_core.bru1_mispredict);
                end

                trace_prev_rat_ra       <= rat_ra_phys;
                trace_prev_crat_ra      <= crat_ra_phys;
                trace_prev_rat_ra_data  <= rat_ra_data;
                trace_prev_crat_ra_data <= crat_ra_data;
                trace_prev_rat_s10       <= rat_s10_phys;
                trace_prev_crat_s10      <= crat_s10_phys;
                trace_prev_rat_s10_data  <= rat_s10_data;
                trace_prev_crat_s10_data <= crat_s10_data;
            end
            if (trace_listptr_en && (trace_cycle >= trace_listptr_start)) begin
                if (u_core.u_fetch_top.f2_work_valid_c &&
                    u_core.u_fetch_top.f2_data_valid &&
                    tb_coremark_list_ptr_pc(u_core.u_fetch_top.f2_work_pc_c)) begin
                    $display("[LPF2] cyc=%0d f2_pc=%016h ext=%0d final=%0d emit=%b data_v=%b rem=%b cons_rem=%b seq_v=%b seq_pc=%016h bp=%b bp_tk=%b bp_slot=%0d bp_tgt=%016h sg_v=%b sg_pc=%016h pkt_v=%b pkt_count=%0d out_count=%0d buf_v=%b flowthrough=%b uoc_active=%b rn_stall=%b fe_stall=%b flush=%b",
                        trace_cycle,
                        u_core.u_fetch_top.f2_work_pc_c,
                        u_core.u_fetch_top.extract_count,
                        u_core.u_fetch_top.final_count,
                        u_core.u_fetch_top.f2_will_emit_c,
                        u_core.u_fetch_top.f2_data_valid,
                        u_core.u_fetch_top.remainder_valid_r,
                        u_core.u_fetch_top.consume_remainder_c,
                        u_core.u_fetch_top.f2_seq_valid,
                        u_core.u_fetch_top.f2_seq_next_pc,
                        u_core.u_fetch_top.bp_branch_found,
                        u_core.u_fetch_top.bp_taken,
                        u_core.u_fetch_top.bp_branch_slot,
                        u_core.u_fetch_top.bp_target_addr,
                        u_core.u_fetch_top.subgroup_seed_valid_r,
                        u_core.u_fetch_top.subgroup_seed_pc_r,
                        u_core.u_fetch_top.packet_buf_in.valid,
                        u_core.u_fetch_top.packet_buf_in.fetch_count,
                        u_core.u_fetch_top.fetch_count,
                        u_core.u_fetch_top.packet_buf_valid,
                        u_core.u_fetch_top.packet_flowthrough_valid,
                        u_core.uoc_active,
                        u_core.rename_stall,
                        u_core.frontend_backend_stall,
                        u_core.flush_out.valid);
                    for (int i = 0; i < PIPE_WIDTH; i++) begin
                        if (u_core.u_fetch_top.slot_valid[i] &&
                            tb_coremark_list_ptr_pc(u_core.u_fetch_top.slot_pc[i])) begin
                            $display("[LPF2SLOT] cyc=%0d slot=%0d pc=%016h hw=%04h raw=%08h rvc=%b decomp=%08h final_in=%b",
                                trace_cycle,
                                i,
                                u_core.u_fetch_top.slot_pc[i],
                                u_core.u_fetch_top.raw_hw[i],
                                u_core.u_fetch_top.raw_insn[i],
                                u_core.u_fetch_top.slot_is_rvc[i],
                                u_core.u_fetch_top.decomp_out[i],
                                (i < int'(u_core.u_fetch_top.final_count)));
                        end
                    end
                end

                for (int i = 0; i < PIPE_WIDTH; i++) begin
                    if ((i < int'(u_core.u_fetch_top.fetch_count)) &&
                        tb_coremark_list_ptr_pc(u_core.u_fetch_top.fetch_pc[i])) begin
                        $display("[LPFETCH] cyc=%0d slot=%0d pc=%016h insn=%08h rvc=%b count=%0d pkt_count=%0d buf_v=%b flowthrough=%b uoc_active=%b rn_stall=%b fe_stall=%b flush=%b",
                            trace_cycle,
                            i,
                            u_core.u_fetch_top.fetch_pc[i],
                            u_core.u_fetch_top.fetch_insn[i],
                            u_core.u_fetch_top.fetch_is_rvc[i],
                            u_core.u_fetch_top.fetch_count,
                            u_core.u_fetch_top.fetch_packet_out.fetch_count,
                            u_core.u_fetch_top.packet_buf_valid,
                            u_core.u_fetch_top.packet_flowthrough_valid,
                            u_core.uoc_active,
                            u_core.rename_stall,
                            u_core.frontend_backend_stall,
                            u_core.flush_out.valid);
                    end
                    if ((i < int'(u_core.dec_count_out)) &&
                        u_core.dec_insn_out[i].valid &&
                        tb_coremark_list_ptr_pc(u_core.dec_insn_out[i].pc)) begin
                        $display("[LPDEC] cyc=%0d slot=%0d pc=%016h insn=%08h rvc=%b rdv=%b rd=%0d rs1v=%b rs1=%0d rs2v=%b rs2=%0d br=%b bp_tk=%b bp_tgt=%016h count=%0d rn_stall=%b flush=%b",
                            trace_cycle,
                            i,
                            u_core.dec_insn_out[i].pc,
                            u_core.dec_insn_out[i].insn,
                            u_core.dec_insn_out[i].is_rvc,
                            u_core.dec_insn_out[i].rd_valid,
                            u_core.dec_insn_out[i].rd_arch,
                            u_core.dec_insn_out[i].rs1_valid,
                            u_core.dec_insn_out[i].rs1_arch,
                            u_core.dec_insn_out[i].rs2_valid,
                            u_core.dec_insn_out[i].rs2_arch,
                            u_core.dec_insn_out[i].is_branch,
                            u_core.dec_insn_out[i].bp_taken,
                            u_core.dec_insn_out[i].bp_target,
                            u_core.dec_count_out,
                            u_core.rename_stall,
                            u_core.flush_out.valid);
                    end
                    if ((i < int'(u_core.fused_count)) &&
                        u_core.fused_insn[i].valid &&
                        tb_coremark_list_ptr_pc(u_core.fused_insn[i].pc)) begin
                        $display("[LPFUSED] cyc=%0d slot=%0d pc=%016h insn=%08h rvc=%b rdv=%b rd=%0d rs1v=%b rs1=%0d rs2v=%b rs2=%0d br=%b bp_tk=%b bp_tgt=%016h count=%0d uoc_active=%b flush=%b",
                            trace_cycle,
                            i,
                            u_core.fused_insn[i].pc,
                            u_core.fused_insn[i].insn,
                            u_core.fused_insn[i].is_rvc,
                            u_core.fused_insn[i].rd_valid,
                            u_core.fused_insn[i].rd_arch,
                            u_core.fused_insn[i].rs1_valid,
                            u_core.fused_insn[i].rs1_arch,
                            u_core.fused_insn[i].rs2_valid,
                            u_core.fused_insn[i].rs2_arch,
                            u_core.fused_insn[i].is_branch,
                            u_core.fused_insn[i].bp_taken,
                            u_core.fused_insn[i].bp_target,
                            u_core.fused_count,
                            u_core.uoc_active,
                            u_core.flush_out.valid);
                    end
                    if ((i < int'(u_core.rename_dec_count)) &&
                        u_core.rename_dec_in[i].valid &&
                        tb_coremark_list_ptr_pc(u_core.rename_dec_in[i].pc)) begin
                        $display("[LPRENIN] cyc=%0d slot=%0d pc=%016h insn=%08h rvc=%b rdv=%b rd=%0d rs1v=%b rs1=%0d rs2v=%b rs2=%0d br=%b bp_tk=%b bp_tgt=%016h count=%0d uoc_active=%b rn_stall=%b hold=%b work=%b adv=%b flush=%b",
                            trace_cycle,
                            i,
                            u_core.rename_dec_in[i].pc,
                            u_core.rename_dec_in[i].insn,
                            u_core.rename_dec_in[i].is_rvc,
                            u_core.rename_dec_in[i].rd_valid,
                            u_core.rename_dec_in[i].rd_arch,
                            u_core.rename_dec_in[i].rs1_valid,
                            u_core.rename_dec_in[i].rs1_arch,
                            u_core.rename_dec_in[i].rs2_valid,
                            u_core.rename_dec_in[i].rs2_arch,
                            u_core.rename_dec_in[i].is_branch,
                            u_core.rename_dec_in[i].bp_taken,
                            u_core.rename_dec_in[i].bp_target,
                            u_core.rename_dec_count,
                            u_core.uoc_active,
                            u_core.rename_stall,
                            u_core.u_rename.hold_valid,
                            u_core.u_rename.work_valid,
                            u_core.u_rename.slot_can_advance,
                            u_core.flush_out.valid);
                    end
                    if ((i < int'(u_core.ren_count_w)) &&
                        u_core.ren_insn[i].base.valid &&
                        tb_coremark_list_ptr_pc(u_core.ren_insn[i].base.pc)) begin
                        $display("[LPREN] cyc=%0d slot=%0d pc=%016h insn=%08h rob=%0d rdv=%b rd=%0d pdst=%0d old=%0d rs1v=%b rs1=%0d rs1p=%0d rs1r=%b rs2v=%b rs2=%0d rs2p=%0d rs2r=%b",
                            trace_cycle,
                            i,
                            u_core.ren_insn[i].base.pc,
                            u_core.ren_insn[i].base.insn,
                            u_core.ren_insn[i].rob_idx,
                            u_core.ren_insn[i].base.rd_valid,
                            u_core.ren_insn[i].base.rd_arch,
                            u_core.ren_insn[i].pdst,
                            u_core.ren_insn[i].old_pdst,
                            u_core.ren_insn[i].base.rs1_valid,
                            u_core.ren_insn[i].base.rs1_arch,
                            u_core.ren_insn[i].rs1_phys,
                            u_core.ren_insn[i].rs1_ready,
                            u_core.ren_insn[i].base.rs2_valid,
                            u_core.ren_insn[i].base.rs2_arch,
                            u_core.ren_insn[i].rs2_phys,
                            u_core.ren_insn[i].rs2_ready);
                    end
                    if ((i < int'(u_core.dq_deq_count)) &&
                        u_core.dq_deq_data[i].base.valid &&
                        tb_coremark_list_ptr_pc(u_core.dq_deq_data[i].base.pc)) begin
                        $display("[LPDQ] cyc=%0d slot=%0d pc=%016h rob=%0d iq=%0d rdv=%b rd=%0d pdst=%0d rs1p=%0d rs1r=%b rs2p=%0d rs2r=%b",
                            trace_cycle,
                            i,
                            u_core.dq_deq_data[i].base.pc,
                            u_core.dq_deq_data[i].rob_idx,
                            u_core.dq_deq_iq_target[i],
                            u_core.dq_deq_data[i].base.rd_valid,
                            u_core.dq_deq_data[i].base.rd_arch,
                            u_core.dq_deq_data[i].pdst,
                            u_core.dq_deq_data[i].rs1_phys,
                            u_core.dq_deq_data[i].rs1_ready,
                            u_core.dq_deq_data[i].rs2_phys,
                            u_core.dq_deq_data[i].rs2_ready);
                    end
                    if (u_core.commit_out[i].valid &&
                        tb_coremark_list_ptr_pc(u_core.rob_head_pc[i])) begin
                        $display("[LPCMT] cyc=%0d slot=%0d pc=%016h cc=%0d rdv=%b rd=%0d pdst=%0d data=%016h old=%0d br=%b tk=%b tgt=%016h mis=%b exc=%b code=%0d",
                            trace_cycle,
                            i,
                            u_core.rob_head_pc[i],
                            u_core.commit_count,
                            u_core.commit_out[i].rd_valid,
                            u_core.commit_out[i].rd_arch,
                            u_core.commit_out[i].pdst,
                            (u_core.commit_out[i].pdst == 8'd0) ? 64'd0 : u_core.u_int_prf.regfile_copy0[u_core.commit_out[i].pdst],
                            u_core.commit_out[i].old_pdst,
                            u_core.rob_head_is_branch[i],
                            u_core.rob_head_branch_taken[i],
                            u_core.rob_head_branch_target[i],
                            u_core.rob_head_branch_mispredict[i],
                            u_core.rob_head_has_exception[i],
                            u_core.rob_head_exc_code[i]);
                    end
                end

                for (int c = 0; c < CDB_WIDTH; c++) begin
                    if (u_core.cdb_valid[c]) begin
                        automatic logic [63:0] cdb_pc;
                        cdb_pc = u_core.u_rob.pc_packed[u_core.cdb_rob_idx[c]*64 +: 64];
                        if (tb_coremark_list_ptr_pc(cdb_pc) ||
                            (u_core.cdb_data[c][63:32] == 32'h8011_011b)) begin
                            $display("[LPCDB] cyc=%0d cdb=%0d pc=%016h rob=%0d tag=%0d data=%016h is_br=%b br_tgt=%016h mis=%b",
                                trace_cycle,
                                c,
                                cdb_pc,
                                u_core.cdb_rob_idx[c],
                                u_core.cdb_tag[c],
                                u_core.cdb_data[c],
                                u_core.cdb_is_branch[c],
                                u_core.cdb_branch_target[c],
                                u_core.cdb_branch_mispredict[c]);
                        end
                    end
                end

                if (u_core.u_lsu.load_issue_candidate_valid[0] &&
                    tb_coremark_list_ptr_pc(u_core.u_lsu.load_issue_data[0].pc)) begin
                    $display("[LPLD0] cyc=%0d pc=%016h rob=%0d pdst=%0d rs1p=%0d rs1=%016h imm=%016h eff=%016h size=%0d cand=%b issue=%b suppress=%b sq_hit=%b sq_wait=%b sq_part=%b same_hit=%b same_part=%b csb_hit=%b dcreq=%b",
                        trace_cycle,
                        u_core.u_lsu.load_issue_data[0].pc,
                        u_core.u_lsu.load_issue_data[0].rob_idx,
                        u_core.u_lsu.load_issue_data[0].pdst,
                        u_core.u_lsu.load_issue_data[0].rs1_phys,
                        u_core.u_lsu.load_rs1[0],
                        u_core.u_lsu.load_issue_data[0].imm,
                        u_core.u_lsu.load_eff_addr[0],
                        u_core.u_lsu.load_issue_data[0].mem_size,
                        u_core.u_lsu.load_issue_candidate_valid[0],
                        u_core.u_lsu.load_issue_valid[0],
                        u_core.lsu_load_issue_suppress[0],
                        u_core.u_lsu.sq_fwd_hit,
                        u_core.u_lsu.sq_fwd_wait,
                        u_core.u_lsu.sq_fwd_partial,
                        u_core.u_lsu.same_cycle_fwd_hit,
                        u_core.u_lsu.same_cycle_fwd_partial,
                        u_core.u_lsu.csb_fwd_hit,
                        u_core.u_lsu.dcache_load_req_valid[0]);
                end
                if (u_core.u_lsu.load_issue_candidate_valid[1] &&
                    tb_coremark_list_ptr_pc(u_core.u_lsu.load_issue_data[1].pc)) begin
                    $display("[LPLD1] cyc=%0d pc=%016h rob=%0d pdst=%0d rs1p=%0d rs1=%016h imm=%016h eff=%016h size=%0d cand=%b issue=%b suppress=%b sq_hit=%b sq_wait=%b sq_part=%b csb_hit=%b dcreq=%b retry=%b",
                        trace_cycle,
                        u_core.u_lsu.load_issue_data[1].pc,
                        u_core.u_lsu.load_issue_data[1].rob_idx,
                        u_core.u_lsu.load_issue_data[1].pdst,
                        u_core.u_lsu.load_issue_data[1].rs1_phys,
                        u_core.u_lsu.load_rs1[1],
                        u_core.u_lsu.load_issue_data[1].imm,
                        u_core.u_lsu.load_eff_addr[1],
                        u_core.u_lsu.load_issue_data[1].mem_size,
                        u_core.u_lsu.load_issue_candidate_valid[1],
                        u_core.u_lsu.load_issue_valid[1],
                        u_core.lsu_load_issue_suppress[1],
                        u_core.u_lsu.sq_fwd_hit_p1,
                        u_core.u_lsu.sq_wait_p1,
                        u_core.u_lsu.sq_fwd_partial_p1,
                        u_core.u_lsu.csb_fwd_hit_p1,
                        u_core.u_lsu.dcache_load_req_valid[1],
                        u_core.u_lsu.p1_retry_valid_r);
                end

                if (u_core.u_lsu.p0_dcache_hit_valid &&
                    tb_coremark_list_ptr_pc(u_core.u_lsu.load_issue_data_r[0].pc)) begin
                    $display("[LPDCHIT0] cyc=%0d pc=%016h rob=%0d pdst=%0d addr=%016h data=%016h",
                        trace_cycle,
                        u_core.u_lsu.load_issue_data_r[0].pc,
                        u_core.u_lsu.load_issue_data_r[0].rob_idx,
                        u_core.u_lsu.load_issue_data_r[0].pdst,
                        u_core.u_lsu.load_eff_addr_r[0],
                        u_core.u_lsu.load_extracted_dc[0]);
                end
                if (u_core.u_lsu.dcache_load_resp_valid[1] &&
                    u_core.u_lsu.load_issue_valid_r[1] &&
                    !u_core.u_lsu.load_nocache_r[1] &&
                    tb_coremark_list_ptr_pc(u_core.u_lsu.load_issue_data_r[1].pc)) begin
                    $display("[LPDCHIT1] cyc=%0d pc=%016h rob=%0d pdst=%0d addr=%016h data=%016h",
                        trace_cycle,
                        u_core.u_lsu.load_issue_data_r[1].pc,
                        u_core.u_lsu.load_issue_data_r[1].rob_idx,
                        u_core.u_lsu.load_issue_data_r[1].pdst,
                        u_core.u_lsu.load_eff_addr_r[1],
                        u_core.u_lsu.load_extracted_dc[1]);
                end
            end
            if (trace_coremark_progress_en && (u_core.commit_count > 3'd0)) begin
                for (int i = 0; i < PIPE_WIDTH; i++) begin
                    automatic int cm_idx;
                    cm_idx = tb_coremark_progress_index(u_core.rob_head_pc[i]);
                    if (u_core.commit_out[i].valid && (cm_idx >= 0)) begin
                        cm_progress_count[cm_idx] <= cm_progress_count[cm_idx] + 1;
                        $display("[CM_PROGRESS] cyc=%0d slot=%0d idx=%0d count=%0d pc=%016h",
                            trace_cycle,
                            i,
                            cm_idx,
                            cm_progress_count[cm_idx] + 1,
                            u_core.rob_head_pc[i]);
                    end
                end
            end
            if (trace_coremark_exit_en) begin
                automatic int lowpc_next_count;

                lowpc_next_count = trace_lowpc_count;
                if (u_core.u_fetch_top.f2_work_valid_c &&
                    u_core.u_fetch_top.f2_data_valid &&
                    tb_coremark_bad_fetch_pc(u_core.u_fetch_top.f2_work_pc_c)) begin
                    $display("[CM_FETCH_F2] cyc=%0d f2_pc=%016h ext=%0d final=%0d emit=%b data_v=%b rem=%b cons_rem=%b seq_v=%b seq_pc=%016h strad=%b pkt_v=%b pkt_count=%0d out_count=%0d buf_v=%b flowthrough=%b uoc_active=%b stall=%b flush=%b",
                        trace_cycle,
                        u_core.u_fetch_top.f2_work_pc_c,
                        u_core.u_fetch_top.extract_count,
                        u_core.u_fetch_top.final_count,
                        u_core.u_fetch_top.f2_will_emit_c,
                        u_core.u_fetch_top.f2_data_valid,
                        u_core.u_fetch_top.remainder_valid_r,
                        u_core.u_fetch_top.consume_remainder_c,
                        u_core.u_fetch_top.f2_seq_valid,
                        u_core.u_fetch_top.f2_seq_next_pc,
                        u_core.u_fetch_top.straddle_detected,
                        u_core.u_fetch_top.packet_buf_in.valid,
                        u_core.u_fetch_top.packet_buf_in.fetch_count,
                        u_core.u_fetch_top.fetch_count,
                        u_core.u_fetch_top.packet_buf_valid,
                        u_core.u_fetch_top.packet_flowthrough_valid,
                        u_core.uoc_active,
                        u_core.frontend_backend_stall,
                        u_core.flush_out.valid);
                    for (int i = 0; i < PIPE_WIDTH; i++) begin
                        if (u_core.u_fetch_top.slot_valid[i]) begin
                            $display("[CM_FETCH_SLOT] cyc=%0d slot=%0d pc=%016h hw=%04h raw=%08h rvc=%b decomp=%08h final_in=%b",
                                trace_cycle,
                                i,
                                u_core.u_fetch_top.slot_pc[i],
                                u_core.u_fetch_top.raw_hw[i],
                                u_core.u_fetch_top.raw_insn[i],
                                u_core.u_fetch_top.slot_is_rvc[i],
                                u_core.u_fetch_top.decomp_out[i],
                                (i < int'(u_core.u_fetch_top.final_count)));
                        end
                    end
                end
                for (int i = 0; i < PIPE_WIDTH; i++) begin
                    if ((i < int'(u_core.u_fetch_top.fetch_count)) &&
                        tb_coremark_bad_fetch_pc(u_core.u_fetch_top.fetch_pc[i])) begin
                        $display("[CM_FETCH_OUT] cyc=%0d slot=%0d pc=%016h insn=%08h rvc=%b count=%0d pkt_count=%0d buf_v=%b flowthrough=%b uoc_active=%b stall=%b flush=%b",
                            trace_cycle,
                            i,
                            u_core.u_fetch_top.fetch_pc[i],
                            u_core.u_fetch_top.fetch_insn[i],
                            u_core.u_fetch_top.fetch_is_rvc[i],
                            u_core.u_fetch_top.fetch_count,
                            u_core.u_fetch_top.fetch_packet_out.fetch_count,
                            u_core.u_fetch_top.packet_buf_valid,
                            u_core.u_fetch_top.packet_flowthrough_valid,
                            u_core.uoc_active,
                            u_core.frontend_backend_stall,
                            u_core.flush_out.valid);
                    end
                    if ((i < int'(u_core.dec_count_out)) &&
                        u_core.dec_insn_out[i].valid &&
                        tb_coremark_bad_fetch_pc(u_core.dec_insn_out[i].pc)) begin
                        $display("[CM_DECODE_OUT] cyc=%0d slot=%0d pc=%016h insn=%08h rvc=%b rd=%0d rdv=%b jal=%b jalr=%b br=%b load=%b store=%b count=%0d stall=%b flush=%b",
                            trace_cycle,
                            i,
                            u_core.dec_insn_out[i].pc,
                            u_core.dec_insn_out[i].insn,
                            u_core.dec_insn_out[i].is_rvc,
                            u_core.dec_insn_out[i].rd_arch,
                            u_core.dec_insn_out[i].rd_valid,
                            u_core.dec_insn_out[i].is_jal,
                            u_core.dec_insn_out[i].is_jalr,
                            u_core.dec_insn_out[i].is_branch,
                            u_core.dec_insn_out[i].is_load,
                            u_core.dec_insn_out[i].is_store,
                            u_core.dec_count_out,
                            u_core.frontend_backend_stall,
                            u_core.flush_out.valid);
                    end
                    if ((i < int'(u_core.fused_count)) &&
                        u_core.fused_insn[i].valid &&
                        tb_coremark_bad_fetch_pc(u_core.fused_insn[i].pc)) begin
                        $display("[CM_FUSED] cyc=%0d slot=%0d pc=%016h insn=%08h rvc=%b rd=%0d rdv=%b jal=%b jalr=%b br=%b load=%b store=%b count=%0d uoc_active=%b flush=%b",
                            trace_cycle,
                            i,
                            u_core.fused_insn[i].pc,
                            u_core.fused_insn[i].insn,
                            u_core.fused_insn[i].is_rvc,
                            u_core.fused_insn[i].rd_arch,
                            u_core.fused_insn[i].rd_valid,
                            u_core.fused_insn[i].is_jal,
                            u_core.fused_insn[i].is_jalr,
                            u_core.fused_insn[i].is_branch,
                            u_core.fused_insn[i].is_load,
                            u_core.fused_insn[i].is_store,
                            u_core.fused_count,
                            u_core.uoc_active,
                            u_core.flush_out.valid);
                    end
                    if ((i < int'(u_core.rename_dec_count)) &&
                        u_core.rename_dec_in[i].valid &&
                        tb_coremark_bad_fetch_pc(u_core.rename_dec_in[i].pc)) begin
                        $display("[CM_RENAME_IN] cyc=%0d slot=%0d pc=%016h insn=%08h rvc=%b rd=%0d rdv=%b jal=%b jalr=%b br=%b load=%b store=%b count=%0d uoc_active=%b flush=%b",
                            trace_cycle,
                            i,
                            u_core.rename_dec_in[i].pc,
                            u_core.rename_dec_in[i].insn,
                            u_core.rename_dec_in[i].is_rvc,
                            u_core.rename_dec_in[i].rd_arch,
                            u_core.rename_dec_in[i].rd_valid,
                            u_core.rename_dec_in[i].is_jal,
                            u_core.rename_dec_in[i].is_jalr,
                            u_core.rename_dec_in[i].is_branch,
                            u_core.rename_dec_in[i].is_load,
                            u_core.rename_dec_in[i].is_store,
                            u_core.rename_dec_count,
                            u_core.uoc_active,
                            u_core.flush_out.valid);
                    end
                    if ((i < int'(u_core.ren_count_w)) &&
                        u_core.ren_insn[i].base.valid &&
                        tb_coremark_bad_fetch_pc(u_core.ren_insn[i].base.pc)) begin
                        $display("[CM_RENAME_OUT] cyc=%0d slot=%0d pc=%016h insn=%08h rvc=%b rd=%0d pdst=%0d rob=%0d jal=%b jalr=%b br=%b load=%b store=%b count=%0d uoc_active=%b flush=%b",
                            trace_cycle,
                            i,
                            u_core.ren_insn[i].base.pc,
                            u_core.ren_insn[i].base.insn,
                            u_core.ren_insn[i].base.is_rvc,
                            u_core.ren_insn[i].base.rd_arch,
                            u_core.ren_insn[i].pdst,
                            u_core.ren_insn[i].rob_idx,
                            u_core.ren_insn[i].base.is_jal,
                            u_core.ren_insn[i].base.is_jalr,
                            u_core.ren_insn[i].base.is_branch,
                            u_core.ren_insn[i].base.is_load,
                            u_core.ren_insn[i].base.is_store,
                            u_core.ren_count_w,
                            u_core.uoc_active,
                            u_core.flush_out.valid);
                    end
                end
                if ((lowpc_next_count < 120) &&
                    u_core.bru_early_redirect &&
                    tb_low_text_pc(u_core.bru_early_target)) begin
                    $display("[LOWPC] cyc=%0d n=%0d stage=bru_redirect pc=%016h uoc_active=%b uoc_state=%0d flush=%b redir=%016h bru0=%b bru1=%b",
                        trace_cycle,
                        lowpc_next_count,
                        u_core.bru_early_target,
                        u_core.uoc_active,
                        u_core.u_uop_cache.state_r,
                        u_core.flush_out.valid,
                        u_core.flush_out.redirect_pc,
                        u_core.bru0_early_redirect,
                        u_core.bru1_early_redirect);
                    lowpc_next_count++;
                end
                if ((lowpc_next_count < 120) &&
                    u_core.flush_out.valid &&
                    tb_low_text_pc(u_core.flush_out.redirect_pc)) begin
                    $display("[LOWPC] cyc=%0d n=%0d stage=flush pc=%016h uoc_active=%b uoc_state=%0d full=%b bru_redir=%b bru_pc=%016h",
                        trace_cycle,
                        lowpc_next_count,
                        u_core.flush_out.redirect_pc,
                        u_core.uoc_active,
                        u_core.u_uop_cache.state_r,
                        u_core.flush_out.full_flush,
                        u_core.bru_early_redirect,
                        u_core.bru_early_target);
                    lowpc_next_count++;
                end
                for (int i = 0; i < PIPE_WIDTH; i++) begin
                    if ((lowpc_next_count < 120) &&
                        (i < int'(u_core.u_fetch_top.fetch_count)) &&
                        tb_low_text_pc(u_core.u_fetch_top.fetch_pc[i])) begin
                        $display("[LOWPC] cyc=%0d n=%0d stage=fetch slot=%0d pc=%016h uoc_active=%b uoc_state=%0d flush=%b redir=%016h bru_redir=%b bru_pc=%016h fetch_count=%0d",
                            trace_cycle,
                            lowpc_next_count,
                            i,
                            u_core.u_fetch_top.fetch_pc[i],
                            u_core.uoc_active,
                            u_core.u_uop_cache.state_r,
                            u_core.flush_out.valid,
                            u_core.flush_out.redirect_pc,
                            u_core.bru_early_redirect,
                            u_core.bru_early_target,
                            u_core.u_fetch_top.fetch_count);
                        lowpc_next_count++;
                    end
                    if ((lowpc_next_count < 120) &&
                        (i < int'(u_core.dec_count_out)) &&
                        u_core.dec_insn_out[i].valid &&
                        tb_low_text_pc(u_core.dec_insn_out[i].pc)) begin
                        $display("[LOWPC] cyc=%0d n=%0d stage=decode slot=%0d pc=%016h uoc_active=%b uoc_state=%0d flush=%b redir=%016h dec_count=%0d",
                            trace_cycle,
                            lowpc_next_count,
                            i,
                            u_core.dec_insn_out[i].pc,
                            u_core.uoc_active,
                            u_core.u_uop_cache.state_r,
                            u_core.flush_out.valid,
                            u_core.flush_out.redirect_pc,
                            u_core.dec_count_out);
                        lowpc_next_count++;
                    end
                    if ((lowpc_next_count < 120) &&
                        (i < int'(u_core.fused_count)) &&
                        u_core.fused_insn[i].valid &&
                        tb_low_text_pc(u_core.fused_insn[i].pc)) begin
                        $display("[LOWPC] cyc=%0d n=%0d stage=fused slot=%0d pc=%016h uoc_active=%b uoc_state=%0d flush=%b redir=%016h fused_count=%0d br=%b jal=%b jalr=%b bp_tk=%b bp_tgt=%016h",
                            trace_cycle,
                            lowpc_next_count,
                            i,
                            u_core.fused_insn[i].pc,
                            u_core.uoc_active,
                            u_core.u_uop_cache.state_r,
                            u_core.flush_out.valid,
                            u_core.flush_out.redirect_pc,
                            u_core.fused_count,
                            u_core.fused_insn[i].is_branch,
                            u_core.fused_insn[i].is_jal,
                            u_core.fused_insn[i].is_jalr,
                            u_core.fused_insn[i].bp_taken,
                            u_core.fused_insn[i].bp_target);
                        lowpc_next_count++;
                    end
                    if ((lowpc_next_count < 120) &&
                        u_core.uoc_active &&
                        (i < int'(u_core.uoc_count)) &&
                        u_core.uoc_insn[i].valid &&
                        tb_low_text_pc(u_core.uoc_insn[i].pc)) begin
                        $display("[LOWPC] cyc=%0d n=%0d stage=uoc slot=%0d pc=%016h uoc_state=%0d flush=%b redir=%016h uoc_count=%0d br=%b bp_tk=%b bp_tgt=%016h",
                            trace_cycle,
                            lowpc_next_count,
                            i,
                            u_core.uoc_insn[i].pc,
                            u_core.u_uop_cache.state_r,
                            u_core.flush_out.valid,
                            u_core.flush_out.redirect_pc,
                            u_core.uoc_count,
                            u_core.uoc_insn[i].is_branch,
                            u_core.uoc_insn[i].bp_taken,
                            u_core.uoc_insn[i].bp_target);
                        lowpc_next_count++;
                    end
                    if ((lowpc_next_count < 120) &&
                        (i < int'(u_core.rename_dec_count)) &&
                        u_core.rename_dec_in[i].valid &&
                        tb_low_text_pc(u_core.rename_dec_in[i].pc)) begin
                        $display("[LOWPC] cyc=%0d n=%0d stage=rename_in slot=%0d pc=%016h src_uoc=%b uoc_state=%0d flush=%b redir=%016h ren_dec_count=%0d br=%b bp_tk=%b bp_tgt=%016h",
                            trace_cycle,
                            lowpc_next_count,
                            i,
                            u_core.rename_dec_in[i].pc,
                            u_core.uoc_active,
                            u_core.u_uop_cache.state_r,
                            u_core.flush_out.valid,
                            u_core.flush_out.redirect_pc,
                            u_core.rename_dec_count,
                            u_core.rename_dec_in[i].is_branch,
                            u_core.rename_dec_in[i].bp_taken,
                            u_core.rename_dec_in[i].bp_target);
                        lowpc_next_count++;
                    end
                    if ((lowpc_next_count < 120) &&
                        (i < int'(u_core.ren_count_w)) &&
                        u_core.ren_insn[i].base.valid &&
                        tb_low_text_pc(u_core.ren_insn[i].base.pc)) begin
                        $display("[LOWPC] cyc=%0d n=%0d stage=rename_out slot=%0d pc=%016h rob=%0d uoc_active=%b uoc_state=%0d flush=%b redir=%016h ren_count=%0d br=%b bp_tk=%b bp_tgt=%016h",
                            trace_cycle,
                            lowpc_next_count,
                            i,
                            u_core.ren_insn[i].base.pc,
                            u_core.ren_insn[i].rob_idx,
                            u_core.uoc_active,
                            u_core.u_uop_cache.state_r,
                            u_core.flush_out.valid,
                            u_core.flush_out.redirect_pc,
                            u_core.ren_count_w,
                            u_core.ren_insn[i].base.is_branch,
                            u_core.ren_insn[i].base.bp_taken,
                            u_core.ren_insn[i].base.bp_target);
                        lowpc_next_count++;
                    end
                    if ((lowpc_next_count < 120) &&
                        (i < int'(u_core.dq_deq_count)) &&
                        u_core.dq_deq_data[i].base.valid &&
                        tb_low_text_pc(u_core.dq_deq_data[i].base.pc)) begin
                        $display("[LOWPC] cyc=%0d n=%0d stage=dq_deq slot=%0d pc=%016h rob=%0d iq=%0d uoc_active=%b uoc_state=%0d flush=%b redir=%016h deq_count=%0d br=%b bp_tk=%b bp_tgt=%016h",
                            trace_cycle,
                            lowpc_next_count,
                            i,
                            u_core.dq_deq_data[i].base.pc,
                            u_core.dq_deq_data[i].rob_idx,
                            u_core.dq_deq_iq_target[i],
                            u_core.uoc_active,
                            u_core.u_uop_cache.state_r,
                            u_core.flush_out.valid,
                            u_core.flush_out.redirect_pc,
                            u_core.dq_deq_count,
                            u_core.dq_deq_data[i].base.is_branch,
                            u_core.dq_deq_data[i].base.bp_taken,
                            u_core.dq_deq_data[i].base.bp_target);
                        lowpc_next_count++;
                    end
                    if ((lowpc_next_count < 120) &&
                        u_core.commit_out[i].valid &&
                        tb_low_text_pc(u_core.rob_head_pc[i])) begin
                        $display("[LOWPC] cyc=%0d n=%0d stage=commit slot=%0d pc=%016h cc=%0d uoc_active=%b uoc_state=%0d flush=%b redir=%016h br=%b tk=%b tgt=%016h mis=%b",
                            trace_cycle,
                            lowpc_next_count,
                            i,
                            u_core.rob_head_pc[i],
                            u_core.commit_count,
                            u_core.uoc_active,
                            u_core.u_uop_cache.state_r,
                            u_core.flush_out.valid,
                            u_core.flush_out.redirect_pc,
                            u_core.rob_head_is_branch[i],
                            u_core.rob_head_branch_taken[i],
                            u_core.rob_head_branch_target[i],
                            u_core.rob_head_branch_mispredict[i]);
                        lowpc_next_count++;
                    end
                end
                trace_lowpc_count <= lowpc_next_count;
            end
            if (trace_coremark_exit_en && (u_core.commit_count > 3'd0)) begin
                automatic logic [7:0]  crat_ra_phys;
                automatic logic [7:0]  crat_a0_phys;
                automatic logic [7:0]  crat_a1_phys;
                automatic logic [7:0]  crat_sp_phys;
                automatic logic [63:0] crat_ra_data;
                automatic logic [63:0] crat_a0_data;
                automatic logic [63:0] crat_a1_data;
                automatic logic [63:0] crat_sp_data;

                crat_ra_phys = u_core.u_rename.u_rat.committed_rat[1];
                crat_sp_phys = u_core.u_rename.u_rat.committed_rat[2];
                crat_a0_phys = u_core.u_rename.u_rat.committed_rat[10];
                crat_a1_phys = u_core.u_rename.u_rat.committed_rat[11];
                crat_ra_data = (crat_ra_phys == 8'd0) ? 64'd0 : u_core.u_int_prf.regfile_copy0[crat_ra_phys];
                crat_sp_data = (crat_sp_phys == 8'd0) ? 64'd0 : u_core.u_int_prf.regfile_copy0[crat_sp_phys];
                crat_a0_data = (crat_a0_phys == 8'd0) ? 64'd0 : u_core.u_int_prf.regfile_copy0[crat_a0_phys];
                crat_a1_data = (crat_a1_phys == 8'd0) ? 64'd0 : u_core.u_int_prf.regfile_copy0[crat_a1_phys];

                for (int i = 0; i < PIPE_WIDTH; i++) begin
                    if (u_core.commit_out[i].valid &&
                        tb_coremark_exit_pc(u_core.rob_head_pc[i])) begin
                        $display("[CM_EXIT] cyc=%0d slot=%0d pc=%016h cc=%0d flush=%b full=%b redir=%016h rdv=%b rd=%0d pdst=%0d pdst_data=%016h ra=%016h a0=%016h a1=%016h sp=%016h",
                            trace_cycle,
                            i,
                            u_core.rob_head_pc[i],
                            u_core.commit_count,
                            u_core.flush_out.valid,
                            u_core.flush_out.full_flush,
                            u_core.flush_out.redirect_pc,
                            u_core.commit_out[i].rd_valid,
                            u_core.commit_out[i].rd_arch,
                            u_core.commit_out[i].pdst,
                            (u_core.commit_out[i].pdst == 8'd0) ? 64'd0 : u_core.u_int_prf.regfile_copy0[u_core.commit_out[i].pdst],
                            crat_ra_data,
                            crat_a0_data,
                            crat_a1_data,
                            crat_sp_data);
                    end
                end
            end
            if (trace_coremark_exit_en) begin
                for (int i = 0; i < PIPE_WIDTH; i++) begin
                    if ((i < int'(u_core.ren_count_w)) &&
                        u_core.ren_insn[i].base.is_store) begin
                        trace_sq_alloc_pc[u_core.ren_insn[i].sq_idx] <=
                            u_core.ren_insn[i].base.pc;
                        trace_sq_alloc_rob[u_core.ren_insn[i].sq_idx] <=
                            u_core.ren_insn[i].rob_idx;
                        if (tb_coremark_exit_pc(u_core.ren_insn[i].base.pc)) begin
                            $display("[CM_SQ_ALLOC] cyc=%0d sq=%0d rob=%0d pc=%016h ren_slot=%0d tail=%0d count=%0d flush=%b",
                                trace_cycle,
                                u_core.ren_insn[i].sq_idx,
                                u_core.ren_insn[i].rob_idx,
                                u_core.ren_insn[i].base.pc,
                                i,
                                u_core.u_lsu.u_store_queue.tail_r,
                                u_core.u_lsu.u_store_queue.count_r,
                                u_core.flush_out.valid);
                        end
                    end
                end

                if (u_core.u_lsu.sta_issue_valid &&
                    (tb_coremark_exit_pc(u_core.u_lsu.sta_issue_data.pc) ||
                     tb_coremark_mmio_addr(u_core.u_lsu.sta_eff_addr))) begin
                    $display("[CM_SQ_STA] cyc=%0d sq=%0d rob=%0d pc=%016h alloc_pc=%016h addr=%016h size=%0d flush=%b head=%0d tail=%0d count=%0d",
                        trace_cycle,
                        u_core.u_lsu.sta_issue_data.sq_idx,
                        u_core.u_lsu.sta_issue_data.rob_idx,
                        u_core.u_lsu.sta_issue_data.pc,
                        trace_sq_alloc_pc[u_core.u_lsu.sta_issue_data.sq_idx],
                        u_core.u_lsu.sta_eff_addr,
                        u_core.u_lsu.sta_issue_data.mem_size,
                        u_core.flush_out.valid,
                        u_core.u_lsu.u_store_queue.head_r,
                        u_core.u_lsu.u_store_queue.tail_r,
                        u_core.u_lsu.u_store_queue.count_r);
                end

                if (u_core.u_lsu.std_issue_valid &&
                    (tb_coremark_exit_pc(u_core.u_lsu.std_issue_data.pc) ||
                     tb_coremark_mmio_addr(u_core.u_lsu.u_store_queue.queue[u_core.u_lsu.std_issue_data.sq_idx].addr))) begin
                    $display("[CM_SQ_STD] cyc=%0d sq=%0d rob=%0d pc=%016h alloc_pc=%016h data=%016h mask=%02h flush=%b entry_valid=%b entry_rob=%0d addr_valid=%b addr=%016h",
                        trace_cycle,
                        u_core.u_lsu.std_issue_data.sq_idx,
                        u_core.u_lsu.std_issue_data.rob_idx,
                        u_core.u_lsu.std_issue_data.pc,
                        trace_sq_alloc_pc[u_core.u_lsu.std_issue_data.sq_idx],
                        u_core.u_lsu.std_rs2,
                        u_core.u_lsu.std_byte_mask,
                        u_core.flush_out.valid,
                        u_core.u_lsu.u_store_queue.queue[u_core.u_lsu.std_issue_data.sq_idx].valid,
                        u_core.u_lsu.u_store_queue.queue[u_core.u_lsu.std_issue_data.sq_idx].rob_idx,
                        u_core.u_lsu.u_store_queue.queue[u_core.u_lsu.std_issue_data.sq_idx].addr_valid,
                        u_core.u_lsu.u_store_queue.queue[u_core.u_lsu.std_issue_data.sq_idx].addr);
                end

                if (u_core.u_lsu.sq_drain_valid && u_core.u_lsu.sq_drain_ready) begin
                    trace_csb_pc[u_core.u_lsu.u_csb.tail_r] <=
                        trace_sq_alloc_pc[u_core.u_lsu.u_store_queue.head_r];
                    trace_csb_rob[u_core.u_lsu.u_csb.tail_r] <=
                        u_core.u_lsu.sq_drain_entry.rob_idx;
                    if (tb_coremark_mmio_addr(u_core.u_lsu.sq_drain_entry.addr) ||
                        tb_coremark_exit_pc(trace_sq_alloc_pc[u_core.u_lsu.u_store_queue.head_r])) begin
                        $display("[CM_SQ_DRAIN] cyc=%0d sq=%0d rob=%0d alloc_rob=%0d alloc_pc=%016h addr=%016h data=%016h mask=%02h csb_tail=%0d flush=%b",
                            trace_cycle,
                            u_core.u_lsu.u_store_queue.head_r,
                            u_core.u_lsu.sq_drain_entry.rob_idx,
                            trace_sq_alloc_rob[u_core.u_lsu.u_store_queue.head_r],
                            trace_sq_alloc_pc[u_core.u_lsu.u_store_queue.head_r],
                            u_core.u_lsu.sq_drain_entry.addr,
                            u_core.u_lsu.sq_drain_entry.data,
                            u_core.u_lsu.sq_drain_entry.byte_mask,
                            u_core.u_lsu.u_csb.tail_r,
                            u_core.flush_out.valid);
                    end
                end

                if (u_core.dc_store_req_valid &&
                    tb_coremark_mmio_addr(u_core.dc_store_req_addr)) begin
                    $display("[CM_CSB_DEQ] cyc=%0d csb=%0d rob=%0d pc=%016h addr=%016h data=%016h ack=%b count=%0d tohost=%b",
                        trace_cycle,
                        u_core.u_lsu.u_csb.head_r,
                        trace_csb_rob[u_core.u_lsu.u_csb.head_r],
                        trace_csb_pc[u_core.u_lsu.u_csb.head_r],
                        u_core.dc_store_req_addr,
                        u_core.dc_store_req_data,
                        u_core.dc_store_ack,
                        u_core.u_lsu.u_csb.count_r,
                        tb_tohost_store_valid);
                end
            end
            if (trace_matrix_branch_en) begin
                if (u_core.bru_issue &&
                    ((u_core.iq0_issue_data[0].pc == 64'h0000_0000_8000_31c8) ||
                     (u_core.iq0_issue_data[0].pc == 64'h0000_0000_8000_31d4) ||
                     (u_core.iq0_issue_data[0].pc == 64'h0000_0000_8000_31e8)) &&
                    (((matrix_branch_trace_count < 160) ||
                      ((matrix_branch_trace_count % 512) == 0)) ||
                     (u_core.iq0_issue_data[0].pc != 64'h0000_0000_8000_31c8))) begin
                    matrix_branch_trace_count <= matrix_branch_trace_count + 1;
                    $display("[MATRIX_BR] cyc=%0d count=%0d port=0 pc=%016h rs1=%016h rs2=%016h bp_taken=%b taken=%b target=%016h misp=%b rob=%0d",
                        trace_cycle,
                        matrix_branch_trace_count + 1,
                        u_core.iq0_issue_data[0].pc,
                        u_core.bypassed_data[0],
                        u_core.bypassed_data[1],
                        u_core.iq0_issue_data[0].bp_taken,
                        u_core.bru_taken,
                        u_core.bru_target,
                        u_core.bru_mispredict,
                        u_core.iq0_issue_data[0].rob_idx);
                end else if (u_core.bru1_issue &&
                    ((u_core.iq0_issue_data[1].pc == 64'h0000_0000_8000_31c8) ||
                     (u_core.iq0_issue_data[1].pc == 64'h0000_0000_8000_31d4) ||
                     (u_core.iq0_issue_data[1].pc == 64'h0000_0000_8000_31e8)) &&
                    (((matrix_branch_trace_count < 160) ||
                      ((matrix_branch_trace_count % 512) == 0)) ||
                     (u_core.iq0_issue_data[1].pc != 64'h0000_0000_8000_31c8))) begin
                    matrix_branch_trace_count <= matrix_branch_trace_count + 1;
                    $display("[MATRIX_BR] cyc=%0d count=%0d port=1 pc=%016h rs1=%016h rs2=%016h bp_taken=%b taken=%b target=%016h misp=%b rob=%0d",
                        trace_cycle,
                        matrix_branch_trace_count + 1,
                        u_core.iq0_issue_data[1].pc,
                        u_core.bypassed_data[2],
                        u_core.bypassed_data[3],
                        u_core.iq0_issue_data[1].bp_taken,
                        u_core.bru1_taken,
                        u_core.bru1_target,
                        u_core.bru1_mispredict,
                        u_core.iq0_issue_data[1].rob_idx);
                end
            end
            if (trace_commit_hotspots_en && (u_core.commit_count > 3'd0)) begin
                for (int i = 0; i < PIPE_WIDTH; i++) begin
                    if (u_core.commit_out[i].valid &&
                        (u_core.rob_head_pc[i] >= COMMIT_HOTSPOT_BASE) &&
                        (((u_core.rob_head_pc[i] - COMMIT_HOTSPOT_BASE) >> 1) < COMMIT_HOTSPOT_BINS)) begin
                        commit_pc_hist[int'((u_core.rob_head_pc[i] - COMMIT_HOTSPOT_BASE) >> 1)] <=
                            commit_pc_hist[int'((u_core.rob_head_pc[i] - COMMIT_HOTSPOT_BASE) >> 1)] + 1;
                    end
                end
            end
            if ((trace_commit_en || trace_dep_en || trace_uoplife_en) && (u_core.commit_count > 3'd0)) begin
                automatic int dep_seq_off; // slot-local seq offset within this cycle
                automatic int uoplife_seq_off;
                dep_seq_off = 0;
                uoplife_seq_off = 0;
                for (int i = 0; i < PIPE_WIDTH; i++) begin
                    if (u_core.commit_out[i].valid) begin
                        // ty bitfield (hex):
                        //   bit0=is_branch, bit1=is_jal,    bit2=is_jalr,
                        //   bit3=is_load,   bit4=is_store,  bit5=is_csr,
                        //   bit6=is_fence|is_fence_i,       bit7=is_ecall|is_ebreak|is_mret|is_sret|is_sfence_vma|is_wfi
                        // (no is_jal/is_jalr/is_amo signal at rob head — JAL/JALR
                        // are encoded in is_branch + bpu_type so we read from the
                        // bpu_type field 1=JAL, 2=JALR, 3=COND-OR-BR-WITH-BPU)
                        automatic logic [7:0] ty;
                        // Resolved per-commit-slot helpers used by both
                        // [CPC] and [DEP].
                        automatic logic [ROB_IDX_BITS-1:0] dep_rob_idx;
                        automatic logic [63:0] dep_mem_addr;
                        automatic logic dep_mem_store_b;
                        automatic logic dep_replay_b;
                        automatic logic dep_flush_b;
                        ty = '0;
                        ty[0] = u_core.rob_head_is_branch[i];
                        ty[1] = (u_core.rob_head_bpu_type[i] == 3'd1); // JAL
                        ty[2] = (u_core.rob_head_bpu_type[i] == 3'd2); // JALR
                        ty[3] = u_core.rob_head_is_load[i];
                        ty[4] = u_core.rob_head_is_store[i];
                        ty[5] = u_core.rob_head_is_csr[i];
                        ty[6] = u_core.rob_head_is_fence[i] || u_core.rob_head_is_fence_i[i];
                        ty[7] = u_core.rob_head_is_ecall[i] || u_core.rob_head_is_mret[i] ||
                                u_core.rob_head_is_sret[i] || u_core.rob_head_is_sfence_vma[i] ||
                                u_core.rob_head_is_wfi[i];
                        // act_tgt = where we actually went (= taken_target if taken, else fall-through);
                        // tgt    = post-resolve target field as written by BRU (taken_target when taken,
                        //          fall-through when not — same field as before, kept for back-compat).
                        if (trace_commit_en) begin
                            $display("[CPC] cyc=%0d slot=%0d pc=%016h ty=%02h fused=%b br=%b tk=%b tgt=%016h act=%016h mis=%b",
                                trace_cycle, i,
                                u_core.rob_head_pc[i],
                                ty,
                                u_core.rob_head_is_fused[i],
                                u_core.rob_head_is_branch[i],
                                u_core.rob_head_branch_taken[i],
                                u_core.rob_head_branch_target[i],
                                u_core.rob_head_branch_taken_target[i],
                                u_core.rob_head_branch_mispredict[i]);
                        end
                        // ----------------------------------------------------
                        // dep.v1 emit (commit-aligned, one line per slot)
                        // ----------------------------------------------------
                        // Notes on field provenance and intentional defaults:
                        //   raw        = post-RVC-expansion 32-bit decoded.insn.
                        //                For RVC, this is the EXPANDED form
                        //                (the 16-bit pre-decompress value is
                        //                not retained at decode/rename).
                        //   epoch      = local commit-side full-flush counter
                        //                (no in-RTL epoch field, so this is a
                        //                tb-side approximation).
                        //   br_pred    = defaulted to br_tk; the BPU prediction
                        //                is not separately routed through
                        //                ROB to commit.
                        //   mem_addr   = looked up at commit time by scanning
                        //                LQ (loads) / SQ (stores) for the
                        //                committing rob_idx; 0 if no entry
                        //                (drained or non-mem op).
                        //   replay/flush = associated with this cycle; gated
                        //                on rob_idx match where possible.
                        if (trace_dep_en) begin
                            // Compute the wrapped ROB index for this commit slot.
                            if ((u_core.rob_head_idx + ROB_IDX_BITS'(i)) >= ROB_IDX_BITS'(ROB_DEPTH))
                                dep_rob_idx = u_core.rob_head_idx + ROB_IDX_BITS'(i) - ROB_IDX_BITS'(ROB_DEPTH);
                            else
                                dep_rob_idx = u_core.rob_head_idx + ROB_IDX_BITS'(i);
                            // Resolve mem_addr by scanning LQ/SQ for matching
                            // rob_idx.  This catches loads/stores still
                            // resident in the queue at commit time; any miss
                            // (entry already drained) reports 0.
                            dep_mem_addr    = 64'd0;
                            dep_mem_store_b = 1'b0;
                            if (u_core.rob_head_is_load[i]) begin
                                for (int q = 0; q < LQ_DEPTH; q++) begin
                                    if (u_core.u_lsu.u_load_queue.queue[q].valid &&
                                        (u_core.u_lsu.u_load_queue.queue[q].rob_idx == dep_rob_idx)) begin
                                        dep_mem_addr = u_core.u_lsu.u_load_queue.queue[q].addr;
                                    end
                                end
                            end else if (u_core.rob_head_is_store[i]) begin
                                dep_mem_store_b = 1'b1;
                                for (int q = 0; q < SQ_DEPTH; q++) begin
                                    if (u_core.u_lsu.u_store_queue.queue[q].valid &&
                                        (u_core.u_lsu.u_store_queue.queue[q].rob_idx == dep_rob_idx)) begin
                                        dep_mem_addr = u_core.u_lsu.u_store_queue.queue[q].addr;
                                    end
                                end
                            end
                            // replay = LSU ordering replay this cycle pointing
                            // at this rob_idx (or older).
                            dep_replay_b = u_core.replay_valid &&
                                           (u_core.replay_rob_idx_from == dep_rob_idx);
                            // flush = full commit-side flush this cycle whose
                            // recovery rob_idx matches this commit slot.
                            dep_flush_b  = u_core.flush_out.valid &&
                                           u_core.flush_out.full_flush &&
                                           (u_core.flush_out.rob_idx == dep_rob_idx);
                            $display("[DEP schema=dep.v1] cyc=%0d seq=%0d slot=%0d rob=%0d epoch=%0d pc=%016h raw=%08h ty=%02h rs1=%0d rs2=%0d rd=%0d ps1=%0d ps2=%0d pdst=%0d old=%0d fu=%0d br_tk=%b br_pred=%b br_tgt=%016h br_act=%016h br_mis=%b mem_addr=%016h mem_size=%0d mem_store=%b replay=%b flush=%b",
                                trace_cycle,
                                dep_seq_counter + dep_seq_off,
                                i,
                                dep_rob_idx,
                                dep_epoch_counter,
                                u_core.rob_head_pc[i],
                                dep_raw[dep_rob_idx],
                                ty,
                                dep_rs1_arch[dep_rob_idx],
                                dep_rs2_arch[dep_rob_idx],
                                u_core.rb_head_rd_arch[i],
                                dep_rs1_phys[dep_rob_idx],
                                dep_rs2_phys[dep_rob_idx],
                                u_core.rb_head_pdst[i],
                                u_core.rb_head_old_pdst[i],
                                dep_fu[dep_rob_idx],
                                u_core.rob_head_branch_taken[i],
                                u_core.rob_head_branch_taken[i], // br_pred placeholder
                                u_core.rob_head_branch_target[i],
                                u_core.rob_head_branch_taken_target[i],
                                u_core.rob_head_branch_mispredict[i],
                                dep_mem_addr,
                                dep_mem_size[dep_rob_idx],
                                dep_mem_store_b,
                                dep_replay_b,
                                dep_flush_b);
                            dep_seq_off = dep_seq_off + 1;
                        end
                        // ----------------------------------------------------
                        // UOPLIFE emit (commit-aligned, one line per slot)
                        // ----------------------------------------------------
                        // Emits a per-uop record with rename/dispatch/issue/wb
                        // timestamps and computed deltas. Stage cyc=0 means
                        // the stage was not observed (e.g., a side-effect-only
                        // uop that never wrote a CDB tag).  Deltas are
                        // computed only when both endpoints were observed; an
                        // unobserved start prints -1.
                        if (trace_uoplife_en) begin
                            automatic logic [ROB_IDX_BITS-1:0] u_rob_idx;
                            automatic int u_rn_cyc, u_dp_cyc, u_is_cyc, u_wb_cyc, u_cm_cyc;
                            automatic int d_rn_dp, d_dp_is, d_is_wb, d_wb_cm, d_total;
                            if ((u_core.rob_head_idx + ROB_IDX_BITS'(i)) >= ROB_IDX_BITS'(ROB_DEPTH))
                                u_rob_idx = u_core.rob_head_idx + ROB_IDX_BITS'(i) - ROB_IDX_BITS'(ROB_DEPTH);
                            else
                                u_rob_idx = u_core.rob_head_idx + ROB_IDX_BITS'(i);
                            u_rn_cyc = uoplife_rename_cyc[u_rob_idx];
                            u_dp_cyc = uoplife_dispatch_cyc[u_rob_idx];
                            u_is_cyc = uoplife_issue_cyc[u_rob_idx];
                            u_wb_cyc = uoplife_wb_cyc[u_rob_idx];
                            u_cm_cyc = trace_cycle;
                            d_rn_dp = (u_dp_cyc != 0 && u_rn_cyc != 0) ? (u_dp_cyc - u_rn_cyc) : -1;
                            d_dp_is = (u_is_cyc != 0 && u_dp_cyc != 0) ? (u_is_cyc - u_dp_cyc) : -1;
                            d_is_wb = (u_wb_cyc != 0 && u_is_cyc != 0) ? (u_wb_cyc - u_is_cyc) : -1;
                            d_wb_cm = (u_wb_cyc != 0) ? (u_cm_cyc - u_wb_cyc) : -1;
                            d_total = (u_rn_cyc != 0) ? (u_cm_cyc - u_rn_cyc) : -1;
                            $display("[UOPLIFE seq=%0d rob=%0d pc=%016h fu=%0d is_load=%0d is_store=%0d is_branch=%0d mis=%0d rename=%0d dispatch=%0d issue=%0d wb=%0d commit=%0d d_ren_to_disp=%0d d_disp_to_iss=%0d d_iss_to_wb=%0d d_wb_to_cmt=%0d d_total=%0d]",
                                uoplife_seq_counter + uoplife_seq_off,
                                u_rob_idx,
                                uoplife_pc[u_rob_idx],
                                uoplife_fu[u_rob_idx],
                                uoplife_is_load[u_rob_idx],
                                uoplife_is_store[u_rob_idx],
                                uoplife_is_branch[u_rob_idx],
                                u_core.rob_head_branch_mispredict[i],
                                u_rn_cyc,
                                u_dp_cyc,
                                u_is_cyc,
                                u_wb_cyc,
                                u_cm_cyc,
                                d_rn_dp,
                                d_dp_is,
                                d_is_wb,
                                d_wb_cm,
                                d_total);
                            uoplife_seq_off = uoplife_seq_off + 1;
                            // Clear the entry so a stale prev-life can't bleed
                            // into the next allocation at this rob_idx.
                            uoplife_valid[u_rob_idx]        <= 1'b0;
                            uoplife_rename_cyc[u_rob_idx]   <= 0;
                            uoplife_dispatch_cyc[u_rob_idx] <= 0;
                            uoplife_issue_cyc[u_rob_idx]    <= 0;
                            uoplife_wb_cyc[u_rob_idx]       <= 0;
                        end
                    end
                end
                // Advance the global dep.v1 sequence number by the number of
                // commits this cycle (only when the dep trace was emitted, so
                // the perf model sees a contiguous seq stream).
                if (trace_dep_en) begin
                    dep_seq_counter <= dep_seq_counter + 64'(dep_seq_off);
                end
                if (trace_uoplife_en) begin
                    uoplife_seq_counter <= uoplife_seq_counter + 64'(uoplife_seq_off);
                end
            end
            // -----------------------------------------------------------------
            // Golden PC scoreboard: commit-aligned check/emit.
            // -----------------------------------------------------------------
            // Independent of TRACE_* gates. Runs when +CHECK_GOLDEN_PCS or
            // +EMIT_COMMIT_PC_HEX is set. Uses u_core.rob_head_pc[i] which is
            // already exposed for commit-hotspot tracing.
            if ((golden_check_en || golden_emit_en) &&
                (u_core.commit_count > 3'd0) && !golden_tripped_r) begin
                automatic int golden_seq_off;
                golden_seq_off = 0;
                for (int i = 0; i < PIPE_WIDTH; i++) begin
                    if (u_core.commit_out[i].valid) begin
                        automatic logic [63:0] cmt_pc;
                        automatic longint      sidx;
                        cmt_pc = u_core.rob_head_pc[i];
                        if (golden_emit_en) begin
                            $fwrite(golden_emit_fd, "%016h\n", cmt_pc);
                        end
                        if (golden_check_en) begin
                            sidx = golden_seq_r + 64'(golden_seq_off);
                            if (sidx >= golden_size) begin
                                $display("[GOLDEN_PC TRIP] cycle=%0d seq=%0d reason=overflow size=%0d actual=%016h",
                                    trace_cycle, sidx, golden_size, cmt_pc);
                                golden_tripped_r <= 1'b1;
                                $finish(2);
                            end else if (golden_q[sidx] != cmt_pc) begin
                                $display("[GOLDEN_PC TRIP] cycle=%0d seq=%0d expected=%016h actual=%016h",
                                    trace_cycle, sidx, golden_q[sidx], cmt_pc);
                                golden_tripped_r <= 1'b1;
                                $finish(2);
                            end
                        end
                        golden_seq_off = golden_seq_off + 1;
                    end
                end
                golden_seq_r <= golden_seq_r + 64'(golden_seq_off);
            end
            if (trace_commit_en && u_core.flush_out.valid) begin
                $display("[FLUSH] cyc=%0d redirect_pc=%016h full=%b",
                    trace_cycle,
                    u_core.flush_out.redirect_pc,
                    u_core.flush_out.full_flush);
            end
            // -----------------------------------------------------------------
            // pipe.v1: per-cycle pipeline trace
            // -----------------------------------------------------------------
            // Emits one [PIPE schema=pipe.v1] line per cycle when
            // +TRACE_PIPELINE is set.  All counters are this-cycle values
            // (stage instruction counts are pre-register; queue occupancies
            // are post-register, captured the same way PERF_PROFILE does).
            //
            // reason codes:
            //   0 = no flush/replay this cycle
            //   1 = branch mispredict (flush_out.full_flush)
            //   2 = LSU ordering replay
            //   3 = ROB-head watchdog (full_flush without mispredict marker)
            //   4 = other flush (e.g., partial flush)
            // The dispatch count is dq_deq_count (the only point where 6
            // entries leave the dispatch queue toward the IQ array each
            // cycle).  cdb count is a popcount of cdb_valid_r.
            if (trace_pipeline_en) begin
                automatic int pipe_cdb_cnt;
                automatic int pipe_iss0_cnt;
                automatic int pipe_iss1_cnt;
                automatic int pipe_iss2_cnt;
                automatic int pipe_load_cnt;
                automatic int pipe_sta_cnt;
                automatic int pipe_std_cnt;
                automatic int pipe_issue_total;
                automatic int pipe_free_cnt;
                automatic int pipe_ckpt_cnt;
                automatic int pipe_reason;
                pipe_cdb_cnt  = $countones(u_core.cdb_valid_r);
                pipe_iss0_cnt = $countones(u_core.iq0_issue_valid);
                pipe_iss1_cnt = $countones(u_core.iq1_issue_valid);
                pipe_iss2_cnt = $countones(u_core.iq2_issue_valid);
                pipe_load_cnt = $countones(u_core.iq_load_issue_valid);
                pipe_sta_cnt  = u_core.routed_sta_valid ? 1 : 0;
                pipe_std_cnt  = u_core.routed_std_valid ? 1 : 0;
                pipe_issue_total = pipe_iss0_cnt + pipe_iss1_cnt +
                                   pipe_iss2_cnt + pipe_load_cnt +
                                   pipe_sta_cnt + pipe_std_cnt;
                pipe_free_cnt = $countones(u_core.u_rename.u_free_list.free_bitmap);
                pipe_ckpt_cnt = $countones(u_core.u_rename.u_checkpoint.occupied);
                pipe_reason   = 0;
                if (u_core.flush_out.valid && u_core.flush_out.full_flush) begin
                    // Heuristic: if any current commit-slot is marked as a
                    // mispredict, classify as branch mispredict.  Otherwise
                    // treat as watchdog/other.
                    pipe_reason = 3; // default to watchdog/other full flush
                    for (int i = 0; i < PIPE_WIDTH; i++) begin
                        if (u_core.commit_out[i].valid &&
                            u_core.rob_head_branch_mispredict[i]) begin
                            pipe_reason = 1;
                        end
                    end
                end else if (u_core.replay_valid) begin
                    pipe_reason = 2;
                end else if (u_core.flush_out.valid) begin
                    pipe_reason = 4;
                end
                $display("[PIPE schema=pipe.v1] cyc=%0d rst=%b fetch=%0d decode=%0d rename=%0d dispatch=%0d issue0=%0d issue1=%0d issue2=%0d cdb=%0d commit=%0d rob_head=%0d rob_tail=%0d rob_cnt=%0d iq0=%0d iq1=%0d iq2=%0d lq=%0d sq=%0d free=%0d ckpt=%0d flush=%b replay=%b reason=%0d",
                    trace_cycle,
                    !rst_n,
                    u_core.fetch_count,
                    u_core.dec_count_out,
                    u_core.ren_count_w,
                    u_core.dq_deq_count,
                    pipe_iss0_cnt,
                    pipe_iss1_cnt,
                    pipe_iss2_cnt,
                    pipe_cdb_cnt,
                    u_core.commit_count,
                    u_core.rob_head_idx,
                    u_core.rob_tail_idx,
                    u_core.u_rob.count_r,
                    u_core.u_iq0.count_r,
                    u_core.u_iq1.count_r,
                    u_core.u_iq2.count_r,
                    u_core.u_lsu.u_load_queue.count_r,
                    u_core.u_lsu.u_store_queue.count_r,
                    pipe_free_cnt,
                    pipe_ckpt_cnt,
                    u_core.flush_out.valid,
                    u_core.replay_valid,
                    pipe_reason);
                $display("[PIPE schema=pipe.v2] cyc=%0d rst=%b fetch=%0d decode=%0d rename=%0d dispatch=%0d issue0=%0d issue1=%0d issue2=%0d issue_load=%0d issue_sta=%0d issue_std=%0d issue_total=%0d cdb=%0d commit=%0d rob_head=%0d rob_tail=%0d rob_cnt=%0d iq0=%0d iq1=%0d iq2=%0d lq=%0d sq=%0d free=%0d ckpt=%0d flush=%b replay=%b reason=%0d",
                    trace_cycle,
                    !rst_n,
                    u_core.fetch_count,
                    u_core.dec_count_out,
                    u_core.ren_count_w,
                    u_core.dq_deq_count,
                    pipe_iss0_cnt,
                    pipe_iss1_cnt,
                    pipe_iss2_cnt,
                    pipe_load_cnt,
                    pipe_sta_cnt,
                    pipe_std_cnt,
                    pipe_issue_total,
                    pipe_cdb_cnt,
                    u_core.commit_count,
                    u_core.rob_head_idx,
                    u_core.rob_tail_idx,
                    u_core.u_rob.count_r,
                    u_core.u_iq0.count_r,
                    u_core.u_iq1.count_r,
                    u_core.u_iq2.count_r,
                    u_core.u_lsu.u_load_queue.count_r,
                    u_core.u_lsu.u_store_queue.count_r,
                    pipe_free_cnt,
                    pipe_ckpt_cnt,
                    u_core.flush_out.valid,
                    u_core.replay_valid,
                    pipe_reason);
            end
            if (trace_head_stall_en &&
                u_core.rob_head_valid[0] &&
                !u_core.rob_head_ready[0]) begin
                $display("[HEADSTALL] cyc=%0d head=%0d pc=%016h load=%b store=%b branch=%b bpu_type=%0d csr=%b fence=%b fencei=%b mret=%b sret=%b sfence=%b ecall=%b wfi=%b",
                    trace_cycle,
                    u_core.rob_head_idx,
                    u_core.rob_head_pc[0],
                    u_core.rob_head_is_load[0],
                    u_core.rob_head_is_store[0],
                    u_core.rob_head_is_branch[0],
                    u_core.rob_head_bpu_type[0],
                    u_core.rob_head_is_csr[0],
                    u_core.rob_head_is_fence[0],
                    u_core.rob_head_is_fence_i[0],
                    u_core.rob_head_is_mret[0],
                    u_core.rob_head_is_sret[0],
                    u_core.rob_head_is_sfence_vma[0],
                    u_core.rob_head_is_ecall[0],
                    u_core.rob_head_is_wfi[0]);
            end
            if (trace_commit_en && u_core.bru_issue &&
                (u_core.iq0_issue_data[0].pc >= 64'h0000000080002000) &&
                (u_core.iq0_issue_data[0].pc <  64'h0000000080002440)) begin
                $display("[BRUI0] cyc=%0d pc=%016h op=%0d fused=%b ftype=%0d bp_taken=%b bp_target=%016h taken=%b target=%016h mis=%b",
                    trace_cycle,
                    u_core.iq0_issue_data[0].pc,
                    u_core.iq0_issue_data[0].br_op,
                    u_core.iq0_issue_data[0].is_fused,
                    u_core.iq0_issue_data[0].fusion_type,
                    u_core.iq0_issue_data[0].bp_taken,
                    u_core.iq0_issue_data[0].bp_target,
                    u_core.bru_taken,
                    u_core.bru_target,
                    u_core.bru_mispredict);
            end
            if (trace_commit_en && u_core.bru1_issue &&
                (u_core.iq0_issue_data[1].pc >= 64'h0000000080002000) &&
                (u_core.iq0_issue_data[1].pc <  64'h0000000080002440)) begin
                $display("[BRUI1] cyc=%0d pc=%016h op=%0d fused=%b ftype=%0d bp_taken=%b bp_target=%016h taken=%b target=%016h mis=%b",
                    trace_cycle,
                    u_core.iq0_issue_data[1].pc,
                    u_core.iq0_issue_data[1].br_op,
                    u_core.iq0_issue_data[1].is_fused,
                    u_core.iq0_issue_data[1].fusion_type,
                    u_core.iq0_issue_data[1].bp_taken,
                    u_core.iq0_issue_data[1].bp_target,
                    u_core.bru1_taken,
                    u_core.bru1_target,
                    u_core.bru1_mispredict);
            end
            // STA issue trace: when an STA completes, log its rob_idx
            if (trace_commit_en && u_core.u_lsu.sta_wb_valid) begin
                $display("[STA_WB] cyc=%0d rob_idx=%0d pc=%016h",
                    trace_cycle,
                    u_core.u_lsu.sta_wb_rob_idx,
                    u_core.u_lsu.sta_issue_data.pc);
            end
            // Dump free_bitmap[0:31] at each cycle until first alloc bug to
            // see when/if pdst 0-31 bits flip
            if (trace_commit_en && trace_cycle < 20) begin
                $display("[FL] cyc=%0d free[31:0]=%08h cmt[31:0]=%08h",
                    trace_cycle,
                    u_core.u_rename.u_free_list.free_bitmap[31:0],
                    u_core.u_rename.u_free_list.committed_bitmap[31:0]);
            end
            // Alloc/release conflict detector: if rename allocates a pdst
            // that is currently in committed_rat for some arch, log it
            // as that's the bug signature.
            if (trace_commit_en) begin
                for (int s = 0; s < PIPE_WIDTH; s++) begin
                    if ((3'(s) < u_core.ren_count_w)
                        && u_core.ren_insn[s].base.rd_valid
                        && u_core.ren_insn[s].pdst != 8'd0) begin
                        automatic logic [7:0] pd = u_core.ren_insn[s].pdst;
                        for (int a = 1; a < 32; a++) begin
                            if (u_core.u_rename.u_rat.committed_rat[a] == pd
                                && a != u_core.ren_insn[s].base.rd_arch) begin
                                $display("[ALLOC_BUG] cyc=%0d slot=%0d rob=%0d writes pdst=%0d rd_arch=%0d but cra[%0d]=%0d",
                                    trace_cycle, s,
                                    u_core.ren_insn[s].rob_idx,
                                    pd,
                                    u_core.ren_insn[s].base.rd_arch,
                                    a, pd);
                    end
                end
            end
            if (trace_bru_en) begin
                if (u_core.bpu_update_valid) begin
                    $display("[BPUUPD] cyc=%0d pc=%016h type=%0d taken=%b mis=%b target=%016h",
                        trace_cycle,
                        u_core.bpu_update_pc,
                        u_core.bpu_update_type,
                        u_core.bpu_update_taken,
                        u_core.bpu_update_mispredict,
                        u_core.bpu_update_target);
                end
                if (u_core.u_fetch_top.f2_work_valid_c &&
                    u_core.u_fetch_top.ic_resp_valid &&
                    (u_core.u_fetch_top.f2_work_pc_c >= 64'h00000000800020d0) &&
                    (u_core.u_fetch_top.f2_work_pc_c < 64'h0000000080002440) &&
                    (u_core.u_fetch_top.f2_btb_hit_r ||
                     u_core.u_fetch_top.bp_branch_found ||
                     u_core.bpu_update_valid)) begin
                    $display("[BPF2] cyc=%0d f2_pc=%016h hit=%b btype=%0d boff=%0d btgt=%016h bp_found=%b bp_type=%0d bp_slot=%0d bp_tgt=%016h ras_tos=%0d push=%b pop=%b",
                        trace_cycle,
                        u_core.u_fetch_top.f2_work_pc_c,
                        u_core.u_fetch_top.f2_btb_hit_r,
                        u_core.u_fetch_top.f2_btb_type_r,
                        u_core.u_fetch_top.f2_btb_offset_r,
                        u_core.u_fetch_top.f2_btb_target_r,
                        u_core.u_fetch_top.bp_branch_found,
                        u_core.u_fetch_top.bp_type,
                        u_core.u_fetch_top.bp_branch_slot,
                        u_core.u_fetch_top.bp_target_addr,
                        u_core.u_fetch_top.ras_tos,
                        u_core.u_fetch_top.ras_push_valid,
                        u_core.u_fetch_top.ras_pop_valid);
                end
                if (u_core.u_fetch_top.ras_push_valid ||
                    u_core.u_fetch_top.ras_pop_valid ||
                    u_core.flush_out.valid) begin
                    $display("[RAS] cyc=%0d tos=%0d push=%b push_addr=%016h pop=%b pop_addr=%016h f2_pc=%016h bp_found=%b bp_type=%0d bp_tgt=%016h emit=%b dup=%b flush=%b fl_tos=%0d fl_pc=%016h",
                        trace_cycle,
                        u_core.u_fetch_top.ras_tos,
                        u_core.u_fetch_top.ras_push_valid,
                        u_core.u_fetch_top.ras_push_addr,
                        u_core.u_fetch_top.ras_pop_valid,
                        u_core.u_fetch_top.ras_pop_addr,
                        u_core.u_fetch_top.f2_work_pc_c,
                        u_core.u_fetch_top.bp_branch_found,
                        u_core.u_fetch_top.bp_type,
                        u_core.u_fetch_top.bp_target_addr,
                        u_core.u_fetch_top.f2_will_emit_c,
                        (u_core.u_fetch_top.f2_last_emit_valid_r &&
                         (u_core.u_fetch_top.f2_last_emit_pc_r ==
                          u_core.u_fetch_top.f2_work_pc_c)),
                        u_core.flush_out.valid,
                        u_core.flush_out.ras_tos,
                        u_core.flush_out.redirect_pc);
                end
                if (u_core.bru_issue && u_core.bru_mispredict) begin
                    $display("[BRU0] cyc=%0d pc=%016h op=%0d bp_taken=%b bp_target=%016h taken=%b target=%016h",
                        trace_cycle,
                        u_core.iq0_issue_data[0].pc,
                        u_core.iq0_issue_data[0].br_op,
                        u_core.iq0_issue_data[0].bp_taken,
                        u_core.iq0_issue_data[0].bp_target,
                        u_core.bru_taken,
                        u_core.bru_target);
                end
                if (u_core.bru1_issue && u_core.bru1_mispredict) begin
                    $display("[BRU1] cyc=%0d pc=%016h op=%0d bp_taken=%b bp_target=%016h taken=%b target=%016h",
                        trace_cycle,
                        u_core.iq0_issue_data[1].pc,
                        u_core.iq0_issue_data[1].br_op,
                        u_core.iq0_issue_data[1].bp_taken,
                        u_core.iq0_issue_data[1].bp_target,
                        u_core.bru1_taken,
                        u_core.bru1_target);
                end
            end
        end
    end
            // Store IQ enqueue trace: when a store enters IQ (BOTH ports)
            for (int p = 0; p < 2; p++) begin
                if (trace_commit_en && u_core.iq_store_enq_valid[p]) begin
                    $display("[SQ_ENQ] cyc=%0d port=%0d rob_idx=%0d pc=%016h s1_rdy=%b s2_rdy=%b",
                        trace_cycle, p,
                        u_core.iq_store_enq_data[p].rob_idx,
                        u_core.iq_store_enq_data[p].pc,
                        u_core.iq_store_enq_data[p].rs1_ready,
                        u_core.iq_store_enq_data[p].rs2_ready);
                end
            end
            // Also trace when a store is dispatched but NOT enqueued to store IQ
            // (indicates the "dropped" path we're hunting)
            for (int s = 0; s < PIPE_WIDTH; s++) begin
                if (trace_commit_en && (s < int'(u_core.dq_deq_count))
                    && u_core.dq_deq_data[s].base.valid
                    && u_core.dq_deq_data[s].base.is_store
                    && !u_core.dq_deq_data[s].base.is_load) begin
                    $display("[DQ_DEQ_ST] cyc=%0d slot=%0d rob_idx=%0d pc=%016h target=%0d",
                        trace_cycle, s,
                        u_core.dq_deq_data[s].rob_idx,
                        u_core.dq_deq_data[s].base.pc,
                        u_core.dq_deq_iq_target[s]);
                end
            end
            // Watchdog fire detection: log what ROB entry was stuck and type.
            // Earlier 12'd61 corresponds to watchdog value 1 cycle before it fires
            // (we sample before the final increment).
            if ((trace_commit_en || trace_wdog_en) &&
                (u_core.u_rob.rob_head_watchdog == 12'd61)) begin
                automatic int sta_match_found = 0;
                automatic int sta_match_idx = -1;
                automatic int sta_s1_rdy = 0;
                automatic int sta_s2_rdy = 0;
                $display("[WDOG] cyc=%0d head_idx=%0d pc=%016h is_store=%b",
                    trace_cycle,
                    u_core.u_rob.head_r,
                    u_core.rob_head_pc[0],
                    u_core.u_rob.is_store_r[u_core.u_rob.head_r]);
                // Scan store IQ for matching rob_idx
                for (int e = 0; e < 32; e++) begin
                    if (u_core.u_iq_store.entry_valid[e]
                        && (u_core.u_iq_store.rob_idx_r[e] == u_core.u_rob.head_r)) begin
                        sta_match_found = 1;
                        sta_match_idx = e;
                        sta_s1_rdy = u_core.u_iq_store.src1_ready[e];
                        sta_s2_rdy = u_core.u_iq_store.src2_ready[e];
                    end
                end
                $display("[WDOG-SQ] sta_match_found=%0d idx=%0d s1_rdy=%0d s2_rdy=%0d",
                    sta_match_found, sta_match_idx, sta_s1_rdy, sta_s2_rdy);
                // DUMP ALL valid store IQ entries — the stuck store's rob_idx
                // may not match the current head if the head watchdog is
                // firing on a different (non-store) entry, but the store
                // entry might still be stuck in IQ with its pdst
                $display("[WDOG-SQDUMP] cyc=%0d valid_bitmap=%08x", trace_cycle,
                    u_core.u_iq_store.entry_valid);
                for (int e = 0; e < 32; e++) begin
                    if (u_core.u_iq_store.entry_valid[e]) begin
                        $display("  [SQ[%0d]] rob=%0d rs1_phys=%0d rs2_phys=%0d s1_rdy=%b s2_rdy=%b s2_spec=%b",
                            e,
                            u_core.u_iq_store.rob_idx_r[e],
                            u_core.u_iq_store.rs1_phys_r[e],
                            u_core.u_iq_store.rs2_phys_r[e],
                            u_core.u_iq_store.src1_ready[e],
                            u_core.u_iq_store.src2_ready[e],
                            u_core.u_iq_store.src2_spec[e]);
                    end
                end
                // Also dump preg_ready_table for the pdsts we see
                for (int e = 0; e < 32; e++) begin
                    if (u_core.u_iq_store.entry_valid[e]
                        && !u_core.u_iq_store.src2_ready[e]) begin
                        $display("  [SQ[%0d]_WAIT] rs2_phys=%0d preg_ready=%b",
                            e, u_core.u_iq_store.rs2_phys_r[e],
                            u_core.preg_ready_table[u_core.u_iq_store.rs2_phys_r[e]]);
                    end
                end
                // RAT dump: ALL arch regs (full RAT state)
                $display("[WDOG-RAT] full RAT dump:");
                for (int a = 0; a < 32; a++) begin
                    $display("  RAT[%0d] = pdst=%0d cra=%0d",
                        a, u_core.u_rename.u_rat.rat_table[a],
                        u_core.u_rename.u_rat.committed_rat[a]);
                end
                // Free list bitmaps for low pdsts
                $display("[WDOG-FL] free/committed bitmaps for low pdsts:");
                for (int p = 0; p < 32; p++) begin
                    $display("  pdst=%0d free=%b cmt=%b preg_rdy=%b",
                        p,
                        u_core.u_rename.u_free_list.free_bitmap[p],
                        u_core.u_rename.u_free_list.committed_bitmap[p],
                        u_core.preg_ready_table[p]);
                end
                // Dump ALL stuck (not ready to issue) entries across all int
                // IQs and load IQ — captures the full dependency chain.
                $display("[WDOG-ALLIQ] all non-ready valid IQ entries:");
                for (int e = 0; e < 32; e++) begin
                    automatic iq_entry_t iq0_ent, iq1_ent, iq2_ent, iqld_ent;
                    iq0_ent  = iq_entry_t'(u_core.u_iq0.payload_r[e]);
                    iq1_ent  = iq_entry_t'(u_core.u_iq1.payload_r[e]);
                    iq2_ent  = iq_entry_t'(u_core.u_iq2.payload_r[e]);
                    iqld_ent = iq_entry_t'(u_core.u_iq_load.payload_r[e]);
                    if (u_core.u_iq0.entry_valid[e]
                        && (!u_core.u_iq0.src1_ready[e] || !u_core.u_iq0.src2_ready[e]))
                        $display("  IQ0[%0d] pdst=%0d rob=%0d fu=%0d s1=%b s2=%b rs1_p=%0d rs2_p=%0d",
                            e, iq0_ent.pdst, u_core.u_iq0.rob_idx_r[e], iq0_ent.fu_type,
                            u_core.u_iq0.src1_ready[e], u_core.u_iq0.src2_ready[e],
                            u_core.u_iq0.rs1_phys_r[e], u_core.u_iq0.rs2_phys_r[e]);
                    if (u_core.u_iq1.entry_valid[e]
                        && (!u_core.u_iq1.src1_ready[e] || !u_core.u_iq1.src2_ready[e]))
                        $display("  IQ1[%0d] pdst=%0d rob=%0d fu=%0d s1=%b s2=%b rs1_p=%0d rs2_p=%0d",
                            e, iq1_ent.pdst, u_core.u_iq1.rob_idx_r[e], iq1_ent.fu_type,
                            u_core.u_iq1.src1_ready[e], u_core.u_iq1.src2_ready[e],
                            u_core.u_iq1.rs1_phys_r[e], u_core.u_iq1.rs2_phys_r[e]);
                    if (u_core.u_iq2.entry_valid[e]
                        && (!u_core.u_iq2.src1_ready[e] || !u_core.u_iq2.src2_ready[e]))
                        $display("  IQ2[%0d] pdst=%0d rob=%0d fu=%0d s1=%b s2=%b rs1_p=%0d rs2_p=%0d",
                            e, iq2_ent.pdst, u_core.u_iq2.rob_idx_r[e], iq2_ent.fu_type,
                            u_core.u_iq2.src1_ready[e], u_core.u_iq2.src2_ready[e],
                            u_core.u_iq2.rs1_phys_r[e], u_core.u_iq2.rs2_phys_r[e]);
                    if (u_core.u_iq_load.entry_valid[e]
                        && (!u_core.u_iq_load.src1_ready[e] || !u_core.u_iq_load.src2_ready[e]))
                        $display("  IQLD[%0d] pdst=%0d rob=%0d s1=%b s2=%b rs1_p=%0d",
                            e, iqld_ent.pdst, u_core.u_iq_load.rob_idx_r[e],
                            u_core.u_iq_load.src1_ready[e], u_core.u_iq_load.src2_ready[e],
                            u_core.u_iq_load.rs1_phys_r[e]);
                end
            end
            // Persistent CDB broadcast log for pdsts matching any store IQ
            // entry that's waiting on rs2 — captures the moment wakeup should
            // have happened (if it happens at all)
            if (trace_commit_en) begin
                for (int c = 0; c < CDB_WIDTH; c++) begin
                    if (u_core.cdb_valid[c]) begin
                        for (int e = 0; e < 32; e++) begin
                            if (u_core.u_iq_store.entry_valid[e]
                                && !u_core.u_iq_store.src2_ready[e]
                                && (u_core.cdb_tag[c] == u_core.u_iq_store.rs2_phys_r[e])) begin
                                $display("[SQ_WAKE] cyc=%0d cdb[%0d] tag=%0d hits sq[%0d] rob=%0d",
                                    trace_cycle, c, u_core.cdb_tag[c], e,
                                    u_core.u_iq_store.rob_idx_r[e]);
                            end
                        end
                    end
                end
            end
            // ROB head snapshot when pipeline appears stalled
            // (fires every 1000 cycles so we can see progress vs stuck)
            if (trace_commit_en && (trace_cycle % 1000 == 0)) begin
                $display("[ROB] cyc=%0d head_idx=%0d head_pc=%016h head_ready=%b",
                    trace_cycle, u_core.rob_head_idx,
                    u_core.rob_head_pc[0], u_core.rob_head_ready[0]);
            end
            // Store drain to D-cache tracing (tohost detection path)
            if (trace_commit_en && u_core.dc_store_req_valid) begin
                $display("[STORE] cyc=%0d addr=%016h data=%016h ack=%b tohost=%b",
                    trace_cycle,
                    u_core.dc_store_req_addr,
                    u_core.dc_store_req_data,
                    u_core.dc_store_ack,
                    tb_tohost_store_valid);
            end
            if (trace_coremark_exit_en && u_core.dc_store_req_valid &&
                (((u_core.dc_store_req_addr >= BENCH_RESULT_BASE) &&
                  (u_core.dc_store_req_addr < BENCH_RESULT_END)) ||
                 (u_core.dc_store_req_addr[31:3] == sim_tohost_addr[31:3]))) begin
                $display("[CM_STORE] cyc=%0d addr=%016h data=%016h ack=%b tohost=%b",
                    trace_cycle,
                    u_core.dc_store_req_addr,
                    u_core.dc_store_req_data,
                    u_core.dc_store_ack,
                    tb_tohost_store_valid);
            end
            // DC L2 traffic trace (to diagnose MSHR/fill stalls)
            if (trace_commit_en && u_core.u_dcache.l2_req_valid) begin
                $display("[DC_L2REQ] cyc=%0d addr=%016h we=%b l2_ready=%b state=%0d",
                    trace_cycle,
                    u_core.u_dcache.l2_req_addr,
                    u_core.u_dcache.l2_req_we,
                    u_core.u_dcache.l2_req_ready,
                    u_core.u_dcache.l2_state_q);
            end
            if (trace_commit_en && u_core.u_dcache.l2_resp_valid) begin
                $display("[DC_L2RESP] cyc=%0d addr=%016h",
                    trace_cycle, u_core.u_dcache.l2_resp_addr);
            end
            // Dump MSHR + waiting_for_fill state when store is stuck
            if (trace_commit_en && u_core.dc_store_req_valid && !u_core.dc_store_ack) begin
                $display("[DC_STATE] cyc=%0d s1_st_v=%b wait_fill=%b fill_done=%b hit=%b allo_mshr=%b mshr_mat=%b l2_state=%0d mshr0_v=%b mshr0_fp=%b mshr0_wp=%b mshr0_fd=%b fill_avail=%b wb_avail=%b",
                    trace_cycle,
                    u_core.u_dcache.s1_st_valid,
                    u_core.u_dcache.s1_st_waiting_for_fill,
                    u_core.u_dcache.fill_done_avail,
                    u_core.u_dcache.st_cache_hit,
                    u_core.u_dcache.s1_st_can_allocate_mshr,
                    u_core.u_dcache.mshr_st_match_hit,
                    u_core.u_dcache.l2_state_q,
                    u_core.u_dcache.mshr[0].valid,
                    u_core.u_dcache.mshr[0].fill_pend,
                    u_core.u_dcache.mshr[0].writeback_pend,
                    u_core.u_dcache.mshr[0].fill_done,
                    u_core.u_dcache.fill_mshr_avail,
                    u_core.u_dcache.wb_mshr_avail);
            end
            // BRU JALR trace: print operands and target every cycle BRU executes a JALR
            if (trace_commit_en) begin
                if ((u_core.iq0_issue_valid[0]) &&
                    (u_core.iq0_issue_data[0].fu_type == FU_BRU) &&
                    (u_core.iq0_issue_data[0].br_op == BR_JALR)) begin
                    $display("[BRU_JALR] cyc=%0d pc=%016h opa=%016h opb=%016h imm=%016h is_fused=%b",
                        trace_cycle,
                        u_core.iq0_issue_data[0].pc,
                        u_core.bypassed_data[0],
                        u_core.bypassed_data[1],
                        u_core.iq0_issue_data[0].imm,
                        u_core.iq0_issue_data[0].is_fused);
                end
                // ALU issue tracing: print PC, opa, opb, alu_op for all ALU issues
                if (u_core.iq0_issue_valid[0] && u_core.iq0_issue_data[0].fu_type == FU_ALU) begin
                    $display("[ALU0] cyc=%0d pc=%016h opa=%016h opb=%016h op=%0d is_w=%b use_imm=%b imm=%016h",
                        trace_cycle,
                        u_core.iq0_issue_data[0].pc,
                        u_core.alu0_op_a,
                        u_core.alu0_op_b,
                        u_core.iq0_issue_data[0].alu_op,
                        u_core.iq0_issue_data[0].is_w_op,
                        u_core.iq0_issue_data[0].use_imm,
                        u_core.iq0_issue_data[0].imm);
                end
                if (u_core.iq0_issue_valid[1] && u_core.iq0_issue_data[1].fu_type == FU_ALU) begin
                    $display("[ALU1] cyc=%0d pc=%016h opa=%016h opb=%016h op=%0d is_w=%b use_imm=%b imm=%016h",
                        trace_cycle,
                        u_core.iq0_issue_data[1].pc,
                        u_core.alu1_op_a,
                        u_core.alu1_op_b,
                        u_core.iq0_issue_data[1].alu_op,
                        u_core.iq0_issue_data[1].is_w_op,
                        u_core.iq0_issue_data[1].use_imm,
                        u_core.iq0_issue_data[1].imm);
                end
                if (u_core.iq1_issue_valid[0] && u_core.iq1_issue_data[0].fu_type == FU_ALU) begin
                    $display("[ALU2] cyc=%0d pc=%016h opa=%016h opb=%016h op=%0d is_w=%b use_imm=%b imm=%016h",
                        trace_cycle,
                        u_core.iq1_issue_data[0].pc,
                        u_core.alu2_op_a,
                        u_core.alu2_op_b,
                        u_core.iq1_issue_data[0].alu_op,
                        u_core.iq1_issue_data[0].is_w_op,
                        u_core.iq1_issue_data[0].use_imm,
                        u_core.iq1_issue_data[0].imm);
                end
                if (u_core.iq1_issue_valid[0] && u_core.iq1_issue_data[0].fu_type == FU_MUL) begin
                    $display("[MULISS] cyc=%0d pc=%016h opa=%016h opb=%016h op=%0d is_w=%b pdst=%0d rob=%0d rs1_p=%0d rs2_p=%0d",
                        trace_cycle,
                        u_core.iq1_issue_data[0].pc,
                        u_core.bypassed_data[4],
                        u_core.bypassed_data[5],
                        u_core.iq1_issue_data[0].mul_op,
                        u_core.iq1_issue_data[0].is_w_op,
                        u_core.iq1_issue_data[0].pdst,
                        u_core.iq1_issue_data[0].rob_idx,
                        u_core.iq1_issue_data[0].rs1_phys,
                        u_core.iq1_issue_data[0].rs2_phys);
                end
                if (u_core.u_multiplier.s1_valid || u_core.u_multiplier.s2_valid ||
                    u_core.mul_hold_valid_r ||
                    u_core.cdb_valid[2]) begin
                    $display("[MULWB] cyc=%0d s1v=%b s1_rob=%0d s1_pdst=%0d s2v=%b s2_rob=%0d s2_pdst=%0d vout=%b hold=%b cdb2=%b cdb2_rob=%0d cdb2_pdst=%0d cdb2_data=%016h",
                        trace_cycle,
                        u_core.u_multiplier.s1_valid,
                        u_core.mul_rob_idx_s1,
                        u_core.mul_pdst_s1,
                        u_core.u_multiplier.s2_valid,
                        u_core.mul_rob_idx_s2,
                        u_core.mul_pdst_s2,
                        u_core.mul_valid_out,
                        u_core.mul_hold_valid_r,
                        u_core.cdb_valid[2],
                        u_core.cdb_rob_idx[2],
                        u_core.cdb_tag[2],
                        u_core.cdb_data[2]);
                end
                if (u_core.iq2_issue_valid[0] && u_core.iq2_issue_data[0].fu_type == FU_ALU) begin
                    $display("[ALU3] cyc=%0d pc=%016h opa=%016h opb=%016h op=%0d is_w=%b use_imm=%b imm=%016h",
                        trace_cycle,
                        u_core.iq2_issue_data[0].pc,
                        u_core.alu3_op_a,
                        u_core.alu3_op_b,
                        u_core.iq2_issue_data[0].alu_op,
                        u_core.iq2_issue_data[0].is_w_op,
                        u_core.iq2_issue_data[0].use_imm,
                        u_core.iq2_issue_data[0].imm);
                end
                // Load issue trace (effective addr is rs1 + imm)
                if (u_core.iq_load_issue_valid[0]) begin
                    $display("[LDISS0] cyc=%0d pc=%016h fu=%0d rs1=%016h imm=%016h size=%0d is_unsigned=%b pdst=%0d rob=%0d is_fused=%b rs1_phys=%0d",
                        trace_cycle,
                        u_core.iq_load_issue_data[0].pc,
                        u_core.iq_load_issue_data[0].fu_type,
                        u_core.bypassed_data[8],
                        u_core.iq_load_issue_data[0].imm,
                        u_core.iq_load_issue_data[0].mem_size,
                        u_core.iq_load_issue_data[0].is_unsigned,
                        u_core.iq_load_issue_data[0].pdst,
                        u_core.iq_load_issue_data[0].rob_idx,
                        u_core.iq_load_issue_data[0].is_fused,
                        u_core.iq_load_issue_data[0].rs1_phys);
                end
                if (u_core.iq_load_issue_valid[1]) begin
                    $display("[LDISS1] cyc=%0d pc=%016h rs1=%016h imm=%016h size=%0d is_unsigned=%b pdst=%0d rob=%0d is_fused=%b rs1_phys=%0d",
                        trace_cycle,
                        u_core.iq_load_issue_data[1].pc,
                        u_core.bypassed_data[9],
                        u_core.iq_load_issue_data[1].imm,
                        u_core.iq_load_issue_data[1].mem_size,
                        u_core.iq_load_issue_data[1].is_unsigned,
                        u_core.iq_load_issue_data[1].pdst,
                        u_core.iq_load_issue_data[1].rob_idx,
                        u_core.iq_load_issue_data[1].is_fused,
                        u_core.iq_load_issue_data[1].rs1_phys);
                end
                // Load writeback (CDB broadcast)
                if (u_core.lsu_load_wb_valid[0]) begin
                    $display("[LDWB0] cyc=%0d rob=%0d pdst=%0d data=%016h",
                        trace_cycle,
                        u_core.lsu_load_wb_rob_idx[0],
                        u_core.lsu_load_wb_pdst[0],
                        u_core.lsu_load_wb_data[0]);
                end
                if (u_core.lsu_load_wb_valid[1]) begin
                    $display("[LDWB1] cyc=%0d rob=%0d pdst=%0d data=%016h",
                        trace_cycle,
                        u_core.lsu_load_wb_rob_idx[1],
                        u_core.lsu_load_wb_pdst[1],
                        u_core.lsu_load_wb_data[1]);
                end
                // Store issue trace
                if (u_core.iq_store_issue_valid[0]) begin
                    $display("[STISS] cyc=%0d pc=%016h rs1=%016h rs2=%016h imm=%016h size=%0d",
                        trace_cycle,
                        u_core.iq_store_issue_data[0].pc,
                        u_core.bypassed_data[10],
                        u_core.bypassed_data[11],
                        u_core.iq_store_issue_data[0].imm,
                        u_core.iq_store_issue_data[0].mem_size);
                end
                // L1D fill trace (snoop)
                if (u_core.dc_fill_snoop_valid) begin
                    $display("[DCFILL] cyc=%0d addr=%016h data[0..63]=%016h data[192..255]=%016h",
                        trace_cycle,
                        u_core.dc_fill_snoop_addr,
                        u_core.dc_fill_snoop_data[63:0],
                        u_core.dc_fill_snoop_data[255:192]);
                end
                // dcache_load_req_addr trace
                if (u_core.u_dcache.load_req_valid[0]) begin
                    $display("[DCLDREQ0] cyc=%0d addr=%016h size=%0d",
                        trace_cycle,
                        u_core.u_dcache.load_req_addr[0],
                        u_core.u_dcache.load_req_size[0]);
                end
                // LSU eff addr inside trace
                if (u_core.u_lsu.load_issue_valid[0]) begin
                    $display("[LSUEFF0] cyc=%0d eff=%016h rs1=%016h imm=%016h pc=%016h is_fused=%b",
                        trace_cycle,
                        u_core.u_lsu.load_eff_addr[0],
                        u_core.u_lsu.load_rs1[0],
                        u_core.u_lsu.load_issue_data[0].imm,
                        u_core.u_lsu.load_issue_data[0].pc,
                        u_core.u_lsu.load_issue_data[0].is_fused);
                end
                if (u_core.u_lsu.load_issue_valid[1]) begin
                    $display("[LSUEFF1] cyc=%0d eff=%016h rs1=%016h imm=%016h pc=%016h is_fused=%b",
                        trace_cycle,
                        u_core.u_lsu.load_eff_addr[1],
                        u_core.u_lsu.load_rs1[1],
                        u_core.u_lsu.load_issue_data[1].imm,
                        u_core.u_lsu.load_issue_data[1].pc,
                        u_core.u_lsu.load_issue_data[1].is_fused);
                end
                if (u_core.u_dcache.load_req_valid[1]) begin
                    $display("[DCLDREQ1] cyc=%0d addr=%016h size=%0d",
                        trace_cycle,
                        u_core.u_dcache.load_req_addr[1],
                        u_core.u_dcache.load_req_size[1]);
                end
                if (trace_lsu_fwd_en &&
                    u_core.u_lsu.load_issue_candidate_valid[0] &&
                    (u_core.u_lsu.load_issue_data[0].pc == 64'h0000_0000_8000_2382)) begin
                    $display("[LSUFWD0] cyc=%0d pc=%016h rob=%0d eff=%016h sq_hit=%b sq_wait=%b sq_partial=%b same_hit=%b same_partial=%b csb_hit=%b suppress=%b",
                        trace_cycle,
                        u_core.u_lsu.load_issue_data[0].pc,
                        u_core.u_lsu.load_issue_data[0].rob_idx,
                        u_core.u_lsu.load_eff_addr[0],
                        u_core.u_lsu.sq_fwd_hit,
                        u_core.u_lsu.sq_fwd_wait,
                        u_core.u_lsu.sq_fwd_partial,
                        u_core.u_lsu.same_cycle_fwd_hit,
                        u_core.u_lsu.same_cycle_fwd_partial,
                        u_core.u_lsu.csb_fwd_hit,
                        u_core.lsu_load_issue_suppress[0]);
                    $display("[LSUFWD0_SQ] cyc=%0d head=%0d tail=%0d commit_ptr=%0d rob_head=%0d",
                        trace_cycle,
                        u_core.u_lsu.u_store_queue.head_r,
                        u_core.u_lsu.u_store_queue.tail_r,
                        u_core.u_lsu.u_store_queue.commit_ptr_r,
                        u_core.rob_head_idx);
                    for (int sqe = 0; sqe < SQ_DEPTH; sqe++) begin
                        if (u_core.u_lsu.u_store_queue.queue[sqe].valid &&
                            u_core.u_lsu.u_store_queue.queue[sqe].addr_valid &&
                            (u_core.u_lsu.u_store_queue.queue[sqe].addr[63:3] ==
                             u_core.u_lsu.load_eff_addr[0][63:3])) begin
                            $display("  [LSUFWD0_ENT] idx=%0d rob=%0d committed=%b addr_v=%b data_v=%b addr=%016h data=%016h size=%0d byte_mask=%02x",
                                sqe,
                                u_core.u_lsu.u_store_queue.queue[sqe].rob_idx,
                                u_core.u_lsu.u_store_queue.queue[sqe].committed,
                                u_core.u_lsu.u_store_queue.queue[sqe].addr_valid,
                                u_core.u_lsu.u_store_queue.queue[sqe].data_valid,
                                u_core.u_lsu.u_store_queue.queue[sqe].addr,
                                u_core.u_lsu.u_store_queue.queue[sqe].data,
                                u_core.u_lsu.u_store_queue.queue[sqe].size,
                                u_core.u_lsu.u_store_queue.queue[sqe].byte_mask);
                        end
                    end
                end
                if (trace_lsu_p1_en &&
                    u_core.u_lsu.p1_wait_req_valid &&
                    (u_core.u_lsu.sq_wait_p1 ||
                     dbg_p1_sq_ready_full ||
                     dbg_p1_sq_ready_partial ||
                     u_core.u_lsu.dcache_conflict)) begin
                    logic [63:0] trace_p1_pc;
                    trace_p1_pc = u_core.u_lsu.p1_retry_valid_r
                        ? u_core.u_lsu.p1_retry_data_r.pc
                        : u_core.u_lsu.load_issue_data[1].pc;
                    $display("[LSUP1] cyc=%0d pc=%016h rob=%0d eff=%016h cand=%b issue=%b eff=%b retry=%b suppress=%b conflict=%b full=%b partial=%b wait=%b",
                        trace_cycle,
                        trace_p1_pc,
                        u_core.u_lsu.p1_wait_req_rob_idx,
                        u_core.u_lsu.p1_wait_req_addr,
                        u_core.u_lsu.load_issue_candidate_valid[1],
                        u_core.u_lsu.load_issue_valid[1],
                        u_core.u_lsu.p1_eff_valid,
                        u_core.u_lsu.p1_retry_valid_r,
                        u_core.lsu_load_issue_suppress[1],
                        u_core.u_lsu.dcache_conflict,
                        dbg_p1_sq_ready_full,
                        dbg_p1_sq_ready_partial,
                        dbg_p1_sq_wait_missing);
                    for (int sqe = 0; sqe < SQ_DEPTH; sqe++) begin
                        if (u_core.u_lsu.u_store_queue.queue[sqe].valid &&
                            u_core.u_lsu.u_store_queue.queue[sqe].addr_valid &&
                            (u_core.u_lsu.u_store_queue.queue[sqe].addr[63:3] ==
                             u_core.u_lsu.p1_wait_req_addr[63:3])) begin
                            $display("  [LSUP1_ENT] idx=%0d rob=%0d committed=%b data_v=%b addr=%016h data=%016h size=%0d byte_mask=%02x overlap=%02x",
                                sqe,
                                u_core.u_lsu.u_store_queue.queue[sqe].rob_idx,
                                u_core.u_lsu.u_store_queue.queue[sqe].committed,
                                u_core.u_lsu.u_store_queue.queue[sqe].data_valid,
                                u_core.u_lsu.u_store_queue.queue[sqe].addr,
                                u_core.u_lsu.u_store_queue.queue[sqe].data,
                                u_core.u_lsu.u_store_queue.queue[sqe].size,
                                u_core.u_lsu.u_store_queue.queue[sqe].byte_mask,
                                tb_byte_mask(u_core.u_lsu.u_store_queue.queue[sqe].size,
                                             u_core.u_lsu.u_store_queue.queue[sqe].addr) &
                                tb_byte_mask(u_core.u_lsu.p1_wait_req_size,
                                             u_core.u_lsu.p1_wait_req_addr));
                        end
                    end
                end
                // dcache MSHR allocation
                if (u_core.u_dcache.s1_ld0_valid && !u_core.u_dcache.ld0_cache_hit && !u_core.u_dcache.mshr_match_hit && u_core.u_dcache.mshr_free_avail) begin
                    $display("[MSHR_ALLOC] cyc=%0d s1_addr=%016h line_addr=%016h free_idx=%0d",
                        trace_cycle,
                        u_core.u_dcache.s1_ld0_addr,
                        u_core.u_dcache.ld0_line_addr,
                        u_core.u_dcache.mshr_free_idx);
                end
                // ROB head and tail tracking
                if (trace_cycle % 100 == 0) begin
                    $display("[ROBSTATE] cyc=%0d head=%0d tail=%0d empty=%b full=%b",
                        trace_cycle,
                        u_core.rob_head_idx,
                        u_core.rob_tail_idx,
                        u_core.rob_empty,
                        u_core.rob_full);
                end
                if (trace_iqld_watch_en) begin
                    for (int p = 0; p < 2; p++) begin
                        if (u_core.u_iq_load.sel_found[p]) begin
                            automatic iq_entry_t sel_ent;
                            sel_ent = iq_entry_t'(u_core.u_iq_load.payload_r[u_core.u_iq_load.sel_idx[p]]);
                            $display("[IQLD_SEL%0d] cyc=%0d idx=%0d rob=%0d pc=%016h pdst=%0d rs1p=%0d s1=%b n1=%b elig=%b suppress=%b issue=%b",
                                p,
                                trace_cycle,
                                u_core.u_iq_load.sel_idx[p],
                                u_core.u_iq_load.rob_idx_r[u_core.u_iq_load.sel_idx[p]],
                                sel_ent.pc,
                                sel_ent.pdst,
                                u_core.u_iq_load.rs1_phys_r[u_core.u_iq_load.sel_idx[p]],
                                u_core.u_iq_load.src1_ready[u_core.u_iq_load.sel_idx[p]],
                                u_core.u_iq_load.next_src1_ready[u_core.u_iq_load.sel_idx[p]],
                                u_core.u_iq_load.eligible[u_core.u_iq_load.sel_idx[p]],
                                u_core.lsu_load_issue_suppress[p],
                                u_core.iq_load_issue_valid[p]);
                        end
                    end
                    for (int e = 0; e < IQ_MEM_DEPTH; e++) begin
                        automatic iq_entry_t iqld_watch_ent;
                        iqld_watch_ent = iq_entry_t'(u_core.u_iq_load.payload_r[e]);
                        if (u_core.u_iq_load.entry_valid[e] &&
                            (u_core.u_iq_load.rob_idx_r[e] == ROB_IDX_BITS'(trace_iqld_watch_rob))) begin
                            $display("[IQLD_WATCH] cyc=%0d idx=%0d rob=%0d pc=%016h pdst=%0d rs1p=%0d rs2p=%0d s1=%b s2=%b n1=%b n2=%b sp1=%b sp2=%b elig=%b age=%0d count=%0d preg1=%b lwb0=%b/%0d lwb1=%b/%0d spec_wk=%b/%0d cancel=%b/%0d flush=%b full=%b rem=%b",
                                trace_cycle,
                                e,
                                u_core.u_iq_load.rob_idx_r[e],
                                iqld_watch_ent.pc,
                                iqld_watch_ent.pdst,
                                u_core.u_iq_load.rs1_phys_r[e],
                                u_core.u_iq_load.rs2_phys_r[e],
                                u_core.u_iq_load.src1_ready[e],
                                u_core.u_iq_load.src2_ready[e],
                                u_core.u_iq_load.next_src1_ready[e],
                                u_core.u_iq_load.next_src2_ready[e],
                                u_core.u_iq_load.src1_spec[e],
                                u_core.u_iq_load.src2_spec[e],
                                u_core.u_iq_load.eligible[e],
                                u_core.u_iq_load.entry_age[e],
                                u_core.u_iq_load.count_r,
                                u_core.preg_ready_table[u_core.u_iq_load.rs1_phys_r[e]],
                                u_core.load_wb_valid[0],
                                u_core.load_wb_pdst[0],
                                u_core.load_wb_valid[1],
                                u_core.load_wb_pdst[1],
                                u_core.lsu_spec_wakeup_valid[0],
                                u_core.lsu_spec_wakeup_tag[0],
                                u_core.lsu_spec_cancel_valid[0],
                                u_core.lsu_spec_cancel_tag[0],
                                u_core.flush_out.valid,
                                u_core.flush_out.full_flush,
                                u_core.u_iq_load.flush_remove[e]);
                        end
                    end
                end
                // Trace load IQ enqueue
                for (int qq = 0; qq < 2; qq++) begin
                    if (u_core.iq_load_enq_valid[qq]) begin
                        $display("[LDENQ%0d] cyc=%0d pc=%016h fu=%0d rs1_phys=%0d pdst=%0d rob=%0d imm=%016h is_fused=%b dqcnt=%0d ld_enq_cnt=%0d iq_count=%0d iq_full=%b free_found=%b free_idx=%0d valid_map=%08h issue=%b",
                            qq,
                            trace_cycle,
                            u_core.iq_load_enq_data[qq].pc,
                            u_core.iq_load_enq_data[qq].fu_type,
                            u_core.iq_load_enq_data[qq].rs1_phys,
                            u_core.iq_load_enq_data[qq].pdst,
                            u_core.iq_load_enq_data[qq].rob_idx,
                            u_core.iq_load_enq_data[qq].imm,
                            u_core.iq_load_enq_data[qq].is_fused,
                            u_core.dq_deq_count,
                            u_core.iq_ld_enq_cnt,
                            u_core.u_iq_load.count_r,
                            u_core.iq_load_full,
                            u_core.u_iq_load.free_found[qq],
                            u_core.u_iq_load.free_idx[qq],
                            u_core.u_iq_load.entry_valid,
                            u_core.iq_load_issue_valid);
                        if (!u_core.u_iq_load.free_found[qq]) begin
                            $display("[LDENQ_DROP] cyc=%0d lane=%0d rob=%0d pc=%016h iq_count=%0d valid_map=%08h",
                                trace_cycle,
                                qq,
                                u_core.iq_load_enq_data[qq].rob_idx,
                                u_core.iq_load_enq_data[qq].pc,
                                u_core.u_iq_load.count_r,
                                u_core.u_iq_load.entry_valid);
                        end
                    end
                end
                // Trace IQ1 enqueue (ALU2/MUL path)
                for (int qq = 0; qq < 2; qq++) begin
                    if (u_core.iq1_enq_valid[qq]) begin
                        $display("[IQ1ENQ%0d] cyc=%0d pc=%016h fu=%0d rs1_phys=%0d rs2_phys=%0d pdst=%0d rob=%0d s1_rdy=%b s2_rdy=%b",
                            qq,
                            trace_cycle,
                            u_core.iq1_enq_data[qq].pc,
                            u_core.iq1_enq_data[qq].fu_type,
                            u_core.iq1_enq_data[qq].rs1_phys,
                            u_core.iq1_enq_data[qq].rs2_phys,
                            u_core.iq1_enq_data[qq].pdst,
                            u_core.iq1_enq_data[qq].rob_idx,
                            u_core.iq1_enq_data[qq].rs1_ready,
                            u_core.iq1_enq_data[qq].rs2_ready);
                    end
                end
                // Trace dq_iq_entry (raw output of dispatch_queue with iq routing)
                for (int dqi = 0; dqi < PIPE_WIDTH; dqi++) begin
                    if ((dqi < int'(u_core.dq_deq_count)) &&
                        u_core.dq_deq_data[dqi].base.valid &&
                        u_core.dq_deq_data[dqi].base.is_load) begin
                        $display("[DQDEQ%0d] cyc=%0d pc=%016h fu=%0d rs1_phys=%0d pdst=%0d rob=%0d imm=%016h is_fused=%b is_load=%b dqcnt=%0d target=%0d",
                            dqi,
                            trace_cycle,
                            u_core.dq_deq_data[dqi].base.pc,
                            u_core.dq_deq_data[dqi].base.fu_type,
                            u_core.dq_deq_data[dqi].rs1_phys,
                            u_core.dq_deq_data[dqi].pdst,
                            u_core.dq_deq_data[dqi].rob_idx,
                            u_core.dq_deq_data[dqi].base.imm,
                            u_core.dq_deq_data[dqi].base.is_fused,
                            u_core.dq_deq_data[dqi].base.is_load,
                            u_core.dq_deq_count,
                            u_core.dq_deq_iq_target[dqi]);
                    end
                end
                // Trace fetcher output (decode input)
                if (u_core.u_fetch_top.fetch_count > 0) begin
                    for (int fi = 0; fi < PIPE_WIDTH; fi++) begin
                        if (fi < int'(u_core.u_fetch_top.fetch_count)) begin
                            $display("[FETCH%0d] cyc=%0d pc=%016h insn=%08h is_rvc=%b",
                                fi,
                                trace_cycle,
                                u_core.u_fetch_top.fetch_pc[fi],
                                u_core.u_fetch_top.fetch_insn[fi],
                                u_core.u_fetch_top.fetch_is_rvc[fi]);
                        end
                    end
                end
                // Trace fetch internals
                $display("[F1F2] cyc=%0d f1_pc=%016h f1_v=%b f2_pc=%016h f2_v=%b ic_v=%b ic_d[63:0]=%016h",
                    trace_cycle,
                    u_core.u_fetch_top.f1_pc,
                    u_core.u_fetch_top.f1_valid,
                    u_core.u_fetch_top.f2_work_pc_c,
                    u_core.u_fetch_top.f2_work_valid_c,
                    u_core.u_fetch_top.ic_resp_valid,
                    u_core.u_fetch_top.ic_resp_data[63:0]);
                $display("[ICST] cyc=%0d mshr0_v=%b mshr1_v=%b fill_v=%b fill_d[63:0]=%016h",
                    trace_cycle,
                    u_core.u_fetch_top.u_ifu_line_fetch.u_icache.ic_mshr_valid[0],
                    u_core.u_fetch_top.u_ifu_line_fetch.u_icache.ic_mshr_valid[1],
                    u_core.u_fetch_top.u_ifu_line_fetch.u_icache.fill_resp_valid,
                    u_core.u_fetch_top.u_ifu_line_fetch.u_icache.fill_resp_data[63:0]);
            end
        end
    end

    final begin
        if (trace_coremark_progress_en) begin
            $display("=== COREMARK PROGRESS SUMMARY ===");
            for (int i = 0; i <= 20; i++) begin
                $display("[CM_PROGRESS_SUMMARY] idx=%0d count=%0d",
                    i, cm_progress_count[i]);
            end
        end
        if (trace_commit_hotspots_en) begin
            logic [COMMIT_HOTSPOT_BINS-1:0] printed;
            integer max_count;
            integer max_idx;
            printed = '0;
            $display("=== COMMIT PC HOTSPOTS ===");
            for (int rank = 0; rank < 32; rank++) begin
                max_count = 0;
                max_idx = 0;
                for (int i = 0; i < COMMIT_HOTSPOT_BINS; i++) begin
                    if (!printed[i] && (commit_pc_hist[i] > max_count)) begin
                        max_count = commit_pc_hist[i];
                        max_idx = i;
                    end
                end
                if (max_count != 0) begin
                    printed[max_idx] = 1'b1;
                    $display("[COMMIT_HOTSPOT] rank=%0d pc=%016h count=%0d",
                        rank,
                        COMMIT_HOTSPOT_BASE + (64'(max_idx) << 1),
                        max_count);
                end
            end
        end
    end

    // =========================================================================
    // Simulation memory instantiation
    // =========================================================================
    sim_memory u_mem (
        .clk             (clk),
        .rst_n           (rst_n),

        // L2 cache to memory interface
        .mem_req_valid   (mem_req_valid),
        .mem_req_addr    (mem_req_addr),
        .mem_req_we      (mem_req_we),
        .mem_req_wdata   (mem_req_wdata),
        .mem_req_ready   (mem_req_ready),
        .mem_resp_valid  (mem_resp_valid),
        .mem_resp_data   (mem_resp_data)
    );

    // =========================================================================
    // Performance counters (enabled with +PERF_COUNTERS)
    // =========================================================================
    logic perf_en;
    initial begin
        perf_en = 0;
        if ($test$plusargs("PERF_COUNTERS")) perf_en = 1;
    end

    // Skip the first WARMUP cycles so startup / icache-cold effects
    // don't dominate the counters.
    localparam int WARMUP = 2000;

    longint unsigned pc_total_cycles;
    longint unsigned pc_fetch_stall;       // backend_stall held fetch
    longint unsigned pc_rob_full;
    longint unsigned pc_dq_full;
    longint unsigned pc_iq0_full, pc_iq1_full, pc_iq2_full;
    longint unsigned pc_lq_full, pc_sq_full;
    longint unsigned pc_flush_cycles;
    longint unsigned pc_fetch_0, pc_fetch_1, pc_fetch_2, pc_fetch_3,
                     pc_fetch_4, pc_fetch_5, pc_fetch_6;
    longint unsigned pc_commit_0, pc_commit_1, pc_commit_2, pc_commit_3,
                     pc_commit_4, pc_commit_5, pc_commit_6;
    longint unsigned pc_total_fetched, pc_total_committed, pc_total_flushed;
    longint unsigned pc_icache_miss;      // f2 valid but icache didn't respond
    longint unsigned pc_bpu_redirect;     // BPU-initiated redirect (taken branch)
    longint unsigned pc_backend_redirect; // commit-initiated flush

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_total_cycles  <= 0;
            pc_fetch_stall   <= 0;
            pc_rob_full      <= 0;
            pc_dq_full       <= 0;
            pc_iq0_full      <= 0; pc_iq1_full <= 0; pc_iq2_full <= 0;
            pc_lq_full       <= 0; pc_sq_full  <= 0;
            pc_flush_cycles  <= 0;
            pc_fetch_0 <= 0; pc_fetch_1 <= 0; pc_fetch_2 <= 0;
            pc_fetch_3 <= 0; pc_fetch_4 <= 0; pc_fetch_5 <= 0; pc_fetch_6 <= 0;
            pc_commit_0 <= 0; pc_commit_1 <= 0; pc_commit_2 <= 0;
            pc_commit_3 <= 0; pc_commit_4 <= 0; pc_commit_5 <= 0; pc_commit_6 <= 0;
            pc_total_fetched   <= 0;
            pc_total_committed <= 0;
            pc_total_flushed   <= 0;
            pc_icache_miss     <= 0;
            pc_bpu_redirect    <= 0;
            pc_backend_redirect <= 0;
        end else if (perf_en && pc_total_cycles >= WARMUP) begin
            pc_total_cycles <= pc_total_cycles + 1;

            // Stall sources
            if (u_core.backend_stall)  pc_fetch_stall <= pc_fetch_stall + 1;
            if (u_core.rob_full)       pc_rob_full    <= pc_rob_full + 1;
            if (u_core.dq_full)        pc_dq_full     <= pc_dq_full + 1;
            if (u_core.iq0_full)       pc_iq0_full    <= pc_iq0_full + 1;
            if (u_core.iq1_full)       pc_iq1_full    <= pc_iq1_full + 1;
            if (u_core.iq2_full)       pc_iq2_full    <= pc_iq2_full + 1;
            if (u_core.lq_full)        pc_lq_full     <= pc_lq_full + 1;
            if (u_core.sq_full)        pc_sq_full     <= pc_sq_full + 1;
            if (u_core.flush_out.valid) pc_flush_cycles <= pc_flush_cycles + 1;
            if (u_core.bru_early_redirect) pc_backend_redirect <= pc_backend_redirect + 1;
            // IC miss: f2 stage was valid but icache didn't deliver data
            if (u_core.u_fetch_top.f2_work_valid_c && !u_core.u_fetch_top.ic_resp_valid)
                pc_icache_miss <= pc_icache_miss + 1;
            if (u_core.uoc_active)
                pc_total_flushed <= pc_total_flushed + 1; // decoded-op replay active counter
            if (u_core.u_fetch_top.f2_bpu_redirect)
                pc_bpu_redirect <= pc_bpu_redirect + 1;
            if (u_core.flush_out.valid)
                pc_backend_redirect <= pc_backend_redirect + 1;
            if (u_core.bru_early_redirect)
                pc_total_flushed <= pc_total_flushed + 1; // reuse for BRU redirect count

            // Fetch width histogram
            case (u_core.fetch_count)
                3'd0: pc_fetch_0 <= pc_fetch_0 + 1;
                3'd1: pc_fetch_1 <= pc_fetch_1 + 1;
                3'd2: pc_fetch_2 <= pc_fetch_2 + 1;
                3'd3: pc_fetch_3 <= pc_fetch_3 + 1;
                3'd4: pc_fetch_4 <= pc_fetch_4 + 1;
                3'd5: pc_fetch_5 <= pc_fetch_5 + 1;
                3'd6: pc_fetch_6 <= pc_fetch_6 + 1;
                default: ;
            endcase
            pc_total_fetched <= pc_total_fetched + {61'd0, u_core.fetch_count};

            // Commit width histogram
            case (u_core.commit_count)
                3'd0: pc_commit_0 <= pc_commit_0 + 1;
                3'd1: pc_commit_1 <= pc_commit_1 + 1;
                3'd2: pc_commit_2 <= pc_commit_2 + 1;
                3'd3: pc_commit_3 <= pc_commit_3 + 1;
                3'd4: pc_commit_4 <= pc_commit_4 + 1;
                3'd5: pc_commit_5 <= pc_commit_5 + 1;
                3'd6: pc_commit_6 <= pc_commit_6 + 1;
                default: ;
            endcase
            pc_total_committed <= pc_total_committed + {61'd0, u_core.commit_count};
            pc_total_flushed   <= pc_total_flushed +
                (u_core.flush_out.valid ? 64'd1 : 64'd0);
        end else begin
            pc_total_cycles <= pc_total_cycles + 1;
        end
    end

    // Print perf counters on tohost write or periodic dump
    logic perf_printed;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            perf_printed <= 1'b0;
        end else if (perf_en && !perf_printed && pc_total_cycles > WARMUP &&
                     (tb_tohost_store_valid || (pc_total_cycles[19:0] == 20'd0 && pc_total_cycles > 64'd1000000))) begin
            perf_printed <= (tb_tohost_store_valid) ? 1'b1 : 1'b0;
            $display("=== PERF COUNTERS (after %0d warmup cycles) ===", WARMUP);
            $display("Total measured cycles : %0d", pc_total_cycles - WARMUP);
            $display("--- Stall breakdown (cycles where signal was high) ---");
            $display("  backend_stall (fetch held) : %0d", pc_fetch_stall);
            $display("  ROB full                   : %0d", pc_rob_full);
            $display("  DQ full                    : %0d", pc_dq_full);
            $display("  IQ0 full                   : %0d", pc_iq0_full);
            $display("  IQ1 full                   : %0d", pc_iq1_full);
            $display("  IQ2 full                   : %0d", pc_iq2_full);
            $display("  LQ full                    : %0d", pc_lq_full);
            $display("  SQ full                    : %0d", pc_sq_full);
            $display("--- Flush ---");
            $display("  Flush events               : %0d", pc_total_flushed);
            $display("--- Fetch width histogram ---");
            $display("  0: %0d  1: %0d  2: %0d  3: %0d  4: %0d  5: %0d  6: %0d",
                pc_fetch_0, pc_fetch_1, pc_fetch_2, pc_fetch_3,
                pc_fetch_4, pc_fetch_5, pc_fetch_6);
            $display("  Total fetched: %0d", pc_total_fetched);
            $display("--- Commit width histogram ---");
            $display("  0: %0d  1: %0d  2: %0d  3: %0d  4: %0d  5: %0d  6: %0d",
                pc_commit_0, pc_commit_1, pc_commit_2, pc_commit_3,
                pc_commit_4, pc_commit_5, pc_commit_6);
            $display("  Total committed: %0d", pc_total_committed);
            $display("--- Frontend detail ---");
            $display("  IC miss (f2 valid, no data) : %0d", pc_icache_miss);
            $display("  BPU redirects (taken br)    : %0d", pc_bpu_redirect);
            $display("  Backend redirects (flush)   : %0d", pc_backend_redirect);
        end
    end

    // ----------------------------------------------------------------
    // Golden PC scoreboard finalization (close emit file, declare OK)
    // ----------------------------------------------------------------
    final begin
        if (golden_emit_en && golden_emit_fd != 0) begin
            $fclose(golden_emit_fd);
            $display("[GOLDEN_PC EMIT_DONE] seq=%0d", golden_seq_r);
        end
        if (golden_check_en && !golden_tripped_r) begin
            $display("[GOLDEN_PC OK] seq=%0d size=%0d",
                golden_seq_r, golden_size);
        end
    end

    // ====================================================================
    // Shadow signals for incremental F2-decoupling cascade validation
    // ====================================================================
    // Per the data-driven discipline + the design-validation tooling gap
    // identified 2026-05-05: rather than land the full F2-work-PC-from-queue
    // refactor as a single big-bang RTL change, we observe what the
    // hypothetical change WOULD do by computing it as a shadow signal
    // alongside the current cursor behavior. The shadow lets us measure the
    // divergence rate before committing.
    //
    // Shadow A: IFU work PC if it tracked icq_deq_pc instead of f1_pc.
    //   - In current design (post-bcf9b5c), the queue is wired but F2
    //     still captures f1_pc each cycle. So in steady-state lockstep,
    //     icq_deq_pc == f1_pc(T-1) == IFU work PC(T+1 captured at T edge).
    //   - The shadow tracks icq_deq_pc each cycle; we count cycles
    //     where the shadow would diverge from actual IFU work PC. In
    //     baseline this should be ~0 (lockstep validates the queue).
    //   - When we later enable F1 runahead, the shadow will start
    //     diverging because F1 advances more often than F2 consumes,
    //     giving us a quantitative measure of "how much would F2's
    //     pc tracking change."
    logic [63:0] f2_work_pc_shadow_queue_r;
    integer      shadow_queue_pc_diverge_cycles_r;
    integer      shadow_queue_pc_match_cycles_r;
    logic [63:0] last_shadow_diverge_actual_r;
    logic [63:0] last_shadow_diverge_proposed_r;
    integer      last_shadow_diverge_cycle_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f2_work_pc_shadow_queue_r <= 64'd0;
            shadow_queue_pc_diverge_cycles_r <= 0;
            shadow_queue_pc_match_cycles_r <= 0;
            last_shadow_diverge_actual_r <= 64'd0;
            last_shadow_diverge_proposed_r <= 64'd0;
            last_shadow_diverge_cycle_r <= 0;
        end else begin
            // Update shadow only when the proposed design's F2 would actually
            // capture from queue: when F2 is consuming this cycle (will emit).
            // Otherwise hold (proposed F2 holds when not consuming).
            if (u_core.u_fetch_top.f2_will_emit_c &&
                u_core.u_fetch_top.ic_resp_valid) begin
                f2_work_pc_shadow_queue_r <= u_core.u_fetch_top.icq_deq_pc;
            end

            // Compare shadow against actual at the F2 stage (only meaningful
            // when F2 is valid AND has data via the queue path AND we're not
            // in a transition state)
            if (u_core.u_fetch_top.f2_work_valid_c &&
                u_core.u_fetch_top.ic_resp_valid &&
                u_core.u_fetch_top.f2_will_emit_c &&
                !u_core.u_fetch_top.f2_line_state_use_c &&
                !u_core.u_fetch_top.consumed_remainder_r) begin
                if (u_core.u_fetch_top.f2_work_pc_c[63:6] ==
                    f2_work_pc_shadow_queue_r[63:6]) begin
                    shadow_queue_pc_match_cycles_r <=
                        shadow_queue_pc_match_cycles_r + 1;
                end else begin
                    shadow_queue_pc_diverge_cycles_r <=
                        shadow_queue_pc_diverge_cycles_r + 1;
                    last_shadow_diverge_actual_r   <= u_core.u_fetch_top.f2_work_pc_c;
                    last_shadow_diverge_proposed_r <= f2_work_pc_shadow_queue_r;
                    last_shadow_diverge_cycle_r    <= trace_cycle;
                end
            end
        end
    end

    final begin
        if (shadow_queue_pc_match_cycles_r > 0 ||
            shadow_queue_pc_diverge_cycles_r > 0) begin
            $display("[SHADOW_F2_PC_FROM_QUEUE] match=%0d diverge=%0d",
                shadow_queue_pc_match_cycles_r,
                shadow_queue_pc_diverge_cycles_r);
            if (shadow_queue_pc_diverge_cycles_r > 0) begin
                $display("[SHADOW_F2_PC_FROM_QUEUE] last_diverge cycle=%0d actual=%016h proposed=%016h",
                    last_shadow_diverge_cycle_r,
                    last_shadow_diverge_actual_r,
                    last_shadow_diverge_proposed_r);
            end
        end
    end

endmodule

/* file: tb_top.sv
 * Description: Top-level simulation testbench.  Instantiates rv64gc_core_top
 *              and sim_memory, wires them together, and exposes tohost
 *              pass/fail signals to the Verilator C++ driver.
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
    // Core-level tohost detection (snoops CSB drain to D-cache)
    logic        core_tohost_valid;
    logic [63:0] core_tohost_data;

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

        // Tohost address from package
        .tohost_addr     (TOHOST_ADDR),

        // Tohost detection
        .tohost_wr_valid (core_tohost_valid),
        .tohost_wr_data  (core_tohost_data),

        // Performance counters
        .perf_mcycle     (perf_mcycle),
        .perf_minstret   (perf_minstret)
    );

    // Use core-level tohost detection (immediate, no cache writeback delay)
    // Latch the core_tohost into a sticky flop so the C++ driver can see
    // the pulse even if it sampled in the wrong half-cycle.
    logic        core_tohost_seen_q;
    logic [63:0] core_tohost_data_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            core_tohost_seen_q <= 1'b0;
            core_tohost_data_q <= 64'd0;
        end else if (core_tohost_valid && !core_tohost_seen_q) begin
            core_tohost_seen_q <= 1'b1;
            core_tohost_data_q <= core_tohost_data;
        end
    end

    assign tohost_valid = core_tohost_seen_q;
    assign tohost_value = core_tohost_data_q;

    // =========================================================================
    // Commit PC tracing (enabled with +TRACE_COMMIT)
    // =========================================================================
    // Dumps every committed PC to stdout so we can post-process in Python.
    // Enabled only when +TRACE_COMMIT is passed on the simulator command line.
    logic trace_commit_en;
    initial begin
        trace_commit_en = 0;
        if ($test$plusargs("TRACE_COMMIT")) trace_commit_en = 1;
    end

    integer trace_cycle;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            trace_cycle <= 0;
        end else begin
            trace_cycle <= trace_cycle + 1;
            if (trace_commit_en && (u_core.commit_count > 3'd0)) begin
                for (int i = 0; i < 6; i++) begin
                    if (u_core.commit_out[i].valid) begin
                        $display("[CPC] cyc=%0d slot=%0d pc=%016h br=%b mis=%b",
                            trace_cycle, i,
                            u_core.rob_head_pc[i],
                            u_core.rob_head_is_branch[i],
                            u_core.rob_head_branch_mispredict[i]);
                    end
                end
            end
            if (trace_commit_en && u_core.flush_out.valid) begin
                $display("[FLUSH] cyc=%0d redirect_pc=%016h full=%b",
                    trace_cycle,
                    u_core.flush_out.redirect_pc,
                    u_core.flush_out.full_flush);
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
                // Trace load IQ enqueue
                for (int qq = 0; qq < 2; qq++) begin
                    if (u_core.iq_load_enq_valid[qq]) begin
                        $display("[LDENQ%0d] cyc=%0d pc=%016h fu=%0d rs1_phys=%0d pdst=%0d imm=%016h is_fused=%b",
                            qq,
                            trace_cycle,
                            u_core.iq_load_enq_data[qq].pc,
                            u_core.iq_load_enq_data[qq].fu_type,
                            u_core.iq_load_enq_data[qq].rs1_phys,
                            u_core.iq_load_enq_data[qq].pdst,
                            u_core.iq_load_enq_data[qq].imm,
                            u_core.iq_load_enq_data[qq].is_fused);
                    end
                end
                // Trace dq_iq_entry (raw output of dispatch_queue with iq routing)
                for (int dqi = 0; dqi < 6; dqi++) begin
                    if (u_core.dq_deq_data[dqi].base.valid &&
                        u_core.dq_deq_data[dqi].base.is_load) begin
                        $display("[DQDEQ%0d] cyc=%0d pc=%016h fu=%0d rs1_phys=%0d pdst=%0d imm=%016h is_fused=%b is_load=%b",
                            dqi,
                            trace_cycle,
                            u_core.dq_deq_data[dqi].base.pc,
                            u_core.dq_deq_data[dqi].base.fu_type,
                            u_core.dq_deq_data[dqi].rs1_phys,
                            u_core.dq_deq_data[dqi].pdst,
                            u_core.dq_deq_data[dqi].base.imm,
                            u_core.dq_deq_data[dqi].base.is_fused,
                            u_core.dq_deq_data[dqi].base.is_load);
                    end
                end
                // Trace fetcher output (decode input)
                if (u_core.u_fetch_unit.fetch_count > 0) begin
                    for (int fi = 0; fi < 6; fi++) begin
                        if (fi < int'(u_core.u_fetch_unit.fetch_count)) begin
                            $display("[FETCH%0d] cyc=%0d pc=%016h insn=%08h is_rvc=%b",
                                fi,
                                trace_cycle,
                                u_core.u_fetch_unit.fetch_pc[fi],
                                u_core.u_fetch_unit.fetch_insn[fi],
                                u_core.u_fetch_unit.fetch_is_rvc[fi]);
                        end
                    end
                end
                // Trace fetch internals
                $display("[F1F2] cyc=%0d f1_pc=%016h f1_v=%b f2_pc=%016h f2_v=%b ic_v=%b ic_d[63:0]=%016h",
                    trace_cycle,
                    u_core.u_fetch_unit.f1_pc,
                    u_core.u_fetch_unit.f1_valid,
                    u_core.u_fetch_unit.f2_pc_r,
                    u_core.u_fetch_unit.f2_valid_r,
                    u_core.u_fetch_unit.ic_resp_valid,
                    u_core.u_fetch_unit.ic_resp_data[63:0]);
                $display("[ICST] cyc=%0d state=%b miss_addr=%016h fill_v=%b fill_d[63:0]=%016h",
                    trace_cycle,
                    u_core.u_fetch_unit.u_icache.state_q,
                    u_core.u_fetch_unit.u_icache.miss_addr_q,
                    u_core.u_fetch_unit.u_icache.fill_resp_valid,
                    u_core.u_fetch_unit.u_icache.fill_resp_data[63:0]);
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
        .mem_resp_data   (mem_resp_data),

        // Tohost monitoring
        .tohost_addr     (TOHOST_ADDR),
        .tohost_valid    (tohost_valid),
        .tohost_value    (tohost_value)
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
            if (u_core.u_fetch_unit.f2_valid_r && !u_core.u_fetch_unit.ic_resp_valid)
                pc_icache_miss <= pc_icache_miss + 1;
            if (u_core.lb_active) pc_total_flushed <= pc_total_flushed + 1; // reuse as LB active counter
            if (u_core.u_fetch_unit.f2_bpu_redirect)
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
                     (core_tohost_valid || (pc_total_cycles[19:0] == 20'd0 && pc_total_cycles > 64'd1000000))) begin
            perf_printed <= (core_tohost_valid) ? 1'b1 : 1'b0;
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

endmodule

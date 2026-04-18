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

    // =========================================================================
    // Per-stage pipeline counters (enabled with +PERF_PROFILE)
    // =========================================================================
    logic pp_en;
    initial begin
        pp_en = 0;
        if ($test$plusargs("PERF_PROFILE")) pp_en = 1;
    end

    // Fetch histogram: cycles where fetch_count = N
    integer fetch_hist [0:6];
    // Commit histogram: cycles where commit_count = N
    integer commit_hist [0:6];
    // Loop buffer active cycles
    integer lb_active_cycles;
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
    integer backend_stall_cyc;
    integer flush_cyc;
    integer perf_total_cyc;
    // Rename stall source breakdown: fires when rename stalls, tags the
    // first missing resource on slot 0 (other slots typically cascade).
    integer stall_preg_cyc, stall_ckpt_cyc, stall_rob_cyc, stall_dq_cyc, stall_other_cyc;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 7; i++) begin
                fetch_hist[i]  <= 0;
                commit_hist[i] <= 0;
            end
            lb_active_cycles   <= 0;
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
            stall_preg_cyc     <= 0;
            stall_ckpt_cyc     <= 0;
            stall_rob_cyc      <= 0;
            stall_dq_cyc       <= 0;
            stall_other_cyc    <= 0;
        end else if (pp_en) begin
            perf_total_cyc    <= perf_total_cyc + 1;
            fetch_hist[u_core.fetch_count]   <= fetch_hist[u_core.fetch_count] + 1;
            commit_hist[u_core.commit_count] <= commit_hist[u_core.commit_count] + 1;
            if (u_core.lb_active)       lb_active_cycles  <= lb_active_cycles + 1;
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
            if (u_core.backend_stall)   backend_stall_cyc <= backend_stall_cyc + 1;
            if (u_core.flush_out.valid) flush_cyc         <= flush_cyc + 1;
            // Rename stall source classification (slot 0 sufficient to attribute)
            if (u_core.rename_stall) begin
                if      (!u_core.u_rename.has_preg[0])  stall_preg_cyc  <= stall_preg_cyc + 1;
                else if (!u_core.u_rename.has_ckpt[0])  stall_ckpt_cyc  <= stall_ckpt_cyc + 1;
                else if (!u_core.u_rename.has_rob[0])   stall_rob_cyc   <= stall_rob_cyc + 1;
                else if (!u_core.u_rename.has_dq[0])    stall_dq_cyc    <= stall_dq_cyc + 1;
                else                                     stall_other_cyc <= stall_other_cyc + 1;
            end
        end
    end

    final begin
        if (pp_en) begin
            $display("==== PERF PROFILE ====");
            $display("Total cycles: %0d", perf_total_cyc);
            $display("Fetch histogram (cycles with N instr fetched):");
            for (int i = 0; i <= 6; i++)
                $display("  fetch=%0d : %0d (%0d%%)", i, fetch_hist[i],
                         (perf_total_cyc > 0) ? (fetch_hist[i] * 100 / perf_total_cyc) : 0);
            $display("Commit histogram (cycles with N instr committed):");
            for (int i = 0; i <= 6; i++)
                $display("  commit=%0d: %0d (%0d%%)", i, commit_hist[i],
                         (perf_total_cyc > 0) ? (commit_hist[i] * 100 / perf_total_cyc) : 0);
            $display("Loop buffer active: %0d cycles (%0d%%)",
                     lb_active_cycles,
                     (perf_total_cyc > 0) ? (lb_active_cycles * 100 / perf_total_cyc) : 0);
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
            $display("  stall_other  : %0d", stall_other_cyc);
            $display("Average IQ occupancy (of 32):");
            $display("  iq0_avg: %0d.%02d", iq0_cnt_sum / perf_total_cyc,
                     ((iq0_cnt_sum * 100) / perf_total_cyc) % 100);
            $display("  iq1_avg: %0d.%02d", iq1_cnt_sum / perf_total_cyc,
                     ((iq1_cnt_sum * 100) / perf_total_cyc) % 100);
            $display("  iq2_avg: %0d.%02d", iq2_cnt_sum / perf_total_cyc,
                     ((iq2_cnt_sum * 100) / perf_total_cyc) % 100);
            $display("Flushes: %0d", flush_cyc);
        end
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
                for (int s = 0; s < 6; s++) begin
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
            for (int s = 0; s < 6; s++) begin
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
            if (trace_commit_en && (u_core.u_rob.rob_head_watchdog == 12'd61)) begin
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
                for (int c = 0; c < 6; c++) begin
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
                    u_core.tohost_wr_valid);
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
                $display("[DC_STATE] cyc=%0d s1_st_v=%b wait_fill=%b fill_done=%b hit=%b allo_mshr=%b mshr_mat=%b is_tohost=%b l2_state=%0d mshr0_v=%b mshr0_fp=%b mshr0_wp=%b mshr0_fd=%b fill_avail=%b wb_avail=%b",
                    trace_cycle,
                    u_core.u_dcache.s1_st_valid,
                    u_core.u_dcache.s1_st_waiting_for_fill,
                    u_core.u_dcache.fill_done_avail,
                    u_core.u_dcache.st_cache_hit,
                    u_core.u_dcache.s1_st_can_allocate_mshr,
                    u_core.u_dcache.mshr_st_match_hit,
                    u_core.u_dcache.s1_st_is_tohost,
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
                $display("[ICST] cyc=%0d mshr0_v=%b mshr1_v=%b fill_v=%b fill_d[63:0]=%016h",
                    trace_cycle,
                    u_core.u_fetch_unit.u_icache.ic_mshr_valid[0],
                    u_core.u_fetch_unit.u_icache.ic_mshr_valid[1],
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

    // =========================================================================
    // DIAGNOSTIC PROBES FOR ROOT-CAUSE ANALYSIS (spec: 2026-04-16)
    // All gated on +TRACE_COMMIT.  Testbench-only; no RTL semantic changes.
    // =========================================================================

    // P1. Per-rob_idx instruction-info snapshot.
    // Captures at rename: pdst, rs1/rs2_phys/arch, rd_arch, PC, rd_valid, is_*.
    // Used for reverse dep-chain walk at WDOG fire.
    typedef struct packed {
        logic                      valid;
        logic [PHYS_REG_BITS-1:0]  pdst;
        logic [PHYS_REG_BITS-1:0]  rs1_phys;
        logic [PHYS_REG_BITS-1:0]  rs2_phys;
        logic [4:0]                rd_arch;
        logic [4:0]                rs1_arch;
        logic [4:0]                rs2_arch;
        logic                      rd_valid;
        logic                      rs1_valid;
        logic                      rs2_valid;
        logic                      is_load;
        logic                      is_store;
        logic                      is_branch;
        logic [63:0]               pc;
        logic [31:0]               cyc_renamed;
        logic [31:0]               cyc_broadcast;
    } diag_insn_info_t;
    diag_insn_info_t insn_info [0:ROB_DEPTH-1];

    // Always update snapshot on rename / CDB broadcast / full flush.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || (u_core.flush_out.valid && u_core.flush_out.full_flush)) begin
            for (int k = 0; k < ROB_DEPTH; k++) insn_info[k] <= '0;
        end else begin
            // Rename: capture
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                if (3'(i) < u_core.ren_count_w) begin
                    automatic logic [ROB_IDX_BITS-1:0] idx = u_core.ren_insn[i].rob_idx;
                    insn_info[idx].valid       <= 1'b1;
                    insn_info[idx].pdst        <= u_core.ren_insn[i].pdst;
                    insn_info[idx].rs1_phys    <= u_core.ren_insn[i].rs1_phys;
                    insn_info[idx].rs2_phys    <= u_core.ren_insn[i].rs2_phys;
                    insn_info[idx].rd_arch     <= u_core.ren_insn[i].base.rd_arch;
                    insn_info[idx].rs1_arch    <= u_core.ren_insn[i].base.rs1_arch;
                    insn_info[idx].rs2_arch    <= u_core.ren_insn[i].base.rs2_arch;
                    insn_info[idx].rd_valid    <= u_core.ren_insn[i].base.rd_valid;
                    insn_info[idx].rs1_valid   <= u_core.ren_insn[i].base.rs1_valid;
                    insn_info[idx].rs2_valid   <= u_core.ren_insn[i].base.rs2_valid;
                    insn_info[idx].is_load     <= u_core.ren_insn[i].base.is_load;
                    insn_info[idx].is_store    <= u_core.ren_insn[i].base.is_store;
                    insn_info[idx].is_branch   <= u_core.ren_insn[i].base.is_branch;
                    insn_info[idx].pc          <= u_core.ren_insn[i].base.pc;
                    insn_info[idx].cyc_renamed <= 32'(trace_cycle);
                    insn_info[idx].cyc_broadcast <= 32'hFFFF_FFFF;
                end
            end
            // CDB broadcast: mark cyc_broadcast for producer
            for (int c = 0; c < CDB_WIDTH; c++) begin
                if (u_core.cdb_valid[c] && u_core.cdb_tag[c] != '0) begin
                    for (int k = 0; k < ROB_DEPTH; k++) begin
                        if (insn_info[k].valid
                            && (insn_info[k].pdst == u_core.cdb_tag[c])
                            && (insn_info[k].cyc_broadcast == 32'hFFFF_FFFF)) begin
                            insn_info[k].cyc_broadcast <= 32'(trace_cycle);
                        end
                    end
                end
            end
        end
    end

    // P2. CDB broadcast ring (256 entries).
    typedef struct packed {
        logic [31:0]                cyc;
        logic [PHYS_REG_BITS-1:0]   pdst;
        logic [63:0]                pc;
    } cdb_event_t;
    cdb_event_t cdb_ring [0:255];
    logic [7:0]  cdb_ring_head;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cdb_ring_head <= 8'd0;
            for (int k = 0; k < 256; k++) cdb_ring[k] <= '0;
        end else if (trace_commit_en) begin
            for (int c = 0; c < CDB_WIDTH; c++) begin
                if (u_core.cdb_valid[c] && u_core.cdb_tag[c] != '0) begin
                    cdb_ring[cdb_ring_head].cyc  <= 32'(trace_cycle);
                    cdb_ring[cdb_ring_head].pdst <= u_core.cdb_tag[c];
                    // PC not available on CDB path; leave 0.
                    cdb_ring[cdb_ring_head].pc   <= 64'd0;
                    cdb_ring_head <= cdb_ring_head + 8'd1;
                end
            end
        end
    end

    // Track whether each rob_idx has EVER been issued via LSU port 0 or 1,
    // and when.  Filled on every LSU issue; cleared on full_flush.
    // Also track: cyc entered stage R (load_issue_data_r), stage RR, dcache response, writeback.
    logic [31:0] lsu_issued_cyc    [0:ROB_DEPTH-1];  // 0 = never issued
    logic [31:0] lsu_r_cyc         [0:ROB_DEPTH-1];  // stage _r (1 cyc after issue)
    logic [31:0] lsu_rr_cyc        [0:ROB_DEPTH-1];  // stage _rr (2 cyc after issue)
    logic [31:0] lsu_dcresp_cyc    [0:ROB_DEPTH-1];  // cyc dcache responded valid
    logic [31:0] lsu_wb_cyc        [0:ROB_DEPTH-1];  // cyc load_wb_valid fired
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || (u_core.flush_out.valid && u_core.flush_out.full_flush)) begin
            for (int k = 0; k < ROB_DEPTH; k++) begin
                lsu_issued_cyc[k]    <= 32'd0;
                lsu_r_cyc[k]         <= 32'd0;
                lsu_rr_cyc[k]        <= 32'd0;
                lsu_dcresp_cyc[k]    <= 32'd0;
                lsu_wb_cyc[k]        <= 32'd0;
            end
        end else begin
            // Port 0 issue — log ALL within cyc range [1430, 1510] for debug
            if (u_core.u_lsu.load_issue_valid[0]) begin
                lsu_issued_cyc[u_core.u_lsu.load_issue_data[0].rob_idx] <= 32'(trace_cycle);
                if (trace_commit_en && trace_cycle >= 1430 && trace_cycle <= 1510) begin
                    $display("[LSU_ISSUE] cyc=%0d rob=%0d pdst=%0d pc=%016h addr=%016h misaligned=%b flush=%b rs1_phys=%0d rs1_val=%016h",
                        trace_cycle,
                        u_core.u_lsu.load_issue_data[0].rob_idx,
                        u_core.u_lsu.load_issue_data[0].pdst,
                        u_core.u_lsu.load_issue_data[0].pc,
                        u_core.u_lsu.load_eff_addr[0],
                        u_core.u_lsu.load_addr_misaligned[0],
                        u_core.u_lsu.flush_in.valid,
                        u_core.u_lsu.load_issue_data[0].rs1_phys,
                        u_core.u_int_prf.regfile_copy0[u_core.u_lsu.load_issue_data[0].rs1_phys]);
                end
            end
            // Stage _r
            if (u_core.u_lsu.load_issue_data_r[0].valid) begin
                lsu_r_cyc[u_core.u_lsu.load_issue_data_r[0].rob_idx] <= 32'(trace_cycle);
            end
            // Stage _rr
            if (u_core.u_lsu.load_issue_data_rr[0].valid) begin
                lsu_rr_cyc[u_core.u_lsu.load_issue_data_rr[0].rob_idx] <= 32'(trace_cycle);
            end
            // Dcache response
            if (u_core.u_lsu.dcache_load_resp_valid[0] && u_core.u_lsu.load_issue_data_rr[0].valid) begin
                lsu_dcresp_cyc[u_core.u_lsu.load_issue_data_rr[0].rob_idx] <= 32'(trace_cycle);
            end
            // Writeback (load_wb_valid[0])
            if (u_core.u_lsu.load_wb_valid[0]) begin
                lsu_wb_cyc[u_core.u_lsu.load_wb_rob_idx[0]] <= 32'(trace_cycle);
            end
        end
    end

    // P3+P7+P8+P9+P10. Reverse dep-chain walk + full pipeline census at WDOG.
    // Fires on cycle watchdog value 61 (one before fire, to capture pre-fire state).
    logic [PHYS_REG_BITS-1:0] chain_pdst [0:15];
    int chain_len;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            chain_len <= 0;
        end else if (trace_commit_en && (u_core.u_rob.rob_head_watchdog == 12'd61)) begin
            automatic logic [ROB_IDX_BITS-1:0] head_rob = u_core.u_rob.head_r;
            automatic logic [63:0] head_pc = u_core.rob_head_pc[0];
            automatic logic [PHYS_REG_BITS-1:0] cur_pdst;
            automatic int producer_rob;
            automatic logic found;

            $display("");
            $display("============================================================");
            $display("[WDOG_CHAIN] cyc=%0d stuck head rob=%0d pc=%016h",
                trace_cycle, head_rob, head_pc);

            // The stuck head's own operand info
            if (insn_info[head_rob].valid) begin
                $display("  HEAD LSU trace: issued=%0d r=%0d rr=%0d dcresp=%0d wb=%0d",
                    lsu_issued_cyc[head_rob],
                    lsu_r_cyc[head_rob],
                    lsu_rr_cyc[head_rob],
                    lsu_dcresp_cyc[head_rob],
                    lsu_wb_cyc[head_rob]);
                $display("  HEAD insn_info: rd_arch=%0d pdst=%0d rs1_phys=%0d rs2_phys=%0d rs1_arch=%0d rs2_arch=%0d rs1v=%b rs2v=%b is_load=%b is_store=%b cyc_ren=%0d cyc_bc=%0d",
                    insn_info[head_rob].rd_arch,
                    insn_info[head_rob].pdst,
                    insn_info[head_rob].rs1_phys,
                    insn_info[head_rob].rs2_phys,
                    insn_info[head_rob].rs1_arch,
                    insn_info[head_rob].rs2_arch,
                    insn_info[head_rob].rs1_valid,
                    insn_info[head_rob].rs2_valid,
                    insn_info[head_rob].is_load,
                    insn_info[head_rob].is_store,
                    insn_info[head_rob].cyc_renamed,
                    insn_info[head_rob].cyc_broadcast);
                $display("  HEAD ready: preg_rdy[pdst=%0d]=%b preg_rdy[rs1_phys=%0d]=%b preg_rdy[rs2_phys=%0d]=%b",
                    insn_info[head_rob].pdst,
                    u_core.preg_ready_table[insn_info[head_rob].pdst],
                    insn_info[head_rob].rs1_phys,
                    u_core.preg_ready_table[insn_info[head_rob].rs1_phys],
                    insn_info[head_rob].rs2_phys,
                    u_core.preg_ready_table[insn_info[head_rob].rs2_phys]);
            end else begin
                $display("  HEAD insn_info not valid — no snapshot available");
            end

            // Walk chain: follow first unready rs_phys back through producers
            if (insn_info[head_rob].valid && insn_info[head_rob].rs1_valid
                && !u_core.preg_ready_table[insn_info[head_rob].rs1_phys]) begin
                cur_pdst = insn_info[head_rob].rs1_phys;
            end else if (insn_info[head_rob].valid && insn_info[head_rob].rs2_valid
                && !u_core.preg_ready_table[insn_info[head_rob].rs2_phys]) begin
                cur_pdst = insn_info[head_rob].rs2_phys;
            end else begin
                cur_pdst = 0;
            end

            for (int hop = 0; hop < 16; hop++) begin
                if (cur_pdst == 0) break;
                // Find producer
                producer_rob = -1;
                found = 1'b0;
                for (int k = 0; k < ROB_DEPTH; k++) begin
                    if (insn_info[k].valid && insn_info[k].rd_valid
                        && insn_info[k].pdst == cur_pdst
                        && !found) begin
                        producer_rob = k;
                        found = 1'b1;
                    end
                end
                if (!found) begin
                    $display("  [HOP %0d] pdst=%0d  ** ORPHAN — no producer in insn_info **",
                        hop, cur_pdst);
                    break;
                end
                $display("  [HOP %0d] pdst=%0d producer rob=%0d pc=%016h rd_arch=%0d rs1_phys=%0d(rdy=%b) rs2_phys=%0d(rdy=%b) cyc_ren=%0d cyc_bc=%0d load=%b",
                    hop, cur_pdst, producer_rob,
                    insn_info[producer_rob].pc,
                    insn_info[producer_rob].rd_arch,
                    insn_info[producer_rob].rs1_phys,
                    u_core.preg_ready_table[insn_info[producer_rob].rs1_phys],
                    insn_info[producer_rob].rs2_phys,
                    u_core.preg_ready_table[insn_info[producer_rob].rs2_phys],
                    insn_info[producer_rob].cyc_renamed,
                    insn_info[producer_rob].cyc_broadcast,
                    insn_info[producer_rob].is_load);
                // Next hop: pick producer's first unready source
                if (insn_info[producer_rob].rs1_valid
                    && !u_core.preg_ready_table[insn_info[producer_rob].rs1_phys]) begin
                    cur_pdst = insn_info[producer_rob].rs1_phys;
                end else if (insn_info[producer_rob].rs2_valid
                    && !u_core.preg_ready_table[insn_info[producer_rob].rs2_phys]) begin
                    cur_pdst = insn_info[producer_rob].rs2_phys;
                end else begin
                    $display("  [HOP %0d+1] producer's sources all ready — producer stuck in pipeline (LSU/FU)",
                        hop);
                    // P7: If producer is load, dump LSU state
                    if (insn_info[producer_rob].is_load) begin
                        $display("    [LSU_DUMP] producer is LOAD at rob=%0d — check LQ/dcache below",
                            producer_rob);
                    end
                    cur_pdst = 0;
                end
            end

            // P10: scan all IQs for the final cur_pdst (if still walking)
            $display("  [IQ_CENSUS] scanning IQ0/IQ1/IQ2/LD/ST for stuck-chain pdsts:");
            for (int e = 0; e < 32; e++) begin
                automatic iq_entry_t e0, e1, e2, el, es;
                e0 = iq_entry_t'(u_core.u_iq0.payload_r[e]);
                e1 = iq_entry_t'(u_core.u_iq1.payload_r[e]);
                e2 = iq_entry_t'(u_core.u_iq2.payload_r[e]);
                el = iq_entry_t'(u_core.u_iq_load.payload_r[e]);
                es = iq_entry_t'(u_core.u_iq_store.payload_r[e]);
                if (u_core.u_iq0.entry_valid[e])
                    $display("    IQ0[%0d] rob=%0d pdst=%0d fu=%0d s1=%b s2=%b",
                        e, u_core.u_iq0.rob_idx_r[e], e0.pdst, e0.fu_type,
                        u_core.u_iq0.src1_ready[e], u_core.u_iq0.src2_ready[e]);
                if (u_core.u_iq1.entry_valid[e])
                    $display("    IQ1[%0d] rob=%0d pdst=%0d fu=%0d s1=%b s2=%b",
                        e, u_core.u_iq1.rob_idx_r[e], e1.pdst, e1.fu_type,
                        u_core.u_iq1.src1_ready[e], u_core.u_iq1.src2_ready[e]);
                if (u_core.u_iq2.entry_valid[e])
                    $display("    IQ2[%0d] rob=%0d pdst=%0d fu=%0d s1=%b s2=%b",
                        e, u_core.u_iq2.rob_idx_r[e], e2.pdst, e2.fu_type,
                        u_core.u_iq2.src1_ready[e], u_core.u_iq2.src2_ready[e]);
                if (u_core.u_iq_load.entry_valid[e])
                    $display("    IQLD[%0d] rob=%0d pdst=%0d s1=%b s2=%b",
                        e, u_core.u_iq_load.rob_idx_r[e], el.pdst,
                        u_core.u_iq_load.src1_ready[e], u_core.u_iq_load.src2_ready[e]);
                if (u_core.u_iq_store.entry_valid[e])
                    $display("    IQST[%0d] rob=%0d pdst=%0d s1=%b s2=%b",
                        e, u_core.u_iq_store.rob_idx_r[e], es.pdst,
                        u_core.u_iq_store.src1_ready[e], u_core.u_iq_store.src2_ready[e]);
            end

            // P2 echo: recent CDB broadcasts
            $display("  [CDB_RECENT] last 16 CDB events:");
            for (int r = 0; r < 16; r++) begin
                automatic logic [7:0] idx = cdb_ring_head - 8'd1 - 8'(r);
                if (cdb_ring[idx].cyc != 0) begin
                    $display("    [%0d] cyc=%0d pdst=%0d",
                        r, cdb_ring[idx].cyc, cdb_ring[idx].pdst);
                end
            end

            // P9. Dispatch queue census — check if stuck load is stuck in DQ.
            $display("  [DQ_CENSUS] int head=%0d tail=%0d count=%0d / mem head=%0d tail=%0d count=%0d",
                u_core.u_dispatch_queue.int_head, u_core.u_dispatch_queue.int_tail, u_core.u_dispatch_queue.int_count,
                u_core.u_dispatch_queue.mem_head, u_core.u_dispatch_queue.mem_tail, u_core.u_dispatch_queue.mem_count);
            // Dump mem FIFO contents (memory queue where loads/stores wait)
            begin : mem_fifo_dump
                automatic renamed_insn_t ri;
                for (int k = 0; k < 32; k++) begin
                    ri = renamed_insn_t'(u_core.u_dispatch_queue.mem_fifo_flat[k]);
                    if (ri.base.valid && (ri.base.is_load || ri.base.is_store)) begin
                        $display("    DQ_MEM[%0d] rob=%0d pc=%016h is_load=%b is_store=%b rs1_phys=%0d pdst=%0d",
                            k, ri.rob_idx, ri.base.pc,
                            ri.base.is_load, ri.base.is_store,
                            ri.rs1_phys, ri.pdst);
                    end
                end
            end
            // P7. Load Queue full census — find where stuck head lives.
            $display("  [LQ_CENSUS] all valid LQ entries:");
            for (int q = 0; q < LQ_DEPTH; q++) begin
                if (u_core.u_lsu.u_load_queue.queue[q].valid) begin
                    $display("    LQ[%0d] rob=%0d pdst=%0d addr=%016h addr_valid=%b executed=%b has_result=%b",
                        q,
                        u_core.u_lsu.u_load_queue.queue[q].rob_idx,
                        u_core.u_lsu.u_load_queue.queue[q].pdst,
                        u_core.u_lsu.u_load_queue.queue[q].addr,
                        u_core.u_lsu.u_load_queue.queue[q].addr_valid,
                        u_core.u_lsu.u_load_queue.queue[q].executed,
                        u_core.u_lsu.u_load_queue.queue[q].has_result);
                end
            end
            // Dcache state snapshot
            $display("  [DC_STATE_WDOG] s1_st_v=%b wait_fill=%b hit=%b l2_state=%0d mshr0_v=%b mshr0_fp=%b mshr0_fd=%b",
                u_core.u_dcache.s1_st_valid,
                u_core.u_dcache.s1_st_waiting_for_fill,
                u_core.u_dcache.st_cache_hit,
                u_core.u_dcache.l2_state_q,
                u_core.u_dcache.mshr[0].valid,
                u_core.u_dcache.mshr[0].fill_pend,
                u_core.u_dcache.mshr[0].fill_done);

            // ROB head flags
            $display("  [ROB_HEAD_FLAGS] rob=%0d valid=%b ready=%b is_load=%b is_store=%b has_exc=%b",
                head_rob,
                u_core.u_rob.valid_r[head_rob],
                u_core.u_rob.ready_r[head_rob],
                u_core.u_rob.is_load_r[head_rob],
                u_core.u_rob.is_store_r[head_rob],
                u_core.u_rob.has_exc_r[head_rob]);

            // LSU load_issue_data pipeline registers
            $display("  [LSU_ISSUE_R0] valid=%b rob=%0d pdst=%0d",
                u_core.u_lsu.load_issue_data_r[0].valid,
                u_core.u_lsu.load_issue_data_r[0].rob_idx,
                u_core.u_lsu.load_issue_data_r[0].pdst);
            $display("  [LSU_ISSUE_R1] valid=%b rob=%0d pdst=%0d",
                u_core.u_lsu.load_issue_data_r[1].valid,
                u_core.u_lsu.load_issue_data_r[1].rob_idx,
                u_core.u_lsu.load_issue_data_r[1].pdst);
            $display("  [LSU_ISSUE_RR0] valid=%b rob=%0d pdst=%0d",
                u_core.u_lsu.load_issue_data_rr[0].valid,
                u_core.u_lsu.load_issue_data_rr[0].rob_idx,
                u_core.u_lsu.load_issue_data_rr[0].pdst);
            $display("  [LSU_ISSUE_RR1] valid=%b rob=%0d pdst=%0d",
                u_core.u_lsu.load_issue_data_rr[1].valid,
                u_core.u_lsu.load_issue_data_rr[1].rob_idx,
                u_core.u_lsu.load_issue_data_rr[1].pdst);

            // LMB (load miss buffer) — loads stuck waiting for cache fill
            $display("  [LMB_CENSUS] entries waiting for fill:");
            for (int m = 0; m < 8; m++) begin
                if (u_core.u_lsu.lmb[m].valid) begin
                    $display("    LMB[%0d] rob=%0d pdst=%0d line_addr=%016h byte_off=%0d",
                        m,
                        u_core.u_lsu.lmb[m].rob_idx,
                        u_core.u_lsu.lmb[m].pdst,
                        u_core.u_lsu.lmb[m].line_addr,
                        u_core.u_lsu.lmb[m].byte_offset);
                end
            end

            $display("============================================================");
            $display("");
        end
    end

endmodule

/* file: tb_xsim.sv
 Description: Self-contained top for Vivado xsim simulation (xvlog/xelab/xsim).
              Generates clk/rst, loads hex, monitors tohost, reports IPC.
              Renamed 2026-04-17 from tb_iverilog.sv — iverilog was abandoned
              due to SystemVerilog struct-array support gaps; xsim is the
              authoritative simulator.
 Author: Jeremy Cai
 Date: Apr. 13, 2026
 Version: 1.1
*/
`timescale 1ns/1ps

module tb_xsim;
    import rv64gc_pkg::*;

    logic        clk;
    logic        rst_n;
    logic        tohost_valid;
    logic [63:0] tohost_value;
    logic [63:0] perf_mcycle;
    logic [63:0] perf_minstret;

    // Clock: 10 ns period (5 ns half)
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // Reset: assert for 20 cycles then deassert
    initial begin
        rst_n = 1'b0;
        repeat (40) @(posedge clk);
        rst_n = 1'b1;
    end

    // DUT
    tb_top u_tb (
        .clk            (clk),
        .rst_n          (rst_n),
        .tohost_valid   (tohost_valid),
        .tohost_value   (tohost_value),
        .perf_mcycle    (perf_mcycle),
        .perf_minstret  (perf_minstret)
    );

    // VCD dump (optional, controlled by +VCD_FOCUSED or +VCD_FULL)
    // NOTE: $test$plusargs does PREFIX matching, so "VCD_FOCUSED" must be
    // checked before "VCD_FULL" (and neither can be "VCD" alone, which
    // would shadow both).
    // +VCD_FULL    — full hierarchy (large; use only for short runs)
    // +VCD_FOCUSED — only the partial-replay-relevant signals (smaller)
    initial begin
        if ($test$plusargs("VCD_FOCUSED")) begin
            $dumpfile("iv_sim_focused.vcd");
            // Core-level signals (partial-replay bus, flush, commit)
            $dumpvars(0, u_tb.u_core.replay_valid);
            $dumpvars(0, u_tb.u_core.replay_rob_idx_from);
            $dumpvars(0, u_tb.u_core.lsu_ordering_violation);
            $dumpvars(0, u_tb.u_core.lsu_violation_rob_idx);
            $dumpvars(0, u_tb.u_core.flush_out);
            $dumpvars(0, u_tb.u_core.commit_count);
            $dumpvars(0, u_tb.u_core.cdb_valid);
            $dumpvars(0, u_tb.u_core.cdb_tag);
            // ROB head/tail
            $dumpvars(0, u_tb.u_core.u_rob.head_r);
            $dumpvars(0, u_tb.u_core.u_rob.tail_r);
            $dumpvars(0, u_tb.u_core.u_rob.count_r);
            $dumpvars(0, u_tb.u_core.u_rob.rob_head_watchdog);
            // LSU issue + ordering_violation source
            $dumpvars(0, u_tb.u_core.u_lsu.load_issue_valid);
            $dumpvars(0, u_tb.u_core.u_lsu.ordering_violation);
            $dumpvars(0, u_tb.u_core.u_lsu.violation_rob_idx);
        end else if ($test$plusargs("VCD_FULL")) begin
            $dumpfile("iv_sim_full.vcd");
            $dumpvars(0, tb_xsim);
        end
    end

    // Cycle counter and max cycles
    integer sim_cycle;
    integer max_cycles;
    initial begin
        sim_cycle  = 0;
        max_cycles = 100000;  // default
        if (!$value$plusargs("MAX_CYCLES=%d", max_cycles))
            max_cycles = 100000;
    end

    // Memory-dependence profiler (+MEMDEP_PROFILE): sizes the store-set /
    // load-disambiguation-speculation lever.  Counts how often a load is blocked
    // by an older store's ordering wait (sq_order_wait_block), specifically the
    // unknown-store-address case (sq_fwd_wait_addr_unknown = the speculation
    // opportunity, since load_issue_spec_past_addr_unknown is hardwired 0), and
    // how much that OVERLAPS the HEAD_WAIT wall (head valid but not ready).
    logic        md_en;
    logic [63:0] md_total, md_headwait, md_sqblock, md_addrunk, md_sqblock_hw, md_addrunk_hw;
    initial begin
        md_en = $test$plusargs("MEMDEP_PROFILE");
        md_total=0; md_headwait=0; md_sqblock=0; md_addrunk=0; md_sqblock_hw=0; md_addrunk_hw=0;
    end
    task automatic print_memdep;
        if (md_en && md_total != 0) begin
            $display("[MEMDEP] total=%0d headwait=%0d sqblock=%0d addrunk=%0d sqblock&hw=%0d addrunk&hw=%0d",
                     md_total, md_headwait, md_sqblock, md_addrunk, md_sqblock_hw, md_addrunk_hw);
            $display("[MEMDEP] %%of-total: headwait=%.2f sqblock=%.2f addrunk=%.2f sqblock&hw=%.2f addrunk&hw=%.2f",
                     100.0*md_headwait/md_total, 100.0*md_sqblock/md_total, 100.0*md_addrunk/md_total,
                     100.0*md_sqblock_hw/md_total, 100.0*md_addrunk_hw/md_total);
        end
    endtask

    // Commit-PC / trap sampler (+PC_SAMPLE): prints the last committed PC every
    // 100K cycles plus the first 20 trap events (cause/epc/tvec).  Sim-only,
    // plusarg-gated, inert by default.  Built to settle where a workload
    // actually executes (kernel vs trap loop vs reboot loop).
    logic        pcs_en;
    logic [63:0] pcs_last_pc;
    logic [63:0] pcs_commits;
    logic [63:0] pcs_hash;
    longint      pcs_ivl;
    logic [63:0] pcs_llf, pcs_llt, pcs_wl, pcs_wl_lastrd, pcs_sf, pcs_st;
    integer      pcs_traps;
    initial begin
        pcs_en = $test$plusargs("PC_SAMPLE");
        if (!$value$plusargs("PC_SAMPLE_IVL=%d", pcs_ivl)) pcs_ivl = 1000000;
        if (!$value$plusargs("LOAD_LOG_FROM=%d", pcs_llf)) pcs_llf = 64'hFFFFFFFFFFFFFFFF;
        if (!$value$plusargs("LOAD_LOG_TO=%d", pcs_llt))   pcs_llt = 64'h0;
        if (!$value$plusargs("WATCH_LINE=%h", pcs_wl))     pcs_wl  = 64'hFFFFFFFFFFFFFFFF;
        if (!$value$plusargs("SNOOP_FROM=%d", pcs_sf))    pcs_sf  = 64'hFFFFFFFFFFFFFFFF;
        if (!$value$plusargs("SNOOP_TO=%d", pcs_st))      pcs_st  = 64'h0;
        pcs_last_pc = '0; pcs_commits = 0; pcs_traps = 0; pcs_hash = 64'hcbf29ce484222325;
    end

    always @(posedge clk) begin
        sim_cycle <= sim_cycle + 1;

        if (rst_n && pcs_en) begin
            if (u_tb.u_core.commit_count != 0) begin
                automatic logic [63:0] h = pcs_hash;
                automatic logic [63:0] n = pcs_commits;
                for (int ci = 0; ci < 4; ci++) begin
                    if (ci < int'(u_tb.u_core.commit_count)) begin
                        pcs_last_pc <= u_tb.u_core.rob_head_pc[ci];
                        // running PC hash: instret-aligned divergence finder
                        h = h * 64'd1099511628211 + u_tb.u_core.rob_head_pc[ci];
                        n = n + 1;
                        if ((n % pcs_ivl) == 0)
                            $display("[PCS-H] instret=%0d hash=%0h pc=%0h cyc=%0d",
                                     n, h, u_tb.u_core.rob_head_pc[ci], sim_cycle);
                    end
                end
                pcs_hash    <= h;
                pcs_commits <= n;
            end
            if (u_tb.u_core.u_csr_file.trap_valid && pcs_traps < 20) begin
                pcs_traps <= pcs_traps + 1;
                $display("[PCS-TRAP] cyc=%0d cause=%0h epc=%0h tvec=%0h",
                         sim_cycle, u_tb.u_core.u_csr_file.trap_cause,
                         u_tb.u_core.u_csr_file.trap_pc,
                         u_tb.u_core.u_csr_file.mtvec_r);
            end
            if (sim_cycle % 100000 == 0) begin
                $display("[PCS] cyc=%0d commits=%0d last_pc=%0h",
                         sim_cycle, pcs_commits, pcs_last_pc);
            end
            // Line-lifetime watcher (+WATCH_LINE=<hex line addr>): every tag
            // write to the line's set, every install selecting it or its set,
            // every store/load touching the line.  Exposes who clobbers a line.
            if (pcs_wl != 64'hFFFFFFFFFFFFFFFF) begin
                // tag writes to the watched set
                if (u_tb.u_core.u_dcache.tr_we &&
                    (u_tb.u_core.u_dcache.tr_waddr == pcs_wl[13:6]))
                    $display("[WL-TAGW] cyc=%0d set=%0h way=%0d wtag=%0h valid=%0b (lineaddr~%0h)",
                             sim_cycle, pcs_wl[13:6], u_tb.u_core.u_dcache.tr_wway,
                             u_tb.u_core.u_dcache.tr_wtag,
                             u_tb.u_core.u_dcache.tr_wvalid,
                             {u_tb.u_core.u_dcache.tr_wtag, pcs_wl[13:6], 6'b0});
                // installs (fill or nwa-validate) whose MSHR line is the watched line
                if (u_tb.u_core.u_dcache.fill_done_avail &&
                    (u_tb.u_core.u_dcache.mshr[u_tb.u_core.u_dcache.fill_done_idx].addr[63:6] == pcs_wl[63:6]))
                    $display("[WL-FILLINST] cyc=%0d idx=%0d victim=%0d",
                             sim_cycle, u_tb.u_core.u_dcache.fill_done_idx,
                             u_tb.u_core.u_dcache.mshr[u_tb.u_core.u_dcache.fill_done_idx].victim);
                if (u_tb.u_core.u_dcache.nwa_validate_avail &&
                    (u_tb.u_core.u_dcache.mshr[u_tb.u_core.u_dcache.nwa_validate_idx].addr[63:6] == pcs_wl[63:6]))
                    $display("[WL-NWAINST] cyc=%0d idx=%0d victim=%0d",
                             sim_cycle, u_tb.u_core.u_dcache.nwa_validate_idx,
                             u_tb.u_core.u_dcache.mshr[u_tb.u_core.u_dcache.nwa_validate_idx].victim);
                // stores/loads touching the watched line
                if (u_tb.u_core.u_dcache.s1_st_valid &&
                    (u_tb.u_core.u_dcache.s1_st_addr[63:6] == pcs_wl[63:6]))
                    $display("[WL-ST] cyc=%0d a=%0h hit=%0b ack=%0b nwa_acc=%0b d=%0h",
                             sim_cycle, u_tb.u_core.u_dcache.s1_st_addr,
                             u_tb.u_core.u_dcache.st_cache_hit,
                             u_tb.u_core.u_dcache.store_ack_s1,
                             u_tb.u_core.u_dcache.nwa_store_accept,
                             u_tb.u_core.u_dcache.s1_st_data);
                if (u_tb.u_core.u_dcache.load_resp_valid[0] &&
                    (u_tb.u_core.u_dcache.s1_ld0_addr[63:6] == pcs_wl[63:6]))
                    $display("[WL-LD] cyc=%0d a=%0h d=%0h",
                             sim_cycle, u_tb.u_core.u_dcache.s1_ld0_addr,
                             u_tb.u_core.u_dcache.load_resp_data[0]);
                // ground truth: every L1->L2 write of the watched line, with
                // the qword at offset 0x30 (the z_stream next_in slot)
                if (u_tb.u_core.u_dcache.l2_req_valid &&
                    u_tb.u_core.u_dcache.l2_req_we &&
                    (u_tb.u_core.u_dcache.l2_req_addr[63:6] == pcs_wl[63:6]))
                    $display("[WL-L2W] cyc=%0d a=%0h q30=%0h q00=%0h",
                             sim_cycle, u_tb.u_core.u_dcache.l2_req_addr,
                             u_tb.u_core.u_dcache.l2_req_wdata[384 +: 64],
                             u_tb.u_core.u_dcache.l2_req_wdata[63:0]);
                // and the WT enqueue/merge events for the watched line
                if (u_tb.u_core.u_dcache.st_wt_enq_valid &&
                    (u_tb.u_core.u_dcache.st_wt_enq_addr[63:6] == pcs_wl[63:6]))
                    $display("[WL-WTENQ] cyc=%0d a=%0h full=%0b merge=%0b push=%0b q30=%0h",
                             sim_cycle, u_tb.u_core.u_dcache.st_wt_enq_addr,
                             u_tb.u_core.u_dcache.st_wt_enq_full_line,
                             u_tb.u_core.u_dcache.st_wt_merge_fire,
                             u_tb.u_core.u_dcache.st_wt_push_fire,
                             u_tb.u_core.u_dcache.st_wt_push_data[384 +: 64]);
                // L2 <-> memory boundary for the watched line: evict writes
                // (L2->mem) and refills (mem->L2)
                if (u_tb.u_core.u_l2_cache.mem_req_valid &&
                    (u_tb.u_core.u_l2_cache.mem_req_addr[63:6] == pcs_wl[63:6]))
                    $display("[WL-MEMRQ] cyc=%0d we=%0b a=%0h q30=%0h",
                             sim_cycle, u_tb.u_core.u_l2_cache.mem_req_we,
                             u_tb.u_core.u_l2_cache.mem_req_addr,
                             u_tb.u_core.u_l2_cache.mem_req_wdata[384 +: 64]);
                // memory responses carry no address: pair with the last read req
                if (u_tb.u_core.u_l2_cache.mem_req_valid &&
                    !u_tb.u_core.u_l2_cache.mem_req_we)
                    pcs_wl_lastrd <= u_tb.u_core.u_l2_cache.mem_req_addr;
                if (u_tb.u_core.u_l2_cache.mem_resp_valid &&
                    (pcs_wl_lastrd[63:6] == pcs_wl[63:6]))
                    $display("[WL-MEMRSP] cyc=%0d a~%0h q30=%0h",
                             sim_cycle, pcs_wl_lastrd,
                             u_tb.u_core.u_l2_cache.mem_resp_data[384 +: 64]);
                // L2 response back to L1 for the watched line (what L1 receives)
                if (u_tb.u_core.u_dcache.l2_resp_valid &&
                    (u_tb.u_core.u_dcache.l2_resp_addr[63:6] == pcs_wl[63:6]))
                    $display("[WL-L2RSP] cyc=%0d a=%0h q30=%0h",
                             sim_cycle, u_tb.u_core.u_dcache.l2_resp_data[384 +: 64],
                             u_tb.u_core.u_dcache.l2_resp_addr);
                // ALL fill_snoop broadcasts in a cycle window (+SNOOP_FROM/TO):
                // shows what woke the LMB load, incl. source mux state
                if (sim_cycle >= pcs_sf && sim_cycle <= pcs_st &&
                    u_tb.u_core.u_dcache.fill_snoop_valid)
                    $display("[WL-SNOOP] cyc=%0d a=%0h fd=%0b nv=%0b q30=%0h",
                             sim_cycle,
                             u_tb.u_core.u_dcache.fill_snoop_addr,
                             u_tb.u_core.u_dcache.fill_done_avail,
                             u_tb.u_core.u_dcache.nwa_validate_avail,
                             u_tb.u_core.u_dcache.fill_snoop_data[384 +: 64]);
            end
            // Windowed D-cache load logger (+LOAD_LOG_FROM/+LOAD_LOG_TO, instret
            // window): prints every dcache load response with address+data.
            // Diffing two deterministic arms names the first corrupted load.
            if (pcs_commits >= pcs_llf && pcs_commits <= pcs_llt) begin
                if (u_tb.u_core.u_dcache.load_resp_valid[0])
                    $display("[LDLOG] i=%0d cyc=%0d a=%0h d=%0h",
                             pcs_commits, sim_cycle,
                             u_tb.u_core.u_dcache.s1_ld0_addr,
                             u_tb.u_core.u_dcache.load_resp_data[0]);
                if (u_tb.u_core.u_dcache.load_resp_valid[1])
                    $display("[LDLOG] i=%0d cyc=%0d a=%0h d=%0h",
                             pcs_commits, sim_cycle,
                             u_tb.u_core.u_dcache.s1_ld1_addr,
                             u_tb.u_core.u_dcache.load_resp_data[1]);
            end
        end

        if (rst_n && md_en) begin
            md_total <= md_total + 1;
            if (u_tb.u_core.backend_admission_head_block) md_headwait <= md_headwait + 1;
            if (u_tb.u_core.u_lsu.p0_sq_order_wait_block ||
                u_tb.u_core.u_lsu.p1_sq_order_wait_block) md_sqblock <= md_sqblock + 1;
            if (u_tb.u_core.u_lsu.sq_fwd_wait_addr_unknown) md_addrunk <= md_addrunk + 1;
            if ((u_tb.u_core.u_lsu.p0_sq_order_wait_block ||
                 u_tb.u_core.u_lsu.p1_sq_order_wait_block) &&
                u_tb.u_core.backend_admission_head_block) md_sqblock_hw <= md_sqblock_hw + 1;
            if (u_tb.u_core.u_lsu.sq_fwd_wait_addr_unknown &&
                u_tb.u_core.backend_admission_head_block) md_addrunk_hw <= md_addrunk_hw + 1;
        end

        // Periodic progress
        if (sim_cycle > 0 && (sim_cycle % 10000) == 0) begin
            $display("... cycle %0d  mcycle=%0d minstret=%0d",
                     sim_cycle, perf_mcycle, perf_minstret);
        end

        // Tohost check
        if (tohost_valid) begin
            if (tohost_value == 64'd0 || tohost_value == 64'd1) begin
                $display("%s at cycle %0d (tohost=%0d)",
                         (tohost_value == 64'd1) ? "PASS" : "FAIL",
                         sim_cycle, tohost_value);
            end else begin
                $display("TOHOST=%0h at cycle %0d", tohost_value, sim_cycle);
            end
            $display("IPC: mcycle=%0d minstret=%0d IPC=%f",
                     perf_mcycle, perf_minstret,
                     $itor(perf_minstret) / $itor(perf_mcycle));
            print_memdep;
            $finish;
        end

        // Timeout
        if (sim_cycle >= max_cycles) begin
            $display("TIMEOUT after %0d cycles", sim_cycle);
            $display("IPC: mcycle=%0d minstret=%0d IPC=%f",
                     perf_mcycle, perf_minstret,
                     $itor(perf_minstret) / $itor(perf_mcycle));
            print_memdep;
            $finish;
        end
    end

endmodule

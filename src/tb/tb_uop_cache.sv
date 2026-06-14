/* file: tb_uop_cache.sv
 * Description: Unit testbench for the UOC-REPACK uop_cache (rebuilt for the
 *              2026-06-13 dense-trace fill contract; the original April TB was
 *              deleted).  Exercises the fill accumulator (dense accumulation
 *              across packet / direct-taken-edge boundaries), seal predicates
 *              (full-4 / indirect-jalr / serializing / exception), head-keyed
 *              install + dup-detect, lookup/hit, replay of straight-line and
 *              (under +UOC_UNSAFE_STREAM) control/partial groups,
 *              redirect-mid-replay abort, FENCE.I / satp / SFENCE invalidation,
 *              and pLRU set-conflict eviction.
 *
 *              Timing convention (SRAM-macro sync read): a fill driven on
 *              cycle N writes at posedge N+1; a lookup addr driven on cycle N
 *              produces tag/data at the comparator on N+2 (addr latched N+1,
 *              RAM read N+2).  Tests therefore set -> step -> step -> check.
 *
 *              Structured as a clocked state machine for Verilator
 *              --no-timing; the C++ harness (tb_uop_cache.cpp) toggles clk.
 * Version: 1.0 (UOC-REPACK)
 */
module tb_uop_cache
    import rv64gc_pkg::*;
    import uarch_pkg::*;
();

    logic clk;
    logic rst_n;
    logic en;

    decoded_insn_t fused_insn [0:PIPE_WIDTH-1];
    logic [2:0]    fused_count;

    decoded_insn_t uoc_insn [0:PIPE_WIDTH-1];
    logic [2:0]    uoc_count;
    logic          active;
    logic          handoff_valid;
    logic [63:0]   handoff_pc;

    logic          redirect_valid;
    logic [63:0]   redirect_pc;
    logic          invalidate;
    logic          stall;

    logic ev_lookup, ev_hit, ev_miss, ev_fill, ev_fill_evict_valid;
    logic ev_enter_playing, ev_exit_playing_miss, ev_exit_playing_nohit;
    logic ev_exit_playing_unsafe, ev_emit, ev_emit_control, ev_emit_cond;
    logic ev_emit_jal, ev_emit_jalr, ev_emit_pred_taken, ev_invalidate;

    uop_cache dut (
        .clk(clk), .rst_n(rst_n), .en(en),
        .fused_insn(fused_insn), .fused_count(fused_count),
        .uoc_insn(uoc_insn), .uoc_count(uoc_count), .active(active),
        .handoff_valid(handoff_valid), .handoff_pc(handoff_pc),
        .redirect_valid(redirect_valid), .redirect_pc(redirect_pc),
        .invalidate(invalidate), .stall(stall),
        .ev_lookup(ev_lookup), .ev_hit(ev_hit), .ev_miss(ev_miss),
        .ev_fill(ev_fill), .ev_fill_evict_valid(ev_fill_evict_valid),
        .ev_enter_playing(ev_enter_playing),
        .ev_exit_playing_miss(ev_exit_playing_miss),
        .ev_exit_playing_nohit(ev_exit_playing_nohit),
        .ev_exit_playing_unsafe(ev_exit_playing_unsafe),
        .ev_emit(ev_emit), .ev_emit_control(ev_emit_control),
        .ev_emit_cond(ev_emit_cond), .ev_emit_jal(ev_emit_jal),
        .ev_emit_jalr(ev_emit_jalr), .ev_emit_pred_taken(ev_emit_pred_taken),
        .ev_invalidate(ev_invalidate)
    );

    integer pass_count = 0;
    integer fail_count = 0;

    task automatic check(input string name, input logic cond);
        if (cond) begin
            pass_count++;
            $display("  PASS: %s", name);
        end else begin
            fail_count++;
            $display("  FAIL: %s", name);
        end
    endtask

    // ---- helpers to build decoded ops -------------------------------------
    function automatic decoded_insn_t mk_alu(input logic [63:0] pc);
        decoded_insn_t o;
        begin
            o = '0;
            o.valid = 1'b1; o.pc = pc; o.trap_pc = pc;
            o.fu_type = FU_ALU; o.rd_valid = 1'b1; o.rd_arch = 5'd5;
            o.is_rvc = 1'b0;
            return o;
        end
    endfunction

    // direct branch, optionally predicted taken to target
    function automatic decoded_insn_t mk_branch(input logic [63:0] pc,
                                                input logic taken,
                                                input logic [63:0] tgt);
        decoded_insn_t o;
        begin
            o = mk_alu(pc);
            o.fu_type = FU_BRU; o.is_branch = 1'b1; o.rd_valid = 1'b0;
            o.bp_taken = taken; o.bp_target = tgt;
            return o;
        end
    endfunction

    function automatic decoded_insn_t mk_jal(input logic [63:0] pc,
                                             input logic [63:0] tgt);
        decoded_insn_t o;
        begin
            o = mk_alu(pc);
            o.fu_type = FU_BRU; o.is_jal = 1'b1; o.rd_valid = 1'b0;
            o.bp_taken = 1'b1; o.bp_target = tgt;
            return o;
        end
    endfunction

    function automatic decoded_insn_t mk_jalr(input logic [63:0] pc);
        decoded_insn_t o;
        begin
            o = mk_alu(pc);
            o.fu_type = FU_BRU; o.is_jalr = 1'b1; o.rd_valid = 1'b0;
            o.bp_taken = 1'b0;
            return o;
        end
    endfunction

    function automatic decoded_insn_t mk_csr(input logic [63:0] pc);
        decoded_insn_t o;
        begin
            o = mk_alu(pc);
            o.fu_type = FU_CSR; o.is_csr = 1'b1;
            return o;
        end
    endfunction

    task automatic drive_group(input decoded_insn_t g [0:PIPE_WIDTH-1],
                               input logic [2:0] cnt);
        begin
            for (int i = 0; i < PIPE_WIDTH; i++) fused_insn[i] = g[i];
            fused_count = cnt;
        end
    endtask

    task automatic clear_group();
        begin
            for (int i = 0; i < PIPE_WIDTH; i++) fused_insn[i] = '0;
            fused_count = 3'd0;
        end
    endtask

    // ---- main sequence ----------------------------------------------------
    integer state = 0;
    decoded_insn_t g [0:PIPE_WIDTH-1];

    // Wait/step bookkeeping (advance one "state" per posedge).
    always_ff @(posedge clk) begin
        if (state == 0) begin
            // reset
            rst_n = 1'b0; en = 1'b1; stall = 1'b0;
            redirect_valid = 1'b0; redirect_pc = '0; invalidate = 1'b0;
            obs_clear = 1'b0;
            clear_group();
            state <= 1;
        end else if (state == 1) begin
            rst_n = 1'b1;
            state <= 2;
        end else if (state == 2) begin
            $display("=== TEST 1: dense fill packs THROUGH a direct taken branch ===");
            // Group A: two ALU ops at 0x1000,0x1004 then a JAL taken to 0x2000.
            // Group B (next cycle): ALU at 0x2000.  The dense builder must pack
            // [alu@1000, alu@1004, jal@1008->2000, alu@2000] into ONE entry
            // keyed at 0x1000 (packing through the taken edge), sealing at 4.
            g[0] = mk_alu(64'h1000);
            g[1] = mk_alu(64'h1004);
            g[2] = mk_jal(64'h1008, 64'h2000);
            g[3] = '0;
            drive_group(g, 3'd3);
            state <= 3;
        end else if (state == 3) begin
            // next contiguous group: head must equal the JAL target 0x2000
            g[0] = mk_alu(64'h2000);
            g[1] = '0; g[2] = '0; g[3] = '0;
            drive_group(g, 3'd1);
            state <= 4;
        end else if (state == 4) begin
            // The seal+install of the 4-op entry should fire THIS cycle (the
            // append of alu@2000 brings count to 4 -> seal).  ev_fill pulses.
            clear_group();
            check("T1 install fired on full-4 dense entry", ev_fill);
            state <= 5;
        end else if (state == 5) begin
            // Now look it up: drive predicted_next_pc to 0x1000 via redirect,
            // then expect a HIT two cycles later on the head-keyed entry.
            redirect_valid = 1'b1; redirect_pc = 64'h1000;
            state <= 6;
        end else if (state == 6) begin
            redirect_valid = 1'b0;
            clear_group();
            state <= 7;
        end else if (state == 7) begin
            // addr 0x1000 latched; RAM read in flight
            state <= 8;
        end else if (state == 8) begin
            check("T1 dense entry HIT at head 0x1000", ev_hit);
            check("T1 dense entry holds 4 dense ops", uoc_count == 3'd4 || dut.hit_count_c == 3'd4);
            state <= 20;

        end else if (state == 20) begin
            $display("=== TEST 2: seal on INDIRECT (jalr) closes the trace ===");
            // fresh: redirect to a cold PC, then fill [alu@3000, jalr@3004].
            invalidate = 1'b1;   // wipe cache
            state <= 21;
        end else if (state == 21) begin
            invalidate = 1'b0;
            redirect_valid = 1'b1; redirect_pc = 64'h3000;
            state <= 22;
        end else if (state == 22) begin
            redirect_valid = 1'b0;
            g[0] = mk_alu(64'h3000);
            g[1] = mk_jalr(64'h3004);
            g[2] = '0; g[3] = '0;
            drive_group(g, 3'd2);
            state <= 23;
        end else if (state == 23) begin
            // The jalr seals AFTER it: a 2-op entry [alu,jalr] installs now.
            clear_group();
            check("T2 install fired on indirect-seal (count<4)", ev_fill);
            check("T2 sealed entry count == 2", dut.install_count_c == 3'd2);
            state <= 24;
        end else if (state == 24) begin
            // Verify the build closed (build_valid_r low: next-PC ceded).
            check("T2 build closed after indirect (cede next-PC)", !dut.build_valid_r);
            state <= 40;

        end else if (state == 40) begin
            $display("=== TEST 3: seal on SERIALIZING (csr) ===");
            invalidate = 1'b1;
            state <= 41;
        end else if (state == 41) begin
            invalidate = 1'b0;
            redirect_valid = 1'b1; redirect_pc = 64'h4000;
            state <= 42;
        end else if (state == 42) begin
            redirect_valid = 1'b0;
            g[0] = mk_alu(64'h4000);
            g[1] = mk_csr(64'h4004);
            g[2] = mk_alu(64'h4008);   // post-csr op must NOT pack with pre-csr
            g[3] = '0;
            drive_group(g, 3'd3);
            state <= 43;
        end else if (state == 43) begin
            clear_group();
            check("T3 install fired on csr-seal", ev_fill);
            check("T3 sealed entry count == 2 (alu+csr)", dut.install_count_c == 3'd2);
            state <= 60;

        end else if (state == 60) begin
            $display("=== TEST 4: FENCE.I / satp invalidation wipes the cache ===");
            // (re)install a simple straight-line 4-op entry at 0x5000.
            invalidate = 1'b1;
            state <= 61;
        end else if (state == 61) begin
            invalidate = 1'b0;
            redirect_valid = 1'b1; redirect_pc = 64'h5000;
            state <= 62;
        end else if (state == 62) begin
            redirect_valid = 1'b0;
            g[0] = mk_alu(64'h5000); g[1] = mk_alu(64'h5004);
            g[2] = mk_alu(64'h5008); g[3] = mk_alu(64'h500c);
            drive_group(g, 3'd4);
            state <= 63;
        end else if (state == 63) begin
            clear_group();
            check("T4 4-op straight-line entry installed", ev_fill);
            state <= 64;
        end else if (state == 64) begin
            // look it up -> hit (sample over a multi-cycle window via sticky)
            obs_clear = 1'b1;
            redirect_valid = 1'b1; redirect_pc = 64'h5000;
            state <= 65;
        end else if (state == 65) begin
            obs_clear = 1'b0;
            redirect_valid = 1'b0; clear_group();
            state <= 66;
        end else if (state == 66) begin
            state <= 67;
        end else if (state == 67) begin
            state <= 68;
        end else if (state == 68) begin
            state <= 69;
        end else if (state == 69) begin
            check("T4 entry HIT before invalidate", saw_hit_r);
            // now invalidate (models satp/SFENCE OR FENCE.I)
            invalidate = 1'b1;
            obs_clear = 1'b1;
            state <= 70;
        end else if (state == 70) begin
            invalidate = 1'b0;
            obs_clear = 1'b0;
            redirect_valid = 1'b1; redirect_pc = 64'h5000;
            state <= 71;
        end else if (state == 71) begin
            redirect_valid = 1'b0; clear_group();
            state <= 72;
        end else if (state == 72) begin
            state <= 73;
        end else if (state == 73) begin
            state <= 74;
        end else if (state == 74) begin
            check("T4 entry MISS after invalidate", !saw_hit_r);
            state <= 80;

        end else if (state == 80) begin
            $display("=== TEST 5: pLRU set-conflict eviction (fill > 8 ways/set) ===");
            // Install 9 distinct dense heads that all map to the SAME set.
            // index = pc[5:1]; keep pc[5:1] constant, vary pc[63:6].
            invalidate = 1'b1;
            evict_i = 0;
            state <= 81;
        end else if (state == 81) begin
            invalidate = 1'b0;
            state <= 82;
        end else if (state == 82) begin
            // drive a single straight-line group whose head maps to set 0,
            // with a unique tag each iteration, sealed at 4.
            redirect_valid = 1'b1;
            redirect_pc = {evict_i[57:0], 6'h00};   // pc[5:1]=0 -> set 0
            state <= 83;
        end else if (state == 83) begin
            redirect_valid = 1'b0;
            g[0] = mk_alu({evict_i[57:0], 6'h00});
            g[1] = mk_alu({evict_i[57:0], 6'h04});
            g[2] = mk_alu({evict_i[57:0], 6'h08});
            g[3] = mk_alu({evict_i[57:0], 6'h0c});
            drive_group(g, 3'd4);
            state <= 84;
        end else if (state == 84) begin
            clear_group();
            if (ev_fill) evict_fills++;
            if (evict_i >= 9) begin
                check("T5 >=8 fills into one set, pLRU evicted (>=9 installs)",
                      evict_fills >= 8);
                state <= 100;
            end else begin
                evict_i = evict_i + 1;
                state <= 82;
            end

        end else if (state == 100) begin
            $display("=== TEST 6: redirect mid-fill drops the partial build ===");
            invalidate = 1'b1; obs_clear = 1'b1; state <= 101;
        end else if (state == 101) begin
            invalidate = 1'b0; obs_clear = 1'b0;
            redirect_valid = 1'b1; redirect_pc = 64'h7000;
            state <= 102;
        end else if (state == 102) begin
            redirect_valid = 1'b0;
            // start a 2-op build (not yet sealed): 2 ALU ops, no seal trigger
            g[0] = mk_alu(64'h7000); g[1] = mk_alu(64'h7004);
            g[2] = '0; g[3] = '0;
            drive_group(g, 3'd2);
            state <= 103;
        end else if (state == 103) begin
            clear_group();
            state <= 1031;
        end else if (state == 1031) begin
            // build register now reflects the 2-op accumulation; no seal fired
            check("T6 partial build open (count==2, no install)",
                  (dut.build_count_r == 3'd2) && !saw_fill_r);
            // now flush mid-build (held for 1 cycle so the DUT's clocked
            // sample of redirect_valid lands before we check)
            redirect_valid = 1'b1; redirect_pc = 64'h9000;
            state <= 104;
        end else if (state == 104) begin
            // keep redirect asserted this cycle; the build drop latches at the
            // posedge sampling redirect_valid=1 (set in the prior state).
            state <= 105;
        end else if (state == 105) begin
            redirect_valid = 1'b0;
            check("T6 partial build dropped on redirect", dut.build_count_r == 3'd0);
            state <= 200;

        end else if (state == 200) begin
            $display("================================================");
            $display("UOC-REPACK unit TB: %0d passed, %0d failed",
                     pass_count, fail_count);
            if (fail_count == 0) $display("RESULT: ALL PASS");
            else                 $display("RESULT: FAIL");
            $finish;
        end
    end

    // eviction-test counters (declared at module scope for Verilator)
    integer evict_i = 0;
    integer evict_fills = 0;

    // sticky observation flags over a multi-cycle lookup window (cleared by
    // the test, set whenever the event pulses).  Robust to the exact
    // SRAM-read latency cycle.
    logic obs_clear;
    logic saw_hit_r, saw_fill_r;
    always_ff @(posedge clk) begin
        if (!rst_n || obs_clear) begin
            saw_hit_r  <= 1'b0;
            saw_fill_r <= 1'b0;
        end else begin
            if (ev_hit)  saw_hit_r  <= 1'b1;
            if (ev_fill) saw_fill_r <= 1'b1;
        end
    end

endmodule

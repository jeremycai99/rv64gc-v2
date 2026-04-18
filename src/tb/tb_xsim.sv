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

    always @(posedge clk) begin
        sim_cycle <= sim_cycle + 1;

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
            $finish;
        end

        // Timeout
        if (sim_cycle >= max_cycles) begin
            $display("TIMEOUT after %0d cycles", sim_cycle);
            $display("IPC: mcycle=%0d minstret=%0d IPC=%f",
                     perf_mcycle, perf_minstret,
                     $itor(perf_minstret) / $itor(perf_mcycle));
            $finish;
        end
    end

endmodule

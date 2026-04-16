/* file: tb_iverilog.sv
 Description: Self-contained top for Icarus Verilog simulation.
              Generates clk/rst, loads hex, monitors tohost, reports IPC.
 Author: Jeremy Cai
 Date: Apr. 13, 2026
 Version: 1.0
*/
`timescale 1ns/1ps

module tb_iverilog;
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

    // VCD dump (optional, controlled by +VCD)
    initial begin
        if ($test$plusargs("VCD")) begin
            $dumpfile("iv_sim.vcd");
            $dumpvars(0, tb_iverilog);
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

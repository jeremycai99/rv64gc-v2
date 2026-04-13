// file: tb_verilator.cpp
// Description: Verilator C++ driver for the RV64GC v2 full-system testbench.
//              Drives clk/rst_n, monitors tohost_valid/tohost_value, reports
//              IPC from the core's mcycle/minstret performance counters,
//              and generates a VCD trace.
// Version: 2.0

#include <verilated.h>
#include <verilated_vcd_c.h>
#include "Vtb_top.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);

    // Default cycle limit; allow override via +MAX_CYCLES=N
    long max_cycles = 5000;
    bool enable_vcd = true;
    for (int i = 1; i < argc; i++) {
        if (strncmp(argv[i], "+MAX_CYCLES=", 12) == 0) {
            max_cycles = atol(argv[i] + 12);
        }
        if (strncmp(argv[i], "+NOVCD", 6) == 0) {
            enable_vcd = false;
        }
    }

    Vtb_top* top = new Vtb_top;
    VerilatedVcdC* tfp = new VerilatedVcdC;
    if (enable_vcd) {
        top->trace(tfp, 99);
        tfp->open("sim.vcd");
    }

    // Reset -- hold rst_n low for 10 full clock cycles (20 half-cycles)
    top->clk   = 0;
    top->rst_n = 0;
    for (int i = 0; i < 20; i++) {
        top->clk = !top->clk;
        top->eval();
        tfp->dump((uint64_t)i);
    }
    top->rst_n = 1;

    long cycle = 0;
    bool done  = false;
    bool pass  = false;

    while (!done && cycle < max_cycles && !Verilated::gotFinish()) {
        // Rising edge
        top->clk = 1;
        top->eval();
        if (enable_vcd) tfp->dump((uint64_t)(20 + cycle * 2));

        // Check tohost write
        if (top->tohost_valid) {
            uint64_t val = top->tohost_value;
            if (val == 1) {
                printf("PASS at cycle %ld\n", cycle);
                pass = true;
            } else {
                printf("FAIL: tohost=%lu (test %lu) at cycle %ld\n",
                       (unsigned long)val, (unsigned long)(val >> 1), cycle);
            }
            done = true;
        }

        // Falling edge
        top->clk = 0;
        top->eval();
        if (enable_vcd) tfp->dump((uint64_t)(20 + cycle * 2 + 1));
        cycle++;

        if (cycle % 1000 == 0)
            printf("... cycle %ld  tohost_valid=%d tohost_value=0x%lx mcycle=%lu minstret=%lu\n",
                   cycle,
                   (int)top->tohost_valid,
                   (unsigned long)top->tohost_value,
                   (unsigned long)top->perf_mcycle,
                   (unsigned long)top->perf_minstret);
    }

    if (!done)
        printf("TIMEOUT after %ld cycles, tohost_valid=%d tohost_value=0x%lx\n",
               cycle,
               (int)top->tohost_valid,
               (unsigned long)top->tohost_value);

    // Run a few extra cycles so the perf counters reflect any committed
    // instructions still in flight at the time of the tohost write.
    for (int i = 0; i < 8; i++) {
        top->clk = 1; top->eval();
        top->clk = 0; top->eval();
    }

    // Print performance counters / IPC
    uint64_t mcycle   = top->perf_mcycle;
    uint64_t minstret = top->perf_minstret;
    printf("PERF: mcycle=%lu minstret=%lu\n",
           (unsigned long)mcycle, (unsigned long)minstret);
    if (mcycle > 0) {
        double ipc = (double)minstret / (double)mcycle;
        printf("PERF: IPC=%.4f (%lu instr / %lu cycles)\n",
               ipc, (unsigned long)minstret, (unsigned long)mcycle);
    }

    if (enable_vcd) tfp->close();
    delete tfp;
    delete top;
    return (done && pass) ? 0 : 1;
}

// Stub required by Verilator when not linking SystemC
double sc_time_stamp() { return 0; }

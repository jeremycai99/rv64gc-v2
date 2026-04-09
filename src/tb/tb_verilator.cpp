// file: tb_verilator.cpp
// Description: Verilator C++ driver for the RV64GC v2 full-system testbench.
//              Drives clk/rst_n, monitors tohost_valid/tohost_value, and
//              generates a VCD trace.
// Version: 2.0

#include <verilated.h>
#include <verilated_vcd_c.h>
#include "Vtb_top.h"
#include <cstdio>
#include <cstdlib>

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);

    Vtb_top* top = new Vtb_top;
    VerilatedVcdC* tfp = new VerilatedVcdC;
    top->trace(tfp, 99);
    tfp->open("sim.vcd");

    // Reset -- hold rst_n low for 10 full clock cycles (20 half-cycles)
    top->clk   = 0;
    top->rst_n = 0;
    for (int i = 0; i < 20; i++) {
        top->clk = !top->clk;
        top->eval();
        tfp->dump(i);
    }
    top->rst_n = 1;

    int  cycle      = 0;
    int  max_cycles = 200000;
    bool done       = false;

    while (!done && cycle < max_cycles && !Verilated::gotFinish()) {
        // Rising edge
        top->clk = 1;
        top->eval();
        tfp->dump(20 + cycle * 2);

        // Check tohost write
        if (top->tohost_valid) {
            uint64_t val = top->tohost_value;
            if (val == 1) {
                printf("PASS at cycle %d\n", cycle);
            } else {
                printf("FAIL: tohost=%lu (test %lu) at cycle %d\n",
                       val, val >> 1, cycle);
            }
            done = true;
        }

        // Falling edge
        top->clk = 0;
        top->eval();
        tfp->dump(20 + cycle * 2 + 1);
        cycle++;

        if (cycle % 10000 == 0)
            printf("... cycle %d\n", cycle);
    }

    if (!done)
        printf("TIMEOUT after %d cycles\n", cycle);

    tfp->close();
    delete tfp;
    delete top;
    return done ? 0 : 1;
}

// Stub required by Verilator when not linking SystemC
double sc_time_stamp() { return 0; }

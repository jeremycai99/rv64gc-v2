#include <verilated.h>
#include "Vtb_bru.h"
#include "Vtb_bru___024root.h"

double sc_time_stamp() { return 0; }

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vtb_bru* top = new Vtb_bru;

    // Toggle clock to drive @(posedge clk) in the SV testbench
    while (!Verilated::gotFinish()) {
        top->rootp->tb_bru__DOT__clk = 0;
        top->eval();
        top->rootp->tb_bru__DOT__clk = 1;
        top->eval();
    }

    delete top;
    return 0;
}

#include <verilated.h>
#include "Vtb_uop_cache.h"
#include "Vtb_uop_cache___024root.h"

double sc_time_stamp() { return 0; }

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vtb_uop_cache* top = new Vtb_uop_cache;

    while (!Verilated::gotFinish()) {
        top->rootp->tb_uop_cache__DOT__clk = 0;
        top->eval();
        top->rootp->tb_uop_cache__DOT__clk = 1;
        top->eval();
    }

    delete top;
    return 0;
}

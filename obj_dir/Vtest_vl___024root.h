// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Design internal header
// See Vtest_vl.h for the primary calling header

#ifndef VERILATED_VTEST_VL___024ROOT_H_
#define VERILATED_VTEST_VL___024ROOT_H_  // guard

#include "verilated.h"


class Vtest_vl__Syms;

class alignas(VL_CACHE_LINE_BYTES) Vtest_vl___024root final : public VerilatedModule {
  public:

    // DESIGN SPECIFIC STATE
    VL_IN8(clk,0,0);
    CData/*0:0*/ __VactContinue;
    IData/*31:0*/ __VactIterCount;
    VlTriggerVec<0> __VactTriggered;
    VlTriggerVec<0> __VnbaTriggered;

    // INTERNAL VARIABLES
    Vtest_vl__Syms* const vlSymsp;

    // CONSTRUCTORS
    Vtest_vl___024root(Vtest_vl__Syms* symsp, const char* v__name);
    ~Vtest_vl___024root();
    VL_UNCOPYABLE(Vtest_vl___024root);

    // INTERNAL METHODS
    void __Vconfigure(bool first);
};


#endif  // guard

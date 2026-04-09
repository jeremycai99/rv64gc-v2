// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Design implementation internals
// See Vtest_vl.h for the primary calling header

#include "Vtest_vl__pch.h"
#include "Vtest_vl__Syms.h"
#include "Vtest_vl___024root.h"

void Vtest_vl___024root___ctor_var_reset(Vtest_vl___024root* vlSelf);

Vtest_vl___024root::Vtest_vl___024root(Vtest_vl__Syms* symsp, const char* v__name)
    : VerilatedModule{v__name}
    , vlSymsp{symsp}
 {
    // Reset structure values
    Vtest_vl___024root___ctor_var_reset(this);
}

void Vtest_vl___024root::__Vconfigure(bool first) {
    (void)first;  // Prevent unused variable warning
}

Vtest_vl___024root::~Vtest_vl___024root() {
}

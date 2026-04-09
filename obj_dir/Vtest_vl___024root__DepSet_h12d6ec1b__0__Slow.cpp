// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Design implementation internals
// See Vtest_vl.h for the primary calling header

#include "Vtest_vl__pch.h"
#include "Vtest_vl___024root.h"

VL_ATTR_COLD void Vtest_vl___024root___eval_static(Vtest_vl___024root* vlSelf) {
    (void)vlSelf;  // Prevent unused variable warning
    Vtest_vl__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtest_vl___024root___eval_static\n"); );
}

VL_ATTR_COLD void Vtest_vl___024root___eval_initial(Vtest_vl___024root* vlSelf) {
    (void)vlSelf;  // Prevent unused variable warning
    Vtest_vl__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtest_vl___024root___eval_initial\n"); );
}

VL_ATTR_COLD void Vtest_vl___024root___eval_final(Vtest_vl___024root* vlSelf) {
    (void)vlSelf;  // Prevent unused variable warning
    Vtest_vl__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtest_vl___024root___eval_final\n"); );
}

VL_ATTR_COLD void Vtest_vl___024root___eval_settle(Vtest_vl___024root* vlSelf) {
    (void)vlSelf;  // Prevent unused variable warning
    Vtest_vl__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtest_vl___024root___eval_settle\n"); );
}

#ifdef VL_DEBUG
VL_ATTR_COLD void Vtest_vl___024root___dump_triggers__act(Vtest_vl___024root* vlSelf) {
    (void)vlSelf;  // Prevent unused variable warning
    Vtest_vl__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtest_vl___024root___dump_triggers__act\n"); );
    // Body
    if ((1U & (~ vlSelf->__VactTriggered.any()))) {
        VL_DBG_MSGF("         No triggers active\n");
    }
}
#endif  // VL_DEBUG

#ifdef VL_DEBUG
VL_ATTR_COLD void Vtest_vl___024root___dump_triggers__nba(Vtest_vl___024root* vlSelf) {
    (void)vlSelf;  // Prevent unused variable warning
    Vtest_vl__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtest_vl___024root___dump_triggers__nba\n"); );
    // Body
    if ((1U & (~ vlSelf->__VnbaTriggered.any()))) {
        VL_DBG_MSGF("         No triggers active\n");
    }
}
#endif  // VL_DEBUG

VL_ATTR_COLD void Vtest_vl___024root___ctor_var_reset(Vtest_vl___024root* vlSelf) {
    (void)vlSelf;  // Prevent unused variable warning
    Vtest_vl__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtest_vl___024root___ctor_var_reset\n"); );
    // Body
    vlSelf->clk = VL_RAND_RESET_I(1);
}

// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Design implementation internals
// See Vtest_vl.h for the primary calling header

#include "Vtest_vl__pch.h"
#include "Vtest_vl__Syms.h"
#include "Vtest_vl___024root.h"

#ifdef VL_DEBUG
VL_ATTR_COLD void Vtest_vl___024root___dump_triggers__act(Vtest_vl___024root* vlSelf);
#endif  // VL_DEBUG

void Vtest_vl___024root___eval_triggers__act(Vtest_vl___024root* vlSelf) {
    (void)vlSelf;  // Prevent unused variable warning
    Vtest_vl__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vtest_vl___024root___eval_triggers__act\n"); );
    // Body
#ifdef VL_DEBUG
    if (VL_UNLIKELY(vlSymsp->_vm_contextp__->debug())) {
        Vtest_vl___024root___dump_triggers__act(vlSelf);
    }
#endif
}

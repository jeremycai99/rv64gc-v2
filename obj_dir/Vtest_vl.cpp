// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Model implementation (design independent parts)

#include "Vtest_vl__pch.h"

//============================================================
// Constructors

Vtest_vl::Vtest_vl(VerilatedContext* _vcontextp__, const char* _vcname__)
    : VerilatedModel{*_vcontextp__}
    , vlSymsp{new Vtest_vl__Syms(contextp(), _vcname__, this)}
    , clk{vlSymsp->TOP.clk}
    , rootp{&(vlSymsp->TOP)}
{
    // Register model with the context
    contextp()->addModel(this);
}

Vtest_vl::Vtest_vl(const char* _vcname__)
    : Vtest_vl(Verilated::threadContextp(), _vcname__)
{
}

//============================================================
// Destructor

Vtest_vl::~Vtest_vl() {
    delete vlSymsp;
}

//============================================================
// Evaluation function

#ifdef VL_DEBUG
void Vtest_vl___024root___eval_debug_assertions(Vtest_vl___024root* vlSelf);
#endif  // VL_DEBUG
void Vtest_vl___024root___eval_static(Vtest_vl___024root* vlSelf);
void Vtest_vl___024root___eval_initial(Vtest_vl___024root* vlSelf);
void Vtest_vl___024root___eval_settle(Vtest_vl___024root* vlSelf);
void Vtest_vl___024root___eval(Vtest_vl___024root* vlSelf);

void Vtest_vl::eval_step() {
    VL_DEBUG_IF(VL_DBG_MSGF("+++++TOP Evaluate Vtest_vl::eval_step\n"); );
#ifdef VL_DEBUG
    // Debug assertions
    Vtest_vl___024root___eval_debug_assertions(&(vlSymsp->TOP));
#endif  // VL_DEBUG
    vlSymsp->__Vm_deleter.deleteAll();
    if (VL_UNLIKELY(!vlSymsp->__Vm_didInit)) {
        vlSymsp->__Vm_didInit = true;
        VL_DEBUG_IF(VL_DBG_MSGF("+ Initial\n"););
        Vtest_vl___024root___eval_static(&(vlSymsp->TOP));
        Vtest_vl___024root___eval_initial(&(vlSymsp->TOP));
        Vtest_vl___024root___eval_settle(&(vlSymsp->TOP));
    }
    VL_DEBUG_IF(VL_DBG_MSGF("+ Eval\n"););
    Vtest_vl___024root___eval(&(vlSymsp->TOP));
    // Evaluate cleanup
    Verilated::endOfEval(vlSymsp->__Vm_evalMsgQp);
}

//============================================================
// Events and timing
bool Vtest_vl::eventsPending() { return false; }

uint64_t Vtest_vl::nextTimeSlot() {
    VL_FATAL_MT(__FILE__, __LINE__, "", "%Error: No delays in the design");
    return 0;
}

//============================================================
// Utilities

const char* Vtest_vl::name() const {
    return vlSymsp->name();
}

//============================================================
// Invoke final blocks

void Vtest_vl___024root___eval_final(Vtest_vl___024root* vlSelf);

VL_ATTR_COLD void Vtest_vl::final() {
    Vtest_vl___024root___eval_final(&(vlSymsp->TOP));
}

//============================================================
// Implementations of abstract methods from VerilatedModel

const char* Vtest_vl::hierName() const { return vlSymsp->name(); }
const char* Vtest_vl::modelName() const { return "Vtest_vl"; }
unsigned Vtest_vl::threads() const { return 1; }
void Vtest_vl::prepareClone() const { contextp()->prepareClone(); }
void Vtest_vl::atClone() const {
    contextp()->threadPoolpOnClone();
}

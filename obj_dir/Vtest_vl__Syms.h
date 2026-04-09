// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Symbol table internal header
//
// Internal details; most calling programs do not need this header,
// unless using verilator public meta comments.

#ifndef VERILATED_VTEST_VL__SYMS_H_
#define VERILATED_VTEST_VL__SYMS_H_  // guard

#include "verilated.h"

// INCLUDE MODEL CLASS

#include "Vtest_vl.h"

// INCLUDE MODULE CLASSES
#include "Vtest_vl___024root.h"

// SYMS CLASS (contains all model state)
class alignas(VL_CACHE_LINE_BYTES)Vtest_vl__Syms final : public VerilatedSyms {
  public:
    // INTERNAL STATE
    Vtest_vl* const __Vm_modelp;
    VlDeleter __Vm_deleter;
    bool __Vm_didInit = false;

    // MODULE INSTANCE STATE
    Vtest_vl___024root             TOP;

    // CONSTRUCTORS
    Vtest_vl__Syms(VerilatedContext* contextp, const char* namep, Vtest_vl* modelp);
    ~Vtest_vl__Syms();

    // METHODS
    const char* name() { return TOP.name(); }
};

#endif  // guard

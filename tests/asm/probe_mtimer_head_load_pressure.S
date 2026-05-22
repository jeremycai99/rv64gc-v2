/*
 * probe_mtimer_head_load_pressure.S
 *
 * Directed Stage 3 smoke for the Linux mtimer freeze class.  The test executes
 * the OpenSBI-like timer handler body directly because the generic tohost
 * benchmark testbench does not model CLINT timer interrupts.  The body starts
 * with a cold load from a timer structure, then issues a long stream of
 * independent cacheable loads so the ROB/LQ can fill while the handler head
 * load is waiting.  The head load must still complete and retire exactly once.
 */

#include "test_macros.h"

    .macro LOAD_PRESSURE
    ld      x0,     0(a0)
    ld      x0,    64(a0)
    ld      x0,   128(a0)
    ld      x0,   192(a0)
    ld      x0,   256(a0)
    ld      x0,   320(a0)
    ld      x0,   384(a0)
    ld      x0,   448(a0)
    ld      x0,   512(a0)
    ld      x0,   576(a0)
    ld      x0,   640(a0)
    ld      x0,   704(a0)
    ld      x0,   768(a0)
    ld      x0,   832(a0)
    ld      x0,   896(a0)
    ld      x0,   960(a0)
    addi    a0, a0, 1024
    .endm

    .section .text.init
    .globl _start
_start:
    la      sp, _stack_top
    j       mtimer_handler

mtimer_handler:
    la      a5, mtimer_struct
    c.lw    a3, 40(a5)
    addiw   a2, x0, 0
    c.ld    a4, 24(a5)
    subw    a2, a2, a3
    slli    a3, a2, 32
    c.ld    a5, 80(a5)
    srli    a2, a3, 29
    add     a2, a2, a4

    la      a0, pressure_lines
    LOAD_PRESSURE
    LOAD_PRESSURE
    LOAD_PRESSURE
    LOAD_PRESSURE

    li      t0, 0x123456789abcdef0
    bne     a4, t0, fail
    li      t0, 7
    bne     a5, t0, fail

    PASS

fail:
    FAIL    1

    .section .data
    .align 6
mtimer_struct:
    .zero 24
    .dword 0x123456789abcdef0
    .zero 8
    .word 7
    .word 0
    .zero 32
    .dword 7

    .align 6
pressure_lines:
    .set val, 1
    .rept 128
    .dword val
    .zero 56
    .set val, val + 1
    .endr

    .section .bss
    .align 12
_stack:
    .zero 4096
_stack_top:

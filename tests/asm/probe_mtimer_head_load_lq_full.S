/*
 * probe_mtimer_head_load_lq_full.S
 *
 * Directed Stage 3 smoke for the Linux mtimer no-retire class.  It keeps the
 * OpenSBI mtimer_event_start head-load shape, then fills the load queue with
 * independent cold loads.  The older handler load must retain its completion
 * owner while younger loads pressure the LQ, LMB, and D-cache miss path.
 */

#include "test_macros.h"

    .macro LD32_X0 base
    ld      x0,     0(\base)
    ld      x0,    64(\base)
    ld      x0,   128(\base)
    ld      x0,   192(\base)
    ld      x0,   256(\base)
    ld      x0,   320(\base)
    ld      x0,   384(\base)
    ld      x0,   448(\base)
    ld      x0,   512(\base)
    ld      x0,   576(\base)
    ld      x0,   640(\base)
    ld      x0,   704(\base)
    ld      x0,   768(\base)
    ld      x0,   832(\base)
    ld      x0,   896(\base)
    ld      x0,   960(\base)
    ld      x0,  1024(\base)
    ld      x0,  1088(\base)
    ld      x0,  1152(\base)
    ld      x0,  1216(\base)
    ld      x0,  1280(\base)
    ld      x0,  1344(\base)
    ld      x0,  1408(\base)
    ld      x0,  1472(\base)
    ld      x0,  1536(\base)
    ld      x0,  1600(\base)
    ld      x0,  1664(\base)
    ld      x0,  1728(\base)
    ld      x0,  1792(\base)
    ld      x0,  1856(\base)
    ld      x0,  1920(\base)
    ld      x0,  1984(\base)
    addi    \base, \base, 1024
    addi    \base, \base, 1024
    .endm

    .section .text.init
    .globl _start
_start:
    la      sp, _stack_top
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
    LD32_X0 a0
    LD32_X0 a0
    LD32_X0 a0
    LD32_X0 a0
    LD32_X0 a0
    LD32_X0 a0

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
    .rept 192
    .dword val
    .zero 56
    .set val, val + 1
    .endr

    .section .bss
    .align 12
_stack:
    .zero 4096
_stack_top:

/*
 * probe_independent_quad.S — Phase D probe for sanity ceiling
 *                            (does 4-wide actually achieve IPC=4?)
 *
 * 8 independent ALUs per loop body — no dependency chain, all srcs are
 * pre-loaded immediates. If 4-wide RTL is structurally sound, this probe
 * SHOULD hit IPC≈4 (with loop overhead causing minor dilution).
 *
 * If IPC stays well below 4 here, there's a structural ceiling bug
 * (PRF read-port pressure, dispatch arbiter inefficiency, or similar)
 * that must be fixed before any other gap-closure work is meaningful.
 */

#include "test_macros.h"

    .section .text.init
    .globl _start
_start:
    li      a0, 1000            // outer-loop count
    li      a1, 1
    li      a2, 2
    li      a3, 3
    li      a4, 4
    li      a5, 5
    li      a6, 6
    li      a7, 7
    li      s0, 8
    li      s1, 9
    li      s2, 10
    li      s3, 11
    li      s4, 12
    li      s5, 13
    li      s6, 14
    li      s7, 15

loop:
    add     t0, a1, a2          // 8 INDEPENDENT adds — no dep chain
    add     t1, a3, a4
    add     t2, a5, a6
    add     t3, a7, s0
    add     t4, s1, s2
    add     t5, s3, s4
    add     t6, s5, s6
    add     s8, s7, a1
    addi    a0, a0, -1
    bnez    a0, loop

    PASS

    .section .tohost,"aw",@progbits
    .globl tohost
tohost:
    .dword 0

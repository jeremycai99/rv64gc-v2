/*
 * probe_alu_chain_8.S — Phase D probe for H1 (ALU bypass coverage)
 *
 * 8-deep ALU dependency chain in tight loop. Stresses bypass + CDB.
 * Expected behavior: if H1 is correct (extra ALU3/DIV/CSR bypass slot
 * needed), this probe shows operand-stall as the dominant bottleneck
 * and IPC well below 4.
 */

#include "test_macros.h"

    .section .text.init
    .globl _start
_start:
    li      a0, 1000        // outer-loop count
    li      a1, 1
loop:
    add     t0, a1, a1      // chain stage 1
    add     t1, t0, a1      // chain stage 2  (depends on t0)
    add     t2, t1, a1      // chain stage 3  (depends on t1)
    add     t3, t2, a1      // chain stage 4  (depends on t2)
    add     t4, t3, a1      // chain stage 5  (depends on t3)
    add     t5, t4, a1      // chain stage 6  (depends on t4)
    add     t6, t5, a1      // chain stage 7  (depends on t5)
    add     a2, t6, a1      // chain stage 8  (depends on t6)
    addi    a0, a0, -1
    bnez    a0, loop

    PASS

    .section .tohost,"aw",@progbits
    .globl tohost
tohost:
    .dword 0

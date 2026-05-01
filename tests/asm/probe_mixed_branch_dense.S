/*
 * probe_mixed_branch_dense.S — Phase D probe for BPU + flush-penalty (broad)
 *
 * 1 branch per 4 instructions, mixed taken/not-taken (alternating per iter
 * via a counter parity check). This stresses the BPU and the flush-recovery
 * cost without targeting one specific mispredict pattern.
 */

#include "test_macros.h"

    .section .text.init
    .globl _start
_start:
    li      a0, 500             // outer-loop count
    li      s0, 0               // even/odd alternator

loop:
    addi    s0, s0, 1           // bump alternator
    andi    t0, s0, 1           // parity bit
    add     t1, a0, s0          // some real work
    bnez    t0, br1_taken       // BR #1 — alternates taken/not
    addi    t2, t1, 7
    j       br1_after
br1_taken:
    addi    t2, t1, 3
br1_after:

    andi    t0, s0, 2           // parity bit 1
    add     t3, t2, s0
    sub     t4, t3, t1
    bnez    t0, br2_taken       // BR #2 — different parity
    addi    t5, t4, 5
    j       br2_after
br2_taken:
    addi    t5, t4, 9
br2_after:

    andi    t0, s0, 4
    xor     t6, t5, t4
    or      t3, t6, t1
    bnez    t0, br3_taken       // BR #3
    addi    t6, t3, 11
    j       br3_after
br3_taken:
    addi    t6, t3, 13
br3_after:

    andi    t0, s0, 8
    add     t1, t6, t3          // some more work
    bnez    t0, br4_taken       // BR #4
    nop
    j       br4_after
br4_taken:
    nop
br4_after:

    addi    a0, a0, -1
    bnez    a0, loop

    PASS

    .section .tohost,"aw",@progbits
    .globl tohost
tohost:
    .dword 0

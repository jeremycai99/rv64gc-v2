/*
 * test_jal4.S - Forward bgeu + sd loop, no JAL.
 *
 * Just do the BSS-clear-style pattern: 4 bgeu forward branches
 * with sd zero body, then PASS.  No JAL at all.  Isolates
 * whether the sd in the loop body is the problem.
 */
#include "test_macros.h"

    .section .text.init
    .globl _start
_start:
    li   sp, 0x800FFFF0
    la   a0, data_start
    la   a1, data_end

    .rept 4
    bgeu a0, a1, 1f
    sd   zero, 0(a0)
    addi a0, a0, 8
    .endr
1:
    PASS

    .section .tohost,"aw",@progbits
    .globl tohost
tohost:
    .dword 0

    .section .data
data_start:
    .zero 32
data_end:

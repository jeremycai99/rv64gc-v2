/*
 * bench_unrolled_5.S - 5-iteration unrolled body, no backward branches
 */

#include "test_macros.h"

    .section .text.init
    .globl _start
_start:
    li   t0, 1
    li   t1, 0

    .rept 5
    add  t1, t1, t0
    addi t2, t0, -1
    and  t3, t0, t1
    xor  t4, t0, t1
    slli t5, t0, 2
    add  t6, t0, t1
    addi t0, t0, 1
    .endr

    PASS

    .section .tohost,"aw",@progbits
    .globl tohost
tohost:
    .dword 0

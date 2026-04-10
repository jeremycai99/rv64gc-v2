/*
 * bench_loop_50.S - 50-iteration variant of bench_loop
 */

#include "test_macros.h"

    .section .text.init
    .globl _start
_start:
    li   t0, 50
    li   t1, 0

loop:
    add  t1, t1, t0
    addi t2, t0, -1
    and  t3, t0, t1
    xor  t4, t0, t1
    slli t5, t0, 2
    addi t0, t0, -1
    bnez t0, loop

    PASS

    .section .tohost,"aw",@progbits
    .globl tohost
tohost:
    .dword 0

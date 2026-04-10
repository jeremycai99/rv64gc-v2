/*
 * bench_one_iter.S - 1 iteration -- bnez never taken
 */

#include "test_macros.h"

    .section .text.init
    .globl _start
_start:
    li   t0, 1

loop:
    addi t0, t0, -1
    bnez t0, loop

    PASS

    .section .tohost,"aw",@progbits
    .globl tohost
tohost:
    .dword 0

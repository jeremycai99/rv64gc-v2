/*
 * bench_no_loop.S - Same as bench_one_iter but no loop label/branch
 */

#include "test_macros.h"

    .section .text.init
    .globl _start
_start:
    li   t0, 1
    addi t0, t0, -1
    nop
    nop
    nop

    PASS

    .section .tohost,"aw",@progbits
    .globl tohost
tohost:
    .dword 0

/*
 * bench_loop_10.S - 10-iteration variant of bench_loop
 */

#include "test_macros.h"

    .section .text.init
    .globl _start
_start:
    li   t0, 10            # iteration count
    li   t1, 0              # accumulator

loop:
    add  t1, t1, t0         # t1 += t0
    addi t2, t0, -1         # t2 = t0 - 1
    and  t3, t0, t1         # t3 = t0 & t1
    xor  t4, t0, t1         # t4 = t0 ^ t1
    slli t5, t0, 2          # t5 = t0 << 2
    addi t0, t0, -1         # t0--
    bnez t0, loop           # branch while t0 != 0

    PASS

    .section .tohost,"aw",@progbits
    .globl tohost
tohost:
    .dword 0

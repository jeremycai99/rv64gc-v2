/*
 * bench_loop.S - Simple instruction-throughput benchmark
 *
 * Runs a small loop ~7000 instructions; the testbench measures cycles
 * and the IPC is computed by external script (or by reading the
 * mcycle/minstret CSRs from the core).
 */

#include "test_macros.h"

    .section .text.init
    .globl _start
_start:
    li   t0, 1000           # iteration count
    li   t1, 0              # accumulator

loop:
    add  t1, t1, t0         # t1 += t0
    addi t2, t0, -1         # t2 = t0 - 1
    and  t3, t0, t1         # t3 = t0 & t1
    xor  t4, t0, t1         # t4 = t0 ^ t1
    slli t5, t0, 2          # t5 = t0 << 2
    addi t0, t0, -1         # t0--
    bnez t0, loop           # branch while t0 != 0

    # Done — write PASS to tohost
    PASS

    .section .tohost,"aw",@progbits
    .globl tohost
tohost:
    .dword 0

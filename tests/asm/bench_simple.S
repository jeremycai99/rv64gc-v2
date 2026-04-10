/*
 * bench_simple.S - simplest test possible: just a few ALU then PASS
 */

#include "test_macros.h"

    .section .text.init
    .globl _start
_start:
    addi t0, x0, 1
    addi t0, t0, 1
    addi t0, t0, 1
    addi t0, t0, 1
    addi t0, t0, 1

    # Now PASS
    li   t0, TOHOST_ADDR
    li   t1, 1
    sd   t1, 0(t0)
    j    .

    .section .tohost,"aw",@progbits
    .globl tohost
tohost:
    .dword 0

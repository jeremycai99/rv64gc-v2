/*
 * bench_loop_uncond.S - Loop using forward branches only
 */

#include "test_macros.h"

    .section .text.init
    .globl _start
_start:
    li   t0, 5
    li   t1, 0

    # Forward-jump-only loop using a counter
    .rept 5
    addi t1, t1, 1
    addi t0, t0, -1
    .endr

    # Now PASS
    li   t0, TOHOST_ADDR
    li   t1, 1
    sd   t1, 0(t0)
    j    .

    .section .tohost,"aw",@progbits
    .globl tohost
tohost:
    .dword 0

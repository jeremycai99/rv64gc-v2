/*
 * test_jal2.S - JAL after forward branches.
 *
 * This tests whether the v2 pipeline gets confused when a JAL follows
 * a bunch of forward-taken conditional branches (mimicking the pattern
 * at the tail of an unrolled BSS clear -> jal main sequence).
 */
#include "test_macros.h"

    .section .text.init
    .globl _start
_start:
    li   sp, 0x800FFFF0

    # Fake BSS-clear skeleton: 8 forward bgeu branches that will be taken.
    li   a0, 1
    li   a1, 0
    bgeu a0, a1, 1f
    nop
1:  bgeu a0, a1, 2f
    nop
2:  bgeu a0, a1, 3f
    nop
3:  bgeu a0, a1, 4f
    nop
4:  bgeu a0, a1, 5f
    nop
5:  bgeu a0, a1, 6f
    nop
6:  bgeu a0, a1, 7f
    nop
7:  bgeu a0, a1, 8f
    nop
8:
    # Call
    li   a0, 5
    li   a1, 3
    jal  ra, add_fn
    li   t3, 8
    bne  a0, t3, fail
    PASS

fail:
    FAIL 1

add_fn:
    add  a0, a0, a1
    jalr x0, 0(ra)

    .section .tohost,"aw",@progbits
    .globl tohost
tohost:
    .dword 0

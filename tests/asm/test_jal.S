/*
 * test_jal.S - Exercises a JAL call and a RET (jalr x0, 0(ra)).
 *
 * Directly probes the bug where the first-ever JAL call doesn't
 * redirect the front-end: call a small helper function, return,
 * then write tohost.
 */
#include "test_macros.h"

    .section .text.init
    .globl _start
_start:
    li   sp, 0x800FFFF0     # stack
    li   a0, 5
    li   a1, 3
    jal  ra, add_fn         # call add_fn; link in ra
    li   t3, 8
    bne  a0, t3, fail
    PASS

fail:
    FAIL 1

add_fn:
    add  a0, a0, a1
    jalr x0, 0(ra)          # explicit RET

    .section .tohost,"aw",@progbits
    .globl tohost
tohost:
    .dword 0

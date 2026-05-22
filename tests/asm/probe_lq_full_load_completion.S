/*
 * probe_lq_full_load_completion.S
 *
 * Directed LSU/LQ pressure smoke for Linux-style load completion loss.  The
 * stream uses x0 destinations so rename physical-register pressure does not
 * hide LQ/ROB pressure; every load still has to complete before it can retire.
 */

#include "test_macros.h"

    .macro LD32_X0
    ld      x0,     0(a0)
    ld      x0,    64(a0)
    ld      x0,   128(a0)
    ld      x0,   192(a0)
    ld      x0,   256(a0)
    ld      x0,   320(a0)
    ld      x0,   384(a0)
    ld      x0,   448(a0)
    ld      x0,   512(a0)
    ld      x0,   576(a0)
    ld      x0,   640(a0)
    ld      x0,   704(a0)
    ld      x0,   768(a0)
    ld      x0,   832(a0)
    ld      x0,   896(a0)
    ld      x0,   960(a0)
    ld      x0,  1024(a0)
    ld      x0,  1088(a0)
    ld      x0,  1152(a0)
    ld      x0,  1216(a0)
    ld      x0,  1280(a0)
    ld      x0,  1344(a0)
    ld      x0,  1408(a0)
    ld      x0,  1472(a0)
    ld      x0,  1536(a0)
    ld      x0,  1600(a0)
    ld      x0,  1664(a0)
    ld      x0,  1728(a0)
    ld      x0,  1792(a0)
    ld      x0,  1856(a0)
    ld      x0,  1920(a0)
    ld      x0,  1984(a0)
    addi    a0, a0, 1024
    addi    a0, a0, 1024
    .endm

    .section .text.init
    .globl _start
_start:
    la      a0, lines

    LD32_X0
    LD32_X0
    LD32_X0
    LD32_X0
    LD32_X0
    LD32_X0

    ld      t0, -64(a0)
    li      t1, 192
    bne     t0, t1, fail

    PASS

fail:
    FAIL    1

    .section .data
    .align 6
lines:
    .set val, 1
    .rept 192
    .dword val
    .zero 56
    .set val, val + 1
    .endr

/*
 * rvc_addi16sp_712d_smoke.S
 *
 * Directed Stage 3 smoke for the Linux trap-entry C.ADDI16SP instruction
 * 0x712d, which must expand to addi sp, sp, -288.
 */

#include "test_macros.h"

    .section .text.init
    .globl _start
_start:
    li      sp, 0x1000
    .hword  0x712d
    li      t0, 0x0ee0
    bne     sp, t0, fail_1

    li      t0, 0x2000
    mv      sp, t0
    .hword  0x712d
    li      t1, 0x1ee0
    bne     sp, t1, fail_2

    PASS

fail_1:
    FAIL    1

fail_2:
    FAIL    2

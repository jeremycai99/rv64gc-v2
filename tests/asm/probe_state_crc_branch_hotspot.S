/*
 * probe_state_crc_branch_hotspot.S
 *
 * Focused Step-3 reproducer for the CoreMark state-machine and CRC branch
 * hotspots. Expected stall signature: raw post-bypass branch-ready stalls in
 * a byte-classification ladder and a tight CRC bnez loop.
 */

#include "test_macros.h"

    .section .text.init
    .globl _start
_start:
    li      sp, 0x800FFFF0
    li      s0, 220
    li      s1, 0

outer_loop:
    la      a0, state_bytes
    la      t0, state_end
    sub     a1, t0, a0
    call    state_walk
    add     s1, s1, a0

    mv      a0, s1
    call    crc16_mix
    mv      s1, a0

    addi    s0, s0, -1
    bnez    s0, outer_loop

    beqz    s1, branch_fail
    PASS

branch_fail:
    FAIL 2

state_walk:
    li      t0, 0
state_loop:
    beqz    a1, state_done
    lbu     t1, 0(a0)
    addi    a0, a0, 1
    addi    a1, a1, -1

    li      t2, 44
    beq     t1, t2, saw_comma
    li      t2, 46
    beq     t1, t2, saw_dot
    li      t2, 48
    bltu    t1, t2, saw_other
    li      t2, 57
    bltu    t2, t1, saw_other
    addi    t0, t0, 3
    j       state_loop
saw_comma:
    addi    t0, t0, 5
    j       state_loop
saw_dot:
    addi    t0, t0, 7
    j       state_loop
saw_other:
    addi    t0, t0, 11
    j       state_loop
state_done:
    mv      a0, t0
    ret

crc16_mix:
    li      t2, 16
    li      t3, 0x1021
crc_loop:
    andi    t0, a0, 1
    srli    a0, a0, 1
    beqz    t0, crc_no_xor
    xor     a0, a0, t3
crc_no_xor:
    addi    t2, t2, -1
    bnez    t2, crc_loop
    ret

    .section .data
    .align 4
state_bytes:
    .ascii "12,34.56,Ee,+-xyz789,01.23,ABcd,45.67,foo,89.00;"
state_end:

    .section .tohost,"aw",@progbits
    .globl tohost
tohost:
    .dword 0

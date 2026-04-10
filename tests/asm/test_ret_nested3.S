/*
 * test_ret_nested3.S - Add intermediate work to my_main.
 */
#include "test_macros.h"

    .section .text.init
    .globl _start
_start:
    li   sp, 0x800FFFF0
    jal  ra, my_main
    li   t3, 0
    bne  a0, t3, fail
    PASS

fail:
    FAIL 1

my_main:
    addi sp, sp, -16
    sd   ra, 8(sp)
    li   a0, 5
    li   a1, 3
    jal  ra, my_add
    addi a0, a0, -8
    snez a0, a0
    ld   ra, 8(sp)
    addi sp, sp, 16
    ret

my_add:
    addw a0, a0, a1
    ret

    .section .tohost,"aw",@progbits
    .globl tohost
tohost:
    .dword 0

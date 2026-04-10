/*
 * test_ret_nested.S - Mimic test_call pattern: nested calls.
 *
 * _start jumps to main; main calls a leaf "add" function;
 * main returns to _start which writes tohost.
 * This is the exact CALL pattern from test_call.c.
 */
#include "test_macros.h"

    .section .text.init
    .globl _start
_start:
    li   sp, 0x800FFFF0
    jal  ra, my_main         // call main, link in ra
    li   t3, 0
    bne  a0, t3, fail        // a0 must be 0 from main
    PASS

fail:
    FAIL 1

my_main:
    addi sp, sp, -16
    li   a1, 3
    li   a0, 5
    sd   ra, 8(sp)
    jal  ra, my_add
    ld   ra, 8(sp)
    addi a0, a0, -8           // expected: 5+3=8, so a0-8=0
    snez a0, a0               // a0 = (a0!=0)
    addi sp, sp, 16
    ret

my_add:
    addw a0, a0, a1
    ret

    .section .tohost,"aw",@progbits
    .globl tohost
tohost:
    .dword 0

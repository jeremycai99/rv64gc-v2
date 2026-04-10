/*
 * test_ret_nested2.S - Even simpler nested call.
 *
 * Strip down test_ret_nested to bare minimum:
 *   _start: call my_main, write tohost
 *   my_main: sd ra; jal my_add; ld ra; ret  (no other work)
 *   my_add: ret
 */
#include "test_macros.h"

    .section .text.init
    .globl _start
_start:
    li   sp, 0x800FFFF0
    jal  ra, my_main
    PASS

my_main:
    addi sp, sp, -16
    sd   ra, 8(sp)
    jal  ra, my_add
    ld   ra, 8(sp)
    addi sp, sp, 16
    ret

my_add:
    ret

    .section .tohost,"aw",@progbits
    .globl tohost
tohost:
    .dword 0

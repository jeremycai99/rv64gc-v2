/*
 * test_ret_stack.S - jal + foo saves ra to stack, restores, ret.
 *
 * Tests function prologue/epilogue with stack save/restore of ra.
 * This is the exact pattern that test_call (and main()) use.
 * If test_ret passes but this fails, the bug is in the
 * sd ra; ld ra; ret sequence (load-to-RET data dependence).
 */
#include "test_macros.h"

    .section .text.init
    .globl _start
_start:
    li   sp, 0x800FFFF0
    jal  ra, foo             // call foo, link in ra
    PASS                     // if we returned, write tohost=1

foo:
    addi sp, sp, -16
    sd   ra, 8(sp)
    nop
    nop
    nop
    nop
    ld   ra, 8(sp)
    addi sp, sp, 16
    ret

    .section .tohost,"aw",@progbits
    .globl tohost
tohost:
    .dword 0

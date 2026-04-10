/*
 * test_ret.S - Bare jal+ret with no stack save.
 *
 * Tests the absolute simplest function call/return: a JAL into foo,
 * which immediately RETs.  No stack manipulation, no register save.
 * If this fails, the bug is in plain JAL link/RET read of ra.
 */
#include "test_macros.h"

    .section .text.init
    .globl _start
_start:
    li   sp, 0x800FFFF0      // stack pointer (unused but conventional)
    jal  ra, foo             // call foo, link in ra
    PASS                     // if we returned, write tohost=1

foo:
    ret                      // jalr x0, 0(ra)

    .section .tohost,"aw",@progbits
    .globl tohost
tohost:
    .dword 0

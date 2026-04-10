/*
 * test_jal3.S - Mimic the crt0 BSS clear pattern exactly (64 bgeu),
 * then JAL to a function far away from _start (to mimic the C test
 * layout where main is in .text at 0x80002000).
 */
#include "test_macros.h"

    .section .text.init
    .globl _start
_start:
    li   sp, 0x800FFFF0
    la   a0, data_start
    la   a1, data_end

    .rept 4
    bgeu a0, a1, 1f
    sd   zero, 0(a0)
    addi a0, a0, 8
    .endr
1:
    # Now call far_fn which lives at a distant PC
    li   a0, 5
    li   a1, 3
    jal  ra, far_fn
    li   t3, 8
    bne  a0, t3, fail
    PASS

fail:
    FAIL 1

    .section .tohost,"aw",@progbits
    .globl tohost
tohost:
    .dword 0

    .section .data
data_start:
    .zero 32
data_end:

    # far_fn is placed in .text.far at a higher address via link script.
    # For now just put it after .data in the same section.
    .section .text.far, "ax"
    .globl far_fn
far_fn:
    add  a0, a0, a1
    jalr x0, 0(ra)

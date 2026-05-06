/*
 * probe_string_retire_hotspot.S
 *
 * Focused Step-3 reproducer for the Dhrystone heavy-row hotspots:
 * byte copy/compare loops with return-heavy control flow. Expected stall
 * signature: load-ready pressure in the byte loops plus raw post-bypass
 * branch/JALR-ready stalls on loop exits and returns.
 */

#include "test_macros.h"

    .section .text.init
    .globl _start
_start:
    li      sp, 0x800FFFF0
    li      s0, 300
    la      s1, src_string
    la      s2, dst_string

outer_loop:
    mv      a0, s2
    mv      a1, s1
    call    probe_strcpy

    mv      a0, s2
    mv      a1, s1
    call    probe_strcmp
    bnez    a0, string_fail

    addi    s0, s0, -1
    bnez    s0, outer_loop

    PASS

string_fail:
    FAIL 1

probe_strcpy:
    mv      a5, a0
copy_loop:
    lbu     a4, 0(a1)
    addi    a5, a5, 1
    addi    a1, a1, 1
    sb      a4, -1(a5)
    bnez    a4, copy_loop
    ret

probe_strcmp:
cmp_loop:
    lbu     a5, 0(a0)
    lbu     a4, 0(a1)
    addi    a0, a0, 1
    addi    a1, a1, 1
    bne     a5, a4, cmp_diff
    bnez    a5, cmp_loop
    li      a0, 0
    ret
cmp_diff:
    subw    a0, a5, a4
    ret

    .section .data
    .align 4
src_string:
    .asciz "DHRY-STRING-HOTSPOT-0123456789-ABCDEFGHIJKLMNOPQRSTUVWXYZ-abcdefghijk"
dst_string:
    .space 96

    .section .tohost,"aw",@progbits
    .globl tohost
tohost:
    .dword 0

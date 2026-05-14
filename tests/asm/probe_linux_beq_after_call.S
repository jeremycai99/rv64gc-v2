/*
 * probe_linux_beq_after_call.S
 *
 * Directed Linux boot debug probe for a call-return value consumed by a
 * callee-saved-register BEQ.  This mirrors the shape seen in
 * __of_find_node_by_path:
 *
 *     call strlen
 *     beq  s3, a0, found
 *
 * It is not a performance benchmark and does not encode any Linux PC.
 */

#include "test_macros.h"

    .option push
    .option norvc

    .section .text.init
    .globl _start
_start:
    li      sp, 0x800ffff0

    li      s3, 4
    call    return_four
    beq     s3, a0, pass_first
    FAIL    1

pass_first:
    li      s3, 4
    call    return_four
    beq     s3, a0, short_found
    ld      s2, 0(sp)
    .option push
    .option rvc
    j       short_fail
    c.li    s2, 0
    .option pop
short_found:
    li      s2, 1
    j       short_done
short_fail:
    FAIL    2

short_done:
    la      a0, test_name
    li      s3, 4
    call    strlen_like
    beq     s3, a0, strlen_found
    ld      s2, 0(sp)
    .option push
    .option rvc
    j       strlen_fail
    c.li    s2, 0
    .option pop
strlen_found:
    li      s2, 2
    j       strlen_done
strlen_fail:
    FAIL    3

strlen_done:
    call    return_four
    addiw   s3, a0, 0
    beqz    s3, fail_fused_sextw
    mv      a2, s3
    li      t0, 4
    beq     a2, t0, fused_sextw_done
    FAIL    4

fail_fused_sextw:
    FAIL    5

fused_sextw_done:
    li      s3, 9
    call    return_four
    beq     s3, a0, fail_third
    PASS

fail_third:
    FAIL    6

return_four:
    addi    sp, sp, -16
    sd      ra, 0(sp)
    li      a0, 4
    ld      ra, 0(sp)
    addi    sp, sp, 16
    ret

strlen_like:
    mv      t1, a0
strlen_loop:
    lbu     t0, 0(t1)
    beqz    t0, strlen_exit
    addi    t1, t1, 1
    j       strlen_loop
strlen_exit:
    sub     a0, t1, a0
    ret

    .option pop

    .section .rodata
test_name:
    .asciz "cpus"

    .section .tohost,"aw",@progbits
    .globl tohost
tohost:
    .dword 0

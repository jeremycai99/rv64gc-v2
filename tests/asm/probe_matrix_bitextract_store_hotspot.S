/*
 * probe_matrix_bitextract_store_hotspot.S
 *
 * Focused Step-3 reproducer for CoreMark matrix bitextract behavior.
 * Expected stall signature: MUL-result and store/SQ readiness on a compact
 * multiply/bitextract/store loop.
 */

#include "test_macros.h"

    .section .text.init
    .globl _start
_start:
    li      sp, 0x800FFFF0
    li      s0, 260
    li      s1, 0

outer_loop:
    la      a0, mat_a
    la      a1, mat_b
    la      a2, mat_c
    li      a3, 64
    call    matrix_bitextract_loop
    add     s1, s1, a0
    addi    s0, s0, -1
    bnez    s0, outer_loop

    beqz    s1, matrix_fail
    PASS

matrix_fail:
    FAIL 3

matrix_bitextract_loop:
    li      t6, 0
matrix_loop:
    lw      t0, 0(a0)
    lw      t1, 0(a1)
    mulw    t2, t0, t1
    sraiw   t3, t2, 2
    sraiw   t4, t2, 5
    andi    t3, t3, 15
    andi    t4, t4, 127
    mulw    t5, t3, t4
    addw    t6, t6, t5
    sw      t6, 0(a2)
    addi    a0, a0, 4
    addi    a1, a1, 4
    addi    a2, a2, 4
    addi    a3, a3, -1
    bnez    a3, matrix_loop
    mv      a0, t6
    ret

    .section .data
    .align 4
mat_a:
    .rept 64
    .word 0x00012345
    .endr
mat_b:
    .rept 64
    .word 0x00000133
    .endr
mat_c:
    .space 256

    .section .tohost,"aw",@progbits
    .globl tohost
tohost:
    .dword 0

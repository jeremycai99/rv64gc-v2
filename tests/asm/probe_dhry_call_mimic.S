/*
 * probe_dhry_call_mimic.S — Phase D probe for H2 + H4 (load wakeup latency
 *                          + dhry-specific 2-PC load hot-spot)
 *
 * Mimics Dhrystone's Proc_1..Proc_7 call topology — NOT a generic call_burst.
 * Per outer-loop iteration: 4 nested calls with mixed argument shapes,
 * each with a real prologue/epilogue (push 2-3 callee-saved regs to stack,
 * load args, return value chained). This reproduces the procedure-entry
 * load-burst pattern that creates head_not_ready_load=27% on dhry.
 *
 * Expected behavior: head_not_ready_load dominates this probe's stall
 * profile (just like dhry); fix-validation = head_not_ready_load drops
 * proportionally with H2/H4 fix.
 */

#include "test_macros.h"

    .section .text.init
    .globl _start
_start:
    li      sp, 0x800FFFF0      // stack high in valid memory (matches dhry crt0 convention)
    li      s2, 200             // outer-loop count (callee-saved, won't be clobbered by calls)
    li      s0, 0               // accumulator

outer_loop:
    addi    sp, sp, -32         // outer prologue
    sd      ra,  0(sp)
    sd      s0,  8(sp)
    sd      s1, 16(sp)
    sd      s2, 24(sp)

    li      a1, 5
    li      a2, 7
    call    proc_a              // proc_a(5, 7) -> a0
    mv      s1, a0

    mv      a1, s1
    call    proc_b              // proc_b(s1) -> a0
    mv      s1, a0

    mv      a1, s1
    li      a2, 11
    li      a3, 13
    call    proc_c              // proc_c(s1, 11, 13) -> a0
    add     s0, s0, a0          // accumulate

    call    proc_d              // proc_d() -> a0
    add     s0, s0, a0

    ld      ra,  0(sp)          // outer epilogue
    ld      s0,  8(sp)
    ld      s1, 16(sp)
    ld      s2, 24(sp)
    addi    sp, sp, 32

    addi    s2, s2, -1
    bnez    s2, outer_loop

    PASS

# ----- proc_a(a, b) -> a + b * 2 -------------------------------------------
proc_a:
    addi    sp, sp, -16
    sd      ra,  0(sp)
    sd      s0,  8(sp)
    mv      s0, a1              // save b
    slli    s0, s0, 1           // b * 2
    add     a0, a1, s0          // returns a + b*2 (uses arg-load pattern)
    ld      ra,  0(sp)
    ld      s0,  8(sp)
    addi    sp, sp, 16
    ret

# ----- proc_b(x) -> x ^ (x << 3) -------------------------------------------
proc_b:
    addi    sp, sp, -16
    sd      ra,  0(sp)
    sd      s0,  8(sp)
    mv      s0, a1
    slli    s0, s0, 3
    xor     a0, a1, s0
    ld      ra,  0(sp)
    ld      s0,  8(sp)
    addi    sp, sp, 16
    ret

# ----- proc_c(x, y, z) -> x + y - z ----------------------------------------
proc_c:
    addi    sp, sp, -24
    sd      ra,  0(sp)
    sd      s0,  8(sp)
    sd      s1, 16(sp)
    mv      s0, a1
    mv      s1, a2
    add     a0, s0, s1
    sub     a0, a0, a3
    ld      ra,  0(sp)
    ld      s0,  8(sp)
    ld      s1, 16(sp)
    addi    sp, sp, 24
    ret

# ----- proc_d() -> 17 ------------------------------------------------------
proc_d:
    addi    sp, sp, -8
    sd      ra,  0(sp)
    li      a0, 17
    ld      ra,  0(sp)
    addi    sp, sp, 8
    ret

    .section .tohost,"aw",@progbits
    .globl tohost
tohost:
    .dword 0

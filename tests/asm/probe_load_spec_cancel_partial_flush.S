/*
 * probe_load_spec_cancel_partial_flush.S
 *
 * Directed Stage 3 LSU/IQ probe for a partial-flush speculative-load wakeup
 * cancel race.  The older cold load should cancel its speculative wakeup on a
 * miss even when a younger branch produces a partial flush in the same window.
 * If cancel is lost, the older dependent branch can read the stale pre-load
 * value and fall into the failure path.
 */

#include "test_macros.h"

    .option push
    .option norvc

    .section .text.init
    .globl _start
_start:
    li      sp, 0x800ffff0
    la      a0, cold_zero_lines

    /* First cold iteration is the highest-risk window for the miss/cancel race. */
    li      t0, 1
    ld      t0, 0(a0)
    beqz    t0, first_ok
    beq     zero, zero, fail_stale_first
first_ok:

    /*
     * Repeat across more cold lines so the probe remains useful if frontend
     * timing moves slightly.  Every loaded value is zero; stale t0 is one.
     */
    li      t2, 1
    li      t3, 31
loop_next:
    addi    a0, a0, 64
    mv      t0, t2
    ld      t0, 0(a0)
    beqz    t0, loop_ok
    beq     zero, zero, fail_stale_loop
loop_ok:
    addi    t3, t3, -1
    bnez    t3, loop_next

    PASS

fail_stale_first:
    FAIL    1

fail_stale_loop:
    FAIL    2

    .option pop

    .section .data
    .align 6
cold_zero_lines:
    .rept 32
    .dword 0
    .zero 56
    .endr

    .section .tohost,"aw",@progbits
    .globl tohost
tohost:
    .dword 0

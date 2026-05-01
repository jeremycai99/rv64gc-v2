/*
 * probe_bpu_data_dep_branch.S — Phase D probe for H3 (BPU mispredict cascade)
 *
 * LFSR-driven data-dependent branch in tight loop. Mimics the cm
 * 0x8000235a profile (100% mispredict on a structurally-adversarial branch).
 *
 * If H3 is intrinsic-to-workload (TAGE structurally can't predict random),
 * this probe shows the same ~50% mispredict rate regardless of TAGE depth.
 * If H3 is "TAGE training pipeline narrowing slowed it", this probe will
 * show better hit rate as the loop runs longer.
 */

#include "test_macros.h"

    .section .text.init
    .globl _start
_start:
    la      a0, lfsr_state
    li      a1, 1000            // iter count
    li      t6, 0xACE1          // initial seed (will be replaced by LFSR-state load)

loop:
    lw      t0, 0(a0)           // load LFSR state
    // 16-bit LFSR via xor-shift (rough — biased but adversarial enough)
    slli    t1, t0, 13
    xor     t0, t0, t1
    srli    t1, t0, 17
    xor     t0, t0, t1
    slli    t1, t0, 5
    xor     t0, t0, t1
    sw      t0, 0(a0)           // store back

    andi    t1, t0, 1           // bit 0 (data-dependent)
    bnez    t1, l_taken
    addi    a2, a2, 1           // not-taken path
    j       l_after
l_taken:
    addi    a3, a3, 1           // taken path
l_after:
    addi    a1, a1, -1
    bnez    a1, loop

    PASS

    .section .data
    .align 4
lfsr_state:
    .word 0xdeadbeef

    .section .tohost,"aw",@progbits
    .globl tohost
tohost:
    .dword 0

/*
 * rv64ufd_fp_smoke.S - Basic RV64F/D datapath smoke tests
 *
 * Exercises FP register allocation, FMV integer crossings, FPnew arithmetic,
 * FP load/store paths, and FLW NaN-boxing.
 */

#include "test_macros.h"

    .section .text.init
    .globl _start
_start:

    # FMV.D.X and FMV.X.D preserve the 64-bit payload.
    li      t0, 0x3ff0000000000000
    fmv.d.x f0, t0
    fmv.x.d a0, f0
    TEST_CASE 1, a0, 0x3ff0000000000000

    # 1.0 + 2.0 = 3.0
    li      t0, 0x4000000000000000
    fmv.d.x f1, t0
    fadd.d  f2, f0, f1, rne
    fmv.x.d a0, f2
    TEST_CASE 2, a0, 0x4008000000000000

    # 2.0 * 3.0 = 6.0
    fmul.d  f3, f1, f2, rne
    fmv.x.d a0, f3
    TEST_CASE 3, a0, 0x4018000000000000

    # FSD/FLD round trip through the data path.
    la      t1, fp_scratch
    fsd     f3, 0(t1)
    fld     f4, 0(t1)
    fmv.x.d a0, f4
    TEST_CASE 4, a0, 0x4018000000000000

    # FLW must NaN-box into the 64-bit FP register file.
    la      t1, single_one_half
    flw     f5, 0(t1)
    fmv.x.d a0, f5
    TEST_CASE 5, a0, 0xffffffff3fc00000

    # FP to integer and integer to FP conversion.
    fcvt.l.d a0, f2, rtz
    TEST_CASE 6, a0, 3
    fcvt.d.l f6, a0, rne
    fmv.x.d a1, f6
    TEST_CASE 7, a1, 0x4008000000000000

    PASS

    .section .data
    .align 3
fp_scratch:
    .dword 0
single_one_half:
    .word 0x3fc00000

    .section .tohost,"aw",@progbits
    .globl tohost
tohost:
    .dword 0

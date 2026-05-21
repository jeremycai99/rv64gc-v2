/*
 * probe_dcache_p0_miss_retry.S
 *
 * Directed LSU/D-cache smoke for load port 0 miss-retry handling.  Twenty four
 * independent cold loads target different cache lines so the 16-entry L1D
 * MSHR pool can fill before all requests are accepted.
 */

#include "test_macros.h"

    .section .text.init
    .globl _start
_start:
    la      a0, lines

    ld      t0,     0(a0)
    ld      t1,    64(a0)
    ld      t2,   128(a0)
    ld      t3,   192(a0)
    ld      t4,   256(a0)
    ld      t5,   320(a0)
    ld      t6,   384(a0)
    ld      a1,   448(a0)
    ld      a2,   512(a0)
    ld      a3,   576(a0)
    ld      a4,   640(a0)
    ld      a5,   704(a0)
    ld      a6,   768(a0)
    ld      a7,   832(a0)
    ld      s1,   896(a0)
    ld      s2,   960(a0)
    ld      s3,  1024(a0)
    ld      s4,  1088(a0)
    ld      s5,  1152(a0)
    ld      s6,  1216(a0)
    ld      s7,  1280(a0)
    ld      s8,  1344(a0)
    ld      s9,  1408(a0)
    ld      s10, 1472(a0)

    add     s0, t0, t1
    add     s0, s0, t2
    add     s0, s0, t3
    add     s0, s0, t4
    add     s0, s0, t5
    add     s0, s0, t6
    add     s0, s0, a1
    add     s0, s0, a2
    add     s0, s0, a3
    add     s0, s0, a4
    add     s0, s0, a5
    add     s0, s0, a6
    add     s0, s0, a7
    add     s0, s0, s1
    add     s0, s0, s2
    add     s0, s0, s3
    add     s0, s0, s4
    add     s0, s0, s5
    add     s0, s0, s6
    add     s0, s0, s7
    add     s0, s0, s8
    add     s0, s0, s9
    add     s0, s0, s10

    li      s11, 300
    bne     s0, s11, fail

    PASS

fail:
    FAIL    1

    .section .data
    .align 6
lines:
    .dword 1
    .zero 56
    .dword 2
    .zero 56
    .dword 3
    .zero 56
    .dword 4
    .zero 56
    .dword 5
    .zero 56
    .dword 6
    .zero 56
    .dword 7
    .zero 56
    .dword 8
    .zero 56
    .dword 9
    .zero 56
    .dword 10
    .zero 56
    .dword 11
    .zero 56
    .dword 12
    .zero 56
    .dword 13
    .zero 56
    .dword 14
    .zero 56
    .dword 15
    .zero 56
    .dword 16
    .zero 56
    .dword 17
    .zero 56
    .dword 18
    .zero 56
    .dword 19
    .zero 56
    .dword 20
    .zero 56
    .dword 21
    .zero 56
    .dword 22
    .zero 56
    .dword 23
    .zero 56
    .dword 24
    .zero 56

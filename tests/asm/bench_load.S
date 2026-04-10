/*
 * bench_load.S - Minimal store+load test for debugging load path.
 * Stores 0x1234 to 0x80002000, loads it back, checks value.
 */

    .section .text.init
    .globl _start
_start:
    # Store a value
    li   t0, 0x80002000
    li   t1, 0x1234
    sd   t1, 0(t0)

    # Load it back
    ld   t2, 0(t0)

    # Compare
    li   t3, 0x1234
    bne  t2, t3, fail

    # PASS
    li   t0, 0x80001000
    li   t1, 1
    sd   t1, 0(t0)
    j    .

fail:
    li   t0, 0x80001000
    li   t1, 3
    sd   t1, 0(t0)
    j    .

/*
 * rv64ui_minimal.S - Minimal pass test (no branches)
 * Just writes 1 to tohost and loops.
 */

    .section .text.init
    .globl _start
_start:
    # Write 1 to tohost (0x80001000) = PASS
    lui   t0, 0x80001        # t0 = 0x80001000
    addi  t1, x0, 1          # t1 = 1
    sd    t1, 0(t0)          # tohost = 1
    j     .                  # infinite loop

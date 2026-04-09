#ifndef TEST_MACROS_H
#define TEST_MACROS_H

#define TOHOST_ADDR 0x80001000

// Write value to tohost
.macro WRITE_TOHOST val
    li t0, TOHOST_ADDR
    li t1, \val
    sd t1, 0(t0)
.endm

// Pass test
.macro PASS
    WRITE_TOHOST 1
    j .
.endm

// Fail with test number
.macro FAIL testnum
    li t1, (\testnum << 1) | 1
    li t0, TOHOST_ADDR
    sd t1, 0(t0)
    j .
.endm

// Test: compare register to expected value
// If mismatch, fail with test number
.macro TEST_CASE testnum, reg, expected
    li t2, \expected
    bne \reg, t2, test_fail_\testnum
    j test_pass_\testnum
test_fail_\testnum:
    FAIL \testnum
test_pass_\testnum:
.endm

#endif

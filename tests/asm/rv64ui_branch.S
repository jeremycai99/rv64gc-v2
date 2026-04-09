/*
 * rv64ui_branch.S - Branch instruction tests
 *
 * Tests BEQ, BNE, BLT, BGE, BLTU, BGEU with taken and not-taken cases.
 */

#include "test_macros.h"

    .section .text.init
    .globl _start
_start:

    # ------------------------------------------------------------------
    # Test 1: BEQ taken (equal values)
    # ------------------------------------------------------------------
    li   a0, 5
    li   a1, 5
    beq  a0, a1, test1_ok
    FAIL 1
test1_ok:
    li   a2, 1   # mark reached
    TEST_CASE 1, a2, 1

    # ------------------------------------------------------------------
    # Test 2: BEQ not taken (unequal values)
    # ------------------------------------------------------------------
    li   a0, 5
    li   a1, 6
    li   a2, 1
    beq  a0, a1, test2_fail_branch
    j    test2_ok
test2_fail_branch:
    FAIL 2
test2_ok:
    TEST_CASE 2, a2, 1

    # ------------------------------------------------------------------
    # Test 3: BNE taken (unequal values)
    # ------------------------------------------------------------------
    li   a0, 10
    li   a1, 20
    bne  a0, a1, test3_ok
    FAIL 3
test3_ok:
    li   a2, 1
    TEST_CASE 3, a2, 1

    # ------------------------------------------------------------------
    # Test 4: BNE not taken (equal values)
    # ------------------------------------------------------------------
    li   a0, 7
    li   a1, 7
    li   a2, 1
    bne  a0, a1, test4_fail_branch
    j    test4_ok
test4_fail_branch:
    FAIL 4
test4_ok:
    TEST_CASE 4, a2, 1

    # ------------------------------------------------------------------
    # Test 5: BLT taken (signed less than)
    # ------------------------------------------------------------------
    li   a0, -1
    li   a1, 1
    blt  a0, a1, test5_ok
    FAIL 5
test5_ok:
    li   a2, 1
    TEST_CASE 5, a2, 1

    # ------------------------------------------------------------------
    # Test 6: BLT not taken (equal)
    # ------------------------------------------------------------------
    li   a0, 5
    li   a1, 5
    li   a2, 1
    blt  a0, a1, test6_fail_branch
    j    test6_ok
test6_fail_branch:
    FAIL 6
test6_ok:
    TEST_CASE 6, a2, 1

    # ------------------------------------------------------------------
    # Test 7: BLT not taken (greater)
    # ------------------------------------------------------------------
    li   a0, 10
    li   a1, 5
    li   a2, 1
    blt  a0, a1, test7_fail_branch
    j    test7_ok
test7_fail_branch:
    FAIL 7
test7_ok:
    TEST_CASE 7, a2, 1

    # ------------------------------------------------------------------
    # Test 8: BGE taken (equal)
    # ------------------------------------------------------------------
    li   a0, 3
    li   a1, 3
    bge  a0, a1, test8_ok
    FAIL 8
test8_ok:
    li   a2, 1
    TEST_CASE 8, a2, 1

    # ------------------------------------------------------------------
    # Test 9: BGE taken (greater)
    # ------------------------------------------------------------------
    li   a0, 10
    li   a1, 5
    bge  a0, a1, test9_ok
    FAIL 9
test9_ok:
    li   a2, 1
    TEST_CASE 9, a2, 1

    # ------------------------------------------------------------------
    # Test 10: BLTU (unsigned less than)
    # ------------------------------------------------------------------
    li   a0, 5
    li   a1, 10
    bltu a0, a1, test10_ok
    FAIL 10
test10_ok:
    li   a2, 1
    TEST_CASE 10, a2, 1

    # ------------------------------------------------------------------
    # Test 11: BLTU not taken (-1 unsigned > 1)
    # ------------------------------------------------------------------
    li   a0, -1        # 0xFFFFFFFF_FFFFFFFF (largest unsigned)
    li   a1, 1
    li   a2, 1
    bltu a0, a1, test11_fail_branch
    j    test11_ok
test11_fail_branch:
    FAIL 11
test11_ok:
    TEST_CASE 11, a2, 1

    # ------------------------------------------------------------------
    # Test 12: BGEU taken (-1 unsigned >= 1)
    # ------------------------------------------------------------------
    li   a0, -1
    li   a1, 1
    bgeu a0, a1, test12_ok
    FAIL 12
test12_ok:
    li   a2, 1
    TEST_CASE 12, a2, 1

    PASS

    .section .tohost,"aw",@progbits
    .globl tohost
tohost:
    .dword 0

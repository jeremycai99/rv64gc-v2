/*
 * rv64ui_zbs.S - Zbs extension tests (single-bit manipulation)
 *
 * Tests bset, bclr, binv, bext with register and immediate forms.
 */

#include "test_macros.h"

    .section .text.init
    .globl _start
_start:

    # ------------------------------------------------------------------
    # Test 1: BSET (set bit N in rs1)
    # bset(0, 5) => 0x20 (set bit 5)
    # ------------------------------------------------------------------
    li   a0, 0
    li   a1, 5
    bset a2, a0, a1
    TEST_CASE 1, a2, 0x20

    # ------------------------------------------------------------------
    # Test 2: BSETI (set bit N, immediate form)
    # bseti(0, 10) => 0x400 (set bit 10)
    # ------------------------------------------------------------------
    li   a0, 0
    bseti a2, a0, 10
    TEST_CASE 2, a2, 0x400

    # ------------------------------------------------------------------
    # Test 3: BCLR (clear bit N in rs1)
    # bclr(0xFF, 3) => 0xF7 (clear bit 3)
    # ------------------------------------------------------------------
    li   a0, 0xFF
    li   a1, 3
    bclr a2, a0, a1
    TEST_CASE 3, a2, 0xF7

    # ------------------------------------------------------------------
    # Test 4: BCLRI (clear bit N, immediate form)
    # bclri(0xFF, 7) => 0x7F (clear bit 7)
    # ------------------------------------------------------------------
    li   a0, 0xFF
    bclri a2, a0, 7
    TEST_CASE 4, a2, 0x7F

    # ------------------------------------------------------------------
    # Test 5: BINV (invert bit N in rs1)
    # binv(0x00, 4) => 0x10 (invert bit 4: 0->1)
    # ------------------------------------------------------------------
    li   a0, 0x00
    li   a1, 4
    binv a2, a0, a1
    TEST_CASE 5, a2, 0x10

    # ------------------------------------------------------------------
    # Test 6: BINVI (invert bit N, immediate form)
    # binvi(0x10, 4) => 0x00 (invert bit 4: 1->0)
    # ------------------------------------------------------------------
    li   a0, 0x10
    binvi a2, a0, 4
    TEST_CASE 6, a2, 0x00

    # ------------------------------------------------------------------
    # Test 7: BEXT (extract bit N from rs1)
    # bext(0xFF, 3) => 1 (bit 3 of 0xFF is 1)
    # ------------------------------------------------------------------
    li   a0, 0xFF
    li   a1, 3
    bext a2, a0, a1
    TEST_CASE 7, a2, 1

    # ------------------------------------------------------------------
    # Test 8: BEXTI (extract bit N, immediate form)
    # bexti(0x80, 7) => 1 (bit 7 of 0x80 is 1)
    # bexti(0x80, 6) => 0 (bit 6 of 0x80 is 0)
    # ------------------------------------------------------------------
    li   a0, 0x80
    bexti a2, a0, 7
    TEST_CASE 8, a2, 1

    PASS

    .section .tohost,"aw",@progbits
    .globl tohost
tohost:
    .dword 0

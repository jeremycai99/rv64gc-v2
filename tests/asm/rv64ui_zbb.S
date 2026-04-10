/*
 * rv64ui_zbb.S - Zbb extension tests (basic bit manipulation)
 *
 * Tests clz, ctz, cpop, min, max, andn, orn, xnor, rol, ror,
 * rev8, orc.b, sext.b, sext.h
 */

#include "test_macros.h"

    .section .text.init
    .globl _start
_start:

    # ------------------------------------------------------------------
    # Test 1: CLZ (count leading zeros) - 64-bit
    # clz of 1 => 63 leading zeros
    # ------------------------------------------------------------------
    li   a0, 1
    clz  a2, a0
    TEST_CASE 1, a2, 63

    # ------------------------------------------------------------------
    # Test 2: CLZ of 0x8000000000000000 => 0 leading zeros
    # ------------------------------------------------------------------
    li   a0, 1
    slli a0, a0, 63
    clz  a2, a0
    TEST_CASE 2, a2, 0

    # ------------------------------------------------------------------
    # Test 3: CTZ (count trailing zeros)
    # ctz of 0x80 => 7 trailing zeros
    # ------------------------------------------------------------------
    li   a0, 0x80
    ctz  a2, a0
    TEST_CASE 3, a2, 7

    # ------------------------------------------------------------------
    # Test 4: CPOP (population count / number of set bits)
    # cpop of 0xFF => 8 bits set
    # ------------------------------------------------------------------
    li   a0, 0xFF
    cpop a2, a0
    TEST_CASE 4, a2, 8

    # ------------------------------------------------------------------
    # Test 5: MIN (signed minimum)
    # min(-5, 10) => -5
    # ------------------------------------------------------------------
    li   a0, -5
    li   a1, 10
    min  a2, a0, a1
    TEST_CASE 5, a2, -5

    # ------------------------------------------------------------------
    # Test 6: MAX (signed maximum)
    # max(-5, 10) => 10
    # ------------------------------------------------------------------
    li   a0, -5
    li   a1, 10
    max  a2, a0, a1
    TEST_CASE 6, a2, 10

    # ------------------------------------------------------------------
    # Test 7: ANDN (and-not: rs1 & ~rs2)
    # 0xFF & ~0x0F = 0xF0
    # ------------------------------------------------------------------
    li   a0, 0xFF
    li   a1, 0x0F
    andn a2, a0, a1
    TEST_CASE 7, a2, 0xF0

    # ------------------------------------------------------------------
    # Test 8: ORN (or-not: rs1 | ~rs2)
    # 0x00 | ~0x0F = ~0x0F = 0xFFFFFFFF_FFFFFFF0
    # ------------------------------------------------------------------
    li   a0, 0x00
    li   a1, 0x0F
    orn  a2, a0, a1
    TEST_CASE 8, a2, -16     # -16 = 0xFFFF...FFF0

    # ------------------------------------------------------------------
    # Test 9: XNOR (exclusive nor: ~(rs1 ^ rs2))
    # xnor(0xFF, 0xFF) = ~0 = 0xFFFF...FFFF = -1
    # ------------------------------------------------------------------
    li   a0, 0xFF
    li   a1, 0xFF
    xnor a2, a0, a1
    TEST_CASE 9, a2, -1

    # ------------------------------------------------------------------
    # Test 10: ROL (rotate left)
    # rol(1, 5) => 0x20 (bit 0 rotated left 5 positions)
    # ------------------------------------------------------------------
    li   a0, 1
    li   a1, 5
    rol  a2, a0, a1
    TEST_CASE 10, a2, 0x20

    # ------------------------------------------------------------------
    # Test 11: ROR (rotate right)
    # ror(0x80, 4) => 0x08
    # ------------------------------------------------------------------
    li   a0, 0x80
    li   a1, 4
    ror  a2, a0, a1
    TEST_CASE 11, a2, 0x08

    # ------------------------------------------------------------------
    # Test 12: REV8 (byte-reverse)
    # rev8(0x0102030405060708) => 0x0807060504030201
    # ------------------------------------------------------------------
    li   a0, 0x01020304
    slli a0, a0, 32
    li   a1, 0x05060708
    or   a0, a0, a1          # a0 = 0x0102030405060708
    rev8 a2, a0
    li   a1, 0x08070605
    slli a1, a1, 32
    li   a3, 0x04030201
    or   a3, a1, a3          # a3 = 0x0807060504030201
    # Explicit comparison because the expected immediate is 64-bit and does
    # not fit in TEST_CASE's sign-extended 12-bit li.
    bne  a2, a3, rev8_fail
    j    rev8_ok
rev8_fail:
    FAIL 12
rev8_ok:

    # ------------------------------------------------------------------
    # Test 13: SEXT.B (sign-extend byte)
    # sext.b(0x80) => 0xFFFFFFFF_FFFFFF80 = -128
    # ------------------------------------------------------------------
    li   a0, 0x80
    sext.b a2, a0
    TEST_CASE 13, a2, -128

    # ------------------------------------------------------------------
    # Test 14: SEXT.H (sign-extend halfword)
    # sext.h(0x8000) => 0xFFFFFFFF_FFFF8000 = -32768
    # ------------------------------------------------------------------
    li   a0, 0x8000
    sext.h a2, a0
    TEST_CASE 14, a2, -32768

    # ------------------------------------------------------------------
    # Test 15: ORC.B (or-combine bytes)
    # Each byte: if any bit set, byte becomes 0xFF; else 0x00
    # orc.b(0x0100008000000001) =>
    #   byte7=0x01->0xFF, byte6=0x00->0x00, byte5=0x00->0x00,
    #   byte4=0x80->0xFF, byte3=0x00->0x00, byte2=0x00->0x00,
    #   byte1=0x00->0x00, byte0=0x01->0xFF
    # => 0xFF0000FF000000FF
    # ------------------------------------------------------------------
    li   a0, 0x01000080
    slli a0, a0, 32
    li   a1, 0x00000001
    or   a0, a0, a1          # a0 = 0x0100008000000001
    orc.b a2, a0
    li   a3, 0xFF0000FF
    slli a3, a3, 32
    li   a4, 0x000000FF
    or   a3, a3, a4          # a3 = 0xFF0000FF000000FF
    bne  a2, a3, orcb_fail
    j    orcb_ok
orcb_fail:
    FAIL 15
orcb_ok:

    PASS

    .section .tohost,"aw",@progbits
    .globl tohost
tohost:
    .dword 0

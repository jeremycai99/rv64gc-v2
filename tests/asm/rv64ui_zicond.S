/*
 * rv64ui_zicond.S - Zicond extension tests (conditional zero)
 *
 * Tests czero.eqz and czero.nez:
 *   czero.eqz rd, rs1, rs2: rd = (rs2 == 0) ? 0 : rs1
 *   czero.nez rd, rs1, rs2: rd = (rs2 != 0) ? 0 : rs1
 */

#include "test_macros.h"

    .section .text.init
    .globl _start
_start:

    # ------------------------------------------------------------------
    # Test 1: czero.eqz with rs2 == 0 => rd = 0
    # ------------------------------------------------------------------
    li   a0, 42             # rs1 = value
    li   a1, 0              # rs2 = 0 (condition)
    czero.eqz a2, a0, a1   # rs2==0, so rd = 0
    TEST_CASE 1, a2, 0

    # ------------------------------------------------------------------
    # Test 2: czero.eqz with rs2 != 0 => rd = rs1
    # ------------------------------------------------------------------
    li   a0, 42
    li   a1, 1              # rs2 != 0
    czero.eqz a2, a0, a1   # rs2!=0, so rd = rs1 = 42
    TEST_CASE 2, a2, 42

    # ------------------------------------------------------------------
    # Test 3: czero.nez with rs2 != 0 => rd = 0
    # ------------------------------------------------------------------
    li   a0, 99
    li   a1, 1              # rs2 != 0
    czero.nez a2, a0, a1   # rs2!=0, so rd = 0
    TEST_CASE 3, a2, 0

    # ------------------------------------------------------------------
    # Test 4: czero.nez with rs2 == 0 => rd = rs1
    # ------------------------------------------------------------------
    li   a0, 99
    li   a1, 0              # rs2 == 0
    czero.nez a2, a0, a1   # rs2==0, so rd = rs1 = 99
    TEST_CASE 4, a2, 99

    # ------------------------------------------------------------------
    # Test 5: czero.eqz with large rs1 and rs2 != 0
    # ------------------------------------------------------------------
    li   a0, 0x123456789   # large value
    li   a1, -1             # rs2 != 0
    czero.eqz a2, a0, a1   # rd = rs1
    TEST_CASE 5, a2, 0x123456789

    # ------------------------------------------------------------------
    # Test 6: czero.nez with large rs1 and rs2 == large
    # ------------------------------------------------------------------
    li   a0, 0xDEADBEEF
    li   a1, 0xCAFE         # rs2 != 0
    czero.nez a2, a0, a1   # rs2!=0, so rd = 0
    TEST_CASE 6, a2, 0

    PASS

    .section .tohost,"aw",@progbits
    .globl tohost
tohost:
    .dword 0

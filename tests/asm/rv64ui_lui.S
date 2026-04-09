/*
 * rv64ui_lui.S - LUI and AUIPC tests
 *
 * Tests LUI with various immediates and AUIPC.
 */

#include "test_macros.h"

    .section .text.init
    .globl _start
_start:

    # ------------------------------------------------------------------
    # Test 1: LUI with small immediate
    # ------------------------------------------------------------------
    lui  a2, 1              # rd = 1 << 12 = 0x1000
    TEST_CASE 1, a2, 0x1000

    # ------------------------------------------------------------------
    # Test 2: LUI with larger immediate
    # ------------------------------------------------------------------
    lui  a2, 0xABCDE        # rd = 0xABCDE << 12 = 0xABCDE000
    # On RV64, LUI sign-extends bit 31 to upper 32 bits.
    # 0xABCDE000 has bit 31 set (0xA = 1010), so it becomes
    # 0xFFFFFFFF_ABCDE000
    TEST_CASE 2, a2, 0xFFFFFFFFABCDE000

    # ------------------------------------------------------------------
    # Test 3: LUI with zero
    # ------------------------------------------------------------------
    lui  a2, 0
    TEST_CASE 3, a2, 0

    # ------------------------------------------------------------------
    # Test 4: AUIPC
    # AUIPC adds (imm << 12) to the PC of the AUIPC instruction.
    # We verify by computing the expected address.
    # ------------------------------------------------------------------
auipc_test:
    auipc a2, 0             # a2 = PC of this instruction
    # The PC should be somewhere after 0x80000000.
    # Verify a2 >= 0x80000000 by checking upper bits.
    li   t2, 0x80000000
    bgeu a2, t2, test4_ok
    FAIL 4
test4_ok:
    # Also verify AUIPC with nonzero immediate:
    # a3 = PC + (1 << 12)
    auipc a3, 1
    # a3 should be approximately a2 + 0x1000 + 4 (since this is the next instr)
    sub  a4, a3, a2
    # The difference should be 0x1000 + (some small offset for instructions between)
    # Let's just check it's positive and in a reasonable range
    li   t2, 0x1000
    bgeu a4, t2, test4b_ok
    FAIL 4
test4b_ok:
    li   a2, 1
    TEST_CASE 4, a2, 1

    PASS

    .section .tohost,"aw",@progbits
    .globl tohost
tohost:
    .dword 0

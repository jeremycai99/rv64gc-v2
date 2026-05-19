/*
 * probe_auipc_ld_dep.S
 *
 * Directed Linux boot debug probe for an adjacent AUIPC+LD pair where the
 * load base register is also the AUIPC destination.  This mirrors kernel GOT
 * loads such as:
 *
 *     auipc a5, imm20
 *     ld    a5, imm12(a5)
 *
 * The test poisons a5 first so a dependency or fusion miss becomes visible.
 */

#include "test_macros.h"

    .option push
    .option norvc

    .section .text.init
    .globl _start
_start:
    li      sp, 0x800ffff0

    li      a5, 0xfffffffff0000000
1:
    auipc   a5, %pcrel_hi(dep_value)
    ld      a5, %pcrel_lo(1b)(a5)

    li      t0, 0x1122334455667788
    bne     a5, t0, fail_dep

    li      a5, 0xfffffffff0000000
2:
    auipc   a4, %pcrel_hi(dep_value)
    ld      a5, %pcrel_lo(2b)(a4)

    bne     a5, t0, fail_distinct
    PASS

fail_dep:
    FAIL    1

fail_distinct:
    FAIL    2

    .option pop

    .section .rodata
    .balign 8
dep_value:
    .dword 0x1122334455667788

    .section .tohost,"aw",@progbits
    .globl tohost
tohost:
    .dword 0

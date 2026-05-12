/*
 * vm_superpage_sv48_smoke.S
 *
 * Directed Stage 3 smoke for Sv48 DTLB superpage translation. Fetch stays in
 * M-mode physical addressing while MPRV/MPP=S makes LSU accesses use S-mode
 * virtual memory. The test covers positive 1 GiB and 2 MiB leaf mappings.
 */

#include "test_macros.h"

    .equ PT_ROOT_PA,     0x80004000
    .equ PT_L2_PA,       0x80005000
    .equ PT_L1_PA,       0x80006000
    .equ PHYS_DATA_PA,   0x80008000
    .equ VA_1G_DATA,     0x0000000000008000
    .equ VA_2M_DATA,     0x0000000040008000

    .equ PTE_V,          0x001
    .equ PTE_R,          0x002
    .equ PTE_W,          0x004
    .equ PTE_A,          0x040
    .equ PTE_D,          0x080

    .equ ROOT_PPN,       (PT_ROOT_PA >> 12)
    .equ L2_PPN,         (PT_L2_PA >> 12)
    .equ L1_PPN,         (PT_L1_PA >> 12)
    .equ DATA_BASE_PPN,  (0x80000000 >> 12)

    .equ L2_PTE,         ((L2_PPN << 10) | PTE_V)
    .equ L1_PTE,         ((L1_PPN << 10) | PTE_V)
    .equ DATA_1G_PTE,    ((DATA_BASE_PPN << 10) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)
    .equ DATA_2M_PTE,    ((DATA_BASE_PPN << 10) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)

    .equ SATP_SV48,      ((9 << 60) | ROOT_PPN)
    .equ MSTATUS_MPRV_S, ((1 << 17) | (1 << 11))
    .equ DATA_VALUE,     0x1122334455667788

    .section .text.init
    .globl _start
_start:
    li      t0, PHYS_DATA_PA
    ld      t1, 0(t0)
    li      t2, DATA_VALUE
    bne     t1, t2, fail_1

    li      t0, SATP_SV48
    csrw    satp, t0
    sfence.vma x0, x0

    li      t0, MSTATUS_MPRV_S
    csrw    mstatus, t0

    li      t0, VA_1G_DATA
    ld      t1, 0(t0)
    nop
    nop
    li      t2, DATA_VALUE
    bne     t1, t2, fail_2

    li      t0, VA_2M_DATA
    ld      t1, 0(t0)
    nop
    nop
    li      t2, DATA_VALUE
    bne     t1, t2, fail_3

    csrw    mstatus, x0
    PASS

fail_1:
    csrw    mstatus, x0
    FAIL    1
fail_2:
    csrw    mstatus, x0
    FAIL    2
fail_3:
    csrw    mstatus, x0
    FAIL    3

    .section .tohost,"aw",@progbits
    .globl tohost
tohost:
    .dword 0

    .section .vm_pt_root,"a",@progbits
    .dword L2_PTE
    .zero 4096 - 8

    .section .vm_pt_l2,"a",@progbits
    .dword DATA_1G_PTE
    .dword L1_PTE
    .zero 4096 - (2 * 8)

    .section .vm_pt_l1,"a",@progbits
    .dword DATA_2M_PTE
    .zero 4096 - 8

    .section .vm_phys_data,"aw",@progbits
    .dword DATA_VALUE

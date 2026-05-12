/*
 * vm_store_fault_sv48_smoke.S
 *
 * Directed Stage 3 smoke for Sv48 store page faults.
 * Fetch stays in M-mode physical addressing.  MPRV with MPP=S makes the LSU
 * use S-mode translation so a store to a read-only S page must trap precisely
 * with mcause=15 and mtval set to the faulting virtual address.
 */

#include "test_macros.h"

    .equ PT_ROOT_PA,     0x80004000
    .equ PT_L2_PA,       0x80005000
    .equ PT_L1_PA,       0x80006000
    .equ PT_L0_PA,       0x80007000
    .equ PHYS_DATA_PA,   0x80008000
    .equ TEST_VA,        0x0000000000009000

    .equ PTE_V,          0x001
    .equ PTE_R,          0x002
    .equ PTE_A,          0x040

    .equ ROOT_PPN,       (PT_ROOT_PA >> 12)
    .equ L2_PPN,         (PT_L2_PA >> 12)
    .equ L1_PPN,         (PT_L1_PA >> 12)
    .equ L0_PPN,         (PT_L0_PA >> 12)
    .equ DATA_PPN,       (PHYS_DATA_PA >> 12)

    .equ L2_PTE,         ((L2_PPN << 10) | PTE_V)
    .equ L1_PTE,         ((L1_PPN << 10) | PTE_V)
    .equ L0_PTE,         ((L0_PPN << 10) | PTE_V)
    .equ DATA_RO_PTE,    ((DATA_PPN << 10) | PTE_V | PTE_R | PTE_A)

    .equ SATP_SV48,      ((9 << 60) | ROOT_PPN)
    .equ MSTATUS_MPRV_S, ((1 << 17) | (1 << 11))
    .equ INIT_VALUE,     0x1122334455667788
    .equ STORE_VALUE,    0x8877665544332211
    .equ EXC_STORE_PAGE_FAULT, 15

    .section .text.init
    .globl _start
_start:
    la      t0, trap_handler
    csrw    mtvec, t0

    li      t0, SATP_SV48
    csrw    satp, t0
    sfence.vma x0, x0

    li      t0, MSTATUS_MPRV_S
    csrw    mstatus, t0

    li      t0, TEST_VA
    ld      t1, 0(t0)
    li      t2, INIT_VALUE
    bne     t1, t2, fail_1

    li      t2, STORE_VALUE
    sd      t2, 0(t0)

    csrw    mstatus, x0
    FAIL    2

    .align 2
trap_handler:
    csrr    t0, mcause
    li      t1, EXC_STORE_PAGE_FAULT
    bne     t0, t1, trap_fail_1

    csrr    t0, mtval
    li      t1, TEST_VA
    bne     t0, t1, trap_fail_2

    csrw    mstatus, x0
    PASS

fail_1:
    csrw    mstatus, x0
    FAIL    1

trap_fail_1:
    csrw    mstatus, x0
    FAIL    3

trap_fail_2:
    csrw    mstatus, x0
    FAIL    4

    .section .tohost,"aw",@progbits
    .globl tohost
tohost:
    .dword 0

    .section .vm_pt_root,"a",@progbits
    .dword L2_PTE
    .zero 4096 - 8

    .section .vm_pt_l2,"a",@progbits
    .dword L1_PTE
    .zero 4096 - 8

    .section .vm_pt_l1,"a",@progbits
    .dword L0_PTE
    .zero 4096 - 8

    .section .vm_pt_l0,"a",@progbits
    .zero 9 * 8
    .dword DATA_RO_PTE
    .zero 4096 - (10 * 8)

    .section .vm_phys_data,"aw",@progbits
    .dword INIT_VALUE

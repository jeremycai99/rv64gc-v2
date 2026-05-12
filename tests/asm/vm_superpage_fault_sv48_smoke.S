/*
 * vm_superpage_fault_sv48_smoke.S
 *
 * Directed Stage 3 smoke for Sv48 superpage alignment faults. It verifies that
 * misaligned 1 GiB and 2 MiB leaf PPNs are rejected by the PTW with load page
 * faults before a DTLB fill can complete.
 */

#include "test_macros.h"

    .equ PT_ROOT_PA,          0x80004000
    .equ PT_L2_PA,            0x80005000
    .equ PT_L1_PA,            0x80006000
    .equ VA_1G_DATA,          0x0000000000008000
    .equ VA_2M_DATA,          0x0000000040008000

    .equ PTE_V,               0x001
    .equ PTE_R,               0x002
    .equ PTE_W,               0x004
    .equ PTE_A,               0x040
    .equ PTE_D,               0x080

    .equ ROOT_PPN,            (PT_ROOT_PA >> 12)
    .equ L2_PPN,              (PT_L2_PA >> 12)
    .equ L1_PPN,              (PT_L1_PA >> 12)
    .equ MISALIGN_1G_PPN,     (0x80008000 >> 12)
    .equ MISALIGN_2M_PPN,     (0x80001000 >> 12)

    .equ L2_PTE,              ((L2_PPN << 10) | PTE_V)
    .equ L1_PTE,              ((L1_PPN << 10) | PTE_V)
    .equ BAD_1G_PTE,          ((MISALIGN_1G_PPN << 10) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)
    .equ BAD_2M_PTE,          ((MISALIGN_2M_PPN << 10) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)

    .equ SATP_SV48,           ((9 << 60) | ROOT_PPN)
    .equ MSTATUS_MPRV_S,      ((1 << 17) | (1 << 11))
    .equ MSTATUS_MPP_M,       (3 << 11)
    .equ EXC_LOAD_PAGE_FAULT, 13

    .section .text.init
    .globl _start
_start:
    la      t0, trap_handler
    csrw    mtvec, t0

    li      t0, SATP_SV48
    csrw    satp, t0
    sfence.vma x0, x0

    li      s2, 1
    la      t3, after_1g_fault
    csrw    mscratch, t3
    li      t0, MSTATUS_MPRV_S
    csrw    mstatus, t0
    li      t1, VA_1G_DATA
    ld      t2, 0(t1)
    csrw    mstatus, x0
    FAIL    1

after_1g_fault:
    sfence.vma x0, x0
    li      s2, 2
    la      t3, after_2m_fault
    csrw    mscratch, t3
    li      t0, MSTATUS_MPRV_S
    csrw    mstatus, t0
    li      t1, VA_2M_DATA
    ld      t2, 0(t1)
    csrw    mstatus, x0
    FAIL    2

after_2m_fault:
    csrw    satp, x0
    sfence.vma x0, x0
    csrw    mstatus, x0
    PASS

    .align 2
trap_handler:
    csrr    t0, mcause
    li      t1, EXC_LOAD_PAGE_FAULT
    bne     t0, t1, trap_fail_1

    csrr    t0, mtval
    li      t1, VA_1G_DATA
    li      t4, 1
    beq     s2, t4, check_fault_va
    li      t1, VA_2M_DATA
    li      t4, 2
    beq     s2, t4, check_fault_va
    csrw    satp, x0
    sfence.vma x0, x0
    FAIL    3

check_fault_va:
    bne     t0, t1, trap_fail_2
    csrr    t0, mscratch
    csrw    mepc, t0
    li      t0, MSTATUS_MPP_M
    csrw    mstatus, t0
    mret

trap_fail_1:
    csrw    satp, x0
    sfence.vma x0, x0
    FAIL    4
trap_fail_2:
    csrw    satp, x0
    sfence.vma x0, x0
    FAIL    5

    .section .tohost,"aw",@progbits
    .globl tohost
tohost:
    .dword 0

    .section .vm_pt_root,"a",@progbits
    .dword L2_PTE
    .zero 4096 - 8

    .section .vm_pt_l2,"a",@progbits
    .dword BAD_1G_PTE
    .dword L1_PTE
    .zero 4096 - (2 * 8)

    .section .vm_pt_l1,"a",@progbits
    .dword BAD_2M_PTE
    .zero 4096 - 8

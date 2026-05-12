/*
 * vm_canonical_sv48_smoke.S
 *
 * Directed Stage 3 smoke for Sv48 canonical-address checks. It verifies that
 * noncanonical data and instruction virtual addresses raise page faults before
 * a page-table walk can complete.
 */

#include "test_macros.h"

    .equ PT_ROOT_PA,             0x80004000
    .equ NONCANON_VA,            0x0001000000000000

    .equ PTE_V,                  0x001
    .equ ROOT_PPN,               (PT_ROOT_PA >> 12)
    .equ SATP_SV48,              ((9 << 60) | ROOT_PPN)
    .equ MSTATUS_MPRV_S,         ((1 << 17) | (1 << 11))
    .equ MSTATUS_MPP_S,          (1 << 11)
    .equ MSTATUS_MPP_M,          (3 << 11)
    .equ EXC_INSN_PAGE_FAULT,    12
    .equ EXC_LOAD_PAGE_FAULT,    13

    .section .text.init
    .globl _start
_start:
    la      t0, trap_handler
    csrw    mtvec, t0

    li      t0, SATP_SV48
    csrw    satp, t0
    sfence.vma x0, x0

    li      s2, 1
    la      t3, after_load_fault
    csrw    mscratch, t3
    li      t0, MSTATUS_MPRV_S
    csrw    mstatus, t0
    li      t1, NONCANON_VA
    ld      t2, 0(t1)
    csrw    mstatus, x0
    FAIL    1

after_load_fault:
    li      s2, 2
    li      t0, MSTATUS_MPP_S
    csrw    mstatus, t0
    li      t0, NONCANON_VA
    csrw    mepc, t0
    mret

    FAIL    2

    .align 2
trap_handler:
    csrr    t0, mcause
    li      t4, 1
    beq     s2, t4, check_load_fault
    li      t4, 2
    beq     s2, t4, check_ifetch_fault
    csrw    satp, x0
    sfence.vma x0, x0
    FAIL    3

check_load_fault:
    li      t1, EXC_LOAD_PAGE_FAULT
    bne     t0, t1, trap_fail_1
    csrr    t0, mtval
    li      t1, NONCANON_VA
    bne     t0, t1, trap_fail_2
    csrr    t0, mscratch
    csrw    mepc, t0
    li      t0, MSTATUS_MPP_M
    csrw    mstatus, t0
    mret

check_ifetch_fault:
    li      t1, EXC_INSN_PAGE_FAULT
    bne     t0, t1, trap_fail_3
    csrr    t0, mtval
    li      t1, NONCANON_VA
    bne     t0, t1, trap_fail_4
    csrw    satp, x0
    sfence.vma x0, x0
    csrw    mstatus, x0
    PASS

trap_fail_1:
    csrw    satp, x0
    sfence.vma x0, x0
    FAIL    4
trap_fail_2:
    csrw    satp, x0
    sfence.vma x0, x0
    FAIL    5
trap_fail_3:
    csrw    satp, x0
    sfence.vma x0, x0
    FAIL    6
trap_fail_4:
    csrw    satp, x0
    sfence.vma x0, x0
    FAIL    7

    .section .tohost,"aw",@progbits
    .globl tohost
tohost:
    .dword 0

    .section .vm_pt_root,"a",@progbits
    .zero 4096

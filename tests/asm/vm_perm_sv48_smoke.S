/*
 * vm_perm_sv48_smoke.S
 *
 * Directed Stage 3 smoke for Sv48 data permission checks. Fetch stays in
 * M-mode physical addressing while MPRV selects S-mode or U-mode data
 * translation. The test covers SUM, MXR, and U/S page access rules.
 */

#include "test_macros.h"

    .equ PT_ROOT_PA,     0x80004000
    .equ PT_L2_PA,       0x80005000
    .equ PT_L1_PA,       0x80006000
    .equ PT_L0_PA,       0x80007000
    .equ PHYS_DATA_PA,   0x80008000
    .equ USER_VA,        0x0000000000009000
    .equ XONLY_VA,       0x000000000000a000
    .equ SUPERVISOR_VA,  0x000000000000b000

    .equ PTE_V,          0x001
    .equ PTE_R,          0x002
    .equ PTE_X,          0x008
    .equ PTE_U,          0x010
    .equ PTE_A,          0x040
    .equ PTE_D,          0x080

    .equ ROOT_PPN,       (PT_ROOT_PA >> 12)
    .equ L2_PPN,         (PT_L2_PA >> 12)
    .equ L1_PPN,         (PT_L1_PA >> 12)
    .equ L0_PPN,         (PT_L0_PA >> 12)
    .equ DATA_PPN,       (PHYS_DATA_PA >> 12)
    .equ CODE_PPN,       (0x80000000 >> 12)

    .equ L2_PTE,         ((L2_PPN << 10) | PTE_V)
    .equ L1_PTE,         ((L1_PPN << 10) | PTE_V)
    .equ L0_PTE,         ((L0_PPN << 10) | PTE_V)
    .equ CODE_1G_PTE,    ((CODE_PPN << 10) | PTE_V | PTE_R | PTE_X | PTE_A | PTE_D)
    .equ USER_RO_PTE,    ((DATA_PPN << 10) | PTE_V | PTE_R | PTE_U | PTE_A | PTE_D)
    .equ XONLY_PTE,      ((DATA_PPN << 10) | PTE_V | PTE_X | PTE_A)
    .equ SUPER_RO_PTE,   ((DATA_PPN << 10) | PTE_V | PTE_R | PTE_A | PTE_D)

    .equ SATP_SV48,      ((9 << 60) | ROOT_PPN)
    .equ MSTATUS_MPRV_U, (1 << 17)
    .equ MSTATUS_MPRV_S, ((1 << 17) | (1 << 11))
    .equ MSTATUS_SUM,    (1 << 18)
    .equ MSTATUS_MXR,    (1 << 19)
    .equ EXC_LOAD_PAGE_FAULT, 13
    .equ DATA_VALUE,     0x1122334455667788

    .section .text.init
    .globl _start
_start:
    la      t0, trap_handler
    csrw    mtvec, t0

    li      t0, SATP_SV48
    csrw    satp, t0
    sfence.vma x0, x0

    li      s2, 1
    la      t3, after_sum_fault
    csrw    mscratch, t3
    li      t0, MSTATUS_MPRV_S
    csrw    mstatus, t0
    li      t1, USER_VA
    ld      t2, 0(t1)
    csrw    mstatus, x0
    FAIL    1

after_sum_fault:
    li      s2, 2
    la      t3, after_mxr_fault
    csrw    mscratch, t3
    li      t0, MSTATUS_MPRV_S
    csrw    mstatus, t0
    li      t1, XONLY_VA
    ld      t2, 0(t1)
    csrw    mstatus, x0
    FAIL    2

after_mxr_fault:
    li      s2, 3
    la      t3, after_user_fault
    csrw    mscratch, t3
    li      t0, MSTATUS_MPRV_U
    csrw    mstatus, t0
    li      t1, SUPERVISOR_VA
    ld      t2, 0(t1)
    csrw    mstatus, x0
    FAIL    3

after_user_fault:
    li      t0, (MSTATUS_MPRV_S | MSTATUS_SUM)
    csrw    mstatus, t0
    li      t1, USER_VA
    ld      t2, 0(t1)
    nop
    nop
    li      t3, DATA_VALUE
    bne     t2, t3, fail_4

    li      t0, (MSTATUS_MPRV_S | MSTATUS_MXR)
    csrw    mstatus, t0
    li      t1, XONLY_VA
    ld      t2, 0(t1)
    nop
    nop
    li      t3, DATA_VALUE
    bne     t2, t3, fail_5

    li      t0, MSTATUS_MPRV_U
    csrw    mstatus, t0
    li      t1, USER_VA
    ld      t2, 0(t1)
    nop
    nop
    li      t3, DATA_VALUE
    bne     t2, t3, fail_6

    csrw    mstatus, x0
    PASS

    .align 2
trap_handler:
    csrr    t0, mcause
    li      t1, EXC_LOAD_PAGE_FAULT
    bne     t0, t1, trap_fail_1

    csrr    t0, mtval
    li      t1, USER_VA
    li      t4, 1
    beq     s2, t4, check_fault_va
    li      t1, XONLY_VA
    li      t4, 2
    beq     s2, t4, check_fault_va
    li      t1, SUPERVISOR_VA
    li      t4, 3
    beq     s2, t4, check_fault_va
    csrw    mstatus, x0
    FAIL    7

check_fault_va:
    bne     t0, t1, trap_fail_2
    csrr    t0, mscratch
    csrw    mepc, t0
    mret

fail_4:
    csrw    mstatus, x0
    FAIL    4
fail_5:
    csrw    mstatus, x0
    FAIL    5
fail_6:
    csrw    mstatus, x0
    FAIL    6
trap_fail_1:
    csrw    mstatus, x0
    FAIL    8
trap_fail_2:
    csrw    mstatus, x0
    FAIL    9

    .section .tohost,"aw",@progbits
    .globl tohost
tohost:
    .dword 0

    .section .vm_pt_root,"a",@progbits
    .dword L2_PTE
    .zero 4096 - 8

    .section .vm_pt_l2,"a",@progbits
    .dword L1_PTE
    .zero 8
    .dword CODE_1G_PTE
    .zero 4096 - (3 * 8)

    .section .vm_pt_l1,"a",@progbits
    .dword L0_PTE
    .zero 4096 - 8

    .section .vm_pt_l0,"a",@progbits
    .zero 9 * 8
    .dword USER_RO_PTE
    .dword XONLY_PTE
    .dword SUPER_RO_PTE
    .zero 4096 - (12 * 8)

    .section .vm_phys_data,"aw",@progbits
    .dword DATA_VALUE

/*
 * vm_ifetch_fault_sv48_smoke.S
 *
 * Directed Stage 3 smoke for Sv48 instruction page faults.
 * M-mode setup enables Sv48 and enters S-mode at a virtual page whose PTE is
 * readable but not executable.  The trap must report mcause=12 and mtval equal
 * to the faulting virtual PC.
 */

#include "test_macros.h"

    .equ PT_ROOT_PA,             0x80004000
    .equ PT_L2_PA,               0x80005000
    .equ PT_L1_PA,               0x80006000
    .equ PT_L0_PA,               0x80007000
    .equ EXEC_PA,                0x80009000
    .equ EXEC_VA,                0x0000000000004000

    .equ PTE_V,                  0x001
    .equ PTE_R,                  0x002
    .equ PTE_A,                  0x040

    .equ ROOT_PPN,               (PT_ROOT_PA >> 12)
    .equ L2_PPN,                 (PT_L2_PA >> 12)
    .equ L1_PPN,                 (PT_L1_PA >> 12)
    .equ L0_PPN,                 (PT_L0_PA >> 12)
    .equ EXEC_PPN,               (EXEC_PA >> 12)

    .equ L2_PTE,                 ((L2_PPN << 10) | PTE_V)
    .equ L1_PTE,                 ((L1_PPN << 10) | PTE_V)
    .equ L0_PTE,                 ((L0_PPN << 10) | PTE_V)
    .equ EXEC_NOX_PTE,           ((EXEC_PPN << 10) | PTE_V | PTE_R | PTE_A)

    .equ SATP_SV48,              ((9 << 60) | ROOT_PPN)
    .equ MSTATUS_MPP_S,          (1 << 11)
    .equ EXC_INSN_PAGE_FAULT,    12

    .section .text.init
    .globl _start
_start:
    la      t0, trap_handler
    csrw    mtvec, t0

    li      t0, SATP_SV48
    csrw    satp, t0
    sfence.vma x0, x0

    li      t0, MSTATUS_MPP_S
    csrw    mstatus, t0

    li      t0, EXEC_VA
    csrw    mepc, t0
    mret

    FAIL    1

    .align 2
trap_handler:
    csrr    t0, mcause
    li      t1, EXC_INSN_PAGE_FAULT
    bne     t0, t1, trap_fail_1

    csrr    t0, mtval
    li      t1, EXEC_VA
    bne     t0, t1, trap_fail_2

    csrw    satp, x0
    sfence.vma x0, x0
    PASS

trap_fail_1:
    csrw    satp, x0
    sfence.vma x0, x0
    FAIL    2

trap_fail_2:
    csrw    satp, x0
    sfence.vma x0, x0
    FAIL    3

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
    .zero 4 * 8
    .dword EXEC_NOX_PTE
    .zero 4096 - (5 * 8)

    .section .vm_exec_code,"ax",@progbits
    .globl vm_noexec_target
vm_noexec_target:
    FAIL    4

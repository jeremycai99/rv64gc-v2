/*
 * vm_ifetch_sv48_smoke.S
 *
 * Directed Stage 3 smoke for instruction-side Sv48 translation.
 * M-mode setup enables Sv48, prepares S-mode return state, then mret jumps
 * to a supervisor virtual address whose executable page maps to a different
 * physical page.  The S-mode payload stores to a virtual tohost mapping.
 */

#include "test_macros.h"

    .equ PT_ROOT_PA,        0x80004000
    .equ PT_L2_PA,          0x80005000
    .equ PT_L1_PA,          0x80006000
    .equ PT_L0_PA,          0x80007000
    .equ TOHOST_PA,         0x80001000
    .equ EXEC_PA,           0x80009000
    .equ EXEC_VA,           0x0000000000004000
    .equ TOHOST_VA,         0x000000000000a000

    .equ PTE_V,             0x001
    .equ PTE_R,             0x002
    .equ PTE_W,             0x004
    .equ PTE_X,             0x008
    .equ PTE_A,             0x040
    .equ PTE_D,             0x080

    .equ ROOT_PPN,          (PT_ROOT_PA >> 12)
    .equ L2_PPN,            (PT_L2_PA >> 12)
    .equ L1_PPN,            (PT_L1_PA >> 12)
    .equ L0_PPN,            (PT_L0_PA >> 12)
    .equ TOHOST_PPN,        (TOHOST_PA >> 12)
    .equ EXEC_PPN,          (EXEC_PA >> 12)

    .equ L2_PTE,            ((L2_PPN << 10) | PTE_V)
    .equ L1_PTE,            ((L1_PPN << 10) | PTE_V)
    .equ L0_PTE,            ((L0_PPN << 10) | PTE_V)
    .equ EXEC_PTE,          ((EXEC_PPN << 10) | PTE_V | PTE_R | PTE_X | PTE_A)
    .equ TOHOST_PTE,        ((TOHOST_PPN << 10) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)

    .equ SATP_SV48,         ((9 << 60) | ROOT_PPN)
    .equ MSTATUS_MPP_S,     (1 << 11)

    .section .text.init
    .globl _start
_start:
    li      t0, SATP_SV48
    csrw    satp, t0
    sfence.vma x0, x0

    li      t0, MSTATUS_MPP_S
    csrw    mstatus, t0

    li      t0, EXEC_VA
    csrw    mepc, t0
    mret

    FAIL    1

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
    .dword EXEC_PTE
    .zero 5 * 8
    .dword TOHOST_PTE
    .zero 4096 - (11 * 8)

    .section .vm_exec_code,"ax",@progbits
    .globl vm_smode_entry
vm_smode_entry:
    li      t0, TOHOST_VA
    li      t1, 1
    sd      t1, 0(t0)
1:
    j       1b

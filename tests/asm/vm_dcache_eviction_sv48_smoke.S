/*
 * vm_dcache_eviction_sv48_smoke.S
 *
 * Directed Stage 3 smoke for a Linux-like Sv48 high-half data mapping.  The
 * test stores a trap-frame-like value through a high virtual address, evicts
 * the L1D set with same-index physical pages, then reloads the original slot.
 * It catches store data that reaches the D-cache hot path but is lost before a
 * later miss/refill.
 */

#include "test_macros.h"

    .equ PT_ROOT_PA,        0x80004000
    .equ PT_L2_PA,          0x80005000
    .equ PT_L1_PA,          0x80006000
    .equ PT_L0_PA,          0x80007000
    .equ TOHOST_PA,         0x80001000
    .equ DATA_PA,           0x80008000
    .equ EXEC_PA,           0x80009000
    .equ EXEC_VA,           0xffffffff80004000
    .equ TOHOST_VA,         0xffffffff8000a000
    .equ STACK_VA,          0xffffffff8000b000
    .equ SLOT_OFF,          0x100

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
    .equ DATA_PTE0,         (((DATA_PA + 0x00000) >> 12) << 10 | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)
    .equ DATA_PTE1,         (((DATA_PA + 0x04000) >> 12) << 10 | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)
    .equ DATA_PTE2,         (((DATA_PA + 0x08000) >> 12) << 10 | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)
    .equ DATA_PTE3,         (((DATA_PA + 0x0c000) >> 12) << 10 | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)
    .equ DATA_PTE4,         (((DATA_PA + 0x10000) >> 12) << 10 | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)
    .equ DATA_PTE5,         (((DATA_PA + 0x14000) >> 12) << 10 | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)

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
    .zero 511 * 8
    .dword L2_PTE

    .section .vm_pt_l2,"a",@progbits
    .zero 510 * 8
    .dword L1_PTE
    .zero 8

    .section .vm_pt_l1,"a",@progbits
    .dword L0_PTE
    .zero 4096 - 8

    .section .vm_pt_l0,"a",@progbits
    .zero 4 * 8
    .dword EXEC_PTE
    .zero 5 * 8
    .dword TOHOST_PTE
    .dword DATA_PTE0
    .zero 3 * 8
    .dword DATA_PTE1
    .zero 3 * 8
    .dword DATA_PTE2
    .zero 3 * 8
    .dword DATA_PTE3
    .zero 3 * 8
    .dword DATA_PTE4
    .zero 3 * 8
    .dword DATA_PTE5
    .zero 4096 - (32 * 8)

    .section .vm_phys_data,"aw",@progbits
    .zero 4096

    .section .vm_exec_code,"ax",@progbits
    .globl vm_smode_entry
vm_smode_entry:
    li      s0, STACK_VA
    li      s1, 0x0000000200000120
    sd      s1, SLOT_OFF(s0)
    ld      t0, SLOT_OFF(s0)
    bne     t0, s1, s_fail_hot

    li      t1, 0x1111111111111111
    li      t2, 0x2222222222222222
    li      t3, 0x3333333333333333
    li      t4, 0x4444444444444444
    li      t5, 0x5555555555555555

    li      a0, STACK_VA + 0x04000
    sd      t1, SLOT_OFF(a0)
    ld      a1, SLOT_OFF(a0)
    bne     a1, t1, s_fail_conflict

    li      a0, STACK_VA + 0x08000
    sd      t2, SLOT_OFF(a0)
    ld      a1, SLOT_OFF(a0)
    bne     a1, t2, s_fail_conflict

    li      a0, STACK_VA + 0x0c000
    sd      t3, SLOT_OFF(a0)
    ld      a1, SLOT_OFF(a0)
    bne     a1, t3, s_fail_conflict

    li      a0, STACK_VA + 0x10000
    sd      t4, SLOT_OFF(a0)
    ld      a1, SLOT_OFF(a0)
    bne     a1, t4, s_fail_conflict

    li      a0, STACK_VA + 0x14000
    sd      t5, SLOT_OFF(a0)
    ld      a1, SLOT_OFF(a0)
    bne     a1, t5, s_fail_conflict

    fence   rw, rw

    ld      a2, SLOT_OFF(s0)
    bne     a2, s1, s_fail_refill

    li      t0, TOHOST_VA
    li      t1, 1
    sd      t1, 0(t0)
1:
    j       1b

s_fail_hot:
    li      t0, TOHOST_VA
    li      t1, 3
    sd      t1, 0(t0)
1:
    j       1b

s_fail_conflict:
    li      t0, TOHOST_VA
    li      t1, 5
    sd      t1, 0(t0)
1:
    j       1b

s_fail_refill:
    li      t0, TOHOST_VA
    li      t1, 7
    sd      t1, 0(t0)
1:
    j       1b

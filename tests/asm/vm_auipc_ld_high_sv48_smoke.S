/*
 * vm_auipc_ld_high_sv48_smoke.S
 *
 * Directed Stage 3 smoke for the Linux bad_range AUIPC+LD dependency under
 * Sv48 high-kernel virtual execution.  The test poisons a5 with the stale
 * value observed in the Linux Oops, then executes the exact AUIPC+LD encoding
 * at the same page offset used by bad_range.
 */

#include "test_macros.h"

    .equ PT_ROOT_PA,        0x80004000
    .equ PT_L2_PA,          0x80005000
    .equ PT_L1_PA,          0x80006000
    .equ PT_L0_PA,          0x80007000
    .equ DATA_PA,           0x80008000
    .equ EXEC_PA,           0x80009000
    .equ TOHOST_PA,         0x80001000

    .equ EXEC_VA,           0xffffffff8013e000
    .equ GOT_PAGE_VA,       0xffffffff80e9d000
    .equ TOHOST_VA,         0x000000000000a000
    .equ STACK_VA,          0xffffffff80e9df00
    .equ BYTE_VA,           0xffffffff80e9de00
    .equ STALE_A5,          0xfffffffff0000000
    .equ EXPECT_BYTE,       0x7b

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
    .equ DATA_PPN,          (DATA_PA >> 12)
    .equ EXEC_PPN,          (EXEC_PA >> 12)
    .equ TOHOST_PPN,        (TOHOST_PA >> 12)

    .equ L2_PTE,            ((L2_PPN << 10) | PTE_V)
    .equ L1_PTE,            ((L1_PPN << 10) | PTE_V)
    .equ L0_PTE,            ((L0_PPN << 10) | PTE_V)
    .equ DATA_PTE,          ((DATA_PPN << 10) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)
    .equ EXEC_PTE,          ((EXEC_PPN << 10) | PTE_V | PTE_R | PTE_X | PTE_A)
    .equ TOHOST_PTE,        ((TOHOST_PPN << 10) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)

    .equ SATP_SV48,         ((9 << 60) | ROOT_PPN)
    .equ MSTATUS_MPP_S,     (1 << 11)
    .equ MEDELEG_LOAD_PF,   (1 << 13)

    .section .text.init
    .globl _start
_start:
    li      t0, MEDELEG_LOAD_PF
    csrw    medeleg, t0

    li      t0, SATP_SV48
    csrw    satp, t0
    sfence.vma x0, x0

    li      t0, EXEC_VA
    la      t1, s_trap
    la      t2, vm_smode_entry
    sub     t1, t1, t2
    add     t0, t0, t1
    csrw    stvec, t0

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
    .zero 510 * 8
    .dword L2_PTE

    .section .vm_pt_l2,"a",@progbits
    .dword L1_PTE
    .zero 509 * 8
    .dword L1_PTE
    .zero 8

    .section .vm_pt_l1,"a",@progbits
    .dword L0_PTE
    .zero 6 * 8
    .dword L0_PTE
    .zero 504 * 8

    .section .vm_pt_l0,"a",@progbits
    .zero 10 * 8
    .dword TOHOST_PTE
    .zero 146 * 8
    .dword DATA_PTE
    .zero 160 * 8
    .dword EXEC_PTE
    .zero 193 * 8

    .section .vm_phys_data,"aw",@progbits
    .org 0xd80
    .dword BYTE_VA
    .org 0xe00
    .byte EXPECT_BYTE
    .zero 4096 - 0xe01

    .section .vm_exec_code,"ax",@progbits
    .globl vm_smode_entry
vm_smode_entry:
    li      sp, STACK_VA
    li      ra, 0x123456789abcdef0
    li      s0, 0x0fedcba987654321
    li      a5, STALE_A5
    j       s_bad_range_mimic

    .org 0x3d8
s_bad_range_mimic:
    .hword 0x1141
    .hword 0xe022
    .hword 0xe406
    .hword 0x0800
    .word  0x00d60797
    .word  0x9a07b783
    lbu     a4, 0(a5)
    li      t0, EXPECT_BYTE
    bne     a4, t0, s_fail_bad_value

s_pass:
    li      t0, TOHOST_VA
    li      t1, 1
    sd      t1, 0(t0)
1:
    j       1b

s_fail_bad_value:
    li      t0, TOHOST_VA
    li      t1, 3
    sd      t1, 0(t0)
1:
    j       1b

s_trap:
    li      t0, TOHOST_VA
    li      t1, 4
    sd      t1, 0(t0)
1:
    j       1b

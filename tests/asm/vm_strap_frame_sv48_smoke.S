/*
 * vm_strap_frame_sv48_smoke.S
 *
 * Directed Stage 3 smoke for the S-mode trap-frame save/restore sequence
 * seen in Linux after Sv48 is enabled.  The test enters S-mode, triggers a
 * delegated supervisor software interrupt through the CSR interrupt-pending
 * shadow, saves sstatus to 256(sp), reloads it before sret, and repeats.
 */

#include "test_macros.h"

    .equ PT_ROOT_PA,        0x80004000
    .equ PT_L2_PA,          0x80005000
    .equ PT_L1_PA,          0x80006000
    .equ PT_L0_PA,          0x80007000
    .equ TOHOST_PA,         0x80001000
    .equ DATA_PA,           0x80008000
    .equ EXEC_PA,           0x80009000
    .equ EXEC_VA,           0x0000000000004000
    .equ TOHOST_VA,         0x000000000000a000
    .equ STACK_VA,          0x000000000000b000

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
    .equ DATA_PPN,          (DATA_PA >> 12)
    .equ EXEC_PPN,          (EXEC_PA >> 12)

    .equ L2_PTE,            ((L2_PPN << 10) | PTE_V)
    .equ L1_PTE,            ((L1_PPN << 10) | PTE_V)
    .equ L0_PTE,            ((L0_PPN << 10) | PTE_V)
    .equ EXEC_PTE,          ((EXEC_PPN << 10) | PTE_V | PTE_R | PTE_X | PTE_A)
    .equ TOHOST_PTE,        ((TOHOST_PPN << 10) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)
    .equ DATA_PTE,          ((DATA_PPN << 10) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)

    .equ SATP_SV48,         ((9 << 60) | ROOT_PPN)
    .equ MSTATUS_MPP_S,     (1 << 11)
    .equ SSTATUS_SIE,       (1 << 1)
    .equ MSTATUS_ENTER_S_IRQ, (MSTATUS_MPP_S | SSTATUS_SIE)
    .equ IRQ_S_SOFT_BIT,    (1 << 1)
    .equ LOOP_COUNT,        16
    .equ STATUS_CLEAR_MASK, 0x46600

    .section .text.init
    .globl _start
_start:
    li      t0, SATP_SV48
    csrw    satp, t0
    sfence.vma x0, x0

    li      t0, IRQ_S_SOFT_BIT
    csrw    mideleg, t0
    csrw    sie, t0

    li      t0, EXEC_VA
    la      t1, s_trap_handler
    la      t2, vm_smode_entry
    sub     t1, t1, t2
    add     t0, t0, t1
    csrw    stvec, t0

    li      t0, MSTATUS_ENTER_S_IRQ
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
    .dword DATA_PTE
    .zero 4096 - (12 * 8)

    .section .vm_phys_data,"aw",@progbits
    .zero 4096

    .section .vm_exec_code,"ax",@progbits
    .globl vm_smode_entry
vm_smode_entry:
    li      sp, STACK_VA
    sd      zero, 16(sp)
    li      s0, LOOP_COUNT

s_loop:
    ld      s5, 16(sp)
    bge     s5, s0, s_pass
    li      t0, IRQ_S_SOFT_BIT
    csrs    sip, t0

s_wait:
    ld      t2, 16(sp)
    beq     t2, s5, s_wait
    j       s_loop

s_pass:
    li      t0, TOHOST_VA
    li      t1, 1
    sd      t1, 0(t0)
1:
    j       1b

s_fail_zero:
    li      t0, TOHOST_VA
    li      t1, 3
    sd      t1, 0(t0)
1:
    j       1b

s_fail_count:
    li      t0, TOHOST_VA
    li      t1, 4
    sd      t1, 0(t0)
1:
    j       1b

    .align 2
s_trap_handler:
    li      t0, STATUS_CLEAR_MASK
    csrrc   s1, sstatus, t0
    csrr    s2, sepc
    csrr    s3, stval
    csrr    s4, scause
    sd      s1, 256(sp)
    sd      s2, 0(sp)
    sd      s3, 264(sp)
    sd      s4, 272(sp)

    li      t2, 0x1122334455667788
    sd      t2, 24(sp)
    sd      t2, 32(sp)
    sd      t2, 40(sp)
    sd      t2, 48(sp)

    li      t0, IRQ_S_SOFT_BIT
    csrc    sip, t0

    ld      a0, 256(sp)
    beqz    a0, s_fail_zero
    ld      a2, 0(sp)
    ld      t1, 16(sp)
    addi    t1, t1, 1
    sd      t1, 16(sp)
    bgt     t1, s0, s_fail_count

    csrw    sstatus, a0
    csrw    sepc, a2
    sret

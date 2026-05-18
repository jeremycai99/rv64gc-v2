/*
 * vm_linux_save_context_pressure_sv48_smoke.S
 *
 * Directed Stage 3 smoke for the Linux _save_context trap frame pattern under
 * Sv48.  This extends vm_strap_frame_sv48_smoke by issuing many store-data
 * queue entries around the csrrc sstatus producer before checking the
 * 256(sp) restore slot.
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
    .equ LOOP_COUNT,        32
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
    li      ra, 0x1111
    li      gp, 0x2222
    li      tp, 0x3333
    li      t0, 0x4444
    li      t1, 0x5555
    li      t2, 0x6666
    li      s0, LOOP_COUNT
    li      s1, 0x7777
    li      a0, 0x8888
    li      a1, 0x9999
    li      a2, 0xaaaa
    li      a3, 0xbbbb
    li      a4, 0xcccc
    li      a5, 0xdddd
    li      a6, 0xeeee
    li      a7, 0xffff
    li      s2, 0x1234
    li      s3, 0x2345
    li      s4, 0x3456
    li      s5, 0x4567
    li      s6, 0x5678
    li      s7, 0x6789
    li      s8, 0x789a
    li      s9, 0x89ab
    li      s10, 0x9abc
    li      s11, 0xabcd
    li      t3, 0xbcde
    li      t4, 0xcdef
    li      t5, 0xdef0
    li      t6, 0xef01
    sd      zero, 16(sp)

s_loop:
    ld      t2, 16(sp)
    bge     t2, s0, s_pass
    sd      t2, 384(sp)
    li      t0, IRQ_S_SOFT_BIT
    csrs    sip, t0

s_wait:
    ld      t4, 384(sp)
    ld      t3, 16(sp)
    beq     t3, t4, s_wait
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

s_fail_mismatch:
    li      t0, TOHOST_VA
    li      t1, 4
    sd      t1, 0(t0)
1:
    j       1b

    .align 2
s_trap_handler:
    sd      ra, 8(sp)
    sd      gp, 24(sp)
    sd      tp, 32(sp)
    sd      t0, 40(sp)
    sd      t1, 48(sp)
    sd      t2, 56(sp)
    sd      s0, 64(sp)
    sd      s1, 72(sp)
    sd      a0, 80(sp)
    sd      a1, 88(sp)
    sd      a2, 96(sp)
    sd      a3, 104(sp)
    sd      a4, 112(sp)
    sd      a5, 120(sp)
    sd      a6, 128(sp)
    sd      a7, 136(sp)
    sd      s2, 144(sp)
    sd      s3, 152(sp)
    sd      s4, 160(sp)
    sd      s5, 168(sp)
    sd      s6, 176(sp)
    sd      s7, 184(sp)
    sd      s8, 192(sp)
    sd      s9, 200(sp)
    sd      s10, 208(sp)
    sd      s11, 216(sp)
    sd      t3, 224(sp)
    sd      t4, 232(sp)
    sd      t5, 240(sp)
    sd      t6, 248(sp)

    li      t0, STATUS_CLEAR_MASK
    csrrc   s1, sstatus, t0
    csrr    s2, sepc
    csrr    s3, stval
    csrr    s4, scause
    csrr    s5, sscratch
    sd      s1, 256(sp)
    sd      s2, 0(sp)
    sd      s3, 264(sp)
    sd      s4, 272(sp)
    sd      s5, 32(sp)
    csrw    sscratch, zero

    li      t0, IRQ_S_SOFT_BIT
    csrc    sip, t0

    li      t0, 64
1:
    sd      t0, 280(sp)
    ld      t2, 280(sp)
    addi    t0, t0, -1
    bnez    t0, 1b
    fence   rw, rw

    ld      a0, 256(sp)
    beqz    a0, s_fail_zero
    bne     a0, s1, s_fail_mismatch
    ld      a2, 0(sp)
    sc.d    zero, a2, (sp)
    ld      t1, 16(sp)
    addi    t1, t1, 1
    sd      t1, 16(sp)
    csrw    sstatus, a0
    csrw    sepc, a2
    sret

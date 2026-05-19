/*
 * vm_mtimer_vector_sv48_smoke.S
 *
 * Directed Stage 3 smoke for machine timer interrupt entry and return while
 * S-mode address translation is active.  The M-mode mtvec fetch must use
 * physical addressing even though satp remains Sv48 from the interrupted
 * S-mode code, then mret must resume translated S-mode fetch.
 */

#include "test_macros.h"

    .equ PT_ROOT_PA,             0x80004000
    .equ PT_L2_PA,               0x80005000
    .equ PT_L1_PA,               0x80006000
    .equ PT_L0_PA,               0x80007000
    .equ EXEC_PA,                0x80009000
    .equ EXEC_VA,                0x0000000000004000
    .equ UART_VA,                0x000000000000a000

    .equ UART_BASE,              0x10000000
    .equ UART_THR,               0
    .equ UART_LSR,               5
    .equ UART_LSR_THRE,          0x20
    .equ CLINT_MTIMECMP,         0x02004000
    .equ CLINT_MTIME,            0x0200bff8

    .equ PTE_V,                  0x001
    .equ PTE_R,                  0x002
    .equ PTE_W,                  0x004
    .equ PTE_X,                  0x008
    .equ PTE_A,                  0x040
    .equ PTE_D,                  0x080

    .equ ROOT_PPN,               (PT_ROOT_PA >> 12)
    .equ L2_PPN,                 (PT_L2_PA >> 12)
    .equ L1_PPN,                 (PT_L1_PA >> 12)
    .equ L0_PPN,                 (PT_L0_PA >> 12)
    .equ EXEC_PPN,               (EXEC_PA >> 12)
    .equ UART_PPN,               (UART_BASE >> 12)

    .equ L2_PTE,                 ((L2_PPN << 10) | PTE_V)
    .equ L1_PTE,                 ((L1_PPN << 10) | PTE_V)
    .equ L0_PTE,                 ((L0_PPN << 10) | PTE_V)
    .equ EXEC_PTE,               ((EXEC_PPN << 10) | PTE_V | PTE_R | PTE_X | PTE_A)
    .equ UART_PTE,               ((UART_PPN << 10) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)

    .equ SATP_SV48,              ((9 << 60) | ROOT_PPN)
    .equ MSTATUS_MPP_S,          (1 << 11)
    .equ MSTATUS_MPP_MASK,       (3 << 11)
    .equ MIE_MTIE,               (1 << 7)
    .equ MCAUSE_M_TIMER,         0x8000000000000007

    .section .text.init
    .globl _start
_start:
    la      sp, _stack_top

    la      t0, mtvec_base
    ori     t0, t0, 1
    csrw    mtvec, t0

    csrw    medeleg, x0
    csrw    mideleg, x0
    li      t0, MIE_MTIE
    csrw    mie, t0

    li      t0, CLINT_MTIME
    ld      t1, 0(t0)
    addi    t1, t1, 64
    li      t0, CLINT_MTIMECMP
    sd      t1, 0(t0)

    li      t0, SATP_SV48
    csrw    satp, t0
    sfence.vma x0, x0

    li      t0, MSTATUS_MPP_S
    csrw    mstatus, t0
    li      t0, EXEC_VA
    csrw    mepc, t0
    mret

    la      a0, fail_msg
    j       uart_puts

    .option push
    .option norvc
    .align 6
mtvec_base:
    j       unexpected_trap
    j       unexpected_trap
    j       unexpected_trap
    j       unexpected_trap
    j       unexpected_trap
    j       unexpected_trap
    j       unexpected_trap
    j       mtimer_handler
    j       unexpected_trap
    j       unexpected_trap
    j       unexpected_trap
    j       unexpected_trap
    j       unexpected_trap
    j       unexpected_trap
    j       unexpected_trap
    j       unexpected_trap
    .option pop

mtimer_handler:
    li      t0, CLINT_MTIMECMP
    li      t1, -1
    sd      t1, 0(t0)

    csrr    t0, mcause
    li      t1, MCAUSE_M_TIMER
    bne     t0, t1, unexpected_trap

    csrr    t0, mstatus
    li      t1, MSTATUS_MPP_MASK
    and     t0, t0, t1
    li      t1, MSTATUS_MPP_S
    bne     t0, t1, unexpected_trap

    csrr    t0, mepc
    li      t1, EXEC_VA
    bltu    t0, t1, unexpected_trap
    li      t1, EXEC_VA + 0x100
    bgeu    t0, t1, unexpected_trap

    li      t0, EXEC_VA
    la      t1, s_timer_pass
    la      t2, vm_smode_entry
    sub     t1, t1, t2
    add     t0, t0, t1
    csrw    mepc, t0
    mret

unexpected_trap:
    la      a0, fail_msg

uart_puts:
    lbu     t0, 0(a0)
    beqz    t0, uart_done
uart_wait:
    li      t1, UART_BASE + UART_LSR
    lbu     t2, 0(t1)
    andi    t2, t2, UART_LSR_THRE
    beqz    t2, uart_wait
    li      t1, UART_BASE + UART_THR
    sb      t0, 0(t1)
    addi    a0, a0, 1
    j       uart_puts

uart_done:
    wfi
    j       uart_done

    .section .rodata
fail_msg:
    .asciz "\r\nM TIMER VECTOR FAIL\r\n"

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
    .dword UART_PTE
    .zero 4096 - (11 * 8)

    .section .vm_exec_code,"ax",@progbits
    .globl vm_smode_entry
vm_smode_entry:
    addi    s0, s0, 1
    addi    s1, s1, 3
    xor     s2, s0, s1
    j       vm_smode_entry

s_timer_pass:
    la      a0, s_pass_msg

s_uart_puts:
    lbu     t0, 0(a0)
    beqz    t0, s_uart_done
s_uart_wait:
    li      t1, UART_VA + UART_LSR
    lbu     t2, 0(t1)
    andi    t2, t2, UART_LSR_THRE
    beqz    t2, s_uart_wait
    li      t1, UART_VA + UART_THR
    sb      t0, 0(t1)
    addi    a0, a0, 1
    j       s_uart_puts

s_uart_done:
    wfi
    j       s_uart_done

s_pass_msg:
    .asciz "\r\nM TIMER VECTOR OK\r\n"

    .section .bss
    .align 12
_stack:
    .zero 4096
_stack_top:

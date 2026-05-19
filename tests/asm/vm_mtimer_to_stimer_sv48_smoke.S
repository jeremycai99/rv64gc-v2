/*
 * vm_mtimer_to_stimer_sv48_smoke.S
 *
 * Directed Stage 3 smoke for the Linux/OpenSBI timer path under Sv48:
 * S-mode runs with translation enabled, MTIP traps to M-mode physical mtvec,
 * the M-mode handler injects STIP, then S-mode takes the delegated timer
 * interrupt through a translated stvec trap frame.
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
    .equ UART_VA,           0x000000000000a000
    .equ STACK_VA,          0x000000000000b000

    .equ UART_BASE,         0x10000000
    .equ UART_THR,          0
    .equ UART_LSR,          5
    .equ UART_LSR_THRE,     0x20
    .equ CLINT_MTIMECMP,    0x02004000
    .equ CLINT_MTIME,       0x0200bff8

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
    .equ UART_PPN,          (UART_BASE >> 12)
    .equ DATA_PPN,          (DATA_PA >> 12)
    .equ EXEC_PPN,          (EXEC_PA >> 12)

    .equ L2_PTE,            ((L2_PPN << 10) | PTE_V)
    .equ L1_PTE,            ((L1_PPN << 10) | PTE_V)
    .equ L0_PTE,            ((L0_PPN << 10) | PTE_V)
    .equ EXEC_PTE,          ((EXEC_PPN << 10) | PTE_V | PTE_R | PTE_X | PTE_A)
    .equ UART_PTE,          ((UART_PPN << 10) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)
    .equ DATA_PTE,          ((DATA_PPN << 10) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)

    .equ SATP_SV48,         ((9 << 60) | ROOT_PPN)
    .equ MSTATUS_MPP_S,     (1 << 11)
    .equ SSTATUS_SIE,       (1 << 1)
    .equ MSTATUS_ENTER_S_IRQ, (MSTATUS_MPP_S | SSTATUS_SIE)
    .equ MIE_MTIE,          (1 << 7)
    .equ IRQ_S_TIMER_BIT,   (1 << 5)
    .equ MCAUSE_M_TIMER,    0x8000000000000007
    .equ SCAUSE_S_TIMER,    0x8000000000000005

    .section .text.init
    .globl _start
_start:
    la      sp, _stack_top

    la      t0, mtvec_base
    ori     t0, t0, 1
    csrw    mtvec, t0

    li      t0, SATP_SV48
    csrw    satp, t0
    sfence.vma x0, x0

    li      t0, IRQ_S_TIMER_BIT
    csrw    mideleg, t0

    li      t0, MIE_MTIE
    csrw    mie, t0

    li      t0, IRQ_S_TIMER_BIT
    csrw    sie, t0

    li      t0, EXEC_VA
    la      t1, s_timer_handler
    la      t2, vm_smode_entry
    sub     t1, t1, t2
    add     t0, t0, t1
    csrw    stvec, t0

    li      t0, CLINT_MTIME
    ld      t1, 0(t0)
    addi    t1, t1, 64
    li      t0, CLINT_MTIMECMP
    sd      t1, 0(t0)

    li      t0, MSTATUS_ENTER_S_IRQ
    csrw    mstatus, t0
    li      t0, EXEC_VA
    csrw    mepc, t0
    mret

    FAIL    1

    .option push
    .option norvc
    .align 6
mtvec_base:
    j       unexpected_m_trap
    j       unexpected_m_trap
    j       unexpected_m_trap
    j       unexpected_m_trap
    j       unexpected_m_trap
    j       unexpected_m_trap
    j       unexpected_m_trap
    j       mtimer_handler
    j       unexpected_m_trap
    j       unexpected_m_trap
    j       unexpected_m_trap
    j       unexpected_m_trap
    j       unexpected_m_trap
    j       unexpected_m_trap
    j       unexpected_m_trap
    j       unexpected_m_trap
    .option pop

mtimer_handler:
    li      t0, CLINT_MTIMECMP
    li      t1, -1
    sd      t1, 0(t0)

    csrr    t0, mcause
    li      t1, MCAUSE_M_TIMER
    bne     t0, t1, unexpected_m_trap

    li      t0, IRQ_S_TIMER_BIT
    csrs    mip, t0
    mret

unexpected_m_trap:
    la      a0, m_fail_msg
    j       m_uart_puts

m_uart_puts:
    lbu     t0, 0(a0)
    beqz    t0, m_uart_done
m_uart_wait:
    li      t1, UART_BASE + UART_LSR
    lbu     t2, 0(t1)
    andi    t2, t2, UART_LSR_THRE
    beqz    t2, m_uart_wait
    li      t1, UART_BASE + UART_THR
    sb      t0, 0(t1)
    addi    a0, a0, 1
    j       m_uart_puts

m_uart_done:
    wfi
    j       m_uart_done

    .section .text.init
m_fail_msg:
    .asciz "\r\nM TIMER TO STIMER M FAIL\r\n"

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
    .dword DATA_PTE
    .zero 4096 - (12 * 8)

    .section .vm_phys_data,"aw",@progbits
    .zero 4096

    .section .vm_exec_code,"ax",@progbits
    .globl vm_smode_entry
vm_smode_entry:
    li      sp, STACK_VA
    li      s0, 0

s_wait_timer:
    addi    s0, s0, 1
    j       s_wait_timer

    .align 2
s_timer_handler:
    csrr    t0, scause
    li      t1, SCAUSE_S_TIMER
    bne     t0, t1, s_fail_scause

    li      t0, IRQ_S_TIMER_BIT
    csrc    sip, t0

    la      a0, s_pass_msg
    j       s_uart_puts

s_fail_scause:
    la      a0, s_fail_msg

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
    .asciz "\r\nM TIMER TO STIMER OK\r\n"
s_fail_msg:
    .asciz "\r\nM TIMER TO STIMER S FAIL\r\n"

    .section .bss
    .align 12
_stack:
    .zero 4096
_stack_top:

/*
 * amo_sc_interrupt_precision.S
 *
 * Directed LR/SC precision check under timer-interrupt full flushes.  The
 * test fails if a failed SC leaves its store value in memory, which indicates
 * that the SC side effect escaped before the ROB commit point.
 */

#include "test_macros.h"

    .equ CLINT_MTIMECMP, 0x02004000
    .equ CLINT_MTIME,    0x0200bff8
    .equ UART_BASE,      0x10000000
    .equ UART_THR,       0
    .equ UART_LSR,       5
    .equ UART_LSR_THRE,  0x20
    .equ TIMER_DELTA,    1024
    .equ MSTATUS_MIE,    (1 << 3)
    .equ MIE_MTIE,       (1 << 7)
    .equ MCAUSE_M_TIMER, 0x8000000000000007

    .section .text.init
    .globl _start
_start:
    la      sp, _stack_top

    la      t0, trap_save_area
    csrw    mscratch, t0
    li      s11, 0

    la      t0, mtimer_handler
    csrw    mtvec, t0

    li      t0, CLINT_MTIME
    ld      t1, 0(t0)
    addi    t1, t1, TIMER_DELTA
    li      t0, CLINT_MTIMECMP
    sd      t1, 0(t0)

    li      t0, MIE_MTIE
    csrs    mie, t0
    li      t0, MSTATUS_MIE
    csrs    mstatus, t0

wait_first_irq:
    beqz    s11, wait_first_irq

    la      s1, lock_word
    li      s0, 2000

acquire_loop:
    sd      zero, 0(s1)
    fence   rw, rw

lr_retry:
    lr.d    t0, (s1)
    bnez    t0, fail_lock_nonzero
    li      t1, 1
sc_site:
    sc.d    t2, t1, (s1)
    bnez    t2, sc_failed

    ld      t3, 0(s1)
    li      t4, 1
    bne     t3, t4, fail_sc_success_no_store
    sd      zero, 0(s1)

    addi    s0, s0, -1
    bnez    s0, acquire_loop

    beqz    s11, fail_no_interrupt
    la      a0, pass_msg
    jal     ra, uart_puts
    PASS

sc_failed:
    ld      t3, 0(s1)
    bnez    t3, fail_sc_failed_store_leaked
    j       lr_retry

fail_lock_nonzero:
    la      a0, fail_msg_1
    jal     ra, uart_puts
    FAIL    1

fail_sc_success_no_store:
    la      a0, fail_msg_2
    jal     ra, uart_puts
    FAIL    2

fail_sc_failed_store_leaked:
    la      a0, fail_msg_3
    jal     ra, uart_puts
    FAIL    3

fail_no_interrupt:
    la      a0, fail_msg_4
    jal     ra, uart_puts
    FAIL    4

mtimer_handler:
    csrr    t6, mscratch
    sd      t0, 0(t6)
    sd      t1, 8(t6)
    sd      t2, 16(t6)
    sd      t3, 24(t6)
    sd      t4, 32(t6)
    sd      t5, 40(t6)

    csrr    t0, mcause
    csrr    t2, mepc
    sd      t0, 48(t6)
    sd      t2, 56(t6)
    li      t1, MCAUSE_M_TIMER
    bne     t0, t1, fail_bad_trap

    addi    s11, s11, 1

    li      t0, CLINT_MTIME
    ld      t1, 0(t0)
    addi    t1, t1, TIMER_DELTA
    li      t0, CLINT_MTIMECMP
    sd      t1, 0(t0)

    ld      t0, 0(t6)
    ld      t1, 8(t6)
    ld      t2, 16(t6)
    ld      t3, 24(t6)
    ld      t4, 32(t6)
    ld      t5, 40(t6)
    mret

fail_bad_trap:
    la      a0, fail_msg_5
    jal     ra, uart_puts
    csrr    t6, mscratch
    la      a0, mcause_msg
    jal     ra, uart_puts
    ld      a0, 48(t6)
    jal     ra, uart_puthex64
    la      a0, mepc_msg
    jal     ra, uart_puts
    ld      a0, 56(t6)
    jal     ra, uart_puthex64
    la      a0, crlf_msg
    jal     ra, uart_puts
    FAIL    5

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
    ret

uart_puthex64:
    mv      t5, a0
    li      t4, 16
hex_loop:
    srli    t0, t5, 60
    li      t1, 10
    bltu    t0, t1, hex_digit
    addi    t0, t0, 87
    j       hex_emit
hex_digit:
    addi    t0, t0, 48
hex_emit:
    li      t1, UART_BASE + UART_LSR
    lbu     t2, 0(t1)
    andi    t2, t2, UART_LSR_THRE
    beqz    t2, hex_emit
    li      t1, UART_BASE + UART_THR
    sb      t0, 0(t1)
    slli    t5, t5, 4
    addi    t4, t4, -1
    bnez    t4, hex_loop
    ret

    .section .data
    .align 3
pass_msg:
    .asciz "\r\nAMO_SC_IRQ_OK\r\n"
fail_msg_1:
    .asciz "\r\nAMO_SC_IRQ_FAIL_LOCK_NONZERO\r\n"
fail_msg_2:
    .asciz "\r\nAMO_SC_IRQ_FAIL_SUCCESS_NO_STORE\r\n"
fail_msg_3:
    .asciz "\r\nAMO_SC_IRQ_FAIL_FAILED_STORE_LEAKED\r\n"
fail_msg_4:
    .asciz "\r\nAMO_SC_IRQ_FAIL_NO_INTERRUPT\r\n"
fail_msg_5:
    .asciz "\r\nAMO_SC_IRQ_FAIL_BAD_TRAP\r\n"
mcause_msg:
    .asciz "mcause="
mepc_msg:
    .asciz " mepc="
crlf_msg:
    .asciz "\r\n"
lock_word:
    .dword 0
trap_save_area:
    .zero 64

    .section .bss
    .align 12
_stack:
    .zero 4096
_stack_top:

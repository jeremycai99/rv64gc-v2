    .section .text.init
    .globl _start

    .equ UART_BASE, 0x10000000
    .equ UART_THR, 0
    .equ UART_LSR, 5
    .equ UART_LSR_THRE, 0x20

_start:
    la sp, _stack_top
    la a0, smoke_msg

1:
    lbu t0, 0(a0)
    beqz t0, 4f

2:
    li t1, UART_BASE + UART_LSR
    lbu t2, 0(t1)
    andi t2, t2, UART_LSR_THRE
    beqz t2, 2b

    li t1, UART_BASE + UART_THR
    sb t0, 0(t1)
    addi a0, a0, 1
    j 1b

4:
    wfi
    j 4b

    .section .rodata
smoke_msg:
    .asciz "\r\nRV64GC-V2 STAGE3 UART OK\r\n"

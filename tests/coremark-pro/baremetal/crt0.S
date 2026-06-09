    .section .text.start, "ax"
    .global _start
_start:
    /* Set stack pointer near top of RAM (128MB window, leave 512KB for stack) */
    li      sp, 0x87F80000

    /* Clear BSS using loop (BSS can be large for CM-PRO) */
    la      a0, __bss_start
    la      a1, __bss_end
    beq     a0, a1, 2f
1:
    sd      zero, 0(a0)
    addi    a0, a0, 8
    bltu    a0, a1, 1b
2:

    /* Call main */
    li      a0, 0      /* argc = 0 */
    li      a1, 0      /* argv = NULL */
    call    main

    /* Write tohost: 1 = PASS, else encode failure */
    li      t0, 0x80001000
    beqz    a0, 3f
    slli    t1, a0, 1
    ori     t1, t1, 1
    sd      t1, 0(t0)
4:  j       4b
3:
    li      t1, 1
    sd      t1, 0(t0)
5:  j       5b

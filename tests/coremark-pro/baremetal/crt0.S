    .section .text.start, "ax"
    .global _start
_start:
    /* Set stack pointer near top of RAM (128MB window, leave 512KB for stack) */
    li      sp, 0x87F80000

    /* Enable FPU: mstatus.FS = Initial (01).  The core resets FS=Off and
     * (correctly) raises illegal-instruction on any FP op / FP-CSR access
     * while FS=Off — without this, every FP kernel silently trapped to
     * mtvec=0 and ran a bogus integer loop instead of its FP code. */
    li      t0, (1 << 13)
    csrs    mstatus, t0

    /* Install a trap catcher: any unexpected trap writes a distinctive
     * failure code to tohost and parks, so a silent trap can never again
     * masquerade as a running benchmark. */
    la      t0, _trap_catch
    csrw    mtvec, t0

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

    /* Unexpected trap: encode mcause into a distinctive tohost failure value
     * and park.  tohost = ((0x700 | mcause) << 1) | 1 — nonzero, visible,
     * immediately stops the simulation instead of silently looping. */
    .align 2
_trap_catch:
    csrr    t0, mcause
    li      t1, 0x700
    or      t0, t0, t1
    slli    t0, t0, 1
    ori     t0, t0, 1
    li      t1, 0x80001000
    sd      t0, 0(t1)
6:  j       6b

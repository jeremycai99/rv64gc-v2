/* crt0.S - minimal C runtime for intermediate RV64GC tests.
 *
 * Called by the reset vector.  Sets up the stack, clears BSS, calls main(),
 * and writes the return value to tohost:
 *     main == 0   -> write 1 (PASS)
 *     main != 0   -> write ((rc << 1) | 1) (FAIL, with return value as test#)
 *
 * The BSS clear loop uses a fully forward-branching unrolled pattern.
 * This mirrors coremark/crt0.S: the v2 pipeline tolerates forward-only
 * branches in the boot sequence far better than backward loops.
 */
    .section .text.start, "ax"
    .global _start
_start:
    /* Stack at top of 1MB (16-byte aligned) */
    li      sp, 0x800FFFF0

    /* Clear BSS with an unrolled forward-branch loop (up to 64 dwords). */
    la      a0, __bss_start
    la      a1, __bss_end
    .rept 64
    bgeu    a0, a1, 1f
    sd      zero, 0(a0)
    addi    a0, a0, 8
    .endr
1:

    /* Call main */
    call    main

    /* On return: a0 holds the exit code (0=pass) */
    li      t0, 0x80001000
    bnez    a0, fail
    li      t1, 1
    sd      t1, 0(t0)
2:  j       2b
fail:
    /* Encode the non-zero return value as ((rc<<1)|1) */
    slli    t1, a0, 1
    ori     t1, t1, 1
    sd      t1, 0(t0)
3:  j       3b

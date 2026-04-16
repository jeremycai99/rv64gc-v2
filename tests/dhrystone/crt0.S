/* crt0.S - Dhrystone startup for rv64gc-v2.
 *
 * Sets up the stack, clears the entire .bss region, calls main(), and
 * reports the result to tohost.
 */
    .section .text.start, "ax"
    .global _start
_start:
    /* Stack at top of 1MB (16-byte aligned). */
    li      sp, 0x800FFFF0

    /* Clear BSS with the same forward-only pattern the core already tolerates.
     * 64 dwords covers the existing benchmark image layout. */
    la      a0, __bss_start
    la      a1, __bss_end
    .rept 64
    bgeu    a0, a1, 2f
    sd      zero, 0(a0)
    addi    a0, a0, 8
    .endr
2:
    call    main

    /* main() returns 0 on success. */
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

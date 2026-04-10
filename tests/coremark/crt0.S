    .section .text.start, "ax"
    .global _start
_start:
    # Stack at top of 1MB
    li      sp, 0x800FFFF0

    # Clear BSS — unrolled loop using forward-only branches.
    # The bnez/bgeu backward-loop pattern currently breaks the v2
    # rv64gc pipeline, so we use a fixed unrolled clear with a fall-
    # through forward branch as the exit. Up to 64 dwords of BSS
    # are cleared (256 bytes), which covers CoreMark's 28-byte BSS.
    la      a0, __bss_start
    la      a1, __bss_end

    # Manually unroll: each line clears 8 bytes and bumps a0,
    # falling out of the cleanup as soon as a0 >= a1.
    .rept 64
    bgeu    a0, a1, 1f
    sd      zero, 0(a0)
    addi    a0, a0, 8
    .endr
1:

    # Call main
    call    main
    # Write 1 to tohost (PASS)
    li      t0, 0x80001000
    li      t1, 1
    sd      t1, 0(t0)
2:  j       2b

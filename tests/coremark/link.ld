OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
    /* First 8KB: startup + tohost region */
    BOOT (rwx) : ORIGIN = 0x80000000, LENGTH = 8K
    /* Main code/data after 8KB */
    RAM (rwx) : ORIGIN = 0x80002000, LENGTH = 1016K
}

SECTIONS {
    /* Startup trampoline at reset vector */
    . = 0x80000000;
    .text.start : {
        *(.text.start)
    } > BOOT

    /* tohost at fixed address 0x80001000 (matches RTL TOHOST_ADDR) */
    .tohost 0x80001000 (NOLOAD) : {
        PROVIDE(tohost = .);
        . += 8;
        PROVIDE(fromhost = .);
        . += 8;
    } > BOOT

    /* Main code at 0x80002000 */
    . = 0x80002000;
    .text : {
        *(.text .text.*)
    } > RAM

    .rodata : ALIGN(16) {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    } > RAM

    .data : ALIGN(16) {
        *(.data .data.*)
        PROVIDE(__global_pointer$ = . + 0x800);
        *(.sdata .sdata.*)
    } > RAM

    /* Keep BSS bounds naturally aligned for crt0's 64-bit clear loop. */
    . = ALIGN(16);
    __bss_start = .;
    .bss : {
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        . = ALIGN(16);
    } > RAM
    __bss_end = .;

    _end = .;
}

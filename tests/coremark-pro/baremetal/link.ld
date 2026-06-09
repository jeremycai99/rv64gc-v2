OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
    /* First 8KB: startup + tohost region */
    BOOT (rwx) : ORIGIN = 0x80000000, LENGTH = 8K
    /* Main code/data: 0x80002000..0x87F80000 (~127 MB usable)          */
    /* Stack: 0x87F80000..0x87FFFFFF (512 KB)                            */
    /* Heap: grows up from _end, capped by __heap_end in syscalls.c      */
    RAM  (rwx) : ORIGIN = 0x80002000, LENGTH = 127M
}

SECTIONS {
    /* Startup trampoline at reset vector */
    . = 0x80000000;
    .text.start : {
        *(.text.start)
    } > BOOT

    /* tohost at fixed address 0x80001000 */
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

    . = ALIGN(16);
    __bss_start = .;
    .bss : {
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        . = ALIGN(16);
    } > RAM
    __bss_end = .;

    _end = .;

    /* Heap grows from _end up to __heap_end (64 MB) */
    __heap_start = _end;
    __heap_end   = 0x87F80000;   /* leave 512KB for stack */
}

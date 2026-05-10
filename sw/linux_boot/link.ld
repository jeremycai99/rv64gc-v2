OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    dram (rwx) : ORIGIN = 0x80000000, LENGTH = 128M
}

SECTIONS
{
    . = ORIGIN(dram);

    .text : {
        *(.text.init)
        *(.text .text.*)
    } > dram

    .rodata : {
        *(.rodata .rodata.*)
    } > dram

    .data : {
        *(.data .data.*)
    } > dram

    .bss : {
        *(.bss .bss.*)
        *(COMMON)
    } > dram

    . = ALIGN(16);
    . += 4096;
    PROVIDE(_stack_top = .);
}

OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS {
    . = 0x80000000;
    .text : { *(.text.init) *(.text) }
    .data : { *(.data) }
    .bss : { *(.bss) }

    . = 0x80001000;
    .tohost : { *(.tohost) }

    . = 0x80004000;
    .vm_pt_root : { *(.vm_pt_root) }

    . = 0x80005000;
    .vm_pt_l2 : { *(.vm_pt_l2) }

    . = 0x80006000;
    .vm_pt_l1 : { *(.vm_pt_l1) }

    . = 0x80007000;
    .vm_pt_l0 : { *(.vm_pt_l0) }

    . = 0x80008000;
    .vm_phys_data : { *(.vm_phys_data) }

    . = 0x80009000;
    .vm_exec_code : { *(.vm_exec_code) }
}

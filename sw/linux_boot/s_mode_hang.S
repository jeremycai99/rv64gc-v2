    .section .text.init
    .globl _start

_start:
    wfi
    j _start

PREFIX = riscv64-unknown-elf
CC = $(PREFIX)-gcc
AS = $(PREFIX)-as
LD = $(PREFIX)-ld
OBJCOPY = $(PREFIX)-objcopy

CFLAGS = -march=rv64gc_zba_zbb_zbs_zicond -mabi=lp64d -nostdlib -nostartfiles -I.
LDFLAGS = -melf64lriscv -T link.ld

ELF2HEX = python3 ../scripts/elf2hex.py

TESTS_S = $(wildcard asm/*.S)
TESTS = $(TESTS_S:asm/%.S=%)
HEXS = $(addprefix hex/, $(addsuffix .hex, $(TESTS)))

.PHONY: all clean

all: $(HEXS)

hex/%.hex: asm/%.S link.ld test_macros.h
	@mkdir -p obj hex
	$(CC) $(CFLAGS) -c $< -o obj/$*.o
	$(LD) $(LDFLAGS) obj/$*.o -o obj/$*.elf
	$(ELF2HEX) obj/$*.elf $@

clean:
	rm -rf obj hex

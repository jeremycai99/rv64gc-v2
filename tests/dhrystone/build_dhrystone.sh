#!/usr/bin/env bash
# Build Dhrystone 2.1 for the rv64gc-v2 simulator.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DHRY_DIR="$ROOT/tests/dhrystone"
SRC_DIR="$DHRY_DIR/src"

CC="${CC:-riscv64-unknown-elf-gcc}"
ELF2HEX="${ELF2HEX:-python3 $ROOT/scripts/elf2hex.py}"
OUT_ELF="${1:-$DHRY_DIR/dhrystone.elf}"
OUT_HEX="${2:-$ROOT/tests/hex/dhrystone.hex}"

CFLAGS=(
  -O2
  -march=rv64gc_zba_zbb_zbs_zicond
  -mabi=lp64d
  -mcmodel=medany
  -ffreestanding
  -fno-builtin
  -fno-common
  -nostdlib
  -nostartfiles
  -static
  -I"$SRC_DIR"
  -DNUM_RUNS=100
)

# Dhrystone needs a full .bss clear and return-code-aware tohost handling.
CRT0="$ROOT/tests/dhrystone/crt0.S"
LINK_LD="$ROOT/tests/coremark/link.ld"

SRCS=(
  "$CRT0"
  "$SRC_DIR/string_bare.c"
  "$SRC_DIR/dhry_1.c"
  "$SRC_DIR/dhry_2.c"
)

mkdir -p "$ROOT/tests/hex"
"$CC" "${CFLAGS[@]}" -T "$LINK_LD" "${SRCS[@]}" -lgcc -o "$OUT_ELF"
eval "$ELF2HEX \"$OUT_ELF\" \"$OUT_HEX\""
echo "Built $OUT_ELF -> $OUT_HEX"

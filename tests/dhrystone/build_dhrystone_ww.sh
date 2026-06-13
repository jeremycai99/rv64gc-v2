#!/usr/bin/env bash
# Build Dhrystone 2.1 for the rv64gc-v2 simulator.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DHRY_DIR="$ROOT/tests/dhrystone"
SRC_DIR="$DHRY_DIR/src"

CC="${CC:-riscv64-unknown-elf-gcc}"
ELF2HEX="${ELF2HEX:-python3 $ROOT/scripts/elf2hex.py}"
OUT_ELF="${1:-$DHRY_DIR/dhrystone-ww.elf}"
OUT_HEX="${2:-$ROOT/tests/hex/dhrystone-ww.hex}"
NUM_RUNS="${NUM_RUNS:-100}"

CFLAGS=(
  -O2
  -march=rv64gc_zba_zbb_zbs_zicond
  -mabi=lp64d
  -mcmodel=medany
  # Normalized to BOOM/riscv-tests Dhrystone methodology (2026-05-29): string/mem
  # builtins ON (riscv-tests disables only -fno-builtin-printf), and NO -ffreestanding.
  # The old full -fno-builtin + -ffreestanding forced byte-at-a-time strcpy/strcmp/
  # memcpy (~90% of instr/iter; DMIPS 3.22). Normalized -O2 build = 4.27 DMIPS/MHz,
  # above BOOM's published 3.93 at matched methodology. IPC unchanged (~2.8) -> the
  # gap was the binary, not the microarchitecture. See memory project_dhrystone_gap_rootcause.
  -ffast-math
  -fno-tree-loop-distribute-patterns
  -fno-pic
  -fno-pie
  -fno-common
  -fno-asynchronous-unwind-tables
  -fno-unwind-tables
  -nostdlib
  -nostartfiles
  -static
  -no-pie
  -Wl,--build-id=none
  -I"$SRC_DIR"
  -DNUM_RUNS="$NUM_RUNS"
)

# Dhrystone needs a full .bss clear and return-code-aware tohost handling.
CRT0="$ROOT/tests/dhrystone/crt0.S"
LINK_LD="$ROOT/tests/coremark/link.ld"

SRCS=(
  "$CRT0"
  "$SRC_DIR/string_ww.c"
  "$SRC_DIR/dhry_1.c"
  "$SRC_DIR/dhry_2.c"
)

mkdir -p "$ROOT/tests/hex"
"$CC" "${CFLAGS[@]}" -T "$LINK_LD" "${SRCS[@]}" -lgcc -o "$OUT_ELF"
eval "$ELF2HEX \"$OUT_ELF\" \"$OUT_HEX\""
echo "Built $OUT_ELF -> $OUT_HEX"

#!/usr/bin/env bash
# Build CoreMark for the rv64gc-v2 simulator.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COREMARK_DIR="$ROOT/tests/coremark"
SRC_DIR="$COREMARK_DIR/src"

CC="${CC:-riscv64-unknown-elf-gcc}"
ELF2HEX="${ELF2HEX:-python3 $ROOT/scripts/elf2hex.py}"
OUT_ELF="${1:-$COREMARK_DIR/coremark.elf}"
OUT_HEX="${2:-$ROOT/tests/hex/coremark.hex}"

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
  -I"$COREMARK_DIR"
  -I"$SRC_DIR"
  -DITERATIONS=1
)

SRCS=(
  "$COREMARK_DIR/crt0.S"
  "$COREMARK_DIR/core_portme.c"
  "$SRC_DIR/core_list_join.c"
  "$SRC_DIR/core_main.c"
  "$SRC_DIR/core_matrix.c"
  "$SRC_DIR/core_state.c"
  "$SRC_DIR/core_util.c"
)

mkdir -p "$ROOT/tests/hex"
"$CC" "${CFLAGS[@]}" -T "$COREMARK_DIR/link.ld" "${SRCS[@]}" -lgcc -o "$OUT_ELF"
eval "$ELF2HEX \"$OUT_ELF\" \"$OUT_HEX\""
echo "Built $OUT_ELF -> $OUT_HEX"

#!/usr/bin/env bash
# Build CoreMark for the rv64gc-v2 simulator.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COREMARK_DIR="$ROOT/tests/coremark"
SRC_DIR="$COREMARK_DIR/src"

if [[ -z "${CC:-}" ]]; then
  if command -v riscv64-unknown-elf-gcc >/dev/null 2>&1; then
    CC="riscv64-unknown-elf-gcc"
    OBJDUMP="${OBJDUMP:-riscv64-unknown-elf-objdump}"
    OBJCOPY="${OBJCOPY:-riscv64-unknown-elf-objcopy}"
  elif command -v riscv64-linux-gnu-gcc >/dev/null 2>&1; then
    CC="riscv64-linux-gnu-gcc"
    OBJDUMP="${OBJDUMP:-riscv64-linux-gnu-objdump}"
    OBJCOPY="${OBJCOPY:-riscv64-linux-gnu-objcopy}"
  else
    echo "ERROR: no RISC-V GCC found (tried riscv64-unknown-elf-gcc and riscv64-linux-gnu-gcc)" >&2
    exit 1
  fi
else
  OBJDUMP="${OBJDUMP:-${CC%-gcc}-objdump}"
  OBJCOPY="${OBJCOPY:-${CC%-gcc}-objcopy}"
fi

ELF2HEX="${ELF2HEX:-python3 $ROOT/scripts/elf2hex.py --objdump $OBJDUMP --objcopy $OBJCOPY}"
OUT_ELF="${1:-$COREMARK_DIR/coremark.elf}"
OUT_HEX="${2:-$ROOT/tests/hex/coremark.hex}"
ITERATIONS="${ITERATIONS:-1}"

CFLAGS=(
  -O2
  -march=rv64gc_zba_zbb_zbs_zicond
  -mabi=lp64d
  -mcmodel=medany
  -ffreestanding
  -fno-pic
  -fno-pie
  -fno-builtin
  -fno-common
  -fno-asynchronous-unwind-tables
  -fno-unwind-tables
  -nostdlib
  -nostartfiles
  -static
  -no-pie
  -Wl,--build-id=none
  -I"$COREMARK_DIR"
  -I"$SRC_DIR"
  -DITERATIONS="$ITERATIONS"
)

if [[ -n "${EXTRA_CFLAGS:-}" ]]; then
  # shellcheck disable=SC2206
  EXTRA_CFLAGS_ARRAY=($EXTRA_CFLAGS)
  CFLAGS+=("${EXTRA_CFLAGS_ARRAY[@]}")
fi

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

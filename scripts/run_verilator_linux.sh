#!/usr/bin/env bash
# Run the Stage 3 Linux platform simulation binary with Verilator.
set -euo pipefail

cd "$(dirname "$0")/.."
PROJ_ROOT=$(pwd)

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <hex_path> [MAX_CYCLES] [extra_plusargs...]"
    exit 1
fi

HEX=$1
MAX_CYC=${2:-1000000}
if [[ $# -ge 2 ]]; then
    shift 2
else
    shift 1
fi
EXTRA_PLUSARGS=("$@")

case "$HEX" in
    /*) ;;
    *)  HEX="$PROJ_ROOT/$HEX" ;;
esac

BIN="${VERILATOR_LINUX_BIN:-$PROJ_ROOT/verilator_linux_work/Vtb_linux}"

if [[ ! -x "$BIN" ]]; then
    echo "ERROR: Verilator binary $BIN not found or not executable."
    echo "       Run scripts/build_verilator_linux.sh first."
    exit 1
fi

"$BIN" \
    "+MEMFILE=$HEX" \
    "+MAX_CYCLES=$MAX_CYC" \
    "${EXTRA_PLUSARGS[@]}"

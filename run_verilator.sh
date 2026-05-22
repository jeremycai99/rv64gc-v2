#!/usr/bin/env bash
# Run the benchmark simulation binary with Verilator.
set -euo pipefail

cd "$(dirname "$0")"
PROJ_ROOT=$(pwd)

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <hex_path> [MAX_CYCLES] [extra_plusargs...]"
    exit 1
fi

HEX=$1
MAX_CYC=${2:-100000}
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

BIN="${VERILATOR_BENCH_BIN:-$PROJ_ROOT/verilator_work/Vtb_xsim}"

if [[ ! -x "$BIN" ]]; then
    echo "ERROR: Verilator binary $BIN not found or not executable."
    echo "       Run ./build_verilator.sh first."
    exit 1
fi

"$BIN" \
    "+MEMFILE=$HEX" \
    "+MAX_CYCLES=$MAX_CYC" \
    "${EXTRA_PLUSARGS[@]}"

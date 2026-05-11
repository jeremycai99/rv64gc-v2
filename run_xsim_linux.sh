#!/usr/bin/env bash
# Run the Stage 3 Linux platform simulation snapshot with Vivado xsim.
set -euo pipefail

cd "$(dirname "$0")"
PROJ_ROOT=$(pwd)

: "${VIVADO_HOME:=/home/jeremycai/Xilinx/2025.2/Vivado}"

if [[ ! -f "$VIVADO_HOME/settings64.sh" ]]; then
    echo "ERROR: Vivado not found at $VIVADO_HOME"
    exit 1
fi

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <hex_path> [MAX_CYCLES] [extra_plusargs...]"
    exit 1
fi

HEX=$1
MAX_CYC=${2:-1000000}
shift
shift 2>/dev/null || true
EXTRA_PLUSARGS=("$@")

case "$HEX" in
    /*) ;;
    *)  HEX="$PROJ_ROOT/$HEX" ;;
esac

PARALLEL_PARENT="$PROJ_ROOT/xsim_linux_parallel"
XSIM_LOGFILE="${XSIM_LOGFILE:-$PROJ_ROOT/xsim_linux_run.log}"

if [[ ! -d "$PARALLEL_PARENT/xsim.dir/tb_linux_sim" ]]; then
    echo "ERROR: snapshot $PARALLEL_PARENT/xsim.dir/tb_linux_sim not found."
    echo "       Run ./build_xsim_linux.sh first."
    exit 1
fi

set +u
# shellcheck disable=SC1091
source "$VIVADO_HOME/settings64.sh"
set -u

cd "$PARALLEL_PARENT"

PLUSARG_FLAGS=(
    --testplusarg "MEMFILE=$HEX"
    --testplusarg "MAX_CYCLES=$MAX_CYC"
)
for arg in "${EXTRA_PLUSARGS[@]:-}"; do
    [[ -z "$arg" ]] && continue
    PLUSARG_FLAGS+=(--testplusarg "${arg#+}")
done

set +e
xsim tb_linux_sim --runall --log "$XSIM_LOGFILE" "${PLUSARG_FLAGS[@]}"
RC=$?
set -e

cd "$PROJ_ROOT"

if [[ $RC -ne 0 ]]; then
    echo "xsim Linux run exited with code $RC"
else
    echo "xsim Linux run complete. Log: $XSIM_LOGFILE"
fi
exit $RC

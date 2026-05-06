#!/usr/bin/env bash
# ============================================================================
# run_xsim.sh -- run a test/benchmark under Vivado xsim (Linux port)
#
# Usage:
#   ./run_xsim.sh <hex_path> [MAX_CYCLES] [extra_plusargs...]
#
# Example:
#   ./run_xsim.sh tests/benchmarks/coremark_O2.hex 500000
#   ./run_xsim.sh tests/hex/dhrystone.hex 10000 +PERF_PROFILE +TRACE_FETCH
#
# Reads the snapshot tb_xsim_sim from xsim_parallel/xsim.dir/  (the user's
# existing xsim.dir/ snapshot is untouched — see build_xsim.sh header).
#
# Produces:
#   xsim_run.log    -- simulation log (IPC, $finish summary, errors)
# ============================================================================
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
MAX_CYC=${2:-200000}
shift
shift 2>/dev/null || true
EXTRA_PLUSARGS=("$@")

# Make HEX absolute so plusarg works no matter what cwd xsim runs from.
case "$HEX" in
    /*) ;;                     # already absolute
    *)  HEX="$PROJ_ROOT/$HEX" ;;
esac

PARALLEL_PARENT="$PROJ_ROOT/xsim_parallel"

if [[ ! -d "$PARALLEL_PARENT/xsim.dir/tb_xsim_sim" ]]; then
    echo "ERROR: snapshot $PARALLEL_PARENT/xsim.dir/tb_xsim_sim not found."
    echo "       Run ./build_xsim.sh first."
    exit 1
fi

# Vivado's settings64.sh references unset PYTHONPATH; relax -u for sourcing.
set +u
# shellcheck disable=SC1091
source "$VIVADO_HOME/settings64.sh"
set -u

# Run from PARALLEL_PARENT so xsim picks up the snapshot in ./xsim.dir/.
# Drop the run log into PROJ_ROOT/xsim_run.log so it's easy to find.
cd "$PARALLEL_PARENT"

# Build plusargs first (need to forward each EXTRA arg as its own --testplusarg).
PLUSARG_FLAGS=(
    --testplusarg "MEMFILE=$HEX"
    --testplusarg "MAX_CYCLES=$MAX_CYC"
    --testplusarg "NOVCD"
)
for arg in "${EXTRA_PLUSARGS[@]:-}"; do
    [[ -z "$arg" ]] && continue
    # Strip leading '+' if user passed +KEY=val style (matches dsim flow).
    PLUSARG_FLAGS+=(--testplusarg "${arg#+}")
done

set +e
xsim tb_xsim_sim --runall --log "$PROJ_ROOT/xsim_run.log" "${PLUSARG_FLAGS[@]}"
RC=$?
set -e

cd "$PROJ_ROOT"

if [[ $RC -ne 0 ]]; then
    echo "xsim run exited with code $RC"
else
    echo "xsim run complete.  Log: xsim_run.log"
fi
exit $RC

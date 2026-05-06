#!/usr/bin/env bash
# ============================================================================
# run_dsim.sh -- run a test/benchmark under DSim 2026 (Linux port)
#
# Usage:
#   ./run_dsim.sh <hex_path> [MAX_CYCLES] [extra_plusargs...]
#
# Example:
#   ./run_dsim.sh tests/benchmarks/coremark_O2.hex 500000
#   ./run_dsim.sh tests/hex/dhrystone.hex 10000 +PERF_PROFILE +TRACE_FETCH
#
# Produces:
#   dsim_run.log    -- simulation log (IPC, SVA fires, final summary)
#   run.mxd         -- MXD waveform (assertion-aware; open in DSim Studio)
# ============================================================================
set -euo pipefail

cd "$(dirname "$0")"

: "${DSIM_HOME:=$HOME/AltairDSim/2026}"

if [[ ! -f "$DSIM_HOME/shell_activate.bash" ]]; then
    echo "ERROR: DSim not found at $DSIM_HOME"
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

# shellcheck disable=SC1091
set +u
source "$DSIM_HOME/shell_activate.bash" >/dev/null
set -u

if [[ -z "${DSIM_LICENSE:-}" ]]; then
    if [[ -f "$HOME/metrics-ca/dsim-license.json" ]]; then
        export DSIM_LICENSE="$HOME/metrics-ca/dsim-license.json"
    elif [[ -f "$HOME/.metrics-ca/dsim-license.json" ]]; then
        export DSIM_LICENSE="$HOME/.metrics-ca/dsim-license.json"
    fi
fi

if [[ ! -f dsim_work/tb_image.so ]]; then
    echo "ERROR: dsim_work/tb_image.so not found.  Run ./build_dsim.sh first."
    exit 1
fi

# -image     run the pre-compiled image (name resolved under dsim_work/)
# -waves     MXD dump for assertion-aware wave viewer (compile used +acc)
# -l         log file
# +plusargs  forwarded verbatim to tb_xsim
dsim -image tb_image \
     -waves run.mxd \
     -l dsim_run.log \
     +MEMFILE="$HEX" \
     +MAX_CYCLES="$MAX_CYC" \
     "${EXTRA_PLUSARGS[@]}"
RC=$?

if [[ $RC -ne 0 ]]; then
    echo "DSim run exited with code $RC"
else
    echo "DSim run complete.  Log: dsim_run.log   Waves: run.mxd"
fi
exit $RC

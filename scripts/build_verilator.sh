#!/usr/bin/env bash
# Build the benchmark simulation binary with Verilator.
set -euo pipefail

cd "$(dirname "$0")/.."

VERILATOR_BIN="${VERILATOR:-verilator}"
WORK_DIR="${VERILATOR_BENCH_WORK_DIR:-verilator_work}"
JOBS="${VERILATOR_JOBS:-0}"
CONVERGE_LIMIT="${VERILATOR_CONVERGE_LIMIT:-100}"
FLATTEN="${VERILATOR_FLATTEN:-1}"
X_MODE="${VERILATOR_X_MODE:-0}"
TRACE="${VERILATOR_TRACE:-0}"
REPORT_UNOPTFLAT="${VERILATOR_REPORT_UNOPTFLAT:-1}"

if ! command -v "$VERILATOR_BIN" >/dev/null 2>&1; then
    echo "ERROR: Verilator not found: $VERILATOR_BIN"
    exit 1
fi

mapfile -t SV_FILES < <(
    awk '
        {
            for (idx = 1; idx <= NF; idx++) {
                gsub(/\\$/, "", $idx);
                if ($idx ~ /\.sv$/ && $idx != "src/rtl/sim/fetch_frontend_assertions.sv") {
                    print $idx;
                }
            }
        }
    ' scripts/build_dsim.sh
)

if [[ ${#SV_FILES[@]} -eq 0 ]]; then
    echo "ERROR: no SystemVerilog files found in scripts/build_dsim.sh"
    exit 1
fi

rm -rf "$WORK_DIR"

FLATTEN_ARGS=()
if [[ "$FLATTEN" != "0" ]]; then
    FLATTEN_ARGS=("--flatten")
fi

UNOPTFLAT_ARGS=("-Wwarn-UNOPTFLAT" "-Wno-fatal")
if [[ "$REPORT_UNOPTFLAT" != "0" ]]; then
    UNOPTFLAT_ARGS+=("--report-unoptflat")
fi

TRACE_ARGS=()
if [[ "$TRACE" != "0" ]]; then
    TRACE_ARGS=("--trace")
fi

"$VERILATOR_BIN" --binary --timing "${TRACE_ARGS[@]}" "${FLATTEN_ARGS[@]}" \
    --converge-limit "$CONVERGE_LIMIT" \
    --x-assign "$X_MODE" \
    --x-initial "$X_MODE" \
    -j "$JOBS" \
    -DSIMULATION \
    -Iexternal/cvfpu-src/src/common_cells/include \
    -Wno-WIDTHEXPAND \
    -Wno-WIDTHTRUNC \
    -Wno-UNUSEDSIGNAL \
    "${UNOPTFLAT_ARGS[@]}" \
    -Wno-CASEINCOMPLETE \
    -Wno-UNSIGNED \
    -Wno-MULTIDRIVEN \
    -Wno-LATCH \
    -Wno-BLKANDNBLK \
    -Wno-COMBDLY \
    -Wno-BLKLOOPINIT \
    -Wno-DECLFILENAME \
    -Wno-PINCONNECTEMPTY \
    -Wno-IMPORTSTAR \
    -Wno-TIMESCALEMOD \
    -Wno-ASCRANGE \
    --Mdir "$WORK_DIR" \
    --top-module tb_xsim \
    "${SV_FILES[@]}"

echo
echo "Verilator benchmark build OK. Binary at $WORK_DIR/Vtb_xsim"
echo "Run with: scripts/run_verilator.sh <hex_path> [MAX_CYCLES] [extra_plusargs...]"
if [[ "$TRACE" == "0" ]]; then
    echo "Waveform tracing disabled. Rebuild with VERILATOR_TRACE=1 when waveforms are required."
fi

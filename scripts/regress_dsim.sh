#!/usr/bin/env bash
# ============================================================================
# regress_dsim.sh — dsim regression for rv64gc-v2
#
# Usage:
#   scripts/regress_dsim.sh                    # run full suite
#   scripts/regress_dsim.sh --func             # functional only (rv64ui_*)
#   scripts/regress_dsim.sh --bench            # benchmarks only (DS + CM)
#   scripts/regress_dsim.sh --extra-plusargs "+FOO +BAR"
#
# Required by the project's performance-change discipline:
#   - Functional check: every rv64ui_*.hex (and bench_*.hex if present)
#     must reach PASS within its small cap.
#   - End-to-end: dhrystone (iter=100) and coremark (iter=1 + iter=10)
#     must finish at STOP cleanly — not TIMEOUT, not dsim IterLimit abort.
#   - Benchmark rows are delegated to tools/run_benchmarks.py in signoff mode,
#     so checksum/flags/control/image-hash/loop-buffer gates are enforced.
#
# IPC is reported but the gating criterion is "finished normally".
# Cycle caps are sized with reasonable margin over expected length.
# ============================================================================
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

# --- Sanity ------------------------------------------------------------------
if [[ ! -f dsim_work/tb_image.so ]]; then
    echo "ERROR: dsim_work/tb_image.so missing — run scripts/build_dsim.sh first."
    exit 1
fi

: "${DSIM_HOME:=$HOME/AltairDSim/2026}"
# shellcheck disable=SC1091
source "$DSIM_HOME/shell_activate.bash" >/dev/null
[[ -z "${DSIM_LICENSE:-}" && -f "$HOME/metrics-ca/dsim-license.json" ]] && \
    export DSIM_LICENSE="$HOME/metrics-ca/dsim-license.json"

# --- Args --------------------------------------------------------------------
RUN_FUNC=1
RUN_BENCH=1
EXTRA_PLUSARGS=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --func)             RUN_BENCH=0;            shift ;;
        --bench)            RUN_FUNC=0;             shift ;;
        --extra-plusargs)   EXTRA_PLUSARGS=$2;      shift 2 ;;
        -h|--help)
            sed -n '2,15p' "$0"
            exit 0 ;;
        *)  echo "Unknown arg: $1"; exit 2 ;;
    esac
done

LOG_DIR="benchmark_results/regress_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG_DIR"
SUMMARY="$LOG_DIR/summary.txt"
: > "$SUMMARY"

PASS_CNT=0
FAIL_CNT=0

# --- Helper: run one dsim test and classify result ---------------------------
# Args: name, hex, max_cycles, [extra_plusargs]
# Records PASS / FAIL / TIMEOUT / ITERLIMIT to $SUMMARY plus IPC line.
run_test() {
    local name=$1 hex=$2 max=$3
    local extra=${4:-}
    local log="$LOG_DIR/$name.log"
    local rc

    printf '  %-32s ... ' "$name"
    # iter-limit set high so a structural-loop hit shows up clearly as ITERLIMIT
    # rather than getting lost in dsim's default 1M
    dsim -image tb_image \
         -iter-limit 10000000 \
         -l "$log" \
         +MEMFILE="$hex" \
         +MAX_CYCLES="$max" \
         $extra $EXTRA_PLUSARGS \
         > "$log.stdout" 2>&1
    rc=$?

    local status ipc cyc instret stop_seen=""
    if   grep -q "IterLimit"           "$log" 2>/dev/null; then status="ITERLIMIT"
    elif grep -q "PASS at cycle"       "$log" 2>/dev/null; then status="PASS"
    elif grep -q "TIMEOUT after"       "$log" 2>/dev/null; then status="TIMEOUT"
    elif grep -q "FAIL at cycle"       "$log" 2>/dev/null; then status="FAIL"
    # Magic TOHOST= without PASS message is suspicious (e.g., HTIF syscall, BPU
    # mistraining cascade, etc.) — flag explicitly instead of treating as PASS.
    elif grep -q "^TOHOST="           "$log" 2>/dev/null; then status="TOHOST_MAGIC"
    else                                                       status="UNKNOWN(rc=$rc)"
    fi
    # STOP-OK requires either a proper [BENCH_RESULT] control=2 or a real
    # PASS at tohost=1. Magic TOHOST values (no PASS line) are NOT STOP-OK.
    if grep -qE '\[BENCH_RESULT\].*field=control value=2' "$log" 2>/dev/null; then
        stop_seen="STOP-OK"
    elif grep -q "PASS at cycle" "$log" 2>/dev/null; then
        stop_seen="STOP-OK"
    fi
    ipc=$(grep -E '^IPC: ' "$log" 2>/dev/null | tail -1 | sed -E 's/.*IPC=([0-9.eE+-]+).*/\1/')
    cyc=$(grep -E '^IPC: ' "$log" 2>/dev/null | tail -1 | sed -E 's/.*mcycle=([0-9]+).*/\1/')
    instret=$(grep -E '^IPC: ' "$log" 2>/dev/null | tail -1 | sed -E 's/.*minstret=([0-9]+).*/\1/')
    [[ -z $ipc ]] && ipc="-"
    [[ -z $cyc ]] && cyc="-"
    [[ -z $instret ]] && instret="-"

    printf '%-9s  cyc=%-10s  instret=%-10s  ipc=%-8s  %s\n' \
        "$status" "$cyc" "$instret" "$ipc" "$stop_seen"
    printf '%-32s  %-9s  cyc=%-10s  instret=%-10s  ipc=%-8s  %s\n' \
        "$name" "$status" "$cyc" "$instret" "$ipc" "$stop_seen" >> "$SUMMARY"

    if [[ $status == "PASS" ]]; then
        ((PASS_CNT++))
    else
        ((FAIL_CNT++))
    fi
}

# --- Functional regression (rv64ui_* + bench_*; small cap) -------------------
if (( RUN_FUNC )); then
    echo "=== Functional regression (rv64ui_*, bench_*) ==="
    shopt -s nullglob
    for hex in tests/hex/rv64ui_*.hex tests/hex/bench_*.hex; do
        name=$(basename "$hex" .hex)
        run_test "$name" "$hex" 20000
    done
    shopt -u nullglob
fi

# --- Benchmark regression with reasonable cycle margins ---------------------
# Expected lengths (4-wide RTL, Stage 2):
#   dhrystone iter=100:     ~23.5k cyc → 70k cap   (3x margin)
#   coremark  iter=10:      ~1.65M cyc → 5M cap    (3x margin)
#   coremark  iter=10 (same binary aliased as iter1): ~1.65M cyc → 5M cap
# NOTE: coremark.hex and coremark_iter10.hex appear to be the same ITERATIONS=10
#       binary (both take 1.65M cycles on 4-wide). The naming dates from the
#       6-wide era.  The gate criterion is STOP cleanly, not cycle count.
if (( RUN_BENCH )); then
    echo "=== Benchmarks (manifest-gated signoff rows) ==="
    BENCH_PLUSARGS=(--plusarg PERF_PROFILE --plusarg PERF_COUNTERS --plusarg STAT_DUMP)
    if [[ -n "$EXTRA_PLUSARGS" ]]; then
        read -r -a EXTRA_PLUSARGS_ARR <<< "$EXTRA_PLUSARGS"
        for arg in "${EXTRA_PLUSARGS_ARR[@]}"; do
            BENCH_PLUSARGS+=(--plusarg "$arg")
        done
    fi
    BENCH_RUN_DIR="$LOG_DIR/benchmarks"
    if python3 tools/run_benchmarks.py \
        --runner dsim \
        --run-class signoff \
        --manifest tests/benchmarks/coverage_expansion.json \
        --bench dhrystone_100,coremark_iter1,coremark_iter10 \
        --run-dir "$BENCH_RUN_DIR" \
        "${BENCH_PLUSARGS[@]}"; then
        printf '%-32s  %-9s  %s\n' "benchmark_signoff_manifest" "PASS" "$BENCH_RUN_DIR" >> "$SUMMARY"
        ((PASS_CNT += 3))
    else
        printf '%-32s  %-9s  %s\n' "benchmark_signoff_manifest" "FAIL" "$BENCH_RUN_DIR" >> "$SUMMARY"
        ((FAIL_CNT++))
    fi
fi

echo
echo "=== Summary ==="
column -t "$SUMMARY"
echo "----------------------------------------"
echo "Total: $((PASS_CNT + FAIL_CNT))   PASS: $PASS_CNT   FAIL/OTHER: $FAIL_CNT"
echo "Log dir: $LOG_DIR"

(( FAIL_CNT == 0 ))

#!/usr/bin/env bash
# D-prefetch FUND/KILL census driver (sim-only). Runs the +PERF_PROFILE bench
# binary (with the DPF census in lsu.sv) on a workload, captures the
# [DPREFETCH CENSUS] block + IPC, writes a per-workload log under
# log/dpf_census_2026-06-14/. nice -n 10, never touches the running boot.
set -uo pipefail
cd "$(dirname "$0")/.."
BIN="${DPF_BIN:-verilator_bench_dpfcensus/Vtb_xsim}"
OUTDIR="log/dpf_census_2026-06-14"
mkdir -p "$OUTDIR"
NAME="$1"; HEX="$2"; MAXCYC="$3"; TO="${4:-1200}"
LOG="$OUTDIR/${NAME}.log"
echo "[DPF] $NAME hex=$HEX maxcyc=$MAXCYC timeout=${TO}s -> $LOG"
nice -n 10 timeout "$TO" "$BIN" "+MEMFILE=$HEX" "+MAX_CYCLES=$MAXCYC" +PERF_PROFILE \
    > "$LOG" 2>&1
ec=$?
echo "[DPF] $NAME exit=$ec"
grep -E "IPC:|DPF |=== DPRE|PASS at|FAIL|TOHOST|HALT" "$LOG" | tail -16

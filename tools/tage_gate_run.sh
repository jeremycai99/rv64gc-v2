#!/usr/bin/env bash
# tage_gate_run.sh — run the misp-band rows on one arm's binary, capture
# IPC + bpu_dyn_total + top per-PC misp.  Sim-only, no RTL.
# Usage: tage_gate_run.sh <Vtb_xsim_binary> <out_dir>
set -uo pipefail
BIN="$1"
OUT="$2"
mkdir -p "$OUT"
PROJ=/home/jeremycai/agent-workspace/rv64gc-v2

# row : hexfile : max_cycles  (cycles sized to let each row finish to STOP)
ROWS=(
  "md5sum:embench-md5sum:3000000"
  "aha-mont64:embench-aha-mont64:12000000"
  "sglib-combined:embench-sglib-combined:16000000"
  "qrduino:embench-qrduino:20000000"
  "huffbench:embench-huffbench:14000000"
  "rvb-median:rvb-median:3000000"
  "rvb-qsort:rvb-qsort:3000000"
  "crc32:embench-crc32:3000000"
)

for entry in "${ROWS[@]}"; do
  IFS=':' read -r name hex maxc <<< "$entry"
  hexpath="$PROJ/tests/hex/${hex}.hex"
  if [[ ! -f "$hexpath" ]]; then echo "MISSING $hexpath"; continue; fi
  nice -n 10 "$BIN" "+MEMFILE=$hexpath" "+MAX_CYCLES=$maxc" +PERF_PROFILE \
      > "$OUT/${name}.log" 2>&1
  # one-line summary
  ipc=$(grep -E "^IPC:" "$OUT/${name}.log" | tail -1)
  done_line=$(grep -E "PASS at cycle|FAIL at cycle|TOHOST=|TIMEOUT" "$OUT/${name}.log" | tail -1)
  tot=$(grep -E "^bpu_dyn_total" "$OUT/${name}.log" | tail -1)
  echo "ROW=$name | $done_line | $ipc"
  echo "  $tot"
done

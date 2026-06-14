#!/usr/bin/env bash
# tage_gate_analyze.sh — extract IPC + total_misp per row per arm, compute deltas.
# Usage: tage_gate_analyze.sh   (reads /tmp/tage_gate/{a0,a1,a2,a3})
set -uo pipefail
BASE=/tmp/tage_gate
ROWS="md5sum aha-mont64 sglib-combined qrduino huffbench rvb-median rvb-qsort crc32"
ARMS="a0 a1 a2 a3"

get_ipc()  { grep -E "^IPC:" "$1" 2>/dev/null | tail -1 | grep -oE "IPC=[0-9.]+" | cut -d= -f2; }
get_misp() { grep -E "^bpu_dyn_total" "$1" 2>/dev/null | tail -1 | grep -oE "misp=[0-9]+" | cut -d= -f2; }
get_cyc()  { grep -E "^IPC:" "$1" 2>/dev/null | tail -1 | grep -oE "mcycle=[0-9]+" | cut -d= -f2; }
get_tagehit(){ grep -E "^bpu_dyn_total" "$1" 2>/dev/null | tail -1 | grep -oE "tage_hit=[0-9]+" | cut -d= -f2; }
get_upd()  { grep -E "^bpu_dyn_total" "$1" 2>/dev/null | tail -1 | grep -oE "updates=[0-9]+" | cut -d= -f2; }

printf "%-16s | %-28s | %-28s | %-28s | %-28s\n" "ROW" "A0 base (IPC/misp)" "A1 TAGE1024 (IPC/misp/Δ)" "A2 LOOP256 (IPC/misp/Δ)" "A3 BIG-ALL (IPC/misp/Δ)"
for r in $ROWS; do
  b_ipc=$(get_ipc $BASE/a0/$r.log); b_misp=$(get_misp $BASE/a0/$r.log)
  line=$(printf "%-16s | %6s / %-8s          " "$r" "${b_ipc:-NA}" "${b_misp:-NA}")
  for a in a1 a2 a3; do
    ipc=$(get_ipc $BASE/$a/$r.log); misp=$(get_misp $BASE/$a/$r.log)
    if [[ -n "$b_misp" && -n "$misp" && "$b_misp" != "0" ]]; then
      dm=$(awk "BEGIN{printf \"%+.2f%%\", 100.0*($misp-$b_misp)/$b_misp}")
    else dm="NA"; fi
    if [[ -n "$b_ipc" && -n "$ipc" ]]; then
      di=$(awk "BEGIN{printf \"%+.4f\", $ipc-$b_ipc}")
    else di="NA"; fi
    line+=$(printf " | %6s / %-7s %s (%s)" "${ipc:-NA}" "${misp:-NA}" "$dm" "$di")
  done
  echo "$line"
done

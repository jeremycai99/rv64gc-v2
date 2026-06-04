#!/usr/bin/env bash
# Full-design Verilator UNOPTFLAT (combinational-loop) lint for the fetch path.
# Uses build_dsim_linux.sh's EXACT file order (cvfpu packages before modules), dropping the
# 2 bind-only SVA checker files (4-arg $past Verilator rejects; they drive no design nets so
# cannot hide a loop). Prints UNOPTFLAT lines.
set -o pipefail
cd /home/jeremycai/agent-workspace/rv64gc-v2
export LD_LIBRARY_PATH=""
# All compile files in build-script order: packages, cvfpu (ordered), then RTL.
FILES=$(grep -oE "(src/rtl|external/cvfpu-src)[^ ]+\.sv" scripts/build_dsim_linux.sh \
        | awk '!seen[$0]++' \
        | grep -vE "fetch_frontend_assertions|branch_recovery_contract_checker" \
        | tr '\n' ' ')
verilator --lint-only --timing +define+SIMULATION \
  -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-CASEINCOMPLETE -Wno-WIDTHEXPAND \
  -Wno-WIDTHTRUNC -Wno-IMPLICIT -Wno-PINMISSING -Wno-BLKLOOPINIT -Wno-TIMESCALEMOD \
  +incdir+external/cvfpu-src/src/common_cells/include \
  +incdir+src/rtl/core/include \
  --top-module tb_linux \
  $FILES src/tb/tb_linux.sv 2>&1

#!/usr/bin/env bash
# Build the Stage 3 Linux platform simulation image with DSim.
set -euo pipefail

cd "$(dirname "$0")"

: "${DSIM_HOME:=$HOME/AltairDSim/2026}"

if [[ ! -f "$DSIM_HOME/shell_activate.bash" ]]; then
    echo "ERROR: DSim not found at $DSIM_HOME"
    exit 1
fi

set +u
# shellcheck disable=SC1091
source "$DSIM_HOME/shell_activate.bash" >/dev/null
set -u

if [[ -z "${DSIM_LICENSE:-}" ]]; then
    if [[ -f "$HOME/metrics-ca/dsim-license.json" ]]; then
        export DSIM_LICENSE="$HOME/metrics-ca/dsim-license.json"
    elif [[ -f "$HOME/.metrics-ca/dsim-license.json" ]]; then
        export DSIM_LICENSE="$HOME/.metrics-ca/dsim-license.json"
    fi
fi

rm -rf dsim_linux_work

dsim -sv +define+SIMULATION +acc+rwb \
     -work dsim_linux_work \
     -top tb_linux \
     -genimage tb_linux_image \
     -l dsim_linux_build.log \
     src/rtl/core/include/rv64gc_pkg.sv \
     src/rtl/core/include/isa_pkg.sv \
     src/rtl/core/include/uarch_pkg.sv \
     src/rtl/sim/mem_if_pkg.sv \
     src/rtl/core/frontend/instr/rvc_decompress.sv \
     src/rtl/core/frontend/instr/rvc_expander.sv \
     src/rtl/core/frontend/instr/predecode.sv \
     src/rtl/core/frontend/instr/instr_boundary.sv \
     src/rtl/core/frontend/instr/instr_compact.sv \
     src/rtl/core/frontend/pred/pred_checker.sv \
     src/rtl/core/bpu/btb.sv \
     src/rtl/core/bpu/ras.sv \
     src/rtl/core/bpu/tage_sc_l.sv \
     src/rtl/core/bpu/bpu.sv \
     src/rtl/core/cache/icache_tag_ram.sv \
     src/rtl/core/cache/icache_data_ram.sv \
     src/rtl/core/cache/icache.sv \
     src/rtl/core/cache/icache_resp_queue.sv \
     src/rtl/core/frontend/ifu/next_line_prefetch_buffer.sv \
     src/rtl/core/frontend/ifu/ifu_line_fetch.sv \
     src/rtl/core/frontend/ifu/ifu_duplicate_guard.sv \
     src/rtl/core/frontend/ifu/ifu.sv \
     src/rtl/core/frontend/ftq/ftq.sv \
     src/rtl/core/frontend/ibuffer/fetch_packet_buffer.sv \
     src/rtl/core/frontend/ibuffer/ibuffer.sv \
     src/rtl/core/frontend/top/fetch_top.sv \
     src/rtl/sim/fetch_delivery_checker.sv \
     src/rtl/sim/fetch_owner_checker.sv \
     src/rtl/sim/fetch_frontend_profiler.sv \
     src/rtl/sim/bpu_dynamic_profiler.sv \
     src/rtl/sim/fetch_trace_probe.sv \
     src/rtl/sim/fetch_frontend_assertions.sv \
     src/rtl/core/decode/decode_slice.sv \
     src/rtl/core/decode/decode.sv \
     src/rtl/core/decode/fusion_detector.sv \
     src/rtl/core/uop_cache/uop_cache_tag_ram.sv \
     src/rtl/core/uop_cache/uop_cache_data_ram.sv \
     src/rtl/core/uop_cache/uop_cache.sv \
     src/rtl/core/rename/rat.sv \
     src/rtl/core/rename/free_list.sv \
     src/rtl/core/rename/checkpoint.sv \
     src/rtl/sim/branch_recovery_contract_checker.sv \
     src/rtl/core/rename/rename.sv \
     src/rtl/core/dispatch/dispatch_queue.sv \
     src/rtl/core/issue/wakeup_network.sv \
     src/rtl/core/issue/issue_queue.sv \
     src/rtl/core/execute/alu.sv \
     src/rtl/core/execute/bru.sv \
     src/rtl/core/execute/multiplier.sv \
     src/rtl/core/execute/divider.sv \
     src/rtl/core/regfile/int_prf.sv \
     src/rtl/core/bypass_network.sv \
     src/rtl/core/backend/rob.sv \
     src/rtl/core/backend/commit.sv \
     src/rtl/core/lsu/store_queue.sv \
     src/rtl/core/lsu/load_queue.sv \
     src/rtl/core/lsu/committed_store_buffer.sv \
     src/rtl/core/lsu/lsu.sv \
     src/rtl/core/cache/dcache_tag_ram.sv \
     src/rtl/core/cache/dcache_data_ram.sv \
     src/rtl/core/cache/dcache.sv \
     src/rtl/core/cache/l2_cache.sv \
     src/rtl/core/csr/csr_file.sv \
     src/rtl/platform/uart_16550.sv \
     src/rtl/platform/clint.sv \
     src/rtl/platform/mmio_platform.sv \
     src/rtl/sim/sim_memory.sv \
     src/rtl/core/rv64gc_core_top.sv \
     src/tb/tb_linux.sv

echo
echo "DSim Linux platform build OK. Image at dsim_linux_work/tb_linux_image.so"
echo "Run with: dsim -work dsim_linux_work -image tb_linux_image +MEMFILE=<hex>"

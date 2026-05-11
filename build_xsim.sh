#!/usr/bin/env bash
# ============================================================================
# build_xsim.sh -- Vivado xsim build for rv64gc-v2 (Linux port of build_xsim.bat)
#
# Mirrors build_xsim.bat (Windows) and build_dsim.sh (DSim).  xsim is the
# authoritative simulator; this script lets us run xsim in parallel with
# DSim on Linux (DSim has a 1-lease cloud license, xsim has no such cap).
#
# Prereq: Vivado 2025.2 installed at /home/jeremycai/Xilinx/2025.2/Vivado/.
#   default VIVADO_HOME=/home/jeremycai/Xilinx/2025.2/Vivado
# Override before calling if installed elsewhere.
#
# Snapshot: xsim_parallel/xsim.dir/tb_xsim_sim/  (xsim hardcodes ./xsim.dir/
# as the snapshot/work parent, so we cd into a sibling parent directory to
# keep the existing xsim.dir/ snapshot intact for the user's other build).
# Snapshot name: tb_xsim_sim (matches the Windows flow).
# ============================================================================
set -euo pipefail

cd "$(dirname "$0")"
PROJ_ROOT=$(pwd)

: "${VIVADO_HOME:=/home/jeremycai/Xilinx/2025.2/Vivado}"

if [[ ! -f "$VIVADO_HOME/settings64.sh" ]]; then
    echo "ERROR: Vivado not found at $VIVADO_HOME"
    echo "Set VIVADO_HOME to the install dir (containing settings64.sh)."
    exit 1
fi

# Vivado's settings64.sh references unset PYTHONPATH; relax -u for sourcing.
set +u
# shellcheck disable=SC1091
source "$VIVADO_HOME/settings64.sh"
set -u

# xsim's xvlog/xelab/xsim hardcode "./xsim.dir/" relative to the cwd as the
# work + snapshot location.  To avoid clobbering the user's existing
# xsim.dir/ snapshot, we run all tools from a sibling parent directory.
PARALLEL_PARENT="$PROJ_ROOT/xsim_parallel"
rm -rf "$PARALLEL_PARENT"
mkdir -p "$PARALLEL_PARENT"
cd "$PARALLEL_PARENT"

# RTL files are listed relative to PROJ_ROOT.
P="$PROJ_ROOT"

# --- Compile ----------------------------------------------------------------
# --sv               treat all files as SystemVerilog
# --relax            allow non-strict LRM constructs (matches Windows .bat)
# -d SIMULATION      enables defensive ifdef resets in int_prf / cache RAMs
# (run from PARALLEL_PARENT so work lib lands at PARALLEL_PARENT/xsim.dir/work/)
xvlog --sv --relax -d SIMULATION -d XSIM \
      -i "$P/external/cvfpu-src/src/common_cells/include" \
      "$P/src/rtl/core/include/rv64gc_pkg.sv" \
      "$P/src/rtl/core/include/isa_pkg.sv" \
      "$P/src/rtl/core/include/fpu_pkg.sv" \
      "$P/src/rtl/core/include/uarch_pkg.sv" \
      "$P/src/rtl/sim/mem_if_pkg.sv" \
      "$P/external/cvfpu-src/src/common_cells/src/cf_math_pkg.sv" \
      "$P/external/cvfpu-src/src/common_cells/src/lzc.sv" \
      "$P/external/cvfpu-src/src/common_cells/src/rr_arb_tree.sv" \
      "$P/external/cvfpu-src/src/fpu_div_sqrt_mvp/hdl/defs_div_sqrt_mvp.sv" \
      "$P/external/cvfpu-src/src/fpu_div_sqrt_mvp/hdl/iteration_div_sqrt_mvp.sv" \
      "$P/external/cvfpu-src/src/fpu_div_sqrt_mvp/hdl/control_mvp.sv" \
      "$P/external/cvfpu-src/src/fpu_div_sqrt_mvp/hdl/norm_div_sqrt_mvp.sv" \
      "$P/external/cvfpu-src/src/fpu_div_sqrt_mvp/hdl/preprocess_mvp.sv" \
      "$P/external/cvfpu-src/src/fpu_div_sqrt_mvp/hdl/nrbd_nrsc_mvp.sv" \
      "$P/external/cvfpu-src/src/fpu_div_sqrt_mvp/hdl/div_sqrt_top_mvp.sv" \
      "$P/external/cvfpu-src/src/fpu_div_sqrt_mvp/hdl/div_sqrt_mvp_wrapper.sv" \
      "$P/external/cvfpu-src/src/fpnew_pkg.sv" \
      "$P/external/cvfpu-src/src/fpnew_cast_multi.sv" \
      "$P/external/cvfpu-src/src/fpnew_classifier.sv" \
      "$P/external/cvfpu-src/src/fpnew_divsqrt_multi.sv" \
      "$P/external/cvfpu-src/src/fpnew_fma.sv" \
      "$P/external/cvfpu-src/src/fpnew_fma_multi.sv" \
      "$P/external/cvfpu-src/src/fpnew_noncomp.sv" \
      "$P/external/cvfpu-src/src/fpnew_opgroup_block.sv" \
      "$P/external/cvfpu-src/src/fpnew_opgroup_fmt_slice.sv" \
      "$P/external/cvfpu-src/src/fpnew_opgroup_multifmt_slice.sv" \
      "$P/external/cvfpu-src/src/fpnew_rounding.sv" \
      "$P/external/cvfpu-src/src/fpnew_top.sv" \
      "$P/src/rtl/core/frontend/instr/rvc_decompress.sv" \
      "$P/src/rtl/core/frontend/instr/rvc_expander.sv" \
      "$P/src/rtl/core/frontend/instr/predecode.sv" \
      "$P/src/rtl/core/frontend/instr/instr_boundary.sv" \
      "$P/src/rtl/core/frontend/instr/instr_compact.sv" \
      "$P/src/rtl/core/frontend/pred/pred_checker.sv" \
      "$P/src/rtl/core/bpu/btb.sv" \
      "$P/src/rtl/core/bpu/ras.sv" \
      "$P/src/rtl/core/bpu/tage_sc_l.sv" \
      "$P/src/rtl/core/bpu/bpu.sv" \
      "$P/src/rtl/core/cache/icache_tag_ram.sv" \
      "$P/src/rtl/core/cache/icache_data_ram.sv" \
      "$P/src/rtl/core/cache/icache.sv" \
      "$P/src/rtl/core/cache/icache_resp_queue.sv" \
      "$P/src/rtl/core/frontend/ifu/next_line_prefetch_buffer.sv" \
      "$P/src/rtl/core/frontend/ifu/ifu_line_fetch.sv" \
      "$P/src/rtl/core/frontend/ifu/ifu.sv" \
      "$P/src/rtl/core/frontend/ifu/ifu_duplicate_guard.sv" \
      "$P/src/rtl/core/frontend/ftq/ftq.sv" \
      "$P/src/rtl/core/frontend/ibuffer/fetch_packet_buffer.sv" \
      "$P/src/rtl/core/frontend/ibuffer/ibuffer.sv" \
      "$P/src/rtl/core/frontend/top/fetch_top.sv" \
      "$P/src/rtl/sim/fetch_delivery_checker.sv" \
      "$P/src/rtl/sim/fetch_owner_checker.sv" \
      "$P/src/rtl/sim/fetch_frontend_profiler.sv" \
      "$P/src/rtl/sim/bpu_dynamic_profiler.sv" \
      "$P/src/rtl/sim/fetch_trace_probe.sv" \
      "$P/src/rtl/sim/fetch_frontend_assertions.sv" \
      "$P/src/rtl/core/decode/decode_slice.sv" \
      "$P/src/rtl/core/decode/decode.sv" \
      "$P/src/rtl/core/decode/fusion_detector.sv" \
      "$P/src/rtl/core/uop_cache/uop_cache_tag_ram.sv" \
      "$P/src/rtl/core/uop_cache/uop_cache_data_ram.sv" \
      "$P/src/rtl/core/uop_cache/uop_cache.sv" \
      "$P/src/rtl/core/rename/rat.sv" \
      "$P/src/rtl/core/rename/free_list.sv" \
      "$P/src/rtl/core/rename/checkpoint.sv" \
      "$P/src/rtl/sim/branch_recovery_contract_checker.sv" \
      "$P/src/rtl/core/rename/rename.sv" \
      "$P/src/rtl/core/dispatch/dispatch_queue.sv" \
      "$P/src/rtl/core/issue/wakeup_network.sv" \
      "$P/src/rtl/core/issue/issue_queue.sv" \
      "$P/src/rtl/core/execute/alu.sv" \
      "$P/src/rtl/core/execute/fmv_unit.sv" \
      "$P/src/rtl/core/execute/fpu_misc.sv" \
      "$P/src/rtl/core/execute/fpu_fpnew_wrapper.sv" \
      "$P/src/rtl/core/execute/fpu_top.sv" \
      "$P/src/rtl/core/execute/bru.sv" \
      "$P/src/rtl/core/execute/multiplier.sv" \
      "$P/src/rtl/core/execute/divider.sv" \
      "$P/src/rtl/core/regfile/int_prf.sv" \
      "$P/src/rtl/core/regfile/fp_prf.sv" \
      "$P/src/rtl/core/bypass_network.sv" \
      "$P/src/rtl/core/backend/rob.sv" \
      "$P/src/rtl/core/backend/commit.sv" \
      "$P/src/rtl/core/lsu/store_queue.sv" \
      "$P/src/rtl/core/lsu/load_queue.sv" \
      "$P/src/rtl/core/lsu/committed_store_buffer.sv" \
      "$P/src/rtl/core/lsu/lsu.sv" \
      "$P/src/rtl/core/cache/dcache_tag_ram.sv" \
      "$P/src/rtl/core/cache/dcache_data_ram.sv" \
      "$P/src/rtl/core/cache/dcache.sv" \
      "$P/src/rtl/core/cache/l2_cache.sv" \
      "$P/src/rtl/core/csr/csr_file.sv" \
      "$P/src/rtl/sim/sim_memory.sv" \
      "$P/src/rtl/core/rv64gc_core_top.sv" \
      "$P/src/tb/tb_top.sv" \
      "$P/src/tb/tb_xsim.sv"

# --- Elaborate --------------------------------------------------------------
# --relax            allow non-strict LRM constructs (matches Windows .bat)
# -s tb_xsim_sim     snapshot name (matches Windows .bat)
# tb_xsim            top-level module
# Snapshot lands at PARALLEL_PARENT/xsim.dir/tb_xsim_sim/
xelab --relax -s tb_xsim_sim tb_xsim

cd "$PROJ_ROOT"
echo
echo "xsim build OK.  Snapshot tb_xsim_sim under xsim_parallel/xsim.dir/"
echo "Run with:  ./run_xsim.sh <hex_path> [MAX_CYCLES] [extra_plusargs...]"

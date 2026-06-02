#!/usr/bin/env bash
# ============================================================================
# build_dsim.sh -- DSim Studio build for rv64gc-v2 (DSim 2026), Linux port
#
# DSim 2026 is the authoritative signoff + SVA/productivity simulator for
# rv64gc-v2.  build_verilator.sh provides an open-source alternative that
# builds the same top-level testbench.
#
# Prereq: DSim 2026 installed locally.
#   default DSIM_HOME=$HOME/AltairDSim/2026
#   default DSIM_LICENSE=$HOME/metrics-ca/dsim-license.json
# Override either env var before calling this script if installed elsewhere.
#
# Produces dsim_work/tb_image.so ready to run via run_dsim.sh.
# ============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

: "${DSIM_HOME:=$HOME/AltairDSim/2026}"

if [[ ! -f "$DSIM_HOME/shell_activate.bash" ]]; then
    echo "ERROR: DSim not found at $DSIM_HOME"
    echo "Set DSIM_HOME to the install directory (containing shell_activate.bash)."
    exit 1
fi

# shellcheck disable=SC1091
set +u
source "$DSIM_HOME/shell_activate.bash" >/dev/null
set -u

# --- License discovery ------------------------------------------------------
# Default Linux DSim Studio location after Altair One sign-in.
if [[ -z "${DSIM_LICENSE:-}" ]]; then
    if [[ -f "$HOME/metrics-ca/dsim-license.json" ]]; then
        export DSIM_LICENSE="$HOME/metrics-ca/dsim-license.json"
    elif [[ -f "$HOME/.metrics-ca/dsim-license.json" ]]; then
        export DSIM_LICENSE="$HOME/.metrics-ca/dsim-license.json"
    fi
fi
if [[ -z "${DSIM_LICENSE:-}" && -z "${ALTAIR_LICENSE_PATH:-}" ]]; then
    echo "ERROR: No DSim license configured."
    echo "Free Individual License setup steps:"
    echo "  1. Open VS Code, click the DSim Studio activity bar icon"
    echo "  2. Sign in via Altair One OAuth in the browser"
    echo "  3. The extension writes \$HOME/metrics-ca/dsim-license.json"
    echo "Alternative: download dsim-license.json from altairone.com/Marketplace"
    echo "  and set DSIM_LICENSE to its path."
    exit 1
fi

# DSim creates dsim_work/ as the default work dir; -genimage paths are
# resolved relative to that work dir, so use a bare image name.
rm -rf dsim_work

# --- Compile + elaborate into a reusable image ------------------------------
# -sv                  treat all files as SystemVerilog regardless of suffix
# +define+SIMULATION   enables defensive ifdef resets in int_prf / icache /
#                      dcache tag RAMs (avoids 4-state X on uninit arrays)
# +acc+rwb             generate support for wave dump + toggle coverage
#                      (required at compile for -waves to work at runtime)
# -top tb_xsim         top-level testbench module
# -genimage tb_image   write compiled code to dsim_work/tb_image
# -l                   log file (compile messages + errors)
# DSim 2026 can spin in bound SVA finalization on long CoreMark rows. Keep
# procedural checker modules active, but disable SVA unless explicitly enabled.
DSIM_SVA_ARGS=("-no-sva")
if [[ "${DSIM_ENABLE_SVA:-0}" == "1" ]]; then
    DSIM_SVA_ARGS=()
fi

dsim -sv +define+SIMULATION +acc+rwb "${DSIM_SVA_ARGS[@]}" \
     +incdir+external/cvfpu-src/src/common_cells/include \
     -top tb_xsim \
     -genimage tb_image \
     -l dsim_build.log \
     src/rtl/core/include/rv64gc_pkg.sv \
     src/rtl/core/include/isa_pkg.sv \
     src/rtl/core/include/fpu_pkg.sv \
     src/rtl/core/include/uarch_pkg.sv \
     src/rtl/sim/mem_if_pkg.sv \
     external/cvfpu-src/src/common_cells/src/cf_math_pkg.sv \
     external/cvfpu-src/src/common_cells/src/lzc.sv \
     external/cvfpu-src/src/common_cells/src/rr_arb_tree.sv \
     external/cvfpu-src/src/fpu_div_sqrt_mvp/hdl/defs_div_sqrt_mvp.sv \
     external/cvfpu-src/src/fpu_div_sqrt_mvp/hdl/iteration_div_sqrt_mvp.sv \
     external/cvfpu-src/src/fpu_div_sqrt_mvp/hdl/control_mvp.sv \
     external/cvfpu-src/src/fpu_div_sqrt_mvp/hdl/norm_div_sqrt_mvp.sv \
     external/cvfpu-src/src/fpu_div_sqrt_mvp/hdl/preprocess_mvp.sv \
     external/cvfpu-src/src/fpu_div_sqrt_mvp/hdl/nrbd_nrsc_mvp.sv \
     external/cvfpu-src/src/fpu_div_sqrt_mvp/hdl/div_sqrt_top_mvp.sv \
     external/cvfpu-src/src/fpu_div_sqrt_mvp/hdl/div_sqrt_mvp_wrapper.sv \
     external/cvfpu-src/src/fpnew_pkg.sv \
     external/cvfpu-src/src/fpnew_cast_multi.sv \
     external/cvfpu-src/src/fpnew_classifier.sv \
     external/cvfpu-src/src/fpnew_divsqrt_multi.sv \
     external/cvfpu-src/src/fpnew_fma.sv \
     external/cvfpu-src/src/fpnew_fma_multi.sv \
     external/cvfpu-src/src/fpnew_noncomp.sv \
     external/cvfpu-src/src/fpnew_opgroup_block.sv \
     external/cvfpu-src/src/fpnew_opgroup_fmt_slice.sv \
     external/cvfpu-src/src/fpnew_opgroup_multifmt_slice.sv \
     external/cvfpu-src/src/fpnew_rounding.sv \
     external/cvfpu-src/src/fpnew_top.sv \
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
     src/rtl/sim/mmu_mem_profiler.sv \
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
     src/rtl/core/execute/fmv_unit.sv \
     src/rtl/core/execute/fpu_misc.sv \
     src/rtl/core/execute/fpu_fpnew_wrapper.sv \
     src/rtl/core/execute/fpu_top.sv \
     src/rtl/core/execute/bru.sv \
     src/rtl/core/execute/multiplier.sv \
     src/rtl/core/execute/divider.sv \
     src/rtl/core/regfile/int_prf.sv \
     src/rtl/core/regfile/fp_prf.sv \
     src/rtl/core/bypass_network.sv \
     src/rtl/core/backend/rob.sv \
     src/rtl/core/backend/commit.sv \
     src/rtl/core/lsu/store_queue.sv \
     src/rtl/core/lsu/load_queue.sv \
     src/rtl/core/lsu/committed_store_buffer.sv \
     src/rtl/core/lsu/lsu.sv \
     src/rtl/core/mmu/itlb.sv \
     src/rtl/core/mmu/dtlb.sv \
     src/rtl/core/mmu/ptw.sv \
     src/rtl/core/cache/dcache_tag_ram.sv \
     src/rtl/core/cache/dcache_data_ram.sv \
     src/rtl/core/cache/dcache.sv \
     src/rtl/core/cache/l2_cache.sv \
     src/rtl/core/csr/csr_file.sv \
     src/rtl/sim/sim_memory.sv \
     src/rtl/core/rv64gc_core_top.sv \
     src/tb/tb_top.sv \
     src/tb/tb_xsim.sv

echo
echo "DSim build OK.  Image at dsim_work/tb_image.so"
echo "Run with:  scripts/run_dsim.sh <hex_path> [MAX_CYCLES] [extra_plusargs...]"

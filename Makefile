# =============================================================================
# RV64GC v2 Makefile
# =============================================================================
# Supports per-module testbenches:  make test_<module>
# Supports full-system build:       make build  (placeholder, Phase 11)
# =============================================================================

PROJ    := $(shell pwd)
RTL_DIR := $(PROJ)/src/rtl
TB_DIR  := $(PROJ)/src/tb
OBJ_DIR := $(PROJ)/obj_dir

# Toolchain
RISCV_PREFIX := riscv64-unknown-elf

# Package files (order matters: pkg files must come first)
PKG_FILES := \
    $(RTL_DIR)/core/include/rv64gc_pkg.sv \
    $(RTL_DIR)/core/include/isa_pkg.sv \
    $(RTL_DIR)/core/include/uarch_pkg.sv

# Verilator settings
# Use verilator_bin.exe directly on Windows to bypass the Perl wrapper.
# VERILATOR_ROOT is exported so the binary can locate its include files.
VERILATOR_BIN_DIR := $(dir $(shell which verilator_bin.exe 2>/dev/null))
VERILATOR       := $(if $(VERILATOR_BIN_DIR),$(VERILATOR_BIN_DIR)verilator_bin.exe,\
                   $(or $(shell which verilator 2>/dev/null),verilator))
VERILATOR_ROOT  ?= $(if $(VERILATOR_BIN_DIR),$(patsubst %/bin/,%,$(VERILATOR_BIN_DIR)),/usr/local)
export VERILATOR_ROOT
# --flatten avoids a Verilator 5 VlUnpacked/VL_IN8 mismatch on big-endian
# unpacked port arrays ([0:N-1]) that would otherwise cause C++ link errors.
# MAKE is set to 'mingw32-make' on Windows because the verilator-internal
# sub-make call uses $(MAKE), which must resolve on the system where build runs.
MAKE_CMD        := $(or $(shell which mingw32-make 2>/dev/null),\
                         $(shell which make 2>/dev/null),make)
VERILATOR_FLAGS := --cc --exe --trace --flatten \
    --converge-limit 500 \
    -Wno-WIDTHEXPAND \
    -Wno-WIDTHTRUNC \
    -Wno-UNUSEDSIGNAL \
    -Wno-UNOPTFLAT \
    -Wno-CASEINCOMPLETE \
    -Wno-UNSIGNED \
    -Wno-MULTIDRIVEN \
    -Wno-LATCH \
    -Wno-BLKANDNBLK \
    -Wno-COMBDLY \
    -Wno-BLKLOOPINIT

# =============================================================================
# Per-module testbench target
#
# Usage:  make test_<module>
#
# Expects:
#   $(TB_DIR)/<module>/<module>_tb.cpp   -- C++ testbench driver
#   $(RTL_DIR)/.../<module>.sv           -- RTL source(s)
#
# The testbench Makefile variable TB_MODULE is set by individual targets below.
# Add a new target here for each module as RTL is developed.
# =============================================================================

# Helper macro: build and run a module testbench
# $(1) = module name
# $(2) = RTL source files (space-separated, in addition to PKG_FILES)
define MODULE_TB_RULE
.PHONY: test_$(1)
test_$(1):
	@echo "=== Building testbench: $(1) ==="
	$(VERILATOR) $(VERILATOR_FLAGS) \
	    --Mdir $(OBJ_DIR)/$(1) \
	    --top-module $(1) \
	    $(PKG_FILES) \
	    $(2) \
	    $(TB_DIR)/$(1)/$(1)_tb.cpp
	@echo "=== Running testbench: $(1) ==="
	$(OBJ_DIR)/$(1)/V$(1)
endef

# ---------------------------------------------------------------------------
# Module testbench registrations
# Add one $(eval $(call MODULE_TB_RULE,...)) line per module below.
# The RTL source list grows as modules are implemented in later phases.
# ---------------------------------------------------------------------------

# ALU (Phase 3)
$(eval $(call MODULE_TB_RULE,alu,\
    $(RTL_DIR)/core/execute/alu.sv))

# Branch unit (Phase 3)
$(eval $(call MODULE_TB_RULE,branch_unit,\
    $(RTL_DIR)/core/execute/branch_unit.sv))

# Register file (Phase 4)
$(eval $(call MODULE_TB_RULE,regfile,\
    $(RTL_DIR)/core/regfile/regfile.sv))

# Fetch (Phase 5)
$(eval $(call MODULE_TB_RULE,fetch,\
    $(RTL_DIR)/core/frontend/top/fetch_top.sv))

# Decode (Phase 6)
$(eval $(call MODULE_TB_RULE,decode,\
    $(RTL_DIR)/core/decode/decode.sv))

# Rename (Phase 7)
$(eval $(call MODULE_TB_RULE,rename,\
    $(RTL_DIR)/core/rename/rename.sv))

# Dispatch / Issue (Phase 8)
$(eval $(call MODULE_TB_RULE,issue,\
    $(RTL_DIR)/core/issue/issue.sv))

# LSU (Phase 9)
$(eval $(call MODULE_TB_RULE,lsu,\
    $(RTL_DIR)/core/lsu/lsu.sv))

# =============================================================================
# Full-system build
# =============================================================================

# All RTL source files (order matters for packages)
RTL_FILES = \
    $(RTL_DIR)/sim/mem_if_pkg.sv \
    $(RTL_DIR)/core/frontend/instr/rvc_decompress.sv \
    $(RTL_DIR)/core/frontend/instr/rvc_expander.sv \
    $(RTL_DIR)/core/frontend/instr/predecode.sv \
    $(RTL_DIR)/core/frontend/instr/instr_boundary.sv \
    $(RTL_DIR)/core/frontend/instr/instr_compact.sv \
    $(RTL_DIR)/core/frontend/pred/pred_checker.sv \
    $(RTL_DIR)/core/bpu/btb.sv \
    $(RTL_DIR)/core/bpu/ras.sv \
    $(RTL_DIR)/core/bpu/tage_sc_l.sv \
    $(RTL_DIR)/core/bpu/bpu.sv \
	$(RTL_DIR)/core/cache/icache_tag_ram.sv \
	$(RTL_DIR)/core/cache/icache_data_ram.sv \
	$(RTL_DIR)/core/cache/icache.sv \
	$(RTL_DIR)/core/frontend/ifu/next_line_prefetch_buffer.sv \
	$(RTL_DIR)/core/frontend/ifu/ifu_line_fetch.sv \
	$(RTL_DIR)/core/frontend/ifu/ifu_duplicate_guard.sv \
	$(RTL_DIR)/core/frontend/ifu/ifu.sv \
	$(RTL_DIR)/core/frontend/ftq/ftq.sv \
	$(RTL_DIR)/core/frontend/ibuffer/fetch_packet_buffer.sv \
	$(RTL_DIR)/core/frontend/ibuffer/ibuffer.sv \
	$(RTL_DIR)/core/frontend/top/fetch_top.sv \
	$(RTL_DIR)/sim/fetch_delivery_checker.sv \
	$(RTL_DIR)/sim/fetch_owner_checker.sv \
	$(RTL_DIR)/sim/fetch_frontend_profiler.sv \
	$(RTL_DIR)/sim/fetch_trace_probe.sv \
	$(RTL_DIR)/sim/fetch_frontend_assertions.sv \
    $(RTL_DIR)/core/decode/decode_slice.sv \
    $(RTL_DIR)/core/decode/decode.sv \
    $(RTL_DIR)/core/decode/fusion_detector.sv \
    $(RTL_DIR)/core/uop_cache/uop_cache_tag_ram.sv \
    $(RTL_DIR)/core/uop_cache/uop_cache_data_ram.sv \
    $(RTL_DIR)/core/uop_cache/uop_cache.sv \
    $(RTL_DIR)/core/rename/rat.sv \
    $(RTL_DIR)/core/rename/free_list.sv \
    $(RTL_DIR)/core/rename/checkpoint.sv \
    $(RTL_DIR)/core/rename/rename.sv \
    $(RTL_DIR)/core/dispatch/dispatch_queue.sv \
    $(RTL_DIR)/core/issue/wakeup_network.sv \
    $(RTL_DIR)/core/issue/issue_queue.sv \
    $(RTL_DIR)/core/execute/alu.sv \
    $(RTL_DIR)/core/execute/bru.sv \
    $(RTL_DIR)/core/execute/multiplier.sv \
    $(RTL_DIR)/core/execute/divider.sv \
    $(RTL_DIR)/core/regfile/int_prf.sv \
    $(RTL_DIR)/core/bypass_network.sv \
    $(RTL_DIR)/core/backend/rob.sv \
    $(RTL_DIR)/core/backend/commit.sv \
    $(RTL_DIR)/core/lsu/store_queue.sv \
    $(RTL_DIR)/core/lsu/load_queue.sv \
    $(RTL_DIR)/core/lsu/committed_store_buffer.sv \
    $(RTL_DIR)/core/lsu/lsu.sv \
    $(RTL_DIR)/core/cache/dcache_tag_ram.sv \
    $(RTL_DIR)/core/cache/dcache_data_ram.sv \
    $(RTL_DIR)/core/cache/dcache.sv \
    $(RTL_DIR)/core/cache/l2_cache.sv \
    $(RTL_DIR)/core/csr/csr_file.sv \
    $(RTL_DIR)/sim/sim_memory.sv \
    $(RTL_DIR)/core/rv64gc_core_top.sv

TB_TOP  = $(TB_DIR)/tb_top.sv
TB_CPP  = $(TB_DIR)/tb_verilator.cpp

SIM_BIN = $(OBJ_DIR)/Vtb_top

MEMFILE ?= test.hex

.PHONY: build run

build:
	$(VERILATOR) $(VERILATOR_FLAGS) \
	    --Mdir $(OBJ_DIR) \
	    --top-module tb_top \
	    $(PKG_FILES) $(RTL_FILES) $(TB_TOP) $(TB_CPP) || true
	$(MAKE_CMD) -C $(OBJ_DIR) -f Vtb_top.mk -j 4

run: build
	$(SIM_BIN) +MEMFILE=$(MEMFILE)

# =============================================================================
# Vivado xsim flow (second simulator for cross-validation)
#
# Usage:
#   make xsim_build                             # compile + elaborate
#   make xsim_run MEMFILE=tests/hex/coremark.hex MAX_CYCLES=500000
#   make xsim_regression                        # run full regression suite
# =============================================================================
XSIM_ROOT    := D:/Xilinx/Vivado/2024.1
WIN_CURDIR   = $(shell wslpath -m "$(CURDIR)" 2>/dev/null || printf '%s' "$(CURDIR)")
WIN_MEMFILE  = $(shell wslpath -m "$(abspath $(MEMFILE))" 2>/dev/null || printf '%s' "$(MEMFILE)")
WIN_XSIM_ALL_SV = $(foreach f,$(XSIM_ALL_SV),$(shell wslpath -m "$(abspath $(f))" 2>/dev/null || printf '%s' "$(f)"))
ifeq ($(shell uname -r 2>/dev/null | grep -qi microsoft && echo 1 || echo 0),1)
XSIM_WIN_ROOT := $(subst /,\,$(XSIM_ROOT))
XVLOG_BAT    := "$(XSIM_WIN_ROOT)\bin\xvlog.bat"
XELAB_BAT    := "$(XSIM_WIN_ROOT)\bin\xelab.bat"
XSIM_BAT     := "$(XSIM_WIN_ROOT)\bin\xsim.bat"
XVLOG        := cmd.exe /C $(XVLOG_BAT)
XELAB        := cmd.exe /C $(XELAB_BAT)
XSIM         := cmd.exe /C $(XSIM_BAT)
XSIM_RUNNER  := cmd.exe /C run_xsim_tmp.bat
else
XVLOG_BAT    := $(XSIM_ROOT)/bin/xvlog.bat
XELAB_BAT    := $(XSIM_ROOT)/bin/xelab.bat
XSIM_BAT     := $(XSIM_ROOT)/bin/xsim.bat
XVLOG        := $(XSIM_ROOT)/bin/xvlog.bat
XELAB        := $(XSIM_ROOT)/bin/xelab.bat
XSIM         := $(XSIM_ROOT)/bin/xsim.bat
XSIM_RUNNER  := ./run_xsim_tmp.bat
endif
XSIM_TB      := tb_xsim
XSIM_SNAP    := tb_xsim_sim
XSIM_TB_FILE := $(TB_DIR)/tb_xsim.sv
XSIM_ALL_SV  := $(PKG_FILES) $(RTL_FILES) $(TB_TOP) $(XSIM_TB_FILE)

.PHONY: xsim_build xsim_run xsim_regression xsim_clean

xsim_build:
	rm -rf xsim.dir
	$(XVLOG) --sv --relax -d SIMULATION $(WIN_XSIM_ALL_SV)
	$(XELAB) --relax -s $(XSIM_SNAP) $(XSIM_TB)

MAX_CYCLES ?= 500000
EXTRA_PLUSARGS ?=

xsim_run: xsim_build
	@printf '%s\n' '@echo off' > run_xsim_tmp.bat
	@printf '%s\n' 'cd /d $(WIN_CURDIR)' >> run_xsim_tmp.bat
	@printf '%s\n' 'call $(XSIM_BAT) $(XSIM_SNAP) --runall --testplusarg "MEMFILE=$(WIN_MEMFILE)" --testplusarg "MAX_CYCLES=$(MAX_CYCLES)" --testplusarg "NOVCD" $(EXTRA_PLUSARGS)' >> run_xsim_tmp.bat
	$(XSIM_RUNNER)
	@rm -f run_xsim_tmp.bat

xsim_regression:
	@for t in tests/hex/rv64ui_*.hex tests/hex/test_*.hex; do \
		name=$$(basename $$t .hex); \
		win_t=$$(wslpath -m "$$t" 2>/dev/null || printf '%s' "$$t"); \
		echo @echo off > run_xsim_tmp.bat; \
		echo cd /d $(WIN_CURDIR) >> run_xsim_tmp.bat; \
		echo call $(XSIM_BAT) $(XSIM_SNAP) --runall --testplusarg "MEMFILE=$$win_t" --testplusarg "MAX_CYCLES=50000" --testplusarg "NOVCD" >> run_xsim_tmp.bat; \
		result=$$(./run_xsim_tmp.bat 2>&1 | grep -E "PASS|FAIL|TIMEOUT" | tail -1); \
		echo "$$name: $$result"; \
	done
	@rm -f run_xsim_tmp.bat

xsim_clean:
	rm -rf xsim.dir xvlog.log xelab.log xsim.log xvlog.pb xelab.pb xsim.jou
	rm -f run_xsim_tmp.bat xsim_run.tcl

# =============================================================================
# Simulator platform flow
#
# Usage:
#   make sim_platform_list
#   make sim_platform_prepare BENCH=isa_rv64ui_add
#   make sim_platform_dry BENCH=isa_rv64ui_add
# =============================================================================
SIM_PLATFORM_MANIFEST ?= tests/sim_platform/stage1_broad.json
SIM_PLATFORM_RUN_DIR  ?= benchmark_results/sim_platform_make
BENCH ?=

.PHONY: sim_platform_list sim_platform_prepare sim_platform_dry

sim_platform_list:
	python3 tools/sim_platform.py --manifest $(SIM_PLATFORM_MANIFEST) --list

sim_platform_prepare:
	python3 tools/sim_platform.py --manifest $(SIM_PLATFORM_MANIFEST) \
	    --prepare-only --run-dir $(SIM_PLATFORM_RUN_DIR) $(if $(BENCH),--bench $(BENCH),)

sim_platform_dry:
	python3 tools/sim_platform.py --manifest $(SIM_PLATFORM_MANIFEST) \
	    --dry-run --run-dir $(SIM_PLATFORM_RUN_DIR) $(if $(BENCH),--bench $(BENCH),)

# =============================================================================
# Clean
# =============================================================================
.PHONY: clean
clean:
	rm -rf $(OBJ_DIR)
	rm -f *.vcd

# =============================================================================
# Help
# =============================================================================
.PHONY: help
help:
	@echo "RV64GC v2 build system"
	@echo ""
	@echo "Targets:"
	@echo "  test_<module>  Build and run a per-module Verilator testbench"
	@echo "                 e.g.: make test_alu, make test_fetch, make test_decode"
	@echo "  build          Full-system build (Phase 11 placeholder)"
	@echo "  sim_platform_list      List broad simulator-platform rows"
	@echo "  sim_platform_prepare   Prepare platform manifest for selected BENCH=<name>"
	@echo "  sim_platform_dry       Dry-run selected platform row through run_benchmarks"
	@echo "  clean          Remove obj_dir/ and *.vcd"
	@echo "  help           Show this message"
	@echo ""
	@echo "Toolchain prefix: $(RISCV_PREFIX)"
	@echo "Verilator:        $(VERILATOR)"
	@echo "RTL_DIR:          $(RTL_DIR)"
	@echo "TB_DIR:           $(TB_DIR)"
	@echo "OBJ_DIR:          $(OBJ_DIR)"

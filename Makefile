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
VERILATOR       := verilator
VERILATOR_FLAGS := --cc --exe --trace --build -j 4 \
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
    -Wno-COMBDLY

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
    $(RTL_DIR)/core/fetch/fetch.sv))

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
# Full-system build (Phase 11 placeholder)
# =============================================================================
.PHONY: build
build:
	@echo "Full-system build not yet implemented (Phase 11 placeholder)"

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
	@echo "  clean          Remove obj_dir/ and *.vcd"
	@echo "  help           Show this message"
	@echo ""
	@echo "Toolchain prefix: $(RISCV_PREFIX)"
	@echo "Verilator:        $(VERILATOR)"
	@echo "RTL_DIR:          $(RTL_DIR)"
	@echo "TB_DIR:           $(TB_DIR)"
	@echo "OBJ_DIR:          $(OBJ_DIR)"

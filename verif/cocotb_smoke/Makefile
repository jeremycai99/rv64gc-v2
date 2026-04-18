# cocotb Makefile — THIS PROJECT REJECTS iverilog and Verilator.
#
# Both simulators have semantic drift from IEEE 1800 strict / synthesis
# semantics and have been shown (in doc/xsim_lessons_learned.md) to
# silently hide tapeout-class bugs on this design.  DO NOT run cocotb
# tests against them as evidence of anything.
#
# Trusted cocotb backend for this project: DSim 2026.  The Windows wheel
# of cocotb 2.0.1 does NOT ship libcocotbvpi_dsim.dll; a source-build
# of cocotb is needed to enable DSim — tracked in the session handoff
# under "verification flow caveat".  Once available:
#
#     source ../../venv_cocotb/bin/activate
#     export DSIM_HOME="/c/PROGRA~1/Altair/DSim/2026"
#     export PATH="$DSIM_HOME/bin:$DSIM_HOME/mingw/bin:$DSIM_HOME/dsim_deps/bin:$DSIM_HOME/lib:$PATH"
#     export DSIM_LICENSE="/c/Users/jeremy/AppData/Local/metrics-ca/dsim-license.json"
#     make SIM=dsim
#
# Until the DSim VPI lib is built, `make` will ERROR OUT rather than
# silently fall back to iverilog.
SIM ?= dsim

ifeq ($(SIM),icarus)
$(error cocotb+iverilog is BANNED on this project — see doc/xsim_lessons_learned.md. Use SIM=dsim (requires source-built cocotb VPI lib).)
endif
ifeq ($(SIM),verilator)
$(error cocotb+Verilator is BANNED on this project — see doc/xsim_lessons_learned.md. Use SIM=dsim.)
endif

TOPLEVEL_LANG ?= verilog
VERILOG_SOURCES := $(PWD)/counter.sv
TOPLEVEL        := counter
MODULE          := test_counter

COMPILE_ARGS += -sv

include $(shell cocotb-config --makefiles)/Makefile.sim

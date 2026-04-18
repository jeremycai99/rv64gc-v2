# Minimal cocotb Makefile — smoke-tests the cocotb+iverilog flow.
SIM ?= icarus
TOPLEVEL_LANG ?= verilog
VERILOG_SOURCES := $(PWD)/counter.sv
TOPLEVEL        := counter
MODULE          := test_counter

# Iverilog-specific: enable SystemVerilog and strict semantics.
COMPILE_ARGS += -g2012

include $(shell cocotb-config --makefiles)/Makefile.sim

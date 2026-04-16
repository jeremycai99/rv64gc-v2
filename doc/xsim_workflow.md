# Vivado xsim Workflow

## Overview

Vivado xsim (Xilinx 2024.1) is the **primary simulator** for development and debug. It is event-driven, standards-compliant SystemVerilog, and does not have the combinational eval-ordering artifacts that mask bugs in Verilator.

Verilator remains available for fast batch regression and IPC benchmarking, but any RTL bug investigation, flush-race analysis, or pipeline timing debug should use xsim.

## Prerequisites

- Vivado 2024.1 installed at `D:/Xilinx/Vivado/2024.1/`
- RISC-V toolchain (for building test hex files)
- Git Bash / MINGW64

## Build Flow

Three-step flow (compile → elaborate → simulate):

### 1. Compile (`xvlog`)

```bash
make xsim_build
```

Underlying command:

```bash
D:/Xilinx/Vivado/2024.1/bin/xvlog.bat --sv --relax \
  src/rtl/core/include/rv64gc_pkg.sv \
  src/rtl/core/include/isa_pkg.sv \
  src/rtl/core/include/uarch_pkg.sv \
  ... all .sv files ...
  src/tb/tb_top.sv \
  src/tb/tb_iverilog.sv
```

Key flags:
- `--sv` — SystemVerilog mode
- `--relax` — Relax strict language checking (allows implicit net declarations from port connections, which we use extensively)

Creates `xsim.dir/work/` with compiled symbols.

### 2. Elaborate (`xelab`)

```bash
D:/Xilinx/Vivado/2024.1/bin/xelab.bat --relax -s tb_iverilog_sim tb_iverilog
```

- `-s tb_iverilog_sim` — name the elaborated snapshot
- `tb_iverilog` — top-level module

Creates `xsim.dir/tb_iverilog_sim/xsimk.exe` (the simulation kernel).

### 3. Simulate (`xsim`)

```bash
make xsim_run MEMFILE=tests/hex/coremark.hex MAX_CYCLES=500000
```

Underlying command (via `.bat` wrapper due to Windows shell quoting):

```bat
call D:\Xilinx\Vivado\2024.1\bin\xsim.bat tb_iverilog_sim --runall \
  --testplusarg "MEMFILE=tests/hex/coremark.hex" \
  --testplusarg "MAX_CYCLES=500000" \
  --testplusarg "NOVCD"
```

**Important**: xsim.bat must be called from a `.bat` file (not directly from bash) because MINGW64 shell doesn't escape `--` arguments correctly to Windows cmd.exe.

## Regression Testing

```bash
make xsim_regression
```

Runs all `tests/hex/rv64ui_*.hex` and `tests/hex/test_*.hex` on xsim and prints PASS/FAIL/TIMEOUT per test.

## Comparing xsim vs Verilator

| Test | Verilator | xsim | Notes |
|------|-----------|------|-------|
| rv64ui_add | PASS @ 127 cyc | PASS @ 167 cyc | Reset length differs |
| rv64ui_branch | PASS | PASS | — |
| test_call | PASS @ 80 cyc | **TIMEOUT** | xsim exposes flush race |
| CoreMark | 3.29 IPC | minstret stuck at 40 | xsim exposes pipeline deadlock |

**xsim is stricter**: it exposes bugs that Verilator masks via eval scheduling. When xsim and Verilator disagree, xsim is the ground truth.

## Debug Flow

### VCD waveform

Enable VCD in `tb_iverilog.sv` (add `$dumpfile` / `$dumpvars`), then view with GTKWave:

```bash
gtkwave dump.vcd &
```

### Signal tracing

xsim supports full hierarchical signal access in TCL. Example:

```tcl
# Save as trace.tcl, invoke with --tclbatch trace.tcl
add_wave /tb_iverilog/u_tb/u_core/u_rob/head_r
add_wave /tb_iverilog/u_tb/u_core/u_rob/ready_r
run -all
```

### Interactive GUI

```bash
call D:\Xilinx\Vivado\2024.1\bin\xsim.bat tb_iverilog_sim --gui
```

## Why xsim Over Verilator for Debug

1. **Deterministic event ordering**: xsim follows IEEE 1800 simulation semantics. Verilator uses a custom scheduler that evaluates combinational blocks in dependency order, which can change when RTL is restructured.

2. **No eval artifacts**: Adding a new `always_ff` block in Verilator can shift evaluation order and break timing-sensitive signals. xsim's scheduling is based on signal dependencies and timestep advancement, not source order.

3. **Catches more bugs**: The `test_call` timeout in xsim (PASS in Verilator) is a real RTL flush race. Verilator's eval ordering accidentally works around it.

4. **Better error messages**: xsim prints proper SystemVerilog compliance errors (e.g., `'variable is used before declaration'`), while Verilator is more permissive.

## Why Keep Verilator

1. **Speed**: Verilator is 10-100× faster for long runs (benchmarking, IPC measurement).
2. **VCD**: Verilator's VCD output is cleaner and smaller for equivalent runs.
3. **Regression CI**: 23 tests in ~30 seconds on Verilator vs ~5 minutes on xsim.
4. **C++ testbench integration**: Verilator's `tb_verilator.cpp` allows complex DPI-like test infrastructure.

## Refactor Priorities

Current RTL contains several Verilator-specific workarounds that should be removed in favor of xsim-compliant code:

### 1. Loop buffer trigger (`backward_branch_taken`)
Currently registered to avoid changing Verilator eval scheduling. Should be combinational — xsim handles this naturally.

### 2. Forwarding hold register
Added to break a structural CDB→bypass→IQ→issue→SQ_fwd→CDB loop that Verilator marks as UNOPTFLAT. xsim handles oscillating combinational loops during settle via delta cycles. The hold register adds 1 cycle to same-cycle forwarded loads.

### 3. Registered fetch_insn fields
Moved to `always_ff` to avoid Verilator's "reading `fused_insn[1+]` in combinational changes eval scheduling" artifact. Should be combinational.

### 4. `converge-limit 500`
Verilator needs this to handle combinational loops during settle. xsim doesn't need any equivalent.

### 5. `no-UNOPTFLAT` suppressions
Multiple Verilator lint suppressions for legitimate combinational paths. xsim would accept these without complaint.

## Migration Plan

**Phase 1 — xsim as debug simulator (done)**
- Add xsim build targets to Makefile
- Document workflow
- Keep Verilator for CI/benchmarking

**Phase 2 — Fix the exposed bugs**
- Use xsim to debug test_call timeout
- Use xsim to debug CoreMark deadlock at minstret=40
- Fix pipeline flush race (dispatch/rename/ROB ordering)
- Both simulators should pass all tests

**Phase 3 — Remove Verilator workarounds**
- Revert loop buffer trigger to combinational
- Remove forwarding hold register (verify no performance regression)
- Revert fetch_insn registration
- Reduce `converge-limit` to default 100

**Phase 4 — Establish xsim as primary**
- Run xsim regression on every commit
- Verilator used only for long IPC runs and batch regression speed
- Any Verilator-only pass (xsim fails) is treated as a bug

## Known xsim Quirks

1. **`$readmemh` path**: xsim resolves relative paths from the run directory (not the .sv file location). Always invoke xsim from the project root.

2. **Implicit net declarations**: Without `--relax`, xsim errors on signals used in port connections before their explicit `logic` declaration. This is actually stricter SystemVerilog compliance.

3. **Shell quoting**: The `--testplusarg` flag's value must be quoted when the value contains `=`. On Windows, call xsim from a `.bat` wrapper rather than directly from bash.

4. **Reset timing**: xsim's default reset in `tb_iverilog.sv` is 40 cycles. Verilator uses a shorter reset. Benchmarks see ~30 extra cycles of startup — not significant for long runs.

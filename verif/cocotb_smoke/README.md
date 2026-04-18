# cocotb smoke-test scaffolding

Minimal framework bring-up for cocotb 2.0.1 + pyuvm 4.0.1.  Intended as
a starting template for block-level unit tests (IQ, LSU, rename, etc.)
once the cocotb+DSim backend is built from source.

## Files

- `counter.sv` — trivial 4-bit counter DUT (not project RTL).
- `test_counter.py` — three plain cocotb tests (reset, enable gate,
  wraparound).
- `test_counter_pyuvm.py` — minimal pyuvm uvm_test + uvm_env.
- `Makefile` — refuses iverilog and Verilator; defaults to DSim.

## Status

**Blocked on cocotb VPI DLL for DSim.**  cocotb 2.0.1 ships
`Makefile.dsim` but not `libcocotbvpi_dsim.dll` in the Windows wheel.
Source-build needed; tracked in `doc/session_handoff_2026-04-17.md`.

Do NOT run with `SIM=icarus` or `SIM=verilator` — both are banned on
this project (see `doc/xsim_lessons_learned.md`, dual-simulator policy
addendum).  The Makefile will `$(error)` out if you try.

## When the DSim VPI lib is available

```bash
cd /d/agent-workspace/rv64gc-v2
source venv_cocotb/bin/activate
export DSIM_HOME="/c/PROGRA~1/Altair/DSim/2026"
export PATH="$DSIM_HOME/bin:$DSIM_HOME/mingw/bin:$DSIM_HOME/dsim_deps/bin:$DSIM_HOME/lib:$PATH"
export DSIM_LICENSE="/c/Users/jeremy/AppData/Local/metrics-ca/dsim-license.json"
cd verif/cocotb_smoke
make                          # SIM=dsim is the default
```

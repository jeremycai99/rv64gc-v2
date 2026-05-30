# Stage 4 UVM Verification Placeholder

Date: May 12, 2026

Status: placeholder only.

Stage 4 is reassigned from architectural performance chasing to a UVM-based
verification phase. Performance work remains paused unless it is needed to
protect an already committed regression gate.

## Goal

Build a reusable UVM verification environment for rv64gc-v2 so future RTL work
is checked by structured stimulus, monitors, scoreboards, assertions, and
coverage instead of ad hoc benchmark-only debug.

The intent is to raise confidence in the ASIC-style core and platform boundary
before returning to aggressive performance work.

## Tooling Baseline

The local DSim 2026 install supports UVM through the `-uvm` option.

Available built-in UVM packages:

| UVM package | Local path |
|---|---|
| `1.1b` | `$HOME/AltairDSim/2026/uvm/1.1b` |
| `1.1d` | `$HOME/AltairDSim/2026/uvm/1.1d` |
| `1.2` | `$HOME/AltairDSim/2026/uvm/1.2` |
| `2020.3.1` | `$HOME/AltairDSim/2026/uvm/2020.3.1` |

Recommended default: use explicit `-uvm 1.2` for initial bring-up unless a
specific IEEE UVM 2020 feature is required. Avoid `-uvm default` in regression
scripts because it depends on `UVM_HOME` being set in the caller environment.

## Scope

Initial Stage 4 scope should focus on reusable correctness infrastructure:

- UVM smoke harness that can compile and run under DSim.
- Core memory bus agent and monitor.
- MMIO platform agent for UART, CLINT timer, and future interrupt sources.
- Scoreboard for instruction retirement, memory ordering, MMIO side effects,
  and trap or interrupt architectural state.
- Coverage for instruction classes, privilege transitions, exceptions,
  cache or LSU corner cases, frontend redirect cases, and MMU/PTW activity.
- Integration with the existing compliance, VM smoke, DS/CM guard, and Linux
  boot runners.

## Ground Rules

- Do not add UVM, DPI, simulator-only endpoint logic, or benchmark pass/fail
  behavior into synthesizable core RTL.
- Keep UVM code under verification or simulation directories, not under the
  core implementation tree.
- Keep the existing ASIC-style core boundary intact.
- Any RTL fix discovered by UVM must still pass full RV64GC compliance and the
  committed DS/CM performance guard before promotion.
- UVM should broaden correctness evidence. It must not become another path for
  benchmark-specific tuning.

## Entry Criteria

Before Stage 4 active implementation starts:

- Current RTL must have a clean committed baseline.
- Full RV64GC instruction compliance should remain passing.
- Stage 3 DS/CM hard guard should remain passing.
- Existing Linux boot evidence should be preserved as the initial platform
  stress workload, but Linux completion is not required to start UVM harness
  construction.

## Placeholder Deliverables

Concrete Stage 4 planning should later define:

- `verif/uvm/` directory layout.
- DSim compile and run scripts using explicit UVM version selection.
- A first minimal UVM test that drives reset, observes retirement, and checks
  no unexpected traps for a small bare-metal image.
- A reusable register or memory transaction model for platform MMIO.
- Coverage database and summary reporting format.
- Regression handoff rules tying UVM failures to compliance, VM, DS/CM, and
  Linux boot evidence.

No UVM implementation plan, test list, or RTL change is defined by this
placeholder. Those should be created from a dedicated Stage 4 planning pass.

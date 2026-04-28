# rv64gc-perf-model Implementation Plan — 2026-04-25

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an industry-style performance modeling loop for rv64gc-v2,
calibrated against current RTL, used to drive the 4-wide pivot decision and
future uarch optimizations *before* RTL refactor.

**Architecture:** Two-track model stack.  The Python perf model is
trace-driven and cycle-approximate; it ranks design choices and explains
bottlenecks.  A separate RTL clock checker consumes richer per-cycle traces
and protects the 6-wide to 4-wide refactor from unintended timing drift.
dsim/xsim RTL remains the final performance and correctness authority.

**Tech Stack:** Python 3.10+, Spike for trace generation, pytest for unit tests, pandas/matplotlib for sweep analysis.

**Performance targets (industry units):**
| Tier | CM/MHz | DMIPS/MHz | Source |
|---|---:|---:|---|
| Baseline (must-match) | ≥ 6.2 | ≥ 4.00 | MegaBoom (4-wide) |
| **Sign-off (must beat)** | **≥ 8.24** | **≥ 4.72** | ARM Cortex-A72 (3-wide OoO) |

**Methodology rationale:** generic OoO models cannot represent v2's specific
structures (3-IQ dual-select, 12R6W PRF, F0/F1/F2 NLPB+FTQ fetch, fusion
detector, uop cache, LSU port-1 hold, CDB->bypass).  Industry teams use a
stack: fast custom perf models for ranking, detailed traces/counters for
calibration, and RTL/emulation for sign-off.  We follow that pattern.
`rv64gc-gem5` and `rv64gc-v1` are historical references unless explicitly
reactivated.

## 2026-04-27 Methodology Upgrade

The original plan treated the perf model as the main pre-refactor tool.  The
updated plan makes the contracts explicit:

- `rv64gc-perf-model`: approximate exploration, bottleneck attribution, and
  parameter sweeps.
- `rtl_clockcheck.py`: clock-by-clock microbench comparison of RTL traces.
- dsim/xsim: final sign-off for functional PASS and measured CM/MHz/DMIPS/MHz.

New required docs in `rv64gc-perf-model/doc/`:

- `methodology.md` - model stack, calibration contract, counter taxonomy, and
  design gates.
- `trace_schema.md` - `cpc.v2`, `dep.v1`, and `pipe.v1` trace contracts.

### Phase 2.5 status (2026-04-27, end-of-session)

| Sub-task | Status | Artifact |
|---|---|---|
| A1 — RTL `[DEP schema=dep.v1]` emit | ✅ done | rv64gc-v2 commit `40bdc6a` |
| A2 — RTL `[PIPE schema=pipe.v1]` emit | ✅ done | rv64gc-v2 commit `ffffd83` |
| A3 — perfmodel dep.v1 consumer | ✅ done | perfmodel commit `6ec1353` |
| A4 — perfmodel pipe.v1 consumer + dashboard | ✅ done | perfmodel commit `67cdd94` |
| A5 — Stats counter-taxonomy bucketing | ✅ done | perfmodel commit `b584e06` |
| A6 — `tools/rtl_clockcheck.py` | ✅ done | perfmodel commit `601521f` |
| A7 — counter calibration on dhry | ✅ done | `doc/calibration.md` "Phase 2.5" section |
| A8 — plan + docs update | ✅ done | this section |

**Test count:** 157/157 passing in perfmodel.
**Commits in perfmodel since Phase 2.5 start:** 6 (A3..A8 inline-doc).

### A7 verdict — T3 contract NOT YET MET, Phase 3 RTL stacking BLOCKED

Counter-by-counter calibration on dhrystone reveals that the +0.6%
cycle match on `v2_full_4wide` is a coincidence — bottleneck attribution
diverges sharply (frontend −51%, bad-spec −90%, IQ-pressure mis-attributed
+1679 cyc).  Diagnosis + actions are in `rv64gc-perf-model/doc/calibration.md`
"Phase 2.5" section.

**Implication for the plan:** the originally-intended Phase 3/4 RTL stacking
must now follow the 5-gate rule below.  Each opt must:
1. Have a perf-model cost model (not just a flag), and
2. Land its corresponding stall counter into Stats, and
3. Move the bucket attribution toward RTL on dhry/cm.

Items O1 (12R6W PRF) + O2 (3-IQ × 2-sel) + O3 (spec wakeup) are the
first stack candidates AND the bottleneck-side fixes implied by A7's
diagnosis (IQ pressure + ready-tracking).  They should be implemented
as cost models, not shells.

### 5-gate rule for any RTL optimization (per methodology.md)

Before dispatching any RTL refactor or large opt:

1. **Perf-model gain is predicted** in the target metric (CM/MHz, DMIPS/MHz).
2. **Gain is tied to a specific bottleneck counter** in Stats.report_taxonomy().
3. **Sensitivity check** shows the same decision under nearby parameters.
4. **Microbenchmark exists** that should expose the mechanism.
5. **RTL regression gate + clock-check scope** are known before editing.

Phase 3 (BPU + memory hierarchy in this plan's numbering = "Tasks 14-20")
is structurally complete in code (perfmodel commits `6797b64`, `13de9c0`,
`8689ab3`, `b384377`, `81ea55c`, `8c7f071`, `71f79df`, `5953c3d`, `0c5158a`,
`784edfa`, `8bf67dd`, `1e03024`).  But its T3 calibration is failing the
counter-class test; the next batch of stacking work (Phase 4 in this plan's
numbering = "Tasks 21-33") must close that gap first.

---

## File Structure (target end-state)

```
rv64gc-perf-model/
├── README.md
├── pyproject.toml
├── doc/
│   ├── design.md             — model architecture spec
│   ├── methodology.md        — calibration + sweep methodology
│   ├── trace_schema.md       — RTL trace contracts for model/checker
│   ├── audit.md              — v2 RTL optimization inventory + measured impact
│   ├── calibration.md        — per-tier RTL-vs-model deltas (filled as we go)
│   └── results/              — sweep CSVs + Pareto plots
├── src/perfmodel/
│   ├── __init__.py
│   ├── config.py             — UarchConfig dataclass (all params, swappable)
│   ├── pipeline.py           — main cycle scheduler (event-driven loop)
│   ├── trace.py              — Spike trace consumer
│   ├── stats.py              — IPC/cycles/hit-rate/stall counters
│   ├── fetch.py              — F0/F1/F2 stages, NLPB, FTQ
│   ├── bpu.py                — BTB / TAGE-SC-L / RAS
│   ├── decode.py             — RVC expand + decoded_insn_t
│   ├── fusion.py             — fusion detector (Tier 3 audit feature)
│   ├── rename.py             — RAT, free list, PRF, checkpoints
│   ├── dispatch.py           — dispatch arbitration
│   ├── issue.py              — IQ + select + speculative wakeup
│   ├── execute.py            — ALU/BRU/MUL/DIV/FPU + bypass
│   ├── lsu.py                — LQ/SQ/LSU + dcache pipeline
│   ├── commit.py             — ROB + commit + checkpoint restore
│   ├── caches.py             — L1I/L1D/L2 + MSHR
│   ├── loop_buffer.py        — LB module (Tier 3)
│   └── uop_cache.py          — UOC module (Tier 3)
├── tests/
│   ├── test_*.py             — per-module unit tests
│   ├── golden/               — RTL-measured cycle counts for regression
│   └── fixtures/             — small Spike traces for tests
├── scripts/
│   ├── gen_trace.sh          — Spike trace capture helper
│   ├── run_workload.py       — single-config sim entry
│   ├── sweep.py              — parameter sweep harness (parallel)
│   ├── calibrate_vs_rtl.py   — compare model vs RTL cycle counts
│   ├── calibrate_counters.py — compare model vs RTL counter dashboards
│   ├── rtl_clockcheck.py     — compare per-cycle RTL traces for refactors
│   └── plot_pareto.py        — visualize CM/MHz vs DMIPS/MHz Pareto
└── traces/
    ├── dhrystone_iter100.trace
    ├── coremark_iter1.trace
    ├── coremark_iter10.trace
    └── microkernel_*.trace
```

**Decomposition rationale:**
- One file per pipeline stage — matches RTL structure, focused responsibility
- `caches.py` groups L1/L2/MSHR (they coordinate tightly, naturally couple)
- `loop_buffer.py` and `uop_cache.py` are separate because they're optional optimizations that can be enabled/disabled per config
- `config.py` dataclass-driven so all params are introspectable and CSV-serializable for sweeps

---

## Phases

| Phase | Goal | Tasks | Effort |
|---|---|---|---|
| 0 — Setup + Audit | Workspace + v2 RTL optimization inventory | 1-3 | done |
| 1 — Vanilla 4-wide baseline | Plain 4-wide OoO model, no v2 opts; calibrate floor | 4-12 | in progress |
| 2 — Trace + Checker Upgrade | `dep.v1`, `pipe.v1`, counter calibration, clockcheck | 13A-13D | 1 week |
| 3 — BPU + memory hierarchy | Real BPU + cache miss model + MSHRs | 14-20 | 1-2 weeks |
| 4 — V2 optimization stacking | Add each v2 RTL opt incrementally, measure each | 21-33 | 2-3 weeks |
| 5 — Calibration + 4-wide sweep | Match RTL within 10%; sweep params for 4-wide | 34-39 | 1 week |
| 6 — New optimization exploration | Decoupled F2, multi-port BPU, etc. — measure on model | 40-44 | 1-2 weeks |
| 7 — RTL Refactor Gates + Docs | Clockcheck, regression, update uarch docs | 45-48 | ongoing |

Plan supports staged checkpoint reviews at end of each phase.  The 4-wide RTL
refactor should not start until Phase 2 trace/checker gates exist and Phase 5
has selected a candidate.

---

# Phase 2 — Trace + Checker Upgrade

This phase is inserted before heavy model sweeps and before the 4-wide RTL
refactor.  It makes the loop industry-oriented: model for design ranking,
clockcheck for refactor safety, RTL for sign-off.

## Task 13A: Document model contracts and trace schemas

**Files:**
- `rv64gc-perf-model/doc/methodology.md`
- `rv64gc-perf-model/doc/trace_schema.md`

- [ ] Define the model stack contract: perf model, RTL clock checker, dsim/xsim.
- [ ] Define calibration by counters, not only cycles.
- [ ] Define `cpc.v2`, `dep.v1`, and `pipe.v1` trace schemas.
- [ ] Add checker policy for expected vs unexpected divergence.

## Task 13B: Add dependency trace capture in RTL

**Files:**
- Edit: `rv64gc-v2/src/tb/tb_top.sv`
- Edit as needed: `rv64gc-v2/src/rtl/core/rv64gc_core_top.sv`

- [ ] Add `+TRACE_DEP` plusarg.
- [ ] Emit `[DEP schema=dep.v1]` lines with `seq`, `rob`, `epoch`, `pc`,
      raw instruction, decoded type, arch regs, physical regs, FU class,
      branch metadata, memory metadata, and recovery metadata.
- [ ] Keep existing `[CPC]` output backward-compatible.
- [ ] Add parser tests in `rv64gc-perf-model/tests/test_trace.py`.

## Task 13C: Add per-cycle pipeline trace capture in RTL

**Files:**
- Edit: `rv64gc-v2/src/tb/tb_top.sv`

- [ ] Add `+TRACE_PIPELINE` plusarg.
- [ ] Emit `[PIPE schema=pipe.v1]` for deterministic microbench runs.
- [ ] Include stage counts, queue occupancy, free-list/checkpoint counts,
      flush/replay state, and fetch-zero reason.
- [ ] Keep this trace off for long CoreMark runs unless specifically requested.

## Task 13D: Add checker and counter calibration scripts

**Files:**
- Create: `rv64gc-perf-model/scripts/rtl_clockcheck.py`
- Create: `rv64gc-perf-model/scripts/calibrate_counters.py`

- [ ] `rtl_clockcheck.py` compares two `pipe.v1`/`dep.v1` traces and reports
      first divergence by category.
- [ ] Support expected-delta config for intentional width/resource changes.
- [ ] `calibrate_counters.py` compares model output against RTL counter
      dashboards using the taxonomy in `methodology.md`.
- [ ] Add tests with small fixture traces.

---

# Phase 0 — Setup + Audit

## Task 1: Create rv64gc-perf-model workspace

**Files:**
- Create: `rv64gc-perf-model/README.md`
- Create: `rv64gc-perf-model/pyproject.toml`
- Create: `rv64gc-perf-model/doc/design.md` (skeleton)
- Create: `rv64gc-perf-model/.gitignore`

- [ ] **Step 1: Create directory + initial files**

```bash
mkdir -p /home/jeremycai/agent-workspace/rv64gc-perf-model/{doc,src/perfmodel,tests/golden,tests/fixtures,scripts,traces}
cd /home/jeremycai/agent-workspace/rv64gc-perf-model
git init
```

- [ ] **Step 2: Write README.md**

```markdown
# rv64gc-perf-model

Cycle-approximate performance model for rv64gc-v2.  Industry-style custom
perf model (mirrors ARM PerfSim methodology, not gem5).

Calibrated against 6-wide RTL via dsim measurements.  Used to drive the
4-wide pivot decision and explore new uarch optimizations BEFORE touching
RTL.

## Quickstart

    pip install -e .
    bash scripts/gen_trace.sh tests/fixtures/microkernel_loop.elf
    python scripts/run_workload.py --config configs/baseline_4wide.json --trace traces/microkernel_loop.trace

## Targets

- Baseline (must match): MegaBoom-class CM/MHz ≥ 6.2, DMIPS/MHz ≥ 4.00
- Sign-off (must beat):  ARM Cortex-A72   CM/MHz ≥ 8.24, DMIPS/MHz ≥ 4.72

See doc/design.md for the model architecture.
```

- [ ] **Step 3: Write pyproject.toml**

```toml
[project]
name = "rv64gc-perf-model"
version = "0.1.0"
description = "Cycle-approximate performance model for rv64gc-v2"
requires-python = ">=3.10"
dependencies = [
    "pandas>=2.0",
    "matplotlib>=3.7",
    "numpy>=1.24",
    "pyelftools>=0.30",
]

[project.optional-dependencies]
dev = ["pytest>=7", "pytest-xdist>=3", "ruff>=0.1"]

[build-system]
requires = ["setuptools>=68"]
build-backend = "setuptools.build_meta"

[tool.setuptools.packages.find]
where = ["src"]

[tool.ruff]
line-length = 100
target-version = "py310"
```

- [ ] **Step 4: Write skeleton design.md**

```markdown
# rv64gc-perf-model Design

## Methodology

Industry-style cycle-approximate model.  Mirrors ARM's PerfSim approach:
custom model written specifically for our uarch, calibrated against RTL,
fast enough for parameter sweeps.

NOT cycle-accurate.  Target: within 10% of RTL on dhrystone/coremark.

## Pipeline Model

Mirrors v2 RTL:
  fetch (F0/F1/F2) → decode → fusion → rename → dispatch → issue → execute → commit
  with parallel BPU + LSU paths.

See per-module docs in src/perfmodel/.

## Configuration

All structural params (PIPE_WIDTH, ROB_DEPTH, IQ count, etc.) live in
src/perfmodel/config.py UarchConfig dataclass.  Configs are JSON-serializable
for sweep harness.
```

- [ ] **Step 5: Write .gitignore**

```
__pycache__/
*.pyc
*.pyo
.pytest_cache/
*.egg-info/
build/
dist/
traces/*.trace
doc/results/*.csv
doc/results/*.png
```

- [ ] **Step 6: Initial commit**

```bash
git add README.md pyproject.toml doc/design.md .gitignore
git commit -m "init: scaffold rv64gc-perf-model workspace"
```

---

## Task 2: Audit v2 RTL optimizations — inventory document

**Files:**
- Create: `rv64gc-perf-model/doc/audit.md`
- Read for reference (do NOT modify): `rv64gc-v2/CLAUDE.md`, `rv64gc-v2/doc/rv64gc_v2_uarch.md`, `rv64gc-v2/src/rtl/core/rv64gc_core_top.sv`

The audit document captures every optimization in v2 RTL, with measured-or-estimated impact.  Used to drive Phase 3 stacking order (highest-impact first).

- [ ] **Step 1: Open the v2 source and walk every optimization**

Walk through these RTL features in order and note presence + parameters:

  Fetch:
    - F0/F1/F2 pipeline staging
    - FTQ (Fetch Target Queue)
    - fetch_packet_buffer
    - NLPB (next-line prefetch buffer)
    - icache (32 kB, 4-way, MSHR depth)

  BPU:
    - BTB sets/ways
    - TAGE-SC-L tables
    - RAS depth
    - GHR width
    - BTB index scheme (cache-line indexed pc[13:6])

  Decode:
    - 6-wide decode
    - RVC expansion
    - decoded_insn_t fields (especially is_fused, bp_*)

  Fusion:
    - Tier 1a-d fusions (LUI+ADDI, AUIPC+JALR, AUIPC+ADDI, AUIPC+LD)
    - Tier 1e-h (SLT/SLTU + B*)

  Rename:
    - per-slot independent advance
    - move elimination
    - 12R6W PRF
    - free list 224
    - 4 → 16 checkpoints (commit 0ebc657)

  Dispatch:
    - 6-wide
    - load cap (≤2 loads/cycle)
    - load-balanced IQ routing (commit 2a92d6b)

  Issue:
    - 3 IQs × 32 entries
    - 2 select ports per IQ
    - speculative wakeup
    - dual BRU on IQ0 (commit ?)

  Execute:
    - 4 ALUs
    - bypass network 6 srcs

  LSU:
    - LQ/SQ 64/64 (power-of-2)
    - committed store buffer
    - port-1 misalign hold register (commit, this session)
    - forwarding hold register (CDB→bypass loop break)

  Cache:
    - dcache 64 kB 4-way 4-bank
    - dual-port tag/data RAM
    - L2 2 MB 8-way 32 MSHR

  Loop buffer (gen-1):
    - 64 µops
    - capture/playback FSM
    - exit predictor

  µop cache (gen-2, just built):
    - 32 sets × 8 ways × 6 µops
    - safety filter (control-free, non-fused, non-mem)
    - single-emit, IDLE_THRESHOLD=3

  Recovery:
    - ROB head watchdog (64-cycle threshold)
    - rename_buf clear on full_flush

- [ ] **Step 2: Write audit.md with ranked impact**

Structure each entry as:

```markdown
## [Optimization name]

**RTL location:** `src/rtl/core/.../foo.sv:NN-MM`
**Type:** [pipeline / cache / BPU / recovery / etc.]
**Status:** [in v2 / not in v2 / partial]
**Measured impact (RTL):** [+X% IPC on Y; +Z% mispredict reduction; etc.]
**Source of measurement:** [commit message / session report / "not measured"]
**Order in Phase 3 stacking:** [1-12, by descending impact]

**Notes:** [implementation gotchas, dependencies on other opts, etc.]
```

- [ ] **Step 3: Verify completeness**

Cross-check audit.md against:
  - `rv64gc-v2/CLAUDE.md` "Recent optimizations" section (should have all 8)
  - `rv64gc-v2/doc/rv64gc_v2_uarch.md` "Innovation" sections
  - All files matching `git log --oneline | grep -iE "perf|opt|fix.*ipc"` in v2

- [ ] **Step 4: Commit**

```bash
cd /home/jeremycai/agent-workspace/rv64gc-perf-model
git add doc/audit.md
git commit -m "doc: v2 RTL optimization audit — 12 entries ranked by impact"
```

---

## Task 3: Capture baseline RTL cycle counts (golden numbers)

**Files:**
- Create: `rv64gc-perf-model/tests/golden/dhrystone_iter100_6wide.json`
- Create: `rv64gc-perf-model/tests/golden/coremark_iter1_6wide.json`
- Create: `rv64gc-perf-model/tests/golden/coremark_iter10_6wide.json`
- Create: `rv64gc-perf-model/tests/golden/microkernel_loop_6wide.json`
- Create: `rv64gc-perf-model/scripts/capture_rtl_golden.sh`

Calibration baseline: actual RTL measurements on dsim that the model must match.

- [ ] **Step 1: Write capture script**

```bash
#!/usr/bin/env bash
# scripts/capture_rtl_golden.sh
# Capture RTL cycle counts for calibration golden values.
set -euo pipefail
RTL_DIR=/home/jeremycai/agent-workspace/rv64gc-v2
OUT_DIR=/home/jeremycai/agent-workspace/rv64gc-perf-model/tests/golden

cd "$RTL_DIR"
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"

run_capture() {
    local name=$1 hex=$2 maxcyc=$3 plus=${4:-}
    local log=/tmp/rtl_golden_${name}.log
    bash run_dsim.sh tests/hex/$hex $maxcyc $plus > $log 2>&1
    cyc=$(grep -E "^IPC: " $log | tail -1 | sed -E 's/.*mcycle=([0-9]+).*/\1/')
    inst=$(grep -E "^IPC: " $log | tail -1 | sed -E 's/.*minstret=([0-9]+).*/\1/')
    cat > $OUT_DIR/${name}_6wide.json <<EOF
{
  "workload": "$name",
  "hex_file": "$hex",
  "rtl_version": "6-wide v2 (PIPE_WIDTH=6, post-uop-cache-integration)",
  "uoc_enable": false,
  "cycles": $cyc,
  "instret": $inst,
  "ipc": $(python3 -c "print($inst/$cyc)"),
  "captured_at": "$(date -Iseconds)"
}
EOF
    echo "Captured $name: $cyc cyc / $inst instret = $(python3 -c "print($inst/$cyc)") IPC"
}

run_capture dhrystone        dhrystone.hex        50000
run_capture coremark_iter1   coremark.hex         500000
run_capture coremark_iter10  coremark_iter10.hex  5000000
```

- [ ] **Step 2: Run the capture**

```bash
chmod +x scripts/capture_rtl_golden.sh
./scripts/capture_rtl_golden.sh
```

Expected: 3 JSON files in `tests/golden/`.  Numbers should be within ±2% of the published values:
  dhrystone:       18730 cyc, 48646 instret, IPC 2.597
  coremark_iter1:  183141 cyc, 332108 instret, IPC 1.813
  coremark_iter10: 1714296 cyc, 3197348 instret, IPC 1.865

- [ ] **Step 3: Add a microkernel as a smaller calibration target**

Use bench_loop.hex (already exists in v2/tests/hex/) — straight-line loop, no memory, idealized BPU behavior.  This is our "T1 baseline calibration" target.

```bash
bash run_dsim.sh tests/hex/bench_loop.hex 20000 > /tmp/microkernel.log
# Capture similarly into tests/golden/microkernel_loop_6wide.json
```

- [ ] **Step 4: Commit**

```bash
cd /home/jeremycai/agent-workspace/rv64gc-perf-model
git add scripts/capture_rtl_golden.sh tests/golden/
git commit -m "test: capture RTL golden cycle counts for calibration"
```

---

# Phase 1 — Vanilla 4-wide OoO baseline

The vanilla baseline must NOT include any v2 optimizations.  No fusion, no LB, no UOC, no NLPB, no speculative wakeup, no dual-BRU, single-port everything.  This establishes the "what does plain 4-wide OoO get us?" floor.

## Task 4: UarchConfig dataclass

**Files:**
- Create: `src/perfmodel/config.py`
- Create: `tests/test_config.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/test_config.py
from perfmodel.config import UarchConfig, BASELINE_VANILLA_4WIDE

def test_baseline_4wide_defaults():
    c = BASELINE_VANILLA_4WIDE
    assert c.pipe_width == 4
    assert c.rob_depth == 64           # vanilla = small
    assert c.int_prf_depth == 96
    assert c.num_int_iqs == 1          # vanilla = single IQ
    assert c.iq_select_ports == 1
    assert c.fusion_enable is False
    assert c.loop_buffer_enable is False
    assert c.uop_cache_enable is False
    assert c.nlpb_enable is False
    assert c.dual_bru is False
    assert c.spec_wakeup is False

def test_config_serializable():
    import json
    c = BASELINE_VANILLA_4WIDE
    s = c.to_json(); restored = UarchConfig.from_json(s)
    assert restored == c
```

- [ ] **Step 2: Run test (expect FAIL — module not yet defined)**

```bash
cd /home/jeremycai/agent-workspace/rv64gc-perf-model
pip install -e .[dev]
pytest tests/test_config.py -v
```
Expected: FAIL with ModuleNotFoundError or AttributeError.

- [ ] **Step 3: Implement UarchConfig**

```python
# src/perfmodel/config.py
"""UarchConfig: all v2 microarchitectural parameters in one dataclass.

Vanilla 4-wide baseline has v2 optimizations DISABLED so each can be
toggled on independently in Phase 3 stacking experiments.
"""
from __future__ import annotations
from dataclasses import dataclass, asdict, field, fields
import json


@dataclass(frozen=True)
class UarchConfig:
    # Pipeline width
    pipe_width: int = 4

    # ROB
    rob_depth: int = 64
    # PRF
    int_prf_depth: int = 96
    fp_prf_depth: int = 64
    int_prf_read_ports: int = 8        # 2 per pipe slot
    int_prf_write_ports: int = 4
    # Free list
    int_free_list_depth: int = 64

    # Issue queues
    num_int_iqs: int = 1
    iq_int_depth: int = 32
    iq_select_ports: int = 1
    iq_mem_depth: int = 24
    iq_fp_depth: int = 24

    # ALU/FU counts
    num_alu: int = 2
    num_bru: int = 1
    mul_latency: int = 3
    div_latency: int = 20
    cdb_width: int = 4
    num_bypass_srcs: int = 4

    # LQ/SQ
    lq_depth: int = 24
    sq_depth: int = 24

    # Caches
    line_size: int = 64
    l1i_size: int = 32 * 1024
    l1i_ways: int = 4
    l1i_mshr: int = 2
    l1i_hit_lat: int = 1
    l1i_miss_lat: int = 12
    l1d_size: int = 64 * 1024
    l1d_ways: int = 4
    l1d_banks: int = 2                 # vanilla = 2-bank
    l1d_mshr: int = 8
    l1d_hit_lat: int = 1
    l1d_miss_lat: int = 12
    l2_size: int = 2 * 1024 * 1024
    l2_ways: int = 8
    l2_mshr: int = 32
    l2_hit_lat: int = 8
    dram_lat: int = 100

    # BPU
    bpu_kind: str = "static_taken"     # vanilla = always-taken predictor
    btb_entries: int = 1024
    btb_ways: int = 4
    ras_depth: int = 16
    ghr_bits: int = 0                  # no global history in vanilla

    # Recovery
    num_checkpoints: int = 4
    rob_watchdog_threshold: int = 0    # disabled in vanilla

    # OPTIMIZATION FLAGS (vanilla = all OFF)
    fusion_enable: bool = False
    loop_buffer_enable: bool = False
    loop_buffer_depth: int = 64
    uop_cache_enable: bool = False
    uop_cache_sets: int = 32
    uop_cache_ways: int = 8
    nlpb_enable: bool = False
    nlpb_depth: int = 4
    dual_bru: bool = False             # both BRUs on IQ0
    spec_wakeup: bool = False
    move_elim: bool = False
    load_balanced_dispatch: bool = False
    forwarding_hold: bool = False      # CDB→bypass loop breaker
    lsu_p1_misalign_hold: bool = False
    rob_full_flush_clear: bool = False

    # Pipeline latencies (cycles)
    fetch_to_decode_lat: int = 1
    decode_to_rename_lat: int = 1
    rename_to_dispatch_lat: int = 1
    dispatch_to_issue_lat: int = 1
    issue_to_execute_lat: int = 1
    execute_to_writeback_lat: int = 1
    writeback_to_commit_lat: int = 1

    def to_json(self) -> str:
        return json.dumps(asdict(self), indent=2)

    @classmethod
    def from_json(cls, s: str) -> "UarchConfig":
        d = json.loads(s)
        return cls(**d)


# Predefined configs
BASELINE_VANILLA_4WIDE = UarchConfig()

# Will be populated in Phase 3 after each opt added
V2_FULL_4WIDE = UarchConfig(
    fusion_enable=True, loop_buffer_enable=True, uop_cache_enable=True,
    nlpb_enable=True, dual_bru=True, spec_wakeup=True, move_elim=True,
    load_balanced_dispatch=True, forwarding_hold=True,
    lsu_p1_misalign_hold=True, rob_full_flush_clear=True,
    bpu_kind="tage_sc_l", ghr_bits=64, num_checkpoints=16,
    rob_watchdog_threshold=64,
    num_alu=3, num_int_iqs=3, iq_select_ports=2,
    rob_depth=128, int_prf_depth=160,
)
```

- [ ] **Step 4: Run test — expect PASS**

```bash
pytest tests/test_config.py -v
```

- [ ] **Step 5: Commit**

```bash
git add src/perfmodel/config.py tests/test_config.py
git commit -m "feat: UarchConfig dataclass with vanilla 4-wide defaults + V2 full preset"
```

---

## Task 5: Stats collector

**Files:**
- Create: `src/perfmodel/stats.py`
- Create: `tests/test_stats.py`

- [ ] **Step 1: Write failing test**

```python
# tests/test_stats.py
from perfmodel.stats import Stats

def test_stats_basic():
    s = Stats()
    for _ in range(10): s.tick(commit_count=2)
    assert s.cycles == 10
    assert s.commit_total == 20
    assert s.ipc() == 2.0

def test_stats_breakdown_categories():
    s = Stats()
    s.tick(commit_count=0); s.note_stall("rename")
    s.tick(commit_count=4)
    assert s.cycles == 2
    assert s.stall_cycles["rename"] == 1
    assert s.commit_hist[0] == 1
    assert s.commit_hist[4] == 1
```

- [ ] **Step 2: Run test (FAIL)**

```bash
pytest tests/test_stats.py -v
```

- [ ] **Step 3: Implement Stats**

```python
# src/perfmodel/stats.py
"""Per-run statistics collector.  All counters are accumulated cycle-by-cycle.

Reports IPC, cycle breakdown by stall category, commit histogram, BPU
mispredict rate, cache miss rates, etc.  Mirrors the v2 PERF_PROFILE block
in tb_top.sv.
"""
from collections import defaultdict
from dataclasses import dataclass, field


@dataclass
class Stats:
    cycles: int = 0
    commit_total: int = 0
    fetch_total: int = 0
    rename_total: int = 0

    commit_hist: dict = field(default_factory=lambda: defaultdict(int))
    fetch_hist: dict = field(default_factory=lambda: defaultdict(int))

    stall_cycles: dict = field(default_factory=lambda: defaultdict(int))

    bpu_lookups: int = 0
    bpu_mispredicts: int = 0
    icache_lookups: int = 0
    icache_misses: int = 0
    dcache_lookups: int = 0
    dcache_misses: int = 0
    flush_count: int = 0
    flush_cycles: int = 0

    def tick(self, commit_count: int = 0, fetch_count: int = 0):
        self.cycles += 1
        self.commit_total += commit_count
        self.fetch_total += fetch_count
        self.commit_hist[commit_count] += 1
        self.fetch_hist[fetch_count] += 1

    def note_stall(self, category: str):
        self.stall_cycles[category] += 1

    def note_bpu(self, mispredict: bool = False):
        self.bpu_lookups += 1
        if mispredict: self.bpu_mispredicts += 1

    def note_icache(self, miss: bool = False):
        self.icache_lookups += 1
        if miss: self.icache_misses += 1

    def note_dcache(self, miss: bool = False):
        self.dcache_lookups += 1
        if miss: self.dcache_misses += 1

    def ipc(self) -> float:
        return self.commit_total / self.cycles if self.cycles else 0.0

    def mispredict_rate(self) -> float:
        return self.bpu_mispredicts / self.bpu_lookups if self.bpu_lookups else 0.0

    def icache_miss_rate(self) -> float:
        return self.icache_misses / self.icache_lookups if self.icache_lookups else 0.0

    def dcache_miss_rate(self) -> float:
        return self.dcache_misses / self.dcache_lookups if self.dcache_lookups else 0.0

    def report(self, workload: str = "?", clk_mhz: int = 1) -> dict:
        return {
            "workload": workload,
            "cycles": self.cycles,
            "instret": self.commit_total,
            "ipc": self.ipc(),
            "mispredict_rate": self.mispredict_rate(),
            "icache_miss_rate": self.icache_miss_rate(),
            "dcache_miss_rate": self.dcache_miss_rate(),
            "stall_breakdown": dict(self.stall_cycles),
            "commit_hist": dict(self.commit_hist),
            "fetch_hist": dict(self.fetch_hist),
        }
```

- [ ] **Step 4: Run test — PASS**

- [ ] **Step 5: Commit**

```bash
git add src/perfmodel/stats.py tests/test_stats.py
git commit -m "feat: Stats collector mirroring v2 PERF_PROFILE counters"
```

---

## Task 6: Spike trace ingest

**Files:**
- Create: `src/perfmodel/trace.py`
- Create: `tests/test_trace.py`
- Create: `tests/fixtures/sample.trace` (small handcrafted trace for testing)
- Create: `scripts/gen_trace.sh`

Spike emits one line per retired instruction in `--log-commits` mode.  Format example:
```
core   0: 3 0x0000000080000004 (0x00010117) auipc x2, 0x10
core   0: 3 0x0000000080000008 (0x00808113) addi x2, x1, 8
```

We parse PC, raw insn bytes, mnemonic, operands → InsnRecord.

- [ ] **Step 1: Create handcrafted fixture**

```
# tests/fixtures/sample.trace
core   0: 3 0x0000000080000000 (0x00010117) auipc x2, 0x10
core   0: 3 0x0000000080000004 (0x00808113) addi x2, x1, 8
core   0: 3 0x0000000080000008 (0x06318063) beq x3, x3, 0x80000068
core   0: 3 0x0000000080000068 (0x00100073) ebreak
```

- [ ] **Step 2: Write failing test**

```python
# tests/test_trace.py
from pathlib import Path
from perfmodel.trace import load_trace, InsnRecord

FIXTURE = Path(__file__).parent / "fixtures" / "sample.trace"

def test_loads_4_records():
    insns = list(load_trace(FIXTURE))
    assert len(insns) == 4

def test_first_record_fields():
    insns = list(load_trace(FIXTURE))
    r = insns[0]
    assert r.pc == 0x80000000
    assert r.raw == 0x00010117
    assert r.mnemonic == "auipc"
    assert r.is_branch is False
    assert r.is_load is False
    assert r.is_store is False

def test_branch_record():
    insns = list(load_trace(FIXTURE))
    beq = insns[2]
    assert beq.is_branch
    assert beq.branch_target == 0x80000068

def test_actual_taken_inferred():
    """Next-PC mismatch with PC+4 = branch was taken."""
    insns = list(load_trace(FIXTURE))
    beq = insns[2]
    assert beq.actual_taken is True
```

- [ ] **Step 3: Run test (FAIL)**

- [ ] **Step 4: Implement trace.py**

```python
# src/perfmodel/trace.py
"""Spike commit-log trace consumer.

Spike --log-commits format is line-based.  We parse PC, raw insn, mnemonic,
and (post-pass) infer actual_taken / branch_target from successive PCs.
"""
from __future__ import annotations
from dataclasses import dataclass
from pathlib import Path
import re
from typing import Iterator, Optional

# Categorize by RV64GC opcode/funct fields.  Coarse — refined as needed.
_BRANCH_OPCODES = {0x63}        # B-type
_JAL_OPCODES = {0x6f}
_JALR_OPCODES = {0x67}
_LOAD_OPCODES = {0x03, 0x07}    # LOAD, LOAD-FP
_STORE_OPCODES = {0x23, 0x27}   # STORE, STORE-FP
_AMO_OPCODES = {0x2f}
_FENCE_OPCODES = {0x0f}
_SYSTEM_OPCODES = {0x73}

_RVC_QUADRANTS = {0, 1, 2}      # opcode bits[1:0] != 11 → RVC


@dataclass
class InsnRecord:
    pc: int
    raw: int
    is_rvc: bool
    mnemonic: str
    operands: str
    is_branch: bool = False
    is_jal: bool = False
    is_jalr: bool = False
    is_load: bool = False
    is_store: bool = False
    is_amo: bool = False
    is_fence: bool = False
    is_system: bool = False
    branch_target: Optional[int] = None
    actual_taken: Optional[bool] = None
    next_pc: Optional[int] = None     # filled in pass 2

    @property
    def size(self) -> int:
        return 2 if self.is_rvc else 4


def _classify(raw: int) -> dict:
    if (raw & 0x3) != 0x3:
        # RVC — coarse: treat as plain ALU unless we add explicit detection
        return dict(is_rvc=True)
    op = raw & 0x7f
    return dict(
        is_rvc=False,
        is_branch=(op in _BRANCH_OPCODES),
        is_jal=(op in _JAL_OPCODES),
        is_jalr=(op in _JALR_OPCODES),
        is_load=(op in _LOAD_OPCODES),
        is_store=(op in _STORE_OPCODES),
        is_amo=(op in _AMO_OPCODES),
        is_fence=(op in _FENCE_OPCODES),
        is_system=(op in _SYSTEM_OPCODES),
    )


_LINE_RE = re.compile(
    r"^core\s+\d+:\s+\d+\s+0x([0-9a-fA-F]+)\s+\(0x([0-9a-fA-F]+)\)\s+(\S+)\s*(.*)$"
)


def load_trace(path: str | Path) -> Iterator[InsnRecord]:
    """Stream InsnRecords from a Spike commit log.  Two-pass: yield records
    after computing actual_taken from successive PCs."""
    pending: list[InsnRecord] = []
    with open(path) as f:
        for line in f:
            m = _LINE_RE.match(line)
            if not m: continue
            pc = int(m.group(1), 16)
            raw = int(m.group(2), 16)
            mnem = m.group(3)
            ops = m.group(4)
            cls = _classify(raw)
            r = InsnRecord(pc=pc, raw=raw, mnemonic=mnem, operands=ops, **cls)
            if pending:
                prev = pending[-1]
                prev.next_pc = pc
                if prev.is_branch or prev.is_jal or prev.is_jalr:
                    expected_fall = prev.pc + prev.size
                    prev.actual_taken = (pc != expected_fall)
                    if prev.actual_taken:
                        prev.branch_target = pc
            pending.append(r)
            if len(pending) >= 2:
                yield pending.pop(0)
        for r in pending:
            yield r


def gen_trace_command(elf: str, out: str, max_insns: int = 10_000_000) -> str:
    """Return the Spike command-line to generate a commit log for `elf`."""
    return (
        f"spike --isa=RV64GC -m2048 --log-commits "
        f"--commit-log {out} {elf} > /dev/null 2>&1"
    )
```

- [ ] **Step 5: Write gen_trace.sh helper**

```bash
#!/usr/bin/env bash
# scripts/gen_trace.sh -- run Spike to generate a commit log trace for an ELF
set -euo pipefail
if [[ $# -lt 1 ]]; then echo "Usage: $0 <elf> [out_trace]"; exit 1; fi
ELF=$1
OUT=${2:-traces/$(basename $ELF .elf).trace}
mkdir -p "$(dirname $OUT)"
spike --isa=RV64GC -m2048 --log-commits "$ELF" > "$OUT" 2>&1
echo "Trace: $OUT  ($(wc -l < $OUT) insns)"
```

- [ ] **Step 6: Run tests — PASS**

- [ ] **Step 7: Commit**

```bash
chmod +x scripts/gen_trace.sh
git add src/perfmodel/trace.py tests/test_trace.py tests/fixtures/sample.trace scripts/gen_trace.sh
git commit -m "feat: Spike commit-log trace consumer with classification"
```

---

## Task 7: Pipeline scheduler skeleton (vanilla in-order shell)

**Files:**
- Create: `src/perfmodel/pipeline.py`
- Create: `tests/test_pipeline_inorder.py`

We start with an IN-ORDER pipeline shell to verify the cycle scheduler works, then layer OoO on top in Task 8+.

- [ ] **Step 1: Write failing test**

```python
# tests/test_pipeline_inorder.py
"""Vanilla in-order shell for cycle-counting sanity.  All insns are
1-cycle ALU ops, perfect L1 hits, ideal BPU."""
from perfmodel.config import BASELINE_VANILLA_4WIDE
from perfmodel.pipeline import Pipeline
from perfmodel.trace import InsnRecord

def make_alu_trace(n=100):
    return [InsnRecord(pc=0x80000000+i*4, raw=0x00100013, is_rvc=False,
                       mnemonic="addi", operands="x0, x0, 1") for i in range(n)]

def test_inorder_4wide_sees_4ipc_on_pure_alu():
    cfg = BASELINE_VANILLA_4WIDE
    p = Pipeline(cfg, mode="inorder_oracle")  # debug helper mode
    stats = p.run(make_alu_trace(100))
    # Vanilla 4-wide on pure-ALU should approach IPC = pipe_width
    assert 3.5 <= stats.ipc() <= 4.0
```

- [ ] **Step 2: Run test (FAIL)**

- [ ] **Step 3: Implement Pipeline skeleton**

Cycle-driven loop.  Each cycle calls each stage's `tick()`.  In-order shell: one queue per stage, fixed inter-stage latency.

```python
# src/perfmodel/pipeline.py
"""Main cycle-by-cycle pipeline scheduler.

Stages connect via FIFO queues with depth and per-cycle bandwidth limits.
Each tick advances one cycle and calls every stage in order:
  fetch → decode → rename → dispatch → issue → execute → writeback → commit

The scheduler is *event-driven within a cycle*: stages may peek at each
other's outputs combinationally (matching how RTL modules wire their
combinational paths within a cycle).

Vanilla mode = in-order, single-issue-per-stage modulo width.  This is
the floor we measure against in Task 11.
"""
from __future__ import annotations
from collections import deque
from typing import Iterable
from .config import UarchConfig
from .stats import Stats
from .trace import InsnRecord


class _Queue:
    """Bounded FIFO with per-cycle dequeue bandwidth.  Used as inter-stage
    interconnect."""
    def __init__(self, capacity: int): self.capacity = capacity; self.q = deque()
    def push(self, x) -> bool:
        if len(self.q) >= self.capacity: return False
        self.q.append(x); return True
    def pop(self):
        return self.q.popleft() if self.q else None
    def peek(self):
        return self.q[0] if self.q else None
    def __len__(self): return len(self.q)
    def full(self): return len(self.q) >= self.capacity


class Pipeline:
    def __init__(self, cfg: UarchConfig, mode: str = "vanilla"):
        self.cfg = cfg
        self.mode = mode
        self.stats = Stats()
        # Inter-stage FIFOs; sizes chosen to be non-binding in vanilla
        self.fetch_q   = _Queue(cfg.pipe_width * 4)
        self.decode_q  = _Queue(cfg.pipe_width * 4)
        self.rename_q  = _Queue(cfg.pipe_width * 4)
        self.dispatch_q = _Queue(cfg.pipe_width * 4)
        self.issue_q   = _Queue(cfg.iq_int_depth * cfg.num_int_iqs)
        self.execute_q = _Queue(cfg.pipe_width * 2)
        self.writeback_q = _Queue(cfg.pipe_width * 2)
        self.commit_q  = _Queue(cfg.rob_depth)
        # Source iterator (the trace)
        self._trace_iter: Iterable[InsnRecord] | None = None
        self._trace_done = False

    def run(self, trace: Iterable[InsnRecord]) -> Stats:
        self._trace_iter = iter(trace)
        self._trace_done = False
        max_cycles = 100_000_000
        for _ in range(max_cycles):
            commit_count = self._commit_stage()
            self._writeback_stage()
            self._execute_stage()
            self._issue_stage()
            self._dispatch_stage()
            self._rename_stage()
            self._decode_stage()
            fetch_count = self._fetch_stage()
            self.stats.tick(commit_count=commit_count, fetch_count=fetch_count)
            if self._trace_done and not self._inflight():
                break
        return self.stats

    def _inflight(self) -> bool:
        return any(len(q) for q in (
            self.fetch_q, self.decode_q, self.rename_q, self.dispatch_q,
            self.issue_q, self.execute_q, self.writeback_q, self.commit_q
        ))

    # ---- Stages ----

    def _fetch_stage(self) -> int:
        if self._trace_done:
            return 0
        n = 0
        while n < self.cfg.pipe_width and not self.fetch_q.full():
            try:
                insn = next(self._trace_iter)
            except StopIteration:
                self._trace_done = True
                break
            self.fetch_q.push(insn)
            n += 1
        return n

    def _decode_stage(self) -> int:
        n = 0
        while n < self.cfg.pipe_width and not self.decode_q.full():
            x = self.fetch_q.pop()
            if x is None: break
            self.decode_q.push(x); n += 1
        return n

    def _rename_stage(self) -> int:
        n = 0
        while n < self.cfg.pipe_width and not self.rename_q.full():
            x = self.decode_q.pop()
            if x is None: break
            self.rename_q.push(x); n += 1
        return n

    def _dispatch_stage(self) -> int:
        n = 0
        while n < self.cfg.pipe_width and not self.issue_q.full():
            x = self.rename_q.pop()
            if x is None: break
            self.issue_q.push(x); n += 1
        return n

    def _issue_stage(self) -> int:
        # Vanilla: single select port — issue 1 per IQ per cycle
        budget = self.cfg.num_int_iqs * self.cfg.iq_select_ports
        n = 0
        while n < budget and not self.execute_q.full():
            x = self.issue_q.pop()
            if x is None: break
            self.execute_q.push(x); n += 1
        return n

    def _execute_stage(self) -> int:
        n = 0
        while n < self.cfg.cdb_width and not self.writeback_q.full():
            x = self.execute_q.pop()
            if x is None: break
            self.writeback_q.push(x); n += 1
        return n

    def _writeback_stage(self) -> int:
        n = 0
        while n < self.cfg.cdb_width and not self.commit_q.full():
            x = self.writeback_q.pop()
            if x is None: break
            self.commit_q.push(x); n += 1
        return n

    def _commit_stage(self) -> int:
        n = 0
        while n < self.cfg.pipe_width:
            x = self.commit_q.pop()
            if x is None: break
            n += 1
        return n
```

- [ ] **Step 4: Run test — PASS**

If IPC < 3.5: probably a queue-depth/bandwidth bug.  Check that fetch_q can hold enough to feed decode without back-pressure.

- [ ] **Step 5: Commit**

```bash
git add src/perfmodel/pipeline.py tests/test_pipeline_inorder.py
git commit -m "feat: pipeline scheduler skeleton with in-order shell"
```

---

## Task 8: Add OoO scheduling — ROB + per-IQ ready tracking

**Files:**
- Modify: `src/perfmodel/pipeline.py`
- Modify: `tests/test_pipeline_inorder.py` → rename to `tests/test_pipeline.py` and extend

In OoO mode, dispatch reserves an ROB entry; issue picks ready insns; execute completes after FU latency; commit retires the ROB head when it's the oldest READY entry.

- [ ] **Step 1: Add ReorderBuffer + Scoreboard classes**

```python
# In src/perfmodel/pipeline.py — add at top

@dataclass
class _ROBEntry:
    insn: InsnRecord
    rob_idx: int
    ready: bool = False         # execution complete
    issued: bool = False
    completed_cycle: int = -1

class ReorderBuffer:
    def __init__(self, depth: int):
        self.depth = depth
        self.entries: list[_ROBEntry | None] = [None] * depth
        self.head = 0
        self.tail = 0
        self.count = 0
    def alloc(self, insn) -> _ROBEntry | None:
        if self.count >= self.depth: return None
        idx = self.tail
        e = _ROBEntry(insn=insn, rob_idx=idx)
        self.entries[idx] = e
        self.tail = (self.tail + 1) % self.depth
        self.count += 1
        return e
    def head_entry(self) -> _ROBEntry | None:
        return self.entries[self.head] if self.count else None
    def retire(self):
        self.entries[self.head] = None
        self.head = (self.head + 1) % self.depth
        self.count -= 1
```

- [ ] **Step 2: Modify Pipeline to use ROB and per-IQ ready tracking**

Replace the `commit_q`, `issue_q` FIFOs with ROB + IQ logic:
- Dispatch: alloc ROB entry, push to one of the IQs (round-robin)
- Issue: from each IQ, pick up-to-`iq_select_ports` ready entries (ready = source operands available — vanilla model uses simple "issued K cycles ago" sliding readiness)
- Execute: mark entry ready after FU latency
- Commit: retire ROB head if `e.ready` (in-order commit, OoO completion)

(Show key code in patch form — engineer fills in remaining glue.)

```python
# Skeleton of new dispatch / issue / commit
def _dispatch_stage(self) -> int:
    n = 0
    while n < self.cfg.pipe_width:
        x = self.rename_q.pop()
        if x is None: break
        e = self.rob.alloc(x)
        if e is None:                    # ROB full — back-pressure
            self.rename_q.push_front(x); break
        # Pick IQ via round-robin (vanilla)
        iq = self.iqs[self._iq_rr]
        if not iq.push(e):
            self.rob.tail = (self.rob.tail - 1) % self.rob.depth
            self.rob.count -= 1; break
        self._iq_rr = (self._iq_rr + 1) % self.cfg.num_int_iqs
        n += 1
    return n

def _issue_stage(self) -> int:
    issued = 0
    for iq in self.iqs:
        for _ in range(self.cfg.iq_select_ports):
            e = iq.pop_oldest_ready(self.cycle)
            if e is None: break
            e.issued = True
            e.completed_cycle = self.cycle + self._fu_latency(e.insn)
            self.executing.append(e)
            issued += 1
    return issued

def _commit_stage(self) -> int:
    n = 0
    while n < self.cfg.pipe_width:
        e = self.rob.head_entry()
        if e is None or not e.ready: break
        self.rob.retire(); n += 1
    return n
```

- [ ] **Step 3: Add OoO test**

```python
def test_ooo_4wide_pure_alu_ipc():
    cfg = BASELINE_VANILLA_4WIDE
    p = Pipeline(cfg, mode="vanilla")
    stats = p.run(make_alu_trace(200))
    assert 3.0 <= stats.ipc() <= 4.0  # vanilla OoO with single-port IQ caps below width

def test_long_chain_ipc():
    """RAW dependency chain — IPC should be 1.0 since each insn waits for prev."""
    insns = []
    for i in range(50):
        insns.append(InsnRecord(pc=0x80000000+i*4, raw=0x00010113,
                                is_rvc=False, mnemonic="addi", operands=f"x2,x2,1"))
    p = Pipeline(BASELINE_VANILLA_4WIDE, mode="vanilla")
    stats = p.run(insns)
    assert 0.8 <= stats.ipc() <= 1.0
```

For the dependency model, you'll need a simple register liveness map: each insn consumes/produces arch registers; the Pipeline tracks "ready cycle" per arch reg.  Add this in the dispatch stage.

- [ ] **Step 4: Run tests — PASS**

- [ ] **Step 5: Commit**

```bash
git add src/perfmodel/pipeline.py tests/test_pipeline.py
git commit -m "feat: ROB + per-IQ ready tracking for OoO scheduling"
```

---

## Task 9: Add memory hierarchy — L1I/L1D hits + miss latency

**Files:**
- Create: `src/perfmodel/caches.py`
- Modify: `src/perfmodel/pipeline.py`
- Create: `tests/test_caches.py`

Vanilla model: caches are MAGIC HIT (always hit, fixed latency).  Miss handling deferred to Task 13.

- [ ] **Step 1: Write minimal Cache class**

```python
# src/perfmodel/caches.py
from dataclasses import dataclass
from .config import UarchConfig

@dataclass
class CacheStats:
    hits: int = 0; misses: int = 0
    @property
    def miss_rate(self) -> float:
        t = self.hits + self.misses
        return self.misses / t if t else 0.0

class Cache:
    """Skeleton: vanilla = always hit, fixed hit latency.
    Tier 2 will replace .access() with set-associative tag check + MSHR."""
    def __init__(self, kind: str, cfg: UarchConfig):
        self.kind = kind
        self.cfg = cfg
        self.stats = CacheStats()
        if kind == "l1i":
            self.hit_lat = cfg.l1i_hit_lat; self.miss_lat = cfg.l1i_miss_lat
        elif kind == "l1d":
            self.hit_lat = cfg.l1d_hit_lat; self.miss_lat = cfg.l1d_miss_lat
        else: raise ValueError(kind)

    def access(self, addr: int, write: bool = False) -> int:
        """Returns access latency in cycles.  Vanilla: always hit."""
        self.stats.hits += 1
        return self.hit_lat
```

- [ ] **Step 2: Wire icache into fetch (latency added to fetch->decode)**

In Pipeline `_fetch_stage`, before pushing into `fetch_q`, simulate icache access for the line containing each insn.  Track per-line accesses (one per cache line, not per insn).

- [ ] **Step 3: Wire dcache into LSU**

Loads: dcache.access(load_addr) returns latency before result is ready.
Stores: dcache.access(store_addr, write=True) updates with same model.

For vanilla, since spike trace doesn't carry effective addresses, model addresses synthetically: address = pc + load_offset (heuristic OK for cycle counts in vanilla).

- [ ] **Step 4: Tests + commit**

---

## Task 10: Static-taken BPU (vanilla branch predictor)

**Files:**
- Create: `src/perfmodel/bpu.py`
- Modify: `src/perfmodel/pipeline.py` (fetch stage)
- Create: `tests/test_bpu.py`

Vanilla = "always predict taken backward branches, fall-through forward."  Mispredict = redirect with `frontend_flush_lat` cycles bubble.

- [ ] **Step 1: Implement static BPU**

```python
# src/perfmodel/bpu.py
class StaticBpu:
    def __init__(self, cfg): self.cfg = cfg
    def predict(self, insn) -> tuple[bool, int]:
        """Return (predicted_taken, predicted_target)."""
        if not (insn.is_branch or insn.is_jal or insn.is_jalr):
            return (False, insn.pc + insn.size)
        if insn.is_jal:
            return (True, insn.branch_target or insn.pc + insn.size)
        if insn.is_jalr:
            # Static can't predict JALR; treat as taken to next-PC
            return (True, insn.next_pc or insn.pc + insn.size)
        # Conditional: assume backward-taken, forward-NT
        if insn.branch_target and insn.branch_target < insn.pc:
            return (True, insn.branch_target)
        return (False, insn.pc + insn.size)
    def update(self, insn, mispredict): pass    # no learning
```

- [ ] **Step 2: Hook into fetch — on mispredict, flush younger insns and bubble fetch**

When mispredict detected (compare BPU.predict() vs trace-recorded actual_taken), flush younger ROB entries and add `frontend_flush_lat` (~3 cycle) bubble.

- [ ] **Step 3: Test + commit**

---

## Task 11: Vanilla 4-wide calibration on microkernel

**Files:**
- Create: `scripts/run_workload.py`
- Create: `doc/calibration.md` (start filling)

- [ ] **Step 1: Write run_workload.py**

```python
#!/usr/bin/env python3
"""Single-config simulation entry."""
import argparse, json
from pathlib import Path
from perfmodel.config import UarchConfig
from perfmodel.pipeline import Pipeline
from perfmodel.trace import load_trace

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--trace", required=True)
    ap.add_argument("--out", default="-")
    args = ap.parse_args()
    cfg = UarchConfig.from_json(Path(args.config).read_text())
    p = Pipeline(cfg)
    stats = p.run(load_trace(args.trace))
    out = json.dumps(stats.report(workload=Path(args.trace).stem), indent=2)
    if args.out == "-": print(out)
    else: Path(args.out).write_text(out)

if __name__ == "__main__": main()
```

- [ ] **Step 2: Generate trace for bench_loop microkernel**

```bash
# Build bench_loop.elf from v2/tests/asm/bench_loop.S (or use existing hex with conversion)
spike --isa=RV64GC --log-commits /path/to/bench_loop.elf 2>/dev/null > traces/microkernel_loop.trace
```

- [ ] **Step 3: Run model and compare to RTL**

```bash
python scripts/run_workload.py --config configs/baseline_vanilla_4wide.json \
                                --trace traces/microkernel_loop.trace
```

Expected (from `tests/golden/microkernel_loop_6wide.json`): RTL was X cycles for 7011 insns.  Vanilla 4-wide model should be roughly X * 1.4 cycles (4-wide vs 6-wide width loss + no v2 opts).  Tune model latencies until within 30% — exact agreement not expected for vanilla.

- [ ] **Step 4: Document calibration deltas in doc/calibration.md**

Record: which cycles the vanilla model over/under-predicts, hypotheses for the gap, what stage logic to revisit.

- [ ] **Step 5: Commit**

```bash
git add scripts/run_workload.py configs/baseline_vanilla_4wide.json doc/calibration.md
git commit -m "feat: vanilla 4-wide microkernel calibration baseline"
```

**Phase 1 checkpoint** — review with user before proceeding to Phase 2.

---

# Phase 2 — BPU + memory hierarchy

## Task 12: BTB + RAS

**Files:**
- Modify: `src/perfmodel/bpu.py`
- Create: `tests/test_btb.py`

- [ ] **Step 1: Add BTBEntry + BTB class**

```python
# In bpu.py
@dataclass
class _BTBEntry:
    valid: bool = False
    tag: int = 0
    target: int = 0
    kind: str = ""        # 'cond', 'jal', 'jalr', 'call', 'ret'

class BTB:
    def __init__(self, cfg):
        self.sets = cfg.btb_entries // cfg.btb_ways
        self.ways = cfg.btb_ways
        self._tbl = [[_BTBEntry() for _ in range(self.ways)] for _ in range(self.sets)]
    def _idx(self, pc): return (pc >> 6) & (self.sets - 1)
    def _tag(self, pc): return pc >> (6 + (self.sets-1).bit_length())
    def lookup(self, pc) -> _BTBEntry | None:
        s = self._idx(pc); t = self._tag(pc)
        for e in self._tbl[s]:
            if e.valid and e.tag == t: return e
        return None
    def update(self, pc, target, kind):
        s = self._idx(pc); t = self._tag(pc)
        for e in self._tbl[s]:
            if e.valid and e.tag == t:
                e.target = target; e.kind = kind; return
        # LRU-ish: replace first invalid, else random way
        for e in self._tbl[s]:
            if not e.valid:
                e.valid = True; e.tag = t; e.target = target; e.kind = kind; return
        self._tbl[s][0] = _BTBEntry(True, t, target, kind)

class RAS:
    def __init__(self, cfg): self.depth = cfg.ras_depth; self._stk = []
    def push(self, ret): 
        self._stk.append(ret)
        if len(self._stk) > self.depth: self._stk.pop(0)
    def pop(self): return self._stk.pop() if self._stk else None
```

- [ ] **Step 2: BPU.predict() consults BTB and RAS for jalr/call/ret**

- [ ] **Step 3: Tests + commit**

---

## Task 13: TAGE-SC-L base predictor

**Files:**
- Modify: `src/perfmodel/bpu.py`
- Create: `tests/test_tage.py`

Implement a simplified TAGE: 4 tagged tables + 1 base bimodal.  Each tagged table indexed with PC ⊕ history; entries hold 3-bit prediction counter + tag + useful counter.  Statistical Corrector + Loop Predictor deferred.

- [ ] **Step 1: Implement TageBpu**

(Code skeleton ~80 LOC; engineer ports from Seznec's reference TAGE in C++.)

- [ ] **Step 2: Wire as `cfg.bpu_kind == "tage_sc_l"` option**

- [ ] **Step 3: Test on a known mispredict-heavy microkernel; expect <3% mispredict rate vs >15% on static**

- [ ] **Step 4: Commit**

---

## Task 14: Real cache miss + MSHR

**Files:**
- Modify: `src/perfmodel/caches.py`
- Create: `tests/test_caches_miss.py`

Replace vanilla "always hit" with set-associative tag check.  Miss → MSHR allocation, latency = miss_lat.  Multiple misses to same line coalesce in MSHR.

- [ ] **Step 1: SetAssocCache class with tag check**
- [ ] **Step 2: MSHR class with allocation/coalescing**
- [ ] **Step 3: L2 cache (next-level)**
- [ ] **Step 4: DRAM-latency at L2 miss**
- [ ] **Step 5: Tests + commit**

---

## Task 15: Real load address modeling

**Files:**
- Modify: `src/perfmodel/lsu.py` (create)
- Modify: `src/perfmodel/pipeline.py`

Spike trace's commit log doesn't include effective addresses — we need to either:
- Run Spike with `--log-mem` to get load/store addresses (preferred), or
- Statically compute from mnemonic (offset+rs1) if rs1 value known

Preferred: extend trace.py to parse `--log-mem` lines and attach addresses to InsnRecord.

- [ ] **Step 1: Extend trace.py for --log-mem parsing**

Spike --log-mem format adds lines like `core   0: > 0x80001234 = 0x42` for stores.  Parse and attach `mem_addr` field to InsnRecord.

- [ ] **Step 2: Use real addresses in dcache lookup**

- [ ] **Step 3: Calibrate dcache miss rate vs RTL on dhrystone (~5% target)**

- [ ] **Step 4: Tests + commit**

---

## Task 16: ROB / IQ / LQ / SQ pressure modeling

**Files:**
- Modify: `src/perfmodel/pipeline.py`
- Create: `tests/test_backpressure.py`

When ROB / IQ / LQ / SQ fills up, dispatch back-pressures.  Track stalls per resource.

- [ ] **Step 1: Add full-detection + Stats counters per resource**
- [ ] **Step 2: Test that small ROB causes IPC drop on long-iter loops**
- [ ] **Step 3: Commit**

---

## Task 17: Bypass network model

**Files:**
- Modify: `src/perfmodel/pipeline.py`
- Modify: `src/perfmodel/execute.py` (create)

Bypass: a producer's result is available to consumers in the SAME cycle (combinational forward) for ALU ops, +1 cycle for loads.  Vanilla = single bypass; v2 = full bypass mesh (modeled in Task 28).

- [ ] **Step 1: Implement BypassNetwork — producer broadcasts, consumers wake one cycle earlier**
- [ ] **Step 2: Test that ALU→ALU dependency chain runs at IPC 1.0 (back-to-back, no extra latency)**
- [ ] **Step 3: Commit**

---

## Task 18: Full vanilla 4-wide calibration

**Files:**
- Modify: `doc/calibration.md`
- Create: `scripts/calibrate_vs_rtl.py`

- [ ] **Step 1: Capture Spike traces for dhrystone + coremark from v2 ELFs**

```bash
bash scripts/gen_trace.sh /path/to/dhrystone.elf
bash scripts/gen_trace.sh /path/to/coremark.elf
```

- [ ] **Step 2: Run vanilla 4-wide on both; compare cycles to RTL golden**

```bash
python scripts/calibrate_vs_rtl.py --config baseline_vanilla_4wide.json \
                                    --traces traces/dhrystone.trace,traces/coremark.trace \
                                    --golden tests/golden/
```

Expected vanilla 4-wide vs 6-wide RTL:
  dhrystone: model should be ~1.5-2x slower than 6-wide RTL (no fusion, no LB, no UOC, no BPU)
  coremark:  model should be ~2-3x slower

This is the FLOOR.  Each Phase 3 opt closes the gap.

- [ ] **Step 3: Document deltas in calibration.md**

- [ ] **Step 4: Commit**

```bash
git add scripts/calibrate_vs_rtl.py doc/calibration.md
git commit -m "feat: vanilla 4-wide full calibration on dhry+cm"
```

**Phase 2 checkpoint** — review with user before proceeding.

---

# Phase 3 — V2 optimization stacking

For each existing v2 RTL optimization, add to model + isolated A/B measurement.  Stacking order = highest-RTL-impact first (per Task 2 audit).

Each opt task follows the same template:
  1. Write/extend opt module
  2. Add cfg flag to UarchConfig
  3. Wire into pipeline (gated by cfg flag)
  4. Test: A/B comparison on microkernel + dhry + cm
  5. Document delta in calibration.md
  6. Commit

The 12 v2 opts (per Task 2 audit), suggested order:

| # | Opt | Module | Expected RTL impact |
|---|---|---|---|
| 19 | TAGE-SC-L (already in T2 — verify) | bpu.py | -50% mispredicts |
| 20 | NLPB (next-line prefetch) | fetch.py | -8% icache miss |
| 21 | Multi-port BTB indexing (pc[13:6]) | bpu.py | -3% mispredict |
| 22 | 3-IQ × 2-select (replaces single-IQ) | issue.py | +0.5 IPC |
| 23 | Speculative wakeup | issue.py | +0.2 IPC |
| 24 | 12R6W PRF (vs 6R3W) | rename.py | enables full IPC |
| 25 | Move elimination | rename.py | +0.05 IPC |
| 26 | Macro-op fusion | fusion.py | +5-10% on coremark |
| 27 | Loop buffer (gen-1) | loop_buffer.py | +20% on tight loops |
| 28 | Full bypass mesh + forwarding hold | execute.py | enables back-to-back |
| 29 | Dual BRU on IQ0 | execute.py | +0.1 IPC on cm |
| 30 | LSU port-1 misalign hold | lsu.py | -100% iter=10 hangs |
| 31 | µop cache (gen-2) | uop_cache.py | observer-only currently |

Each task ~1-2 days of implementation + measurement.

## Tasks 19-31 (templated, condensed)

For each opt, the steps are:

- [ ] **Step 1: Write the opt's module (or extend an existing one)**
- [ ] **Step 2: Add the corresponding flag (or param) to `UarchConfig`**
- [ ] **Step 3: Gate the opt's behavior on `cfg.<flag>` in the pipeline**
- [ ] **Step 4: Write test — A/B with flag on vs off**
- [ ] **Step 5: Generate measured delta on dhry + cm; record in calibration.md**
- [ ] **Step 6: Commit (per opt)**

Detailed per-opt sub-plans live in `doc/audit.md` (filled during Task 2).  Each opt becomes its own micro-plan.

## Task 32: Phase 3 final calibration

After all 12 opts stacked, the model should match RTL within **10% on dhrystone and coremark**.  If not, revisit individual deltas.

- [ ] **Step 1: Full calibration run with all v2 opts ON (V2_FULL_4WIDE config)**
- [ ] **Step 2: Compare to RTL golden (note: RTL is 6-wide, model is 4-wide — expect ~10-25% difference from width alone, not opt errors)**
- [ ] **Step 3: Build a 6-wide V2_FULL_6WIDE config; calibrate against RTL — this isolates the model accuracy from width**
- [ ] **Step 4: Document final calibration delta**
- [ ] **Step 5: Commit**

**Phase 3 checkpoint** — model is now calibrated.  Ready for sweeps.

---

# Phase 4 — Calibration + sweep

## Task 33: Sweep harness (parallel)

**Files:**
- Create: `scripts/sweep.py`

Generates a Cartesian or Pareto-aware grid of UarchConfig values; runs each on dhrystone + coremark + microkernel; collects results in CSV.  Parallelism via `concurrent.futures.ProcessPoolExecutor`.

- [ ] **Step 1: Implement sweep.py with axial sweep + reference points (mirror `gem5/study/scripts/sweep_4wide_parallel.py` shape)**
- [ ] **Step 2: Test on small grid (3 configs × 2 workloads = 6 sims)**
- [ ] **Step 3: Commit**

## Task 34: Run full 4-wide sweep

- [ ] **Step 1: Define grid: ROB {64, 96, 128, 160, 192} × PRF {96,128,160,192,224} × IQ {48,64,80,96} × ALU {2,3,4} × BTB {1k,2k,4k,8k}**

(Pareto-aware: anchor + axial first, then refine around top-5 configs.)

- [ ] **Step 2: Run in parallel — 12 workers × ~30s per sim**
- [ ] **Step 3: Save summary.csv to doc/results/4wide_sweep_<date>/**

## Task 35: Pareto analysis vs targets

- [ ] **Step 1: scripts/plot_pareto.py — scatter CM/MHz vs DMIPS/MHz, color by total area-cost (proxy = ROB*depth + PRF + IQ*depth)**
- [ ] **Step 2: Mark MegaBoom (4.0 / 6.2) and A72 (4.72 / 8.24) reference points**
- [ ] **Step 3: Identify smallest config that beats MegaBoom + matches A72**
- [ ] **Step 4: Document recommended config in doc/results/4wide_winner.md**

## Task 36: Validate winner against 6-wide V2 RTL

If the winner config beats 6-wide V2 in the model, run it for confidence as a 6-wide config too — sanity-check that narrowing isn't hiding a regression.

## Task 37: Phase 4 sign-off summary

- [ ] **Step 1: Write doc/results/sweep_summary.md — recommended 4-wide config, expected RTL projection, what the gap to A72 implies**

**Phase 4 checkpoint** — recommend RTL refactor or revisit.

---

# Phase 5 — New optimization exploration

## Task 38: Decoupled F2 fetch

Add F2 stage with independent PC counter (the prior session's #1 IPC fix).  Model the speculative advance + retreat.

- [ ] Standard 6-step opt template (per Task 19-31).

## Task 39: Multi-port BPU update

Today's BPU update is single-pick.  Multi-port = update all CFIs in commit batch in one cycle.

- [ ] Standard 6-step opt template.

## Task 40: Larger TAGE tables

Currently 4×256 entries.  Sweep 4×512, 4×1024, 5×512.  Expected: -1-2% mispredict at +area cost.

- [ ] Standard 6-step opt template.

## Task 41: F1 prefetch buffer

A 4-entry FIFO between icache response and F2.  Allows F1 to speculatively advance.

- [ ] Standard 6-step opt template.

## Task 42: Phase 5 summary

- [ ] **Step 1: Aggregate all new opts into a Pareto plot — IPC gain vs area cost**
- [ ] **Step 2: Pick top-3 to RTL-implement**
- [ ] **Step 3: Document in doc/results/new_opts.md**

---

# Phase 6 — Refactor uarch doc

## Task 43: Update rv64gc-v2 uarch spec

**Files:**
- Modify: `rv64gc-v2/doc/rv64gc_v2_uarch.md`
- Modify: `rv64gc-v2/CLAUDE.md`

- [ ] **Step 1: Update CLAUDE.md sign-off targets to industry units (CM/MHz ≥ 6.2 baseline, ≥ 8.24 stretch)**
- [ ] **Step 2: Update uarch doc § Performance Targets table**
- [ ] **Step 3: Add § Pivot 6→4 Wide Decision with model-derived rationale**
- [ ] **Step 4: Update § Modules to Build for the chosen 4-wide config**
- [ ] **Step 5: Commit**

## Task 44: Save project memory + close out

- [ ] **Step 1: Update `~/.claude/projects/.../memory/MEMORY.md` to reflect post-pivot state**
- [ ] **Step 2: Commit perf-model workspace + push**

---

## Self-Review

**Spec coverage:** Every phase target in the user's requirements is covered:
- ✓ Vanilla 4-wide OoO baseline first → Phase 1
- ✓ Audit existing v2 optimizations → Task 2
- ✓ Stack optimizations and measure → Phase 3
- ✓ MegaBoom baseline + A72 stretch targets → Header + Task 35
- ✓ Industry-style perf model (not gem5) → Phase 0 methodology, language choice
- ✓ Refactor uarch doc → Phase 6

**Placeholders:** Several Phase 3 opt tasks are templated rather than fully expanded — this is intentional because the per-opt sub-plan depends on Task 2 audit findings.  Phase 3 opens with audit-derived ordering and detail.  Acceptable given checkpoint review at end of each phase.

**Type consistency:** UarchConfig field names (pipe_width, rob_depth, etc.) used consistently across config.py, pipeline.py, sweep.py.  InsnRecord fields used consistently in trace.py and pipeline.py.  No method-name drift detected.

---

## Execution Handoff

Plan complete and saved to `doc/perfmodel_coding_plan_2026-04-25.md`.  Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.  Best for learning since you can review and adjust between each task.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batched with checkpoint reviews.

**Which approach?**

Given the plan spans ~8 weeks of work and you said you want to LEARN performance modeling, my recommendation is:

- **Phase 0 + Phase 1 inline** in this session (so you see the model take shape, the calibration discipline, the test rhythm) — that's ~Tasks 1-11
- **Phases 2-6 subagent-driven** with phase-end checkpoints (so you can review delta after each chunk and the agent handles the boilerplate)

But you decide.

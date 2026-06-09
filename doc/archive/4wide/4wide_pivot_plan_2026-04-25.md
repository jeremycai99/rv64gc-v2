# rv64gc-v2 4-wide Pivot Plan — 2026-04-25

## Decision

Narrow rv64gc-v2 from **6-wide → 4-wide**, in place. User-approved 2026-04-25
after measurement showed 6-wide v2 (5.83 CM/MHz) loses to 4-wide Reference Core A (large config)
(~6.2 CM/MHz). Per-slot efficiency: 0.97 vs 1.55 — width is wasted by
front-end starvation, not consumed by issue/execute.

## Sign-off targets (revised, industry units)

| Tier | CM/MHz | DMIPS/MHz | Comparison |
|---|---:|---:|---|
| Baseline must-match | ≥ 6.2 | ≥ 4.00 | Reference Core A (large config) (4-wide) |
| **Sign-off (must beat)** | **≥ 8.24** | **≥ 4.72** | a commercial 3-wide OoO core (3-wide OoO) |

Old IPC targets (CM ≥ 2.5, DS ≥ 3.2) **superseded**. Sign-off authority is
dsim/xsim measurement (same class as Reference Core A's Verilator → directly comparable).

## Methodology (industry-style model stack)

Active flow uses `rv64gc-perf-model` plus dsim/xsim RTL measurement.
`rv64gc-gem5` is historical/inactive unless explicitly reactivated.

1. **Phase 0 — model and trace readiness**
   - Calibrate the 6-wide RTL baseline in `rv64gc-perf-model` against
     Dhrystone, CoreMark iter=1, CoreMark iter=10, and small microbenches.
   - Compare counters, not just cycles: fetch/commit histograms, branch
     misses, flush/replay counts, IQ/LQ/SQ/ROB/free-list stalls, and cache
     behavior.
   - Add `dep.v1` and `pipe.v1` RTL traces per
     `rv64gc-perf-model/doc/trace_schema.md`.
   - Add `rtl_clockcheck.py` for deterministic microbench refactor checks.
2. **Phase 1 — perf-model parameter discovery**
   - Sweep 4-wide candidates in `rv64gc-perf-model`: ROB, PRF, IQ count/depth,
     LQ/SQ, ALU/BRU/CDB width, L1D banks, uop-cache and frontend options.
   - Pick Pareto candidates that meet or plausibly close on CM/MHz ≥ 6.2 and
     DMIPS/MHz ≥ 4.00 before RTL edits.
   - Require a bottleneck-counter explanation for every selected candidate.
3. **Phase 2 — staged RTL refactor in place**
   - Change `PIPE_WIDTH=4` only after Phase 1 has a candidate.
   - Cascade dependent params per the model-picked candidate.
   - Touch hardcoded 6-slot constructs in small module groups.
   - After each group, run build + clockcheck microbenches before full
     benchmark runs.
4. **Phase 3 — full dsim/xsim regression and calibration**
   - Functional regression must pass.
   - Dhrystone, CoreMark iter=1, and CoreMark iter=10 must STOP cleanly.
   - CM/MHz and DMIPS/MHz measured on dsim/xsim are official.
   - Compare model prediction vs RTL measurement and update calibration docs.

## RTL refactor scope

**Files containing PIPE_WIDTH** (19 — the easy path: param flows through):
```
include/rv64gc_pkg.sv      — define
include/uarch_pkg.sv       — uses for typedefs (decoded_insn_t array sizes)
core/rv64gc_core_top.sv    — many instantiation widths
core/decode/decode.sv
core/decode/fusion_detector.sv
core/rename/rat.sv
core/rename/rename.sv
core/rename/free_list.sv
core/rename/checkpoint.sv
core/dispatch/dispatch_queue.sv
core/backend/rob.sv
core/backend/commit.sv
core/lsu/lsu.sv
core/lsu/load_queue.sv
core/lsu/store_queue.sv
core/loop_buffer.sv
core/fetch/fetch_unit.sv
core/fetch/uop_cache.sv
core/fetch/uop_cache_data_ram.sv
```

**Param table changes** in `rv64gc_pkg.sv` (driven by Phase 0 winner):

| Param | Current | Target (typical 4-wide) |
|---|---:|---:|
| PIPE_WIDTH | 6 | 4 |
| FETCH_BYTES | 24 | 16 |
| ROB_DEPTH | 192 | 128 |
| ROB_IDX_BITS | 8 | 7 |
| INT_PRF_DEPTH | 256 | 160 |
| PHYS_REG_BITS | 8 | 8 (unchanged) |
| FP_PRF_DEPTH | 128 | 96 |
| LQ_DEPTH / SQ_DEPTH | 64 / 64 | 32 / 32 |
| LQ/SQ_IDX_BITS | 6 / 6 | 5 / 5 |
| IQ_INT_DEPTH | 32 | 24 |
| NUM_INT_IQS | 3 | 2 (or 3 — Phase 0 sweep) |
| NUM_ALU | 4 | 3 |
| CDB_WIDTH | 6 | 4 |
| NUM_BYPASS_SRCS | 6 | 4 |
| L1D_BANKS | 4 | 2 (matches dispatch) |

**Module-level rewrites required** (not just param-driven):

| Module | Change | Effort |
|---|---|---|
| `int_prf` | 12R6W → 8R4W (port count down 33%) | M (port-list rewrite) |
| `bypass_network` | 6 srcs → 4 (24 muxes vs 48) | M |
| `rv64gc_core_top` rename mux | 6 slots → 4 | L |
| `dispatch_queue` arbitration | 6-wide round-robin → 4-wide | L |
| `issue_queue` × 3 | Re-balance load between IQs (or drop IQ2) | M |
| `dcache` 4-bank → 2-bank arbitration | M |
| `rob` 192 → 128 (idx bits 8→7) — affects everywhere ROB_IDX_BITS used | M |
| `fetch_unit` extract 4-wide insn slots | L (mostly param-driven) |
| `loop_buffer` capture/replay 4-wide | L |
| `uop_cache*` sizing (32×8×4 instead of 32×8×6) | L (param) |
| `tb_top.sv` PERF_PROFILE | L |

**Files NOT changed**:
- `lsu.sv` port-1 misalign hold patch — keep (sign-off-class win for iter=10)
- `cache/icache*`, `cache/dcache_*ram` — independent of pipe width
- ALU implementations — independent
- BPU (TAGE, BTB, RAS) — independent of dispatch width

## Risk / mitigation

| Risk | Mitigation |
|---|---|
| Many sites break at once after PIPE_WIDTH change → days of debug | Stage edits per-module; build after each; only enter regression after entire core compiles |
| Functional 18/18 PASS lost during transition | Branch first (`git checkout -b 4wide-pivot`); keep 6-wide RTL stable on main |
| Performance worse than model prediction | Calibrate counters first; if gap >20%, identify the missing bottleneck model before continuing |
| Clockcheck diverges unexpectedly | Stop at the first divergence; either fix RTL or add an explicit expected-delta rule for intentional resource changes |
| Phase 1 finds no 4-wide candidate beating Reference Core A (large config) baseline | Halt before RTL touch; revisit frontend, BPU, uop-cache, or decoupled F2 options in the model |

## Done criteria

- [ ] Phase 0: `dep.v1` and `pipe.v1` trace capture specified and clockcheck plan documented
- [ ] Phase 1: perf-model sweep identifies a 4-wide candidate with bottleneck-counter rationale
- [ ] Phase 1: 18/18 functional regression PASS at 4-wide
- [ ] Phase 1: dhrystone, coremark iter=1, coremark iter=10 all PASS at STOP
- [ ] Phase 2: clockcheck microbenches pass or all divergences are documented expected deltas
- [ ] Phase 3: dsim/xsim CM/MHz ≥ 6.2 + DMIPS/MHz ≥ 4.0 (Reference Core A (large config) baseline)
- [ ] Phase 3: dsim/xsim CM/MHz ≥ 8.24 + DMIPS/MHz ≥ 4.72 (commercial 3-wide OoO stretch sign-off) **OR** documented gap-closing follow-up plan
- [ ] CLAUDE.md updated with new sign-off targets + 4-wide rationale
- [ ] `doc/rv64gc_v2_uarch.md` updated to 4-wide spec

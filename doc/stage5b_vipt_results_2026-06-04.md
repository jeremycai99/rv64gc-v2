# Stage 5b — VIPT Instruction Fetch: Results

**Date:** 2026-06-04
**Outcome:** **SHIPPED.** True VIPT (virtually-indexed, physically-tagged) L1 instruction
fetch lands the paged-mode IPC win with zero benchmark regression.

## Headline

| Metric | Pre-VIPT (RC) | Post-VIPT | Δ |
|---|---|---|---|
| Paged-mode fetch translation stall (`fe_stall_xlate`) | ~47% of cycles | **~0 (literally 1)** | eliminated |
| Paged-mode IPC (steady-state) | 0.90 | **2.24** | **~2.5×** |
| Paged-mode IPC (full-boot mean) | 0.90 | **1.37** | +52% |
| CoreMark | 6.8515 CM/MHz | **6.8516** | +0.001% (no regression) |
| Dhrystone-300 | 4.2731 DMIPS/MHz | **4.2731** | 0.00% (cycle-identical) |
| RV64GC compliance | 113/113 | **113/113** | maintained |
| Linux boot | BOOT OK | **BOOT OK** | maintained |

The original Stage 5 goal — "good at the normal (paged) workload, not just benchmarks" —
is met: paged fetch now runs at ~the bare-metal rate, and the benchmark wins are untouched
(both still beat BOOM's 6.2 / 3.93 floor).

## What was built

1. **8-way 32 KB L1I geometry** (was 4-way) → 4 KB/way = 64 sets, index `addr[11:6]`
   entirely within the 4 KB page offset → alias-free VIPT, no capacity loss. 7-bit
   tree-PLRU. Independently benchmark-neutral (+0.001% CoreMark).
2. **VIPT index/tag split** in the icache: index the SRAM with the VA (`addr[11:6]`,
   == PA bits within the page offset) while tag-comparing against the physical address
   (`req_pa`). MSHR/fill carry the PA.
3. **F0/F1 fetch pipeline** — the structural fix that made VIPT possible:
   - **F0** (combinational, feed-forward): drives the live ITLB lookup + icache index from
     the live fetch address, and always advances. No translation stall in F0.
   - **F1** (registered): makes the translation hit/miss decision from a registered bundle
     `{pc, owner, itlb_hit, itlb_pa, itlb_fault}`, does packet/FTQ commit, and on a miss
     issues a **redirect-on-miss replay** (refetch the missed VA after the PTW fill, with
     an FTQ-epoch bump to discard the speculatively-advanced fetches).
   - The miss decision lives in the registered F1, so it no longer feeds the same-cycle F0
     address → the combinational loop is broken **by pipeline structure**.

## Why the pipeline rebuild was necessary (the disproven shortcuts)

The naive VIPT (stall on live `itlb_hit`) creates a combinational loop:
`instr_translation_stall → fe_stall → next-PC/straddle/will_emit → ITLB VA → itlb_hit →
instr_translation_stall`. It is dormant at satp=0 (so compliance + signoff pass) and
non-converges the instant Sv39 paging arms (DSim IterLimit at the identical tick for
-iter-limit 1M and 10M; Verilator UNOPTFLAT = 16 loops vs a 15 baseline, the extra net
being `instr_translation_stall`). Three single-register cuts were each disproven:

| Attempt | Loop | VIPT win |
|---|---|---|
| both live (naive) | ❌ loops | ✅ |
| register the ITLB hit result | ✅ broken | ❌ PIPT (stalls every fetch) |
| register the access PC (`ic_access_pc_r`) | ✅ broken (UNOPTFLAT 15) | ❌ PIPT (ITLB lags f1) |
| **F0/F1 pipeline (shipped)** | ✅ broken | ✅ **true VIPT** |

The conflict is fundamental: the stall must judge the *live* address's hit in the *same*
cycle the icache indexes it — that simultaneity is both the loop and the VIPT win, so no
single register can separate them. Only a structural pipeline stage does.

A late counter bug also masked success once: `f1_xlate_miss_c` was captured every paged
cycle (incl. stall cycles where no real fetch issued), so a frozen f1_pc_r on a
not-yet-filled VA re-presented as a miss every cycle → `fe_stall_xlate` read ~lookups
(PIPT signature) even though the structure was correct. Fix: gate the F1 miss-capture on
`req_valid_i` (a real issued fetch). Root-caused via a 3-agent analysis workflow.

## Method notes (what kept the campaign honest)

- **Verilator UNOPTFLAT as a pre-boot gate.** Every loop-affecting change was checked for
  16→15 (loop gone) BEFORE spending an ~11 h boot. `scripts/lint_unoptflat.sh`.
- **The VIPT-vs-PIPT discriminator:** `fe_stall_xlate ≈ itlb_misses` (≈hundreds = VIPT) vs
  `≈ itlb_lookups` (≈100k+ = PIPT regression). This single ratio caught two failed attempts.
- **Cross-check counters against ground truth.** A workflow concluded "stuck PTW" from
  `ptw_busy_cycles=1M`, but `minstret` advancing + boot reaching Linux proved the PTW was
  fine — `ptw_busy_cycles` is the known-broken Stage-5 counter. Avoided a phantom fix.
- **Always `--build-sim` for Linux runs.** One boot ran a 2-day-stale image (benchmark vs
  Linux images are separate artifacts); caught by timestamp check before drawing a wrong
  conclusion.

## The new bottleneck (next campaign)

Post-VIPT, the dominant paged-mode stall is now **`fe_stall_backend` = 23.1M cycles**
(3.4× the next, `fe_stall_icache` 6.7M; `fe_stall_xlate` = 1). Fetch is no longer the
limiter — the back-end is. Root sub-cause is **unmeasured** (ROB-full vs IQ-full vs
FTQ-full vs the load-port-1-disabled-in-paged-mode structural limit). The disciplined next
step is a sim-only backend-stall-attribution + per-type-mispredict + load-port-1-suppress
instrumentation pass (the Stage-5 pattern: instrument before building), run on a sustained
workload (boot idles into a timer loop — a Tier-2 userspace workload would be more
representative).

## Files

- `src/rtl/core/include/rv64gc_pkg.sv` — L1I_WAYS 4→8.
- `src/rtl/core/cache/icache.sv`, `icache_tag_ram.sv`, `icache_data_ram.sv` — 8-way +
  7-bit PLRU + VIPT index/tag split.
- `src/rtl/core/frontend/ifu/ifu_line_fetch.sv` — F1 bundle, miss decision, replay.
- `src/rtl/core/frontend/ifu/ifu.sv` — F0 feed-forward; translation_stall out of fe_stall.
- `src/rtl/core/frontend/top/fetch_top.sv`, `rv64gc_core_top.sv` — replay wiring.
- `scripts/lint_unoptflat.sh` — the Verilator combinational-loop oracle.

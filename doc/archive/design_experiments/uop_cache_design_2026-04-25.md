# µop Cache Design — Spec, 2026-04-25

Replacement of the gen-1 loop buffer (`loop_buffer.sv`, 64 µops, capture/
arm/replay/abort lifecycle) with a gen-2 PC-indexed µop cache, modeled
after Intel DSB / AMD Zen op cache / ARM Mop cache. Goal: close the
remaining IPC gap to sign-off (CoreMark ≥ 2.5, Dhrystone ≥ 3.2) and
retire the LB-class structural-bug surface (CDB→bypass→AGU comb-loop
family).

---

## Quick resume — read this first if context was compressed

**What this is:** the active µop cache project for rv64gc-v2. User
approved the design 2026-04-25 in a brainstorming session; implementation
plan in `doc/uop_cache_implementation_plan_2026-04-25.md`.

**Why µop cache, not the other 2 candidates:** TAGE V3 (mispredict
reduction) and F1 prefetch buffer (Dhrystone fetch bubble) are bonus
features, applied only AFTER µop cache lands. See § 5.2 Phase 4.

**Current LB-only baselines (must not regress under `+UOC_ENABLE`):**
- Dhrystone (iter=100): timed cyc 17,732 / instret 47,029 / **IPC 2.652** / DMIPS/MHz 3.21
- CoreMark iter=1: timed cyc 174,055 / instret 318,367 / **IPC 1.829** / 5.745 CM/MHz
- CoreMark iter=10: timed cyc 1,705,142 / instret 3,183,607 / **IPC 1.866** / 5.866 CM/MHz, 0 watchdog fires

**Sign-off targets:** CoreMark ≥ 2.5, Dhrystone ≥ 3.2 (per `CLAUDE.md`).

**Gate criteria for LB removal (Phase 3) — concrete IPC tiers:**

| Bench | Floor (FAIL) | Wash | Success target | Stretch |
|---|---:|---:|---:|---:|
| Dhrystone | < 2.55 | 2.55–2.65 | **2.86** | 3.06 |
| CM iter=1 | < 1.78 | 1.78–1.85 | **1.99** | 2.14 |
| CM iter=10 | < 1.83 | 1.83–1.90 | **2.05** | 2.20 |

Plus inviolable: 18/18 functional regression PASS, all 3 benches
STOP-OK, no IterLimit, no new watchdog fires.

**Architecture in one paragraph:** Per-fetch-group indexed cache,
32 sets × 8 ways × 6 µops = **1,536 µops** post-fusion, sync-read SRAM
(mirror `icache_tag_ram.sv` / `icache_data_ram.sv`), F0 lookup / F1
hit-data / F2 mux to rename input. Fill on miss at end of F2,
pseudo-LRU replacement, flat invalidate on FENCE.I/MRET/SRET/SFENCE.VMA.
LB stays in tree as parallel path under `+UOC_ENABLE` gate; LB clock-
gated when µop cache active (strict A/B for clean comparison).

**What this session shipped (the win we keep):** `lsu.sv` port-1
misalign hold register (the LB iter=10 patch). Brought CoreMark iter=10
from BROKEN (IterLimit abort cyc 316,161) to PASS at IPC 1.866 with
0 watchdog fires. Do NOT revert.

**What this session attempted and reverted (do NOT redo without
significant redesign):**
- TAGE serializer V1 (full FIFO replacing pickers): broke mispredict-
  first priority → Dhrystone -60% IPC. Reverted.
- TAGE serializer V2 (additive overflow with "skip first"): wrong
  index skipped → re-trained the picked CFI as overflow → CoreMark
  -0.5% IPC. Reverted.
- `+FETCH_PACKET_BYPASS2*` plusarg variants: zero help in steady-state.
- `+LB_ALLOW_COND_CHAIN_ALL`: TIMEOUT + 10 watchdog fires.

**Validated facts to assume true:**
- BTB index-mismatch bug from CLAUDE.md is FIXED (commit `0a3ca2f`,
  both lookup and update use `pc[13:6]`). Don't try to "fix" it again.
- xsim and dsim agree exactly on IPC (validated this session via
  CM iter=1 cross-check: both reported 1.813401). dsim is not
  pessimistic.
- Mispredict overhead ~28% of CoreMark cycles. Frontend bubble ~25%
  of Dhrystone cycles (after LB absorbs 17%). Total fetch=0 = 42%.
- LB capture-abort rate 38% on CoreMark. The lifecycle complexity
  is the structural problem the µop cache eliminates.

**First implementation step when resuming:** see implementation plan;
TL;DR Phase 1a is `uop_cache_tag_ram.sv` + `uop_cache_data_ram.sv`
(mirror icache RAM templates) with a small standalone testbench.

---

## 1. Motivation

### Why now
- Current IPC after the LB iter=10 patch (commit pending): CoreMark
  iter=10 = 1.866, Dhrystone = 2.652. Sign-off targets unmet by
  ~21–34%.
- LB has known structural problems documented in `doc/rv64gc_v2_uarch.md`
  § 4.10: 38–57% capture-abort rate, lifecycle complexity that has
  produced two comb-loop bugs already (Verilator convergence-limit
  history; the iter=10 IterLimit at cyc 316,161).
- Industry has standardized on PC-indexed µop caches (Intel DSB since
  Sandy Bridge, AMD Zen op-cache, ARM Cortex-A77+ Mop cache, Apple M
  series). The gen-1 LB approach is deprecated.
- Sub-agent gap analysis shows mispredict overhead ~28% of CoreMark
  cycles and frontend bubble ~25% of Dhrystone cycles — both addressed
  by µop cache + later TAGE V3 + F1 prefetch.

### What this delivers
- Replaces LB with a 32-set × 8-way × 6-µop = **1,536 µop** PC-indexed
  cache, sync-read SRAM, post-fusion µops, fill-on-miss with pseudo-LRU.
- Eliminates LB lifecycle (capture/arm/replay/abort/exit-pred) and the
  bug class it introduced.
- Preserves the LB code as a fallback during the parallel-path phase;
  retires it after data-driven validation.
- Adds telemetry (8 PERF_PROFILE counters + hot-PC histogram) and 5
  validation plusargs.
- Sets the stage for two follow-on bonus features: (a) TAGE V3
  serializer with picked-index tracking, (b) F1 prefetch buffer.

## 2. Scope and non-goals

In scope:
- µop cache RTL (lookup, fill, replacement, invalidation)
- Parallel-path coexistence with LB via `+UOC_ENABLE`
- Telemetry counters + validation plusargs
- Regression script extension (`scripts/regress_dsim.sh --uoc-compare`)
- Phase 4 LB removal once the µop cache wins on data
- Phase 5 (a) TAGE V3 + (b) F1 prefetch buffer (after µop cache lands)

Not in scope:
- Per-PC variable-width indexing (Intel DSB style) — fetch-group
  granularity for v1; revisit later if hit-rate analysis warrants.
- Multi-port BPU update (`btb.sv` + `tage_sc_l.sv` extension) — large
  separate project, not coupled to µop cache.
- Decoupled F2 fetch — parallel project; µop cache hit subsumes most
  of its win.
- Coherent multi-core invalidation — single-core scope.
- ASID / page-table tag inclusion — single address-space scope.

## 3. Architecture

### 3.1 Pipeline placement

```
F0:  PC gen + BPU lookup
     |  +--------------+
     |  | µoc tag/data |  <-- new: lookup initiated here
     |  | SRAM addr    |
     |  +--------------+
     |  +--------------+
     |  | icache lookup|  <-- existing
     |  +--------------+
F1:  +--------------+  hit/miss decided here
     | µoc tag-match|  data on output of SRAM (sync read)
     | hit?         |
     +--------------+
     | icache resp  |
     | + predecode  |
F2:  hit  -> deliver µoc data to rename input mux (skip decode+fusion)
     miss -> decode + fusion runs as today; on completion, schedule
             speculative fill into µoc (sync write at F2+1)
Rename: gets fused µops one cycle earlier on µoc hit
```

Net latency win on hit: 1 cycle (skip the F2 decode+fusion stage).

### 3.2 Storage parameters

| Parameter | Value | Source |
|---|---:|---|
| Sets (`UOC_SETS`) | 32 | Intel DSB Sandy Bridge baseline |
| Ways (`UOC_WAYS`) | 8 | same |
| µops per entry (`UOC_PER_ENTRY`) | 6 | matches `PIPE_WIDTH` |
| Total µop capacity | 1,536 µops | Sandy Bridge precedent |
| Tag width | `64 - $clog2(UOC_SETS) - $clog2(FETCH_GROUP_BYTES)` ≈ 54 bits | tag = upper PC bits |
| Index width | 5 bits | `$clog2(UOC_SETS)` |
| Replacement state | 7 bits per set (binary tree pseudo-LRU) | proven |
| Storage rough order | ~16 KB data + ~2 KB tag + ~28 B pLRU | SRAM-class |

### 3.3 New modules

| File | Role | Template |
|---|---|---|
| `src/rtl/core/fetch/uop_cache.sv` | Top: lookup orchestration, hit/miss, fill control, pLRU, invalidation, telemetry | new |
| `src/rtl/core/fetch/uop_cache_tag_ram.sv` | Sync-read tag SRAM (32×8 × tag bits) | mirror `icache_tag_ram.sv` |
| `src/rtl/core/fetch/uop_cache_data_ram.sv` | Sync-read data SRAM (32×8 × payload of decoded_insn_t × PIPE_WIDTH + count) | mirror `icache_data_ram.sv` |

### 3.4 Modified modules

| File | Change |
|---|---|
| `src/rtl/core/include/uarch_pkg.sv` | Add `UOC_SETS=32`, `UOC_WAYS=8`, `UOC_PER_ENTRY=6`, `UOC_INDEX_BITS=5`, `UOC_TAG_BITS`, `UOC_PAYLOAD_BITS` derived constants |
| `src/rtl/core/rv64gc_core_top.sv` | (a) instantiate `uop_cache`; (b) extend rename-input mux from 2-way (lb/fused) to 3-way (uoc/lb/fused); (c) gate LB inputs/outputs to '0 when `+UOC_ENABLE` is set; (d) wire UOC counters out to tb |
| `src/rtl/core/fetch/fetch_unit.sv` | Forward F0 PC and F2 fused-output to the µop cache; receive µoc-hit-bypass signal back |
| `src/tb/tb_top.sv` | Add 8 UOC counters to PERF_PROFILE histogram block |
| `scripts/regress_dsim.sh` | Add `--uoc-compare` flag |

### 3.5 SRAM discipline (mandatory)

Both new RAM modules MUST follow the icache RAM template exactly:
- Address registered: `addr`, `wen`, `wdata`, byte mask
- Output port is registered (1-cycle sync read)
- No combinational read paths
- Data array `ifdef SIMULATION` zero-init (matches commit 8e280c6 icache pattern); production builds rely on the valid bit, no reset on the data array
- Document in CLAUDE.md § "ASIC-Correct Reset Discipline" that
  `uop_cache_data_ram` joins the no-reset list

Reason: at ~16 KB data + ~2 KB tag, this is firmly in SRAM-macro
territory; flop arrays of this size are unbuildable in tapeout.

## 4. Operations

### 4.1 Lookup (every cycle when `+UOC_ENABLE`)

- F0: f1_pc → `uoc_index = f1_pc[UOC_INDEX_BITS+offset-1:offset]`,
  `uoc_tag_in = f1_pc[63:UOC_INDEX_BITS+offset]`
- Tag SRAM and data SRAM both addressed in F0
- F1: tag SRAM returns up to 8 stored tags; comparator finds matching
  way; data SRAM returns up to 8 ways of payload; way-select mux
- F1 outputs: `uoc_hit`, `uoc_hit_count`, `uoc_hit_data[PIPE_WIDTH-1:0]`
- F2 mux: if `uoc_hit && +UOC_ENABLE`, drive rename input from uoc_hit_data; else fall through to fused_insn (decode path) or 0 (under bru_redirect_quarantine)

### 4.2 Fill (on miss, end of F2)

- Trigger: F2 completes a fetch group (fusion done) AND prior cycle's
  `uoc_hit` was 0 for the same group's start PC
- Write target way: pLRU-selected victim way in the indexed set
- Write at posedge clk: tag, valid bit, count, payload
- Update pLRU bits for the set (chosen way now the most-recently-used)
- Single fill port per cycle. If two consecutive cycles both miss with
  fills queued, the second waits one cycle (rare in practice; flag as
  a counter `uoc_fill_stall` — added if it shows up).

### 4.3 Invalidation (flat)

Triggered by:
- Commit of `FENCE.I`: clear all valid bits
- Commit of `MRET` / `SRET` / `SFENCE.VMA`: clear all valid bits
  (covers context switch / TLB shootdown — code may have changed)
- `rst_n` deassert: clear all valid bits

Not triggered by:
- Branch mispredict / BRU flush
- ROB exception / replay
- Speculative-but-squashed µops

Implementation: 32×8 = 256 valid bits in a flop array (separate from
data SRAM). Flat clear is one cycle of all-zero broadcast.

### 4.4 Replacement (pseudo-LRU)

- 7 bits of pLRU state per set (binary tree pLRU for 8 ways)
- Updated on every hit (lookup) and every fill (write)
- Victim selected by walking pLRU tree from root

### 4.5 Bandwidth

- Lookup: 1 per cycle (F0 issues, F1 resolves)
- Fill: 1 per cycle (no contention with lookup — separate logical port,
  but in practice same SRAM banks; double-pumped or 1R+1W SRAM macro)
- Hit data delivery: up to PIPE_WIDTH (6) µops per cycle to rename
  input — same as fetch_unit's max emit rate

## 5. Coexistence and migration

### 5.1 Parallel path under `+UOC_ENABLE`

| `+UOC_ENABLE` setting | LB state | µop cache state | rename input source |
|---|---|---|---|
| absent (default OFF) | active (current behavior) | inactive (lookup gated, fill gated) | lb_insn OR fused_insn (existing 2-way mux) |
| present (ON) | clock-gated: dec_count forced 0, lb_active forced low | active: lookup, fill, invalidate all running | uoc_hit_data OR fused_insn (LB path dead, only 2 of 3 mux inputs live) |

Strict A/B: under `+UOC_ENABLE` the LB hardware is silent. No captures,
no replays, no contention. Comparison data is unambiguous.

### 5.2 Migration phases

- **Phase 0 (this spec)** — design approved
- **Phase 1** — RTL implementation in parallel-path form
  - 1a: SRAM modules (tag + data); standalone testbench passes
  - 1b: `uop_cache.sv` top module integrated into `rv64gc_core_top.sv`;
    LB clock-gating wired; default OFF
  - 1c: full functional regression with `+UOC_ENABLE` (all rv64ui_*,
    bench_*, dhrystone, coremark iter=1, iter=10)
- **Phase 2** — validation + tuning
  - Run `scripts/regress_dsim.sh --uoc-compare` to produce LB-vs-UOC
    side-by-side
  - Compare to tier-gate criteria (§ 6.2)
  - Tune parameters if needed (associativity, capacity)
- **Phase 3** — LB removal (data-driven gate; user approves)
  - Decision: based on Phase 2 numbers vs gate criteria, user
    explicitly authorizes LB removal
  - Delete `loop_buffer.sv`
  - Remove `LB_*` plusargs from `loop_buffer.sv` and `tb_top.sv`
  - Remove LB-related telemetry from `tb_top.sv` PERF_PROFILE
  - Strip `lb_active`/`lb_insn`/`lb_count` from `rv64gc_core_top.sv`
    (rename mux back to 2-way: uoc/fused)
  - Make `+UOC_ENABLE` always-on (remove gating) OR rename to
    `+UOC_DISABLE` for emergency override
  - Update `doc/rv64gc_v2_uarch.md` § 4.10 to describe the µop cache
    (rename section title)
  - Update `CLAUDE.md` ground rules / known-issues
- **Phase 4 (optional bonuses)** — if Phase 3 lands cleanly
  - **(a) TAGE V3** — track picker's chosen index in `rv64gc_core_top.sv:3683-3780`,
    skip exactly that index in any future overflow FIFO. Estimated +0.1–0.3 CoreMark IPC.
    Validate via same regression rule (no regression on Dhrystone).
    ~30–50 LOC.
  - **(b) F1 prefetch buffer** — add small FIFO between icache resp and
    F2 stage in `fetch_unit.sv`; F1 advances PC speculatively when buffer
    has slots. Estimated +0.1–0.3 Dhrystone IPC. ~80–120 LOC.

## 6. Telemetry, plusargs, and gate criteria

### 6.1 Telemetry (extend `tb_top.sv` PERF_PROFILE block)

| Counter | Definition |
|---|---|
| `uoc_lookup_total` | every cycle the µop cache is queried |
| `uoc_lookup_hit` | tag matched a valid entry |
| `uoc_lookup_mid_group_miss` | miss because lookup PC ≠ any stored group-start PC (informs whether per-PC indexing would help) |
| `uoc_fill_count` | fills attempted |
| `uoc_fill_evict_valid` | fills that evicted a valid entry (conflict-miss indicator) |
| `uoc_invalidate_count` | flat invalidates triggered (FENCE.I / mode change) |
| `uoc_active_cycles` | cycles where µop cache drove the rename input |
| Top-N hot-PC hit histogram | mirror of TAGE hot-PC summary; shows which PCs are most-cached |

Headline metric: **hit rate = `uoc_lookup_hit / uoc_lookup_total`**.

### 6.2 Plusargs

| Plusarg | Behavior |
|---|---|
| `+UOC_ENABLE` | master switch (default OFF in Phase 1; default ON post-Phase 3 LB removal) |
| `+UOC_DISABLE_FILL` | lookup runs but fills skipped (cache stays empty → 0% hit rate; sanity check that lookup wiring is alive) |
| `+UOC_FORCE_FLUSH=N` | flat invalidate every N cycles (exercises invalidation path under stress) |
| `+TRACE_UOC` | per-cycle prints of {sim_cycle, lookup_pc, hit, way, fill_pc, fill_way} (gated by simple cycle-range filter) |
| `+UOC_DISABLE_INVALIDATE` | sim-only — skip FENCE.I-driven invalidation (catches stale-cache bugs in self-modifying-code tests) |

### 6.3 Tier-gate criteria for LB removal (the data that justifies Phase 3)

Per benchmark, against current LB-only baselines (Dhrystone 2.597, CM
iter=1 1.813, CM iter=10 1.866):

| Tier | Range | Action |
|---|---|---|
| Hard regression floor | IPC drops by more than 2% | **PROJECT FAILS** — revert µop cache, keep LB, document why |
| Wash zone | IPC within ±2% of baseline | µop cache delivers no perf win; user decides whether the LB-bug-class elimination justifies architectural cleanup |
| Project success target | IPC ≥ baseline × 1.10 (+10%) | clear LB removal data; ship Phase 3 |
| Stretch | IPC ≥ baseline × 1.18 (+18%) | meaningfully closing sign-off gap |

| Benchmark | Floor (< this = FAIL) | Wash | Success (≥ this = ship) | Stretch |
|---|---:|---:|---:|---:|
| Dhrystone | 2.55 | 2.55–2.65 | **2.86** | 3.06 |
| CoreMark iter=1 | 1.78 | 1.78–1.85 | **1.99** | 2.14 |
| CoreMark iter=10 | 1.83 | 1.83–1.90 | **2.05** | 2.20 |

Plus inviolable functional gates (no exceptions, hard fail if violated):
- 18/18 rv64ui_* / bench_* tests must PASS
- All three benchmarks must reach STOP cleanly (control=2 written, flags=0)
- No new watchdog fires beyond baseline (currently 0 on iter=10 with
  the LB patch)
- No `IterLimit` aborts on dsim under any plusarg combination

## 7. Testing strategy

### 7.1 Unit tests (Phase 1a)

- New testbench for `uop_cache_tag_ram.sv`: write/read/byte-mask/reset
- New testbench for `uop_cache_data_ram.sv`: same
- Standalone `tb_uop_cache.sv` for the top module: synthetic lookup/
  hit/miss/fill/evict/invalidate sequences

### 7.2 Integration tests (Phase 1c)

- Run `scripts/regress_dsim.sh --func` with `+UOC_ENABLE`: 18/18 PASS
  required (any FAIL = revert)
- Run `scripts/regress_dsim.sh --bench` with `+UOC_ENABLE`: all three
  benchmarks must reach STOP cleanly

### 7.3 Validation tests (Phase 2)

- New flag `scripts/regress_dsim.sh --uoc-compare`: runs each benchmark
  twice (off, on) and prints side-by-side delta in markdown. This is
  the data file the user reviews before Phase 3 authorization.
- Hit-rate sanity (`+UOC_DISABLE_FILL` = 0% hit rate confirmed)
- Invalidation correctness (`+UOC_FORCE_FLUSH=10000` = high invalidate
  count; benchmarks still PASS)
- Self-modifying-code regression: write a small test that issues
  FENCE.I and re-executes modified code; verify correct semantics
  with and without `+UOC_DISABLE_INVALIDATE`

### 7.4 Cleanup tests (Phase 3 LB removal)

- After deleting LB code, repeat full regression. All gate criteria
  still met = removal validated.

## 8. Risks and open questions

### Risks
- **Tag width on PC**: 54 bits of tag per entry × 256 entries = ~13.8 Kbits
  of tag SRAM. Manageable, but tag SRAM read latency must match data SRAM.
  Both should use the same SRAM-macro template.
- **Mid-group hit rate**: per-fetch-group means lookup PC must match
  group-start. If FTQ delivers mid-group entries frequently, hit rate
  suffers. Mitigation: counters `uoc_lookup_mid_group_miss` will
  expose this; per-PC indexing is a v2 fallback if mid-group misses
  dominate.
- **Fill bandwidth contention**: speculative fill on miss could collide
  with concurrent lookup of a different set. Sync read + sync write to
  separate banks should resolve; flag if `uoc_fill_stall` shows up.
- **pLRU under bursty access**: if working set fits in 8 ways, pLRU is
  fine; if it exceeds, conflict misses rise. Counters expose this.
- **Speculative fill of wrong-path code**: caches mispredict-shadow
  µops. Bounded by pLRU eviction (correct-path code wins the way back).
  Industry standard; proven OK.

### Open questions
- Should we pre-warm the µop cache on boot (e.g., during reset)? Probably no — first-time-through code should miss, fill, then hit on subsequent passes. Boot rarely re-executes.
- Do we need per-context invalidation (ASID)? No for this scope; flat invalidate on context switch is correct (single-core, single context typically).
- Is `UOC_PER_ENTRY=6` always sufficient? `PIPE_WIDTH=6`, so a fetch group emits at most 6 µops. Yes.

## 9. Cleanup discipline (per user direction)

Once µop cache lands and Phase 3 LB removal is authorized:

| Item | Action |
|---|---|
| `loop_buffer.sv` | DELETE the file |
| `tests/asm/test_lb_*` (if any) | DELETE |
| `tb_top.sv` LB telemetry block | DELETE |
| `tb_top.sv` LB plusargs (`+DISABLE_LB`, `+LB_*`) | DELETE |
| `rv64gc_core_top.sv` LB instantiation, mux input, gating | DELETE |
| `rv64gc_v2_uarch.md` § 4.10 | REWRITE as "µop cache" section |
| `CLAUDE.md` known-issues mentioning LB | UPDATE |
| Validation plusargs (`+UOC_DISABLE_FILL`, `+UOC_FORCE_FLUSH`, `+TRACE_UOC`, `+UOC_DISABLE_INVALIDATE`) | KEEP if they cost zero RTL area (sim-only); REMOVE if they cost area |
| `+UOC_ENABLE` | RENAME to `+UOC_DISABLE` (default ON, opt-out for emergencies) OR remove entirely if confidence is high |

## 10. References

- `doc/rv64gc_v2_uarch.md` § 4.10 (current LB) and § 9.1 (planned µop cache migration — this spec realizes it)
- `doc/ralph_loop_session_2026-04-25.md` — gap analysis, why µop cache is the right next move
- `doc/dsim_first_repro_2026-04-24.md` — current LB-only IPC baseline
- `src/rtl/core/cache/icache_tag_ram.sv` and `icache_data_ram.sv` — RAM templates
- `src/rtl/core/loop_buffer.sv` — what gets retired
- `src/rtl/core/include/uarch_pkg.sv` — package edits
- `src/rtl/core/rv64gc_core_top.sv:402-416` — current rename input mux
- Industry references: Intel Sandy Bridge DSB papers, AMD Zen op-cache slides, ARM Cortex-A78 Mop cache docs

# µop Cache Implementation Plan — 2026-04-25

Concrete, ordered, post-context-compression executable plan for the µop
cache project. Companion to spec at `doc/uop_cache_design_2026-04-25.md`
(read its "Quick resume" first).

## Quick resume — read this first if context was compressed

This is the implementation plan for replacing the gen-1 loop buffer
(`src/rtl/core/loop_buffer.sv`) with a gen-2 PC-indexed µop cache.
Design approved 2026-04-25. The current LB iter=10 patch in `lsu.sv`
must NOT be reverted (it's the only sign-off-class win we have).

**TL;DR ordering:**
1. Phase 1a: build the two SRAM modules (mirror icache RAMs) + standalone unit tb. ~1-2 days.
2. Phase 1b: build `uop_cache.sv` top + integrate into `rv64gc_core_top.sv` behind `+UOC_ENABLE`. LB stays as fallback. ~3-5 days.
3. Phase 1c: full functional regression with `+UOC_ENABLE` (18/18 PASS required). ~half day.
4. Phase 2: A/B regression (`scripts/regress_dsim.sh --uoc-compare`); compare to tier-gate criteria. ~1-2 days for tuning if needed.
5. Phase 3 (gated by data): user authorizes; remove LB code, doc updates. ~half day.
6. Phase 4 (optional): TAGE V3 (~1 day) and F1 prefetch buffer (~3-5 days) post-µop-cache. Each independent A/B regression.

**Hard rules:**
- All RTL changes require regression PASS (18/18 functional + 3 benches STOP-OK + IPC ≥ baseline) before declaring done.
- Tier gate criteria for shipping LB removal: see spec § 6.3.
- Use sync-read SRAM ONLY for both new RAMs (no flop arrays).
- LB removal happens ONLY after user explicit authorization based on the data table from `--uoc-compare`.

## Files to create

| Path | Purpose | Estimated LOC |
|---|---|---:|
| `src/rtl/core/fetch/uop_cache_tag_ram.sv` | sync-read tag SRAM, 32 sets × 8 ways × ~54-bit tag + valid | ~150 |
| `src/rtl/core/fetch/uop_cache_data_ram.sv` | sync-read data SRAM, 32 sets × 8 ways × (PIPE_WIDTH × decoded_insn_t bits + count) | ~200 |
| `src/rtl/core/fetch/uop_cache.sv` | top: F0 lookup, F1 hit, F2 mux + fill, pLRU, invalidation, telemetry counter outputs | ~400 |
| `src/tb/tb_uop_cache.sv` | standalone unit tb for `uop_cache.sv` (lookup/hit/miss/fill/evict/invalidate sequences) | ~250 |

## Files to edit

| Path | Change | Estimated LOC delta |
|---|---|---:|
| `src/rtl/core/include/uarch_pkg.sv` | Add `UOC_SETS=32`, `UOC_WAYS=8`, `UOC_PER_ENTRY=6`, `UOC_INDEX_BITS=5`, `UOC_TAG_BITS`, `UOC_PAYLOAD_BITS`, `UOC_PLRU_BITS=7` | +15 |
| `src/rtl/core/rv64gc_core_top.sv` | (a) instantiate `uop_cache`; (b) extend rename input mux from 2-way (lb/fused) to 3-way (uoc/lb/fused); (c) gate LB inputs/outputs to '0 when `+UOC_ENABLE`; (d) wire UOC counter outputs to tb | +60 |
| `src/rtl/core/fetch/fetch_unit.sv` | (a) forward F0 PC to `uop_cache`; (b) forward F2 fused output to `uop_cache` for fill; (c) accept `uoc_hit_bypass` signal back | +40 |
| `src/tb/tb_top.sv` | Add `+UOC_ENABLE`, `+UOC_DISABLE_FILL`, `+UOC_FORCE_FLUSH`, `+TRACE_UOC`, `+UOC_DISABLE_INVALIDATE` plusargs; add 8 UOC counters to PERF_PROFILE block | +80 |
| `scripts/regress_dsim.sh` | Add `--uoc-compare` flag (runs each bench twice and prints A/B delta in markdown table) | +60 |
| `CLAUDE.md` | Add line to "ASIC-Correct Reset Discipline" noting `uop_cache_data_ram` joins no-reset list | +1 |

## Files to delete (Phase 3 only — gated by user authorization on data)

| Path | Why |
|---|---|
| `src/rtl/core/loop_buffer.sv` | Retired; µop cache subsumes |
| LB sections of `tb_top.sv` (LB telemetry, LB plusargs) | Not needed |
| `tests/asm/test_lb_*.S` (if any exist) | LB-specific |

Plus edits:
- `src/rtl/core/rv64gc_core_top.sv`: strip `loop_buffer u_loop_buffer (...)` instantiation; mux back to 2-way (uoc/fused)
- `doc/rv64gc_v2_uarch.md` § 4.10: rewrite as "µop cache" section
- `CLAUDE.md`: remove LB-related known issues

## Phase 1: RTL (parallel path)

### Phase 1a — RAM modules (foundation)

1. Read template: `src/rtl/core/cache/icache_tag_ram.sv` and
   `src/rtl/core/cache/icache_data_ram.sv`. Note their port lists,
   addr/wen/wdata pipelining, sync-read pattern, `ifdef SIMULATION`
   data-array zero-init.
2. Create `src/rtl/core/fetch/uop_cache_tag_ram.sv`. Same port shape
   as `icache_tag_ram.sv` but parameters: 32 sets, 8 ways per set,
   `UOC_TAG_BITS` width per way + 1 valid bit.
3. Create `src/rtl/core/fetch/uop_cache_data_ram.sv`. Port shape:
   one read port (lookup) + one write port (fill). 32 sets, 8 ways,
   `UOC_PAYLOAD_BITS` per way (= `PIPE_WIDTH * $bits(decoded_insn_t) + 3` for count).
4. Create `src/tb/tb_uop_cache.sv` standalone testbench:
   - reset → all valid bits clear
   - write set 0 way 0 with known tag/data → read back next cycle (sync read)
   - write set 0 ways 0..7 with different tags → read all back
   - flat invalidate → all hits become misses
   - sync-write conflict: write same set/way two cycles in a row
5. Build with dsim: `./build_dsim.sh` succeeds.
6. Run unit tb: `./run_dsim.sh tests/hex/<unit_test>.hex 1000` (or whatever shim makes sense — may need a minimal tb hex bridging the unit tb to the existing flow). Targets: every read returns the value written one cycle prior; invalidate clears all entries.

Exit criteria: unit tb passes, build clean, no Verilator/dsim warnings.

### Phase 1b — `uop_cache.sv` top + integration

1. Create `src/rtl/core/fetch/uop_cache.sv`:
   - Inputs: `clk`, `rst_n`, `en` (from `+UOC_ENABLE`), `lookup_pc`, `fill_valid`, `fill_pc`, `fill_data` (decoded_insn_t × PIPE_WIDTH), `fill_count`, `invalidate`
   - Outputs: `hit`, `hit_count`, `hit_data` (decoded_insn_t × PIPE_WIDTH), telemetry counters (8)
   - Internal: tag-RAM instance, data-RAM instance, pLRU bits per set (256-bit total = 32 sets × 8 bits, but binary tree pLRU only needs 7 bits per set = 224 bits), valid bits per set/way (256 bits), invalidation logic
   - F0: address SRAMs with `lookup_pc[INDEX]`
   - F1: 8 tag comparators, hit-way mux on data SRAM output, drive `hit`/`hit_data`/`hit_count`
   - Fill: at posedge clk, when `fill_valid`, write tag/data to pLRU-victim way, update pLRU bits, set valid bit
   - Invalidate: at posedge clk, when `invalidate`, clear all 256 valid bits, no SRAM write needed
2. Edit `src/rtl/core/include/uarch_pkg.sv` to add UOC parameters.
3. Edit `src/rtl/core/rv64gc_core_top.sv`:
   - Add `bit sim_uoc_enable; initial sim_uoc_enable = $test$plusargs("UOC_ENABLE");`
   - Instantiate `uop_cache u_uop_cache (...)` after the existing `loop_buffer u_loop_buffer`
   - Wire `uoc.lookup_pc <= f1_pc`; wire `uoc.fill_*` from F2 fused output; wire `uoc.invalidate <= commit-side flat-invalidate trigger`
   - Modify the rename input mux at lines 402–416: extend to 3-way:
     ```sv
     if (bru_redirect_quarantine) ... '0
     else if (sim_uoc_enable && uoc_hit) ... uoc_hit_data
     else if (lb_active) ... lb_insn
     else ... fused_insn
     ```
   - Gate LB: when `sim_uoc_enable`, force `loop_buffer.dec_count <= 0` and ignore `lb_active`/`lb_insn` outputs by the mux above
4. Edit `src/rtl/core/fetch/fetch_unit.sv`:
   - Add output port `f1_pc_for_uoc` (already have `f1_pc` internal; just expose)
   - Receive `uoc_hit_bypass` from above; when bypass active, suppress F2 decode/fusion writeback to dispatch (avoid double-emit). Note: F2 decode still RUNS in parallel (we can't predict the bypass before F1's data is back); the writeback path is what gets gated.
5. Edit `src/tb/tb_top.sv`:
   - Add 8 UOC counters to PERF_PROFILE block
   - Add 5 plusargs (gated `initial` blocks)
   - Add hot-PC histogram for UOC hits (mirror TAGE hot-PC structure)
6. Build dsim: `./build_dsim.sh`. Resolve any compile errors.

Exit criteria: build clean. `dsim_work/tb_image.so` produced.

### Phase 1c — Functional regression

1. Default-OFF baseline first: `./scripts/regress_dsim.sh --func` → must
   match prior 18/18 PASS (sanity that integration didn't break existing flow).
2. With `+UOC_ENABLE`: `./scripts/regress_dsim.sh --func --extra-plusargs "+UOC_ENABLE"` → must also be 18/18 PASS. Any FAIL = blocker, do NOT proceed.

Exit criteria: 36/36 PASS (18 with UOC off, 18 with UOC on).

## Phase 2: validation + tuning

1. Implement `--uoc-compare` flag in `scripts/regress_dsim.sh`:
   - For each benchmark: run twice (once without `+UOC_ENABLE`, once with)
   - Output a markdown table comparing IPC, cycle count, instret, watchdog fires, mispredicts
2. Run `./scripts/regress_dsim.sh --uoc-compare`. Capture the table.
3. Compare each row to tier-gate criteria from spec § 6.3:
   - HARD FAIL on any benchmark below floor → ABORT, dig into the regression cause
   - All in WASH/SUCCESS/STRETCH → present to user with the table
4. If hit-rate is low (`uoc_lookup_hit / uoc_lookup_total < 50%`), check the `uoc_lookup_mid_group_miss` counter; if it dominates, consider per-PC indexing as a v2 tuning.
5. If `uoc_fill_evict_valid` rate is high (>30% of fills), capacity may be too small; consider growing to 64 sets × 8 ways.
6. Re-run as needed until either: (a) tier-gate criteria all SUCCESS or STRETCH (proceed to Phase 3), OR (b) it's clear µop cache won't beat LB (back out and document).

Exit criteria: data table presented to user, decision made.

## Phase 3: LB removal (gated by user authorization)

1. User reviews `--uoc-compare` table; explicitly authorizes LB removal.
2. Delete files / edit per the "Files to delete" + "edits" tables above.
3. Make `+UOC_ENABLE` always-on (e.g., default `sim_uoc_enable = 1`) OR add `+UOC_DISABLE` opt-out.
4. Re-run full regression: `./scripts/regress_dsim.sh` → must still pass all gate criteria with LB code gone.
5. Update `doc/rv64gc_v2_uarch.md` § 4.10 to describe µop cache (rename section title).
6. Update `CLAUDE.md` to remove LB-related known issues.
7. Commit (user's existing rule: only commit when requested — flag for user authorization separately).

Exit criteria: LB code gone, regression still passes all gate criteria, docs updated.

## Phase 4: bonus features (optional, if Phase 3 cleanly lands)

### Phase 4a — TAGE V3 (mispredict reduction)

1. Read `src/rtl/core/rv64gc_core_top.sv` lines 3683–3780 (existing pickers).
2. Add a `picked_btb_idx` and `picked_tage_idx` set in each picker (when `found_update = 1'b1`, also set `picked_btb_idx = i;`).
3. Add an additive overflow FIFO that pushes CFIs from the commit batch SKIPPING `picked_btb_idx` and `picked_tage_idx`.
4. FIFO drain only when picker picked nothing this cycle.
5. Build, regress with `--uoc-compare` shape but on the V3 toggle. Tier gate: must NOT regress Dhrystone, must show ≥ 0% IPC change on CoreMark (no regression). Ideally +0.1 IPC on CoreMark.

Exit criteria: regression PASS with no Dhrystone regression; CoreMark IPC delta documented.

### Phase 4b — F1 prefetch buffer

1. Read `src/rtl/core/fetch/fetch_unit.sv` around the F1/F2 stage interaction.
2. Add a small FIFO (4 entries) between the icache response and the F2 stage.
3. F1 advances PC speculatively when the FIFO has slots; retreats on F2 mismatch.
4. Build, regress. Tier gate: must NOT regress CoreMark; ideally Dhrystone +0.1–0.3 IPC.

Exit criteria: regression PASS with no CoreMark regression; Dhrystone IPC delta documented.

## Risks and abort conditions

- **dsim license: 1 lease only.** Use `xsim_parallel/` for parallel xsim builds during long dsim runs. xsim build script exists at `build_xsim.sh`; runner at `run_xsim.sh`.
- **Stuck dsim license**: cloud lease can take 5+ min to free after process death. If `Lease acquisition denied`, wait 60s and retry. Don't `pkill -f` patterns that match the parent shell (have hit this twice this session).
- **Unexpected RTL convergence loops**: the LB-class comb-loop family. If µop cache integration causes new IterLimit aborts, investigate via the existing `+TRACE_*` plusargs before adding new ones.
- **Tag width math**: `UOC_TAG_BITS = 64 - UOC_INDEX_BITS - log2(fetch group base alignment)`. Confirm by example: if fetch_group is 32 bytes, low 5 bits are offset, next 5 bits are index, top 54 bits are tag.
- **Mid-group hit rate**: if benchmarks frequently land mid-group (e.g., from BPU-redirect targets that aren't group-aligned), per-fetch-group hit rate suffers. Counter `uoc_lookup_mid_group_miss` exposes this; if dominant, per-PC indexing is the v2 fix.

## Done checklist

- [ ] Phase 1a: RAM modules built, unit tb passes
- [ ] Phase 1b: top module built, integrated, default-OFF, `dsim_work/tb_image.so` clean
- [ ] Phase 1c: 36/36 functional regression PASS
- [ ] Phase 2: `--uoc-compare` table generated, presented to user
- [ ] Phase 3 (if user authorizes): LB code deleted, regression still passes
- [ ] Phase 4a (optional): TAGE V3 lands without regression
- [ ] Phase 4b (optional): F1 prefetch buffer lands without regression
- [ ] All cleanup done per spec § 9
- [ ] `doc/rv64gc_v2_uarch.md` § 4.10 rewritten
- [ ] `CLAUDE.md` updated

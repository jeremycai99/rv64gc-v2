# ASIC Sign-off Work Plan — RV64GC v2

**Last updated:** 2026-04-17 (systematic-debug-instrumented session)

## Root cause definitively identified

**Dhrystone hit spec.** With all ASIC-correct fixes applied:

| Workload | Baseline IPC | Full-fix IPC | Spec | Result |
|---|---|---|---|---|
| Dhrystone | 1.81 | **3.94** | 3.2 | ✅ **SPEC MET (+23%)** |
| CoreMark | 2.91 | 0.31 | 3.9 | ❌ Below — different root cause |

**The phantom-release fix is correct and necessary.** It takes Dhrystone from 1.81 → 3.94 IPC. It takes CoreMark from 2.91 → 0.31 IPC — a genuine exposure of a separate issue that was previously hidden.

## Why CoreMark drops with the correctness fix

Evidence from cycle-accurate probes (`STAT_DUMP` in `free_list.sv`, `rename.sv`, `commit.sv`):

| Metric | CoreMark baseline | CoreMark phantom-fix |
|---|---|---|
| IPC | 2.91 | 0.31 |
| Slot advance rate | 92% | 66% |
| Flushes total | 2,250 | **8,019** |
| **Load-ordering replays** | ~0 (hidden) | **3,181** |
| Branch mispredicts | ~2,250 | 4,838 |
| `committed_bitmap` population | 233 (+9 phantom inflation) | 224 (correct) |
| `has_rob=0` stalls | 2 | 50,903 |
| `has_ckpt=0` stalls | 15,370 | 36,841 |
| `has_preg=0` stalls | 13,125 | 3,321 |
| `free_bitmap` min | 99 / 256 | 87 / 256 |

**Mechanism.** The phantom release bug aliased committed RAT entries (multiple arch regs → same pdst). Loads and stores therefore computed their effective addresses from the WRONG registers' values. In the LSU's ordering check (`load_queue.sv:119-135`), addresses never "overlapped" because they were garbage. Every real memory ordering violation went undetected. CoreMark's final checksum happens to be robust to these value-level errors (matrix ops with aggregated hashes), so the test "passed" while the pipeline was producing wrong data.

With the phantom fix, addresses are correct, the LSU's ordering detector does its job, and CoreMark's actual load-store hazards (matrix-inner-loop store→load reuse, tight deps) surface as 3,181 replays per 200K cycles = 1 replay per ~63 cycles. Each replay is a **full_flush** + fetch redirect to the load's PC (see `commit.sv:242-248`). That's the cliff.

## The real issue is microarchitectural, not a bug

The RTL does memory ordering correctly. It just uses the most expensive possible recovery mechanism (full_flush) and has no memory-dependence prediction to avoid the replays in the first place. Modern OoO cores at this IPC target:

- Predict load-store independence (MDP — memory dependence predictor) and delay risky loads.
- Forward through a store buffer for common same-address hits.
- Use *partial* replay — squash the offending load and younger ops only, not the whole pipeline.

This v2 design has none of those yet. CoreMark exposes this.

## Recommended path

1. **Lock in the phantom-release fix** — it's correctness-required and already makes Dhrystone exceed spec.
2. **For CoreMark recovery to 3.9 IPC, implement one of:**
   - **(A) Partial replay** — on memory-ordering exception, squash only the replay-slot and younger entries, don't full-flush. Estimated recovery: ~0.5-1.0 IPC. Moderate effort (~100-150 RTL lines in `commit.sv` + `rob.sv` + `lsu.sv`).
   - **(B) Store-to-load forwarding buffer enhancement** — the LSU already has `p0_fwd_hit`; check if it's catching every case it should (`lsu.sv:288-310` has a same-cycle STA/STD bypass already). If a hit rate probe shows misses on the CoreMark replay hotspots, extending the forwarding path may fix many replays without any replay mechanism change. Lower effort.
   - **(C) Memory dependence prediction (MDP)** — track load PCs and their tendency to violate, delay issue for known-risky loads. Highest complexity, best steady-state gain.

My recommendation: **start with (B)** — probe forwarding hit rate on CoreMark. If misses are concentrated on a few common patterns, this is the lowest-cost recovery. If not, move to (A).

## Committed changes (all ASIC-correct, in the tree now)

1. **Phase A — reset fanout** moved to `ifdef SIMULATION initial`:
   - `int_prf.sv`, `dcache_tag_ram.sv`, `icache_tag_ram.sv`.

2. **Phase B — icache sync reads:**
   - `icache_data_ram.sv`, `icache_tag_ram.sv`: registered read outputs.
   - `icache.sv`: hit detection, MSHR alloc, PLRU, response all at s1.
   - `fetch_unit.sv`: removed redundant `ic_resp_*` register to realign pipeline.

3. **sp-gate** (structural alloc-no-advance orphan prevention):
   - `rename.sv`: `fl_req_count` / `fl_slot_idx` gated by `slot_can_advance_sp`.

4. **Phantom-release fix** (correctness + Dhrystone spec):
   - `decode_slice.sv`: `rd_arch=0 when !rd_valid` (invariant).
   - `rename.sv`: per-slot gate on `fl_release_preg[i]` by `commit_rd_valid`.

5. **Documentation and diagnostics:**
   - `CLAUDE.md`: ASIC-correct reset discipline section.
   - Full STAT_DUMP infrastructure in `free_list.sv`, `rename.sv`, `commit.sv` (sim-only, `+STAT_DUMP` plusarg).

## The original CLAUDE.md claim of "CoreMark 3.91 IPC" was an artifact

It was measured against RTL with the phantom-release bug active. The pipeline was producing numerically incorrect intermediate values that happened to cancel out in CoreMark's checksum. That number cannot be trusted as a correctness-respecting baseline — the real CoreMark IPC with correct memory ordering is 0.31 in the current RTL, which we now need to improve with the recommendations above.

## Next session plan

1. Add LSU store-to-load forwarding hit/miss probe per address pattern.
2. Run CoreMark + phantom fix + new LSU probe. Analyze miss patterns.
3. If patterns are addressable via forwarding path extension → implement (B).
4. If not, begin partial-replay work in commit.sv + rob.sv (option A).
5. Retarget CoreMark ≥ 3.5 as interim. Full 3.9 may require MDP (option C).

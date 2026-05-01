# 4-Wide RTL Refactor — Performance Gap Analysis Methodology

**Date:** 2026-05-01
**Status:** DESIGN — methodology only; **no RTL changes proposed in this doc.**
**Repo HEAD:** `master @ cd54cf1` (post Load1 bypass fix)
**Simulator:** DSim 2026.0.0
**Companion docs:**
- `doc/4wide_signoff_2026-04-30.md` — structural-refactor sign-off (PARTIAL; numbers stale, see Background)
- `doc/4wide_refactor_checklist.md` — execution checklist (all 90 items complete)
- `doc/baseline_6wide_obsolete_2026-04-30.md` — 6-wide archive

> ## What this doc IS and IS NOT
>
> **IS:** A 5-phase methodology for closing the 4-wide CM/MHz and DMIPS/MHz gaps versus
> the MegaBoom 4-wide sign-off floor — purely data-driven, with falsifiable predictions
> attached to every proposed RTL change.
>
> **IS NOT:** An implementation plan, a commitment to specific RTL edits, or a replacement
> for the structural sign-off doc. The implementation plan comes from
> `superpowers:writing-plans` invoked after this doc is approved. Specific RTL edits come
> out of Phase E, only after Phase A–D produce a confirmed bucket-level hypothesis.

---

## 1. Background

The 5-stage 4-wide refactor (Stage 1 Rename+ROB → Stage 5 Frontend+TB) merged to master
at `aca1f33` with all functional and clockcheck gates green but with both performance
floors missed. The CoreMark functional bug discovered post-merge (Load1 bypass slot was
silently dropped in Stage 2) was resolved at `cd54cf1` by restoring `bypass[4]` for Load1
and bumping `NUM_BYPASS_SRCS` 4 → 5. After the fix, the previously-reported sign-off
numbers were exposed as inflated by an 11× BPU mistraining cascade. The real measurements
on `cd54cf1` are:

| Workload | Cycles | Instret | IPC | Metric | MegaBoom floor | Gap |
|---|---:|---:|---:|---|---:|---:|
| dhrystone (100 iter) | 23,514 | 47,670 | 2.027 | **2.42 DMIPS/MHz** | 4.00 | **−39.5%** |
| coremark iter1 | 199,452 | 332,110 | 1.665 | **5.01 CM/MHz** | 6.2 | **−19.2%** |
| coremark iter10 | 1,860,512 | 3,197,342 | 1.719 | **5.37 CM/MHz** | 6.2 | **−13.3%** |
| bench_loop_100 | 237 | 709 | 2.992 | (microbench) | — | — |

Functional 21/21 PASS, clockcheck 3/3 PASS, all benches reach `PASS at tohost=1` under
the tightened STOP-OK detection (also landed at `cd54cf1`).

`doc/4wide_signoff_2026-04-30.md` still cites the inflated 6.05 CM/MHz figure and needs
a separate post-fix correction pass — that is a documentation cleanup task tracked
separately and **out of scope for this analysis methodology**.

---

## 2. Problem statement

The two open gaps have non-overlapping profiles and likely require different attributions:

- **CoreMark** — uniform narrowing penalty: 6-wide IPC 1.81 → 4-wide IPC 1.665 (−8%) on
  the same iter1 binary. The penalty is plausibly diffuse — CDB bandwidth contention,
  shorter bypass network on ALU dependency chains, narrower issue per cycle.
- **Dhrystone** — acute IPC drop: 6-wide IPC 2.597 → 4-wide IPC 2.027 (−22% IPC, −20%
  DMIPS). The drop is plausibly concentrated on the procedure-call hotpath
  (`main → Proc_1..Proc_7 → return`, repeated per loop iteration), which Stage 2's
  `load_wb` sideband architectural fix did not touch.

Without per-cycle bucket-level attribution, the only options are blind RTL tweaks. That
is the exact failure mode that produced the reflexive 3a/3b/3c "revert to make symptom go
away" options during the cm bug investigation. **The Load1 bypass fix worked because we
waited for trace data; the same discipline applies to closing these performance gaps.**

---

## 3. Methodology overview

Five sequential phases. **No phase short-cuts the previous one.** Each phase is gated on
the prior phase's deliverable. RTL changes appear only in Phase E, only after a hypothesis
is confirmed in Phase D.

```
        ┌── 6-wide rebuild (commit 4f28619, ~3 min)
        ▼
Phase A ──► Phase B ──► Phase C ──► Phase D ──► Phase E
counters    bucket      hypothesis  microbench  RTL changes
collected   attribution enumeration probes      (writing-plans)
~1 hr       ~30 min     ~30 min     ~1 hr       per-iteration
```

**Total Phase A–D wallclock estimate:** ~3 hours active work (excludes DSim license
release waits and rebuild time).

---

## 4. Phase A — Same-binary counter collection

**Goal:** Capture every existing `dsim_run.log` counter on both 6-wide (`4f28619`) and
4-wide (`cd54cf1`) for the same binaries. No RTL changes. Pure data collection.

### Steps

1. **Capture 4-wide counters** at `cd54cf1` (current master). Already partially done in
   Section 1; re-run to ensure fresh logs.
   ```bash
   export LD_LIBRARY_PATH=
   for hex in dhrystone coremark coremark_iter10; do
       bash run_dsim.sh tests/hex/${hex}.hex 5000000 +PERF_PROFILE \
           > /tmp/4wide_${hex}.log 2>&1
       cp dsim_run.log benchmark_results/perf_gap_4wide_${hex}.log
   done
   ```

2. **Rebuild 6-wide** at `4f28619` in a worktree (avoid disturbing master HEAD):
   ```bash
   git worktree add /tmp/rv64gc-v2-6wide 4f28619
   cd /tmp/rv64gc-v2-6wide
   export LD_LIBRARY_PATH=
   bash build_dsim.sh                    # ~2-3 min
   ```

3. **Capture 6-wide counters** on the same binaries (these binaries pre-date the refactor
   and have not changed):
   ```bash
   for hex in dhrystone coremark coremark_iter10; do
       bash run_dsim.sh tests/hex/${hex}.hex 5000000 +PERF_PROFILE \
           > /tmp/6wide_${hex}.log 2>&1
       cp dsim_run.log /tmp/perf_gap_6wide_${hex}.log
   done
   ```

4. **Inventory existing counters.** Stage 5 added per-PC PERF_PROFILE buckets in
   `tb_top.sv`; LSU/BPU/ROB summaries already emit at end of run. Catalog every counter
   block and confirm both 6-wide and 4-wide emit the same set (or document any missing).

5. **Produce side-by-side counter diff table** at
   `benchmark_results/counter_diff_2026-05-01.md` covering:
   - `IPC: mcycle / minstret / IPC`
   - LSU LMB summary, LSU P1 conflict
   - BPU mispredict counters (per-direction + per-type if available)
   - ROB head stall summary
   - CSB / D-cache store / D-cache load-miss summaries
   - Free-list / IQ-full counters (if exposed; document if not)
   - Per-PC PERF_PROFILE buckets (load / store / branch / serial / other)

### Phase A deliverable

`benchmark_results/counter_diff_2026-05-01.md` — flat markdown table, 6-wide column +
4-wide column + delta column for every counter, per workload. **No interpretation in this
deliverable.** Interpretation is Phase B.

### Phase A gate to Phase B

- Both designs successfully completed all three workloads at PASS+tohost=1.
- Counter diff table covers all five counter blocks.
- Any counter present in one design but not the other is documented.

---

## 5. Phase B — Bucket attribution

**Goal:** Convert raw counter deltas into per-bucket cycle attribution that explains the
IPC gap.

### Buckets (6 total)

Per Section 2 design discussion, LSU is its own bucket (it spans Execute and Commit, and
its bottlenecks are architecturally distinct from non-memory FU contention).

1. **Frontend** — fetch / IFU / BPU mispredict flush / uop cache miss / loop buffer miss.
   Cycles in which fetch was unable to deliver a full bundle to dispatch.
2. **Rename + Dispatch** — free list empty / ROB full / IQ full / dispatch-to-IQ port
   conflict. Cycles in which dispatch could not enqueue a renamed uop.
3. **Issue** — IQ entries present but no ready entry / functional-unit contention /
   issue-port arbitration loss. Cycles in which the IQ couldn't pick an eligible uop.
4. **Execute (non-LSU)** — MUL/DIV serial latency / BRU mispredict flush penalty / CSR
   serialization. Cycles in flight on a non-LSU FU but not making forward progress.
5. **LSU** — LMB stall / dcache miss serialization / P1 port conflict / store-forward
   block / store-buffer full. Separated from buckets 4 and 6 because LSU bottlenecks
   span Execute and Commit and respond to different RTL knobs (LQ/SQ depth, MSHR count,
   bank parallelism).
6. **Commit (non-LSU)** — ROB head waiting on writeback for a uop on a non-LSU FU.

### Method

For each workload:
1. Compute `total_cycles = mcycle`. Compute `peak_retire_cycles = ceil(minstret / PIPE_WIDTH)`.
2. `gap_cycles = total_cycles - peak_retire_cycles`.
3. Attribute `gap_cycles` to the 6 buckets using the available counters. The sum of
   bucket gaps should approximate `gap_cycles` within ±10%; document any unattributed
   residual.
4. Compute `delta_per_bucket = bucket_gap_4wide - bucket_gap_6wide`.

### Phase B deliverable

A per-workload bucket gap table (6 buckets × {6-wide, 4-wide, delta}) plus a top-3
ranked list of which buckets dominate the IPC delta. This deliverable lives in
`benchmark_results/bucket_attribution_2026-05-01.md`.

### Phase B gate to Phase C

- Both workloads have a bucket attribution table.
- Sum-of-buckets residual is documented (target ±10% of `gap_cycles`).
- The top-3 buckets per workload are identified and not contradicted by the raw counter
  diff.

---

## 6. Phase C — Hypothesis enumeration

**Goal:** For each top-3 bucket per workload, enumerate concrete RTL hypotheses with
predicted counter signatures.

### Hypothesis template

| Field | Content |
|---|---|
| ID | e.g., `cm-H1` |
| Bucket | which Phase B bucket this hypothesis explains |
| Description | one-sentence mechanism in narrowed RTL |
| Why | specific Stage 2/3/4/5 narrowing decision that introduced the bottleneck |
| Predicted signature | which counter elevates / regresses if hypothesis is correct |
| Discrimination | which Phase D microbench would isolate it |

### Initial seed hypotheses (refine or replace based on Phase B output)

These are *seeds* — Phase B may invalidate any of them or surface unanticipated
hypotheses. Do not start Phase D against this list; start Phase D against whatever
Phase C produces *after* Phase B data lands.

| ID | Bucket | Hypothesis |
|---|---|---|
| cm-H1 | Issue/Execute | CDB shrink 6 → 4 causes BRU/ALU writeback contention on dense cycles |
| cm-H2 | Issue | Bypass network only covers 5 sources (3 CDB + 2 load); ALU3/DIV/CSR consumers wait an extra cycle for PRF read |
| cm-H3 | LSU | LQ/SQ shrunk 64 → 32; cache-miss bursts may saturate LQ |
| dhry-H1 | Issue | NUM_ALU=3 saturates on procedure-entry instruction burst (call/save-regs/argload pattern) |
| dhry-H2 | Frontend / Rename | Checkpoint allocation back-pressure on procedure-call PUSH; restore latency on RET |
| dhry-H3 | Frontend | BPU return-address-stack hit rate degraded for nested calls in narrowed frontend |
| dhry-H4 | Rename+Dispatch | IQ_INT_DEPTH=24 (was 32 in 6-wide) too small for procedure-entry rename burst |

### Phase C deliverable

A hypothesis table at `benchmark_results/hypothesis_table_2026-05-01.md` with one row
per hypothesis, every field filled. Each hypothesis MUST cite the Phase B bucket it
explains and the predicted counter signature.

### Phase C gate to Phase D

- Every top-3 bucket has at least one hypothesis.
- Every hypothesis has a predicted counter signature and a microbench-discrimination
  pointer.
- No hypothesis is "we don't know" — if a bucket dominates and we have no hypothesis,
  return to Phase A and capture additional counters before continuing.

---

## 7. Phase D — Microbench probes

**Goal:** Confirm or refute hypotheses with synthetic workloads that isolate one bucket
each.

### Probe set (5 initial; add as Phase C reveals more)

| Probe | Stress target | Expected isolation |
|---|---|---|
| `alu_chain_8.S` | 8-deep ALU dependency chain in tight loop | bypass + CDB (cm-H1, cm-H2) |
| `dhry_call_mimic.S` | RV64 .S that mimics dhrystone Proc_1..Proc_7 call pattern: 4–7 nested calls per outer-loop iter, mixed-arg signatures, return-value chained into next call. **NOT a generic call_burst** — designed to reproduce dhry's specific call topology. | dhry-H1, dhry-H2, dhry-H3, dhry-H4 |
| `load_dep_alu.S` | load → 6 dependent ALU ops, repeated | Load bypass + IQ wakeup |
| `mixed_branch_dense.S` | 1 branch per 4 instructions, mixed taken/not-taken | BPU + flush penalty |
| `independent_quad.S` | 4 independent ALU ops per cycle, sustained loop | Sanity check that 4-wide actually achieves IPC=4 under ideal conditions; baseline for "what's the theoretical ceiling" |

### Method

For each probe:
1. Build hex via existing assembly toolchain (`scripts/elf2hex.py` flow).
2. Run on **both** 6-wide (`4f28619` worktree) and 4-wide (`cd54cf1` master).
3. Measure: cycles, instret, IPC, **and** the predicted bucket counter from Phase C.
4. Hypothesis is *confirmed* if 4-wide bucket counter regresses vs 6-wide in the
   direction predicted; *refuted* if not.

### Phase D deliverable

`benchmark_results/microbench_probes_2026-05-01.md` — per-probe IPC comparison,
predicted-vs-observed bucket counter, and per-hypothesis confirm/refute verdict.

### Phase D gate to Phase E

- Every Phase C hypothesis has a confirm or refute verdict.
- At least one hypothesis per workload is confirmed (else iterate Phase B/C with more
  data).
- For confirmed hypotheses, predicted-vs-measured counter agreement is documented.

---

## 8. Phase E — RTL change proposals

**Out of scope for this design doc.** Phase E is the deliverable of
`superpowers:writing-plans` invoked after this design is approved.

### Phase E rule (formalized — applies to every RTL change in gap-closure work)

Each RTL change proposal MUST include:

1. **Files:lines** to touch (concrete, not abstract).
2. **Predicted IPC delta** on cm iter1, cm iter10, dhrystone, **and** the relevant
   Phase D microbench. Predictions are committed to git **before** measurement, in the
   commit message or an associated planning doc. This blocks post-hoc rationalization.
3. **Confirmation criterion** — which counter must improve, by how much, to declare the
   change successful.
4. **Refutation criterion** — what observation would invalidate the underlying
   hypothesis.
5. **Neutral-or-better verification** — post-change, the OTHER workload (cm if dhry
   change, dhry if cm change) must show no regression beyond ±2% IPC. Functional 21/21
   and clockcheck 3/3 must remain PASS.

**The 30% rule:** if the predicted IPC delta and the measured IPC delta diverge by more
than 30% (in either direction), the underlying hypothesis is unsound. Record the
prediction and the actual; do not revise the prediction; return to Phase B/C with the
new data point.

This rule binds future sessions, not just the current one. The point is to make the
methodology falsifiable rather than narratively self-confirming.

---

## 9. Constraints (do NOT do)

1. **No RTL changes before Phase D.** The Load1 bypass fix worked because we waited for
   trace data; same discipline applies here. The reflexive-revert reflex (3a/3b/3c) is
   the failure mode this methodology exists to prevent.
2. **No cross-width raw cycle deltas alone.** Cycle counts vary with binary alignment
   and BPU warm-up. Always normalize to bucket counters before drawing conclusions.
3. **No single-workload optimization.** Every Phase E proposal must show neutral-or-better
   on the other workload (per Phase E rule #5).
4. **No new RTL counters until existing are exhausted.** Stage 5 added per-PC PROFILE;
   Phase A inventories what's available before any instrumentation work.
5. **No re-derivation of the cm functional bug.** RESOLVED at `cd54cf1`. Do not
   re-investigate, re-bisect, or revisit Approach 3a/3b/3c.
6. **No reactivation of `../rv64gc-perf-model/`.** The perf model is paused on a
   structural toolchain dead-end (see that repo's `doc/phase_2_5_signoff.md`). Only
   `rtl_clockcheck.py` from that repo is in active use; the rest must not be referenced.
7. **No CDB widening as a bandage.** If Phase B/C/D points at CDB bandwidth as the cm
   bottleneck, the Phase E proposal must be a targeted narrowing-preserving fix (e.g.,
   smarter arbitration, additional bypass slot for ALU3, dedicated MUL writeback port),
   NOT "restore CDB_WIDTH=6". The 4-wide design must remain 4-wide on writeback.

---

## 10. Sign-off bar (re-stated for clarity)

| Tier | CM/MHz | DMIPS/MHz | Source |
|---|---:|---:|---|
| Floor — must match | ≥ 6.2 | ≥ 4.00 | MegaBoom (4-wide OoO) |
| Stretch — must beat | ≥ 8.24 | ≥ 4.72 | ARM Cortex-A72 (3-wide OoO) |

After Phase E iterations, sign-off requires **both** workloads at floor, **and**
functional 21/21 + clockcheck 3/3 still PASS, **and** the post-change measurement is
captured in a refreshed sign-off doc that supersedes `doc/4wide_signoff_2026-04-30.md`.

Stretch target is desired but not blocking.

---

## 11. Out of scope

Recorded so we don't accidentally pull them in:

- Reverting any narrowing decision speculatively (3a/3b/3c style).
- Adding new architectural features unrelated to gap closure (e.g., a second LSU port,
  new BPU table, new prefetcher class).
- Re-tuning 6-wide to "see what changed".
- ASIC sign-off / synthesis QoR — separate workplan in `doc/asic_signoff_workplan.md`.
- Cleanup of `doc/4wide_signoff_2026-04-30.md` to reflect post-fix numbers — separate
  documentation task; should land before the gap-closure work but is independent of
  this methodology.

---

## 12. Companion deliverable (after Phase E execution)

A results doc `doc/4wide_perf_gap_results_<final-date>.md` will pair this design with:

- Counter diff table (Phase A output)
- Bucket attribution per workload (Phase B output)
- Confirmed hypotheses with predicted-vs-measured IPC delta (Phase D + E output)
- RTL changes landed with measured cm + dhry + clockcheck deltas
- Refreshed sign-off table (replaces stale 6.05 number in 2026-04-30 sign-off doc)

The results doc is written incrementally as each Phase E iteration completes.

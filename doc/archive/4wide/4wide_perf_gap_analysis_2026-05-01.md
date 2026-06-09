# 4-Wide RTL Refactor — Performance Gap Analysis Methodology

**Date:** 2026-05-01
**Status:** DESIGN — methodology only; **no RTL changes proposed in this doc.**
**Repo HEAD:** `master @ cd54cf1` (post Load1 bypass fix)
**Simulator:** DSim 2026.0.0
**Companion docs:**
- `doc/4wide_signoff_2026-04-30.md` — structural-refactor sign-off (PARTIAL; numbers stale, see Background)
- `doc/4wide_refactor_checklist.md` — execution checklist (all 90 items complete)
- `doc/baseline_6wide_obsolete_2026-04-30.md` — 6-wide archive (cross-width comparison rejected for sign-off)

> ## What this doc IS and IS NOT
>
> **IS:** A 4-wide-absolute, data-driven methodology for closing the CM/MHz and DMIPS/MHz
> gaps versus the Reference Core A (large config) 4-wide sign-off floor. Bubbles and stalls are measured directly
> on the 4-wide machine; no 6-wide reference is required because sign-off is external.
>
> **IS NOT:** An implementation plan, a commitment to specific RTL edits, or a replacement
> for the structural sign-off doc. The implementation plan comes from
> `superpowers:writing-plans` invoked after this doc is approved. Specific RTL edits come
> out of Phase D, only after Phase A–C produce a confirmed bucket-level hypothesis.

---

## 1. Background

The 5-stage 4-wide refactor merged at `aca1f33` with all functional and clockcheck gates
green but with both performance floors missed. The CoreMark functional bug discovered
post-merge (Load1 bypass slot was silently dropped in Stage 2) was resolved at `cd54cf1`
by restoring `bypass[4]` for Load1 and bumping `NUM_BYPASS_SRCS` 4 → 5. After the fix,
the previously-reported sign-off numbers were exposed as inflated by an 11× BPU
mistraining cascade. Real measurements on `cd54cf1`:

| Workload | Cycles | Instret | IPC | Metric | Reference Core A (large config) floor | Gap |
|---|---:|---:|---:|---|---:|---:|
| dhrystone (100 iter) | 23,514 | 47,670 | 2.027 | **2.42 DMIPS/MHz** | 4.00 | **−39.5%** |
| coremark iter1 | 199,452 | 332,110 | 1.665 | **5.01 CM/MHz** | 6.2 | **−19.2%** |
| coremark iter10 | 1,860,512 | 3,197,342 | 1.719 | **5.37 CM/MHz** | 6.2 | **−13.3%** |

Functional 21/21 PASS, clockcheck 3/3 PASS, all benches reach `PASS at tohost=1`.

`doc/4wide_signoff_2026-04-30.md` still cites the inflated 6.05 CM/MHz figure and needs
a separate post-fix correction pass — out of scope for this analysis methodology.

---

## 2. Problem statement & framing

### 2.1 Why 4-wide-absolute, not 6-wide-diff

Sign-off is external (Reference Core A (large config) 4-wide floor, a commercial 3-wide OoO core stretch). `doc/baseline_6wide_obsolete_2026-04-30.md`
explicitly rejects cross-width cycle comparison for sign-off purposes. To close the gap
we need to **eliminate bubbles in 4-wide**, not match a different machine's behavior. In
fact, 4-wide must *beat* 6-wide IPC on cm to clear the Reference Core A (large config) floor (need IPC ≈ 2.06;
6-wide had 1.81), so 6-wide-matching is not even sufficient.

Bubble/stall counters are intrinsically meaningful in 4-wide alone:
- "ROB head was waiting Y% of cycles" — absolute fact about 4-wide
- "Issue picked < 4 uops in Z% of cycles" — absolute fact about 4-wide
- "Cycle-class N% of total" — absolute fact about 4-wide

These tell us where the *closable* bubbles are. A 6-wide diff would only tell us "this
machine is different from that machine" — not actionable for hitting the external floor.

### 2.2 Two distinct gap profiles

Initial PERF_PROFILE captures (Section 3) show the two workloads have **different**
bottleneck signatures, requiring different attributions:

- **CoreMark** — BPU mispredict-driven. 8.0% conditional-branch mispredict rate, 4343
  flushes in 199k cycles, top mispredict PC at 100% (`0x8000235a`, in `core_list_mergesort`).
  All structure-full counters zero. The bottleneck is in front-end recovery /
  branch-resolution latency, not in narrowing.
- **Dhrystone** — issue/execute bubble-dominated. BPU healthy (1.6% cond mispredict),
  all structures non-full, but commit-count distribution skews to 2 (41% of cycles) with
  only 6% reaching peak 4. The bottleneck is downstream of issue.

Without per-cycle bubble attribution, we'd be reduced to blind RTL tweaks (the failure
mode that produced 3a/3b/3c). The Load1 bypass fix worked because we waited for trace
data; same discipline applies here.

---

## 3. Existing 4-wide instrumentation inventory

Stage 5's `+PERF_PROFILE` plusarg already exposes a comprehensive bubble/stall picture in
`tb_top.sv`. Phase A leverages what's already there before adding any new counters.

### 3.1 What's already exposed (categorized for the 6-bucket framework)

| Bucket | Existing counters |
|---|---|
| **Cycle-class distribution** | `commit_hist[0..6]` — cycles where commit_count = N (0–6); printed as `commit=N: count (pct%)`. **This is the bubble distribution.** |
| **Frontend** | `flush_cyc`; loop-buffer summary (replay/body-length/forward-progress/exit-pred); committed PC diversity windows; uop-cache miss/replay/exit reasons; LB `commit_no_load` cycles |
| **Rename + Dispatch** | `rename_stall_cyc`, `backend_stall_cyc`, `rob_full_cyc`, `dq_full_cyc`, `lq_full_cyc`, `sq_full_cyc`, `iq{0,1,2}_full_cyc`; rename slot-attribution `stall_{preg,ckpt,rob,dq,other}_cyc`; rename slot-advance summary |
| **Issue** | `iq{0,1,2}_avg` (occupancy of 32) and `iq{0,1,2}_cnt_sum` |
| **Execute / LSU** | `ld{0,1}_{candidate,issue,suppress}`; `sq_fwd_wait`; storeIQ blocking; p0/p1 forwarding (full/partial/wait-only/conflict); spec wake p0/p1; std IQ spec match p0/p1; sta/std/store_req issue; SQ addr-only pending avg/max + addr-to-data lag histogram |
| **Load latency** | `load_lat_{issue,reissue,wb,untracked}`; pending avg/max; latency histogram (10 buckets: 0/1/2/3/4/5/6-7/8-15/16-31/32+); source breakdown (dchit/fwd/lmb/misalign/unknown); top-N PCs |
| **Branch / control** | committed cond/jal/jalr/call/ret + mispredict per-type + top mispredict PCs (with taken/not-taken split); GHR + RAS restore counts; BRU early-redirect recovery |
| **Free-list** | total allocs/releases/commits/flushes; min free/committed bitmap popcount |

### 3.2 What's MISSING (Phase A.2 minimal additive instrumentation)

The 6-bucket framework needs three additional counter classes that Stage 5 does not yet
expose. These are pure additive instrumentation (counters only, no RTL logic change):

1. **ROB head-stall classification.** When `commit_count < commit_count_max` AND ROB head
   is non-empty, classify what the head is waiting on:
   - `head_wait_load_wb_cyc` — load writeback pending
   - `head_wait_mul_cyc` — MUL writeback pending
   - `head_wait_div_cyc` — DIV writeback pending
   - `head_wait_csr_cyc` — CSR serialization
   - `head_wait_bru_cyc` — BRU resolution pending
   - `head_wait_other_cyc` — fallthrough
2. **Issue-stall classification.** When IQ has eligible entries AND issue_count < 4,
   classify why:
   - `issue_stall_operand_cyc` — operands not ready
   - `issue_stall_fu_cyc` — functional unit contention
   - `issue_stall_arb_cyc` — issue-port arbitration loss
3. **Rename slot-count distribution.** `rename_slots_hist[0..4]` — cycles where N rename
   slots were valid this cycle. (Symmetric to `commit_hist`, gives front-end bubble shape.)

These counters live in `tb_top.sv` alongside existing PERF_PROFILE infrastructure. Each
is a single integer + a single increment in the same `always_ff` block as existing
counters. Estimated: ~80 lines added to `tb_top.sv`, no RTL logic change.

### 3.3 Initial findings (already visible from existing counters)

These are observations from running PERF_PROFILE on `cd54cf1` for both workloads. They
inform the Phase B/C/D work but are NOT yet confirmed hypotheses.

**CoreMark cm iter1:**
- Commit-count distribution heavily skewed: commit=0 (23%), commit=1 (20%), commit=2 (30%),
  commit=3 (14%), commit=4 (10%). Average commit ≈ 1.62 ≈ measured IPC 1.665. ✓
- IQ occupancy avg: iq0=2.41, iq1=1.21, iq2=1.01 (out of 32) — IQs are barely utilized
- Conditional-branch mispredict rate: **4256 / 52946 = 8.0%** (high for a TAGE-equipped BPU)
- Top mispredict PC: `0x8000235a` at **103/103 = 100% mispredict rate** (in `core_list_mergesort`,
  the same PC that surfaced in the Load1 bypass bug trace-divergence point)
- Total flushes: 4343 ⇒ one flush every 46 cycles
- Load latency: 99% of loads wb at 1 cycle (57107 of 57722); pending avg 0.29 — LSU healthy
- All structure-full / rename-stall counters: 0 (or near-zero: iq0_full=20)

**Dhrystone:**
- Commit-count distribution: commit=0 (9%), commit=1 (16%), commit=2 (41%), commit=3 (25%),
  commit=4 (6%). Average ≈ 1.97 ≈ measured IPC 2.027. ✓
- Conditional-branch mispredict rate: **123 / 7532 = 1.6%** (BPU healthy)
- Total flushes: 128 ⇒ one flush every 184 cycles
- Load latency: 94% of loads wb at 1 cycle (10677 of 11385); pending avg 0.51 — LSU healthy
- All structure-full / rename-stall counters: 0
- Single hot mispredict PC `0x80002028` at 100/100 (likely a loop exit; intrinsic to the
  workload at iter=100 boundary)

**Implications for hypothesis ranking:**
- *cm:* the dominant bottleneck is **BPU mispredict + flush recovery**, not narrowing. The
  4343 flushes recover at ~5–7 cycles each ≈ 21k–30k lost cycles, accounting for 10–15% of
  total cm cycles. The narrowing penalty (CDB/bypass/IQ) appears secondary.
- *dhry:* the dominant bottleneck is **issue or commit-side bubbles** with no structure
  pressure. The data lacks the head-stall classification (Phase A.2 #1) needed to
  attribute this; that's the highest-priority Phase A.2 addition.

---

## 4. Methodology — 4 phases (4-wide-only)

```
Phase A ──► Phase B ──► Phase C ──► Phase D
counter      bottleneck    hypothesis    RTL changes
inventory +  ranking       enumeration   (writing-plans)
minimal      from absolute with predicted output)
add'l        4-wide        counter
instr        bubble %      signature
```

**Total wallclock estimate:** ~2 hours active work for Phases A–C (excludes DSim license
release waits and the ~80-line counter-add patch which is its own commit cycle).

### 4.1 Phase A — 4-wide bubble/stall inventory + minimal instrumentation

**Goal:** Make the 4-wide bubble picture complete enough that Phase B can attribute every
non-peak commit cycle to a bucket.

**Steps:**

1. **A.1 — capture existing counters.** Run cm iter1 + cm iter10 + dhry on `cd54cf1` with
   `+PERF_PROFILE`. Save full dsim_run.log to
   `benchmark_results/perf_baseline_4wide_<workload>.log`.
2. **A.2 — add missing counters** (Section 3.2 list): head-stall classification (6
   buckets), issue-stall classification (3 buckets), rename slot-count distribution (5
   buckets). All in `tb_top.sv`, all gated on existing `+PERF_PROFILE`. ~80 lines.
3. **A.3 — rebuild + re-run** all three workloads. Save logs to
   `benchmark_results/perf_full_4wide_<workload>.log`.
4. **A.4 — produce the bubble inventory table** at
   `benchmark_results/perf_inventory_2026-05-01.md`: per workload, every counter as
   absolute value AND as percentage of `mcycle`.

**Deliverable:** `perf_inventory_2026-05-01.md` — flat markdown table with every counter
bucketed into one of the 6 buckets, normalized to %-of-mcycle. No interpretation yet
(that's Phase B).

**Gate to Phase B:**
- Three workloads completed at PASS+tohost=1 with PERF_PROFILE active.
- All 6 buckets have at least one counter feeding them.
- Sum of bucket-attributed cycles ≈ `mcycle - peak_retire_cycles` within ±10%.

### 4.2 Phase B — Bottleneck ranking from absolute 4-wide bubbles

**Goal:** Rank the top-3 bubble buckets per workload from absolute 4-wide percentages.

**Method:** For each workload:
1. `peak_retire_cycles = ceil(minstret / PIPE_WIDTH)` — theoretical floor for the workload.
2. `gap_cycles = mcycle - peak_retire_cycles` — the bubble budget to be attributed.
3. Attribute `gap_cycles` to the 6 buckets:
   - **Frontend** — flush recovery + LB miss + uop-cache miss + frontend-bubble (rename slot=0)
   - **Rename + Dispatch** — `rename_stall_cyc` + structure-full (`*_full_cyc`)
   - **Issue** — `issue_stall_*_cyc` (Phase A.2 addition)
   - **Execute (non-LSU)** — MUL/DIV serial latency + BRU resolution latency
   - **LSU** — pending-load latency × pending count + sq_fwd_wait + storeIQ block + p1 conflict
   - **Commit** — `head_wait_*_cyc` (Phase A.2 addition, excluding LSU which is bucket 5)
4. Compute residual; if >10%, identify what counter is missing and iterate Phase A.2.

**Deliverable:** `bottleneck_ranking_2026-05-01.md` — per workload, 6-bucket ranked table
with %-of-gap attribution + top-3 callout.

**Gate to Phase C:**
- Both workloads have ranked bucket attribution.
- Residual <10% per workload.
- Top-3 per workload identified and consistent with raw counter inspection.

### 4.3 Phase C — Hypothesis enumeration

**Goal:** For each top-3 bucket per workload, enumerate concrete RTL hypotheses with
predicted counter signatures.

**Hypothesis template:**

| Field | Content |
|---|---|
| ID | e.g., `cm-H1` |
| Bucket | which Phase B bucket this hypothesis explains |
| Description | one-sentence mechanism in narrowed 4-wide RTL |
| Predicted signature | which counter would change (and direction) if hypothesis is correct |
| Discrimination | which microbench would isolate it (Phase D) |
| Expected fix shape | what RTL change family would address it (NOT the change itself) |

**Initial seed hypotheses** (informed by Section 3.3 findings; refine after Phase B):

| ID | Bucket | Hypothesis |
|---|---|---|
| cm-H1 | Frontend (flush) | `0x8000235a` (data-dependent compare in mergesort) is intrinsically hard for TAGE; mispredicts at high rate, drives flush recovery |
| cm-H2 | Frontend (flush) | TAGE training pipeline narrowed in Stage 5 trains slower than 6-wide; iter1 doesn't reach steady-state hit rate |
| cm-H3 | Issue | NUM_ALU=3 causes ALU contention on dense cycles |
| dhry-H1 | Commit (head wait) | ROB head waits on load WB during procedure entry (need Phase A.2 #1 to confirm) |
| dhry-H2 | Issue | NUM_ALU=3 saturates on procedure-entry instruction burst (need Phase A.2 #2 to confirm) |
| dhry-H3 | Frontend | BPU return-stack hit rate degraded for nested calls in narrowed frontend |
| dhry-H4 | Issue | IQ_INT_DEPTH=24 too small for procedure-entry rename burst (would manifest as iq*_full > 0; currently 0 → likely refute) |

**Deliverable:** `hypothesis_table_2026-05-01.md` — one row per hypothesis, every field
filled. Every hypothesis cites its Phase B bucket and predicted counter signature.

**Gate to Phase D:**
- Every top-3 bucket has at least one hypothesis.
- Every hypothesis has predicted counter signature + microbench-discrimination pointer +
  expected-fix shape.
- No hypothesis is "we don't know" — if a bucket dominates and we have no hypothesis,
  return to Phase A.2 with a more targeted counter.

### 4.4 Phase D — Microbench probes + RTL change proposals

**Goal:** Confirm or refute hypotheses with synthetic workloads, then propose RTL changes.

**Probes (5 initial; refine based on Phase B/C):**

| Probe | Stress target | Hypotheses isolated |
|---|---|---|
| `alu_chain_8.S` | 8-deep ALU dependency chain | cm-H3 (issue contention) |
| `dhry_call_mimic.S` | Dhrystone Proc_1..Proc_7 call topology mimic: 4–7 nested calls per outer-loop iter, mixed-arg, return-value chained. **Specifically modeled on dhry, not generic** | dhry-H1, H2, H3, H4 |
| `bpu_data_dep_branch.S` | Random data-dependent branch in tight loop; mimics `0x8000235a` profile | cm-H1 (intrinsic) vs cm-H2 (training speed) |
| `mixed_branch_dense.S` | 1 branch per 4 instructions, mixed taken/not-taken | BPU + flush penalty broadly |
| `independent_quad.S` | 4 independent ALU per cycle, sustained loop | Sanity ceiling — does 4-wide hit IPC=4? |

**Method per probe:**
1. Build hex via `scripts/elf2hex.py`.
2. Run with `+PERF_PROFILE` on `cd54cf1`.
3. Confirm: predicted bucket counter responds in predicted direction.
4. Refute: counter doesn't respond → hypothesis is incorrect; return to Phase B.

**Phase D RTL change rule (formalized):**

Each Phase D RTL change proposal MUST include:

1. **Files:lines** to touch (concrete).
2. **Predicted IPC delta** on cm iter1, cm iter10, dhrystone, **and** the relevant
   microbench. Predictions committed to git **before** measurement (in commit message or
   plan doc). Blocks post-hoc rationalization.
3. **Confirmation criterion** — which counter must improve, by how much.
4. **Refutation criterion** — what observation would invalidate the hypothesis.
5. **Neutral-or-better verification** — the OTHER workload (cm if dhry change, dhry if
   cm change) must show no regression beyond ±2% IPC. Functional 21/21 + clockcheck 3/3
   stay PASS.

**The 30% rule:** if predicted IPC delta and measured IPC delta diverge by >30% in either
direction, the hypothesis is unsound. Record prediction and actual; do NOT revise the
prediction; return to Phase B/C with the new data point.

**Deliverable:** `microbench_probes_2026-05-01.md` (Phase D output) + per-iteration RTL
change proposals (in writing-plans output).

---

## 5. Constraints (do NOT do)

1. **No RTL changes (other than Phase A.2 instrumentation) before Phase D.** The Load1
   bypass fix worked because we waited for trace data; same discipline applies. The
   reflexive-revert reflex (3a/3b/3c) is the failure mode this methodology prevents.
2. **No 6-wide rebuild for sign-off comparison.** Sign-off is external (Reference Core A (large config)/commercial 3-wide OoO stretch).
   `doc/baseline_6wide_obsolete_2026-04-30.md` already records why cross-width comparison
   is rejected.
3. **No single-workload optimization.** Every Phase D proposal must show neutral-or-better
   on the other workload (Phase D rule #5).
4. **No new RTL counters until Phase A.2 list is exhausted.** Section 3.2 enumerates the
   minimal additive set; if Phase B residual is still >10% after those land, revisit.
5. **No re-derivation of cm functional bug.** RESOLVED at `cd54cf1`. Do not re-investigate.
6. **No reactivation of `../rv64gc-perf-model/`.** Paused on toolchain dead-end. Only
   `rtl_clockcheck.py` remains in active use.
7. **No CDB widening as a bandage.** If Phase B/C points at CDB bandwidth as the cm
   bottleneck, the Phase D proposal must be a targeted narrowing-preserving fix (e.g.,
   smarter arbitration, additional bypass slot, dedicated MUL writeback port) NOT
   "restore CDB_WIDTH=6". The 4-wide design must remain 4-wide on writeback.

---

## 6. Sign-off bar (re-stated)

| Tier | CM/MHz | DMIPS/MHz | Source |
|---|---:|---:|---:|---|
| Floor — must match | ≥ 6.2 | ≥ 4.00 | Reference Core A (large config) (4-wide OoO) |
| Stretch — must beat | ≥ 8.24 | ≥ 4.72 | a commercial 3-wide OoO core (3-wide OoO) |

After Phase D iterations, sign-off requires **both** workloads at floor, **and**
functional 21/21 + clockcheck 3/3 still PASS, **and** the post-change measurement is
captured in a refreshed sign-off doc that supersedes `doc/4wide_signoff_2026-04-30.md`.

Stretch target is desired but not blocking.

---

## 7. Out of scope

- Reverting any narrowing decision speculatively (3a/3b/3c style).
- Adding new architectural features unrelated to gap closure.
- Re-tuning 6-wide to "see what changed".
- ASIC sign-off / synthesis QoR — separate workplan in `doc/asic_signoff_workplan.md`.
- Cleanup of `doc/4wide_signoff_2026-04-30.md` to reflect post-fix numbers — separate
  task.

---

## 8. Companion deliverable (after Phase D execution)

A results doc `doc/4wide_perf_gap_results_<final-date>.md` will pair this design with:

- Counter inventory + bottleneck ranking (Phase A + B output)
- Confirmed hypotheses with predicted-vs-measured IPC delta (Phase D output)
- RTL changes landed with measured cm + dhry + clockcheck deltas
- Refreshed sign-off table (replaces stale 6.05 number in 2026-04-30 sign-off doc)

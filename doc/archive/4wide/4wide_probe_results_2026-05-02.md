# Pipeline Bubble Probe Results — Hypothesis Investigation

**Date:** 2026-05-02
**Repo HEAD:** `master @ 9c0695c`
**Trigger:** User instinct that ROB shouldn't stay partially full (12/128); 4 hypotheses raised:
1. Renaming issue / bubbles not identified
2. Inter-EU forwarding or wakeup network issue
3. BPU mispredict high
4. Other potential issues

**Investigation:** 6 probes designed; Probes 1+2+3 executed (all use existing instrumentation, no RTL change). Probes 4+5+6 deferred pending probe-results review.

---

## TL;DR

**The ROB is small because the entire pipeline is in balanced equilibrium at ~1.7 uops/cycle, not because of stall pressure.** The bottleneck is **frontend supply**, not rename, not backend backpressure. Specifically:

- Rename is **never structurally stalled** (rename_stall_cyc=0; slot advance rate 100%)
- Backend has massive headroom (INT IQs at 5-10% capacity, ROB at 10% capacity)
- Frontend delivers **~2 uops/cycle** on average (out of PIPE_WIDTH=4)
- Backend consumes at the same rate (steady state)
- ROB equilibrium = avg in-flight time (7.57 cyc) × commit rate (1.665) = 12.6 entries — matches measured

**Frontend supply decomposition (cm):**
- 34% of cycles: LB replay (NOT a bubble — feeds rename directly bypassing fetch_unit)
- 16% of cycles: F2 enqueue blocked by control transfer (BPU pipeline interaction)
- 1.6% of cycles: actual I-cache miss wait
- 2.2% of cycles: explicit flush recovery
- ~14.7% indirect: mispredict-recovery cycles (drain + refill the fetch pipe)
- Remainder: LB↔fresh-fetch transitions, decode/fusion timing

---

## Probe 1 — Per-cycle rename_count distribution

For each cycle, classify by `rename_count` (instructions delivered to rename stage from fetch+decode OR loop buffer).

### CM iter1 results

| rename_count | cycles | % of total |
|---:|---:|---:|
| 0 | 64,981 | **32.58%** |
| 1 | 23,780 | 11.92% |
| 2 | 20,823 | 10.44% |
| 3 | 27,978 | 14.03% |
| 4 | 61,890 | **31.03%** |

**Observation:** the distribution is BIMODAL — peaks at rename=0 (32.6%) and rename=4 (31.0%), with mid-counts only 36%. This is the signature of LB-replay-vs-LB-exit transitions.

### Dhrystone results

| rename_count | cycles | % of total |
|---:|---:|---:|
| 0 | 5,861 | 24.93% |
| 1 | 4,508 | 19.17% |
| 2 | 3,245 | 13.80% |
| 3 | 2,076 | 8.83% |
| 4 | 7,824 | **33.27%** |

Less bimodal — dhry has more mid-count distribution (less LB activity).

---

## Probe 2 — Frontend supply decomposition (PERF_PROFILE Fetch=0 breakdown)

For cm: 126,152 cycles where fetch_unit emitted 0 (63.25% of cm). Breakdown from existing tb_top.sv counters:

| Sub-category | Cycles | % of fetch=0 | % of cm total |
|---|---:|---:|---:|
| **loop_buffer_hold** | 68,573 | 54.4% | **34.4%** |
| **packet_empty (icreq_live)** | 56,102 | 44.5% | 28.1% |
| └─ wait_icresp (real I$ miss) | 3,107 | 2.5% | 1.6% |
| └─ wait_f2_data | 49,536 | 39.3% | 24.8% |
| └─ enq blocked (no emit downstream) | 44,256 | 35.1% | 22.2% |
| │   └─ ctl_cond (cond branch) | 27,867 | 22.1% | 14.0% |
| │   └─ ctl_taken | 18,207 | 14.4% | 9.1% |
| │   └─ ctl_nt | 13,895 | 11.0% | 7.0% |
| │   └─ noctl | 12,133 | 9.6% | 6.1% |
| │   └─ callret + other | ~4,256 | ~3% | ~2% |
| **redirect_recovery (flush)** | 1,477 | 1.2% | 0.7% |

(Sub-categories overlap; the wait_f2_data and enq sub-buckets are different observation perspectives on the same cycles, not strictly MECE.)

**Key insight: 54% of fetch=0 cycles are LB replay** — fetch_unit is intentionally idle while the loop buffer feeds rename directly (bypassing fetch_unit). These are **NOT bubbles** in the conventional sense.

### Top (fetch, rename) pairs for cm

| fetch | rename | cycles | % | Note |
|---:|---:|---:|---:|---|
| 0 | **4** | 52,961 | **26.55%** | LB-replay PEAK (rename=4 from LB) |
| 0 | 3 | 23,014 | 11.54% | LB-replay partial |
| 0 | 0 | 20,072 | 10.06% | TRUE empty (flush recovery / I$ miss) |
| 4 | 0 | 17,529 | 8.79% | Fetch supplied to packet_buffer; rename=0 (buffer-drain timing artifact) |
| 0 | 2 | 16,249 | 8.15% | LB partial |
| 0 | 1 | 13,856 | 6.95% | LB partial |
| 1 | 0 | 13,732 | 6.88% | Fetch supplied 1 ALIGN; rename=0 (timing) |

**Observation:** the top pair (fetch=0, rename=4) at 26.55% confirms LB is doing significant useful work. The (fetch>0, rename=0) cycles are timing artifacts of fetch supplying ALIGN slots that take >1 cycle to propagate through decode → fusion → rename.

---

## Probe 3 — Rename stage stall classification

From rename.sv RENAME STALL SUMMARY for cm (199,452 cycles sampled):

| Counter | Value | Interpretation |
|---|---:|---|
| Total work-slot cycles | 136,435 | rename had ≥1 valid slot |
| Total advanced slot cycles | 136,435 | **100% slot advance rate** — no holding |
| Cycles with any valid slot | 136,435 | 68.4% of cm |
| Cycles any slot stalled | **14** | negligible |
| Cycles ALL slots stalled | **0** | never |
| Cycles rename.stall asserted | **0** | rename never blocks upstream |
| has_preg=0 (free list empty) | **3** | negligible |
| has_rob=0 (ROB full) | **0** | ROB never full |
| has_ckpt=0 (checkpoint full) | 14 | small |
| has_lq=0 / sq=0 / dq=0 | 0 / 0 / 0 | LSU/dispatch never full |
| Eliminated at rename: zero | 3,416 | 2.5% of cycles |
| Eliminated at rename: move | 0 | mv-elim not firing |

**Definitive finding: rename is NOT the bottleneck.** Whenever it has work, it processes it at full rate. Stall reasons are essentially zero across the board.

The "rename=0" cycles in Probe 1 are NOT rename stalls — they are cycles where rename's INPUT supply (fetch_unit + LB) delivered 0 instructions.

---

## Hypothesis Verdicts

### #1 Renaming issue, bubbles not identified — **PARTIALLY CONFIRMED with reframe**

- **NOT a rename-stage issue.** Rename never structurally stalls; slot advance rate is 100%; ROB never fills enough to backpressure rename.
- **IS a frontend-supply issue.** Frontend delivers ~2 uops/cycle on average:
  - 34% of cm cycles are LB-replay (intentional; LB feeds rename ~3-4 uops/cycle when active)
  - 16% of cm cycles are F2-enqueue-blocked by control transfers (BPU pipeline interaction; ~1 cycle per cond branch)
  - 1.6% of cm cycles are actual I$ miss wait
  - 2.2% explicit flush recovery
  - ~14.7% indirect mispredict-recovery (frontend re-fills after flush)

**Actionable signal:** the **F2-enqueue-blocked-by-control-transfer** cost (~16% of cm cycles) is the largest non-LB-non-flush component. This is BPU pipeline interaction: when F2 detects a control transfer, the enqueue logic holds for ≥1 cycle to integrate BPU/FTQ state. If this could be pipelined more aggressively (speculative enqueue with rollback on BPU-late-resolve), 16% of cm cycles could become productive.

### #2 Inter-EU forwarding / wakeup network — NOT YET INVESTIGATED

Probe 4 designed but not run. Existing data suggests wakeup is well-tuned:
- Spec wakeup mechanism active (cm: 43,861 spec-wake p0 + 12,684 p1)
- Bypass network covers 5 sources (3 CDB-registered + 2 load combinational)
- Cycle E REFUTED that adding ALU3 bypass helps (0% IPC impact)

The user's intuition would benefit from a per-cycle "consumer wakes but waits N cycles before issue" probe — would require new instrumentation.

### #3 BPU mispredict high — CONFIRMED at 14.7% of cm cycles

- 4,343 mispredicts × ~7 cyc avg recovery = ~30k cycles = 14.7% of cm
- Top mispredict PC: `0x8000235a` (`bge s0, s5` in `core_list_mergesort`) at 100% mispredict — data-dependent, intrinsic
- TAGE structural limit on data-dependent branches confirmed via `probe_bpu_data_dep_branch.S` (29.4% mispredict on true-random)
- BPU storage already BIGGER than BOOM (Cycle A REFUTED uBTB sizing); not a tuning issue

### #4 Other — Two specific candidates surfaced

**4a. F2-enqueue-blocked-by-control-transfer (~16% of cm cycles).** Per Probe 2 sub-decomposition. This is the largest single attributed source of fetch=0 that ISN'T LB-replay or flush. Would need RTL inspection of fetch_unit's F2 → packet_buffer enqueue path to understand what specifically holds when a control transfer is detected.

**4b. LB↔fresh-fetch transition cost.** When LB exits, fetch_unit needs to re-establish state (PC, BPU, FTQ) before resuming. This shows up partly as packet_empty during the transition. Hard to quantify without per-cycle LB-state tracing.

---

## What this changes about prior cycle conclusions

The bubble taxonomy + Little's-law decomposition were correct but missed the FRONTEND structural component. Updated picture:

| Cause | % of cm cycles | Origin |
|---|---:|---|
| PEAK / productive | 64.7% | — |
| Mispredict recovery (head-wait dwell 6-10) | 14.7% | BPU + flush pipe (intrinsic) |
| Load-WB at head (head-wait dwell 2) | 16.4% | dcache latency + in-order commit |
| MUL at head | 2.6% | MUL FU latency |
| F2-enqueue ctl-transfer block | ~16%* | BPU/FTQ pipeline interaction |
| LB↔fresh-fetch transitions | ~5-10%* | LB state machine |

*These overlap with the productive category and head-wait categories, so don't double-count. The taxonomy categories are mutually exclusive at per-cycle level; these % refer to CONDITIONS that contribute to cycles in those categories.

**The new actionable target is 4a (F2-enqueue ctl-blocked).** Worth scoping a probe + potential RTL change as Cycle G (if user wants).

---

## Tools

- `tools/bubble_taxonomy.py` — per-cycle exclusive bubble classification (Probe 0)
- `tools/headwait_deepdive.py` — Little's-law + head-dwell distribution (Probe 0.5)
- `tools/frontend_probe.py` — rename × ROB cross-tab + rename<4 attribution (Probes 1+2)
- (rename stall summary from `rename.sv` final block — already in PERF_PROFILE)

---

## Companion docs

- `doc/4wide_pipeline_bubble_taxonomy_2026-05-02.md` — gross bubble category split
- `doc/4wide_headwait_deepdive_2026-05-02.md` — HEAD_WAIT_BACKLOG decomposition
- `doc/4wide_arch_diff_2026-05-02.md` — BOOM v4 audit
- `doc/rv64gc_v2_uarch.md` — current µarch spec (after rewrite)

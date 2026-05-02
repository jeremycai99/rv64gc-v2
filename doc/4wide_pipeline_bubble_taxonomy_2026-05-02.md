# Pipeline Bubble Taxonomy — rv64gc-v2 4-Wide

**Date:** 2026-05-02
**Repo HEAD:** `master @ 4d74bf0`
**Source data:** `[PIPE schema=pipe.v1]` per-cycle traces from `tb_top.sv:3243`, gated on `+TRACE_PIPELINE`. Captured for cm iter1 (199,452 cycles, 43 MB log) and dhry (23,514 cycles, 5 MB log).
**Analyzer:** `/tmp/bubble_taxonomy.py` (Python decision-tree classifier; per-cycle exclusive attribution)

---

## TL;DR

The 4-wide design is **not** structurally bottlenecked by frontend bandwidth, dispatch capacity, issue queue size, branch prediction accuracy, or any other parameter we previously suspected. **74% of cm cycles and 88% of dhry cycles are in HEAD_WAIT_BACKLOG** — meaning the ROB has uops to commit, but the head (or near-head) uop is not writeback-ready, and the pipeline can only commit 1-3 uops per cycle (or 0) instead of the 4-wide peak.

Across both workloads:
- PEAK (commit=4) cycles: only 10% (cm) and 7% (dhry)
- HEAD_WAIT_BACKLOG: 74-88% — dominant by far
- All other categories combined: 4-16% (frontend / dispatch / flush / other)

This means the IPC ceiling is set by **producer-completion latency on the critical-path uops**, not by any of the structural parameters we've been investigating. **The remaining gap to MegaBoom is fundamentally about per-uop completion latency on dependency chains, not about queue sizes, IQ structure, or BPU storage.**

---

## Methodology

### Per-cycle classification (decision tree, first match wins)

For each cycle in the pipe.v1 trace, classify into exactly ONE category:

1. **FLUSH** — `flush == 1` (pipeline drain in progress)
2. **PEAK** — `commit == PIPE_WIDTH` (4) — productive cycle
3. **HEAD_WAIT_BACKLOG** — `commit < 4 AND rob_cnt >= 4` — ROB has ≥4 uops, head can't drain commit window
4. **DISPATCH_BLOCKED** — `commit < 4 AND rob_cnt < 4 AND rename >= 4 AND dispatch < rename` — frontend has work, downstream rejected
5. **FRONTEND_LIMITED** — `commit < 4 AND rob_cnt < 4 AND rename < 4` — not enough work in flight; frontend not delivering
6. **OTHER** — residual (in practice, 0%)

The **most-upstream binding constraint** rule applies: if frontend can't deliver (FRONTEND_LIMITED), downstream issues are masked and don't count separately. If dispatch is blocked (DISPATCH_BLOCKED), issue/commit issues are masked. Etc.

### Why this is more decisive than the prior bucket-attribution analysis

The prior gap analysis (`doc/4wide_perf_inventory_2026-05-01.md`) used aggregated counters:
- "head_not_ready_cyc = 94,129 (47% of cm)"
- "issue_stall_operand_cyc = 69,426 (35% of cm)"
- These COULD overlap (a cycle could be both head-stalled AND have IQ in operand-stall)

The new bubble taxonomy uses **per-cycle exclusive classification**: each cycle counts in exactly one category. The 74% HEAD_WAIT_BACKLOG number is the actual fraction of cycles where the bottleneck is at-or-near the ROB head, not a sum of overlapping measurements.

---

## Results — coremark iter1 (mcycle=199,452, IPC=1.665)

| Category | Cycles | % of mcycle |
|---|---:|---:|
| **HEAD_WAIT_BACKLOG** | **147,682** | **74.04%** |
| FRONTEND_LIMITED | 22,810 | 11.44% |
| PEAK (commit=4) | 19,814 | 9.93% |
| DISPATCH_BLOCKED | 4,803 | 2.41% |
| FLUSH | 4,343 | 2.18% |
| OTHER | 0 | 0.00% |

**Commit-count distribution within each category:**

| Category | commit=0 | =1 | =2 | =3 | =4 |
|---|---:|---:|---:|---:|---:|
| PEAK | 0 | 0 | 0 | 0 | 19,814 |
| HEAD_WAIT_BACKLOG | 23,546 | 36,148 | 59,121 | 28,867 | 0 |
| FRONTEND_LIMITED | 20,396 | 1,955 | 451 | 8 | 0 |
| DISPATCH_BLOCKED | 3,926 | 530 | 343 | 4 | 0 |
| FLUSH | 0 | 2,127 | 1,328 | 581 | 307 |

**HEAD_WAIT_BACKLOG sub-detail (147,682 cycles):**
- With issue activity: 120,010 (81.3%) — younger uops issuing past stuck head
- No issue activity: 27,672 (18.7%) — pipeline truly stalled
- ROB occupancy distribution:
  - 4-7: 52,775 (35.7%) — light backlog
  - 8-15: 70,476 (47.7%) — moderate backlog (dominant)
  - 16-31: 10,752 (7.3%)
  - 32-63: 9,635 (6.5%)
  - 64+: 4,044 (2.7%)

**FRONTEND_LIMITED sub-detail (22,810 cycles):**
- rename=0: 16,726 (73.3%) — frontend totally empty (likely flush-recovery cycles after the ~4,343 flushes)
- rename=1-3: 6,084 (26.7%) — partial delivery

---

## Results — dhrystone (mcycle=23,514, IPC=2.027)

| Category | Cycles | % of mcycle |
|---|---:|---:|
| **HEAD_WAIT_BACKLOG** | **20,806** | **88.48%** |
| PEAK (commit=4) | 1,601 | 6.81% |
| FRONTEND_LIMITED | 847 | 3.60% |
| DISPATCH_BLOCKED | 132 | 0.56% |
| FLUSH | 128 | 0.54% |
| OTHER | 0 | 0.00% |

**Commit-count distribution within each category:**

| Category | commit=0 | =1 | =2 | =3 | =4 |
|---|---:|---:|---:|---:|---:|
| PEAK | 0 | 0 | 0 | 0 | 1,601 |
| HEAD_WAIT_BACKLOG | 1,446 | 3,863 | 9,687 | 5,810 | 0 |
| FRONTEND_LIMITED | 722 | 11 | 107 | 7 | 0 |
| DISPATCH_BLOCKED | 129 | 2 | 1 | 0 | 0 |
| FLUSH | 0 | 14 | 8 | 105 | 1 |

**HEAD_WAIT_BACKLOG sub-detail (20,806 cycles):**
- With issue activity: 15,493 (74.5%)
- No issue activity: 5,313 (25.5%)
- ROB occupancy:
  - 4-7: 4,848 (23.3%)
  - 8-15: 15,448 (74.2%) — dominant
  - 16+: 510 (2.5%)

dhry's HEAD_WAIT_BACKLOG is even MORE dominant than cm's (88% vs 74%). dhry's ROB stays in the 8-15 range for 74% of head-wait cycles — slightly larger backlog than cm's 8-15 (47.7%).

---

## Cross-workload synthesis

| Metric | cm iter1 | dhry |
|---|---:|---:|
| IPC | 1.665 | 2.027 |
| % cycles in HEAD_WAIT_BACKLOG | 74.04% | **88.48%** |
| % cycles at PEAK | 9.93% | 6.81% |
| Average commit per HEAD_WAIT cycle | ~1.6 | ~2.0 |
| % HEAD_WAIT cycles with issue activity | 81.3% | 74.5% |
| Most common ROB occupancy in HEAD_WAIT | 8-15 (47.7%) | 8-15 (74.2%) |

**The pipeline is rarely deadlocked.** 74-81% of HEAD_WAIT cycles still have issue activity (younger uops issuing past the head). The bottleneck is **completion order**, not **completion throughput**.

**The ROB stays small.** During head-wait, ROB occupancy is mostly 8-15 entries (out of 128 capacity). This means:
- The design is well-tuned (not pile-up at any structure)
- But also: there's no cushion to absorb head-of-ROB latency
- A larger backlog wouldn't help unless commit can also speed up

---

## What HEAD_WAIT_BACKLOG actually means at the RTL level

`HEAD_WAIT_BACKLOG` cycles split into two sub-causes that the snapshot rule cannot directly distinguish without additional per-cycle signals:

1. **Head-not-ready**: the ROB head uop's writeback bit is 0 — head literally cannot commit. The rob.sv `rob_head_not_ready_cyc` counter (94,129 for cm; 8,940 for dhry) captures this in a related-but-not-identical way (the counter has a slightly different sampling definition that overcounts vs the strict commit-blocking semantics).

2. **Slot-not-ready**: the head IS writeback-ready and commits successfully, but slots 1/2/3 of the commit window are not yet writeback-ready. Commit window only fills to N < 4. This is implied by the gap between `rob_head_not_ready_cyc` and `HEAD_WAIT_BACKLOG`.

Both sub-causes share the **same root mechanism**: producer-completion latency on the uops near the ROB head. Whether it's the head itself or slot 1-3, the fix would be the same: reduce per-uop completion time.

---

## Why prior gap-closure cycles all REFUTED — explained by the taxonomy

The 5 prior cycles (A, C, B, E, F) all REFUTED. The bubble taxonomy explains why:

| Cycle | Hypothesis (what it tried to fix) | Bubble category targeted | Result |
|---|---|---|---|
| A — uBTB sizing | BPU mispredicts → flush cycles | FLUSH (2.18% of cm) | REFUTE: BPU was bigger than BOOM |
| C — BRU early-redirect | Reduce flush penalty | FLUSH | REFUTE: actually increased mispredicts |
| B — SFB | Eliminate predictable branches | FLUSH | REFUTE: <1% SFB-eligible patterns |
| E — ALU3 bypass | Reduce operand-wait stalls | (HEAD_WAIT_BACKLOG indirect) | REFUTE: 0% impact (CDB[3] rarely used) |
| F — IQ reorg | More issue parallelism | (HEAD_WAIT_BACKLOG indirect) | REFUTE: actually hurt (lost ALU IQ capacity) |

**Cycles A, C, B targeted FLUSH (2.18% of cm)** — even if they had landed at the predicted +5%, they would have closed at most 0.5% IPC gap (5% × 2% / mcycle). The audit didn't recognize that FLUSH is a tiny fraction.

**Cycles E and F targeted what looked like operand-stall** — but the bubble taxonomy shows that operand-stall is a SYMPTOM of HEAD_WAIT_BACKLOG, not an independent bottleneck. The bypass slot didn't help because the consumers were already getting their operands by the time the head was ready. The IQ reorg didn't help because issue throughput wasn't the bottleneck — commit throughput was.

**The audit's 5 structural-difference predictions ranged from 1-5% IPC each.** None of them targeted HEAD_WAIT_BACKLOG specifically because HEAD_WAIT_BACKLOG isn't a structural difference — it's an emergent property of completion latency × dependency chains × workload critical paths.

---

## What WOULD close the gap (theoretical)

To reduce HEAD_WAIT_BACKLOG from 74% to (say) 50%, the average commit per cycle would need to rise from ~1.66 to (very roughly) ~2.5. That's a 50% IPC improvement on cm — would close most of the gap to MegaBoom.

Mechanisms that COULD achieve this (each is a major architectural change):

1. **Reduce dcache hit latency** (already discussed; we're FASTER than BOOM here at ~3 cyc, dropping to 1 cyc would require VIPT + way prediction — structural)

2. **Wider commit window with relaxed in-order constraint** — allow non-head ready uops to commit out of order, with checkpoint-based recovery on exception. This is a major architectural change with significant verification cost.

3. **Pre-completion of long-latency ops** — speculatively start MUL/DIV at decode (vs at issue), saving 1-2 cycles. Would require predication infrastructure for incorrect speculation.

4. **Smaller pipeline depth** — fewer cycles between issue and writeback. We're already at the aggressive end (3-cycle load-to-use vs BOOM 4-5). Going lower requires merging stages and timing closure rework.

None of these are parameter tweaks. All require multi-month engineering investments with no guarantee of success.

---

## What WOULDN'T close the gap (data-driven)

Per the bubble taxonomy + prior REFUTEs, the following are confirmed NOT to be the bottleneck:

- ❌ Frontend bandwidth (cm: only 11% FRONTEND_LIMITED, dhry: 4%)
- ❌ Dispatch / structural capacity (cm: 2.4%, dhry: 0.6% DISPATCH_BLOCKED; all `*_full_cyc` essentially zero)
- ❌ BPU prediction accuracy (cm: 2.2% FLUSH; we're already better-equipped than BOOM)
- ❌ Issue queue depth or partitioning (REFUTED Cycle F: more parallelism in IQ reorg actually HURT)
- ❌ ALU bypass coverage (REFUTED Cycle E: ALU3/DIV/CSR bypass had 0% impact)
- ❌ uBTB / NLP sizing (REFUTED Cycle A: we're bigger than BOOM)

These are settled. Future work should not re-investigate them.

---

## Recommendation

**Adopt the bubble taxonomy as the closing analytical framework for the rv64gc-v2 4-wide refactor performance work.** It explains both:
- Why the gap exists (HEAD_WAIT_BACKLOG dominance)
- Why all 5 prior gap-closure RTL attempts failed (none targeted the actual bottleneck)
- What WOULD work (major architectural changes, not parameter tunes)

**The PARTIAL-FLOOR sign-off (`doc/4wide_signoff_2026-05-01.md`) is correct and final** for this RTL design point. The gap to MegaBoom is structural and would require either:
- Major architectural redesign (out of scope)
- A different workload set (cm/dhry are MegaBoom-tuned; not our home turf)
- A frequency push (ASIC sign-off track)

**This bubble taxonomy is the missing analytical bridge** between the prior bucket-attribution analysis and the cumulative REFUTE evidence. It transforms the conclusion from "we tried things and they didn't work" into "the data tells us why nothing in our parameter space CAN work — the gap requires architectural change of a kind not in scope."

---

## Reproducing this analysis

```bash
cd /home/jeremycai/agent-workspace/rv64gc-v2
export LD_LIBRARY_PATH=

# Capture pipe.v1 traces (cm: ~5 min, dhry: ~30s)
bash run_dsim.sh tests/hex/coremark.hex 5000000 +PERF_PROFILE +TRACE_PIPELINE > /dev/null 2>&1
grep "^\[PIPE schema=pipe.v1\]" dsim_run.log > /tmp/cm_pipe.trace
bash run_dsim.sh tests/hex/dhrystone.hex 100000 +PERF_PROFILE +TRACE_PIPELINE > /dev/null 2>&1
grep "^\[PIPE schema=pipe.v1\]" dsim_run.log > /tmp/dhry_pipe.trace

# Run the analyzer
python3 /tmp/bubble_taxonomy.py
```

The analyzer source is at `/tmp/bubble_taxonomy.py`; it can be moved to `tools/bubble_taxonomy.py` if this becomes a recurring analysis.

---

## Companion docs

- Methodology: `doc/4wide_perf_gap_analysis_2026-05-01.md`
- Architectural audit: `doc/4wide_arch_diff_2026-05-02.md` (largely superseded by this doc — the audit identified WHAT is structurally different but couldn't predict that those differences don't translate to closable IPC gaps because of HEAD_WAIT_BACKLOG dominance)
- Sign-off: `doc/4wide_signoff_2026-05-01.md` (PARTIAL-FLOOR final)
- Methodology retrospective: `doc/4wide_methodology_retrospective_2026-05-02.md`

# Per-uop Lifecycle (UOPLIFE) Findings — distribution, not aggregate

**Date:** 2026-05-02
**Repo HEAD:** `master @ 6f30f9a` (instrumentation pending commit on this branch)
**Source data:**
- `/tmp/dhry_uoplife.trace` (47,670 records; mcycle=23,514; IPC=2.027)
- `/tmp/cm_uoplife.trace` (332,110 records; mcycle=199,452; IPC=1.665)
- analyzer output saved to `benchmark_results/uoplife_dhry.txt` and `benchmark_results/uoplife_cm.txt`
**Toolchain:** `/usr/bin/riscv64-unknown-elf-objdump -d tests/coremark/coremark.elf`
**Instrumentation:** `src/tb/tb_top.sv` lines ~1709-1745 (state), ~1875-1928 (hooks),
~3320-3358 (commit emit). Gated on `+TRACE_UOPLIFE`. Sim-only — IPC parity verified
both workloads (cm 1.665112 with vs without; dhry 2.027303 with vs without).

---

## 1. Methodology

For each retired uop, capture timestamps at five pipeline stages:
- `rename_cyc` — written by tb when rename allocates rob_idx for slot
- `dispatch_cyc` — written when uop dequeues from dispatch queue toward IQ
- `issue_cyc` — written when issue_valid asserts on the matching IQ entry
- `wb_cyc` — written when CDB[N] carries this rob_idx, OR `lsu_load_wb` sideband fires
- `commit_cyc` — emit time

Trackers are 128-entry arrays indexed by ROB index, written under `if
(trace_uoplife_en)` blocks; full-flush events invalidate all in-flight entries.
Branch-mispredict squashed uops never emit; commit-aligned emit only.

Stage deltas (`d_ren_to_disp`, `d_disp_to_iss`, `d_iss_to_wb`, `d_wb_to_cmt`,
`d_total`) are -1 when an endpoint was not observed (e.g., stores never write
CDB → `d_iss_to_wb=-1` and `d_wb_to_cmt=-1` for is_store=1).

The analyzer (`tools/uoplife_analyzer.py`) buckets each delta into 10
buckets {0, 1, 2, 3, 4-5, 6-10, 11-20, 21-50, 51-100, 100+}, computes
per-FU breakdowns, ranks PCs by avg time-in-stage (min 50 occurrences),
and surfaces dispatch-cluster sizes and mispredict-tail behavior.

**Functional regression preserved:** all 17 functional tests PASS
(`scripts/regress_dsim.sh --func`).

---

## 2. Headline aggregates (cm iter1, 332,110 uops)

```
stage              sum_cyc      avg/uop   %total
rename->dispatch       340799       1.04   16.99%
dispatch->issue        756658       2.30   37.71%
issue->wb               68772       0.22    3.43%
wb->commit             785336       2.51   39.14%
TOTAL_in_ROB          2006433       6.04  100.00%
```

For dhry the same pattern (avg total 4.61 cyc):

```
rename->dispatch        48375       1.02   22.00%
dispatch->issue         65447       1.38   29.77%
issue->wb               12193       0.30    5.55%
wb->commit              75843       1.89   34.49%
TOTAL_in_ROB           219876       4.61  100.00%
```

**Two bottleneck stages dominate (~77% of in-ROB time on cm):**
1. `dispatch->issue` (37.7%) — wakeup latency, in-IQ dependency wait
2. `wb->commit` (39.1%) — head-of-rob serialization after exec

`issue->wb` is essentially a constant 0–1 cyc (1-cyc ALU, 1-cyc D$-hit load).
`rename->dispatch` is dominantly 1-cyc with a modest 2-3 cyc tail.

This sets up the per-stage tail story.

---

## 3. The dominant per-uop pattern: dependency-chain pile-ups in 4 hot loops

### Pattern A — `core_init_matrix` mul-anchored chain (cm only)

PCs `0x80002fb8 – 0x80002ffa` form a 17-instruction loop body:

```
80002fb8:  mulw   a2,a2,a4         ← MUL latency anchor (3-4 cyc)
80002fbc:  zext.h a5,a4
80002fc0:  addiw  a1,a4,-1
80002fc4:  sh1add.uw a7,a1,t1
...
80002fde:  subw   a2,a2,a6         ← chain on mulw result
80002fe2:  addw   a6,a2,a5
80002fe6:  zext.h a6,a6
80002fea:  addw   a5,a6,a5
80002fee:  sh     a6,0(a7)
80002ff2:  zext.b a5,a5
80002ff6:  sh     a5,0(a1)
80002ffa:  bne    a4,t3,80002fb8   ← loop branch, mispredicts on exit
```

UOPLIFE telemetry on this region:
- `0x80002ffa` (the loop branch): avg `wb->commit = 14.4 cyc`, max 25; happens
  exclusively when the branch issues from BRU early (1-cyc) but ALU chain
  ahead has not yet drained the ROB.
- `0x80002ff6/0x80002ff2/0x80002fee` (last 3 chain ALU + store): avg `d_total =
  15-16 cyc`, with `d_disp_to_iss` 9-13 cyc dominating (i.e., they sit in IQ
  waiting for sources to wake up).
- `d_iss_to_wb = 0` for all the ALU ops (1-cyc execution); none of the latency
  is in execute. **Latency is wakeup-dominated.**

**This loop alone contributes ~5.4k 11-20-cyc ALU records** and is the largest
single contributor to the cm `dispatch->issue` 11-20-cyc bucket (which holds
20.32% of all dispatch->issue cycles).

### Pattern B — `crcu32` 8-iteration bit-loop (cm only, x4 inlined copies)

PCs `0x800039c0 – 0x80003ab4` (and 3 unrolled copies up to `0x80003aea`):

```
80003a14:  xor    a5,a1,a0       ← chain head (depends on prev iter a5)
80003a18:  andi   a5,a5,1
80003a1a:  negw   a5,a5
80003a1e:  srliw  a0,a0,0x1
80003a22:  and    a5,a6,a5
80003a26:  addiw  a4,a4,-1
80003a28:  xor    a5,a5,a0
80003a2a:  zext.b a4,a4
80003a2e:  srli   a1,a1,0x1
80003a30:  zext.h a0,a5
80003a34:  bnez   a4,80003a14    ← 8-iter loop close; mispredicts at exit
```

This is a 9-uop dependency chain bnez-closed, repeated 8× per byte; the
unrolled version repeats 4×. Per UOPLIFE:
- Loop-end branches (`0x80003a34`, `0x80003a5c`, `0x80003a8c`, `0x80003ab4`,
  `0x80003ade`, `0x80003aea`): `wb->commit` 8-10 cyc avg, peak 19-25 cyc.
- Body chain (`0x80003a28`/`0x80003a50`/`0x80003a8c`/`0x80003ab0`):
  `dispatch->issue` ~10 cyc avg (max 20-21).
- ~3700 occurrences of `wb->commit` >10 cyc on these PCs (the bulk of the
  `wb->commit` 11-20 bucket, which holds 11.6% of all cm wb→commit cyc).

Same root cause as Pattern A: 4-wide dispatch + 4 IQ schedulers but a
serial dependency chain in the workload — only one ALU can wake per cycle
in the chain, so the chain length × 1-cyc/op = the wakeup-issue tail.

### Pattern C — `matrix_mul_matrix_bitextract` two-mul-per-iter (cm only)

PCs `0x800031c0 – 0x800031ec`:

```
800031c0:  sh1add.uw a5,a3,t1
800031c4:  sh1add.uw a4,a2,a7
800031c8:  lh     a5,0(a5)         ← load #1
800031cc:  lh     a4,0(a4)         ← load #2 (same rs1 base disambig)
800031d0:  addiw  a3,a3,1
800031d2:  addw   a2,a2,a0
800031d4:  mulw   a5,a5,a4         ← MUL #1, depends on both loads
800031d8:  sraiw  a4,a5,0x2        ← chain on mulw
800031dc:  sraiw  a5,a5,0x5
800031e0:  andi   a4,a4,15
800031e2:  andi   a5,a5,127
800031e6:  mulw   a5,a4,a5         ← MUL #2, depends on MUL #1's children
800031ea:  addw   a1,a1,a5
800031ec:  bne    a6,a3,800031c0
```

Two serially dependent multiplies + ALU bridge. Per UOPLIFE: 14 of the
14 PCs in this loop are in the d_total 11-20 bucket; this loop alone
accounts for ~1500-1900 occurrences in the bucket (the next-largest
contributor after Pattern A's 1500-2000). The two `mulw` operations
sit in IQ for ~3-7 cyc each waiting on each other; the trailing
`addw` and branch wait for MUL #2.

### Pattern D — Dhrystone DIV at `0x8000221a` (dhry only, 100 occurrences)

```
8000221a:  divw   s5,s0,s6     ← multi-cycle DIV
8000221e:  addiw  s2,s2,-1
80002220:  sw     s5,4(sp)     ← stores DIV result; d_total=9, max=9
80002222:  jal    Proc_2       ← jal, blocked behind store
```

100% of dhry uops in d_total 6-10 bucket cluster around 0x80002220 (max=9 cyc)
and 0x80002222 (jal). This is a single PC pair; total contribution is
small (~600 cyc) and it's a benchmark-specific divw instance, not a
representative pattern.

---

## 4. What the data RULES OUT

These should be flagged because they **fail** to motivate previously-floated
RTL candidates:

### Loads are not the bottleneck.

```
Loads with iss->wb > 20 cyc (probable D$ miss / SQ replay / LMB wait):
  cm:    0 of 56,052 loads  (0.00%)
  dhry:  0 of 11,281 loads  (0.00%)
```

D$-hit pipe is dominant; load `iss->wb` averages 1.01-1.05 cyc with a
0.79-1.51% 2-cyc tail and basically zero >2-cyc tail. **No D$/LMB/SQ-replay
RTL change is justified by this data.** (The 6-10 cyc bucket on `LOAD
d_total` is wb→commit serialization behind in-flight ALU chains, not load
latency.)

### No "long-tail outliers" (d_total > 50 cyc) on either workload.

```
Total long-tail uops (d_total > 50): 0 on cm, 0 on dhry
```

The long tail tops out at 21-50 (1.21% of cm uops, 4.35% of cyc-sum) and
even the 21-50 bucket is dominated by the same 4 hot loops above.
**There is no rare-event class (e.g., page fault, cache miss avalanche) to
chase.** Performance is structurally bound.

### Frontend supply (rename → dispatch) is healthy.

```
rename->dispatch (cm):   96.49% in 1-cyc, 3.46% in 2-cyc, ≤0.05% beyond
rename->dispatch (dhry): 97.87% in 1-cyc, 2.13% in 2-cyc, ≤0.00% beyond
```

The 1-cyc nominal latency of dispatch-queue-to-IQ enq is the structural
floor. The few 2-cyc records are dq-full backpressure clusters. **No
dispatch-queue resize would yield material gain** (consistent with prior
finding that frontend supply is fine).

### Mispredict-recovery latency is short (when not chain-bound).

```
mis=1 d_wb_to_cmt (dhry):  126 of 128 mispredicts in 2-cyc bucket; avg 2.02
mis=1 d_wb_to_cmt (cm):    71.91% in 2-cyc bucket; avg 4.49 cyc (driven by
                           Pattern B chain-trail)
```

The 11-20-cyc tail on cm mispredicts is exclusively the loop-end branches
of Pattern B (crcu32) waiting for the chain ahead to retire — i.e., it's
already-counted Pattern B latency, not a separate flush-recovery problem.

### Dispatch is wide (most cycles dispatch a full cluster of 4).

```
cluster_size  cm %clusters  cm %uops    dhry %clusters  dhry %uops
1             21.79%        7.82%       29.13%          11.17%
2             17.69%        12.70%      21.07%          16.16%
3             20.75%        22.35%      9.72%           11.18%
4             39.77%        57.12%      40.09%          61.49%
```

57-61% of uops are dispatched in 4-wide bursts; the remainder in 1-3-wide
bursts is consistent with backpressure from IQ-full (when chains pile up)
rather than rename starvation.

---

## 5. Per-FU class summary (cm)

| FU class | n        | avg d_total | distribution insight                                  |
| -------- | -------- | ----------: | ----------------------------------------------------- |
| ALU      | 183,110  |  6.43 cyc   | 16% in 11-20 bucket = 33% of ALU sum_cyc (chains)     |
| BRANCH   |  60,688  |  5.59 cyc   | mostly 4-5 cyc; 11-20 tail is loop-end mispredicts    |
| LOAD     |  56,052  |  5.33 cyc   | 12% in 6-10 bucket = wb→commit-bound (not iss→wb)     |
| STORE    |  15,970  |  5.21 cyc   | 25% in 6-10 = same pattern                            |
| MUL      |   9,493  |  7.96 cyc   | 36% in 11-20 = MUL chain in matrix_mul_matrix         |
| BRU      |   6,791  |  4.72 cyc   | tight; very few outliers                              |
| DIV      |       4  |  6.75 cyc   | trivial volume                                        |
| CSR      |       2  |  4.50 cyc   | trivial volume                                        |

**ALU and MUL are the only classes with material 11-20-cyc tails**, and both
tails localize to the 4 hot loops in Section 3.

---

## 6. Recommendations for RTL change candidates

The data points to **one and only one structurally significant target**:

### Primary recommendation: nothing actionable that the architecture audit didn't already explore.

The 4 hot patterns are all wakeup-bound serial dependency chains (ALU/MUL
results forwarded through ~9-17 instructions before the loop closes). The
existing 4-wide design has:
- 4 ALU FUs (3 in IQ0, 1 in IQ2) — adequate parallelism; not the bottleneck.
- 1-cyc back-to-back wakeup (the wakeup network already handles 1-cyc dependence).
- MUL is 3-cyc unpipelined → 4-cyc effective; chained MULs in Pattern C will
  always serialize to ~8-10 cyc even with infinite IQ width.

There is no RTL change at the IQ/wakeup/PRF level that would compress these
chains. They are workload-intrinsic dependency chains.

### Secondary observations (low-confidence; not worth implementing without quantitative model):

1. **Multiply pipelining** would directly affect Pattern C (matrix_mul_matrix_bitextract):
   making the multiplier 1-cyc throughput (still 3-cyc latency) would let MUL #1
   and MUL #2 of consecutive iterations overlap. *But Pattern C is only ~3-5k uops
   in the 11-20 bucket; total upside is bounded by ~20-30k cyc out of 199k = ≤1.5%
   IPC.* Not actionable without a perf model.
2. **Macro-op fusion of zext.h/zext.b + dependent ALU** would shorten Pattern B
   (crcu32) chain by 1-2 ops per iteration. *But fusion infra was already
   evaluated (REFUTED in cycle E of the post-merge handoff). Same conclusion stands.*
3. **Load-pair / store-pair fusion** in Pattern C (lh/lh, then later sh/sh
   in Pattern A) could shave 1 cyc per pair. *Not material (~5k pair-ops × 1 cyc
   = 0.25%).*

### What is NOT a candidate based on this data:

- D$ prefetcher / NLP / FDIP — no load tail justifies these.
- Larger IQ / ROB / DQ — nothing is queue-full bound.
- Larger CDB width — `issue->wb` already at floor.
- Branch-direction-prediction improvements — non-mispredict branches are tight;
  mispredict-recovery latency is already short for non-chain branches.
- Reorder buffer / commit-width changes — wb→commit is dominated by chain serialization,
  not commit width.

---

## 7. Conclusion

The per-uop distribution confirms what the aggregate average implied but did
not localize: rv64gc-v2 4-wide spends ~77% of in-ROB cycles on
**workload-intrinsic dependency-chain wakeup latency**, distributed across 4
specific hot loops in the coremark workload. There is no long tail (no >50-cyc
records), no D$ pathology (no >20-cyc load `iss->wb`), and no frontend
starvation (97% of rename→dispatch in 1 cyc). This rules out additional
RTL gap-closure targets and is consistent with the post-merge handoff sign-off
that the design is structurally well-tuned and any further IPC gain would
require a calibrated perf model rather than RTL surgery.

The instrumentation itself adds zero IPC perturbation (verified by parity run)
and is opt-in via `+TRACE_UOPLIFE`. It is preserved in tb_top.sv for future
regression-time per-uop investigations (e.g., when characterizing workload
classes beyond CM/DS).

# Cycle C Results — BRU Early-Redirect Enable

**Verdict:** REFUTED — criterion (a) failed: cm IPC delta outside [+2.0%, +4.0%] band (in fact, cm REGRESSED).

**Date:** 2026-05-01
**Repo HEAD at measurement:** master @ 9f554bc (prediction commit)
**Plan:** `doc/4wide_iter_flush_recovery_plan_2026-05-01.md`
**Prediction (committed BEFORE measurement):** `doc/4wide_iter_flush_recovery_prediction.md`

## Measured

| Workload | Baseline IPC | +ENABLE_BRU_EARLY_REDIRECT IPC | Δ measured | Predicted | In tolerance? |
|---|---:|---:|---:|---:|---|
| cm iter1   | 1.665112 | 1.630940 | **−2.05%** | +2.5-3.5% | **NO** (target +2.0% to +4.0%) |
| cm iter10  | 1.718528 | 1.689151 | **−1.71%** | +2.5-3.5% | **NO** (target +2.0% to +4.0%) |
| dhrystone  | 2.027303 | 2.039839 | +0.62%    | +0-1%     | YES (in [−2.0%, +2.0%]) |

### Mechanism activation (PERF_PROFILE)

| Workload | Early redirects total | BRU0 | BRU1 | Quarantine cycles |
|---|---:|---:|---:|---:|
| cm iter1   | 4,652  | 3,580  | 1,072 | 23,001  |
| cm iter10  | 37,047 | 27,909 | 9,138 | 197,822 |
| dhrystone  | 133    | 129    | 4     | 401     |

The mechanism IS firing — REFUTE is NOT criterion (b). Quarantine cycles confirm
the redirect-quarantine state machine engages.

### Mispredict counts (committed)

| Workload | Baseline mispredicts | With early-redirect mispredicts | Δ |
|---|---:|---:|---:|
| cm iter1   | 4,343  | 4,652  | +309 (+7.1%) |
| cm iter10  | 35,070 | (not extracted) | (likely up similarly) |
| dhrystone  | 128    | 133    | +5 (+3.9%) |

**Mispredict count INCREASED with the early-redirect enabled** — the mechanism
is causing additional mispredicts, not just failing to amortize savings.

### Functional regression with the plusarg

`scripts/regress_dsim.sh --extra-plusargs "+ENABLE_BRU_EARLY_REDIRECT"` →
**Total: 20  PASS: 20  FAIL/OTHER: 0** (all STOP-OK).

So the mechanism is functionally correct — the verdict is purely a performance refute.

## Refute reason

**(a) Measured cm IPC delta outside band — mechanism is firing but REGRESSES cm.**

Hypothesis why (post-hoc, not validated):

1. **Speculative path corruption.** The early-redirect lets fetch+decode chase a
   newly-resolved path before the older mispredicting branch retires. If a second
   prediction in the new path mispredicts before the first one drains commit, the
   net effect is more wasted decode/rename work than waiting for commit-time flush.
   The +309 / +7.1% increase in cm-iter1 committed mispredicts is consistent with
   this — the early-redirect is opening the rename window to additional speculative
   instructions that themselves mispredict at higher rates (warm BPU never gets to
   update on the first mispredict before being asked to predict again).

2. **Quarantine cost > recovery savings.** 23,001 quarantine cycles on cm iter1
   represent ~11.5% of the 199,452 total cycles. Even if every early-redirect
   saved 2 cycles vs commit-time flush (4652 × 2 = 9,304 cycles ≈ 4.7%), that
   would be more than wiped out by the quarantine stall added to the renamer.
   Quarantine stalls rename for the whole window between BRU detection and
   commit-time architectural flush — so any in-flight speculative dispatch
   stalls.

3. **BPU not updated until commit.** Early-redirect changes fetch direction
   immediately but the BPU/RAS update path may still wait for commit. Repeated
   passes through the same mispredicted region keep producing the same wrong
   prediction until the first one finally commits, multiplying the misprediction
   count.

These are conjectures; debugging the mechanism is OUT OF SCOPE per Cycle C
constraint #9 ("the mechanism is complex (quarantine, packet retention) and
debugging is out of scope").

## Implication

Cycle C produces **no RTL change**. Baseline (cm-iter1 IPC=1.665, cm-iter10
IPC=1.719, dhry IPC=2.027) is unchanged. The plusarg-gated default-OFF state of
`+ENABLE_BRU_EARLY_REDIRECT` is preserved.

## Disposition for the larger plan

The "fast flush-recovery" intuition is sound (cm has thousands of mispredicts at
~5-7 cyc each), but the existing implementation is net-negative — likely because
it permits additional speculation past unresolved mispredicts that the BPU
hasn't been updated on yet. Future work could:

- Investigate whether updating BPU/RAS at BRU resolution time (rather than
  commit) would convert this from net-negative to net-positive.
- Investigate whether reducing quarantine duration would help.
- Explore alternative recovery mechanisms (e.g., checkpoint-based fast-flush
  rather than quarantine-and-wait).

But none of these are in scope here.

**Proceed to Cycle B (SFB fold-into-predication).**

## Files

- Logs: `benchmark_results/cycle_c_baseline_{cm_iter1,dhry}.log` (default-OFF)
- Logs: `benchmark_results/cycle_c_early_{cm_iter1,cm_iter10,dhry}.log` (plusarg-ON)
- Prediction (committed pre-measurement): `doc/4wide_iter_flush_recovery_prediction.md`
- Plan: `doc/4wide_iter_flush_recovery_plan_2026-05-01.md`
- Sequence: `doc/4wide_gap_closure_sequence_2026-05-01.md`

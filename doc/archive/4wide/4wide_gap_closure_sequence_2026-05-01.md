# 4-Wide Gap Closure — 3-Cycle Sequence Design

**Date:** 2026-05-01
**Status:** DESIGN — sequence + per-cycle scopes; Cycle A plan comes next via writing-plans
**Repo HEAD at design time:** `master @ 0809226`
**Companion docs:**
- `doc/4wide_perf_gap_results_2026-05-01.md` — completed gap analysis (corrected)
- `doc/4wide_signoff_2026-05-01.md` — refreshed PARTIAL-FLOOR sign-off (corrected)
- `doc/4wide_perf_gap_analysis_2026-05-01.md` — methodology (data-driven discipline)

---

## Background

The completed 4-phase gap analysis (Phases A–D) refuted most candidate
hypotheses or classified them as intrinsic. The remaining actionable
follow-up RTL candidates were sourced from the Reference Core A paper
(Zhao et al., CARRV 2020) and Reference Core A source. From those, the user
selected three for sequenced execution, ordered low-risk first:

1. Cycle A — uBTB / NLP sizing (calibration; smallest blast radius)
2. Cycle C — Flush-recovery latency narrowing (medium risk)
3. Cycle B — SFB (Short-Forward-Branch) fold-into-predication (highest risk, biggest expected win)

The other two candidates from the results doc — TAGE-L loop predictor
verification and more-aggressive spec wakeup — are NOT in this sequence.

## Sequence overview

| Cycle | Hypothesis | Files touched | Predicted IPC win | Risk |
|---|---|---|---|---|
| A | uBTB / NLP undersized vs Reference Core A (large config) | `rv64gc_pkg.sv` + 1–2 BPU files | cm +1–3%, dhry +1–3% | Low |
| C | Flush-recovery latency reducible from 5–7 cyc → 3–4 cyc | core_top flush pipe + BPU/fetch redirect path | cm +3–5%, dhry +0–1% | Medium |
| B | SFB fold-into-predication absent in our design | decode + rename + ALU predicate + ROB tracking | dhry +5–15%, cm +3–8% | High |

Each cycle is its own write-plan + subagent-driven-execution. Plans for
C and B are written **after** the prior cycle lands, so predictions
incorporate updated baseline numbers.

## Per-cycle execution shape (applies to all 3)

1. **Investigation step** (read-only): characterize current state vs the
   reference (Reference Core A source / Reference Core A paper) to confirm the hypothesis
   has signal. If current state already matches the reference, the
   hypothesis is REFUTED-no-change — document and proceed to next cycle.
2. **Predict step:** write the predicted IPC delta on cm + dhry to a
   per-cycle prediction note (`doc/4wide_iter_<id>_prediction.md`),
   commit it BEFORE any RTL change. This gates the cycle's discipline.
3. **RTL change step:** apply the targeted edit. One iteration = one
   focused change; no bundling.
4. **Validate step:** build + functional regression (must remain 21/21)
   + clockcheck (must remain 3/3 PASS, 0 diverging) + cm + dhry + cm10
   measurement.
5. **Commit-or-revert step:** compare measured vs predicted. Per the
   30%-rule (relative) for predicted ≥3% IPC win, or per the **±0.5%
   IPC absolute tolerance** for predicted <3% (the methodology
   adjustment for small predictions). If in-range and no regression on
   the other workload (±2%): commit. If out-of-range or regression:
   revert RTL, mark hypothesis REFUTED, document.

## 30%-rule small-delta adjustment

Per the methodology doc (`doc/4wide_perf_gap_analysis_2026-05-01.md`
Section 4.4), Phase D RTL change rule #5 specifies the 30%-rule as
"if measured-vs-predicted divergence > 30%, hypothesis unsound." For
predicted IPC win < 3%, this produces too-tight bands (e.g., predicted
+2% → in-range = +1.4% to +2.6%, indistinguishable from cycle-to-cycle
noise).

For the gap-closure sequence, replace the relative 30% rule with an
**absolute ±0.5% IPC tolerance** when the predicted win is <3%. So for
predicted +2% IPC: any measured delta in [+1.5%, +2.5%] is "in range".

For predicted ≥3% IPC win, the original 30%-rule applies.

## Cycle A scope (the immediate next plan)

**Hypothesis:** rv64gc-v2's uBTB and/or next-line predictor are undersized
relative to Reference Core A, contributing to the BPU-recovery cycles even on the
healthy-BPU dhry workload.

**Investigation steps (in the Cycle A plan):**
- Inspect `src/rtl/core/include/rv64gc_pkg.sv` for uBTB and NLP
  parameter declarations
- Inspect the BPU module(s) under `src/rtl/core/fetch/` or `bpu/` for
  the actual storage instantiations and any cascade dependencies
- Look up Reference Core A uBTB and NLP sizes from
  `src/main/scala/v4/ifu/btb.scala` and related
- Compare; if our values < Reference Core A's, bump them; if equal-or-larger, REFUTE

**Files likely touched if change applies:**
- `src/rtl/core/include/rv64gc_pkg.sv` (parameter values)
- 1–2 BPU module files (storage table widths, possibly counter widths)

**Validation gates:**
- Functional 21/21 PASS
- Clockcheck 3/3 PASS, 0 diverging
- cm + dhry + cm10 measured
- Predicted: cm +1–3%, dhry +1–3% (small-delta tolerance: ±0.5% IPC)

## Stopping conditions for the sequence

Sequence terminates when either:
- (a) Both workloads at floor: cm CM/MHz ≥ 6.2 AND dhry DMIPS/MHz ≥ 4.00 → adopt floor sign-off
- (b) All 3 cycles complete (whether SUCCESS or REFUTED) → adopt cumulative result as final sign-off
- (c) Any cycle produces an unrecoverable regression (functional or clockcheck broken) → halt sequence, escalate to user

## Out of scope (do NOT pursue)

- Cycles outside the 3 selected (TAGE-L, spec wakeup tightening) — held for a future sequence
- Dcache hit latency reduction (per Reference Core A research correction — already faster than Reference Core A)
- Dhry compiler/binary investigation (per Reference Core A research correction — ≤3% contribution)
- Reverting any narrowing decision (CDB widen, IQ depth, etc.)
- Re-investigating any of the refuted hypotheses (H1, H5, H6 from the prior gap analysis)
- Modifying `src/rtl/core/lsu/lsu.sv` misalign-hold patch (sign-off-class win, frozen)

## Deliverables expected by sequence end

- `doc/4wide_iter_uBTB_prediction.md` (Cycle A) + commit-or-revert evidence
- `doc/4wide_iter_flush_recovery_prediction.md` (Cycle C) + evidence
- `doc/4wide_iter_sfb_prediction.md` (Cycle B) + evidence
- Sequence summary appended to or replacing `doc/4wide_signoff_2026-05-01.md`

Each cycle's plan is written separately via writing-plans, after the
prior cycle's measurement informs the next cycle's predictions.

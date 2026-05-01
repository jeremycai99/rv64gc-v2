# Cycle C Prediction — BRU Early-Redirect Enable

**Date:** 2026-05-01
**Repo HEAD at prediction:** master @ c1b3879
**Cycle:** C (flush-recovery latency narrowing via BRU early-redirect)
**Sequence design:** doc/4wide_gap_closure_sequence_2026-05-01.md

## Hypothesis

The existing `+ENABLE_BRU_EARLY_REDIRECT` mechanism (already implemented at
core_top.sv:740-775 but plusarg-gated OFF by default) reduces the mispredict
recovery cost by allowing fetch + decode to redirect to the correct path
immediately at BRU resolution, instead of waiting for the mispredicting
branch to reach commit. Cm has 4,343 mispredicts at ~5-7 cyc each ≈ ~25k
cycles of recovery; if the early-redirect saves 1-2 cycles per mispredict,
that's ~5k cycles saved ≈ 2.5% of cm cycles.

## Predicted change

- Step A (validation): run cm + dhry with `+ENABLE_BRU_EARLY_REDIRECT` plusarg
- Step B (if Step A wins): promote default by editing `core_top.sv:252-280`
  to enable in both SIMULATION and synthesis paths

## Predicted IPC delta (Step A measurement)

- cm iter1: 1.665 → 1.71 ± 0.015 (predicted +2.5-3.5%)
- cm iter10: 1.719 → 1.76 ± 0.015 (predicted +2.5-3.5%)
- dhrystone: 2.027 → 2.04 ± 0.010 (predicted +0-1%; dhry has only 128 mispredicts)

## Tolerance band (small-delta rule, predicted <3%)

±0.5% IPC absolute. cm in-range = +2.0% to +4.0%. dhry in-range = -0.5% to +1.5%.

## Confirmation criterion

Measured cm IPC delta in [+2.0%, +4.0%] AND dhry no-regression beyond ±2% AND
PERF_PROFILE shows non-zero "Early redirects total" + "Quarantine cycles" (proves
the mechanism is firing).

## Refutation criterion (REVERT triggers)

(a) Measured cm IPC delta outside [+2.0%, +4.0%]
(b) PERF_PROFILE still shows 0 early-redirects (plusarg didn't activate)
(c) Functional regression breaks 21/21
(d) Clockcheck divergence on non-mispredict-recovery cycles

# Cycle E Results — ALU3/DIV/CSR Bypass Slot

**Date:** 2026-05-02
**Verdict:** REFUTE — measured Δ = 0% (out of ±0.5% IPC absolute band; predicted +1.0–1.5%)
**RTL untouched** — change reverted; baseline preserved.

## Measured

| Workload | Baseline | With bypass[5] | Δ | In tolerance? |
|---|---:|---:|---:|---|
| cm iter1 IPC | 1.665112 | 1.665112 | **+0.00%** | NO (predicted +1.0–1.5%; in-range +0.5% to +2.0%) |
| cm iter10 IPC | 1.718528 | 1.718528 | **+0.00%** | NO |
| dhry IPC | 2.027303 | 2.027303 | **+0.00%** | (predicted +0.5–1.0%; in-range 0% to +1.5%) — at the lower edge |

**Bit-identical IPC** across all 3 workloads with the new bypass slot enabled.

## Validation gates (all passed)

- Functional regression: 20/20 PASS, all proper STOP-OK
- Clockcheck 3/3 PASS, 0 diverging cycles on bench_loop_100, bench_load, bench_unrolled_5
- Build clean

## Why the change had zero effect

The original code comment at `core_top.sv:3007-3009` (now reverted) said:

> Dropped vs 6-wide: ALU3/DIV/CSR (CDB[3]): DIV is multi-cycle, bypass rarely
> fires; CSR is infrequent and serialised; consumers fall back to PRF read.

This rationale was **correct on the workloads we care about**. The architectural
audit (`doc/4wide_arch_diff_2026-05-02.md`) flagged the missing bypass as a
~1-2% IPC opportunity, but the prediction over-estimated the impact:
- DIV/CSR rarely fire (cm head_not_ready_div=14 cyc, csr=0 cyc per Phase A inventory)
- ALU3 is the lowest-priority ALU lane in dispatch arbitration; most uops route
  to ALU0/1/2
- When CDB[3] does fire, the consumers had already gotten their operand via
  PRF (PRF write latches at T+3, consumer reads PRF at T+3 — same cycle as bypass would deliver)

In short: CDB[3] activity is too rare to influence aggregate IPC, AND the
existing PRF-read fallback covers the few cases that do occur.

## Implication for the audit's predictions

The audit's structural diff identified 5 differences predicting ~6-10% cm IPC loss.
This (item #4 in the audit table, "ALU3 lane not bypassed") was predicted at +1-2%
but measured at 0%. The audit's prediction model OVER-WEIGHTED this item.

This data point updates the audit's calibration:
- Items #1, #2, #3, #5 (IQ depth fragmentation, MUL co-location, DIV/CSR
  co-location, fewer total INT IQ entries) — addressed by Variant A (IQ reorg)
- Item #4 (this) — REFUTED; bypass coverage is NOT the gap source

The Variant A prediction (+3-5% on cm) is still credible because it addresses
the FOUR remaining audit items, but it's been calibrated downward: if Variant B
predicted +1-2% and measured 0%, Variant A's +3-5% prediction may also be
optimistic. Realistic expectation: +1.5-3% on cm from Variant A.

## Next step

Proceed to Variant A (INT IQ reorganization, 2×32 ALU + 1×16 UNQ). It's the
larger blast radius (~250 LOC, 2-3 days, 4-5 files) but addresses the bulk of
the audit's identified differences. Calibrated prediction: +1.5-3% on cm,
+0.5-1% on dhry.

If Variant A also REFUTES or comes in below predicted, the cm gap is more
intrinsic than the audit suggested and the dhry mystery (~30% unexplained)
becomes the dominant remaining work.

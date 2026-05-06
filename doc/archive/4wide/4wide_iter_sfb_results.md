# Cycle B Results — SFB Fold-into-Predication

**Date:** 2026-05-01
**Verdict:** REFUTED-on-investigation
**Plan:** `doc/4wide_iter_sfb_plan_2026-05-01.md`
**Investigation:** `doc/4wide_iter_sfb_investigation.md` (commit `0acb007`)

## Investigation findings

- dhry SFB-eligible mispredict cycles: 12 of 23,514 total cycles (0.05%)
- cm SFB-eligible mispredict cycles:   1842 of 199,452 total cycles (0.92%)
- Predicted SFB win: dhry +0.05%, cm +0.92%
- Decision threshold: dhry >=1%, cm >=2% — **failed for both**

Per the cross-reference of SFB-eligible static branches against committed-mispredict PCs:
- **dhry:** 7 static SFB-eligible branches; only 2 ever appear in the top mispredict list (1 event each). Of 92 dhry cond branches, 83 are backward loop edges.
- **cm:** 35 static SFB-eligible branches; 21 appear in the top mispredict list, capturing 307 of 4256 cond mispredict events (7.2%). The hottest cm mispredict PCs (521, 324, 204, 203, 186, 168, ...) all fall *outside* the SFB <=32B forward window.

## Why the RTL effort is not justified

Implementing minimal SFB infrastructure requires:
- Decode-pattern detection (~50 lines)
- Predicate signal added to uop struct (~30 lines)
- Rename pipeline propagation (~80 lines)
- ALU predicate handling + writeback suppression (~50 lines)
- ROB tracking (~40 lines)
- Clockcheck allowlist updates for new predicate-related divergences
- Functional regression maintenance during stepwise build-up (3-5 build/test cycles)

Total: ~250 lines RTL across 4-5 files, ~2-4 days of careful subagent work.

For a predicted gain <1% IPC on both workloads we care about, the engineering cost is not justified. Adopt the cumulative state as the final sign-off.

## Cumulative gap-closure result (Cycles A + C + B)

| Cycle | Verdict | Why | Δ to baseline |
|---|---|---|---|
| A — uBTB sizing | REFUTE-on-investigation | rv64gc-v2 BPU is BIGGER than BOOM (8x BTB, has Statistical Corrector, larger TAGE tags). No undersize to bump. | 0 |
| C — BRU early-redirect | REFUTE-on-measurement | Mechanism fired correctly (4652 early redirects on cm) but net-NEGATIVE (cm IPC -2.05%): early speculation past unresolved mispredicts multiplied wrong-path work (mispredict count +7.1%). | 0 |
| B — SFB | REFUTE-on-investigation | Insufficient SFB-eligible mispredict patterns: dhry 0.05% predicted, cm 0.92% predicted, both below thresholds. | 0 |

Final 4-wide measurements remain at:
- cm iter1: 5.01 CM/MHz
- cm iter10: 5.37 CM/MHz
- dhrystone: 2.42 DMIPS/MHz

PARTIAL-FLOOR sign-off (`doc/4wide_signoff_2026-05-01.md`) stands as final.

## What this tells us

The 3-cycle gap-closure sequence ran the data-driven methodology to its conclusion. All three cycles produced data-grounded REFUTEs:

- **A:** design is well-equipped (BPU > BOOM)
- **C:** mechanism that "should" help is net-negative (counter-intuitive but measured)
- **B:** workload doesn't have enough SFB-eligible patterns

This is consistent with the prior gap analysis (`doc/4wide_perf_gap_results_2026-05-01.md`) that classified most remaining gap as INTRINSIC. The narrowing decision (6-wide -> 4-wide) is correct; the remaining −19% (cm) / −39% (dhry) gap is structural — workload+narrowing — not addressable via parameter tuning, mechanism enabling, or feature addition without major redesign.

## Recommendation

Adopt PARTIAL-FLOOR as the final sign-off. Document this 3-cycle sequence as the closing record of the rv64gc-v2 4-wide refactor's performance-iteration work.

The discipline followed across all three cycles (predict-before-change, threshold-gated decisions, REFUTE on data not narrative) is the deliverable; the absence of RTL deltas is the correct outcome.

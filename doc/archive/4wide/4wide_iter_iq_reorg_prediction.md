# Cycle F Prediction — INT IQ Reorganization (Variant A)

**Date:** 2026-05-02
**Repo HEAD at prediction:** master @ b5a6138 (post Cycle E REFUTE)
**Cycle:** F (audit-driven, Variant A from `doc/4wide_arch_diff_2026-05-02.md`)

## Hypothesis

Per the BOOM v4 ↔ rv64gc-v2 architectural audit, the 4 remaining (post Cycle E) structural
INT IQ differences contributing to the cm gap are:

1. **IQ depth fragmentation:** rv64gc-v2 splits across 3×24-entry IQs (72 total); BOOM has unified 40-entry IQ_ALU + separate IQ_UNQ
2. **MUL co-located with ALU2** on shared issue port (u_iq1, NUM_SELECT=1)
3. **DIV/CSR co-located with ALU3** on shared issue port (u_iq2, NUM_SELECT=1)
4. **22% fewer total INT IQ entries** (72 vs 92 in BOOM Mega)

Variant A addresses all four by:
- Restructuring 3×24 → 2 ALU IQs (32 each) + 1 UNQ IQ (16 entries) = **80 total** (+11% vs current)
- ALU IQs hold ALU/BRU only; UNQ IQ holds MUL/DIV/CSR
- Both ALU IQs at NUM_SELECT=2; UNQ at NUM_SELECT=1 (MUL/DIV/CSR are infrequent)

## Predicted RTL change scope

- **Modify:** `src/rtl/core/include/rv64gc_pkg.sv` — bump IQ_INT_DEPTH 24→32, add IQ_UNQ_DEPTH=16, NUM_INT_IQS may stay 3 but semantics differ
- **Modify:** `src/rtl/core/rv64gc_core_top.sv` — IQ instantiations (rename to u_iq_alu0/u_iq_alu1/u_iq_unq), dispatch routing logic (uop fu_type → IQ assignment), ALU/MUL/DIV/CSR consumer wiring
- **Modify:** `src/rtl/core/issue/dispatch_queue.sv` — route fu_type to per-IQ enqueue
- **Possibly modify:** `src/rtl/core/issue/issue_queue.sv` — confirm parameterization handles new depths
- **Possibly modify:** `src/tb/tb_top.sv` — issue-stall classification counter signals (u_iq0/1/2 → u_iq_alu0/u_iq_alu1/u_iq_unq) so PERF_PROFILE keeps working

Estimated: ~250 LOC across 4-5 files. 2-3 days subagent work.

## Predicted IPC delta (calibrated from Cycle E REFUTE)

The audit predicted +3-5% cm. Cycle E (smaller change, predicted +1-1.5%) measured 0%, so
calibration suggests the audit's IPC predictions are ~50% optimistic. Adjusted prediction:

- cm iter1: 1.665 → ~1.700 (predicted **+1.5-3.0%**)
- cm iter10: 1.719 → ~1.755 (predicted **+1.5-3.0%**)
- dhrystone: 2.027 → ~2.040 (predicted **+0.5-1.0%**)

## Tolerance band

Predicted upper bound ~3% sits at the boundary of small-delta vs relative tolerance. Using
**±0.5% IPC absolute tolerance** for consistency with prior Cycle E (small-delta rule):
- cm in-range = +1.0% to +3.5%
- dhry in-range = 0% to +1.5%

## Confirmation criterion

Measured cm IPC delta in [+1.0%, +3.5%] AND dhry no-regression beyond ±2% AND
PERF_PROFILE shows reduction in `issue_stall_operand_cyc` or `head_not_ready_unknown_cyc`
(direct mechanism evidence: more issue capacity → fewer operand-stall cycles).

## Refutation criterion

(a) Measured cm IPC delta outside [+1.0%, +3.5%] — IQ reorg didn't help as predicted
(b) Functional regression breaks 20+/20 — restructure introduced a bug
(c) Clockcheck divergence — pipeline timing perturbed beyond allowlist
(d) dhry IPC drops >2% — side effect on procedure-call-heavy code

## Acceptance philosophy

Per user directive (2026-05-02): "do Variant A blindly... we don't have a right perf
model anchor for the diminishing returns. Hence no meaningful trace investigation."

We're not pre-judging by Cycle E's REFUTE. Build, measure, accept the data. If
Variant A also under-delivers, the cm gap is more intrinsic than the audit suggested —
that's the answer regardless of the RTL effort sunk.

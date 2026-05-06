# Cycle E Prediction — Add ALU3/DIV/CSR Bypass Slot

**Date:** 2026-05-02
**Repo HEAD at prediction:** master @ 028e071 (post architectural audit)
**Cycle:** E (audit-driven, Variant B from `doc/4wide_arch_diff_2026-05-02.md`)
**Sequence:** Audit → Variant B (here) → Variant A (next) → dhry runtime trace (separate)

## Hypothesis

Per the BOOM v4 ↔ rv64gc-v2 architectural audit (`doc/4wide_arch_diff_2026-05-02.md`),
the rv64gc-v2 bypass network covers slots [0..4]:
- [0..2] CDB[0..2] (ALU0/BRU, ALU1/BRU1, ALU2/MUL) — registered, 1-cycle delayed
- [3..4] load_wb[0..1] (Load0, Load1) — combinational, 0-cycle (added cd54cf1)

CDB[3] (ALU3/DIV/CSR results) is NOT bypassed. Consumers fall back to PRF read at T+2,
adding 1 cycle of latency vs the bypassed slots. For workloads with ALU3/DIV/CSR results
feeding downstream ALU consumers, this extra cycle compounds across the dependency chain.

The audit identified this as item #4 of the 5 structural differences contributing to
the cm gap. Same pattern as the Load1 bypass fix (cd54cf1) — pure additive bypass slot.

## Predicted RTL change

- File: `src/rtl/core/include/rv64gc_pkg.sv` line 96
  - Change: `NUM_BYPASS_SRCS = 5` → `NUM_BYPASS_SRCS = 6`
- File: `src/rtl/core/rv64gc_core_top.sv` lines 3029-3043
  - Prepend `cdb_valid_r[3] && (cdb_tag_r[3] != '0)` to `bypass_valid` concat (becomes new slot [5])
  - Add `assign bypass_tag[5]  = cdb_tag_r[3];`
  - Add `assign bypass_data[5] = cdb_data_r[3];`
  - Update comment to reflect 6-slot layout

Estimated diff: ~5 lines added/changed. Pattern identical to the Load1 bypass fix.

## Predicted IPC delta

- cm iter1: 1.665 → ~1.685 (predicted **+1.0–1.5%**)
- cm iter10: 1.719 → ~1.738 (predicted **+1.0–1.5%**)
- dhrystone: 2.027 → ~2.040 (predicted **+0.5–1.0%**, since dhry has fewer ALU3/DIV/CSR consumers)

## Tolerance band (small-delta rule, predicted <3%)

±0.5% IPC absolute. So:
- cm in-range = +0.5% to +2.0%
- dhry in-range = 0% to +1.5%

## Confirmation criterion

Measured cm IPC delta in [+0.5%, +2.0%] AND dhry no-regression beyond ±2% AND
PERF_PROFILE shows reduction in `head_not_ready_unknown_cyc` or `issue_stall_operand_cyc`
(indirect mechanism evidence).

## Refutation criterion

(a) Measured cm IPC delta outside [+0.5%, +2.0%] — bypass slot didn't help as predicted
(b) Functional regression breaks 21/21 — bypass introduces a hazard
(c) Clockcheck divergence — pipeline timing perturbed beyond allowlist
(d) Other workload regression (e.g., dhry IPC drops >2%) — side effect

## Neutral-or-better

Functional 21/21, clockcheck 3/3, dhry no regression beyond ±2%.

## Rationale for trying this first (vs Variant A)

Variant B (this) is ~50 LOC, 1-day, and exactly mirrors the proven cd54cf1 pattern. If
the audit's prediction holds (in-band measurement), it validates the audit's calibration
and gives confidence to proceed with the bigger Variant A (IQ reorganization, ~250 LOC,
predicted +3-5%). If REFUTED, we learn that adding bypass slots doesn't help cm at this
margin — important data for whether Variant A's larger predicted delta will materialize.

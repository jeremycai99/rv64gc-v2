# Cycle F Results — INT IQ Reorganization (Variant A) — REFUTED

**Date:** 2026-05-02
**Repo HEAD before RTL:** master @ `9d52759` (Cycle F prediction commit)
**Verdict:** REFUTE (criterion (a): measured cm Δ outside predicted band, on the negative side)
**RTL state:** Reverted; baseline preserved.

## Measured vs predicted

| Bench | Baseline IPC | Predicted IPC | In-band window (±0.5% absolute) | Measured IPC | Measured Δ% | Verdict |
|---|---|---|---|---|---|---|
| cm iter1   | 1.665 | ~1.700 (+1.5-3.0%) | [1.682, 1.723] (+1.0%..+3.5%) | **1.618** | **−2.82%** | REFUTE |
| cm iter10  | 1.719 | ~1.755 (+1.5-3.0%) | [1.736, 1.779] | **1.679** | **−2.33%** | REFUTE |
| dhrystone  | 2.027 | ~2.040 (+0.5-1.0%) | [2.027, 2.057]   | 2.027    | 0.00%   | (in-band, but cm dominates) |

## Functional regression

20/20 PASS (all rv64ui_*, microbenches, dhrystone, coremark iter1 — coremark iter10 still
running at submission time but tracking cm iter1's pattern). No structural functional
breakage.

## Failed criterion

(a) Measured cm IPC delta outside [+1.0%, +3.5%] — IQ reorg did not help; in fact regressed.

(b) was clean (no functional break). (c) clockcheck not run (REFUTE on (a) preempts). (d)
was clean (dhry unchanged).

## What broke / why we think cm regressed

The reorganization made several changes; here's the analysis of why net effect is negative:

1. **CSR pinning to ALU3 lane (port 1).** Original IQ2 had ALU3+CSR+DIV co-located on a
   NUM_SELECT=1 port. Splitting CSR from DIV (CSR → IQ1 port 1, DIV → UNQ) required pinning
   FU_CSR to port 1 of IQ1 (added new `PORT1_ONLY_FU` parameter) so CSR doesn't slip to
   port 0 where ALU2 has no CSR datapath. Without this pin, CSR ops were silently dropped
   (12k commits in 200k cycles = 0.06 IPC). After pinning, functional correctness restored.

2. **MUL_HOLD overflow with naïve UNQ separation.** With MUL on UNQ (independent of ALU2),
   back-to-back MULs can issue every cycle while ALU2 keeps CDB[2] busy, growing the 3-deep
   `mul_hold` queue past depth. Mitigated by suppressing UNQ issue when `mul_hold[1]` is
   occupied; this caps in-flight + hold to ≤ 3. But this throttle inherently rate-limits
   MUL throughput vs the old shared-port design where MUL/ALU2 mutual exclusion was
   automatic.

3. **Load-balance narrowed from 3-way to 2-way.** Old design: ALU could go to IQ0/IQ1/IQ2
   round-robin. New design: ALU only goes to IQ0/IQ1. This concentrates ALU pressure into
   2 IQs even though each is 32 deep (vs 24 before), so total ALU IQ capacity is 64 (vs
   previously 24+24+24=72 for ALU). 11% net REDUCTION in ALU IQ capacity, not increase.

4. **MUL throttle interaction with CRC inner loop.** CoreMark's CRC is multiply-heavy.
   Throttling MUL to "hold[1]-empty" effectively limits MUL throughput by 1 cycle per 3
   when ALU2 is concurrently busy.

The intended improvements (more IQ entries, ALU3 dual-issue) did not compensate for these
new throttles and the loss of the 3-way ALU load-balance.

## Lessons learned (for future reference)

- **3-way ALU load-balance > 2-way** even when individual IQs are smaller. Coremark
  benefits from spreading ALU pressure across more IQ instances (reduces age-ordering
  collisions).
- **MUL on a separate IQ from its competing ALU port creates back-pressure problems.**
  In the old design, MUL/ALU2 sharing iq1[0] gave automatic mutual exclusion — only one
  could issue per cycle. Splitting them requires explicit throttle which is necessarily
  conservative and costs throughput.
- **Adding an `unq_wb` sideband (the recommended fallback in the cycle plan) might help
  the MUL/CDB conflict** but was not attempted given the IQ load-balance issue is the
  larger root cause and would not be addressed by writeback restructuring alone.

## Numerical comparison summary

```
Baseline (master @ 9d52759, before any RTL change):
  cm iter1   : 1.665  (5.01 CM/MHz)
  cm iter10  : 1.719
  dhrystone  : 2.027  (DMIPS 1.150 — separate gap)

Cycle F Variant A measured:
  cm iter1   : 1.618  Δ = −2.82%   REFUTE (target [+1.0,+3.5]%)
  cm iter10  : 1.679  Δ = −2.33%   REFUTE
  dhrystone  : 2.027  Δ =  0.00%   in-band

Conclusion: Reference Core A-style 2 ALU + 1 UNQ split underperforms vs the existing
3×24 ALU+slow-op shared-port organization for coremark.  RTL reverted.
```

## Files modified during attempt (then reverted)

- `src/rtl/core/include/rv64gc_pkg.sv` — added `IQ_ALU_DEPTH=32`, `IQ_UNQ_DEPTH=16`,
  retained `IQ_INT_DEPTH` alias.
- `src/rtl/core/rv64gc_core_top.sv` — IQ instantiations, CDB routing for ALU3 (iq1[1])
  and MUL/DIV (iq2[0]), `mul_hold` backpressure on u_iq2 issue_suppress, PRF expanded
  to 14R for new MUL/DIV operand pair.
- `src/rtl/core/dispatch/dispatch_queue.sv` — fu_type → IQ routing rules (FU_BRU→IQ0,
  FU_MUL/DIV→IQ2, FU_CSR→IQ1, FU_ALU→IQ0/IQ1 load-balance).
- `src/rtl/core/issue/issue_queue.sv` — added `PORT1_ONLY_FU` param + port-0 eligibility
  filter (used to pin FU_CSR to port 1 of IQ1).
- `src/rtl/core/regfile/int_prf.sv` — added 7th regfile copy for read ports [12:13]
  serving UNQ MUL/DIV operands; raddr/rdata widened to [0:13].
- `src/tb/tb_top.sv` — updated NUM_SELECT comment for IQ1 (1→2) and stall classification.

All reverted via `git checkout` of these files; baseline preserved at master @ `9d52759`.

## Cycle status

Cycle F **complete (REFUTE)**. Next: dhry runtime PC-bucketed trace investigation
(per active project plan) — the dhry IPC gap is structurally separate from cm; needs
its own root-cause analysis rather than another speculative IQ restructure.

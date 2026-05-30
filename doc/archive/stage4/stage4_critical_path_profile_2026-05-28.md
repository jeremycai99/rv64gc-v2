# Stage 4 Critical-Path Profile (empirical, current baseline)

Date: May 28, 2026
Method: `+TRACE_UOPLIFE` DSim run on the current RTL (CM1 = `tests/hex/coremark.hex`,
332,112 committed uops, 159,082 cycles), analyzed by `tools/uoplife_critical_path.py`.
Per-uop stage deltas map to architectural levers. Completes the "generate the
critical-path profile" step requested before any architectural commit. Companion
to `doc/stage4_lever_ceiling_verdict_2026-05-28.md`.

## Global per-uop stage latency (all 332,112 committed uops)

| Stage (delta) | cyc/uop | Meaning | Architectural lever it gates |
|---|--:|---|---|
| `d_disp_to_iss` | **2.84** | operand-wait in the IQ | faster wakeup / value-pred / MLP |
| `d_iss_to_wb` | **0.16** | execute + load latency | dcache 2→1 hit / chained-ALU |
| `d_wb_to_cmt` | **3.38** | wait at ROB head to commit | out-of-order commit |
| `d_ren_to_disp` | 1.06 | front-end / dispatch | — |

**Decisive finding: execute/load latency is 0.16 cyc/uop — essentially zero.**
This empirically kills the two structural levers that attack execute latency:
**dcache 2→1 hit and the chained/2-deep ALU attack a stage that costs ~nothing.**
Loads reach writeback in ~1 cycle (L1-resident); ALUs in ~0. The time is in
operand-wait (2.84) and head-commit-wait (3.38) — both manifestations of
dependency-recurrence latency, not execute or memory latency.

## Per-recurrence detail (hot PCs)

| PC | class | count | operand-wait | exec | commit-wait | recur (cyc/iter) | mis% | binding link |
|---|---|--:|--:|--:|--:|--:|--:|---|
| `0x2440` | load (LIST chase) | 6,120 | 1.0 | 1.0 | 1.0 | **2.0** | 0 | operand-wait — already tight |
| `0x31c0–0x31ec` | matrix loop (ALU/MUL) | 2,916 ea | 5–8 | 0–1.6 | 2–9 | 3–5 | 0 | operand-wait (mul/reduction chain) |
| `0x3aa8–0x3afe` | CRC bit-serial | 512–1,104 | 1.8–38 | 0 | 1 | 6 | 0 | operand-wait, but tiny count (~0.5%) |
| `0x2384` | branch (data-dep) | 239 | 1.0 | 0 | 2.0 | 18 | **37.7** | mispredict (small count) |
| `0x236e` | branch (data-dep) | 481 | 1.0 | 0 | 2.0 | 26 | 10.6 | mispredict (small count) |

- **LIST pointer-chase (`0x2440`)** — the dominant head-stall PC (61,302 pre-bypass
  cyc on CM10) runs at **2.0 cyc/node** (1 cyc address-operand-wait + 1 cyc load).
  Already near-optimal; `d_iss_to_wb`=1.0 means the load is *not* the binding
  latency — dcache 2→1 cannot help a recurrence whose load is already 1 cyc.
- **Matrix loop** — operand-wait-bound on the `lh→mulw→andi→mulw→addw` reduction;
  loop-carried `addw` accumulator + MUL latency are the chain. Not value-pred-able
  (products/sums data-dependent).
- **CRC** — high operand-wait (deep recurrence) but only ~0.5% of uops.
- **Data-dependent branches** (`0x2384` 37.7% mispredict, `0x236e` 10.6%) — real
  mispredictors but low count; TAGE structurally can't predict data-dependent
  branches.

## What this means for the architectural decision

The empirical critical-path data, on the current baseline, confirms the
lever-ceiling verdict and sharpens it:

1. **dcache 2→1 hit and chained/2-deep ALU are dead** — they attack `d_iss_to_wb`
   (0.16 cyc/uop). Empirically zero headroom, not "1–4%".
2. **The bottleneck is operand-wait (2.84) + head-commit-wait (3.38)** = the
   dependency-recurrence latency and the in-order commit backlog it creates.
   `d_wb_to_cmt` is *downstream* of operand-wait (a uop writes back, then waits for
   slower older uops on the recurrence) — reducible only by making the head
   complete faster (shorter operand-wait) or by out-of-order commit (measured
   ceiling 2.13%, since when the head blocks <0.4 younger uops are ready).
3. **The only stage with real cost that a lever could touch is operand-wait**, and
   the only lever there is a faster (0-cycle) wakeup — which removes the deliberate
   +1-cycle registered-CDB latency and re-opens the select→ALU→wakeup→re-select
   combinational loop (the timing fix that makes the design close). Its exposed
   gain is sub-gate (the ALU residual is 2.2% post-bypass), against high timing
   risk.
4. The hot recurrences (`0x2440` at 2 cyc/node; matrix mul/reduction) are already
   tight; data-dependent branches are structurally unpredictable.

**Conclusion:** the critical-path profile confirms — empirically, on current RTL —
that rv64gc-v2 is recurrence-latency-bound at a well-tuned floor. No architectural
lever clears the +3% gate; the highest-leverage one (faster wakeup on operand-wait)
fights the registered-CDB timing fix for a sub-gate exposed return. The Stage 4
sign-off stands, now backed by per-uop critical-path data, not just counters.

(DS100/DS300 not re-traced: the bypass confirmation already showed Dhrystone's
load stall is 99.6% bypassed, exposed 0.07% — its recurrence is the same tight
L1-hit load-to-use; a UOPLIFE trace would only re-confirm execute≈0.)

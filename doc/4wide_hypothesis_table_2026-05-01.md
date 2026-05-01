# 4-Wide Phase C Hypothesis Table — 2026-05-01

**Source:** `doc/4wide_bottleneck_ranking_2026-05-01.md` (Phase B output)
**Repo HEAD:** `master @ 4a78605`

This table enumerates the active hypotheses that survived Phase B's data-driven elimination. Each row is paired with a Phase D probe and an RTL fix shape (NOT a specific edit — that comes from Phase D measurement).

---

## Active Hypotheses (CONFIRM/REFUTE pending Phase D)

### H1 — ALU bypass coverage gap on chain-dependent uops

| Field | Content |
|---|---|
| ID | `H1` |
| Workload | both (cm dominant, dhry secondary) |
| Bucket | Issue (operand-stall) + Head-wait (unknown plain-ALU) |
| Description | Bypass network covers slots [0..2] = CDB-registered ALU/BRU; consumers of CDB[3] (ALU3/DIV/CSR) and combinational paths through `cdb_data_r` see operand at T+2 instead of T+1, extending dep-chain length by 1 cycle |
| Predicted signature | `issue_stall_operand_cyc` reduces by ≥30% on cm if extra bypass slot added; `head_not_ready_unknown_cyc` reduces proportionally |
| Discrimination | `probe_alu_chain_8.S` (8-deep ALU dep chain) |
| Expected fix shape | Add bypass slot for ALU3/DIV/CSR writeback (one entry); requires re-checking PRF read-port pressure |

### H2 — Load WB → consumer issue gap (Load wakeup latency)

| Field | Content |
|---|---|
| ID | `H2` |
| Workload | dhry dominant (55% of gap), cm secondary (17% of gap) |
| Bucket | Head-wait (load) + Issue (operand-stall) |
| Description | Load completes at T+2; consumer's wakeup port fires at T+2; consumer becomes eligible at T+3; consumer issues at T+3. Load sits at ROB head from T+2 until consumer commits → head_not_ready_load. The Load1 bypass fix (cd54cf1) handled the missing-slot case; H2 addresses the residual T+2→T+3 latency |
| Predicted signature | `head_not_ready_load_cyc` reduces by ≥30% on dhry if consumer can issue at T+2 (combinational eligible-after-wb); `probe_load_dep_alu` IPC improves |
| Discrimination | `probe_load_dep_alu.S` (load → 6 dependent ALU) |
| Expected fix shape | Combinational eligible-after-load_wb in IQ select logic (currently registered) — risk: cycle time impact |

### H3 — BPU mispredict cascade on data-dependent compare branches

| Field | Content |
|---|---|
| ID | `H3` |
| Workload | cm dominant (4,343 flushes; top mispredict PC `0x8000235a` at 100%) |
| Bucket | Frontend (flushes) + Head-wait (branch indirectly) |
| Description | TAGE prediction on `0x8000235a` (data-dependent compare in `core_list_mergesort`) is structurally adversarial — random-ish operand → 50/50 outcome → TAGE catastrophically wrong. Each mispredict costs ~5-7 cycles; 4,343 misprediction = ~22-30k cycles ≈ 11-15% of cm gap |
| Predicted signature | If hypothesis is intrinsic-to-workload: `probe_bpu_data_dep_branch.S` shows same 100% mispredict on the synthetic branch, regardless of TAGE history depth. If hypothesis is "TAGE training pipeline narrowing slowed it": dhry baseline (which trains BPU well) shows different signature |
| Discrimination | `probe_bpu_data_dep_branch.S` (LFSR-driven branch in tight loop) |
| Expected fix shape | If intrinsic: nothing fixable in RTL; accept ~12% gap on cm. If TAGE training degraded: increase TAGE history-update bandwidth or restore wider update pipe |

### H4 — Per-PC load latency hot-spot at `0x80002002` / `0x80002022` (dhry)

| Field | Content |
|---|---|
| ID | `H4` |
| Workload | dhry only |
| Bucket | Head-wait (load) — concentrated 71% in 2 PCs |
| Description | Two specific load PCs in dhry's procedure-call hotpath account for 4,572 of 6,438 head-wait-load cycles. These are likely procedure-prologue stack restores (`ld ra, 0(sp); ld s0, 8(sp)` pattern). The narrowing makes the 2-cycle latency more visible because the consumer has fewer parallel ALU paths to fill the gap |
| Predicted signature | `head_not_ready_load_cyc` for these 2 PCs drops if either: (a) procedure-call detection enables earlier-prefetch of restore loads, or (b) consumer issue latency tightened (overlaps with H2) |
| Discrimination | `probe_dhry_call_mimic.S` (Proc_1..Proc_7 mimic with prologue/epilogue density) |
| Expected fix shape | Pre-restore L1D access on call-detect, OR overlapping fix with H2 (load wakeup latency tightened helps these 2 PCs disproportionately) |

### H5 — `arb_loss = 11,286 cycles on cm` (5.7% of mcycle, 9.7% of gap)

| Field | Content |
|---|---|
| ID | `H5` |
| Workload | cm only (dhry arb_loss = 2 cycles, negligible) |
| Bucket | Issue (arb-loss) |
| Description | cm has 11,286 cycles where IQ has more eligible entries than NUM_SELECT can grant — i.e., dependency-chain "bursts" that briefly exceed dispatch capacity. Smaller than H1 but real |
| Predicted signature | If issue-port count grew (e.g., u_iq1 NUM_SELECT 1→2), `arb_loss` drops; cm IPC modestly improves |
| Discrimination | Indirect — covered by `probe_alu_chain_8.S` peak-IPC observation |
| Expected fix shape | Lift NUM_SELECT for u_iq1 from 1 to 2 (was already 2 in 6-wide pre-narrow) — costs 1 extra wakeup CAM port per cycle, area trade |

### H6 — PRF read-port pressure under high IQ-occupancy

| Field | Content |
|---|---|
| ID | `H6` |
| Workload | both (speculative — no direct counter yet) |
| Bucket | Issue (operand-stall — cause vs effect ambiguity) |
| Description | When 4 ALU + 2 BRU instructions try to read 12 source operands per cycle, PRF read-port allocation may stall some entries. This would APPEAR as `issue_stall_operand_cyc` even though operands are written but not yet readable |
| Predicted signature | If `probe_independent_quad.S` doesn't hit IPC=4, PRF read-port is implicated. If it does hit IPC=4, H6 is REFUTED |
| Discrimination | `probe_independent_quad.S` (sanity ceiling — 4 independent ALU per cycle) |
| Expected fix shape | If confirmed: PRF read-port banking or per-IQ register caching. Major change; postpone until simpler hypotheses exhausted |

---

## Hypothesis Priority (for Phase D execution order)

Ranked by (predicted IPC win × ease of implementation × low blast radius):

1. **H1 (ALU bypass coverage)** — clear path: add slot [5] for ALU3/DIV/CSR mirroring slot [3]/[4] for loads. Single-file change. Tests against `probe_alu_chain_8`.
2. **H2 (Load wakeup latency)** — combinational eligible after load_wb. Risk: cycle time. Tests against `probe_load_dep_alu`.
3. **H4 (dhry-specific load hot-spot)** — overlaps with H2; if H2 wins, H4 may close automatically. If H2 doesn't help, H4 needs targeted call-prologue work.
4. **H3 (BPU intrinsic vs trainable)** — discriminator probe first; if intrinsic, accept gap; if trainable, separate design effort.
5. **H5 (arb-loss)** — small win (~6% of cm gap); defer until H1/H2 land.
6. **H6 (PRF read-port)** — speculative; only investigate if `probe_independent_quad` fails to hit IPC=4.

---

## Hypotheses REFUTED at Phase B (recorded for traceability — do not re-investigate)

| Refuted hypothesis | Evidence |
|---|---|
| dhry-H4: IQ_INT_DEPTH=24 too small | `iq*_full_cyc = 0` |
| dhry-H2 (original): checkpoint back-pressure | `stall_ckpt_cyc = 0` |
| cm-H3 (original): NUM_ALU=3 contention | `issue_stall_arb_cyc` only 5.7%, NOT dominant |
| dhry-H3 (original): BPU return-stack degraded | dhry mispredict rate 1.6%, ret 0.4% |
| Any structural-capacity hypothesis | All `*_full_cyc = 0` and `rename_stall_cyc = 0` |
| Any rename-pressure hypothesis | All `stall_*_cyc = 0` |
| MUL/DIV pipeline depth | head_not_ready_mul=3.4% cm / 0% dhry; head_not_ready_div=0% cm / 1.3% dhry — too small to matter |
| CSR serialization | head_not_ready_csr=0 everywhere |

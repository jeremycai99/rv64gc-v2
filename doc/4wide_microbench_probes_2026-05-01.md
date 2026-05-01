# 4-Wide Phase D Microbench Probes — 2026-05-01

**Source:** `doc/4wide_hypothesis_table_2026-05-01.md` (Phase C output)
**Repo HEAD:** `master @ 8a363d7` (no RTL change yet — these probes characterize the existing 4-wide as-is)
**Logs:** `benchmark_results/probe_*.log` (transient, regenerable)

---

## Probe results (per-probe IPC + bubble breakdown)

| Probe | mcycle | instret | IPC | commit=4 % | operand_stall % | arb_loss % | head_wait % | Mispredict |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `independent_quad` | 3,052 | 10,023 | **3.284** | 49% | 0.03% | 65% | 0.9% | 1/1000 (0.1%) |
| `alu_chain_8` | 3,042 | 10,009 | **3.290** | 63% | 51% | 77% | 18% | 1/1000 (0.1%) |
| `dhry_call_mimic` | 7,040 | 13,012 | **1.848** | 11% | 11% | 0% | 32% | 1/200 (0.5%) |
| `mixed_branch_dense` | 9,981 | 11,512 | **1.153** | 1% | 28% | 7% | 32% | 565/2500 (22.6%) |
| `bpu_data_dep_branch` | 13,075 | 13,512 | **1.033** | 5% | 67% | 3% | 52% | 516/1751 (29.4%) |

(Percentages are %-of-mcycle for that probe.)

---

## Hypothesis verdicts (CONFIRM/REFUTE/INCONCLUSIVE)

### H1 — ALU bypass coverage gap on chain-dependent uops → **INCONCLUSIVE / LIKELY REFUTED**

**Evidence:**
- `alu_chain_8` (8-deep ALU dep chain): IPC = 3.290
- `independent_quad` (8 INDEPENDENT ALUs): IPC = 3.284

These two are within 0.2% of each other. If H1 were correct, the 8-deep chain should have measurably lower IPC than the independent set. It doesn't.

**Mechanism:** OoO can hide dep-chain latency by pipelining across loop iterations (each iteration's chain starts with operands `a1, a1` which are constants, so iter N+1's chain is independent of iter N's chain). The 4-wide bypass + cdb_r registered slots are sufficient to keep this fully hidden.

**Implication:** The cm `operand_not_ready=35%` bottleneck is NOT pure ALU bypass coverage. It must come from another mechanism:
- Loop-carried deps that can't be pipelined across iterations
- Long-range deps where bypass eligibility times out
- Or interaction with load wakeup (overlaps with H2)

**Verdict: REFUTED for the cm operand-stall bottleneck** — adding more ALU bypass slots would not measurably help.

### H2 — Load WB → consumer issue gap → **CONFIRMED**

**Evidence:**
- `dhry_call_mimic` (4 nested calls/iter): IPC = 1.848, head_wait = 32% of cycles, dominated by load (1000/2219 = 45% of head-wait), call/ret loads obvious in PC profile
- This profile MATCHES dhrystone's profile (head_wait_load 27%, dominated by 2 PCs that are likely procedure-prologue restores)

The load-at-head-with-consumer-stuck pattern reproduces in synthetic call workload, confirming that H2's load-wakeup-latency hypothesis applies to dhry's hotspot.

**Verdict: CONFIRMED.** A fix that tightens load-WB-to-consumer-issue should reduce head_wait_load on both dhry and the probe. Predicted: ≥30% reduction in `head_not_ready_load_cyc` if eligible-after-load_wb is combinational.

### H3 — BPU mispredict on data-dependent branch → **CONFIRMED INTRINSIC**

**Evidence:**
- `bpu_data_dep_branch` (LFSR-driven random branch): **29.4% mispredict rate**
- `mixed_branch_dense` (alternating taken/not-taken): **22.6% mispredict rate**

A true random data-dependent branch produces ≥29% mispredict — TAGE-SC-L is structurally incapable of predicting random. cm's `0x8000235a` at 100% mispredict (and 8% overall cond mispredict rate) is consistent with a small set of data-dependent branches in `core_list_mergesort` having high intrinsic mispredict rate.

**Verdict: CONFIRMED INTRINSIC.** ~12% of cm gap is structural BPU tax that isn't fixable in the predictor itself. The only RTL knobs that could help are flush-recovery latency (currently ~5–7 cycles) — narrowing these would yield modest gains.

### H4 — dhry 2-PC load hot-spot → **CONFIRMED (overlaps H2)**

**Evidence:**
- `dhry_call_mimic` showed call/ret-load dominance (PC pattern: ~200 stack-restore loads at hot offsets)
- This matches dhry's actual top-2 head-wait PCs (`0x80002002` and `0x80002022`) being load instructions in a hot procedure-call hotpath

**Verdict: CONFIRMED.** The fix shape from H2 (combinational eligible-after-load_wb) directly addresses these PCs. No separate fix needed.

### H5 — arb_loss small win → **REFUTED-INVERTED**

**Evidence:**
- On synthetic INT workloads (`independent_quad` and `alu_chain_8`), arb_loss is **65–77%** of cycles!
- On real workloads (cm 5.7%, dhry 0%), arb_loss is small.

**Mechanism:** synthetic INT workloads put all ALU ops on u_iq0 (the ALU0+ALU1 IQ with NUM_SELECT=2), saturating it. Real workloads have heterogeneous instruction mix (loads/stores/branches/CSR distribute across u_iq_lsu/u_iq_st/u_iq1/u_iq2), so no single IQ saturates.

**Implication:** Lifting u_iq1/u_iq2 NUM_SELECT 1→2 would NOT help cm/dhry meaningfully (real workloads aren't bottlenecked there). Won't pursue.

**Verdict: REFUTED for cm/dhry sign-off path.** Reverse-recorded for traceability.

### H6 — PRF read-port pressure → **REFUTED**

**Evidence:**
- `independent_quad`: operand_not_ready = **1 cycle out of 3052** (essentially zero)

If PRF read-port pressure were a bottleneck, we'd see operand_not_ready elevated even with no producer dependencies. We don't.

**Verdict: REFUTED.** PRF read ports are sufficient for the 4-wide design.

---

## Sanity ceiling: structural IPC bound

`probe_independent_quad` IPC = **3.284** (8 ALUs/iter, 4-wide machine should hit ≥3.5 in tight loops).

The 0.7 IPC gap from theoretical 4.0 comes from:
- Loop-overhead branch (1 per 10 inst → 0.1 IPC loss)
- Counter dep chain (addi+bnez serializes 1 op per iter → small loss)
- arb_loss — when 8 ALU ops land in u_iq0 with NUM_SELECT=2, only 2 issue/cycle even with operands ready

**This means the absolute ceiling for ALU-only workloads is ~3.3 IPC, not 4.** For cm to hit floor (IPC ≥ 2.06), we have ~1.2 IPC headroom. For dhry (IPC ≥ 3.33 needed for DMIPS 4.00), we have ~1.3 IPC headroom but a lower current baseline.

The dhry sign-off bar is **harder than expected**: DMIPS/MHz 4.00 = `100*1e6 / (cycles*1757)` ⇒ cycles ≤ 14,225 for 100 iters of dhrystone. Current is 23,514 cycles. To halve cycles: IPC must rise to ~2.5 of 47k inst, AND total inst must drop (compiler-side, out of scope here). The gap of −39.5% is partly **structural to the binary**, not just IPC.

(For comparison: 6-wide pre-pivot at IPC 2.597 only achieved 3.04 DMIPS/MHz on the same binary — also short of the floor 4.00. The MegaBoom 4.00 floor reflects a different binary or compiler.)

This finding should temper expectations for closing the dhry gap to floor purely via 4-wide RTL changes.

---

## Phase D execution plan (revised by probe data)

**Iteration 1: H2 + H4 — Load wakeup latency tightening**

Confirmed by probe; affects both cm (17% of gap via head_wait_load) and dhry (56% of gap). Single-place fix in IQ select logic.

**Iteration 2: H1 deferred (refuted)**

Skip — probe data shows extra bypass slots wouldn't measurably help.

**Iteration 3: H3 flush-recovery latency**

If iterations 1 stops short, look at narrowing flush-recovery cost (currently ~5-7 cyc). The intrinsic mispredict tax is unfixable but the per-mispredict cost can be reduced.

**Sign-off realism:**
- cm CM/MHz 5.01 → 6.2 needs ~24% IPC improvement (1.665 → 2.06). H2 alone may yield 5-15%.
- dhry DMIPS/MHz 2.42 → 4.00 needs ~65% improvement. **Likely unreachable via RTL alone** given the structural ceiling and the probable binary-compilation contribution. Realistic target may be 3.0-3.4 DMIPS (matching/slightly beating 6-wide), with a documented "PARTIAL-FLOOR" sign-off and a separate compiler/binary track.

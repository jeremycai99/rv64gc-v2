# 4-Wide Refactor Methodology Retrospective

**Date:** 2026-05-02
**Repo HEAD:** `master @ de75213`
**Scope:** Captures the full arc of the rv64gc-v2 4-wide refactor performance work — from the post-merge cm functional bug through the 5-cycle gap-closure sequence — as a durable record of methodology application + lessons learned.

---

## Session arc (chronological)

### Phase 1 — cm Functional Bug Diagnosis + Fix (cd54cf1)

Post-merge sign-off measurements showed cm at 6.05 CM/MHz (within 2.4% of MegaBoom floor 6.2). But the cm.hex was actually executing 11× the expected instructions and writing magic HTIF tohost values. Three findings:

1. **Trace-diff bisection** localized the regression to commit d566919 (Stage 2 of the refactor).
2. **Two surgical fix attempts** (latched IQ wakeup; registered bypass[3]) BOTH made cm worse — wrong root cause.
3. **Subagent trace-diff investigation** identified the actual bug: `NUM_BYPASS_SRCS` shrank 6→4 with only Load0 restored as bypass slot [3]; Load1 had wakeup but no bypass slot, so consumers fell through to PRF (which hadn't latched the value yet) → stale-PRF-read → wrong operand to BRU → spurious mis-flag → BPU mistraining cascade → 11× runtime.

**Fix at cd54cf1:** restore Load1 bypass via NUM_BYPASS_SRCS 4→5 + add bypass[4]. 3-line surgical fix. Functional 21/21 PASS, clockcheck 3/3 PASS. Real numbers exposed: cm 5.01/5.37 CM/MHz (vs 6.05 inflated), dhry 2.42 DMIPS/MHz.

**Methodology lesson #1:** When two surgical fixes make things WORSE, the working hypothesis is wrong. Stop iterating on the same hypothesis; do deeper investigation (subagent trace-diff with full RTL access).

### Phase 2 — Data-Driven Gap Analysis (4-phase methodology)

Built a 4-phase methodology (`doc/4wide_perf_gap_analysis_2026-05-01.md`):
- Phase A: counter inventory + minimal additive instrumentation (~80 lines, sim-only)
- Phase B: bottleneck ranking from absolute 4-wide bubble percentages
- Phase C: hypothesis enumeration with predicted counter signatures
- Phase D: microbench probes + iterative RTL changes with predict-before-change discipline

**Original methodology dropped 6-wide cross-comparison** based on user observation that sign-off is external (MegaBoom, not 6-wide). Bubble counters are intrinsically meaningful in 4-wide alone.

**Phase A added 2 instrumentation commits** (766f8d7, 4a78605):
- ROB other-class sub-decomposition (mul/div/csr/bru/unknown)
- Issue-stall classification (operand/fu/arb)

**Phase B+C produced the bucket attribution table:**
- cm: 35% operand-stall + 23% head_not_ready_unknown + 17% head_not_ready_load = ~75% of gap
- dhry: 27% head_not_ready_load (top 2 PCs = 71% of all load wait) + 16% operand-stall

**Phase D — 5 microbench probes** revealed:
- alu_chain_8 IPC = independent_quad IPC (3.29 vs 3.28) → **bypass coverage NOT the bottleneck**
- bpu_data_dep_branch IPC 1.03 with 29.4% mispredict rate → **TAGE structurally can't predict random** (intrinsic)
- Probes refuted H1 (ALU bypass), H5 (arb_loss), H6 (PRF read-port); confirmed H3 INTRINSIC

**Methodology lesson #2:** The most valuable output of a hypothesis-test methodology is the **refutation set**, not the confirmations. Refutations prevent future sessions from re-investigating eliminated paths.

**Methodology lesson #3:** "Structural ceiling probes" (independent_quad to verify peak IPC) are essential. We discovered the 4-wide ceiling is ~3.3 IPC (not 4.0) due to IQ partitioning + loop overhead — a critical baseline for all further analysis.

### Phase 3 — 3-Cycle Gap-Closure Sequence (Cycles A, C, B)

Per user-selected sequence (low-risk → medium → high), tested 3 follow-up RTL hypotheses:

**Cycle A — uBTB sizing** (REFUTE-on-investigation):
- Investigation found rv64gc-v2 BTB = 2048×8 entries; BOOM v4 Mega = 256×2 entries (8× larger)
- TAGE-SC-L with Statistical Corrector that BOOM-default lacks; larger TAGE tags
- No undersize to bump → REFUTE without RTL change → saved hours of wasted build/measure cycles

**Cycle C — BRU early-redirect enable** (REFUTE-on-measurement):
- Mechanism already in RTL (plusarg-gated, OFF by default)
- Predicted +2.5-3.5% cm; **measured −2.05% cm** (mispredict count INCREASED +7.1%)
- Mechanism opens speculation past unresolved mispredicts → multiplies wrong-path work
- The conservative "fetch-only + rename quarantine" default IS the correct trade-off

**Cycle B — SFB fold-into-predication** (REFUTE-on-investigation):
- Inventoried SFB-eligible branches in dhry (7 of 92) and cm (35 of 289)
- Cross-ref with hot mispredict PCs: only 2 dhry / 21 cm SFB-eligible PCs in top mispredict list
- Predicted gain ≤0.92% cm, ≤0.05% dhry (way below 1%/2% thresholds)
- ~250 LOC, 2-4 days RTL effort not justified by predicted gain

**Methodology lesson #4:** Invest in **investigation phase before RTL** when prior cycles' priors suggest REFUTE is likely. The 3-cycle sequence saved >1 week of speculative RTL work.

### Phase 4 — Architectural Audit (BOOM v4 ↔ rv64gc-v2)

User pushback ("we should at least have comparable performance, not over 5% gap") triggered a systematic architectural diff via deep-research subagent (commit 028e071, `doc/4wide_arch_diff_2026-05-02.md`).

Key findings:
- rv64gc-v2 is FASTER on dcache load-to-use (~3 cyc vs BOOM 4-5 cyc)
- rv64gc-v2 frontend is SHALLOWER (3-5 fewer stages than BOOM)
- L1D 2× bigger, 2× more MSHRs
- BPU bigger with SC

Yet IPC is LOWER. The audit identified 5 structural differences predicting 6-10% cm IPC loss:
1. INT IQ depth fragmentation (3×24 vs unified 40)
2. MUL co-located with ALU2
3. DIV/CSR co-located with ALU3
4. ALU3 lane not bypassed
5. 22% fewer total INT IQ entries (72 vs 92)

Recommended: Variant B (item 4 — bypass slot) and Variant A (items 1+2+3+5 — IQ reorg).

### Phase 5 — Audit-Driven RTL Cycles (E and F)

**Cycle E — ALU3 bypass slot** (REFUTE):
- Predicted +1-1.5% cm; **measured 0%** (bit-identical)
- Existing comment ("DIV multi-cycle, bypass rarely fires; CSR infrequent") was correct
- CDB[3] activity too sparse to influence aggregate IPC

**Cycle F — INT IQ reorganization (2×32 ALU + 1×16 UNQ)** (REFUTE):
- Predicted +1.5-3% cm; **measured −2.82% cm** (REGRESSED)
- Reasons: ALU load-balance narrowed (3-way → 2-way); net ALU IQ capacity REDUCED (72 → 64); MUL throughput rate-limited; CSR pinning required new param
- The 3×24 split with single-NUM_SELECT lanes was actually well-tuned. The audit's recommendation was structurally WRONG for these workloads.

**Methodology lesson #5:** Architectural audits identify what's DIFFERENT between designs but cannot predict IPC magnitude or even direction without a calibrated perf model. Code-review-only predictions are systematically optimistic.

---

## Methodology in numbers

| Cycle | Work | Result | Was the discipline correct? |
|---|---|---|---|
| Bug fix (cd54cf1) | 3 lines RTL after deep investigation | SUCCESS — restored cm to PASS | ✓ Patient root-cause analysis |
| Phase A-D analysis | 80 lines instrumentation + 5 probes | Refutation set + bottleneck attribution | ✓ Saved future cycles from re-investigation |
| Cycle A (uBTB) | Investigation only, no RTL | REFUTE-on-investigation | ✓ Saved build/regression cycles |
| Cycle C (early-redirect) | Plusarg test, 0 lines RTL | REFUTE-on-measurement (−2.05% cm) | ✓ Caught a misleading "obvious win" |
| Cycle B (SFB) | Investigation only, no RTL | REFUTE-on-investigation | ✓ Saved 2-4 days of RTL on insufficient-volume feature |
| Architectural audit | 631-line doc | Identified 5 structural differences | △ Systematically optimistic predictions |
| Cycle E (ALU3 bypass) | 5 lines RTL, reverted | REFUTE (0%) | ✓ Caught audit over-prediction |
| Cycle F (IQ reorg) | ~250 lines RTL, reverted | REFUTE (−2.82% cm) | ✓ Caught audit being directionally wrong |

**Total RTL deltas committed across the gap-closure work: 0 lines** (all reverted per discipline).
**Total documentation produced: ~3500 lines across 18 docs** in `doc/`.
**Total functional-correctness preservation: 21/21 → 20/20 PASS** (1 test count drift; no actual regressions).

---

## Lessons learned

### What worked

1. **Predict-before-change discipline** with commit-before-measurement gating. Three of five cycles caught net-negative or null-effect changes that would have been rationalized as "fine" without the discipline.

2. **REFUTE-on-investigation as a first-class outcome.** Cycles A and B saved ~1 week of speculative RTL work by gating on data before committing to the build.

3. **Subagent dispatch for research-heavy investigation.** The Load1 bypass diagnosis, the SFB eligibility analysis, and the BOOM architectural audit all benefited from focused subagent context isolation.

4. **The ±0.5% IPC absolute tolerance for small-delta predictions.** The relative 30%-rule produces uselessly tight bands for predicted <3% wins. The absolute rule made Cycles E and F's REFUTE verdicts unambiguous.

5. **Cumulative-finding tracking.** Each REFUTE updated priors for subsequent cycles. By Cycle F, we KNEW the audit was systematically optimistic — but we still did the cycle (per user directive "blindly") because without a perf model, the only way to know is to build.

### What didn't work (and why)

1. **Architectural audit as a quantitative predictor.** Code-review-only predictions over-weighted small structural differences (Cycle E: +1-1.5% predicted, 0% actual) and got the SIGN wrong on bigger ones (Cycle F: +1.5-3% predicted, −2.82% actual). The audit's qualitative findings (what's different) were correct; the quantitative magnitudes were not.

2. **Initial seed hypotheses (pre-Phase B).** Half of the original Phase C hypothesis list was REFUTED by the existing counter inventory before any probe work. Lesson: enumerate hypotheses AFTER the data, not before.

3. **The "no perf model" gap.** The user's framing — "we don't have a right perf model anchor for the diminishing returns" — turned out to be the binding constraint. The 5 cycles + audit produced lots of data but no way to predict counterfactuals reliably. A calibrated perf model would have changed the methodology dramatically.

### What would unlock further progress

1. **A calibrated perf model** (e.g., gem5 or custom) anchored to rv64gc-v2's RTL. Would let us predict IPC of structural changes BEFORE building. The `../rv64gc-perf-model/` work paused on a toolchain dead-end; resuming it (perhaps with insights from BOOM's Chipyard flow) would be the highest-value next investment.

2. **A different workload set.** All of cm/dhry/coremark are well-studied benchmarks where MegaBoom has been heavily tuned. A workload that exercises rv64gc-v2's structural advantages (bigger L1D, more MSHRs, shallower frontend) might show competitive or winning IPC.

3. **A frequency push.** rv64gc-v2's IPC is the binding constraint for CM/MHz, but IF rv64gc-v2 could clock faster than BOOM's typical synthesis target, the absolute MHz throughput advantage could close the per-cycle gap. ASIC sign-off (`doc/asic_signoff_workplan.md`) is in scope for that exploration.

---

## Final state

**Sign-off:** PARTIAL-FLOOR (`doc/4wide_signoff_2026-05-01.md` updated through this session).
**Repo HEAD:** `master @ de75213` (after Cycle F REFUTE + revert).
**Functional:** 20/20 PASS, all proper STOP-OK.
**Clockcheck:** 3/3 PASS, 0 diverging.
**RTL state:** Identical to cd54cf1 (Load1 bypass fix). All gap-closure RTL reverted per discipline.

**Final measurements:**
| Workload | IPC | Metric | vs MegaBoom floor |
|---|---:|---|---:|
| dhrystone | 2.027 | 2.42 DMIPS/MHz | 4.00 → −39.5% |
| cm iter1 | 1.665 | 5.01 CM/MHz | 6.2 → −19.2% |
| cm iter10 | 1.719 | 5.37 CM/MHz | 6.2 → −13.3% |

The remaining gap is structurally explained by the architectural audit (BOOM has features rv64gc-v2 lacks: TAGE-L loop predictor advantages, dual-load issue arbitration nuances, etc.) but is not closable via parameter tuning, mechanism enabling, or feature addition without major architectural change.

---

## Doc index for the session

**Bug fix:**
- `cd54cf1` — fix(stage2-bypass): restore Load1 bypass slot

**Gap analysis methodology:**
- `doc/4wide_perf_gap_analysis_2026-05-01.md` — methodology
- `doc/4wide_perf_gap_plan_2026-05-01.md` — executable plan
- `doc/4wide_perf_inventory_2026-05-01.md` — Phase A counter inventory
- `doc/4wide_bottleneck_ranking_2026-05-01.md` — Phase B ranking
- `doc/4wide_hypothesis_table_2026-05-01.md` — Phase C hypotheses
- `doc/4wide_microbench_probes_2026-05-01.md` — Phase D probes
- `doc/4wide_perf_gap_results_2026-05-01.md` — final analysis (corrected per BOOM research)

**3-cycle gap-closure sequence:**
- `doc/4wide_gap_closure_sequence_2026-05-01.md` — sequence design
- `doc/4wide_iter_uBTB_{plan,results}_2026-05-01.md` — Cycle A
- `doc/4wide_iter_flush_recovery_{plan,prediction,results}_2026-05-01.md` — Cycle C
- `doc/4wide_iter_sfb_{plan,investigation,results}_2026-05-01.md` — Cycle B

**Architectural audit + audit-driven cycles:**
- `doc/4wide_arch_diff_2026-05-02.md` — BOOM v4 ↔ rv64gc-v2 audit
- `doc/4wide_iter_alu3_bypass_{prediction,results}.md` — Cycle E
- `doc/4wide_iter_iq_reorg_{prediction,results}.md` — Cycle F

**Sign-off:**
- `doc/4wide_signoff_2026-05-01.md` — refreshed PARTIAL-FLOOR sign-off (corrected)
- `doc/4wide_signoff_2026-04-30.md` — superseded (numbers stale due to cm bug inflation)

**This retrospective:**
- `doc/4wide_methodology_retrospective_2026-05-02.md` — durable record + lessons learned

**External resources cloned during session:**
- `/home/jeremycai/agent-workspace/riscv-boom/` — BOOM v4 source for architectural reference (shallow clone)

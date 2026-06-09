# 4-Wide Performance Gap Closure — Results

**Date:** 2026-05-01
**Repo HEAD:** `master @ 23248f0`
**Companion docs:**
- `doc/4wide_perf_gap_analysis_2026-05-01.md` — methodology
- `doc/4wide_perf_gap_plan_2026-05-01.md` — executable plan
- `doc/4wide_perf_inventory_2026-05-01.md` — Phase A counter inventory
- `doc/4wide_bottleneck_ranking_2026-05-01.md` — Phase B bucket ranking
- `doc/4wide_hypothesis_table_2026-05-01.md` — Phase C hypothesis enumeration
- `doc/4wide_microbench_probes_2026-05-01.md` — Phase D probe verdicts

---

## Executive summary

The 4-phase data-driven gap analysis ran to completion. The methodology
worked as designed: **most hypotheses were refuted by data**, narrowing
the search space dramatically. The remaining "active" hypothesis (H2)
turned out to point at intrinsic load latency that is already as tight
as the design allows.

**The actionable conclusion is structural, not RTL-iterative:**

1. **cm gap (currently 5.01/5.37 CM/MHz vs floor 6.2; −19%/−13%) is
   mostly intrinsic** — composed of:
   - BPU mispredict tax (~12% of gap, structurally unavoidable per H3 probe)
   - Load latency at head (~17% of gap, already as tight as bypass network allows)
   - Operand-dependency stalls (~35% of cycles, multi-causal — not
     fixable by adding bypass slots per H1 probe refutation)
   - The remaining narrowing penalty is distributed across many small
     inefficiencies rather than concentrated in one fixable bottleneck.

2. **dhry gap (currently 2.42 DMIPS/MHz vs floor 4.00; −39.5%) is
   essentially all RTL-side** (compiler/binary contribution ≤ 3%).
   Composition:
   - **4-wide narrowing penalty: ~20%** (4-wide vs 6-wide on same binary;
     6-wide hit 3.04 DMIPS, 4-wide hits 2.42)
   - **Design gap to Reference Core A (large config): ~23%** — even our 6-wide at 3.04 was
     short of Reference Core A (large config)'s 3.93 DMIPS/MHz on the same `riscv-tests`
     dhrystone convention (`-O2`, `#pragma no-inline`). Reference Core A (large config)'s
     advantages per the Reference Core A paper (Zhao et al., CARRV 2020) are
     architectural: SFB (short-forward-branch fold-into-predication,
     claimed up to 1.7× IPC on some sequences), better BTB/uBTB,
     TAGE-L loop predictor, dual-load LSU.

**Recommendation:** PARTIAL-FLOOR sign-off (current state). Both gaps
are RTL-side and concentrated in known mechanisms; closing requires
architectural feature additions (SFB, better BTB, etc.), each its own
brainstorm + plan cycle.

**CORRECTION TO PRIOR DRAFT (2026-05-01 17:00):** An earlier draft of
this doc attributed ~24% of the dhry gap to "binary/compiler" and
listed "dcache hit latency reduction (2 → 1 cycle)" as a follow-up
candidate. Both claims were wrong:
- Reference Core A / its build framework dhrystone convention is `-O2 -ffast-math -DPREALLOCATE=1`
  with `#pragma GCC optimize("no-inline")`. Our build (`-O2
  -march=rv64gc_zba_zbb_zbs_zicond -mabi=lp64d`) is convention-equivalent;
  Zbb/Zicond have near-zero impact on dhry. Binary contribution is
  1–3%, not 24%.
- Reference Core A's dcache is a 3-stage pipeline (S0/S1/S2) with 4-cycle
  load-to-use (Reference Core A (large config) config) or 5-cycle (a larger reference-core config). rv64gc-v2's
  2-cycle hit / ~3-cycle load-to-use is *already faster than Reference Core A*.
  Industry convention (commercial cores at 3–5 cycles, Reference Core A = 4–5,
  a low-end RV core = 2) puts 1-cycle outside the field — it requires VIPT + way
  prediction, a structural rework, not a parameter flip.

---

## What the methodology produced (Phases A–D)

### Phase A — Counter inventory + minimal additive instrumentation

**Commits landed:**
- `766f8d7` — ROB other-class sub-decomposition (mul/div/csr/bru/unknown)
- `4a78605` — Issue-stall classification (operand/fu/arb)

Two pure-additive instrumentation changes (~80 lines total). No production
RTL change. Functional 21/21 PASS, clockcheck 3/3 PASS preserved.

**Key inventory finding:** the 4-wide PERF_PROFILE was already richer
than the methodology assumed. The two additions filled the only real
visibility gaps (sub-class for "other" head-stall + issue-stall reasons).

### Phase B — Bottleneck ranking

| Workload | #1 bucket | #2 bucket | #3 bucket |
|---|---|---|---|
| cm iter1 | Issue operand-stall (60% of gap) | Head-wait unknown plain-ALU (40%) | Head-wait load (17%) |
| cm iter10 | (same as iter1) | (same) | (same) |
| dhrystone | Head-wait load (56% of gap) — 71% in 2 PCs | Issue operand-stall (32%) | Head-wait unknown (11%) |

**Refuted at Phase B (do not re-investigate):**
- Structural capacity (all `*_full = 0`)
- Rename pressure (`stall_* = 0`)
- IQ depth too small (refutes original dhry-H4)
- Checkpoint back-pressure (refutes original dhry-H2)
- NUM_ALU=3 contention (refutes original cm-H3)
- BPU return-stack degradation (refutes original dhry-H3)
- MUL/DIV pipeline depth (3.4% / 0% of gap)
- CSR serialization (0% everywhere)

### Phase C — 6 active hypotheses enumerated

H1 (ALU bypass coverage), H2 (Load wakeup latency), H3 (BPU mispredict),
H4 (dhry hot-spot), H5 (arb_loss), H6 (PRF read-port pressure).

### Phase D — 5 microbench probes refuted/confirmed each

| Hypothesis | Probe verdict | Evidence |
|---|---|---|
| H1 ALU bypass coverage | **REFUTED** | `alu_chain_8` IPC 3.290 = `independent_quad` IPC 3.284 (within 0.2%) |
| H2 Load wakeup latency | **CONFIRMED but INTRINSIC** | `dhry_call_mimic` reproduces dhry's load-at-head pattern; the latency is already as tight as the bypass network supports |
| H3 BPU mispredict | **CONFIRMED INTRINSIC** | `bpu_data_dep_branch` = 29.4% mispredict on a true random branch — TAGE structurally can't predict random |
| H4 dhry 2-PC hot-spot | **CONFIRMED (overlaps H2)** | Same root cause as H2 |
| H5 arb_loss small | **REFUTED-INVERTED** | Huge on synthetic INT (65–77%), tiny on real workloads (5.7%/0%) |
| H6 PRF read-port pressure | **REFUTED** | `independent_quad` operand_not_ready = 1 cycle of 3052 |

**Probe-derived finding: structural ceiling on 4-wide ALU-only workloads
is ~3.3 IPC**, not 4.0, due to IQ partitioning (u_iq0=2, u_iq1=1,
u_iq2=1) and loop overhead. This is a design choice, not a defect.

### What did NOT happen: Phase D Task 11 (RTL iterations)

The plan reserved Task 11 for iterative RTL changes per confirmed
hypothesis with predicted-IPC-delta gating. **No iterations were
executed because all confirmed hypotheses turned out to be intrinsic
or already-tight**, leaving no falsifiable RTL change to attempt within
the methodology's discipline (predicted delta committed before measure,
30%-divergence triggers refutation).

Executing speculative RTL changes without a confirmed mechanism would
violate the methodology's core principle and risk regressing the
post-Load1-bypass state (which is functionally clean and matches all
gates: 21/21 PASS, clockcheck 3/3 PASS, real measured numbers stable).

---

## Final measurements (cd54cf1 → 8a363d7 unchanged)

The instrumentation added in Phase A is sim-only and does not change
runtime semantics. Performance numbers are identical to `cd54cf1` (the
Load1 bypass fix landing).

| Workload | Cycles | IPC | Metric | vs Reference Core A (large config) 4-wide floor | vs a commercial 3-wide OoO core stretch |
|---|---:|---:|---|---:|---:|
| dhrystone (100 iter) | 23,514 | 2.027 | **2.42 DMIPS/MHz** | 4.00 → −39.5% | 4.72 → −48.7% |
| coremark iter1 | 199,452 | 1.665 | **5.01 CM/MHz** | 6.2 → −19.2% | 8.24 → −39.2% |
| coremark iter10 | 1,860,512 | 1.719 | **5.37 CM/MHz** | 6.2 → −13.3% | 8.24 → −34.8% |

**Functional 21/21 PASS, clockcheck 3/3 PASS preserved throughout.**

---

## Follow-up RTL candidates (out of scope for this methodology;
each would require its own brainstorm + plan cycle)

Ranked by predicted IPC win × ease × confidence (sourced from the
Reference Core A paper and Reference Core A source — see references):

1. **Short-Forward-Branch (SFB) fold-into-predication** — biggest
   expected win for both cm and dhry. The Reference Core A team credits this with
   up to 1.7× IPC on branch-dense sequences. Mechanism: detect short
   forward branches at decode, fold the branch + small target block
   into a predicated micro-op, eliminating the branch entirely (no
   prediction needed → no mispredict). Touches: decode, rename, ALU
   predicate handling. Invasive but bounded. Predicted: 5–15% IPC win
   on dhry (procedure-call-heavy), 3–8% on cm.
2. **TAGE-L loop predictor verification.** Confirm rv64gc-v2's loop
   predictor is TAGE-L equivalent (with loop length tracking). If it's
   simpler TAGE without loop tagging, Reference Core A (large config)'s loop-handling advantage
   may explain part of cm's mispredict-rate gap on regular loops.
   Predicted: 2–5% on cm if upgrade needed.
3. **uBTB / next-line predictor sizing.** Compare entry counts vs
   Reference Core A (large config) (uBTB 64+ entries, NLP 32+ entries). Easy parameter
   adjustments if undersized. Predicted: 1–3% on both workloads.
4. **Flush recovery latency narrowing.** Each cm mispredict costs
   ~5–7 cycles of recovery. If reduced to 3–4 cycles via shorter flush
   pipe, ~5% of cm gap recoverable. Investigation needed: trace
   flush-to-redirect cycle path in core_top.
5. **Speculative wakeup at issue (not at WB).** Already partially
   present (`spec_wake_p0/p1` counters non-zero), but could be more
   aggressive. Risk: recovery cost on speculation failure.

**Explicitly OUT of follow-up consideration (per Reference Core A research findings):**
- Dcache hit latency 2→1: structural, NOT minimal; rv64gc-v2 already
  faster than Reference Core A on this axis
- dhry compiler/binary investigation: contribution is 1–3%, won't move
  the needle on the −39.5% gap

**References:**
- Reference Core A paper: Zhao et al., CARRV 2020 — https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf
- Reference Core A LSU source: https://github.com/riscv-boom/riscv-boom/blob/master/src/main/scala/v4/lsu/lsu.scala
- Reference Core A Memory System docs: https://docs.boom-core.org/en/latest/sections/memory-system.html
- riscv-tests dhrystone: https://github.com/riscv-software-src/riscv-tests/tree/master/benchmarks/dhrystone

---

## Methodology assessment

The 4-phase methodology worked as designed:
- Phase A established factual instrumentation
- Phase B narrowed from many possible causes to a top-3 per workload
- Phase C produced falsifiable hypotheses with predicted signatures
- Phase D probes refuted speculative hypotheses (H1, H5, H6) and
  classified remaining ones as intrinsic (H2, H3, H4)

**The methodology's most valuable output is the refutation set**, which
prevents the team from wasting RTL-change cycles on hypotheses that
data has eliminated. The Load1 bypass cycle (cd54cf1) succeeded
specifically because it followed this discipline; not finding additional
quick wins doesn't mean the methodology failed — it means the design is
already well-tuned and remaining gains require structural changes.

This doc and its companions form a permanent record of what was
investigated, what was eliminated, and what would need to happen next.
Future sessions can resume from this point without re-investigating the
refuted paths.

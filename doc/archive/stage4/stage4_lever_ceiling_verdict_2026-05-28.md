# Stage 4 Lever-Ceiling Verdict

Date: May 28, 2026
Status: **Stage 4 active-RTL campaign closed — well-tuned floor, CONFIRMED on the
current baseline (zero new sim).** Three parallel read-only ceiling probes plus a
current-baseline confirmation (§ "Current-baseline confirmation" below) establish
that **no remaining lever clears the +3% promotion gate.** No RTL was promoted;
`src/rtl` is byte-identical to the Stage 3 boot-OK commit `ce93aea`, so the
`BOOT OK` artifact is intact by construction. Builds on
`doc/stage4_phase0_findings_2026-05-28.md`; plan of record
`doc/stage4_perf_campaign_plan_2026-05-28.md`.

## Current-baseline confirmation (zero new sim — from baseline dsim.log STAT_DUMP)

The bypass-fire counters are emitted in each baseline-run `dsim.log` (the RTL has
`rob_head_arith_wb_bypass_fire_cnt` / `rob_head_load_wb_bypass_fire_cnt`,
`rob.sv:1057-1126`). Exposed head-stall = (rob_head_not_ready by class) − (WB
bypass fires) — the same arithmetic that reproduces the 2026-05-03 trace exactly
(517,857 − 451,853 = 66,004). On the CURRENT baseline:

| Row | cyc | head-not-ready (pre-bypass) | bypass-resolved | EXPOSED total | exp. ALU(other) | exp. load | exp. branch | exp. store |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| DS100 | 18,532 | 4,202 (22.7%) | 3,627 (86%) | **575 (3.1%)** | 394 (2.1%) | 45 (0.24%) | 13 | 123 |
| DS300 | 53,536 | 12,385 (23.1%) | 10,626 (86%) | **1,759 (3.3%)** | 492 (0.9%) | 37 (0.07%) | 611 | 619 |
| CM1 | 159,123 | 65,177 (41.0%) | 52,957 (81%) | **12,220 (7.7%)** | 4,003 (2.5%) | 2,740 (1.7%) | 3,105 | 2,367 |
| CM10 | 1,468,279 | 600,298 (40.9%) | 506,566 (84%) | **93,732 (6.4%)** | 32,228 (2.2%) | 19,063 (1.3%) | 23,370 | 19,066 |

The reframe HOLDS on current RTL and tightens: the registered CDB resolves 81–86%
of head-not-ready. **Max exposed single class = 2.5% (CM ALU); total exposed
reclaimable head-stall is 3.1–3.3% (Dhrystone) / 6.4–7.7% (CoreMark).** Every
single-lever ceiling is below the +3% gate. Notably **Dhrystone's "19% load"
stall is 99.6% bypassed (exposed load = 0.07%)**, so the dcache-2→1 / prefetch
levers are firmly DEAD for Dhrystone (revise the §table "1–4%" down to ~0% DS,
≤1.7% CM). The stale-trace caveat below is RESOLVED.

## TL;DR

The headline "CoreMark = 25% ALU dependency chain" — which motivated the original
ladder — is a **pre-bypass pressure-counter artifact**. The registered CDB's
same-cycle bypass network already resolves ~85% of it. The true *exposed*
(reclaimable) head-stall is ~14.5% of cycles, branch-dominated, and every piece
is near-intrinsic: a serial load-fed chain already running at 1 cycle/link, the
deliberate registered-CDB +1-cycle wakeup, or MUL latency. Every candidate lever
measures **sub-gate** (realistic ceiling < +3%) and costs weeks-to-months of
structural/speculative RTL that fights the very timing fixes (registered CDB,
2-stage dcache) that make the design fast.

## The bypass reframe (the decisive finding)

From `benchmark_results/item12_baseline_coverage_20260503/.../coremark_iter10_checkedin.trace_summary_v2.json`
(`rob_head`, `cycles_sampled`=1,860,512):

| ROB-head class | PRE-bypass (`class_counts`) | bypass fires | POST-bypass exposed (`raw_headstall_class_all`) |
|---|---:|---:|---:|
| other (ALU/MUL) | 517,857 (27.8%) | 451,853 (`head_arith_wb_bypass_fires`) | **66,004 (3.5%)** |
| load | 184,685 (9.9%) | 163,724 (`head_load_wb_bypass_fires`) | **20,961 (1.1%)** |
| branch | 149,191 (8.0%) | — | **149,191 (8.0%)** |
| store | 33,440 (1.8%) | — | **33,440 (1.8%)** |

The pre-bypass "other" is 85% producer-class `unknown` (441,036) that the
registered CDB bypasses same-cycle. **The dominant *exposed* head-stall class is
BRANCH (8.0%), not ALU (3.5%).** Those branches (`core_state_transition`) do NOT
mispredict — they wait at the ROB head for a serial load-fed compare chain
(`lbu *str → addiw -48 → zext.b → bgeu`) to resolve.

## Lever ceiling table (all sub-gate)

| Lever | Realistic ceiling | Clears +3%? | Effort / risk | Verdict |
|---|---|:--:|---|---|
| **Value prediction** (ALU chain) | <1% IPC CM, ~0% DS | no | 3–6 wk; fights registered-CDB timing; recovery needs selective-replay | **DROP** — addressable pool 3.5%, and CRC/matrix/state values are unpredictable (pseudo-random / data-dependent / load-fed) |
| **Narrow 2-deep / chained ALU** | 0.5–2% CM (best case), ~0% DS | no | weeks; ALU datapath + decode/IQ 3rd-operand port; front-end fusion-detect timing | **lean DROP** — CRC (the clean target) <1% of cycles; biggest exposed bucket (state branches) is load-fed, not an ALU RAW chain |
| **L1D prefetcher** (misses) | <0.17% (abs), ~0% real | no | 2–4 wk | **DROP** — L1D miss rate 0.008–0.04%; the misses are pointer-chase first-touches a stride/next-line engine cannot predict |
| **dcache 2→1 hit** (load-use) | 1–4% per workload | no | multi-month, structural, high timing risk | **lean DROP** — attacks the right term but load completion is already 1 cycle with delay-0 consumer wakeup (91% CM / 93% DS); the residual is consumer execute + registered-CDB wakeup + commit, which faster dcache does not touch. rv64gc-v2 is already faster load-to-use than Reference Core A (2-cyc vs 3-cyc). |

Supporting evidence (verified): L1D load-miss counts DS100=1, DS300=4, CM1=23,
CM10=47 (baseline `dsim.log` "D-cache load miss allocation summary"); LSU
issue-to-WB latency lat1≈549,416 / lat2≈6,054 / lat8+≈7 on CM10; load→consumer
issue delay-0 = 91% (CM10) / 93% (DS100). `dep_alu_wait_not_issued` (833,504 CM1
/ 8,165,615 CM10 = 556% of cycles) is a per-cycle slot SUM, not a cycle count —
it ranks pressure, it is not reclaimable cycles.

## Component decomposition of the exposed stall

- **LIST** (`core_bench_list` pointer-chase, `ld a4,0(s0)→bnez→mv s0,a4`):
  largest pre-bypass head-load bucket (65,280 cyc), 100% L1-hit (avg_lat 1.00),
  delay-0 consumer. Fundamentally serial pointer-chase — only address/pointer
  *prediction* (adversarial, sort-shuffled) or impossible prefetch breaks it.
- **STATE** (`core_state_transition`): exposed-branch dominant; branches wait on
  a load-fed `lbu→addiw→zext.b→cmp` char-classification chain; not mispredicts.
- **MATRIX**: `mulw` (1-cycle MUL) + loop-carried `addw` reduction + `sw` of the
  accumulator; latency gated by two serial MULs, not ALU depth.
- **CRC**: a clean 6-deep dependent ALU recurrence but only ~0.5% of cycles.
- **Dhrystone**: `strcpy`/`strcmp` L1-hit load-to-use; post-bypass "other" only
  2,761 cyc → ~0 ALU-chain payoff; the 19% load-head-stall is hit-latency.

## Why this is the floor

The bypass network already hides the bulk of the apparent ALU stall. What remains
is (a) serial load-fed chains (pointer-chase / char-classification) already
running at 1 cycle/link — intrinsic to the algorithm's data dependence; (b) the
deliberate +1-cycle registered-CDB consumer wakeup (`rv64gc_core_top.sv:145-151`,
the fix that breaks the select→ALU→wakeup→re-select loop); and (c) MUL latency.
None is a parameter tweak; all gate-clearing attacks are multi-month structural
rework past an already-better-than-Reference Core A design point (CM 6.85 > ~6.2; DS load-to-
use faster than Reference Core A). This re-confirms — now rigorously and at a +30% higher
performance level — the 2026-05-01 PARTIAL-FLOOR conclusion.

## Caveat — RESOLVED

The bypass-reframe was originally derived from a 2026-05-03 trace. It is now
confirmed directly on the current baseline (§ "Current-baseline confirmation"):
the bypass decomposition is emitted in each baseline `dsim.log` STAT_DUMP, so no
new sim was needed. The qualitative conclusion holds and the exposed percentages
are tighter than the old trace (max single-class 2.5%). The two remaining
optional probes (Spike value-trace for a precise VP hit-rate; state-branch
latency-vs-mispredict split) would only further firm an already sub-gate DROP and
are not required for sign-off.

## Recommendation — SIGN OFF

**Accept the well-tuned floor as the Stage 4 outcome.** Confirmed on the current
baseline: total exposed reclaimable head-stall is 3.1–3.3% (Dhrystone) /
6.4–7.7% (CoreMark), with no single-lever ceiling above 2.5% — all below the +3%
promotion gate. The campaign's deliverable is the discipline: 5+ levers refuted
on evidence **before** any wasted RTL/sim, plus a verified bypass-corrected
bottleneck characterization showing the registered CDB already does the work the
original ladder assumed was open.

Any further IPC at this design point requires one of:
- **Relax the +3% gate** for a marginal (~1–2%) structural win (narrow chained
  ALU on the CM ALU residual) — explicit policy change.
- **Multi-month structural** work (dcache 2→1 hit, pointer/address prediction for
  the list pointer-chase) — past an already-better-than-Reference Core A design point.
- **A different optimization axis** — Fmax/timing closure, area/power efficiency,
  or a broader/representative workload suite (the 2 benchmarks here are
  near-floor; target workloads may expose different headroom).

Stage 4 (IPC-on-current-benchmarks) is closed at the well-tuned floor:
**CoreMark 6.85 CM/MHz (> Reference Core A ~6.2), Dhrystone 3.22 DMIPS/MHz.**

# 4-Wide RTL Refactor Sign-off — 2026-05-01 (refresh)

**Supersedes:** `doc/4wide_signoff_2026-04-30.md` (numbers stale — based
on a CoreMark functional bug that inflated CM/MHz to 6.05; bug RESOLVED
at `cd54cf1`, real numbers below).

**Branch:** `master`
**Final HEAD:** `23248f0`
**Pivot point:** `4f28619` (last 6-wide RTL on master)
**Simulator:** DSim 2026.0.0
**Plusargs:** `+PERF_PROFILE`

> ## ⚠ Sign-off VERDICT: PARTIAL — both floors missed; gap is partially
> ## intrinsic per data-driven analysis (see doc/4wide_perf_gap_results_2026-05-01.md)
>
> The 5-stage RTL refactor (Stage 1 Rename+ROB → Stage 5 Frontend+TB)
> landed cleanly with all functional, clockcheck, and STOP-OK gates
> green. The CoreMark functional bug introduced by Stage 2 (missing
> Load1 bypass slot — `NUM_BYPASS_SRCS` shrunk 6→4 with only Load0
> restored) was diagnosed via subagent trace-diff and fixed at
> `cd54cf1` (3-line fix: `NUM_BYPASS_SRCS=5` + add `bypass[4]`
> mirror). Post-fix instrumentation top-up (Tasks 1–3 of the gap-
> closure plan) added head-stall sub-classification and issue-stall
> classification.
>
> **Sign-off measurements (real, post-fix):**
>
> | Workload | CM/MHz or DMIPS/MHz | MegaBoom 4-wide floor | Gap |
> |---|---:|---:|---:|
> | cm iter1 | 5.01 CM/MHz | 6.2 | −19.2% |
> | cm iter10 | 5.37 CM/MHz | 6.2 | −13.3% |
> | dhrystone | 2.42 DMIPS/MHz | 4.00 | −39.5% |
>
> The gap-closure analysis (4 phases, 5 microbench probes, 6
> hypotheses) ran to completion. **Most hypotheses were REFUTED by
> data** (H1 ALU bypass coverage, H5 arb_loss, H6 PRF read-port). The
> remaining hypotheses are either INTRINSIC (H3 BPU mispredict on
> data-dependent branches — TAGE structurally can't predict random)
> or already as tight as the design supports (H2 load wakeup latency).
>
> No quick-win RTL change is currently identifiable that would close
> either gap to floor. **Closing further requires either accepting the
> intrinsic gap, pursuing structural changes (flush recovery latency
> narrowing, dcache hit latency reduction), or addressing the
> compiler/binary contribution to dhry.**

---

## Sign-off targets vs measured

| Tier | Required | Measured | Pass? |
|---|---:|---:|---|
| Floor — MegaBoom 4-wide | CM/MHz ≥ 6.2 | 5.01 (iter1), 5.37 (iter10) | ❌ −19% / −13% |
| Floor — MegaBoom 4-wide | DMIPS/MHz ≥ 4.00 | 2.42 (100 iters) | ❌ −39.5% |
| Stretch — Cortex-A72 | CM/MHz ≥ 8.24 | 5.01 / 5.37 | ❌ −39% / −35% |
| Stretch — Cortex-A72 | DMIPS/MHz ≥ 4.72 | 2.42 | ❌ −48.7% |

**Functional regression:** 21/21 PASS (8 rv64ui_* + 10 bench_* + dhry +
cm iter1 + cm iter10), all proper `tohost=1` under tightened STOP-OK
(no magic-tohost masking).
**Clockcheck microbenches:** 3/3 PASS, 0 diverging cycles.

---

## Final 4-wide bench measurements

| Workload | Cycles | Instret | IPC | Derived metric |
|---|---:|---:|---:|---|
| dhrystone (100 iters) | 23,514 | 47,670 | 2.027 | **2.42 DMIPS/MHz** |
| cm iter1 | 199,452 | 332,110 | 1.665 | **5.01 CM/MHz** |
| cm iter10 | 1,860,512 | 3,197,342 | 1.719 | **5.37 CM/MHz** |
| bench_loop_100 | 237 | 709 | 2.992 | (microbench) |

---

## Full commit history (gap-closure work)

| Commit | Subject |
|---|---|
| `cd54cf1` | fix(stage2-bypass): restore Load1 bypass slot — fixes cm BPU mistraining cascade |
| `56ee37c` | doc: 4-wide perf gap analysis methodology — 5-phase data-driven design |
| `68ddf57` | doc: revise perf gap methodology — drop 6-wide diff, lock in initial 4-wide findings |
| `7985ea6` | doc: 4-wide perf gap closure — executable implementation plan |
| `766f8d7` | perf-instr: refine ROB other-class head-stall (mul/div/csr/bru/unknown) |
| `4a78605` | perf-instr: add issue-stall classification (operand/fu/arb) |
| `d11aac0` | doc: 4-wide Phase A+B+C — bubble inventory, bucket ranking, hypothesis table |
| `8a363d7` | doc: fix internal source-pointer paths after move benchmark_results/→doc/ |
| `23248f0` | perf-probe: 5 microbench .S probes + Phase D hypothesis verdict table |
| (this doc) | doc: 4-wide perf gap closure RESULTS + refreshed sign-off |

---

## Architectural state (4-wide as merged + Load1 bypass fix)

| Param | Value | Notes |
|---|---|---|
| PIPE_WIDTH | 4 | Stage 1 |
| FETCH_BYTES | 16 | Stage 1 |
| ROB_DEPTH | 128 | Stage 1 (count_r width fix at ab9e897) |
| INT_PRF_DEPTH | 160 | Stage 1 |
| INT_PRF read/write | 12R6W | 4 CDB + 2 load_wb writes; 3 ALU × 2 + 2 BRU × 2 reads |
| NUM_ALU | 3 | Stage 2 |
| MUL_LATENCY | 3 | |
| CDB_WIDTH | 4 | Stage 2 |
| **NUM_BYPASS_SRCS** | **5** | Stage 2 + Load1 fix at cd54cf1 (was incorrectly 4) |
| IQ_INT_DEPTH × NUM_SELECT | 24 × {2, 1, 1} | u_iq0=2, u_iq1=1, u_iq2=1 |
| LSU LQ/SQ depth | 32 / 32 each | Stage 3 |
| L1D banks | 2-bank dual-port | Stage 4 |
| Frontend | uop cache + LB at PIPE_WIDTH=4 | Stage 5 |
| load_wb sideband | 2 ports (Load0 + Load1) | Stage 2 architectural addition |

---

## Why floor wasn't reached (data-driven attribution)

### CM (5.01 CM/MHz, target 6.2; 24% IPC improvement needed)

Composition of the gap (per `doc/4wide_perf_gap_results_2026-05-01.md`):
- ~12% intrinsic BPU mispredict tax (H3 confirmed via `bpu_data_dep_branch`
  probe — 29.4% mispredict on true random branch)
- ~17% intrinsic load latency at ROB head (loads complete in 1 cycle, but
  the head-wait cost is intrinsic to OoO slack on the narrowed machine)
- ~35% operand-stall (multi-causal; H1 bypass coverage refuted as the
  cause; remaining mechanism is dependency chains that don't pipeline
  across iterations as well as on a wider machine)

No single-RTL-change targeted fix has been identified by the methodology.
Closing requires multiple small accretive wins or a structural change.

### DHRY (2.42 DMIPS/MHz, target 4.00; 65% improvement needed)

- 6-wide pre-pivot was at 3.04 DMIPS/MHz on the same binary — also 24%
  short of the 4.00 floor. **Half of the dhry gap is binary-related**,
  not RTL-related.
- 4-wide loses 0.62 DMIPS vs 6-wide (~20% IPC drop on dhry), driven
  primarily by the procedure-call hot-path's load-at-head behavior
  (top 2 PCs `0x80002002`, `0x80002022` account for 71% of all load
  head-wait cycles).
- Even with full RTL gap-closure, the binary-bound ceiling is ~3.04
  DMIPS unless compiler/binary work is also done.

---

## Recommendation

**Adopt this PARTIAL-FLOOR sign-off.** The 4-wide RTL is functionally
clean (21/21, clockcheck 3/3), the architectural narrowing is correct
(5 stages landed cleanly), and the cm functional bug introduced by
narrowing was diagnosed and fixed.

**Track follow-up work in three separate streams:**

1. **Flush-recovery latency narrowing** (RTL — small win ~5% on cm)
2. **Dcache hit-latency reduction** (RTL — major architectural change,
   targets ~17% load-wait reduction)
3. **dhry compiler/binary investigation** (out of RTL scope — targets
   ~24% binary-bound gap)

Each stream warrants its own brainstorm + plan cycle, gated by the same
data-driven discipline that produced this analysis.

**Reference for follow-up sessions:**
- Methodology + plan: `doc/4wide_perf_gap_{analysis,plan}_2026-05-01.md`
- Findings: `doc/4wide_perf_gap_results_2026-05-01.md`
- Per-phase deliverables: `doc/4wide_{perf_inventory, bottleneck_ranking, hypothesis_table, microbench_probes}_2026-05-01.md`

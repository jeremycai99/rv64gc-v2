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
> | Workload | CM/MHz or DMIPS/MHz | Reference Core A (large config) 4-wide floor | Gap |
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
| Floor — Reference Core A (large config) 4-wide | CM/MHz ≥ 6.2 | 5.01 (iter1), 5.37 (iter10) | ❌ −19% / −13% |
| Floor — Reference Core A (large config) 4-wide | DMIPS/MHz ≥ 4.00 | 2.42 (100 iters) | ❌ −39.5% |
| Stretch — a commercial 3-wide OoO core | CM/MHz ≥ 8.24 | 5.01 / 5.37 | ❌ −39% / −35% |
| Stretch — a commercial 3-wide OoO core | DMIPS/MHz ≥ 4.72 | 2.42 | ❌ −48.7% |

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

The gap is essentially all RTL-side. Composition:
- **4-wide narrowing penalty: ~20%** (4-wide vs 6-wide on same binary;
  6-wide hit 3.04, 4-wide hits 2.42). Driven primarily by the
  procedure-call hot-path's load-at-head behavior — top 2 PCs
  `0x80002002`, `0x80002022` account for 71% of all load head-wait.
- **Design gap to Reference Core A (large config): ~23%** — even our 6-wide at 3.04 was short
  of Reference Core A (large config)'s 3.93 DMIPS/MHz (the "4.00" is a round-up; canonical
  source Reference Core A paper, Zhao et al., CARRV 2020) on the same
  `riscv-tests` dhrystone convention. Reference Core A (large config)'s advantages are
  architectural: SFB (short-forward-branch fold-into-predication),
  better BTB/uBTB, TAGE-L loop predictor.
- **Binary contribution: 1–3%** (negligible). Both rv64gc-v2 (`-O2
  -march=rv64gc_zba_zbb_zbs_zicond -mabi=lp64d`) and Reference Core A / its build framework
  (`-O2 -ffast-math -DPREALLOCATE=1` + `#pragma no-inline` driver)
  are convention-equivalent. Bitmanip/Zicond have near-zero impact
  on dhrystone. The 2.42 → 4.00 gap is **>95% RTL-side**.

---

## Recommendation

**Adopt this PARTIAL-FLOOR sign-off.** The 4-wide RTL is functionally
clean (21/21, clockcheck 3/3), the architectural narrowing is correct
(5 stages landed cleanly), and the cm functional bug introduced by
narrowing was diagnosed and fixed.

**Follow-up RTL candidates** (each its own brainstorm + plan cycle),
ranked by predicted IPC win × ease × confidence:

1. **Short-Forward-Branch (SFB) fold-into-predication.** Reference Core A
   paper credits this with up to 1.7× IPC on branch-dense sequences.
   Predicted: 5–15% on dhry, 3–8% on cm. Touches decode + rename +
   ALU predicate handling. Invasive but bounded.
2. **TAGE-L loop predictor verification.** Confirm rv64gc-v2's loop
   predictor matches Reference Core A (large config)'s TAGE-L (with loop-length tracking).
   Predicted: 2–5% on cm.
3. **uBTB / next-line predictor sizing.** Compare entry counts vs
   Reference Core A (large config); easy parameter tweaks if undersized. Predicted: 1–3%.
4. **Flush-recovery latency narrowing.** ~5% cm if reducible.
5. **Speculative wakeup at issue (more aggressive).** Risk: spec failure
   recovery cost.

**Explicitly OUT of follow-up consideration** (per Reference Core A research):
- Dcache hit latency 2→1: structural (VIPT + way-prediction), NOT
  minimal; rv64gc-v2 already faster than Reference Core A here (Reference Core A 4-cycle
  load-to-use vs ours ~3-cycle).
- dhry compiler/binary investigation: 1–3% contribution, won't move
  the needle.

**Reference for follow-up sessions:**
- Methodology + plan: `doc/4wide_perf_gap_{analysis,plan}_2026-05-01.md`
- Findings: `doc/4wide_perf_gap_results_2026-05-01.md`
- Per-phase deliverables: `doc/4wide_{perf_inventory, bottleneck_ranking, hypothesis_table, microbench_probes}_2026-05-01.md`

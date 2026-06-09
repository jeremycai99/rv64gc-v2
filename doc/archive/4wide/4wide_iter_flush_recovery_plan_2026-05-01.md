# Cycle C — BRU Early-Redirect Enable — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Test and (if validated) enable the existing `+ENABLE_BRU_EARLY_REDIRECT` mechanism in rv64gc-v2 to reduce mispredict recovery latency. Predicted: cm +3–5% IPC, dhry +0–1% IPC.

**Architecture:** The mechanism is ALREADY implemented in RTL (`src/rtl/core/rv64gc_core_top.sv` lines 740–775) but plusarg-gated and disabled by default. Cycle C tests the existing mechanism with the plusarg, measures, and if win+clean promotes the default to enabled.

**Tech Stack:** SystemVerilog + DSim 2026 + python3 clockcheck.

**Companion docs:**
- `doc/4wide_gap_closure_sequence_2026-05-01.md` — sequence design (this is Cycle C)
- `doc/4wide_iter_uBTB_results.md` — Cycle A REFUTE-on-investigation result
- `doc/4wide_perf_gap_results_2026-05-01.md` — gap analysis findings (cm has 4343 mispredicts, ~13% of cm gap is recovery cost)

---

## Pre-recon (already done by plan author, recorded for reference)

The current rv64gc-v2 design has a "fetch-only BRU redirect contract" (per comment at `core_top.sv:780-782`):

> After execute redirects fetch, rename is intentionally quarantined until the mispredicting branch reaches commit and performs the architectural flush.

The `+ENABLE_BRU_EARLY_REDIRECT` plusarg activates an opt-in early-redirect mode (`core_top.sv:252-268`) where BRU mispredict redirects fetch + dequeue/decode immediately, without waiting for commit. The mechanism includes:
- `bru_early_redirect` signal (line 54)
- `bru_redirect_quarantine_r` state machine (lines 759-775)
- "early-frontend retention mode" (`keep_early_frontend`) that holds correct-path packets fetched by the execute-time redirect

In synthesis (non-SIMULATION), the mechanism is hard-coded OFF (`core_top.sv:275-276`). Promoting to default-enabled requires changing those lines.

The cm log already showed the mechanism inactive (no early redirects, no quarantine cycles). The plan validates the mechanism WORKS when enabled, then promotes the default if win.

---

## File Structure

| File | Purpose |
|---|---|
| `doc/4wide_iter_flush_recovery_prediction.md` | (create) Predicted IPC delta + criteria; committed BEFORE measurement |
| `doc/4wide_iter_flush_recovery_results.md` | (create) Final outcome (REFUTE OR success-promoted-default) |
| `src/rtl/core/rv64gc_core_top.sv` | (modify, ONLY on Task 5 success) flip `sim_bru0_early_redirect_en`/`sim_bru1_early_redirect_en` default in synthesis path; possibly modify the simulation-mode default to enable always |

---

## Task 1: Inspect the BRU early-redirect mechanism

**Files (read-only):** `src/rtl/core/rv64gc_core_top.sv` lines 50-280, 736-780.

- [ ] **Step 1: Confirm the plusarg + mechanism**

```bash
grep -nE "bru_early_redirect|bru_redirect_quarantine|ENABLE_BRU_EARLY_REDIRECT|sim_bru0_early|sim_bru1_early|keep_early_frontend" src/rtl/core/rv64gc_core_top.sv | head -30
```

Verify: the plusarg `ENABLE_BRU_EARLY_REDIRECT` enables `sim_bru0_early_redirect_en` and `sim_bru1_early_redirect_en` (`core_top.sv:261-268`); these gate the `bru_early_redirect` signal generation and the quarantine state machine; the synthesis path hard-codes them to 0 (`core_top.sv:275-276`).

Document inline: WHERE the plusarg flows (which lines), HOW the synthesis-default OFF is encoded, and any plusarg interactions (DISABLE_BRU0/1_EARLY_REDIRECT individual disables).

- [ ] **Step 2: Identify the runtime measurement signals**

```bash
grep -nE "Early redirects total|Quarantine cycles|sim_bru_quarantine_cycles|sim_bru_early_cnt" src/rtl/core/rv64gc_core_top.sv | head -10
```

Confirm: the existing PERF_PROFILE output already prints "Early redirects total / BRU0 / BRU1: <X> / <Y> / <Z>" and "Quarantine cycles: <N>". These give us direct measurement when the mechanism is active.

---

## Task 2: Predict + commit prediction note BEFORE any RTL or sim change

**Files:**
- Create: `doc/4wide_iter_flush_recovery_prediction.md`

- [ ] **Step 1: Write prediction**

```markdown
# Cycle C Prediction — BRU Early-Redirect Enable

**Date:** 2026-05-01
**Repo HEAD at prediction:** master @ <git log -1 --format=%h>
**Cycle:** C (flush-recovery latency narrowing via BRU early-redirect)
**Sequence design:** doc/4wide_gap_closure_sequence_2026-05-01.md

## Hypothesis

The existing `+ENABLE_BRU_EARLY_REDIRECT` mechanism (already implemented at
core_top.sv:740-775 but plusarg-gated OFF by default) reduces the mispredict
recovery cost by allowing fetch + decode to redirect to the correct path
immediately at BRU resolution, instead of waiting for the mispredicting
branch to reach commit. Cm has 4,343 mispredicts at ~5–7 cyc each ≈ ~25k
cycles of recovery; if the early-redirect saves 1–2 cycles per mispredict,
that's ~5k cycles saved ≈ 2.5% of cm cycles.

## Predicted change

- Step A (validation): run cm + dhry with `+ENABLE_BRU_EARLY_REDIRECT` plusarg
- Step B (if Step A wins): promote default by editing `core_top.sv:275-276`
  to enable in synthesis path too

## Predicted IPC delta (Step A measurement)

- cm iter1: 1.665 → 1.71 ± 0.015 (predicted +2.5–3.5%)
- cm iter10: 1.719 → 1.76 ± 0.015 (predicted +2.5–3.5%)
- dhrystone: 2.027 → 2.04 ± 0.010 (predicted +0–1%; dhry has only 128 mispredicts so minimal effect)

## Tolerance band (small-delta rule, predicted <3%)

±0.5% IPC absolute. So for cm at predicted +2.5–3.5%: in-range = +2.0% to +4.0%.
For dhry at predicted +0–1%: in-range = -0.5% to +1.5%.

## Confirmation criterion

Measured cm IPC delta in [+2.0%, +4.0%] AND dhry no-regression beyond ±2% AND
PERF_PROFILE shows non-zero "Early redirects total" + "Quarantine cycles" (proves
the mechanism is actually firing).

## Refutation criterion

(a) Measured cm IPC delta outside [+2.0%, +4.0%] — mechanism didn't help as predicted, OR
(b) PERF_PROFILE still shows 0 early-redirects (plusarg didn't activate the mechanism), OR
(c) Functional regression breaks 21/21 (mechanism has correctness bug), OR
(d) Clockcheck divergence (mechanism perturbs pipeline beyond allowlist)

## Promotion-to-default trigger

If Step A measurement is in-band: edit `core_top.sv:275-276` to enable in synthesis path. Re-build, re-run regression to confirm default-enabled match plusarg-enabled. Commit promotion.

If Step A is REFUTED: do not promote. Document and proceed to Cycle B.
```

- [ ] **Step 2: Commit prediction BEFORE any test run**

```bash
git add doc/4wide_iter_flush_recovery_prediction.md
git -c user.email="jeremycai@local" -c user.name="Jeremy Cai" commit -q -m \
  "doc: Cycle C prediction — BRU early-redirect predicted +2.5-3.5% cm

Mechanism already in RTL at core_top.sv:740-775 but plusarg-gated OFF
by default. Cycle C tests with +ENABLE_BRU_EARLY_REDIRECT, measures,
then promotes to default if in-band.

Tolerance: ±0.5% IPC absolute (small-delta rule).
Plan: doc/4wide_iter_flush_recovery_plan_2026-05-01.md"
```

---

## Task 3: Build (current default-OFF) and capture baseline

**Files:** none modified.

- [ ] **Step 1: Confirm build is current**

```bash
export LD_LIBRARY_PATH=
bash build_dsim.sh 2>&1 | tail -3
```

Expected: `DSim build OK`.

- [ ] **Step 2: Capture baseline (default-OFF) measurements**

These should match the prior baseline (cm IPC 1.665, dhry IPC 2.027).

```bash
export LD_LIBRARY_PATH=
bash run_dsim.sh tests/hex/coremark.hex 5000000 +PERF_PROFILE > /dev/null 2>&1
cp dsim_run.log benchmark_results/baseline_cm_iter1.log
grep -E "PASS at cycle|^IPC:|Early redirects total|Quarantine cycles" benchmark_results/baseline_cm_iter1.log

bash run_dsim.sh tests/hex/dhrystone.hex 100000 +PERF_PROFILE > /dev/null 2>&1
cp dsim_run.log benchmark_results/baseline_dhry.log
grep -E "PASS at cycle|^IPC:|Early redirects total|Quarantine cycles" benchmark_results/baseline_dhry.log
```

Expected: cm `IPC=1.665`, `Early redirects total / BRU0 / BRU1: 0 / 0 / 0`, `Quarantine cycles: 0`. dhry `IPC=2.027`, similarly zero.

If baselines DON'T match priors, halt — something has regressed since the last measurement.

---

## Task 4: Run with `+ENABLE_BRU_EARLY_REDIRECT` enabled

**Files:** none modified.

- [ ] **Step 1: cm iter1 with early-redirect enabled**

```bash
export LD_LIBRARY_PATH=
bash run_dsim.sh tests/hex/coremark.hex 5000000 +PERF_PROFILE +ENABLE_BRU_EARLY_REDIRECT > /dev/null 2>&1
cp dsim_run.log benchmark_results/early_cm_iter1.log
grep -E "PASS at cycle|^IPC:|Early redirects total|Quarantine cycles" benchmark_results/early_cm_iter1.log
```

Required output: `PASS at cycle <X>`, `IPC=<Y>`, `Early redirects total / BRU0 / BRU1: <non-zero> / <X> / <Y>`, `Quarantine cycles: <non-zero>`. The non-zero early-redirect counts prove the mechanism is firing.

If `Early redirects total = 0` even with the plusarg: the mechanism didn't activate — this is a REFUTE-(b) per Task 2 criteria. Do NOT proceed to Task 5; jump to Task 7b (REFUTE).

- [ ] **Step 2: cm iter10 with early-redirect enabled**

```bash
bash run_dsim.sh tests/hex/coremark_iter10.hex 5000000 +PERF_PROFILE +ENABLE_BRU_EARLY_REDIRECT > /dev/null 2>&1
cp dsim_run.log benchmark_results/early_cm_iter10.log
grep -E "PASS at cycle|^IPC:|Early redirects total|Quarantine cycles" benchmark_results/early_cm_iter10.log
```

- [ ] **Step 3: dhry with early-redirect enabled**

```bash
bash run_dsim.sh tests/hex/dhrystone.hex 100000 +PERF_PROFILE +ENABLE_BRU_EARLY_REDIRECT > /dev/null 2>&1
cp dsim_run.log benchmark_results/early_dhry.log
grep -E "PASS at cycle|^IPC:|Early redirects total|Quarantine cycles" benchmark_results/early_dhry.log
```

---

## Task 5: Functional + clockcheck regression with `+ENABLE_BRU_EARLY_REDIRECT`

**Files:** none modified — verification only.

- [ ] **Step 1: Functional regression**

The regression script doesn't pass `+ENABLE_BRU_EARLY_REDIRECT` by default. Add it via the EXTRA_PLUSARGS env var (the script's existing convention):

```bash
export LD_LIBRARY_PATH=
EXTRA_PLUSARGS="+ENABLE_BRU_EARLY_REDIRECT" bash scripts/regress_dsim.sh 2>&1 | tail -10
```

Expected: `Total: 21   PASS: 21   FAIL/OTHER: 0`. Any FAIL means the early-redirect mechanism has a correctness bug — REFUTE-(c) per Task 2.

If `EXTRA_PLUSARGS` isn't honored by `regress_dsim.sh`, edit the script's `dsim` invocation to pass the plusarg:
```
grep -nE "EXTRA_PLUSARGS|extra=" scripts/regress_dsim.sh
```
The script at line ~76 already has `$extra $EXTRA_PLUSARGS` — it should work. If env-var pass-through fails, alternative: edit `run_test()` to add the plusarg unconditionally for this run, then revert before commit.

- [ ] **Step 2: Clockcheck**

```bash
mkdir -p traces/iter_flush_recovery
for hex in bench_loop_100 bench_load bench_unrolled_5; do
    bash run_dsim.sh tests/hex/${hex}.hex 5000 +PERF_PROFILE +TRACE_PIPELINE +ENABLE_BRU_EARLY_REDIRECT > /dev/null 2>&1
    grep "^\[PIPE schema=pipe.v1\]" dsim_run.log > traces/iter_flush_recovery/${hex}.pipe.v1.trace
done
for hex in bench_loop_100 bench_load bench_unrolled_5; do
    python3 ../rv64gc-perf-model/tools/rtl_clockcheck.py \
        --baseline-pipe traces/baseline_6wide/${hex}.pipe.v1.trace \
        --refactor-pipe traces/iter_flush_recovery/${hex}.pipe.v1.trace \
        --allowlist tools/clockcheck_4wide.allowlist.json
    echo "EXIT $? for $hex"
done
```

NOTE: Early-redirect changes pipeline timing on mispredict-flush microbenches; clockcheck divergences here may be EXPECTED side-effects, not bugs. If diverging cycles > 0:
- Inspect: which cycles diverge? Are they all on mispredict-recovery paths? (Consistent with the change.)
- If yes: this is an intentional pipeline change; document the divergences and EXTEND the allowlist with `_notes` justification per the project's clockcheck convention. Do NOT auto-allow blanket divergence — characterize each.
- If no (divergences appear in non-mispredict cycles): the mechanism has unintended side effects; REFUTE-(d).

---

## Task 6: Compare measured vs predicted

**Files:** none modified.

- [ ] **Step 1: Build the result table**

For cm iter1, cm iter10, dhry: compute `Δ_measured = (IPC_early - IPC_baseline) / IPC_baseline`.

Build inline scratch table:
```
              | Baseline | Early-Redirect | Δ measured | In tolerance? |
cm iter1 IPC  | 1.665    | <X>            | <Δ%>       | YES (target +2.0% to +4.0%) |
cm iter10 IPC | 1.719    | <X>            | <Δ%>       | YES |
dhry IPC      | 2.027    | <X>            | <Δ%>       | YES (target -0.5% to +1.5%) |
```

- [ ] **Step 2: Apply confirmation/refutation criteria**

CONFIRM (proceed to Task 7a) IF:
- cm iter1 Δ in [+2.0%, +4.0%] AND
- dhry Δ in [−2.0%, +2.0%] (no regression) AND
- functional 21/21 PASS AND
- clockcheck PASS or only documented allowlist divergences AND
- "Early redirects total" > 0 (mechanism actually fired)

REFUTE (proceed to Task 7b) otherwise. Document the specific failed criterion.

---

## Task 7a: Promote `+ENABLE_BRU_EARLY_REDIRECT` to default

**Files:**
- Modify: `src/rtl/core/rv64gc_core_top.sv` lines 252-280 (enable defaults in both SIMULATION and synthesis paths)

**ONLY EXECUTE IF Task 6 said CONFIRM.**

- [ ] **Step 1: Inspect current default flip**

Read `core_top.sv:250-280`. The pattern is:
```systemverilog
`ifdef SIMULATION
    bit sim_bru0_early_redirect_en;
    bit sim_bru1_early_redirect_en;
    initial sim_bru0_early_redirect_en =
        $test$plusargs("ENABLE_BRU_EARLY_REDIRECT") &&
        !$test$plusargs("DISABLE_BRU_EARLY_REDIRECT") &&
        !$test$plusargs("DISABLE_BRU0_EARLY_REDIRECT");
    initial sim_bru1_early_redirect_en = ...
`else
    localparam logic sim_bru0_early_redirect_en = 1'b0;
    localparam logic sim_bru1_early_redirect_en = 1'b0;
`endif
```

- [ ] **Step 2: Edit defaults to enabled**

Change the SIMULATION initial block to enable by default (with optional disable plusarg), and the synthesis branch to enable always:

```systemverilog
`ifdef SIMULATION
    bit sim_bru0_early_redirect_en;
    bit sim_bru1_early_redirect_en;
    initial sim_bru0_early_redirect_en =
        !$test$plusargs("DISABLE_BRU_EARLY_REDIRECT") &&
        !$test$plusargs("DISABLE_BRU0_EARLY_REDIRECT");
    initial sim_bru1_early_redirect_en =
        !$test$plusargs("DISABLE_BRU_EARLY_REDIRECT") &&
        !$test$plusargs("DISABLE_BRU1_EARLY_REDIRECT");
`else
    localparam logic sim_bru0_early_redirect_en = 1'b1;
    localparam logic sim_bru1_early_redirect_en = 1'b1;
`endif
```

(Replace `ENABLE_BRU_EARLY_REDIRECT` opt-in semantics with default-on + opt-out via DISABLE_*. Synthesis localparam flips 1'b0 → 1'b1 on both lines.)

- [ ] **Step 3: Rebuild + verify default-enabled matches plusarg-enabled**

```bash
export LD_LIBRARY_PATH=
bash build_dsim.sh 2>&1 | tail -3
bash run_dsim.sh tests/hex/coremark.hex 5000000 +PERF_PROFILE > /dev/null 2>&1
grep -E "PASS at cycle|^IPC:|Early redirects total" dsim_run.log
```

The IPC and early-redirect count should match the Task 4 measurement (which used the plusarg). If they don't match, something else changed — debug before committing.

- [ ] **Step 4: Functional + clockcheck final**

```bash
bash scripts/regress_dsim.sh 2>&1 | tail -10
# Re-run clockcheck (mechanism is now default-on; pipeline traces should match Task 5)
```

Required: 21/21 PASS, clockcheck PASS or same allowlist as Task 5.

- [ ] **Step 5: Write success results doc**

Create `doc/4wide_iter_flush_recovery_results.md`:

```markdown
# Cycle C Results — BRU Early-Redirect Enable

**Date:** 2026-05-01
**Verdict:** SUCCESS (mechanism enabled by default)

## Measured

| | Baseline (default-OFF) | +ENABLE_BRU_EARLY_REDIRECT | Default-ON (post-promotion) | Δ vs baseline |
|---|---:|---:|---:|---:|
| cm iter1 IPC | 1.665 | <X> | <X> | <+Δ%> |
| cm iter10 IPC | 1.719 | <X> | <X> | <+Δ%> |
| dhry IPC | 2.027 | <X> | <X> | <+Δ%> |
| cm iter1 Early redirects | 0 | <N> | <N> | mechanism fires |
| cm iter1 Quarantine cycles | 0 | <M> | <M> | quarantine active |

Functional 21/21 PASS. Clockcheck: <PASS / N diverging cycles documented in allowlist>.

## Updated gap to Reference Core A (large config) floor

| Workload | New CM/MHz or DMIPS | Floor | Updated gap |
|---|---:|---:|---:|
| cm iter1 | <X> | 6.2 | <Y%> |
| cm iter10 | <X> | 6.2 | <Y%> |
| dhry | <X> | 4.00 | <Y%> |

## Sources of recovery savings

Per the SIM_BRU_RECOVERY_TOPN PERF_PROFILE output, the top mispredict PCs benefiting:
[paste top 5 from cm iter1 log]
```

- [ ] **Step 6: Commit RTL change + results + clockcheck allowlist if extended**

```bash
git add src/rtl/core/rv64gc_core_top.sv doc/4wide_iter_flush_recovery_results.md tools/clockcheck_4wide.allowlist.json
git -c user.email="jeremycai@local" -c user.name="Jeremy Cai" commit -q -m \
  "perf-iter C: enable BRU early-redirect by default — measured +<X>% cm

Hypothesis: existing +ENABLE_BRU_EARLY_REDIRECT mechanism (gated OFF
by default) reduces mispredict recovery cost.

Predicted: cm +2.5-3.5% (1.665 → ~1.71)
Measured: cm +<X>% (1.665 → <Meas>), dhry +<Y>% (2.027 → <Meas>)
In-band: YES (±0.5% IPC absolute tolerance)

PERF_PROFILE confirms mechanism firing: Early redirects total <N>,
Quarantine cycles <M> on cm iter1.

Functional 21/21 PASS. Clockcheck <PASS or allowlist extended for
N intentional pipeline-timing changes on mispredict-recovery paths>.

RTL change: core_top.sv:252-280 — flip simulation default from opt-in
(ENABLE_BRU_EARLY_REDIRECT plusarg required) to opt-out (DISABLE_*
plusarg required), and flip synthesis localparam from 1'b0 → 1'b1.

See doc/4wide_iter_flush_recovery_prediction.md for prediction committed
BEFORE the RTL change.
See doc/4wide_iter_flush_recovery_results.md for full measurement +
updated gap.

Cycle C complete. Next: Cycle B (SFB fold-into-predication)."
```

---

## Task 7b: REFUTE — write REFUTE doc, no RTL change

**Files:**
- Create: `doc/4wide_iter_flush_recovery_results.md`

**ONLY EXECUTE IF Task 6 said REFUTE.**

- [ ] **Step 1: Write REFUTE doc**

Create with the failed-criterion + measured numbers + reason analysis. Pattern:

```markdown
# Cycle C Results — BRU Early-Redirect Enable

**Verdict:** REFUTED (<specific criterion failed>)

## Measured

| | Baseline | +ENABLE_BRU_EARLY_REDIRECT | Δ measured | In tolerance? |
|---|---:|---:|---:|---|
| cm iter1 IPC | 1.665 | <X> | <Δ%> | NO (target +2.0% to +4.0%) |
| ...

## Refute reason

<One of:>
(a) Measured cm IPC delta outside band — mechanism didn't help as predicted (possibly because cm's mispredicts are clustered such that the 1-2 cyc savings don't compound)
(b) Mechanism didn't fire (Early redirects total = 0) — plusarg may not have been wired correctly OR additional gate prevents firing
(c) Functional regression broken — mechanism has correctness bug
(d) Clockcheck diverged on non-mispredict cycles — unintended side effect

## Implication

Cycle C produces no RTL change. Baseline (cm 1.665, dhry 2.027) unchanged.
Proceed to Cycle B (SFB fold-into-predication).
```

- [ ] **Step 2: Commit REFUTE doc**

```bash
git add doc/4wide_iter_flush_recovery_results.md
git -c user.email="jeremycai@local" -c user.name="Jeremy Cai" commit -q -m \
  "perf-iter C: BRU early-redirect REFUTED — <criterion>

Predicted: cm +2.5-3.5% (1.665 → ~1.71)
Measured: cm <Δ%> (1.665 → <Meas>) — outside ±0.5% tolerance band
OR <other criterion that failed>

RTL untouched. Baseline unchanged. Cycle C complete (REFUTE).

See doc/4wide_iter_flush_recovery_results.md for refute reasoning.

Next: Cycle B (SFB fold-into-predication)."
```

---

## Constraints

1. **DSim license is single-seat.** Sequential runs only.
2. **`export LD_LIBRARY_PATH=`** before any bash build_dsim.sh / run_dsim.sh / regress_dsim.sh.
3. **Pre-existing housekeeping (~30 files)** must NOT be committed. Specific `git add <file>`, never `git add -A`.
4. **`src/rtl/core/lsu/lsu.sv`** must NEVER be modified. This task touches `core_top.sv` only.
5. **Prediction note (Task 2) MUST be committed BEFORE the measurement runs (Tasks 3-4)** — methodology discipline.
6. **±0.5% IPC absolute tolerance** (small-delta rule).
7. **Working on `master`** is correct.
8. **Do NOT modify CDB_WIDTH, IQ depth, NUM_ALU, or any narrowing decision.**
9. **Clockcheck divergence on mispredict-recovery paths is EXPECTED with this change** — extend allowlist with documented `_notes` justifications, do NOT blanket-allow.
10. **The early-redirect mechanism is functionally complex (quarantine, packet retention, etc.).** If functional regression breaks even one test, do NOT try to "fix" the mechanism — REFUTE and revert.

---

## Self-review

- [x] Spec coverage: Task 1 inspect → Task 2 predict → Task 3 baseline → Task 4 enable+measure → Task 5 regression → Task 6 verdict → Task 7a/b commit. Each branch (SUCCESS/REFUTE) has a clean exit.
- [x] Placeholder scan: no TBD/TODO. The bash + edit blocks have actual code.
- [x] Type consistency: signal names (`bru_early_redirect`, `sim_bru0_early_redirect_en`, etc.) match between Task 1 inspection, Task 4 measurement, Task 7a edit.
- [x] Prediction-before-measurement order is explicit (Task 2 before Tasks 3-4).
- [x] REFUTE branch (7b) is explicit and actionable.
- [x] Plusarg pass-through to regress_dsim.sh has fallback path documented.
- [x] Clockcheck divergence handling is nuanced (expected on mispredict paths, suspicious elsewhere).

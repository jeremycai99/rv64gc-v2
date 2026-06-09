# Cycle A — uBTB / NLP Sizing Calibration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Auto-mode standing rule: subagent-driven-development is invoked automatically after this plan completes.

**Goal:** Validate the data-driven gap-closure methodology pipeline on a low-blast-radius RTL change by checking whether rv64gc-v2's BTB / NLP / branch-prediction storage sizes are undersized vs Reference Core A (large config). If undersized: bump and measure with predicted ±0.5% IPC tolerance. If match-or-exceed Reference Core A: REFUTE-no-change and document.

**Architecture:** 5-step cycle (investigate → predict → change → validate → commit-or-revert). Likely outcome based on pre-recon: REFUTE-no-change, since `BTB_ENTRIES=2048` already exceeds typical Reference Core A BTB size. Plan handles both branches cleanly.

**Tech Stack:** SystemVerilog + DSim 2026 + python3 clockcheck (`../rv64gc-perf-model/tools/rtl_clockcheck.py`).

**Companion docs:**
- `doc/4wide_gap_closure_sequence_2026-05-01.md` — sequence design (this is Cycle A)
- `doc/4wide_perf_gap_results_2026-05-01.md` — completed gap analysis
- `doc/4wide_signoff_2026-05-01.md` — current PARTIAL-FLOOR sign-off baseline

---

## Pre-recon (already done by plan author, recorded for reference)

Current rv64gc-v2 BPU storage:

| Component | Size | Source |
|---|---|---|
| BTB | 2048 entries × 8 ways = 256 sets | `src/rtl/core/include/rv64gc_pkg.sv:186-188` (`BTB_ENTRIES=2048`, `BTB_WAYS=8`) |
| TAGE-SC-L | (size TBD by Task 1) | `src/rtl/core/fetch/tage_sc_l.sv` exists |
| RAS | (size TBD by Task 1) | `src/rtl/core/fetch/ras.sv` exists |
| Next-line prefetch buffer | 4 entries | `src/rtl/core/fetch/next_line_prefetch_buffer.sv:45` (`NUM_ENTRIES=4`) |

The BTB at 2048 entries is large — Reference Core A typical is ~256-512 BTB entries. The NLP at 4 entries is small but it's a prefetch buffer (warm-cache helper), NOT the primary prediction path. The primary predictor is TAGE-SC-L + BTB + RAS, which appears well-equipped.

This pre-recon suggests REFUTE-no-change is the likely outcome. Plan handles this cleanly without wasted RTL build cycles.

---

## File Structure

| File | Purpose |
|---|---|
| `doc/4wide_iter_uBTB_prediction.md` | (create) Predicted IPC delta + confirmation/refutation criteria; committed BEFORE any RTL change |
| `doc/4wide_iter_uBTB_results.md` | (create) Final outcome (REFUTE-no-change OR measured RTL delta) |
| `src/rtl/core/include/rv64gc_pkg.sv` | (modify, ONLY if Task 3 decides to change params) BTB/NLP parameter values |
| `src/rtl/core/fetch/next_line_prefetch_buffer.sv` | (modify, ONLY if NUM_ENTRIES is bumped and is internal-not-pkg-derived) NLP storage size |

---

## Task 1: Investigate current rv64gc-v2 BPU storage sizes

**Files (read-only):**
- `src/rtl/core/include/rv64gc_pkg.sv` (BTB params + any TAGE/RAS params)
- `src/rtl/core/fetch/tage_sc_l.sv` (TAGE table sizes)
- `src/rtl/core/fetch/ras.sv` (RAS depth)
- `src/rtl/core/fetch/next_line_prefetch_buffer.sv` (NLP entry count)

- [ ] **Step 1: Catalog BTB params**

Run: `grep -nE "BTB_|^localparam" src/rtl/core/include/rv64gc_pkg.sv | grep -iE "btb"`
Expected output: `BTB_ENTRIES=2048`, `BTB_WAYS=8`, `BTB_SETS=256`. Record actual values found.

- [ ] **Step 2: Catalog TAGE-SC-L sizes**

Run: `grep -nE "ENTRIES|TABLE_SIZE|NUM_TABLES|HISTORY_LEN|TAG_BITS|^localparam" src/rtl/core/fetch/tage_sc_l.sv | head -30`
Record: number of TAGE tables, entries per table, history lengths, tag widths, SC (statistical corrector) sizes if separate.

- [ ] **Step 3: Catalog RAS depth**

Run: `grep -nE "DEPTH|ENTRIES|^localparam" src/rtl/core/fetch/ras.sv | head -10`
Record: RAS stack depth.

- [ ] **Step 4: Catalog NLP entry count**

Run: `grep -nE "NUM_ENTRIES|^localparam" src/rtl/core/fetch/next_line_prefetch_buffer.sv | head -10`
Expected: `NUM_ENTRIES=4`. Record actual value.

- [ ] **Step 5: Document findings inline**

Append to a scratch buffer (in your subagent context, not committed yet):
```
rv64gc-v2 BPU storage inventory (2026-05-01, master @ c732117):
- BTB: <entries> × <ways> = <sets> sets
- TAGE-SC-L: <num_tables> tables, entries/table = <list>, history lens = <list>, SC = <if separate>
- RAS: <depth> entries
- NLP: <entries> entries
```

This buffer feeds Task 2 comparison.

---

## Task 2: Look up Reference Core A reference values

**Files (web-fetched):**
- https://github.com/riscv-boom/riscv-boom/blob/master/src/main/scala/v4/ifu/btb.scala
- https://github.com/riscv-boom/riscv-boom/blob/master/src/main/scala/v4/ifu/bpd/tage.scala
- https://github.com/riscv-boom/riscv-boom/blob/master/src/main/scala/v4/common/config-mixins.scala (search for `MegaBoomConfig`, `LargeBoomConfig`, BTB params)
- https://docs.boom-core.org/en/latest/sections/branch-prediction/index.html

- [ ] **Step 1: WebFetch the Reference Core A BTB source**

Use the WebFetch tool on `https://github.com/riscv-boom/riscv-boom/blob/master/src/main/scala/v4/ifu/btb.scala` with prompt `"What are the BTB nSets, nWays, total entry count, tag bits, and any related parameters? Quote the relevant Scala code."`

Record Reference Core A's BTB nSets, nWays, total entries.

- [ ] **Step 2: WebFetch the Reference Core A (large config) config**

Use WebFetch on `https://github.com/riscv-boom/riscv-boom/blob/master/src/main/scala/v4/common/config-mixins.scala` with prompt `"What BTB parameters and BPD (branch predictor) parameters does the WithNMegaBooms or MegaBoomConfig set? Quote the bpdMaxMetaLength, BTB nSets, nWays, ghistLength, tage table sizes if visible."`

Record Reference Core A (large config)'s tuned BTB + BPD values.

- [ ] **Step 3: WebFetch the Reference Core A TAGE source**

Use WebFetch on `https://github.com/riscv-boom/riscv-boom/blob/master/src/main/scala/v4/ifu/bpd/tage.scala` with prompt `"What are the TAGE table sizes (nEntries per table), history lengths per table, tag bits per table, and number of tables in the default BoomTAGE? Quote the case class defaults."`

Record Reference Core A's TAGE configuration.

- [ ] **Step 4: WebFetch the Reference Core A docs**

Use WebFetch on `https://docs.boom-core.org/en/latest/sections/branch-prediction/index.html` with prompt `"What is BOOM's branch prediction structure? Are there micro-BTB, RAS, loop predictor, statistical corrector? What sizes does the doc cite?"`

Record any explicit RAS depth, NLP/uBTB info from the docs.

- [ ] **Step 5: Build comparison table in scratch buffer**

```
                  rv64gc-v2 (current)        Reference Core A (Mega)        Verdict
BTB entries       <Task1 value>              <Task2 value>         <larger/smaller/equal>
BTB ways          <>                         <>                    <>
TAGE tables       <>                         <>                    <>
TAGE entries/tbl  <>                         <>                    <>
RAS depth         <>                         <>                    <>
NLP entries       <>                         <>                    <>
```

This table feeds Task 3.

---

## Task 3: Decide proceed-or-REFUTE

**No files modified in this task — pure decision.**

- [ ] **Step 1: Apply decision rule**

For EACH component in the Task 2 comparison table:

- If `rv64gc-v2 size < BOOM size`: this component is undersized; mark as a CANDIDATE for the parameter bump
- If `rv64gc-v2 size ≥ BOOM size`: this component is correctly-or-over-sized; mark as REFUTED for this hypothesis

- [ ] **Step 2: Aggregate decision**

If at least ONE component is a CANDIDATE: proceed to Task 4 (predict + change).
If ALL components are REFUTED (≥ Reference Core A): the cycle's hypothesis is REFUTED-no-change — skip to Task 8 (document + proceed to Cycle C).

**Important:** "Within ~10% of Reference Core A size" still counts as ≥ Reference Core A (no change). Only meaningfully-undersized components (e.g., rv64gc-v2 has 32 BTB entries when Reference Core A has 256) qualify as CANDIDATES. Use engineering judgment: if a small bump (≤2× current) doesn't materially change the design, the cycle has nothing to test.

- [ ] **Step 3: Branch the plan**

Record the decision in the scratch buffer:
- `DECISION: PROCEED — components to bump: <list>`
- OR `DECISION: REFUTE-no-change — all components ≥ BOOM`

Tasks 4-7 only execute on PROCEED. Task 8 executes either way.

---

## Task 4: Write + commit prediction note (BEFORE any RTL change)

**Files:**
- Create: `doc/4wide_iter_uBTB_prediction.md`

**SKIP this task and Tasks 5-7 if Task 3 said REFUTE-no-change.**

- [ ] **Step 1: Write the prediction note**

Create `doc/4wide_iter_uBTB_prediction.md` with:

```markdown
# Cycle A Prediction — uBTB / NLP Sizing

**Date:** 2026-05-01
**Repo HEAD at prediction:** master @ <current HEAD from git log>
**Cycle:** A (uBTB / NLP sizing calibration)
**Methodology:** doc/4wide_perf_gap_analysis_2026-05-01.md
**Sequence design:** doc/4wide_gap_closure_sequence_2026-05-01.md

## Hypothesis

rv64gc-v2's <component(s)> at <current size(s)> is/are undersized vs
Reference Core A (large config) at <Reference Core A size(s)>. Bumping to <new size(s)> should reduce
BPU-induced flush cycles and produce a small IPC win on cm and dhry.

## Predicted RTL change

- File: `src/rtl/core/include/rv64gc_pkg.sv` line <N>
- Change: `<param> = <old>` → `<param> = <new>`
- (Repeat per component)

## Predicted IPC delta

- cm iter1: 1.665 → <predicted, e.g., 1.682> (predicted Δ = +<X>%, +0.0XX absolute)
- cm iter10: 1.719 → <predicted>
- dhrystone: 2.027 → <predicted>

## Tolerance band (small-delta rule, predicted <3%)

±0.5% IPC absolute. So for predicted +1.0% IPC on cm: in-range = +0.5% to +1.5%.

## Confirmation criterion

Measured cm IPC delta in [predicted-0.5%, predicted+0.5%] AND dhry no-regression beyond ±2%.

## Refutation criterion

Measured cm IPC delta outside [predicted-0.5%, predicted+0.5%] OR regression on the other workload (cm or dhry) beyond ±2% IPC.

## Neutral-or-better verification

- Functional 21/21 PASS preserved
- Clockcheck 3/3 PASS, 0 diverging cycles preserved
- The OTHER workload (cm if dhry change, dhry if cm change) shows no regression beyond ±2% IPC
```

Replace the `<...>` placeholders with concrete values from Tasks 1-3.

- [ ] **Step 2: Commit the prediction note BEFORE any RTL change**

```bash
git add doc/4wide_iter_uBTB_prediction.md
git -c user.email="jeremycai@local" -c user.name="Jeremy Cai" commit -q -m \
  "doc: Cycle A prediction — uBTB sizing predicted +X% cm, +Y% dhry

Prediction committed BEFORE the RTL change per gap-closure sequence
methodology. See doc/4wide_iter_uBTB_prediction.md for the full
prediction + confirmation + refutation criteria.

Tolerance band: ±0.5% IPC absolute (predicted win <3%, per the
small-delta rule in doc/4wide_gap_closure_sequence_2026-05-01.md).

Plan: doc/4wide_iter_uBTB_plan_2026-05-01.md
Sequence: doc/4wide_gap_closure_sequence_2026-05-01.md"
```

---

## Task 5: Apply the RTL change

**Files (depends on Task 3 candidate list):**
- Modify: `src/rtl/core/include/rv64gc_pkg.sv` (the BTB / NLP / TAGE / RAS parameter lines identified in Task 3)
- Modify: any cascade files (e.g., `src/rtl/core/fetch/next_line_prefetch_buffer.sv` if its NUM_ENTRIES is internal-not-pkg-derived)

**SKIP if Task 3 said REFUTE-no-change.**

- [ ] **Step 1: Apply parameter changes**

Use the Edit tool. For each candidate component:
- Read the current pkg declaration line
- Replace the value with the bumped value

Example (illustrative — actual values from Task 1+2):
```systemverilog
// BEFORE
localparam int BTB_ENTRIES    = 2048;
// AFTER (only if Task 2 found Reference Core A has more)
localparam int BTB_ENTRIES    = 4096;
```

- [ ] **Step 2: Cascade check**

Run: `grep -rn "<param-name>" src/rtl/ | head -20` for each changed param.
Verify all consumers compute their derived sizes correctly. If any consumer hard-codes the old value (e.g., `localparam int IDX_BITS = 8;` instead of `$clog2(BTB_SETS)`), update those lines too.

- [ ] **Step 3: NLP-specific cascade (if NLP changed)**

If Task 1 found NLP `NUM_ENTRIES` is internal to `next_line_prefetch_buffer.sv` (not pkg-derived), edit that file's `localparam int NUM_ENTRIES = 4;` line directly.

---

## Task 6: Build + functional + clockcheck regression

**Files:** none modified — verification only.

**SKIP if Task 3 said REFUTE-no-change.**

- [ ] **Step 1: Build**

```bash
export LD_LIBRARY_PATH=
bash build_dsim.sh 2>&1 | tail -10
```

Expected: `DSim build OK. Image at dsim_work/tb_image.so`. If compile errors (e.g., a width mismatch from the parameter cascade), fix the offending consumer per Task 5 Step 2 and rebuild.

- [ ] **Step 2: Functional regression**

```bash
export LD_LIBRARY_PATH=
bash scripts/regress_dsim.sh 2>&1 | tail -10
```

Expected: `Total: 21   PASS: 21   FAIL/OTHER: 0`. If anything FAILs, the parameter change broke something — investigate and either fix or revert (Task 8 branch).

- [ ] **Step 3: Clockcheck**

```bash
export LD_LIBRARY_PATH=
mkdir -p traces/iter_uBTB
for hex in bench_loop_100 bench_load bench_unrolled_5; do
    bash run_dsim.sh tests/hex/${hex}.hex 5000 +PERF_PROFILE +TRACE_PIPELINE > /dev/null 2>&1
    grep "^\[PIPE schema=pipe.v1\]" dsim_run.log > traces/iter_uBTB/${hex}.pipe.v1.trace
done
for hex in bench_loop_100 bench_load bench_unrolled_5; do
    python3 ../rv64gc-perf-model/tools/rtl_clockcheck.py \
        --baseline-pipe traces/baseline_6wide/${hex}.pipe.v1.trace \
        --refactor-pipe traces/iter_uBTB/${hex}.pipe.v1.trace \
        --allowlist tools/clockcheck_4wide.allowlist.json
    echo "EXIT $? for $hex"
done
```

Expected: each clockcheck reports `PASS: checked N cycles, 0 diverging.` with `EXIT 0`. If diverging > 0 (and not in the allowlist), the parameter change introduced unintended pipeline behavior — investigate or revert.

---

## Task 7: Measure cm + dhry + cm10

**Files:** none modified — measurement only.

**SKIP if Task 3 said REFUTE-no-change.**

- [ ] **Step 1: Run cm iter1**

```bash
export LD_LIBRARY_PATH=
bash run_dsim.sh tests/hex/coremark.hex 5000000 +PERF_PROFILE > /dev/null 2>&1
grep -E "PASS at cycle|^IPC:" dsim_run.log
```

Record: cycles, instret, IPC. Expected baseline (pre-change): `PASS at cycle 199492 (tohost=1)`, `IPC=1.665112`.

- [ ] **Step 2: Run cm iter10**

```bash
bash run_dsim.sh tests/hex/coremark_iter10.hex 5000000 +PERF_PROFILE > /dev/null 2>&1
grep -E "PASS at cycle|^IPC:" dsim_run.log
```

Record. Baseline: `PASS at cycle 1860552`, `IPC=1.718528`.

- [ ] **Step 3: Run dhry**

```bash
bash run_dsim.sh tests/hex/dhrystone.hex 100000 +PERF_PROFILE > /dev/null 2>&1
grep -E "PASS at cycle|^IPC:" dsim_run.log
```

Record. Baseline: `PASS at cycle 23554`, `IPC=2.027303`.

- [ ] **Step 4: Compare measured vs predicted**

For each workload:
- `Δ_measured = (IPC_measured - IPC_baseline) / IPC_baseline`
- `In_band = (predicted_Δ - 0.005) ≤ Δ_measured ≤ (predicted_Δ + 0.005)`  ← ±0.5% IPC absolute tolerance
- `Other_no_regress = |Δ_other_workload| ≤ 0.02`  ← ±2% IPC

If both `In_band` (for the change's primary target) AND `Other_no_regress` AND functional/clockcheck still PASS: **SUCCESS**.
Else: **REVERT**.

---

## Task 8: Commit-or-revert + write results doc

**Files:**
- Create: `doc/4wide_iter_uBTB_results.md`
- (Branch a) On SUCCESS: commit RTL change with measurement in commit body
- (Branch b) On REVERT or REFUTE-no-change: `git checkout` the RTL files, no RTL commit

### 8a — Branch SUCCESS (Task 7 said in-band)

- [ ] **Step 1: Write results doc**

Create `doc/4wide_iter_uBTB_results.md`:

```markdown
# Cycle A Results — uBTB / NLP Sizing

**Date:** 2026-05-01
**Repo HEAD pre-change:** <prior HEAD>
**Verdict:** SUCCESS

## Measured

|              | Pre-change | Post-change | Δ | In-band? |
|---|---:|---:|---:|---|
| cm iter1 IPC | 1.665 | <X> | <+Δ%> | YES (predicted <P%>) |
| cm iter10 IPC | 1.719 | <X> | <+Δ%> | YES |
| dhry IPC | 2.027 | <X> | <+Δ%> | YES (no-regress check) |

Functional 21/21 PASS. Clockcheck 3/3 PASS, 0 diverging.

## Updated gap to Reference Core A (large config) floor

| Workload | New CM/MHz or DMIPS | Floor | Updated gap |
|---|---:|---:|---:|
| cm iter1 | <X> | 6.2 | <Y%> |
| cm iter10 | <X> | 6.2 | <Y%> |
| dhry | <X> | 4.00 | <Y%> |

## Next cycle

Cycle C (flush-recovery latency narrowing) will use this post-A baseline
for its predictions.
```

- [ ] **Step 2: Commit RTL change + results**

```bash
git add src/rtl/core/include/rv64gc_pkg.sv <any-cascade-files> doc/4wide_iter_uBTB_results.md
git -c user.email="jeremycai@local" -c user.name="Jeremy Cai" commit -q -m \
  "perf-iter A: uBTB sizing — measured Δ <X%> cm / <Y%> dhry (in-band)

Hypothesis: <component> undersized vs Reference Core A (large config)
Predicted: cm +<P%> (1.665 → <Pred>), dhry +<P%> (2.027 → <Pred>)
Measured:  cm +<X%> (1.665 → <Meas>), dhry +<Y%> (2.027 → <Meas>)
In-band:   YES (±0.5% IPC absolute tolerance for predicted <3% win)

Functional 21/21 PASS. Clockcheck 3/3 PASS, 0 diverging.

See doc/4wide_iter_uBTB_results.md for full measurement + updated gap.
See doc/4wide_iter_uBTB_prediction.md for the prediction committed BEFORE
the RTL change.

Cycle A complete. Next: Cycle C (flush-recovery latency narrowing) will
get its plan via writing-plans, with predictions referencing this updated
baseline."
```

### 8b — Branch REVERT (Task 7 said out-of-band or regression)

- [ ] **Step 1: Revert RTL files**

```bash
git checkout src/rtl/core/include/rv64gc_pkg.sv <any-cascade-files-from-Task-5>
```

- [ ] **Step 2: Write REFUTE results doc**

Create `doc/4wide_iter_uBTB_results.md`:

```markdown
# Cycle A Results — uBTB / NLP Sizing

**Date:** 2026-05-01
**Verdict:** REFUTED (out-of-band measurement)

## Measured

| | Pre-change | Post-change | Δ | In-band? |
|---|---:|---:|---:|---|
| cm iter1 IPC | 1.665 | <X> | <Δ%> | NO (predicted <P%>, measured outside ±0.5%) |
| ... |

## Refute reason

<Either: measured below tolerance band → bigger bump won't help cleanly,
OR: regression on other workload → side-effect not anticipated,
OR: clockcheck regression → the change perturbs pipeline beyond allowlist.>

## Implication

The "<component> undersized" hypothesis is REFUTED. RTL reverted.
Proceed to Cycle C with original baseline (cm 1.665, dhry 2.027).
```

- [ ] **Step 3: Commit REFUTE doc only**

```bash
git add doc/4wide_iter_uBTB_results.md
git -c user.email="jeremycai@local" -c user.name="Jeremy Cai" commit -q -m \
  "perf-iter A: uBTB sizing REFUTED — measured Δ <X%> outside band

Predicted: cm +<P%> (1.665 → <Pred>)
Measured:  cm +<X%> (1.665 → <Meas>) — outside ±0.5% IPC tolerance
RTL reverted. No semantic change to design.

See doc/4wide_iter_uBTB_results.md for refute reasoning.

Cycle A complete. Next: Cycle C with unchanged baseline."
```

### 8c — Branch REFUTE-no-change (Task 3 said all components ≥ Reference Core A)

- [ ] **Step 1: Write REFUTE-on-investigation results doc**

Create `doc/4wide_iter_uBTB_results.md`:

```markdown
# Cycle A Results — uBTB / NLP Sizing

**Date:** 2026-05-01
**Verdict:** REFUTED-no-change (investigation only)

## Investigation findings

| Component | rv64gc-v2 | Reference Core A (Mega) | Verdict |
|---|---|---|---|
| BTB entries | <X> | <Y> | <≥ / <> |
| BTB ways | <X> | <Y> | ... |
| TAGE tables | <X> | <Y> | ... |
| TAGE entries/table | <X> | <Y> | ... |
| RAS depth | <X> | <Y> | ... |
| NLP entries | <X> | <Y> | ... |

All rv64gc-v2 sizes meet or exceed Reference Core A reference values. No bump
applies; the "undersized vs Reference Core A" hypothesis is REFUTED on investigation.

## Implication

Cycle A produces no RTL change. Baseline (cm 1.665, dhry 2.027) is
unchanged. Proceed to Cycle C (flush-recovery latency narrowing).

This is a valid methodology outcome — refuting a hypothesis is itself
data, and saved a build+regression cycle that would have produced a
neutral measurement.
```

- [ ] **Step 2: Commit REFUTE-on-investigation doc**

```bash
git add doc/4wide_iter_uBTB_results.md
git -c user.email="jeremycai@local" -c user.name="Jeremy Cai" commit -q -m \
  "perf-iter A: uBTB sizing REFUTED-on-investigation (no RTL change)

Investigation found rv64gc-v2's BTB/TAGE/RAS/NLP storage all meet or
exceed Reference Core A reference sizes. No 'undersize' to bump. RTL untouched;
baseline unchanged.

See doc/4wide_iter_uBTB_results.md for the side-by-side comparison.

Cycle A complete (REFUTE-on-investigation). Next: Cycle C."
```

---

## Constraints (apply throughout)

1. **DSim license is single-seat.** Sequential runs only; if `License not obtained`, wait 60s and retry.
2. **`export LD_LIBRARY_PATH=`** (empty) before any bash build_dsim.sh / run_dsim.sh / regress_dsim.sh.
3. **`src/rtl/core/lsu/lsu.sv` LSU misalign-hold patch must NEVER be modified.** This task should not touch LSU at all.
4. **Pre-existing housekeeping (~30 files)** — `.gitignore`, `Makefile`, `build_dsim.bat`, deleted `*.log` — must NOT be committed. Use specific `git add <file>`, never `git add -A` or `git add .`.
5. **Prediction note MUST be committed BEFORE the RTL change commit** (Task 4 before Task 5). This is the methodology's discipline — no post-hoc rationalization of measurements.
6. **±0.5% IPC absolute tolerance, NOT relative 30%-rule** (this cycle's predicted win <3%).
7. **Working on `master` is correct** — project workflow is master-direct. No worktree.
8. **Do NOT modify CDB_WIDTH, IQ depth, NUM_ALU, or any narrowing decision.** This cycle is BPU-storage-sizing only.
9. **Do NOT re-investigate refuted hypotheses (H1 ALU bypass, H5 arb_loss, H6 PRF read-port).**
10. **The TAGE-SC-L module is functionally complex — only adjust SIZE parameters (entries, history length), never modify update logic or prediction logic.** If a size bump requires logic changes (e.g., width-cascaded counters), document and treat as scope expansion.

---

## Self-review checklist (run by writer before handing off)

- [x] Spec coverage: each phase of the 5-step cycle has at least one task; each branch (PROCEED / REFUTE-no-change / REVERT) has a documented exit
- [x] Placeholder scan: no TBD/TODO/"add error handling"/"similar to Task N"
- [x] Type consistency: parameter names match between Task 1 (catalog), Task 2 (Reference Core A lookup), Task 4 (prediction note), Task 5 (RTL change), Task 8 (commit message)
- [x] REFUTE-on-investigation branch (8c) is explicit and actionable, not buried
- [x] Tolerance is consistently ±0.5% IPC absolute (small-delta rule), NOT relative 30%
- [x] Prediction-before-change order is explicit (Task 4 before Task 5)
- [x] Constraints section enumerates all standing rules

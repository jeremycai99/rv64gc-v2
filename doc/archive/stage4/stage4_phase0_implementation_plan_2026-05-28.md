# Stage 4 Phase 0 + Slice 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce the data that ranks the Stage 4 DSE ladder (Phase 0 evidence
refresh → per-lever ceiling table + re-ranked ladder), then execute Slice 1
(the highest-ceiling low-risk lever Phase 0 selects) under the perf gate + the
Linux `BOOT OK` guard.

**Architecture:** Phase 0 is read-only analysis of the existing baseline
artifact `benchmark_results/stage4_profiled_baseline_20260528a` (no RTL change,
no new sim required for the primary deliverable). Slice 1 is a gated RTL change
verified by predicted-then-measured benchmarking, functional regression, and a
full DSim Linux boot replay. Plan of record: `doc/stage4_perf_campaign_plan_2026-05-28.md`.

**Tech Stack:** SystemVerilog RTL (`src/rtl/core/`), DSim 2026 (authoritative),
Python harness (`tools/run_benchmarks.py`, `tools/bottleneck_analysis.py`,
`tools/run_linux_boot.py`, `tools/run_rv64gc_compliance.py`).

**Environment guards (apply to every task that builds/runs):**
- `export LD_LIBRARY_PATH=` before any `build_dsim.sh` / `run_dsim.sh` /
  `run_benchmarks.py --runner dsim` invocation (memory: DSim lib quirk).
- DSim license is single-seat — runs are sequential; allow ~30–90 s for the
  lease to release between runs.
- Instrumentation-only commits MUST be cycle-identical to baseline.

---

## Phase 0 — Evidence refresh

### Task 0.1: Cross-slice ceiling & viability synthesis (no sim)

**Files:**
- Read: `benchmark_results/stage4_profiled_baseline_20260528a/bottleneck_rank.md`
- Read: `benchmark_results/stage4_profiled_baseline_20260528a/perf_profile_summary.md`
- Read: `benchmark_results/stage4_profiled_baseline_20260528a/results.json`
- Create: `doc/stage4_phase0_ceiling_table_2026-05-28.md`

- [ ] **Step 1: Extract per-row cycle-bound views.** For DS100, DS300, CM1,
  CM10, pull from `bottleneck_rank.md`: the bypass-corrected decode-supply view
  (decode-bubble %), the load-consumer viability view (Load→BRU/STD ROB-head
  block cycles), and the top-20 counter ranking. Run for confirmation:

  Run: `python3 tools/bottleneck_analysis.py benchmark_results/stage4_profiled_baseline_20260528a/results.json --bench coremark_iter1_generalization --top 25`
  Run: `python3 tools/bottleneck_analysis.py benchmark_results/stage4_profiled_baseline_20260528a/results.json --bench dhrystone_100_checkedin --top 25`
  Expected: matches the committed `bottleneck_rank.md` tables (CM1 decode bubble
  86.8%; DS100 dominant `lsu_store_fwd_backlog` 80.3%; both ROB-head block = 0).

- [ ] **Step 2: Build the ceiling table.** For each of the 5 ladder slices,
  compute an upper-bound cycles-removable per row from the cycle-bound counters
  (NOT the >100% pressure counters), and a viability verdict. Use this schema:

```
| Slice | Target row(s) | Cycle-bound counter | Upper-bound cycles | % of row | Viability (harness gate) | Verdict |
```

  Rules: a slice is **VIABLE** only if its targeted cycle-bound counter is a
  material fraction (>~3%) of the row's timed cycles AND the harness viability
  gate for that path is non-zero. Record explicitly that load-consumer ROB-head
  block = 0 makes Slices 2/3 **provisionally LOW-PAYOFF** unless the
  `lsu_store_fwd_backlog` / `fwd_wait_addr_unknown` decomposition (Task 0.2)
  reveals a distinct cycle-bound load stall.

- [ ] **Step 3: Resolve the CoreMark decode-bubble attribution question.**
  Determine whether CM1's 86.8% decode bubble is backend backpressure (ROB/IQ
  full → fetch stalls → fusion/chain-shortening helps) or genuine frontend
  under-supply (FTQ/icache rate → a frontend lever helps). Evidence to cross-
  reference from `results.json`: `xs_packet_buf_empty_*` sub-reasons
  (`wait_icresp` vs `f2_data` vs `noemit_dup`), `xs_ftq_ifu2commit_occ_*`,
  commit-zero %, and the dispatch/rename-stall counters. Write the verdict
  (backend-backpressure vs frontend-supply) with the supporting counter values.

- [ ] **Step 4: Write `doc/stage4_phase0_ceiling_table_2026-05-28.md`.** Include
  the per-row cycle-bound views, the ceiling table, the decode-bubble verdict,
  and a one-paragraph "what the data says" per slice. No RTL recommendation yet.

- [ ] **Step 5: Commit.**

```bash
git add doc/stage4_phase0_ceiling_table_2026-05-28.md
git commit -m "stage4 phase0: cross-slice ceiling & viability table from baseline"
```

### Task 0.2: Store-forward & load-ordering decomposition (targeted, sim only if needed)

**Files:**
- Read: `src/rtl/core/lsu/store_queue.sv:285-334`, `src/rtl/core/lsu/lsu.sv:1482-1605`
- Read: `src/tb/tb_top.sv` (counter definitions for `lsu_store_fwd_backlog`,
  `sq_fwd_wait_addr_unknown`, `sq_addr_unknown_p0/p1`)
- Append to: `doc/stage4_phase0_ceiling_table_2026-05-28.md`

- [ ] **Step 1: Map the DS dominant counter to a cycle-bound stall.** The DS100
  dominant counter is `xs_bottleneck_lsu_store_fwd_backlog` (14,840, 80.3%). Read
  its definition in `tb_top.sv` and determine whether it is cycle-bound (a real
  stall) or an activity indicator like the pressure counters. Cross-reference
  `xs_bottleneck_lsu_load_issue_lost_slots`, `xs_bottleneck_lsu_sq_addr_unknown_p0/p1`,
  and the load-consumer ROB-head block (= 0).

- [ ] **Step 2: Decide whether Slices 2/3 retain a real ceiling.** If
  `store_fwd_backlog` is an indicator and the load path has 0 ROB-head block,
  record Slices 2/3 as **DEPRIORITIZED** (the harness viability gate already
  says a local load repair is unlikely to pay multi-percent). If a distinct
  cycle-bound load stall exists, quantify its ceiling.

- [ ] **Step 3 (conditional): bubble-taxonomy confirmation.** Attempt to recover
  the pipe-trace generation for `tools/bubble_taxonomy.py` /
  `tools/headwait_deepdive.py` (they read `/tmp/{dhry,cm}_pipe.trace`). Search
  `src/tb/`, `build_dsim.sh`, and `../rv64gc-perf-model/` for the trace emitter.
  If found and cheap (< one CM1 run), generate the CM1 + DS100 traces and run
  both tools to confirm the commit-window split against the counter view. If the
  emitter is tied to the paused perf-model or absent, record that the counter +
  viability views in `bottleneck_rank.md` are the authoritative Phase 0 evidence
  (they are marked authoritative there) and skip the taxonomy.

  Run (if emitter found): `python3 tools/bubble_taxonomy.py` (after placing
  traces at `/tmp/dhry_pipe.trace`, `/tmp/cm_pipe.trace`)
  Expected: per-cycle category split; HEAD_WAIT_BACKLOG % re-measured on the
  current baseline (compare against the stale 74/88% from 2026-05-02).

- [ ] **Step 4: Commit the decomposition.**

```bash
git add doc/stage4_phase0_ceiling_table_2026-05-28.md
git commit -m "stage4 phase0: store-forward/load-ordering decomposition + taxonomy note"
```

### Task 0.3: Phase 0 verdict — re-ranked ladder + Slice 1 selection

**Files:**
- Read: `doc/stage4_phase0_ceiling_table_2026-05-28.md`
- Modify: `doc/stage4_perf_campaign_plan_2026-05-28.md` (§4 ladder ordering)
- Create: `doc/stage4_phase0_verdict_2026-05-28.md`

- [ ] **Step 1: Re-rank the ladder by measured ceiling.** Produce the final
  ranked ladder with each slice's ceiling estimate, viability verdict, and
  go/no-go. The provisional order (1 fusion → 2 SQ disambiguation → 3 MDP →
  4 selective-squash → 5 value-pred) is updated to match the data. Expected per
  current evidence: load slices (2/3) demote; the live contest is fusion/chain-
  shortening vs a frontend decode-supply lever for CoreMark (resolved by Task
  0.1 Step 3) and selective-squash recovery.

- [ ] **Step 2: Select Slice 1 = the highest-ceiling low-risk lever.** Name the
  exact mechanism, the exact RTL file(s) it touches, the targeted cycle-bound
  counter, and the predicted decrease (`--expect-counter-decrease NAME:DELTA`).
  This instantiates the Slice 1 tasks below.

- [ ] **Step 3: Write the verdict doc and update campaign §4.** Commit.

```bash
git add doc/stage4_phase0_verdict_2026-05-28.md doc/stage4_perf_campaign_plan_2026-05-28.md
git commit -m "stage4 phase0: verdict, re-ranked ladder, Slice 1 selection"
```

- [ ] **Step 4: CHECKPOINT — present Phase 0 data to the user.** The user
  explicitly needs the data to judge the rungs. Present the ceiling table,
  re-ranked ladder, and Slice 1 selection. Proceed to Slice 1 only after this
  checkpoint (the data may redirect which lever Slice 1 is).

---

## Slice 1 — (instantiated by Task 0.3; structure below is fixed)

> The specific mechanism/file/counter are filled in by Task 0.3 Step 2. The
> task STRUCTURE — directed test, predicted-then-measured gate, regression,
> boot guard — is fixed regardless of which lever is selected.

### Task 1.1: Baseline re-confirm + directed test for the target pattern

**Files:**
- Create: `tests/asm/probe_stage4_slice1_<pattern>.S` (directed microbench
  exercising the exact uop pattern Slice 1 targets, e.g. the crc16
  logic/W-op dependent chain)
- Read: `<Slice-1 RTL file from Task 0.3>`

- [ ] **Step 1: Re-confirm baseline.** Rebuild DSim from the clean baseline and
  re-run the strict DS100+CM1 smoke; confirm cycles match the baseline artifact
  (DS100=18,068, CM1=150,396) before any change.

```bash
export LD_LIBRARY_PATH=; ./build_dsim.sh
python3 tools/run_benchmarks.py --runner dsim --run-class dse \
  --manifest tests/benchmarks/stage1_signoff.json \
  --bench dhrystone_100_checkedin,coremark_iter1_generalization \
  --plusarg FETCH_DELIVERY_CHECK --plusarg FETCH_DELIVERY_STRICT \
  --plusarg FETCH_OWNER_CHECK --plusarg FETCH_OWNER_STRICT \
  --plusarg BRANCH_RECOVERY_CHECK --plusarg BRANCH_RECOVERY_STRICT \
  --plusarg PERF_PROFILE --plusarg PERF_COUNTERS --plusarg STAT_DUMP \
  --plusarg BOTTLENECK_PROFILE \
  --run-dir benchmark_results/stage4_slice1_prebaseline_$(printf %s 20260528) --run-id stage4_slice1_prebaseline
```
  Expected: both rows PASS; cycles == baseline.

- [ ] **Step 2: Write the directed microbench** exercising the exact target
  pattern, with the golden-PC harness enabled so divergence is caught fast.
  Build it with the toolchain quirk:
  `make LD=/usr/bin/riscv64-unknown-elf-ld CC=/usr/bin/riscv64-unknown-elf-gcc <hex>`.

- [ ] **Step 3: Capture the target counter on the directed test** (baseline RTL)
  so the predicted decrease has a concrete reference.

- [ ] **Step 4: Commit the test (cycle-identical, no RTL change yet).**

```bash
git add tests/asm/probe_stage4_slice1_<pattern>.S
git commit -m "stage4 slice1: directed probe for <pattern> (no RTL change)"
```

### Task 1.2: Implement Slice 1 RTL (minimal, predicted)

**Files:**
- Modify: `<Slice-1 RTL file(s) from Task 0.3>`

- [ ] **Step 1: Apply the minimal RTL change** targeting the selected counter
  (e.g. extend `src/rtl/core/decode/fusion_detector.sv` with the fusible pair,
  or the rename move/zero-elim coverage). Keep the change minimal and acyclic.

- [ ] **Step 2: Rebuild + functional smoke.** `export LD_LIBRARY_PATH=; ./build_dsim.sh`
  then run the directed probe + the strict DS100+CM1 smoke. Expected: golden-PC
  PASS, no functional divergence, all owner/delivery/branch-recovery invariant
  counters zero, LSU ordering/replay counters zero.

- [ ] **Step 3: Run the predicted-then-measured gate** (signoff class with the
  declared prediction; harness fails the row if the counter movement does not
  materialize):

```bash
python3 tools/run_benchmarks.py --runner dsim --goal stage1 --run-class signoff \
  --manifest tests/benchmarks/stage1_signoff.json \
  --plusarg FETCH_DELIVERY_CHECK --plusarg FETCH_DELIVERY_STRICT \
  --plusarg FETCH_OWNER_CHECK --plusarg FETCH_OWNER_STRICT \
  --plusarg BRANCH_RECOVERY_CHECK --plusarg BRANCH_RECOVERY_STRICT \
  --plusarg PERF_PROFILE --plusarg PERF_COUNTERS --plusarg STAT_DUMP --plusarg BOTTLENECK_PROFILE \
  --mechanism-class <class-from-0.3> --mechanism-name stage4_slice1_<pattern> \
  --baseline-results benchmark_results/stage4_profiled_baseline_20260528a/results.json \
  --targets-counter <counter-from-0.3> \
  --expect-counter-decrease <counter-from-0.3>:<predicted-delta-from-0.3> \
  --run-dir benchmark_results/stage4_slice1_signoff_20260528 --run-id stage4_slice1_signoff
```
  Expected (PROMOTE): targeted rows improve ≥3%; no row regresses beyond 0.01%;
  predicted counter decrease materializes; all invariants clean.
  Expected (REFUTE): if cycles do not improve ≥3% or the prediction does not
  materialize → quarantine (Task 1.4).

### Task 1.3: Promotion guards (perf signoff clean → compliance + Linux BOOT OK)

**Files:** none (verification only)

- [ ] **Step 1: Full 16-row signoff is clean** (from Task 1.2 Step 3): confirm
  all 16 rows PASS, four-row anchor (DS100/DS300/CM1/CM10) within gates.

- [ ] **Step 2: RV64GC compliance.**

```bash
python3 tools/run_rv64gc_compliance.py
```
  Expected: compliance PASS (no new failures vs baseline).

- [ ] **Step 3: Linux BOOT OK guard (the Stage 3 artifact).**

```bash
export LD_LIBRARY_PATH=
python3 tools/run_linux_boot.py --run --build --build-sim --simulator dsim \
  --build-mode linux --linux-profile full --max-cycles 1000000000 \
  --target-milestone boot_ok \
  --run-dir linux_boot_results/stage4_slice1_boot_guard_20260528a
```
  Expected: exit 0, `summary.json` status=PASS, all 8 milestones reached
  through `boot_ok`. ~277M cycles; schedule around the DSim lease.
  If FAIL → Slice 1 broke the boot; treat as REFUTE, restore baseline (Task 1.4).

- [ ] **Step 4: Promote.** Only if Steps 1–3 all pass, commit Slice 1 RTL as the
  new accepted baseline.

```bash
git add src/rtl tests/asm doc
git commit -m "stage4 slice1: <mechanism> — PROMOTED (+X% <row>, boot OK, compliance OK)"
```

### Task 1.4: Refute path (if any gate fails)

- [ ] **Step 1: Restore baseline RTL.** `git checkout -- src/rtl` (and rebuild).
- [ ] **Step 2: Document the refutation** in `doc/stage4_phase0_verdict_2026-05-28.md`
  as DSE-only evidence (what was tried, the measured counters, why it failed).
- [ ] **Step 3: Advance to the next ladder rung** per campaign §6 (re-run Phase 0
  attribution before the next structural rung).

---

## Self-review notes
- Spec coverage: Phase 0 (campaign §3) → Tasks 0.1–0.3; ladder selection (§4) →
  Task 0.3; per-slice gate (§5) incl. replay-gate → Task 1.2/1.3; boot guard
  (§7) → Task 1.3 Step 3; refute/quarantine (§6) → Task 1.4.
- Data dependency: Slice 1's exact mechanism/file/counter are intentionally
  selected by Task 0.3 from measured ceilings — this is a real data dependency
  (the user requires data-first), not a placeholder. The task STRUCTURE is fully
  concrete.
- Guards: perf gate (predicted-then-measured + 3%/0.01%) and Linux BOOT OK guard
  are explicit, required steps before any RTL promotion.

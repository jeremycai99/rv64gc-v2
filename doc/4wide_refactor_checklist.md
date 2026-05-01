# 4-wide RTL Refactor Checklist — rv64gc-v2

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this checklist task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Narrow rv64gc-v2 from 6-wide to 4-wide in place; sign off via dsim/xsim measurement against external 4-wide references.

**Architecture:** Staged refactor in 5 module groups (Rename+ROB → Dispatch+IQ → LSU → Caches → Frontend+TB). After each group: build + clockcheck microbench + functional regression must PASS before the next group starts. **No perf-model gate** — `../rv64gc-perf-model/` is paused on a structural toolchain dead-end (`../rv64gc-perf-model/doc/phase_2_5_signoff.md`); refactor proceeds with textbook 4-wide param values.

**Tech Stack:** SystemVerilog + DSim 2026 (build_dsim.sh) + clockcheck (Python tool in `../rv64gc-perf-model/tools/rtl_clockcheck.py`). Branch `4wide-pivot` cut from `master` at `4f28619` (the 6-wide IPC bundle: uop cache gen-2 + LB exit predictor + BPU update split + ROB commit bypass + MUL/DIV latency cut).

**Authoritative design references** (do not re-litigate here):
- `doc/4wide_pivot_plan_2026-04-25.md` — full RTL refactor scope, param table, module-level rewrites, files NOT to touch, risk/mitigation. **This checklist EXECUTES that plan; it does not redesign it.**
- `doc/baseline_6wide_obsolete_2026-04-30.md` — archive snapshot of the 6-wide we are retiring; **do NOT use its numbers for forward comparison** (cross-width is apple-to-orange).
- `AGENTS.md` — repo ground rules.

---

## Sign-off Targets (the only valid bar)

| Tier | CM/MHz | DMIPS/MHz | Source |
|---|---:|---:|---|
| Floor — must match | ≥ 6.2 | ≥ 4.00 | MegaBoom (4-wide) |
| Stretch — should beat | ≥ 8.24 | ≥ 4.72 | ARM Cortex-A72 (3-wide OoO) |

**These are external benchmarks, not internal predictions.** Sign-off is dsim/xsim measurement on the refactored 4-wide RTL. The retired 6-wide's numbers are not part of any sign-off comparison.

---

## What NOT to Do

1. **Do NOT modify the LSU port-1 misalign hold patch** in `core/lsu/lsu.sv`. It is the only sign-off-class IPC win we have on iter=10. Preserve verbatim.
2. **Do NOT touch icache/dcache RAM modules**: `core/cache/icache*`, `core/cache/dcache_*ram` are independent of pipe width. Stage 4 only changes dcache banking, not the RAMs themselves.
3. **Do NOT modify ALU implementations** — independent of width.
4. **Do NOT modify BPU (TAGE, BTB, RAS)** — independent of dispatch width.
5. **Do NOT reference any data, calibration delta, or per-mechanism decision from `../rv64gc-perf-model/`.** That repo's calibration data is paused on a structural dead-end and is record-only. The textbook 4-wide param table in this checklist comes from `doc/4wide_pivot_plan_2026-04-25.md` directly.
6. **Do NOT use the 6-wide baseline (`doc/baseline_6wide_obsolete_2026-04-30.md`) as a forward comparison target.** Cross-width cycle deltas are not meaningful; sign-off is against MegaBoom + A72 only.
7. **Do NOT touch the ~30 pre-existing uncommitted housekeeping files** (.gitignore, Makefile, build_dsim.bat, deleted *.log files). That cleanup is separate work.
8. **Do NOT skip a stage's gate.** The whole methodology is "build + clockcheck + regress before continuing." Compounding edits across un-validated stages is exactly the failure mode the staging is designed to prevent.
9. **Do NOT add new optimisations during the refactor.** Pure narrowing pass first; opts can be considered later, after the 4-wide baseline measures against MegaBoom. **Exception:** an architectural change is allowed if it is a *fix required to keep regression alive* — e.g., Stage 2's `load_wb` sideband was necessary because CDB shrink (6→4) removed the slots loads had been using for definitive wakeup, causing cache-miss ROB deadlock. Document any such exception in the commit message + here in the plan.

---

## Pre-flight

### Task 0.1: Verify clean starting point on master

**Files:** none (git state check only)

- [ ] **Step 1: Confirm RTL HEAD**

  ```bash
  cd /home/jeremycai/agent-workspace/rv64gc-v2
  git log --oneline -3
  ```

  Expected (top three):
  ```
  4f28619 feat(core): 6-wide IPC bundle — uop cache gen-2 + LB exit predictor + ...
  48f3e9f doc: archive 6-wide baseline measurement on fb2d9cc — OBSOLETE design
  fb2d9cc doc: rename CLAUDE.md to AGENTS.md (...)
  ```
  If different, STOP and re-baseline.

- [ ] **Step 2: Confirm 6-wide baseline doc is committed**

  ```bash
  git log --oneline | head -3 | grep "baseline_6wide_obsolete"
  ```

  Expected: commit `48f3e9f doc: archive 6-wide baseline measurement on fb2d9cc — OBSOLETE design` is present.

- [ ] **Step 3: Note pre-existing uncommitted housekeeping (do NOT touch)**

  ```bash
  git status --short
  ```

  Expected: housekeeping uncommitted files only — `.gitignore`, `Makefile`, `build_dsim.bat`, `run_dsim.bat`, deleted `build_*.log` files, untracked `.claude/`, untracked `doc/*.md` plan files, untracked `scripts/` and test benchmark hex/elf. **Crucially: NO modified files under `src/rtl/`** — those were all committed in `4f28619` before refactor start. Verify with `git status --short | grep "^ M src/rtl/"` returning nothing.

### Task 0.2: Branch

**Files:** none (git operation)

- [ ] **Step 1: Create branch**

  ```bash
  git checkout -b 4wide-pivot
  git status
  ```

  Expected: `On branch 4wide-pivot`, working tree state unchanged.

- [ ] **Step 2: Confirm master is unaffected**

  ```bash
  git log master --oneline -3
  ```

  Expected: master HEAD is still `48f3e9f` (the baseline doc commit) on top of `fb2d9cc`.

### Task 0.3: Capture baseline pipe.v1 traces (for clockcheck reference)

**Files:** `traces/baseline_6wide/<workload>.pipe.v1.trace` (new dir, gitignored)

- [ ] **Step 1: Pick the clockcheck microbench set**

  Use the smallest `bench_*.hex` files (these are deterministic, short, and exercise specific structures). Recommended set:

  - `tests/hex/bench_loop_100.hex` (tight inner loop — exercises LB, IQ, dep chain)
  - `tests/hex/bench_load.hex` (LSU stress)
  - `tests/hex/bench_unrolled_5.hex` (rename + dispatch parallelism)

  These are the deterministic kernels for cycle-by-cycle pipe.v1 comparison.

- [ ] **Step 2: Capture each baseline trace from current master state**

  ```bash
  mkdir -p traces/baseline_6wide
  export LD_LIBRARY_PATH=
  for hex in bench_loop_100 bench_load bench_unrolled_5; do
      bash run_dsim.sh tests/hex/${hex}.hex 5000 +PERF_PROFILE +TRACE_PIPELINE
      grep "^\[PIPE schema=pipe.v1\]" dsim_run.log > traces/baseline_6wide/${hex}.pipe.v1.trace
      wc -l traces/baseline_6wide/${hex}.pipe.v1.trace
  done
  ```

  Expected: each trace file is non-empty. These are the "old" pipe.v1 references for clockcheck through every stage.

- [ ] **Step 3: Add baseline trace dir to .gitignore (if not already)**

  Verify `traces/baseline_6wide/*.trace` is excluded by current `.gitignore`. Do NOT modify the in-flight `.gitignore` housekeeping; if needed, add the rule and let the housekeeping commit subsume it.

### Task 0.4: Build the clockcheck allowlist

**Files:** Create `tools/clockcheck_4wide.allowlist.json`

- [ ] **Step 1: Create the allowlist describing intentional refactor effects**

  ```bash
  cat > tools/clockcheck_4wide.allowlist.json <<'EOF'
  {
    "expected": {
      "pipe_width":     {"old": 6,   "new": 4},
      "fetch_bytes":    {"old": 24,  "new": 16},
      "rob_depth":      {"old": 192, "new": 128},
      "rob_idx_bits":   {"old": 8,   "new": 7},
      "int_prf_depth":  {"old": 256, "new": 160},
      "fp_prf_depth":   {"old": 128, "new": 96},
      "lq_depth":       {"old": 64,  "new": 32},
      "sq_depth":       {"old": 64,  "new": 32},
      "lq_sq_idx_bits": {"old": 6,   "new": 5},
      "iq_int_depth":   {"old": 32,  "new": 24},
      "num_alu":        {"old": 4,   "new": 3},
      "cdb_width":      {"old": 6,   "new": 4},
      "num_bypass_srcs":{"old": 6,   "new": 4},
      "l1d_banks":      {"old": 4,   "new": 2}
    },
    "ignore_fields": ["rob_tail", "iq2_count"],
    "max_cycle_delta_by_seq": 50,
    "note": "iq2_count ignored if NUM_INT_IQS drops to 2; remove from ignore list if Stage 2 keeps 3 IQs."
  }
  EOF
  ```

- [ ] **Step 2: Commit pre-flight artifacts**

  ```bash
  git add traces/.gitignore tools/clockcheck_4wide.allowlist.json
  git -c user.email="jeremycai@local" -c user.name="Jeremy Cai" commit -q -m \
    "refactor(4wide): pre-flight — clockcheck allowlist + baseline trace ignore"
  ```

### Task 0.5: Confirm full regression baseline on master snapshot

**Files:** none (regression run)

- [ ] **Step 1: Run full regression on the just-branched tree (still 6-wide-equivalent)**

  ```bash
  bash build_dsim.sh
  bash scripts/regress_dsim.sh 2>&1 | tee /tmp/regress_baseline.log
  ```

  Expected: full pass (all rv64ui_* + bench tests reach STOP). This proves the branch starts in a clean regress-PASS state. If anything fails here, STOP and fix on master before refactoring.

---

## Stage 1: Rename + ROB

**Goal:** PIPE_WIDTH=4 + ROB depth/index cascade. The single biggest "many sites change at once" stage; all subsequent stages depend on getting this clean.

### Task 1.1: Param-table edit in rv64gc_pkg.sv

**Files:**
- Modify: `include/rv64gc_pkg.sv` (param defines)

- [ ] **Step 1: Edit the param table**

  Change in `include/rv64gc_pkg.sv`:

  ```systemverilog
  parameter int PIPE_WIDTH       = 4;   // was 6
  parameter int FETCH_BYTES      = 16;  // was 24
  parameter int ROB_DEPTH        = 128; // was 192
  parameter int ROB_IDX_BITS     = 7;   // was 8
  parameter int INT_PRF_DEPTH    = 160; // was 256
  parameter int FP_PRF_DEPTH     = 96;  // was 128
  parameter int INT_FREE_LIST_DEPTH = 128; // sized to PRF - 32 arch
  ```

  Leave the other params (LQ/SQ/IQ/ALU/CDB/BYPASS/L1D_BANKS) at their 6-wide values for now — they get changed in their own stages.

- [ ] **Step 2: Build to surface compile errors**

  ```bash
  bash build_dsim.sh 2>&1 | tail -50
  ```

  Expected: many errors from downstream modules (uarch_pkg typedefs, rename, ROB, free_list, etc.) — these are the per-file edits in tasks 1.2-1.6. Capture the error list as the to-do.

### Task 1.2: uarch_pkg typedef cascade

**Files:**
- Modify: `include/uarch_pkg.sv`

- [ ] **Step 1: Update typedef array sizes**

  Anywhere that uses `[PIPE_WIDTH-1:0]` or hardcoded `[5:0]` for pipe-width-indexed arrays — should already be parametric, but check for any `decoded_insn_t [5:0]`-style hardcodes and convert to `[PIPE_WIDTH-1:0]`.

- [ ] **Step 2: Build**

  ```bash
  bash build_dsim.sh 2>&1 | tail -50
  ```

  Expected: typedef errors gone; the remaining errors are in rename/ROB modules.

### Task 1.3: Rename modules

**Files:**
- Modify: `core/rename/rat.sv`
- Modify: `core/rename/rename.sv`
- Modify: `core/rename/free_list.sv`
- Modify: `core/rename/checkpoint.sv`

For each file:

- [ ] **Step 1: Replace any hardcoded 6, 5:0, or `IF6_*` reference with the corresponding parameter**

  Common patterns:
  - `for (int i = 0; i < 6; i++)` → `for (int i = 0; i < PIPE_WIDTH; i++)`
  - `[5:0]` arrays → `[PIPE_WIDTH-1:0]`
  - Any free-list / RAT entry sized to old PRF_DEPTH → use new INT_PRF_DEPTH

- [ ] **Step 2: ~~Re-write `int_prf` port list (12R6W → 8R4W)~~ — DEFERRED to Stage 2**

  Originally scoped to Stage 1, but the rewrite is tightly coupled with `CDB_WIDTH` (which is still 6 in Stage 1; CDB_WIDTH 6→4 is a Stage 2 change).  Reducing `int_prf` write ports to 4 while CDB still emits 6 results would be a partial structural change — better to land int_prf reduction atomically with CDB_WIDTH reduction in Stage 2.  See Task 2.4.

  The actual `int_prf` lives at `src/rtl/core/regfile/int_prf.sv` (not under `core/rename/` as the plan originally said).  At Stage 1 commit `a64efbc`, ports remain 12R6W; `INT_PRF_DEPTH` is reduced to 160 (parameter-driven).

- [ ] **Step 3: Build**

  ```bash
  bash build_dsim.sh 2>&1 | tail -50
  ```

  Expected: rename modules compile; remaining errors are in ROB / commit / core_top.

### Task 1.4: ROB + commit

**Files:**
- Modify: `core/backend/rob.sv`
- Modify: `core/backend/commit.sv`

- [ ] **Step 1: ROB depth + idx-bits cascade**

  - All `[7:0]` rob_idx → `[ROB_IDX_BITS-1:0]`
  - All `192` literal references → `ROB_DEPTH`
  - Wraparound math should already be `% ROB_DEPTH` parametric

- [ ] **Step 2: Commit width**

  - `for (int i = 0; i < 6; i++)` → `PIPE_WIDTH`
  - Commit slot arrays sized parametrically

- [ ] **Step 3: Build**

  ```bash
  bash build_dsim.sh 2>&1 | tail -50
  ```

  Expected: ROB/commit clean; remaining errors are in core_top instantiations.

### Task 1.5: core_top instantiation widths (rename + ROB only)

**Files:**
- Modify: `core/rv64gc_core_top.sv` (rename + ROB instantiation widths and the rename mux)

- [ ] **Step 1: Update rename instantiation port widths**

  Reduce 6-slot to 4-slot connections at rename-stage instantiations.

- [ ] **Step 2: Re-write rename mux 6 slots → 4**

  The 6→4 rename mux. Effort: L.

- [ ] **Step 3: Update ROB instantiation port widths**

- [ ] **Step 4: Build — expect to compile clean now**

  ```bash
  bash build_dsim.sh 2>&1 | tail -20
  ```

  Expected: build SUCCESS. Stage 1 RTL edits are done; gate-checks next.

### Task 1.6: Stage 1 gate — clockcheck

**Files:** none (verification)

- [ ] **Step 1: Capture refactor pipe.v1 traces from the Stage-1 RTL**

  ```bash
  mkdir -p traces/stage1
  export LD_LIBRARY_PATH=
  for hex in bench_loop_100 bench_load bench_unrolled_5; do
      bash run_dsim.sh tests/hex/${hex}.hex 5000 +PERF_PROFILE +TRACE_PIPELINE
      grep "^\[PIPE schema=pipe.v1\]" dsim_run.log > traces/stage1/${hex}.pipe.v1.trace
  done
  ```

- [ ] **Step 2: Run clockcheck against baseline (each microbench)**

  ```bash
  for hex in bench_loop_100 bench_load bench_unrolled_5; do
      python ../rv64gc-perf-model/tools/rtl_clockcheck.py \
          --baseline-pipe traces/baseline_6wide/${hex}.pipe.v1.trace \
          --refactor-pipe traces/stage1/${hex}.pipe.v1.trace \
          --allowlist tools/clockcheck_4wide.allowlist.json
      echo "EXIT $? for $hex"
  done
  ```

  Expected: each clockcheck exits 0 (PASS), or with only allowed deltas. Any UNEXPLAINED divergence → STOP, debug, fix RTL or extend allowlist with explicit justification before continuing.

### Task 1.7: Stage 1 gate — functional regression

- [ ] **Step 1: Run functional-only regression**

  ```bash
  bash scripts/regress_dsim.sh --func 2>&1 | tee /tmp/regress_stage1_func.log
  ```

  Expected: all `rv64ui_*` tests PASS. Stage 1 must not break ISA functional behaviour.

- [ ] **Step 2: Run benchmark regression (informational, not gating yet)**

  ```bash
  bash scripts/regress_dsim.sh --bench 2>&1 | tee /tmp/regress_stage1_bench.log
  grep -E "PASS|TIMEOUT|IPC:" /tmp/regress_stage1_bench.log
  ```

  Expected: dhry / cm / cm10 / bench_loop_100 reach STOP. Cycles will differ from 6-wide (that's the point); the gate is "STOP cleanly", not "match 6-wide".

  IF any benchmark TIMEOUTs or hits IterLimit: STOP. Stage 1 likely has a deadlock or a missed wraparound somewhere. Debug before proceeding.

### Task 1.8: Stage 1 commit

- [ ] **Step 1: Commit**

  ```bash
  git add include/rv64gc_pkg.sv include/uarch_pkg.sv \
          core/rename/*.sv core/backend/rob.sv core/backend/commit.sv \
          core/rv64gc_core_top.sv \
          traces/.gitignore tools/clockcheck_4wide.allowlist.json
  git -c user.email="jeremycai@local" -c user.name="Jeremy Cai" commit -q -m \
    "refactor(stage1): rename + ROB cascade — PIPE_WIDTH=4, ROB_DEPTH=128, INT_PRF=160

  - rv64gc_pkg.sv: PIPE_WIDTH 6->4, FETCH_BYTES 24->16, ROB_DEPTH 192->128,
    ROB_IDX_BITS 8->7, INT_PRF_DEPTH 256->160, FP_PRF_DEPTH 128->96
  - rename/*: cascade param + rewrite int_prf port list 12R6W -> 8R4W
  - rob/commit: depth/idx-bits cascade, commit slot arrays parametric
  - core_top: rename mux 6->4, rename + ROB instantiation widths
  - clockcheck: all 3 microbenches PASS against baseline_6wide with allowlist
  - regression: functional all PASS; bench dhry/cm/cm10/bench_loop_100 STOP cleanly"
  ```

---

## Stage 2: Dispatch + IQ

**Goal:** Re-balance the dispatch arbitration and per-IQ load for the new 4-wide. CDB and bypass network shrink to match.

### Task 2.1: Param-table edits (Stage 2 portion)

**Files:**
- Modify: `include/rv64gc_pkg.sv` (IQ + ALU + CDB + bypass)

- [ ] **Step 1: Update params**

  ```systemverilog
  parameter int IQ_INT_DEPTH    = 24;  // was 32
  parameter int NUM_INT_IQS     = 3;   // keep 3 for now; revisit with 2 if Phase-3 sweep merits
  parameter int NUM_ALU         = 3;   // was 4
  parameter int CDB_WIDTH       = 4;   // was 6
  parameter int NUM_BYPASS_SRCS = 4;   // was 6
  ```

  Note on NUM_INT_IQS: the planning doc allows "2 (or 3 — Phase 4 sweep)". Keep 3 for the staged refactor; merging IQs is a later optimisation experiment. If we hit an IQ-rewrite issue here, revisit.

- [ ] **Step 2: Build, expect downstream errors in dispatch / IQ / bypass**

  ```bash
  bash build_dsim.sh 2>&1 | tail -50
  ```

### Task 2.2: Decode

**Files:**
- Modify: `core/decode/decode.sv`
- Modify: `core/decode/fusion_detector.sv`

- [ ] **Step 1: Cascade PIPE_WIDTH through decode**

  Decode is mostly param-driven; replace 6 slot iterators / arrays with PIPE_WIDTH.

- [ ] **Step 2: Build**

### Task 2.3: Dispatch queue + arbitration rewrite

**Files:**
- Modify: `core/dispatch/dispatch_queue.sv`

- [ ] **Step 1: Re-write dispatch arbitration 6-wide → 4-wide**

  Round-robin across PIPE_WIDTH dispatch slots. Effort: L.

- [ ] **Step 2: Build**

### Task 2.4: IQ depth + bypass network rewrite + int_prf parameterization + load_wb sideband

**Files (locations confirmed during Stage 2 execution):**
- Modify: `src/rtl/core/issue/issue_queue.sv` — IQ depth cascade + new `load_wb_wk_*` definitive wakeup ports (load_wb sideband fix).
- Modify: `src/rtl/core/bypass_network.sv` — fully parametric on NUM_BYPASS_SRCS (6→4 srcs).
- Modify: `src/rtl/core/regfile/int_prf.sv` — `PRF_WRITE_PORTS=6` made explicit; **port count NOT reduced** (12R6W is the correct target with load_wb sideband — see Task 1.3 Step 2 resolution).
- Modify: `src/rtl/core/backend/rob.sv` — load_wb sideband ports replace the old LOAD_CDB_FIRST pattern.
- Modify: `src/rtl/core/decode/fusion_detector.sv` — 5 fusion pairs → 3 (PIPE_WIDTH-1 max pairs across 4 dispatch slots).
- Modify: `src/rtl/core/rv64gc_core_top.sv` — full stitching with load_wb sideband + 4-source bypass + load_wb_wk wired to all IQs.
- Modify: `src/tb/tb_top.sv` — replaced out-of-bounds `cdb_valid[4:5]` with `load_wb_valid[0:1]` (Stage 5 file touched out-of-scope; necessary to avoid TB compile error from CDB shrink).

- [ ] **Step 1: IQ depth cascade**

  All three IQ instances drop from depth 32 to depth 24. Re-check IQ select-port count (should still be 2 per IQ for 6 issues/cycle theoretical → 6 issues/cycle with 3 IQs × 2 ports; if NUM_INT_IQS drops to 2 this is 4 issues/cycle).

- [ ] **Step 2: Bypass network 6 srcs → 4 (24 muxes vs 48)**

  Effort: M. The mux array is the visible cost of dropping CDB_WIDTH and NUM_BYPASS_SRCS.

- [x] **Step 2b: ~~int_prf port-list reduction 12R6W → 8R4W~~ — RESOLVED: 12R6W is the correct steady-state target.**

  Outcome from Stage 2 (commit `d566919`): the planning doc's 8R4W target was based on the assumption that loads write through CDB. With the load_wb sideband architecture (added in Stage 2 to fix cache-miss deadlock), loads write through 2 dedicated ports separate from CDB. So:

  - **Read-port demand:** NUM_ALU=3 × 2 srcs + NUM_BRU=2 × 2 srcs = 10 reads minimum, plus LSU AGU srcs. **12R kept** — meets demand with margin.
  - **Write-port demand:** CDB_WIDTH=4 (ALU/BRU) + load_wb sideband=2 = 6 writes. **6W kept** — exact fit.

  No port reduction in Stage 2; the deferral note in Task 1.3 Step 2 is now superseded by this architectural reality. `int_prf.sv` was given a new `PRF_WRITE_PORTS=6` parameter to make the count explicit; depth was already reduced to 160 in Stage 1.

- [ ] **Step 3: Build**

### Task 2.5: core_top stitching for Stage 2

**Files:**
- Modify: `core/rv64gc_core_top.sv` (dispatch + IQ + bypass instantiation)

- [ ] **Step 1: Update dispatch / IQ / bypass instantiation widths**

- [ ] **Step 2: Build clean**

  ```bash
  bash build_dsim.sh 2>&1 | tail -20
  ```

  Expected: SUCCESS.

### Task 2.6: Stage 2 gate

- [ ] **Step 1: Capture Stage 2 pipe.v1 traces, run clockcheck**

  ```bash
  mkdir -p traces/stage2
  export LD_LIBRARY_PATH=
  for hex in bench_loop_100 bench_load bench_unrolled_5; do
      bash run_dsim.sh tests/hex/${hex}.hex 5000 +PERF_PROFILE +TRACE_PIPELINE
      grep "^\[PIPE schema=pipe.v1\]" dsim_run.log > traces/stage2/${hex}.pipe.v1.trace
      python ../rv64gc-perf-model/tools/rtl_clockcheck.py \
          --baseline-pipe traces/baseline_6wide/${hex}.pipe.v1.trace \
          --refactor-pipe traces/stage2/${hex}.pipe.v1.trace \
          --allowlist tools/clockcheck_4wide.allowlist.json
  done
  ```

  Expected: all PASS or only allowlist deltas.

- [ ] **Step 2: Functional regression**

  ```bash
  bash scripts/regress_dsim.sh --func 2>&1 | tee /tmp/regress_stage2_func.log
  ```

  Expected: all PASS.

- [ ] **Step 3: Bench regression (STOP-cleanly check)**

  ```bash
  bash scripts/regress_dsim.sh --bench 2>&1 | tee /tmp/regress_stage2_bench.log
  grep -E "PASS|TIMEOUT|IPC:" /tmp/regress_stage2_bench.log
  ```

  Expected: dhry / cm / cm10 / bench_loop_100 reach STOP.

### Task 2.7: Stage 2 commit

- [ ] **Step 1: Commit**

  ```bash
  git add include/rv64gc_pkg.sv core/decode/*.sv core/dispatch/*.sv \
          core/issue/*.sv core/rv64gc_core_top.sv
  git -c user.email="jeremycai@local" -c user.name="Jeremy Cai" commit -q -m \
    "refactor(stage2): dispatch + IQ + CDB + bypass to 4-wide

  - rv64gc_pkg.sv: IQ_INT_DEPTH 32->24, NUM_ALU 4->3, CDB_WIDTH 6->4,
    NUM_BYPASS_SRCS 6->4 (NUM_INT_IQS kept at 3)
  - decode/*: PIPE_WIDTH cascade
  - dispatch_queue: round-robin 6->4
  - issue_queue x 3: depth 32->24 (IQ count unchanged at 3)
  - bypass_network: 6->4 srcs (24 muxes vs 48)
  - core_top: dispatch + IQ + bypass instantiation widths
  - clockcheck + functional + bench regression all PASS"
  ```

---

## Stage 3: LSU

**Goal:** LQ/SQ depth from 64 to 32, idx-bits 6→5.

**CRITICAL:** Do NOT touch the LSU port-1 misalign hold patch in `core/lsu/lsu.sv`. It is a sign-off-class iter=10 win and must be preserved verbatim through this stage.

### Task 3.1: Param-table edits (Stage 3 portion)

**Files:**
- Modify: `include/rv64gc_pkg.sv` (LQ/SQ)

- [ ] **Step 1: Update params**

  ```systemverilog
  parameter int LQ_DEPTH        = 32;  // was 64
  parameter int SQ_DEPTH        = 32;  // was 64
  parameter int LQ_IDX_BITS     = 5;   // was 6
  parameter int SQ_IDX_BITS     = 5;   // was 6
  ```

- [ ] **Step 2: Build, expect downstream errors in lsu/load_queue/store_queue**

### Task 3.2: Load queue + store queue

**Files:**
- Modify: `core/lsu/load_queue.sv`
- Modify: `core/lsu/store_queue.sv`

For each:

- [ ] **Step 1: Cascade depth + idx-bits**

  Replace `64` literals with `LQ_DEPTH`/`SQ_DEPTH`; replace `[5:0]` with `[LQ_IDX_BITS-1:0]`/`[SQ_IDX_BITS-1:0]`. Wraparound math should already use the param.

- [ ] **Step 2: Build**

### Task 3.3: lsu.sv (preserve iter=10 patch)

**Files:**
- Modify: `core/lsu/lsu.sv` (only width-cascade edits; misalign-hold patch untouched)

- [ ] **Step 1: Identify the iter=10 misalign-hold block**

  ```bash
  grep -n "misalign\|p1_hold\|iter=10" core/lsu/lsu.sv
  ```

  Note the line range. Do NOT modify those lines.

- [ ] **Step 2: Cascade PIPE_WIDTH / LQ_IDX_BITS through the rest of lsu.sv**

  Wherever lsu.sv references the LQ/SQ port count, dispatch slot count, etc. — convert to params. Skip the misalign-hold block.

- [ ] **Step 3: Build**

### Task 3.4: core_top LSU instantiation

**Files:**
- Modify: `core/rv64gc_core_top.sv` (LSU instantiation widths)

- [ ] **Step 1: Update LSU instantiation port widths**

- [ ] **Step 2: Build clean**

### Task 3.5: Stage 3 gate

- [ ] **Step 1: Clockcheck (all 3 microbenches)**

  ```bash
  mkdir -p traces/stage3
  export LD_LIBRARY_PATH=
  for hex in bench_loop_100 bench_load bench_unrolled_5; do
      bash run_dsim.sh tests/hex/${hex}.hex 5000 +PERF_PROFILE +TRACE_PIPELINE
      grep "^\[PIPE schema=pipe.v1\]" dsim_run.log > traces/stage3/${hex}.pipe.v1.trace
      python ../rv64gc-perf-model/tools/rtl_clockcheck.py \
          --baseline-pipe traces/baseline_6wide/${hex}.pipe.v1.trace \
          --refactor-pipe traces/stage3/${hex}.pipe.v1.trace \
          --allowlist tools/clockcheck_4wide.allowlist.json
      echo "EXIT $? for $hex"
  done
  ```

  Expected: each clockcheck exits 0 (PASS), or with only allowed deltas. Any UNEXPLAINED divergence → STOP, debug.

- [ ] **Step 2: Functional regression**

  ```bash
  bash scripts/regress_dsim.sh --func 2>&1 | tee /tmp/regress_stage3_func.log
  ```

  Expected: all `rv64ui_*` tests PASS.

- [ ] **Step 3: Bench regression — pay special attention to cm10 (LSU-heavy, iter=10 patch sensitive)**

  ```bash
  bash scripts/regress_dsim.sh --bench 2>&1 | tee /tmp/regress_stage3_bench.log
  grep -E "PASS|TIMEOUT|IPC:" /tmp/regress_stage3_bench.log
  ```

  cm10 must still reach STOP. The iter=10 patch should still be in effect; if cm10 IPC dropped sharply or TIMEOUTs, the patch was disturbed — STOP and verify (re-grep `core/lsu/lsu.sv` for the misalign-hold block; the lines should be unchanged from master).

### Task 3.6: Stage 3 commit

- [ ] **Step 1: Commit**

  ```bash
  git add include/rv64gc_pkg.sv core/lsu/*.sv core/rv64gc_core_top.sv
  git -c user.email="jeremycai@local" -c user.name="Jeremy Cai" commit -q -m \
    "refactor(stage3): LSU LQ/SQ 64->32 (LSU misalign-hold patch preserved)

  - rv64gc_pkg.sv: LQ_DEPTH 64->32, SQ_DEPTH 64->32, idx_bits 6->5
  - load_queue / store_queue: depth + idx-bits cascade
  - lsu.sv: width cascade ONLY; iter=10 misalign-hold patch untouched
  - core_top: LSU instantiation widths
  - clockcheck PASS; cm10 reaches STOP cleanly with patch intact"
  ```

---

## Stage 4: Caches

**Goal:** L1D banks 4→2 (matches new dispatch width). Cache RAMs themselves are NOT touched.

### Task 4.1: Param-table edit (Stage 4 portion)

**Files:**
- Modify: `include/rv64gc_pkg.sv` (L1D_BANKS)

- [ ] **Step 1: Update param**

  ```systemverilog
  parameter int L1D_BANKS = 2;  // was 4
  ```

- [ ] **Step 2: Build, expect errors in dcache top-level (NOT in dcache_*ram)**

### Task 4.2: dcache banking arbitration rewrite

**Files:**
- Modify: the dcache top-level — locate via `grep -rn "L1D_BANKS\|dcache_top\|dcache\.sv" core/ --include='*.sv' | head`. Do NOT touch any `dcache_*ram*.sv` (RAM modules are independent of banking arbitration).

- [ ] **Step 1: Re-write bank arbitration 4-bank → 2-bank**

  Effort: M. The bank crossbar shrinks; bank-select bits drop by one.

- [ ] **Step 2: Build**

### Task 4.3: core_top dcache instantiation

**Files:**
- Modify: `core/rv64gc_core_top.sv` (dcache instantiation widths)

- [ ] **Step 1: Update dcache instantiation port widths**

- [ ] **Step 2: Build clean**

### Task 4.4: Stage 4 gate

- [ ] **Step 1: Clockcheck (all 3 microbenches)**

  ```bash
  mkdir -p traces/stage4
  export LD_LIBRARY_PATH=
  for hex in bench_loop_100 bench_load bench_unrolled_5; do
      bash run_dsim.sh tests/hex/${hex}.hex 5000 +PERF_PROFILE +TRACE_PIPELINE
      grep "^\[PIPE schema=pipe.v1\]" dsim_run.log > traces/stage4/${hex}.pipe.v1.trace
      python ../rv64gc-perf-model/tools/rtl_clockcheck.py \
          --baseline-pipe traces/baseline_6wide/${hex}.pipe.v1.trace \
          --refactor-pipe traces/stage4/${hex}.pipe.v1.trace \
          --allowlist tools/clockcheck_4wide.allowlist.json
      echo "EXIT $? for $hex"
  done
  ```

  Expected: each clockcheck exits 0 (PASS), or with only allowed deltas.

- [ ] **Step 2: Functional regression**

  ```bash
  bash scripts/regress_dsim.sh --func 2>&1 | tee /tmp/regress_stage4_func.log
  ```

  Expected: all `rv64ui_*` tests PASS.

- [ ] **Step 3: Bench regression**

  ```bash
  bash scripts/regress_dsim.sh --bench 2>&1 | tee /tmp/regress_stage4_bench.log
  grep -E "PASS|TIMEOUT|IPC:" /tmp/regress_stage4_bench.log
  ```

  Expected: dhry / cm / cm10 / bench_loop_100 reach STOP.

- [ ] **Step 4: Mid-refactor CM/MHz trajectory check (per the Halt rule)**

  Compute current cm-iter1 CM/MHz from the bench log (`1e6 / cycles`).
  - If CM/MHz ≥ 4.34 (i.e., within 30% of MegaBoom's 6.2 floor): continue to Stage 5.
  - If CM/MHz < 4.34: **STOP** — the refactor is unlikely to clear sign-off. Convene a review per the Halt-and-Re-evaluate rule.

### Task 4.5: Stage 4 commit

- [ ] **Step 1: Commit**

  ```bash
  git add include/rv64gc_pkg.sv core/cache/dcache.sv core/rv64gc_core_top.sv
  git -c user.email="jeremycai@local" -c user.name="Jeremy Cai" commit -q -m \
    "refactor(stage4): L1D 4-bank -> 2-bank (matches 4-wide dispatch)

  - rv64gc_pkg.sv: L1D_BANKS 4->2
  - dcache.sv: bank arbitration rewrite (RAMs untouched)
  - core_top: dcache instantiation widths
  - clockcheck + functional + bench regression all PASS"
  ```

---

## Stage 5: Frontend + Testbench + PERF_PROFILE

**Goal:** Final width cascade through fetch / uop_cache / loop_buffer; testbench PERF_PROFILE counters re-sized.

### Task 5.1: Fetch unit

**Files:**
- Modify: `core/fetch/fetch_unit.sv`

- [ ] **Step 1: Update fetch slot extraction (FETCH_BYTES 24→16 cascaded)**

  Mostly param-driven; verify slot-extract loop bounds use FETCH_BYTES / PIPE_WIDTH.

- [ ] **Step 2: Build**

### Task 5.2: Uop cache

**Files:**
- Modify: `core/fetch/uop_cache.sv`
- Modify: `core/fetch/uop_cache_data_ram.sv`

- [ ] **Step 1: Update uop cache sizing**

  Sets/ways/widths: 32×8×6 → 32×8×4. Effort: L (param-driven).

- [ ] **Step 2: Build**

### Task 5.3: Loop buffer

**Files:**
- Modify: `core/loop_buffer.sv`

- [ ] **Step 1: Update LB capture/replay 4-wide**

  PIPE_WIDTH cascade through LB capture path. Effort: L.

- [ ] **Step 2: Build**

### Task 5.4: tb_top.sv PERF_PROFILE counters

**Files:**
- Modify: `src/tb/tb_top.sv` (PERF_PROFILE block)

- [ ] **Step 1: Re-size PERF_PROFILE counter arrays**

  Per-IQ counter arrays sized to NUM_INT_IQS; per-slot fetch/commit histograms sized to PIPE_WIDTH; CDB/bypass counters sized to CDB_WIDTH. Anywhere a 6 is hardcoded in instrumentation, parameterise.

- [ ] **Step 2: Verify dep.v1 / pipe.v1 / cpc.v2 emit still works**

  ```bash
  export LD_LIBRARY_PATH=
  bash build_dsim.sh
  bash run_dsim.sh tests/hex/bench_loop_100.hex 5000 +PERF_PROFILE +TRACE_COMMIT +TRACE_DEP +TRACE_PIPELINE
  grep -c "^\[CPC\]"  dsim_run.log
  grep -c "^\[DEP "   dsim_run.log
  grep -c "^\[PIPE "  dsim_run.log
  ```

  Expected: all three trace formats emit non-zero rows. Stage 5 must not break trace emission (downstream tools depend on it).

### Task 5.5: core_top stitching for Stage 5

**Files:**
- Modify: `core/rv64gc_core_top.sv` (fetch / uop_cache / loop_buffer instantiation)

- [ ] **Step 1: Update remaining instantiation widths**

- [ ] **Step 2: Build clean**

### Task 5.6: Stage 5 gate

- [ ] **Step 1: Clockcheck (all 3 microbenches)**

  ```bash
  mkdir -p traces/stage5
  export LD_LIBRARY_PATH=
  for hex in bench_loop_100 bench_load bench_unrolled_5; do
      bash run_dsim.sh tests/hex/${hex}.hex 5000 +PERF_PROFILE +TRACE_PIPELINE
      grep "^\[PIPE schema=pipe.v1\]" dsim_run.log > traces/stage5/${hex}.pipe.v1.trace
      python ../rv64gc-perf-model/tools/rtl_clockcheck.py \
          --baseline-pipe traces/baseline_6wide/${hex}.pipe.v1.trace \
          --refactor-pipe traces/stage5/${hex}.pipe.v1.trace \
          --allowlist tools/clockcheck_4wide.allowlist.json
      echo "EXIT $? for $hex"
  done
  ```

  Expected: each clockcheck exits 0 (PASS), or with only allowed deltas.

- [ ] **Step 2: Functional regression**

  ```bash
  bash scripts/regress_dsim.sh --func 2>&1 | tee /tmp/regress_stage5_func.log
  ```

  Expected: all `rv64ui_*` tests PASS.

- [ ] **Step 3: Bench regression**

  ```bash
  bash scripts/regress_dsim.sh --bench 2>&1 | tee /tmp/regress_stage5_bench.log
  grep -E "PASS|TIMEOUT|IPC:" /tmp/regress_stage5_bench.log
  ```

  Expected: dhry / cm / cm10 / bench_loop_100 reach STOP. Stage 5 ends with all 5 stages of width cascade in place; the next phase is sign-off.

### Task 5.7: Stage 5 commit

- [ ] **Step 1: Commit**

  ```bash
  git add core/fetch/*.sv core/loop_buffer.sv src/tb/tb_top.sv core/rv64gc_core_top.sv
  git -c user.email="jeremycai@local" -c user.name="Jeremy Cai" commit -q -m \
    "refactor(stage5): frontend + uop cache + LB + tb PERF_PROFILE to 4-wide

  - fetch_unit: FETCH_BYTES 24->16, slot-extract param-driven
  - uop_cache + uop_cache_data_ram: 32x8x6 -> 32x8x4
  - loop_buffer: PIPE_WIDTH cascade
  - tb_top.sv: PERF_PROFILE counter arrays re-sized; trace emit verified
  - core_top: final instantiation widths
  - clockcheck + functional + bench regression all PASS"
  ```

---

## Halt-and-Re-evaluate Rule

**STOP refactoring and convene a review if any of:**

1. Any stage's clockcheck reports unexpected divergence not covered by `tools/clockcheck_4wide.allowlist.json`. Do NOT extend the allowlist to silence the divergence — debug it first. Allowlist extensions require explicit justification (a code change describing what intentional refactor effect creates the diff).

2. Any stage's functional regression (`scripts/regress_dsim.sh --func`) regresses a previously-passing rv64ui test. Stop, fix, re-verify before continuing.

3. Any benchmark TIMEOUTs / IterLimit aborts where it previously reached STOP. The 4-wide is allowed to be slower (more cycles), but it MUST still finish; a TIMEOUT signals deadlock or wraparound bug.

4. **Mid-refactor CM/MHz trajectory check** (after Stage 4): run `bash scripts/regress_dsim.sh --bench` and compute current cm-iter1 CM/MHz. If the partially-refactored RTL is already > 30% below MegaBoom's 6.2 CM/MHz floor (i.e., < 4.34 CM/MHz), it is unlikely Stage 5 alone closes the gap. Stop, review, decide whether to (a) carry on knowing sign-off may fail, or (b) revisit param choices before continuing. **Do not silently compound RTL surgery on a config that won't sign off.**

5. Any commit-time hook fails. Investigate the underlying cause; do not bypass.

---

## Sign-off

After all 5 stages land cleanly:

### Task SO.1: Final functional regression (gating)

- [ ] **Step 1: Full functional + bench regression**

  ```bash
  bash build_dsim.sh
  bash scripts/regress_dsim.sh 2>&1 | tee /tmp/regress_final.log
  ```

  **Required for sign-off:**
  - All `rv64ui_*` tests PASS
  - dhrystone reaches PASS at tohost (STOP)
  - coremark iter=1 reaches PASS at tohost (STOP)
  - coremark iter=10 reaches PASS at tohost (STOP)  ← LSU iter=10 patch preservation gate
  - bench_loop_100 reaches PASS at tohost (STOP)

  No TIMEOUTs, no IterLimit aborts.

### Task SO.2: Performance measurement

- [ ] **Step 1: Re-run the three perf benchmarks with PERF_PROFILE for the official IPC**

  ```bash
  export LD_LIBRARY_PATH=
  for hex in dhrystone coremark coremark_iter10 bench_loop_100; do
      bash run_dsim.sh tests/hex/${hex}.hex 5000000 +PERF_PROFILE 2>&1 | tail -5
      grep -E "BENCH_RESULT|IPC:" dsim_run.log | tail -10
      cp dsim_run.log /tmp/signoff_${hex}.log
  done
  ```

- [ ] **Step 2: Compute CM/MHz and DMIPS/MHz from the logs**

  - **DMIPS/MHz** = `iterations * 1e6 / (cycles * 1757)` (dhry, iter=100)
  - **CM/MHz** = `iterations * 1e6 / cycles` (coremark)

  Record both iter=1 and iter=10 CM/MHz; iter=10 amortises CoreMark setup and is the more comparable figure for external references.

### Task SO.3: Sign-off gate

- [ ] **Step 1: Compare against external references**

  | Tier | Required | Measured | Pass? |
  |---|---:|---:|---|
  | Floor (MegaBoom) | CM/MHz ≥ 6.2 | _______ | _______ |
  | Floor (MegaBoom) | DMIPS/MHz ≥ 4.00 | _______ | _______ |
  | Stretch (A72) | CM/MHz ≥ 8.24 | _______ | _______ |
  | Stretch (A72) | DMIPS/MHz ≥ 4.72 | _______ | _______ |

  Sign-off success = floor met. Stretch met = strong. Floor missed = halt-and-re-evaluate (see rule above); the 4-wide refactor itself is correct, but the design as configured does not meet the bar.

### Task SO.4: Sign-off commit + doc

- [ ] **Step 1: Write `doc/4wide_signoff_<DATE>.md`** capturing the measured numbers, the sign-off gate result, and which (if any) stretch tier was met.

- [ ] **Step 2: Commit the sign-off doc**

  ```bash
  git add doc/4wide_signoff_*.md
  git -c user.email="jeremycai@local" -c user.name="Jeremy Cai" commit -q -m \
    "doc: 4-wide refactor sign-off — CM/MHz=… DMIPS/MHz=…"
  ```

- [ ] **Step 3: Merge to master (only if floor passed; otherwise leave on branch for revisit)**

  ```bash
  git checkout master
  git merge --no-ff 4wide-pivot
  ```

---

## Reference

- **Design rationale:** `doc/4wide_pivot_plan_2026-04-25.md` (full param table, module rewrites, files NOT to touch, risk/mitigation).
- **6-wide baseline (archive only, do not use for forward comparison):** `doc/baseline_6wide_obsolete_2026-04-30.md`.
- **Perf-model status (paused, dead-end):** `../rv64gc-perf-model/doc/phase_2_5_signoff.md`.
- **Repo ground rules:** `AGENTS.md`.
- **Clockcheck tool:** `../rv64gc-perf-model/tools/rtl_clockcheck.py`.

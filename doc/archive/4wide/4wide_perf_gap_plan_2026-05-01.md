# 4-Wide Performance Gap Closure — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Auto-mode standing rule: subagent-driven-development is invoked automatically after this plan completes.

**Goal:** Close the rv64gc-v2 4-wide CM/MHz gap (5.01/5.37 vs 6.2 floor; −13%/−19%) and DMIPS/MHz gap (2.42 vs 4.00 floor; −39.5%) through purely data-driven RTL changes, with each change gated by a falsifiable predicted-IPC delta committed before measurement.

**Architecture:** 4 phases (A: instrumentation top-up + counter capture; B: bubble bucket attribution from absolute 4-wide percentages; C: hypothesis enumeration with predicted counter signatures; D: microbench probes + iterative RTL changes). Sign-off is external (Reference Core A (large config)/A72), not 6-wide-relative — the design doc `doc/4wide_perf_gap_analysis_2026-05-01.md` explains why.

**Tech Stack:** SystemVerilog + DSim 2026 (build_dsim.sh) + clockcheck (`python3 ../rv64gc-perf-model/tools/rtl_clockcheck.py`). All work on `master` (currently `68ddf57`).

---

## Background — what the existing instrumentation already gives us

A pre-plan inventory of `tb_top.sv` PERF_PROFILE + `rob.sv` HEAD STALL summary on `cd54cf1` shows the bubble picture is **already largely instrumented**:

- `commit_hist[0..6]` — per-cycle commit-count distribution (the bubble shape)
- `frontend_hist[0..6]` — per-cycle rename slot count distribution (front-end bubble shape)
- `rob_head_not_ready_cyc` + per-class breakdown (`load/store/branch/serial/other`)
- `rob_head_wb_bypass_cand_cnt` + per-class breakdown
- Per-PC head-stall sample table (top 32 PCs)
- Full structure-full counters (`rob_full`, `dq_full`, `lq_full`, `sq_full`, `iq{0,1,2}_full`)
- Rename stall slot-attribution (`stall_{preg,ckpt,rob,dq,other}_cyc`)
- IQ avg occupancy + LSU pressure summary + load latency histogram + per-PC mispredict table

What's missing (the only gap that requires additive counters):

- **Issue-stall classification** — when IQ has eligible entries AND issue grant < 4, why? (operands-not-ready / FU-contention / arb-loss)
- **"Other" head-stall PC-level decomposition** — the catch-all bucket that dominates cm's head-stall (54154 of 94129 cycles); we need to know what sub-class of uop falls into "other"

These are pure additive counters, no RTL logic change. Scoped at ~40-60 lines total.

---

## File Structure

| File | Responsibility |
|---|---|
| `src/tb/tb_top.sv` | (modify) Add issue-stall classification counters + corresponding print block |
| `src/rtl/core/backend/rob.sv` | (modify) Refine "other" head-stall classification — add `head_not_ready_other_{mul,div,csr,bru,unknown}_cyc` sub-buckets |
| `benchmark_results/perf_inventory_2026-05-01.md` | (create) Phase A flat counter inventory |
| `benchmark_results/perf_full_4wide_{cm_iter1,cm_iter10,dhrystone}.log` | (create) Per-workload full PERF_PROFILE logs after instrumentation lands |
| `benchmark_results/bottleneck_ranking_2026-05-01.md` | (create) Phase B bucket attribution + top-3 ranking |
| `benchmark_results/hypothesis_table_2026-05-01.md` | (create) Phase C hypothesis enumeration |
| `tests/asm/probe_*.S` | (create) 5 microbench probe sources (Phase D) |
| `tests/hex/probe_*.hex` | (create) 5 microbench hex artifacts (Phase D) |
| `benchmark_results/microbench_probes_2026-05-01.md` | (create) Phase D probe results + hypothesis confirm/refute table |
| `doc/4wide_perf_gap_results_<final-date>.md` | (create, incremental) Companion results doc to design doc |
| `doc/4wide_signoff_2026-05-XX.md` | (create) Refreshed sign-off doc post Phase D |

---

## Phase A — Instrumentation Top-Up + Capture

### Task 1: Inspect ROB "other" head-stall classification

**Files:**
- Read: `src/rtl/core/backend/rob.sv:900-960` (head-stall counter declaration + classification logic)

- [ ] **Step 1: Find the head-class classification logic**

Run: `grep -nE "head_not_ready.*<=|case.*head_uop|head_op_type" src/rtl/core/backend/rob.sv | head -20`

Read the surrounding always_ff block to identify how load/store/branch/serial/other are determined and what the "other" catch-all currently absorbs (likely arithmetic-pending = MUL pending writeback, DIV pending writeback, CSR serialization, BRU pending resolution, plus genuinely-unknown).

- [ ] **Step 2: Determine sub-class signal availability**

For each candidate sub-class (mul/div/csr/bru), confirm a signal exists at the head uop that distinguishes it. Common patterns: `head_uop.fu_type`, `head_uop.is_mul`, `head_uop.is_div`. Document findings inline — no code yet.

Expected output: a 5-line note in the next step that lists the signal name(s) for each sub-class.

- [ ] **Step 3: Move on to Task 2 only after Step 2 produces a usable signal map**

If the head-uop FU-type signal isn't directly exposed at rob.sv scope, add a one-line note and DEFER the "other" decomposition to a future iteration. Do not add speculative classification.

### Task 2: Add ROB "other" head-stall sub-classification (only if Task 1 found usable signals)

**Files:**
- Modify: `src/rtl/core/backend/rob.sv` — counter declarations near line 908; classification block in always_ff; print block near line 1163

- [ ] **Step 1: Declare sub-counters**

Add near `rob_head_not_ready_other_cyc` declaration:
```systemverilog
    integer rob_head_not_ready_mul_cyc;
    integer rob_head_not_ready_div_cyc;
    integer rob_head_not_ready_csr_cyc;
    integer rob_head_not_ready_bru_cyc;
    integer rob_head_not_ready_unknown_cyc;
```

- [ ] **Step 2: Add reset for the new counters**

In the same reset block as `rob_head_not_ready_other_cyc <= 0;`, add five `<= 0;` lines for the new counters.

- [ ] **Step 3: Refine classification in the always_ff increment block**

Replace the existing `else rob_head_not_ready_other_cyc <= rob_head_not_ready_other_cyc + 1;` with a nested classification using the signals identified in Task 1 Step 2. Keep `rob_head_not_ready_other_cyc` as the top-level total (sum of mul+div+csr+bru+unknown) — do not break callers.

- [ ] **Step 4: Add print lines after the existing "other" print**

In the final block near line 1168:
```systemverilog
            $display("  other-class: mul/div/csr/bru/unknown: %0d / %0d / %0d / %0d / %0d",
                rob_head_not_ready_mul_cyc,
                rob_head_not_ready_div_cyc,
                rob_head_not_ready_csr_cyc,
                rob_head_not_ready_bru_cyc,
                rob_head_not_ready_unknown_cyc);
```

- [ ] **Step 5: Build + smoke-test**

Run:
```bash
export LD_LIBRARY_PATH=
bash build_dsim.sh
bash run_dsim.sh tests/hex/coremark.hex 5000000 +PERF_PROFILE > /tmp/cm_smoke.log 2>&1
grep -A 2 "other-class" /tmp/cm_smoke.log
```

Expected: a non-empty `other-class:` line with five counter values that sum to `rob_head_not_ready_other_cyc`.

- [ ] **Step 6: Verify functional regression unchanged**

Run: `export LD_LIBRARY_PATH= && bash scripts/regress_dsim.sh 2>&1 | tail -10`
Expected: 21/21 PASS, no FAIL.

- [ ] **Step 7: Commit**

```bash
git add src/rtl/core/backend/rob.sv
git -c user.email="jeremycai@local" -c user.name="Jeremy Cai" commit -m \
  "perf-instr: refine ROB other-class head-stall (mul/div/csr/bru/unknown)

Phase A.2 of doc/4wide_perf_gap_analysis_2026-05-01.md. Adds 5 sub-counters
to decompose rob_head_not_ready_other_cyc — currently 54154 of 94129
head-stall cycles in cm (57%). Without sub-classification we can't tell
whether the dominant 'other' head-wait is MUL/DIV/CSR/BRU latency or
genuinely unclassified.

Pure additive counters; no RTL logic change. Total counter is preserved
for callers."
```

### Task 3: Add issue-stall classification counters in tb_top.sv

**Files:**
- Modify: `src/tb/tb_top.sv` — counter declarations near line 437; reset block near line 825; increment block near line 879; print block near line 1505

- [ ] **Step 1: Inspect IQ eligible/grant signals**

Run: `grep -nE "eligible|sel_idx|issue_valid" src/rtl/core/issue/issue_queue.sv | head -15`

Identify three signals per IQ:
- `eligible[*]` — entries with operands ready
- `sel_idx[*]` — selected entries (granted port)
- `issue_valid[*]` — final fire (after FU suppress)

Note: in the 4-wide design IQ has 2 ports per queue × 3 queues = 6 issue ports max.

- [ ] **Step 2: Declare counters in tb_top.sv near line 437**

```systemverilog
    // Issue-stall classification (Phase A.2): IQ has eligible entries but issue_valid count < grant capacity
    integer issue_stall_operand_cyc;   // entries valid but no operands ready
    integer issue_stall_fu_cyc;        // operands ready but FU suppress dropped grant
    integer issue_stall_arb_cyc;       // ports granted < min(eligible_count, NUM_SELECT)
```

- [ ] **Step 3: Add reset block near line 825**

Inside the reset clause where existing stall counters reset:
```systemverilog
            issue_stall_operand_cyc <= 0;
            issue_stall_fu_cyc      <= 0;
            issue_stall_arb_cyc     <= 0;
```

- [ ] **Step 4: Add classification in the increment block near line 879**

For each IQ (iq0, iq1, iq2), classify within the `pp_en` block. Pseudocode (adapt to actual signal names from Step 1):

```systemverilog
            // Per-IQ issue-stall classification
            for (int iq = 0; iq < 3; iq++) begin
                automatic int eligible_count;
                automatic int issue_count;
                automatic int valid_count;
                // Collect counts from u_core.u_iq{0,1,2} (use $countones over the bit vectors)
                // Order: operand-stall (valid but no eligible) > fu-stall (eligible but no issue_valid) > arb-stall (eligible > issue_valid)
            end
```

**Note:** the actual implementation must call out the iqN by name (no for loop over hierarchical references in synthesizable SV). Use three sequential blocks with explicit `u_core.u_iq0.eligible`, `u_core.u_iq1.eligible`, `u_core.u_iq2.eligible`. Sum across all three IQs into the three counter buckets.

- [ ] **Step 5: Add print block near line 1505 ("Stall breakdown" section)**

```systemverilog
            $display("Issue-stall classification (cycle-based, all IQs):");
            $display("  operand_not_ready: %0d", issue_stall_operand_cyc);
            $display("  fu_contention   : %0d", issue_stall_fu_cyc);
            $display("  arb_loss        : %0d", issue_stall_arb_cyc);
```

- [ ] **Step 6: Build + smoke-test**

```bash
export LD_LIBRARY_PATH=
bash build_dsim.sh
bash run_dsim.sh tests/hex/coremark.hex 5000000 +PERF_PROFILE > /tmp/cm_iss.log 2>&1
grep "Issue-stall classification" -A 3 /tmp/cm_iss.log
```

Expected: a non-zero `operand_not_ready` count for cm (we already know commit-count distribution shows lots of 0/1 commits).

- [ ] **Step 7: Verify functional regression unchanged**

Run: `export LD_LIBRARY_PATH= && bash scripts/regress_dsim.sh 2>&1 | tail -10`
Expected: 21/21 PASS, no FAIL.

- [ ] **Step 8: Commit**

```bash
git add src/tb/tb_top.sv
git -c user.email="jeremycai@local" -c user.name="Jeremy Cai" commit -m \
  "perf-instr: add issue-stall classification (operand/fu/arb)

Phase A.2 of doc/4wide_perf_gap_analysis_2026-05-01.md. Adds 3 cycle
counters classifying why the issue stage didn't grant 4 per cycle:
  - operand_not_ready: IQ entries valid but no src ready
  - fu_contention   : eligible but FU suppress dropped grant
  - arb_loss        : eligible_count > grant_count

Counter-only addition in tb_top.sv; no RTL logic change. Gated on
existing +PERF_PROFILE plusarg."
```

### Task 4: Capture full PERF_PROFILE for cm + dhry

**Files:**
- Create: `benchmark_results/perf_full_4wide_cm_iter1.log`
- Create: `benchmark_results/perf_full_4wide_cm_iter10.log`
- Create: `benchmark_results/perf_full_4wide_dhrystone.log`

- [ ] **Step 1: Capture cm iter1**

```bash
export LD_LIBRARY_PATH=
bash run_dsim.sh tests/hex/coremark.hex 5000000 +PERF_PROFILE > /dev/null 2>&1
cp dsim_run.log benchmark_results/perf_full_4wide_cm_iter1.log
grep -E "PASS at cycle|TOHOST|^IPC:" benchmark_results/perf_full_4wide_cm_iter1.log
```

Expected: `PASS at cycle 199xxx (tohost=1)` and `IPC: mcycle=199xxx minstret=332xxx IPC=1.66x`.

- [ ] **Step 2: Capture cm iter10**

```bash
bash run_dsim.sh tests/hex/coremark_iter10.hex 5000000 +PERF_PROFILE > /dev/null 2>&1
cp dsim_run.log benchmark_results/perf_full_4wide_cm_iter10.log
grep -E "PASS at cycle|^IPC:" benchmark_results/perf_full_4wide_cm_iter10.log
```

Expected: `PASS at cycle 186xxxx (tohost=1)` and `IPC: ... IPC=1.71x`.

- [ ] **Step 3: Capture dhrystone**

```bash
bash run_dsim.sh tests/hex/dhrystone.hex 100000 +PERF_PROFILE > /dev/null 2>&1
cp dsim_run.log benchmark_results/perf_full_4wide_dhrystone.log
grep -E "PASS at cycle|^IPC:" benchmark_results/perf_full_4wide_dhrystone.log
```

Expected: `PASS at cycle 23514 (tohost=1)` and `IPC: ... IPC=2.027`.

- [ ] **Step 4: Commit logs**

```bash
git add benchmark_results/perf_full_4wide_*.log
git -c user.email="jeremycai@local" -c user.name="Jeremy Cai" commit -m \
  "perf-data: capture full PERF_PROFILE for cm/dhry post Phase A.2 instr"
```

### Task 5: Produce perf_inventory_2026-05-01.md

**Files:**
- Create: `benchmark_results/perf_inventory_2026-05-01.md`

- [ ] **Step 1: Extract section headers from a captured log**

Run: `grep -nE "^(===|Stall breakdown|Average|LSU pressure|Load issue|Committed|Loop-buffer|Issue-stall|=== ROB)" benchmark_results/perf_full_4wide_cm_iter1.log`

This gives the section structure to reproduce in the inventory table.

- [ ] **Step 2: Write the inventory doc**

Structure: per workload, a table with columns `Counter | Absolute | % of mcycle`.

Group by 6-bucket framework:
1. **Frontend** — flush_cyc, fetch_zero_*_cyc, frontend_hist[0..4], LB miss, uop-cache miss
2. **Rename + Dispatch** — rename_stall_cyc, structure-full counters, stall_{preg,ckpt,rob,dq,other}_cyc
3. **Issue** — issue_stall_{operand,fu,arb}_cyc (NEW from Task 3)
4. **Execute (non-LSU)** — head_not_ready_{mul,div,csr,bru}_cyc (NEW from Task 2), backend_stall_cyc
5. **LSU** — head_not_ready_{load,store}_cyc, sq_fwd_wait_cyc, ld*_suppress_cyc, p1 conflict, load_lat_pending_*
6. **Commit** — head_not_ready_unknown_cyc (residual after the above), commit_hist[0..3]

Include the per-workload `mcycle / minstret / IPC` as a header row.

- [ ] **Step 3: Sanity-check residual**

For each workload, compute `peak_retire_cycles = ceil(minstret / 4)` and `gap_cycles = mcycle - peak_retire_cycles`. Compare against the sum of bucketed cycles. Document residual % at the bottom of each workload table.

Acceptance: residual ≤ 10% per workload. If >10%, identify the missing counter and iterate Task 2 or Task 3 with a more targeted addition.

- [ ] **Step 4: Commit**

```bash
git add benchmark_results/perf_inventory_2026-05-01.md
git -c user.email="jeremycai@local" -c user.name="Jeremy Cai" commit -m \
  "perf-data: Phase A inventory — 6-bucket counter table for cm + dhry"
```

---

## Phase B — Bottleneck Ranking

### Task 6: Produce bottleneck_ranking_2026-05-01.md

**Files:**
- Create: `benchmark_results/bottleneck_ranking_2026-05-01.md`
- Read: `benchmark_results/perf_inventory_2026-05-01.md`

- [ ] **Step 1: Per-workload bucket gap table**

For each workload, copy the bucket inventory and add a `% of gap_cycles` column. Sum bucket attribution; flag residual.

Example structure:
```
## CoreMark iter1 (mcycle=199452, IPC=1.665)

peak_retire_cycles = ceil(332110 / 4) = 83028
gap_cycles = 199452 - 83028 = 116424

| Bucket | Cycles | % of gap |
|---|---:|---:|
| Frontend (flush, fetch_zero, ...) | 21,xxx | xx.x% |
| Rename + Dispatch | 0 | 0.0% |
| Issue | xxx | xx.x% |
| Execute (non-LSU) | xx,xxx | xx.x% |
| LSU | xx,xxx | xx.x% |
| Commit | xx,xxx | xx.x% |
| Residual | xxx | x.x% |
```

- [ ] **Step 2: Top-3 ranked callout per workload**

Add at the top of each workload section:
```
**Top-3 buckets:**
1. <bucket-name> (xx.x% of gap_cycles)
2. <bucket-name> (xx.x%)
3. <bucket-name> (xx.x%)
```

- [ ] **Step 3: Cross-workload synthesis**

Add a final section: "Per-workload bottleneck profiles differ — gap closure work must be partitioned by workload, not by RTL module." List the dominant bucket per workload.

- [ ] **Step 4: Commit**

```bash
git add benchmark_results/bottleneck_ranking_2026-05-01.md
git -c user.email="jeremycai@local" -c user.name="Jeremy Cai" commit -m \
  "perf-data: Phase B bucket ranking — top-3 bottleneck per workload"
```

---

## Phase C — Hypothesis Enumeration

### Task 7: Produce hypothesis_table_2026-05-01.md

**Files:**
- Create: `benchmark_results/hypothesis_table_2026-05-01.md`
- Read: `benchmark_results/bottleneck_ranking_2026-05-01.md`

- [ ] **Step 1: For each top-3 bucket per workload, write hypothesis rows**

Use the template from the design doc Section 4.3. Required fields per row:
- ID (e.g., `cm-H1`)
- Bucket (which Phase B bucket)
- Description (one-sentence mechanism in narrowed RTL)
- Predicted signature (which counter changes, in which direction, if hypothesis is correct)
- Discrimination (which microbench probe would isolate it)
- Expected fix shape (RTL change family — NOT specific edits)

- [ ] **Step 2: Seed with the design-doc initial findings**

Pre-populate from the seed list in `doc/4wide_perf_gap_analysis_2026-05-01.md` Section 4.3. Refine wording if Phase B data invalidates any. Document any seed that's refuted by Phase B with a one-line note (do not delete; the refute is itself a finding).

- [ ] **Step 3: Add new hypotheses surfaced by Phase B**

If Phase B revealed a bucket the seed list didn't address, add hypotheses for it. Each hypothesis must cite the Phase B counter that motivated it.

- [ ] **Step 4: Commit**

```bash
git add benchmark_results/hypothesis_table_2026-05-01.md
git -c user.email="jeremycai@local" -c user.name="Jeremy Cai" commit -m \
  "perf-data: Phase C hypothesis enumeration — seeded by Phase B ranking"
```

---

## Phase D — Microbench Probes + Iterative RTL Changes

### Task 8: Write 5 microbench probe sources

**Files:**
- Create: `tests/asm/probe_alu_chain_8.S`
- Create: `tests/asm/probe_dhry_call_mimic.S`
- Create: `tests/asm/probe_bpu_data_dep_branch.S`
- Create: `tests/asm/probe_mixed_branch_dense.S`
- Create: `tests/asm/probe_independent_quad.S`

- [ ] **Step 1: Inspect existing test asm to learn the project's tohost/exit convention**

Run: `ls tests/asm/ 2>/dev/null && grep -l "tohost" tests/asm/*.S 2>/dev/null | head -3`
Read one example to learn the boilerplate (entry point, tohost write to exit, .data section). If `tests/asm/` doesn't exist, fall back to `tests/c/` or wherever the existing dhry/cm sources live and check the linker script.

- [ ] **Step 2: Write probe_alu_chain_8.S**

Goal: 8-deep ALU dependency chain in tight loop. Stresses bypass and CDB.
Body shape (after entry boilerplate):
```asm
    li      a0, 1000        # outer loop count
    li      a1, 1
loop:
    add     t0, a1, a1
    add     t1, t0, a1
    add     t2, t1, a1
    add     t3, t2, a1
    add     t4, t3, a1
    add     t5, t4, a1
    add     t6, t5, a1
    add     a2, t6, a1
    addi    a0, a0, -1
    bnez    a0, loop
    # exit via tohost=1 boilerplate
```

- [ ] **Step 3: Write probe_dhry_call_mimic.S**

Goal: mimic Dhrystone's Proc_1..Proc_7 call topology (4–7 nested calls per outer-loop iter, mixed-arg, return-value chained). Specifically NOT a generic call_burst.

Body shape: implement 4 small functions `Proc_a/b/c/d` with mixed argument shapes (1-arg, 2-arg, 3-arg + return-via-pointer, 0-arg). Have main call `Proc_a(x)` → `Proc_b(x, y)` → `Proc_c(x, &y)` → `Proc_d()` → loop. Outer-loop count 1000.

The point is to reproduce dhry's procedure-entry burst pattern (push regs to stack, load args, call, restore regs, return). Do not optimize the calling convention — this probe needs the same prologue/epilogue density that dhry has.

- [ ] **Step 4: Write probe_bpu_data_dep_branch.S**

Goal: random data-dependent branch in tight loop; mimics the cm `0x8000235a` profile.
Body shape:
```asm
    la      a0, lfsr_state
    li      a1, 1000
loop:
    lw      t0, 0(a0)               # load LFSR state
    slli    t1, t0, 13
    xor     t0, t0, t1
    srli    t1, t0, 17
    xor     t0, t0, t1
    slli    t1, t0, 5
    xor     t0, t0, t1              # next LFSR value
    sw      t0, 0(a0)
    andi    t1, t0, 1               # bit 0 of LFSR (random-ish)
    bnez    t1, l_taken             # data-dependent branch
    addi    a2, a2, 1
    j       l_after
l_taken:
    addi    a3, a3, 1
l_after:
    addi    a1, a1, -1
    bnez    a1, loop
.data
lfsr_state: .word 0xdeadbeef
```

- [ ] **Step 5: Write probe_mixed_branch_dense.S**

Goal: 1 branch per 4 instructions, mixed taken/not-taken.
Body shape: a loop body of 16 instructions including 4 conditional branches, with the predicate alternating per iteration via a counter parity check. Outer-loop count 1000.

- [ ] **Step 6: Write probe_independent_quad.S**

Goal: 4 independent ALU per cycle, sustained loop. Sanity ceiling — does 4-wide hit IPC=4?
Body shape:
```asm
    li      a0, 1000
loop:
    add     t0, a1, a2     # 4 INDEPENDENT adds — no dep chain
    add     t1, a3, a4
    add     t2, a5, a6
    add     t3, a7, s0
    add     t4, s1, s2
    add     t5, s3, s4
    add     t6, s5, s6
    add     s7, s8, s9
    addi    a0, a0, -1
    bnez    a0, loop
```

- [ ] **Step 7: Commit asm sources**

```bash
git add tests/asm/probe_*.S
git -c user.email="jeremycai@local" -c user.name="Jeremy Cai" commit -m \
  "perf-probe: 5 microbench .S sources for Phase D bottleneck isolation"
```

### Task 9: Build microbench hex artifacts

**Files:**
- Create: `tests/hex/probe_alu_chain_8.hex`
- Create: `tests/hex/probe_dhry_call_mimic.hex`
- Create: `tests/hex/probe_bpu_data_dep_branch.hex`
- Create: `tests/hex/probe_mixed_branch_dense.hex`
- Create: `tests/hex/probe_independent_quad.hex`

- [ ] **Step 1: Inspect the existing build flow**

Run: `cat scripts/elf2hex.py 2>/dev/null | head -40 || find . -name "Makefile" -path "*/tests/*" | head -3`

Locate the toolchain command sequence. Typically: `riscv64-unknown-elf-gcc -nostartfiles -T <link.ld> -o <name>.elf <name>.S` then `python3 scripts/elf2hex.py <name>.elf > <name>.hex`.

- [ ] **Step 2: Build each probe**

For each probe (replace `<name>`):
```bash
riscv64-unknown-elf-gcc -nostartfiles -march=rv64gc -mabi=lp64d \
    -T tests/link/test.ld \
    -o /tmp/<name>.elf tests/asm/<name>.S
python3 scripts/elf2hex.py /tmp/<name>.elf > tests/hex/<name>.hex
```

(Adjust the `-T` linker script path to whatever the existing tests use.)

- [ ] **Step 3: Smoke-test each hex with DSim**

```bash
export LD_LIBRARY_PATH=
for p in alu_chain_8 dhry_call_mimic bpu_data_dep_branch mixed_branch_dense independent_quad; do
    bash run_dsim.sh tests/hex/probe_${p}.hex 100000 +PERF_PROFILE > /tmp/probe_${p}.log 2>&1
    echo "=== ${p} ==="
    grep -E "PASS at cycle|TIMEOUT|^IPC:" /tmp/probe_${p}.log | head -3
done
```

Expected: each probe reaches `PASS at cycle ...`. If any TIMEOUTs, the .S has a tohost-write bug — fix the boilerplate before continuing.

- [ ] **Step 4: Commit hexes**

```bash
git add tests/hex/probe_*.hex
git -c user.email="jeremycai@local" -c user.name="Jeremy Cai" commit -m \
  "perf-probe: build 5 microbench hex artifacts"
```

### Task 10: Run probes + write microbench_probes_2026-05-01.md

**Files:**
- Create: `benchmark_results/microbench_probes_2026-05-01.md`
- Read: `/tmp/probe_*.log` (from Task 9 Step 3) or re-run

- [ ] **Step 1: Capture full PERF_PROFILE for each probe**

Re-run with adequate cycle cap and save to benchmark_results/:
```bash
export LD_LIBRARY_PATH=
for p in alu_chain_8 dhry_call_mimic bpu_data_dep_branch mixed_branch_dense independent_quad; do
    bash run_dsim.sh tests/hex/probe_${p}.hex 100000 +PERF_PROFILE > /dev/null 2>&1
    cp dsim_run.log benchmark_results/probe_${p}.log
done
```

- [ ] **Step 2: Per-probe IPC + bucket-counter table**

For each probe, extract:
- mcycle / minstret / IPC
- The Phase B bucket the probe was designed to stress
- The counter that should respond

- [ ] **Step 3: Hypothesis confirm/refute table**

For each hypothesis from `hypothesis_table_2026-05-01.md`, compare:
- Predicted signature (counter direction)
- Observed signature (from the matching probe)
- Verdict: CONFIRM / REFUTE / INCONCLUSIVE

- [ ] **Step 4: Sanity check independent_quad**

If `probe_independent_quad` doesn't achieve IPC ≈ 4, flag immediately — there's a structural ceiling bug that must be fixed before any gap-closure RTL work proceeds.

- [ ] **Step 5: Commit**

```bash
git add benchmark_results/microbench_probes_2026-05-01.md benchmark_results/probe_*.log
git -c user.email="jeremycai@local" -c user.name="Jeremy Cai" commit -m \
  "perf-data: Phase D probes — confirm/refute table for hypotheses"
```

### Task 11: RTL change iteration (REPEAT for each confirmed hypothesis from Task 10)

**Files:** depends on hypothesis. Each iteration produces:
- Modify: 1–3 RTL files (concrete files identified by the hypothesis's "expected fix shape")
- Modify or create: a per-iteration prediction note in `benchmark_results/iter_<id>_prediction.md`
- Update: `benchmark_results/microbench_probes_2026-05-01.md` (append measurement row)

For the FIRST confirmed hypothesis from Task 10's table, follow the template below. Re-instantiate the template for each subsequent confirmed hypothesis.

- [ ] **Step 1: Pick the highest-ranked confirmed hypothesis**

Select from Task 10's CONFIRM verdicts. Highest-rank = largest predicted IPC delta or dominates the largest bucket.

- [ ] **Step 2: Write the prediction note BEFORE any RTL change**

Create `benchmark_results/iter_<id>_prediction.md` (e.g., `iter_dhry-H1_prediction.md`) with:
```
# Iteration <id> — Prediction

**Hypothesis:** <copy from hypothesis_table>
**Predicted RTL change:** <files:lines + concrete edit shape>
**Predicted IPC delta:**
  - cm iter1:  ±X.XX (current 1.665 → expected 1.665 ± X.XX)
  - cm iter10: ±X.XX (current 1.719 → expected 1.719 ± X.XX)
  - dhrystone: ±X.XX (current 2.027 → expected 2.027 ± X.XX)
  - probe_<matching>: ±X.XX
**Confirmation criterion:** counter <name> must <improve/regress> by ≥<N>%
**Refutation criterion:** if measured cm/dhry diverges from predicted by >30% → hypothesis unsound; revert
**Neutral-or-better:** other workload (cm or dhry) must not regress beyond ±2% IPC
```

Commit this note BEFORE making any RTL change:
```bash
git add benchmark_results/iter_<id>_prediction.md
git -c user.email="jeremycai@local" -c user.name="Jeremy Cai" commit -m \
  "perf-iter <id>: prediction committed before RTL change"
```

- [ ] **Step 3: Apply the RTL change**

Make the concrete edit identified in Step 2. One iteration = one focused change. Do not bundle.

- [ ] **Step 4: Build + functional + clockcheck regression**

```bash
export LD_LIBRARY_PATH=
bash build_dsim.sh 2>&1 | tail -3
bash scripts/regress_dsim.sh 2>&1 | tail -10
mkdir -p traces/iter_<id>
for hex in bench_loop_100 bench_load bench_unrolled_5; do
    bash run_dsim.sh tests/hex/${hex}.hex 5000 +PERF_PROFILE +TRACE_PIPELINE > /dev/null 2>&1
    grep "^\[PIPE schema=pipe.v1\]" dsim_run.log > traces/iter_<id>/${hex}.pipe.v1.trace
    python3 ../rv64gc-perf-model/tools/rtl_clockcheck.py \
        --baseline-pipe traces/baseline_6wide/${hex}.pipe.v1.trace \
        --refactor-pipe traces/iter_<id>/${hex}.pipe.v1.trace \
        --allowlist tools/clockcheck_4wide.allowlist.json
done
```

Required: 21/21 functional PASS; clockcheck PASS or only documented allowlist deltas.

- [ ] **Step 5: Measure cm + dhry + matching probe**

```bash
bash run_dsim.sh tests/hex/coremark.hex 5000000 +PERF_PROFILE > /dev/null 2>&1 && \
    grep "^IPC:" dsim_run.log
bash run_dsim.sh tests/hex/dhrystone.hex 100000 +PERF_PROFILE > /dev/null 2>&1 && \
    grep "^IPC:" dsim_run.log
bash run_dsim.sh tests/hex/probe_<matching>.hex 100000 +PERF_PROFILE > /dev/null 2>&1 && \
    grep "^IPC:" dsim_run.log
```

- [ ] **Step 6: Compare measured vs predicted**

Append measurement row to `iter_<id>_prediction.md`:
```
## Measured

  - cm iter1:  X.XX (Δ = +X.XX vs current; predicted +X.XX → divergence X.X%)
  - cm iter10: X.XX (...)
  - dhrystone: X.XX (...)
  - probe_<matching>: X.XX (...)
  - confirmation counter <name>: <value> (predicted <expected> → MET / NOT MET)
**Verdict:** SUCCESS / REVERT (per the 30% rule and neutral-or-better rule)
```

- [ ] **Step 7a: If SUCCESS — commit the RTL change**

```bash
git add <touched-files>
git -c user.email="jeremycai@local" -c user.name="Jeremy Cai" commit -m \
  "perf-iter <id>: <hypothesis-summary> — measured Δ <cm-delta>/<dhry-delta>

Hypothesis: <id> from hypothesis_table_2026-05-01.md
Predicted: cm iter1 ±X.XX, cm iter10 ±X.XX, dhrystone ±X.XX
Measured: cm iter1 +X.XX, cm iter10 +X.XX, dhrystone +X.XX
Confirmation counter <name>: <improvement>
Functional 21/21 PASS, clockcheck 3/3 PASS, no allowlist regressions.

See benchmark_results/iter_<id>_prediction.md for full prediction-vs-measured."
```

Then commit the updated prediction note:
```bash
git add benchmark_results/iter_<id>_prediction.md \
        benchmark_results/microbench_probes_2026-05-01.md
git commit -m "perf-iter <id>: record measurement (SUCCESS)"
```

- [ ] **Step 7b: If REVERT — back out the RTL change**

```bash
git checkout <touched-files>
git add benchmark_results/iter_<id>_prediction.md
git -c user.email="jeremycai@local" -c user.name="Jeremy Cai" commit -m \
  "perf-iter <id>: REVERT — hypothesis refuted

Predicted: <delta>; Measured: <delta>; Divergence: <pct>% (>30% rule)
OR: regression on other workload (<delta>%, exceeds ±2% rule)

Hypothesis recorded as REFUTED in hypothesis_table_2026-05-01.md.
No RTL change retained. Return to Phase B/C with this data point."
```

Update `hypothesis_table_2026-05-01.md` to mark the hypothesis REFUTED with the measured divergence as evidence.

- [ ] **Step 8: Loop**

Re-instantiate Task 11 for the next confirmed hypothesis. Continue until either:
- (a) Both workloads at floor: cm CM/MHz ≥ 6.2 AND dhry DMIPS/MHz ≥ 4.00
- (b) Hypothesis list exhausted (all CONFIRM verdicts processed) — stop and return to Phase B/C with new data
- (c) Five consecutive REVERT verdicts — methodology may be broken; halt and re-evaluate

---

## Phase Complete — Sign-Off Refresh

### Task 12: Write companion results doc + refreshed sign-off

**Files:**
- Create: `doc/4wide_perf_gap_results_<final-date>.md`
- Create: `doc/4wide_signoff_<final-date>.md`

- [ ] **Step 1: Write the results doc**

Pair with `doc/4wide_perf_gap_analysis_2026-05-01.md`. Sections:
1. Final cm + dhry + cm10 measurements
2. Counter inventory delta (Phase A starting point → Phase D end state)
3. Bucket attribution evolution (Phase B → end state)
4. Hypothesis verdicts (CONFIRM/REFUTE/INCONCLUSIVE per row)
5. RTL changes landed (one row per Task 11 SUCCESS commit, with measured delta)
6. RTL changes attempted+reverted (one row per Task 11 REVERT commit, with refute evidence)

- [ ] **Step 2: Write the refreshed sign-off doc**

Same structure as `doc/4wide_signoff_2026-04-30.md` but with:
- Updated measurement table (real numbers, not the inflated 6.05 from the cm bug era)
- Updated verdict (SUCCESS if both at floor; PARTIAL with explicit gap if not)
- Reference to the gap-closure work (this plan's results doc)
- Supersedes-pointer back to the 04-30 doc

- [ ] **Step 3: Commit both docs**

```bash
git add doc/4wide_perf_gap_results_<final-date>.md doc/4wide_signoff_<final-date>.md
git -c user.email="jeremycai@local" -c user.name="Jeremy Cai" commit -m \
  "doc: 4-wide perf gap closure results + refreshed sign-off

Companion to doc/4wide_perf_gap_analysis_2026-05-01.md (methodology) and
doc/4wide_perf_gap_plan_2026-05-01.md (executable plan).

Supersedes: doc/4wide_signoff_2026-04-30.md (numbers stale due to cm bug
inflation; resolved at cd54cf1).

Final measurements: cm iter1=X.XX CM/MHz, cm iter10=X.XX, dhry=X.XX DMIPS/MHz."
```

---

## Constraints (apply throughout)

1. **Auto-mode standing rule**: when this plan completes, `superpowers:subagent-driven-development` is invoked automatically. No prompt.
2. **DSim license is single-seat**; sequential runs only; ~30–90s lease release between runs. If a run fails with `License not obtained`, wait 60s and retry.
3. **`export LD_LIBRARY_PATH=`** (empty) before any `bash build_dsim.sh` / `bash run_dsim.sh` / `bash scripts/regress_dsim.sh` to work around `shell_activate.bash`'s `set -u`.
4. **LSU iter=10 misalign-hold patch in `src/rtl/core/lsu/lsu.sv` is NEVER modified.** Sign-off-class IPC win for cm iter=10. If a Task 11 iteration touches lsu.sv, explicitly verify the misalign-hold logic is not affected.
5. **Pre-existing housekeeping (~30 files)** — `.gitignore`, `Makefile`, `build_dsim.bat`, deleted `*.log` files — must NOT be committed. Use `git add <specific-files>`, never `git add -A`.
6. **Sign-off floor:** CM/MHz ≥ 6.2, DMIPS/MHz ≥ 4.00 (Reference Core A (large config) 4-wide).
7. **Stretch:** CM/MHz ≥ 8.24, DMIPS/MHz ≥ 4.72 (a commercial 3-wide OoO core). Desired-not-blocking.
8. **Each Task 11 RTL change gets its own commit** with predicted IPC delta in commit message. No bundling.
9. **No CDB widening as a bandage.** If a hypothesis points at CDB bandwidth, the RTL change must be a targeted narrowing-preserving fix (e.g., smarter arbitration, additional bypass slot) NOT `CDB_WIDTH=6`. The 4-wide design must remain 4-wide on writeback.
10. **No reactivation of `../rv64gc-perf-model/`** — paused on toolchain dead-end. Only `rtl_clockcheck.py` is in active use.

---

## Self-Review Checklist (run by writer before handing off to executor)

- [x] Spec coverage: every phase A/B/C/D in the design doc has at least one task
- [x] Placeholder scan: no TBD/TODO/"add error handling"/"similar to Task N"
- [x] Type consistency: counter names match between Task 2/3 declarations and Task 5 inventory groupings
- [x] Phase A.2 scope corrected after pre-plan inventory (head-stall already exposed; only "other" decomp + issue-stall added)
- [x] Phase D RTL iteration template (Task 11) is self-contained — re-instantiable per hypothesis without re-reading earlier tasks
- [x] Constraints section captures all standing rules (auto mode, DSim license, LD_LIBRARY_PATH, lsu.sv freeze, housekeeping, sign-off bar, no-CDB-widen, no-perf-model)

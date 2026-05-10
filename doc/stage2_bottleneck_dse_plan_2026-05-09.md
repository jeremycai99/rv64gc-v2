# Stage 2 Bottleneck DSE Plan

Date: May 9, 2026

Status: planning document. This is the execution plan for deeper DSE after the
short-ALU/IQ0 chaining audit. It is not a performance claim and does not
promote any RTL change.

## Purpose

The next optimization loop must move from short local policy variants to
counter-ranked architectural work. The goal is to choose one structural
mechanism at a time, predict which counters it should move, run with strict
checks, and reject the mechanism if the expected counter movement or broad
cycle improvement does not materialize.

The promotion bar for a new Stage 2 mechanism is:

- Plausible 3-5 percent broad performance upside before implementation.
- Endpoint-clean strict smoke before any longer run.
- Full 16-row signoff coverage before promotion.
- No unexplained benchmark regression.
- No benchmark-PC steering, loop-buffer revival, scalar threshold chasing, or
  local IQ0/short-ALU op-list tuning.

## Current Evidence Snapshot

Baseline comparison rows:

- Accepted baseline artifact:
  `benchmark_results/signoff_signoff_20260508_loop_bypass_threshold2_goal`.
- Full bottleneck artifacts:
  `benchmark_results/dse_alu_chain_shape_profile_smoke_r2_20260509`,
  `benchmark_results/dse_alu_chain_shape_profile_coremark10_20260509`, and
  `benchmark_results/dse_dse_branch_recovery_checker_hardening_smoke_20260509`.
- Short-chain audit artifact set:
  `benchmark_results/20260509_iq0_*`.

Executed full profiled baseline, May 9, 2026:

- Rebuilt DSim from the current committed RTL before the run.
- Artifact: `benchmark_results/stage2_bottleneck_baseline_20260509`.
- Goal audit: `GOAL_PASS`, `stage1`, `signoff`, `16/16`.
- All rows passed endpoint gates with legacy loop buffer and standalone
  decoded-op replay activity at zero.
- `tools/bottleneck_analysis.py` was updated after this run to surface the
  existing FTQ/IBuffer runahead attribution counters in ranked output.
- Expanded rank report:
  `benchmark_results/stage2_bottleneck_baseline_20260509/bottleneck_rank.md`.

Cycle-level frontend/backend pressure from the accepted signoff baseline:

| Row | Cycles | Main cycle counters | Interpretation |
|---|---:|---|---|
| Dhrystone 100 | `18,577` | `packet_empty=745`, `packet_empty_f2_data=526`, `redirect_recovery=81` | Frontend cycle pressure is small; later bottleneck profile shows Dhrystone has load and same-cycle wakeup sensitivity. |
| CoreMark 1 | `163,013` | `packet_empty=11,242`, `packet_empty_f2_data=6,653`, `packet_empty_noemit_dup=3,569`, `redirect_recovery=4,052`, `xs_backend_stall_pkt_ready=3,595` | Mixed frontend, redirect, and backend drain pressure. |
| CoreMark 10 | `1,500,110` | `packet_empty=91,909`, `packet_empty_f2_data=60,845`, `packet_empty_noemit_dup=32,151`, `redirect_recovery=29,575`, `xs_backend_stall_pkt_ready=34,950` | Largest scoreable anchor. Several 2-6 percent cycle buckets remain, but they overlap through control and packet delivery behavior. |
| Frontend mixed branch dense | `7,220` | `packet_empty=433`, `redirect_recovery=426` | Branch-recovery dominated, small absolute row. |
| Backend ALU chain 8 | `3,039` | `packet_empty=7`, `redirect_recovery=2` | Current baseline is near saturated; this is mostly a regression guard. |
| Branch hotspot | `141,326` | `packet_empty=39,804`, `packet_empty_f2_data=31,408`, `packet_empty_noemit_dup=21,794`, `redirect_recovery=8,331` | Frontend and branch-owner pressure dominate, with very low decode-supply rate. |

Entry-slot pressure from `+BOTTLENECK_PROFILE`:

| Row | Dominant actionable counter | Evidence |
|---|---|---|
| Dhrystone 100 | `xs_bottleneck_dep_wait_on_load=17,175` | Dhrystone is not primarily an ALU-chain row; load-use and store-forward paths need attribution before a Dhrystone-targeted backend change. |
| CoreMark 1 | `xs_bottleneck_dep_wait_on_alu=1,370,358` | ALU dependency-chain pressure dominates entry slots; most producers are not yet issued and are themselves operand-blocked. |
| CoreMark 10 | `xs_bottleneck_dep_wait_on_alu=13,495,221` | Same CoreMark shape as iter1. The leading sub-bucket is blocked not-yet-issued ALU producers with ALU-produced operands. |
| Frontend mixed branch dense | `xs_bottleneck_dep_wait_on_alu=16,558` | ALU pressure exists, but `redirect_recovery=426` almost equals `packet_empty=433`, so control recovery is the cycle-level limiter. |
| Branch hotspot | `xs_bottleneck_iq0_enq_ready_hidden=78,752` | Ready-enqueue visibility, commit-zero, frontend-zero, packet-empty, duplicate/no-emit, and redirect counters all contribute; this row is not a pure ALU-chain workload. |

Full-run runahead attribution highlights:

| Row | Key runahead counters | Implication |
|---|---|---|
| CoreMark 10 | `xs_runahead_req_valid=90,954`, `xs_runahead_req_fire=90,954`, `xs_runahead_dup_alloc_block=89,972`, `xs_runahead_pending_cycles=126,997`, `xs_data_present_no_emit=83,016`, `xs_data_no_emit_dup=41,286`, `xs_data_no_emit_redirect=30,052` | There is real IFU runahead opportunity, but duplicate allocation and no-emit ownership policy prevent those requests from translating into useful decode supply. |
| CoreMark 10 | `xs_same_owner_candidate=389,324`, `xs_same_owner_advanced=341,599`, `xs_same_owner_block_rem=34,907` | Same-owner advancement is active, but remainder handling still blocks a material fraction of otherwise useful same-owner work. |
| Branch hotspot | `xs_data_present_no_emit=30,172`, `xs_data_no_emit_dup=23,635`, `xs_dup_no_same_owner=23,635`, `xs_dup_no_owner_control=23,635`, `xs_dup_no_owner_straddle=23,635` | The hotspot is a control/straddle owner problem. Removing duplicate suppression locally is not safe; the fix must be owner-aware buffering and delivery. |
| Backend independent quad | `packet_empty=2,014`, `packet_empty_f2_data=2,003`, `xs_data_no_emit_dup=1,002` | Even a backend-width guard row exposes frontend duplicate/data-present no-emit pressure, so the issue is not CoreMark-specific. |

Direction selection update from this full baseline:

- Branch recovery remains important, but pure redirect recovery is not the
  broadest first lever. CoreMark 10 redirect recovery is `29,575` cycles, while
  packet-empty is `91,909` cycles and data-present no-emit is `83,016` cycles.
- Local IQ0/short-ALU work remains quarantined. It targets a real entry-slot
  pressure counter, but the measured clean variant was only about 1 percent and
  neighboring variants regressed branch rows.
- The next implementation branch is therefore Branch B, true FTQ/IBuffer
  runahead attribution and then owner-aware buffering. This is the best match
  to the current cycle-level evidence and is a recognizable architectural
  direction rather than benchmark tuning.

B0 depth-profile instrumentation result, May 9, 2026:

- Instrumentation commit: `2a7ba3a Add FTQ runahead depth profiling`.
- T1 artifact: `benchmark_results/stage2_ftq_depth_profile_t1_20260509`.
- T2 artifact: `benchmark_results/stage2_ftq_depth_profile_t2_20260509`.
- Both T1 and T2 passed strict owner, delivery, and branch-recovery checks.
- Cycles matched the locked baseline exactly, so the instrumentation is
  performance-neutral evidence.

| Row | Cycles | `alloc2ifu max` | `ifu2wb max` | `ifu2commit max` | `ifu2commit 2-3 cyc` | Main implication |
|---|---:|---:|---:|---:|---:|---|
| Dhrystone 100 | `18,577` | `0` | `2` | `3` | `6,537` | Demand allocation is not running ahead of IFU, but owners remain live after IFU delivery. |
| CoreMark 1 | `163,013` | `0` | `2` | `9` | `48,488` | Owner state can be many entries ahead of commit even though IFU allocation depth is zero. |
| CoreMark 10 | `1,500,110` | `0` | `2` | `9` | `450,207` | The main score row has sustained post-IFU owner depth plus duplicate/no-emit pressure. |
| Frontend mixed branch dense | `7,220` | `0` | `1` | `2` | `373` | This row is still redirect dominated, so it remains a Branch A guard. |
| Backend ALU chain 8 | `3,039` | `0` | `2` | `3` | `2,010` | Even a backend guard accumulates post-IFU owner depth without pre-IFU runahead. |
| Branch hotspot | `141,326` | `0` | `1` | `3` | `64,771` | Control/straddle owner hold is persistent; local duplicate removal would be unsafe. |

The depth profile recalibrates Branch B:

- The missing runahead is not simply an empty FTQ allocation window. The
  `alloc2ifu` path stays at zero in all T2 rows.
- The live opportunity sits after IFU consumption: `ifu2wb` and especially
  `ifu2commit` show sustained depth while packet delivery still bubbles.
- Therefore B1 should not start by adding a XiangShan-style `pfPtr`. The next
  structural candidate is owner-aware delivery buffering and FTQ writeback or
  commit decoupling, with additional counters that explain why post-IFU owners
  do not produce decode packets.

Important interpretation rule:

- Entry-slot counters can exceed 100 percent of timed cycles because several IQ
  entries can wait in the same cycle. They rank pressure but do not directly
  predict cycle improvement.
- Cycle counters such as `packet_empty`, `redirect_recovery`,
  `xs_backend_stall_pkt_ready`, `xs_bottleneck_rob_commit_zero_cycles`, and
  latency histograms bound the possible cycle payoff.
- Every DSE branch must include both views: pressure counter movement and
  cycle-level movement.

## Ground Rules

1. Lock the baseline before DSE.
   - `git status --short` must be clean before any run that will be cited.
   - Rebuild DSim or XSim after RTL changes.
   - Commit after each validated slice, including instrumentation-only slices.

2. Run data first.
   - Do not implement RTL from a hunch.
   - Run `+BOTTLENECK_PROFILE` on the current baseline, rank counters, and
     identify which rows share the same root cause.

3. One mechanism per branch.
   - A DSE branch may add instrumentation first.
   - A behavior branch should target one structural mechanism and one primary
     counter family.
   - Do not combine branch recovery, packet scheduling, and scheduler changes
     in one trial.

4. Predict before measuring.
   - Each non-default mechanism run must declare `--targets-counter` and
     `--expect-counter-decrease`.
   - The predicted counter reduction should be large enough to justify at
     least a 3-5 percent cycle upside on the affected row group.

5. Reject cleanly.
   - Endpoint failure, strict checker failure, stale owner mismatch, branch
     recovery invariant violation, checksum drift, or timeout rejects the row.
   - A regression on any guard row quarantines the candidate unless the
     mechanism has a documented fix path and the regression is explained by
     counters.
   - Marginal cycle movement below 1 percent is evidence only, not promotion.

## Baseline Run Plan

### Step 0: Clean And Rebuild

Run before the full DSE baseline:

```bash
git status --short
./build_dsim.sh
```

If DSim has a license conflict, use XSim:

```bash
./build_xsim.sh
```

### Step 1: Full Profiled Baseline

Run the full Stage 1 manifest as the Stage 2 bottleneck baseline. This is not
a new signoff target; it is the current clean baseline with deeper counters.

```bash
python3 tools/run_benchmarks.py \
  --runner dsim \
  --manifest tests/benchmarks/stage1_signoff.json \
  --run-class signoff \
  --goal stage1 \
  --mechanism-class default_rtl \
  --run-id stage2_bottleneck_baseline_20260509 \
  --run-dir benchmark_results/stage2_bottleneck_baseline_20260509 \
  --plusarg +FETCH_DELIVERY_CHECK \
  --plusarg +FETCH_DELIVERY_STRICT \
  --plusarg +FETCH_OWNER_CHECK \
  --plusarg +FETCH_OWNER_STRICT \
  --plusarg +BRANCH_RECOVERY_CHECK \
  --plusarg +BRANCH_RECOVERY_STRICT \
  --plusarg +PERF_PROFILE \
  --plusarg +PERF_COUNTERS \
  --plusarg +STAT_DUMP \
  --plusarg +BOTTLENECK_PROFILE
```

XSim fallback:

```bash
python3 tools/run_benchmarks.py \
  --runner xsim-sh \
  --manifest tests/benchmarks/stage1_signoff.json \
  --run-class signoff \
  --goal stage1 \
  --mechanism-class default_rtl \
  --run-id stage2_bottleneck_baseline_xsim_20260509 \
  --run-dir benchmark_results/stage2_bottleneck_baseline_xsim_20260509 \
  --plusarg +FETCH_DELIVERY_CHECK \
  --plusarg +FETCH_DELIVERY_STRICT \
  --plusarg +FETCH_OWNER_CHECK \
  --plusarg +FETCH_OWNER_STRICT \
  --plusarg +BRANCH_RECOVERY_CHECK \
  --plusarg +BRANCH_RECOVERY_STRICT \
  --plusarg +PERF_PROFILE \
  --plusarg +PERF_COUNTERS \
  --plusarg +STAT_DUMP \
  --plusarg +BOTTLENECK_PROFILE
```

### Step 2: Generate Ranking Reports

```bash
python3 tools/bottleneck_analysis.py \
  benchmark_results/stage2_bottleneck_baseline_20260509/results.json \
  --top 40 \
  > benchmark_results/stage2_bottleneck_baseline_20260509/bottleneck_rank.md

python3 tools/audit_goal_runs.py > benchmark_results/stage2_bottleneck_baseline_20260509/goal_audit.txt
```

Required additions after the run:

- Add a short summary table to this plan with the top three actionable
  bottleneck families per row.
- Do not hand-pick only CoreMark and Dhrystone. Include all 16 rows so
  microbench and hotspot guard rows can expose regressions.

## DSE Selection Method

For every row, classify the top counters into these domains:

| Domain | Primary counters | Cycle-bound counters | Promotion requirement |
|---|---|---|---|
| Branch recovery and checkpoint | `redirect_recovery`, `xs_bottleneck_branch_mispredicts`, `xs_branch_recovery_*`, checkpoint save/restore counters | `packet_empty`, `fe_zero`, commit zero after redirect | Reduce recovery cycles or useful-work loss without branch/checkpoint invariant failures. |
| True FTQ/IBuffer runahead | `packet_empty_f2_data`, `packet_empty_noemit_dup`, `xs_dup_last_emit`, FTQ occupancy, IBuffer occupancy | `packet_empty`, decode supply rate, frontend-zero cycles | Increase useful packet delivery without packet-full, stale owner, duplicate, or backend-drain regression. |
| Scheduler/wakeup/select | `xs_bottleneck_dep_wait_on_alu`, producer-blocked counters, ready-hidden, arb-loss, wakeup missed | commit IPC, issue utilization, backend stall, guard-row cycles | Reduce producer-chain pressure across IQs, not only IQ0, with broad cycle movement. |
| Memory/load-use | `xs_bottleneck_dep_wait_on_load`, load latency buckets, store-forward wait, dcache-port wait, reissue counts | load-use stall cycles, commit-zero, Dhrystone cycles | Reduce load-use or store-forward pressure with replay correctness and no stale wakeups. |
| Commit/window/rename | `xs_bottleneck_rob_commit_zero_cycles`, head-block lost slots, rename slots lost, ROB/PRF/DQ stalls | cycle IPC, backend packet-ready stall | Improve sustained retirement or admission without hiding frontend/control regressions. |

Selection rule:

- Pick the direction that explains the most rows and has a clear cycle-bound
  payoff.
- Prefer directions that affect both CoreMark and at least one non-CoreMark
  guard row.
- If a high entry-slot counter has no cycle-bound path, add attribution first
  rather than implementing RTL.

## Branch A: Branch Recovery And Checkpoint Contract

Why this branch matters:

- CoreMark 10 has `redirect_recovery=29,575`.
- Branch hotspot has `redirect_recovery=8,331`, `packet_empty=39,804`, and high
  commit-zero pressure.
- Prior direct partial recovery was endpoint-clean only in limited form and
  regressed, so the issue is contract quality, not a missing scalar gate.

### A0: Complete Opportunity Attribution

Add or confirm counters for:

- Mispredicts by branch type: conditional, JAL, JALR, return.
- Mispredicts by ROB age bucket: head, near-head, middle, tail.
- Cycles from redirect to first valid fetch packet.
- Cycles from redirect to first decode packet.
- Number of younger ROB entries flushed per redirect.
- Number of ready younger entries flushed per redirect.
- Checkpoint live count histogram.
- Checkpoint save blocked because full.
- Save ignored because recovery had priority.
- Partial-recovery candidate count where backend could safely restore before
  head commit.

Exit criterion:

- The report can state whether non-head recovery has enough dynamic
  opportunity to move at least 3 percent on branch-heavy rows.

### A1: Backend-Only Recovery Contract Repair

Implement or harden only backend semantics first:

- Branch-ordered checkpoint ownership.
- RAT restore image at branch boundary.
- Free-list restore with same-cycle commit release ordering.
- ROB tail restore and younger-entry invalidation.
- Writeback filtering for recovered and younger entries.
- LSU cleanup for loads/stores younger than the recovery branch.
- No early frontend redirect yet.

Required strict checks:

- All `xs_branch_recovery_*` invariant counters remain zero.
- Fetch owner/delivery strict counters remain zero.
- Golden PC rows pass where golden streams exist.

Primary target counters:

- `redirect_recovery`
- `xs_bottleneck_fe_redirect_recovery`
- `xs_bottleneck_rob_commit_zero_cycles`

Promotion gate:

- Branch hotspot improves by at least 3 percent.
- CoreMark 1 and CoreMark 10 do not regress.
- Dhrystone 100 and backend/memory guard rows do not regress.

### A2: Selective Early Frontend Redirect

Only after A1 is endpoint-clean and non-regressing:

- Redirect frontend from the non-head branch owner.
- Restore BPU history and RAS from the same branch owner.
- Flush or retag FTQ, IFU, and IBuffer entries with a single owner rule.

Stop condition:

- Any stale packet owner, duplicate delivery, or checkpoint invariant violation.

## Branch B: True FTQ/IBuffer Runahead

Why this branch matters:

- CoreMark 10 has `packet_empty=91,909`, `packet_empty_f2_data=60,845`,
  `packet_empty_noemit_dup=32,151`, and `xs_backend_stall_pkt_ready=34,950`.
- Branch hotspot has `packet_empty=39,804`, `packet_empty_f2_data=31,408`, and
  `packet_empty_noemit_dup=21,794`.
- The current duplicate suppressor and single-packet buffering model are not a
  recognizable high-performance frontend contract.

### B0: Runahead Attribution Before RTL

Add or confirm counters for:

- FTQ allocated-to-IFU depth histogram. Completed in `2a7ba3a`.
- IFU-to-writeback and IFU-to-commit depth histograms. Completed in
  `2a7ba3a`.
- Cycles IFU cannot advance because owner metadata is tied to commit head.
- Cycles F2 has line data but no legal packet because of owner hold.
- Packet drops by reason: owner mismatch, epoch mismatch, duplicate guard,
  IBuffer full, predicted-control hold, straddle/remainder hold.
- IBuffer occupancy by packet class: control, predicted taken, fall-through,
  multi-instruction, single-instruction.
- Decode packet age histogram.

Exit criterion:

- The plan can estimate how many `packet_empty_f2_data` and
  `packet_empty_noemit_dup` cycles are removable by runahead rather than caused
  by downstream drain.
- The next missing attribution must split `xs_data_present_no_emit` and
  `packet_empty_f2_data` by the live FTQ state:
  alloc-to-IFU empty, IFU-to-writeback live, IFU-to-commit live, redirect hold,
  remainder hold, packet-ready hold, and IBuffer full.

### B1: Owner-Aware Delivery Decoupling

The T1/T2 depth profile shows `alloc2ifu` is already zero in the current
frontend, so simply splitting an allocation pointer is not the highest leverage
first behavior change. B1 should instead decouple packet delivery from
post-IFU owner lifetime while preserving the FTQ owner contract.

Behavior-neutral first slice:

- Keep existing allocation semantics.
- Keep existing IFU owner consumption semantics.
- Add assertion and profile state for post-IFU owners that still have pending
  packet delivery work.
- Preserve owner metadata until all required PCs for that owner are delivered.
- Keep strict owner and delivery checkers active.

Behavior slice candidate:

- Introduce a small owner-aware delivery queue in front of decode.
- Each entry carries FTQ index, owner epoch, start PC, packet valid mask, and
  predicted-control metadata.
- Allow IFU/F2 to enqueue a legal packet for an owner even when that owner
  remains live for writeback, training, or commit.
- Convert last-emitted-PC duplicate suppression from an active throttle into an
  assertion against duplicate delivery of the same owner/PC packet.

Primary target counters:

- `xs_data_present_no_emit`
- `xs_data_no_emit_dup`
- `xs_runahead_dup_alloc_block`
- `xs_ftq_ifu2commit_occ_hist_2to3`
- `packet_empty_f2_data`
- `packet_empty_noemit_dup`
- `xs_dup_last_emit`

Promotion gate:

- CoreMark 10 and branch hotspot packet-empty buckets drop without increasing
  `xs_packet_buf_full_cycles`, `xs_backend_stall_pkt_ready`, or redirect
  recovery.
- T2 must show broad reduction in data-present no-emit on CoreMark 1,
  CoreMark 10, backend ALU chain 8, and branch hotspot before a full 16-row
  run.

### B2: Full Owner-Aware IBuffer

Implement after B1:

- At least four packet entries.
- Each packet carries FTQ index, epoch, tag, start PC, valid mask, predicted
  control metadata, and delivery-complete state.
- Decode can drain independently from F2 owner advancement.
- Duplicate suppression becomes an assertion-only safety net, not a normal
  mechanism.

Primary target counters:

- `packet_empty_noemit_dup`
- `xs_dup_last_emit`
- `packet_empty_f2_data`
- decode bubble cycles from `bottleneck_analysis.py`

Promotion gate:

- Broad reduction in duplicate/no-emit and F2-data packet-empty buckets.
- No rise in packet-full or backend-packet-ready stalls.

### B3: Optional Prefetch Pointer

Do not start with `pfPtr`. Add it only if B1/B2 show that demand ownership is
clean and remaining `packet_empty_wait_icresp` or I-cache request stalls are
large enough.

## Branch C: Broader Scheduler/Wakeup/Select Redesign

Why this branch matters:

- CoreMark 10 shows `xs_bottleneck_dep_wait_on_alu=13,495,221`.
- The dominant sub-bucket is not-yet-issued ALU producers blocked on their own
  operands.
- Local IQ0 short-chain variants were too marginal and sometimes regressed
  branch rows.

### C0: Scheduler Criticality Attribution

Add or confirm counters for:

- Producer-chain depth histogram at issue.
- Oldest not-ready age by IQ and by producer FU class.
- Ready-hidden entries by IQ and by FU class.
- Issue port utilization per cycle.
- Select-lost cause: older priority, FU-class unavailable, operand not ready,
  branch-control conflict, load/store conflict.
- Cross-IQ producer/consumer pair histogram.
- Same-cycle wakeup candidate that would require a legal registered bypass
  rather than an ALU-to-IQ combinational path.

Exit criterion:

- Identify whether the scheduler problem is issue bandwidth, port steering,
  dependency-depth, or load/mul/branch producer latency.

### C1: Structural Scheduler Candidate Only

Allowed candidates:

- Cross-IQ age-aware select fairness that reduces starvation without changing
  branch timing locally.
- Cluster-level issue steering for simple integer work across IQs, not only
  IQ0 port1.
- A registered fast-lane wakeup token that changes next-cycle readiness
  broadly while keeping ALU outputs registered.
- Producer-criticality priority that helps long chains across workloads.

Rejected candidate class:

- Local IQ0 port0-to-port1 same-cycle op-list tuning.
- Threshold or priority tweaks that only move DS/CoreMark.

Primary target counters:

- `xs_bottleneck_dep_wait_on_alu`
- `xs_bottleneck_dep_alu_wait_not_issued_producer_blocked`
- `xs_bottleneck_iq*_not_ready_entry_sum`
- `xs_bottleneck_iq*_arb_loss`

Promotion gate:

- At least 3 percent CoreMark 10 improvement.
- No regression on branch dense, branch hotspot, Dhrystone 100, memory rows,
  and backend independent/ALU-chain guards.

## Branch D: Memory And Load-Use Pipeline

Why this branch matters:

- Dhrystone 100 bottleneck profile ranks `xs_bottleneck_dep_wait_on_load=17,175`
  above ALU dependency pressure.
- CoreMark 10 still has `xs_bottleneck_dep_wait_on_load=704,872`.
- Memory-sensitive rows are currently small, so broader workload expansion may
  make this branch more important.

### D0: Load-Use Attribution

Add or confirm counters for:

- Load issue-to-data latency histogram: 1, 2, 3, 4-7, 8-15, 16-31, 32+ cycles.
- Load-to-consumer wakeup delay histogram.
- Store-forward search wait and failure reason.
- D-cache port conflict and bank conflict if applicable.
- Load queue full or blocked by older store.
- Replay count by cause.
- Speculative load wakeup emitted, consumed, cancelled, and replayed.

Exit criterion:

- Decide whether the load branch is latency, store-forward, D-cache conflict,
  or queue pressure.

### D1: Candidate Classes

Allowed candidates:

- Store-forward path repair or latency reduction if store-forward wait is high.
- Speculative load wakeup with replay if load-use delay is high and cancellation
  is controlled.
- D-cache port/banking adjustment if port conflict is high across memory rows.

Rejected candidate class:

- Raw load speculation plusarg promotion without replay correctness.
- Memory row changes that improve Dhrystone but regress CoreMark or hotspots.

Primary target counters:

- `xs_bottleneck_dep_wait_on_load`
- `xs_bottleneck_lsu_load_latency_*`
- `xs_bottleneck_lsu_store_forward_wait`
- `xs_bottleneck_lsu_dcache_port_wait`

Promotion gate:

- Dhrystone improves without CoreMark regression.
- Memory generalization rows improve or stay neutral.
- No stale wakeup, wrong-path store, or replay endpoint drift.

## Branch E: Commit, Rename, And Window Pressure

Why this branch matters:

- CoreMark 10 has `xs_bottleneck_rob_commit_zero_cycles=217,897` in the
  bottleneck profile.
- Branch hotspot has `xs_bottleneck_rob_commit_zero_cycles=65,236` and high
  backend head-block pressure.
- Earlier raw capacity and blind backend admission probes were rejected, so this
  branch must be cause-specific.

### E0: Attribution

Add or confirm counters for:

- ROB head block cause: load, branch, ALU, multiply/divide, store, CSR, unknown.
- Ready younger commit slots hidden behind head block.
- ROB occupancy at head-block cycles.
- PRF free count and rename stall reason at head-block cycles.
- Dispatch queue occupancy and issue queue occupancy during commit-zero
  windows.
- Correlation between redirect recovery and commit-zero windows.

Exit criterion:

- Decide whether commit-zero is a branch recovery symptom, memory symptom,
  scheduler symptom, or actual commit/window design bottleneck.

Promotion gate:

- A candidate reduces commit-zero cycles and improves IPC without increasing
  frontend packet-empty or backend drain pressure.

## Run Matrix

| Tier | Scope | Purpose | Required plusargs | Promotion use |
|---|---|---|---|---|
| T0 compile | Build only | Catch syntax and simulator incompatibility. | N/A | Required after every RTL or file-list edit. |
| T1 strict smoke | Dhrystone 100, CoreMark 1 | Fast correctness and first counter check. | strict fetch owner/delivery, branch recovery strict, `+PERF_PROFILE +PERF_COUNTERS +STAT_DUMP +BOTTLENECK_PROFILE` | May keep debugging. Not scoreable. |
| T2 focused six-row | Dhrystone 100, CoreMark 1, CoreMark 10, branch dense, backend ALU chain, branch hotspot | Catch anchor, heavy, branch, backend, and hotspot regressions. | Same as T1 | Candidate can proceed to full coverage only if endpoint-clean and regression-free. |
| T3 full 16-row | Full `stage1_signoff.json` | Broad signoff guard. | Same as T1 plus `--goal stage1` | Required before promotion. |
| T4 competitor rescore | Calibrated MegaBOOM rows and stretch-target reporting | Re-score after a promoted structural mechanism. | Same methodology as baseline comparison docs | Reporting only after T3 passes. |

Example T1 command shape:

```bash
python3 tools/run_benchmarks.py \
  --runner dsim \
  --manifest tests/benchmarks/stage1_signoff.json \
  --run-class dse \
  --bench dhrystone_100_checkedin,coremark_iter1_generalization \
  --mechanism-class <class> \
  --mechanism-name <name> \
  --baseline-results benchmark_results/stage2_bottleneck_baseline_20260509/results.json \
  --targets-counter <counter> \
  --expect-counter-decrease <counter>:<delta> \
  --run-id <name>_smoke_YYYYMMDD \
  --run-dir benchmark_results/<name>_smoke_YYYYMMDD \
  --plusarg +FETCH_DELIVERY_CHECK \
  --plusarg +FETCH_DELIVERY_STRICT \
  --plusarg +FETCH_OWNER_CHECK \
  --plusarg +FETCH_OWNER_STRICT \
  --plusarg +BRANCH_RECOVERY_CHECK \
  --plusarg +BRANCH_RECOVERY_STRICT \
  --plusarg +PERF_PROFILE \
  --plusarg +PERF_COUNTERS \
  --plusarg +STAT_DUMP \
  --plusarg +BOTTLENECK_PROFILE
```

Example T3 command shape:

```bash
python3 tools/run_benchmarks.py \
  --runner dsim \
  --manifest tests/benchmarks/stage1_signoff.json \
  --run-class signoff \
  --goal stage1 \
  --mechanism-class <class> \
  --mechanism-name <name> \
  --baseline-results benchmark_results/stage2_bottleneck_baseline_20260509/results.json \
  --targets-counter <counter> \
  --expect-counter-decrease <counter>:<delta> \
  --run-id <name>_full_YYYYMMDD \
  --run-dir benchmark_results/<name>_full_YYYYMMDD \
  --plusarg +FETCH_DELIVERY_CHECK \
  --plusarg +FETCH_DELIVERY_STRICT \
  --plusarg +FETCH_OWNER_CHECK \
  --plusarg +FETCH_OWNER_STRICT \
  --plusarg +BRANCH_RECOVERY_CHECK \
  --plusarg +BRANCH_RECOVERY_STRICT \
  --plusarg +PERF_PROFILE \
  --plusarg +PERF_COUNTERS \
  --plusarg +STAT_DUMP \
  --plusarg +BOTTLENECK_PROFILE
```

## Scoring Rules

Use these labels for every branch:

| Label | Meaning |
|---|---|
| Accepted architectural candidate | Full 16-row pass, no unexplained regression, target counters moved as predicted, and broad cycle movement is at least 3 percent on the intended row group. |
| DSE-only evidence | Endpoint-clean and useful for understanding counters, but below impact threshold, incomplete coverage, or not yet structurally general. |
| Rejected due regression | Any checked row regresses without a counter-backed explanation and a planned structural fix. |
| Rejected due correctness | Timeout, checksum drift, strict checker failure, branch recovery invariant failure, stale owner, or golden PC mismatch. |
| Quarantined | Interesting but too close to benchmark-shaped policy, scalar tuning, or a previously rejected architecture. |

Regression thresholds:

- Any endpoint or strict-check failure is an immediate reject.
- Any anchor row regression above 0.5 percent requires an explanation before
  continuing.
- Any full 16-row regression above 1.0 percent rejects promotion unless the row
  is intentionally outside the mechanism and a follow-up repair is already
  identified.
- Micro rows with tiny absolute cycle counts require both percent and absolute
  review. Do not reject a structural mechanism solely because a 50-cycle row
  moves by one cycle, but do reject if the movement indicates an invariant or
  ownership drift.

## Expected Work Products

Each DSE branch should produce:

1. Baseline counter table from the full profiled baseline.
2. Hypothesis note with target counter, predicted delta, and expected cycle
   impact.
3. RTL or instrumentation commit.
4. T1 smoke artifact.
5. T2 six-row artifact.
6. T3 full 16-row artifact if T2 passes.
7. One doc update classifying the branch as accepted, DSE-only, rejected, or
   quarantined.

Do not leave uncommitted RTL across long runs. Commit either the validated
slice or a revert before starting the next long run.

## Recommended First Direction

Start with Branch B, true FTQ/IBuffer runahead, based on the full profiled
baseline. Branch A remains the second structural direction, but the current
cycle-level data says packet/data-present no-emit pressure is the broader first
lever than pure redirect recovery.

Reason:

- CoreMark 10 has `packet_empty=91,909`,
  `xs_data_present_no_emit=83,016`, and
  `xs_runahead_dup_alloc_block=89,972`, which are larger cycle-bound
  opportunities than `redirect_recovery=29,575`.
- The branch hotspot has `packet_empty=39,804` and
  `xs_data_no_emit_dup=23,635`, all tied to no-same-owner control/straddle
  context. That argues for owner-aware buffering, not duplicate-suppression
  tweaks.
- Backend independent quad also shows `packet_empty_f2_data=2,003` and
  duplicate no-emit pressure, so this is not isolated to CoreMark.
- It avoids continuing the local short-ALU/IQ0 path that has already shown
  marginal gains and nearby regressions.

Immediate next steps:

1. Keep `benchmark_results/stage2_bottleneck_baseline_20260509` as the locked
   comparison artifact.
2. Treat `stage2_ftq_depth_profile_t1_20260509` and
   `stage2_ftq_depth_profile_t2_20260509` as completed B0 instrumentation
   smoke evidence.
3. Add one more B0 profile slice only if needed: classify
   `xs_data_present_no_emit` and `packet_empty_f2_data` by post-IFU owner
   state, redirect hold, remainder hold, packet-ready hold, and IBuffer full.
4. Implement B1 as owner-aware delivery decoupling, not scalar duplicate
   suppression tuning and not `pfPtr`.
5. Run B1 with an explicit prediction before measurement:
   `--targets-counter xs_data_present_no_emit` and
   `--expect-counter-decrease xs_data_present_no_emit:<predicted_delta>`.
6. Promote B1 only if T2 shows a meaningful broad drop in data-present no-emit
   and packet-empty buckets without regression, then run the full 16-row signoff
   before considering B2.

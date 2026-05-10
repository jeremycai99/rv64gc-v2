# Stage 2 Dhrystone Backend DSE Plan

Date: May 10, 2026

Status: instrumentation baseline implemented. This document is the backend
Dhrystone/DMIPS pivot plan. It does not promote a behavior RTL optimization
yet.

## Current Run State

- No DSim or benchmark run is active.
- The unaccepted frontend fallthrough/remap DSE RTL was reverted before this
  pivot. The working tree was clean at `f9d4719` before the counter slice.
- XSim and DSim were rebuilt from the current tree after the counter changes.
- Strict T1 smoke passed with the new machine-readable backend counters:
  `benchmark_results/stage2_ds_backend_attr_t1b_20260510_005527`.
- Same-day four-row profile used for DS/CM ranking:
  `benchmark_results/stage2_ds_backend_attr_t2_20260510_004044`.
- A later four-row rerun with the expanded load-issue display was stopped
  because the profiling overhead made it too slow and the run had not reached a
  useful complete artifact. That partial output is not used.

## Pivot Rule

Pause fractional frontend score chasing. The next optimization loop targets
materially higher Dhrystone/DMIPS with CoreMark non-regression.

Dhrystone is only a scalar-latency diagnostic. It must not be optimized through
benchmark software changes, fixed PCs, string special cases, scalar threshold
chasing, loop-buffer revival, or benchmark-shaped policy.

## Fixed-Binary Score Baseline

| Row | Current metric | Current timed cycles | Stretch metric | Stretch timed cycles | Required timed-cycle reduction |
|---|---:|---:|---:|---:|---:|
| Dhrystone 100 | 3.133924 DMIPS/MHz | 18,161 | 4.0 DMIPS/MHz | about 14,229 | 3,932 cycles, 21.7% |
| Dhrystone 300 | 3.193357 DMIPS/MHz | 53,469 | 4.0 DMIPS/MHz | about 42,686 | 10,783 cycles, 20.2% |
| CoreMark 1 | 6.483697 CM/MHz | 154,233 | non-regression | 154,233 or better | no regression |
| CoreMark 10 | 6.705406 CM/MHz | 1,491,334 | non-regression | 1,491,334 or better | no regression |

The Dhrystone target is not reachable through another one-percent local tweak.
The first promoted backend mechanism should have a credible multi-percent DS
upside and must preserve CM1 and CM10.

## Instrumentation Status

Implemented in the simulation harness only:

- Load-produced operand waits split by consumer class.
- Load-produced operand lifecycle split: issue-same-cycle, not-issued,
  issued-not-writeback, stale-done, unknown.
- Branch consumers waiting on ALU/load/store/CSR/mul/div operands.
- Resident load-wakeup candidate, selected, and missed buckets.
- Load-woken enqueue visibility and hidden opportunity counters.
- ROB head not-ready cause surfaced from the core.
- Store-forward cause buckets: address missing, data missing, path busy,
  partial, spill hold, backlog, unknown.
- Machine-readable load issue candidate/fire/lost-slot/suppress counters.

Instrumentation validation:

| Run | Rows | Result |
|---|---|---|
| `stage2_ds_backend_attr_t1b_20260510_005527` | DS100, CM1 | PASS, cycle-identical to baseline |
| `build_xsim.sh` | full RTL/TB compile | PASS |
| `build_dsim.sh` | full RTL/TB compile | PASS |

The counter slice changes only `src/tb/tb_top.sv` and
`tools/bottleneck_analysis.py`. No synthesizable behavior RTL is changed.

## Ranked Bottleneck Report

Interpretation rule: entry-slot counters can exceed timed cycles because
multiple IQ entries can wait in one cycle. They rank pressure. Cycle counters
such as commit-zero, frontend-zero, packet-empty, redirect recovery, and load
issue no-fire bound direct cycle payoff.

| Row | Timed cycles | Mcycle | Load wait | ALU wait | Load enqueue hidden | Store-forward wait | Load issue total | Commit-zero | Frontend zero | Packet-empty | Redirect |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| DS100 | 18,161 | 18,577 | 17,175 | 11,462 | 599 | 1,103 | 11,381 | 1,104 | 827 | 745 | 81 |
| DS300 | 53,469 | 53,890 | 49,155 | 40,343 | 605 | 4,498 | 33,274 | 3,023 | 2,057 | 1,880 | 176 |
| CM1 | 154,233 | 163,013 | 71,901 | 1,370,358 | 9,329 | 569 | 60,859 | 28,301 | 15,393 | 11,242 | 4,052 |
| CM10 | 1,491,334 | 1,500,110 | 704,872 | 13,495,221 | 90,450 | 6,301 | 583,224 | 217,897 | 122,514 | 91,909 | 29,575 |

### DS Load-Use Shape

| Row | Load wait | BRU consumer | Store-data consumer | ALU consumer | Load-addr consumer | Store-addr consumer | Producer not issued | Producer issue same cycle |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| DS100 | 17,175 | 7,318 | 5,942 | 1,303 | 1,318 | 1,193 | 6,613 | 10,341 |
| DS300 | 49,155 | 24,319 | 14,039 | 5,697 | 3,302 | 1,498 | 15,879 | 30,525 |
| CM1 | 71,901 | 27,713 | 838 | 15,324 | 10,963 | 37 | 17,009 | 54,357 |
| CM10 | 704,872 | 274,576 | 1,977 | 143,209 | 108,928 | 166 | 172,221 | 529,182 |

DS is dominated by load-produced branch and store-data consumers. That points
to scalar loop control and memory-dependency timing, not a frontend-only issue.

### Load-Wakeup Selection Is Not The Main DS Limiter

| Row | Resident load-wakeup candidates | Selected | Missed | Miss cause |
|---|---:|---:|---:|---|
| DS100 | 900 | 801 | 99 | all port busy |
| DS300 | 1,808 | 1,808 | 0 | none |
| CM1 | 2,734 | 2,712 | 22 | all port busy |
| CM10 | 26,952 | 26,699 | 253 | all port busy |

The earlier broad `+IQ_READY_ENQ_BYPASS` probe confirmed that hidden enqueue
work exists, but it is not enough to unblock DS materially:

| Probe | DS100 mcycle | DS100 delta | CM1 mcycle | CM1 delta |
|---|---:|---:|---:|---:|
| Baseline | 18,577 | baseline | 163,013 | baseline |
| `+IQ_READY_ENQ_BYPASS` | 18,563 | -14 | 162,433 | -580 |

This is useful architectural evidence, but not a promoted performance
mechanism. The resident load-wakeup path is already mostly selecting legal work.

### Load-Store Dependency Timing Is The Stronger DS Lead

Load issue loss is strongly tied to store-order and same-cycle store-address
availability:

| Row | Load candidates | Load issues | Lost/suppressed slots | Store-order block | Same-cycle STA block |
|---|---:|---:|---:|---:|---:|
| DS100 | 13,690 | 11,381 | 2,309 | 2,002 | 1,993 |
| DS300 | 43,172 | 33,274 | 9,898 | 8,091 | 7,487 |
| CM1 | 61,950 | 60,859 | 1,091 | 655 | 621 |
| CM10 | 594,812 | 583,224 | 11,588 | 6,641 | 6,376 |

The `+ALLOW_LOAD_SPEC_PAST_STA` probe was cycle-identical to baseline because
the LSU raw forwarding/store-address wait still suppresses the load. That
rules out a superficial suppress-mask removal. A real mechanism needs a
general memory-dependence and store-forward contract: same-cycle store-address
visibility, correct store-data readiness, forwarding or replay safety, and no
wrong-path or stale-load behavior.

### CoreMark Guard

CoreMark remains dominated by ALU dependency pressure:

- CM1: `xs_bottleneck_dep_wait_on_alu=1,370,358`.
- CM10: `xs_bottleneck_dep_wait_on_alu=13,495,221`.

Any DS mechanism that increases CoreMark cycles should be rejected unless the
regression is explained and fixed. The DS path should first target
load-store/load-use timing without disturbing ALU scheduling.

## Proposed First Structural Mechanism

First candidate: LSU memory-dependence and store-forward timing repair.

This is a general OoO backend mechanism, not a Dhrystone shortcut. Loads that
are blocked only because an older store address or store data becomes known in
the same cycle should not lose an avoidable full cycle if the core can prove one
of these legal outcomes:

- no older unknown store can alias the load,
- an older matching store can forward complete data,
- the load can issue speculatively under an explicit replay/violation recovery
  contract.

The behavior slice should be staged:

1. Add a load-store dependency scoreboard view in the LSU or core wrapper that
   distinguishes older-store-address-unknown, older-store-data-unknown,
   forwardable-hit, non-alias, and replay-required cases.
2. Add same-cycle STA visibility to the load issue decision only when the
   address compare result is architecturally safe or covered by replay.
3. Add store-data readiness into the same contract so store-data consumers do
   not become a silent correctness hole.
4. Preserve strict checks and add stale-load or memory-order violation counters
   before any performance claim.

Expected counter movement for a valid candidate:

| Counter | DS100 expected movement | DS300 expected movement | CM expectation |
|---|---:|---:|---|
| load lost/suppressed slots | down 800-1,500 | down 3,000-5,000 | neutral or down |
| same-cycle STA block | materially down | materially down | neutral or down |
| `xs_bottleneck_dep_wait_on_load` | down 1,500-3,000 entry slots | down 5,000-9,000 entry slots | neutral or down |
| `xs_bottleneck_rob_head_not_ready_load` | down or neutral | down or neutral | no increase |
| replay or stale-load violation counters | zero or explained | zero or explained | zero |

Cycle target for the first promoted candidate:

- DS100 improves at least 3 percent versus fixed-binary baseline:
  `18,161 -> 17,616` timed cycles or better.
- DS300 improves in the same direction by at least 2 percent:
  `53,469 -> 52,400` timed cycles or better.
- CM1 and CM10 are cycle-neutral or faster.
- A stronger candidate should aim for DS100 under 17,000 timed cycles before a
  full signoff run. The 4.0 DMIPS/MHz target still needs about 14,229 timed
  cycles, so more than one structural mechanism is likely required.

## Alternative Directions And Order

| Priority | Direction | Why it is in scope | Why it is not first |
|---:|---|---|---|
| 1 | LSU memory-dependence and store-forward timing | Strong DS lost-load evidence, especially same-cycle STA blocking. General OoO mechanism. | First. |
| 2 | Load-use wakeup and critical-consumer select | Load wait is large and general. | Resident load-wakeup selection is already near perfect; enqueue bypass evidence was marginal. |
| 3 | Scheduler ready-at-enqueue visibility | Large across DS and CM. | Prior broad bypass DSE was marginal; needs a narrower causality contract. |
| 4 | ALU-to-branch short-chain scheduling | Branch consumers waiting on load and ALU are visible. | Current CoreMark risk is high because ALU dependency dominates CM. |
| 5 | ROB head/commit drain repair | Commit-zero exists on DS and larger on CM. | Likely downstream symptom until load/store and ALU producers improve. |
| 6 | Frontend owner/fallthrough continuation | Still relevant for CoreMark and hotspot rows. | DS frontend empty is too small and recent frontend DSE regressed CM10. |

## Non-Regression Gate

Every DS-focused RTL candidate must run with strict owner, delivery, branch
recovery, perf profile, perf counters, and stat dump enabled:

`+FETCH_DELIVERY_CHECK +FETCH_DELIVERY_STRICT +FETCH_OWNER_CHECK +FETCH_OWNER_STRICT +BRANCH_RECOVERY_CHECK +BRANCH_RECOVERY_STRICT +PERF_PROFILE +PERF_COUNTERS +STAT_DUMP +BOTTLENECK_PROFILE`

### T0: Instrumentation Compile

- Build DSim from the current tree.
- XSim compile is acceptable as a syntax fallback, but XSim CM10 is too slow to
  be the full performance gate.
- Instrumentation-only changes must be cycle-identical on DS100 and CM1 before
  they are committed.

### T1: DS Smoke

Rows:

- `dhrystone_100_checkedin`
- `coremark_iter1_generalization`

Promotion from T1 requires:

- DS100 faster by at least 1 percent for a behavior candidate.
- CM1 cycle-neutral or faster.
- All invariant, stale, cancel, and memory-order counters clean.

### T2: Four-Row Pivot Gate

Rows:

- `dhrystone_100_checkedin`
- `dhrystone_300_stage1_anchor`
- `coremark_iter1_generalization`
- `coremark_iter10_checkedin`

Promotion from T2 requires:

- DS100 faster by at least 3 percent.
- DS300 faster by at least 2 percent and same direction as DS100.
- CM1 and CM10 cycle-neutral or faster versus fixed-binary baseline.
- Primary counters move as predicted, especially load issue suppression,
  same-cycle STA block, load-wait, and ROB-head-load block.

### T3: Broader Guard Gate

Rows:

- T2 rows
- `frontend_mixed_branch_dense`
- `backend_alu_chain_8`
- `hotspot_state_crc_branch`
- `hotspot_string_retire`
- `hotspot_matrix_store`
- `memory_array_c`

Promotion from T3 requires:

- No endpoint failures.
- No CoreMark regression.
- No unexplained guard-row regression.
- No increase in load reissue, stale wakeup, wrong-path issue, owner violation,
  branch recovery violation, memory-order violation, or replay storm counters.

### T4: Full Signoff

Run the full Stage 1 or Stage 2 signoff matrix after T3 passes. A candidate is
not accepted until this run is clean and committed.

## Execution Plan

1. Commit the instrumentation-only counter baseline after T0/T1 validation.
2. Inspect LSU/store queue interfaces for the smallest safe way to expose
   same-cycle older-store address/data readiness to load issue.
3. Add memory-order/replay safety counters before changing behavior.
4. Implement one behavior slice for same-cycle STA/load issue timing. Do not
   mix it with frontend policy, ALU chaining, or generic scheduler bypass.
5. Run T1 and reject immediately if CM1 regresses or memory-order counters move.
6. Run T2 and require DS100 at least 3 percent faster, DS300 same direction at
   least 2 percent faster, and CM1/CM10 non-regression.
7. Run T3 and full signoff only after T2 passes with the predicted counter
   movement.
8. If the LSU slice is rejected, pivot to the second direction:
   load-use critical-consumer select with a narrower causality contract.

## Current Verdict

The DS bottleneck is not the current frontend fallthrough path and not generic
resident load-wakeup selection. The current best evidence points to LSU
memory-dependence timing:

- DS load wait is dominated by branch and store-data consumers.
- Resident load-woken entries are mostly selected when legal.
- DS load issue loses thousands of slots to store-order and same-cycle
  store-address blocking.
- A naive load-past-STA suppress-mask probe has no effect, so the real fix must
  be in the LSU memory-dependence, store-forward, and replay contract.

No behavior RTL is accepted yet. The next promoted optimization must be a
general memory-dependence mechanism with DS100/DS300 material improvement and
CM1/CM10 non-regression.

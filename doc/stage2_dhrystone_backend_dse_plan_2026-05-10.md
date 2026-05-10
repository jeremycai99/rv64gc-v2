# Stage 2 Dhrystone Backend DSE Plan

Date: May 10, 2026

Status: instrumentation baseline implemented and first LSU speculation DSE
audited. This document is the backend Dhrystone/DMIPS pivot plan. It does not
promote a behavior RTL optimization yet.

## Current Run State

- No DSim or benchmark run is active.
- The unaccepted frontend fallthrough/remap DSE RTL was reverted before this
  pivot. The working tree was clean at `f9d4719` before the counter slice.
- XSim and DSim were rebuilt from the current tree after the counter changes.
- Strict T1 smoke passed with the new machine-readable backend counters:
  `benchmark_results/stage2_ds_backend_attr_t1b_20260510_005527`.
- Same-day four-row profile used for DS/CM ranking:
  `benchmark_results/stage2_ds_backend_attr_t2_20260510_004044`.
- Additional LSU reason-split counters were added and revalidated as
  behavior-neutral:
  `benchmark_results/stage2_ds_lsu_reason_counters_t1_20260510_104034`.
- Rejected LSU behavior probes are kept as DSE evidence only:
  - unconditional unresolved-store speculation:
    `stage2_ds_lsu_spec_m1_t1_20260510_100945`,
  - replay-trained memory-dependence prediction:
    `stage2_ds_lsu_memdep_m1_t1_20260510_101458`,
    `stage2_ds_lsu_memdep_t2_ds300_20260510_102919`,
    `stage2_ds_lsu_memdep_t2_cm10_20260510_103007`,
  - p1 same-cycle forward probe:
    `stage2_ds_lsu_memdep_p1fwd_t2_20260510_102019`.
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
- Store queue reason outputs for address-unknown versus data-missing wait,
  consumed only by unchanged LSU gating and the simulation harness.
- Replay-safety counters for speculative unresolved-store loads, currently
  expected to remain zero in the committed baseline.
- Machine-readable load issue candidate/fire/lost-slot/suppress counters.

Instrumentation validation:

| Run | Rows | Result |
|---|---|---|
| `stage2_ds_backend_attr_t1b_20260510_005527` | DS100, CM1 | PASS, cycle-identical to baseline |
| `stage2_ds_lsu_reason_counters_t1_20260510_104034` | DS100, CM1 | PASS, cycle-identical to baseline, exact SQ address/data wait reasons populated |
| `build_xsim.sh` | full RTL/TB compile | PASS |
| `build_dsim.sh` | full RTL/TB compile | PASS |

The counter slice changes `store_queue.sv` and `lsu.sv` to expose reason
signals, `tb_top.sv` to count them, and `tools/bottleneck_analysis.py` to
classify them. The committed LSU gating remains behavior-equivalent to the
baseline.

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

### LSU Timing Root Cause

The current root cause is a conservative load/store ordering contract, not a
D-cache hit latency problem.

RTL chain:

- The load IQ selects ready loads and exposes both candidate and final issue
  ports. A selected load is removed only if `issue_suppress[p]` is low.
- `rv64gc_core_top.sv` ORs two suppression sources into the load IQ:
  LSU-local suppression plus `store_iq_older_than_load`.
- `store_iq_older_than_load` is generated by the STA issue queue's
  `has_older_entry` probe. It only knows that some older store address uop is
  still resident and not selected this cycle; it cannot prove alias or
  non-alias.
- In parallel, the store queue has reserved entries from rename. Before STA
  fills an entry, that SQ entry is valid but address-unknown. The SQ forwarding
  CAM treats any older address-unknown store as a load wait for currently
  uncovered bytes.
- Therefore `+ALLOW_LOAD_SPEC_PAST_STA` removes only the outer STA-IQ guard.
  The same load candidates are still blocked by the SQ CAM's
  `sq_fwd_wait`/`sq_wait_p1` path. This explains the cycle-identical probe.

Measured DS evidence:

| Row | Load issue lost slots | P0 SQ wait | P1 SQ wait | Store-IQ proxy block | Same-cycle STA proxy | Load latency 1-cycle hits |
|---|---:|---:|---:|---:|---:|---:|
| DS100 | 2,309 | 1,103 | 1,099 | 2,002 | 1,993 | 11,086 |
| DS300 | 9,898 | 4,498 | 4,194 | 8,091 | 7,487 | 30,986 |

Interpretation:

- The lost-load slots are nearly covered by `sq_fwd_wait + sq_wait_p1`, so
  the blocker is inside the LSU/store queue, not only in the external STA-IQ
  guard.
- Most loads that do issue return in one cycle. The opportunity is issuing
  eligible loads earlier, not shortening D-cache hit latency.
- The "same-cycle STA" bucket should be read as a proxy for store-address
  backlog pressure. It does not prove the STA issued in that same cycle is
  always the exact aliasing blocker, because the STA IQ can still contain other
  older unresolved stores.
- DS load-produced consumers are mainly branches and store data. When a load
  waits behind unresolved older stores, loop-control and store-data chains both
  lose cycles.

Concrete architectural gap:

The core has precise replay machinery for memory-order violations, but the
load issue policy does not use it to speculate past unresolved older stores.
It waits until older store addresses/data are known enough for the SQ CAM to
prove no wait or to forward. Higher-performance OoO designs typically reduce
this loss with a load-store dependence predictor, store-set style predictor, or
replay-backed speculative load issue guarded by violation detection.

### M1 DSE Outcome: Do Not Promote

The first unresolved-store speculation attempts did not meet the DS signoff
gate.

| Probe | DS100 timed cycles | DS300 timed cycles | CM1 timed cycles | CM10 timed cycles | Verdict |
|---|---:|---:|---:|---:|---|
| Fixed baseline | 18,161 | 53,469 | 154,233 | 1,491,334 | reference |
| Unconditional unresolved-store speculation | 20,123 | not run | 157,061 | not run | rejected, replay storm |
| Replay-trained memory-dependence predictor | 18,163 | 53,468 | 153,872 | 1,493,709 | rejected, DS flat and CM10 regresses |
| p1 same-cycle forward probe | not promoted | ITERLIMIT | not promoted | 1,493,709 | rejected, simulator convergence failure |

Counter evidence:

- Unconditional speculation exposed the correctness cost: DS100 issued `1,505`
  speculative unresolved-store loads and replayed `200`; CM1 issued `575` and
  replayed `191`. Replay recovery erased any load-issue gain.
- The replay-trained predictor reduced replay pressure to DS100 `4` and CM1
  `1`, but it also blocked many of the same loads later and left DS cycles
  essentially unchanged. CM10 regressed by about `2,375` timed cycles.
- The p1 same-cycle forward probe produced no T1 score movement and triggered
  a DSim timestep iteration-limit failure on DS300. It is quarantined, not a
  candidate.

Conclusion:

- The new SQ reason counters prove most DS store-order loss is
  address-unknown rather than data-missing: DS100 p0/p1 address-unknown
  waits are `903/1099`, while data-missing waits are `200/0`.
- Removing unresolved-store suppression does not move DS materially once replay
  cost and downstream consumers are included.
- M1 unresolved-store speculation is not the next promoted direction.
- The next DS signoff attempt should target load-produced critical consumers,
  especially branch and store-data consumers, because DS load wait remains
  dominated by those classes and the load issue slot reduction did not shorten
  the benchmark.

Secondary issues to keep separate:

- Port 1 same-line D-cache conflict is real but smaller for DS100
  (`310` conflict cycles) and should not be mixed into the first LSU ordering
  slice.
- Port 1 forwarded results use a hold path by default. That can be evaluated
  after the unresolved-store ordering bottleneck, but it is not the primary DS
  blocker.

### CoreMark Guard

CoreMark remains dominated by ALU dependency pressure:

- CM1: `xs_bottleneck_dep_wait_on_alu=1,370,358`.
- CM10: `xs_bottleneck_dep_wait_on_alu=13,495,221`.

Any DS mechanism that increases CoreMark cycles should be rejected unless the
regression is explained and fixed. The DS path should first target
load-store/load-use timing without disturbing ALU scheduling.

## Audited First Structural Mechanism

First candidate audited: LSU memory-dependence and store-forward timing repair.

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
| 1 | Load-use critical-consumer select for BRU and STD | DS load wait is dominated by branch and store-data consumers, and M1 showed load-issue suppression alone is not on the critical path. | First after M1 rejection. |
| 2 | LSU memory-dependence and store-forward timing | Strong lost-load evidence remains, and reason counters are now precise. | First speculative approach was rejected; revisit only with a stronger predictor and CM10 guard evidence. |
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

1. Commit the behavior-neutral LSU reason-counter baseline after T0/T1
   validation.
2. Treat unresolved-store speculation and p1 same-cycle forward as rejected DSE
   until a materially different mechanism is proposed.
3. Start the next behavior branch from load-produced critical consumers:
   load-to-branch and load-to-store-data scheduling/selection.
4. Add any missing counters before the behavior change, specifically selected
   load wakeup to BRU/STD, missed same-cycle BRU/STD wakeup, and ROB-head wait
   after a load-produced BRU/STD chain.
5. Run T1 and reject immediately if CM1 regresses or memory-order/replay
   counters move.
6. Run T2 and require DS100 at least 3 percent faster, DS300 same direction at
   least 2 percent faster, and CM1/CM10 non-regression.
7. Run T3 and full signoff only after T2 passes with the predicted counter
   movement.

## Signoff DS Design Breakdown

The DS signoff target is a sequence of architectural milestones, not one large
DSE patch. Each milestone must be committed independently after it passes its
gate. Do not merge stages just because an intermediate probe shows a good DS
number.

### Signoff Definition

Primary DS signoff target:

- DS100: `4.0 DMIPS/MHz`, about `14,229` timed cycles.
- DS300: same direction and close to `4.0 DMIPS/MHz`, about `42,686` timed
  cycles.
- CM1 and CM10: no timed-cycle regression versus the fixed-binary baseline.
- Broader guard rows: endpoint clean, no unexplained regression.

Near-term DS milestone targets:

| Milestone | DS100 timed-cycle target | DS300 timed-cycle target | Purpose |
|---|---:|---:|---|
| M0 baseline | 18,161 | 53,469 | current reference |
| M1 first LSU mechanism | 17,616 or better | 52,400 or better | prove the memory-dependence direction |
| M2 combined LSU mechanism | under 17,000 | under 50,800 | meaningful DS latency reduction |
| M3 scheduler/load-use follow-up | under 16,000 | under 47,500 | move beyond LSU-only bound |
| M4 signoff stretch | about 14,229 | about 42,686 | final 4.0 DMIPS/MHz target |

### M0: Lock The Measurement Contract

Goal: make every later claim comparable.

Tasks:

- Keep DS100, DS300, CM1, and CM10 fixed-binary hashes locked.
- Keep the required strict plusargs unchanged.
- Preserve current instrumentation and avoid behavior RTL changes in the
  measurement harness.
- Add any missing counters as instrumentation-only commits before behavior
  work.

Exit criteria:

- XSim and DSim rebuild from the current tree.
- DS100 and CM1 smoke cycle-identical when instrumentation only changes.
- Results include load issue, SQ wait, replay, stale-load, ROB-head, and CM
  guard counters.

### M1: Replay-Safe Load Past Unresolved Store

Status: rejected as the next promoted direction by the May 10 DSE listed
above. Keep this section as the contract required if the direction is revisited
with a materially stronger predictor.

Goal: prove that conservative unresolved-store blocking is a real performance
limit and can be relaxed safely.

Mechanism:

- Add a replay-backed speculative load issue mode for loads blocked only by
  unresolved older store addresses.
- Track the speculative load in the load queue with enough metadata to detect a
  later older-store alias.
- On later STA alias, trigger the existing memory-order violation or replay
  path from the violating load's ROB index.
- Keep the initial policy conservative: allow speculation only when there is no
  known older matching store with missing data and no partial-forward hazard.

Required new counters before promotion:

- load candidates blocked by unresolved older store address.
- speculative load issued past unresolved store.
- speculative load later proved non-alias.
- speculative load replayed by later STA alias.
- speculative load killed by unrelated flush.
- replay storm cycles and maximum replay distance.

Expected movement:

- DS100 load issue lost slots down `800-1,500`.
- DS300 load issue lost slots down `3,000-5,000`.
- `sq_fwd_wait + sq_wait_p1` down materially.
- Memory-order violation/replay counters nonzero only when explained and
  bounded.

Gate:

- T1: DS100 at least 1 percent faster, CM1 non-regressing, no stale-load
  errors.
- T2: DS100 at least 3 percent faster and DS300 at least 2 percent faster,
  CM1/CM10 non-regressing.
- Reject if replay count is large enough to erase the gain or if CM regresses.

### M2: Same-Cycle STA Visibility And Forwarding

Goal: remove the avoidable one-cycle gap when the older store address becomes
known in the same cycle as the load candidate.

Mechanism:

- Feed same-cycle STA address compare into the load issue decision before the
  load is suppressed.
- If the same-cycle STA proves non-alias for all blocking older stores, allow
  the load to issue.
- If the same-cycle STA aliases and same-cycle STD data is complete and fully
  covers the load, forward safely.
- If alias is partial or data is missing, keep the load suppressed.

Required counters:

- same-cycle STA proves non-alias.
- same-cycle STA full forward.
- same-cycle STA partial/data-missing hold.
- same-cycle STA allowed load that later replayed.

Expected movement:

- `same-cycle STA proxy` bucket down materially.
- DS100 under `17,000` timed cycles if M1 and M2 both work.
- DS300 under `50,800` timed cycles.
- CM unchanged or slightly better.

Gate:

- T2 required before promotion.
- T3 required if replay count is nonzero.
- Reject if any stale load or memory-order violation is not recovered precisely.

### M3: Store-Data Consumer And Load-Use Follow-Up

Goal: reduce the next DS bottleneck after load issue is less constrained.

Likely mechanisms:

- Store-data load-wakeup path: prioritize STD consumers that are woken by a
  load and unblock older stores.
- Branch load-use path: reduce load-to-branch scheduling latency only when the
  branch is a legal load-woken consumer.
- Narrow ready-at-enqueue visibility for load-woken BRU/STD consumers, not the
  old broad enqueue bypass.

Entry criteria:

- M1/M2 counters show load issue suppression is no longer the dominant DS
  blocker.
- The top remaining DS counters are load-produced BRU or STD consumer waits.

Expected movement:

- `xs_bottleneck_dep_load_consumer_bru` and
  `xs_bottleneck_dep_load_consumer_store_data` down.
- ROB-head-load block down or neutral.
- DS100 under `16,000` timed cycles.

Gate:

- CM1 and CM10 must not regress, because CoreMark is ALU-dependency dominated
  and should not be destabilized by branch/store-data policy.
- T3 guard rows required before promotion.

### M4: Port-1 And Dual-Load Cleanup

Goal: recover secondary load bandwidth only after memory-order correctness is
settled.

Potential mechanisms:

- Safe same-line dual-load policy for port 1.
- Port-1 forwarded result fast path without reviving the old combinational CDB
  loop.
- More precise port-1 retry arbitration if it still appears in the top DS
  counters.

Entry criteria:

- M1/M2/M3 are committed or explicitly rejected.
- Port-1 conflict or forward-hold counters are still top-ranked after the main
  ordering fix.

Gate:

- T2 must show DS gain without CM regression.
- Full strict smoke must show no CDB loop, stale wakeup, or load replay
  violation.

### M5: Final Signoff Run

Goal: accept the design for DS signoff only when the score and counters agree.

Run order:

1. T1 smoke after fresh rebuild.
2. T2 four-row pivot gate.
3. T3 broader guard gate.
4. Full Stage 2 signoff matrix.

Acceptance package:

- Final DS100/DS300/CM1/CM10 score table.
- Counter delta table versus M0 baseline.
- Replay and stale-load safety counters.
- Explanation of any guard-row movement.
- Commit hash of the accepted RTL.

Stop conditions:

- Any CM1 or CM10 regression that is not explained and fixed.
- Any endpoint failure.
- Any stale-load, wrong-path load writeback, unrecovered memory-order
  violation, replay storm, or owner/delivery violation.
- DS gain below the milestone threshold after T2.

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

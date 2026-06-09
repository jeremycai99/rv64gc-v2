# Stage 2 Bottleneck DSE Plan

Date: May 9, 2026

Status: planning document. This is the execution plan for deeper DSE after the
short-ALU/IQ0 chaining audit and the post-IFU no-emit attribution pass. It is
not a performance claim and does not promote any RTL change.

## May 10 Pivot

The active optimization loop is paused from fractional frontend score chasing
and redirected to Dhrystone/DMIPS backend latency improvement with CoreMark
non-regression. The frontend ownership/fallthrough evidence remains useful,
but it is not promoted as score progress while CM10 regression is unexplained.

Use `doc/stage2_dhrystone_backend_dse_plan_2026-05-10.md` as the current
execution plan for the next DSE loop. The first branch is load-use wakeup and
critical-consumer select attribution, then one structural backend behavior
slice if the counters confirm the timing loss.

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
- The next implementation branch must stay inside Branch B or Branch A, but
  Branch B cannot mean "add another FIFO" by default. The newer attribution
  shows that most data-present no-emit cycles happen with the existing packet
  buffer empty and owner state live. That points at an owner/control delivery
  contract, duplicate cursor recovery, or branch recovery contract issue rather
  than raw packet storage capacity.

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
- Therefore B1 should not start by adding a Reference Core B-style `pfPtr`. Before
  any behavior change, the next question is why post-IFU live owners do not
  produce legal decode packets.

B0b post-IFU no-emit attribution result, May 9, 2026:

- Instrumentation commit: `89a4b8b Add post-IFU no-emit attribution counters`.
- T1 artifact: `benchmark_results/stage2_noemit_attr_t1_20260509`.
- T2 artifact: `benchmark_results/stage2_noemit_attr_t2_20260509`.
- Both T1 and T2 passed strict owner, delivery, and branch-recovery checks.
- Cycles matched the locked baseline exactly, so the counters are
  performance-neutral evidence.

| Row | Data no-emit | Duplicate | Redirect | IBuffer empty | IBuffer nonempty | IBuffer full | Owner live | Main implication |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| Dhrystone 100 | `289` | `212` | `77` | `289` | `0` | `0` | `289` | Small frontend issue; all no-emit is live-owner and empty-buffer. |
| CoreMark 1 | `9,741` | `4,475` | `3,933` | `7,407` | `2,334` | `1,521` | `9,741` | Mostly empty-buffer live-owner no-emit, with a secondary packet-full component. |
| CoreMark 10 | `83,016` | `41,286` | `30,052` | `61,010` | `22,006` | `13,654` | `82,982` | The largest row has true owner/control no-emit plus some downstream fullness. |
| Frontend mixed branch dense | `425` | `0` | `425` | `425` | `0` | `0` | `425` | Pure redirect no-emit with empty packet buffer. |
| Backend ALU chain 8 | `2` | `0` | `2` | `2` | `0` | `0` | `2` | Not a frontend capacity row, but still validates the redirect accounting path. |
| Branch hotspot | `30,172` | `23,635` | `6,537` | `30,122` | `50` | `0` | `30,172` | Control/straddle owner no-emit, not packet storage capacity. |

Additional owner shape:

| Row | IFU-to-commit max | IFU-to-commit 2-3 cyc | IFU-to-commit 4-7 cyc | IFU-to-commit 8-15 cyc | Duplicate no-same-owner | Duplicate owner-control | Duplicate owner-straddle |
|---|---:|---:|---:|---:|---:|---:|---:|
| Dhrystone 100 | `3` | `6,537` | `0` | `0` | `109` | `4` | `109` |
| CoreMark 1 | `9` | `48,488` | `6,480` | `18` | `3,266` | `1,059` | `3,266` |
| CoreMark 10 | `9` | `450,207` | `61,878` | `289` | `29,898` | `8,968` | `29,864` |
| Frontend mixed branch dense | `2` | `373` | `0` | `0` | `0` | `0` | `0` |
| Backend ALU chain 8 | `3` | `2,010` | `0` | `0` | `0` | `0` | `0` |
| Branch hotspot | `3` | `64,771` | `0` | `0` | `23,635` | `23,635` | `23,635` |

This result changes the Branch B entry point:

- The existing `fetch_packet_buffer` is already a multi-entry owner-aware
  packet buffer. Its empty state dominates the no-emit cycles in the important
  rows, so a second generic delivery FIFO is not justified as the next
  behavior slice.
- `xs_data_no_emit_owner_live` nearly equals `xs_data_present_no_emit` on all
  rows. The bug or missed opportunity is in the owner/control delivery
  contract while a live post-IFU owner exists, not in FTQ allocation depth.
- CoreMark 10 has a real packet-full component, but branch hotspot and branch
  dense do not. Any capacity change must be treated as a secondary repair and
  must not be used to explain control-dominated rows.
- Branch hotspot duplicate no-emit is entirely no-same-owner, owner-control,
  and owner-straddle. Removing duplicate suppression locally would be an
  endpoint risk. A legal fix must prove each required owner PC reaches decode
  exactly once before changing the suppressor.
- The next DSE must split redirect-driven no-emit from duplicate/control
  owner handoff before behavior changes. Branch A and Branch B are now coupled
  by the same owner contract, but they still need separate DSE branches.

Important interpretation rule:

- Entry-slot counters can exceed 100 percent of timed cycles because several IQ
  entries can wait in the same cycle. They rank pressure but do not directly
  predict cycle improvement.
- Cycle counters such as `packet_empty`, `redirect_recovery`,
  `xs_backend_stall_pkt_ready`, `xs_bottleneck_rob_commit_zero_cycles`, and
  latency histograms bound the possible cycle payoff.
- Every DSE branch must include both views: pressure counter movement and
  cycle-level movement.

## Deep DSE Master Plan

This section is the longer execution plan for the next optimization campaign.
It is intentionally stricter than the earlier local DSE loops. The objective is
to turn the current bottleneck analysis into a sequence of structural
experiments that can expose multi-percent opportunities or reject them with
clear evidence.

### Current Bottleneck Stacks

The current counters do not point to one isolated bug. They point to five
overlapping bottleneck stacks that must be separated before more RTL tuning:

| Stack | Current evidence | Architectural hypothesis | First proof needed |
|---|---|---|---|
| Frontend owner delivery | CoreMark 10 has `xs_data_present_no_emit=83,016`, `xs_data_no_emit_pktbuf_empty=61,010`, and branch hotspot has `xs_data_present_no_emit=30,172` with `xs_data_no_emit_owner_live=30,172`. | A post-IFU owner can be live with data present, but the frontend cannot prove that a legal decode packet should be emitted, replayed, or killed. | Delivery scoreboard plus owner/epoch no-emit classification. |
| Branch recovery contract | CoreMark 10 has `redirect_recovery=29,575`; branch hotspot has `redirect_recovery=8,331`. A0 showed many non-head mispredicts with useful younger work. | Recovery opportunity is real, but the checkpoint, frontend, and backend contracts are not yet strong enough for an early recovery behavior change. | Checkpoint boundary metadata repair, then a resource-aware recovery scheduler, not raw plusarg replay. |
| Scheduler dependency pressure | CoreMark 10 has `xs_bottleneck_dep_wait_on_alu=13,495,221`, but local IQ0/short-ALU variants were marginal and sometimes regressed branch rows. | The real backend opportunity is broader wakeup/select or criticality scheduling, not a local same-cycle chain shortcut. | Producer state, select-loss, and cross-IQ criticality attribution. |
| Load-use and memory latency | Dhrystone 100 has `xs_bottleneck_dep_wait_on_load=17,175`, and CoreMark 10 still has large load-wait pressure. | Dhrystone is partly memory/load-use limited, so a frontend-only campaign cannot explain all anchor-row movement. | Load latency, store-forward, cache-port, replay, and consumer-wakeup split. |
| Commit and window drain | CoreMark 10 has high commit-zero pressure and branch hotspot has high head-block pressure. | Commit-zero may be a downstream symptom of branch recovery, memory, or scheduler stalls rather than a commit-width bottleneck. | ROB-head block cause and correlation with redirect, load, and scheduler stalls. |

The working priority is:

1. Finish Branch A evidence cleanup because branch-boundary checkpoint metadata
   already showed large opportunity-counter movement.
2. Build Branch B delivery-scoreboard evidence before changing duplicate or
   redirect handoff behavior.
3. Add Branch C/D attribution only after the frontend and recovery ownership
   evidence is current, because backend counter pressure is large but not yet
   cycle-bound enough for a behavior slice.
4. Treat Branch E as a dependent investigation until head-block cause proves
   actual commit/window limits.

### Current DSE Thesis After Cursor Attribution

The current bottleneck data now supports one narrow next behavior direction,
plus several deeper evidence branches. The next DSE campaign should not be a
menu of independent tweaks. It should test this ordered thesis:

1. The dominant frontend loss is a post-delivery owner-cursor handoff problem,
   not raw IBuffer capacity and not safe duplicate packet emission.
2. Branch recovery has real opportunity after checkpoint-boundary metadata
   repair, but the old recovery behavior knobs are too blunt and currently
   increase recovery cost.
3. Scheduler pressure is very large on CoreMark, but previous local IQ0 and
   short-ALU trials were too marginal. The next backend work must first prove
   whether the problem is criticality, select fairness, FU steering, or true
   dependency depth.
4. Dhrystone still has a load-use component that a frontend-only campaign will
   not remove.
5. Commit-zero pressure is probably a symptom until ROB-head attribution proves
   a direct window or retirement structure bottleneck.

Therefore the near-term DSE queue is:

| Priority | Branch | Reason to run now | First expected proof |
|---:|---|---|---|
| 1 | B1 post-delivery cursor handoff | B1b shows repeated same-line already-delivered PCs while seq, duplicate-next, request-PC, and ICQ state often already know the scoreboard next PC. | `xs_delivery_no_emit_already_delivered`, `xs_data_no_emit_dup`, and `packet_empty_noemit_dup` fall without duplicate-delivery or stale-owner violations. |
| 2 | A1 recovery scheduler attribution | Checkpoint rejects collapsed after metadata repair, but raw and selective recovery regressed. | Recovery attempt cost, refill latency, and useful-work loss are split well enough to design a resource-aware scheduler. |
| 3 | C0 scheduler criticality attribution | CoreMark ALU dependency pressure is huge, but local chaining was not broad enough. | Producer blocked state and select-loss counters identify one structural scheduler mechanism with at least 3 percent projected upside. |
| 4 | D0 load-use attribution | Dhrystone ranks load wait above ALU pressure. | Load-use, store-forward, dcache-port, and replay causes are separated before any Dhrystone-directed change. |
| 5 | E0 ROB-head attribution | Commit-zero pressure is large but entangled with branch, frontend, memory, and scheduler stalls. | Head-block cause and ready-younger hidden slots prove whether commit/window work is root-cause. |

The first behavior trial should be B1 only if it changes the owner cursor
contract for a scoreboard-proven already-delivered packet. It must not emit a
duplicate packet, steer to benchmark PCs, revive the old loop buffer, or add
capacity before the empty-buffer owner-live no-emit bucket is reduced.

### Phase 0: Evidence Freeze And Run Hygiene

Purpose:

- Prevent another cycle where results from different RTL states are compared as
  if they were one baseline.
- Make every DSE row reproducible and traceable.

Required work:

- Keep `benchmark_results/stage2_bottleneck_baseline_20260509` as the locked
  baseline until a full 16-row promoted candidate replaces it.
- Record every behavior trial against that baseline using `--baseline-results`.
- Do not cite a run if its result summary predates the RTL under test.
- Rebuild DSim or XSim after every RTL change.
- Commit validated instrumentation separately from behavior changes.
- Do not leave dirty RTL running in a long run.

Exit criteria:

- `git status --short` is understood before every run.
- The doc records which artifact is baseline, instrumentation, behavior trial,
  rejected trial, or promoted candidate.
- Any stale run is labeled as functionality-only or historical evidence.

### Phase 1: Counter Completeness Pass

Purpose:

- Ensure every major bottleneck stack has enough cycle-bound counters to drive
  an architectural decision.
- Avoid implementing an RTL mechanism when the current counters only show a
  symptom.

Required counter coverage:

| Area | Missing or required split | Why it matters |
|---|---|---|
| Frontend owner delivery | For every data-present no-emit cycle: owner phase, FTQ idx, epoch valid, redirect pending, predicted-control hold, straddle/remainder hold, packet-ready hold, IBuffer state, and duplicate safe/unsafe classification. | Distinguishes a legal owner handoff repair from unsafe duplicate suppression removal. |
| Redirect refill | Redirect to first I-cache request, first line response, first emitted packet, and first decoded packet. | Separates branch recovery latency from fetch delivery policy. |
| Branch recovery | Recovery candidate by branch type, ROB age, checkpoint state, resource headroom, side-effect class, and younger useful work. | Prevents raw early recovery from firing in states that cannot recover safely. |
| Scheduler | Not-ready producer state, producer FU class, consumer IQ, select-lost reason, FU-port busy, age priority loss, and ready-hidden by IQ. | Determines whether the fix is wakeup timing, select policy, port steering, or true dependency depth. |
| Load-use | Load latency bucket, load-to-consumer wakeup delay, store-forward wait/fail reason, dcache port conflict, replay reason, and LSU queue pressure. | Prevents Dhrystone-oriented changes from masking a load-use issue. |
| Commit/window | ROB head class, head ready state, ready younger count, ROB occupancy, rename stall cause, PRF pressure, and redirect/load correlation. | Distinguishes root-cause drain from commit-width symptoms. |

Exit criteria:

- A new bottleneck rank report includes both cycle counters and pressure
  counters for all 16 rows.
- Each proposed behavior branch has one primary target counter and one
  cycle-bound companion counter.
- If a branch lacks a cycle-bound companion counter, only instrumentation work
  is allowed.

### Phase 2: Branch A Recovery Contract DSE

Purpose:

- Convert branch recovery from a known opportunity into a safe architectural
  mechanism.
- Avoid reusing the old partial-recovery plusargs as a proxy for a real design.

Required sequence:

1. A1a checkpoint-boundary metadata repair.
   - Repair branch checkpoint ownership so the recorded checkpoint boundary
     matches the branch ROB, not the rename group head.
   - Validate as default-performance-neutral structural metadata.
   - Expected counter movement: `xs_branch_opportunity_reject_checkpoint`
     drops sharply without cycle changes.

2. A1b recovery scheduler attribution.
   - Add counters for why a candidate is not fired after metadata repair:
     resource headroom, commit conflict, frontend pending redirect, side-effect
     class, UOC activity, ROB age, and cooldown.
   - Add counters for recovery attempts that increase redirect work instead of
     reducing it.

3. A1c resource-aware backend-only recovery.
   - Fire only when checkpoint, RAT, free-list, ROB tail, writeback filtering,
     and LSU cleanup are all proven safe.
   - Do not redirect frontend early yet.
   - Primary expected movement: lower `redirect_recovery` and commit-zero after
     mispredict, with zero branch-recovery invariant counters.

4. A2 early frontend redirect.
   - Start only after A1c is clean.
   - Restore BPU history, RAS, FTQ owner, IFU cursor, and IBuffer epoch from one
     owner rule.
   - Any stale owner, duplicate delivery, or checkpoint mismatch rejects the
     trial.

Promotion criteria:

- T2 branch hotspot improves by at least 3 percent.
- CoreMark 1 and CoreMark 10 improve or stay neutral.
- Dhrystone 100, backend ALU chain, and frontend branch dense do not regress.
- Strict fetch owner, delivery, and branch-recovery violation counters remain
  zero.

### Phase 3: Branch B Owner Delivery DSE

Purpose:

- Attack the largest current frontend opportunity without reviving the loop
  buffer or adding blind packet storage.

Required sequence:

1. B1a delivery scoreboard instrumentation.
   - Track every required PC for a post-IFU owner until decode delivery.
   - Classify each no-emit as already-delivered, must-replay, must-kill,
     predicted-control hold, straddle/remainder hold, redirect hold, or
     downstream hold.
   - This is instrumentation first. It must not change cycles.

2. B1b post-delivery cursor attribution.
   - Determine why F2 revisits an already-delivered or non-next PC while the
     delivery scoreboard has a different next required PC.
   - Keep this behavior-neutral.

3. B1c owner/epoch duplicate cursor advancement.
   - Advance the work cursor only for scoreboard-equivalent, same-line,
     already-delivered duplicate cases.
   - Keep duplicate packet emission blocked.
   - Unsafe duplicate cases remain conservative.
   - Primary target counters:
     `xs_data_no_emit_dup`, `xs_data_no_emit_pktbuf_empty`,
     `packet_empty_noemit_dup`.

4. B1d redirect no-emit handoff.
   - For redirect-driven no-emit with an empty packet buffer, classify whether
     the owner is killed, replayed, or legally deliverable.
   - Update FTQ, IFU cursor, and IBuffer from one owner transition.

5. B2 owner-aware capacity.
   - Add more delivery capacity only if B1 leaves `xs_data_no_emit_pktbuf_full`
     or packet-age counters as the dominant limiter.
   - Each entry carries FTQ idx, epoch, start PC, valid mask, predicted-control
     metadata, and delivery-complete state.

Promotion criteria:

- T2 CoreMark 10 and branch hotspot reduce data-present no-emit with no rise in
  stale owner, duplicate-delivery, packet-full, or backend packet-ready stalls.
- If `xs_data_no_emit_pktbuf_empty` does not fall, the candidate did not fix
  the dominant measured shape and is not promotable.
- Capacity-only work is forbidden until empty-buffer owner-live no-emit is no
  longer dominant.

### Phase 4: Branch C Scheduler DSE

Purpose:

- Reopen backend performance only as a structural scheduler study, not as local
  IQ0 tuning.

Required sequence:

1. C0 criticality attribution.
   - Add producer-chain depth, producer issue state, select-loss reason,
     ready-hidden by IQ, and FU-port utilization counters.
   - Split ALU dependency pressure into true dependency, producer blocked,
     ready not selected, steering conflict, and wakeup timing.

2. C1 broad scheduler candidate.
   - Allowed mechanisms include age-aware select fairness, cluster-level simple
     integer steering, registered fast-lane wakeup token, or producer
     criticality priority.
   - Rejected mechanisms include local port op-list tuning, scalar threshold
     chasing, and any path that only targets Dhrystone/CoreMark.

Promotion criteria:

- At least 3 percent CoreMark 10 improvement.
- No regression on branch dense, branch hotspot, Dhrystone 100, memory rows,
  backend independent rows, or ALU-chain guards.
- `xs_bottleneck_dep_wait_on_alu` must fall with a cycle-bound companion such
  as commit IPC, issue utilization, or commit-zero movement.

### Phase 5: Branch D Load-Use DSE

Purpose:

- Explain Dhrystone sensitivity and prevent frontend/backend changes from
  hiding load-use latency.

Required sequence:

1. D0 load-use attribution.
   - Add issue-to-data latency buckets.
   - Add load-to-consumer wakeup delay buckets.
   - Add store-forward wait/fail reasons.
   - Add dcache-port conflict and replay cause counters.

2. D1 structural memory candidate.
   - Allowed mechanisms include store-forward latency repair, speculative load
     wakeup with replay, or dcache port/banking adjustment if counters justify
     them.
   - Raw load speculation without replay correctness is rejected.

Promotion criteria:

- Dhrystone improves without CoreMark or branch hotspot regression.
- Memory generalization rows improve or stay neutral.
- Replay, stale wakeup, and wrong-path store safety counters stay clean.

### Phase 6: Branch E Commit And Window DSE

Purpose:

- Determine whether commit-zero pressure is root cause or a symptom.

Required sequence:

1. E0 head-block attribution.
   - Classify ROB head block by uop class and ready state.
   - Count ready younger slots hidden behind the head.
   - Correlate head blocks with redirect, load, scheduler, rename, and PRF
     pressure.

2. E1 window or drain candidate.
   - Only implement if E0 proves actual admission or retirement structure is
     limiting broad rows.

Promotion criteria:

- Commit-zero cycles fall and IPC rises without increasing frontend packet
  empty, backend packet-ready stall, or branch recovery pressure.

### Phase 7: Cross-Branch Interaction Review

Purpose:

- Prevent one branch from improving a local counter while worsening a shared
  architectural contract.

Required review after every T2:

| Check | Required question |
|---|---|
| Frontend and branch | Did redirect recovery fall by making packet delivery more conservative, or did packet delivery improve by increasing wrong-path work? |
| Frontend and backend | Did packet-empty fall only because decode stalls grew, or did useful decode/commit IPC improve? |
| Branch and commit | Did early recovery reduce useful flush work, or did it increase recovery attempts and commit-zero windows? |
| Scheduler and branch | Did wakeup/select changes alter branch resolution timing enough to regress branch rows? |
| Load-use and scheduler | Did speculative load wakeup reduce real load-use latency, or did it add replay pressure? |

Exit criteria:

- Every promoted candidate has a before/after table for primary counters,
  companion cycle counters, and guard counters.
- Any cross-branch regression is either fixed before promotion or the candidate
  is classified as DSE-only or rejected.

### Phase 8: Broader Workload Expansion

Purpose:

- Reduce overfitting to Dhrystone and CoreMark while still using them as anchor
  rows for continuity with the Reference Core A (large config) comparison.

Execution rules:

- First keep the six-row T2 set for fast architectural screening.
- Add broader rows only after T2 is clean, so the long run is not wasted on an
  already-regressing candidate.
- Include integer control, pointer chasing, memcpy/memset, branch dense, cache
  pressure, independent ALU, dependent ALU, load-use, and mixed call/return
  rows.
- A candidate that only improves Dhrystone/CoreMark and regresses broader rows
  is not an architectural promotion.

Exit criteria:

- Stage 2 promoted mechanisms are measured on the full Stage 1 manifest first.
- Additional broader rows are used to rank the next architectural direction,
  not to excuse regressions in the locked signoff rows.

### Experiment Decision Record Template

Every DSE branch should add a compact decision block to this document:

```text
Experiment:
Mechanism class:
Mechanism name:
RTL state or commit:
Baseline artifact:
Run artifacts:
Hypothesis:
Primary target counter:
Cycle-bound companion counter:
Expected delta:
Observed delta:
Rows improved:
Rows regressed:
Strict checker status:
Verdict:
Next action:
```

Verdicts must use one of the scoring labels in this document. Do not describe a
trial as "promising" unless it has a named next structural fix and clean guard
rows.

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

## Deep DSE Execution Ladder

The DSE loop should be long enough to prevent another marginal scalar-tuning
cycle. Each branch must pass through these steps before RTL promotion.

### Step 1: Symptom To Root-Cause Split

Start from cycle-level symptoms, not aggregate entry-slot counts:

| Symptom | Candidate root causes | Required split before RTL |
|---|---|---|
| `packet_empty` and `fe_zero` | Missing fetch data, legal packet held, redirect recovery, decode not ready, packet buffer full | Split by F2 data valid, no-emit cause, IBuffer state, owner live state, and redirect age. |
| `xs_data_present_no_emit` | Duplicate guard, predicted-control hold, straddle/remainder hold, packet-ready hold, redirect hold | Split by duplicate vs redirect vs stall, then by owner continuity and post-IFU depth. |
| `redirect_recovery` | Late branch detection, checkpoint restore latency, frontend redirect replay, BPU history/RAS restore | Split by branch type, ROB age, checkpoint availability, flushed useful work, and fetch/decode refill latency. |
| `xs_bottleneck_dep_wait_on_alu` | True dependency depth, producer blocked, ready-not-selected, same-cycle wakeup not visible, cluster steering | Split by producer issue state, producer FU class, consumer IQ, and selected-lost reason. |
| `xs_bottleneck_dep_wait_on_load` | Load-use latency, store-forward wait, cache port conflict, replay, queue pressure | Split by load latency bucket, store-forward status, cache conflict, and replay cause. |
| `rob_commit_zero` | Branch recovery drain, long-latency load, exception/CSR, scheduler starvation, window pressure | Split by ROB head uop class, ready younger slots, redirect correlation, and LSU/mul/div wait. |

Step 1 exit:

- Every branch has a named counter family that is cycle-bound and row-shared.
- The hypothesis states why the issue is architectural and not a benchmark PC
  artifact.
- The expected upside is at least 3 percent on the intended row group or the
  branch is kept as instrumentation only.

### Step 2: Opportunity Quantification

Before behavior changes, quantify removable cycles with conservative
accounting:

- `removable_upper_bound = min(symptom_cycles, target_counter_cycles)`.
- Discount overlapping counters. For example, `xs_data_no_emit_dup` and
  `packet_empty_f2_data` overlap and cannot both be counted as additive gain.
- For entry-slot counters, require a cycle-bound companion counter before
  predicting cycle gain.
- For microbench rows, require absolute movement as well as percent movement.

Step 2 exit:

- Each candidate has a table with baseline cycles, target counter, predicted
  counter delta, expected cycle delta, and rows that may regress.
- The predicted delta is passed into `tools/run_benchmarks.py` using
  `--targets-counter` and `--expect-counter-decrease`.

### Step 3: Behavior-Neutral Instrumentation

Add counters and checkers before RTL behavior:

- Prefer `src/rtl/sim/*` profiler modules or existing simulation boundary
  files.
- Do not add new `$display`, `$test$plusargs`, or ad hoc debug blocks to
  synthesizable RTL unless the file already owns simulation-only debug and the
  change is explicitly a profiling debt slice.
- Compile tools and rebuild the simulator after instrumentation.
- Run T1 and T2. Cycles should match baseline exactly for instrumentation-only
  commits.

Step 3 exit:

- Instrumentation is committed separately.
- The plan document is updated with a table that either selects a behavior
  branch or rejects the branch as not actionable.

### Step 4: Smallest Architectural Behavior Slice

Implement the smallest mechanism that matches the chosen root cause:

- One branch, one mechanism, one primary target counter.
- No scalar threshold chasing unless the threshold is part of a documented
  general predictor mechanism.
- No benchmark PC lists, no benchmark-specific op lists, and no loop-buffer
  revival.
- Keep behavior changes separated from style cleanup.

Step 4 exit:

- T1 strict smoke passes.
- Target counters move in the predicted direction.
- No strict fetch owner, delivery, branch recovery, stale owner, or endpoint
  failures.

### Step 5: Focused Coverage And Quarantine

Run T2 before any long run:

- Dhrystone 100
- CoreMark 1
- CoreMark 10
- Frontend mixed branch dense
- Backend ALU chain 8
- Branch hotspot

Step 5 exit:

- T2 has no unexplained regression.
- Any regression has a counter-backed explanation and a structural repair path.
- If the candidate improves only one anchor row and regresses a guard row, mark
  it DSE-only or rejected instead of continuing.

### Step 6: Full Coverage And Competitor Context

Run T3 only after T2 passes:

- Full `tests/benchmarks/stage1_signoff.json`.
- Same strict plusargs and bottleneck profile.
- Compare against locked baseline and calibrated Reference Core A (large config) methodology only
  after the full row set is clean.

Step 6 exit:

- Full 16-row pass.
- No unexplained regression above the documented thresholds.
- Counter movement matches the hypothesis.
- The doc classifies the candidate and records whether it changes the Stage 2
  baseline.

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

A0 baseline opportunity result, May 9, 2026:

- Instrumentation artifact: `benchmark_results/stage2_branch_a0_profile_t2_20260509`.
- T1 artifact: `benchmark_results/stage2_branch_a0_profile_t1_20260509`.
- Both runs passed strict owner, delivery, and branch-recovery checks.
- Cycles matched the locked baseline exactly, so the counters are
  behavior-neutral evidence.

| Row | CDB mispredict cycles | Redirect recovery | Partial candidates | Resource-ok candidates | Checkpoint at branch | Checkpoint rejects | Younger sum | Younger ready sum |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Dhrystone 100 | `88` | `81` | `64` | `64` | `67` | `18` | `556` | `23` |
| CoreMark 1 | `4,685` | `4,052` | `2,930` | `2,897` | `3,184` | `1,328` | `37,571` | `1,365` |
| CoreMark 10 | `35,512` | `29,575` | `21,002` | `20,478` | `22,976` | `10,990` | `293,294` | `9,349` |
| Frontend mixed branch dense | `564` | `426` | `198` | `198` | `240` | `258` | `4,961` | `104` |
| Backend ALU chain 8 | `2` | `2` | `0` | `0` | `0` | `2` | `24` | `2` |
| Branch hotspot | `8,738` | `8,331` | `1,671` | `1,671` | `1,857` | `6,711` | `63,873` | `3,043` |

Interpretation:

- Branch recovery is real and broad enough for a structural branch. CoreMark 10
  has `35,512` execute-time mispredict cycles and `29,575` redirect-recovery
  cycles, so the cycle-bound upper bound is large enough to justify A1 work.
- The current safe-boundary partial recovery rule is not enough for the branch
  hotspot. It finds only `1,671` candidates while `6,711` opportunities reject
  on checkpoint ownership.
- The dominant checkpoint reject shape is "checkpoint exists, but the
  checkpoint tail is not the branch ROB", not raw checkpoint absence.
  Branch hotspot has `8,563` checkpointed mispredicts and only `175`
  checkpoint-missing cases.
- Resource headroom is not the limiter for current candidates. Resource-ok
  counts nearly equal partial-candidate counts in the important rows.
- The next Branch A behavior candidate must repair branch-boundary checkpoint
  ownership. Re-enabling the old partial-recovery plusargs without changing the
  checkpoint contract would only replay a known limited mechanism.
- Redirect-to-fetch and redirect-to-decode latency can still be added later,
  but this A0 result is already sufficient to reject another old-plusarg retry
  and select checkpoint-boundary ownership as the next Branch A design problem.

Checkpoint-boundary metadata repair result, May 9, 2026:

- T1 artifact: `benchmark_results/stage2_branch_ckpt_boundary_t1_20260509`.
- T2 artifact: `benchmark_results/stage2_branch_ckpt_boundary_t2_20260509`.
- Both runs passed strict owner, delivery, and branch-recovery checks.
- Cycles matched the locked baseline exactly, so this is structural enabling
  work, not a performance improvement claim.
- The repair changes the branch checkpoint boundary metadata so a branch
  checkpoint records the branch ROB boundary instead of the rename group head.

| Row | Cycles | Partial candidates before | Partial candidates after | Resource-ok after | Checkpoint at branch after | Checkpoint rejects before | Checkpoint rejects after |
|---|---:|---:|---:|---:|---:|---:|---:|
| Dhrystone 100 | `18,577` | `64` | `74` | `74` | `78` | `18` | `8` |
| CoreMark 10 | `1,500,110` | `21,002` | `31,617` | `28,090` | `34,812` | `10,990` | `375` |
| CoreMark 1 | `163,013` | `2,930` | `4,202` | `3,879` | `4,572` | `1,328` | `56` |
| Frontend mixed branch dense | `7,220` | `198` | `456` | `456` | `564` | `258` | `0` |
| Backend ALU chain 8 | `3,039` | `0` | `2` | `1` | `2` | `2` | `0` |
| Branch hotspot | `141,326` | `1,671` | `8,231` | `8,231` | `8,563` | `6,711` | `151` |

Interpretation:

- The checkpoint metadata issue was a real architectural blocker. It hid most
  branch-hotspot recovery opportunity and a large CoreMark 10 opportunity.
- Default cycles did not change, so the repair should be treated as enabling
  metadata, not a Stage 2 performance mechanism by itself.
- After the repair, remaining rejects are no longer dominated by checkpoint
  ownership. The next recovery question is whether the backend and frontend can
  safely consume those candidates without increasing wrong-path or replay work.

Behavior plusarg trials after checkpoint repair:

| Trial | Artifact | Result | Verdict |
|---|---|---|---|
| Raw `+EXEC_PARTIAL_BRANCH_RECOVERY` | `benchmark_results/stage2_branch_partial_recovery_t1_20260509` | Dhrystone regressed from `18,577` to `36,434`; CoreMark 1 timed out at `999,960` cycles. Strict invariant counters stayed zero, but recovery attempts exploded. | Rejected due regression and timeout. Do not promote raw execution partial recovery. |
| `+SELECTIVE_BRANCH_RECOVERY` | `benchmark_results/stage2_branch_selective_recovery_t1_20260509` | Dhrystone regressed from `18,577` to `18,894`; CoreMark 1 regressed from `163,013` to `171,729`. Strict owner, stale, and branch-recovery violation counters stayed zero. | DSE-only rejected behavior. The resource gate is safer than raw recovery, but it still increases useful work loss or refill cost. |

The immediate Branch A conclusion is that opportunity exists, metadata repair
was necessary, and the old behavior knobs are not the final design. The next
Branch A step must be a recovery scheduler and redirect/refill attribution
pass, not another plusarg retry.

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

### B1: Owner-Aware No-Emit Contract Repair

The T1/T2 depth profile shows `alloc2ifu` is already zero in the current
frontend, so simply splitting an allocation pointer is not the highest leverage
first behavior change. The B0b no-emit attribution also shows that the existing
packet buffer is usually empty on no-emit cycles. B1 should therefore repair
the legal delivery contract for live post-IFU owners before adding storage.

Behavior-neutral first slice:

- Keep existing allocation semantics.
- Keep existing IFU owner consumption semantics.
- Add assertion and profile state for post-IFU owners that still have pending
  packet delivery work.
- Preserve owner metadata until all required PCs for that owner are delivered.
- Keep strict owner and delivery checkers active.
- Add a delivery scoreboard that can prove every required owner PC reaches
  decode exactly once.
- Add a duplicate-suppression audit counter that distinguishes safe duplicate
  suppression from a suppressed packet that should have been delivered through
  a different owner phase.

Delivery-scoreboard instrumentation result, May 9, 2026:

- Instrumentation commit: `96a655d Add fetch delivery scoreboard counters`.
- T1 artifact: `benchmark_results/stage2_delivery_scoreboard_t1_20260509`.
- T2 artifact: `benchmark_results/stage2_delivery_scoreboard_t2_20260509`.
- T2 rank report:
  `benchmark_results/stage2_delivery_scoreboard_t2_20260509/bottleneck_rank.md`.
- T1 and T2 passed strict owner, delivery, and branch-recovery checks.
- Cycles matched the locked baseline exactly on all six T2 rows, so this is
  behavior-neutral evidence.
- New delivery invariants stayed clean:
  `xs_delivery_owner_switch=0` and `xs_delivery_noncontig_pcs=0` on every T2
  row.

| Row | Data no-emit | Score active | Expected-PC no-emit | Already-delivered no-emit | Dup expected-PC | Dup already-delivered | Redirect hold | Control | Taken control |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Dhrystone 100 | `289` | `6,537` | `6` | `213` | `0` | `212` | `6` | `3` | `3` |
| CoreMark 10 | `83,016` | `479,647` | `3,508` | `32,267` | `1` | `32,257` | `3,507` | `2,262` | `1,927` |
| CoreMark 1 | `9,741` | `51,672` | `433` | `3,605` | `1` | `3,603` | `432` | `279` | `244` |
| Frontend mixed branch dense | `425` | `373` | `19` | `0` | `0` | `0` | `19` | `19` | `19` |
| Backend ALU chain 8 | `2` | `2,010` | `1` | `0` | `0` | `0` | `1` | `1` | `1` |
| Branch hotspot | `30,172` | `64,551` | `1,974` | `25,328` | `0` | `23,635` | `1,974` | `1,712` | `41` |

Interpretation:

- Local duplicate-suppression removal is not justified. The scoreboard sees
  almost no duplicate-suppressed no-emit cycles at the next required PC:
  CoreMark 10 has `1`, CoreMark 1 has `1`, and branch hotspot has `0`.
- The dominant duplicate bucket is already-delivered or non-next-PC repetition:
  CoreMark 10 has `32,257` duplicate already-delivered cycles and branch
  hotspot has `23,635`. Emitting those packets would be wrong; the frontend
  must advance or redirect the owner cursor instead.
- Expected-PC no-emit is mostly redirect hold: CoreMark 10 has
  `3,507/3,508`, CoreMark 1 has `432/433`, and branch hotspot has
  `1,974/1,974`. That ties the remaining legal-delivery stalls back to the
  Branch A/B redirect and owner handoff contract.
- The next B1 slice should not be a behavior patch. It should add
  post-delivery cursor attribution for why F2 revisits an already-delivered PC
  instead of moving to the scoreboard's next required PC.

B1b attribution requirements before behavior:

- Split already-delivered no-emit by whether the scoreboard next PC is same
  line, cross line, predicted target, branch target, or unknown.
- Split by IFU cursor state: current `work_pc`, `seq_next_pc`, requested PC,
  duplicate next PC, successor request validity, runahead pending, and
  `ftq_next_owner` stability.
- Split by redirect state: commit redirect, BPU redirect, request redirect, and
  redirect target equal to scoreboard next PC.
- Split by line availability: line-state reuse, ICQ hit/mismatch, data wait,
  and future-line head block.
- Only after that attribution identifies a structural owner-cursor bug should a
  behavior trial modify duplicate, redirect, or successor handoff.

Post-delivery cursor attribution result, May 9, 2026:

- Instrumentation commit:
  `a694c08 Add post-delivery cursor attribution counters`.
- T1 artifact: `benchmark_results/stage2_delivery_cursor_attr_t1_20260509`.
- T2 artifact: `benchmark_results/stage2_delivery_cursor_attr_t2_20260509`.
- T2 rank report:
  `benchmark_results/stage2_delivery_cursor_attr_t2_20260509/bottleneck_rank.md`.
- T1 and T2 passed strict owner, delivery, and branch-recovery checks.
- Cycles matched the locked baseline exactly on all six T2 rows, so this is
  behavior-neutral evidence.
- New delivery invariant counters remained zero.

| Row | Already delivered | Same line | Cross line | Seq-next match | Duplicate-next match | Request-PC match | Successor match | Runahead match | Redirect overlap | Line-state match | ICQ match | FTQ next-start match |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Dhrystone 100 | `213` | `212` | `1` | `212` | `212` | `109` | `0` | `0` | `0` | `1` | `212` | `0` |
| CoreMark 10 | `32,267` | `32,259` | `8` | `32,209` | `32,257` | `23,779` | `0` | `0` | `0` | `149` | `32,259` | `0` |
| CoreMark 1 | `3,605` | `3,603` | `2` | `3,601` | `3,603` | `2,660` | `0` | `0` | `0` | `36` | `3,603` | `0` |
| Frontend mixed branch dense | `0` | `0` | `0` | `0` | `0` | `0` | `0` | `0` | `0` | `0` | `0` | `0` |
| Backend ALU chain 8 | `0` | `0` | `0` | `0` | `0` | `0` | `0` | `0` | `0` | `0` | `0` | `0` |
| Branch hotspot | `25,328` | `23,635` | `1,693` | `23,462` | `23,635` | `23,635` | `0` | `0` | `0` | `3,534` | `23,635` | `0` |

Interpretation:

- The repeated already-delivered packet is almost always on the same line as
  the scoreboard next required PC. CoreMark 10 is `32,259/32,267`, CoreMark 1
  is `3,603/3,605`, and branch hotspot is `23,635/25,328`.
- The existing local next-PC information is usually sufficient. The computed
  duplicate next PC matches the scoreboard next PC for CoreMark 10
  `32,257` times, CoreMark 1 `3,603` times, and branch hotspot `23,635`
  times. The sequential next PC also matches in nearly all same-line cases.
- The IFU request PC and ICQ head also often point at the scoreboard next PC:
  CoreMark 10 has `23,779` request-PC matches and `32,259` ICQ matches;
  branch hotspot has `23,635` request-PC matches and `23,635` ICQ matches.
- Redirect overlap is zero for this already-delivered bucket, so this B1
  behavior candidate is not the same problem as Branch A recovery.
- Successor, runahead, BPU target, and FTQ next-start matches are zero in this
  bucket, which means the immediate fix should not be a new prefetch pointer or
  successor request queue. The local post-delivery work cursor is the first
  suspect.

B1b verdict:

- The data now proves a broad structural post-delivery cursor advancement
  opportunity across Dhrystone, CoreMark 1, CoreMark 10, and branch hotspot.
- The opportunity is not benchmark-specific because the same shape appears on
  anchor, heavy, and branch-hotspot rows, while branch-dense and backend-chain
  rows correctly show no already-delivered duplicate bucket.
- The next behavior trial may update the IFU work cursor only for a
  scoreboard-equivalent, owner-live, same-line, already-delivered duplicate
  case. It must keep duplicate packet emission blocked.
- If that trial does not reduce `xs_delivery_no_emit_already_delivered` and
  `xs_data_no_emit_dup`, it should be rejected even if a row has marginal cycle
  movement.

Behavior slice candidates, in order:

1. Post-delivery cursor advancement or redirect/refill repair.
   - Move the IFU work cursor from an already-delivered/non-next PC toward the
     scoreboard next required PC through FTQ, IFU, IBuffer, and BPU ownership.
   - This is now the current first behavior candidate because B1b proved a
     general same-line missing handoff source.

2. Control-aware duplicate cursor recovery.
   - Permit IFU/F2 to advance past a duplicate-held packet only when the
     delivery scoreboard proves the packet is already delivered for that exact
     owner and epoch.
   - Keep predicted-control and straddle owners conservative until their
     endpoint identity is proven.
   - Convert `last_emitted_pc` from a global throttle into an owner/epoch
     assertion for the safe subset.

3. Redirect no-emit recovery handoff.
   - When data-present no-emit is redirect-driven and the packet buffer is
     empty, explicitly classify whether the owner should be killed, replayed,
     or delivered.
   - The handoff must update FTQ, IFU cursor, IBuffer, and BPU history from one
     owner rule. No local PC steering in IFU is allowed.

4. Owner-aware delivery capacity only if counters justify it.
   - Add packet storage only for rows where `xs_data_no_emit_pktbuf_full`,
     packet age, or downstream drain evidence explains the loss.
   - Each entry must carry FTQ index, owner epoch, start PC, packet valid mask,
     and predicted-control metadata.
   - This is not the first B1 behavior slice because B0b shows empty-buffer
     no-emit dominates branch hotspot and most CoreMark no-emit cycles.

Primary target counters:

- `xs_data_present_no_emit`
- `xs_data_no_emit_dup`
- `xs_runahead_dup_alloc_block`
- `xs_ftq_ifu2commit_occ_hist_2to3`
- `packet_empty_f2_data`
- `packet_empty_noemit_dup`
- `xs_dup_last_emit`
- `xs_data_no_emit_pktbuf_empty`
- `xs_data_no_emit_owner_live`
- `xs_data_no_emit_redir_pktbuf_empty`

Promotion gate:

- CoreMark 10 and branch hotspot packet-empty buckets drop without increasing
  `xs_packet_buf_full_cycles`, `xs_backend_stall_pkt_ready`, redirect
  recovery, stale owner, or duplicate-delivery violations.
- T2 must show broad reduction in data-present no-emit on CoreMark 1,
  CoreMark 10, frontend mixed branch dense, and branch hotspot before a full
  16-row run.
- If `xs_data_no_emit_pktbuf_empty` does not drop, the mechanism did not fix
  the currently dominant B0b shape and must not be promoted.

### B2: Full Owner-Aware IBuffer

Implement after B1 only if capacity remains the measured bottleneck:

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
- Explicit evidence that capacity, not live-owner empty-buffer no-emit, is the
  remaining limiter.

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
| T4 competitor rescore | Calibrated Reference Core A (large config) rows and stretch-target reporting | Re-score after a promoted structural mechanism. | Same methodology as baseline comparison docs | Reporting only after T3 passes. |

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

Start with a three-part evidence cleanup, not a new behavior patch:

1. Commit and preserve the checkpoint-boundary metadata repair as structural
   enabling work if the working tree matches the validated artifacts.
2. Branch B1 owner-aware no-emit contract repair remains the first frontend
   candidate, but only for duplicate/control owner handoff and redirect
   no-emit recovery. It is not a generic packet-buffer expansion.
3. Branch A continues as recovery-scheduler attribution, not as another retry
   of raw or selective partial-recovery plusargs.

Reason:

- The checkpoint-boundary repair reduced checkpoint rejects dramatically
  without changing default cycles. That proves the metadata contract was an
  architectural blocker, but not yet a performance mechanism.
- Raw and selective partial-recovery behavior trials both regressed, so the
  next Branch A work must explain recovery attempt cost and redirect/refill
  latency before another behavior change.
- CoreMark 10 has `packet_empty=91,909`,
  `xs_data_present_no_emit=83,016`, and
  `xs_runahead_dup_alloc_block=89,972`, which remain larger cycle-bound
  opportunities than `redirect_recovery=29,575`.
- The B0b profile shows `xs_data_no_emit_pktbuf_empty=61,010` on CoreMark 10
  and `30,122` on branch hotspot. Adding storage is not the direct answer when
  the buffer is empty during the bubble.
- Branch hotspot has `xs_data_no_emit_dup=23,635`, and all of it is
  no-same-owner, owner-control, and owner-straddle. That argues for a
  scoreboard-backed owner handoff, not duplicate-suppression removal.
- Frontend mixed branch dense is pure redirect no-emit
  (`425/425`) with empty buffer, so Branch A cannot be postponed behind a
  capacity-only Branch B implementation.
- The local short-ALU/IQ0 path remains quarantined because the accepted gains
  were marginal and nearby variants regressed branch rows.

Immediate next steps:

1. Keep `benchmark_results/stage2_bottleneck_baseline_20260509` as the locked
   comparison artifact.
2. Treat `stage2_ftq_depth_profile_t1_20260509`,
   `stage2_ftq_depth_profile_t2_20260509`,
   `stage2_noemit_attr_t1_20260509`, and
   `stage2_noemit_attr_t2_20260509` as completed behavior-neutral evidence.
3. Treat `stage2_branch_a0_profile_t1_20260509`,
   `stage2_branch_a0_profile_t2_20260509`,
   `stage2_branch_ckpt_boundary_t1_20260509`, and
   `stage2_branch_ckpt_boundary_t2_20260509` as completed Branch A evidence.
   The checkpoint-boundary repair is enabling metadata and should be committed
   separately from any behavior trial.
4. Treat `stage2_branch_partial_recovery_t1_20260509` and
   `stage2_branch_selective_recovery_t1_20260509` as rejected behavior trials.
   They show that available recovery candidates are not enough; the recovery
   scheduler and redirect/refill contract must be repaired first.
5. Treat `stage2_delivery_scoreboard_t1_20260509` and
   `stage2_delivery_scoreboard_t2_20260509` as completed B1a
   behavior-neutral evidence. The scoreboard rejects local duplicate-emission
   as the next behavior because expected-PC duplicate suppression is near zero.
6. Treat `stage2_delivery_cursor_attr_t1_20260509` and
   `stage2_delivery_cursor_attr_t2_20260509` as completed B1b
   behavior-neutral evidence. B1b proves that repeated already-delivered
   packets are usually same-line cases where duplicate-next, seq-next,
   request-PC, and ICQ state already match the scoreboard next PC.
7. Run the first B1 behavior trial: post-delivery duplicate cursor
   advancement. This trial may advance the IFU work cursor for an
   owner-live, same-line, already-delivered duplicate when the local next-PC
   candidates agree. It must not emit the duplicate packet.
8. If B1 cursor advancement is endpoint-clean and reduces the target counters,
   continue to B1 redirect no-emit handoff. If it is endpoint-clean but does
   not reduce the counters, classify it as DSE-only and move to A1 recovery
   scheduler attribution. If it fails correctness, revert or quarantine it.
9. If B1 and A1 both fail to expose multi-percent movement, continue with C0
   scheduler criticality attribution before any new backend behavior patch.
10. Run every behavior trial with an explicit prediction before measurement.
   B1 examples:
   `--targets-counter xs_data_no_emit_pktbuf_empty` and
   `--expect-counter-decrease xs_data_no_emit_pktbuf_empty:<predicted_delta>`.
   A1 examples:
   `--targets-counter xs_bottleneck_fe_redirect_recovery` and
   `--expect-counter-decrease xs_bottleneck_fe_redirect_recovery:<predicted_delta>`.
11. Promote only if T2 shows meaningful broad movement, then run the full
   16-row signoff before updating the Stage 2 baseline.

## Immediate Deep DSE Workplan

This section is the concrete long plan for the next implementation sessions.
It intentionally starts from the current bottleneck evidence and keeps each
trial falsifiable.

### Workstream B1c: Post-Delivery Cursor Advancement

Hypothesis:

- The IFU work cursor can remain at an already-delivered PC even when
  `seq_next_pc`, `duplicate_next_pc`, the active request PC, and the ICQ head
  already identify the next required same-line PC.
- Advancing the cursor in this scoreboard-equivalent safe subset should reduce
  frontend no-emit cycles without changing endpoint identity.

Allowed behavior:

- Advance the IFU work cursor only when all of these are true:
  owner is live, owner delivery already started, duplicate suppression is
  active, `seq_next_pc` is valid, `duplicate_next_pc == seq_next_pc`, the next
  PC is on the same cache line, no remainder or straddle handoff is active, no
  owner completion is pending, and strict owner state says the owner is still
  valid.
- Keep packet emission suppressed for the duplicate packet.
- Do not add a new packet FIFO, successor queue, prefetch pointer, benchmark PC
  table, or loop-buffer-like replay path in this slice.

Primary counters:

- `xs_delivery_no_emit_already_delivered`
- `xs_data_no_emit_dup`
- `packet_empty_noemit_dup`
- `xs_data_no_emit_pktbuf_empty`

Companion counters:

- `packet_empty`
- `packet_empty_f2_data`
- decode-supply rate from `tools/bottleneck_analysis.py`
- `xs_backend_stall_pkt_ready`
- `redirect_recovery`

Guard counters:

- `xs_delivery_owner_switch`
- `xs_delivery_noncontig_pcs`
- stale owner counters
- duplicate delivery counters
- branch recovery invariant counters
- packet buffer full counters

T1 predicted movement:

- Dhrystone and CoreMark 1 should show a measurable reduction in
  `xs_delivery_no_emit_already_delivered`.
- A small cycle change is acceptable at T1, but no cycle improvement alone is
  sufficient. The target counters must move.

T2 predicted movement:

- CoreMark 10 should reduce at least several thousand already-delivered or
  duplicate no-emit cycles.
- Branch hotspot should reduce the same-line duplicate bucket without
  increasing redirect recovery.
- Frontend branch dense and backend ALU chain should stay neutral because
  their already-delivered bucket is zero.

Reject conditions:

- Any strict checker failure, checksum drift, timeout, stale owner, or
  duplicate-delivery violation.
- `xs_backend_stall_pkt_ready` rises enough to explain away a packet-empty
  decrease.
- Branch hotspot improves by allowing wrong-path or stale owner packets.
- The counter movement is limited to Dhrystone or CoreMark only.

T1 command shape:

```bash
python3 tools/run_benchmarks.py \
  --runner dsim \
  --manifest tests/benchmarks/stage1_signoff.json \
  --run-class dse \
  --bench dhrystone_100_checkedin,coremark_iter1_generalization \
  --mechanism-class post_delivery_cursor_handoff \
  --mechanism-name post_delivery_duplicate_cursor_advance \
  --baseline-results benchmark_results/stage2_delivery_cursor_attr_t2_20260509/results.json \
  --targets-counter xs_delivery_no_emit_already_delivered \
  --expect-counter-decrease xs_delivery_no_emit_already_delivered:100 \
  --run-id stage2_b1c_cursor_advance_t1_YYYYMMDD \
  --run-dir benchmark_results/stage2_b1c_cursor_advance_t1_YYYYMMDD \
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

T2 command shape:

```bash
python3 tools/run_benchmarks.py \
  --runner dsim \
  --manifest tests/benchmarks/stage1_signoff.json \
  --run-class dse \
  --bench dhrystone_100_checkedin,coremark_iter1_generalization,coremark_iter10_checkedin,frontend_mixed_branch_dense,backend_alu_chain_8,hotspot_state_crc_branch \
  --mechanism-class post_delivery_cursor_handoff \
  --mechanism-name post_delivery_duplicate_cursor_advance \
  --baseline-results benchmark_results/stage2_delivery_cursor_attr_t2_20260509/results.json \
  --targets-counter xs_delivery_no_emit_already_delivered \
  --expect-counter-decrease xs_delivery_no_emit_already_delivered:1000 \
  --run-id stage2_b1c_cursor_advance_t2_YYYYMMDD \
  --run-dir benchmark_results/stage2_b1c_cursor_advance_t2_YYYYMMDD \
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

T3 promotion note:

- Use the narrower `post_delivery_cursor_handoff` mechanism class for this
  trial so the harness checks only the explicitly declared target counter.
  Do not bypass the data-driven discipline to avoid unrelated default
  expectations from broader mechanism classes.

B1c behavior and blocker-profile result, May 9, 2026:

- First behavior artifact:
  `benchmark_results/stage2_b1c_cursor_advance_t1_20260509`.
- Second behavior artifact:
  `benchmark_results/stage2_b1c_cursor_advance_t1_r2_20260509`.
- Blocker profile T1 artifact:
  `benchmark_results/stage2_b1c_cursor_blocker_t1_20260509`.
- Blocker profile T2 artifact:
  `benchmark_results/stage2_b1c_cursor_blocker_t2_20260509`.
- T2 rank report:
  `benchmark_results/stage2_b1c_cursor_blocker_t2_20260509/bottleneck_rank.md`.
- All runs passed endpoint, strict owner, strict delivery, and branch-recovery
  checks.
- Both behavior attempts were cycle-identical to baseline and failed the
  declared counter gate: `xs_delivery_no_emit_already_delivered` did not fall
  on Dhrystone or CoreMark 1.
- The behavior RTL from those attempts was reverted. The retained RTL delta is
  simulation-only blocker attribution.

| Row | Post-delivery duplicate base | Ready same-cycle subset | Pred-control blocked | Next-owner blocked | Redirect blocked | FE-stall blocked | Already-delivered no-emit | Duplicate no-emit |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Dhrystone 100 | `212` | `212` | `0` | `0` | `0` | `0` | `213` | `212` |
| CoreMark 10 | `41,198` | `30,228` | `8,851` | `36` | `153` | `1,975` | `32,267` | `41,286` |
| CoreMark 1 | `4,473` | `3,230` | `1,044` | `3` | `35` | `187` | `3,605` | `4,475` |
| Frontend mixed branch dense | `0` | `0` | `0` | `0` | `0` | `0` | `0` | `0` |
| Backend ALU chain 8 | `0` | `0` | `0` | `0` | `0` | `0` | `0` | `0` |
| Branch hotspot | `23,462` | `8` | `23,454` | `0` | `1,838` | `0` | `25,328` | `23,635` |

Interpretation:

- A next-cycle work-cursor advance is insufficient. The duplicate bubble is
  counted in the same cycle that the cursor would learn enough to move, so
  advancing the registered cursor after the bubble does not reduce
  `xs_delivery_no_emit_already_delivered`.
- A same-cycle effective-PC remap could remove a CoreMark-shaped subset:
  CoreMark 10 has `30,228` ready same-line cycles, roughly 2 percent of the
  row. That is real, but below the desired 3-5 percent broad promotion bar by
  itself and does not address the branch hotspot.
- Branch hotspot is not a ready same-line cursor problem. It has only `8`
  ready cycles and `23,454` pred-control blocked cycles, so the hotspot needs a
  control-aware owner handoff, not another duplicate-threshold or local cursor
  tweak.
- The next Branch B behavior must combine same-cycle effective-PC delivery
  with predicted-control and straddle ownership rules, or it should defer to
  A1 recovery-scheduler attribution. A CoreMark-only same-cycle remap is
  DSE-only evidence until paired with the hotspot control-handoff mechanism.

Verdict:

- B1c next-cycle post-delivery cursor advancement is rejected as a promoted
  behavior candidate due to no target-counter movement.
- The blocker instrumentation is accepted as behavior-neutral evidence.
- Continue with B1d control-aware redirect/pred-control no-emit handoff before
  considering any isolated same-cycle remap promotion.

### Workstream B1d: Redirect No-Emit Handoff

Start only if B1c is clean or if B1c proves redirect handoff is the remaining
B1 limiter.

Hypothesis:

- Data-present no-emit caused by redirect hold with an empty packet buffer can
  be split into legal kill, replay, or deliver cases from a single owner rule.

Required attribution before behavior:

- Redirect source: commit, BPU, request redirect, or recovery redirect.
- Redirect age from assertion to first request, first response, first emitted
  packet, and first decoded packet.
- Owner fate: killed, replayed, delivered, or stale.
- Whether the redirected target equals the scoreboard next PC.

B1d pred-control blocker result, May 9, 2026:

- T1 artifact: `benchmark_results/stage2_b1d_predctl_blocker_t1_20260509`.
- T2 artifact: `benchmark_results/stage2_b1d_predctl_blocker_t2_20260509`.
- T2 rank report:
  `benchmark_results/stage2_b1d_predctl_blocker_t2_20260509/bottleneck_rank.md`.
- T1 and T2 passed endpoint, strict owner, strict delivery, and
  branch-recovery checks.
- Cycles matched the locked baseline exactly, so this is behavior-neutral
  evidence.

| Row | Pred-control blocked | Pred taken | Pred not taken | Predecode present | BPU taken now | Conditional | JAL | JALR | RET | Ready same-cycle subset |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Dhrystone 100 | `0` | `0` | `0` | `0` | `0` | `0` | `0` | `0` | `0` | `212` |
| CoreMark 10 | `8,851` | `0` | `8,851` | `8,851` | `1` | `8,848` | `0` | `0` | `3` | `30,228` |
| CoreMark 1 | `1,044` | `0` | `1,044` | `1,044` | `0` | `1,044` | `0` | `0` | `0` | `3,230` |
| Frontend mixed branch dense | `0` | `0` | `0` | `0` | `0` | `0` | `0` | `0` | `0` | `0` |
| Backend ALU chain 8 | `0` | `0` | `0` | `0` | `0` | `0` | `0` | `0` | `0` | `0` |
| Branch hotspot | `23,454` | `0` | `23,454` | `23,454` | `3` | `23,454` | `0` | `0` | `0` | `8` |

Interpretation:

- The dominant hotspot block is not a taken-control redirect problem. It is a
  conditional predicted-not-taken fallthrough handoff problem.
- CoreMark has two useful subsets: `30,228` ready same-cycle duplicate cycles
  and `8,851` not-taken conditional pred-control blocked cycles. Branch
  hotspot has almost no ready subset but has `23,454` not-taken conditional
  pred-control blocked cycles.
- Therefore a CoreMark-only same-cycle effective-PC remap remains
  insufficient. The next promotable Branch B candidate must support fallthrough
  after an already-delivered not-taken conditional owner.
- The implementation should not be a local IFU PC mux. It must separate the
  duplicate-detection PC from the emitted packet PC so the duplicate guard can
  detect the old already-delivered packet while the boundary, predecode,
  compact, and guard update paths use the fallthrough PC for the emitted
  packet.

Next behavior candidate:

- `post_delivery_fallthrough_remap`: same-line effective-PC remap for an
  owner-tagged last-emitted duplicate when the FTQ predicted control is a
  conditional not-taken fallthrough or when no predicted-control window blocks
  the remap.
- Primary target counters:
  `xs_post_delivery_dup_ready`,
  `xs_post_delivery_dup_pred_ctl_not_taken`,
  `xs_delivery_no_emit_already_delivered`,
  and `packet_empty_noemit_dup`.
- Required guard counters:
  delivery owner switch, delivery non-contiguous PC, stale owner,
  branch-recovery invariants, redirect recovery, and backend packet-ready
  stalls.
- Reject the candidate if it only improves CoreMark while hotspot
  pred-control blocked cycles remain unchanged.

Candidate behavior:

- Centralize redirect owner handoff so FTQ, IFU cursor, IBuffer, and BPU
  history/RAS observe one owner transition.
- Do not locally steer IFU to a target without updating the owner metadata.

Promotion target:

- Reduce `xs_data_no_emit_redir_pktbuf_empty`, `redirect_recovery`, and
  frontend branch dense packet-empty without increasing duplicate or stale
  owner counters.

B1d fallthrough-remap trial result, May 9, 2026:

- Behavior artifacts:
  `benchmark_results/stage2_b1d_fallthrough_remap_t1_20260509` and
  `benchmark_results/stage2_b1d_fallthrough_remap_t2_20260509`.
- Baseline artifact:
  `benchmark_results/stage2_b1d_predctl_blocker_t2_20260509`.
- This RTL state is an uncommitted behavior trial. It is not promoted.
- T1 was endpoint-clean and reduced the declared target counter on the smoke
  rows.
- T2 was endpoint-clean, but CoreMark 10 regressed, so the candidate cannot be
  accepted without a deeper explanation and structural repair.

| Row | Baseline `mcycle` | Trial `mcycle` | Delta | Already-delivered delta | Duplicate no-emit delta | Packet-empty delta | Redirect-recovery delta | Backend-ready delta | Remaps |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Dhrystone 100 | `18,577` | `18,371` | `-206` | `-213` | `-212` | `-206` | `0` | `0` | `212` |
| CoreMark 10 | `1,500,110` | `1,514,156` | `+14,046` | `-29,755` | `-39,840` | `-17,763` | `+4,383` | `-9,766` | `45,623` |
| CoreMark 1 | `163,013` | `161,534` | `-1,479` | `-3,243` | `-4,295` | `-2,471` | `+100` | `-701` | `4,857` |
| Frontend mixed branch dense | `7,220` | `7,220` | `0` | `0` | `0` | `0` | `0` | `0` | `0` |
| Backend ALU chain 8 | `3,039` | `3,039` | `0` | `0` | `0` | `0` | `0` | `0` | `0` |
| Branch hotspot | `141,326` | `126,335` | `-14,991` | `-22,127` | `-21,442` | `-20,602` | `-163` | `+25` | `23,418` |

Interpretation:

- The mechanism attacks a real architectural bucket. It sharply reduces
  already-delivered and duplicate no-emit counters in CoreMark 10, CoreMark 1,
  Dhrystone, and the branch hotspot.
- It is not yet a complete architectural fix. CoreMark 10 loses `14,046`
  cycles even while duplicate/no-emit counters fall, and the run shows higher
  `redirect_recovery` plus higher commit-zero pressure.
- The regression is not explained by backend packet-ready pressure because
  CoreMark 10 backend-ready stalls fall by `9,766`.
- The hotspot improvement proves the not-taken fallthrough handoff is not just
  CoreMark-specific, but the CoreMark 10 regression proves the current remap
  is missing a branch/recovery or commit-window contract.
- The next step must be an autopsy of the regression path, not a wider remap
  or another local PC-steering patch.

Verdict:

- `post_delivery_fallthrough_remap` is DSE-only evidence in its current form.
- Do not promote it, do not run a full signoff on this dirty RTL, and do not
  tune its scalar guards until the CoreMark 10 regression is explained by
  counters.
- Either add behavior-neutral attribution around the remap and recovery
  windows, or revert the behavior trial and continue from the committed
  instrumentation baseline.

## Current Deep DSE Plan After B1d

The current bottleneck analysis says the next campaign needs a wider
correlation pass before the next behavior change. The frontend remap trial
proved that a large duplicate/no-emit bucket is removable, but it also showed
that reducing that bucket can expose or create recovery and commit pressure.
The next DSE therefore has to track causality across frontend delivery,
redirect recovery, scheduler dependency, load-use latency, and commit head
blocking.

### Planning Principle

Each DSE branch must answer four questions before RTL behavior changes:

1. Which cycle-bound counter is the primary limiter?
2. Which pressure counter explains the dynamic shape behind it?
3. Which guard counter could prove that an apparent improvement is false?
4. Which row group, beyond Dhrystone and CoreMark, should also move if the
   mechanism is architectural?

If any answer is missing, the branch is instrumentation-only.

### Current Ranked Hypotheses

| Priority | Hypothesis | Evidence now | Missing evidence | Allowed next action |
|---:|---|---|---|---|
| 1 | Frontend delivery is blocked by an owner handoff contract, not raw buffer capacity. | B1d removes duplicate/no-emit pressure and improves the branch hotspot, but CoreMark 10 regresses. | Per-remap fate, post-remap redirect age, post-remap commit head cause, and whether the emitted fallthrough packet later commits. | Add attribution around remap fate and recovery correlation. Do not widen the remap yet. |
| 2 | Redirect recovery and frontend delivery are coupled. | CoreMark 10 `redirect_recovery` rises in the remap trial while packet-empty falls. | Redirect source, redirect-to-request latency, redirect-to-decode latency, and useful younger work lost after remap. | Add A1 recovery/refill attribution, then design a scheduler for recovery attempts. |
| 3 | CoreMark is still dominated by ALU producer chains. | Post-remap rank still shows `xs_bottleneck_dep_wait_on_alu` and blocked not-yet-issued producers as the top pressure family. | Whether the cycle-bound loss is select loss, issue steering, wakeup timing, or true dependency depth. | Add C0 criticality counters before any more IQ0 or short-chain behavior. |
| 4 | Dhrystone has a load-use component independent of frontend. | Dhrystone rank shows high `xs_bottleneck_dep_wait_on_load` and store-forward wait. | Load latency, store-forward wait/fail, replay, and wakeup delay buckets. | Add D0 LSU/load-use attribution before Dhrystone-directed behavior. |
| 5 | Commit-zero is probably a symptom, but it can hide regressions. | CoreMark 10 commit-zero rises in the remap trial and is large in baseline. | ROB head class, head ready state, ready-younger slots, and correlation with remap, redirect, load, and scheduler stalls. | Add E0 head-block attribution and use it as a guard for every behavior trial. |

### H0: State Freeze And Trial Classification

Objective:

- Restore a trackable baseline for deeper DSE.
- Prevent the current dirty remap RTL from becoming the implicit baseline.

Actions:

1. Record `git status --short` before every cited run.
2. Classify the current B1d fallthrough-remap RTL as DSE-only until CoreMark
   10 is repaired.
3. Keep the result artifacts above as evidence, but do not compare future
   candidates against the dirty remap unless the repaired version becomes a
   clean T3 baseline.
4. If the next work is instrumentation, either add it on top of the dirty
   behavior only for autopsy runs or revert the behavior first. Do not mix
   accepted instrumentation with unaccepted behavior in one commit.
5. Commit only behavior-neutral documentation or instrumentation unless a
   behavior slice passes the promotion ladder.

Exit criteria:

- The doc says whether the active RTL is baseline, instrumentation-only,
  dirty behavior trial, rejected behavior, or accepted candidate.
- No long run starts from an unclassified dirty RTL state.

### H1: Remap Regression Autopsy

Objective:

- Explain why CoreMark 10 regresses after duplicate/no-emit counters fall.

New attribution to add:

| Counter family | Required split | Decision it enables |
|---|---|---|
| Remap fate | Remap emitted, emitted packet entered decode, packet killed by redirect, packet reached commit, packet became stale, packet caused delivery checker skip. | Determines whether the remap creates useful work or wrong-path work. |
| Remap class | No predicted control, conditional not-taken fallthrough, predicted-control offset before next PC, straddle/remainder, owner-complete pending. | Shows which sub-class is beneficial or harmful without scalar threshold tuning. |
| Post-remap redirect window | Redirect within 1, 2, 3, 4-7, 8+ cycles after remap, source of redirect, redirect target equal to remap PC or next owner PC. | Separates legal fallthrough progress from soon-to-be-killed work. |
| Post-remap commit window | Commit-zero within 1, 2, 3, 4-7, 8+ cycles after remap, ROB head class, ready-younger slots hidden. | Explains the CoreMark 10 commit-zero increase. |
| Delivery scoreboard | Required PC after remap, owner completion state, noncontiguous delivery, duplicate delivery, owner switch. | Proves endpoint identity is still exact. |

Expected outcomes:

- If remapped packets mostly commit and redirect/commit-zero rise is
  unrelated, continue with a structural recovery/commit fix.
- If remapped packets are often killed soon after decode, narrow the remap to a
  stronger owner/predictor-safe class.
- If commit-zero rises because the remap changes decode burst timing, the next
  fix is downstream drain scheduling, not more frontend delivery.
- If checker-visible owner ambiguity appears, reject the remap and return to
  Branch A/C/D attribution.

T1 autopsy run:

```bash
python3 tools/run_benchmarks.py \
  --runner dsim \
  --manifest tests/benchmarks/stage1_signoff.json \
  --run-class dse \
  --bench dhrystone_100_checkedin,coremark_iter1_generalization \
  --mechanism-class post_delivery_cursor_handoff \
  --mechanism-name post_delivery_fallthrough_remap_autopsy \
  --baseline-results benchmark_results/stage2_b1d_predctl_blocker_t2_20260509/results.json \
  --targets-counter xs_post_delivery_fallthrough_remap \
  --expect-counter-decrease xs_post_delivery_fallthrough_remap:0 \
  --run-id stage2_b1d_fallthrough_remap_autopsy_t1_YYYYMMDD \
  --run-dir benchmark_results/stage2_b1d_fallthrough_remap_autopsy_t1_YYYYMMDD \
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

T2 autopsy run:

- Use the six-row T2 set.
- Compare against `stage2_b1d_predctl_blocker_t2_20260509`.
- Required report columns:
  remaps, remap-commit, remap-kill, remap-stale, redirect-after-remap,
  commit-zero-after-remap, packet-empty, redirect recovery, backend-ready,
  and cycle delta.

Promotion rule:

- H1 does not promote behavior. It either produces a repaired B1d design
  target, rejects the remap, or redirects the next effort to A1, C0, D0, or E0.

### H2: Branch A And B Coupled Recovery Study

Objective:

- Determine whether the current frontend delivery changes need a branch
  recovery scheduler before they can be safely profitable.

Required counters:

- Redirect source by age and branch type.
- Redirect assertion to first IFU request.
- Redirect assertion to first I-cache response.
- Redirect assertion to first emitted packet.
- Redirect assertion to first decoded packet.
- Useful younger uops flushed by redirect.
- Ready younger uops flushed by redirect.
- Recovery candidate blocked by resource, checkpoint read, LSU, writeback,
  frontend pending redirect, or owner handoff.
- Recovery attempt later followed by full flush.

Design directions allowed after attribution:

- Backend-only resource-aware recovery scheduler.
- Delayed frontend redirect only when the owner state and checkpoint state
  agree.
- FTQ/IFU/IBuffer/BPU history recovery from one owner rule.

Design directions rejected:

- Raw partial-recovery plusarg retry.
- Selective recovery with no refill-cost model.
- Any frontend target steer that does not update FTQ owner, BPU history, RAS,
  IFU cursor, and IBuffer epoch together.

Success target:

- Branch hotspot at least 3 percent faster.
- CoreMark 10 neutral or faster.
- Redirect recovery falls without increasing packet-empty, stale owner,
  duplicate delivery, or commit-zero guard counters.

### H3: Scheduler Criticality Study

Objective:

- Find a structural scheduler mechanism with multi-percent potential instead
  of another local IQ0 or short-chain variant.

Required counters:

- Producer-chain depth at issue and while blocked.
- Producer state: not issued, issued this cycle, selected-lost, waiting on
  ALU, waiting on load, waiting on multiply/divide, waiting on branch.
- Consumer IQ and producer IQ pair.
- FU utilization by class and issue port.
- Select-lost cause by IQ: older-priority loss, port unavailable, operand not
  ready, FU mismatch, branch or LSU conflict.
- Ready-hidden count by IQ and FU class.
- Same-cycle wakeup candidate that could be supported by a registered
  next-cycle token without an ALU-to-IQ combinational path.

Candidate mechanisms after attribution:

| Candidate | Required proof | Expected broad effect |
|---|---|---|
| Age-aware select fairness | High ready-not-selected or arb-loss pressure across multiple IQs. | Reduces starvation without benchmark op-list tuning. |
| Simple-integer steering | Cross-IQ producer/consumer chains show avoidable cluster imbalance. | Improves CoreMark and backend guards without branch regression. |
| Registered fast-lane wakeup token | Same-cycle wakeup candidates are broad and miss selection because readiness arrives late. | Improves dependency chains while staying timing-clean. |
| Producer criticality priority | Long producer chains dominate and critical producers lose selection. | Reduces blocked not-yet-issued producer pressure. |

Reject conditions:

- Improvement is below 1 percent and target pressure does not fall.
- Branch rows regress due changed branch issue timing.
- The mechanism is an op-list or scalar threshold tuned around Dhrystone or
  CoreMark.

### H4: Load-Use And LSU Study

Objective:

- Explain Dhrystone and memory-sensitive rows with explicit load-use evidence.

Required counters:

- Load issue-to-data latency buckets.
- Load data-to-consumer-ready latency buckets.
- Store-forward hit, wait, fail, and ambiguity causes.
- D-cache port or bank conflict cycles.
- Load queue and store queue pressure.
- Replay cause and replay age.
- Speculative load wakeup issued, consumed, cancelled, replayed, and committed.

Candidate mechanisms after attribution:

- Store-forward path repair.
- Speculative load wakeup with replay correctness.
- D-cache port or bank adjustment if broad memory rows prove the pressure.

Reject conditions:

- Dhrystone improves while CoreMark or memory generalization rows regress.
- Replay pressure rises enough to erase the load-use benefit.
- Any stale load wakeup or wrong-path store safety counter trips.

### H5: Commit And Window Correlation Study

Objective:

- Make commit-zero a guard and possible root-cause branch, not a vague
  after-the-fact explanation.

Required counters:

- ROB head uop class and ready state.
- ROB head blocked by load, branch, ALU, multiply/divide, store, CSR,
  exception, or unknown.
- Ready younger commit slots hidden behind the head.
- ROB occupancy, IQ occupancy, dispatch occupancy, rename stall cause, and PRF
  pressure during commit-zero windows.
- Correlation of commit-zero windows with remap, redirect, load-use, and
  scheduler blocked-producer windows.

Decision rules:

- If commit-zero is mostly redirect-correlated, continue Branch A/B.
- If commit-zero is mostly load-correlated, continue Branch D.
- If commit-zero is mostly scheduler-correlated, continue Branch C.
- If ready-younger slots are high and independent of other stalls, plan a
  window or retirement structure change.

### H6: Broader Coverage Before Promotion

Objective:

- Keep DSE architectural and avoid Dhrystone/CoreMark overfit.

Coverage ladder:

1. T1 smoke: Dhrystone 100 and CoreMark 1.
2. T2 focused: Dhrystone 100, CoreMark 1, CoreMark 10, branch dense, backend
   ALU chain 8, and branch hotspot.
3. T3 signoff: full `tests/benchmarks/stage1_signoff.json`.
4. T4 generalization: add rows for pointer chasing, memcpy/memset, load-use,
   store-forward, call/return, indirect branch, independent ALU, dependent
   ALU, and cache-pressure microbenchmarks.

Promotion rule:

- A behavior candidate must pass T3 before it becomes the new Stage 2
  baseline.
- T4 is not allowed to excuse a regression in T3. It is used to rank the next
  architectural direction and to expose overfit risk.

### H7: Decision Records Required For Every Trial

Every trial must add a compact block with these fields:

```text
Experiment:
Mechanism class:
Mechanism name:
RTL state or commit:
Baseline artifact:
Run artifacts:
Hypothesis:
Primary target counter:
Cycle-bound companion counter:
Guard counters:
Predicted removable cycles:
Observed counter delta:
Observed cycle delta:
Rows improved:
Rows regressed:
Strict checker status:
Verdict:
Next action:
```

Verdicts:

- Accepted architectural candidate.
- DSE-only evidence.
- Rejected due regression.
- Rejected due correctness.
- Quarantined as overfit risk.

### Immediate Next Session Plan

1. Freeze the current state and decide whether the dirty remap RTL is kept only
   for H1 autopsy or reverted before new instrumentation.
2. Add H1 attribution counters at the simulation boundary where possible. If a
   synthesizable signal must be exposed, keep it as a narrow profiling signal
   and commit it separately from behavior.
3. Rebuild DSim. If DSim has a license conflict, rebuild XSim and run the same
   strict plusargs.
4. Run H1 T1 on Dhrystone 100 and CoreMark 1.
5. If H1 T1 is endpoint-clean and counters are populated, run H1 T2 on the
   six-row set.
6. Classify the current fallthrough-remap behavior:
   DSE-only repaired candidate, rejected due CoreMark 10 regression, or
   ready for a structural B1d repair.
7. If the remap is rejected, revert the dirty behavior and continue with A1
   recovery/refill attribution.
8. If the remap has a clean structural repair target, implement exactly that
   target and rerun T1/T2 with declared counter expectations.
9. If A1 does not expose a multi-percent recovery candidate, move to C0
   scheduler criticality attribution before any backend behavior patch.
10. Only after a clean T2, run T3 full signoff and update the Stage 2 baseline.

### Workstream A1: Recovery Scheduler Attribution

Start in parallel as instrumentation if B1c is compiling or running; do not
promote behavior until B1c T2 is classified.

Hypothesis:

- After checkpoint-boundary repair, recovery candidates exist, but raw
  recovery increases useful-work loss or refill cost because attempts are not
  scheduled with enough resource and frontend context.

Required counters:

- Attempt accepted, blocked, replayed, cancelled, and later full-flush count.
- Candidate resource headroom: free-list, ROB tail, RAT, LSU, writeback, and
  checkpoint read port.
- Recovery attempt age and branch type.
- Useful younger ready entries lost or preserved.
- Refill latency from recovery to fetch request, line response, emitted
  packet, decode packet, and first commit.

Candidate behavior after attribution:

- Resource-aware backend-only recovery scheduler.
- Frontend early redirect only after backend recovery is non-regressing.

Promotion target:

- Branch hotspot at least 3 percent faster.
- CoreMark 1 and CoreMark 10 neutral or faster.
- No Dhrystone or backend guard regression.

### Workstream C0: Scheduler Criticality Attribution

Start after B1/A1 current trials are classified unless the B1c result shows no
frontend counter movement.

Hypothesis:

- CoreMark ALU wait pressure is dominated by blocked producer chains, but the
  correct fix may be select fairness or steering rather than local same-cycle
  ALU chaining.

Required counters:

- Producer-chain depth histogram for each issued and blocked integer uop.
- Producer state: not issued, selected this cycle, waiting on ALU, waiting on
  load, waiting on mul/div, ready-not-selected.
- Select-lost reason by IQ and FU class.
- FU utilization and port conflict by cycle.
- Cross-IQ producer/consumer pairs.
- Age of oldest ready and oldest not-ready entries per IQ.

Candidate behaviors after attribution:

- Age-aware select fairness.
- Simple-integer steering across clusters.
- Registered next-cycle fast-lane wakeup token.
- Producer criticality priority.

Promotion target:

- `xs_bottleneck_dep_wait_on_alu` falls with commit IPC improvement.
- CoreMark 10 improves by at least 3 percent.
- Branch dense, branch hotspot, memory rows, and backend guard rows do not
  regress.

### Workstream D0: Load-Use Attribution

Start before any Dhrystone-specific optimization.

Hypothesis:

- Dhrystone improvement requires reducing load-use or store-forward wait, not
  another frontend or ALU-chain tweak.

Required counters:

- Load issue to data latency buckets.
- Load data to consumer wakeup latency buckets.
- Store-forward wait, hit, miss, and ambiguity reasons.
- D-cache port or bank conflict cycles.
- LSU queue pressure and replay cause.
- Speculative wakeup emitted, consumed, cancelled, and replayed.

Candidate behaviors after attribution:

- Store-forward timing repair.
- Speculative load wakeup with replay correctness.
- D-cache port or banking change only if broad memory rows prove pressure.

Promotion target:

- Dhrystone improves with no CoreMark, branch hotspot, or memory-row
  regression.

### Workstream E0: Commit And Window Attribution

Start only as attribution until Branch B, A, C, and D have clearer root causes.

Hypothesis:

- Commit-zero is currently a symptom of frontend, branch, scheduler, or memory
  stalls rather than a direct commit-width limit.

Required counters:

- ROB head uop class and ready state.
- Ready younger commit slots hidden behind head.
- ROB, IQ, dispatch queue, rename, and PRF pressure during head-block cycles.
- Correlation with redirect recovery, load wait, scheduler not-ready, and
  frontend-zero cycles.

Candidate behaviors after attribution:

- Only implement window or drain changes if E0 proves actual admission or
  retirement structure pressure independent of the other branches.

## DSE Cadence For The Next Sessions

1. Update and commit documentation separately from behavior RTL.
2. Treat B1c next-cycle cursor advancement as rejected for no target-counter
   movement.
3. Treat the current B1d fallthrough-remap RTL as DSE-only until H1 explains
   the CoreMark 10 regression.
4. Do not continue scalar guard tuning on the remap.
5. Run H1 remap regression autopsy if the dirty RTL is kept, otherwise revert
   the behavior and start A1 recovery/refill attribution from the committed
   baseline.
6. Rebuild DSim. If license conflict occurs, rebuild XSim and use the same
   strict plusargs.
7. Run T1 strict smoke with explicit target-counter expectations.
8. If T1 fails, fix or revert before running anything longer.
9. If T1 passes and counters are meaningful, run T2 focused six-row.
10. Classify the trial using the scoring labels in this document.
11. Continue to T3 full 16-row only after T2 is endpoint-clean,
    regression-free, and counter movement matches the hypothesis.
12. Keep every instrumentation slice and every behavior slice in separate
    commits.

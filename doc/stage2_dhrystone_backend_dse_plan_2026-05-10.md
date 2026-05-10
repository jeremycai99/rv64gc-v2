# Stage 2 Dhrystone Backend DSE Plan

Date: May 10, 2026

Status: planning document. This is the pivot plan for raising Dhrystone/DMIPS
through architectural backend latency work while keeping CoreMark
non-regressing. It is not a performance claim and does not promote any RTL
change.

## Current Run State

- No DSim or benchmark run is active.
- The unaccepted frontend fallthrough/remap DSE RTL was reverted before this
  plan. The working tree was clean at the start of this pivot.
- A fresh DSim rebuild was attempted, but the DSim license server rejected the
  checkout with a `maxLeases` failure. No fresh DSim DS-focused long run is
  available from the current turn.
- XSim was rebuilt and used as a fallback for a short DS-only probe, but CM10
  was too slow for a useful four-row run and the XSim run was stopped. The
  partial artifact is
  `benchmark_results/stage2_ds_focus_baseline_xsim_20260510_000006`.
- Counter-shape evidence below uses the latest full profiled DSim artifact:
  `benchmark_results/stage2_bottleneck_baseline_20260509`. Score baselines use
  the fixed-binary baseline requested for this pivot.

## Pivot Rule

Pause the current fractional frontend score-chasing path. The recent frontend
ownership/fallthrough DSE is useful as evidence, but it is not score progress
because CM10 regressed about 1 percent and the regression is not explained.

The next optimization loop targets materially higher Dhrystone/DMIPS with
CoreMark non-regression. Dhrystone is a scalar-latency diagnostic. It must not
be optimized through benchmark software changes, fixed PCs, string special
cases, scalar threshold chasing, loop-buffer revival, or benchmark-shaped
policy.

## Fixed-Binary Score Baseline

| Row | Current metric | Current cycles | Stretch metric | Stretch cycles | Required cycle reduction |
|---|---:|---:|---:|---:|---:|
| Dhrystone 100 | 3.133924 DMIPS/MHz | 18,161 | 4.0 DMIPS/MHz | about 14,229 | 3,932 cycles, 21.7% |
| Dhrystone 300 | 3.193357 DMIPS/MHz | 53,469 | 4.0 DMIPS/MHz | about 42,686 | 10,783 cycles, 20.2% |
| CoreMark 1 | 6.483697 CM/MHz | 154,233 | non-regression | 154,233 or better | no regression |
| CoreMark 10 | 6.705406 CM/MHz | 1,491,334 | non-regression | 1,491,334 or better | no regression |

The Dhrystone target is not reachable through another one-percent local tweak.
The first promoted backend mechanism should have a credible multi-percent DS
upside and must preserve CM1 and CM10.

## Counter Source Caveat

The full bottleneck counters were gathered from
`stage2_bottleneck_baseline_20260509`, whose cycles differ slightly from the
fixed-binary score baseline:

| Row | Fixed-binary score cycles | Counter artifact cycles |
|---|---:|---:|
| DS100 | 18,161 | 18,577 |
| DS300 | 53,469 | 53,890 |
| CM1 | 154,233 | 163,013 |
| CM10 | 1,491,334 | 1,500,110 |

Therefore the counters should be used to rank causes and choose experiments,
not to declare the exact score delta. A fresh DSim profile should replace this
section once the license is available.

## Ranked Bottleneck Report

Important interpretation rule: entry-slot counters can exceed timed cycles
because multiple IQ entries can wait in one cycle. They rank pressure. Cycle
counters such as commit-zero, frontend-zero, packet-empty, redirect recovery,
and load latency histograms bound direct cycle payoff.

| Row | Score cycles | Counter cycles | Load wait | ALU wait | Ready-enq hidden | Store-forward wait | Load issue total | Commit-zero | Frontend zero | Packet-empty | Redirect |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| DS100 | 18,161 | 18,577 | 17,175 | 11,462 | 17,055 | 1,103 | 11,381 | 1,104 | 827 | 745 | 81 |
| DS300 | 53,469 | 53,890 | 49,155 | 40,343 | 43,048 | 4,498 | 33,274 | 3,023 | 2,057 | 1,880 | 176 |
| CM1 | 154,233 | 163,013 | 71,901 | 1,370,358 | 109,361 | 569 | 60,859 | 28,301 | 15,393 | 11,242 | 4,052 |
| CM10 | 1,491,334 | 1,500,110 | 704,872 | 13,495,221 | 1,002,784 | 6,301 | 583,224 | 217,897 | 122,514 | 91,909 | 29,575 |

### Rank 1: Load-Use Consumer Wait

DS100 and DS300 are dominated by load-produced operand wait:

- DS100: `xs_bottleneck_dep_wait_on_load=17,175`.
- DS300: `xs_bottleneck_dep_wait_on_load=49,155`.
- CM1 and CM10 also have load wait, but their dominant pressure is ALU
  dependency wait.

The load latency histogram says this is not primarily a cache-miss problem:

| Row | Load latency 1 | Load latency 2 | Load latency 3+ |
|---|---:|---:|---:|
| DS100 | 11,086 | 206 | 2 |
| DS300 | 30,986 | 2,104 | 5 |
| CM1 | 56,700 | 724 | 20 |
| CM10 | 550,463 | 6,343 | 30 |

Most loads write back in one cycle after issue. The actionable loss is the
consumer seeing the result too late, not the memory system returning data late.
That points at load-wakeup visibility, select priority for load-woken consumers,
and load consumer enqueue timing.

### Rank 2: Ready-At-Enqueue Hidden Work

Ready-at-enqueue hidden work is almost equal to the DS load-wait scale:

- DS100: IQ0/1/2 ready-enq hidden = 17,055.
- DS300: IQ0/1/2 ready-enq hidden = 43,048.
- CM10: IQ0/1/2 ready-enq hidden = 1,002,784.

The old generic enqueue-issue bypass did not qualify as a promoted DS
mechanism because it gave only fractional DS movement and had guard-row
regressions in neighboring variants. However, the counter still indicates a
real structural timing problem: newly visible ready consumers are often hidden
from issue/select for a cycle even when they are legal work.

The next mechanism should not simply re-enable broad `IQ_READY_ENQ_BYPASS`.
It should first identify which ready-at-enqueue cases are load-produced,
consumer-critical, and selected late.

### Rank 3: ALU Producer Wait As A CoreMark Guard

CoreMark is dominated by ALU dependency wait:

- CM1: `xs_bottleneck_dep_wait_on_alu=1,370,358`.
- CM10: `xs_bottleneck_dep_wait_on_alu=13,495,221`.
- The largest sub-bucket is not-yet-issued ALU producers blocked by their own
  operands.

This explains why local ALU/IQ0 chaining was tempting, but the measured
variants were marginal and sometimes guard-row negative. For this DS pivot,
ALU work is a CoreMark non-regression guard and a second mechanism, not the
first DS mechanism.

### Rank 4: Store-Forward And Store Queue Coupling

Store-forward wait is visible, especially in DS300:

- DS100: `xs_bottleneck_lsu_store_forward_wait=1,103`.
- DS300: `xs_bottleneck_lsu_store_forward_wait=4,498`.

This is too small to close the 4.0 DMIPS/MHz gap alone, but it can explain
part of the DS tail and can interact with load-use wakeup. It should be
instrumented with source-specific reasons before a store-forward timing change:
waiting for store address, waiting for store data, forward-data hold, partial
forward, p1 spill, and commit backlog.

### Rank 5: Commit-Zero And ROB Head Block

Commit-zero is secondary on DS:

- DS100: 1,104 commit-zero cycles.
- DS300: 3,023 commit-zero cycles.

This is meaningful but not first-order. It should be treated as a guard that
must fall when the real latency bottleneck improves. If it rises while DS
cycles fall, the mechanism may be hiding another problem.

### Rank 6: Frontend Empty Is A Secondary Bound For DS

Frontend empty is not the DS root cause:

- DS100: `packet_empty=745`, `redirect_recovery=81`.
- DS300: `packet_empty=1,880`, `redirect_recovery=176`.

Frontend work remains important for CoreMark and hotspot rows, but it is not
large enough to explain the DS stretch gap. The current DS-focused loop should
not spend more time on frontend fallthrough scoring unless the backend
candidate changes frontend behavior as a side effect.

## Missing Counters Before RTL Promotion

The existing counters are good enough to choose the next branch, but not good
enough to safely promote a backend RTL change. Add these counters first unless
fresh DSim data already proves the specific cause.

### Load-Use Consumer Attribution

Add entry-slot counters that split load-produced source waits by consumer:

- `xs_bottleneck_dep_load_consumer_alu`
- `xs_bottleneck_dep_load_consumer_bru`
- `xs_bottleneck_dep_load_consumer_load_addr`
- `xs_bottleneck_dep_load_consumer_store_addr`
- `xs_bottleneck_dep_load_consumer_store_data`
- `xs_bottleneck_dep_load_consumer_other`

Add lifecycle counters for load-produced operands:

- producer not issued
- producer issued this cycle
- producer issued but not written back
- producer wrote back this cycle
- producer already done but source still stale
- unknown producer state

These should mirror the ALU lifecycle split already present in the harness.

### Load Wakeup And Select Visibility

Add counters for the specific place where a one-cycle load result is lost:

- load wakeup makes a resident entry ready this cycle
- load wakeup makes an enqueue ready this cycle
- load-woken entry selected same cycle
- load-woken entry selected next cycle
- load-woken entry missed because all issue ports busy
- load-woken entry missed because older ready work won
- load-woken entry missed because FU/port class blocked
- load-woken entry missed because suppress/replay/flush intervened

The key derived ratio is:

`load_wakeup_missed / load_wakeup_candidate`

If that ratio is high on DS and low or benign on CM, the first RTL mechanism
should target load-woken select timing.

### Branch Consumer Wait

The current `xs_bottleneck_dep_wait_on_branch` counts waits on branch/link
producers. It does not answer whether branch uops are waiting on ALU or load
operands.

Add counters for branch consumers blocked by:

- ALU-produced operand
- load-produced operand
- store-side operand
- CSR/multiply/divide/unknown

Only after this split should ALU-to-branch short-chain scheduling be considered
as a DS mechanism.

### Store-Forward Cause Split

Split `xs_bottleneck_lsu_store_forward_wait` into:

- older store address unknown
- older store data unknown
- address and data known but forward-data path busy
- partial or misaligned forward
- port 0 to port 1 spill/hold
- store queue commit backlog
- unknown

Also count cycles from store address ready to store data ready. Some histograms
exist, but the DS plan needs a direct forward-wait cause table.

### Cycle-Bound Load Issue Delay

Current load issue counters are entry-slot oriented. Add cycle-bound counters:

- load IQ has at least one ready load but no load issues
- load IQ ready load lost to older load arbitration
- load IQ ready load blocked by D-cache port conflict
- load IQ ready load blocked by older store address dependency
- load IQ ready load blocked by store queue fullness or retry

This distinguishes true load issue delay from downstream consumer wakeup delay.

### ROB Head Cause Split

Add or surface head-block cause for DS rows:

- head load not complete
- head store not complete
- head branch not resolved
- head ALU not complete
- exception/CSR/serial
- younger ready slots hidden behind blocked head

The current commit-zero number is useful but not actionable enough.

## Proposed First Structural Mechanism

First candidate: load-result wakeup and critical-consumer select repair.

This is not a Dhrystone shortcut and not a revival of the old loop buffer. It
is a general backend timing mechanism: one-cycle load hits should make their
dependent consumers visible to the scheduler at the earliest legal cycle, and
load-woken critical consumers should not be hidden by avoidable enqueue/select
timing.

The mechanism should be staged:

1. Add the missing load-use attribution counters and rerun DS100, DS300, CM1,
   and CM10 with strict checks.
2. If DS load-woken misses are confirmed, add a registered load-wakeup token
   path into the integer, branch, store-address, and store-data issue queues.
   The token must be keyed by physical destination tag and cancel/replay state.
3. Add select-side criticality only for entries made ready by an architecturally
   legal load wakeup. Resident oldest-ready priority remains the baseline unless
   counters prove a specific lost opportunity.
4. Only then consider an enqueue-visible path for load-woken consumers. Avoid
   the old broad ready-enqueue bypass policy unless it can be restricted by
   load-wakeup causality and passes CoreMark and guard rows.

Expected counter movement for a good first candidate:

| Counter | DS100 expected movement | DS300 expected movement | CM expectation |
|---|---:|---:|---|
| `xs_bottleneck_dep_wait_on_load` | down 2,500-4,000 entry slots | down 8,000-12,000 entry slots | neutral or down |
| `xs_bottleneck_iq*_enq_ready_hidden` | down 1,500-2,500 combined | down 5,000-8,000 combined | neutral or down |
| load-wakeup missed/candidate | materially down | materially down | no regression |
| `xs_bottleneck_rob_commit_zero_cycles` | down or neutral | down or neutral | no increase |
| `packet_empty` and `redirect_recovery` | no material increase | no material increase | no material increase |

Cycle target for the first promoted candidate:

- DS100 improves at least 3 percent versus fixed-binary baseline:
  `18,161 -> 17,616` cycles or better.
- DS300 improves in the same direction by at least 2 percent:
  `53,469 -> 52,400` cycles or better.
- CM1 and CM10 are cycle-neutral or faster.
- A stronger candidate should aim for DS100 under 17,000 cycles before a full
  signoff run. The 4.0 DMIPS/MHz target still needs about 14,229 cycles, so
  more than one structural mechanism is likely required.

## Alternative Directions And Order

| Priority | Direction | Why it is in scope | Why it is not first |
|---:|---|---|---|
| 1 | Load-use wakeup and critical-consumer select | Highest DS-specific pressure with one-cycle load latency evidence. General mechanism used in OoO cores. | First. |
| 2 | Store-forward wakeup latency reduction | DS300 has visible forward wait and store queue coupling. | Smaller bound than load-use and needs cause split first. |
| 3 | Scheduler ready-at-enqueue visibility | Very large across DS and CM. | Prior broad bypass DSE was marginal or regressive; needs causality split. |
| 4 | ALU-to-branch short-chain scheduling | Could help DS branch/loop scalar latency if branch consumers wait on ALU/load operands. | Current counters do not yet count branch consumers waiting on ALU/load. |
| 5 | ROB head/commit drain repair | Commit-zero exists on DS and larger on CM. | Likely downstream symptom until head-cause split proves otherwise. |
| 6 | Frontend owner/fallthrough continuation | Still relevant for CoreMark and hotspot rows. | DS frontend empty is too small and current frontend DSE regressed CM10. |

## Non-Regression Gate

Every DS-focused RTL candidate must run with strict owner, delivery, branch
recovery, perf profile, perf counters, and stat dump enabled:

`+FETCH_DELIVERY_CHECK +FETCH_DELIVERY_STRICT +FETCH_OWNER_CHECK +FETCH_OWNER_STRICT +BRANCH_RECOVERY_CHECK +BRANCH_RECOVERY_STRICT +PERF_PROFILE +PERF_COUNTERS +STAT_DUMP +BOTTLENECK_PROFILE`

### T0: Instrumentation Compile

- Build DSim from a clean tree when the license is available.
- XSim compile is acceptable as a syntax fallback, but XSim CM10 is too slow
  to be the full performance gate.
- Instrumentation-only changes must be cycle-identical on DS100 and CM1 before
  they are committed.

### T1: DS Smoke

Rows:

- `dhrystone_100_checkedin`
- `coremark_iter1_generalization`

Promotion from T1 requires:

- DS100 faster by at least 1 percent for a behavior candidate.
- CM1 cycle-neutral or faster.
- All new invariant and stale/cancel counters clean.

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
- Primary counters move as predicted, especially load-wait and load-wakeup
  missed/candidate.

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
  or branch recovery violation counters.

### T4: Full Signoff

Run the full Stage 1 or Stage 2 signoff matrix after T3 passes. A candidate is
not accepted until this run is clean and committed.

## Execution Plan

1. Rebuild DSim from the clean tree once the license is available. If DSim is
   still blocked, use XSim only for compile and DS/CM1 smoke, not for CM10
   performance signoff.
2. Rerun a fresh four-row profiled baseline using the fixed binaries and this
   pivot's plusargs. Replace the counter caveat table with fresh cycles and
   counter data.
3. Add the missing load-use and load-wakeup visibility counters in the
   simulation harness only. Keep synthesizable RTL unchanged.
4. Run T1 and T2 instrumentation gates. Commit the instrumentation if it is
   cycle-neutral and endpoint-clean.
5. Decide the first behavior slice from measured load-wakeup cause data:
   load-woken resident select priority, load-woken enqueue visibility, or
   store-forward wakeup repair.
6. Implement one behavior slice. Do not mix it with unrelated scheduler or
   frontend policy changes.
7. Run T1, T2, T3, then full signoff. Reject or quarantine the slice if CM1 or
   CM10 regresses.
8. Only after a promoted DS improvement is committed, revisit the next
   structural mechanism. The expected second mechanism is store-forward cause
   reduction or branch-consumer short-chain scheduling, depending on the new
   counters.

## Current Verdict

The DS bottleneck is not the current frontend fallthrough path. The strongest
current evidence is load-use consumer latency plus ready-at-enqueue hidden
work. The first structural backend mechanism should target load-result wakeup
and critical-consumer select visibility, with CoreMark treated as a hard
non-regression gate.

No RTL behavior change should be promoted until:

- Fresh profiled data is gathered from the clean tree or the existing counter
  artifact is explicitly accepted as the starting shape.
- Load-use consumer attribution confirms the exact missed timing point.
- DS100 and DS300 improve materially.
- CM1 and CM10 do not regress.

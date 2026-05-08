# Stage 2 Frontend Optimization Target, 2026-05-06

## Purpose

Stage 2 should turn the frontend ownership refactor into measurable,
general performance. The target is not another local packet or PC shortcut.
The target is a structurally decoupled, BPU-owned frontend that can run ahead
safely while preserving FTQ identity through IFU, IBuffer, decode, and
commit/training.

Aggressive multi-stage signoff targets:

| Metric | Target |
|---|---:|
| CoreMark/MHz | 7.5 |
| DMIPS/MHz | 4.0 |

These targets are not a frontend-only promise. The frontend slice must first
close the measured MegaBOOM gap without endpoint drift. If frontend-only work
does not reach the Gate C ceiling below, open a second-domain DSE from
counters, not intuition.

## Current Scoreboard

Latest committed cleanup point:

- Commit: `3e58a93 fix rename hold decode ownership`
- Accepted RTL delta: rename hold ownership fix only.
- Rejected and removed: subgroup/owner-complete successor allocation trials.

Current scoreable rows:

| Workload | Source | Timed cycles | Metric | Status |
|---|---|---:|---:|---|
| Dhrystone 100 | `benchmark_results/20260507_stage2_rename_hold_clean_smoke` | 22,189 | 2.565019 DMIPS/MHz | PASS |
| CoreMark 1 | `benchmark_results/20260507_stage2_rename_hold_clean_smoke` | 195,632 | 5.111638 CoreMark/MHz | PASS |
| CoreMark 10 | `benchmark_results/20260507_stage2_rename_hold_clean_coremark10` | 1,926,763 | 5.190052 CoreMark/MHz | PASS |
| Dhrystone 300 | `benchmark_results/20260507_pred_ctl_start_stage1_goal` | 64,719 | 2.638261 DMIPS/MHz | PASS, previous full-goal row |

Current gap to the Stage 2 stretch targets:

| Metric | Current row | Target | Required score uplift | Equivalent cycle reduction |
|---|---:|---:|---:|---:|
| CoreMark/MHz | 5.190052 | 7.5 | +44.5% | 30.8% |
| DMIPS/MHz | 2.638261 | 4.0 | +51.6% | 34.0% |

Current calibrated MegaBOOM comparison on shared smoke rows:

| Workload | MegaBOOM calibrated | rv64gc-v2 current | Current gap |
|---|---:|---:|---:|
| Dhrystone 100 | 23,814 cycles | 22,189 cycles | rv64gc-v2 6.8% faster |
| CoreMark 1 | 192,249 cycles | 195,632 cycles | rv64gc-v2 1.8% slower |

Interpretation:

- Stage 1 is effectively closed on Dhrystone 100 and nearly closed on
  CoreMark 1, but CoreMark 10 still shows a meaningful frontend and recovery
  gap.
- The latest rename fix is correctness-preserving and mostly performance
  neutral versus the immediately previous accepted smoke baseline.
- The aggressive 7.5 CM/MHz and 4.0 DMIPS/MHz targets require structural
  performance work beyond the small cursor/runahead gains already landed.

## Accepted Evidence

The accepted frontend path so far:

| Slice | Key result | Verdict |
|---|---|---|
| Owned same-owner IFU cursor advance | Dhrystone 100 `27,093 -> 26,080`, CoreMark 1 `209,058 -> 199,331`; strict owner/delivery and golden PC clean. | Keep. It proves duplicate/no-emit pressure is real when bounded by predicted-control reachability. |
| Predicted-control-start advance | Dhrystone 100 `26,080 -> 22,290`, CoreMark 1 `199,331 -> 196,124`; broad smoke clean. | Keep. This is the first broad, endpoint-clean frontend improvement. |
| Depth-1 direct-taken BPU/F1 runahead | Dhrystone 100 `22,290 -> 22,189`, CoreMark 1 `196,124 -> 195,632`; `xs_ftq_occ_max` reaches 2. | Keep. It proves bounded runahead is active, but the gain is marginal. |
| Owner-keyed IBuffer delivery | No speed change, owner/stale counters remain clean. | Keep as a guardrail. It prevents future-owner decode leakage once upstream backlog exists. |
| Rename hold ownership fix | CoreMark 10 passes with checksum `64687`, flags `0`, 1,926,763 timed cycles. | Keep. It fixes a traced dropped-tail bug when held rename work shares a cycle with a fresh decode packet. |

Current important counters from the final CoreMark 10 row:

| Counter | Value | Meaning |
|---|---:|---|
| `xs_f2_owner_idx_mismatch` | 0 | F2 owner identity clean. |
| `xs_packet_stale_idx_mismatch` | 0 | Decode-facing packet owner clean. |
| `xs_packet_buffer_stale_owner` | 0 | No stale owner packet consumed. |
| `xs_ftq_occ_max` | 2 | Runahead exists but remains shallow. |
| `xs_packet_buf_occ_max` | 8 | IBuffer can hold packets on the heavy row. |
| `packet_empty_noemit_dup` | 631,880 | Duplicate/no-emit pressure remains very large. |
| `packet_empty_f2_data` | 661,446 | F2 data/no-emit bucket remains dominant. |

## Rejected Evidence

Rejected trials that should not be revived in their old form:

| Trial | Failure | Keep as evidence |
|---|---|---|
| Disable duplicate guard | Strict delivery aborts at cycle 6 with replayed reset-vector PCs. | Duplicate suppression is still protecting a real structural hazard. Remove it only after owner delivery makes duplicates impossible. |
| One-line same-owner cursor advance | Dhrystone improves to about 21.6K cycles, but CoreMark skips a compressed fall-through PC and fails golden PC. | The direction has leverage; the implementation was incomplete. |
| Unconditional predicted-control owner split | Endpoint-clean but regresses CoreMark 1 badly. | Predicted-control ownership must be selective, not a blunt split-before-control policy. |
| Same-cycle subgroup successor allocation | Dhrystone improves, CoreMark times out or corrupts ownership. | Future-owner production without owner-keyed delivery is unsafe. |
| Owner-complete successor allocation | Dhrystone/CoreMark 1 improve, but branch hotspot and CoreMark 10 fail. | The transition gap is real, but owner-start packet delivery must be atomic with FTQ allocation and IFU cursor selection. |
| Guarded successor retry after rename fix | Owner/stale counters become clean, but CoreMark 10 checksum is `17144` instead of `64687`. | Do not carry the old trial RTL forward as-is. Keep successor runahead as an active bug-isolation and performance path. |

The key rejected-successor lesson is specific: allocating a new owner is not
enough. The first packet for that owner must be delivered from the owner-start
PC exactly once, with matching FTQ identity, ICQ response association,
prediction snapshot, and completion state.

The successor trials should not be abandoned. They showed material performance
potential on smaller rows, so the failure should be treated as a pipeline
contract bug revealed by deeper workloads. The next successor work must start
from the clean baseline and add observability around the owner transition:
allocated successor PC, selected IFU work PC, ICQ response owner, first packet
PC, IBuffer owner, rename hold ownership, and retired golden PC. A successor
trial is scoreable only after Dhrystone, CoreMark 1, CoreMark 10, and the branch
hotspot probe all pass endpoint and golden-PC checks.

Bug-isolation progress, 2026-05-07:

- Added simulation assertions for owner-start delivery. `INVARIANT_G` now
  checks next-owner cursor load against the FTQ owner-start PC, not a stale
  sequential PC assumption. `INVARIANT_G1/G2` check that the first packet
  delivered for any owner starts exactly at the FTQ owner-start PC and carries
  the live IFU work owner metadata.
- Cleaned the same-owner advance event used by assertions/profiling so it
  reports actual same-owner cursor advancement, not a candidate cycle that is
  overridden by redirect, next-owner load, or request-owner load.
- CoreMark 10 exposed old `INVARIANT_I` hits that were assertion scope, not
  endpoint corruption: all detailed hits crossed an FTQ epoch change during
  redirect recovery. The invariant is now scoped to ignore epoch transitions.
- Validation artifacts:
  `benchmark_results/20260507_successor_owner_start_assert_epochfix_smoke`
  and
  `benchmark_results/20260507_successor_owner_start_assert_epochfix_coremark10`.
  Dhrystone 100, CoreMark 1, and CoreMark 10 all pass with strict
  owner/delivery checks, profiling, and no invariant/error signatures.

## Architecture State

rv64gc-v2 is aligned in direction with the XiangShan/BOOM-style frontend split,
but it is not yet deep enough.

| Role | Current state | Remaining gap |
|---|---|---|
| BPU | Can launch bounded depth-1 direct-taken runahead. JALR/RET are excluded. | Not yet a sustained predicted owner stream. BPU timing/quality has not been proven the limiter. |
| FTQ | Allocation, IFU request, IFU writeback, and commit/training views are split. | Depth is still effectively shallow. Owner-start delivery is not robust enough for subgroup successor allocation. |
| IFU | `ifu_work_item_t` carries PC, line address, FTQ identity, and owner-delivered state. Same-owner cursor advance is bounded by owner and predicted-control rules. | Needs a real owner work/request queue before depth-2 runahead. Duplicate suppression remains a crutch. |
| IBuffer | Decode-facing packet buffer is owner-aware and can select the oldest matching commit-owner packet. | It must be fed by real owner-tagged upstream backlog, then scored by occupancy and stale-owner counters. |
| Rename | Held work now owns rename input for one cycle and stalls decode. | This is a correctness fix, not a frontend performance mechanism. |

## Active Bottleneck Hypothesis

The current frontend still spends too many cycles in F2 data/no-emit and
duplicate/no-emit buckets. The likely root cause is not nominal decode width;
it is insufficient owner-decoupled frontend supply. The next improvement must
make FTQ, IFU, ICQ, and IBuffer operate as independent owner-tagged stages,
not as a mirrored F1/F2 flow-through path.

Promotion conditions:

| Gate | Objective | Required evidence |
|---|---|---|
| A | Lock current accepted RTL as scoreable baseline. | Full scoreable run from committed RTL, strict checks, endpoint identity, broad smoke pass. |
| B | Prove true frontend runahead. | `xs_ftq_occ_max > 1`, nonzero IBuffer occupancy on meaningful rows, lower duplicate/no-emit broadly, no owner/stale drift. |
| C | Score frontend-only ceiling. | Heavy rows should approach roughly 6.0 CM/MHz and 3.2 DMIPS/MHz after depth-1 or depth-2 runahead. |
| D | Pick second-domain limiter. | Branch/recovery, uop-count, LSU/load-use, ROB-head, and scheduler counters identify one dominant residual. |
| E | Stretch to final target. | Full manifest passes, no major off-target regression, then compare against 7.5 CM/MHz and 4.0 DMIPS/MHz. |

If Gate C fails, stop treating frontend-only DSE as sufficient. Promote the
counter-backed second domain instead.

## Workable Options

| Option | Status | Expected benefit | Guardrail |
|---|---|---|---|
| Baseline counter pass | Required next | Prevents another stale methodology loop. | Use committed RTL and full strict plusargs. |
| Successor runahead bug isolation | Active, instrumentation landed | Preserves the high-leverage smaller-row gain while finding the CoreMark 10 corruption mechanism. | Reintroduce the successor reproducer only after owner-start assertions stay clean on baseline; any perf claim still needs endpoint and golden-PC evidence. |
| Owner request queue / IFU work queue | Primary structural frontend slice | Lets IFU request and F2 delivery decouple by FTQ owner. | Owner-start PC delivery exactly once; no stale ICQ response consumption. |
| Capacity-bounded depth-2 runahead | Only after queue cleanup | More useful fetch overlap. | Do not promote if it increases redirect or ICQ head blocking enough to erase gains. |
| Early fetch-line metadata | High value | Reduces conservative predicted-control and RVC boundary stalls. | Golden PC clean on mixed RVC/control windows. |
| BPU/FTQ training metadata cleanup | High value | Improves attribution and enables safe prediction experiments. | Preserve GHR/RAS/target snapshots per owner. |
| BPU S0/uBTB | Conditional | May help if lookup latency or direction quality blocks runahead. | Promote only with per-PC branch data or timing evidence. |
| Indirect prediction | Conditional | Helps if indirect MPKI is material. | Per-PC evidence required. |
| Fusion/uop accounting | Orthogonal candidate | Reduces useful work per frontend slot and backend pressure. | Pattern frequency and retired-stream identity required. |
| LSU/load-use or backend balance | Later candidate | Addresses non-frontend residuals. | Open only after Gate C or counter evidence says frontend is no longer dominant. |

## Evidence Required

Every accepted performance row must report:

- Endpoint identity: checksum, flags, iterations, `tohost`.
- Strict owner/delivery checks:
  `+FETCH_DELIVERY_CHECK +FETCH_DELIVERY_STRICT +FETCH_OWNER_CHECK
  +FETCH_OWNER_STRICT`.
- `+PERF_PROFILE +PERF_COUNTERS +STAT_DUMP`.
- Frontend supply histogram and frontend-zero percentage.
- `packet_empty_noemit_dup`, `packet_empty_f2_data`,
  `packet_empty_wait_icresp`.
- FTQ occupancy histogram and `xs_ftq_occ_max`.
- IBuffer occupancy histogram and stale-owner counters.
- Redirect recovery cycles.
- Commit width histogram and timed IPC.
- Golden PC scoreboard where available.

## Implementation Order

| Phase | Task | Exit criterion |
|---|---|---|
| 0 | Rerun full baseline from commit `3e58a93`. | Gate A passes and becomes the new comparison anchor. |
| 1 | Reproduce and isolate the successor transition bug from clean RTL. | Owner-start assertions are in place; next exit is first failing successor transition caught by assertion or golden PC, not by late checksum drift. |
| 2 | Convert the successor fix into owner-tagged IFU request/work queue semantics. | Owner-start delivery is exact; strict checks and CoreMark 10 checksum pass. |
| 3 | Re-score depth-1 successor/runahead with real upstream backlog. | Duplicate/no-emit falls without ICQ wait or redirect recovery replacing it. |
| 4 | Try depth-2 only if Phase 3 is clean. | Heavy rows improve with no endpoint drift. |
| 5 | Score frontend-only ceiling. | Gate C passes or fails explicitly. |
| 6 | Open one second-domain DSE if Gate C fails. | Gate D names the limiter before RTL work starts. |
| 7 | Re-score against MegaBOOM and stretch targets. | Gate E passes on broad coverage. |

## Explicit Non-Goals

- No loop buffer revival.
- No benchmark-PC steering.
- No standalone same-line, same-FTQ-tail, or sequential lookahead shortcut.
- No duplicate suppression as the final correctness mechanism.
- No widening decode, rename, or commit in this frontend slice.
- No active XiangShan-style `pfPtr` until demand ownership is working.
- No LSU, cache, or backend latency DSE until counters justify the domain.

## Verdict

The next frontend work should keep successor runahead alive, but treat the
previous implementation as a bug reproducer rather than a candidate to keep.
The prior successor trials proved there is performance in earlier owner
transition, especially on smaller rows, and they also exposed that the current
owner-start delivery contract is too weak.

Near-term objective: produce real, strict-clean FTQ and IBuffer occupancy and
reduce CoreMark 10 duplicate/no-emit pressure without checksum drift. The
successor bug isolation is part of that objective, not a discarded side branch.
Long-term objective remains 7.5 CM/MHz and 4.0 DMIPS/MHz, with a required
second-domain escalation if frontend-only work does not reach the Gate C
ceiling.

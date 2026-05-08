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

Latest scoreable successor point:

- Accepted RTL delta: owner-complete successor allocation, IFU successor request
  selection, IBuffer fire-qualified decode valid, and rename total-block
  backpressure.
- Rejected and removed: benchmark-window trace probes and previous unguarded
  successor variants.

Current scoreable rows:

| Workload | Source | Timed cycles | Metric | Status |
|---|---|---:|---:|---|
| Dhrystone 100 | `benchmark_results/20260507_successor_rename_total_block_stall_final_smoke` | 19,611 | 2.965569 DMIPS/MHz | PASS |
| CoreMark 1 | `benchmark_results/20260507_successor_rename_total_block_stall_final_smoke` | 175,318 | 6.007521 CoreMark/MHz | PASS |
| CoreMark 10 | `benchmark_results/20260507_successor_rename_total_block_stall_final_coremark10` | 1,642,655 | 6.120764 CoreMark/MHz | PASS |
| Branch hotspot probe | `benchmark_results/20260507_successor_rename_total_block_stall_final_smoke` | 146,142 | 1.072300 IPC | PASS |
| Dhrystone 300 | `benchmark_results/20260507_pred_ctl_start_stage1_goal` | 64,719 | 2.638261 DMIPS/MHz | PASS, previous full-goal row |

Current gap to the Stage 2 stretch targets:

| Metric | Current row | Target | Required score uplift | Equivalent cycle reduction |
|---|---:|---:|---:|---:|
| CoreMark/MHz | 6.120764 | 7.5 | +22.5% | 18.4% |
| DMIPS/MHz | 2.965569 | 4.0 | +34.9% | 25.9% |

Current calibrated MegaBOOM comparison on shared smoke rows:

| Workload | MegaBOOM calibrated | rv64gc-v2 current | Current gap |
|---|---:|---:|---:|
| Dhrystone 100 | 23,814 cycles | 19,611 cycles | rv64gc-v2 17.6% faster |
| CoreMark 1 | 192,249 cycles | 175,318 cycles | rv64gc-v2 8.8% faster |

Interpretation:

- The successor path is now a real accepted Stage 2 frontend improvement, not
  just a smaller-row hint. It improves Dhrystone 100, CoreMark 1, CoreMark 10,
  and the branch hotspot probe with strict owner/delivery checks enabled.
- The new row beats the calibrated MegaBOOM smoke baseline on the shared
  Dhrystone 100 and CoreMark 1 timing windows.
- The aggressive 7.5 CM/MHz and 4.0 DMIPS/MHz targets still require another
  structural step. The remaining gap is smaller, but not closed.

## Accepted Evidence

The accepted frontend path so far:

| Slice | Key result | Verdict |
|---|---|---|
| Owned same-owner IFU cursor advance | Dhrystone 100 `27,093 -> 26,080`, CoreMark 1 `209,058 -> 199,331`; strict owner/delivery and golden PC clean. | Keep. It proves duplicate/no-emit pressure is real when bounded by predicted-control reachability. |
| Predicted-control-start advance | Dhrystone 100 `26,080 -> 22,290`, CoreMark 1 `199,331 -> 196,124`; broad smoke clean. | Keep. This is the first broad, endpoint-clean frontend improvement. |
| Depth-1 direct-taken BPU/F1 runahead | Dhrystone 100 `22,290 -> 22,189`, CoreMark 1 `196,124 -> 195,632`; `xs_ftq_occ_max` reaches 2. | Keep. It proves bounded runahead is active, but the gain is marginal. |
| Owner-keyed IBuffer delivery | No speed change, owner/stale counters remain clean. | Keep as a guardrail. It prevents future-owner decode leakage once upstream backlog exists. |
| Rename hold ownership fix | CoreMark 10 passes with checksum `64687`, flags `0`, 1,926,763 timed cycles. | Keep. It fixes a traced dropped-tail bug when held rename work shares a cycle with a fresh decode packet. |
| Owner-complete successor allocation plus rename total-block stall | Dhrystone 100 `22,189 -> 19,611`, CoreMark 1 `195,632 -> 175,318`, CoreMark 10 `1,926,763 -> 1,642,655`; branch hotspot also improves `152,021 -> 146,142`. | Keep. This is the first broad, strict-clean successor-runahead improvement. |

Current important counters from the accepted CoreMark 10 row:

| Counter | Value | Meaning |
|---|---:|---|
| `xs_f2_owner_idx_mismatch` | 0 | F2 owner identity clean. |
| `xs_packet_stale_idx_mismatch` | 0 | Decode-facing packet owner clean. |
| `xs_packet_buffer_stale_owner` | 0 | No stale owner packet consumed. |
| `xs_ftq_occ_max` | 2 | Runahead exists but remains shallow. |
| `xs_packet_buf_occ_max` | 8 | IBuffer can hold packets on the heavy row. |
| `xs_runahead_req_fire` | 114,729 | Successor requests are active on the heavy row. |
| `xs_runahead_pending_cycles` | 223,297 | The frontend has useful outstanding owner work. |
| `packet_empty_noemit_dup` | 196,264 | Still large, but down 68.9% from the clean baseline. |
| `packet_empty_f2_data` | 229,907 | Still dominant, but down 65.2% from the clean baseline. |
| `packet_empty_wait_icresp` | 39,329 | Down 91.5% from the clean baseline. |

## Rejected Evidence

Rejected trials that should not be revived in their old form:

| Trial | Failure | Keep as evidence |
|---|---|---|
| Disable duplicate guard | Strict delivery aborts at cycle 6 with replayed reset-vector PCs. | Duplicate suppression is still protecting a real structural hazard. Remove it only after owner delivery makes duplicates impossible. |
| One-line same-owner cursor advance | Dhrystone improves to about 21.6K cycles, but CoreMark skips a compressed fall-through PC and fails golden PC. | The direction has leverage; the implementation was incomplete. |
| Unconditional predicted-control owner split | Endpoint-clean but regresses CoreMark 1 badly. | Predicted-control ownership must be selective, not a blunt split-before-control policy. |
| Same-cycle subgroup successor allocation | Dhrystone improves, CoreMark times out or corrupts ownership. | Future-owner production without owner-keyed delivery is unsafe. |
| Owner-complete successor allocation before rename total-block stall | Dhrystone/CoreMark 1 improve, but branch hotspot and CoreMark 10 fail. | The transition gap was real. The later accepted fix shows the failure was a pipeline contract bug, not a dead direction. |
| Guarded successor retry before final rename fix | Owner/stale counters become clean, but CoreMark 10 checksum is `17144` instead of `64687`. | Superseded by the accepted total-block stall fix. Do not revive the old RTL shape. |

The resolved successor lesson is specific: allocating a new owner was not the
only risk. The first packet for that owner must be delivered from the owner
start PC exactly once, and decode/rename must not consume a fresh packet when
rename can advance none of its slots. The accepted fix keeps the owner-start
path and tightens rename backpressure so the frontend cannot silently skip a
fresh packet under total allocation block.

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
- Final root cause: when a fresh decode packet had zero advancing rename slots,
  rename previously deasserted `stall`. Decode/IBuffer could advance while the
  packet made no progress, which later appeared as a skipped/reordered PC in
  CoreMark golden-PC checking. The fix stalls on total fresh-packet block and
  captures non-advanced work only when hold already owns rename or at least one
  work slot advanced.
- Validation artifacts:
  `benchmark_results/20260507_successor_rename_total_block_stall_final_smoke`
  and
  `benchmark_results/20260507_successor_rename_total_block_stall_final_coremark10`.
  Dhrystone 100, CoreMark 1, CoreMark 10, and the branch hotspot probe all pass
  with strict owner/delivery checks, profiling, and no endpoint drift.

## Architecture State

rv64gc-v2 is aligned in direction with the XiangShan/BOOM-style frontend split,
but it is not yet deep enough.

| Role | Current state | Remaining gap |
|---|---|---|
| BPU | Can launch bounded depth-1 direct-taken runahead and accepted owner-complete successor requests. JALR/RET are excluded. | Not yet a sustained predicted owner stream. BPU timing/quality has not been proven the limiter. |
| FTQ | Allocation, IFU request, IFU writeback, and commit/training views are split. `xs_ftq_occ_max=2` on the accepted heavy row. | Depth is still effectively shallow. Depth-2 needs an owner request queue before promotion. |
| IFU | `ifu_work_item_t` carries PC, line address, FTQ identity, and owner-delivered state. It can select a successor request after owner completion and hold an undelivered owner stable. | Needs a real owner work/request queue before deeper runahead. Duplicate suppression remains a crutch. |
| IBuffer | Decode-facing packet buffer is owner-aware and decode valid is qualified by actual dequeue fire. | It must be fed by deeper owner-tagged upstream backlog, then scored by occupancy and stale-owner counters. |
| Rename | Held work owns rename input; fresh packets stall when no slot can advance, while partial progress captures the non-advanced tail. | This is now a required frontend-runahead contract. Remaining rename stalls should be tracked as backend pressure, not frontend supply. |

## Active Bottleneck Hypothesis

The accepted successor path removes a large part of the F2 data/no-emit and
duplicate/no-emit buckets, but those buckets remain the largest frontend
opportunity on CoreMark 10. The likely residual root cause is not nominal
decode width; it is still insufficient owner-decoupled frontend supply. The
next improvement must make FTQ, IFU, ICQ, and IBuffer operate as independent
owner-tagged stages, not as a mirrored F1/F2 flow-through path.

Promotion conditions:

| Gate | Objective | Required evidence |
|---|---|---|
| A | Lock current accepted RTL as scoreable baseline. | Full scoreable run from committed RTL, strict checks, endpoint identity, broad smoke pass. |
| B | Prove true frontend runahead. | Achieved for depth-1 successor: `xs_ftq_occ_max=2`, nonzero IBuffer occupancy on CoreMark, lower duplicate/no-emit broadly, no owner/stale drift. |
| C | Score frontend-only ceiling. | CoreMark already exceeds 6.0 CM/MHz; Dhrystone still needs movement toward roughly 3.2 DMIPS/MHz before deciding frontend-only has topped out. |
| D | Pick second-domain limiter. | Branch/recovery, uop-count, LSU/load-use, ROB-head, and scheduler counters identify one dominant residual. |
| E | Stretch to final target. | Full manifest passes, no major off-target regression, then compare against 7.5 CM/MHz and 4.0 DMIPS/MHz. |

If Gate C fails, stop treating frontend-only DSE as sufficient. Promote the
counter-backed second domain instead.

## Workable Options

| Option | Status | Expected benefit | Guardrail |
|---|---|---|---|
| Baseline counter pass | Required after commit | Prevents another stale methodology loop. | Use committed RTL and full strict plusargs. |
| Successor runahead | Accepted depth-1 slice | Keeps owner-complete successor allocation active and broadly profitable. | Any further change still needs endpoint, strict owner/delivery, and golden-PC evidence where available. |
| Owner request queue / IFU work queue | Primary next structural frontend slice | Lets IFU request and F2 delivery decouple by FTQ owner instead of relying on a single pending successor. | Owner-start PC delivery exactly once; no stale ICQ response consumption. |
| Capacity-bounded depth-2 runahead | Next candidate after queue cleanup | More useful fetch overlap and fewer F2 no-emit cycles. | Do not promote if it increases redirect or ICQ head blocking enough to erase gains. |
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
| 0 | Lock the accepted successor and rename backpressure slice. | Gate A candidate is trackable from source control and has final strict smoke plus CoreMark 10 evidence. |
| 1 | Reconfirm from a clean committed checkout if needed. | Results match the accepted rows within normal determinism and no stale debug harness is required. |
| 2 | Add a real owner request queue / IFU work queue. | Owner-start delivery remains exact; CoreMark 10, Dhrystone, and branch hotspot pass. |
| 3 | Re-score queued successor/runahead. | Duplicate/no-emit falls further without ICQ wait, redirect recovery, or rename stalls replacing it. |
| 4 | Try capacity-bounded depth-2 runahead. | Heavy rows improve with no endpoint drift and no off-target regression. |
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

The successor path should be pursued. It is now strict-clean on the scoreable
smoke plus CoreMark 10, it beats the calibrated MegaBOOM smoke rows, and it
cuts the dominant CoreMark 10 frontend-empty buckets by roughly two thirds.

Near-term objective: use this as the new Stage 2 frontend baseline, then
replace the single pending successor mechanism with an owner-tagged IFU
request/work queue. Long-term objective remains 7.5 CM/MHz and 4.0
DMIPS/MHz, with a required second-domain escalation if frontend-only work does
not reach the Gate C ceiling.

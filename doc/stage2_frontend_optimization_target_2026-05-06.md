# Stage 2 Frontend Optimization Target, 2026-05-06

## Purpose

Stage 2 should turn the current frontend ownership refactor into measurable
performance. The target is not another local packet/PC shortcut. The target is
a structurally decoupled, BPU-owned frontend that can run ahead safely while
preserving FTQ identity through IFU, IBuffer, decode, and commit/training.

The aggressive multi-stage signoff targets remain:

| Metric | Target |
|---|---:|
| CoreMark/MHz | 7.5 |
| DMIPS/MHz | 4.0 |

These targets should not be treated as a frontend-only promise. The current
frontend slice must first close the measured Stage 1 gap to MegaBOOM and prove
that proactive frontend supply improves real benchmark cycles without endpoint
drift. Broader memory, execution, or uop-count work should be opened only after
post-refactor counters show the remaining limiter.

## Current Baseline

The calibrated MegaBOOM comparison still shows rv64gc-v2 behind on the shared
smoke rows:

| Workload | MegaBOOM calibrated | rv64gc-v2 timed | Gap |
|---|---:|---:|---:|
| Dhrystone 100 | 23,814 cycles | 26,394 cycles | rv64gc-v2 +9.8% cycles |
| CoreMark 1 | 192,249 cycles | 207,775 cycles | rv64gc-v2 +7.5% cycles |

The current frontend refactor is structurally useful but nearly
performance-neutral. `tools/bubble_attribution.py` on CoreMark 10 reports the
current commit-stage shape:

| Category | % of run | Meaning |
|---|---:|---|
| PRODUCTIVE | 79.1% | commit > 0 |
| BACKEND_STALL | 11.3% | fetch available, ROB occupied, commit blocked |
| FRONTEND_BUBBLE | 5.7% | no fetch supply while ROB occupied |
| IDLE_BUBBLE | 1.4% | no fetch supply and ROB empty |
| FLUSH | 1.0% | redirect/recovery |
| RAMP | 1.6% | reset/edge effects |

The visible commit-stage frontend bubble is small, but the frontend-stage
decode supply rate is only about 58.5%. The working hypothesis is that better
proactive frontend supply keeps more independent work in flight, which can
reduce both frontend bubbles and some apparent ROB-head backend stalls.

## Kickoff Study, 2026-05-07

The first Stage 2 pass rebuilt DSim from clean post-refactor commit `7837713`
and reran the two strict smoke rows with:
`+FETCH_DELIVERY_CHECK +FETCH_DELIVERY_STRICT +FETCH_OWNER_CHECK
+FETCH_OWNER_STRICT +PERF_PROFILE +PERF_COUNTERS +STAT_DUMP`.

Baseline run: `benchmark_results/20260507_stage2_post_refactor_baseline`.

| Workload | Status | Timed cycles | Metric | Frontend zero | `packet_empty_noemit_dup` | `packet_empty_f2_data` | `ftq_occ_max` | `packet_buf_occ_max` |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| Dhrystone 100 | PASS | 27,093 | 2.100734 DMIPS/MHz | 35.4% | 9,098 | 9,410 | 1 | 0 |
| CoreMark 1 | PASS | 209,058 | 4.783362 CM/MHz | 41.9% | 82,614 | 85,756 | 1 | 0 |

This confirms the current frontend is still shallow: FTQ occupancy never rises
above one owner, the IBuffer is flow-through only on these rows, and the
dominant actionable frontend bucket remains duplicate/no-emit pressure caused
by the IFU work cursor lagging useful same-owner packet progress.

Two quick RTL trials were run to test whether that diagnosis is real. Both are
rejected as default behavior, but they are useful direction evidence.

| Trial | Run directory | Result | Verdict |
|---|---|---|---|
| Disable `ifu_duplicate_guard` suppression | `benchmark_results/20260507_trial_disable_duplicate_guard` | Both rows abort at cycle 6 under strict delivery: expected owner stream PC `0x000000008000000c`, got replayed `0x0000000080000000`. | Reject. The guard is still protecting a real duplicate stream. Do not remove it before the IFU/ICQ owner contract makes duplicates structurally impossible. |
| Advance IFU work PC to `seq_next_pc` on same-owner continuation | `benchmark_results/20260507_trial_same_owner_cursor_advance` | Dhrystone passes and improves to 21,496 timed cycles, 2.647711 DMIPS/MHz; duplicate/no-emit falls from 9,098 to 3,308. CoreMark times out at 1,000,000 cycles with 949,359 retired instructions, 52,524 redirect-recovery cycles, and clean owner/stale counters. | Reject as default. The counter movement proves the cursor direction has leverage, but CoreMark loses endpoint progress. |
| Same as above, but only when the packet really emits | `benchmark_results/20260507_trial_same_owner_emit_cursor_advance` | Dhrystone passes and improves to 21,597 timed cycles, 2.635329 DMIPS/MHz; CoreMark still times out at 1,000,000 cycles with the same clean owner/stale counters and high redirect activity. | Reject as default. Emission gating is necessary but not sufficient. |

Interpretation:

- The targeted counter is real. Same-owner cursor advance cuts Dhrystone
  frontend zero cycles from 35.4% to about 18.5% and improves Dhrystone by
  roughly 20% timed cycles.
- The current strict owner/delivery checks are necessary but not sufficient for
  CoreMark. CoreMark can keep owner packet identity clean while still losing
  architectural endpoint progress through control-flow or data-state drift.
- The next accepted implementation must not be a one-line same-owner shortcut.
  It needs an explicit IFU work/response contract: emitted packet PC,
  FTQ owner identity, ICQ response line, BPU/RAS/GHR snapshot, and completion
  state must advance as one owned work item.

Immediate follow-up before the next RTL change:

1. Generate a fresh CoreMark 1 golden PC stream from the clean baseline, then
   rerun the same-owner cursor trial with `+CHECK_GOLDEN_PCS` to find the first
   architectural divergence instead of waiting for a timeout.
2. Use `+TRACE_COMMIT`, `+TRACE_COREMARK_PROGRESS`, and targeted branch traces
   around the hot CoreMark PCs seen in the timeout (`0x80002380`,
   `0x800023ae`, `0x80002fb8`, `0x80002ffa`) to separate frontend delivery
   drift from backend state corruption.
3. Implement the real Phase 1 cursor decoupling as an owned IFU work item tied
   to ICQ response acceptance and FTQ IFU-writeback advancement. Keep the
   duplicate guard enabled until that path passes CoreMark endpoint and golden
   PC checks.

Follow-up result:

- A clean CoreMark 1 golden PC stream was generated from the post-refactor
  baseline: `benchmark_results/20260507_stage2_coremark_iter1_baseline.golden.hex`.
  It contains 332,110 committed PCs and has sha256
  `9746a895591ff24d2f50d2cb244f04ee7760406e310ddf1e6a1bb50eab9911ff`.
- Rerunning the same-owner emit-gated cursor trial with that golden stream
  fails at the first architectural divergence instead of timing out:
  sequence 7,056 expected `0x0000000080002ffe`, actual
  `0x0000000080003000`.
- The failing window is a mixed-width CoreMark loop tail:
  `0x80002ffa: bne`, `0x80002ffe: c.addiw`, `0x80003000: addw`.
  Baseline emits and retires `0x80002ffe` correctly in this window and reports
  `GOLDEN_PC OK` through the same partial run. The trial skips the compressed
  fall-through instruction while existing owner/stale counters remain clean.

Revised verdict: this is not a scoreable performance iteration, but it should
not remove same-owner cursor decoupling from the option list. The row is a
failed counter probe of an incomplete implementation. The regression is caused
by a local cursor change, not by benchmark methodology. The one-line advance
changes the work PC without atomically advancing the full IFU work item: owner
identity, ICQ line response association, prediction snapshot, branch/remainder
boundary state, and completion/writeback state. Future trials must pass golden
PC checks on both Dhrystone and CoreMark, and any benchmark regression
invalidates the row even if another benchmark improves.

Why the RTL was active:

- The result provenance recorded a dirty RTL delta in
  `src/rtl/core/frontend/ifu/ifu.sv` before the trial build.
- Dhrystone moved from 27,093 to 21,597 timed cycles and
  `packet_empty_noemit_dup` fell from 9,098 to 3,410, so the simulator was not
  running the old image.
- CoreMark then failed with the same modified image. The first failure is not a
  late timeout ambiguity: the golden PC checker catches the exact retired
  stream divergence at sequence 7,056.

Correct next interpretation: keep the option, reject this implementation. The
next RTL slice must make same-owner progress through an owned IFU work advance
event that updates PC, line ownership, completion state, and prediction boundary
metadata together. A local work-PC edit is not enough evidence to abandon the
architectural path.

Accepted RTL slice, 2026-05-07:

- Implemented an owned same-owner IFU work advance in `ifu.sv`. The cursor may
  advance to `seq_next_pc` only when the emitted packet enqueues, the current
  FTQ writeback owner is live, no remainder or straddle transition is active,
  the next PC stays on the same line, and a predicted-control owner cannot
  place its predicted control in the next maximum 4-wide packet window.
- Added `INVARIANT_I` in the simulation frontend assertions: a same-owner
  advance must keep the same FTQ owner and load the previous cycle's
  `seq_next_pc`.
- Rejected sub-variants:
  - Owner-live plus enqueue gating alone still trips CoreMark at sequence 7,056.
  - Allowing advance before, but close to, a predicted control also trips the
    same CoreMark fall-through PC.
  - Control-free-only gating passes both rows but captures only part of the
    opportunity: Dhrystone +3.1% DMIPS/MHz, CoreMark +0.9% CoreMark/MHz.

Accepted result directories:

- `benchmark_results/20260507_trial_pred_ctl_distance_same_owner_final_dhrystone`
- `benchmark_results/20260507_trial_pred_ctl_distance_same_owner_final_coremark`

| Workload | Baseline timed cycles | Accepted timed cycles | Metric delta | Correctness |
|---|---:|---:|---:|---|
| Dhrystone 100 | 27,093 | 26,080 | +3.9% DMIPS/MHz | PASS, golden PC OK, strict owner/delivery clean |
| CoreMark 1 | 209,058 | 199,331 | +4.9% CoreMark/MHz | PASS, golden PC OK, strict owner/delivery clean |

Key counter movement:

| Workload | `packet_empty_noemit_dup` | `packet_empty_f2_data` | Redirect recovery |
|---|---:|---:|---:|
| Dhrystone 100 | 9,098 -> 8,067 | 9,410 -> 8,379 | 126 -> 126 |
| CoreMark 1 | 82,614 -> 70,972 | 85,756 -> 74,161 | 2,969 -> 2,995 |

This is a valid performance iteration, not just a counter probe: both endpoint
identity and golden PC streams pass. It does not close the full Stage 1 gap by
itself, but it proves the same-owner IFU cursor direction is real when bounded
by predicted-control reachability.

### Bubble Analysis

The previous 21K-cycle Dhrystone row is real as a Dhrystone measurement, but it
is not maintainable as default behavior because it advances inside predicted
control ownership without proving that the next packet cannot cross the
predicted-control boundary. Dhrystone does not expose that hazard; CoreMark
does, at `0x80002ffa -> 0x80002ffe -> 0x80003000`.

The accepted gate keeps only the part of the optimization that is outside the
predicted-control reachability window. That is why Dhrystone gives back most of
the 21K-cycle improvement.

| Dhrystone row | Correctness | Timed cycles | Frontend zero | `packet_empty_f2_data` | `packet_empty_noemit_dup` | Commit=4 cycles |
|---|---|---:|---:|---:|---:|---:|
| Baseline | PASS | 27,093 | 9,770, 35.4% | 9,410 | 9,098 | 307 |
| Unsafe same-owner shortcut | DS PASS, CM FAIL | 21,597 | 4,085, 18.5% | 3,722 | 3,410 | 1,905 |
| Control-free-only safe gate | PASS | 26,281 | 8,944, 33.4% | 8,581 | 8,269 | 812 |
| Accepted predicted-control-distance gate | PASS | 26,080 | 8,742, 32.9% | 8,379 | 8,067 | 813 |

Interpretation:

- The unsafe row removes 5,685 frontend-zero cycles versus baseline, and
  `packet_empty_noemit_dup` falls by 5,688. This is too exact to be random
  noise; it is the intended same-owner cursor mechanism.
- The accepted row removes 1,028 frontend-zero cycles versus baseline and
  `packet_empty_noemit_dup` falls by 1,031. It keeps about 18% of the unsafe
  Dhrystone bubble removal because the rest lies in predicted-control hazard
  windows.
- Redirect recovery is unchanged on Dhrystone, 126 cycles in all rows, and
  I-cache wait changes only 271 -> 262 cycles. The Dhrystone delta is therefore
  frontend duplicate/no-emit pressure, not branch recovery, I-cache miss, or
  backend scheduling.
- `xs_ftq_occ_max` remains 1 and `xs_packet_buf_occ_max` remains 0. This slice
  is not yet true FTQ/IBuffer runahead; it is a bounded same-owner cursor
  repair in the current flow-through frontend.

CoreMark also confirms the same mechanism once the predicted-control hazard is
bounded:

| CoreMark row | Timed cycles | Frontend zero | `packet_empty_f2_data` | `packet_empty_noemit_dup` | Commit=4 cycles |
|---|---:|---:|---:|---:|---:|
| Baseline | 209,058 | 92,111, 41.9% | 85,756 | 82,614 | 11,638 |
| Accepted predicted-control-distance gate | 199,331 | 80,548, 38.4% | 74,161 | 70,972 | 12,603 |

CoreMark gains 9,727 timed cycles while reducing `packet_empty_noemit_dup` by
11,642 cycles. Redirect recovery changes only 2,969 -> 2,995 cycles, so the
accepted improvement is also frontend supply, not hidden redirect behavior.

Same-owner block-reason counters were added and rerun on the accepted RTL with
the same strict owner/delivery and golden PC checks:

- `benchmark_results/20260507_same_owner_block_counters_dhrystone`
- `benchmark_results/20260507_same_owner_block_counters_coremark`

| Workload | Candidate | Emit candidate | Advanced | No emit | No enqueue | Predicted-control window | Remainder/straddle | Owner not live | Owner complete | Cross-line | Other |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Dhrystone 100 | 10,782 | 5,914 | 1,042 | 4,868 | 3 | 4,664 | 205 | 0 | 0 | 0 | 0 |
| CoreMark 1 | 56,352 | 35,278 | 12,718 | 21,074 | 264 | 19,292 | 3,004 | 0 | 0 | 0 | 0 |

Interpretation:

- The accepted same-owner cursor slice is performance-active but still leaves
  most recoverable emit candidates blocked by predicted-control reachability.
- Owner liveness, owner completion, and cross-line conditions are not the
  current limiter; their counts are zero in both rows.
- Packet enqueue backpressure is also negligible. `xs_packet_buf_occ_max`
  remains 0 and backend stalls remain 0, so the issue is not decode-side
  pressure.
- The next architecture-level trial should therefore be predicted-control
  owner splitting: make the packet/FTQ boundary stop before an owned predicted
  conditional when needed, then allow the IFU cursor to advance up to, but not
  past, that predicted-control PC. This is a general frontend ownership rule,
  not a benchmark-PC rule.

Rejected follow-up trial:

- `benchmark_results/20260507_trial_pred_ctl_owner_split_dhrystone`
- `benchmark_results/20260507_trial_pred_ctl_owner_split_coremark`

The trial split before any FTQ-owned predicted conditional at a nonzero packet
slot and relaxed IFU same-owner advance up to the predicted-control PC. It was
endpoint-clean, but it is rejected as a performance policy:

| Workload | Accepted timed cycles | Trial timed cycles | Verdict |
|---|---:|---:|---|
| Dhrystone 100 | 26,080 | 26,778 | Regresses. |
| CoreMark 1 | 199,331 | 241,204 | Large regression. |

The trial reduced Dhrystone `packet_empty_noemit_dup` from 8,067 to 6,009, but
CoreMark increased it from 70,972 to 80,254 and increased redirect recovery
from 2,995 to 3,310. The forced split created many more same-owner advances,
but it also destroyed useful branch-packet packing and increased FTQ empty
time. The conclusion is not "predicted-control ownership is irrelevant"; it is
that unconditional branch-boundary splitting is too blunt. The next candidate
needs a selective predicted-control mechanism that preserves useful packet
packing while preventing the specific fall-through skip hazard.

Accepted follow-up trial:

- `benchmark_results/20260507_trial_pred_ctl_start_advance_dhrystone`
- `benchmark_results/20260507_trial_pred_ctl_start_advance_coremark`
- `benchmark_results/20260507_pred_ctl_start_broad_smoke`

The accepted RTL keeps packet packing intact and only relaxes the IFU
same-owner rule when the next packet starts exactly at the FTQ predicted-control
PC. That case does not carry the control as a passenger behind earlier
straight-line instructions, so it avoids the CoreMark fall-through skip hazard
that invalidated the earlier broad same-owner shortcut.

| Workload | Prior accepted timed cycles | New timed cycles | Metric |
|---|---:|---:|---:|
| Dhrystone 100 | 26,080 | 22,290 | 2.553396 DMIPS/MHz |
| CoreMark 1 | 199,331 | 196,124 | 5.098815 CoreMark/MHz |

Key counter movement versus the prior accepted row:

| Workload | `packet_empty_noemit_dup` | `packet_empty_f2_data` | Same-owner advanced | Same-owner no-emit block |
|---|---:|---:|---:|---:|
| Dhrystone 100 | 8,067 -> 4,111 | 8,379 -> 4,423 | 1,042 -> 5,004 | 4,868 -> 906 |
| CoreMark 1 | 70,972 -> 66,694 | 74,161 -> 69,884 | 12,718 -> 17,323 | 21,074 -> 16,701 |

All 12 broader smoke probes passed with strict owner/delivery checks and
profiling enabled: frontend mixed-branch, data-dependent branch, call/return,
taken-loop, jump-table, memory struct/array, backend independent/chain, and the
three hotspot probes. This is still DSE evidence rather than final signoff, but
it is no longer a two-benchmark-only datapoint.

The heavier Stage 1 workload rows also passed with the same checks:

| Workload | Timed cycles | Metric | `packet_empty_noemit_dup` | Same-owner advanced |
|---|---:|---:|---:|---:|
| Dhrystone 300 | 64,719 | 2.638261 DMIPS/MHz | 11,213 | 14,518 |
| CoreMark 10 | 1,931,584 | 5.177098 CoreMark/MHz | 639,203 | 158,584 |

Compared with the older locked Stage 1 rows, this moves Dhrystone 300 from the
mid 76K to 64.7K timed-cycle range and CoreMark 10 from about 2.03M to 1.93M
timed cycles. The next formal step is a full scoreable signoff run from this
committed RTL, using the same strict checks and counter-movement gate.

## Current Architecture State

rv64gc-v2 is already aligned with the intended XiangShan/BOOM-style ownership
split in direction, but not yet in depth:

| Role | Current state | Remaining gap |
|---|---|---|
| BPU | Prediction is still coupled to F2 packet progress. | F1 does not yet build a sustained predicted owner stream. |
| FTQ | Allocation, IFU request, IFU writeback, and commit/training views are structurally split. | The split is not yet used to maintain deeper demand runahead. |
| IFU work cursor | A stateful `ifu_work_item_t` exists and carries PC, line address, and FTQ identity. Same-owner advance is now allowed when the next packet is outside the predicted-control hazard window. | It still needs deeper owner runahead and eventual removal of duplicate suppression as a correctness crutch. |
| IBuffer | `fetch_packet_buffer.sv` is the owner-aware decode-facing packet boundary. | Capacity must be used as the runahead limit, not just as a pass-through buffer. |

Therefore the next work is not to add these objects from scratch. The next work
is to let the existing objects act independently under explicit ownership and
completion rules.

## Workable Options

These are the options worth keeping in the active Stage 2 plan.

| Option | Status | Expected benefit | Guardrail / enable condition |
|---|---|---|---|
| Baseline counter pass | Required first | Prevents another stale methodology loop. | Capture current RTL counters before changing default behavior. |
| Decouple existing IFU work cursor | In progress, first accepted slice landed | Allows IFU extraction/progress by FTQ owner instead of raw F2 mirror state. | Keep same-owner advance bounded by live owner, same line, real packet enqueue, and predicted-control reachability. |
| Capacity-bounded BPU/F1 runahead | Primary after cursor decoupling | Lets F1 allocate/fetch ahead when FTQ, ICQ, and IBuffer have room. | Initial depth 1-2; limit derived from occupancy and epoch safety, not benchmark PCs. |
| Owner-aware IBuffer elasticity | Primary support work | Absorbs decode/backend bubbles while IFU continues producing packets. | Complete packets carry FTQ identity and owner-complete metadata; strict delivery remains clean. |
| Early IFU prediction validation | Workable after runahead | Repairs wrong predicted control closer to fetch. | Owner-tagged writeback to FTQ; redirect counters must not become dominant. |
| Mispredict recovery shortening | Conditional | Reduces FLUSH/restart cost. | Do only if `redirect_to_restart_cycles` shows meaningful headroom. |
| BPU S0 fast-path predictor / uBTB | Conditional | May allow deeper runahead or timing closure if main prediction path becomes the limiter. | Do only after cursor+runahead data shows BPU lookup latency/timing blocks depth, or timing closure requires it. |
| BPU S1 registered main predictor | Conditional | May support depth >2 and timing closure. | Pair with S0/override accounting; track squash cost from disagreement. |
| Indirect prediction uplift / ITTAGE-lite | Conditional | Reduces indirect-branch redirect cost on state-machine workloads. | Do only if per-PC indirect MPKI is material. |
| Fusion pattern expansion | Orthogonal candidate | Reduces effective uop count and relieves pressure downstream. | Per-pattern frequency and correctness evidence before default enable. |
| FTQ-driven L1I prefetch / `pfPtr` | Later candidate | Can reduce line-wait cost once demand ownership is clean. | Do not add active `pfPtr` before demand request/writeback/delivery ownership is proven. |
| UOC re-evaluation | Measurement only | Checks whether post-runahead 4-wide behavior changes prior UOC conclusion. | Keep only if it shows measured benefit without endpoint risk. |

The BPU S0/uBTB path is a real industry-style option, but it is not yet proven
to be the mandatory first step. Current RTL has combinational BTB/TAGE lookup;
the measured structural problem is F1/F2 progress coupling and shallow owner
runahead. S0/uBTB should be promoted only if the decoupled cursor and bounded
runahead expose prediction latency or timing as the next limiter.

## Evidence Required

A Stage 2 optimization row is meaningful only if it passes correctness and
moves the intended counters.

### Baseline Counters

| Counter | Purpose |
|---|---|
| `xs_ftq_occ_max` and FTQ occupancy histogram | Proves whether ownership is still shallow or running ahead. |
| `packet_buf_occ_max` and IBuffer non-empty cycles | Shows whether IBuffer is absorbing rate mismatch. |
| `packet_empty_noemit_dup` | Tracks duplicate/no-emit pressure that should disappear structurally. |
| `xs_dup_last_emit` | Must fall without relying on local duplicate filtering. |
| Frontend supply histogram | Measures useful packets delivered to decode. |
| Commit-stage bubble attribution | Confirms frontend improvements also change timed execution. |
| `redirect_to_restart_cycles` | Sizes recovery-shortening opportunity. |
| `branches_per_packet_hist` | Bounds useful runahead and prediction pressure. |
| `fetch_width_utilized` | Shows whether 4-wide supply is being saturated. |
| `indirect_mpki_per_pc` | Gates ITTAGE-lite or indirect-specific work. |
| `head_blocking_uop_class_hist` | Separates frontend overlap issues from real memory/EXU bottlenecks. |

### Correctness Gates

- Dhrystone/CoreMark endpoint identity: checksum, flags, iterations, `tohost`.
- Broad anti-overfit smoke suite remains clean.
- `+FETCH_DELIVERY_CHECK +FETCH_DELIVERY_STRICT`.
- `+FETCH_OWNER_CHECK +FETCH_OWNER_STRICT`.
- Golden PC scoreboard where available.
- No owner duplicate/replayed PCs, skipped PCs, or IFU-line metadata mismatch.
- No stale epoch response consumed as instruction data.

## Implementation Order

This is the cleaned Stage 2 order. It starts from the current RTL state, where
the FTQ owner split, owner-aware IBuffer boundary, and neutral IFU work cursor
already exist.

| Phase | Task | Exit criterion |
|---|---|---|
| 0 | Capture baseline counters on current RTL. | Current cm/dhry rows plus occupancy, duplicate/no-emit, supply, redirect, and head-blocking data recorded. |
| 1 | Decouple the existing IFU work cursor from raw F2 mirror state. | Cursor advances by FTQ IFU-writeback owner and current PC; strict delivery remains clean. |
| 2 | Use IBuffer and FTQ capacity to bound proactive BPU/F1 runahead at depth 1. | FTQ/IBuffer occupancy rises; duplicate/no-emit buckets fall; endpoint identity remains clean. |
| 3 | Increase bounded runahead to depth 2 if Phase 2 is clean. | Timed cycles improve and wrong-path/flush cost remains bounded. |
| 4 | Decide whether BPU S0/uBTB or BPU S1 pipelining is needed. | Promote only if counters show prediction latency/timing blocks deeper runahead. |
| 5 | Evaluate recovery, indirect prediction, fusion, or prefetch candidates. | Each candidate must be gated by its specific counter and measured independently. |
| 6 | Re-score against calibrated MegaBOOM rows and update the remaining bottleneck map. | Stage 1 gap closes or the residual limiter is named with data. |

## Explicit Non-Goals

For this Stage 2 frontend slice:

- No loop buffer revival.
- No benchmark-PC steering.
- No same-line, same-FTQ-tail, or sequential lookahead as standalone
  correctness mechanisms.
- No duplicate suppression as the correctness mechanism; duplicates should
  become structurally impossible under owner-aware delivery.
- No widening decode/rename/commit in this slice.
- No dcache hit-latency, L1D, store-load forwarding, or EXU-latency work until
  post-runahead counters prove frontend overlap is no longer the main limiter.
- No active XiangShan-style `pfPtr` until demand ownership is working.

## Verdict

The workable Stage 2 frontend path is:

1. Measure current ownership/supply behavior.
2. Decouple the existing IFU work cursor.
3. Enable small, capacity-bounded proactive BPU/F1 runahead.
4. Promote BPU S0/uBTB, recovery, indirect prediction, fusion, or prefetch only
   when counters identify them as the next limiter.

The strongest near-term objective remains closing the calibrated MegaBOOM gap
on Dhrystone/CoreMark without endpoint drift. The aggressive 7.5 CM/MHz and
4.0 DMIPS/MHz targets remain valid as multi-stage goals, but this document no
longer claims a hard frontend-only ceiling or declares memory/EXU work required
before the frontend runahead data exists.

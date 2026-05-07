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

## Current Architecture State

rv64gc-v2 is already aligned with the intended XiangShan/BOOM-style ownership
split in direction, but not yet in depth:

| Role | Current state | Remaining gap |
|---|---|---|
| BPU | Prediction is still coupled to F2 packet progress. | F1 does not yet build a sustained predicted owner stream. |
| FTQ | Allocation, IFU request, IFU writeback, and commit/training views are structurally split. | The split is not yet used to maintain deeper demand runahead. |
| IFU work cursor | A stateful `ifu_work_item_t` exists and carries PC, line address, and FTQ identity. | It is still mirror-locked to F2 by SVA and must be decoupled from raw F2 register progress. |
| IBuffer | `fetch_packet_buffer.sv` is the owner-aware decode-facing packet boundary. | Capacity must be used as the runahead limit, not just as a pass-through buffer. |

Therefore the next work is not to add these objects from scratch. The next work
is to let the existing objects act independently under explicit ownership and
completion rules.

## Workable Options

These are the options worth keeping in the active Stage 2 plan.

| Option | Status | Expected benefit | Guardrail / enable condition |
|---|---|---|---|
| Baseline counter pass | Required first | Prevents another stale methodology loop. | Capture current RTL counters before changing default behavior. |
| Decouple existing IFU work cursor | Primary | Allows IFU extraction/progress by FTQ owner instead of raw F2 mirror state. | Cursor carries idx/epoch/tag/current PC; no identity inferred from ICQ request PC. |
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

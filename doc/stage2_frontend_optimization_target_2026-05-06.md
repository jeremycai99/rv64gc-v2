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

## C910-Inspired Optimization Options, 2026-05-07

OpenC910 is useful as a high-performance RISC-V reference, but it should not be
treated as a block-level blueprint for rv64gc-v2. The most important correction
from the RTL readout is that C910 is not a 6-wide decode machine. The C910 IFU
delivers three instruction slots to IDU, and the ID stage instantiates three
main decoders. C910 then expands into up to four internal ID/IR slots and feeds
a wider heterogeneous backend. The lesson for rv64gc-v2 is therefore not
"widen decode first"; it is "make frontend supply, branch ownership, and
internal useful work per slot strong enough that nominal decode width is not
the limiter."

Local C910 references:

- `openc910/C910_RTL_FACTORY/gen_rtl/ifu/rtl/ct_ifu_top.v`: IFU exports
  `ifu_idu_ib_inst0/1/2_data` only.
- `openc910/C910_RTL_FACTORY/gen_rtl/idu/rtl/ct_idu_id_dp.v`: three primary
  `ct_idu_id_decd` instances.
- `openc910/C910_RTL_FACTORY/gen_rtl/idu/rtl/ct_idu_id_ctrl.v`: four
  `ctrl_id_pipedown_inst0..3_vld` internal slots after split/expansion.
- `openc910/C910_RTL_FACTORY/gen_rtl/idu/rtl/ct_idu_ir_ctrl.v`: four IR
  allocation slots.
- `openc910/C910_RTL_FACTORY/gen_rtl/ifu/rtl/ct_ifu_ibuf.v`: 32-entry
  instruction buffer.
- `openc910/C910_RTL_FACTORY/gen_rtl/ifu/rtl/ct_ifu_lbuf.v`: 16-entry line or
  loop buffer.
- `openc910/C910_RTL_FACTORY/gen_rtl/ifu/rtl/ct_ifu_pcfifo_if.v`: PC and
  branch metadata FIFO feeding later branch validation/training.
- `openc910/C910_RTL_FACTORY/gen_rtl/pmu/rtl/ct_hpcp_top.v`: PMU event model
  including frontend stall, backend stall, I-cache access/miss, BHT/jump/BTB
  mispredicts, D-cache misses, LSU stalls, scheduler latch failures, and IR
  instruction type counts.

Transferable options, ordered by leverage:

| Option | C910 reference idea | rv64gc-v2 application | Acceptance signal | Verdict |
|---|---|---|---|---|
| Selective predicted-control ownership | Branch metadata is carried separately from raw fetch bytes through PCFIFO-like ownership. | Prevent same-owner cursor progress from crossing a predicted-control PC, but do not blindly split every packet before every predicted control. Preserve useful branch-packet packing. | Golden PC clean on Dhrystone and CoreMark, lower predicted-control block count, lower `packet_empty_noemit_dup`, no redirect increase. | Do next as a selective mechanism. The later unconditional split trial proves the blunt version is too expensive. |
| Real FTQ/IBuffer elasticity | C910 has a much deeper IBUF and separate PC/control metadata. | Make FTQ occupancy exceed one and make the decode-facing IBuffer hold real packets instead of flow-through only. Retire duplicate guard only after duplicates are structurally impossible. | `ftq_occ_max > 1`, `packet_buf_occ_max > 0`, lower `ftq_empty_cycles` and frontend zero cycles, no owner/delivery violations. | Do after owner splitting or in parallel if scoped. This is the main path to true frontend runahead. |
| Early fetch-line metadata | C910 predecodes around fetch-line positions before the 3-wide ID boundary and stores predecode metadata near I-cache. | Strengthen `instr_boundary`, `predecode`, and `instr_compact` so each line has reliable RVC boundaries, first/second control candidates, fallthrough/remainder identity, and predicted-control slot metadata. | Lower boundary/remainder stalls, fewer conservative predicted-control blocks, no compressed fallthrough skips under golden PC. | High value. This is safer than reviving a loop buffer. |
| BPU/FTQ training metadata cleanup | C910 keeps retired branch details and prediction hit/miss signals visible to PMU/training. | Make FTQ writeback/training metadata explicit for control type, predicted slot, target, fallthrough, GHR/RAS snapshot, and validation result. | Lower branch recovery or unchanged recovery while frontend supply improves; clearer per-control mispredict counters. | High value, especially before indirect or uBTB work. |
| Uop/fusion accounting | C910's 3 decode to 4 internal slots shows decode width and internal work width are different. | Track useful architectural instructions, internal uops, fused pairs, UOC hits, and decode slot waste separately. Optimize effective work per frontend slot instead of raw slot count. | Higher commit/useful-op density, stable retired instruction count, no benchmark-specific transforms. | Medium-high. Do after frontend delivery correctness is stable. |
| Typed issue/ready instrumentation | C910 has typed issue queues and PMU-visible latch-fail/backend-stall events. | Add or refine counters for integer issue starvation, memory issue starvation, wakeup/select blocked, PRF write port pressure, CDB pressure, and load-use wait. | Backend stall attribution becomes specific enough to pick an execution or LSU DSE. | Defer until frontend gate reaches a ceiling. |
| LSU and memory-system DSE | C910 has a mature banked LSU/cache path and PMU-visible load/store miss/stall events. | Consider load-use latency, store-load forwarding, memory dependence prediction, D-cache bank conflicts, and fill bypass only if post-frontend counters point there. | Backend or memory stall dominates after frontend supply improves. | Defer. Do not open this before frontend evidence saturates. |
| Loop buffer | C910 has a line/loop buffer. | Do not import a loop buffer as the main Stage 2 mechanism. If any loop-local optimization returns later, it must be line-metadata based and owner-clean, not a separate PC owner. | Must improve broad benchmarks and pass strict owner/golden PC. | Reject for now. Prior rv64gc-v2 evidence says correctness risk exceeds benefit. |

The immediate C910-inspired Stage 2 path is:

1. Selective predicted-control ownership, not unconditional branch-boundary splitting.
2. FTQ/IBuffer elasticity with nonzero runahead.
3. Early fetch-line metadata and predecode-cache style reuse.
4. BPU/FTQ training metadata cleanup.
5. Uop/fusion accounting, then backend/LSU DSE only if counters demand it.

## C910 Performance Modeling Readout

The public OpenC910 release does not include a full internal performance model
or design-space study. What it does include is enough to infer the modeling
style used for released benchmark claims and local simulation:

1. Architectural target specs are published at the product/datasheet level.
   `openc910/doc/openc910_datasheet.pdf` describes C910 as an RV64GC
   12-stage out-of-order multiple-issue core with 64KB I-cache, 64KB D-cache,
   1MB L2, AXI4-128, hardware cache coherency, and PMU support. This is a
   product capability statement, not a bottleneck model.
2. The simulation environment has benchmark cases, including CoreMark. The
   local CoreMark case uses `VCUNT_SIM`, reads the RISC-V `time` CSR through
   `get_vtimer()`, measures only the benchmark iterate window, and reports
   `(iterations/sec)/MHz` as `1000000 / cycles_per_iteration`.
3. The released CoreMark build is compiler-heavy and C910-specific:
   `-O3 -mtune=c910 -static -funroll-all-loops -finline-limit=500
   -fgcse-sm -fno-schedule-insns ... -DITERATIONS=10000`. That means public
   or repo-local CoreMark/MHz numbers are not pure microarchitecture numbers;
   they include compiler scheduling and C910-tuned code generation.
4. The architectural PMU is broad. `ct_hpcp_top.v` exposes selectable events
   for I-cache access/miss, I-TLB/D-TLB/JTLB miss, BHT and jump mispredict,
   BTB target miss, frontend stall, backend stall, D-cache read/write
   access/miss, LSU cross-4K/other stalls, SQ replay/discard, scheduler latch
   failures, IR instruction type counts, sync/fence stalls, interrupts, and
   retired branch/control details.
5. The PMU event selector is generic: `ct_hpcp_event.v` supports 42 event
   indices using a 6-bit event selector. This suggests the intended modeling
   loop is benchmark timing plus selectable hardware counter attribution, not
   only endpoint cycle counts.

For rv64gc-v2, the matching methodology should be stricter than simply chasing
CoreMark/MHz:

1. Keep the same timed-window discipline: measure only the benchmark region,
   not reset, loading, UART, or harness setup.
2. Keep golden PC and endpoint checks on every performance row.
3. Report CoreMark and Dhrystone with compiler flags and image hash.
4. For every accepted RTL row, report at least:
   `frontend_zero`, `packet_empty_noemit_dup`, `packet_empty_f2_data`,
   predicted-control block count, FTQ/IBuffer occupancy, redirect recovery,
   I-cache wait, backend stall, commit-width histogram, retired instruction
   count, and any new PMU-style bottleneck counters.
5. Treat C910-style PMU categories as the model taxonomy:
   frontend supply, branch prediction/recovery, cache/TLB, backend issue,
   memory ordering/replay, and useful internal work per decoded slot.

Verdict: C910 gives us a good performance-modeling pattern, but not a
drop-in answer. The correct rv64gc-v2 adaptation is benchmark-window timing
plus PMU-grade bottleneck counters, with strict correctness invariants kept on
while each architecture option is swept.

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
timed cycles. These rows were then consolidated into a full goal run from the
committed RTL.

Full goal consolidation:

- `benchmark_results/20260507_pred_ctl_start_stage1_goal`
- 16/16 rows PASS under `--goal stage1`, signoff class, strict owner/delivery
  checks, `+PERF_PROFILE`, `+PERF_COUNTERS`, and `+STAT_DUMP`.

| Workload | Timed cycles | Metric |
|---|---:|---:|
| Dhrystone 100 | 22,290 | 2.553396 DMIPS/MHz |
| Dhrystone 300 | 64,719 | 2.638261 DMIPS/MHz |
| CoreMark 1 | 196,124 | 5.098815 CoreMark/MHz |
| CoreMark 10 | 1,931,584 | 5.177098 CoreMark/MHz |

This is the first consolidated post-refactor goal artifact for the
predicted-control-start IFU rule. It does not reach the long-term 4.0
DMIPS/MHz and 7.5 CoreMark/MHz targets, but it is a broad, endpoint-clean
frontend improvement and should become the new baseline for the next bottleneck
iteration.

Accepted depth-1 BPU/F1 runahead slice:

- `benchmark_results/20260507_stage2_depth1_runahead_final_smoke`
- Rebuilt DSim from the current RTL and reran the strict DSE smoke with
  `+FETCH_DELIVERY_CHECK +FETCH_DELIVERY_STRICT +FETCH_OWNER_CHECK
  +FETCH_OWNER_STRICT +PERF_PROFILE +PERF_COUNTERS +STAT_DUMP`.
- The implementation allocates one direct-taken predicted target ahead of the
  current IFU writeback owner when FTQ, ICQ, and packet-buffer capacity allow
  it. JALR and return targets are excluded for this first slice.
- FTQ successor ownership is now registered and replacement-aware. A pending
  runahead successor can be consumed by a matching redirect, or cancelled and
  replaced when the real redirect target differs.
- The I-cache response path has a one-entry future-line side buffer so a
  response for the successor owner does not get consumed by the current owner.

| Workload | Prior timed cycles | Depth-1 timed cycles | Metric | Strict result |
|---|---:|---:|---:|---|
| Dhrystone 100 | 22,290 | 22,189 | 2.565019 DMIPS/MHz | PASS |
| CoreMark 1 | 196,124 | 195,632 | 5.111638 CoreMark/MHz | PASS |

Key counter movement versus the prior predicted-control-start baseline:

| Workload | `xs_ftq_occ_max` | `xs_ftq_occ_hist_2to3` | `xs_runahead_req_fire` | `xs_runahead_pending_cycles` | `xs_runahead_redirect_match` | `xs_runahead_cancel_next` |
|---|---:|---:|---:|---:|---:|---:|
| Dhrystone 100 | 1 -> 2 | 0 -> 699 | 500 | 699 | 500 | 0 |
| CoreMark 1 | 1 -> 2 | 0 -> 20,257 | 10,572 | 20,257 | 10,382 | 3 |

Bubble counters:

| Workload | `packet_empty_noemit_dup` | `packet_empty_f2_data` | `packet_empty_wait_icresp` | `xs_ftq_empty_cycles` | `xs_icq_future_head_block` | `xs_packet_buf_occ_max` |
|---|---:|---:|---:|---:|---:|---:|
| Dhrystone 100 | 4,111 -> 4,009 | 4,423 -> 4,321 | 262 -> 3,332 | 3,326 -> 3,326 | 399 | 0 |
| CoreMark 1 | 66,694 -> 65,881 | 69,884 -> 69,072 | 3,437 -> 49,477 | 51,151 -> 51,242 | 1,887 | 0 |

Interpretation:

- This is the first scoreable proof that the frontend can hold more than one
  FTQ owner under strict checks: `xs_ftq_occ_max` reaches 2 on both smoke rows,
  and the runahead request, pending, and redirect-match counters move.
- The score gain is real but marginal: about 0.45% fewer Dhrystone 100 timed
  cycles and 0.25% fewer CoreMark 1 timed cycles versus the previous accepted
  baseline.
- Gate B is therefore only partially satisfied. FTQ runahead exists, but
  `xs_packet_buf_occ_max` remains 0, so the decode-facing IBuffer is still not
  absorbing rate mismatch. The large `packet_empty_wait_icresp` increase also
  shows that future-line ownership is exposing ICQ/head-of-line effects rather
  than eliminating fetch starvation.
- The next implementation should not keep pushing local runahead depth first.
  It should make the IBuffer and IFU request queue absorb complete
  owner-tagged packets or lines, then rerun the same counters. Depth 2 should
  only be promoted after the depth-1 path no longer converts duplicate bubbles
  into I-cache or ICQ waiting.

## Stage 2 Signoff Risk And Phase Gates

The accepted same-owner/predicted-control work is a real architectural
improvement, but the remaining gap to the aggressive Stage 2 targets is still
large. This must be treated as a signoff risk, not as a small cleanup tail.

| Metric | Current heavy row | Stage 2 target | Required score uplift | Equivalent cycle reduction |
|---|---:|---:|---:|---:|
| CoreMark/MHz | 5.177098 | 7.5 | +44.9% | 31.0% |
| DMIPS/MHz | 2.638261 | 4.0 | +51.6% | 34.0% |

The Arm Cortex-A72 comparison should be interpreted as an effective-utilization
warning. A72 is nominally a 3-wide decode machine, but its score comes from a
balanced commercial frontend/backend: prediction quality, recovery latency,
fetch buffering, load-use behavior, memory dependence handling, scheduler
balance, and physical timing discipline. rv64gc-v2 has more nominal width in
some places, but width is not useful when the frontend remains shallow or when
uop, branch, LSU, or ROB-head behavior prevents sustained retirement.

Stage 2 therefore needs explicit promotion and stop criteria:

| Gate | Objective | Required evidence | Decision |
|---|---|---|---|
| A | Lock current accepted RTL as the new scoreable baseline. | Full scoreable run from committed RTL, strict owner/delivery checks, endpoint identity, broad smoke pass, and the expected duplicate/no-emit counter movement. | If this fails, fix correctness or methodology before more DSE. |
| B | Prove true frontend runahead, not just same-owner cursor repair. | `xs_ftq_occ_max > 1`, nonzero IBuffer occupancy on meaningful rows, duplicate/no-emit falls broadly, and redirect recovery does not grow enough to erase the gain. | If occupancy stays shallow, continue FTQ/IFU/IBuffer ownership work. |
| C | Score the frontend-only ceiling. | After depth-1 or depth-2 runahead, heavy rows should approach roughly 6.0 CM/MHz and 3.2 DMIPS/MHz. | If scores are below that range, frontend-only work is insufficient and a second-domain DSE must open. |
| D | Select the second-domain limiter from counters. | Use branch/recovery, effective-uop, LSU/load-use, ROB-head, and backend scheduling counters to identify the largest residual. | Promote only the counter-backed domain: BPU/recovery, fusion/uop count, LSU, or backend balance. |
| E | Stretch to final signoff. | Full benchmark manifest, broad probes, endpoint/golden checks where available, and no major regression outside Dhrystone/CoreMark. | Only then compare against the 7.5 CM/MHz and 4.0 DMIPS/MHz targets. |

Concrete second-domain triggers:

| Residual signal after runahead | Next architectural direction |
|---|---|
| High redirect or restart cost | Recovery shortening, BPU timing, or early IFU prediction validation. |
| High branch MPKI or indirect concentration | BPU quality work, including uBTB/S0 or indirect prediction only if the per-PC data supports it. |
| High instruction count per useful work | Macro-op/uop fusion and effective frontend-slot utilization. |
| ROB-head stalls dominated by loads | Load-use path, LSU latency, memory dependence, or store/load forwarding. |
| Backend issue or wakeup/select stalls dominate | Scheduler and execution balance, not more frontend patches. |

The Stage 2 plan should continue the frontend path first because current
occupancy and duplicate/no-emit counters still show shallow delivery. However,
the final A72-class target should not depend on frontend work alone unless
Gate C proves the frontend-only ceiling is much higher than the current data
suggests.

## Current Architecture State

rv64gc-v2 is already aligned with the intended XiangShan/BOOM-style ownership
split in direction, but not yet in depth:

| Role | Current state | Remaining gap |
|---|---|---|
| BPU | Prediction can now launch a bounded depth-1 direct-taken successor request without updating F2 prediction state. | It is not yet a sustained predicted owner stream, and indirect/return targets remain excluded. |
| FTQ | Allocation, IFU request, IFU writeback, and commit/training views are structurally split. The successor owner is registered and can be cancelled/replaced under runahead. | Depth is still capped at one successor and the runahead path is not yet backed by real IBuffer elasticity. |
| IFU work cursor | A stateful `ifu_work_item_t` exists and carries PC, line address, and FTQ identity. Same-owner advance is allowed when bounded by predicted-control reachability, and depth-1 predicted-target runahead is active. | It still needs a deeper owner request queue and eventual removal of duplicate suppression as a correctness crutch. |
| IBuffer | `fetch_packet_buffer.sv` is the owner-aware decode-facing packet boundary. | Capacity is still effectively unused on the measured rows; it must become a real elastic buffer before increasing runahead depth. |

Therefore the next work is not to add these objects from scratch. The next work
is to let the existing objects act independently under explicit ownership and
completion rules.

## Workable Options

These are the options worth keeping in the active Stage 2 plan.

| Option | Status | Expected benefit | Guardrail / enable condition |
|---|---|---|---|
| Baseline counter pass | Required first | Prevents another stale methodology loop. | Capture current RTL counters before changing default behavior. |
| Decouple existing IFU work cursor | In progress, first accepted slice landed | Allows IFU extraction/progress by FTQ owner instead of raw F2 mirror state. | Keep same-owner advance bounded by live owner, same line, real packet enqueue, and predicted-control reachability. |
| Capacity-bounded BPU/F1 runahead | Depth-1 direct-taken slice implemented | Lets F1 allocate/fetch ahead when FTQ, ICQ, and IBuffer have room. | Do not raise depth until ICQ and IBuffer head effects are reduced; limit remains occupancy and epoch based, not benchmark PCs. |
| Owner-aware IBuffer elasticity | Next primary support work | Absorbs decode/backend bubbles while IFU continues producing packets. | Complete packets carry FTQ identity and owner-complete metadata; `xs_packet_buf_occ_max` must become nonzero without strict-delivery drift. |
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
| 0 | Lock the current accepted RTL as the new scoreable baseline. | Gate A passes: full scoreable run, strict checks, endpoint identity, broad smoke pass, and expected counter movement. |
| 1 | Finish decoupling the existing IFU work cursor from raw F2 mirror state. | Cursor advances by FTQ IFU-writeback owner and current PC; strict delivery remains clean. |
| 2 | Use FTQ capacity to bound proactive BPU/F1 runahead at depth 1. | Partial Gate B evidence exists: FTQ occupancy reaches 2 and strict checks pass, but IBuffer occupancy remains zero. |
| 3 | Add owner-aware IBuffer/request elasticity before increasing runahead depth. | `xs_packet_buf_occ_max > 0`, duplicate/no-emit falls broadly, ICQ/future-head blocking does not replace the old bubble, and strict delivery remains clean. |
| 4 | Increase bounded runahead to depth 2 only if Phase 3 is clean. | Heavy rows improve without endpoint drift; wrong-path/flush cost does not erase the frontend gain. |
| 5 | Score the frontend-only ceiling. | Gate C passes or fails explicitly; if it fails, stop treating frontend-only DSE as sufficient for final signoff. |
| 6 | Select and implement one second-domain optimization. | Gate D names the residual limiter from counters before RTL work starts. |
| 7 | Re-score against calibrated MegaBOOM and final Stage 2 targets. | Gate E passes: full manifest, broad probes, endpoint/golden checks where available, and no major off-target regression. |

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
4. Add owner-aware IBuffer/request elasticity before increasing runahead depth.
5. Score the frontend-only ceiling against the Gate C threshold.
6. Promote BPU S0/uBTB, recovery, indirect prediction, fusion, LSU/load-use, or backend balance only
   when counters identify them as the next limiter.

The strongest near-term objective remains closing the calibrated MegaBOOM gap
on Dhrystone/CoreMark without endpoint drift. The aggressive 7.5 CM/MHz and
4.0 DMIPS/MHz targets remain valid as multi-stage goals, but the current heavy
rows still require about one third fewer cycles to reach those targets. The
plan therefore keeps frontend runahead first, while making second-domain work a
required escalation if true frontend runahead does not clear the Gate C score
range.

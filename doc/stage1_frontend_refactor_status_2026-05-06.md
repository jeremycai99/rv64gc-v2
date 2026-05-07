# Stage 1 Frontend Refactor Status, 2026-05-06

## Verdict

Stage 1 is still open. The original 2026-05-06 local BOOM run completed the
same benchmark images, but it used a different counter window from rv64gc-v2.
That first table remains invalid and must not be used as signoff evidence.

- BOOM: `_start` through final `tohost` store.
- rv64gc-v2: internal benchmark timed window from `rv64gc_bench_begin()` to
  `rv64gc_bench_end()`.

The BOOM harness has since been calibrated to the same benchmark-result MMIO
window used by rv64gc-v2. The calibrated smoke rows show rv64gc-v2 is still
behind MegaBOOM on the shared rows that have been rerun through that hook:

| Workload | MegaBOOM calibrated | rv64gc-v2 timed | Gap |
|---|---:|---:|---:|
| Dhrystone 100 | 23,814 cycles | 26,394 cycles | rv64gc-v2 +9.8% cycles |
| CoreMark 1 | 192,249 cycles | 207,775 cycles | rv64gc-v2 +7.5% cycles |

The full shared Dhrystone/CoreMark set still needs to be rerun through the
calibrated BOOM hook before Stage 1 can be scored. The current evidence does
not support a claim that rv64gc-v2 beats MegaBOOM.

Stage 2 remains open: the aggressive targets are 7.5 CM/MHz and
4.0 DMIPS/MHz.

## Locked Baseline Before Delivery-Push Slice, 2026-05-06

Fresh rebuilt DSim strict/profiled smoke passed on the last locked baseline
before the FTQ delivery-push slice:

- Build: `./build_dsim.sh` passed after the current `fetch_unit.sv` checker
  fix.
- Run artifact:
  `benchmark_results/20260506_stage1_strict_profiled_current_rtl/`.
- Required plusargs were present:
  `+FETCH_DELIVERY_CHECK +FETCH_DELIVERY_STRICT +FETCH_OWNER_CHECK
  +FETCH_OWNER_STRICT +PERF_PROFILE +PERF_COUNTERS +STAT_DUMP`.
- Golden-PC delivery was enabled by the manifest rows.
- Legacy loop buffer and standalone decoded-op replay activity remained zero.

| Workload | Status | Timed cycles | Timed instret | `mcycle` | Metric |
|---|---|---:|---:|---:|---:|
| Dhrystone 100 | PASS | 26,394 | 48,436 | 26,893 | 2.156369 DMIPS/MHz |
| CoreMark 1 | PASS | 207,775 | 318,379 | 218,205 | 4.812899 CM/MHz |
| CoreMark 10 | PASS | 2,033,822 | 3,183,638 | 2,044,276 | 4.916851 CM/MHz |

The strict CoreMark 10 blocker was a checker contract bug, not an RTL delivery
bug. The failing packet contained an indirect `ret` with no predicted target
(`pd_ctl_target=0`) followed by the fall-through `jal crc16` at `0x8000347e`.
The frontend correctly keeps fetching fall-through until a backend redirect
resolves the unknown indirect target; the checker incorrectly treated the
zero target as an architectural redirect to PC zero. The checker now treats
direct `JAL`/`CALL` as known redirects, while `JALR`/`RET` redirect the expected
stream only when the packet carries a nonzero predicted target.

Current frontend counters still show the Stage 1 performance work is open:

| Counter | Dhrystone 100 | CoreMark 1 | CoreMark 10 | Interpretation |
|---|---:|---:|---:|---|
| Frontend zero cycles | 35.2% | 41.8% | 41.4% | Decode supply is still frequently empty. |
| `ftq_occ_max` | 1 | 1 | 1 | FTQ runahead is still effectively one owner deep. |
| `packet_buf_occ_max` | 0 | 0 | 0 | IBuffer is still flow-through only in these rows. |
| `packet_empty_f2_data` | 9,308 | 85,166 | 806,782 | F2/data-side empty pressure remains dominant. |
| `packet_empty_noemit_dup` | 8,997 | 82,038 | 777,901 | Duplicate/no-emit pressure remains dominant. |
| `xs_f2_owner_idx_mismatch` | 0 | 0 | 0 | Owner invariant is clean. |
| `xs_f2_owner_tag_mismatch` | 0 | 0 | 0 | Owner invariant is clean. |
| `xs_ftq_empty_cycles` | 8,927 | 83,056 | 779,071 | Demand frontend is still shallow. |
| `xs_packet_buffer_stale_owner` | 418 | 5,792 | 53,242 | Flow-through misses remain visible. |

Verdict: this baseline is endpoint-clean and profiled under strict
owner/delivery checks, but it does not yet show a performance-active frontend
architecture change. The next RTL slice must make FTQ/IBuffer occupancy move:
bounded BPU/F1 runahead should be accepted only if `ftq_occ_max` rises above 1,
IBuffer occupancy becomes nonzero, duplicate/no-emit pressure drops, and the
strict/golden owner invariants remain clean.

## FTQ Delivery-Push Structural Checkpoint, 2026-05-06

The current working tree splits first-packet delivery from final IFU-owner
completion. The first accepted packet for an IFU-writeback owner pushes that
owner into the commit/decode-visible FTQ region; the IFU-writeback owner can
remain live until a same-owner continuation finishes. This fixes the stale
owner artifact that appeared when one FTQ owner legally spans multiple packets.

- Build: `./build_dsim.sh` passed.
- Strict/profiled smoke artifact:
  `benchmark_results/20260506_delivery_push_same_owner_smoke/`.
- Heavy endpoint-only artifact:
  `benchmark_results/20260506_delivery_push_same_owner_iter10_endpoint/`.
- The stage1 CoreMark 10 golden-PC row tripped at sequence `2553567`
  (`expected=0x800023e0`, `actual=0x800023de`). Local disassembly shows
  `0x800023de` is the real compressed `ld s2,64(sp)` between `0x800023dc`
  and `0x800023e0`, so the current golden fixture is stale or generated from a
  different retire stream. That golden file must not be treated as an
  independent oracle until the generation contract is repaired.

| Workload | Status | Timed cycles | Timed instret | Metric | Notes |
|---|---|---:|---:|---:|---|
| Dhrystone 100 | PASS | 27,093 | 48,436 | 2.100734 DMIPS/MHz | strict owner/delivery clean |
| CoreMark 1 | PASS | 209,058 | 318,379 | 4.783362 CM/MHz | strict owner/delivery clean |
| CoreMark 10 | PASS | 2,058,941 | 3,183,639 | 4.856866 CM/MHz | endpoint-only run; golden fixture excluded |

Key counter movement versus the locked baseline:

| Counter | Dhrystone 100 | CoreMark 1 | CoreMark 10 endpoint | Interpretation |
|---|---:|---:|---:|---|
| `ftq_occ_max` | 1 | 1 | 1 | Still no real FTQ runahead. |
| `packet_buf_occ_max` | 0 | 0 | 0 | IBuffer is still flow-through only. |
| `packet_empty_f2_data` | 9,410 | 85,756 | 814,953 | F2/data empty pressure did not improve. |
| `packet_empty_noemit_dup` | 9,098 | 82,614 | 785,795 | Duplicate/no-emit pressure did not improve. |
| `xs_f2_owner_idx_mismatch` | 0 | 0 | 0 | Owner invariant remains clean. |
| `xs_packet_buffer_stale_owner` | 0 | 0 | 0 | Delivery/commit visibility split fixed stale owner accounting. |
| `xs_ftq_empty_cycles` | 3,223 | 50,944 | 480,771 | FTQ empty accounting changed, but occupancy is still shallow. |

Verdict: accept this as a structural checkpoint only. It cleans up owner
lifetime for legal multi-packet FTQ owners, but it regresses measured timing
and does not provide Stage 1 performance evidence. The next implementation
must create capacity-owned BPU/F1 runahead and nonzero IBuffer occupancy before
any performance claim is valid.

## ICQ FTQ-Entry Carry Checkpoint, 2026-05-06

The current accepted ICQ slice carries the full FTQ entry snapshot with each
I-cache response queue entry, alongside request PC and idx/epoch/tag. This is a
behavior-neutral preparation step for a later ICQ-driven IFU cursor load: the
future handoff can consume PC and FTQ metadata as one request object instead of
re-pairing current-cycle request PC with older FTQ metadata.

- Build: `./build_dsim.sh` passed.
- Strict/profiled smoke artifact:
  `benchmark_results/20260506_icq_ftq_entry_carry_smoke/`.
- Carried-entry invariant smoke artifact:
  `benchmark_results/20260506_icq_ftq_entry_invariant_smoke/`.

| Workload | Status | Timed cycles | Timed instret | Metric | Notes |
|---|---|---:|---:|---:|---|
| Dhrystone 100 | PASS | 27,093 | 48,436 | 2.100734 DMIPS/MHz | strict owner/delivery clean |
| CoreMark 1 | PASS | 209,058 | 318,379 | 4.783362 CM/MHz | strict owner/delivery clean |

The new invariant checks that an ICQ head carrying the current FTQ
IFU-writeback owner also carries the same full FTQ entry snapshot as the FTQ
owner view. Key counters remain structurally clean:
`xs_f2_owner_idx_mismatch=0`, `xs_f2_owner_epoch_mismatch=0`,
`xs_f2_owner_tag_mismatch=0`, `xs_packet_buffer_stale_owner=0`,
`packet_stale_* = 0`, `ftq_occ_max=1`, and `packet_buf_occ_max=0`. Verdict:
accept as an ownership-carry checkpoint only; it intentionally does not claim
performance movement.

## IFU Request Work-Item Checkpoint, 2026-05-06

The request-owner cursor load sites now consume one combinational
`ifu_req_work_item_c` object instead of separately assigning request PC and raw
`ftq_enq_*` fields at each policy branch. This keeps the request PC, FTQ
idx/epoch/tag, and full FTQ entry snapshot paired at one local source before a
future owner queue or capacity-bounded runahead path is introduced.

- Build: `./build_dsim.sh` passed before this smoke; no RTL dependency changed
  after that rebuild.
- Strict/profiled anchor smoke artifact:
  `benchmark_results/20260506_ifu_req_work_item_smoke/`.
- Strict/profiled frontend smoke artifact:
  `benchmark_results/20260506_ifu_req_work_item_frontend_smoke/`.

| Workload | Status | Timed cycles | Timed instret | Metric | Notes |
|---|---|---:|---:|---:|---|
| Dhrystone 100 | PASS | 27,093 | 48,436 | 2.100734 DMIPS/MHz | strict owner/delivery clean |
| CoreMark 1 | PASS | 209,058 | 318,379 | 4.783362 CM/MHz | strict owner/delivery clean |
| Mixed branch dense | PASS | - | - | - | strict frontend smoke clean |
| Data-dependent branch | PASS | - | - | - | strict frontend smoke clean |
| Call/return mimic | PASS | - | - | - | strict frontend smoke clean |
| Taken loop 100 | PASS | - | - | - | strict frontend smoke clean |

Key anchor counters remain neutral relative to the ICQ FTQ-entry checkpoint:
`ftq_occ_max=1`, `packet_buf_occ_max=0`, `xs_f2_owner_idx_mismatch=0`,
`xs_f2_owner_tag_mismatch=0`, and `packet_stale_* = 0`. Verdict: accept as a
local owner-pairing cleanup only. It does not claim performance movement or
enable proactive runahead by itself.

## Bottleneck (data-driven)

`tools/bubble_attribution.py` on cm10 (commit-stage classification):

| Category | Cycles | % of run | Notes |
|---|---:|---:|---|
| PRODUCTIVE | 1,617,865 | 79.1% | commit > 0 |
| BACKEND_STALL | 230,971 | 11.3% | fetch>0 + commit=0 + rob_cnt>0 |
| FRONTEND_BUBBLE | 115,650 | 5.7% | fetch=0 + rob_cnt>0 |
| IDLE_BUBBLE | 27,976 | 1.4% | fetch=0 + rob_cnt=0 |
| FLUSH | 20,063 | 1.0% | control-flow recovery |
| RAMP | 32,646 | 1.6% | reset/edge cases |

Per-PC BACKEND_STALL attribution shows the dominant stalls are
load-consumer chains in `core_state_transition` and `core_list_mergesort`.
The "branch BACKEND_STALL" cluster is **state-machine branches consuming
a load result**, not loop branches — a loop predictor would not help.

The "97% packet_buf_empty" reading from `xs_packet_buf_empty_cycles`
is a metric artifact: the same-cycle bypass path keeps the buffer empty
even on supply cycles. True decode-supply rate is **58.5%**; true
decode bubble is **41.5%** at the frontend stage, mostly absorbed by
packet_buf+ROB so only 5.7% propagates to commit.

## Architectural finding: frontend-proactive is the answer

User push-back rejected the dcache-latency framing. BOOM and XiangShan
operate at the same load-to-use class (3-4 cycle hit) yet achieve higher
IPC. The differentiator is frontend supply rate, specifically how F1
advances.

Inspecting BOOM v4 `src/main/scala/v4/ifu/frontend.scala` (lines 347-571):

```scala
val s0_valid = WireInit(false.B)
val s1_valid = RegNext(s0_valid)
val s2_valid = RegNext(s1_valid && !f1_clear)
...
when (s2_valid && f3_ready) {
    when (s1_valid && s1_vpc === f2_predicted_target && !f2_correct_f1_ghist) {
        // s0 advances per BPD's predicted target
    }
}
val f3 = Module(new Queue(new FetchBundle, 1, pipe=true, flow=false))
```

BOOM's s0 advances **proactively** based on BPD prediction every cycle.
The f3 queue absorbs rate mismatch with backpressure to s0.

Our equivalent: F1 advances **reactively** from `f2_seq_next_pc` (case
4 in the next_pc priority chain at fetch_unit.sv:170). F1 only advances
when F2 emits. This is the lockstep that limits frontend supply to
~58.5% of cycles.

The "BACKEND_STALL=11.3%" is partially intrinsic but is also a symptom
of low frontend supply: with fewer parallel chains in flight, each
chain's latency manifests as ROB head stall instead of overlapping.
BOOM hides the same load latency behind more parallelism.

## XiangShan-aligned ownership breakdown, 2026-05-06

The next performance work should follow XiangShan's frontend ownership split
rather than continue local `fetch_unit.sv` steering. XiangShan separates the
frontend into:

- BPU: prediction producer plus redirect/train/commit consumer.
- FTQ: dynamic fetch-block owner with separate BPU, prefetch, IFU, IFU-writeback,
  and commit/training pointers.
- IFU: consumes FTQ-owned requests, reads ICache, expands/predecodes, checks
  predicted control, writes validation/redirect information back to FTQ.
- IBuffer: decouples IFU packet production from backend/decode consumption while
  preserving per-instruction FTQ identity.

rv64gc-v2 is now aligned in direction but not yet in depth:

| Role | Current rv64gc-v2 state | Bottleneck impact | Next refactor slice |
|---|---|---|---|
| BPU owner production | BPU prediction is still coupled to F2 packet progress. | F1 cannot build a predicted stream; FTQ occupancy remains shallow. | Enable proactive F1 only after FTQ owner allocation and IBuffer capacity are structural. |
| FTQ owner lifetime | `ftq.sv` now has separate allocation-to-request, request-to-writeback, and writeback-to-commit state, with distinct IFU request and IFU-writeback owner views. First-packet delivery now pushes the owner into the commit/decode-visible region separately from final IFU-owner completion, so a same-owner continuation can remain live without making the packet buffer see a stale owner. `ifu_req_ready` is gated by response-queue and IBuffer capacity. | F2 completion, IBuffer flow-through, and owner-mismatch counters now name the correct completion-side role instead of raw queue-head state. The delivery split removes stale-owner accounting but still does not create runahead. | Define redirect/epoch lifetime for outstanding responses, then use the capacity-aware boundary for bounded runahead. |
| IFU validation | IFU/F2 logic still lives mostly inside `fetch_unit.sv`, but there is now a stateful IFU work cursor (`ifu_work_item_t`) carrying PC, line address, FTQ identity, delivery state, and completion state. Raw F2 PC/FTQ mirror registers have been removed, so the cursor is the single registered F2 work state. Same-line straight-line continuation remains under the same FTQ owner until the final packet. Request de-dup, NLPB response matching, line acceptance, line-state matching, extraction, predecode, owner-live checks, packet metadata, debug/probe reporting, and the owner-completion decision all use cursor aliases. | The boundary is structurally in place, but F1/F2 are still lockstep and duplicate/no-emit pressure remains high. | Continue replacing local F1/F2 owner steering with FTQ owner identity while preserving the cursor-owned in-owner PC. |
| IBuffer elasticity | `fetch_packet_buffer.sv` is now the owner-aware decode-facing IBuffer boundary: it stores complete fetch packets, exposes enqueue/dequeue fire, classifies the head packet as owner-match/stale/owner-complete against the FTQ commit owner, and owns the empty-buffer flow-through path to decode. `+FETCH_DELIVERY_STRICT` now survives the clean Dhrystone/CoreMark smoke. | It now manages the commit-pop side of owner lifetime and removes the separate `packet_buf_in` decode bypass, but F1/F2 are still mostly lockstep and duplicate suppression remains in `fetch_unit.sv`. | Use IBuffer capacity to bound proactive F1 runahead, then broaden strict delivery/golden-PC coverage. |

The current bottleneck maps to the missing IFU/IBuffer split: the core can
predict and fetch, but ownership, validation, packet formation, and decode
delivery are still too tightly coupled. This keeps the frontend effectively
near one owned packet deep even when the backend could tolerate more in-flight
work.

## Next-session performance plan

The next session should use this order:

1. **Rebuild after the FTQ IFU-writeback owner-view slice.** Done on
   2026-05-06; functionally neutral.
2. **Split the IFU request owner from the IFU-writeback owner.** Done on
   2026-05-06 as structural FTQ state. The registered allocation-derived bridge
   has been removed; `fetch_unit.sv` now asserts request-accept in the normal
   request allocation cycle, with same-cycle alloc-to-IFU handled
   inside `ftq.sv`.
3. **Convert `fetch_packet_buffer` into owner-aware IBuffer.** Initial boundary
   done on 2026-05-06: complete packet metadata is stored, enqueue/dequeue fire
   is explicit, and the head packet is classified against the FTQ commit owner.
   `+FETCH_DELIVERY_STRICT` was hardened to preserve the next expected PC for a
   same FTQ owner even when a completed packet is followed by another packet
   carrying the same owner tag. The buffer now owns the empty-buffer
   flow-through path to decode, and F2 emission uses IBuffer enqueue-ready
   rather than the raw full flag. Remaining work is using IBuffer occupancy as
   a real runahead capacity limit and broadening strict/golden coverage.
4. **Introduce a neutral IFU work cursor.** Done on 2026-05-06. The cursor is
   stateful and is now the single registered F2 work state; the old raw F2
   PC/FTQ mirror registers were retired. SVA D3 now checks the cursor's own
   line identity rather than mirror equality. Line-data acceptance
   and line-state matching use the cursor's active `line_addr`; extraction,
   predecode, owner-live checks, packet metadata, packet flow-through, and FTQ IFU-pop
   completion now reference the cursor through `f2_work_*` and the named
   `f2_work_owner_complete_c` boundary. On a clean IFU-owner completion, the
   cursor now takes next-owner identity from the FTQ IFU-writeback view while
   keeping the cursor-computed `f2_seq_next_pc`. Debug/probe paths that report
   active F2 PC/FTQ state also read `f2_work_*`, including the testbench
   hierarchical probes that used to read `f2_valid_r`/`f2_pc_r`.
5. **Split first-packet delivery from final IFU completion.** Done as a
   structural checkpoint on 2026-05-06. Same-line straight-line continuation
   can keep the same FTQ owner live across multiple packets while the first
   packet still makes that owner visible to the IBuffer/commit side. This fixes
   stale-owner accounting, but the run regressed timing and left `ftq_occ_max`
   at 1 and `packet_buf_occ_max` at 0, so it is not performance evidence.
6. **Carry complete FTQ request metadata through the ICQ.** Done on
   2026-05-06. The response queue now carries request PC, FTQ idx/epoch/tag,
   and the full FTQ entry snapshot. This is the accepted replacement for the
   rejected flow-through owner queue wrapper: later cursor handoff must consume
   this coherent request object instead of re-pairing PC and FTQ metadata from
   separate phases.
7. **Then enable bounded BPU/F1 runahead.** F1 can advance from BPU prediction
   only when FTQ allocation and IBuffer capacity are available. The runahead
   limit should initially be small and derived from FTQ/IBuffer occupancy, not
   benchmark PCs.
8. **Measure the intended counters.** The improvement claim is valid only if
   `packet_empty_noemit_dup`, `xs_dup_last_emit`, frontend bubbles, and shallow
   FTQ occupancy move in the expected direction while endpoint identity and
   owner-invariant counters remain clean.

Do not add an active XiangShan-style `pfPtr` yet. Prefetch can help later, but
the current bottleneck is demand ownership: BPU allocation, IFU request issue,
IFU writeback, and IBuffer delivery are still not independently tracked.

## Evidence Qualification, Fresh Profiled Smoke

The identical-cycle rows below remain useful only as endpoint/invariant
functionality smoke unless the row explicitly has a fresh `+PERF_PROFILE`
summary generated after the current RTL rebuild. Several earlier summaries
were generated before the latest `fetch_unit.sv` edit or had empty frontend
profile columns, so they must not be used as evidence that an architecture
change is performance-active. Treat those rows as: **functionality smoke only;
performance unproven**.

Previous fresh profiled smoke, retained for counter-comparison history:

- Rebuild: `./build_dsim.sh` passed after the current `fetch_unit.sv` timestamp,
  including the simulation-only `+TRACE_FETCH_OWNER` diagnostic hook.
- Run artifact:
  `benchmark_results/20260506_owner_complete_successor_gate_smoke_seq/summary.md`.
- Required plusargs were present in both command lines:
  `+FETCH_DELIVERY_CHECK +FETCH_DELIVERY_STRICT +FETCH_OWNER_CHECK
  +FETCH_OWNER_STRICT +PERF_PROFILE`.
- Endpoint/invariant grep was clean: no `ERROR`, `FATAL`, `INVARIANT_`,
  `ASSERT`, or `FAIL` signatures in the run directory.
  A follow-up `+TRACE_FETCH_OWNER` diagnostic run also passed and produced zero
  owner-trace lines:
  `benchmark_results/20260506_owner_complete_successor_gate_trace_seq/summary.md`.

Fresh profiled smoke result:

| Workload | Status | Timed cycles | Timed instret | Metric |
|---|---|---:|---:|---:|
| Dhrystone 100 | PASS | 26,394 | 48,436 | 2.156369 DMIPS/MHz |
| CoreMark 1 | PASS | 207,775 | 318,379 | 4.812899 CM/MHz |

Dhrystone 100 counter movement versus locked Stage 1 baseline
`benchmark_results/signoff_20260505_stage1_current_recheck`:

| Counter | Locked baseline | Fresh current RTL | Movement |
|---|---:|---:|---:|
| Timed cycles | 26,394 | 26,394 | 0 |
| `ftq_occ_max` | 1 | 1 | 0 |
| `packet_buf_occ_max` | 1 | 0 | -1 |
| `packet_empty_noemit_dup` | 8,563 | 8,997 | +434 |
| `packet_empty_f2_data` | 9,292 | 9,308 | +16 |
| `f2_owner_idx_mismatch` | 0 | 0 | 0 |
| `ftq_empty_cycles` | 9,042 | 8,927 | -115 |
| Frontend zero cycles | 9,484 | 9,462 | -22 |
| Frontend hist `0/1/2/3/4` | `9484/4501/3135/2076/7717` | `9462/4501/3137/2076/7717` | effectively flat |
| IBuffer stale owner total | 309 | 418 | +109 |
| Packet stale `no_head/idx/epoch/tag` | `107/202/0/0` | `418/0/0/0` | bucket shifted |

CoreMark iter1 does not have a locked signoff baseline row; the signoff
CoreMark row is iter10. For smoke-to-smoke comparison only, the closest clean
profiled CoreMark iter1 row is
`benchmark_results/20260506_queue_boundary_restored_smoke_seq`:

| Counter | Prior profiled iter1 smoke | Fresh current RTL | Movement |
|---|---:|---:|---:|
| Timed cycles | 207,870 | 207,775 | -95 |
| `ftq_occ_max` | 1 | 1 | 0 |
| `packet_buf_occ_max` | 1 | 0 | -1 |
| `packet_empty_noemit_dup` | 76,252 | 82,038 | +5,786 |
| `packet_empty_f2_data` | 85,166 | 85,166 | 0 |
| `f2_owner_idx_mismatch` | 76,909 | 0 | -76,909 |
| `ftq_empty_cycles` | 86,106 | 83,056 | -3,050 |
| Frontend zero cycles | 91,460 | 91,304 | -156 |
| Frontend hist `0/1/2/3/4` | `91460/34029/14247/22535/56093` | `91304/34038/14250/22545/56068` | effectively flat |
| IBuffer stale owner total | 5,786 | 5,792 | +6 |
| Packet stale `no_head/idx/epoch/tag` | `5662/124/0/0` | `5792/0/0/0` | bucket shifted |

Verdict at that checkpoint: the rebuilt RTL was endpoint-clean and profiled,
but did not prove a performance-active architecture change. The newer current
RTL checkpoint at the top of this document supersedes this as the latest
evidence and reaches the same conclusion: the frontend remains lockstep.

Long-run launch status: scoreable Stage 1 should still wait for the next
performance-active frontend slice. The owner-completion invariant is clean in
smoke, but the frontend remains lockstep (`ftq_occ_max=1`, IBuffer occupancy
0 through flow-through), so a full signoff run before bounded F1/BPU runahead
would mostly re-score the existing timing point.

2026-05-06 owner-completion counter split and E2 guard:

| Workload | Status | Timed cycles | Timed instret | Notes |
|---|---|---:|---:|---|
| Dhrystone 100 | PASS | 26,394 | 48,436 | wrong-owner completion candidates are measured separately from raw cursor/writeback skew |
| CoreMark 1 | PASS | 207,775 | 318,379 | SVA E2 now checks that wrong-owner completion candidates cannot pop FTQ |

Accepted run artifact:
`benchmark_results/20260506_owner_completion_counter_split_e2guard_smoke_seq/summary.md`.
No invariant/error/fail signatures were found in the run logs.

Counter interpretation after this slice:

| Counter family | Meaning |
|---|---|
| `xs_f2_owner_*` | Architecturally relevant owner state for completed IFU work candidates. Nonzero `no_head` or `idx_mismatch` means the cursor can still produce a completed packet while FTQ IFU-writeback ownership is elsewhere; it is blocked from popping FTQ by `ftq_ifu_pop_valid = candidate && owner_live`. |
| `xs_f2_cursor_wb_*` | Diagnostic raw skew between the live IFU work cursor and the FTQ IFU-writeback pointer. This is expected to remain high until the cursor is fully driven by the FTQ/IBuffer work contract. |

Superseded blocker: this slice exposed nonzero
`xs_f2_owner_idx_mismatch` (Dhrystone 202, CoreMark iter1 138) and
`xs_f2_owner_no_head` (Dhrystone 107, CoreMark iter1 2,977). The successor-gated
owner-completion slice below resolves those architectural owner counters while
leaving raw cursor/writeback skew as diagnostic evidence of the remaining
lockstep frontend.

2026-05-06 non-live owner trace hook:

| Workload | Status | Timed cycles | Timed instret | Trace count | Notes |
|---|---|---:|---:|---:|---|
| Dhrystone 100 | PASS | 26,394 | 48,436 | 309 | `TRACE_FETCH_OWNER` count equals `xs_f2_owner_no_head + xs_f2_owner_idx_mismatch` (`107 + 202`) |
| CoreMark 1 | PASS | 207,775 | 318,379 | 3,115 | `TRACE_FETCH_OWNER` count equals `xs_f2_owner_no_head + xs_f2_owner_idx_mismatch` (`2,977 + 138`) |

Accepted diagnostic artifact:
`benchmark_results/20260506_fetch_owner_trace_diag_seq/summary.md`.
The hook is simulation-only and prints only when a completed IFU work candidate
is not live at the FTQ IFU-writeback owner. The first Dhrystone hit occurs at
cycle 20 (`pc=0x8000004c`, `seq=0x80000058`) immediately after the prior
same-owner packet popped the IFU-writeback owner. Later mismatch samples show
`work_idx/tag` one owner behind the FTQ IFU-writeback owner. This narrows the
blocker to the IFU-owner completion boundary: `f2_work_owner_complete_c` can
complete an FTQ owner before all required same-owner packet PCs have been
delivered. It is not a decode-side IBuffer dequeue problem.

2026-05-06 successor-gated owner-completion boundary:

| Workload | Status | Timed cycles | Timed instret | Owner no-head/idx | Notes |
|---|---|---:|---:|---:|---|
| Dhrystone 100 | PASS | 26,394 | 48,436 | `0 / 0` | same cycles as prior smoke; FTQ owner completion no longer pops on straddle-remainder consume |
| CoreMark 1 | PASS | 207,775 | 318,379 | `0 / 0` | remaining CoreMark no-head event was a taken redirect without a successor owner; now gated by registered FTQ successor state |

Accepted run artifacts:
`benchmark_results/20260506_owner_complete_successor_gate_smoke_seq/summary.md`
and
`benchmark_results/20260506_owner_complete_successor_gate_trace_seq/summary.md`.
The trace diagnostic emitted zero `FETCH_OWNER_TRACE` lines. The accepted RTL
uses `consume_remainder_c` and registered `ftq_count_ifu_to_wb`/`ftq_enq_valid`
state to decide whether the current owner has a successor before pop.

Rejected variant:
`benchmark_results/20260506_owner_complete_keep_owner_gate_smoke_seq/summary.md`.
Gating completion directly with `ifu_work_redirect_keep_owner_c` hit DSim
`ITERLIMIT` on both smoke workloads because that signal depends on the
combinational FTQ next-owner view, which in turn depends on the pop decision.
That form was backed out.

2026-05-06 owner-view smoke after adding the explicit IFU-writeback owner alias:

| Workload | Status | Timed cycles | Timed instret | Notes |
|---|---|---:|---:|---|
| Dhrystone 100 | PASS | 26,394 | 48,436 | endpoint clean; legacy loop buffer and decoded-op replay both zero |
| CoreMark 1 | PASS | 207,870 | 318,379 | endpoint clean; legacy loop buffer and decoded-op replay both zero |

Run artifact:
`benchmark_results/20260506_ifu_wb_owner_smoke/summary.md`.

2026-05-06 smoke after splitting IFU request owner from IFU-writeback owner:

| Workload | Status | Timed cycles | Timed instret | Notes |
|---|---|---:|---:|---|
| Dhrystone 100 | PASS | 26,394 | 48,436 | endpoint clean; legacy loop buffer and decoded-op replay both zero |
| CoreMark 1 | PASS | 207,870 | 318,379 | endpoint clean; legacy loop buffer and decoded-op replay both zero |

Run artifact:
`benchmark_results/20260506_ifu_ptr_wb_ptr_split_smoke/summary.md`.

2026-05-06 smoke after adding the owner-aware IBuffer boundary, direct
allocation-cycle IFU request accept, and explicit monolithic
`ifu_req_valid/ready/fire` boundary:

| Workload | Status | Timed cycles | Timed instret | Notes |
|---|---|---:|---:|---|
| Dhrystone 100 | PASS | 26,394 | 48,436 | endpoint clean; legacy loop buffer and decoded-op replay both zero |
| CoreMark 1 | PASS | 207,870 | 318,379 | endpoint clean; legacy loop buffer and decoded-op replay both zero |

Run artifacts:
`benchmark_results/20260506_owner_aware_ibuffer_smoke/summary.md` and
`benchmark_results/20260506_ifu_req_accept_bypass_smoke/summary.md`;
latest equivalent recheck:
`benchmark_results/20260506_ifu_req_boundary_smoke/summary.md`.

2026-05-06 strict delivery-check recheck:

| Workload | Status | Timed cycles | Timed instret | Notes |
|---|---|---:|---:|---|
| Dhrystone 100 | PASS | 26,394 | 48,436 | `+FETCH_DELIVERY_CHECK +FETCH_DELIVERY_STRICT`; no false trip at `0x8000003a -> 0x8000004c` |
| CoreMark 1 | PASS | 207,870 | 318,379 | `+FETCH_DELIVERY_CHECK +FETCH_DELIVERY_STRICT`; endpoint clean |

Run artifacts:
`benchmark_results/20260506_fetch_delivery_strict_recheck/summary.md` and
`benchmark_results/20260506_fetch_delivery_strict_coremark/summary.md`.

2026-05-06 capacity-aware IFU request boundary recheck:

| Workload | Status | Timed cycles | Timed instret | Notes |
|---|---|---:|---:|---|
| Dhrystone 100 | PASS | 26,394 | 48,436 | `ifu_req_ready = !icq_full && !packet_buf_full`; strict delivery clean |
| CoreMark 1 | PASS | 207,870 | 318,379 | `ifu_req_ready = !icq_full && !packet_buf_full`; strict delivery clean |

Run artifact:
`benchmark_results/20260506_ifu_req_capacity_gate_smoke_seq/summary.md`.

2026-05-06 neutral IFU work-cursor and line-gate recheck:

| Workload | Status | Timed cycles | Timed instret | Notes |
|---|---|---:|---:|---|
| Dhrystone 100 | PASS | 26,396 | 48,436 | `ifu_work_item_t` mirrors F2 by SVA D3; line gates use `f2_work_*`; strict delivery/owner clean |
| CoreMark 1 | PASS | 207,855 | 318,379 | `ifu_work_item_t` mirrors F2 by SVA D3; line gates use `f2_work_*`; strict delivery/owner clean |

The result is behaviorally neutral against the identity and cursor-mirror
rechecks: Dhrystone/CoreMark `mcycle`, `minstret`, timed cycles, timed
instruction count, and timed IPC match
`benchmark_results/20260506_f2_work_identity_sva_clean_smoke_seq` and
`benchmark_results/20260506_ifu_work_cursor_mirror_smoke_seq`.

Run artifact:
`benchmark_results/20260506_ifu_work_cursor_linegate_smoke_seq/summary.md`.
XSim fallback was also rebuilt and
`./run_xsim.sh tests/hex/rv64ui_minimal.hex 50000 +FETCH_DELIVERY_CHECK
+FETCH_DELIVERY_STRICT +FETCH_OWNER_CHECK +FETCH_OWNER_STRICT` passed.

2026-05-06 IFU work-cursor owner-reference and active-line recheck:

| Workload | Status | Timed cycles | Timed instret | Notes |
|---|---|---:|---:|---|
| Dhrystone 100 | PASS | 26,396 | 48,436 | owner-live/mismatch SVA and counters use `f2_work_*`; response-line matching uses active `ifu_work_r.line_addr` |
| CoreMark 1 | PASS | 207,855 | 318,379 | owner-live/mismatch SVA and counters use `f2_work_*`; response-line matching uses active `ifu_work_r.line_addr` |

Run artifacts:
`benchmark_results/20260506_ifu_work_cursor_owner_refs_smoke_seq/summary.md`
and
`benchmark_results/20260506_ifu_work_cursor_active_line_smoke_seq/summary.md`.
The latest XSim fallback was rebuilt and `rv64ui_minimal` passed with strict
delivery/owner checks.

2026-05-06 IFU work-cursor request/NLPB boundary recheck:

| Workload | Status | Timed cycles | Timed instret | Notes |
|---|---|---:|---:|---|
| Dhrystone 100 | PASS | 26,396 | 48,436 | FTQ allocation anti-dup and NLPB response-line match use IFU work cursor aliases |
| CoreMark 1 | PASS | 207,855 | 318,379 | FTQ allocation anti-dup and NLPB response-line match use IFU work cursor aliases |

Run artifact:
`benchmark_results/20260506_ifu_work_cursor_req_nlp_smoke_seq/summary.md`.
XSim fallback was rebuilt again and `rv64ui_minimal` passed with strict
delivery/owner checks.

2026-05-06 IFU work-cursor owner-completion boundary recheck:

| Workload | Status | Timed cycles | Timed instret | Notes |
|---|---|---:|---:|---|
| Dhrystone 100 | PASS | 26,396 | 48,436 | packet completion, bypass pop, and FTQ IFU pop share `f2_work_owner_complete_c` |
| CoreMark 1 | PASS | 207,855 | 318,379 | packet completion, bypass pop, and FTQ IFU pop share `f2_work_owner_complete_c` |

Run artifact:
`benchmark_results/20260506_ifu_work_owner_complete_boundary_smoke_seq/summary.md`.
XSim fallback was rebuilt and `rv64ui_minimal` passed with strict
delivery/owner checks.

2026-05-06 IFU work-cursor source-side mirror recheck:

| Workload | Status | Timed cycles | Timed instret | Notes |
|---|---|---:|---:|---|
| Dhrystone 100 | PASS | 26,396 | 48,436 | source-side mirror cleanup was neutral at this step; SVA D3 remained clean |
| CoreMark 1 | PASS | 207,855 | 318,379 | source-side mirror cleanup was neutral at this step; SVA D3 remained clean |

Run artifact:
`benchmark_results/20260506_ifu_work_cursor_sources_f2_smoke_seq/summary.md`.
XSim fallback was rebuilt and `rv64ui_minimal` passed with strict
delivery/owner checks.

2026-05-06 IFU work-cursor single-mirror cleanup and next-owner handoff:

| Workload | Status | Timed cycles | Timed instret | Notes |
|---|---|---:|---:|---|
| Dhrystone 100 | PASS | 26,396 | 48,436 | raw F2 PC/FTQ has one source: `ifu_work_next_c`; next-owner identity is taken from FTQ on clean owner completion |
| CoreMark 1 | PASS | 207,855 | 318,379 | raw F2 PC/FTQ has one source: `ifu_work_next_c`; next-owner identity is taken from FTQ on clean owner completion |

Accepted run artifacts:
`benchmark_results/20260506_ifu_work_cursor_single_f2_mirror_smoke_seq/summary.md`,
`benchmark_results/20260506_ifu_work_cursor_single_f2_mirror_recheck_seq/summary.md`,
and
`benchmark_results/20260506_ifu_work_cursor_next_owner_seqpc_smoke_seq/summary.md`.
Rejected variant:
`benchmark_results/20260506_ifu_work_cursor_ftq_next_owner_smoke_seq/summary.md`
loaded the FTQ next-owner entry start PC directly and starved both smoke rows.
Verdict: the FTQ IFU-writeback pointer supplies owner identity; the IFU cursor
must still supply the current in-owner PC (`f2_seq_next_pc` on this handoff).
XSim fallback was rebuilt and `rv64ui_minimal` passed with strict
delivery/owner checks.

2026-05-06 IFU work-cursor debug/probe source cleanup:

| Workload | Status | Timed cycles | Timed instret | Notes |
|---|---|---:|---:|---|
| Dhrystone 100 | PASS | 26,396 | 48,436 | D3 now names raw F2 as the mirror; debug/probe F2 PC/FTQ reporting uses `f2_work_*` aliases |
| CoreMark 1 | PASS | 207,855 | 318,379 | D3 now names raw F2 as the mirror; debug/probe F2 PC/FTQ reporting uses `f2_work_*` aliases |

Accepted run artifact:
`benchmark_results/20260506_ifu_work_cursor_debug_refs_smoke_seq/summary.md`.
No invariant/error/fail signatures were found in the run logs. This is a
refactor-neutral smoke only; it does not advance the performance signoff claim.
DSim licensing was available for this slice, so the XSim fallback was not needed.

2026-05-06 raw F2 mirror-register retirement:

| Workload | Status | Timed cycles | Timed instret | Notes |
|---|---|---:|---:|---|
| Dhrystone 100 | PASS | 26,396 | 48,436 | removed raw F2 PC/FTQ mirror registers; D3 now checks IFU work cursor line self-consistency |
| CoreMark 1 | PASS | 207,855 | 318,379 | testbench hierarchical probes now read `f2_work_valid_c` / `f2_work_pc_c` |

Accepted run artifact:
`benchmark_results/20260506_ifu_work_raw_f2_retired_smoke_seq/summary.md`.
No invariant/error/fail signatures were found in the run logs. This remains
refactor-neutral evidence only; it does not advance the performance signoff
claim.

2026-05-06 IBuffer-owned flow-through:

| Workload | Status | Timed cycles | Timed instret | Notes |
|---|---|---:|---:|---|
| Dhrystone 100 | PASS | 26,394 | 48,436 | empty-buffer same-cycle delivery now comes from `fetch_packet_buffer` flow-through |
| CoreMark 1 | PASS | 207,775 | 318,379 | F2 emission uses IBuffer enqueue-ready; FTQ commit-pop comes only from IBuffer dequeue |

Accepted run artifact:
`benchmark_results/20260506_ibuffer_flowthrough_smoke_seq/summary.md`.
No invariant/error/fail signatures were found in the run logs. The small cycle
movement is noted only to confirm the refactor did not introduce an obvious
penalty; performance analysis remains deferred until the frontend refactor is
finished.
XSim fallback sanity was also rebuilt and `rv64ui_minimal` passed at cycle 53
with strict delivery/owner checks: owner switch before complete `0`,
non-contiguous packet PCs `0`, packet line metadata mismatch `0`,
duplicate/replayed PCs `0`, skipped PCs `0`.

2026-05-06 direct packet flow-through knob retirement:

| Workload | Status | Timed cycles | Timed instret | Notes |
|---|---|---:|---:|---|
| Dhrystone 100 | PASS | 26,394 | 48,436 | removed stale `FETCH_PACKET_BYPASS2*` controls after decode became IBuffer-owned |
| CoreMark 1 | PASS | 207,775 | 318,379 | remaining flow-through signal observes IBuffer flow-through only |

Accepted run artifact:
`benchmark_results/20260506_packet_bypass_knobs_retired_smoke_seq/summary.md`.
No invariant/error/fail signatures were found in the run logs.

2026-05-06 local lookahead knob retirement:

| Workload | Status | Timed cycles | Timed instret | Notes |
|---|---|---:|---:|---|
| Dhrystone 100 | PASS | 26,394 | 48,436 | removed opt-in same-line, same-tail, sequential-lookahead, and weak-bias plusargs |
| CoreMark 1 | PASS | 207,775 | 318,379 | default behavior remains matched to the IBuffer flow-through baseline |

Accepted run artifact:
`benchmark_results/20260506_local_lookahead_knobs_retired_smoke_seq/summary.md`.
No invariant/error/fail signatures were found in the run logs.

2026-05-06 local shortcut logic removal:

| Workload | Status | Timed cycles | Timed instret | Notes |
|---|---|---:|---:|---|
| Dhrystone 100 | PASS | 26,394 | 48,436 | deleted the unreachable same-line, same-tail, sequential-lookahead, weak-bias, and direct packet policy/tail logic |
| CoreMark 1 | PASS | 207,775 | 318,379 | result remains matched to the IBuffer flow-through baseline |

Accepted run artifact:
`benchmark_results/20260506_local_shortcut_logic_removed_smoke_seq/summary.md`.
No invariant/error/fail signatures were found in the run logs.

Restored-baseline recheck after backing out the rejected runahead attempt:

| Workload | Status | Timed cycles | Timed instret | Notes |
|---|---|---:|---:|---|
| Dhrystone 100 | PASS | 26,394 | 48,436 | working tree restored to the local-shortcut-removal baseline |
| CoreMark 1 | PASS | 207,775 | 318,379 | no invariant/error/fail signatures in logs |

Accepted run artifact:
`benchmark_results/20260506_after_reverted_runahead_smoke_seq/summary.md`.

2026-05-06 IFU cursor named owner-policy cleanup:

| Workload | Status | Timed cycles | Timed instret | Notes |
|---|---|---:|---:|---|
| Dhrystone 100 | PASS | 26,394 | 48,436 | explicit cursor policy signals separate redirect, FTQ next-owner handoff, normal request owner load, and remainder request owner load |
| CoreMark 1 | PASS | 207,775 | 318,379 | matching redirect handoff may use the FTQ next IFU-writeback owner view before falling back to direct request allocation |

Accepted run artifact:
`benchmark_results/20260506_ifu_cursor_named_owner_policy_smoke_seq/summary.md`.
No invariant/error/fail signatures were found in the run logs.

2026-05-06 FTQ enqueue-ready request boundary:

| Workload | Status | Timed cycles | Timed instret | Notes |
|---|---|---:|---:|---|
| Dhrystone 100 | PASS | 26,394 | 48,436 | `ftq_enq_ready` now feeds IFU request-ready and fetch stall instead of inferring readiness from `ftq_full` alone |
| CoreMark 1 | PASS | 207,775 | 318,379 | result remains matched to the owner-policy cleanup baseline |

Accepted run artifact:
`benchmark_results/20260506_ftq_enq_ready_boundary_smoke_seq/summary.md`.
No invariant/error/fail signatures were found in the run logs.

2026-05-06 FTQ IFU-to-writeback count export:

| Workload | Status | Timed cycles | Timed instret | Notes |
|---|---|---:|---:|---|
| Dhrystone 100 | PASS | 26,394 | 48,436 | `ftq.sv` now exposes requested-not-written-back owner occupancy for future capacity-owned runahead limits |
| CoreMark 1 | PASS | 207,775 | 318,379 | structural port addition is behaviorally neutral |

Accepted run artifact:
`benchmark_results/20260506_ftq_ifu_to_wb_count_export_smoke_seq/summary.md`.
No invariant/error/fail signatures were found in the run logs.

2026-05-06 IFU owner-policy SVA:

| Workload | Status | Timed cycles | Timed instret | Notes |
|---|---|---:|---:|---|
| Dhrystone 100 | PASS | 26,394 | 48,436 | added SVA for IFU request-pop ready/enqueue alignment and FTQ next-owner cursor loads |
| CoreMark 1 | PASS | 207,775 | 318,379 | new invariants F/G/H are calibrated to the current architecture |

Accepted run artifact:
`benchmark_results/20260506_ifu_owner_policy_sva_smoke_seq/summary.md`.
No invariant/error/fail signatures were found in the run logs.

2026-05-06 packet flow-through naming cleanup:

| Workload | Status | Timed cycles | Timed instret | Notes |
|---|---|---:|---:|---|
| Dhrystone 100 | PASS | 26,394 | 48,436 | frontend packet fast path is now named as IBuffer-owned flow-through, not a fetch-unit bypass |
| CoreMark 1 | PASS | 207,775 | 318,379 | `packet_flowthrough_*` and `xs_flowthrough_*` counters are behaviorally neutral |

Accepted run artifact:
`benchmark_results/20260506_packet_flowthrough_rename_smoke_seq/summary.md`.
No invariant/error/fail signatures were found in the run logs. This is a
semantic cleanup only; the timing remains matched to the accepted
IBuffer-owned flow-through baseline.

## 2026-05-06 Queue/F2 Prototype Results

Several response-queue/F2 experiments were intentionally rejected and removed
from the default RTL. They are useful evidence for the next architecture slice,
but none is a scoreable Stage 1 mechanism.

| Experiment | Artifact | Observed behavior | Verdict |
|---|---|---|---|
| Queue-head-as-line-latch | `benchmark_results/20260506_icq_line_hold_smoke_seq/summary.md` | Dhrystone and CoreMark both TIMEOUT with only 11 retired instructions; `packet_empty_noemit_dup` dominates. | Rejected. Queue credit was coupled into `fe_stall`, freezing F2 instead of creating runahead. |
| Split request credit from F2 hold | `benchmark_results/20260506_icq_line_hold_splitstall_smoke_seq/summary.md` | Strict delivery fails, e.g. non-contiguous owner stream after F2 starts consuming line state under the wrong owner. | Rejected. It removed the starvation symptom but exposed missing owner semantics. |
| Explicit F2 line register | `benchmark_results/20260506_f2_line_register_smoke_seq/summary.md` | Strict delivery fails immediately: expected `0x80000042`, got `0x80000002` for the same FTQ owner stream. | Rejected. The current frontend can issue multiple same-line request/allocation events, so a naive line latch replays an earlier line position under a younger owner. |
| Hold-only IFU cursor decoupling plus one-target conditional runahead | `benchmark_results/20260506_bpu_cond_runahead_smoke_seq/summary.md` | Dhrystone 100 TIMEOUT after 86 retired instructions; CoreMark fails strict delivery (`expected 0x800027d8`, got `0x80002056`); `xs bpu runahead fires` is `0`, while F2 owner-index mismatch dominates. | Rejected and backed out. The failure is not useful BPU runahead; it proves the cursor cannot be held independently unless it also advances from the FTQ IFU-writeback owner at the correct phase. |
| Gate IBuffer dequeue on owner-ready | `benchmark_results/20260506_ibuffer_owner_ready_deq_smoke_seq` | Dhrystone/CoreMark abort quickly under strict owner checking with `fetch owner stream duplicate or skip`, e.g. expected `0x80000058` but replayed `0x8000004c`. | Rejected and backed out. Commit-side packet dequeue is the wrong control point; the owner has already been completed too early before this logic can repair the stream. |
| Guard normal request-owner cursor overwrite | `benchmark_results/20260506_request_owner_guard_smoke/summary.md` | Dhrystone TIMEOUT after 89 retired instructions and CoreMark TIMEOUT after 417 retired instructions; `xs_f2_owner_idx_mismatch` rises above zero. | Rejected and backed out. The current lockstep cursor still depends on direct request-owner loads; this confirms the next slice needs a real IFU owner queue/cursor handoff rather than a local guard. |
| Flow-through IFU owner queue wrapper | `benchmark_results/20260506_ifu_ownerq_flowthrough_smoke/summary.md` | Dhrystone/CoreMark abort under strict delivery; Dhrystone reports non-contiguous owner stream at cycle 188 (`expected=0x800020d0`, `got=0x80002010`). | Rejected and backed out. A queue wrapper is not neutral unless request PC, FTQ entry, and redirect/cursor handoff are latched as one object before flow-through; otherwise the PC and FTQ metadata can pair from different phases. |
| Flow-through IFU request work queue | `benchmark_results/20260506_ifu_req_workq_smoke/summary.md` | Dhrystone TIMEOUT after 620 retired instructions with `xs_f2_owner_idx_mismatch=3` and `xs_packet_stale_idx_mismatch=139`; CoreMark TIMEOUT after 71 retired instructions. FTQ occupancy rises (`ftq_occ_max=4` on Dhrystone), but the owner stream drifts. | Rejected and backed out. Pairing request PC and FTQ metadata is necessary but still not sufficient: the queue needs an explicit phase relationship with ICQ response acceptance and FTQ IFU-writeback cursor advancement before it can store owners. |

Root cause: line data and FTQ ownership are not the same object. The line fill
may be physically shared across multiple same-line predicted owners, but packet
delivery must remain per FTQ idx/epoch/alloc-tag. The rejected patches made
`fetch_unit.sv` infer correctness from queue-head or locally latched line
state, before the FTQ/IBuffer contract could distinguish data sharing from
owner delivery.

One safe queue boundary fix remains in RTL: `icache_resp_queue.sv` now accepts
an enqueue when full if the head also pops in the same cycle. This prevents a
one-cycle I-cache response from being dropped while preserving the current
transparent F2 consumption model.

The restored default recheck is clean:
- `./build_dsim.sh` passed.
- Strict DSim DSE smoke with `+FETCH_DELIVERY_CHECK +FETCH_DELIVERY_STRICT
  +PERF_PROFILE +PERF_COUNTERS +STAT_DUMP` passed:
  `benchmark_results/20260506_queue_boundary_restored_smoke_seq/summary.md`.
- Dhrystone 100: `mcycle=26913`, `minstret=49088`, timed
  `cycles=26394`, `instret=48436`, `checksum=24`, `flags=0`,
  `2.156369 DMIPS/MHz`.
- CoreMark 1: `mcycle=218364`, `minstret=332154`, timed
  `cycles=207870`, `instret=318379`, `checksum=59156`, `flags=0`,
  `4.810699 CoreMark/MHz`.
- XSim fallback is available: `./build_xsim.sh` passed and
  `./run_xsim.sh tests/hex/rv64ui_minimal.hex 50000 +PERF_PROFILE` passed.

Stage 1 should continue from this restored boundary. The rejected F2 line-latch
logic must not be carried forward as dormant RTL.

## Stage 1 Implementation Plan

The next implementation has to close the measured frontend gap without adding
benchmark-specific behavior.

1. **Lock the clean baseline.** Rebuild DSim, rerun `rv64ui_minimal`,
   Dhrystone 100/300, CoreMark 1/10, and the 43-row broad suite. This gives the
   baseline `results.json` required by the counter-movement gate.
2. **Harden the existing delivery checker before the next RTL slice.** Done for
   the current smoke set. `+FETCH_DELIVERY_STRICT` now keeps the next expected
   PC for the same FTQ owner even after an `owner_complete` packet, so legal
   multi-packet owner tails no longer restart at the FTQ start offset. The
   remaining signoff work is to run strict mode with golden-PC coverage across
   the broader suite.
3. **Refactor FTQ ownership explicitly.** The demand-request and IFU-writeback
   pointers are now split, the temporary registered request-pop bridge is gone,
   and the monolithic IFU request accept is expressed as
   `ifu_req_valid/ready/fire` with ready gated by response-queue/IBuffer
   capacity. The remaining work is to define redirect/epoch lifetime for
   outstanding responses. F2 must never infer ownership from the current queue
   head alone.
4. **Define same-line request ownership.** Current frontend state can allocate
   more than one FTQ owner for PCs in the same I-cache line. The first
   instrumentation slice is now in RTL: `fetch_packet_t` carries
   `ifu_line_addr` / `ifu_line_reused`, and `+FETCH_OWNER_CHECK` classifies
   same-line owner transitions, line reuse, duplicate PCs, skipped PCs, and
   IFU-line metadata mismatches. Remaining work is to use that contract to
   split line-data lifetime from owner-cursor lifetime before enabling a line
   latch.
5. **Finish the owner-aware IBuffer contract.** The IBuffer now stores complete
   fetch packets with FTQ idx, epoch, alloc tag, block PC, and owner-complete
   metadata and exposes owner-match/stale/complete classification. Remaining
   work is decode-accept/golden delivery tracking and making duplicate delivery
   structurally impossible under runahead.
6. **Only then make F1 proactive.** F1 may run ahead from BPU prediction only
   when FTQ allocation and IBuffer capacity can accept the owner. Runahead is
   bounded by FTQ free entries and IBuffer occupancy.
7. **Score with the calibrated harness.** A Stage 1 row must pass endpoint
   identity, golden PC where available, owner counter invariants, broad-suite
   coverage, and the declared counter movement versus baseline.

## Next frontend optimization direction (capacity-owned runahead first)

The next behavior-changing implementation should not be another local
PC-steering patch in `fetch_unit.sv`. It should use the XiangShan-style
ownership split that is now explicit: FTQ owns predicted blocks, IFU owns line
access/validation, and IBuffer owns decode-facing packet delivery. The retired
same-line handoff, same-FTQ tail carry, sequential-lookahead, and weak-bias
paths are cleanup evidence only; they are not a basis for the next runahead
slice.

### 1. Instrument same-line owner allocation

Done in working-tree RTL. `+FETCH_OWNER_CHECK` and `+FETCH_OWNER_STRICT` now
cover these cases:

- same I-cache line, different FTQ owner;
- same I-cache line, same FTQ owner, multiple packets;
- line response shared by more than one owner;
- IFU line metadata mismatch, including legal handling for a 32-bit instruction
  straddling byte offset 62;
- packet PC emitted twice or skipped under any owner.

Smoke artifact:
`benchmark_results/20260506_owner_line_metadata_fixed_smoke_seq/summary.md`.
Both Dhrystone 100 and CoreMark 1 passed with
`+FETCH_DELIVERY_CHECK +FETCH_DELIVERY_STRICT +FETCH_OWNER_CHECK
+FETCH_OWNER_STRICT`.

Current observations from that smoke:
- Dhrystone 100: same-line new-owner allocs `13646`, same-line diff-owner
  packets `13945`, duplicate/replayed PCs `0`, skipped PCs `0`, line metadata
  mismatches `0`.
- CoreMark 1: same-line new-owner allocs `72542`, same-line diff-owner packets
  `74268`, duplicate/replayed PCs `0`, skipped PCs `0`, line metadata
  mismatches `0`.

After making the ICQ response-line address explicit, the same strict smoke
passed again:
`benchmark_results/20260506_response_line_assoc_smoke_seq/summary.md`.
`./build_xsim.sh` also passed, and
`./run_xsim.sh tests/hex/rv64ui_minimal.hex 50000 +FETCH_DELIVERY_CHECK
+FETCH_DELIVERY_STRICT +FETCH_OWNER_CHECK +FETCH_OWNER_STRICT` passed.

### 2. Define owner granularity

Done for packet metadata. Keep the architectural owner as the FTQ fetch block,
not the I-cache line. If two predicted blocks land in the same 64-byte line,
the IFU may reuse the line data, but each extracted packet still carries the
correct FTQ idx/epoch/tag, block PC, slot PCs, predicted-control metadata, and
owner-complete bit. `ifu_line_addr` names the line data used by F2; this can
differ from `fetch_pc[0]` only for the legal line-straddle case.

### 3. Refactor response association before bounded runahead

Done for the conservative F2 line-state boundary. `icache_resp_queue.sv` now exposes the response-line address
explicitly, and `fetch_unit.sv` uses that line address to fill
`fetch_packet_t.ifu_line_addr`. This removes another implicit dependency on
queue-head PC slicing when validating packet line identity.

The F2 line-state record is now active and checked by SVA. It records
the consumed response line separately from the FTQ owner cursor:
- line data lifetime: cache-line address, response data, hit state, redirect
  epoch validity;
- owner cursor lifetime: FTQ idx/epoch/tag, block PC, next byte offset, and
  owner-complete state.

The first behavior-changing attempt only accepted same-line queue heads. That
compiled, but timed out because a redirect left an outstanding stale response at
the ICQ head:
`benchmark_results/20260506_f2_line_state_consumption_smoke_seq/summary.md`.
The accepted implementation drains invalid/stale-epoch responses while keeping
them invisible to F2 data. Matching-line responses can refill the line state;
same-line owners can consume the line-state record when no matching queue
response is available.

Smoke artifact:
`benchmark_results/20260506_f2_line_state_active_shadowfix_smoke_seq/summary.md`.
Both Dhrystone 100 and CoreMark 1 passed with the strict delivery and owner
checks:
- Dhrystone 100: timed cycles `26396`, `2.156205 DMIPS/MHz`,
  line-share diff-owner `28`, metadata mismatch `0`, duplicate/replayed PCs
  `0`, skipped PCs `0`.
- CoreMark 1: timed cycles `207855`, `4.811046 CoreMark/MHz`,
  line-share diff-owner `42`, metadata mismatch `0`, duplicate/replayed PCs
  `0`, skipped PCs `0`.
`./build_xsim.sh` also passed after this slice, and
`./run_xsim.sh tests/hex/rv64ui_minimal.hex 50000 +FETCH_DELIVERY_CHECK
+FETCH_DELIVERY_STRICT +FETCH_OWNER_CHECK +FETCH_OWNER_STRICT` passed with
line-share diff-owner `1`, metadata mismatch `0`, duplicate/replayed PCs `0`,
and skipped PCs `0`.
The `SHADOW_F2_PC_FROM_QUEUE` harness probe now samples accepted responses
(`ic_resp_valid`) rather than raw queue-head visibility, so stale or future
ICQ entries do not pollute the next runahead evidence.

Same-line owners may share the line-data record, but they must not share the
owner cursor.

### 4. Then enable bounded BPU-owned runahead

F1 may advance from BPU prediction only when the FTQ can allocate the owner and
the IBuffer/response boundary has capacity. The first runahead limit should be
small and occupancy-derived. No same-line handoff, same-FTQ tail carry, static
direction shortcut, or sequential-lookahead logic should be used to recover
correctness.

Evidence after the active line-state slice confirms the old same-line
lookahead hook must remain disabled:
`benchmark_results/20260506_xs_same_line_lookahead_after_line_state_seq/summary.md`.
It improved Dhrystone 100, but CoreMark 1 failed with `TOHOST=3`,
`flags=1`, checksum `12758`, and repeated owner invariant failures. The
failure did not show packet duplicate/skipped PCs; it showed that F2's PC/owner
source still is not the IFU writeback view. The stateful IFU work cursor now
exists as a neutral mirror; the next slice is decoupling that cursor from raw
F2 flow. A combinational replacement is not enough because the physical line
response, the FTQ IFU-writeback owner, and the current in-owner PC can legally
be at different phases.

2026-05-06 F2 work-source recheck:
- Tightening ICQ dequeue on `icq_deq_owner_match_c` built but starved both
  smoke rows with only 14 retired instructions:
  `benchmark_results/20260506_f2_work_alias_smoke_seq/summary.md`.
- Using the accepted ICQ request PC as the packet PC caused an immediate strict
  delivery failure: the line data was legal, but the request PC was not the
  younger FTQ owner's current packet PC:
  `benchmark_results/20260506_f2_work_alias_neutral_ready_smoke_seq/summary.md`.
- Substituting the FTQ IFU-writeback owner's start PC as a combinational F2
  work PC avoided the immediate duplicate, but then starved after one
  shared-line owner because no stateful cursor advanced to the next owner:
  `benchmark_results/20260506_f2_wb_owner_resync_smoke_seq/summary.md`.
- Default RTL was restored to an identity `f2_work_*` alias over the registered
  F2 cursor. Strict DSim smoke is clean again:
  `benchmark_results/20260506_f2_work_alias_identity_restore_smoke_seq/summary.md`.
  Dhrystone 100 remains `26396` timed cycles / `2.156205 DMIPS/MHz`; CoreMark 1
  remains `207855` timed cycles / `4.811046 CoreMark/MHz`.
- Invariant E was recalibrated to the current architecture: it now asserts that
  FTQ IFU-writeback pop requires F2 owner/writeback-owner equality, instead of
  falsely requiring every F2 emit to equal the writeback pointer. Recheck:
  `benchmark_results/20260506_f2_work_identity_sva_clean_smoke_seq/summary.md`.
  The DSim rows pass with no `[INVARIANT_*]` assertion errors. XSim fallback was
  rebuilt and `rv64ui_minimal` passed with strict delivery/owner checks.

Implication: the explicit IFU work item now owns the data/extraction-facing
aliases, active line identity, and a single named owner-completion boundary for
packet/FTQ IFU-pop decisions. Raw F2 PC/FTQ mirror registers have been retired.
On a clean owner handoff, the FTQ
IFU-writeback view supplies the next owner identity, while the IFU cursor
supplies the next in-owner PC. The next implementation must continue this split
without substituting request-time FTQ start PCs for cursor PCs: the ICQ entry
supplies data, the FTQ IFU-writeback owner supplies identity, and the IFU work
cursor supplies the current in-owner PC, line identity, and completion state. It
should still be bounded by FTQ and IBuffer capacity and must not reintroduce
same-line/same-tail/sequential lookahead shortcuts.

### Required counter movement

| Counter | Direction required |
|---|---|
| `packet_empty_noemit_dup` | large decrease without endpoint drift |
| `xs_dup_last_emit` | large decrease without local duplicate filtering |
| `xs_ftq_occ_max` | increase above the current shallow occupancy |
| `packet_buf_occ_max` | increase above the current near-lockstep behavior |
| `frontend_hold` / backend stalls | no new dominant bottleneck |
| timed Dhrystone/CoreMark cycles | decrease versus the restored safe boundary |

The harness is a guardrail, not the optimization target. Golden PC scoreboard
catches architectural divergence (the unsafe-fix line-skipping pattern from the
prior session); SVA invariants (fetch_unit.sv) catch pipeline timing
violations; counter_invariants enforce zero-asserts. A row is only meaningful
when these checks prove that the BPU-owned stream, not a testbench-specific
path, moved the frontend-supply counters.

## Frontend module split plan

This refactor is behavior-neutral structural cleanup first. Do not claim a
performance improvement from these slices. The goal is to make the RTL map to a
recognizable XiangShan-like frontend organization before the next performance
inspection.

Target integration:

| Target file | XiangShan analogue | Current ownership in `fetch_unit.sv` | First interface shape |
|---|---|---|---|
| `fetch_top.sv` | `FrontendInlinedImp` | Current `fetch_unit.sv` top-level ports and pure wiring around FTQ/BPU/IFU/ICache/IBuffer. | Preserve the existing `fetch_unit` external port contract initially; later `fetch_unit.sv` can become a compatibility wrapper around `fetch_top`. |
| `bpu/bpu.sv` | `Bpu` | BTB/TAGE/RAS instances and request-time FTQ prediction assembly around lines 857-1100, plus RAS/GHR speculative update control around lines 2334-2383. The predictor leaves live in `src/rtl/core/bpu/`, not `src/rtl/core/fetch/`. | `lookup_pc`, `aux_lookup_pc`, commit/update/restore inputs, `bpu_pred_t`/`bpu_aux_pred_t`, RAS snapshot, `ghr_out`, speculative update request. |
| `ftq.sv` | `Ftq` | Already separate. Current owner pointers are `alloc_to_ifu`, `ifu_to_wb`, and `ifu_to_commit`. | Keep `ftq_entry_t` and current valid/ready/pop interface; later rename ports toward `BpuToFtq`, `FtqToIfu`, `IfuToFtq` bundles. |
| `ifu.sv` | `Ifu` | F1 PC generation lines 125-204; request ready/alloc policy lines 317-371; IFU work cursor and duplicate/replay guard lines 1102-1470; FTQ completion/commit-pop policy lines 2260-2332. | `FtqToIfu` owner view, `IfuToFtq` request/delivery/writeback pops, redirect/remainder inputs, IBuffer/ICQ backpressure, `ifu_work_item_t` output to line fetch and packet build. |
| `ifu_line_fetch.sv` | `Ifu` + `ICache` adapter | ICache request/response association, NLPB, ICQ, and same-line line-state reuse around lines 207-759. | `IfuToICache`: request valid/addr. `ICacheToIfu`: response valid/hit/data plus request PC and FTQ identity. Keep `icache.sv` separate. |
| `pred_checker.sv` | `PredChecker` | FTQ predicted-control matching, static CFI override, branch target choice, subgroup split choice, final count, owner completion, redirect/RAS/GHR requests around lines 1763-2383. | Inputs: extracted slots, predecode result, FTQ owner entry, BPU prediction metadata. Outputs: redirect request/target, final count, seq-next PC, owner complete, RAS op, TAGE spec update. |
| `instr_boundary.sv` | `InstrBoundary` | Raw parcel extraction, RVC length detection, straddle detect, and remainder state around lines 1472-1626 and 2385-2419. | Inputs: work PC, 512-bit line, valid, redirect/stall. Outputs: raw slot PCs/instructions/RVC flags, extract count, straddle/remainder consume, seq helper signals. |
| `predecode.sv` | `PreDecode` / `F3PreDecode` | Earliest and second control-flow decode around lines 1648-1761; helper functions `is_link_reg`, `imm_b64`, `imm_j64`. | Inputs: raw/decompressed slots, slot PCs/valid/RVC, extract count, RAS top. Outputs: first/second CFI metadata and owner conditional prediction flag. |
| `rvc_expander.sv` | `RvcExpander` | Generate block of `rvc_decompress` instances around lines 1628-1646. | Inputs: raw halfword array. Outputs: decompressed word/is_rvc/illegal arrays. |
| `instr_compact.sv` | `InstrCompact` | Packet construction around lines 2421-2519. | Inputs: slots, final count, prediction decision, FTQ/IFU metadata, RAS/GHR snapshots. Output: `FetchToIBuffer` packet valid plus `fetch_packet_t`. |
| `ibuffer.sv` | `IBuffer` | Existing `fetch_packet_buffer.sv` instance and decode-facing output around lines 832-855 and 2521-2562. | Rename or wrap `fetch_packet_buffer.sv`; keep `fetch_packet_t` valid/ready/deq owner-match interface. |

Interface naming should converge toward XiangShan's direction names without a
large package rewrite in the first slices:

| Direction | Initial SystemVerilog carrier |
|---|---|
| BPU to FTQ | Existing `ftq_entry_t` prediction fields; later split into a packed `bpu_to_ftq_t`. |
| FTQ to BPU | Existing commit/update/restore signals plus RAS/GHR repair; later packed `ftq_to_bpu_t` if needed. |
| FTQ to IFU | Current `ftq_*owner_*`, `ftq_current_epoch`, occupancy counts. |
| IFU to FTQ | Current `ftq_ifu_req_pop_valid`, `ftq_delivery_push_valid`, `ftq_ifu_pop_valid`, `ftq_commit_pop_valid`. |
| IFU to ICache | Current `ic_req_valid/ic_req_addr`. |
| ICache to IFU | Current `ic_resp_valid/ic_resp_hit/ic_resp_data` plus ICQ request PC and FTQ identity. |
| Fetch to IBuffer | `packet_buf_enq`, `packet_buf_in`, `packet_buf_enq_ready`. |
| IBuffer to decode | Current `fetch_count/fetch_insn/fetch_pc/fetch_is_rvc/fetch_bp_*` outputs. |

Migration order:

1. Extract leaf combinational helpers with no architectural behavior change:
   `predecode.sv`, `instr_boundary.sv`, `rvc_expander.sv`,
   `instr_compact.sv`, then `pred_checker.sv`.
2. After each leaf extraction, update DSim/XSim file lists, rebuild, run strict
   DSE smoke on Dhrystone 100 and CoreMark 1 with:

   ```bash
   python3 tools/run_benchmarks.py --runner dsim --run-class dse \
       --manifest tests/benchmarks/stage1_signoff.json \
       --bench dhrystone_100_checkedin \
       --bench coremark_iter1_generalization \
       --plusarg FETCH_DELIVERY_CHECK --plusarg FETCH_DELIVERY_STRICT \
       --plusarg FETCH_OWNER_CHECK --plusarg FETCH_OWNER_STRICT \
       --plusarg PERF_PROFILE --plusarg PERF_COUNTERS --plusarg STAT_DUMP
   ```

3. Commit each validated extraction before starting the next one.
4. Only after the leaf modules are clean, move stateful ownership pieces:
   `ifu_line_fetch.sv`, `ifu.sv`, `bpu.sv`, and final `fetch_top.sv`.
5. Keep debug probes and SVA with the owner module they observe as state moves.
   Until then, leave them in `fetch_unit.sv` so hierarchical testbench probes
   continue to work.

Validated split slices:

| Slice | RTL movement | Validation | Verdict |
|---|---|---|---|
| `predecode.sv` extraction | Moved first/second CFI decode and helper immediate/link-register functions out of `fetch_unit.sv`; `fetch_unit.sv` now instantiates the leaf module. | `benchmark_results/20260506_predecode_extraction_smoke`: Dhrystone 100 PASS (`mcycle=27598`, `minstret=49088`), CoreMark 1 PASS (`mcycle=219901`, `minstret=332154`) with `+FETCH_DELIVERY_CHECK +FETCH_DELIVERY_STRICT +FETCH_OWNER_CHECK +FETCH_OWNER_STRICT +PERF_PROFILE +PERF_COUNTERS +STAT_DUMP`. Owner/stale counters remained zero. | Accepted as behavior-neutral structural cleanup; no performance claim. |
| `instr_boundary.sv` extraction | Moved raw slot extraction, RVC length detection, straddle detection, and cross-line remainder state out of `fetch_unit.sv`; old signal names remain visible as module outputs for existing probes. | `benchmark_results/20260506_instr_boundary_extraction_smoke`: Dhrystone 100 PASS (`mcycle=27598`, `minstret=49088`), CoreMark 1 PASS (`mcycle=219901`, `minstret=332154`) with the same strict owner/delivery/perf plusargs. Owner/stale counters remained zero. | Accepted as behavior-neutral structural cleanup; no performance claim. |
| `rvc_expander.sv` extraction | Moved the multi-slot `rvc_decompress` generate wrapper out of `fetch_unit.sv`; `rvc_decompress.sv` remains the decompressor leaf. | `benchmark_results/20260506_rvc_expander_extraction_smoke`: Dhrystone 100 PASS (`mcycle=27598`, `minstret=49088`), CoreMark 1 PASS (`mcycle=219901`, `minstret=332154`) with the same strict owner/delivery/perf plusargs. | Accepted as behavior-neutral structural cleanup; no performance claim. |
| BPU folder split | Moved `btb.sv`, `tage_sc_l.sv`, and `ras.sv` from `src/rtl/core/fetch/` to `src/rtl/core/bpu/`; fetch still instantiates them through the existing module names. | `benchmark_results/20260506_bpu_folder_split_smoke`: Dhrystone 100 PASS (`mcycle=27598`, `minstret=49088`), CoreMark 1 PASS (`mcycle=219901`, `minstret=332154`) with the same strict owner/delivery/perf plusargs. Owner/stale counters remained zero. | Accepted as physical RTL ownership cleanup; no behavior or performance claim. |

### Long-run drift guard

Use `--goal stage1` for any Stage 1 long run. The runner now rejects drifted
commands before simulation if they use `--run-class dse`, the coverage-only
manifest, partial `--bench` selection, missing strict owner/delivery checks, or
missing perf-counter plusargs. `--allow-partial-goal` is dry-run only, so no
partial benchmark subset can produce a goal artifact. This also keeps DSE rows
from being mislabeled as endpoint failures when the benchmark checksum/control
endpoint is clean but the row is not scoreable.

The Stage 1 manifest is self-identifying through `goal_contract.name=stage1`
and `goal_contract.version=stage1-2026-05-06-v2`; goal runs record manifest
path and SHA-256 in `run_manifest.json`. Contract v2 excludes the stale
CoreMark10 golden-PC fixture that tripped at sequence `2553567`; CoreMark10 is
still endpoint/checksum/strict-owner checked, but that golden oracle must be
regenerated before it is re-enabled. Real non-dry-run goal runs reject a dirty
`tests/benchmarks/stage1_signoff.json` or `tools/run_benchmarks.py`, so the
benchmark contract must be committed before producing scoreable evidence. Use
the audit helper to classify recent artifacts before citing any result:

```bash
python3 tools/audit_goal_runs.py --limit 12
```

### If the next slice is pursued

```bash
python3 tools/run_benchmarks.py --runner dsim --goal stage1 --run-class signoff \
    --manifest tests/benchmarks/stage1_signoff.json \
    --plusarg FETCH_DELIVERY_CHECK --plusarg FETCH_DELIVERY_STRICT \
    --plusarg FETCH_OWNER_CHECK --plusarg FETCH_OWNER_STRICT \
    --plusarg PERF_PROFILE --plusarg PERF_COUNTERS --plusarg STAT_DUMP \
    --mechanism-class ftq_owned_delivery \
    --mechanism-name same_line_owner_delivery_contract \
    --baseline-results <pre_change_results.json> \
    --targets-counter <counter_name> \
    --expect-counter-decrease <counter_name>:<predicted_delta> \
    --run-id <run_id>
```

## Harness in place (committed)

| Piece | Commit | Purpose |
|---|---|---|
| `tools/bottleneck_analysis.py` | 5fd8577 | Frontend-stage counter ranking with bypass-corrected view |
| `tools/bubble_attribution.py` | 6b3301c, c3e1305 | Commit-stage cycle classification + per-PC attribution |
| `tools/golden_pc_stream.py` | 8b30714 | Golden generation/verification |
| `tools/image_diff.py` | 8b30714 | Fresh-rebuild divergence triage |
| Golden PC scoreboard (tb_top.sv) | 8b30714 | `+EMIT_COMMIT_PC_HEX` / `+CHECK_GOLDEN_PCS` |
| Counter invariants (manifest schema) | 8b30714 | Manifest-level structural assertions |
| SVA invariants (fetch_unit.sv) | 6b3301c | Pipeline timing assertions |
| Shadow signals (tb_top.sv) | 6b3301c | Pre-RTL change divergence measurement |
| Data-driven discipline rules | 5fd8577 | Reject default_rtl signoff with uncommitted RTL |
| `icache_resp_queue.sv` | b97adb1, bcf9b5c, working tree 2026-05-06 | F1/F2 response elasticity, transparent F2 consumption, full-plus-pop enqueue |
| `fetch_packet_t.ifu_line_*` + `FETCH_OWNER_CHECK` | working tree 2026-05-06 | Explicit IFU line identity and same-line owner contract checking |
| ICQ response-line output | working tree 2026-05-06 | Response line address is explicit and feeds packet IFU line metadata |
| ICQ FTQ-entry carry | working tree 2026-05-06 | I-cache response queue carries request PC, FTQ idx/epoch/tag, and full FTQ entry snapshot so future cursor handoff has one coherent request object |
| IFU request work item | working tree 2026-05-06 | Request-owner cursor loads now consume one paired request PC + FTQ metadata object instead of scattering raw `ftq_enq_*` assignments across cursor policy branches |
| FTQ enqueue-ready boundary | working tree 2026-05-06 | `ftq_enq_ready` is wired into IFU request-ready and fetch stall; request allocation and IFU request-pop now share the FTQ valid/ready contract |
| FTQ IFU-to-writeback count | working tree 2026-05-06 | `ftq.sv` exposes requested-not-written-back owner occupancy as a separate count for future bounded runahead rules |
| IFU owner-policy SVA | working tree 2026-05-06 | Invariants F/G/H check request-pop ready/enqueue alignment, FTQ next-owner cursor loads, and matching redirect next-owner loads |
| F2 line-state record | working tree 2026-05-06 | Active line/epoch-qualified data reuse with stale-response epoch drain; FTQ owner cursor remains separate |
| F2 queue-PC shadow probe | working tree 2026-05-06 | Shadow runahead evidence now samples accepted ICQ responses, not raw queue-head visibility |
| IFU work cursor (`ifu_work_item_t`) | working tree 2026-05-06 | Stateful PC/FTQ/line work item; raw F2 PC/FTQ mirror registers retired; clean owner handoff uses FTQ next-owner identity plus cursor `f2_seq_next_pc`; redirect handoff can use the matching FTQ next-owner view; line gates use active `line_addr`, and extraction/owner/completion/debug probes use `f2_work_*` aliases |
| FTQ delivery-push split | working tree 2026-05-06 | First accepted packet pushes the IFU-writeback owner into the commit/decode-visible region separately from final IFU-owner completion; same-owner multi-packet continuation no longer appears as stale owner |
| IBuffer flow-through | working tree 2026-05-06 | Empty-buffer same-cycle decode delivery is owned by `fetch_packet_buffer`; the old separate `packet_buf_in` decode bypass no longer feeds `fetch_packet_out` |
| Packet flow-through naming | working tree 2026-05-06 | Stale `FETCH_PACKET_BYPASS2*` direct-bypass controls removed; frontend fast-path counters and trace labels now use flow-through naming |
| Local shortcut controls and logic | working tree 2026-05-06 | Opt-in same-line, same-tail, sequential-lookahead, weak-bias, and direct packet-policy/tail paths removed from `fetch_unit.sv`; stale harness summary columns were removed; remaining runahead work must be FTQ/IBuffer capacity-owned |
| `build_xsim.sh` frontend file list | working tree 2026-05-06 | XSim fallback includes `icache_resp_queue.sv` |
| ASIC-clean endpoint split | working tree 2026-05-05 | Removed fixed `tohost` ports from `rv64gc_core_top.sv` and magic `tohost` policy from D-cache |
| `tools/sim_platform.py` + `tests/sim_platform/stage1_broad.json` | working tree 2026-05-05 | Broad coverage preparation layer; keeps ABI/image handling in the harness |

The harness should stay a guardrail. The core should not gain benchmark-specific
side logic for pass/fail, `tohost`, CoreMark, Dhrystone, XiangShan AM, or BOOM
HTIF compatibility. Those belong in `tb_top.sv` and the simulator platform
runner.

## Stage 2 (out of scope for Stage 1)

Targets: 7.5 CM/MHz, 4.0 DMIPS/MHz. Mechanisms:
- BOOM-style loop predictor for genuine loop-boundary branches (e.g.,
  dhrystone strcpy at `0x8000200e`). NOT a loop buffer — BPU-side
  prediction structure that records trip counts.
- ICache prefetch by FTQ entry.
- Optional decoded-op cache (FTQ-attached, never authoritative for
  branch direction).
- Per-PC dcache prefetch for pointer-chase patterns.

## Coverage expansion

The current score rows are still Dhrystone/CoreMark, but the next frontend RTL
slice should also pass a broader anti-overfit smoke matrix. The XiangShan
benchmark survey and recommended port list are in
`doc/benchmark_coverage_expansion_2026-05-05.md`.

2026-05-06 broad-suite status:
- `tests/sim_platform/stage1_broad.json` ran 43 rows with DSim DSE and
  PERF_PROFILE enabled.
- Initial result was 42 PASS and one false timeout in
  `probe_string_retire_hotspot` at the old 150k cap.
- Single-row retry passed at `mcycle=169620`; the manifest cap is now 250k.
- A normal manifest-path cap check passed without a command-line cap override.
- Effective status after the cap fix is 43/43 PASS.

Do not defer this existing broad suite to Stage 2. Use it as Stage 1
anti-overfit coverage. Defer only new external benchmark ports until the
simulator platform has a common source/ELF ABI path.

Near-term priority:
- Port XiangShan `nexus-am/tests/frontendtest` first because it directly
  stresses BPU/BTB/RAS/IFU behavior.
- Port XiangShan `apps/microbench` second for broader branch, pointer, sort,
  compression, hash, graph, and recursion coverage.
- Keep XiangShan prebuilt `.bin` files as references only until they are rebuilt
  with rv64gc-v2 `tohost` and benchmark-result MMIO.
- Refactor the simulator/test platform toward a multi-ABI endpoint:
  rv64gc fixed-address `tohost` for current score rows, BOOM/Spike/HTIF-style
  ELF-symbol `tohost/fromhost` for riscv-tests and Chipyard-compatible workloads,
  and a Nexus-AM source-port shim for XiangShan apps. This belongs in the
  harness, not in the core frontend.

## What NOT to do (locked-in lessons)

- No loop buffer revival (architectural decision: loop-exit prediction
  belongs in BPU/FTQ, not frontend replay).
- No standalone UOC / decoded-op cache that's authoritative for branch
  direction (rejected by audit; trips golden PC).
- No same-line/same-FTQ-tail/sequential-lookahead local shortcuts — all
  rejected with documented evidence in archive.
- No backend widening (rename/commit > 4) — backend not constrained per
  counter data.
- No dcache hit latency reduction (2-cycle hit / 3-cycle load-to-use is
  already faster than BOOM; not the differentiator).

## Pointer to history

The detailed iteration history (rejected DSE rows, evidence tables for
the architectural decisions above, prior closure plan revisions) lives
in `doc/archive/stage1_frontend_refactor_history_2026-05-05.md`.

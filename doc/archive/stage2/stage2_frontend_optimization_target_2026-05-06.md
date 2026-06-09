# Stage 2 Frontend Optimization Target, 2026-05-06

## Purpose

Stage 2 should turn the frontend ownership refactor into measurable,
general performance. The target is not another local packet or PC shortcut.
The target is a structurally decoupled, BPU-owned frontend that can run ahead
safely while preserving FTQ identity through IFU, IBuffer, decode, and
commit/training.

## Architecture Guardrails

The current optimization line must stay on the Reference Core B/Reference Core A-style ownership
path:

`BPU prediction -> FTQ owner -> IFU work item -> owner-aware IBuffer -> decode`.

Allowed mechanisms:

- BPU predictor quality or timing repairs that operate through FTQ owner
  metadata, such as the accepted loop-exit speculative-count sideband.
- FTQ, IFU, and IBuffer decoupling that preserves one owner identity for every
  delivered fetch packet.
- Control-aware packet scheduling or downstream drain changes that improve
  useful delivered work without changing architectural fetch ownership.
- Backend recovery or useful-work reduction only when checkpoint, rename,
  free-list, and ROB ordering contracts are explicit and endpoint-clean.

Forbidden mechanisms for this path:

- Reviving a legacy loop buffer or any loop-body replay structure that owns
  fetch delivery outside the FTQ owner contract.
- Fixed benchmark-PC steering, benchmark-window special cases, or decoded-body
  replay that bypasses normal BPU/FTQ/IFU ownership.
- Local same-line, same-tail, or fall-through shortcuts that relax owner
  identity without a full branch-owner sequencing contract.
- Treating marginal threshold or scalar knob movement as architectural
  progress unless the underlying predictor mechanism is general and broader
  benchmark evidence stays clean.

Threshold calibration is acceptable only as tuning of a general predictor
mechanism. It is not by itself the next architectural direction.

Aggressive multi-stage signoff targets:

| Metric | Target |
|---|---:|
| CoreMark/MHz | 7.5 |
| DMIPS/MHz | 4.0 |

These targets are not a frontend-only promise. The frontend slice must first
close the measured Reference Core A (large config) gap without endpoint drift. If frontend-only work
does not reach the Gate C ceiling below, open a second-domain DSE from
counters, not intuition.

## Current Scoreboard

Latest scoreable successor point:

- Accepted RTL delta: owner-complete successor allocation, IFU successor request
  selection, IBuffer fire-qualified decode valid, and rename total-block
  backpressure, plus predicted-control-window same-owner advance with F2 packet
  fire aligned to IFU stall, plus same-owner advance when the already allocated
  next FTQ owner is a backward target behind the current work PC, plus
  weak-TAGE gated local arbitration and a chooser-gated loop-exit
  speculative-count bypass. The latest accepted loop-predictor tuning enables
  that bypass one chooser step earlier, at `loop_bypass_conf >= 2`.
- Rejected and removed: benchmark-window trace probes and previous unguarded
  successor variants.

Current scoreable rows:

| Workload | Source | mcycle | Metric | Status |
|---|---|---:|---:|---|
| Dhrystone 100 | `benchmark_results/signoff_signoff_20260508_loop_bypass_threshold2_goal` | 18,577 | 3.133924 DMIPS/MHz | PASS |
| CoreMark 1 | `benchmark_results/signoff_signoff_20260508_loop_bypass_threshold2_goal` | 163,013 | 6.483697 CoreMark/MHz | PASS |
| CoreMark 10 | `benchmark_results/signoff_signoff_20260508_loop_bypass_threshold2_goal` | 1,500,110 | 6.705406 CoreMark/MHz | PASS |
| Branch hotspot probe | `benchmark_results/signoff_signoff_20260508_loop_bypass_threshold2_goal` | 141,326 | 1.108734 IPC | PASS |
| Dhrystone 300 | `benchmark_results/signoff_signoff_20260508_loop_bypass_threshold2_goal` | 53,890 | 3.193357 DMIPS/MHz | PASS |

Current gap to the Stage 2 stretch targets:

| Metric | Current row | Target | Required score uplift | Equivalent cycle reduction |
|---|---:|---:|---:|---:|
| CoreMark/MHz | 6.705406 | 7.5 | +11.9% | 10.6% |
| DMIPS/MHz | 3.193357 | 4.0 | +25.3% | 20.2% |

Current calibrated Reference Core A (large config) comparison on shared smoke rows:

| Workload | Reference Core A (large config) calibrated | rv64gc-v2 current | Current gap |
|---|---:|---:|---:|
| Dhrystone 100 | 23,814 cycles | 18,577 cycles | rv64gc-v2 22.0% faster |
| CoreMark 1 | 192,249 cycles | 163,013 cycles | rv64gc-v2 15.2% faster |

Interpretation:

- The successor path is now a real accepted Stage 2 frontend improvement, not
  just a smaller-row hint. It improves Dhrystone 100, CoreMark 1, CoreMark 10,
  and the branch hotspot probe with strict owner/delivery checks enabled.
- The predicted-control-window extension is the next accepted frontend step:
  CoreMark 10 improves `1,642,655 -> 1,570,351` cycles and
  `6.120764 -> 6.403369` CoreMark/MHz, while Dhrystone 100 improves
  `19,611 -> 18,913` cycles and `2.965569 -> 3.076996` DMIPS/MHz.
- The backward-next-owner safety extension is now the latest accepted frontend
  step: CoreMark 10 improves `1,570,351 -> 1,528,608` cycles and
  `6.403369 -> 6.579328` CoreMark/MHz. CoreMark 1 improves
  `169,049 -> 164,550` cycles. Dhrystone 100 is unchanged, while the longer
  Dhrystone 300 anchor improves to `54,926` cycles and
  `3.132659` DMIPS/MHz.
- The new row beats the calibrated Reference Core A (large config) smoke baseline on the shared
  Dhrystone 100 and CoreMark 1 timing windows.
- The weak-TAGE gated local alternation filter is the latest accepted BPU
  arbitration step. It is intentionally narrow: local alternation can override
  only when TAGE is weak and the learned per-branch bias is not fully opposed.
  It improves CoreMark 1 and CoreMark 10 while keeping Dhrystone and the branch
  hotspot clean.
- The loop-exit speculative-count bypass chooser is the latest accepted loop
  prediction timing step. It uses the FTQ owner's predicted conditional as a
  same-cycle sideband into the loop predictor, but enables the bypass only for
  loop entries that repeatedly miss loop exits. This preserves the CoreMark
  loops that the baseline already handled well while fixing stale speculative
  counts on Dhrystone and the residual CoreMark matrix loop.
- The latest threshold-2 chooser activation keeps the same mechanism but lets
  the sideband engage one confidence step earlier. The full 16-row signoff is
  strict-clean and raises CoreMark 10 from `6.594618` to `6.705406` CM/MHz
  without regressing Dhrystone, Dhrystone 300, or the branch hotspot.
- The aggressive 7.5 CM/MHz and 4.0 DMIPS/MHz targets still require another
  structural step. The remaining gap is smaller, but not closed.

Backend follow-up DSE, 2026-05-08:

- Counter analysis showed many integer-IQ enqueue lanes were already ready but
  invisible to issue until the next cycle. The mechanism under test is an
  opt-in idle-port ready-enqueue bypass: resident issue queue entries keep the
  baseline oldest-ready priority, while a ready enqueue may issue only through
  an otherwise unused integer issue port and then skips allocation.
- This is not a loop-buffer or benchmark-shaped frontend shortcut. It is a
  backend wakeup/issue timing repair driven by the `xs_bottleneck_iq*_enq_*`
  and ALU dependency counters.
- Raw same-cycle bypass is too broad. It looked acceptable on the initial
  four-row smoke, but the broader probe showed large regressions:
  `coremark_iter10_checkedin 1,500,110 -> 1,539,634`,
  `hotspot_string_retire 107,379 -> 209,336`, and
  `memory_array_c 94 -> 116`.
- The cleaned RTL keeps only the raw bypass primitive plus an ALU-only FU-class
  filter. The rejected drain/head/pressure gating probes were removed from the
  harness and RTL after evidence review.

ALU-only full DSE candidate:

| Workload | Baseline mcycle | ALU-only mcycle | Cycle delta | Verdict |
|---|---:|---:|---:|---|
| Dhrystone 100 | 18,577 | 18,569 | -8, -0.04% | Small positive. |
| Dhrystone 300 | 53,890 | 53,885 | -5, -0.01% | Small positive. |
| CoreMark 1 | 163,013 | 160,354 | -2,659, -1.63% | Strong positive. |
| CoreMark 10 | 1,500,110 | 1,486,459 | -13,651, -0.91% | Strong positive on the heavier row. |
| Frontend mixed branch dense | 7,220 | 6,671 | -549, -7.60% | Positive, though less aggressive than raw bypass. |
| Hotspot state CRC branch | 141,326 | 135,779 | -5,547, -3.93% | Strong positive. |
| Hotspot string retire | 107,379 | 107,378 | -1, neutral | Regression from raw bypass is fixed. |
| Memory array | 94 | 92 | -2, -2.13% | Regression from raw bypass is fixed. |
| Hotspot matrix store | 84,437 | 84,443 | +6, +0.01% | Remaining blocker. |

Key artifacts:

- Baseline full profile:
  `benchmark_results/dse_bottleneck_profile_full_20260508`.
- ALU-only full DSE:
  `benchmark_results/dse_iq_ready_enq_bypass_alu_only_full_20260508`.
- Clean-tree ALU-only smoke after removing rejected knobs:
  `benchmark_results/dse_iq_ready_enq_bypass_alu_only_clean_smoke_20260508`.
- Rejected raw-bypass regression probe:
  `benchmark_results/dse_iq_ready_enq_bypass_raw_regression_probe_20260508`.
- Rejected non-ALU pressure probe:
  `benchmark_results/dse_iq_ready_enq_bypass_nonalu_pressure_full_20260508`.

Verdict:

- 2026-05-12 update: ALU-only enqueue issue bypass is promoted as the default
  IQ0/IQ1 policy after the Stage 3 RTL guard and RV64GC compliance audit. The
  old `+IQ_READY_ENQ_BYPASS_ALU_ONLY` signoff plusarg is removed from the
  harness because the behavior is no longer a runtime DSE knob.
- The earlier `hotspot_matrix_store` concern was not a reason to keep the
  mechanism default-off. The row exposed a real L2/LSU contract bug: DCache
  could retry or wait on a miss that L2 had not accepted for the D-cache
  source when another source already owned the same line.
- The accepted fix keeps the ALU-only architectural selector, adds a DCache to
  LSU miss-retry contract for unaccepted port-1 misses, and makes L2 same-line
  MSHR duplicate detection source-aware for read fills.
- Promoted artifact:
  `benchmark_results/stage3_l2_lsu_contract_guard_refined_20260512` passes the
  16-row guard, with `hotspot_matrix_store` at `84,357` cycles and CM10 at
  `1,454,994` timed cycles, `6.872881` CM/MHz.

Follow-up implementation, 2026-05-08:

- Added FU-class attribution counters for blocked ready-enqueue bypass
  candidates: conditional BRU, backward predicted-taken conditional BRU, JAL,
  JALR, and serial MUL/DIV/CSR classes.
- Tried an `ALU + backward conditional BRU` selector in
  `benchmark_results/dse_iq_ready_enq_bypass_alu_backedge_bru_smoke_20260508`.
  It is endpoint-clean and improves CoreMark 10 to `1,453,244` cycles, but it
  regresses `memory_array_c 92 -> 119` versus ALU-only, regresses
  `hotspot_string_retire 107,378 -> 109,142`, and leaves
  `hotspot_matrix_store` at `84,443`.
- Counter verdict: the matrix row has no blocked backward conditional BRU to
  recover. Its remaining blocked IQ0 candidates are conditional non-backedge,
  JAL, and JALR. The backedge-BRU selector improves CoreMark by changing branch
  timing, but that same timing shift increases head-block and mispredict
  pressure on broader rows. The selector was removed from RTL and should not be
  revived in this form.
- Tried `IQ_READY_ENQ_BYPASS_ALU_ONLY + BACKEND_ADMISSION_THROTTLE` in
  `benchmark_results/dse_iq_ready_enq_bypass_alu_only_backend_throttle_smoke_20260508`.
  The pair is endpoint-clean but effectively matches ALU-only: CoreMark 10
  `1,486,431`, CoreMark 1 `160,334`, and `hotspot_matrix_store` still
  `84,443`. Do not tune the admission throttle around this 6-cycle matrix
  regression.

Follow-up implementation, 2026-05-09:

- Commit `0814869` adds enqueue-time speculative load wakeup accounting in the
  issue queues. The mechanism writes same-cycle speculative load wakeups into
  newly allocated IQ entries for next-cycle issue, and adds parsed
  `xs_bottleneck_iq*_enq_spec_wakeup` / `*_cancelled` counters. It does not feed
  same-cycle enqueue issue bypass.
- `benchmark_results/dse_dse_enq_spec_load_wakeup_full_20260509` passes all 16
  Stage 1 rows with strict owner/delivery checks and is cycle-identical to the
  locked threshold-2 loop-exit baseline. CoreMark 10 reports about `163,239`
  enqueue speculative wakeups and zero cancels, proving the counter path is
  active but cycle-neutral in this form.
- Pressure-aware ALU enqueue-bypass routing was tried after that. The best
  store-head guard candidate preserved most of the Dhrystone/CoreMark gain
  (`Dhrystone 100 18,577 -> 18,569`, CoreMark 1 `163,013 -> 160,016`) but
  still regressed `hotspot_matrix_store 84,437 -> 84,438`. DSim hit a license
  lease conflict on the last long-run row, and an XSim rerun confirmed the
  one-cycle matrix regression.
- Verdict: keep commit `0814869` as a correctness/accounting repair. Reject and
  revert the pressure-aware ALU bypass candidates for now; they are promising
  but not signoff-safe because the regression rule is zero unexplained benchmark
  regressions.

ALU dependency lifecycle profiling, 2026-05-09:

- Added simulation-only producer lifecycle counters for ALU dependency wait.
  The old `xs_bottleneck_dep_wait_on_alu` counter is now split into:
  producer issued this cycle, producer not yet issued, producer issued but not
  written back, producer already done but source still stale, and unknown state.
  Additional counters split ALU-woken same-cycle select misses and ready ALU
  uops that lost selection.
- Artifacts:
  `benchmark_results/dse_dse_alu_dep_lifecycle_profile_smoke_20260509` and
  `benchmark_results/dse_dse_alu_dep_lifecycle_profile_coremark10_20260509`.
- Smoke rows remain cycle-identical and endpoint-clean:
  Dhrystone 100 `18,577`, CoreMark 1 `163,013`.
- CoreMark 10 remains `1,500,110` cycles and `6.705406` CM/MHz. The split is:

| Counter | Count | Share of ALU wait | Interpretation |
|---|---:|---:|---|
| `xs_bottleneck_dep_wait_on_alu` | 13,495,221 | 100.0% | Original broad ALU dependency wait. |
| `xs_bottleneck_dep_alu_wait_not_issued` | 12,310,501 | 91.2% | Dominant bucket; consumer waits because the ALU producer has not issued yet. |
| `xs_bottleneck_dep_alu_wait_issue_same_cycle` | 1,184,720 | 8.8% | Producer is issuing this cycle; registered CDB wakeup arrives next cycle. |
| `xs_bottleneck_dep_alu_wait_issued_not_wb` | 0 | 0.0% | No evidence of ALU producers stuck after issue before writeback. |
| `xs_bottleneck_dep_alu_wait_done_stale` | 0 | 0.0% | No stale source-ready bug after ALU writeback. |
| `xs_bottleneck_dep_alu_wait_state_unknown` | 0 | 0.0% | Producer lifecycle tracking is complete for this row. |
| `xs_bottleneck_dep_alu_wakeup_same_cycle_missed` | 69,681 | 0.5% of ALU wait | Same-cycle ALU wakeup select miss exists but is too small to explain the gap. |
| `xs_bottleneck_dep_alu_ready_not_selected` | 186,804 | 1.4% of ALU wait | Ready ALU issue arbitration is secondary. |

Producer-location profiling, 2026-05-09:

- Commit-under-test instrumentation adds simulation-only counters that split
  `xs_bottleneck_dep_alu_wait_not_issued` by where the not-yet-issued ALU
  producer is in the integer issue queues.
- Artifacts:
  `benchmark_results/dse_dse_alu_dep_producer_location_smoke_20260509` and
  `benchmark_results/dse_dse_alu_dep_producer_location_coremark10_20260509`.
- Timed performance is unchanged and endpoint-clean:
  Dhrystone 100 `18,577`, CoreMark 1 `163,013`, CoreMark 10 `1,500,110`
  / `6.705406` CM/MHz.

| Workload | Not-issued ALU waits | Producer absent | Producer blocked | Producer ready not selected | Producer selected |
|---|---:|---:|---:|---:|---:|
| Dhrystone 100 | 2,043 | 0 | 2,043 | 0 | 0 |
| CoreMark 1 | 1,248,238 | 10 | 1,240,649 | 7,579 | 0 |
| CoreMark 10 | 12,310,501 | 208 | 12,234,377 | 75,916 | 0 |

Verdict: do not pursue another wakeup-propagation, raw issue arbitration, or
enqueue-bypass-only fix as the main Stage 2 optimization. On CoreMark 10,
99.38% of not-issued ALU waits are for producers that are present in an integer
IQ but operand-blocked. Ready-not-selected producer pressure is only 0.62% of
the same bucket. The next data slice should classify the blocked producer's own
missing operand by producer class, such as ALU, load, multiply, branch, CSR, or
unknown. Only after that split should we choose between an ALU-chain timing
repair, a load-to-use path, or a useful-work reduction mechanism.

Blocked-producer source-class profiling, 2026-05-09:

- Added simulation-only counters that split the operand-blocked ALU producers by
  the producer's own missing source class. The exclusive split has single-source
  class buckets plus a multi-source bucket and conserves the
  `producer_blocked` total. The overlapping `any_*` counters show every missing
  source class seen on those blocked producers.
- Artifacts:
  `benchmark_results/dse_dse_alu_blocked_producer_srcclass_smoke_20260509` and
  `benchmark_results/dse_dse_alu_blocked_producer_srcclass_coremark10_20260509`.
- Timed performance remains unchanged and endpoint-clean:
  Dhrystone 100 `18,577`, CoreMark 1 `163,013`, CoreMark 10 `1,500,110`
  / `6.705406` CM/MHz.

Exclusive blocked-producer split:

| Workload | Producer blocked | Single ALU | Single load | Single mul | Multi source | Other |
|---|---:|---:|---:|---:|---:|---:|
| Dhrystone 100 | 2,043 | 1,235 | 800 | 0 | 8 | 0 |
| CoreMark 1 | 1,240,649 | 1,047,373 | 11,042 | 33,436 | 148,780 | 18 |
| CoreMark 10 | 12,234,377 | 10,393,558 | 103,189 | 312,329 | 1,425,283 | 18 |

Overlapping source-class view on CoreMark 10:

| Counter | Count | Share of blocked producers |
|---|---:|---:|
| `producer_blocked_any_alu` | 11,818,841 | 96.6% |
| `producer_blocked_any_mul` | 354,469 | 2.9% |
| `producer_blocked_any_load` | 108,253 | 0.9% |
| `producer_blocked_any_div` | 18 | ~0.0% |

Verdict: the current limiter is primarily true ALU dependency-chain depth, not
load-use timing, CDB writeback latency, or issue selection. The issue queue
already wakes consumers from the registered CDB so ALU-to-ALU dependent issue is
one cycle after producer issue; trying to make dependent ALU chains issue in the
same cycle would create an unrealistic IQ-to-ALU-to-IQ combinational path. The
next RTL candidate should therefore be a useful-work reduction or op-pattern
mechanism backed by another counter slice, such as identifying whether the ALU
chains are dominated by address-generation adds, word sign-extension/addw
chains, CRC/shift/xor chains, or removable moves/constants. Do not spend more
time on raw wakeup propagation or scalar issue threshold tuning for this bucket.

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
| Predicted-control-window same-owner advance plus F2 fire contract | Dhrystone 100 `19,611 -> 18,913`, CoreMark 1 `175,318 -> 169,049`, CoreMark 10 `1,642,655 -> 1,570,351`; branch hotspot improves `146,142 -> 141,408`. | Keep. This is an architectural cleanup: same-owner advance can cover packets up to the predicted control, but F2 `will_emit` must mean an accepted packet fire and must be blocked by IFU stall. |
| Backward-next-owner same-owner safety | CoreMark 1 `169,049 -> 164,550`, CoreMark 10 `1,570,351 -> 1,528,608`; Dhrystone 300 improves to `54,926`, while Dhrystone 100 and branch hotspot are unchanged. | Keep. A next FTQ owner whose start PC is behind the current work PC is a backward target, not a forward overlap hazard. Same-owner straight-line delivery can continue until the predicted-control packet without replaying the same F2 PC. |
| Weak-TAGE gated local alternation filter | Dhrystone 100 stays `18,913`, CoreMark 1 improves `164,550 -> 164,364`, CoreMark 10 improves `1,528,608 -> 1,526,048`, and branch hotspot improves `141,408 -> 141,326`. | Keep. This is a general BPU arbitration rule, not fixed-PC steering: local alternation may override only weak TAGE predictions and only when a per-branch bias table is not fully opposed. |
| Loop-exit speculative-count bypass chooser | Dhrystone 100 improves `18,913 -> 18,577`, CoreMark 1 improves `164,364 -> 163,727`, CoreMark 10 improves `1,526,048 -> 1,525,168`, Dhrystone 300 improves `54,926 -> 53,890`, and branch hotspot stays `141,326`. | Keep. The bypass uses the FTQ owner's predicted conditional to avoid stale loop speculative counts, but a per-loop chooser enables it only after saturated loop confidence plus repeated exit misses. This avoids the broad CoreMark regression seen with an always-on bypass. |
| Loop-exit bypass threshold-2 activation | Dhrystone 100 stays `18,577`, CoreMark 1 improves `163,727 -> 163,013`, CoreMark 10 improves `1,525,168 -> 1,500,110`, Dhrystone 300 stays `53,890`, and branch hotspot stays `141,326`. | Keep. The sideband is still chooser-gated, but engaging it at `loop_bypass_conf >= 2` fixes residual loop-exit miss timing earlier without becoming the rejected always-on policy. |

Current important counters from the accepted CoreMark 10 row, with the latest
profiling attribution from
`benchmark_results/signoff_signoff_20260508_loop_bypass_threshold2_goal`:

| Counter | Value | Meaning |
|---|---:|---|
| `xs_f2_owner_idx_mismatch` | 0 | F2 owner identity clean. |
| `xs_packet_stale_idx_mismatch` | 0 | Decode-facing packet owner clean. |
| `xs_packet_buffer_stale_owner` | 0 | No stale owner packet consumed. |
| `xs_ftq_occ_max` | 2 | Runahead exists but remains shallow. |
| `xs_packet_buf_occ_max` | 8 | IBuffer can hold packets on the heavy row. |
| `packet_buf_full_cycles` | 14,640 | The IBuffer is active enough to backpressure F2 on CoreMark 10. |
| `same_owner_advanced` | 341,599 | Same-owner cursor movement is now a major useful path. |
| `same_owner_block_pred_ctl` | 0 | The stale pre-window attribution remains gone. |
| `same_owner_block_no_emit` | 12,782 | Down from `45,436`; residual no-emit is smaller but still real. |
| `same_owner_block_rem` | 34,907 | Remainder and straddle policy is now the largest same-owner residual bucket. |
| `same_owner_block_rem_straddle` | 0 | The residual is not direct line-straddle blocking. |
| `same_owner_block_rem_consume` | 24,223 | Most remainder blocking is the consume-remainder phase. |
| `same_owner_block_rem_consumed` | 10,684 | A smaller but material post-consume hold remains. |
| `same_owner_block_other` | 36 | Down from `33,142`; backward next-owner blocking was the root cause of this bucket. |
| `same_owner_no_emit_fe_stall` | 6,054 | Largest residual same-owner no-emit sub-bucket. |
| `same_owner_no_emit_redirect` | 3,583 | Redirect recovery still overlaps useful same-owner candidate cycles. |
| `same_owner_no_emit_pkt_not_ready` | 2,425 | Packet buffer backpressure is visible but not dominant. |
| `same_owner_no_emit_dup` | 720 | Same-owner no-emit is no longer mainly duplicate suppression. |
| `packet_empty_noemit_dup` | 32,151 | Down from `63,848`; the duplicate replay tax remains about half the old value. |
| `packet_empty_f2_data` | 60,845 | Down from `92,059`; this counter means F2 had data but emitted no packet. |
| `xs_f2_data_wait` | 480 | True missing F2 data wait is tiny on this row. |
| `xs_f2_data_wait_icq_empty` | 480 | The true F2 wait is fully ICQ-empty in this run. |
| `packet_empty_wait_icresp` | 31,100 | Down from the previous accepted row. |

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
| Depth-2 budget without owner queue | Strict-clean but performance-identical to the accepted successor row; `xs_ftq_depth_gt1_cycles=0`. | Rejected as a no-op. Raising the budget alone does not create a second safe owner because IFU still has only a single pending successor relation. |
| Predicted-control-window advance without F2 fire contract | Dhrystone improves to `18,913` cycles, but CoreMark times out with stale owner and packet-stale counters. | Direction has leverage, but packet side effects fired while the IFU cursor was stalled. |
| Predicted-control-window advance with only packet enqueue stall gating | Owner/stale counters are clean, but strict delivery skips `0x80002fce` inside the `0x80002fc0` owner. | `will_emit` still updated duplicate and cursor state without an accepted packet. F2 fire must gate `will_emit`, not just `packet_enq`. |
| Two-entry pending owner queue plus cancel-all younger FTQ policy | Strict-clean on smoke and CoreMark 10, but performance-identical: CoreMark 10 remains `1,570,351` cycles and `6.403369` CoreMark/MHz. `xs_ftq_depth_gt1_cycles` reaches only `92`, with only `46` queued runahead candidates. | Rejected as insufficient leverage in this form. The queued target is usually absent or already represented by the next FTQ owner, so extra owner depth is dormant rather than supply-producing. |
| Two-entry future-line buffer in `ifu_line_fetch` | Strict-clean but performance-identical on smoke and CoreMark 10; `xs_icq_future_head_block` remains `6,176` on CoreMark 10. | Rejected as a no-op. The counted future-head cycles are mostly waiting for owner promotion, not lost because the single future-line slot is full. |
| Direct post-consume remainder hold bypass | Strict-clean and improves smoke rows: Dhrystone 100 `18,913 -> 18,812`, CoreMark 1 `164,550 -> 163,958`. CoreMark 10 regresses `1,528,608 -> 1,542,985`, with `xs_packet_buf_full_cycles` rising `14,753 -> 21,022` and `xs_backend_stall_pkt_ready` rising `35,109 -> 40,730`. | Rejected in this form. The post-consume hold is not purely wasted frontend time; removing it creates a denser packet burst that overfills the downstream packet buffer on the heavy row. |
| IBuffer-credit-gated post-consume remainder bypass | Same smoke win as direct bypass, but CoreMark 10 still regresses to `1,542,985`. Full-buffer cycles improve versus direct bypass but backend packet-ready stall remains `40,730`. | Rejected in this form. Current-cycle IBuffer occupancy is not enough credit information for this burst; future remainder work must coordinate with downstream drain or owner work scheduling, not just local cursor motion. |
| Line-end straddle handoff | Unguarded handoff improves Dhrystone 100 `18,913 -> 18,705` but trips strict delivery on CoreMark 10 by skipping a control-owner PC near `0x800038ba`. Control-gated handoff is endpoint-clean but regresses CoreMark 1 `164,550 -> 164,941` and CoreMark 10 `1,528,608 -> 1,543,758`. It reduces CoreMark 10 packet-empty pressure (`packet_empty_f2_data 60,689 -> 35,796`, `packet_empty_noemit_dup 32,112 -> 21,607`) but raises backpressure (`xs_packet_buf_full_cycles 14,753 -> 26,215`, `xs_backend_stall_pkt_ready 35,109 -> 40,342`). | Rejected in this form. It proves the frontend can remove real no-emit work, but the dense packet burst exposes the same downstream drain limiter as the post-consume bypass. |
| Credit-aware line-end straddle handoff | Dhrystone 100 keeps the gain at `18,709`, CoreMark 1 still regresses to `164,799`, and CoreMark 10 regresses further to `1,545,490`. | Rejected. A simple current-cycle IBuffer credit gate is not a sufficient scheduler. The next useful step is not another local straddle gate; it is a downstream drain or packet scheduling mechanism that can absorb the frontend burst. |
| TAGE mispredicted-conditional-first training | Smoke regresses: CoreMark 1 `164,550 -> 167,213`, branch hotspot `141,408 -> 146,011`. | Rejected as the next BPU training policy. Prioritizing a mispredicted conditional in the commit group hurts broader branch behavior. |
| Execute-time BRU recovery plus partial recovery knobs | Branch hotspot improves `141,408 -> 131,707`, but CoreMark 1 fails with `TOHOST_3`, flags `1`, checksum `36549` instead of `59156`. | Rejected as-is. Execute-time branch recovery has leverage, but the current recovery contract is not endpoint-safe enough to harden. |
| Integer PRF depth 192 | Dhrystone 100, CoreMark 1, branch hotspot, and CoreMark 10 are cycle-identical to the accepted baseline. | Rejected as a no-op for the current limiter. Raw PRF capacity does not move the measured rows even though CoreMark 10 reports integer physical-register pressure. |
| Same-cycle free-list release forwarding | Build passes, but Dhrystone 100 hits the DSim iteration limit after only 9 sampled cycles. The release mask creates a same-cycle commit-release to allocation/rename availability path. | Rejected in combinational form. Do not forward commit releases directly into the allocator ready network; reopen only with a registered credit or queue structure that cannot form a stall/allocation loop. |
| ROB slot-2 writeback-ready bypass | Dhrystone 100 and branch hotspot are unchanged, while CoreMark 1 regresses `164,550 -> 165,565`. The broader full writeback bypass plusarg regresses CoreMark 1 to `167,527`. | Rejected. Same-cycle ROB head ready bypass is not a useful commit-side fix in this pipeline shape. |
| Load speculation past unresolved store-address entries | `+ALLOW_LOAD_SPEC_PAST_STA` is strict-clean, but Dhrystone 100 and CoreMark 1 are cycle-identical to the accepted baseline: `18,913` and `164,550` cycles. | Rejected as a raw no-op. Do not promote this plusarg without a deeper LSU dependency predictor or replay contract that can demonstrate counter movement. |
| Standalone refcounted rename move elimination | Endpoint-clean and active, but not a performance win. Dhrystone 100 is effectively unchanged at `18,912`, CoreMark 1 regresses `164,550 -> 165,430`, CoreMark 10 regresses `1,528,608 -> 1,545,737`, and the branch hotspot regresses `141,408 -> 143,204`. A ready-source-only variant is worse on CoreMark 1 at `166,609`; a one-cycle delayed move-ready path matches the same regression. | Rejected in standalone form. It reduces backend pressure, but the saved work exposes more branch/redirect and operand-ready stalls. Reopen only with a predictor/recovery companion or a stronger pressure-aware policy that is proven on CoreMark 1, CoreMark 10, and the branch hotspot. |
| BRU early fetch redirect isolation | The latest profiled current-RTL recheck regresses all smoke rows: Dhrystone 100 `18,913 -> 18,921`, CoreMark 1 `164,550 -> 165,800`, and branch hotspot `141,408 -> 146,756`. | Rejected as a global policy. Branch/recovery still has leverage, but raw early redirect injects too much quarantine and timing disturbance. |
| BRU early redirect plus partial recovery | Endpoint-clean and improves the branch hotspot `141,408 -> 138,564`, but regresses Dhrystone 100 `18,913 -> 18,920` and CoreMark 1 `164,550 -> 166,483`. | Mixed evidence only. Partial recovery has a real branch-heavy signal, but the current policy is too broad for scoreable RTL. Reopen as a structurally selective recovery policy, not a global plusarg. |
| Age-bounded BRU early recovery | Age 8 and age 12 gates are endpoint-clean but still regress the score rows. Age 8 gives Dhrystone 100 `18,920`, CoreMark 1 `165,342`, hotspot `143,982`; age 12 gives `18,926`, `165,421`, and `142,859`. | Rejected. ROB age alone is not the right selector. It reduces long CoreMark quarantine but also destroys the branch-hotspot predictor/recovery effect. |
| Direct non-head partial recovery | Removing the head-only requirement lets the branch hotspot nearly match baseline at `141,469`, but Dhrystone 100 and CoreMark 1 time out. Dhrystone stalls at `9,010` retired instructions with free-list popcount drained to zero; CoreMark stalls at `5,458` retired instructions. | Rejected as a contract bug, not a performance candidate. The current checkpoint manager clears all checkpoints on restore, which is safe for head-only recovery but unsafe for non-head recovery with older unresolved checkpoints. |
| Checkpoint sequence-preserve trial for non-head recovery | A first checkpoint-file sequence tag trial preserved older checkpoint slots on partial restore and gated checkpoint save during restore, but direct non-head partial recovery still reproduces the same Dhrystone/CoreMark timeout signature. | Rejected as incomplete. Non-head recovery needs a deeper branch checkpoint contract, including restore snapshot semantics and same-cycle release/commit handling, not only checkpoint occupancy preservation. |
| Local PHT global override | Branch hotspot improves `141,408 -> 138,680`, Dhrystone 100 is unchanged, and CoreMark 1 regresses `164,550 -> 169,642` with mispredicts rising from `4,250` to `5,025`. | Rejected as a global policy. Local history has useful information, but it needs per-PC arbitration against TAGE/SC instead of overriding everywhere. |
| Disable local predictor | Branch hotspot improves `141,408 -> 137,606`, Dhrystone 100 is unchanged, and CoreMark 1 regresses `164,550 -> 165,487`. | Rejected. Current local alternation support is useful on CoreMark but harmful on the branch probe, so the right direction is a chooser, not all-on or all-off. |
| Local PHT-only chooser | Dhrystone 100 is unchanged, CoreMark 1 regresses `164,550 -> 167,144`, and branch hotspot regresses `141,408 -> 141,738`. | Rejected. Gating only the PHT path misses the larger mixed signal from the local alternation path. |
| Local component chooser, SC-biased reset | Dhrystone 100 is unchanged and branch hotspot improves `141,408 -> 140,709`, but CoreMark 1 regresses `164,550 -> 164,966`. | Rejected. The direction can suppress harmful local behavior, but the warmup and chooser signal still trade away CoreMark. |
| Local component chooser, local-biased reset | Dhrystone 100 is unchanged and branch hotspot improves `141,408 -> 140,195`, but CoreMark 1 regresses `164,550 -> 166,501`. | Rejected. Starting from baseline-local behavior helps the branch probe more, but the CoreMark cost grows. |
| Bias-only local alternation filters | Non-saturated bias improves CoreMark 1 `164,550 -> 163,000` but regresses the branch hotspot `141,408 -> 141,959`. Saturated bias gives CoreMark 1 `164,285` and branch hotspot `142,325`. | Rejected. Bias alone is not the right selector; the accepted follow-up also requires weak TAGE before local alternation can override. |
| Weak-TAGE-only local alternation filter | Dhrystone 100 is unchanged, but CoreMark 1 regresses from the accepted row `164,364 -> 164,782` and the branch hotspot regresses `141,326 -> 143,909`. | Rejected. The weak-TAGE guard and per-PC bias guard are both required. |
| Disable loop speculative count | Dhrystone 100 is unchanged at `18,913`, while CoreMark 1 regresses `164,550 -> 176,523` and the branch hotspot regresses `141,408 -> 142,828`. | Rejected. The loop predictor's speculative count path is not the broad limiter; using committed counts increases frontend zero and redirect pressure on CoreMark. |
| Direct same-cycle loop speculative-count bypass | Dhrystone 100 improves to `18,227`, but CoreMark 1 hits the DSim iteration limit after only a short sampled window. | Rejected as a combinational-loop-shaped timing path. Do not feed the current BPU lookup directly from the current `pred_checker` speculative update. |
| Allocation-time loop speculative-count update | Endpoint-clean, but Dhrystone 100 is unchanged at `18,913` and CoreMark 1 regresses to `173,807`. | Rejected. Updating the loop speculative count at FTQ allocation is too early and pollutes loops that the baseline already handles well. |
| Always-on FTQ-owner loop speculative-count sideband bypass | Endpoint-clean and Dhrystone 100 improves to `18,227`, but CoreMark 1 regresses to `165,402` or `166,151` depending on whether the sideband also replaces the sequential update. | Rejected in always-on form. The sideband mechanism is useful, but it needs a per-loop chooser so it only fixes loops that repeatedly miss exits. |
| Loop-bypass threshold-1 activation | Endpoint-clean, but CoreMark 1 regresses `163,013 -> 164,080` while Dhrystone 100 improves only `18,577 -> 18,570` and the branch hotspot is unchanged. CoreMark 1 dynamic BPU-update misses rise `2,481 -> 2,578`, `redirect_recovery` rises `4,052 -> 4,225`, and `packet_empty` rises `11,242 -> 12,685`. | Rejected as scalar threshold chasing. Do not promote without a general predictor mechanism and broader benchmark evidence. |
| Sticky/no-decay loop-bypass chooser | Endpoint-clean and Dhrystone 100 improves to `18,241`, but CoreMark 1 regresses to `163,827`; the branch hotspot is unchanged. | Rejected as overfit risk. Removing chooser decay makes loop-exit repair too sticky across CoreMark loop classes. |
| Saturated-threshold sticky/no-decay chooser | Endpoint-clean and Dhrystone 100 improves to `18,248`, but CoreMark 1 still regresses to `163,269`. CoreMark 1 dynamic BPU-update misses rise `2,481 -> 2,489`, `redirect_recovery` rises `4,052 -> 4,111`, and `packet_empty` rises `11,242 -> 11,384`. | Quarantined DSE evidence only. It proves hysteresis has a real Dhrystone signal, but not a signoff-safe architectural step. |
| NLPB full-depth duplicate check | Dhrystone 100 and branch hotspot are unchanged; CoreMark 1 moves only `164,550 -> 164,556`. | Not a performance slice. This may be a cleanup candidate, but it does not close the Stage 2 target gap. |

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
- Follow-up accepted artifacts:
  `benchmark_results/20260507_pred_ctl_window_f2_fire_accept_smoke` and
  `benchmark_results/20260507_pred_ctl_window_f2_fire_accept_coremark10`.
  The key contract fix is that `instr_compact.will_emit` now means a real
  accepted packet fire, so duplicate suppression, IFU cursor movement, FTQ
  delivery, and packet enqueue agree on the same F2 event.

## Architecture State

rv64gc-v2 is aligned in direction with the Reference Core B/Reference Core A-style frontend split,
but it is not yet deep enough.

| Role | Current state | Remaining gap |
|---|---|---|
| BPU | Can launch bounded depth-1 direct-taken runahead and accepted owner-complete successor requests. JALR/RET are excluded. | Not yet a sustained predicted owner stream. BPU timing/quality has not been proven the limiter. |
| FTQ | Allocation, IFU request, IFU writeback, and commit/training views are split. `xs_ftq_occ_max=2` on the accepted heavy row. | Depth is still effectively shallow. Depth-2 needs an owner request queue before promotion. |
| IFU | `ifu_work_item_t` carries PC, line address, FTQ identity, and owner-delivered state. It can select a successor request after owner completion, hold an undelivered owner stable, advance within an owner up to the predicted-control packet, and keep advancing when the next owner is a backward target behind the current work PC. | Needs a real owner work/request queue before deeper runahead. Duplicate suppression remains a crutch, and remainder handling is now the largest same-owner residual. |
| IBuffer | Decode-facing packet buffer is owner-aware and decode valid is qualified by actual dequeue fire. | It must be fed by deeper owner-tagged upstream backlog, then scored by occupancy and stale-owner counters. |
| Rename | Held work owns rename input; fresh packets stall when no slot can advance, while partial progress captures the non-advanced tail. | This is now a required frontend-runahead contract. Remaining rename stalls should be tracked as backend pressure, not frontend supply. |

## Active Bottleneck Hypothesis

The accepted successor path, predicted-control fire contract, and
backward-next-owner safety rule remove a large part of the F2 data/no-emit and
duplicate/no-emit buckets. The old `same_owner_block_other` bucket is now gone.
The latest attribution shows that `packet_empty_f2_data` is not true missing
F2 data; true no-data wait is only `466` cycles on CoreMark 10. The large
`packet_empty_f2_data` bucket is therefore data-present no-emit and overlaps
with remainder, redirect, packet-ready, and frontend-stall causes.

The same-owner remainder family has now been tested in two useful forms:
post-consume hold bypass and line-end straddle handoff. Both remove real
frontend bubbles on short rows, and the straddle handoff also cuts CoreMark 10
packet-empty counters sharply. Both still regress the heavy CoreMark row
because they create a denser packet burst than the backend/IBuffer can drain.
This moves the next viable work away from local remainder cursor removal and
toward a downstream drain or packet scheduling mechanism.

Current plan execution, 2026-05-08:

- XSim was rebuilt from the current tree at `a4131c0` before the fresh quick
  baseline. XSim ignores several SVA properties, so this is a profiled smoke,
  not a replacement for the DSim strict full signoff artifact.
- Fresh rebuilt-XSim quick artifact:
  `benchmark_results/dse_20260508_current_baseline_profile_quick`.
- Passed rows: Dhrystone 100 `18,577` cycles, CoreMark 1 `163,013` cycles,
  branch hotspot `141,326` cycles. Loop-buffer activity and standalone
  decoded-op replay remain zero.
- CoreMark 10 remains covered by the existing full strict signoff artifact
  `benchmark_results/signoff_signoff_20260508_loop_bypass_threshold2_goal`,
  because XSim CoreMark 10 is too slow for the quick planning loop.

The fresh quick counters confirm that the next useful slice is not another
local loop or threshold knob:

| Row | `packet_empty_f2_data` | `packet_empty_noemit_dup` | `xs_packet_buf_full_cycles` | `xs_backend_stall_pkt_ready` | Readout |
|---|---:|---:|---:|---:|---|
| Dhrystone 100 | 526 | 212 | 0 | 0 | No packet-drain pressure. |
| CoreMark 1 | 6,653 | 3,569 | 1,613 | 3,595 | Packet/backpressure is visible even on the short row. |
| Branch hotspot | 31,408 | 21,794 | 0 | 51 | Mostly duplicate/redirect no-emit, not downstream drain. |
| CoreMark 10, full signoff | 60,845 | 32,151 | 14,640 | 34,950 | Heavy row has real packet/backpressure pressure. |

Follow-up instrumentation:
`benchmark_results/dse_20260508_packet_head_class_prof_smoke` adds
simulation-only head-class attribution for packet-buffer-full and
backend-packet-ready cycles. It is endpoint-clean on Dhrystone 100 and
CoreMark 1. CoreMark 1 reports:

| Counter | Value | Interpretation |
|---|---:|---|
| `xs_packet_buf_full_cycles` | 1,613 | Full-buffer pressure exists in the short CoreMark row. |
| `xs_packet_full_head_multi` | 1,608 | Almost every full-buffer cycle has a multi-instruction packet at the head. |
| `xs_packet_full_head_ctl` | 777 | About half of full-buffer cycles have a control-bearing head packet. |
| `xs_packet_full_head_taken` | 1,239 | Most full-buffer cycles are behind a predicted-taken owner. |
| `xs_packet_full_drain_ready` | 1,148 | Most full-buffer cycles are not owner-wait. The buffer can drain, but downstream cannot absorb enough. |
| `xs_backend_stall_pkt_ready` | 3,595 | Backend backpressure with a packet ready is still larger than packet-full time. |
| `xs_backend_stall_pkt_head_multi` | 3,158 | Backend packet-ready stalls are mostly multi-instruction packet heads. |
| `xs_backend_stall_pkt_head_complete` | 2,119 | Many stalls occur with an owner-complete head packet, suggesting the next scheduler should treat owner completion and control boundaries explicitly. |

Near-term structural target: control-aware packet/drain scheduling. The first
candidate should not produce more packets blindly. It should schedule or pace
multi-instruction, control-bearing, and owner-complete packet heads so that
CoreMark 1 and CoreMark 10 reduce `xs_backend_stall_pkt_ready` and
`xs_packet_buf_full_cycles` without increasing branch-hotspot duplicate or
redirect no-emit pressure.

Execution result, 2026-05-08: the first downstream-drain candidate is
rejected. The RTL trial changed ROB admission from all-or-nothing full-width
readiness to count-based partial prefix admission, then tested a larger
backend window variant. Both are general architectural mechanisms, not loop
buffer replay and not benchmark-PC steering, but neither meets the acceptance
bar.

| Artifact | Mechanism | Result | Verdict |
|---|---|---|---|
| `benchmark_results/dse_20260508_rob_counted_admission_smoke` | Count-based ROB admission, rename can consume one to three available ROB slots and hold the rest. | Dhrystone 100 stays `18,577`, branch hotspot stays `141,326`, CoreMark 1 improves `163,013 -> 162,549`. | Short-row evidence only. |
| `benchmark_results/dse_20260508_rob_counted_admission_cm10` | Same counted admission on CoreMark 10. | Endpoint-clean, but CoreMark 10 regresses `1,500,110 -> 1,512,356`. Backend stall drops, but packet-empty and frontend stall overlap rise. | Rejected, do not keep RTL. |
| `benchmark_results/dse_20260508_window_capacity_dse` | Counted admission plus `ROB_DEPTH=256`, `INT_PRF_DEPTH=192`. | Endpoint-clean on Dhrystone, CoreMark 1, CoreMark 10, and branch hotspot, but CoreMark 10 regresses further to `1,525,077`. | Rejected combined window-capacity form. |

Readout: the backend/packet boundary is real, but simply admitting partial ROB
prefixes or adding raw window capacity changes pressure distribution instead
of reducing total cycles. This path should resume only with a scheduler that
has an explicit control/owner policy and proves CoreMark 10 improvement, not
with raw capacity or all-purpose partial admission.

Follow-up, 2026-05-08: pressure-aware backend admission throttle.

The implemented DSE knob `+BACKEND_ADMISSION_THROTTLE` is a default-off
backend admission governor. It does not use benchmark PCs. When enabled, it
monitors registered ROB free count and rename free physical-register count.
If ROB headroom drops to `<=16` entries or integer physical-register headroom
drops to `<=24`, rename switches to half-width admission, two oldest slots per
cycle, and holds the younger tail. It exits after recovery to `>=32` ROB free
entries and `>=48` free physical registers. This keeps the mechanism in the
backend window-pressure domain instead of reviving loop replay or frontend
benchmark steering.

Full strict profiled DSE:
`benchmark_results/dse_backend_admission_throttle_v2_full_20260508`.

| Row | Baseline cycles | Throttle cycles | Delta | Verdict |
|---|---:|---:|---:|---|
| Dhrystone 100 | 18,577 | 18,577 | 0 | No regression |
| Dhrystone 300 | 53,890 | 53,890 | 0 | No regression |
| CoreMark 1 | 163,013 | 162,979 | -34 | Small gain |
| CoreMark 10 | 1,500,110 | 1,498,206 | -1,904 | Small gain |
| Other 12 stage-1 rows | unchanged | unchanged | 0 | No regression |

CoreMark 10 counter movement against
`benchmark_results/dse_bottleneck_profile_full_20260508`:

| Counter | Baseline | Throttle | Delta |
|---|---:|---:|---:|
| `xs_bottleneck_rename_stall_preg` | 33,444 | 52 | -33,392 |
| `xs_bottleneck_rename_free_preg_min` | 11 | 21 | +10 |
| `xs_bottleneck_rename_rob_free_min` | 0 | 2 | +2 |
| `xs_bottleneck_dep_wait_on_alu` | 13,495,221 | 13,426,224 | -68,997 |
| `xs_bottleneck_dep_wait_on_load` | 705,820 | 702,895 | -2,925 |
| `xs_bottleneck_fe_zero_cycles` | 122,514 | 120,716 | -1,798 |
| `xs_bottleneck_branch_mispredicts` | 30,607 | 30,412 | -195 |
| `xs_bottleneck_rename_slots_lost_total` | 197,914 | 211,806 | +13,892 |
| `xs_bottleneck_rob_commit_slots_lost_head_block` | 88,308 | 88,361 | +53 |
| `xs_bottleneck_backend_throttle_active_cycles` | 0 | 89,493 | +89,493 |
| `xs_bottleneck_backend_throttle_limited_slots` | 0 | 137,825 | +137,825 |

Verdict: keep this as a measurable default-off DSE mechanism and counter hook,
not as the main Stage 2 performance direction. It proves that pressure-aware
admission can remove physical-register starvation without hurting the broader
16-row set, but the gain is only about `0.13%` on CoreMark 10 and intentionally
adds rename deferral. The larger remaining limiter is still ALU producer
dependency and issue readiness; next work should target wakeup/issue latency
or a control-aware packet/drain scheduler with CoreMark 10 counter movement.

Additional top-PC attribution from
`benchmark_results/dse_20260508_remainder_noemit_top_pc_coremark10` keeps the
accepted RTL cycle-identical at CoreMark 10 `1,528,608` cycles and
`6.579328` CoreMark/MHz, but names the remaining hot paths:

| Bucket | Dominant PCs | Interpretation |
|---|---|---|
| Same-owner remainder | `0x80003b00` inside `crc16`, plus `0x80002140/0x8000214e` inside `cmp_idx` | The largest entry is the next-line consume point for a 32-bit instruction starting at `0x80003afe`, byte offset 62. The consume cycle emits a real packet, so only the post-consume hold is clearly lost time. |
| Data-present no-emit duplicate | `0x80003af4` in the `crc16` byte loop, `0x80003676/0x80003738` in `core_state_transition`, `0x80003176` in `matrix_mul_matrix` | Duplicate suppression is still protecting endpoint identity, but it is now concentrated in real loop/control hot paths rather than random owner drift. |
| Data-present no-emit redirect | `0x800023ac` in `core_list_mergesort`, `0x8000315c` in `matrix_mul_matrix`, `0x8000242c` in list handling | Redirect recovery remains the second large packet-empty cause after duplicate suppression. |
| Data-present no-emit stall | `0x800039f8/0x800039ee` in `crcu16`, plus list and CRC tail PCs | Some residual packet-empty time overlaps backend or packet-ready stalls, consistent with the rejected post-remainder bypass backpressure result. |

Verdict from this attribution and the follow-up trials: do not count all
`same_owner_block_rem_consume` cycles as waste. The local cursor bubbles are
real, but removing them alone is not enough; it shifts the bottleneck into
packet-buffer fullness, backend packet-ready stalls, and ROB/PRF-correlated
rename pressure. The next architectural optimization should therefore target
useful work per delivered packet or downstream drain, not another local
straddle/remainder shortcut.

The `20260507_packet_pressure_attrib_coremark10` row resolves the next
bottleneck selection:

| Counter | Value | Interpretation |
|---|---:|---|
| `xs_data_present_no_emit` | 86,522 | Most remaining `packet_empty_f2_data` style cycles are data-present no-emit, not missing I-cache data. |
| `xs_data_no_emit_dup` | 41,442 | Duplicate suppression is the largest data-present no-emit cause. |
| `xs_data_no_emit_redirect` | 33,202 | Redirect recovery is the second-largest data-present no-emit cause. |
| `xs_data_no_emit_fe_stall` | 8,286 | Backend/F2 stall overlap is material but smaller. |
| `xs_packet_buf_full_cycles` | 14,753 | IBuffer fullness exists but is not an owner-selection problem. |
| `xs_packet_full_owner_wait` | 0 | The owner-aware IBuffer is not blocked by waiting for the matching owner. |
| `xs_packet_full_backend` | 4,169 | Some full-buffer time overlaps backend stall. |
| `xs_packet_full_drain_ready` | 10,584 | Most full-buffer cycles are already drain-ready. |
| `xs_backend_stall_pkt_ready` | 35,109 | Backend cannot accept while fetch has a packet ready. |
| `rob_full` | 34,217 | Rename/backpressure is strongly correlated with ROB capacity. |
| `stall_preg` | 33,177 | Slot-0 rename stall is also strongly correlated with integer physical register pressure. |

The same profiling-only row keeps the accepted CoreMark 10 timing
cycle-identical at `1,528,608` cycles and `6.579328` CoreMark/MHz while adding
backend attribution:

| Counter | Value | Interpretation |
|---|---:|---|
| `issue_stall_operand_cyc` | 619,195 | Operand readiness, not FU contention, dominates issue pressure. |
| `issue_stall_arb_cyc` | 189,596 | Selection pressure is real but secondary to operand readiness. |
| `iq0 operand/arb/issued/eligible_avg` | `233,534 / 108,244 / 1,651,528 / 1.16` | IQ0 carries most integer issue pressure. |
| `iq1 operand/arb/issued/eligible_avg` | `227,742 / 63,012 / 638,300 / 0.46` | IQ1 is also materially blocked on operands. |
| `iq2 operand/arb/issued/eligible_avg` | `293,745 / 38,258 / 430,440 / 0.30` | IQ2 sees fewer eligible uops but the largest operand-blocked cycle count. |
| `rename_fused_uops` | 89 | Macro-fusion frequency is too low to be the next broad lever. |
| `commit_fused_uops` | 71 | Committed fused work is negligible on CoreMark 10. |
| `rename_move_candidate_total` | 258,574 | Move elimination has large dynamic frequency, about 8 percent of the retired stream. |
| `rename_zero_elim_total` | 33,292 | Zero elimination is already active and safe, but smaller than the remaining move opportunity. |

Verdict: frontend ownership is no longer the only active limiter on CoreMark
10. Raw ROB/PRF capacity and ROB-head bypass did not move the broad rows, so
the next architectural slice should reduce useful backend work per architectural
instruction instead of adding raw capacity. The strongest current lever is
alias-safe rename move elimination: the dynamic move-candidate count is large,
while macro-fusion is negligible on CoreMark 10.

Update, 2026-05-08: the first local-vs-SC chooser family is rejected. It is
functionally clean, but it trades CoreMark against the branch hotspot instead
of improving both. Do not promote local arbitration without a better training
contract and dynamic hot-PC attribution that covers the branch probe PCs, not
only the fixed CoreMark hot-PC list. The next architectural slice should move
to a non-BPU limiter with direct CoreMark 10 evidence.

Update, 2026-05-08: dynamic hot-PC BPU attribution is now available from
`benchmark_results/dse_dse_20260508_bpu_dynamic_profile128_smoke` and
`benchmark_results/dse_dse_20260508_bpu_dynamic_profile_coremark10`. The
profiler is simulation-only and cycle-identical on the strict smoke and
CoreMark 10: Dhrystone 100 remains `18,913`, CoreMark 1 remains `164,550`,
the branch hotspot remains `141,408`, and CoreMark 10 remains `1,528,608`.
CoreMark 10 reports `458,389` branch-predictor updates and `19,882` BPU-update
mispredicts in the dynamic profiler. The largest dynamic BPU miss PCs are:

| PC | Function | Updates | BPU-update mispredicts | Direction shape | Component evidence |
|---|---|---:|---:|---|---|
| `0x800036b4` | `core_state_transition` | 10,823 | 2,542 | Forward, strongly not-taken biased | Local override is active in the fixed hot-PC probe while the update stream is `2,879` taken, `7,944` not-taken. |
| `0x800023ae` | `core_list_mergesort` | 3,294 | 1,409 | Backward, mixed outcome | Loop table hits almost every update, but the branch is data-dependent rather than a simple counted loop. |
| `0x80002380` | `core_list_mergesort` | 4,640 | 1,328 | Backward, mixed outcome | Loop table hits almost every update and the loop override is frequently active. |
| `0x800031ec` | `matrix_mul_matrix_bitextract` | 29,160 | 1,264 | Backward counted loop | Loop table hits almost every update, but exit/iteration phasing still leaves residual misses. |
| `0x80003704` | `core_state_transition` | 13,116 | 1,250 | Forward, strongly not-taken biased | State-machine delimiter branch, similar class to `0x800036b4`. |
| `0x800036bc` | `core_state_transition` | 10,238 | 1,054 | Forward, strongly not-taken biased | TAGE/SC/local interaction is still weak on state-machine delimiter branches. |

This reopens BPU arbitration, but with a narrower contract than the rejected
global local chooser. The next local-predictor trial should suppress local
alternation only when a per-branch bias table says the branch is strongly
biased in the opposite direction. That is a general predictor arbitration
mechanism, not a CoreMark-PC special case. Guardrails: no regression on
Dhrystone 100, CoreMark 1, CoreMark 10, or the branch hotspot; the dynamic BPU
profile must show lower miss pressure on `core_state_transition` without
raising the loop-heavy merge/matrix rows.

Follow-up, 2026-05-08: two bias-only local filters are rejected. The first
filter suppresses local alternation against a strong-but-not-saturated bias and
improves CoreMark 1 to `163,000` cycles, but regresses the branch hotspot to
`141,959`. The saturated-bias-only version reduces the CoreMark 1 gain to
`164,285` and regresses the branch hotspot further to `142,325`. The accepted
version adds a non-local strength guard: local alternation may override only
when TAGE is weak and the per-PC bias is not fully opposed. This keeps the
smoke clean and improves the heavy row:

| Row | Dhrystone 100 | CoreMark 1 | CoreMark 10 | Branch hotspot | Verdict |
|---|---:|---:|---:|---:|---|
| Accepted baseline | 18,913 | 164,550 | 1,528,608 | 141,408 | Baseline before local arbitration. |
| Bias filter | 18,913 | 163,000 | Not run | 141,959 | Rejected, branch-hotspot regression. |
| Saturated bias filter | 18,913 | 164,285 | Not run | 142,325 | Rejected, branch-hotspot regression. |
| Weak-TAGE gated bias filter | 18,913 | 164,364 | 1,526,048 | 141,326 | Accepted, strict-clean broad improvement. |

The accepted row reduces CoreMark 10 committed mispredicts from `34,092` to
`33,593` and dynamic BPU-update misses from `19,882` to `18,352`. It strongly
improves the forward state-machine branch at `0x800036b4`
(`2,542 -> 977` dynamic BPU-update misses) and `0x80003704`
(`1,250 -> 573`), while making some loop/data-dependent branches worse
(`0x800031ec` moves `1,264 -> 1,827`). Net performance still improves, but
this is a narrow BPU quality step, not a packet-empty fix.

Follow-up simplification rejected: removing the per-PC bias guard and using
only the weak-TAGE condition keeps Dhrystone 100 unchanged, but regresses
CoreMark 1 `164,364 -> 164,782` and the branch hotspot
`141,326 -> 143,909` versus the accepted weak-TAGE gated bias row. Keep the
bias guard.

Follow-up, 2026-05-08, loop-exit speculative-count bypass chooser: CoreMark
10 after the weak-TAGE row still showed loop-exit residual misses. The most
visible case was the counted matrix loop at `0x800031ec`, where the baseline
often predicted the loop exit as taken because the next same-cycle lookup saw
a stale loop speculative count. Three unsafe or too-broad forms were rejected:
direct current-cycle bypass tripped an iteration-limit failure, allocation-time
speculative count update regressed CoreMark 1 to `173,807`, and always-on
FTQ-owner sideband bypass regressed CoreMark 1 to `165,402` or `166,151`.

The accepted form keeps the original sequential speculative-count update and
adds a narrow same-cycle bypass from the emitted FTQ owner's predicted
conditional into the next loop predictor lookup. A per-loop
`loop_bypass_conf` chooser enables that bypass only after the loop predictor is
already saturated-confident and still repeatedly misses loop exits. Evidence:

| Row | Previous accepted | Loop bypass chooser | Verdict |
|---|---:|---:|---|
| Dhrystone 100 | 18,913 | 18,577 | Accepted, strict-clean. |
| CoreMark 1 | 164,364 | 163,727 | Accepted, strict-clean. |
| CoreMark 10 | 1,526,048 | 1,525,168 | Accepted, strict-clean. |
| Dhrystone 300 | 54,926 | 53,890 | Accepted, broad guard clean. |
| Branch hotspot | 141,326 | 141,326 | Unchanged. |

The branch evidence matches the design intent. The always-on bypass fixed
Dhrystone's hot loop but damaged CoreMark loops such as `0x80002446` and
`0x80003aea`. The chooser keeps the useful Dhrystone signal while avoiding
that broad CoreMark loop pollution. CoreMark 10 committed mispredicts improve
from `33,593` to `33,293`, and dynamic BPU-update misses improve from
`18,352` to `17,794`.

Follow-up threshold tuning is accepted. The chooser threshold now enables the
same sideband at `loop_bypass_conf >= 2` instead of only at saturated
confidence. This is still not the rejected always-on policy: the loop must
already have repeated exit-miss evidence before the bypass engages. Evidence:

| Row | Loop bypass chooser | Threshold-2 chooser | Verdict |
|---|---:|---:|---|
| Dhrystone 100 | 18,577 | 18,577 | Accepted, unchanged. |
| CoreMark 1 | 163,727 | 163,013 | Accepted, strict-clean improvement. |
| CoreMark 10 | 1,525,168 | 1,500,110 | Accepted, strict-clean improvement. |
| Dhrystone 300 | 53,890 | 53,890 | Accepted, unchanged. |
| Branch hotspot | 141,326 | 141,326 | Accepted, unchanged. |

The CoreMark 10 dynamic BPU-update miss total improves from `17,794` to
`16,086`. The residual matrix bitextract loop at `0x800031ec` is the main
winner, with BPU-update misses reduced from `2,077` to `529`.

Architectural line after the 2026-05-08 audit:

- Keep the FTQ-owner loop speculative-count sideband. It is a timing repair for
  the loop predictor, not a benchmark-PC steering path.
- Keep the per-loop exit-miss chooser with decay. The chooser is what prevents
  the sideband from becoming the rejected always-on policy.
- Keep threshold-2 activation as the accepted baseline because it passed the
  full 16-row signoff and improves CoreMark without Dhrystone, Dhrystone 300,
  or branch-hotspot regression.
- Do not continue scalar loop-bypass threshold chasing. Threshold-1,
  sticky/no-decay, and saturated-threshold sticky/no-decay are DSE-only
  rejected or quarantined evidence until a broader predictor mechanism and
  broader benchmark suite justify reopening them.

Clean committed goal run:
`benchmark_results/signoff_signoff_20260508_loop_bypass_threshold2_goal`
passes all 16 Stage 1 manifest rows from commit `476dc67` with strict
owner/delivery checks, `+PERF_PROFILE +PERF_COUNTERS +STAT_DUMP`, loop-buffer
activity zero, and standalone decoded-op replay activity zero.

Update, 2026-05-08: raw load speculation past unresolved store-address entries
using `+ALLOW_LOAD_SPEC_PAST_STA` is endpoint-clean but performance-identical
on Dhrystone 100 and CoreMark 1. It is not a useful next slice in its current
form.

Update, 2026-05-08: standalone refcounted move elimination is also rejected.
The RTL trial added committed physical-register reference counts and enabled
move aliasing. It eliminated `248,837` CoreMark 10 moves and reduced several
backend-pressure counters, but the net row regressed:

| CoreMark 10 counter | Baseline | Move-elim trial | Direction |
|---|---:|---:|---|
| `mcycle` | 1,528,608 | 1,545,737 | worse by 1.12% |
| `CoreMark/MHz` | 6.579328 | 6.505639 | worse |
| `rob_full` | 34,217 | 30,386 | better |
| `stall_preg` | 33,177 | 28,437 | better |
| `xs_backend_stall_pkt_ready` | 35,109 | 30,745 | better |
| `issue_stall_arb_cyc` | 189,596 | 169,038 | better |
| `issue_stall_operand_cyc` | 619,195 | 668,600 | worse |
| `redirect_recovery` | 33,006 | 35,776 | worse |
| `committed mispredicts` | 34,092 | 36,906 | worse |
| `packet_empty_f2_data` | 60,689 | 63,023 | worse |
| `packet_empty_noemit_dup` | 32,112 | 33,433 | worse |

Verdict: the useful-work reduction is real, but the current branch/recovery
path cannot absorb the changed timing. The next accepted architectural step
should therefore target branch recovery/update timing or predictor ownership
before reopening move elimination as a paired optimization.

Update, 2026-05-08: branch recovery timing has now been rechecked from the
current accepted RTL with `+TRACE_BRU_RECOVERY`. The global policies are not
acceptable, but the attribution is useful:

| Row | Dhrystone 100 | CoreMark 1 | Branch hotspot | Verdict |
|---|---:|---:|---:|---|
| Accepted baseline | 18,913 | 164,550 | 141,408 | Scoreable baseline. |
| Early redirect | 18,921 | 165,800 | 146,756 | Rejected, broad regression. |
| Early redirect plus partial recovery | 18,920 | 166,483 | 138,564 | Mixed signal, hotspot improves but DS and CoreMark regress. |

CoreMark 1 with early plus partial recovery reports `22,981` BRU quarantine
cycles, `4,319` committed mispredicts, and `9,592` safe-boundary quarantine
cycles. Several top CoreMark recovery PCs have long average quarantine and are
not consistently checkpoint-at-branch safe. The branch hotspot, in contrast,
benefits from the partial policy because the recovery windows are short and
regular: `23,871` quarantine cycles, `7,805` mispredicts, and max quarantine
of only 4 cycles. The next branch slice must therefore be selective by
architectural recovery metadata, such as checkpoint-at-branch availability,
ROB-age/quarantine bound, and branch/control type. It must not steer on fixed
benchmark PCs.

Follow-up, 2026-05-08: the first selective attempts are also rejected. A
ROB-age gate keeps the runs endpoint-clean but does not improve performance.
Direct non-head partial recovery exposes the missing contract: partial
checkpoint restore currently clears all checkpoint slots. That is acceptable
when the recovering branch is at the head because there are no older unresolved
branch checkpoints to preserve. It is not acceptable for general non-head
branch recovery. A real Reference Core B/Reference Core A-style recovery path needs selective
checkpoint invalidation, preserving checkpoints older than the recovered branch
and squashing only the branch plus younger state. Do not retry non-head partial
recovery until that checkpoint ownership rule exists.

Follow-up, 2026-05-08, second trial: preserving older checkpoint slots with a
simple sequence tag is insufficient by itself. The timeout signature remains
identical, so the missing branch recovery contract likely also includes the
RAT/free-list restore snapshot boundary and same-cycle commit release handling.
Treat non-head branch recovery as a larger backend recovery redesign, not a
small checkpoint-file patch or local resource selector.

Follow-up, 2026-05-08, third trial: the non-head recovery contract was extended
with same-cycle RAT/free-list checkpoint save semantics, older-checkpoint
preservation, recovery-filtered writeback survival, consumed-checkpoint
metadata clearing for the recovered branch, and a rename-resource gate. This
turns the previous timeout into endpoint-clean execution, but it is still not
scoreable performance:

| Trial | Evidence | Dhrystone 100 | CoreMark 1 | Branch hotspot | Verdict |
|---|---|---:|---:|---:|---|
| Default resmoke with opt-in code disabled | `benchmark_results/dse_dse_20260508_partial_recovery_dirty_default_resmoke` | 18,913 | 164,364 | 141,326 | Accepted baseline is unchanged. |
| Non-head partial recovery, resource gated | `benchmark_results/dse_dse_20260508_partial_recovery_resource_gate_smoke` | 21,730 | 168,444 | 142,321 | Rejected. Endpoint-clean, but still regresses every score row. |
| Early redirect plus resource-gated partial recovery | `benchmark_results/dse_dse_20260508_early_partial_resource_gate_smoke` | 21,767 | TOHOST_3 | 139,612 | Rejected. Hotspot improves, but CoreMark endpoint breaks. |

The resource gate is useful evidence: it reduces the pathological Dhrystone
free-list stall signature from the earlier direct non-head trial
(`30,229 -> 21,730` cycles, `has_preg=0` stalls `11,778 -> 2,977`), proving
that branch recovery can overrun rename/PRF resources when it is too eager.
However, it remains worse than the accepted default (`18,913` cycles), and
CoreMark remains worse than the accepted default (`164,364` cycles). Do not
promote execute-time non-head partial recovery yet. Reopen only with a stronger
branch-order checkpoint ownership design and a headroom signal that prevents
PRF/ROB pressure before rename stalls are already visible.

Follow-up, 2026-05-08, fourth trial: resource-aware selective branch recovery
was implemented as `+SELECTIVE_BRANCH_RECOVERY`, separate from the older
unfiltered `+EXEC_PARTIAL_BRANCH_RECOVERY` experiment. The selector adds
registered frontend IBuffer headroom, registered rename/free-list headroom, a
32-cycle burst guard, and recovery-candidate attribution counters. Default RTL
is cycle-identical to the accepted baseline on the rebuilt strict smoke:

| Row | Baseline | Selective recovery | Delta | Verdict |
|---|---:|---:|---:|---|
| Dhrystone 100 | 18,577 | 18,828 | +251 | Rejected. |
| CoreMark 1 | 163,013 | 165,766 | +2,753 | Rejected. |
| Branch hotspot | 141,326 | 144,753 | +3,427 | Rejected. |

Attribution shows the selector is active but still harmful. Dhrystone accepts
`99` recoveries, CoreMark 1 accepts `1,597`, and the branch hotspot accepts
`1,236`. CoreMark 1 packet-empty rises `11,242 -> 12,539`, FTQ-empty rises
`4,154 -> 4,478`, and checkpoint restore reports `3,103` discarded checkpoint
slots. The branch hotspot does reduce `packet_empty_f2_data`
`31,408 -> 30,216`, but total cycles still regress because FTQ-empty,
backend-packet-ready, and redirect duplicate pressure rise. Verdict: resource
headroom is not the missing architectural contract. Keep the selector
DSE-only; the next real branch-recovery step must implement branch-order
checkpoint ownership and selective squash before any further recovery timing
tuning.

Follow-up, 2026-05-08, IBuffer packet coalescing: simple useful-work-per-packet
coalescing is rejected as a no-op. Two RTL variants were tested: head-only
same-owner adjacent packet merge and selected-owner-anywhere adjacent packet
merge. Both were strict-clean, but both were cycle-identical to the accepted
baseline:

| Trial | Evidence | Dhrystone 100 | CoreMark 1 | Branch hotspot | CoreMark 10 | Verdict |
|---|---|---:|---:|---:|---:|---|
| Head-only adjacent packet coalescing | `benchmark_results/dse_dse_20260508_ibuf_coalesce_smoke`, `benchmark_results/dse_dse_20260508_ibuf_coalesce_coremark10` | 18,913 | 164,550 | 141,408 | 1,528,608 | Rejected no-op. |
| Selected-owner-anywhere adjacent packet coalescing | `benchmark_results/dse_dse_20260508_ibuf_coalesce_anywhere_smoke`, `benchmark_results/dse_dse_20260508_ibuf_coalesce_anywhere_coremark10` | 18,913 | 164,550 | 141,408 | 1,528,608 | Rejected no-op. |

The CoreMark 10 profile remained exactly at the accepted counter shape:
`packet_empty_f2_data=60,689`, `packet_empty_noemit_dup=32,112`,
`xs_packet_buf_full_cycles=14,753`, and
`xs_backend_stall_pkt_ready=35,109`. Do not carry this packet merge logic in
RTL. The downstream-drain direction remains open, but the next version should
decouple decode or rename acceptance from frontend packet production rather
than merging already formed IBuffer packets.

Follow-up, 2026-05-08, decode-to-rename queue: a blind decoded-packet queue is
also rejected as a standalone optimization. The queue was inserted after
fusion with empty flow-through, so it did not add latency when rename was
ready. It was endpoint-clean, and depth 2 showed a tiny CoreMark 1 improvement
(`164,550 -> 164,408`), but all CoreMark 10 variants regressed:

| Trial | Evidence | Dhrystone 100 | CoreMark 1 | Branch hotspot | CoreMark 10 | Verdict |
|---|---|---:|---:|---:|---:|---|
| Depth 4 decoded queue | `benchmark_results/dse_dse_20260508_decode_queue_smoke`, `benchmark_results/dse_dse_20260508_decode_queue_coremark10` | 18,913 | 164,550 | 141,408 | 1,542,513 | Rejected, heavy-row regression. |
| Depth 2 decoded queue | `benchmark_results/dse_dse_20260508_decode_queue_depth2_smoke`, `benchmark_results/dse_dse_20260508_decode_queue_depth2_coremark10` | 18,913 | 164,408 | 141,408 | 1,535,323 | Rejected, small CoreMark 1 win does not hold on CoreMark 10. |
| One-entry decoded skid | `benchmark_results/dse_dse_20260508_decode_skid1_smoke`, `benchmark_results/dse_dse_20260508_decode_skid1_coremark10` | 18,913 | 164,550 | 141,408 | 1,542,513 | Rejected, heavy-row regression. |

The queue trials are still useful evidence. Depth 4 reduced
`xs_packet_buf_full_cycles 14,753 -> 11,613` and
`xs_backend_stall_pkt_ready 35,109 -> 26,952`, but increased
`packet_empty 95,219 -> 101,030` and `redirect_recovery 33,006 -> 34,743`.
Depth 2 changed the pressure shape differently: packet-empty improved to
`86,337`, but packet-buffer full rose to `26,789` and rename stall asserted
cycles rose to `55,074`. Verdict: the bottleneck is not solved by adding a
generic queue. Any future drain mechanism needs branch/control awareness or a
joint frontend/backend scheduling policy, not blind decoupling.

Follow-up, 2026-05-08, IBuffer depth and control-aware buffering: deeper
packet buffering has real CoreMark 10 leverage, but not yet a signoff-safe
policy. A blind IBuffer depth increase from 8 to 16 entries was strict-clean
and improved CoreMark 10 from `1,525,168` to `1,498,650` cycles
(`6.594618 -> 6.711860` CoreMark/MHz). It reduced CoreMark 10 packet pressure
(`packet_empty 96,280 -> 92,430`,
`packet_empty_f2_data 62,549 -> 60,964`,
`packet_empty_noemit_dup 34,055 -> 32,245`,
`xs_packet_buf_full_cycles 15,159 -> 7,391`), but CoreMark 1 regressed
`163,727 -> 163,991`. Therefore the blind depth change is rejected.

Additional strict-clean classifier trials were also rejected or no-op:

| Trial | Smoke result | CoreMark 10 result | Verdict |
|---|---|---|---|
| Blind IBuffer 16 | Dhrystone 100 and hotspot unchanged; CoreMark 1 regresses to `163,991`. | Improves to `1,498,650`. | Rejected. Useful pressure relief, but not broad. |
| Any-control watermark at 8 | Smoke matches baseline exactly. | Matches baseline exactly at `1,525,168`. | Rejected no-op. Gating all control packets removes the long-row win. |
| Any-control watermark at 10/12/9 | CoreMark 1 regresses to `163,785` at watermark 10 and `163,991` at 9 or 12. | Not promoted. | Rejected. Threshold tuning is not stable. |
| Predicted-taken-control watermark at 8 | Smoke matches baseline exactly. | Matches baseline exactly. | Rejected no-op. Extra depth for not-taken/fallthrough traffic is not the useful class. |
| Backward conditional allowlist | Smoke matches baseline exactly. | Matches baseline exactly. | Rejected no-op. Simple loop-back control is not enough. |
| Non-conditional-control allowlist | Smoke matches baseline exactly. | Matches baseline exactly. | Rejected no-op. Calls, returns, and jumps are not the useful class here. |
| Conditional-branch allowlist | CoreMark 1 regresses to `163,991`. | Not promoted. | Rejected. This confirms conditional-branch buffering is the coupled win/loss class. |
| TAGE-confident conditional allowlist | CoreMark 1 still regresses to `163,991`. | Not promoted. | Rejected. The existing `tage_confident` bit is not a sufficient safety discriminator. |
| Blind IBuffer 16 plus speculative-update window at 8 | CoreMark 1 regresses badly to `166,007`. | Not promoted. | Rejected. Suppressing speculative BPU state while still fetching deep is worse than the original coupling. |

Verdict: IBuffer capacity is a real downstream-drain lever, but conditional
branch buffering couples useful packet burst absorption to branch-predictor
state and short-row mispredict timing. Do not keep any of the RTL from this
slice. Reopen only with a stronger conditional-branch ownership or BPU
checkpoint contract, for example a way to let buffered conditional packets use
extra capacity without advancing predictor state beyond a restorable owner
snapshot.

Follow-up, 2026-05-08, duplicate/remainder attribution: a profiler-only slice
in `benchmark_results/dse_dse_20260508_dup_rem_attrib_coremark10` keeps
CoreMark 10 cycle-identical at `1,528,608` cycles and `6.579328` CoreMark/MHz,
while splitting the duplicate and remainder residuals more precisely:

| Counter | Value | Interpretation |
|---|---:|---|
| `xs_dup_last_emit` | 41,442 | Every duplicate suppression is from the last-emitted packet guard, not the replay guard. |
| `xs_dup_next_is_seq` | 41,377 | Nearly every duplicate would advance to the sequential next PC. |
| `xs_dup_next_same_line` | 41,442 | The duplicate tax is fully same-line in this row. |
| `xs_dup_next_branch_target` | 0 | This is not a taken-target duplicate problem. |
| `xs_dup_with_control` | 9,177 | Some duplicates sit on packets containing a control instruction. |
| `xs_dup_with_taken_control` | 37 | Almost none are taken-control redirects. |
| `xs_same_owner_block_rem_backend` | 3,699 | Only a minority of remainder blocking directly overlaps backend stall. |
| `xs_same_owner_block_rem_packet_full` | 0 | The local remainder block itself is not packet-buffer-full, but prior bypass trials show it creates future packet-buffer pressure. |

This confirms that the largest remaining duplicate bucket is a same-line
sequential replay caused by conservative owner/cursor policy, not I-cache
latency or branch-target replay. The architectural opportunity is real, but it
must preserve the FTQ owner and prediction-snapshot contract.

Follow-up, 2026-05-08, predicted-not-taken same-owner trial: a narrow RTL trial
allowed same-owner fall-through past predicted-not-taken conditionals when
there was no subgroup split and the next PC stayed in the same line. It is
rejected and removed. Smoke evidence from
`benchmark_results/dse_dse_20260508_nt_cond_same_owner_smoke`:

| Workload | Baseline | Trial | Verdict |
|---|---:|---:|---|
| Dhrystone 100 | 18,913 | 21,419 | Regresses badly. |
| CoreMark 1 | 164,550 | did not finish cleanly | Unsafe. |
| Branch hotspot | 141,408 | iteration limit | Unsafe. |

Verdict: not-taken control fall-through cannot simply stay in the same FTQ
owner in the current contract. The likely missing piece is branch-owner
snapshot/repair ownership for packets after a not-taken conditional. Do not
retry this as a local `same_owner_continue` relaxation; reopen only with an
explicit branch-control owner contract that handles GHR/RAS snapshots and FTQ
completion/training for later packets.

A follow-up live-snapshot repair trial is also rejected and removed. That
trial made later control packets use the live request snapshot when their
control did not match the FTQ-predicted control slot, then retried the same
predicted-not-taken owner fall-through. Smoke evidence from
`benchmark_results/dse_dse_20260508_nt_cond_live_snapshot_smoke`:

| Workload | Baseline | Live-snapshot trial | Verdict |
|---|---:|---:|---|
| Dhrystone 100 | 18,913 | 21,359 | Regresses badly. |
| CoreMark 1 | 164,550 | did not finish cleanly | Unsafe. |
| Branch hotspot | 141,408 | timeout with owner/stale mismatches | Unsafe. |

Verdict: live branch snapshots alone are not sufficient. The rejected row hit
`xs_f2_owner_idx_mismatch=21` and persistent packet-stale owner mismatches on
the hotspot. This points to the FTQ/IBuffer owner sequencing contract itself,
not only the branch snapshot fields.

Follow-up, 2026-05-08, duplicate owner-context attribution: a profiler-only
slice in
`benchmark_results/dse_dse_20260508_dup_reason_attrib_coremark10` keeps the
accepted CoreMark 10 timing cycle-identical at `1,528,608` cycles and
`6.579328` CoreMark/MHz. The strict smoke artifact is
`benchmark_results/dse_dse_20260508_dup_reason_attrib_smoke`, with Dhrystone
100 `18,913`, CoreMark 1 `164,550`, and branch hotspot `141,408`.

| Counter | Value | Interpretation |
|---|---:|---|
| `xs_dup_suppressed` | 41,442 | Total duplicate-suppressed data-present cycles. |
| `xs_dup_same_owner_recover` | 11,419 | Already covered by the accepted same-owner recovery path. |
| `xs_dup_no_same_owner` | 30,023 | Residual duplicates that are not currently allowed to use same-owner recovery. |
| `xs_dup_no_owner_straddle` | 29,987 | Nearly every no-owner duplicate overlaps line-end straddle classification. |
| `xs_dup_no_owner_control` | 9,177 | A large subset also contains a control instruction. |
| `xs_dup_no_owner_subgroup` | 42 | Subgroup split is not the broad limiter. |
| `xs_dup_no_owner_not_live` | 36 | Owner-liveness misses are negligible. |
| `xs_dup_no_owner_complete` | 73 | Owner-complete misses are negligible. |
| `xs_dup_no_owner_safe_noctl` | 0 | There is no remaining safe, same-line, no-control, no-straddle duplicate bucket. |
| `xs_same_owner_block_rem` | 34,820 | Remainder remains material, dominated by consume/post-consume phases. |
| `xs_same_owner_block_rem_consume` | 24,084 | Most remainder blocking is the active consume cycle. |
| `xs_same_owner_block_rem_consumed` | 10,736 | Post-consume hold is smaller but still visible. |

Verdict: the tempting "same-line sequential duplicate" residual is not an
owner-free no-control case. It is mostly straddle and sometimes control-owner
work. That matches the rejected straddle handoff and predicted-not-taken owner
relaxation results. The next useful frontend attempt must change the
branch/straddle owner sequencing contract or the downstream drain contract; it
should not be another local `same_owner_continue` predicate relaxation.

Promotion conditions:

| Gate | Objective | Required evidence |
|---|---|---|
| A | Lock current accepted RTL as scoreable baseline. | Full scoreable run from committed RTL, strict checks, endpoint identity, broad smoke pass. |
| B | Prove true frontend runahead. | Achieved for depth-1 successor, predicted-control-window same-owner advance, and backward-next-owner safety: `xs_ftq_occ_max=2`, nonzero IBuffer occupancy on CoreMark, lower duplicate/no-emit broadly, no owner/stale drift. |
| C | Score frontend-only ceiling. | CoreMark now reaches 6.71 CM/MHz; the longer Dhrystone anchor reaches 3.19 DMIPS/MHz. Frontend-only work still has measurable residual before declaring the ceiling. |
| D | Pick second-domain limiter. | Branch/recovery, uop-count, LSU/load-use, ROB-head, and scheduler counters identify one dominant residual. |
| E | Stretch to final target. | Full manifest passes, no major off-target regression, then compare against 7.5 CM/MHz and 4.0 DMIPS/MHz. |

If Gate C fails, stop treating frontend-only DSE as sufficient. Promote the
counter-backed second domain instead.

## Workable Options

| Option | Status | Expected benefit | Guardrail |
|---|---|---|---|
| Baseline counter pass | Required after commit | Prevents another stale methodology loop. | Use committed RTL and full strict plusargs. |
| Successor runahead | Accepted depth-1 slice | Keeps owner-complete successor allocation active and broadly profitable. | Any further change still needs endpoint, strict owner/delivery, and golden-PC evidence where available. |
| Predicted-control-window same-owner advance | Accepted depth-1 slice | Removes conservative F2 duplication before predicted-control packets. | `will_emit`, duplicate tracking, packet enqueue, and IFU cursor movement must share one accepted-packet fire. |
| Backward-next-owner same-owner safety | Accepted depth-1 slice | Removes false overlap blocking when a predicted next owner is a backward loop target. | Only treat the next owner as non-blocking when its start PC is behind the current work PC. |
| Owner request queue / IFU work queue | Deferred structural depth slice | Lets IFU request and F2 delivery decouple by FTQ owner instead of relying on a single pending successor. | Reopen after residual attribution shows useful future targets; owner-start PC delivery exactly once. |
| Capacity-bounded depth-2 runahead | Recalibrate before another RTL trial | The first owner-queue attempt was dormant, so more depth alone is not enough. | Reopen only with evidence that the next predicted owner is not already the FTQ next owner and has a useful distinct target. |
| Early fetch-line metadata | Conditional | Local straddle handoff reduces frontend bubbles but regresses CoreMark 10 through downstream pressure. | Reopen only as part of a packet scheduling or drain improvement, not as another standalone cursor shortcut. |
| Same-owner remainder policy | Rejected in local forms | Post-consume bypass and line-end straddle handoff both improve short rows but regress CoreMark 10. | Do not continue local remainder bypass DSE until downstream packet drain is improved. |
| Same-owner residual attribution | Keep active as a guardrail | The corrected profiler has now isolated predicted-control, backward-target, and no-owner duplicate context. | The latest no-owner split reports `xs_dup_no_owner_safe_noctl=0`; do not reopen local same-owner relaxation without a branch/straddle owner redesign. |
| BPU/FTQ training metadata cleanup | High value | Improves attribution and enables safe prediction experiments. | Preserve GHR/RAS/target snapshots per owner. |
| BPU S0/uBTB | Conditional | May help if lookup latency or direction quality blocks runahead. | Promote only with per-PC branch data or timing evidence. |
| Indirect prediction | Conditional | Helps if indirect MPKI is material. | Per-PC evidence required. |
| Macro-fusion expansion | Deprioritized by evidence | Existing macro-fusion commits only 71 fused uops on CoreMark 10, so expanding this path is unlikely to close the stretch gap. | Reopen only if a broader benchmark suite shows high dynamic fused-pattern frequency. |
| Refcounted rename move elimination | Rejected standalone, keep as paired candidate | CoreMark 10 reports 258,574 dynamic move candidates, and the RTL trial proves backend pressure can drop. Net performance still regresses because redirect/mispredict and operand-ready stalls rise. | Reopen only after branch recovery/update timing is improved, or with pressure-aware enable evidence. Keep physical-register refcounting as the required correctness mechanism if this path returns. |
| ROB/PRF capacity | Rejected in raw, counted-admission, and combinational timing forms | CoreMark 10 has `rob_full=34,217` and slot-0 `stall_preg=33,177`, but PRF192 is cycle-identical, ROB-head bypass regresses CoreMark 1, same-cycle free-list release forwarding trips a simulator iteration loop, counted ROB admission regresses CoreMark 10 to `1,512,356`, and counted admission plus `ROB_DEPTH=256` / `INT_PRF_DEPTH=192` regresses to `1,525,077`. | Reopen only with a registered allocation, free, or commit-drain mechanism paired with control/owner scheduling, not raw depth, comb release-forwarding, or all-purpose partial ROB admission. |
| BPU local-vs-SC chooser | Accepted in weak-TAGE gated form | Dynamic BPU attribution showed forward state-machine branches where local alternation fought stronger non-local predictions. The accepted form improves CoreMark 10 and the smoke set without fixed-PC steering. | Keep local alternation narrow: it may override only weak TAGE and only when the per-PC bias is not fully opposed. Do not broaden local override without full smoke plus CoreMark 10 evidence. |
| Loop predictor speculative count policy | Accepted in threshold-2 chooser-gated form | The FTQ-owner sideband bypass improves Dhrystone 100, CoreMark 1, CoreMark 10, and Dhrystone 300 when gated by a per-loop exit-miss chooser with decay. The latest threshold-2 activation raises CoreMark 10 to `1,500,110` cycles and `6.705406` CM/MHz. | Keep the original sequential speculative-count update, FTQ-owner sideband, per-loop exit-miss chooser, decay, and threshold-2 baseline. Do not use direct current-cycle bypass, allocation-time update, always-on sideband bypass, threshold-1 activation, or sticky/no-decay chooser behavior without a general predictor mechanism and broader benchmark evidence. |
| Selective branch recovery/update timing | Blocked on checkpoint ownership | Global early recovery is rejected, but early plus partial recovery improves the branch hotspot by 2.0 percent and exposes useful recovery metadata. Direct non-head partial recovery and the resource-aware selector both prove the current checkpoint manager cannot yet support general execute-time recovery profitably. | First add selective checkpoint squash or an equivalent branch-order checkpoint ownership scheme. Resource/free-list/IBuffer headroom guards alone are insufficient; do not promote early or partial recovery until checkpoint ownership is fixed. |
| Uop-count and fusion accounting | Evidence slice complete | The profiler separates macro-fusion from move elimination: macro-fusion is low-frequency, move candidates are high-frequency. | Continue with refcounted move elimination, not a broad fusion sweep. |
| Downstream packet drain / scheduling | First counted-admission forms rejected | Accepted frontend work and rejected remainder/straddle trials all show that denser packet supply can exceed backend drain. Head-only and selected-owner IBuffer packet coalescing were strict-clean but cycle-identical no-ops. Blind decoded queues moved pressure but regressed CoreMark 10. Blind IBuffer depth 16 improved CoreMark 10 to `1,498,650`, but regressed CoreMark 1 to `163,991`; control-aware watermarks either became no-ops or preserved the short-row regression. New head-class profiling shows CoreMark 1 full-buffer and backend-packet-ready stalls are mostly multi-instruction heads. Count-based ROB prefix admission improves CoreMark 1 but regresses CoreMark 10, and a larger-window variant regresses further. | Reopen only with explicit owner/control scheduling, likely paired with branch recovery or useful-work reduction. Do not keep raw partial ROB admission, packet merge, generic queue, raw IBuffer depth increase, or loop-threshold tuning. Must reduce `xs_backend_stall_pkt_ready` or packet-buffer-full cycles without increasing `packet_empty`, redirect recovery, or DS/CoreMark cycles. |
| Predicted-not-taken owner fall-through | Rejected local forms | Attribution shows many duplicate cycles are same-line sequential, so this looked tempting. The local owner relaxation regressed Dhrystone and broke CoreMark/hotspot. A live-snapshot repair still timed out with owner/stale mismatches. | Reopen only with explicit branch-owner and FTQ/IBuffer sequencing semantics, not by relaxing `same_owner_continue` alone. |
| LSU/load-use or backend balance | Later candidate | Addresses non-frontend residuals. | Open after ROB/PRF capacity if backend stalls persist. |

## Update, 2026-05-09: ALU-Chain Shape Attribution

Profiler-only implementation:
`src/tb/tb_top.sv` now tracks the operation shape of physical registers that
are ALU-produced and still not issued because their own producer is blocked.
The parser ranks these as `xs_bottleneck_dep_alu_blocked_prod_*` counters.
This is simulation-only attribution; no core RTL behavior changed.

Validation artifacts:

- Smoke:
  `benchmark_results/dse_alu_chain_shape_profile_smoke_r2_20260509`
- Heavy row:
  `benchmark_results/dse_alu_chain_shape_profile_coremark10_20260509`
- DSim rebuilt from the current tree. Dhrystone 100, CoreMark 1, and CoreMark
  10 are endpoint-clean with strict fetch owner/delivery and branch recovery
  checks.

Cycle results are identical to the accepted baseline:

| Row | Cycles | Metric |
|---|---:|---:|
| Dhrystone 100 | 18,577 | 3.133924 DMIPS/MHz |
| CoreMark 1 | 163,013 | 6.483697 CM/MHz |
| CoreMark 10 | 1,500,110 | 6.705406 CM/MHz |

CoreMark 10 residual ALU dependency shape:

| Counter | Value | Interpretation |
|---|---:|---|
| `xs_bottleneck_dep_wait_on_alu` | 13,495,221 | Dominant residual source-wait class. |
| `xs_bottleneck_dep_alu_wait_not_issued` | 12,310,501 | Most ALU waits are before producer issue, not post-issue writeback. |
| `xs_bottleneck_dep_alu_wait_not_issued_producer_blocked` | 12,234,377 | The producer is present in an integer IQ but blocked on its own operands. |
| `xs_bottleneck_dep_alu_wait_not_issued_producer_blocked_single_alu` | 10,393,558 | The dominant shape is a single ALU-produced source chain. |
| `xs_bottleneck_dep_alu_blocked_prod_logic` | 8,682,202 | Boolean logic producers dominate the blocked-producer shape. |
| `xs_bottleneck_dep_alu_blocked_prod_wop` | 5,853,515 | RV64 W-suffix ops are a large overlapping subset. |
| `xs_bottleneck_dep_alu_blocked_prod_imm` | 6,289,578 | Immediate-form ALU producers are slightly more common than register-register producers. |
| `xs_bottleneck_dep_alu_blocked_prod_reg` | 5,944,799 | Register-register ALU chains are also material. |
| `xs_bottleneck_dep_alu_blocked_prod_shift` | 1,598,881 | Shift/rotate chains are secondary but non-trivial. |
| `xs_bottleneck_dep_alu_blocked_prod_sub` | 1,425,437 | SUB/NEG-style work is secondary. |
| `xs_bottleneck_dep_alu_blocked_prod_move_candidate` | 239,271 | Move candidates are real but too small to be the next standalone lever. |
| `xs_bottleneck_rename_move_candidates` | 256,478 | Dynamic move frequency is high, but only a small fraction is on the dominant blocked-producer wait path. |
| `xs_bottleneck_rename_move_candidates_rs1_wait` | 201,088 | Most move candidates are source-waiting at rename, which explains why standalone elimination changed timing rather than simply deleting easy work. |

The top blocked producer PCs cluster in CoreMark `crc16`, especially the
bit-serial update loop around `0x80003ab8..0x80003b14`. The instructions are
general ALU shapes (`xor`, `andi`, `negw`, `srliw`, `and`, `zext.h`) rather
than a fixed benchmark PC special case.

Architectural verdict:

- Reopening standalone move elimination is not the next step. The data shows
  only about 2 percent of blocked not-yet-issued ALU-producer wait slots are
  move-candidate producers, and the earlier refcounted move-elimination trial
  already reduced pressure while regressing net cycles.
- A C910-style short-ALU or wakeup/forwarding slice was the correct next probe
  from the counter evidence, but the first local IQ0 variants are not promoted
  architecture. The only clean subvariant, boolean/shift-only same-cycle IQ0
  chaining, is useful DSE evidence but does not clear the current bar for
  Stage 2 promotion because its measured upside is below 3 percent, coverage is
  not full signoff, and nearby variants regress branch-heavy rows.
- Any trial must target `xs_bottleneck_dep_wait_on_alu`,
  `xs_bottleneck_dep_alu_wait_not_issued_producer_blocked`, and the new
  operation-shape counters. It must not claim success from DS/CoreMark cycle
  movement alone.

## Direction 1 Todo: Branch Ownership and Recovery Contract

Status on May 9, 2026: Direction 1 is still a correctness-observability and
contract-hardening path, not a performance claim. Commit `0d0b5ff` hardens the
simulation-only checkpoint recovery checker and exposes parser-compatible
branch-recovery counters. The accepted loop-exit threshold-2 baseline remains
the scoreable baseline until non-head branch recovery is endpoint-clean and
broadly non-regressing.

| Step | Status | Exit criterion |
|---|---|---|
| 1.1 | Done | Added `branch_recovery_contract_checker.sv`; both DSim and XSim compile it. |
| 1.2 | Done | Dhrystone 100, CoreMark 1, frontend mixed branch dense, and branch hotspot pass with `+BRANCH_RECOVERY_CHECK +BRANCH_RECOVERY_STRICT` added to the existing strict fetch owner/delivery/profile plusargs. |
| 1.3 | Done | Documented the branch-order recovery contract across checkpoint, RAT, free-list, ROB, commit release, writeback, LSU side effects, and frontend redirect ownership. |
| 1.4 | Checker hardening done, behavior pending | Commit `0d0b5ff` adds strict save-overwrite and save-blocked-with-free checkpoint allocation invariants plus parsed counters. It does not change checkpoint restore behavior. |
| 1.5 | Rejected in current form | Resource-aware direct recovery is endpoint-clean on Dhrystone 100, CoreMark 1, and branch hotspot, but regresses all three rows. Do not continue selector tuning until 1.4 exists. |
| 1.6 | Pending | Only after 1.5, reintroduce selective early frontend redirect with a resource/headroom guard. |
| 1.7 | Pending | Promote only if branch hotspot improves without Dhrystone/CoreMark regression and contract counters show active non-head recovery with no free-list leak, checkpoint orphan, stale owner, or endpoint drift. |

Required Direction 1 checker plusargs:

- `+BRANCH_RECOVERY_CHECK`
- `+BRANCH_RECOVERY_STRICT`

Stop conditions:

- Invalid checkpoint restore or release.
- Duplicate checkpoint release in one commit group.
- Checkpoint save overwrites a post-release occupied slot.
- Checkpoint save is blocked while a post-release slot is free.
- Restore of a checkpoint that is also released in the same cycle.
- Free-list popcount drain or leak.
- Checkpoint orphan or wrong branch-order preservation.
- Any endpoint mismatch or timeout.

Initial checker smoke:

- Dhrystone 100: PASS, `mcycle=18,577`, `minstret=49,088`, branch-recovery
  checker invalid/duplicate/restore-conflict/save-overwrite counts all zero.
  Accepted checkpoint saves: `8,917`.
- CoreMark 1: PASS, `mcycle=163,013`, `minstret=332,154`, branch-recovery
  checker invalid/duplicate/restore-conflict/save-overwrite counts all zero.
  Accepted checkpoint saves: `70,671`.
- Frontend mixed branch dense: PASS, `mcycle=7,220`, `minstret=11,514`,
  all branch-recovery violation counters zero. Accepted checkpoint saves:
  `3,595`.
- Branch hotspot: PASS, `mcycle=141,326`, `minstret=156,693`,
  all branch-recovery violation counters zero. Accepted checkpoint saves:
  `74,634`.
- Artifacts:
  `benchmark_results/dse_dse_branch_recovery_checker_standard_smoke_20260509`
  and
  `benchmark_results/dse_dse_branch_recovery_checker_hardening_smoke_20260509`.

Fresh `+EXEC_PARTIAL_BRANCH_RECOVERY` probe with the checker:

- Branch hotspot: PASS and contract-clean with `checkpoint_restores=1,793`,
  but regresses `141,326 -> 142,321` cycles.
- Dhrystone 100: PASS and contract-clean with `checkpoint_restores=113`, but
  regresses `18,577 -> 21,730` cycles. The regression is resource-pressure
  shaped: `backend_stall=2,976`, packet-buffer full cycles `2,679`, and
  free-list minimum popcount drops to `1`.

Interpretation: the current partial recovery path is now observable and does
not trip the first checkpoint-order checker, but it is not a performance
candidate. The next RTL slice should add explicit recovery selection and
resource-headroom gating before any early frontend redirect or default-on
promotion.

Branch-order recovery contract draft:

- **Checkpoint owner.** A checkpoint belongs to exactly one unresolved branch
  ROB entry. `uses_checkpoint`, `checkpoint_id`, and the checkpoint's ROB-tail
  snapshot must identify the same branch boundary.
- **Restore branch.** A non-head restore may target only a live checkpoint owned
  by the recovering branch. Restoring a free checkpoint, or a checkpoint being
  released in the same cycle, is illegal.
- **Older checkpoints.** Checkpoints older than the recovering branch must
  survive a partial restore so older unresolved branches remain recoverable.
- **Recovered and younger checkpoints.** The recovering branch checkpoint and
  all younger checkpoints must be invalidated by the partial restore.
- **RAT image.** The restored RAT must be the speculative architectural map at
  the recovery branch boundary. Same-cycle commit writes must not overwrite
  that speculative image during checkpoint restore.
- **Free-list image.** The restored free-list must return physical registers
  allocated after the recovery branch while preserving allocations that were
  already live at the branch boundary. Same-cycle commit release must not
  double-free or hide a register still referenced by a surviving older entry.
- **ROB image.** The ROB must clear the recovering branch and younger entries,
  restore the tail to the checkpoint boundary, and preserve all older valid
  entries and their metadata.
- **Commit overlap.** Same-cycle commit and partial restore must have a single
  ordering rule across commit release, checkpoint release, ROB clear, RAT
  update, and free-list update. Any branch checkpoint released by commit must
  be older than the restoring branch.
- **Writeback survival.** Writebacks for surviving older ROB entries must remain
  observable after recovery. Writebacks for the recovering branch and younger
  entries must be filtered before they can update architectural or readiness
  state.
- **LSU side effects.** Stores younger than the recovery branch must not become
  committed-visible. Loads younger than the recovery branch must not leave
  stale wakeups, replay requests, or queue entries after the partial restore.
- **Frontend handoff.** FTQ, IFU, IBuffer, BPU history, and RAS restoration must
  be driven by the same recovery branch owner. Early frontend redirect remains
  disabled until backend partial recovery is endpoint-clean without it.

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
- Full bottleneck DSE counters when choosing the next architectural slice:
  `+BOTTLENECK_PROFILE` plus the normal
  `+PERF_PROFILE +PERF_COUNTERS +STAT_DUMP` profile.

## Full Bottleneck DSE Profiler

Implemented on May 8, 2026 as simulation-only testbench profiling. The
profiler is off by default and emits parser-compatible
`xs bottleneck_* : value` counters only when `+BOTTLENECK_PROFILE` is present.
The plusarg also enables the existing performance profile window so the new
counts share the same timed context as the legacy frontend/backend counters.

Smoke validation:

- With `+BOTTLENECK_PROFILE`:
  `benchmark_results/dse_bottleneck_profile_smoke_20260508`.
- Without `+BOTTLENECK_PROFILE`:
  `benchmark_results/dse_bottleneck_profile_off_smoke_20260508`.
- Dhrystone 100 and CoreMark iteration 1 both pass strict owner/delivery checks
  in both runs.
- Timed cycles are identical with the profiler off and on:
  Dhrystone 100 `18,577`, CoreMark iteration 1 `163,013`.
- The on run emits 207 `xs_bottleneck_*` counters per row; the off run emits
  none.

Counter families now available for DSE ranking:

- Frontend zero and packet-empty aliases.
- Rename/window pressure and lost rename slots.
- Per-IQ valid, ready, not-ready, eligible, selected, arb-loss, and oldest
  not-ready-age counts for integer, load, store-address, and store-data IQs.
- Producer-class dependency wait counts for ALU, load, branch, multiply, divide,
  store, CSR, and unknown producers.
- ALU dependency lifecycle and producer-location counts that distinguish
  same-cycle issue, producer not issued, producer blocked in IQ, producer ready
  but not selected, missing producer entry, and stale lifecycle states.
- Blocked ALU producer source-class counts, with both exclusive single-source
  versus multi-source attribution and overlapping missing-source class counts.
- Same-cycle wakeup candidates and missed same-cycle wakeup opportunities.
- ROB head-blocked younger-ready lost commit slots.
- LSU load latency, forwarding, retry, D-cache conflict, and store backlog
  counters.
- Branch mispredict and restore counters.

Use `tools/bottleneck_analysis.py` on the resulting `results.json` before
selecting any new performance RTL. Some counters are entry-slot or event
counts, not single-cycle buckets, so values can exceed 100% of timed cycles.

## Short-ALU/IQ0 Chaining Audit, 2026-05-09

Current run and repo state:

- No active DSim, XSim, `run_benchmarks.py`, or simulator rebuild process was
  present when this audit started.
- Commit `ccf213b` made the boolean/shift IQ0 short-chain RTL default-on.
  That was reverted by `57bfa58` so the working baseline is trackable again.
- The accepted baseline for comparison remains
  `signoff_signoff_20260508_loop_bypass_threshold2_goal` plus the later
  profiler-only commits. Baseline rows used here are Dhrystone 100 `18,577`,
  CoreMark 1 `163,013`, CoreMark 10 `1,500,110`,
  `frontend_mixed_branch_dense=7,220`,
  `backend_alu_chain_8=3,039`, and
  `hotspot_state_crc_branch=141,326`.

Latest short-chain evidence:

| Variant | Evidence artifact | Dhrystone 100 | CoreMark 1 | CoreMark 10 | Branch dense | ALU chain | Branch hotspot | Classification |
|---|---|---:|---:|---:|---:|---:|---:|---|
| Full simple-ALU chain | `20260509_iq0_short_alu_chain_smoke2`, `20260509_iq0_short_alu_chain_validation` | `18,575` | `160,429` | `1,485,336` | `7,326` | `3,035` | `141,237` | DSE-only evidence, rejected for branch-dense regression. |
| Idle-slot-only chain | `20260509_iq0_short_alu_chain_idle_smoke` | `18,576` | `163,297` | Not run | `7,385` | `3,038` | `141,237` | Rejected due CoreMark 1 and branch-dense regression. |
| Typed arithmetic plus logic chain | `20260509_iq0_typed_short_alu_chain_smoke` | `18,576` | `161,577` | Not run | `7,337` | `3,036` | `141,237` | Rejected due branch-dense regression. |
| Boolean/shift-only chain | `20260509_iq0_logic_shift_chain_smoke`, `20260509_iq0_logic_shift_chain_validation` | `18,577` | `161,582` | `1,483,858` | `7,128` | `3,039` | `141,326` | DSE-only evidence, quarantined, not promoted. |

Counter evidence for the best boolean/shift-only subvariant:

| Row | Baseline cycles | Trial cycles | Cycle delta | Relevant movement |
|---|---:|---:|---:|---|
| CoreMark 1 | `163,013` | `161,582` | `-1,431` | `xs_bottleneck_dep_wait_on_alu` drops from `1,370,358` to `1,229,167`; short-chain fires `2,913` times. |
| CoreMark 10 | `1,500,110` | `1,483,858` | `-16,252` | `xs_bottleneck_dep_wait_on_alu` drops from `13,495,221` to `12,066,640`; short-chain fires `28,109` times. |
| Frontend mixed branch dense | `7,220` | `7,128` | `-92` | Branch mispredicts drop from `426` to `414`; short-chain fires `68` times. |
| Dhrystone 100 | `18,577` | `18,577` | `0` | No active short-chain fires. |
| Backend ALU chain 8 | `3,039` | `3,039` | `0` | No active short-chain fires. |
| Branch hotspot | `141,326` | `141,326` | `0` | No active short-chain fires. |

Architectural audit verdict:

- There is no accepted architectural candidate from the local IQ0/short-ALU
  family today.
- The full simple-ALU, idle-slot-only, and typed variants are rejected because
  they introduce benchmark regressions. The regressions are most visible on
  branch-dense rows, so the mechanism is changing control timing rather than
  simply removing a backend bottleneck.
- The boolean/shift-only variant is endpoint-clean on the checked rows and
  gives useful counter evidence, but it is quarantined as DSE-only. It does not
  meet the new promotion bar: broad regression-free evidence, full signoff
  coverage, and a realistic multi-percent impact.
- Do not continue scalar short-chain threshold, op-list, or IQ0 priority
  tuning. A future scheduler/wakeup direction must be a broader structural
  redesign across issue queues, producer classes, and select policy, not a
  local IQ0 shortcut.

Next high-leverage architectural directions:

| Direction | Why it is still credible | Required proof before promotion |
|---|---|---|
| Branch recovery and checkpoint contract | CoreMark 10 still has `redirect_recovery=29,575`; the branch hotspot has high redirect and commit-zero pressure. A correct non-head recovery contract can remove useful-work loss across branchy code instead of shifting local ALU timing. | Backend checkpoint, RAT, free-list, ROB, writeback, LSU, and frontend-owner recovery invariants stay zero on strict rows; branch hotspot improves without Dhrystone/CoreMark regression. |
| True FTQ/IBuffer runahead | The frontend still reports `packet_empty_f2_data`, duplicate/no-emit, and frontend-zero buckets. Reference Core B-style split ownership can let prediction and fetch run ahead without duplicate suppression. | Split FTQ allocation, IFU, commit, and optional prefetch ownership; owner-aware IBuffer absorbs F2 hold; delivery scoreboard proves each PC reaches decode exactly once. |
| Broader scheduler/wakeup/select redesign | ALU dependency counters show true producer-chain depth, but local IQ0 chaining is too small. A real redesign should address producer blocking, wakeup fanout, select fairness, and cluster steering across integer IQs. | Multi-row reduction in `xs_bottleneck_dep_wait_on_alu`, producer-blocked counts, and IQ not-ready pressure with no branch/control regression and at least 3-5 percent broad upside. |
| Memory and load-use pipeline | Current Stage 2 work has mostly targeted frontend and integer ALU chains. A broader workload set will expose load-use, forwarding, retry, D-cache conflict, and store-backlog limits. | Full bottleneck run shows LSU or load-use counters dominate multiple rows; any load speculation or forwarding change includes replay correctness and no stale wakeup side effects. |

Detailed DSE execution plan:
`doc/stage2_bottleneck_dse_plan_2026-05-09.md`.

## Implementation Order

| Phase | Task | Exit criterion |
|---|---|---|
| 0 | Lock the accepted successor and rename backpressure slice. | Gate A candidate is trackable from source control and has final strict smoke plus CoreMark 10 evidence. |
| 1 | Lock the predicted-control-window same-owner advance and F2 fire contract. | Dhrystone 100, CoreMark 1, CoreMark 10, and branch hotspot pass strict checks from committed RTL. |
| 2 | Reconfirm from a clean committed checkout if needed. | Results match the accepted rows within normal determinism and no stale debug harness is required. |
| 3 | Re-attribute residual same-owner and F2-data bubbles with the corrected profiler. | CoreMark 10 reports no stale predicted-control bucket and names the dominant remaining no-emit/remainder/other causes. |
| 4 | Reopen owner queue only if the attribution shows distinct useful future targets. | Candidate count is large enough to move cycles, not merely strict-clean. |
| 5 | Lock backward-next-owner same-owner safety. | CoreMark 1, CoreMark 10, Dhrystone 300, Dhrystone 100, branch hotspot, and broad Stage 1 DSE rows pass strict checks. |
| 6 | Split the remaining same-owner remainder and no-emit buckets. | Done by `20260507_same_owner_remainder_attrib_coremark10`: remainder is consume/post-consume, no-emit is mainly frontend stall, redirect, and packet-ready. |
| 7 | Try post-consume remainder bypass variants. | Rejected: strict-clean but CoreMark 10 regresses from downstream packet pressure. |
| 8 | Re-attribute duplicate/no-emit and packet-buffer full cycles, then choose owner work scheduling, packet-buffer credit policy, or a second-domain backend drain limiter. | Done by `20260507_packet_pressure_attrib_coremark10`: packet full is not owner-wait, backend stall is ROB/PRF-correlated. |
| 9 | Record raw capacity and commit-bypass probes. | Done: PRF192 is a no-op, ROB-head bypass regresses CoreMark 1, and neither is the next accepted path. |
| 10 | Add BPU component attribution and try selective local-vs-SC arbitration. | Done and rejected in first form: endpoint-clean, but CoreMark regresses when branch hotspot improves. |
| 11 | Add dynamic branch-hot-PC attribution before reopening local arbitration. | The profiler captures the actual top PCs from arbitrary benchmark rows, including branch probes, and reports local/SC correctness by PC. |
| 12 | Try local same-owner remainder/straddle bubble removal. | Done and rejected in local form: frontend bubbles drop, but heavy CoreMark regresses from packet-buffer and backend drain pressure. |
| 13 | Open the downstream drain or useful-work-per-packet slice. | Done by `dse_20260508_issue_fusion_move_attrib_coremark10`: macro-fusion is low-frequency, move candidates are high-frequency, and issue pressure is operand-ready dominated. |
| 14 | Design and score alias-safe rename move elimination. | Done and rejected in standalone form: endpoint-clean and backend pressure drops, but CoreMark 1, CoreMark 10, and the branch hotspot regress. |
| 15 | Record global branch recovery probes. | Done: early redirect is rejected broadly; early plus partial recovery is mixed and only improves the branch hotspot. |
| 16 | Try first selective branch recovery filters. | Done and rejected: ROB-age early recovery is endpoint-clean but slower; direct non-head partial recovery times out from checkpoint/free-list contract breakage. |
| 17 | Redesign backend checkpoint recovery before non-head recovery. | Checkpoint, RAT, free-list, ROB, and same-cycle commit release semantics are branch-ordered; direct partial recovery passes DS/CoreMark/hotspot before any performance claim. |
| 18 | Reopen useful-work reduction only as a paired optimization. | Move elimination or another uop-reduction path is retried only after branch/recovery can absorb the timing change. |
| 19 | Record simple IBuffer packet coalescing as rejected. | Done: head-only and selected-owner adjacent coalescing are strict-clean but cycle-identical no-ops, so RTL was not kept. |
| 20 | Try real decode or rename decoupling before more packet production shortcuts. | Done and rejected in blind form: decoded queues are strict-clean but CoreMark 10 regresses. |
| 21 | Reopen downstream drain only with branch/control-aware policy. | Candidate lowers packet-full or backend-packet-ready stalls without increasing packet-empty, redirect recovery, or CoreMark 10 cycles. |
| 22 | Split duplicate/remainder residuals by owner/control context. | Done by `dse_dse_20260508_dup_reason_attrib_coremark10`: the no-owner duplicate residual has no safe no-control bucket, and is dominated by straddle/control context. |
| 23 | Try predicted-not-taken same-owner fall-through only if ownership evidence supports it. | Done and rejected in local forms: plain owner relaxation and live-snapshot repair both regress or fail. |
| 24 | Lock the loop-exit speculative-count bypass chooser and threshold-2 activation. | Dhrystone 100, CoreMark 1, CoreMark 10, Dhrystone 300, branch hotspot, and frontend branch broad rows pass strict checks, with loop-buffer and standalone replay activity zero. Current accepted artifact is `signoff_signoff_20260508_loop_bypass_threshold2_goal`; threshold-1 and sticky/no-decay variants are rejected or quarantined DSE-only evidence. |
| 25 | Probe IBuffer depth and control-aware packet buffering. | Done and rejected in current forms: blind depth 16 improves CoreMark 10 but regresses CoreMark 1; control/type/confidence watermarks either become no-ops or retain the short-row regression. |
| 26 | Resume from a structural bottleneck instead of loop threshold tuning. | Next RTL candidates come from branch ownership/recovery, control-aware packet buffering, downstream drain scheduling, or another counter-backed structural mechanism. |
| 27 | Add packet head-class attribution for downstream drain scheduling. | Done by `dse_20260508_packet_head_class_prof_smoke`: CoreMark 1 packet-full and backend-packet-ready stalls are mostly multi-instruction heads, often control-bearing, predicted-taken, or owner-complete. |
| 28 | Try first downstream-drain structural candidates. | Done and rejected: counted ROB admission improves CoreMark 1 but regresses CoreMark 10; counted admission plus larger ROB/PRF capacity also regresses CoreMark 10. RTL was restored to the committed threshold-2 baseline. |
| 29 | Resume from a higher-leverage structural path. | Next candidate should be branch ownership/recovery or useful-work reduction with explicit checkpoint/resource contracts, not raw capacity, packet merge, generic queueing, or loop-threshold tuning. |
| 30 | Add branch recovery contract checkers. | Done by `0d0b5ff`: DSim compiles the simulation-only checker, strict DS/CoreMark/branch smoke passes, and parser-compatible `xs_branch_recovery_*` counters are active. |
| 31 | Document and harden the non-head recovery contract. | Contract documented; checkpoint allocation invariants are checked. Behavior hardening is still pending before any non-head recovery performance claim. |
| 32 | Reopen direct non-head partial recovery without early redirect. | Current resource-aware selector is endpoint-clean on smoke but regresses; checkpoint ownership must be fixed before another performance claim. |
| 33 | Reopen selective early frontend redirect. | Branch hotspot improves without Dhrystone/CoreMark regression and without contract checker failures. |
| 34 | Add ALU producer lifecycle profiling. | Done by `dse_dse_alu_dep_lifecycle_profile_*`: CoreMark 10 shows 91.2% of ALU dependency waits are producers not yet issued, while post-issue and stale-ready buckets are zero. |
| 35 | Split not-issued ALU waits by producer IQ location. | Done by `dse_dse_alu_dep_producer_location_*`: CoreMark 10 shows 99.38% of not-issued ALU waits have the producer present but operand-blocked in an integer IQ. |
| 36 | Split operand-blocked ALU producers by their missing operand class. | Done by `dse_dse_alu_blocked_producer_srcclass_*`: CoreMark 10 shows 96.6% overlapping ALU-source blocking and 85.0% exclusive single-ALU blocking, so this is mostly true ALU dependency-chain depth. |
| 37 | Attribute ALU-chain op patterns before RTL. | Done by `dse_alu_chain_shape_profile_*`: CoreMark 10 shows boolean/W-op ALU chains dominate the blocked-producer wait path, while move candidates are a small subset. |
| 38 | Audit local IQ0 short-ALU chaining. | Done: full simple-ALU, idle-slot-only, and typed variants are rejected due regressions. Boolean/shift-only is DSE-only evidence and has been reverted from default RTL by `57bfa58`. |
| 39 | Select the next high-leverage structural direction from bottleneck evidence. | Candidate must have a plausible 3-5 percent broad upside, no unexplained benchmark regression, and a structural mechanism rather than scalar tuning. |
| 40 | Re-score against Reference Core A (large config) and stretch targets only after the structural slice passes broad evidence. | Gate E passes on broad coverage. |

## Explicit Non-Goals

- No loop buffer revival.
- No benchmark-PC steering.
- No standalone same-line, same-FTQ-tail, or sequential lookahead shortcut.
- No duplicate suppression as the final correctness mechanism.
- No widening decode, rename, or commit in this frontend slice.
- No active Reference Core B-style `pfPtr` until demand ownership is working.
- No raw load-speculation plusarg promotion without LSU dependency prediction
  and replay evidence.
- No local IQ0/short-ALU scalar tuning as the next promoted direction unless
  broader evidence shows regression-free, multi-percent impact.

## Verdict

The successor plus predicted-control-window plus backward-next-owner path,
weak-TAGE local arbitration, and loop-exit speculative-count bypass chooser
should be pursued. They are strict-clean on the scoreable smoke, CoreMark 10,
and broad Stage 1 DSE rows, they beat the calibrated Reference Core A (large config) smoke rows, and
they cut the dominant CoreMark 10 frontend-empty and branch-miss buckets while
lifting CoreMark 10 to 6.71 CM/MHz. The latest accepted row still has material
residual pressure: CoreMark 10 reports `packet_empty_f2_data=60,845`,
`packet_empty_noemit_dup=32,151`, `redirect_recovery=29,575`, and
`xs_backend_stall_pkt_ready=34,950`.

Near-term objective: keep this as the Stage 2 frontend baseline. The branch
recovery direction still has evidence, but the next branch RTL work is not
another early-redirect gate; it is a full backend checkpoint recovery contract
for non-head recovery. Global early recovery, ROB-age early recovery, direct
non-head partial recovery, and the simple checkpoint sequence-preserve trial
are rejected in the current backend contract. The latest duplicate attribution
also rejects local predicted-not-taken owner relaxation, including a live
snapshot repair. Any next frontend owner change must redesign the FTQ/IBuffer
branch-owner sequencing contract, not only the prediction-snapshot fields.
Scalar loop-bypass threshold and sticky/no-decay tuning is now quarantined as
overfit risk; the accepted loop-predictor line is the threshold-2 per-loop
exit-miss chooser with decay.
Local IQ0/short-ALU chaining is also not the next promoted direction. The
boolean/shift-only subvariant is useful DSE evidence, but the family is
currently too marginal and too close to benchmark-shaped policy tuning. The
next implementation should target a structural mechanism with realistic
multi-percent upside: branch recovery/checkpoint repair, true FTQ/IBuffer
runahead, broader scheduler/wakeup/select redesign, or memory/load-use
pipeline work selected by the full bottleneck counters.
Long-term objective remains 7.5 CM/MHz and 4.0 DMIPS/MHz, with a required
second-domain escalation if frontend-only work does not reach the Gate C
ceiling.

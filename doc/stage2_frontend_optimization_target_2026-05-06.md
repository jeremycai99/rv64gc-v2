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
  backpressure, plus predicted-control-window same-owner advance with F2 packet
  fire aligned to IFU stall, plus same-owner advance when the already allocated
  next FTQ owner is a backward target behind the current work PC.
- Rejected and removed: benchmark-window trace probes and previous unguarded
  successor variants.

Current scoreable rows:

| Workload | Source | mcycle | Metric | Status |
|---|---|---:|---:|---|
| Dhrystone 100 | `benchmark_results/dse_dse_20260508_local_tageweak_bias_smoke` | 18,913 | 3.076996 DMIPS/MHz | PASS |
| CoreMark 1 | `benchmark_results/dse_dse_20260508_local_tageweak_bias_smoke` | 164,364 | 6.427396 CoreMark/MHz | PASS |
| CoreMark 10 | `benchmark_results/dse_dse_20260508_local_tageweak_bias_coremark10` | 1,526,048 | 6.590663 CoreMark/MHz | PASS |
| Branch hotspot probe | `benchmark_results/dse_dse_20260508_local_tageweak_bias_smoke` | 141,326 | 1.108734 IPC | PASS |
| Dhrystone 300 | `benchmark_results/dse_dse_20260508_local_tageweak_bias_dhry300` | 54,926 | 3.132659 DMIPS/MHz | PASS |

Current gap to the Stage 2 stretch targets:

| Metric | Current row | Target | Required score uplift | Equivalent cycle reduction |
|---|---:|---:|---:|---:|
| CoreMark/MHz | 6.590663 | 7.5 | +13.8% | 12.1% |
| DMIPS/MHz | 3.132659 | 4.0 | +27.7% | 21.7% |

Current calibrated MegaBOOM comparison on shared smoke rows:

| Workload | MegaBOOM calibrated | rv64gc-v2 current | Current gap |
|---|---:|---:|---:|
| Dhrystone 100 | 23,814 cycles | 18,913 cycles | rv64gc-v2 20.6% faster |
| CoreMark 1 | 192,249 cycles | 164,364 cycles | rv64gc-v2 14.5% faster |

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
- The new row beats the calibrated MegaBOOM smoke baseline on the shared
  Dhrystone 100 and CoreMark 1 timing windows.
- The weak-TAGE gated local alternation filter is the latest accepted BPU
  arbitration step. It is intentionally narrow: local alternation can override
  only when TAGE is weak and the learned per-branch bias is not fully opposed.
  It improves CoreMark 1 and CoreMark 10 while keeping Dhrystone and the branch
  hotspot clean.
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
| Predicted-control-window same-owner advance plus F2 fire contract | Dhrystone 100 `19,611 -> 18,913`, CoreMark 1 `175,318 -> 169,049`, CoreMark 10 `1,642,655 -> 1,570,351`; branch hotspot improves `146,142 -> 141,408`. | Keep. This is an architectural cleanup: same-owner advance can cover packets up to the predicted control, but F2 `will_emit` must mean an accepted packet fire and must be blocked by IFU stall. |
| Backward-next-owner same-owner safety | CoreMark 1 `169,049 -> 164,550`, CoreMark 10 `1,570,351 -> 1,528,608`; Dhrystone 300 improves to `54,926`, while Dhrystone 100 and branch hotspot are unchanged. | Keep. A next FTQ owner whose start PC is behind the current work PC is a backward target, not a forward overlap hazard. Same-owner straight-line delivery can continue until the predicted-control packet without replaying the same F2 PC. |
| Weak-TAGE gated local alternation filter | Dhrystone 100 stays `18,913`, CoreMark 1 improves `164,550 -> 164,364`, CoreMark 10 improves `1,528,608 -> 1,526,048`, and branch hotspot improves `141,408 -> 141,326`. | Keep. This is a general BPU arbitration rule, not fixed-PC steering: local alternation may override only weak TAGE predictions and only when a per-branch bias table is not fully opposed. |

Current important counters from the accepted CoreMark 10 row, with the latest
profiling attribution from
`benchmark_results/dse_dse_20260508_local_tageweak_bias_coremark10`:

| Counter | Value | Meaning |
|---|---:|---|
| `xs_f2_owner_idx_mismatch` | 0 | F2 owner identity clean. |
| `xs_packet_stale_idx_mismatch` | 0 | Decode-facing packet owner clean. |
| `xs_packet_buffer_stale_owner` | 0 | No stale owner packet consumed. |
| `xs_ftq_occ_max` | 2 | Runahead exists but remains shallow. |
| `xs_packet_buf_occ_max` | 8 | IBuffer can hold packets on the heavy row. |
| `packet_buf_full_cycles` | 14,783 | The IBuffer is active enough to backpressure F2 on CoreMark 10. |
| `same_owner_advanced` | 351,972 | Same-owner cursor movement is now a major useful path. |
| `same_owner_block_pred_ctl` | 0 | The stale pre-window attribution remains gone. |
| `same_owner_block_no_emit` | 13,602 | Down from `45,436`; residual no-emit is smaller but still real. |
| `same_owner_block_rem` | 34,975 | Remainder and straddle policy is now the largest same-owner residual bucket. |
| `same_owner_block_rem_straddle` | 0 | The residual is not direct line-straddle blocking. |
| `same_owner_block_rem_consume` | 24,244 | Most remainder blocking is the consume-remainder phase. |
| `same_owner_block_rem_consumed` | 10,731 | A smaller but material post-consume hold remains. |
| `same_owner_block_other` | 39 | Down from `33,142`; backward next-owner blocking was the root cause of this bucket. |
| `same_owner_no_emit_fe_stall` | 6,110 | Largest residual same-owner no-emit sub-bucket. |
| `same_owner_no_emit_redirect` | 4,353 | Redirect recovery still overlaps useful same-owner candidate cycles. |
| `same_owner_no_emit_pkt_not_ready` | 2,441 | Packet buffer backpressure is visible but not dominant. |
| `same_owner_no_emit_dup` | 698 | Same-owner no-emit is no longer mainly duplicate suppression. |
| `packet_empty_noemit_dup` | 33,453 | Down from `63,848`; the duplicate replay tax remains about half the old value. |
| `packet_empty_f2_data` | 62,204 | Down from `92,059`; this counter means F2 had data but emitted no packet. |
| `xs_f2_data_wait` | 492 | True missing F2 data wait is tiny on this row. |
| `xs_f2_data_wait_icq_empty` | 492 | The true F2 wait is fully ICQ-empty in this run. |
| `packet_empty_wait_icresp` | 34,079 | Slightly down from the previous accepted row. |

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
| Disable loop speculative count | Dhrystone 100 is unchanged at `18,913`, while CoreMark 1 regresses `164,550 -> 176,523` and the branch hotspot regresses `141,408 -> 142,828`. | Rejected. The loop predictor's speculative count path is not the broad limiter; using committed counts increases frontend zero and redirect pressure on CoreMark. |
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

rv64gc-v2 is aligned in direction with the XiangShan/BOOM-style frontend split,
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
branch recovery. A real XiangShan/BOOM-style recovery path needs selective
checkpoint invalidation, preserving checkpoints older than the recovered branch
and squashing only the branch plus younger state. Do not retry non-head partial
recovery until that checkpoint ownership rule exists.

Follow-up, 2026-05-08, second trial: preserving older checkpoint slots with a
simple sequence tag is insufficient by itself. The timeout signature remains
identical, so the missing branch recovery contract likely also includes the
RAT/free-list restore snapshot boundary and same-cycle commit release handling.
Treat non-head branch recovery as a larger backend recovery redesign, not a
small checkpoint-file patch.

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
| C | Score frontend-only ceiling. | CoreMark now reaches 6.58 CM/MHz; the longer Dhrystone anchor reaches 3.13 DMIPS/MHz. Frontend-only work still has measurable residual before declaring the ceiling. |
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
| ROB/PRF capacity | Rejected in raw and combinational timing forms | CoreMark 10 has `rob_full=34,217` and slot-0 `stall_preg=33,177`, but PRF192 is cycle-identical, ROB-head bypass regresses CoreMark 1, and same-cycle free-list release forwarding trips a simulator iteration loop. | Reopen only with a registered allocation, free, or commit-drain mechanism, not raw depth or comb release-forwarding. |
| BPU local-vs-SC chooser | Accepted in weak-TAGE gated form | Dynamic BPU attribution showed forward state-machine branches where local alternation fought stronger non-local predictions. The accepted form improves CoreMark 10 and the smoke set without fixed-PC steering. | Keep local alternation narrow: it may override only weak TAGE and only when the per-PC bias is not fully opposed. Do not broaden local override without full smoke plus CoreMark 10 evidence. |
| Loop predictor speculative count policy | Rejected | `+NO_LOOP_SPEC_COUNT` is endpoint-clean but regresses CoreMark 1 and the branch hotspot. | Keep the speculative loop-count policy. Reopen loop prediction only with a new predictor contract, not by disabling speculative count. |
| Selective branch recovery/update timing | Blocked on checkpoint ownership | Global early recovery is rejected, but early plus partial recovery improves the branch hotspot by 2.0 percent and exposes useful recovery metadata. The direct non-head partial trial proves the current checkpoint manager cannot yet support general execute-time recovery. | First add selective checkpoint squash or an equivalent branch-order checkpoint ownership scheme. Without that, keep partial recovery head-only and do not promote early recovery. |
| Uop-count and fusion accounting | Evidence slice complete | The profiler separates macro-fusion from move elimination: macro-fusion is low-frequency, move candidates are high-frequency. | Continue with refcounted move elimination, not a broad fusion sweep. |
| Downstream packet drain / scheduling | Still open, simple packet coalescing and blind decode queues rejected | Accepted frontend work and rejected remainder/straddle trials all show that denser packet supply can exceed backend drain. Head-only and selected-owner IBuffer packet coalescing were strict-clean but cycle-identical no-ops. Blind decoded queues moved pressure but regressed CoreMark 10. | Next attempt needs branch/control-aware scheduling or a paired backend policy, not another packet merge or generic queue. Must reduce `xs_backend_stall_pkt_ready` or packet-buffer-full cycles without increasing `packet_empty`, redirect recovery, or DS/CoreMark cycles. |
| Predicted-not-taken owner fall-through | Rejected local forms | Attribution shows many duplicate cycles are same-line sequential, so this looked tempting. The local owner relaxation regressed Dhrystone and broke CoreMark/hotspot. A live-snapshot repair still timed out with owner/stale mismatches. | Reopen only with explicit branch-owner and FTQ/IBuffer sequencing semantics, not by relaxing `same_owner_continue` alone. |
| LSU/load-use or backend balance | Later candidate | Addresses non-frontend residuals. | Open after ROB/PRF capacity if backend stalls persist. |

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
| 24 | Re-score against MegaBOOM and stretch targets. | Gate E passes on broad coverage. |

## Explicit Non-Goals

- No loop buffer revival.
- No benchmark-PC steering.
- No standalone same-line, same-FTQ-tail, or sequential lookahead shortcut.
- No duplicate suppression as the final correctness mechanism.
- No widening decode, rename, or commit in this frontend slice.
- No active XiangShan-style `pfPtr` until demand ownership is working.
- No raw load-speculation plusarg promotion without LSU dependency prediction
  and replay evidence.

## Verdict

The successor plus predicted-control-window plus backward-next-owner path
should be pursued. It is strict-clean on the scoreable smoke, CoreMark 10, and
broad Stage 1 DSE rows, it beats the calibrated MegaBOOM smoke rows, and it
cuts the dominant CoreMark 10 frontend-empty buckets while lifting CoreMark 10
to 6.58 CM/MHz.

Near-term objective: keep this as the Stage 2 frontend baseline. The branch
recovery direction still has evidence, but the next branch RTL work is not
another early-redirect gate; it is a full backend checkpoint recovery contract
for non-head recovery. Global early recovery, ROB-age early recovery, direct
non-head partial recovery, and the simple checkpoint sequence-preserve trial
are rejected in the current backend contract. The latest duplicate attribution
also rejects local predicted-not-taken owner relaxation, including a live
snapshot repair. Any next frontend owner change must redesign the FTQ/IBuffer
branch-owner sequencing contract, not only the prediction-snapshot fields.
Long-term objective remains 7.5 CM/MHz and 4.0 DMIPS/MHz, with a required
second-domain escalation if frontend-only work does not reach the Gate C
ceiling.

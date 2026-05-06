# Stage 1 XiangShan-Style Frontend Refactor Plan, 2026-05-05

## Verdict

Stage 1 is open and not signed off. XiangShan should now be treated as the
primary high-performance RISC-V frontend reference, but the reusable target is
its frontend contract: prediction blocks, FTQ ownership, IFU/ICache request
lifetime, predecode validation, IBuffer delivery, and data-driven frontend
topdown counters. We should not copy XiangShan wholesale, widen the core just
to resemble it, or revive a benchmark-shaped loop buffer.

Current checkpoint, rebuilt and rerun on 2026-05-05 after removing the legacy
loop buffer from the active pipeline accounting:

| Artifact | Result |
|---|---|
| Build | `./build_dsim.sh > benchmark_results/remove_loop_buffer_pipeline_build_20260505.stdout 2>&1` passed |
| Signoff command | `python3 tools/run_benchmarks.py --runner dsim --run-class signoff --manifest tests/benchmarks/stage1_signoff.json --plusarg PERF_PROFILE --plusarg PERF_COUNTERS --plusarg STAT_DUMP --mechanism-name loop_buffer_removed_pipeline_accounting --run-id 20260505_loop_buffer_removed_accounting` |
| Dhrystone 300 | PASS, 76,738 timed cycles, 77,268 `mcycle`, 2.225046 DMIPS/MHz, checksum `24`, `flags=0`, legacy loop buffer active `0`, standalone decoded-op replay active `0` |
| CoreMark iter10 | PASS, 2,034,653 timed cycles, 2,045,171 `mcycle`, 4.914843 CM/MHz, checksum `64687`, `flags=0`, legacy loop buffer active `0`, standalone decoded-op replay active `0` |
| Stage 1 performance verdict | Not signed off. Dhrystone is still +5,955 cycles slower than the old clean loop-buffer row (`70,783`) and +17,040 cycles slower than MegaBOOM (`59,698`). CoreMark is still +184,613 cycles slower than the old clean loop-buffer row (`1,850,040`) and +198,838 cycles slower than MegaBOOM (`1,835,815`). |

## External Feedback Audit, 2026-05-05

The latest external evaluation is directionally correct: stop adding local
PC-steering patches in `fetch_unit.sv`, move ownership into the FTQ, then add
an owner-aware IBuffer and a delivery scoreboard before further performance
DSE. The measured check below confirms why this should be treated as a
structural plan rather than as another shortcut.

First validation slice: `ftq.sv` now has separate IFU-delivery and
commit/training heads (`ifu_ptr_r`, `commit_ptr_r`), with
`count_alloc_to_ifu` and `count_ifu_to_commit` exported for topdown/debug. The
fetch unit connects packet-buffer ownership checks to the commit head while F2
delivery uses the IFU head. This is the minimum XS-FE2 ownership split.

Validation artifact:
`benchmark_results/signoff_20260505_ftq_split_delivery/`.

| Row | Result |
|---|---|
| Build | `./build_dsim.sh > benchmark_results/stage1_ftq_split_behavior_build_20260505.stdout 2>&1` passed |
| Dhrystone 300 | PASS, 76,738 timed cycles, 77,268 `mcycle`, checksum `24`, `flags=0`, legacy loop buffer active `0`, standalone decoded-op replay active `0` |
| CoreMark iter10 | PASS, 2,034,653 timed cycles, 2,045,171 `mcycle`, checksum `64687`, `flags=0`, legacy loop buffer active `0`, standalone decoded-op replay active `0` |
| Counter read | CoreMark remains dominated by `packet_empty_noemit_dup=725222`, `packet_empty_f2_data=807324`, `dup_last_emit=783583`, `ftq_full_cycles=0`, `ftq_occ_max=1`, and `packet_buf_occ_max=1`. |
| Verdict | Functionally safe and architecture-aligned, but not performance-moving yet. The split FTQ heads are groundwork; the next lever is an owner-aware multi-entry IBuffer plus a delivery scoreboard. |

Second validation slice: `+FETCH_DELIVERY_CHECK` adds a bounded
decode-visible packet delivery diagnostic. It tracks the current FTQ owner,
expected next PC, owner switch before completion, and non-contiguous delivered
PCs. Because the current legal path still has remainder/control discontinuities
that need more precise modeling, the default checker is nonfatal; fatal mode is
reserved for `+FETCH_DELIVERY_STRICT` after those cases are modeled.

Validation artifacts:
`benchmark_results/debug_20260505_delivery_checker_dhry100_v6/` and
`benchmark_results/debug_20260505_delivery_checker_coremark/`.

| Row | Result |
|---|---|
| Build | `./build_dsim.sh > benchmark_results/stage1_delivery_checker_build6_20260505.stdout 2>&1` passed |
| Dhrystone 100 + checker | PASS, cycle-identical at 26,394 timed cycles / 26,913 `mcycle`; checker summary: owner switch before complete `0`, non-contiguous packet PCs `308` |
| CoreMark iter10 + checker | PASS, cycle-identical at 2,034,653 timed cycles / 2,045,171 `mcycle`; checksum `64687`, `flags=0`; checker summary: owner switch before complete `0`, non-contiguous packet PCs `28,839` |
| Verdict | Useful guardrail, not the full SVA yet. It proves checker instrumentation is non-perturbing and highlights how much of the current legal flow still depends on control/remainder discontinuity modeling before strict delivery assertions can become a hard gate. |

Adjusted feedback verdict:

1. **Accept with evidence:** FTQ must own multi-phase pointers. The safe run
   proves the split pointer scaffold can land without changing endpoint
   behavior. It does not by itself close the gap because the effective packet
   buffer is still one-deep.
2. **Accept as next performance lever:** add a real owner-aware IBuffer of
   complete packets keyed by FTQ index/epoch/tag. The current
   `packet_buf_occ_max=1` and large duplicate/no-emit bucket support this
   directly.
3. **Accept as a hard gate:** add a delivery scoreboard/SVA before more
   performance patches. The first diagnostic checker is now present and
   non-perturbing, but it is not yet the full strict SVA. The final invariant
   remains: every architecturally required PC owned by an allocated FTQ entry
   must reach decode exactly once before the commit/training head pops that
   owner, unless redirect flushes it. This would have caught the `crcu32`
   skipped-PC failures immediately once legal remainder/control discontinuities
   are modeled.
4. **Modify the revert instruction:** do not blindly revert to the old
   92,948-cycle Dhrystone / 2,272,228-cycle CoreMark baseline. The current
   endpoint-clean loop-buffer-free anchor is better and already passes the
   tightened harness. Cleanup should delete rejected lookahead/tail/UOC DSE
   scaffolding from `fetch_unit.sv` while preserving accepted general fixes,
   `FETCH_PACKET_BYPASS2`, predictor alias repair, BRU correctness repair, and
   the signoff harness gates.
5. **Keep in parallel:** the fresh CoreMark rebuild drift is a separate
   benchmark-image contract issue. The checked-in CoreMark image remains the
   apples-to-apples signoff image until ELF/HEX flags, `ITERATIONS`, symbol
   layout, and retire trace are reconciled.
6. **Defer:** UOPLIFE/per-uop attribution is useful after FTQ split plus
   IBuffer exists. It is lower leverage for choosing the direction because the
   current aggregate counters already identify duplicate/no-emit delivery churn
   as the dominant visible bucket.

The current endpoint-clean RTL contains a general loop-predictor alias repair:
the old direct-mapped 64-entry loop predictor aliases Dhrystone `strcpy` at
`0x8000200e` with another loop, while the current PC-index hash plus exit-only
loop override lets that loop retain confidence. This is accepted as useful DSE
evidence because it improves Dhrystone without benchmark-PC special casing, but
it is not enough for Stage 1 because CoreMark remains the dominant miss.

The source-side loop-buffer removal is explicit: `src/rtl/core/loop_buffer.sv`
is deleted, `rv64gc_core_top.sv` has no loop-buffer instance, and the testbench
no longer aliases UOC replay activity to the legacy loop-buffer counter. The
stage-1 manifest now requires both `require_loop_buffer_zero` and
`require_decoded_op_replay_zero`; the compatibility `Loop buffer active: 0`
line remains only as a parser-visible proof that the legacy path stayed absent.

Two latest probes are explicitly rejected. `+ENABLE_UOC +UOC_UNSAFE_STREAM`
reaches higher raw CoreMark IPC but exits with `TOHOST=3`, checksum `47732`,
`flags=1`, and nonzero replay activity. `+ENABLE_XS_SEQ_LOOKAHEAD` exits with
`TOHOST=3`, checksum `24727`, and `flags=1`. Neither can be used as signoff
evidence. They confirm the next RTL step must be a correctness-preserving
FTQ/IBuffer delivery scoreboard, not another local replay or lookahead shortcut.
The signoff harness now hard-rejects those rejected local lookahead/tail
shortcuts as well as standalone decoded-op replay, even when a plusarg allowlist
is supplied. It also requires the canonical `Standalone decoded-op replay
active:` telemetry label for scoreable rows; old `Decoded-op cache active:`
logs are stale replay evidence, not Stage 1 frontend-refactor evidence.

Current CoreMark topdown counters from the passing row identify the remaining
limiter: `packet_empty_noemit_dup=725222`, `dup_last_emit=783583`,
`ftq_empty_cycles=807119`, `packet_buf_empty_cycles=1990791`,
`ftq_full_cycles=0`, `packet_buf_full_cycles=0`, and
`backend_stall_pkt_ready=0`. The gap is a prediction-block delivery problem,
not decode width, FTQ capacity, I-cache wait, or backend pressure.

The older DSE history below is retained only as supporting evidence. Rows that
are faster but change endpoint identity remain rejected.

The best archived valid candidate after loop-buffer removal is an opt-in
bounded sequential lookahead slice. It is still only a diagnostic
XiangShan-style anchor: the frontend can request the next sequential line after
a delivered packet under strict FTQ/backpressure gating. This is a real
Dhrystone win and a large CoreMark improvement versus the safe no-handoff row,
but it is still not Stage 1 signoff because CoreMark remains slower than both
MegaBOOM and the previous clean loop-buffer baseline. After the later rejected
tail-carry and loop-tail DSEs were reverted, the current rebuilt source is
conservative again. The Dhrystone `+ENABLE_XS_SEQ_LOOKAHEAD` sanity row is
77,929 timed cycles, not the 68,934-cycle archived anchor. The current
CoreMark `+ENABLE_XS_SEQ_LOOKAHEAD` rerun is not signoff-valid: it reached
2,022,165 timed cycles but ended with `flags=1` and checksum `24510`. The
current safe no-seq fallback passes CoreMark at 2,135,092 cycles.

The latest request-time predictor-update DSE is also rejected and reverted. It
was valid (`flags=0`) but slower on both signoff workloads: Dhrystone 300
ended at 77,673 cycles and checked-in CoreMark iter10 ended at 2,182,234
cycles. CoreMark duplicate/no-emit cycles rose to 556,026 and redirect
recovery rose to 71,013 cycles. After reverting that slice, DSim rebuilds; the
accepted current fallback is the no-seq path, while bounded sequential
lookahead remains archived evidence until its current-source correctness issue
is fixed.

Follow-up attempts to localize the current-source CoreMark corruption are also
rejected. Gating sequential lookahead when the current packet contains
predecoded control still ended CoreMark with `flags=1`, checksum `847`, and
2,058,826 timed cycles. Making duplicate suppression FTQ-tag-aware preserved
Dhrystone but produced the exact same invalid CoreMark row as the current seq
path (`flags=1`, checksum `24510`, 2,022,165 cycles), so that RTL experiment
was reverted. The current accepted source therefore remains the no-seq
fallback; Stage 1 is still open.

The latest May 5 corruption check made the failure concrete. A safe-vs-seq
CoreMark iter3 committed-PC comparison first diverges in `crcu32` at sequence
180151: the safe stream commits `0x80003a10` (`srliw a0,a0,0x1`) while the
seq-lookahead stream jumps to `0x80003a14`. The surrounding loop is the
8-iteration CRC bit loop from `0x80003a06` through the backward branch at
`0x80003a24`. `+FETCH_DUP_TRACE` confirms the current seq path repeatedly
suppresses legitimate loop packets such as `pc=0x80003a06 last_next=0x80003a14`
and `pc=0x80003a0c last_next=0x80003a18` while the FTQ entry still advertises
the predicted control at offset 36 (`0x80003a24`). This is not a decode-width
issue and not a CoreMark image issue; it is an FTQ owner-lifetime and packet
delivery contract issue.

A first direct owner-lifetime patch was rejected and reverted. Holding a
predicted-control FTQ owner across same-line packets made Dhrystone pass at
79,150 timed cycles, but checked-in CoreMark iter10 stopped retiring at
`minstret=13287` and reached the 4M-cycle limit. The counters show why:
`packet_empty_ftq_full=3,989,342`, `xs_ftq_full_cycles=3,989,344`, and
`xs_ftq_occ_max=24`. The experiment proves the invariant is right but the
incremental patch is wrong; owner lifetime must be implemented with a real
prediction-block stream plus delivery/writeback/commit pointers, not by simply
holding the current FIFO head. After reverting, the restored safe default again
passes Dhrystone 300 at 78,827 cycles and CoreMark iter10 at 2,135,092 cycles
with `flags=0`; this is still +32.04% and +16.30% slower than the corrected
MegaBOOM rows, respectively.

The latest Stage 1 retry is also not a signoff. Disabling the weak-confidence
backward-conditional static bias exposed a real CoreMark control problem: the
hot backward-exit branch at `0x8000257c` dropped from 26,862 committed
mispredicts to 892, total CoreMark mispredicts dropped from 46,495 to 19,499,
and timed CoreMark improved from 2,135,092 to 2,028,590 cycles. However, the
row was produced as a cycle-focused DSE rather than a pre-declared bottleneck
hypothesis, so it is evidence only until reverified under the new methodology.
Combining that idea with same-FTQ tail delivery made Dhrystone pass at 70,127
cycles, but CoreMark ended with
`flags=1`, checksum `58624`, and 2,026,973 cycles. The RTL knob was removed;
the result remains DSE evidence only. Stage 1 still needs a checksum-invariant
BPU/FTQ/IBuffer fix, not a global static-bias shortcut.

Latest continuation checkpoint: Stage 1 remains open. The BRU fused-immediate
repair is accepted as a correctness cleanup because fused `slti/sltiu + beq/bne`
now carries the compare immediate separately from the branch offset and uses the
branch op to select the equality sense. It does not close Stage 1: the checked-in
CoreMark image still passes a short iter1 sanity at 207,348 timed cycles
(`flags=0`, checksum `59156`, loop-buffer activity zero), but fresh CoreMark
rebuilds from the current source produce different endpoint state on this core
(`flags=1`, checksum `28974` for the non-debug iter1 rebuild). Host-native
CoreMark on the same source computes the expected CRCs, so this is a local
benchmark-image/core execution contract blocker rather than a source-level
CoreMark CRC problem. The same-tail DSE after the BRU repair keeps Dhrystone 300
valid at 70,127 timed cycles, checksum `24`, but checked-in CoreMark iter10 ends
invalid at 2,026,973 cycles with `flags=1` and checksum `58624`; that row is
rejected.

| Workload | MegaBOOM timed | Old clean loop-buffer row | Current endpoint-clean source | Verdict |
|---|---:|---:|---:|---|
| Dhrystone 300 | 59,698 | 70,783 | 76,738 PASS | Blocking: endpoint-clean and loop-buffer-free, but still slower than both old loop buffer and MegaBOOM. |
| CoreMark iter10 checked-in | 1,835,815 | 1,850,040 | 2,034,653 PASS | Blocking: endpoint-clean and loop-buffer-free, but still +184,613 cycles slower than old loop buffer and +198,838 cycles slower than MegaBOOM. |

This does not beat the previous clean loop-buffer design. The result is
accepted only as a clean Stage 1 evidence anchor, not as Stage 1 signoff. A faster
`+DISABLE_SUBGROUP_SPLIT_OWNER_COND` variant reached 1,877,792 CoreMark
benchmark cycles, but it ended with `flags=1` and checksum `42077`; it is
rejected as invalid despite the cycle improvement.

Later same-FTQ tail-carry variants on top of bounded sequential lookahead are
also rejected. The best Dhrystone result in that family reached 65,344 timed
cycles, but every CoreMark iter10 variant either ended with `flags=1` or
stalled before the endpoint. The strict carry-owner run ended at 2,140,203
timed cycles with checksum `57556`, `flags=1`, and much worse
`packet_empty_noemit_dup` behavior. This confirms that same-owner tail carry is
not a signoff-safe substitute for a real FTQ-owned IBuffer/delivery contract.
After forcing tail carry back to opt-in, the rebuilt source passes a short
Dhrystone sanity run at 77,929 timed cycles, but that is only the conservative
post-rejection state. It does not reproduce the 68,934-cycle archived anchor
and it is not a Stage 1 performance baseline.

The May 5 guarded single-packet loop-tail same-line DSE is also rejected and
reverted. It recovered Dhrystone 300 to 66,221 timed cycles with `flags=0`, but
checked-in CoreMark iter10 ended with `flags=1`, checksum `29775`, and
2,078,791 timed cycles. This narrows the diagnosis: the Dhrystone loop-tail
delivery bubble is real, but a local same-line/tail shortcut still corrupts
CoreMark control/owner lifetime. Stage 1 should use this as evidence for a real
BPU/FTQ/IFU/IBuffer loop-exit and delivery contract, not as accepted RTL.

The previous near-match row depended on a benchmark-shaped plusarg cocktail
around the current loop buffer. That row remains useful DSE evidence, but it is
not an accepted architecture. Stage 1 now includes replacing or subsuming the
loop buffer with a general frontend delivery mechanism.

Late May 5 recalibration: the plan is now explicitly "scaled XiangShan
frontend" rather than "find a local packet handoff that recovers the loop
buffer." The local XiangShan/Kunminghu source shows a BPU, FTQ, ICache, IFU,
and IBuffer wired as separate units; its FTQ has separate BPU, prefetch, IFU,
IFU-writeback, and commit ownership pointers; and the default parameters expose
`FtqSize=64`, `BpRunAheadDistance=8`, and a 48-entry IBuffer. That is the
right class of design to emulate. The bounded same-line FTQ handoff DSE remains
rejected because CoreMark failed with `flags=1`. The bounded sequential
lookahead DSE is cleaner and useful, but it is still only a small slice of the
needed BPU/FTQ/IFU/IBuffer contract.

Refactor target after the XiangShan recalibration: use a XiangShan-style
decoupled frontend backbone as the Stage 1 architecture anchor. That means
fetch-block identity first, then BPU runahead, FTQ-owned metadata, IFU/ICache
fetch by FTQ entry, predecode/control validation, and IBuffer elasticity before
adding any UOP-cache layer. The decoded-op cache remains a possible
later layer, but it is no longer the first primitive to force into the design.

The immediate RTL pivot is concrete: stop optimizing the old tightly coupled
request/packet path as if a local PC-steering patch can become a modern
frontend. XiangShan's useful pattern is that an FTQ entry, not just a PC, owns
the predicted block through BPU prediction, IFU fetch, predecode writeback,
delivery, redirect, commit, and training. The latest trace tightens this
diagnosis: after the replay-guard repair, the Dhrystone hot loop still shows a
body packet, then a same-FTQ duplicate bubble, then the branch packet, then the
target body packet. Bounded sequential lookahead removes part of that cost, but
the CoreMark counters still show many same-line duplicate/no-emit cycles and a
large control-recovery tax. Stage 1 therefore needs a scaled XiangShan-style
BPU/FTQ/IFU/IBuffer contract, not another special-case loop replay path.

Stage 1 pass condition:

1. Recover the previous clean loop-buffer performance with a reusable frontend
   mechanism, not a loop-specific replay path or benchmark plusarg cocktail:
   Dhrystone 300 must beat `70,783` timed cycles and CoreMark iter10 must beat
   `1,850,040` timed cycles with loop-buffer activity zero.
2. Beat the corrected MegaBOOM timed rows on Dhrystone 300 and CoreMark iter10,
   with endpoint accounting unchanged and `flags=0`.
3. Keep total-cycle accounting close enough that any post-benchmark overhead is
   explained by measurement structure, not hidden performance loss.
4. Pass broader probes before the mechanism is called accepted Stage 1 RTL.
5. Preserve endpoint identity, not only the PASS bit: Dhrystone checksum `24`,
   CoreMark iter10 final checksum `64687`, `flags=0`, no `TOHOST=3`, and
   `loop_buffer_hold=0`.
6. Lock the benchmark image contract. A rebuilt image with different endpoint
   behavior is not a signoff replacement until the instruction/trace mismatch is
   root-caused and the image hash, ELF/HEX generation flags, checksum, and
   retire path are all recorded.
7. Pass the anti-overfitting rule: the accepted mechanism must be a reusable
   frontend structure, not a benchmark-PC special case, benchmark-image
   assumption, global static-direction shortcut, or workload-specific plusarg
   cocktail. DSE plusargs may expose opportunities, but a row remains
   non-signoff until the behavior is converted into a general BPU/FTQ/IFU/
   IBuffer mechanism and re-run on fixed images with endpoint identity intact.

Stage 2 remains the later stretch target of 7.5 CM/MHz and 4.0 DMIPS/MHz. It
should not start until Stage 1 closes the MegaBOOM baseline gap.

## Harness Updates 2026-05-05

The signoff harness was extended in commit-pending state (uncommitted in the
working tree as of 2026-05-05). New capabilities every Stage 1 iteration is
expected to use:

### Golden PC scoreboard (`src/tb/tb_top.sv`)

Two new plusargs gate a commit-aligned PC-stream check:

- `+EMIT_COMMIT_PC_HEX=<path>` — write every committed PC to `<path>` as one
  `$readmemh`-format hex line, in retire order. The TB emits
  `[GOLDEN_PC EMIT_DONE seq=N]` at run end.
- `+CHECK_GOLDEN_PCS=<path>` — load `<path>` at simulation start and assert
  every committed PC matches the next entry. On first divergence, the TB
  emits `[GOLDEN_PC TRIP cycle=N seq=S expected=PC actual=PC]` and
  `$finish(2)`. Clean completion emits `[GOLDEN_PC OK seq=N size=M]`.

Rationale: any RTL change that skips architectural work in tight loops (the
pattern that broke `crc16` / `crcu32` in the rejected DSEs) trips the check
within hundreds of cycles, instead of failing only at the 2M-cycle CoreMark
checksum. Use it on every iteration.

`tools/golden_pc_stream.py` is the operator interface:

```bash
./tools/golden_pc_stream.py emit \
    --bench-name dhrystone_300_stage1_anchor \
    --output tests/golden_pc/dhrystone_300_stage1_anchor.golden.hex
./tools/golden_pc_stream.py wire-manifest \
    --bench-name dhrystone_300_stage1_anchor \
    --golden tests/golden_pc/dhrystone_300_stage1_anchor.golden.hex
```

After `wire-manifest`, every signoff invocation auto-forwards
`+CHECK_GOLDEN_PCS=` and gates on the result.

### Counter invariants and Stage 1 targets (`tests/benchmarks/stage1_signoff.json`)

Two new schema fields per benchmark row:

- `counter_invariants` — `{name: {min/max}}`. Checked on every run
  (signoff and dse). Currently locks `xs_f2_owner_*_mismatch` and
  `xs_packet_stale_{epoch,tag}_mismatch` to zero — the FTQ-split structural
  invariants that all three signoff rows currently pass.
- `counter_targets_stage1` — `{name: {min/max}}`. Checked only on
  `--run-class signoff`. Currently empty pending Stage 1 RTL convergence;
  populate when the structural mechanism stack is in place. Suggested
  ranges in each row's `notes` field.

Both feed `evaluate_gate` in `tools/run_benchmarks.py`. A violation surfaces
as a gate reason and (on signoff) flips the row to `FAIL`.

### Image diff tool (`tools/image_diff.py`)

ELF-vs-ELF diff that triages fresh-rebuild divergence:

```bash
./tools/image_diff.py tests/coremark/coremark_iter10.elf /tmp/fresh.elf
```

Reports SHA256 fingerprints, ELF header diff, section sizes, symbol-map
diff, per-section content hash (.text / .data / .rodata / .sdata / .bss),
and disassembly first-divergence address. Use when the checked-in image
PASSes but a freshly built image fails endpoint identity.

### Drift guards (planned, not yet implemented)

The next harness commit will add structural enforcement of the FTQ-ownership
contract so any future mechanism (UOC, future stream-lookahead, future
trace cache, etc.) that delivers without an FTQ owner or drives request-PC
outside BPU is caught at the counter level, not just at the label level.
See decision-pending plan in handover prompt; the proposed counters are:

- `xs_packet_enq_no_ftq_owner_cycles`
- `xs_request_pc_non_bpu_drive_cycles`
- `xs_packet_enq_owner_mismatch_cycles`
- For UOC specifically: `xs_uoc_lookup_ftq_owned_cycles`,
  `xs_uoc_lookup_independent_cycles`, `xs_uoc_redirects_request_pc_cycles`,
  `xs_uoc_overrides_bpu_target_cycles`

Each will be added as `counter_invariants: { max: 0 }` after observation
confirms the safe baseline reads zero. This makes "loop buffer banished but
decoded-op cache is back with the same shape" a structural impossibility,
not a labeling decision.

## Stage 1 Closure Plan: BPU Decoupling

The post-FTQ-split baseline (`pre_alpha_baseline`, all 3 signoff rows PASS)
has `xs_ftq_occ_max=1` and `xs_packet_buf_occ_max=1` as **structural
properties** of the BPU/F1/F2 lockstep, not tunable parameters. Closing the
Stage 1 gap requires architectural decoupling of the predict path from the
emit path, equivalent to XiangShan's `BpRunAheadDistance` mechanism.

### Architectural findings the plan must respect

1. **F2 emit dynamics.** When `fe_stall` is high (initial fill, backend
   hold, packet_buf back-pressure), F2 holds `f2_pc_r`/`f2_data_valid`
   constant. `f2_has_emit_payload_c` stays asserted — without an
   external gate the same packet would emit every freeze cycle. The
   current `f2_last_emit_*` duplicate suppressor is the de-facto
   F2-freeze gate. Any RTL plan that "deletes the dup suppressor"
   without first installing a real F2-emit-vs-packet_buf-enq backpressure
   handshake is structurally wrong; the suppressor is load-bearing.

2. **FTQ allocation gates.** `ftq_need_alloc_c` blocks alloc when
   `req_pc_c == f2_pc_r` (F2 currently owns this PC) or
   `req_pc_c == ftq_last_alloc_req_pc_r` (just allocated for this PC).
   Both are correct dedup checks but couple FTQ alloc to F2 progress,
   producing ~1 alloc per F2 emit.

3. **Lockstep result.** BPU produces ~1 FTQ entry per F2 emit; F2
   consumes ~1 per cycle. FTQ stays at occ=0 or 1 in steady state.
   The 24-deep FTQ and 8-deep packet_buf are oversized for this regime.

4. **Counter telemetry.** `xs_dup_last_emit`, `xs_f2_owner_no_head`,
   and `xs_packet_empty_noemit_dup` are all in the 700-800k range on
   cm iter10 (~38% of the run). They are correlated symptoms of F2
   freeze + lockstep, not independent bottlenecks.

### Iteration order

Each iteration is gated by golden PC scoreboard, `counter_invariants`
zero-asserts, and a specific predicted counter movement. Iterations may
be reordered if data demands; the listed order is by leverage and risk.

#### α' — F2 emit backpressure handshake

**Goal.** Replace the implicit duplicate-suppressor F2-freeze gate with an
explicit packet_buf-enq-ready handshake: F2 emits only when the packet
buffer has space. F2-freeze becomes a structural property of "buffer is
backpressured", not "this PC was just emitted".

**Change.** `f2_will_emit_c` gates on `packet_buf_enq_ready` (currently
`packet_buf.enq_ready` exposed via top-level wire). The dup suppressor
state machinery stays for the moment as a redundant check (will be
removed in α' part 2 once the new gate is data-validated). Predicted
golden PC PASS because architectural commit stream is unchanged — the
same packets are emitted, just gated more cleanly.

**Predicted counter movement (cm iter10):**
- `xs_dup_last_emit`: 783k → near 0 (F2 freeze no longer triggers
  re-emit; suppressor never fires).
- `xs_packet_empty_noemit_dup`: 725k → similar (the bubble still
  exists, just attributed differently).
- `xs_packet_buf_occ_max`: still 1 (no producer change yet).
- timed cycles: ±2% (not the bottleneck-mover).

**Acceptance.** All 3 signoff rows PASS, `flags=0`, golden PC PASS, all
`counter_invariants` hold.

**Scope.** ~5–10 LOC in `fetch_unit.sv` (one expression change + comment).

#### α'' — Delete the dup suppressor

**Prerequisite.** α' has landed and passes a full signoff with
`xs_dup_last_emit` near zero, confirming the new backpressure handshake
fully replaces the suppressor.

**Change.** Delete `f2_last_emit_*` signal declarations, owner-match,
hit, reset, redirect-handler, and update logic. Delete
`xs_dup_last_emit_*`, `xs_dup_both_reasons_*` counters and their dump
lines. Keep `f2_replay_block_*` (the orthogonal replay-guard
ownership repair from prior session). Keep `xs_dup_replay_guard_*`.

**Predicted counter movement (cm iter10):**
- `xs_dup_last_emit`: removed from PERF_PROFILE.
- timed cycles: ±0.5% (cleanup, not a bottleneck-mover).

**Scope.** ~80 LOC delete in `fetch_unit.sv`. Half-day.

#### β' — Owner-tagged packets through fetch_packet_buffer

**Change.** Extend `fetch_packet_t` (in `rv64gc_pkg.sv`) with `ftq_idx`,
`ftq_epoch`, `ftq_alloc_tag`. `fetch_packet_buffer.sv` carries the
fields per entry; on flush, sweep entries with `epoch != current_epoch`
rather than wiping the whole buffer; on pop, validate epoch and silently
drop stale entries (advance rd_ptr, do not deliver). Decoupled from γ'
because owner-tagging is a prerequisite for runahead correctness — when
BPU runs ahead, packets in the buffer must carry their owner identity
to survive flush events.

**Predicted counter movement (cm iter10):**
- `xs_packet_stale_epoch_mismatch`: 0 → 0 (epoch filter must work
  correctly; non-zero is a regression).
- `xs_packet_buf_occ_max`: still 1 (no producer change yet).
- timed cycles: ±0.5%.

**Scope.** ~80 LOC across pkg, fetch_packet_buffer, fetch_unit. Half-day.

#### γ' — BPU runahead phase 1: decouple FTQ alloc from F2 progress

**Change.** Remove the `(req_pc_c == f2_pc_r)` and
`(req_pc_c == ftq_last_alloc_req_pc_r)` gates from `ftq_need_alloc_c`.
Replace with: alloc when BPU has predicted a new fetch block AND
`ftq_count_alloc_to_ifu < BP_RUNAHEAD_MAX` (parameter, default 8).
Wire `BP_RUNAHEAD_MAX` through `rv64gc_pkg.sv`.

This requires BPU to produce predicted PCs at its own rate, not gated
on F1 status. The BPU prediction state must therefore be decoupled
from `f1_pc`. Specifics depend on current BPU integration; expect
~150 LOC of fetch_unit + tage_sc_l reorganization.

**Predicted counter movement (cm iter10):**
- `xs_ftq_occ_max`: 1 → ≥ 4.
- `xs_ftq_occ_hist_4to7`: 0 → > 100k.
- `xs_packet_empty_wait_icresp`: 582 → ≤ 50.
- timed cycles cm: 2,034,653 → ≤ 1,950,000.

**Scope.** 1–2 days RTL, plus regression and golden PC validation.

#### γ'' — BPU runahead phase 2: ICache prefetch by FTQ entry

**Change.** Add a prefetch pointer to `ftq.sv` (between `bpu_alloc` and
`ifu_req`). ICache prefetch issues at the prefetch pointer. IFU
fetches at `ifu_req_ptr` (current). Prefetch pointer advances with
`PREFETCH_DISTANCE` parameter (default 4) ahead of `ifu_req_ptr`.

**Predicted counter movement (cm iter10):**
- `xs_packet_empty_wait_icresp`: ≤ 50 → ≤ 5.
- timed cycles cm: 1,950k → 1,850k (Stage 1 pass condition).

**Scope.** 1–2 days. Stage 1 pass attempt.

### Stop conditions

Adopt-and-stop after γ' if Stage 1 closes (cm < 1,850,040, dhry300 <
70,783). γ'' is the headroom layer for Stage 2.

If γ' leaves > 5% residual cm gap, dump per-PC mispredict and add a
loop predictor as δ' (Stage 2 starter).

If any iteration trips golden PC: STOP, do not pattern-match-fix; the
trip is the signal that the architectural assumption is wrong.

### 2026-05-05 progress checkpoint

| Iteration | Status | Result |
|---|---|---|
| α' (F2 emit backpressure on `!packet_buf_full`) | LANDED | PASS all 3 rows at baseline-identical numbers (dhry100 26913 mcycle / dhry300 77268 / cm10 2045171). No perf delta because `packet_buf_full` never asserts in the lockstep regime (`packet_buf_occ_max=1`); the change is structurally correct and is the prerequisite for the buf-fill regime that γ' will create. Mechanism class `default_rtl` retained because the change is a safety/correctness handshake, not an architectural mechanism on its own. |
| α'' (delete dup suppressor) | BLOCKED | Requires F2-data lifecycle change. `f2_data_valid` is combinational off `ic_resp_valid` (line 581 of fetch_unit.sv), not a register that clears on emit. A safe replacement mechanism (e.g., `f2_emitted_this_data_r` latch tracking ic_resp_valid edge) is structural cleanup, not a perf mover. Defer until the icache response queue (γ' phase 0) is in place. |
| β' (owner-tagged packets epoch-filter at decode pop) | PARTIALLY DONE | `fetch_packet_t` already carries `ftq_idx`/`ftq_epoch`/`ftq_alloc_tag` (lines 2453-2455 of fetch_unit.sv). Decode-pop epoch filter not yet wired. Functionally a no-op until γ' creates a regime with cross-epoch packets in flight. |
| γ' phase 0 (icache response queue) | DESIGN-PENDING | Newly identified prerequisite. The icache (`src/rtl/core/cache/icache.sv`) has a single request port and single response port (`req_valid`/`req_addr`/`resp_valid`/`resp_data`); F2's `f2_data_valid = ic_resp_valid` directly couples F2 to the icache's combinational response signal. For F1 to fire requests faster than F2 consumes data, an icache→F2 response queue must absorb the rate mismatch. Estimated scope: ~150-300 LOC for a new module + integration, plus careful handshake design (rate, depth, flush-on-redirect semantics, response-to-FTQ-entry mapping). 2-3 days. |
| γ' phase 1 (F1 advance decoupled from F2 consumption) | BLOCKED | Depends on γ' phase 0. The current F1 next-PC selection at lines 170-187 of fetch_unit.sv has the priority chain `redirect > f2_bpu_redirect > f2_duplicate_suppressed > (f2_seq_valid && f2_pc_consumed_c) > hold`. The lockstep is at the 4th term: `f2_seq_valid` is itself computed from F2's byte-consumption state, so removing the explicit `f2_pc_consumed_c` gate (tested 2026-05-05 as iter γ'-test-1) is a no-op — the lockstep is structural, not gate-removable. Replacing this term with an F1-stage BTB-derived next-PC (using `btb_hit`/`btb_target` available at line 652-653) would let F1 advance on its own prediction, but would also produce icache responses that F2 can't immediately consume; hence the queue requirement. |
| γ' phase 2 (FTQ alloc rate decoupled) | BLOCKED | Depends on γ' phase 1. The two FTQ alloc dedup gates (`req_pc_c != f2_pc_r` and `req_pc_c != ftq_last_alloc_req_pc_r` at lines 463-465) are correct given the current single-cycle-per-request stream; replacing them with `count_alloc_to_ifu < BP_RUNAHEAD_MAX` requires the F1 stream to actually produce distinct PCs faster than F2 pops them. |
| γ'' (ICache prefetch by FTQ entry) | BLOCKED | Depends on γ' phase 2. |

### γ' phase 0 infrastructure: icache_resp_queue.sv landed (2026-05-05, b97adb1)

The FIFO module that will decouple F2 consumption from F1 request rate
is now in master:

- `src/rtl/core/cache/icache_resp_queue.sv` (144 LOC, depth-parameterized,
  default 4)
- Each entry carries `(data, hit, pc, ftq_valid, ftq_idx, ftq_epoch,
  ftq_alloc_tag)` so F2 can consume in order with correct owner tracking
  even when F1 fires ahead
- `flush` clears all entries (used on backend redirect)
- `full`/`empty`/`count` status outputs for backpressure gating
- Compiles into dsim_work/tb_image.so (build rc=0); not yet wired

### Integration plan (to be done in a focused next iteration)

The wiring step changes the F2 data path from combinational ic_resp read
to queue-deq, and is bigger than a single in-session edit because it
requires coordinated retiming across F2's pc/btb/ftq tracking. Specific
edits:

1. `src/rtl/core/fetch/fetch_unit.sv`:
   - Add a 1-cycle pipeline register that captures the (request_pc,
     ftq_identity_at_request_time) when F1 fires `ic_req`. The register
     output is what the icache response 1 cycle later "is for".
   - Instantiate `icache_resp_queue` with the captured identity on enq
     side and the existing `ic_resp_valid_comb`/`ic_resp_data_comb`
     wires.
   - Replace `assign f2_data_valid = ic_resp_valid;` (line 581) with
     `assign f2_data_valid = queue.deq_valid_o;` Replace
     `f2_data_line = ic_resp_data` (line 582) with `queue.deq_data_o`.
   - Replace `f2_pc_r <= f1_pc` (line 1267, default case) with
     `f2_pc_r <= queue.deq_pc_o` so F2's PC tracks the queue head, not
     F1's live state. Similarly for `f2_ftq_*_r` — capture from
     queue's deq side, not from `ftq_enq_*`.
   - Drive `queue.deq_ready` from F2's consume-cycle gate: when F2 will
     emit, deq_ready = 1.
   - Drive `queue.flush` from `redirect_valid`.
   - Plumb backpressure: when `queue.full`, gate `ic_req_valid` so F1
     doesn't fire requests the queue can't hold.

2. After 1 lands and signoff PASSes (no behavioral change beyond the
   structural retime), THEN modify F1's next-PC selection to use
   F1-stage BTB prediction even when F2 hasn't emitted, achieving the
   actual runahead. Predicted counter movements (cm10, vs current
   pre_alpha_baseline):
   - `packet_empty_noemit_dup`: 725,222 → ≤ 100,000  (decrease ≥ 625k)
   - `xs_dup_last_emit`: 783,583 → ≤ 100,000
   - `xs_ftq_occ_max`: 1 → ≥ 4
   - `packet_empty`: 827,933 → ≤ 200,000
   - `timed cycles cm10`: 2,034,653 → ≤ 1,750,000 (Stage 1 close
     possible if predictions hold)

3. The harness-required signoff invocation (per
   feedback_perf_discipline.md and the rules at
   tools/run_benchmarks.py:1337-1396):
   ```bash
   python3 tools/run_benchmarks.py --runner dsim --run-class signoff \
     --manifest tests/benchmarks/stage1_signoff.json \
     --plusarg PERF_PROFILE --plusarg PERF_COUNTERS --plusarg STAT_DUMP \
     --mechanism-class ftq_owned_delivery \
     --mechanism-name f2_decoupled_via_icache_resp_queue \
     --baseline-results benchmark_results/signoff_pre_alpha_baseline/results.json \
     --targets-counter packet_empty \
     --expect-counter-decrease packet_empty:500000 \
     --run-id iter_gamma_phase0_queue_wired
   ```

The harness will reject the run if the predicted decrease did not
materialize, and the golden PC scoreboard will trip on first
architectural divergence. Both safety nets in place.

### γ'-test-1 result (2026-05-05)

Tested change: drop `f2_pc_consumed_c` gate from `next_pc` selection at
line 180 of fetch_unit.sv. Hypothesis: F1 sequential advance is held back
by the consumption check; allowing advance on `f2_seq_valid` alone would
let F1 fire ahead.

Result: PASS at byte-identical numbers (dhry100 26913 mcycle, all
counters identical including `xs_ftq_occ_max=1`, `xs_packet_buf_occ_max=1`,
`xs_dup_last_emit=8990`, `xs_ftq_alloc_cycles=17029`). The change was
functionally a no-op because `f2_seq_valid` is itself computed from F2's
byte-consumption state — the gate I removed was redundant, not the
throttle. Reverted; tree at 8b30714 + α' (no further RTL changes).

### Bottleneck verification (2026-05-05): 97% is bypass artifact, real bottleneck 41.5%

A previous reading of `xs_packet_buf_empty_cycles=1,990,791 (97.3%)`
suggested decode is starved 97% of cycles. Verification with
`tools/bottleneck_analysis.py` (committed at 5fd8577, updated to show
the bypass-corrected view) shows this is a metric artifact:

| Path | Cycles | % of run |
|---|---:|---:|
| Packet delivered via same-cycle bypass (`xs_bypass_valid`) | 1,142,874 | 55.9% |
| Packet delivered via buf occupancy | 54,380 | 2.7% |
| **Decode bubble (no packet delivered)** | **847,957** | **41.5%** |

True frontend supply rate: **58.5%**. The bypass path delivers a packet
to decode same-cycle without entering the buffer; `packet_buf_empty`
fires on those cycles too, inflating the empty-cycles counter. Real
bottleneck is the 41.5% decode-bubble row, which equals `packet_empty`
to within a cycle.

Of those 41.5% bubble cycles: ~35.5% (`packet_empty_noemit_dup=725,222`)
are F2 dup-suppressor firing because F2 holds same PC across consecutive
cycles. That's the BPU/F1/F2 lockstep.

### Heterogeneous design analysis (2026-05-05)

The "4-wide" pipeline is decode/rename/commit width. Other stages may
be wider or different. Key counter check on whether non-uniform widths
help:

| Counter | cm10 value | Implication |
|---|---:|---|
| `xs_backend_stall_cycles` | 0 | Backend never stalls supplying packet back-pressure |
| `xs_backend_stall_pkt_ready` | 0 | No back-pressure stalls when packet was ready |
| `commit_zero` (frontend probe) | 19.9% | Commit fires 80% of cycles |
| `frontend_zero` | 41.5% | Frontend supplies 58.5% of cycles (decode bubble dominant) |

Backend is NOT a bottleneck. Heterogeneous backend widening
(rename > 4, commit > 4, more ALUs/IQs) cannot help while frontend
delivers only 58.5% of cycles. Issue stage is already heterogeneous
(3 IQs × 1-2 select ports each = up to 5 issues/cycle into 4 ALUs +
1 BRU + LSU).

The only heterogeneity that would help today is **wider frontend supply**
(more packets/cycle to decode) — which requires fixing the lockstep,
not adding pipeline stages. The lockstep fix is structural per below.

### Why the simple "advance F1 on suppressor" fix is unsafe

A naive RTL change (when suppressor fires AND `last_emit_next == f1_pc`,
advance F1 to next-line in `f2_duplicate_next_pc_c`) fails architecturally.
F2's update logic captures `f1_pc` each cycle (`f2_pc_r <= f1_pc` at
fetch_unit.sv:1267). When F1 jumps ahead by a full line, F2 follows on
the next cycle, **skipping intermediate packets**:

```
T0: F2 at A0+0,  emit packet [A+0, A+4, A+8, A+12]. last_emit=A0.
T1: f1_pc=A0+16. f2_pc_r=A0+0 (captured f1(T0)). SUPPRESSOR.
    Old: case 3 → next_pc=A0+16=f1_pc. NO advance.
    Naive new: case 3 → next_pc=A0+64 (next line). F1 jumps.
T2: f1_pc=A0+64. f2_pc_r=A0+16. F2 emits A0+16.
T3: f1_pc=A0+72. f2_pc_r=A0+64. F2 emits A0+64. ← SKIPS A0+32, A0+48!
```

Architecturally wrong; golden PC will trip. The naive fix violates the
F2-tracks-F1 invariant. To safely break the lockstep, F2 must track its
own PC (sourced from FTQ entries with stored block_pc and predicted
control), not from `f1_pc` capture. That decoupling is the deep
refactor.

### Architectural conclusion

Stage 1 close requires γ' phase 0 (icache response queue) before any of
phase 1, phase 2, or γ'' can land safely. The harness is correctly
identifying this as a structural problem: every gate-removal experiment
in fetch_unit.sv that doesn't address the icache→F2 single-response
coupling is either a no-op (γ'-test-1) or trips golden PC (α as
originally specified). The architectural unlock is:

1. **icache response queue** (new module `src/rtl/core/cache/icache_resp_queue.sv` or extension of fetch_packet_buffer): FIFO of in-flight icache responses keyed by FTQ entry.
2. **F1 predicts next-PC from F1-stage BTB** (already available at line 652-653, currently consumed only at F2): use `btb_hit && btb_target` to drive F1 advance independent of F2.
3. **FTQ alloc decoupling**: replace `req_pc_c != f2_pc_r` and `req_pc_c != ftq_last_alloc_req_pc_r` with bounded runahead distance.
4. **F2 dequeue from response queue** (replacing direct `ic_resp_valid` read): F2 pops one entry per emit cycle, processes it.
5. **Owner mapping**: each queue entry carries the FTQ idx that requested it; F2 captures owner from queue entry, not from live BPU state.

This is the deliberate RTL effort. The harness (golden PC, counter
invariants, signoff manifest) is in place to gate it.

The harness is operating correctly: golden PC scoreboard caught the
α-as-originally-specified mistake instantly, counter_invariants hold
through the edit-revert-edit cycle, baseline identity preserved across
α' (numbers byte-for-byte identical). The next session can resume from
this state with confidence that any iteration's correctness is checked
mechanically.

Stage 1 should proceed as a measured pipeline debug loop, not as blind feature
DSE. Cycle-count-only sweeps are rejected methodology; every RTL change must
start from a bottleneck hypothesis that predicts which counter bucket will move:

1. Start from a passing baseline and record timed cycles, total cycles,
   `minstret`, checksum, and `flags`.
2. Reject any run with a MEMFILE load error before reading performance data.
3. Attribute the gap with frontend topdown counters before changing RTL:
   effective fetch width, packet-empty buckets, duplicate/no-emit cycles,
   redirect recovery, mispredicts, FTQ fullness, and I-cache wait.
4. Use `tools/summarize_perf_profile.py` on every `+PERF_PROFILE` row so
   endpoint status, frontend buckets, commit histograms, loop-buffer activity,
   and XS probe counters are summarized mechanically.
5. Use full or sampled `+TRACE_PIPELINE` plus `tools/pipeline_width_dse.py` at
   stage gates to separate fetch, decode, rename, dispatch, issue, and commit
   utilization. Do not compare cores by decode width alone.
6. Use short traces only to localize the dominant counter bucket to concrete
   PCs and owner-lifetime events.
7. Before changing RTL, write a bottleneck ledger row with: baseline artifact,
   named limiter, expected direction for `packet_empty`, `packet_empty_f2_data`,
   `packet_empty_noemit_dup`, `redirect_recovery`, frontend average/zero, and
   commit average/zero.
8. Make one scoped opt-in RTL change that targets that measured bucket.
9. Gate the change in this order: compile, short traced sanity, Dhrystone
   endpoint, CoreMark endpoint, then performance counters.
10. Accept only changes that preserve endpoint accounting and reduce the named
    bucket on the same benchmark image. Rejected rows stay as evidence but do
    not become architecture. A faster run is not accepted if the predicted
    counter did not move or if endpoint identity is weak.

The current dominant bucket is not decode width, I-cache miss, or raw FTQ
capacity. It is the owner/delivery discontinuity where F2 holds an already
emitted PC while F1/ICache/FTQ have the next predicted block, causing
duplicate/no-emit bubbles and empty packet delivery.

## May 5 Data-Driven Checkpoint

After the same-FTQ tail-delivery and bounded sequential-lookahead DSEs, the
next step must remain counter-driven. The recent rows show which ideas are real
and which were only tempting shortcuts:

| Row | Dhrystone 300 | CoreMark iter10 | Flags/status | Verdict |
|---|---:|---:|---|---|
| Previous clean loop-buffer baseline | 70,783 | 1,850,040 | `flags=0`, PASS | Historical performance bar only. Rejected as architecture because it depends on the discarded loop buffer. |
| Safe no-handoff, loop buffer removed | 78,827 | 2,135,092 | `flags=0`, PASS | Clean but too slow. |
| Current loop-predictor PC-hash, exit-only override | 76,738 | 2,034,653 | `flags=0`, PASS, loop buffer active `0` | Current endpoint-clean source after rebuild/recheck. Useful Dhrystone alias repair, but still slower than old loop buffer and MegaBOOM on both signoff workloads. |
| Same-FTQ tail delivery | 69,832 | 2,087,049 | `flags=0`, PASS | Keep as XS-FE1 anchor. It proves same-owner delivery continuity is useful, but CoreMark still misses signoff. |
| XS bounded sequential lookahead | 68,934 | 1,970,838 | `flags=0`, PASS | Best valid loop-buffer-free row so far. It proves bounded next-line runahead helps, but CoreMark is still +120,798 cycles versus the previous clean loop-buffer row. |
| Request-time FTQ predictor spec update | 77,673 | 2,182,234 | `flags=0`, PASS | Rejected and reverted. Moving speculative predictor update to FTQ allocation was valid but worsened both benchmarks; CoreMark duplicate/no-emit rose to 556,026 and redirect recovery to 71,013. |
| Current source plus bounded sequential lookahead | 77,929 | 2,022,165 | Dhrystone `flags=0`; CoreMark `flags=1`, checksum `24510` | Rejected as a current signoff knob. The archived seq row remains evidence, but current-source seq correctness must be repaired before it can be accepted. |
| Current-source sequential lookahead recheck | not rerun | 1,921,629 total `mcycle` | CoreMark `TOHOST=3`, checksum `24727`, `flags=1` | Rejected. Raw IPC improves, but endpoint identity fails. |
| Current-source UOC unsafe stream probe | not rerun | 1,898,258 total `mcycle` | CoreMark `TOHOST=3`, checksum `47732`, `flags=1`, replay activity nonzero | Rejected. The mop/uop cache path still is not a signoff-safe loop-buffer replacement. |
| Current-packet-control-gated sequential lookahead | 78,227 | 2,058,826 | Dhrystone `flags=0`; CoreMark `flags=1`, checksum `847` | Rejected and reverted. It proves the corruption is not only same-cycle current-packet control metadata. |
| FTQ-tag-aware duplicate suppression | 77,929 | 2,022,165 | Dhrystone `flags=0`; CoreMark `flags=1`, checksum `24510` | Rejected and reverted. It preserved the Dhrystone row but did not change the invalid CoreMark endpoint, so PC-only duplicate suppression was not the root cause. |
| Current seq divergence audit | n/a | iter3 debug only | safe first mismatch: `0x80003a10`; seq: `0x80003a14` | Confirms seq lookahead skips architectural work in the `crcu32` bit loop. `+FETCH_DUP_TRACE` shows stale owner/duplicate suppression around `0x80003a06` and `0x80003a0c` while the predicted control is still later at `0x80003a24`. |
| Simple predicted-control owner hold | 79,150 | timeout at 4M cycles | Dhrystone `flags=0`; CoreMark stuck at `minstret=13287` | Rejected and reverted. It validates the owner-lifetime hypothesis but fills the FTQ (`xs_ftq_full_cycles=3,989,344`) because the current FIFO has no split delivery/writeback/commit ownership. |
| Current safe no-seq source | latest no-seq Dhrystone row 78,827 | 2,135,092 | CoreMark `flags=0`, PASS | Passing fallback after rejecting the tail-carry, loop-tail, request-time spec-update, and current seq rows. Too slow for Stage 1 signoff. |
| XS-FE0 counter baseline | 78,827 | 2,135,092 | `flags=0`, PASS | Accepted as instrumentation only. It proves the new counters are non-perturbing, but it does not close the performance gap. |
| Disable weak-confidence backward-cond bias | 78,824 | 2,028,590 | Dhrystone `flags=0`; CoreMark `flags=0`, PASS, checksum `64687` | Evidence only. It identifies `0x8000257c` as a major backward-exit branch problem and cuts CoreMark mispredicts to 19,499, but it was a cycle-focused DSE without a pre-declared bottleneck ledger and does not beat the previous loop-buffer Dhrystone row. |
| Disable backward-cond bias plus same-FTQ tail carry | 70,127 | 2,026,973 | Dhrystone `flags=0`; CoreMark `flags=1`, checksum `58624` | Rejected. It keeps the Dhrystone win but corrupts CoreMark endpoint state; same-tail remains opt-in DSE evidence only. |
| Latest BRU fused-immediate repair | compile/pass sanity | checked-in iter1 sanity 207,348 | checked-in iter1 `flags=0`, checksum `59156`; fresh iter1 rebuild `flags=1`, checksum `28974` | Accept the BRU correctness fix, but do not count this as Stage 1 performance closure. Fresh CoreMark image generation is now a blocking contract to root-cause before using rebuilt images for signoff. |
| Latest same-tail after harness tightening | 70,123 | 2,012,612 | Dhrystone `flags=0`, checksum `24`, legacy LB `0`, standalone decoded-op replay `0`; CoreMark `TOHOST=3`, `flags=1`, checksum `23175`, legacy LB `0`, standalone decoded-op replay `0` | Rejected. The Dhrystone row is valid and loop-buffer-free, but CoreMark endpoint identity fails on the checked-in iter10 image. This is diagnostic evidence for prediction-block ownership, not a scoreable Stage 1 mechanism. |
| Same-tail plus incomplete-owner bypass | 69,823 | 2,016,577 | Dhrystone `flags=0`, checksum `24`, legacy LB `0`, standalone decoded-op replay `0`; CoreMark `TOHOST=3`, `flags=1`, checksum `23175`, legacy LB `0`, standalone decoded-op replay `0` | Rejected. Bypassing the incomplete-owner packet changes timing but not the CoreMark failure signature, so the issue is not FIFO-vs-bypass ordering. |
| Same-tail bounded commit trace | 250k-cycle trace only | first mismatch at commit sequence 153,905 | clean commits `0x80003a18/0x80003a1a/0x80003a1e`; same-tail jumps from `0x80003a14` to `0x80003a22` | Rejected with root cause. Same-tail skips architectural work in `crcu32`, so it must not be converted into Stage 1 RTL. Compact artifact: `benchmark_results/trace_20260505_same_tail_divergence/first_mismatch.txt`. |
| Latest fresh CoreMark rebuild audit | n/a | iter1 only | host-native source CRCs expected; rv64gc fresh image fails | The checked-in image remains the current apples-to-apples benchmark contract. Fresh image mismatch must be debugged with instruction/trace comparison before it can replace checked-in signoff images. |
| Same-FTQ tail bypass on top of bounded sequential lookahead | 68,934 | not run | Dhrystone `flags=0`, PASS | Rejected as a local latency tweak. It fired in the probe counter but did not move Dhrystone cycles, so it is not the Stage 1 lever. Keep it opt-in only. |
| XS bounded sequential lookahead plus no-owner-cond | 68,328 | 1,877,792 | Dhrystone `flags=0`; CoreMark `flags=1`, checksum `42077`, no PASS | Rejected. The performance gain is not usable because the CoreMark endpoint changes. |
| XS same-line lookahead, owner-cleared hardening | 66,228 | 2,092,355 | Dhrystone `flags=0`; CoreMark `flags=1`, checksum `45991` | Rejected. Dhrystone confirms the opportunity, but CoreMark trace shows skipped architectural PCs in `crc16`. |
| XS same-FTQ tail carry on bounded sequential lookahead | 65,344 best Dhrystone; 69,841 live-owner; 69,234 strict | 2,069,835 to 2,140,203 when it reaches endpoint | CoreMark `flags=1`; no-tail-bypass variants stall | Rejected. Broad carry duplicated `core_state_transition` packets with stale owners; live-owner and strict gating removed the first early duplicate but still corrupted CoreMark later or stalled. Keep tail carry opt-in only. |
| Guarded single-packet loop-tail same-line lookahead | 66,221 | 2,078,791 | Dhrystone `flags=0`; CoreMark `flags=1`, checksum `29775` | Rejected and reverted. A target-equals-packet-start guard exposes the Dhrystone opportunity, but CoreMark still corrupts endpoint state and raises stale-owner/no-emit churn. Use the row to justify real loop-exit prediction plus IBuffer ownership, not another local shortcut. |
| Packet-buffer stale-owner drop experiment | stopped after >770k Dhrystone cycles | not run | no endpoint | Rejected. Dropping stale-owner packets prevents wrong delivery but also drops architecturally required packets. The fix must repair FTQ/IBuffer lifetime, not silently discard. |
| Loop-spec-count catch-up | 69,832 | 2,088,224 | `flags=0`, PASS | Rejected and reverted. It slightly worsened CoreMark and did not move Dhrystone. |
| `+NO_LOOP_SPEC_COUNT` DSE | 71,312 | not run | `flags=0`, PASS | Rejected. Dhrystone regressed below the previous loop-buffer bar. |
| Safe straight-line UOC DSE | 77,019 | not run | Dhrystone `TOHOST=3`, checksum 19 | Rejected and reverted. Even non-control decoded-op replay corrupts endpoint behavior because source switching is not FTQ-owned yet. |
| Direct duplicate catch-up from live F1 | invalid Dhrystone run; missing MEMFILE | short trace only | no endpoint result | Rejected as an RTL direction. Same-cycle live predictor redirect creates a predictor-to-request feedback risk, while delaying redirect does not provide the stored target path needed to remove the real bubble. The missing-MEMFILE Dhrystone timeout is not counted as performance evidence. |
| XS aux-BTB/NLPB catch-up probe | 69,832 | 2,087,049 | `flags=0`, PASS | Observation-only. It proves the line-boundary bubble is measurable, but the recoverable simple-catch-up subset is too small to close Stage 1. Do not implement this as the primary performance path. |

CoreMark counter deltas explain why the valid bounded sequential-lookahead row
is not enough:

| Counter | Clean loop-buffer row | XS bounded seq-lookahead row | Read |
|---|---:|---:|---|
| Timed cycles | 1,850,040 | 1,970,838 | Remaining gap: +120,798 cycles. |
| Loop-buffer / UOC active cycles | 700,939 LB cycles | 0 | The old design was hiding a large delivery problem with loop replay. |
| Effective frontend zero cycles | 567,842 | 559,303 | Runahead reduces raw frontend-zero cycles below the old row, so the remaining gap is not just "more fetch". |
| `packet_empty_f2_data` | 455,444 | 440,750 | F2-data empty cycles are also below the old row; the next issue is packet ownership/control validity. |
| `packet_empty_noemit_dup` | 20,424 | 306,939 | Duplicate/no-emit delivery churn is still far above the old loop-buffer row. |
| Redirect recovery cycles | 12,273 | 51,851 | Control recovery remains expensive. |
| Mispredicts | 35,070 | 58,986 | The valid row still pays far more wrong-path/control cost than the old loop-buffer path. |
| `packet_empty_ftq_full` | 0 | 0 | The next fix should not be bigger FTQ capacity by itself. |
| `packet_empty_wait_icresp` | 24,980 | 612 | The next fix should not be I-cache miss tuning by itself. |

Mechanically generated summary for these rows:

```text
benchmark_results/20260505_xs_stage1_anchor/perf_profile_summary_xs_seq_no_owner.md
benchmark_results/20260505_xs_stage1_anchor/perf_profile_summary_stage1_open_latest.md
benchmark_results/20260505_xs_stage1_anchor/perf_profile_summary_tail_rejection.md
benchmark_results/20260505_xs_stage1_anchor/perf_profile_summary_current_default_off_sanity.md
benchmark_results/20260505_xs_stage1_anchor/perf_profile_summary_stage1_current_rejections.md
benchmark_results/20260505_xs_stage1_anchor/perf_profile_summary_reqspec_rejection.md
benchmark_results/20260505_xs_stage1_anchor/perf_profile_summary_stage1_post_cleanup.md
benchmark_results/20260505_xs_stage1_anchor/perf_profile_summary_xs_fe0_counters.md
benchmark_results/20260506_stage1_xs_anchor/coremark_iter10_current_safe_after_bias_knob.stdout
benchmark_results/20260506_stage1_xs_anchor/coremark_iter10_no_backward_bias.stdout
benchmark_results/20260506_stage1_xs_anchor/coremark_iter10_no_backward_bias_same_tail.stdout
benchmark_results/20260506_stage1_xs_anchor/dhrystone300_no_backward_bias.stdout
benchmark_results/20260506_stage1_xs_anchor/dhrystone300_no_backward_bias_same_tail.stdout
```

XS-FE0 completed the missing counter slice without changing endpoint behavior:

| Counter | Dhrystone 300 safe default | CoreMark iter10 safe default | Read |
|---|---:|---:|---|
| Timed cycles | 78,827 | 2,135,092 | Same as the pre-counter safe no-seq rows. |
| `ftq_occ_max` | 2 | 2 | Current frontend is effectively not using a deep prediction stream. |
| `ftq_full_cycles` | 0 | 0 | The gap is not raw FTQ capacity. |
| `ftq_empty_cycles` | 26,089 | 803,065 | The frontend often has no owned predicted block ready. |
| `packet_buf_occ_max` | 1 | 1 | Current packet delivery is still effectively one-deep, not an IBuffer. |
| `packet_buf_full_cycles` | 0 | 0 | The gap is not packet-buffer capacity either. |
| `packet_empty_noemit_dup` | 24,480 | 694,255 | Duplicate/no-emit remains the dominant visible bubble in CoreMark. |
| `dup_last_emit` / `dup_replay_guard` | 25,998 / 0 | 752,950 / 0 | Duplicate suppression is almost entirely last-emitted-PC churn, not replay-guard blocking. |
| `f2_owner_no_head` | 25,762 | 756,569 | F2 often holds data while the FTQ head has drained, confirming an owner-lifetime/runahead split problem. |
| `bypass_owner_miss` / `bypass_incomplete_owner` | 907 / 309 | 28,751 / 24,278 | Some immediate delivery opportunities are blocked by owner mismatch or incomplete-owner state. |
| `backend_stall_pkt_ready` | 0 | 0 | Decode/rename backpressure is not the current limiter. |

XS-FE0 verdict: Stage 1 is still open. The safe default is correct but too
slow; the next accepted RTL direction must make BPU runahead, FTQ ownership,
IFU writeback, and IBuffer delivery real instead of adding another local
PC-steering shortcut.

Cleanup note: duplicate DSim side logs and raw trace dumps larger than 50 MB
were pruned after their endpoint rows and aggregate counts were promoted into
this document and generated summaries. The Stage 1 anchor directory now keeps
small endpoint/build logs, the 300-iteration Dhrystone image, and markdown
summaries only.

May 5 cleanup refresh: after the rejected predicted-control owner-hold patch
was reverted, DSim was rebuilt and the safe default was rerun in
`benchmark_results/20260505_stage1_xs_anchor_finish/`. The restored rows match
the accepted fallback exactly: Dhrystone 300 `78,827` timed cycles, CoreMark
iter10 `2,135,092` timed cycles, both `flags=0`, PASS, and loop-buffer activity
zero. The rejected owner-hold stdout is kept only as small negative evidence;
raw CPC and duplicate-trace logs were removed after the divergence facts above
were promoted here.

The invalid no-owner row is useful negative evidence: removing owner-condition
gating cuts CoreMark cycles and mispredicts, but changes the endpoint. That
means owner metadata is a correctness boundary, not just a conservative
performance throttle. The next valid design has to keep owner identity while
making the delivery path more elastic.

May 5 follow-up: the same-line lookahead family remains rejected after a deeper
trace audit. The best-looking same-line row reached 66,228 Dhrystone cycles with
loop-buffer activity zero, but CoreMark completed with `flags=1`, checksum
`45991`, and 2,092,355 timed cycles. A later packet-buffer owner-gating attempt
prevented stale-owner packets from reaching decode, but Dhrystone then failed to
reach the endpoint and was stopped after it was already past 770k cycles and
560k retired instructions. That row is rejected as a timeout/stuck-path
diagnostic, not as performance evidence.

The useful finding is architectural: the invalid CoreMark trace first diverges
in the `crc16` loop after a taken branch at `0x80003aaa` back to
`0x80003a8c`. The bad row commits `0x80003a8c` and then jumps to
`0x80003a9a`, skipping `0x80003a90`, `0x80003a92`, and `0x80003a96`.
`+FETCH_DUP_TRACE` shows the frontend had a valid four-slot packet containing
those PCs, but also exposed stale packet-buffer/FTQ owner cases such as a packet
with tag `20196` being delivered while the FTQ head had already advanced to tag
`20197`. Dropping stale packets is not correct because some of those packets are
architecturally required; the real fix is to split FTQ allocation, IFU request,
predecode writeback, packet/IBuffer delivery, and FTQ completion so an owner
cannot be popped before every architecturally required packet for that owner has
been delivered or explicitly flushed.

Duplicate/no-emit attribution checkpoint:

An opt-in duplicate trace was added with `+FETCH_DUP_TRACE` after discovering
that `+TRACE_FETCH_DUP` also enabled the older `+TRACE_FETCH` path by prefix
matching. The compact trace run completed with `flags=0`, checksum `37896`,
`mcycle=2,097,471`, and `minstret=3,197,647`, matching the measured same-FTQ
tail row above. It emitted 577,240 duplicate-suppressed F2 payload events. That
trace count is larger than `packet_empty_noemit_dup=473,981` because the trace
records every duplicate suppression, while the performance bucket only counts
cycles where rename sees an empty packet output. The `fetch_out=0` subset is
482,572 events, which is the comparable bucket.

Artifacts:

```text
benchmark_results/20260505_xs_stage1_anchor/build_fetch_dup_trace_compact.stdout
raw `coremark_iter10_same_ftq_tail_fetch_dup_trace.stdout` pruned after summary promotion
```

| Attribute from compact trace | Count | Share of duplicate samples | Read |
|---|---:|---:|---|
| `replay_hit=0` | 577,240 | 100.00% | The dominant bucket is not the replay-block guard; it is last-emitted-PC duplicate suppression. |
| `ftq_cnt=0` | 514,563 | 89.14% | Duplicate bubbles mostly appear after the FTQ stream drains, so this is an owner/continuation timing problem. |
| `pkt_v=0` | 482,572 | 83.60% | Rename often has no buffered packet while F2 is still holding an already emitted PC. |
| `pred_v=1` | 361,386 | 62.61% | Many duplicates are still tied to predicted blocks, not only unpredicted straight-line fallthrough. |
| `pd_v=1` | 324,924 | 56.29% | Predecode frequently sees control metadata while delivery cannot hand off a fresh packet. |
| `bp_taken=1` | 38,471 | 6.66% | The duplicate bubble itself is usually not a newly taken BPU redirect cycle. |
| `straddle=1` / `rem_v=1` | 31,302 | 5.42% | RVC/line straddles are visible but not the primary cause. |

Top duplicate PCs/functions from the same compact trace:

| Rank | PC / next PC | Count | Function | Local code shape |
|---:|---|---:|---|---|
| 1 | `0x8000243e -> 0x80002440` | 87,122 | `core_bench_list` | Linked-list relink loop around `mv s0,a4; ld/sd; bnez`. |
| 2 | `0x80003b08 -> 0x80003b12` | 26,486 | `crc16` | Tight CRC shift/xor loop body before loop branch. |
| 3 | `0x8000242c -> 0x80002436` | 25,303 | `core_bench_list` | Linked-list search loop. |
| 4 | `0x80003700 -> 0x80003710` | 14,703 | `core_state_transition` | Byte-parser branch ladder. |
| 5 | `0x80003a4c -> 0x80003a56` | 13,846 | `crcu32` | Tight CRC shift/xor loop body. |
| 6 | `0x800036e8 -> 0x800036f2` | 13,750 | `core_state_transition` | Digit-scan loop. |
| 7 | `0x800036f2 -> 0x800036fc` | 13,749 | `core_state_transition` | Adjacent digit-scan branch group. |
| 8 | `0x800036b4 -> 0x800036bc` | 13,546 | `core_state_transition` | State-parser branch group. |

Function-level rollup of duplicate samples: `core_state_transition` 209,366
(36.27%), `core_bench_list` 130,430 (22.60%), `matrix_test` 50,935 (8.82%),
`crc16` 49,100 (8.51%), `crcu32` 32,269 (5.59%), and
`core_list_mergesort` 30,987 (5.37%). This is not a single loop-buffer-like
microbenchmark artifact. The duplicates span linked-list pointer chasing, CRC
inner loops, state parser control, and matrix code.

### XS Aux-BTB/NLPB Catch-Up Probe

The next experiment was intentionally measurement-only.  An independent BTB
lookup and auxiliary next-line-prefetch-buffer lookup observe the current F1 PC
while the main frontend request can remain owned by the normal path.  The probe
asks a narrow question: how many duplicate/no-output bubbles could be removed
by delivering the F1 line from the existing NLPB and steering the next request
with an independent F1 prediction?

Artifacts:

```text
benchmark_results/20260505_xs_stage1_anchor/build_xs_catchup_probe.stdout
benchmark_results/20260505_xs_stage1_anchor/coremark_iter10_trace_xs_catchup_12k.stdout
benchmark_results/20260505_xs_stage1_anchor/coremark_iter10_xs_catchup_probe.stdout
benchmark_results/20260505_xs_stage1_anchor/dhrystone_300_xs_catchup_probe_validhex.stdout
```

Endpoint check:

| Workload | Timed cycles | Timed instret | Checksum | Flags/status |
|---|---:|---:|---:|---|
| Dhrystone 300 | 69,832 | 149,739 | 24 | `flags=0`, PASS |
| CoreMark iter10 | 2,087,049 | 3,183,873 | 37,896 | `flags=0`, PASS |

Probe result:

| Probe counter | Dhrystone 300 | CoreMark iter10 | Read |
|---|---:|---:|---|
| Base duplicate cycles | 14,821 | 473,981 | Matches the dominant `packet_empty_noemit_dup` bucket. |
| Base cross-line cycles | 916 | 164,044 | Cross-line handoff is significant on CoreMark. |
| Base with NLPB aux hit | 637 | 37,079 | The existing NLPB has data for only a small subset of the duplicate bubbles. |
| Base with aux taken prediction | 9,904 | 266,546 | Prediction metadata is often available; data/ownership is the limiting side. |
| Recoverable cross-line cycles | 2 | 21,855 | Upper bound for the simple catch-up path before correctness overhead. |
| Recoverable target=last PC | 0 | 12,279 | `0x80002440 -> 0x8000243e` is real but not enough by itself. |

The 12k trace confirmed the motivating hot-loop pattern: at `0x80002440`,
F1 has the line-boundary packet, the auxiliary BTB predicts the backward target
`0x8000243e`, and the NLPB sometimes has the line.  The full CoreMark run then
puts the upper bound in context: even a perfect one-cycle recovery for every
currently recoverable cross-line sample would save at most 21,855 cycles,
leaving about 215k cycles of the 237,009-cycle gap to the old clean loop-buffer
row.  Dhrystone has only two recoverable samples.

Verdict: reject the simple aux-BTB/NLPB catch-up as the primary Stage 1
mechanism.  It is useful instrumentation and may become one source inside a
real IFU/IBuffer, but it cannot be the loop-buffer replacement.  The data points
to missing owner-aware storage and delivery: the frontend often has prediction
metadata, but not a durable predicted-block data/packet owner that can feed
decode without reusing F2 or relying on a narrow next-line buffer hit.

Data-driven verdict:

1. Keep XS-FE1 same-FTQ tail delivery and the valid bounded sequential
   lookahead as partial architectural anchors, not as Stage 1 signoff.
2. Do not continue local same-line shortcuts, loop-count tweaks, or standalone
   decoded-op replay. The measured rows reject them.
3. The trace names the current owner-lifetime failure more tightly:
   last-emitted-PC duplicate suppression is masking repeated F2 PC hold after an
   already delivered packet, usually with an empty FTQ head and no packet buffer
   output. This points to the frontend lacking an elastic, owner-aware
   continuation queue, not to I-cache wait, raw FTQ depth, or the replay guard.
4. The direct duplicate-catch-up DSE shows that the next block should not be
   borrowed from live F1 combinationally. If the packet is allowed to redirect
   in the same cycle, prediction can feed request PC and create a feedback
   path. If redirect is delayed, it does not provide the stored target-path
   delivery that the measured hot loop needs. The replacement therefore needs
   stored predicted-path metadata owned by an FTQ/IBuffer or UOP-cache entry.
5. The aux-BTB/NLPB probe narrows the next RTL target: a simple line-boundary
   catch-up can explain only 21,855 CoreMark cycles and two Dhrystone cycles.
   The replacement must therefore store and deliver predicted blocks through an
   owner-aware IFU/IBuffer path, not just borrow the current F1 line.
6. The next RTL target should be XS-FE2/XS-FE3: split FTQ delivery/writeback
   lifetime and make the packet buffer an owner-aware IBuffer-equivalent before
   attempting any decoded-op cache source switching. The accepted mechanism must
   reduce `packet_empty_noemit_dup`, `packet_empty_f2_data`, and redirect
   recovery on the same checked CoreMark image without changing endpoint
   accounting.

Direct duplicate-catch-up artifacts:

```text
benchmark_results/20260505_xs_stage1_anchor/build_dup_catchup_packet.stdout
benchmark_results/20260505_xs_stage1_anchor/coremark_iter10_trace_fetch_12k_dup_catchup.stdout
benchmark_results/20260505_xs_stage1_anchor/dhrystone_300_dup_catchup_packet.stdout
```

Note: `dhrystone_300_dup_catchup_packet.stdout` used the missing
`tests/hex/dhrystone_300.hex` path and is retained only as a run-hygiene
warning. The valid post-cleanout confirmations are:

```text
benchmark_results/20260505_xs_stage1_anchor/dhrystone_300_after_dup_catchup_cleanout_validhex.stdout
benchmark_results/20260505_xs_stage1_anchor/coremark_iter10_after_dup_catchup_cleanout.stdout
```

## Previous Clean Loop-Buffer Baseline

| Workload | MegaBOOM | Clean rv64gc-v2 | Delta | Verdict |
|---|---:|---:|---:|---|
| Dhrystone 300 timed window | 59,698 cycles | 70,783 cycles | +11,085 (+18.57%) | Blocking Stage 1 gap. |
| Dhrystone 300 total run | 59,698 cycles | 71,287 cycles | +11,589 (+19.41%) | Blocking Stage 1 gap. |
| CoreMark iter10 timed window | 1,835,815 cycles | 1,850,040 cycles | +14,225 (+0.77%) | Near parity, not a win. |
| CoreMark iter10 total run | 1,835,815 cycles | 1,860,512 cycles | +24,697 (+1.35%) | Near parity, not a win. |

Score equivalents at 1 MHz:

| Workload | MegaBOOM score | Clean rv64gc-v2 timed score | Clean rv64gc-v2 total-cycle score |
|---|---:|---:|---:|
| Dhrystone 300 | 2.860 DMIPS/MHz | 2.412 DMIPS/MHz | 2.395 DMIPS/MHz |
| CoreMark iter10 | 5.447 CM/MHz | 5.405 CM/MHz | 5.375 CM/MHz |

This was the last clean baseline before removing the loop buffer. It remains
the near-term performance reference that the replacement must recover and then
beat with a reusable design.

## UOP-cache Refactor Attempt

An initial UOP-cache-style refactor removed the `loop_buffer` RTL from the
compiled design and replaced the rename-input replay path with default-on
PC-indexed decoded-op streaming from `uop_cache.sv`.

Result: rejected for signoff.

| Workload | Row | Timed cycles | Total cycles | Timed instret | Flags/status | Verdict |
|---|---|---:|---:|---:|---|---|
| Dhrystone 300 | Loop buffer removed, UOP cache disabled with `+DISABLE_UOC` | 92,948 | 93,560 | 149,739 | `flags=0`, PASS | Removing the loop buffer alone regresses clean baseline by +31.31%. |
| Dhrystone 300 | Naive streaming UOP cache default-on | 103,308 | 103,862 | 152,136 | `flags=0`, PASS | Worse than no UOP cache; committed mispredict flushes jump to 5,412. |
| CoreMark iter10 | Naive streaming UOP cache default-on | n/a | n/a | n/a | DSim `IterLimit` around 107k cycles | Functionally unsafe for signoff; repeated benchmark-start writes before completion. |

Artifacts:

```text
benchmark_results/20260504_cleanup_recalibration/build_mopcache.stdout
benchmark_results/20260504_cleanup_recalibration/dhrystone_300_no_mopcache.stdout
benchmark_results/20260504_cleanup_recalibration/dhrystone_300_mopcache.stdout
benchmark_results/20260504_cleanup_recalibration/coremark_iter10_mopcache.stdout
```

Interpretation: a UOP cache cannot simply replay cached branch outcomes.
The removed loop buffer was also hiding loop-exit/control-flow cost. A viable
replacement needs the decoded-op cache to integrate live branch validation,
exit prediction metadata, or a fetch/FTQ-owned branch-prediction replay
contract. Otherwise it trades frontend delivery for many more backend flushes.

## May 5 Raw FTQ-Only Anchor

The initial loop-buffer-removed anchor kept standalone decoded-op replay behind
an explicit unsafe research knob:

```text
+ENABLE_UOC +UOC_UNSAFE_STREAM
```

Fetch-packet empty bypass started as the `+FETCH_PACKET_BYPASS2` DSE knob and
is now kept default-on as a narrow IBuffer-like stabilization because it is
functionally clean in the no-handoff rows. It is not the Stage 1 architecture
by itself; it only removes one local enqueue/dequeue bubble.

Raw FTQ-only measurements:

| Workload | Artifact | Timed cycles | Total cycles | Timed instret | Final `minstret` | Flags/status | Notes |
|---|---|---:|---:|---:|---:|---|---|
| Dhrystone 300 | `benchmark_results/20260505_xs_frontend_anchor/dhrystone_300_final_safe_defaults.stdout` | 92,948 | 93,560 | 149,739 | 150,406 | `flags=0`, PASS | No loop-buffer/UOC activity. |
| CoreMark iter10 checked-in | `benchmark_results/20260505_xs_frontend_anchor/coremark_iter10_checkedin_safe_defaults.stdout` | 2,272,228 | 2,283,711 | 3,183,639 | 3,197,414 | `flags=0`, PASS | Correct checked-in image; no loop-buffer/UOC activity. |

Score equivalents at 1 MHz:

| Workload | Raw FTQ-only timed score | Raw FTQ-only total-cycle score |
|---|---:|---:|
| Dhrystone 300 | 1.837 DMIPS/MHz | 1.825 DMIPS/MHz |
| CoreMark iter10 checked-in | 4.401 CM/MHz | 4.379 CM/MHz |

Current limiter read:

| Workload | Dominant observed frontend loss | Implication |
|---|---|---|
| Dhrystone 300 | 41,595 fetch-zero packet-empty cycles; 41,119 cycles with F2 data present; 26,046 packet-empty enqueue cycles. | The replacement has not recovered the loop-buffer's hot-loop delivery benefit. |
| CoreMark iter10 checked-in | 990,788 fetch-zero packet-empty cycles; 943,835 cycles with F2 data present; 768,508 packet-empty enqueue cycles. | CoreMark parity depended on the old loop-buffer path; the FTQ-only anchor is insufficient. |

Image-selection guard: `benchmark_results/item12_baseline_coverage_20260503/images/coremark_iter10.hex`
is not the accepted checked-in CoreMark image; it reproduces the older
`flags=1`, `TOHOST=3`, `checksum=8879` failure row. Use
`tests/hex/coremark_iter10.hex` for current checked-in CoreMark signoff. For
apples-to-apples iter10 performance comparison, `flags=0` is necessary but not
sufficient: the final checksum must remain `64687`, matching the previous
clean loop-buffer row and the best valid loop-buffer-free anchor. The latest
no-seq rerun at 2,135,092 cycles, checksum `17574`, `flags=0`, PASS, and
`loop_buffer_hold=0` is a useful safe performance reference, but it also proves
why final checksum identity must be checked explicitly.

## May 5 Replay-Guard Ownership Repair

A follow-up trace showed that the raw FTQ-only frontend was also suppressing a
legitimate tight-loop return packet. The hot Dhrystone loop alternates between
`0x80002002` and the backward conditional at `0x8000200e`; the fixed-age replay
guard kept blocking `0x8000200e` even after the redirected-to packet had
already emitted. Clearing that guard when a different packet emits is a
general FTQ/IBuffer ownership repair, not a loop-buffer replacement.

| Row | Artifact | Timed cycles | Delta vs raw FTQ-only | Flags/status | Verdict |
|---|---|---:|---:|---|---|
| Raw FTQ-only safe default | `benchmark_results/20260505_xs_frontend_anchor/dhrystone_300_final_safe_defaults.stdout` | 92,948 | baseline | `flags=0`, PASS | Safe but too slow. |
| Replay-guard ownership repair | `benchmark_results/20260505_xs_stage1_continue/dhrystone_300_replay_guard_clear.stdout` | 79,145 | -13,803 (-14.85%) | `flags=0`, PASS | Keep as Step 1 ownership evidence; not Stage 1 pass. |
| Replay-guard repair plus packet bypass | `benchmark_results/20260505_xs_stage1_continue/dhrystone_300_replay_guard_clear_bypass2.stdout` | 78,827 | -14,121 (-15.19%) | `flags=0`, PASS | Bypass adds only 318 cycles beyond the repair. |
| Replay-guard repair plus TAGE update-PC experiment | `benchmark_results/20260505_xs_stage1_continue/dhrystone_300_replay_guard_tage_pc.stdout` | 79,145 | -13,803 (-14.85%) | `flags=0`, PASS | No measurable benefit; do not count as closure evidence. |

CoreMark on the repaired default:

| Row | Artifact | Timed cycles | Total cycles | Timed instret | Final `minstret` | Checksum | Flags/status | Verdict |
|---|---|---:|---:|---:|---:|---:|---|---|
| Historical raw FTQ-only safe default | `benchmark_results/20260505_xs_frontend_anchor/coremark_iter10_checkedin_safe_defaults.stdout` | 2,272,228 | 2,283,711 | 3,183,639 | 3,197,414 | 64687 | `flags=0`, PASS | Endpoint-equivalent but too slow. Keep checksum `64687` as the iter10 identity guard; use newer no-seq rows only as performance references when their checksum is also audited. |
| Replay-guard ownership repair | `benchmark_results/20260505_xs_stage1_continue/coremark_iter10_replay_guard_current.stdout` | 2,179,696 | 2,190,521 | 3,183,873 | 3,197,648 | 37896 | `flags=0`, PASS | Faster than raw FTQ-only by 92,532 cycles (-4.07%), but still +17.82% vs the prior clean loop-buffer row and checksum/instret identity must be audited. |

Counter movement:

| Counter | Raw FTQ-only | Replay-guard repair | Read |
|---|---:|---:|---|
| `packet_empty` | 41,595 | 27,432 | Large improvement, but still high. |
| `packet_empty_f2_data` | 41,119 | 26,956 | F2 often has data while decode still sees no packet. |
| `packet_empty_f2_emit` | 26,046 | 26,344 | Packet production remains a major loss after the stale guard is fixed. |
| `packet_empty_noemit_other` | 14,461 | 0 | The stale replay-guard suppression was real and is removed. |
| committed mispredicts | 326 | 326 | The repair removes frontend bubbles but does not fix loop-exit prediction. |

Interpretation: this is exactly why the Stage 1 refactor should be
XiangShan-style FTQ/IFU/IBuffer first. Packet ownership, redirect lifetime, and
valid-block delivery are architectural contracts. The remaining Dhrystone gap
is now more specific than "PC identity is too coarse." A focused trace with
`+FETCH_PACKET_BYPASS2` shows the hot `strcpy` loop alternating between an
emitted body packet at `0x80002002`, a duplicate no-emit cycle on the same FTQ
owner while the branch FTQ entry is being created, an emitted branch packet at
`0x8000200e`, and then the target body packet. That means the frontend needs
bounded BPU/FTQ runahead plus IBuffer-like delivery, not only looser duplicate
suppression. The CoreMark rerun confirms the ownership repair is helpful beyond
Dhrystone, but the checksum/instret drift prevents treating it as a clean
baseline until the benchmark image and endpoint accounting are rechecked.

## May 5 Follow-Up DSE: Rejected Shortcuts

The follow-up rows were used to calibrate the XiangShan-style plan. They show
that the gap is not closed by a local packet bypass, one predictor update tweak,
early backend redirect, or standalone UOC replay.

| Row | Artifact | Timed cycles | Delta vs FTQ-only | Flags/status | Verdict |
|---|---|---:|---:|---|---|
| Fetch-packet same-cycle bypass | `benchmark_results/20260505_xs_frontend_followup/dhrystone_300_fetch_packet_bypass2.stdout` | 92,630 | -318 (-0.34%) | `flags=0`, PASS | Not enough. It reduces `packet_empty_enq` from 26,046 to 1,216, but `packet_empty_f2_data` remains 40,767 cycles. |
| TAGE update PC experiment | `benchmark_results/20260505_xs_frontend_followup/dhrystone_300_tage_branch_pc_update.stdout` | 92,948 | 0 | `flags=0`, PASS | No movement; temporary RTL change was reverted. |
| Disable loop speculative count | `benchmark_results/20260505_xs_frontend_followup/dhrystone_300_no_loop_spec_count.stdout` | 95,316 | +2,368 (+2.55%) | `flags=0`, PASS | Worse; committed mispredicts rise from 326 to 622. |
| BRU early redirect | `benchmark_results/20260505_xs_frontend_followup/dhrystone_300_bru_early_redirect.stdout` | 92,946 | -2 (-0.00%) | `flags=0`, PASS | No meaningful cycle movement. |
| Safe/no-control UOC enable | `benchmark_results/20260505_xs_frontend_followup/dhrystone_300_uoc_safe_nocontrol.stdout` | 117,541 | +24,593 (+26.46%) | `flags=0`, but checksum/instret diverge | Rejected. Even without cached control groups, endpoint behavior changes and cycles regress. |
| Full-group UOC with control | `benchmark_results/20260505_xs_frontend_followup/dhrystone_300_uoc_fullgroups_control.stdout` | n/a | n/a | Did not complete by 300k max cycles | Rejected as unsafe; partial endpoint was divergent and mispredicts rose to 1,411. |
| Naive F2-driven sequential lookahead | `benchmark_results/20260505_xs_stage1_continue/dhrystone_300_seq_lookahead.stdout` | n/a | n/a | Did not complete by 300k max cycles; `minstret=92`, `packet_empty_ftq_full=299898` | Rejected and reverted. It proved that lookahead must be bounded by FTQ ownership and IBuffer/packet consumption; raw next-PC steering overfills FTQ. |

The key branch evidence is still Dhrystone `strcpy` at PC `0x8000200e`.
The FTQ-only safe row records 303 committed mispredicts at that one backward
conditional branch, while the previous loop-buffer row had only 36 committed
mispredicts total. The refactor therefore needs both frontend delivery
elasticity and BPU/FTQ-owned loop-exit/control prediction; it cannot be a
single bypass or a stale decoded replay cache.

## May 5 Same-Line FTQ Handoff DSE: Rejected

The bounded same-line FTQ handoff was tested as a small XiangShan-style
ownership slice: when a full packet leaves a same-cacheline sequential tail
whose first instruction is a predicted-taken backward conditional branch, the
frontend allocates a second FTQ owner and carries the current I-cache line for
the next packet. This is closer to an FTQ/IBuffer handoff than the old loop
buffer, but it is still too local to be accepted.

| Workload | Artifact | Timed cycles | Timed instret | Checksum | Flags/status | Verdict |
|---|---|---:|---:|---:|---|---|
| Dhrystone 300 | `benchmark_results/20260505_xs_stage1_anchor/dhrystone_300_same_line_branch_start.stdout` | 69,826 | 149,739 | 24 | `flags=0`, PASS | Useful opportunity signal: it beats the prior clean loop-buffer Dhrystone row by 957 cycles, with loop-buffer activity zero. |
| CoreMark iter10 checked-in | `benchmark_results/20260505_xs_stage1_anchor/coremark_iter10_same_line_branch_start.stdout` | 2,141,493 | 3,223,197 | 24,726 | `flags=1`, `TOHOST=3` | Rejected. Endpoint drift proves the handoff is not a correct general frontend mechanism. |

This result recalibrates the plan in two ways:

1. The Dhrystone gain confirms that the remaining Stage 1 opportunity is in
   FTQ-owned delivery continuity, not in widening decode.
2. The CoreMark failure confirms that a local same-line shortcut is not enough.
   We need the full XiangShan-style contract: bounded BPU runahead, explicit
   FTQ producer/consumer phases, IFU predecode writeback, PredChecker-style
   repair, and IBuffer delivery. The same-line handoff is now disabled by
   default and can only be used as opt-in DSE with
   `+ENABLE_SAME_LINE_FTQ_HANDOFF`.

## UOP-Cache Reference Audit

The reference audit changes the Stage 1 direction: a real UOP cache is not
a small PC-indexed cache bolted onto rename. It is a frontend delivery source
with explicit source switching, branch-prediction ownership, fetch-block or
trace metadata, validation, and recovery rules.

May 4 recalibration: XiangShan is the primary high-performance RISC-V reference
for Stage 1. Public XiangShan materials describe it as a high-performance
open-source RISC-V project, with the official site calling it the world's
top-performing open-source processor core. Its current Kunminghu documentation
lists a 32-byte-per-cycle fetch unit, 6-wide decode/rename, 8-wide commit,
ICache/FDIP/BPU, ROB compression, and a 13-cycle mispredict penalty. The local
source does not show a copyable UOP cache; it shows the frontend contract we
should emulate.

Local RV core audit:

| Reference | Has a decoded-op cache? | Useful structures found | Stage 1 verdict |
|---|---|---|---|
| XiangShan (`../xiangshan`) | No obvious UOP-cache RTL in this snapshot. | FTQ with BPU runahead limits, ICache/IFU requests by FTQ entry, IBuffer delivery, IFU predecode, `PredChecker`, IFU writeback redirect, detailed frontend topdown counters. | Primary Stage 1 reference. Build an analogous BPU/FTQ/IFU/IBuffer/control-validation backbone, scaled to our 4-wide core. Do not copy implementation or widen just to match XiangShan. |
| BOOM/MegaBOOM (`../riscv-boom`, `../chipyard/generators/boom`) | No decoded-op cache. | FTQ entry stores fetch PC plus branch prediction snapshot; FetchBuffer converts fetch bundles into `MicroOp`s; loop predictor learns loop trip counts and flips prediction at exit. | Strong baseline reference. Borrow FTQ metadata lifetime and loop predictor placement. Loop-exit prediction belongs in BPU/FTQ, not hidden inside a replay cache. |
| NaxRiscv (`../naxriscv`) | No decoded-op cache found. | Fetch aligner carries branch prediction metadata and has prediction sanity correction; BranchContextPlugin stores branch context separately through allocation/commit/reschedule. | Useful lower-complexity reference for separating branch context from instruction/decode storage and correcting bad prediction slicing. |
| RSD (`../rsd`) | No decoded-op cache. | 2-fetch frontend, predecode/decode, conventional branch predictors, micro-op scheduler terminology. | Not a Stage 1 architecture reference for UOP cache. Useful only as contrast/instrumentation style. |
| rv64gc perf model (`../rv64gc-perf-model`) | Config knobs exist, but no implemented uop-cache model file was found. | Loop-buffer activity model and frontend stall taxonomy. | Use only for what-if modeling after the RTL contract is defined. It is not an external architecture reference. |

Industry/public reference audit:

| Reference | Evidence | Stage 1 implication |
|---|---|---|
| XiangShan official docs/site/tutorials | Official docs describe Kunminghu as the third-generation XiangShan microarchitecture for server and high-performance embedded scenarios; the official site calls XiangShan the world's top-performing open-source processor core; ISCA 2025 tutorial slides report Kunminghu SPEC CPU 2006 evaluation methodology and list frontend upgrades around FDIP/ICache. | Treat XiangShan as the primary RISC-V architecture reference. The reusable idea is not a UOP cache; it is the decoupled frontend and data-driven frontend topdown methodology. |
| Arm Neoverse N2 TRM and optimization guide | Public Arm docs list a macro-operation cache in the L1 instruction memory system and describe instructions decoded into internal macro-ops. For this repo, we normalize that class of structure to "UOP cache." Local `../arm/Neoverse-N2_uArch_Diagram.svg` also shows BPU/FAQ feeding a decoded-op cache. | Strong conceptual target: decoded-op delivery is real industry practice, but it sits inside a broader decoupled frontend. The cache must shorten/hide decode on hot streams, not own branch truth. |
| Arm Cortex-A76 local diagram | Local `../arm/Cortex-A76_uArch_Diagram.svg` shows decoupled BPU/FAQ/fetch queue, decoded-op generation, and a tight-loop buffer. | Useful warning: strong frontend performance comes from decoupled prediction and queueing as much as width. A loop buffer can exist, but should be a frontend-source optimization, not a benchmark-specific special path. |
| Intel Decoded ICache / DSB and LSD | Intel's optimization manual describes a Decoded ICache with higher micro-op bandwidth and decode-power savings, but also warns about penalties when switching frequently between decoded-cache and legacy decode. The same manual describes LSD micro-op replay for small loops. | We need explicit `UOP cache -> decode` and `decode -> UOP cache` source-switch counters, hit/miss exposure counters, and loop-stream behavior that preserves branch-exit correctness. |
| AMD Zen OpCache | AMD public material says Zen 2 increased OpCache capacity to 4K. AMD uProf IBS docs describe instruction fetch as checking the op-cache before I-cache/L2 and recording frontend sample data. | Treat op-cache as a first-class frontend source and build counters around source, misses, delivered ops, and wrong-path waste. |

Primary source anchors checked:

```text
../xiangshan/src/main/scala/xiangshan/frontend/Frontend.scala
../xiangshan/src/main/scala/xiangshan/frontend/ftq/Ftq.scala
../xiangshan/src/main/scala/xiangshan/frontend/ifu/Ifu.scala
../xiangshan/src/main/scala/xiangshan/frontend/ifu/PredChecker.scala
../riscv-boom/src/main/scala/v4/ifu/fetch-target-queue.scala
../riscv-boom/src/main/scala/v4/ifu/fetch-buffer.scala
../riscv-boom/src/main/scala/v4/ifu/bpd/loop.scala
../naxriscv/src/main/scala/naxriscv/fetch/AlignerPlugin.scala
../naxriscv/src/main/scala/naxriscv/prediction/BranchContextPlugin.scala
../rsd/Processor/Src/Core.sv
../arm/Cortex-A76_uArch_Diagram.svg
../arm/Neoverse-N2_uArch_Diagram.svg
https://xiangshan.cc/en/
https://github.com/OpenXiangShan/XiangShan
https://docs.xiangshan.cc/projects/user-guide/en/kunminghu-v3/introduction/
https://docs.xiangshan.cc/projects/user-guide/en/kunminghu-v3/processor/
https://docs.xiangshan.cc/projects/user-guide/en/kunminghu-v3/typical-configuration/
https://docs.xiangshan.cc/projects/design/en/kunminghu-v3/frontend/FTQ/
https://docs.xiangshan.cc/projects/design/en/kunminghu-v3/frontend/IFU/
https://docs.xiangshan.cc/projects/design/en/kunminghu-v3/frontend/IFU/PreDecoder/
https://docs.xiangshan.cc/projects/design/en/kunminghu-v3/frontend/ICache/
https://tutorial.xiangshan.cc/isca25/slides/20250621-ISCA25-3-Microarchitecture.pdf
https://documentation-service.arm.com/static/60ad234d982fc7708ac1d0f6
https://documentation-service.arm.com/static/66880d189082ad344b14c342
https://developer.arm.com/community/arm-community-blogs/b/architectures-and-processors-blog/posts/arm-neoverse-n2-industry-leading-performance-efficiency
https://www.intel.cn/content/dam/doc/manual/64-ia-32-architectures-optimization-manual.pdf
https://docs.amd.com/r/en-US/68658-uProf-getting-started-guide/Introduction-to-IBS-Instruction-Based-Sampling
https://www.amd.com/en/technologies/zen-core.html
```

Key design rules inferred from the audit:

1. Stage 1 should first build the XiangShan-like decoupled frontend backbone:
   BPU runahead, FTQ-owned fetch-block metadata, IFU/ICache fetch by FTQ entry,
   predecode/control validation, and IBuffer delivery into decode.
2. The UOP cache, if added, must never be authoritative for dynamic branch direction,
   target, return prediction, or loop exit. Those remain BPU/FTQ-owned.
3. A cache hit should supply already-decoded work for an FTQ-approved fetch
   block or stream. It should not independently decide the next PC.
4. Fill entries only after the fetched bytes are aligned, decompressed, decoded,
   and predecode/control metadata are internally consistent.
5. Cache metadata must include at least start PC, valid mask, uop count, CFI
   offset/type, fallthrough/next-block metadata, and a prediction/epoch check.
6. On `fence.i`, instruction-side coherence events, decode policy changes, or
   relevant frontend flushes, cached decoded entries must be invalidated or made
   unreachable by epoch.
7. Source switching is part of the design. Frequent oscillation between legacy
   fetch/decode and UOP-cache replay can erase the benefit and must be counted.
8. Loop-exit recovery should be handled by a loop predictor or BPU-side metadata
   feeding FTQ prediction, using BOOM-style trip-count confidence as the first
   reference. It should not be replayed as stale cached `bp_taken`.
9. A high hit rate is not success. The rejected row had a 92% UOC hit rate but
   much worse cycles because it increased wrong-path/control-flow work.

## XiangShan-Calibrated Refactor Plan

This replaces the previous UOP-cache-first sequence. The near-term goal is not
to copy XiangShan RTL or widen rv64gc-v2 to XiangShan width. The goal is to
make our 4-wide frontend use the same class of contract: a predicted
fetch-block stream with explicit ownership, validation, training, prefetch, and
delivery stages before any decoded-op cache participates.

May 5 recalibration: XiangShan is the primary Stage 1 architecture reference
because it is the strongest open high-performance RISC-V design available to
inspect. The official XiangShan site calls it the world's top-performing
open-source processor core, and the GitHub project describes it as an
open-source high-performance RISC-V processor. The useful takeaway is not
"copy XiangShan" and not "make rv64gc-v2 6-wide." The useful takeaway is the
decoupled frontend contract:

1. BPU predicts in blocks and can run ahead.
2. FTQ owns prediction-block PC, CFI, redirect, and training metadata for the
   full lifetime from prediction through commit.
3. FTQ has separate producer/consumer phases: BPU allocation, ICache/FDIP
   prefetch, IFU fetch, IFU writeback, backend redirect/resolve, commit, and
   BPU training. A single fixed-age replay guard is not enough ownership.
4. IFU and ICache consume FTQ entries, not ad hoc replay PCs.
5. IFU predecode and a PredChecker-like unit repair control-flow mistakes
   before they become backend surprises where possible.
6. IBuffer absorbs IFU/decode rate mismatch and supports real empty-queue
   bypass.
7. Frontend topdown counters identify whether the next limiter is BPU runahead,
   FTQ fullness, IFU/ICache readiness, IBuffer delivery, predecode repair,
   backend redirect, decode backpressure, or source switching.

Local XiangShan source confirms the partitioning: `Frontend.scala` wires
`Bpu`, `Ftq`, `ICache`, `Ifu`, and `IBuffer` as separate modules; `Ftq.scala`
has separate `bpuPtr`, `pfPtr`, `ifuPtr`, `ifuWbPtr`, and `commitPtr`-style
ownership; `FtqParameters.scala` defaults to `FtqSize=64` and
`BpRunAheadDistance=8`; `IBuffer` defaults to 48 entries with banked read/write
and bypass; and `PredChecker.scala` classifies direct, indirect, return,
not-CFI, invalid-taken, and target faults. Public XiangShan FTQ documentation
also describes the FTQ as storing BPU fetch targets, sending requests to IFU,
writing back predecode metadata, retaining BPU metadata for commit-time
training, supporting redirect recovery, and using BPU runahead entries for
ICache prefetch. We should scale that behavior to our 4-wide core, not copy
their width or code.

Reference width calibration:

| Item | XiangShan/Kunminghu reference | rv64gc-v2 current RTL | Stage 1 target |
|---|---|---|---|
| Fetch block / IFU bandwidth | Public docs: up to 32 B/cycle; local default parameter allows larger fetch blocks with multiple fetch ports. | 16 B/cycle logical fetch window, one live request path. | Keep 4-wide decode, but make fetch-block ownership decoupled enough that IFU/ICache can run ahead of decode stalls. |
| Decode / rename / commit | Public docs: 6 decode, 6 rename, 8 commit. | 4 decode, 4 rename, 4 commit. | Do not widen for Stage 1. First remove frontend bubbles and wrong-path recovery waste. |
| FTQ ownership | Separate BPU, prefetch, IFU, IFU writeback, and commit pointers; BPU runahead is explicitly bounded. | Simple FIFO allocated on actual request; head/pop tied tightly to packet emission. The replay-guard repair proves ownership lifetime is currently too local. | Split producer/consumer ownership so BPU can form a predicted block stream before IFU/decode consume it. |
| Control validation | IFU predecode plus `PredChecker` redirects before backend surprise where possible. | Predecode metadata exists, but many corrections still surface through backend flush accounting. | Add PredChecker-like classification: invalid-taken, missing direct/indirect/return prediction, target mismatch, CFI mask repair. |
| Delivery elasticity | IBuffer absorbs IFU/decode rate mismatch and can bypass when empty. | 8-entry fetch-packet FIFO; the repaired Dhrystone row still has 26,956 `packet_empty_f2_data` cycles. | Harden packet FIFO into an IBuffer-equivalent interface with explicit stall-source counters. |
| Loop behavior | Prediction remains BPU/FTQ-owned; no local evidence of a XiangShan UOP cache in this snapshot. | Old loop buffer delivered hot loops but is discarded; standalone UOC replay is unsafe. | Move useful loop-exit behavior into BPU/FTQ prediction, then add decoded delivery only behind FTQ validation if needed. |

XiangShan-scaled RTL shape for rv64gc-v2:

| XiangShan idea | rv64gc-v2 implementation shape | Non-negotiable invariant |
|---|---|---|
| Prediction block as the frontend unit | Add an explicit fetch-block record around the current FTQ entry: start PC, line PC, fallthrough/next PC, predicted CFI offset/type/target, prediction snapshot, predecode writeback fields, delivered mask, and completion state. | A packet can never outlive or pop a prediction block by local PC heuristics alone. |
| Separate BPU and IFU pointers | Split the current FTQ head/allocation behavior into at least allocation, IFU request, IFU writeback/delivery, and commit/training phases. Start with runahead depth 4, then sweep to 8 only with counters. | Runahead must be bounded by FTQ free entries and IBuffer consumption, so the rejected F2 lookahead cannot fill the FTQ while no real work is delivered. |
| IFU consumes FTQ entries | Replace ad hoc same-line handoff with same-FTQ tail delivery: if one prediction block spans multiple 4-wide packets in the same line, carry the line and owner to the tail packet instead of allocating a fresh FTQ entry. | The tail packet uses the same FTQ owner and prediction metadata. A new FTQ entry is allocated only for a new prediction block. |
| IFU predecode writeback | Treat predecode as FTQ writeback metadata, not only local packet construction. Record valid-start mask, CFI mask/type, corrected range, target mismatch, and repaired next PC. | Backend mispredicts should not be the first place obvious JAL/RET/non-CFI/invalid-target errors are detected. |
| PredChecker-style repair | Add a small checker after predecode that classifies missed JAL, missed RET, invalid predicted CFI, non-CFI taken, and direct-target mismatch. | Each redirect source must be counted separately and must update the same FTQ owner it checked. |
| IBuffer delivery | Convert the fetch packet FIFO into an IBuffer-equivalent delivery layer with per-uop FTQ owner, `is_last_in_ftq_entry`, empty bypass, decode accept accounting, and precise flush invalidation. | Decode sees a stable stream of valid uops; FTQ completion follows the last delivered instruction in the block, not the first packet boundary. |
| Loop-exit handling | Move the useful loop-buffer behavior into BPU/FTQ loop prediction using trip count, confidence, speculative count, and flush recovery. | No benchmark PC special cases and no replay of stale cached `taken` bits. |
| Decoded-op cache | Keep `uop_cache` as a later FTQ-attached source that can supply decoded uops for an FTQ-approved block. | The cache is not allowed to own dynamic branch truth, next PC selection, or loop exit behavior. |

Immediate Stage 1 ladder after this recalibration:

1. **XS-FE0: counters and endpoint audit.** Complete for the safe no-seq baseline. Keep these counters in every future DSE row: they prove the current limiter is FTQ-empty/packet-empty/duplicate last-emitted-PC churn with max FTQ occupancy of only 2 and max packet-buffer occupancy of only 1, not capacity pressure or backend backpressure.
2. **XS-FE1: same-FTQ tail delivery.** Replace the rejected same-line new-entry handoff with a conservative same-owner tail carry. This is the smallest RTL slice that directly tests XiangShan-style block ownership against the observed Dhrystone body/branch bubble.
3. **XS-FE2: FTQ pointer split.** Separate allocation, IFU request, delivery/writeback, and commit/training lifetime so BPU runahead is real and bounded.
4. **XS-FE3: IBuffer-equivalent delivery.** Extend the packet FIFO into an owner-aware instruction buffer with decode accept tracking and last-in-block completion.
5. **XS-FE4: PredChecker writeback.** Add frontend repair and FTQ writeback for predecode-discoverable prediction errors.
6. **XS-FE5: BPU/FTQ loop-exit predictor.** Rebuild the loop-buffer benefit as predictor state feeding FTQ, then rerun Dhrystone and CoreMark.
7. **XS-FE6: FDIP and decoded-op cache hooks.** Only after XS-FE1 through XS-FE5 are clean, add ICache prefetch from the FTQ stream and allow decoded-op cache hits behind FTQ validation.

This ladder is intentionally narrower than XiangShan's full Kunminghu frontend.
It borrows the ownership contract and measurement discipline, not the 6-wide
backend, vector machinery, or exact Chisel implementation.

Recalibrated implementation steps:

| Step | Component | Required behavior | Acceptance evidence |
|---|---|---|---|
| 0 | Evidence and endpoint audit | Add counters before the next structural DSE: BPU runahead distance, FTQ full, FTQ empty/no predicted block, IFU request wait, ICache response wait, packet/IBuffer empty, packet/IBuffer full, duplicate-suppressed reason split, decode backpressure, predecode redirect, backend redirect, and source-switch bubbles. Also audit the repaired CoreMark checksum/instret drift before treating that row as a clean baseline. | Every DSE row names the limiter before and after the change. No unlabeled "several percent" result is accepted, and CoreMark endpoint identity is either explained or fixed. |
| 1A | Current-frontend ownership repair and invariants | Keep the replay-guard repair and default packet-empty bypass, but keep rejected PC-steering shortcuts and the same-line handoff disabled by default. Make current packet/FTQ ownership auditable before the larger rewrite. Duplicate suppression, replay guards, allocation gating, packet bypass, redirect invalidation, and BPU update metadata must all expose the FTQ owner and reason for blocking. This is a stabilization step, not the final performance mechanism. | The safe default returns to a clean no-handoff baseline rather than the failed lookahead timeout or the `flags=1` handoff row. Dhrystone/CoreMark remain `flags=0` with loop-buffer activity zero, and every remaining frontend-empty cycle is classifiable. |
| 1B | FTQ-owned prediction-block stream | Refactor the request/packet FIFO into a predicted fetch-block queue modeled on XiangShan's ownership split. FTQ owns start PC, next/fallthrough PC, predicted CFI offset/type, target, BPU metadata, predecode writeback metadata, redirect/resolve state, and commit/training lifetime. Start with scaled runahead depth 4, then sweep 8 only if counters show IFU starvation. The runahead limit must account for both FTQ occupancy and IBuffer/packet consumption so the F2 lookahead failure cannot recur. | Dhrystone/CoreMark show lower packet-empty and redirect-recovery bubbles without endpoint drift. Runahead/full histograms prove BPU and IFU are decoupled rather than locked to one request, while FTQ-full stalls do not replace the old duplicate bubbles. |
| 2 | IBuffer-equivalent delivery | Replace the one-cycle packet contract with a real elastic IBuffer interface: banked or FIFO storage, decode accept tracking, empty bypass, buffered dequeue under decode stalls, FTQ-owner completion, and flush/replay correctness. This is mandatory Stage 1 work because the trace shows the current path loses a cycle between body and branch packets even after ownership repair. | `packet_empty_f2_data` and frontend-empty cycles fall materially versus the 79,145-cycle Dhrystone row without increasing committed mispredicts; CoreMark packet-empty falls toward the clean loop-buffer row. |
| 3 | IFU plus PredChecker repair path | Consume FTQ entries in IFU, align/decompress/predecode them, write predecode metadata back to FTQ, and generate frontend redirects for invalid taken bits, missed JAL/JALR/RET/direct branches, not-CFI-taken cases, and direct target mismatches. This is the XiangShan-style control-validation point; backend flushes should not be the first place routine frontend prediction mistakes are discovered. | Top mispredict list loses stale frontend-control patterns; predecode redirects are counted separately from backend mispredicts. |
| 4 | BPU/FTQ loop-exit predictor | Move the useful prediction part of the discarded loop buffer into BPU/FTQ: trip count, current iteration count, confidence, speculative update, squash recovery, and normal branch training. BOOM's loop predictor is the first implementation reference, but the state must be trained and consumed through the normal prediction-block path. | Dhrystone `0x8000200e` loop-exit mispredict count falls without benchmark PCs or stale replay of cached branch outcomes. CoreMark committed mispredicts move back toward the clean row of 35,070 rather than the repaired row of 46,402. |
| 5 | FTQ-driven FDIP / ICache lookahead | Use the FTQ stream to prefetch or pre-validate upcoming I-cache lines, following XiangShan's FDIP direction. A full WayLookup is optional for our current cache, but the prefetch/runahead contract is not. | Fewer IFU/ICache starvation cycles on Dhrystone/CoreMark and probe workloads; no CoreMark endpoint regression. |
| 6 | Width and effective-work analysis | After the frontend contract and counters exist, measure fetch, decode, rename, dispatch, issue, and commit separately. Only then decide whether fetch block size, branch slots, issue resources, or backend width need attention. | Width changes are justified by measured utilization, not by comparing decode width names. |
| 7 | FTQ-attached decoded-op cache hook | Only after Steps 1A-5 are stable, allow an FTQ-approved block to bypass decode using cached decoded uops. It is a delivery accelerator behind the XiangShan-style backbone, not the backbone itself. | Hit rate correlates with lower frontend-empty/decode work and does not increase wrong-path flushes. |
| 8 | Multi-block trace/stream cache | Only after fetch-block cache and loop predictor are correct, allow traces crossing taken branches. | Consider only if the XiangShan-style fetch-block stream cannot close Stage 1 with clean correctness. |

Stage 1 execution plan:

1. Freeze the current safe default at the replay-guard repair level. Keep the
   rejected unbounded F2-driven lookahead, same-line handoff, and invalid
   no-owner-condition shortcut out of default RTL. The timeout and `flags=1`
   rows are now design constraints: runahead must be bounded by FTQ ownership,
   predecode validation, and delivery consumption, not by raw next-PC
   availability. Do not "fix" stale owner cases by dropping packet-buffer
   entries; the trace proves some stale-owner-looking packets are still
   architecturally required. The fix is owner lifetime repair.
2. Add Step 0 counters and audit the repaired CoreMark checksum/instret drift
   before promoting any new row to the clean default baseline.
3. Complete Step 1A as an ownership/instrumentation cleanup, not as the main
   performance patch. The output should be a stable baseline with classified
   frontend stalls and no hidden loop-buffer/UOC participation.
4. Implement Step 1B and Step 2 as the first real XiangShan-style structural
   slice: bounded BPU prediction-block runahead, FTQ-owned fetch requests,
   IFU writeback of predecode metadata, and IBuffer-equivalent delivery. These
   two steps should be designed together because the trace shows either one
   alone can just move the bubble or corrupt CoreMark endpoint behavior.
5. Implement Step 3 PredChecker-style repair and Step 4 loop-exit prediction
   through the normal BPU/FTQ path. The loop predictor is the loop-buffer
   replacement for tight-loop correctness/performance, but it should not be
   implemented as a PC-special replay path.
6. Add Step 5 FDIP/ICache lookahead only if counters still show IFU/ICache
   starvation after Steps 1B-4.
7. Keep decoded-op replay disabled until cached decoded work is attached to an
   FTQ-approved fetch block and dynamic branch truth remains owned by BPU/FTQ.

Stage 1 verdict after recalibration: replace the loop buffer with a
XiangShan-style decoupled frontend first. The first accepted structural unit is
not a uop cache; it is a correct FTQ-owned fetch-block identity. The current
standalone PC-indexed replay cache remains rejected. A decoded-op cache can
still be added later, but only as an FTQ-attached accelerator after the
fetch-block stream, branch validation, IBuffer delivery, and loop-exit
predictor are correct.

## Loop-Buffer Replacement Shortlist

| Candidate | Role | Stage 1 verdict |
|---|---|---|
| XiangShan-style FTQ + IFU/ICache + IBuffer frontend stream | Primary loop-buffer replacement. Decouples prediction, I-cache, predecode, and decode so frontend bubbles can be measured and removed. | Steps 1B-3 after Step 1A stabilization. New Stage 1 anchor. Scale it to our 4-wide machine; do not widen solely to match XiangShan. |
| BPU-side loop-exit predictor | Restores the useful part of the removed loop buffer by predicting hot loop exits before replay/fetch reaches the wrong path. | Step 4. Use BOOM-style trip-count confidence as the first implementation reference, but train/consume it through FTQ. |
| Decoded uop cache / op-cache behind FTQ | Optional accelerator once the XiangShan-style frontend contract is correct. Delivers already decoded work from FTQ-approved fetch blocks. | Step 7 for Stage 1 only if Steps 1A-5 do not close the gap. Prior `+UOC_ENABLE` rows are rejected as standalone replay; do not continue tuning them. |
| Stronger fetch packet buffer / IBuffer elasticity | Frontend continuity improvement required by the XiangShan-style plan. Helps separate fetch delivery gaps from decode/rename stalls. | Step 2. Mandatory Stage 1 work; prior bypass-only DSE shows a one-cycle shortcut is not a substitute for a real queue. |
| L0/predecoded I-cache | Keeps instruction bytes plus predecode metadata close to decode. Lower complexity than a full uop cache, but less direct reuse of decoded work. | Step 5/7 option. Consider if full uop cache risk is too high. |
| Trace cache | Can capture taken-control-flow paths and eliminate repeated fetch/decode on hot traces. | Step 8. Powerful but higher validation and recovery complexity; not first Stage 1 choice. |
| LSD-style loop stream detector | Streams tight loops with very low frontend power. | Not primary. Too close to replacing one loop-specific structure with another unless it is naturally backed by the uop/op-cache path. |

## ARM Reference Notes

Two local ARM diagrams were checked from `../arm`:

| Diagram | Relevant frontend points | Stage 1 implication |
|---|---|---|
| `../arm/Cortex-A76_uArch_Diagram.svg` | Decoupled branch prediction runs ahead of fetch, fills a fetch address queue, uses hierarchical BTB, 16 B/cycle fetch, fetch queue, 4-wide decode/rename, 8-uop dispatch/issue/retire, and a tight-loop buffer. | Do not compare only decode width. The reusable idea is decoupled prediction plus fetch queueing; the loop buffer is only one part of a broader frontend delivery system. |
| `../arm/Neoverse-N2_uArch_Diagram.svg` | Decoupled BPU fills a FAQ, predicted blocks stream into a decoded-op cache, loop buffer is UOP-cache fed, decode/rename are 5-wide, dispatch/retire are 8-uop, and issue capacity is over-provisioned. | Strong support for Stage 1 replacing/subsuming our loop buffer with decoded-op delivery. A standalone LB is not the right signoff target. |

The ARM diagrams reinforce the MegaBOOM lesson: "4-wide" or "5-wide" alone is
not a sufficient comparison. The measured analysis must track effective work per
frontend slot and separate fetch, decode, rename, dispatch, issue, and commit
bandwidth.

## Cleanup Scope

Removed from accepted RTL/DSE path:

| Area | Cleanup decision | Reason |
|---|---|---|
| Loop-buffer safe wrap-fill | Removed from default RTL diff. | It was a Dhrystone-shaped local replay special case in a component we intend to replace/subsume. |
| Loop-buffer exit confidence threshold knobs | Removed from default RTL diff. | `LB_EXIT_CONF1` helped the tuned Dhrystone row, but it is not a general architecture decision. |
| BPU loop-confidence DSE knobs | Removed from default RTL diff. | No cycle movement; not needed for clean core. |
| Dhrystone-specific BPU hot-PC diagnostics | Removed from default RTL diff. | Hardcoded benchmark PCs do not belong in reusable core RTL. |
| Slot-3 FTQ taken-only default | Reverted to opt-in/off behavior. | It was not yet proven on broad workloads. |
| Fetch packet empty bypass | Kept default-on as a narrow IBuffer-like stabilization; additional policy filters remain DSE knobs. | It is functionally clean in the no-handoff rows, but it is only a small local latency fix and does not close Stage 1. |
| Same-line FTQ handoff | Disabled by default; opt-in only with `+ENABLE_SAME_LINE_FTQ_HANDOFF`. | Dhrystone improved to 69,826 cycles, but CoreMark ended with `flags=1`, so the mechanism is rejected as a standalone shortcut. |
| Guarded single-packet loop-tail same-line lookahead | Reverted from RTL; archived as rejected DSE evidence only. | Dhrystone reached 66,221 cycles, but CoreMark ended with `flags=1` and checksum `29775`; the local guard still corrupts control/owner lifetime. |
| Standalone decoded-op replay | Default disabled; explicit unsafe research path requires `+ENABLE_UOC +UOC_UNSAFE_STREAM`. | Current UOC replay is not FTQ/BPU-validated and is not signoff-safe. |

The final safe-default RTL still carries the `uop_cache` module and telemetry so
the next design can integrate an FTQ-attached decoded-op cache, but the module
does not participate in default performance.

## Evidence

MegaBOOM fixed baselines:

| Workload | Artifact | Cycles | Retired |
|---|---|---:|---:|
| Dhrystone 300 | `benchmark_results/item12_baseline_coverage_20260503/boom/dhrystone_300.boom.log` | 59,698 | 150,402 |
| CoreMark iter10 checked-in | `benchmark_results/item12_baseline_coverage_20260503/boom/coremark_iter10_checkedin.boom.log` | 1,835,815 | 3,197,417 |

Clean rv64gc-v2 reruns:

| Workload | Artifact | Timed cycles | Total cycles | Timed instret | Final `minstret` | Flags |
|---|---|---:|---:|---:|---:|---:|
| Dhrystone 300 clean | `benchmark_results/20260504_cleanup_recalibration/dhrystone_300_clean.stdout` | 70,783 | 71,287 | 149,739 | 150,406 | 0 |
| CoreMark iter10 clean | `benchmark_results/20260504_cleanup_recalibration/coremark_iter10_clean.stdout` | 1,850,040 | 1,860,512 | 3,183,638 | 3,197,413 | 0 |

Current loop-buffer-removed replacement reruns:

| Workload | Artifact | Timed cycles | Total cycles | Timed instret | Final `minstret` | Flags |
|---|---|---:|---:|---:|---:|---:|
| Dhrystone 300 FTQ-only | `benchmark_results/20260505_xs_frontend_anchor/dhrystone_300_final_safe_defaults.stdout` | 92,948 | 93,560 | 149,739 | 150,406 | 0 |
| Dhrystone 300 replay-guard ownership repair | `benchmark_results/20260505_xs_stage1_continue/dhrystone_300_replay_guard_clear.stdout` | 79,145 | 79,699 | 149,739 | 150,406 | 0 |
| Dhrystone 300 replay-guard plus packet-empty bypass, no handoff | `benchmark_results/20260505_xs_stage1_anchor/dhrystone_300_default_bypass_no_handoff.stdout` | 78,827 | 79,364 | 149,739 | 150,405 | 0 |
| Dhrystone 300 XS-FE0 counters, no handoff | `benchmark_results/20260505_xs_stage1_anchor/dhrystone_300_xs_fe0_counters.stdout` | 78,827 | 79,364 | 149,739 | 150,405 | 0 |
| CoreMark iter10 checked-in FTQ-only | `benchmark_results/20260505_xs_frontend_anchor/coremark_iter10_checkedin_safe_defaults.stdout` | 2,272,228 | 2,283,711 | 3,183,639 | 3,197,414 | 0 |
| CoreMark iter10 checked-in replay-guard ownership repair | `benchmark_results/20260505_xs_stage1_continue/coremark_iter10_replay_guard_current.stdout` | 2,179,696 | 2,190,521 | 3,183,873 | 3,197,648 | 0 |
| CoreMark iter10 checked-in replay-guard plus packet-empty bypass, no handoff | `benchmark_results/20260505_xs_stage1_anchor/coremark_iter10_default_bypass_no_handoff.stdout` | 2,135,092 | 2,145,679 | 3,183,917 | 3,197,691 | 0 |
| CoreMark iter10 checked-in XS-FE0 counters, no handoff | `benchmark_results/20260505_xs_stage1_anchor/coremark_iter10_xs_fe0_counters.stdout` | 2,135,092 | 2,145,679 | 3,183,917 | 3,197,691 | 0 |
| Dhrystone 300 restored safe default after rejected owner-hold revert | `benchmark_results/20260505_stage1_xs_anchor_finish/dhrystone_300_restored_safe.stdout` | 78,827 | 79,364 | 149,739 | 150,405 | 0 |
| CoreMark iter10 restored safe default after rejected owner-hold revert | `benchmark_results/20260505_stage1_xs_anchor_finish/coremark_iter10_restored_safe.stdout` | 2,135,092 | 2,145,679 | 3,183,917 | 3,197,691 | 0 |

Build check:

| Check | Artifact | Result |
|---|---|---|
| DSim clean rebuild | `benchmark_results/20260504_cleanup_recalibration/build_clean.stdout` | Build completed with `DSim build OK`; pre-existing DSim warnings remain. |
| DSim safe-default rebuild | `benchmark_results/20260505_xs_frontend_anchor/build_after_fifo_revert.stdout` | Build completed with `DSim build OK`; pre-existing DSim warnings remain. |
| DSim replay-guard rebuild | `benchmark_results/20260505_xs_stage1_continue/build_replay_guard_clear.stdout` | Build completed with `DSim build OK`; pre-existing DSim warnings remain. |
| DSim rebuild after disabling same-line handoff default | `benchmark_results/20260505_xs_stage1_anchor/build_disable_same_line_default.stdout` | Build completed with `DSim build OK`; pre-existing DSim warnings remain. |
| DSim rebuild after reverting guarded single-packet loop-tail DSE | `benchmark_results/20260505_xs_stage1_anchor/build_after_reject_revert.stdout` | Build completed with `DSim build OK`; pre-existing DSim warnings remain. |
| DSim rebuild after XS-FE0 counters | `benchmark_results/20260505_xs_stage1_anchor/build_xs_fe0_counters.stdout` | Build completed with `DSim build OK`; pre-existing DSim warnings remain. |
| DSim rebuild after rejected predicted-control owner hold was reverted | `benchmark_results/20260505_stage1_xs_anchor_finish/build_restore_after_rejected_owner_carry.stdout` | Build completed with `DSim build OK`; pre-existing DSim warnings remain. |

## Archived DSE Evidence

These rows are useful for estimating opportunity size, but they are not
accepted clean core results.

| Row | Result | Status |
|---|---:|---|
| Dhrystone tuned loop-buffer row | 59,927 timed cycles, 60,404 total cycles, `flags=0` | Archived DSE only. It used `+LB_WRAP_FILL_SAFE +LB_ALLOW_NT_COND_CHAIN +LB_EXIT_LEAD2 +LB_EXIT_CONF1 +FETCH_PACKET_BYPASS2 +FETCH_PACKET_BYPASS2_NONCOND +DISABLE_SUBGROUP_SPLIT_OWNER_COND`. |
| CoreMark split-slot/default tuned row | 1,805,670 timed cycles, 1,816,075 total cycles, `flags=0` | Archived DSE only. It should not be treated as the clean default baseline after cleanup. |
| `LB_EXIT_*_LEAD1` rows | Best local row reached 58,432 Dhrystone cycles | Rejected. The lead special cases were removed before this cleanup. |
| `LB_WRAP_BACKEDGE` shortcut | Around 53,335 Dhrystone cycles | Invalid because retired-count behavior changed. |
| UOC rows | Timeout, endpoint divergence, or Dhrystone 103,308-cycle regression | Rejected for performance comparison; standalone replay is now explicit unsafe research only. |
| May 5 shortcut rows | Packet bypass only -0.34%, TAGE update PC no-op, early redirect no-op, no-loop-spec worse, standalone UOC unsafe/worse | Rejected. These rows recalibrate Stage 1 toward a real XiangShan-style frontend contract rather than local tuning. |
| May 5 replay-guard ownership repair | Dhrystone improves from 92,948 to 79,145 cycles; CoreMark improves from 2,272,228 to 2,179,696 cycles but checksum/instret drift appears | Accepted as partial ownership evidence only. It does not close Stage 1 and the CoreMark row needs endpoint audit. |
| May 5 same-line FTQ handoff | Dhrystone reaches 69,826 cycles, but CoreMark reaches `flags=1` with checksum drift | Rejected as a standalone shortcut. It proves opportunity in FTQ delivery continuity but not correctness. |
| May 5 guarded single-packet loop-tail same-line lookahead | Dhrystone reaches 66,221 cycles, but CoreMark reaches `flags=1`, checksum `29775`, and 2,078,791 timed cycles | Rejected and reverted. It proves the loop-tail bubble is valuable but still unsafe without FTQ/IBuffer-owned control validation. |

## Stage 1 Methodology

Use the clean rerun rows above as the baseline. A candidate architecture change
can be promoted only if it is stated as a general pipeline mechanism, then
validated on fixed heavy workloads plus broader coverage, with endpoint
accounting unchanged.

Anti-overfitting rule for the goal run:

- Treat Dhrystone/CoreMark as signoff gates, not design specifications. They
  identify bottleneck buckets; they do not justify benchmark-PC constants,
  checksum-specific behavior, or per-workload steering.
- Keep every accepted RTL change explainable in architectural terms:
  FTQ ownership, prediction-block lifetime, IFU/predecode writeback, IBuffer
  delivery, BPU/loop-exit learning, recovery, or source switching.
- Classify any plusarg cocktail as DSE evidence only. Before signoff, rerun the
  candidate as the intended default or as one named general architectural knob,
  and document why it is not workload-shaped.
- Reject split results. A Dhrystone win with CoreMark endpoint drift, a
  CoreMark speedup with checksum drift, or a row that only works on one stale
  image is not Stage 1 progress except as localization evidence.
- Before promoting a row, audit source and traces for benchmark-specific PCs or
  local branch exceptions. A hot PC may appear in the explanation, but the RTL
  rule must apply to a class of frontend ownership/delivery cases.
- Enforce the rule in the harness, not only by review. Long runs must use
  `tools/run_benchmarks.py --run-class signoff` with
  `tests/benchmarks/stage1_signoff.json` or the checked-in coverage manifest,
  plus `--plusarg PERF_PROFILE --plusarg PERF_COUNTERS --plusarg STAT_DUMP`
  so loop-buffer-zero and bottleneck-counter gates are observable.
  The runner now records HEX/ELF SHA-256, git status, exact command, endpoint
  fields, loop-buffer activity, and the anti-overfit verdict. `--run-class dse`
  is allowed for exploration, but those rows remain evidence only.

Minimum acceptance loop:

1. Name the measured limiter before the change.
2. Add a bottleneck-hypothesis row before touching RTL: expected movement for
   `packet_empty`, `packet_empty_f2_data`, `packet_empty_noemit_dup`,
   `redirect_recovery`, frontend average/zero, and commit average/zero.
3. State the fetch/decode/rename/dispatch/issue/commit counter expected to move.
4. Run Dhrystone 300 and CoreMark iter10 with `flags=0`.
5. Verify retired instruction counts against the fixed MegaBOOM rows.
6. Verify CoreMark endpoint identity. `flags=0` is necessary but not sufficient
   for iter10 comparison; the final checksum must remain `64687` for the
   current apples-to-apples heavy image.
7. Verify the CoreMark image identity; current checked-in signoff uses
   `tests/hex/coremark_iter10.hex`, not the stale failing artifact under
   `benchmark_results/item12_baseline_coverage_20260503/images/`.
8. Run broader coverage/probes before declaring the mechanism accepted.
9. Reject benchmark-PC special cases, global static-direction shortcuts, and
   workload-specific plusarg cocktails.
10. Record the anti-overfit verdict for the row: accepted general mechanism,
    rejected shortcut, or DSE evidence only.
11. Archive the harness-produced `results.json`, `summary.md`,
    `perf_profile_summary.md`, per-row `result.json`, `command.txt`, and
    `env.txt` under the unique run directory.

Cleanup and completion harness for long runs:

The long-run agent must separate scoreable evidence from stale workspace noise
before it declares Stage 1 achieved. Cleanup is not a substitute for passing
performance gates; it is a final audit step that proves the row being reported
is the intended row.

1. Use one unique run directory per candidate, for example
   `benchmark_results/signoff_<run_id>/`, and cite only artifacts inside that
   directory for the completion claim.
2. Before reading performance, confirm the run was launched through the gated
   signoff harness:
   `python3 tools/run_benchmarks.py --runner dsim --run-class signoff --manifest tests/benchmarks/stage1_signoff.json --plusarg PERF_PROFILE --plusarg PERF_COUNTERS --plusarg STAT_DUMP --mechanism-name <general_mechanism> --run-id <run_id>`.
3. Confirm `results.json` exists and every Stage 1 row has `gate_status=PASS`,
   `status=PASS`, expected checksum/flags/iterations/control fields, matching
   HEX/ELF SHA-256, `loop_buffer_active=0`, `decoded_op_active=0`, and the
   canonical decoded-op telemetry label
   `Standalone decoded-op replay active:`.
4. Confirm the performance claim uses benchmark timed cycles, not total shell
   runtime or stale stdout snippets. The accepted row must beat both the old
   clean loop-buffer baseline (`70,783` Dhrystone 300 and `1,850,040`
   CoreMark iter10 timed cycles) and the corrected MegaBOOM rows (`59,698`
   Dhrystone 300 and `1,835,815` CoreMark iter10 timed cycles).
5. Confirm the mechanism is general RTL. The final row must not depend on
   benchmark-PC constants, stale images, `--run-class dse`, debug traces, or a
   plusarg cocktail that is not named and allowed as one general mechanism.
   `ENABLE_UOC`, `UOC_UNSAFE_STREAM`, `UOC_ALLOW_CONTROL`,
   `UOC_ALLOW_PARTIAL_GROUPS`, `ENABLE_SAME_FTQ_TAIL_CARRY`,
   `ENABLE_SAME_FTQ_TAIL_BYPASS`, `ENABLE_SAME_LINE_FTQ_HANDOFF`,
   `ENABLE_XS_SAME_LINE_LOOKAHEAD`, and `ENABLE_XS_SEQ_LOOKAHEAD` are
   hard-forbidden for signoff because they let a standalone decoded-op source or
   local fetch shortcut hold/redirect/deliver work without the FTQ/IBuffer
   ownership contract. Use them only as DSE evidence, never as the long-run
   completion path.
6. Run a workspace hygiene preflight before deleting anything:
   `ps -eo pid,ppid,stat,etime,cmd | rg 'dsim|run_benchmarks|build_dsim|run_dsim|xsim' || true`.
   If any simulator or benchmark runner is active, do not delete
   `benchmark_results/`, `dsim_work/`, root logs, waves, metrics, or generated
   images.
7. Safe final cleanup, only after no active simulator process remains, is
   limited to root-level transient outputs such as `dsim_run.log`,
   `dsim_build.log`, `dsim.env`, `metrics.db`, `run.mxd`, `traces/`,
   `__pycache__/`, and rebuildable `tests/**/obj/`. Do not delete the accepted
   run directory or benchmark images cited by the signoff manifest.
8. Record `git status --short` and classify the remaining dirty tree into:
   cleanup deletions, accepted RTL/doc/tooling changes, untracked new harness
   files, and ignored generated artifacts. A dirty tree is allowed during DSE,
   but a completion claim must explain which files are part of the candidate
   and which are unrelated cleanup.
9. Before declaring the goal achieved, write a prompt-to-artifact checklist in
   the doc or final report: each pass condition above must point to a concrete
   artifact (`results.json`, per-row `result.json`, `perf_profile_summary.md`,
   source diff, or command file). If any item points only to memory, intent, or
   an old row, Stage 1 remains open.

Immediate next step:

1. Treat the replay-guard, packet-empty-bypass, same-FTQ tail, and bounded
   sequential-lookahead rows as partial ownership progress, not as Stage 1
   success. Keep the rejected unbounded F2-driven lookahead, same-line FTQ
   handoff, same-FTQ tail carry, guarded single-packet loop-tail shortcut, and
   no-owner-condition shortcut out of default RTL. Audit CoreMark
   checksum/instret identity before promoting any
   loop-buffer-removed row to the new clean baseline.
   The May 5 current-packet-control and FTQ-tag-aware duplicate-suppression
   probes, plus the simple predicted-control owner-hold patch, are now
   rejected evidence, not pending fixes.
2. Treat XS-FE0 counters as complete for the safe default row. The measured
   limiter is now explicit: CoreMark has 803,065 FTQ-empty cycles, 2,091,513
   packet-buffer-empty cycles, max FTQ occupancy of only 2, max packet-buffer
   occupancy of only 1, 694,255 duplicate/no-emit cycles, zero FTQ-full cycles,
   zero packet-buffer-full cycles, and zero backend-stall-with-packet-ready
   cycles.
3. Complete the remaining Step 1A ownership cleanup only where it supports the
   Step 1B/2 rewrite: duplicate suppression, replay guards, allocation gating,
   packet ownership, redirect invalidation, and BPU training must keep exposing
   owner/reason counters. Do not treat Step 1A as the main performance fix; the
   trace and XS-FE0 counters say the remaining bubble needs a structural stream
   and queue.
4. Implement Steps 1B and 2 together as the first scaled XiangShan-style
   structural slice. The goal is a bounded prediction-block stream carried
   through BPU prediction, FTQ allocation, IFU/ICache fetch, IFU
   writeback/validation, IBuffer delivery, backend redirect, commit, and BPU
   training. The first invariant is owner lifetime: an FTQ entry must not be
   considered complete until every required packet for that prediction block has
   either been delivered to decode or flushed by a redirect. The rejected
   owner-hold patch proves this invariant cannot be bolted onto the current
   single FIFO head; Step 1B needs separate allocation, fetch, writeback,
   delivery, and commit/training pointers.
5. Keep standalone UOC/decoded-op replay out of this long-run branch. A decoded
   cache becomes eligible only after an FTQ-approved block can request cached
   decoded work without the cache owning next-PC truth, fetch hold, stream
   exit, or rename-source selection. Until then, inspect example cores for
   BPU/FTQ/IBuffer/control-validation structure, not for a renamed loop buffer.
6. Add PredChecker-style frontend control repair and BPU/FTQ loop-exit
   prediction. These target wrong-path recovery and the Dhrystone `strcpy`
   loop-exit value that the discarded loop buffer previously hid.
7. Only after that, consider decoded-op delivery as an FTQ-attached accelerator
   whose hits are approved by the live fetch-block stream and whose branch truth
   remains owned by BPU/FTQ.

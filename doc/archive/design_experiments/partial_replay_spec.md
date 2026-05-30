# Partial Replay Mechanism — RTL Spec

**Purpose:** Replace full_flush-based recovery from memory-ordering violations
with a selective replay that preserves fetch / decode / rename / dispatch /
ROB state. Target: close the CoreMark IPC gap caused by 3,181 replay events
per 200K cycles.

## Key invariants

1. **Rename is final.** Once an instruction is renamed (`pdst` allocated,
   `old_pdst` recorded, RAT updated), that mapping never changes. Replay
   re-executes; it never re-renames.

2. **ROB entries persist across replay.** `valid_r` stays 1. Only `ready_r`
   is cleared for the violating load and its potential dependents.

3. **Fetch state is sacrosanct.** No fetch redirect. No PC rollback. The
   loop buffer and BPU state remain consistent with the program counter
   stream that was already issued.

4. **Dependency chain is preserved.** A consumer's `src_pdst` value was
   correctly computed at rename time; the consumer just needs to re-execute
   with the producer's *new* CDB broadcast value.

## New control signal bus

```systemverilog
// LSU → top-level → IQ/ROB/PRF-ready-table
logic                    replay_valid;       // 1-cycle pulse
logic [ROB_IDX_BITS-1:0] replay_rob_idx_from; // inclusive starting ROB slot
```

`replay_rob_idx_from` is the ROB index of the violating load. Every ROB
entry *at or younger than* this (in wrap-safe modular ROB order) must be
put back into a pre-execute state.

## Per-module changes

### LSU (`load_queue.sv` + `lsu.sv`)

- Existing `ordering_violation + violation_rob_idx` path already detects
  the event. Route it to the new `replay_valid` bus instead of — or in
  addition to — the commit-exception path.
- Clear `executed` flag in LQ for the violating entry.
  *Optionally* also clear it for all younger valid LQ entries (pessimistic,
  safe). Start pessimistic; tighten later if IPC demands.
- LMB (load-miss buffer) entries younger than the violation may also need
  to be invalidated; initial implementation: let flush-through happen by
  re-issue.

### Commit (`commit.sv`)

- The existing `found_replay` path must NOT reach commit's flush output
  anymore — because LSU will trigger the new replay bus BEFORE the load
  reaches the ROB head.
- Keep the current full_flush path as a fallback for cases where the
  replay signal didn't catch it (defensive). Guard behind an assertion
  that replay should have happened earlier.
- Add a `commit_rob_bcast_valid[0..PIPE_WIDTH-1]` + `commit_rob_bcast_idx[0..PIPE_WIDTH-1]`
  output that signals which ROB entries committed this cycle. IQ uses this
  to free entries that can no longer be replayed.

### Issue Queue (`issue_queue.sv`)

This is the biggest change.

**Entry lifecycle change:**
- Current: `free → ready → (issued, removed from IQ)`.
- New:     `free → ready → issued_unconfirmed → (freed on commit_rob_bcast match)`.

**Select logic change:** issue select picks from `ready && !issued`. Entries
in `issued_unconfirmed` state are NOT candidates.

**Replay handler:**
- On `replay_valid`, walk all entries.
- For each entry `e` with `rob_idx_ge_replay(e.rob_idx, replay_rob_idx_from)`:
  - Transition state: `issued_unconfirmed` → `ready`.
  - Clear `src1_ready`, `src2_ready` if `e.src*_pdst`'s producer has
    `rob_idx >= replay_rob_idx_from`. (See dependency check below.)
- The violating load's IQ entry itself will be one of these.

**Dependency check (simple pessimistic variant):**
Reset `src_ready` for every `issued_unconfirmed` entry with
`rob_idx ≥ replay_rob_idx_from`, regardless of which pdst is the source.
This is over-replay but functionally correct. The over-replayed entries
will wake up again from CDB once their producers (who weren't replayed)
re-broadcast. Wait — that's a problem: producers only broadcast once.

**Refined pessimistic dependency check:**
On replay, for every `issued_unconfirmed` entry with
`rob_idx ≥ replay_rob_idx_from`:
- For each `src_pdst`: look up the pdst's producer's rob_idx via a new
  per-pdst metadata array (`pdst_producer_rob[0..INT_PRF_DEPTH-1]`),
  maintained at rename.
- If producer's rob_idx is *also* `≥ replay_rob_idx_from` (i.e., the
  producer is also being replayed), clear `src_ready`. Otherwise leave
  it set (producer already completed, data still valid).

### ROB (`rob.sv`)

- On `replay_valid`, clear `ready_r[j]` for every entry `j` with
  `rob_in_replay_range(j, replay_rob_idx_from)`. `valid_r[j]` stays.
- Entries will re-become ready when the replayed instructions re-execute
  and broadcast CDB.

### PRF ready table (`rv64gc_core_top.sv` at the `preg_ready_table` site)

- Maintain alongside the table a `pdst_producer_rob[pdst]` array, written
  at rename time.
- On `replay_valid`, clear `preg_ready_table[p]` for every `p` where
  `pdst_producer_rob[p] ≥ replay_rob_idx_from`.

## Modular ROB index comparison

ROB is a circular buffer. "rob_idx ≥ replay_from" in wrap-safe semantics:

```systemverilog
function logic rob_idx_in_replay_range(
    input logic [ROB_IDX_BITS-1:0] candidate,
    input logic [ROB_IDX_BITS-1:0] from,
    input logic [ROB_IDX_BITS-1:0] tail  // ROB's current allocation tail
);
    // Entry is in replay range if it's in [from, tail) going forward in
    // ROB order. Using rob_dist = (candidate - from) mod ROB_DEPTH, and
    // tail_dist = (tail - from) mod ROB_DEPTH.
    logic [ROB_IDX_BITS-1:0] rob_dist, tail_dist;
    rob_dist  = candidate - from;
    tail_dist = tail - from;
    return (rob_dist < tail_dist);
endfunction
```

Use this for every "is this entry at or younger than the violation" check.
`tail` comes from ROB's alloc pointer.

## IQ occupancy concern

Current IQ empties on issue (entries become free). New design keeps them
until commit. At 192-entry ROB and 3×32 = 96 IQ slots, the IQ becomes the
new constraint. Worst case: all 192 ROB entries are issued-unconfirmed and
awaiting commit, but IQ only has 96 slots — rename would stall waiting
for IQ.

**Mitigation:**
- Measure first. Our benchmarks don't hold 192 in-flight simultaneously
  typically; average ROB occupancy is much lower.
- If measurement shows stall-via-IQ, two options:
  - Bump IQ sizes (parameter change, minimal RTL work).
  - Move issued-unconfirmed entries to a separate replay queue (more
    area, frees IQ quickly).
- User guidance: "unless proven performance degradation" — meaning
  we try keep-in-IQ first, measure, and only add a replay queue if
  CoreMark IPC shows the IQ becoming the bottleneck.

## Cost estimate (cycles per replay, pessimistic)

| Phase | Full-flush (current) | Partial replay (new) |
|---|---|---|
| Fetch redirect | 3 cycles (pipeline refill) | 0 |
| Decode | 1 | 0 |
| Rename | 1 | 0 |
| Re-dispatch | 1 | 0 |
| Issue + execute | ~3-10 (depends on deps) | ~3-10 |
| ROB drain | ~5-20 (wait for replayed ops) | ~5-20 |
| **Total per replay** | **~15-35 cycles** | **~8-30 cycles** |

Expected saving per replay: ~7-10 cycles. Over 3,181 replays, that's
~22-32K cycles recovered out of 200K. Yields CoreMark IPC lift of roughly
2-5× from 0.31 baseline.

Note: the biggest practical win is that the ROB STAYS FULL — no bubble
refilling. That indirect effect is where most of the IPC comes from.

## Implementation plan (phased)

### Phase 1 — IQ lifecycle change (no replay yet)
1. `commit.sv`: add `commit_rob_bcast_*` signals.
2. `issue_queue.sv`: add `issued_unconfirmed` state. Route `commit_rob_bcast_*`
   in to free entries on commit. Verify issue select correctly excludes
   `issued_unconfirmed`.
3. Rebuild. Run regression + both benchmarks. Confirm functional + IPC neutral.

### Phase 2 — add replay signal path
4. Add `replay_valid + replay_rob_idx_from` bus in `rv64gc_core_top.sv`.
5. `lsu.sv` / `load_queue.sv`: drive the new bus on `ordering_violation`.
   Clear `executed` on violating LQ entry.
6. Route to IQ, ROB, and the PRF ready table.

### Phase 3 — dependency-precise invalidation
7. Add `pdst_producer_rob[]` metadata at rename.
8. IQ replay handler uses it to selectively reset `src_ready`.

### Phase 4 — measure, tighten, or extend
9. Benchmark. If IPC good → done for this revision. If IQ occupancy is
   limiting → add replay queue or enlarge IQ.

## Risks / things that can break

1. **Pipeline-level atomicity.** Replay signal must fire ATOMICALLY across
   IQ/ROB/LSU/PRF-ready in one cycle. Need careful timing; probably gated
   by a flop.
2. **Multiple concurrent replays.** Two violations same cycle — pick
   the oldest. Straightforward.
3. **Replay while replay in-progress.** If a second violation detected
   while a replay is already settling, need to merge or serialize.
4. **LSU store buffer state.** Stores that committed and were forwarded
   to a now-replayed load — the store data is still in SQ/CSB, safe.
   Confirmed OK.
5. **Speculative wakeup in IQ.** The existing `src_spec` path (from cache
   miss speculation) must co-exist with the replay signal. Review careful.
6. **Watchdog.** The existing ROB head watchdog fires after 64 cycles.
   A long replay sequence that exceeds 64 cycles would (wrongly) fire
   the watchdog. Need to either raise the threshold or gate it on replay.

## Decisions logged per user guidance

- **IQ-keep vs replay-queue:** IQ-keep (Option 1). User guidance:
  "unless proven performance degradation."
- **Invalidation scope:** Precise dataflow (use `pdst_producer_rob`).
  User guidance: "all legit optimizations OK." Starting pessimistic
  costs IQ bandwidth; precise is only marginally more RTL.

# LMB orphan re-probe — fix spec (early-redirect deadlock)

**Date:** 2026-06-05  **Branch:** backend/lq-instrument  **File:** `src/rtl/core/lsu/lsu.sv` only.

## Problem (confirmed via probe)

With BRU early-redirect enabled, CoreMark deadlocks at ~46K instrs. Ground truth from a live-dump probe:
`lmb[0] valid ready=0 rob_idx=122 line=0x800ff640 pc=0x80002250`, **MSHR array empty**. A surviving
load's LMB entry is **orphaned**: its one-shot `dcache_fill_valid` snoop (dcache.sv:44, "fires the cycle a
fill is installed") was missed because the early-redirect partial-flush delayed the load's re-issue past
its fill, so the LMB alloc landed >FILL_BYPASS_DEPTH(4) cycles after the fill. The line is now in L1, but
nothing will re-broadcast the fill → `ready=0` forever → the same-line dual-load partner (the ROB head)
blocks → ROB never frees → total hang. The ROB watchdog can't help (no writeback exists to bypass).

## Fix: timeout-triggered re-probe of an orphaned LMB entry

When an LMB entry has been valid+`!ready` with no fill activity for a long time, re-issue a D-cache load
request for its line via the existing `dcache_load_req` port; on the hit, write it back through the normal
load_wb path and clear the entry. The line is resident now, so the re-probe hits and the load completes.

### Memory-ordering safety (why a raw L1 re-read is correct here — no at-head gate needed)
- A load only reaches the LMB after a FULL cache miss; at its ORIGINAL issue it already passed
  store-queue forwarding (partial-forward loads stall, they do not allocate an LMB entry; our run shows
  `partial=0`). So the load had no older *uncommitted* same-address store to forward from.
- Program order is fixed: no NEW older store can appear after the load issued.
- L1 is **write-through** (dcache `wt_*` queue + `fill_snoop`); committed stores update L1 immediately.
- Therefore re-reading L1 returns data consistent with all committed stores and with the load's already-
  resolved forwarding — identical to what the lost fill would have delivered. The re-probe reuses the
  normal `dcache_load_req` port, inheriting existing load/store port arbitration.

## Implementation (all in `src/rtl/core/lsu/lsu.sv`)

1. **Gate** behind a new `parameter logic LMB_REPROBE_ENABLE = 1'b0` on the `lsu` module (add to the
   `#(...)` list; pass `1'b1` from the core only when early-redirect is enabled — but for THIS task the
   core wiring stays default, so the param defaults 0 = byte-identical to today). Also allow a sim plusarg
   `+LMB_REPROBE` (OR'd in under `ifdef SIMULATION`) so it can be exercised without a param change.
   Net `lmb_reprobe_en = LMB_REPROBE_ENABLE || sim_lmb_reprobe`.

2. **Orphan detector.** Add a saturating counter `lmb_stall_cyc` (e.g. `[9:0]`). Increment when
   `lmb_reprobe_en` and there exists a valid+`!ready` LMB entry AND no fill/drain/alloc activity this
   cycle (`!dcache_fill_valid && !lmb_any_match && ...`); reset to 0 on any LMB drain/fill/alloc.
   Declare `lmb_orphan_trigger = lmb_reprobe_en && (lmb_stall_cyc >= REPROBE_THRESHOLD)` with
   `localparam REPROBE_THRESHOLD = 10'd512` (well above worst-case L2/mem latency, so a legitimately
   in-flight miss is never re-probed). Pick the lowest-indexed valid+`!ready` entry as
   `lmb_reprobe_idx` (combinational priority scan, like `lmb_free_idx`).

3. **Re-probe request.** In the `dcache_load_req_*` driving block, when `lmb_orphan_trigger` and load
   port 0 is NOT issuing a normal load this cycle (`!<normal port-0 req>`), drive:
   `dcache_load_req_valid[0]=1`, `dcache_load_req_addr[0] = {lmb[idx].line_addr[63:LINE_BITS], lmb[idx].byte_offset}`,
   `dcache_load_req_size[0]=lmb[idx].size`, `dcache_load_req_is_unsigned[0]=lmb[idx].is_unsigned`.
   Register `reprobe_inflight`, `reprobe_idx_r` for the 1-cycle D-cache latency. Do NOT issue a re-probe
   while one is already in flight.

4. **Re-probe completion.** Next cycle, if `reprobe_inflight` and `dcache_load_resp_valid[0]` (hit):
   route into the load_wb path a writeback with `rob_idx/pdst/byte_offset/size/is_unsigned` from
   `lmb[reprobe_idx_r]` and data extracted from `load_resp_data[0]`; clear `lmb[reprobe_idx_r].valid`.
   Mux this into the existing `load_wb_valid[0]`/`load_wb_rob_idx[0]`/`load_wb_data[0]` generation with
   LOWER priority than a real port-0 load_wb (re-probe only fires when port 0 is otherwise idle, so no
   conflict). If instead `dcache_load_miss_retry[0]` (line was evicted again — rare): leave the entry
   valid, clear `reprobe_inflight`; the dcache will allocate an MSHR and the normal fill-match path
   completes it (the timeout re-arms if needed).

5. **Sim counter** (under `ifdef SIMULATION`): `reprobe_fires`, `reprobe_hits`, `reprobe_retries`,
   printed in a `final` block, so the DSim run shows the mechanism engaged and recovered the load.

## Validation ladder (controller runs DSim)
- `bash scripts/lint_unoptflat.sh` → expect 15 (no new comb-loop).
- Build; run CM-iter1 with early-redirect ON + `+LMB_REPROBE` → **deadlock must clear, PASS at tohost**,
  `reprobe_hits>0`.
- RV compliance(113) with early-redirect+reprobe ON → 113/113.
- Stage-3 guard (CM/DS) bit-exact vs commit-flush baseline, ≤1% → no regression.
- ENABLE=0 / no-plusarg path must remain byte-identical (the param defaults off).

## Out of scope (this task)
Wiring `LMB_REPROBE_ENABLE` to the core's early-redirect param; the rest of the early-redirect backend
recovery (this fix only removes the load-orphan deadlock so the early-redirect path can make progress).

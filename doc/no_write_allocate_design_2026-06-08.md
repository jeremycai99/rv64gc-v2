# No-Write-Allocate (write-validate) — store-commit-bandwidth lever

**Goal:** lift the store-commit ceiling ~0.36 → ~1.0 stores/cyc on the store-bound CoreMark-PRO
workloads (nnet/loops/linear_alg/cjpeg). Confirmed lever (A/B battery 2026-06-08): the store-bound
ceiling is immune to SQ depth, L1D capacity, and L2 latency; the misses are **compulsory streaming
full-line writes** (linear_alg store-misses byte-identical at 64KB vs 256KB; ~0 loads → pure write
phase). Today the D-cache is write-through + **write-allocate**, so each cold streaming line pays a
read-for-ownership FILL **plus** the write-through = 2 L2 transactions through the single-outstanding
L2 FSM. The FILL is pure waste (the store overwrites the whole line).

## Mechanism: write-validate full lines (gated, default-off)

`localparam logic NO_WRITE_ALLOCATE_ENABLE = 1'b0;` (rv64gc_pkg.sv). When ON:

1. **Defer the fill on a store-miss** (dcache.sv:1231-1242 store-miss MSHR alloc): allocate the MSHR
   with `store_pending=1`, accumulate `store_line_data/mask`, but **do NOT set `fill_pend`** (skip the
   read-for-ownership) — wait to see if write-combining fills the line.
2. **Accumulate** on subsequent same-line store merges (dcache.sv:1254-1255) — `store_line_mask |= new`.
3. **Write-validate on mask-full**: when `store_line_mask == {all ones}` (full 64B defined by stores),
   install the line directly from `store_line_data` (no fill) + enqueue the existing write-through
   (`st_wt`) to L2 + free the MSHR. The line is fully defined → no garbage, coherent via write-through.
4. **Load-upgrade fallback** (safety): if a load misses to a deferred store-MSHR (it needs bytes the
   stores haven't covered), set `fill_pend=1` → fetch the line (revert to write-allocate for that line).
   With ~0 loads in the pure-store phase this is rare; it preserves correctness for read-modify-write.
5. **Evict/age fallback**: if a deferred store-MSHR must free its slot (MSHR pressure) before mask-full,
   set `fill_pend=1` (fetch) — never write a partial line without the rest.

Net: pure streaming full-line stores skip the FILL (1 transaction instead of 2) → ~2x store-commit
throughput. Partial-line and read-then-write stays write-allocate (unchanged, safe).

## Correctness surface
- **Only full-mask lines write-validate** → every byte defined → no stale data.
- **In-flight forwarding**: a load to a line still accumulating in a store-MSHR upgrades to a fill (4),
  so it gets the architectural line; the existing MSHR/CSB store-forward covers the stored bytes.
- **Coherence**: written data goes to L2 via the unchanged write-through path; L1D install is a fully-
  defined line. No change to the LQ ordering / partial-flush recovery machinery (the store path is
  post-commit).
- **OFF (default)** → byte-identical to today (the defer/validate logic is gated).

## Validation ladder
1. lint_unoptflat = 15 (no new comb loop).
2. RV compliance 113 (esp. rv64ua AMO/LR-SC — atomics interact with the store path).
3. CM/DS bit-exact vs baseline at ENABLE=0; ≤1% no-regression at ENABLE=1 (store-light → ~free).
4. Store-bound workloads ENABLE=1 vs 0: linear_alg/loops/cjpeg/nnet — do store-commit rate + IPC rise
   toward ~1.0 stores/cyc? (the lever's success metric).
5. Boot (paged) clean, no wedge (kernel page-zeroing/memcpy are streaming stores — likely a cross-benefit).

## A/B
ENABLE is a localparam (compile-time). Build a dedicated arm (verilator_bench_nwa) vs baseline; measure
sta_issue/store_req/stores-committed-per-cyc + sq_full% on the store-bound workloads.

## >>> IMPLEMENTATION FINDING (2026-06-09) — SCOPE IS LARGER THAN A DCACHE TWEAK

Reading the store-completion path changed the picture. `store_ack_s1` (dcache.sv:911) fires ONLY on a
cache HIT or the same-cycle fill-merge — a store-MISS is **held in the CSB (LSU) and re-presented every
cycle until its line is resident** (comment dcache.sv:890-894). Consequences:
1. **Write-validate-via-merge is blocked by CSB serialization.** The first missing store to a cold line
   is held (not acked); the CSB won't present the subsequent same-line stores, so the line can't be
   completed by merging → the deferred-fill + mask-full-validate plan does not work as-is.
2. **The bottleneck is serialization OVERHEAD, not fill latency** — confirmed by the A/B: L2-latency
   8->2 was FLAT on linear_alg. So the ~0.36 stores/cyc ceiling = (CSB holds the missing store for the
   whole fill) x (single-outstanding L2 FSM, ~fixed overhead per transaction), latency-insensitive.

REVISED LEVER (multi-component): the store-commit lever requires BOTH
  (a) **per-store write-around** — a missing store ACKs immediately (writes its bytes toward L2 via a
      write-combining buffer) instead of being held for a read-for-ownership fill; AND
  (b) **a write-combining buffer + multi-outstanding L2** — to sustain throughput (combine same-line
      stores into one L2 write; let multiple L2 transactions overlap so the single-FSM serialization
      doesn't re-cap it).
This touches the **CSB store-completion (LSU) + D-cache store path + the L2 transaction FSM** — a real
multi-component microarchitecture change, not a localized dcache edit. Scope/plan accordingly (brainstorm
-> spec -> task-by-task implement with the validation ladder), rather than a single patch.

STABLE CHECKPOINT (this session): the design + the confirmed write-through policy + the gated param
`NO_WRITE_ALLOCATE_ENABLE=1'b0` (inert, lint 15, byte-identical baseline). The multi-component
implementation is the next focused effort.

## >>> IMPLEMENTATION ROUND 1 (2026-06-09) — first cut + adversarial review findings

Implemented a first NWA cut in dcache.sv (MSHR `nwa_pending` flag; deferred-fill alloc; immediate
write-around ack `nwa_store_accept`; write-validate install `nwa_validate_avail`; load-upgrade +
pressure-upgrade fallbacks). Lint clean (UNOPTFLAT=15), ENABLE=0 byte-identical (all gated). An
adversarial code review (feature-dev:code-reviewer) found the first cut is **NOT shippable at ENABLE=1**:

- **CRITICAL Bug 1 — L2 corruption.** The cache is write-through and **L2 has no byte-mask write port**
  (`l2_req_we`/`l2_req_wdata` only; `data_ram[set][way] <= arb_wdata` is a full-line replace,
  l2_cache.sv:791). A store MISS has no full line to write, so the per-store write-around enqueues
  `st_wt_line_data='0` (dcache.sv:857-863, the `!st_cache_hit` arm) → a ZERO line drains to L2 and
  clobbers the non-stored bytes. **Root constraint: stores must reach L2 as FULL LINES.**
- **CRITICAL Bug 2 — AMO deadlock.** `fill_snoop_valid = fill_done_avail` only (dcache.sv:1150); it does
  not fire on `nwa_validate_avail`, so an AMO load that completes via a write-validate install never
  wakes the AMO FSM (lsu.sv amo_load_fill_fire) → hang (AMOs bypass the LMB re-probe).
- **HIGH Bug 3 — normal load 512-cyc LMB stall** (same fill_snoop gap).
- **HIGH Bug 4 — PLRU not updated on nwa_validate install** → the freshly installed line is the next
  victim → thrash (every nwa line evicted on the next miss to its set).

## >>> CORRECTED DESIGN (Option A — full-line write-through at completion; no L2 change)

Stores must reach L2 as full lines, so NWA accumulates the full line in the MSHR overlay and
write-throughs ONCE, at install, instead of per-store:
1. **Suppress the per-store nwa WT** — `nwa_store_accept` acks the store (bytes captured in the overlay)
   WITHOUT enqueuing a write-through; decouple `store_ack_s1` from `st_wt_enq_ready` for the nwa arm.
2. **Inject a full-line WT at install** — when `nwa_validate_avail` installs (overlay = full line) OR an
   ex-nwa MSHR's fill installs (`nwa_wt_owed` flag, set at nwa alloc, survives upgrade, cleared on
   free), enqueue ONE full-line WT (`st_wt_enq_full_line=1`) of the installed line. Arbitrate vs a
   concurrent store-hit WT (install priority; the store holds one cycle — rare, ~1 WT per 8 stores).
3. **fill_snoop_valid |= nwa_validate_avail** (addr/data muxed to the validating MSHR) — fixes Bug 2/3.
4. **PLRU update arm for nwa_validate** install (mirror the fill_done arm) — fixes Bug 4.
5. **Exclude atomics (AMO/LR/SC) from `nwa_store_accept`** — force them through the legacy fill path
   (they read-modify-write the line; not the streaming bottleneck). Needs the store-port is_amo signal.

ENABLE=0 must stay byte-identical at EVERY step (validate after each edit). L2 stays unchanged (it
already handles full-line writes). Note: even corrected, NWA alone is S1-bubble-capped at ~0.5 ack/cyc
=> ~1.0 IPC on sf~0.5 workloads (per the feasibility verify); the S1-fix + dual-port are still required
for linear_alg/loops to reach 2.0. cjpeg/nnet (lower sf) may clear with NWA+S1-fix alone.

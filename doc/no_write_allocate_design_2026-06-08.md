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

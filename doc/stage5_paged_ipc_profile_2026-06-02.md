# Stage 5 — Paged-Mode IPC Bottleneck Attribution

**Date:** 2026-06-02
**Source run:** `linux_boot_results/stage5_perf_capture_20260601_211436` (full DSim boot, BOOT OK, 277 `[PERF_PROFILE]` + 277 `[LINUX_STATUS]` interval samples).
**Instrumentation:** sim-only `mmu_mem_profiler` + `fetch_frontend_profiler` fe_stall split (Stage 5 branch `stage5/paged-ipc-instrumentation`). Core verified bit-identical to RC (113/113 compliance, 16/16 signoff, cycle-identical).
**Tool:** `tools/paged_ipc_profile.py`.

## Headline

| Metric | Value |
|---|---|
| Overall boot IPC | **0.900** |
| Paged (S-mode) mean IPC | **0.758** |
| MMU-off (early M-mode) IPC | ~2.08 (≈ CoreMark 2.18) |

The IPC collapse is paged-mode-specific and the dominant cause is now identified.

## Ranked paged-mode stall attribution (lost-cycle proxy)

```
fe_stall_xlate     131,220,667   <- DOMINANT (~47% of all boot cycles)
fe_stall_backend     8,084,625
dcache_misses        1,018,801
fe_stall_icache        996,051
```

Sanity invariants PASS: `itlb_misses <= itlb_lookups`; `fe_stall_xlate + fe_stall_icache + fe_stall_backend == fe_stall_total` (every interval).

## Verdict: the bottleneck is the fetch translation **stage**, not TLB/cache misses

`fe_stall_xlate` counts cycles where `instr_translation_stall` is high =
`instr_vm_active && f1_valid && !flush && !vm_req_valid_r` (ifu_line_fetch.sv:175) —
i.e. **a fetch is presenting an address but the physical icache request has not yet
launched because address translation is still in progress.** Under paging the fetch
path serializes (present VA → translate → *then* assert `icache_req_valid`, which gates
on `vm_req_valid_r`); in bare mode that stage is bypassed (`!instr_vm_active` lets the
icache request fire immediately). This is precisely why MMU-off IPC ≈ 2.08 and MMU-on
IPC ≈ 0.89.

Two pieces of evidence prove this is a **structural per-fetch translation-stage cost,
not an ITLB-capacity / miss problem**:

1. **`fe_stall_xlate / itlb_lookups` is a dead-constant ~0.98** across the entire boot
   (interval samples: 45.15M/46.16M, 70.10M/71.11M, 94.44M/95.57M, 118.69M/120.02M).
   The translation stall scales with fetch **volume**, not with misses.
2. **`itlb_misses` is frozen at 177,829** from ~cyc 100M onward — the 16-entry ITLB hits
   ~100% on the hot kernel working set. Fetch is stalling on translation even when the
   ITLB *hits*.

So enlarging the ITLB would **not** move IPC. The lever is the **fetch translation-stage
pipelining**: the VA→translate→icache-request serialization adds a stall on ~98% of
paged fetch cycles. Candidate Stage 5b directions (to be scoped in a separate spec, each
gated on the ≤0.01% benchmark no-regression invariant):
- Overlap translation with the icache request (parallel ITLB lookup + tag access, i.e.
  a VIPT-style fetch) so the translate cycle is not serialized ahead of the icache req.
- Pipeline `vm_req_valid_r` so a translated request launches the cycle after lookup
  without bubbling the front end.
- Confirm whether `instr_translation_stall` reflects a true extra cycle per fetch or a
  handshake/back-pressure artifact in the VM fetch FSM (read ifu_line_fetch VM path).

## Secondary signals

- **`fe_stall_backend` (8.1M, ~3%)** — back-pressure stalls; small, not the story.
- **`dcache_misses` (1.02M over 59.8M load accesses, ~1.7%)** — D-side is healthy; rules
  out a data-cache explanation. (This counter was re-tapped during Stage 5 after the
  original `load_resp_valid`-based tap was found structurally hit-only.)
- **`fe_stall_icache` (1.0M, ~0.7%)** — I-cache supply is NOT the bottleneck; the L1I +
  next-line prefetch hold the kernel footprint well.
- **flushes:** `flush_commit` 2.31M (trap/exception/sret path), `flush_bru` 0,
  `flush_satp` 8. Trap/flush overhead is negligible — consistent with the earlier
  coarse finding (~2,000 trap events).

## KNOWN INSTRUMENTATION BUG — `ptw_busy_cycles` is unreliable (do not use)

`ptw_busy_cycles` reports 257.3M/277M (93%), which is **a stuck-flag artifact, not real
PTW occupancy**: in the first paged interval alone it accrues 15.8M busy cycles against
~27K walks (~580 cyc/walk), and mid-boot it adds ~9.9M busy cycles/interval against
+0 ITLB and ~1,835 DTLB walks. Root cause: `ptw_busy_r` is set on walk-start and cleared
on fill/fault, but a walk terminated by `flush_i` / `translation_flush_i` ends WITHOUT
asserting fill or fault, so the flag never clears and saturates high.

This counter was **deliberately excluded from the ranked attribution**, so it does not
affect the verdict above. But it must be fixed before any Stage 5b work reads PTW
latency: add the PTW flush signals to `ptw_walk_end` in `mmu_mem_profiler.sv`
(`ptw_busy_r` should clear on `flush_i || translation_flush_i` too). `ptw_walks_itlb`
(6,300) and `ptw_walks_dtlb` (117,837) walk *counts* are trustworthy; only the
*busy-cycle* accumulator is broken.

## Conclusion

Paged-mode IPC (0.90) is dominated by a **fetch translation-stage stall** that fires on
~98% of paged fetch cycles regardless of ITLB hit/miss — a structural serialization of
the VM fetch path, not a TLB/cache capacity problem. Stage 5b should target overlapping
translation with the icache access (VIPT-style fetch / pipelined `vm_req_valid_r`), NOT
enlarging the ITLB. The `ptw_busy_cycles` counter needs a one-line flush-clear fix before
it can be trusted for PTW-latency analysis.

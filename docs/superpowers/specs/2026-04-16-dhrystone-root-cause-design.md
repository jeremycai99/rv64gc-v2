# Dhrystone Root-Cause Investigation — Design Spec

**Date:** 2026-04-16
**Status:** Approved (sections 1+2), executing auto-mode

## Goal

Find the ROOT ORPHAN physical register that leaves Dhrystone's pipeline deadlocked once the store-encoding aliasing bug (decode_slice.sv:50) is removed. Name the specific dynamic instruction, pin the mechanism, and state a falsifiable fix hypothesis. Do NOT commit any RTL fix yet.

## Phase B — Diagnostic Run (this session)

**Protocol:**
1. Apply decode fix (`rd_arch=0 when !rd_valid`) temporarily in `decode_slice.sv`.
2. Add probes below to `src/tb/tb_top.sv` (no RTL semantic changes; all gated on `+TRACE_COMMIT`).
3. Build xsim, run Dhrystone with `MAX_CYCLES=10000 +TRACE_COMMIT`.
4. Collect chain dumps at first 3-5 WDOG fires.
5. Identify root orphan and mechanism.
6. REVERT the decode fix before committing anything to RTL.
7. Commit the diagnostic probes only (safe — they're testbench-only).

### Probes

**P1. Per-`rob_idx` instruction-info snapshot.**
`insn_info[ROB_DEPTH]` array captured on rename: `{pdst, rs1_phys, rs2_phys, rd_arch, rs1_arch, rs2_arch, PC, rd_valid, is_load, is_store, is_branch, cyc_renamed, cyc_issued, cyc_broadcast}`. Cleared on full_flush.

**P2. CDB broadcast ring (256 entries).**
`{cyc, pdst, PC}` appended on every CDB broadcast. Used to answer "was this pdst written recently?"

**P3. Reverse-dep-chain dump at WDOG fire.**
Walk from stuck head's rs1/rs2 back through producers, up to 16 hops. Print at each hop: pdst, producer rob_idx (if found), producer PC, producer's own rs status. Terminate at first ORPHAN (no producer found in insn_info).

**P4. LSU pipeline state dump at WDOG fire.**
If the stuck head is a load and NOT in any IQ, dump LSU/LQ/dcache state: LQ entry for its rob_idx, addr_valid, data_valid, waiting_for_fill, MSHR allocation, L2 state.

**P5. pdst alloc/release event log (ring, 1024 entries).**
`{cyc, event_type, pdst, rob_idx, PC}`. event_type ∈ {ALLOC, COMMIT_RELEASE, FLUSH_RESTORE, CDB_WRITE}. Answers "when was pdst X allocated and is there a matching release?"

**P6. Flush snapshot.**
On `flush_out.valid && flush_full`, log: cycle, redirect_pc, flush reason (mispredict/exception/replay/IRQ), rob_head range being squashed, list of spec-in-flight pdsts (from insn_info) that will be restored.

**P7. LSU in-flight pipeline census.**
At WDOG fire, scan LQ and SQ entries: for each, log `{rob_idx, PC, stage, address, data_ready, waiting_on_fill, mshr_idx}`. Find producers that are "in LSU but stuck."

**P8. MUL/DIV pipeline state.**
At WDOG fire, dump current state of MUL and DIV units: `{valid, rob_idx, cycles_elapsed, pdst}`. Rules out long-latency ALU stalls.

**P9. Dispatch-queue census.**
At WDOG fire, scan DQ int and mem FIFOs: `{head, tail, count, entries with rob_idx}`. Finds producers stuck in dispatch queue waiting to enter IQ.

**P10. IQ global census.**
At WDOG fire, scan ALL entries of IQ0/IQ1/IQ2/IQ_LOAD/IQ_STORE that have the stuck chain's pdsts as rd. Report their src1/src2_ready states. Answers "is the producer waiting on its own source?"

### Runtime

- Dhrystone, 10000 cycles, `+TRACE_COMMIT`.
- At ~1504 cycles first WDOG fires. Dump the chain.
- Collect 3-5 WDOG fires; compare chains.
- If chains converge on same root orphan each time → stable mechanism.
- If chains differ → multiple independent orphans; instrument further.

## Success Criteria (Phase B)

1. The root orphan is named: `{PC, rd_arch, pdst, cyc_renamed, reason_never_written}`.
2. Mechanism is statable in one paragraph with evidence from the probes.
3. A one-line falsifiable fix hypothesis is produced.
4. Both CoreMark and Dhrystone ground-state run cleanly with the probes on (no noise, no performance impact on non-trace runs).

## Phase A — Validation (separate follow-up session)

Applied only after Phase B identifies the root orphan AND a fix hypothesis is designed. Validation must show:
- CoreMark ≥ 3.9 IPC on xsim 500K cycles.
- Dhrystone IPC materially > 0.98 (target 3.2).
- 23/23 regression PASS.

If Phase A fails any criterion, revert the fix and report back. Do NOT iterate locally without checking in.

## Hard Constraints (restated)

1. CM ≥ 3.9 IPC hard floor — any fix that regresses below is reverted.
2. Any "pure degradation" attempt (CM drops, DH unchanged) is reverted.
3. Root cause must be understood before fix — no speculative patches.

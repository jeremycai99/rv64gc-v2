# Stage 4 Performance Campaign Plan

Date: May 28, 2026
Status: ACTIVE. This is the Stage 4 plan of record. It **supersedes**
`stage4_performance_exploration_2026-05-28.md`, which is retained only as a
failed-attempt log (two quarantined DSE branches), not a plan.

## 0. Why this plan exists

A prior session's Stage 4 work did not pan out and was rolled back to the Stage
3 boot-OK baseline. Verified: `master` HEAD `63adbb3` has `src/rtl` byte-
identical to the Stage 3 boot-OK commit `ce93aea` — the Stage 4 commits added
only docs/artifacts, no promoted RTL. Two branches were tried and rejected:

- **LSU SQ-owned load gate** — zero cycle movement (the suppress path was
  already SQ-CAM-driven; the branch touched a redundant top-level proxy).
- **IQ2 ALU ready-at-enqueue bypass** — CoreMark regressed 0.18%
  (150,396 → 150,667); local counter moved, global `dep_wait_on_alu` worsened.

Both failures are explained by the root-cause finding in §2.

## 1. Corrected baseline and targets

Baseline artifact: `benchmark_results/stage4_profiled_baseline_20260528a`
(current-tree DSim, full 16-row signoff manifest, strict invariant checks,
`+PERF_PROFILE +PERF_COUNTERS +STAT_DUMP +BOTTLENECK_PROFILE`).

| Row | Timed cycles | Metric | Stretch | Gap to stretch | vs BOOM floor |
|---|---:|---:|---:|---:|---|
| Dhrystone 100 | 18,068 | 3.150 DMIPS/MHz | 4.0 | ~27% | — |
| Dhrystone 300 | 53,047 | 3.219 DMIPS/MHz | 4.0 | ~24% | 3.22 < ~3.93 (behind) |
| CoreMark 1 | 150,396 | 6.649 CM/MHz | 7.5 | ~13% | — |
| CoreMark 10 | 1,459,538 | 6.851 CM/MHz | 7.5 | ~9.5% | 6.85 > ~6.2 (passed) |

Dhrystone is the larger relative gap and the only metric still behind the
competitor floor. The 2026-05-01 "gap is intrinsic / PARTIAL-FLOOR" conclusion
is **superseded**: Stages 1–3 raised Dhrystone +30% and CoreMark +33% over that
sign-off, so real structural wins exist.

This campaign does **not** chase benchmark-shaped thresholds or software
changes. Targets are direction, not contract; the stopping rule is §6.

## 2. Root-cause findings (the evidence this plan is built on)

Verified against current RTL (file:line anchors are current-tree).

**CoreMark = serial single-ALU producer→consumer dependency chain.**
`xs_bottleneck_dep_wait_on_alu` = 915,721 (CM1); `dep_alu_wait_not_issued` =
833,504, of which `producer_blocked_single_alu` = **695,745 (~83%)**. The ALU is
combinational (`alu.sv`), but wakeup goes through the **registered CDB**
(`cdb_wakeup_valid_r`, `rv64gc_core_top.sv:145-151`), a deliberate +1-cycle
latency that breaks the select→ALU→wakeup→re-select combinational loop. So a
dependent ALU chain advances ~1 link/cycle regardless of ALU port count. Stage 2
attribution: **99.4% of producer-blocks are operand-blocked** (producer resident
in the IQ, waiting on *its* operand), only **0.6% ready-not-selected**.

→ **Scheduler-throughput levers cannot move this** (more ALU ports, enqueue
bypass, oldest-ready cross-IQ select, IQ resizing). This is why the IQ2 branch
failed. Only two mechanism classes break a true producer-blocked chain:
**shorten it** (fusion / move-elim) or **speculate through it** (value
prediction). A literal 0-cycle ALU wakeup would re-create the loop the
registered CDB exists to break, so it is treated as a timing-closure risk, not a
free lever.

**Dhrystone = load-bound on store-to-load ordering + load-use latency.**
`xs_bottleneck_dep_wait_on_load` = 14,772 (DS100) / 44,643 (DS300). The gating
term is `p0_sq_order_wait_block = sq_fwd_wait_data_missing ||
sq_fwd_wait_addr_unknown` (`lsu.sv:1482-1485`). In `store_queue.sv:288-310`, when
an older store's address is uncomputed the forwarding scan conservatively sets
the wait over the **whole requested byte mask**, so a load is held even when it
provably cannot alias. The failed SQ-gate branch removed the redundant
top-level proxy (`store_iq_older_than_load`, `rv64gc_core_top.sv:1860-1864`),
not this real path. Speculation hooks are already wired but inert:
`load_issue_spec_past_addr_unknown` is hardwired `2'b00` (`lsu.sv:1831`); ROB
replay ports (`ordering_violation_valid`, `replay_valid`, `replay_rob_idx_from`,
`rob.sv:90-101`) exist but are unused (full commit-time flush today).

**Verified current parameters** (`rv64gc_pkg.sv`): ROB=128, INT PRF=160 (12R/6W),
INT IQ 3×24 (IQ0 dual-select ALU0/ALU1/BRU, IQ1 single-select ALU2/MUL, IQ2
single-select ALU3/DIV/CSR), MEM IQ 3×32, LQ/SQ/CSB=32, NUM_CHECKPOINTS=64,
CDB_WIDTH=4, NUM_BYPASS_SRCS=6, L1D MSHR=16. CDB[3] (ALU3/DIV/CSR) is **not
bypassed** (+1 cycle PRF-read for its consumers). `fusion_detector.sv` (44 KB)
and rename move/zero-elim (`rename.sv` `is_move_elim`/`is_zero_elim`) **already
exist** — Slice 1 extends them, it does not build them.

## 3. Phase 0 — Evidence refresh (entry gate to the ladder)

The 74–88% HEAD_WAIT_BACKLOG taxonomy is from 2026-05-02 and predates the
+30% Stage 1–3 gains; its absolute percentages are stale. Phase 0 re-derives,
on `stage4_profiled_baseline_20260528a`:

1. **Fresh bubble taxonomy** — re-run `tools/bubble_taxonomy.py` and
   `tools/headwait_deepdive.py` on current DS100/DS300/CM1/CM10 traces; report
   the current per-cycle bubble split and head-stall dwell distribution.
2. **Exact-blocker attribution** —
   - CoreMark: enumerate the *specific* dependent op-pairs in the single-ALU
     chain (the crc16 `xor/andi/negw/srliw` bit-serial loop is the known hot
     spot) and classify each as fusible by the existing `fusion_detector`,
     fusible by a new pattern, or irreducible. Confirm move/zero-elim already
     fires where expected. Audit whether the compiler emitted Zicond
     (`czero.*`) — prior binaries had zero despite `-march=...zicond`.
   - Dhrystone: per-byte breakdown of `fwd_wait_addr_unknown` holds — how many
     are *false* aliases provable away by partial-address / byte-mask
     disambiguation vs genuine RAW that needs speculation.
3. **Per-lever ceiling estimate** — upper bound on cycles removable if the
   targeted counter went to zero, per row. No ladder slice proceeds without a
   ceiling estimate; this table is what confirms/re-ranks §4.

**Phase 0 gate:** ranked ceiling table produced; all instrumentation commits are
cycle-identical to baseline (enforced by the data-driven discipline harness).

## 4. The ranked DSE ladder

Default sequence (escalating risk). Phase 0 confirms or re-ranks by ceiling
estimate, but this is the plan's prescribed order.

| # | Target | Mechanism | Spec? | State | RTL touch | Risk |
|---|---|---|:--:|---|---|---|
| 1 | CM | Extend `fusion_detector` pairs + confirm move/zero-elim + Zicond-emission audit | no | extend existing | `decode/fusion_detector.sv`, `rename.sv` | low |
| 2 | DS | Exact SQ disambiguation — per-byte / partial-addr no-alias proving (cut *false* `fwd_wait_addr_unknown`) | no | new | `store_queue.sv:288-310` | low |
| 3 | DS | Memory-dependence / store-set predictor + speculative load past unknown-addr store + replay | **yes** | hooks stubbed | `lsu.sv:557/1831`, `rob.sv:90-101`, LSU replay path | med-high |
| 4 | CM | Selective-squash branch recovery (branch-order checkpoint ownership) | no | new (enabling repair landed) | checkpoint mgr, RAT, free-list | med-high |
| 5 | CM | Value prediction for ALU producers — only if Phase 0 proves the chain is irreducible by 1/4 | **yes** | new | rename, IQ, recovery | high |

**Slice detail**

- **Slice 1 (CM, low):** The crc16 chain dominates `producer_blocked_single_alu`.
  Extend `fusion_detector.sv` with the fusible adjacent pairs Phase 0 identifies;
  verify the existing move/zero-elim covers the move/`mv`/`li 0` cases; confirm
  Zicond emission (compiler flag fix if absent). Shortens the chain → directly
  reduces chain depth. Ceiling set by Phase 0 fusibility count.
- **Slice 2 (DS, low):** Replace the whole-byte-mask conservative hold in
  `store_queue.sv:299-310` with exact per-byte / partial-address overlap so a
  load is held only when an older uncomputed STA can *actually* alias. **No
  speculation, no replay** — keeps the hard gate intact. Targets the false-hold
  fraction Phase 0 measures.
- **Slice 3 (DS, structural, speculative):** Store-set/memory-dependence
  predictor; on low predicted-alias confidence, issue the load past an
  unknown-address older store via the stubbed
  `load_issue_spec_past_addr_unknown` hook, and replay on proven alias via the
  wired ROB replay ports. Primary Dhrystone bet. Requires the §5 replay-gate
  redefinition and the new replay-safety counters/assertion.
- **Slice 4 (CM, structural):** Branch-order checkpoint ownership + selective
  squash to replace full-flush recovery for non-head mispredicts. The enabling
  checkpoint-boundary metadata repair already landed (Stage 2). Attacks the
  ~14.7% mispredict-recovery dwell. Reusable across both workloads.
- **Slice 5 (CM, high, speculative):** ALU-producer value prediction — the
  textbook chain-breaker. Gated: pursued only if Phase 0 + Slices 1/4 show the
  CoreMark chain is irreducible by cheaper means and the residual gap justifies
  the verification + recovery cost.

**Explicitly excluded (REFUTED):** more ALU ports, enqueue bypass, oldest-ready
cross-IQ select, IQ resizing, ROB/PRF capacity growth. The chain is 99.4%
operand-blocked, 0.6% select-blocked — scheduler-throughput levers cannot help.
The reference-core audit also rejects generic width growth (occupancy is low).

## 5. Per-slice promotion gate

Existing 5-step ladder, unchanged in ordering:

1. Rebuild DSim from current RTL (`./build_dsim.sh`).
2. Strict DS100 + CM1 bottleneck smoke (~50 s) — `--runner dsim --run-class dse`
   with `+...STRICT` invariant plusargs + `+BOTTLENECK_PROFILE`.
3. Four-row anchor: DS100, DS300, CM1, CM10.
4. Full 16-row signoff (`--goal stage1 --run-class signoff`, ~9.5 min; CM10
   dominates wall time).
5. **RV64GC compliance + full DSim Linux `BOOT OK` replay** (§7) — the Stage 3
   guard. Run only at final promotion of an accepted slice.

**Promotion criteria:** targeted primary rows improve **≥3%**; DS100/DS300/CM1/
CM10 do not regress beyond the **0.01%** hard gate; fetch owner/stale/delivery/
branch-recovery invariant counters stay clean.

**Replay-gate redefinition (admits Slices 3 and 5):**
- `xs_bottleneck_lsu_ordering_violations` stays **0** (correctness absolute).
- `xs_bottleneck_lsu_replay_valid` arising from a *violation* stays **0**.
- Design-intended `xs_bottleneck_lsu_spec_replays` is **counted and bounded**:
  add `lsu_spec_replay_rate`, which must stay under a per-mechanism declared
  ceiling, and a **no-spurious-replay assertion** proving every replay
  corresponds to a real alias. A replay-based slice that clears +3% but whose
  replay overhead exceeds its gain on any row is rejected (cost-neutrality).

**Predicted-then-measured discipline (harness-enforced):** non-default
`--mechanism-class` signoff requires `--targets-counter` + matching
`--expect-counter-decrease NAME:DELTA` + `--baseline-results`; the harness FAILs
the row if the predicted counter movement does not materialize, even if cycles
improved. Scheduler/LSU work uses the `issue_wakeup_bypass` class (add LSU and
value-prediction mechanism classes + `DEFAULT_COUNTER_EXPECTATIONS` entries as
part of the relevant slice).

## 6. Decision tree, escalation, stopping rule

- Each slice is gated per §5. **Refute → quarantine as DSE-only evidence,
  restore baseline RTL, document, advance to the next rung.**
- **Promote-and-continue:** a promoted slice becomes the new baseline; re-run
  Phase 0 attribution before the next rung, because the dominant bottleneck
  moves after each promotion.
- **Escalate to speculative rungs (3, 5)** only after their cheaper same-target
  rung is exhausted (Slice 2 before 3; Slices 1/4 before 5) and Phase 0 shows
  the residual ceiling still clears +3%.
- **Stop** when either the stretch targets are reached, or every remaining
  rung's ceiling estimate is below the +3% promotion threshold (document the
  residual as the new structural floor).

## 7. Linux boot guard integration

The Stage 3 `BOOT OK` artifact is a full RISC-V Linux boot replay through
`src/tb/tb_linux.sv`, verified by a console-string + failure-marker state
machine (no golden PCs). Authoritative simulator: DSim. Freshest PASS:
`linux_boot_results/stage3_full_mainline_dsim_post_rtl_style_20260527a/`.

Final-promotion guard command (from repo root):

```bash
python3 tools/run_linux_boot.py --run --simulator dsim --build-mode linux \
    --linux-profile full --max-cycles 1000000000 --target-milestone boot_ok \
    --run-dir linux_boot_results/stage4_<slice>_boot_guard_<YYYYMMDD>a
# add --build --build-sim to rebuild the Linux image + DSim sim image first
```

A full-profile boot is ~277.34M core cycles; the single shared DSim lease can
block, so schedule around it or use the Verilator backup
(`verilator_linux_work/Vtb_linux`). For routine pre-promotion confidence, the
`trimmed` profile is the fast regression baseline; `full` is required for the
gate. The guard is a binary regression detector, not a tuning lever — any slice
that does not alter committed architectural state should keep `BOOT OK`
invariant. RTL regions most likely to break it: MMU/PTW, CLINT/PLIC timers,
CSR, LSU ordering (Slices 3/5 carry the highest boot-regression risk).

## 8. Doc and infrastructure hygiene (fold in during the campaign)

- **AGENTS.md "Key Design Parameters" table is stale vs RTL:** ROB 192→128, INT
  PRF 256→160, INT IQ 3×32→3×24, LQ/SQ 64/64→32/32; `fusion_detector` listed as
  "(new ~500 lines)" but is built (44 KB); several "6-wide" descriptions are
  pre-pivot. Reconcile (separate user decision — do not silently rewrite
  guidance).
- `rv64gc_v2_uarch.md`: `NUM_BYPASS_SRCS` prose says 5, pkg says 6; reconcile.
- `rv64gc_pkg.sv:99` `MUL_LATENCY=3` is declared but never referenced (MUL is
  1-cycle) — remove or wire.
- `partial_replay_spec.md` assumes ROB=192 / 3×32 IQ — re-target to the current
  128-ROB / 3×24 INT + 3×32 MEM geometry as part of Slice 3.
- Add a `stage4` goal contract to `tools/run_benchmarks.py` (currently reuses
  `stage1`); populate `tests/benchmarks/stage1_signoff.json` counter targets.
- Add this plan to `doc/README.md` "Current Source Of Truth".

## 9. Deliverables and execution

This document is the design of record. Next step: invoke the writing-plans skill
to produce an executable implementation plan for **Phase 0 + Slice 1 only**
(later rungs depend on Phase 0 data and are planned just-in-time after each
promotion). The campaign then proceeds rung by rung under §5/§6.

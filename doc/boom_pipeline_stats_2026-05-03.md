# Stage 1 Frontend Refactor Status, 2026-05-05

## Verdict

Stage 1 is open. Numbers as of master `c8295c6`:

| Workload | Timed cycles | Score | Stage 1 target | Gap |
|---|---:|---:|---:|---:|
| Dhrystone 300 | 76,738 | 2.225 DMIPS/MHz | < 70,783 | +5,955 |
| CoreMark iter10 | 2,034,653 | 4.915 CM/MHz | < 1,850,040 | +184,613 |
| Dhrystone 100 | 26,394 | 2.156 DMIPS/MHz | sanity row | — |

All 3 rows PASS, `flags=0`, checksums match, golden PC scoreboard PASS,
all 5 owner-identity counter_invariants hold zero.

## Bottleneck (data-driven)

`tools/bubble_attribution.py` on cm10 (commit-stage classification):

| Category | Cycles | % of run | Notes |
|---|---:|---:|---|
| PRODUCTIVE | 1,617,865 | 79.1% | commit > 0 |
| BACKEND_STALL | 230,971 | 11.3% | fetch>0 + commit=0 + rob_cnt>0 |
| FRONTEND_BUBBLE | 115,650 | 5.7% | fetch=0 + rob_cnt>0 |
| IDLE_BUBBLE | 27,976 | 1.4% | fetch=0 + rob_cnt=0 |
| FLUSH | 20,063 | 1.0% | control-flow recovery |
| RAMP | 32,646 | 1.6% | reset/edge cases |

Per-PC BACKEND_STALL attribution shows the dominant stalls are
load-consumer chains in `core_state_transition` and `core_list_mergesort`.
The "branch BACKEND_STALL" cluster is **state-machine branches consuming
a load result**, not loop branches — a loop predictor would not help.

The "97% packet_buf_empty" reading from `xs_packet_buf_empty_cycles`
is a metric artifact: the same-cycle bypass path keeps the buffer empty
even on supply cycles. True decode-supply rate is **58.5%**; true
decode bubble is **41.5%** at the frontend stage, mostly absorbed by
packet_buf+ROB so only 5.7% propagates to commit.

## Architectural finding: frontend-proactive is the answer

User push-back rejected the dcache-latency framing. BOOM and XiangShan
operate at the same load-to-use class (3-4 cycle hit) yet achieve higher
IPC. The differentiator is frontend supply rate, specifically how F1
advances.

Inspecting BOOM v4 `src/main/scala/v4/ifu/frontend.scala` (lines 347-571):

```scala
val s0_valid = WireInit(false.B)
val s1_valid = RegNext(s0_valid)
val s2_valid = RegNext(s1_valid && !f1_clear)
...
when (s2_valid && f3_ready) {
    when (s1_valid && s1_vpc === f2_predicted_target && !f2_correct_f1_ghist) {
        // s0 advances per BPD's predicted target
    }
}
val f3 = Module(new Queue(new FetchBundle, 1, pipe=true, flow=false))
```

BOOM's s0 advances **proactively** based on BPD prediction every cycle.
The f3 queue absorbs rate mismatch with backpressure to s0.

Our equivalent: F1 advances **reactively** from `f2_seq_next_pc` (case
4 in the next_pc priority chain at fetch_unit.sv:170). F1 only advances
when F2 emits. This is the lockstep that limits frontend supply to
~58.5% of cycles.

The "BACKEND_STALL=11.3%" is partially intrinsic but is also a symptom
of low frontend supply: with fewer parallel chains in flight, each
chain's latency manifests as ROB head stall instead of overlapping.
BOOM hides the same load latency behind more parallelism.

## Stage 1 closure RTL plan (BOOM-grounded)

Three coordinated changes in `src/rtl/core/fetch/fetch_unit.sv`:

### 1. F1 proactive next_pc

Replace the priority chain in `next_pc`:

```sv
always_comb begin
    if (redirect_valid)              next_pc = redirect_pc;
    else if (f2_bpu_redirect)        next_pc = f2_bpu_target;
    else if (f2_duplicate_suppressed_c) next_pc = f2_duplicate_next_pc_c;
    else if (f1_valid && !fe_stall) begin
        // F1 RUNAHEAD: advance per F1-stage BTB each cycle
        if (btb_hit && btb_branch_type != BT_COND) next_pc = btb_target;
        else                                       next_pc = next_line_aligned_pc;
    end
    else if (f2_seq_valid && f2_pc_consumed_c)  next_pc = f2_seq_next_pc;
    else                                         next_pc = f1_pc;
end
```

### 2. F2 pc_r decoupling at line boundary

Replace `f2_pc_r <= f1_pc` (line 1267) with conditional update:

```sv
end else if (line_boundary_crossed) begin
    f2_pc_r <= icq_deq_pc;     // queue head's pc on cross-line
end else if (f2_will_emit_c) begin
    f2_pc_r <= f2_seq_next_pc; // within-line advance from F2's own state
end else begin
    f2_pc_r <= f2_pc_r;        // hold
end
```

`line_boundary_crossed` detected when `extract_count` covers remaining
bytes in current line.

### 3. F2 data latch at line boundary

Latch `icq_deq_data` when crossing line boundary; F2 reads from latched
copy within line. `icache_resp_queue` (already wired at commit `bcf9b5c`)
provides the source.

### Predicted counter movement (cm10)

| Counter | Baseline | Predicted |
|---|---:|---:|
| `packet_empty_noemit_dup` | 725,222 | ≤ 50,000 |
| `xs_dup_last_emit` | 783,583 | ≤ 50,000 |
| `xs_ftq_occ_max` | 1 | ≥ 4 |
| FRONTEND_BUBBLE | 115,650 | ≤ 30,000 |
| timed cycles cm10 | 2,034,653 | ≤ 1,800,000 (Stage 1 close) |

The harness gates each retime point: golden PC scoreboard catches
architectural divergence (the unsafe-fix line-skipping pattern from the
prior session); SVA invariants (fetch_unit.sv) catch pipeline timing
violations; counter_invariants enforce zero-asserts.

### Mandatory signoff invocation

```bash
python3 tools/run_benchmarks.py --runner dsim --run-class signoff \
    --manifest tests/benchmarks/stage1_signoff.json \
    --plusarg PERF_PROFILE --plusarg PERF_COUNTERS --plusarg STAT_DUMP \
    --mechanism-class ftq_owned_delivery \
    --mechanism-name f1_proactive_runahead \
    --baseline-results <pre_change_results.json> \
    --targets-counter packet_empty_noemit_dup \
    --expect-counter-decrease packet_empty_noemit_dup:500000 \
    --run-id <run_id>
```

## Harness in place (committed)

| Piece | Commit | Purpose |
|---|---|---|
| `tools/bottleneck_analysis.py` | 5fd8577 | Frontend-stage counter ranking with bypass-corrected view |
| `tools/bubble_attribution.py` | 6b3301c, c3e1305 | Commit-stage cycle classification + per-PC attribution |
| `tools/golden_pc_stream.py` | 8b30714 | Golden generation/verification |
| `tools/image_diff.py` | 8b30714 | Fresh-rebuild divergence triage |
| Golden PC scoreboard (tb_top.sv) | 8b30714 | `+EMIT_COMMIT_PC_HEX` / `+CHECK_GOLDEN_PCS` |
| Counter invariants (manifest schema) | 8b30714 | Manifest-level structural assertions |
| SVA invariants (fetch_unit.sv) | 6b3301c | Pipeline timing assertions |
| Shadow signals (tb_top.sv) | 6b3301c | Pre-RTL change divergence measurement |
| Data-driven discipline rules | 5fd8577 | Reject default_rtl signoff with uncommitted RTL |
| `icache_resp_queue.sv` | b97adb1, bcf9b5c | F1/F2 rate-mismatch absorption (wired transparent) |

## Stage 2 (out of scope for Stage 1)

Targets: 7.5 CM/MHz, 4.0 DMIPS/MHz. Mechanisms:
- BOOM-style loop predictor for genuine loop-boundary branches (e.g.,
  dhrystone strcpy at `0x8000200e`). NOT a loop buffer — BPU-side
  prediction structure that records trip counts.
- ICache prefetch by FTQ entry.
- Optional decoded-op cache (FTQ-attached, never authoritative for
  branch direction).
- Per-PC dcache prefetch for pointer-chase patterns.

## What NOT to do (locked-in lessons)

- No loop buffer revival (architectural decision: loop-exit prediction
  belongs in BPU/FTQ, not frontend replay).
- No standalone UOC / decoded-op cache that's authoritative for branch
  direction (rejected by audit; trips golden PC).
- No same-line/same-FTQ-tail/sequential-lookahead local shortcuts — all
  rejected with documented evidence in archive.
- No backend widening (rename/commit > 4) — backend not constrained per
  counter data.
- No dcache hit latency reduction (2-cycle hit / 3-cycle load-to-use is
  already faster than BOOM; not the differentiator).

## Pointer to history

The detailed iteration history (rejected DSE rows, evidence tables for
the architectural decisions above, prior closure plan revisions) lives
in `doc/archive/boom_pipeline_stats_history_2026-05-05.md`.

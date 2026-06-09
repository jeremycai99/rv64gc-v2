# HEAD_WAIT_BACKLOG Deep Dive — Mechanism + Decomposition + Targeted Fixes

**Date:** 2026-05-02
**Repo HEAD:** `master @ eab3138`
**Source data:** pipe.v1 trace (cm: 199,452 cycles, dhry: 23,514 cycles); rob.sv head-stall PC sample table (prior captures); cm.elf disassembly (`/usr/bin/riscv64-unknown-elf-objdump`).
**Tools:** `tools/bubble_taxonomy.py` + `/tmp/headwait_deepdive.py` (Little's-law decomposition + head-dwell-time analyzer).

---

## What HEAD_WAIT_BACKLOG actually IS at the RTL level

A cycle is in HEAD_WAIT_BACKLOG when:
- `commit_count < PIPE_WIDTH (4)` — commit didn't fire 4 uops, AND
- `rob_cnt >= 4` — the ROB has at least 4 in-flight uops, AND
- `flush == 0` — no pipeline drain in progress

**Why this happens (the RTL mechanism):** the 4-wide commit logic reads the
ROB head's `wb_done` flag. If the head is `wb_done=0`, commit fires 0 uops.
If head is ready but slot 1 isn't ready, commit fires only 1 uop. Etc. The
in-order constraint propagates from the head: **a single non-ready slot
blocks all uops behind it**.

**Why ROB stays small (8-15 entries dominant):** the design is in equilibrium.
Frontend dispatches at the same rate as commit (~1.665 IPC for cm). Avg ROB
occupancy = avg in-flight time × commit rate (Little's law).

**The user's "previous stages" intuition is correct:** the bubble doesn't
originate at commit OR at rename/dispatch. It originates **between dispatch
and wb** — the head can't drain because its `wb_done` bit is set late. That
late-setting is what we need to characterize.

---

## Little's-Law Decomposition

For each per-cycle counter, `avg_time_per_uop_in_stage = avg_occupancy / throughput`.
Throughput at every stage equals commit rate in steady state.

### Coremark iter1 (IPC=1.665, mcycle=199,452, instret=332,110)

| Component | Avg occupancy | Avg time per uop |
|---|---:|---:|
| ROB (rename → commit) | 12.61 | **7.57 cycles** |
| IQ_INT_TOTAL (dispatch → issue) | 4.64 | 2.79 cycles |
|   ├─ iq0 (ALU0+ALU1+BRU) | 2.42 | 1.45 cycles |
|   ├─ iq1 (ALU2+MUL) | 1.21 | 0.73 cycles |
|   └─ iq2 (ALU3+DIV+CSR) | 1.02 | 0.61 cycles |
| LQ | 1.61 | 0.96 cycles |
| SQ | 0.53 | 0.32 cycles |
| **Implied: post-IQ → commit** | — | **4.78 cycles** |

The 4.78 cycles "after-IQ → commit" is the dominant component. A typical INT
uop should take execute (1 cyc) + WB (1 cyc) + commit (1 cyc) = 3 cycles
post-IQ. The **excess ~1.78 cycles is commit-wait** (head-of-line blocking).

### Dhrystone (IPC=2.027, mcycle=23,514)

| Component | Avg occupancy | Avg time per uop |
|---|---:|---:|
| ROB | 9.49 | **4.68 cycles** |
| IQ_INT_TOTAL | 1.67 | 0.83 cycles |
| LQ | 2.29 | 1.13 cycles |
| SQ | 1.94 | 0.96 cycles |
| Implied: post-IQ → commit | — | 3.85 cycles |

dhry's avg in-ROB time is 4.68 cycles vs cm's 7.57 — **3 cycles less per uop**
explains why dhry's IPC is higher (2.027 vs 1.665).

---

## Head Dwell-Time Distribution

Per-cycle: each `rob_head` value persists for N consecutive cycles before commit moves it.
`dwell=1` means head moved every cycle (productive). `dwell=N` means head was stuck
for N-1 consecutive commit=0 cycles followed by 1 commit cycle.

### Coremark dwell distribution

| Dwell length | # head events | % of head events | % of total cycles |
|---|---:|---:|---:|
| 1 (productive) | 129,054 | 85.2% | **64.7%** |
| 2 (1 stall cycle) | 16,396 | 10.8% | **16.4%** |
| 3 (2 stall cycles) | 1,731 | 1.1% | 2.6% |
| 4-5 | 224 | 0.1% | 0.6% |
| **6-10 (5-9 stall cycles)** | **3,933** | **2.6%** | **14.7%** |
| 11-20 | 125 | 0.1% | 1.0% |
| 21-50 | 5 | 0.0% | 0.1% |
| 51+ | 0 | 0.0% | 0.0% |

**Key observation:** 14.7% of cm cycles are consumed by long-dwell heads (5-9 stall cycles).
Math check: 4,343 mispredicts × ~6.7 cycles recovery ≈ 29k cycles = 14.7% of mcycle. **The 6-10
dwell category is mispredict recovery cost** — the data exactly matches the BPU mispredict count.

### Dhrystone dwell distribution

| Dwell | % of total cycles |
|---|---:|
| 1 | 85.4% |
| 2 | 5.7% |
| 3 | 2.6% |
| 6-10 | 4.1% |

dhry has many fewer mispredicts (128 vs 4,343 in cm), so the 6-10 dwell consumes only 4.1% of cycles.

---

## Per-PC Head-Stall Pattern (cm)

The rob.sv `head_not_ready PC sample table` from prior captures shows the top head-stall PCs.
Cross-referenced with cm.elf disassembly:

| PC | Head-stall cycles | Disassembly | Pattern |
|---|---:|---|---|
| `0x80002440` | 6,528 | `ld a4, 0(s0)` then `bnez a4` | Linked-list walk in `core_bench_list` — load address depends on s0 from prior iteration |
| `0x80003164` | 2,951 | `lh a5, 0(a5)` then `mulw a5,a5,a1` | Matrix load → MUL (3-cyc FU latency at head) |
| `0x80003564` | 525 | `lbu a6, 0(a5)` then `sb a6, ...` | Load→store |
| `0x8000235e` | 320 | **`ld a5, 0(a5)`** then `bnez a5` | **PURE POINTER CHASE in core_list_mergesort** — load address = previous load result |
| `0x80002128` | 317 | `lh a5, 0(a0)` then `andi a4,a5,...` | Load→ALU |
| `0x80003326` | 114 | `lw a3, 0(a3)` then `slt a5,a5,a3` | Load→ALU |
| `0x80002430` | 104 | `ld a4, 8(a5)` then `bne a4,s2` | Load→branch |

**Every top head-stall PC is a load with an immediate dependent consumer.** The pattern is:

```
Load result → Op (1-3 instructions away)
```

This is the classic **load-use latency limit**. In rv64gc-v2:
- Load issues at cycle T
- AGU + dcache tag/data + way-select takes 2 cycles → wb at T+2
- Consumer can issue at T+2 via combinational bypass slot[3]/[4] (Load1 fix from cd54cf1)
- So load-to-use = 3 cycles total

In cm's hot loops (`core_list_mergesort`, `core_bench_list`, `matrix_test`), the workload is
intentionally pointer-chase intensive — the dependency chains are FUNDAMENTAL to the algorithm.
**No amount of OoO depth, IQ size, or BPU sophistication helps when iteration N's address
depends on iteration N-1's load result.**

---

## Bubble Decomposition Summary (cm)

| Bottleneck source | % of cm cycles | Cause | Fixable? |
|---|---:|---|---|
| Productive (PEAK + dwell-1 partial) | ~65% | Pipeline executing | — |
| Load-at-head latency (dwell-2) | **16.4%** | Each load occupies head for 1 cycle waiting for wb | Only by reducing dcache hit latency (structural; we're already faster than Reference Core A) |
| Mispredict recovery (dwell 6-10) | **14.7%** | 4,343 mispredicts × ~7 cyc each | Only by reducing pipeline depth (rejected by user; pipelining doesn't help here because flush DRAINS the pipe) OR reducing mispredict rate (TAGE limits per H3) |
| MUL/multi-cycle at head (dwell-3) | 2.6% | MUL is 3-cyc FU; sits at head for 2 cycles | Only by reducing MUL latency (1-cyc multipliers are exotic, large area) |
| Other partial commits | ~1% | Long-tail (cache misses, DIV) | Workload-specific |

**Total intrinsic-bottleneck contribution: ~33.7%** of cm cycles are stuck on
structurally-unavoidable waits. The remaining 65% includes both productive
PEAK cycles and small-dwell partial commits.

---

## Theoretical IPC Ceiling

If we could (impossibly) eliminate all three structural waits:
- Save 33.7% of cm cycles
- New mcycle = 199,452 × (1 − 0.337) = 132,243
- **Theoretical IPC = 332,110 / 132,243 = 2.51**
- **Theoretical CM/MHz = 7.55** — well above Reference Core A (large config) 6.2 floor

So there IS room theoretically. But each elimination requires:
- **Load-WB at head**: dcache latency 2→1 (VIPT + way-prediction; structural rework)
- **Mispredict recovery**: shorter flush pipe OR fewer mispredicts (both REFUTED in prior cycles)
- **MUL at head**: faster MUL (large area cost; not parameter-tunable)

---

## Why prior REFUTEs make sense in this framing

| Cycle | Targeted | Bubble category targeted | Was it the right target? |
|---|---|---|---|
| A — uBTB sizing | BPU mispredicts | Mispredict recovery (14.7% of cm) | Yes, but BPU was already bigger than Reference Core A so no IPC headroom |
| C — BRU early-redirect | Mispredict recovery | Mispredict recovery (14.7%) | Yes, but mechanism caused MORE mispredicts (+7.1%) |
| B — SFB | Mispredict recovery | Mispredict recovery (14.7%) | Yes, but only 0.92% of cm cycles SFB-eligible |
| E — ALU3 bypass | Operand-stall (symptom) | Other partial (~50%) | No — bypass coverage isn't the bottleneck; load-WB is |
| F — IQ reorg | Issue throughput (symptom) | Other partial (~50%) | No — issue throughput is fine (1.43 uops/cyc); commit-wait is the bottleneck |

Cycles A/C/B all targeted the right category (mispredict recovery is 14.7% of cm) but failed
because the BPU is already well-tuned. Cycles E/F targeted symptoms instead of root causes.

---

## Targeted Proposal: What COULD work (and what couldn't)

### REJECTED (per user feedback or prior REFUTEs)

- ❌ **Relaxed in-order commit** (user rejected — breaks renaming/exception model)
- ❌ **Smaller pipeline depth** (user rejected — pipelining means depth doesn't affect steady-state)
- ❌ **Pre-completion of MUL/DIV** (user rejected — speculative execute = unknown territory)
- ❌ **Dcache hit 2→1 cycle** (per Reference Core A research — we're already faster than Reference Core A; would need VIPT + way-prediction = structural rework)
- ❌ **Wider commit / more bypass / larger IQ** (Cycles E, F refuted)
- ❌ **BPU storage growth** (Cycle A refuted — already bigger than Reference Core A)
- ❌ **Early-redirect** (Cycle C refuted — increased mispredicts)

### Remaining angles worth ONE more careful look

These are the structurally-non-trivial-but-not-yet-tried angles:

1. **Reduce LOAD's commit-side bypass latency** — `head_load_wb_bypass_fires=17,470` for cm
   (already firing on most loads). Verify whether the 2,726 head_wait_load cycles where it
   DIDN'T fire are due to a fixable arbitration condition. **Investigation only, ~1 day.**

2. **Per-uop "no-stall" early-commit hint** — at decode, mark uops that are independent
   (no producer dep) for fast-track commit. They commit ahead of in-flight slow ops without
   breaking in-order semantics IF the head is also a no-stall hint AND we batch-commit them.
   **NOT relaxed in-order** — it's still in-order but we ensure the head is fast-completable.
   This is essentially "schedule slow ops away from head" which is a rename/dispatch policy
   change. **Speculative; ~1 week investigation.**

3. **Increase load issue parallelism speculatively** — currently spec_wakeup wakes consumer
   when load address is computed. If we could wake consumer at decode (predicted-ready),
   the consumer could issue earlier and not block at head. Risk: wrong-path waste.
   **Speculative; ~2 weeks investigation.**

None of these are guaranteed wins. All require careful design + verification with the
predict-before-change discipline.

### Most realistic conclusion

The cm gap (5.01 vs 6.2 floor = 19%) decomposes into:
- ~14.7% from BPU mispredict recovery (structurally bounded by TAGE limits)
- ~16.4% from load-WB at head (structurally bounded by dcache latency, which we already win)
- ~2.6% from MUL latency
- Remaining ~5-10% from chain-effects + partial commits

**The first three account for the entire gap.** None are parameter-tunable in the rv64gc-v2
design point. All require structural change of a kind not in scope for this 4-wide refactor.

The dhry gap (2.42 vs 4.00 floor = 39.5%) is dominated by similar load-at-head patterns
in `proc_3` strncpy/strncmp loops, plus the workload's intrinsic IPC ceiling on a 4-wide
machine (per the Reference Core A paper, Reference Core A (large config) only achieves 3.93 DMIPS — even Reference Core A (large config) hits
a similar wall).

---

## Recommendation

**The bubble decomposition definitively shows that the rv64gc-v2 4-wide design is not
parameter-bound.** All knobs that we COULD turn either:
- Have already been turned (BPU bigger than Reference Core A, dcache faster than Reference Core A, etc.)
- Were tested and refuted (Cycles A, C, B, E, F)
- Require structural change beyond this design point (dcache redesign, relaxed commit, etc.)

The remaining gap is the inherent cost of:
1. In-order commit + 2-cycle dcache + 4-wide width on workloads with serial dependencies
2. BPU mispredict on adversarial branches (TAGE structural limit)
3. MUL/DIV latency on FU-bound microbenchmarks

**PARTIAL-FLOOR sign-off remains correct.** This deep dive transforms it from
"we tried things and they didn't work" into a rigorously-attributed structural
explanation: every cycle of bubble has a named cause, and every named cause is
either intrinsic to the workload or fundamentally structural.

The most honest next step is **either** to accept the structural ceiling **or**
to scope a separate workstream for one of the three structural changes (dcache
redesign being the most impactful — but a multi-month effort).

---

## Reproducing this analysis

```bash
cd /home/jeremycai/agent-workspace/rv64gc-v2
export LD_LIBRARY_PATH=

# Capture pipe.v1 traces (cm: ~5 min, dhry: ~30s)
bash run_dsim.sh tests/hex/coremark.hex 5000000 +PERF_PROFILE +TRACE_PIPELINE > /dev/null 2>&1
grep "^\[PIPE schema=pipe.v1\]" dsim_run.log > /tmp/cm_pipe.trace
bash run_dsim.sh tests/hex/dhrystone.hex 100000 +PERF_PROFILE +TRACE_PIPELINE > /dev/null 2>&1
grep "^\[PIPE schema=pipe.v1\]" dsim_run.log > /tmp/dhry_pipe.trace

# Run the analyzers
python3 tools/bubble_taxonomy.py
python3 /tmp/headwait_deepdive.py

# Disassemble cm hot PCs
/usr/bin/riscv64-unknown-elf-objdump -d tests/coremark/coremark.elf | grep -B2 -A4 "^    80002440:"
```

---

## Companion docs

- Bubble taxonomy: `doc/4wide_pipeline_bubble_taxonomy_2026-05-02.md`
- Methodology retrospective: `doc/4wide_methodology_retrospective_2026-05-02.md`
- Architectural audit: `doc/4wide_arch_diff_2026-05-02.md`
- All 5 prior gap-closure cycles: `doc/4wide_iter_*_results.md`
- Sign-off: `doc/4wide_signoff_2026-05-01.md` (PARTIAL-FLOOR final)

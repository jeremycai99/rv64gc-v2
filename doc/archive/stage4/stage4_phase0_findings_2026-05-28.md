# Stage 4 Phase 0 Findings — Evidence Refresh

Date: May 28, 2026
Source: `benchmark_results/stage4_profiled_baseline_20260528a` (no new sim; all
numbers from the committed baseline artifact). Covers implementation-plan
Tasks 0.1–0.3. Plan of record: `doc/stage4_perf_campaign_plan_2026-05-28.md`.

## Method

Distinguish **pressure counters** (IQ source-wait slots; can exceed 100% of
cycles; rank pressure only) from **cycle-bound counters** (ROB head-stall,
commit-zero, backend-stall; ≤100%; real cycles). Rank by cycle-bound counters
and the harness viability gates, not by the >100% pressure counters.

## Per-row commit-stall breakdown

| Row | timed | IPC | commit_zero | head: load | head: other | head: branch | head: store | backend_stall | rename_stall_rob |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| DS100 | 18,068 | 2.65 | 4.4% | **19.1%** | 2.9% | 0.1% | 0.7% | 0.0% | 0.0% |
| DS300 | 53,047 | 2.81 | 4.3% | **18.2%** | 2.7% | 1.1% | 1.2% | 0.0% | 0.0% |
| CM1 | 150,396 | 2.09 | 15.7% | 14.2% | **25.5%** | 2.0% | 1.6% | 1.1% | 0.1% |
| CM10 | 1,459,538 | 2.18 | 12.0% | 13.3% | **24.7%** | 1.6% | 1.3% | 1.1% | 0.1% |

(head: X = `xs_bottleneck_rob_head_not_ready_X` as % of timed cycles. "other" =
ALU/MUL/CSR/BRU/unknown at head.)

## Finding 1 — Not capacity-bound, not backpressure-bound

`backend_stall_cycles` ≤ 1.1% and `rename_stall_rob` ≤ 0.1% on every row;
`rename_stall_preg` ≤ 1.0%. The ROB/IQ/PRF are never the limiter. This kills any
capacity-growth lever (more ROB/IQ/PRF) — the reference-core audit's rejection of
width growth is re-confirmed on the fresh baseline.

## Finding 2 — Commit-latency-bound, and the binding head-stall class differs by workload

The machine is limited by the ROB head/near-head not being writeback-ready
(HEAD_WAIT_BACKLOG), qualitatively matching the 2026-05-02 taxonomy. But the
**dominant head-stall class is different per workload**:

- **Dhrystone: load-at-head ~19%** dominates; ALU "other" is only ~3%.
  Dhrystone is essentially a load-completion-latency machine at this point
  (commit_zero only ~4.4%, IPC 2.65–2.81 — already running well).
- **CoreMark: ALU-chain "other" ~25%** dominates, load-at-head ~14% second;
  commit_zero 12–16%.

## Finding 3 — Load *forwarding/ordering* is NOT the bottleneck (refutes Slices 2/3 before implementation)

The harness load-consumer viability view shows **ROB-head consumer-block = 0** on
all rows (loads wake their consumers, which are then selected immediately; 0-1
cycle edges dominate, e.g. DS100 10,574/10,576). The "dominant actionable"
counter `xs_bottleneck_lsu_store_fwd_backlog` (DS100 80.3%) is an **activity
indicator**, not a stall — its definition is `if (dc_store_req_valid) backlog++`
(`tb_top.sv:4836`), counting store-commit activity, not load holds.

Therefore the ~19% Dhrystone load-head-stall is **load-completion latency**
(3-cycle load-to-use on the strcpy/strcmp pointer/array chains, on a tiny
L1-resident footprint → overwhelmingly *hits*, not misses), NOT store-to-load
forwarding or memory-ordering. Slice 2 (exact SQ disambiguation) and Slice 3
(memory-dependence predictor + speculative load/replay) attack a path that the
data shows is **already tight** — they would target a non-bottleneck.

**Verdict: Slices 2/3 are REFUTED pre-implementation.** (Saves the multi-week MDP
build.) A precise hit/miss split for the load-head-stall needs a dcache-miss
counter dump (not in the current profile set) — a cheap follow-up if a
load-completion lever is pursued.

## Finding 4 — CoreMark ALU chain confirmed, with uop shapes

CM1 blocked-not-yet-issued ALU producers by shape: logic 577,990 / imm 423,256 /
reg 406,796 / wop 415,345 / shift 113,189 / sub 97,746 (pressure counts; CM10
scales identically). The dependent chain is dominated by boolean-logic and
RV64 W-suffix ops — consistent with the crc16 bit-serial loop
(`xor/andi/negw/srliw`). `producer_blocked_single_alu` = 695,745 (CM1) /
6,890,779 (CM10) — a serial single-ALU producer→consumer chain.

## Ceiling table (per ladder slice)

| Slice | Mechanism | Targeted cycle-bound stall | Upper-bound | Viability | Verdict |
|---|---|---|---:|---|---|
| 1 | Fusion + move/zero-elim | CM head "other" (ALU chain) 25% | ≤ CM ~25% (fraction collapsible) | VIABLE (low-risk) | **LEAD** |
| 5 | ALU value prediction | CM head "other" 25% (fundamental) | ≤ CM ~25% | VIABLE (high-risk) | keep, gated |
| (new) | Load-completion latency (dcache 2→1 hit / prefetch) | DS load 19% + CM load 14% | ≤ DS ~19% / CM ~14% | partial — hits need structural latency, only misses help via prefetch | ADD as candidate |
| 4 | Selective-squash recovery | CM/DS branch head ~2% (recovery dwell larger) | ~2% head; ~up to mispredict-dwell | LOW at head | demote |
| 2 | Exact SQ disambiguation | DS forwarding false-holds | ~0 (consumer-block=0) | NONE | **DROP (refuted)** |
| 3 | MDP + speculative load/replay | DS load ordering | ~0 (consumer-block=0) | NONE | **DROP (refuted)** |

## Re-ranked ladder (data-driven)

1. **Fusion + move/zero-elim (CoreMark, low-risk)** — Slice 1. Attacks the
   dominant CM head-stall (25% ALU chain) by shortening the dependent chain.
2. **ALU value prediction (CoreMark, high-risk, gated)** — the fundamental
   chain-breaker if fusion's collapsible fraction is small.
3. **Load-completion-latency lever (cross-workload, NEW)** — attacks the biggest
   shared stall (DS ~19% + CM ~14%). Caveat: Dhrystone's is hit-latency
   (structural dcache 2→1, multi-month) not miss (prefetch). Needs the hit/miss
   split before committing.
4. **Selective-squash branch recovery (demoted)** — branch head-stall only ~2%.
5. ~~Exact SQ disambiguation~~ / ~~MDP + speculative load~~ — **DROPPED**, refuted
   by the consumer-block=0 viability gate.

## Slice 1 fusibility gate — REFUTED (pre-implementation, no RTL touched)

Task 1.1's fusibility sub-analysis disqualified Slice 1 before any RTL change.
The dominant CoreMark chain is the `crcu8` bit-serial CRC loop; its critical
dependent chain on the CRC register `a2` is `srliw a2,a2,1 → xori a2,a2,K →
ori a2,a2,K` (a 3-deep RAW chain) plus the `andi→xor` test path — **every link
is a genuine dependent ALU→ALU edge** (consumer needs the producer's *computed*
result as an input operand).

Verified crux counters (from baseline `results.json`):

| Counter (CM1 / CM10) | Value | Meaning |
|---|---:|---|
| `dep_alu_blocked_prod_fused` | **0 / 0** | the fusion detector covers ZERO blocked producers |
| `dep_alu_blocked_prod_zero_candidate` | **0 / 0** | no zero-elim candidates in the blocked chain |
| `dep_alu_blocked_prod_move_candidate` | 9,175 / 100,476 (~1.1%) | move candidates are ~1% and live in matrix/list code, NOT the CRC chain |

The current `fusion_detector.sv` only fuses pre-compute-at-decode pairs
(LUI+ADDI, AUIPC+JALR/ADDI) and compare-and-branch pairs (SLT*/SEXT.W + B*) —
all single-ALU-pass, none touching dependent ALU→ALU data edges. `rename.sv`
move-elim is intentionally disabled (needs refcount/lifetime support); zero-elim
is active but has 0 candidates in the chain. Collapsing `srliw→xori→ori` into one
cycle would require a **2-deep combinational ALU**, re-introducing exactly the
select→ALU→wakeup→re-select loop the registered CDB (`core_top.sv:145-151`)
exists to break.

**Realistic Slice 1 ceiling: ≤~0.5% of total CoreMark cycles. Verdict: do NOT
spend an RTL cycle on fusion/move-elim.** This is a clean pre-implementation
refutation — recorded as DSE-only evidence per campaign §6.

## What remains (the levers with a real ceiling are all hard)

With Slices 1, 2, 3 refuted and 4 demoted, the addressable headroom is genuinely
structural/speculative — the "easy" tuning is exhausted at this (already strong)
design point:

- **Value prediction on the ALU chain (CM ~25%)** — the textbook chain-breaker,
  BUT the dominant chain is CRC, whose values are pseudo-random by construction
  and likely poorly predictable. Ceiling depends entirely on producer
  predictability, which is unmeasured → probe before building.
- **Narrow 2-deep / chained ALU for shift→logic dependent pairs** — directly
  collapses the `srliw→xori→ori` chain for specific patterns; bounded timing
  risk (narrow, not a general 0-cycle wakeup). Ceiling = the collapsible chain
  fraction.
- **Load-use latency (dcache 2→1 hit) for the DS ~19% + CM ~14% load-head-stall**
  — structural, multi-month; rv64gc-v2 is already faster load-to-use than Reference Core A,
  so low ROI.

Recommended next step: a cheap **lever-ceiling probe** (measure ALU-producer
value-predictability and count collapsible shift→logic pairs) before committing
weeks to any structural/speculative build.

## Headroom reframing (for the target decision)

- **CoreMark** (6.65/6.85 → 7.5, ~10–13% gap): the 25% ALU-chain head-stall is
  real and addressable (fusion → value prediction). Best-supported target.
- **Dhrystone** (3.15/3.22 → 4.0, ~24–27% gap): the ~19% head-stall is
  load-use latency on hits + an intrinsic OoO-slack floor; commit_zero is only
  ~4.4% and IPC already 2.65–2.81. Realistic non-structural headroom is **smaller
  than the % gap implies** — closing to 4.0 likely needs the structural dcache
  2→1 path, which prior analysis (memory) flagged as multi-month and notes
  rv64gc-v2 is already faster load-to-use than Reference Core A.

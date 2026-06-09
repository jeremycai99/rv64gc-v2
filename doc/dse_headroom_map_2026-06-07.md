# rv64gc-v2 — Design-Space Headroom Map (2026-06-07, post early-redirect)

Multi-agent DSE survey (7 axis analysts → synthesis → adversarial critique), all claims
grounded in `src/rtl/core/`. Baseline: boot IPC ~2.04 (early-redirect just landed),
CoreMark ~2.16, Dhrystone ~2.4–2.58.

## The fact that dominates everything

The core is **commit-order-bound, not capacity-bound.** `backend/commit.sv:213` halts the
in-order retire scan at the first not-writeback-ready head slot; the bubble taxonomy shows
**74% (CM) / 88% (DS)** of cycles are HEAD_WAIT_BACKLOG (ROB has ≥4 uops queued but the head
can't drain). **Every "feed faster / buffer more" lever is upstream of this wall and measures
~0 on benchmarks.** Only three classes of lever can move it: (a) make the head-uop's operand
ready sooner, (b) cut uops on the critical path, (c) relax in-order retire.

## Ranked remaining headroom (critique-corrected)

### Bankable now — software/build, zero RTL risk (MEASURE-FIRST on the %)
- **`-flto` on CM/DS builds** — cross-TU inlining of hot loops. Gain unknown for *this* core
  (the DS string win doesn't transfer to CM's pointer-chase); "the measurement is the lever."
- **Normalize CM binary** (drop `-fno-builtin`/`-ffreestanding`) — fair-methodology, small.

### Strongest NEW RTL lever (critique's catch — on the critical path)
- **Memory-dependence speculation / store-set predictor.** The core is *maximally conservative*:
  `lsu.sv:1876 load_issue_spec_past_addr_unknown = 2'b00` (never speculate), and a load with any
  older unknown-address store stalls (`lsu.sv:1527-1530` `sq_order_wait_block`). That delayed
  load *is* the load-use latency the backend root-cause blames — and it sits directly on the
  HEAD_WAIT path, not upstream. The LQ already has ordering-violation/squash detection
  (`load_queue.sv:278 [LQ_ORDV]`). **Cheapest high-value test on the board:** one `assign` +
  counter on `sq_order_wait_block` cycles, cross-tabbed with HEAD_WAIT. >5–10% overlap ⇒ real;
  <1% ⇒ kill.

### Cleanest boot RTL win (RE-MEASURE first)
- **Re-enable NLPB next-line I-prefetch under VM** (`ifu_line_fetch.sv:226` hard-gated by
  `!instr_vm_active`). Structurally safe post-VIPT (fill carries PA). Targeted fe_stall_icache
  (~6.7M cyc) — but that number predates early-redirect+VIPT; re-read the counter before trusting ~1–1.5%.

### Real-but-unmeasurable (gated on a representative workload)
- **C1 (the actual unlock): get a long/indirect-rich workload** (CoreMark-PRO bare-metal) into
  the suite + measure steady-state per-type MPKI. The current suite is indirect-light, FP-free,
  small-footprint — it *hides* exactly the workloads the broad-app levers target.
- Gated on C1: **ITTAGE** (indirect JALR, 1–4% on interpreter/vtable/jump-table code),
  **L1D data prefetcher** (none exists today; streaming code), **larger TAGE-SC-L** (bounded
  ~2–4%, mostly broad-app — *not* CM/DS where flush is only 0.5–2.2%), **move-elimination**,
  **extend early-redirect to JALR/CALL** (the `rd_valid` guard `core_top.sv:3128` excludes them).

### Demoted / floor (don't fund)
- **Free-LQ-at-execute**: self-refuted — only ~2,454 cyc on the full boot window (phase-confined).
- **Macro-op fusion (indexed-load)**: its flagship form (ADD+LD) collides with the documented
  one-destination constraint (`fusion_detector.sv:158-160`, same reason AUIPC+load is refused);
  realistic on-suite gain <1%.
- **OoO/relaxed retire**: mis-aimed — the wall is *operand-wait at the head*; reordering retire
  doesn't make the operand arrive sooner. Likely ~0 or negative.
- **Execute / IQ / rename / ROB / commit-width / free-list / 6-wide / 0-cyc-wakeup / 2nd-MUL /
  LQ-SQ-depth / 2nd-DTLB-port / ITLB-enlarge / satp-redirect**: refuted by direct A/B or
  measurement (Stage-4 mined these out; free-list never depletes 160/160; 6-wide measured worse).

## Cheapest measurement that could change the whole ranking
The **one-line `sq_order_wait_block` counter** (memory-dependence-stall vs HEAD_WAIT overlap).
It sizes the strongest new critical-path lever for ~zero cost.

## MEASURED 2026-06-07 — memory-dependence lever REFUTED (the cheap test ran)

Added a plusarg-gated sim counter (`+MEMDEP_PROFILE`, tb_xsim) cross-tabbing the
`sq_order_wait_block` / `sq_fwd_wait_addr_unknown` load-stall against HEAD_WAIT
(`backend_admission_head_block` = `rob_head_valid[0] && !rob_head_ready[0]`):

| | total | HEAD_WAIT | sqblock | addr-unknown | **addr-unknown ∩ HEAD_WAIT** |
|---|---|---|---|---|---|
| CoreMark | 1,480,830 | 6.65% | 0.44% | 0.13% | **0.00% (2 cyc)** |
| Dhrystone | 13,784 | 10.49% | 11.65% | 8.76% | **0.04% (6 cyc)** |

**Verdict: store-set / load-disambiguation speculation is DEAD on CM/DS.** Loads blocked on
unknown-address older stores essentially never coincide with the commit-head stall (2 / 6 cycles).
On DS loads *are* store-order-blocked 8.76% of the time, but off the critical path → speculating
them buys ~0 IPC. Do not build the store-set predictor for these workloads. (Re-check only if C1's
representative workload shows a different memory-dependence profile.)

**Also measured:** strict HEAD_WAIT (head's own result not ready) is only 6.65% (CM) / 10.49% (DS)
— far below the taxonomy's broader "74/88% HEAD_WAIT_BACKLOG." The head usually CAN commit; the
2.16-IPC ceiling (54% of 4-wide) is a **commit-width-utilization** limit set by dependency-chain
length, not a hard head stall and not memory ordering. This is the true shape of the benchmark floor.

## MEASURED 2026-06-08 — CoreMark-PRO KERNEL-PHASE profiles (the broad-app unlock, C1 done)

Ported CoreMark-PRO bare-metal (infra: tests/coremark-pro/baremetal/) and profiled the actual
KERNELS (custom direct-kernel mains bypass the mith/newlib harness storm; phase markers confirm
kernel reached). Two representative workloads:

| Metric | sha-test (compute) | parser-125k (XML, pointer-chase) |
|---|---|---|
| IPC (kernel) | **2.93** (73% of 4-wide) | **0.76** |
| true-indirect JALR mispredict share | 2.1% | **0% in kernel** (the 1.68% counted were newlib sprintf's jump table in SETUP, not ezxml) |
| cond mispredict rate | ~0% | 10.3% (TAGE-hard char-class branches) |
| HEAD_WAIT% | 2.6% | **47.3%** |
| LQ-full% | 0% | **41.1%** |
| L1D miss→L2 | 0.6% | **24.3%** |
| operand-not-ready% | 18.6% (SHA round chain) | 62% |

**DSE verdicts from real app kernels:**
1. **ITTAGE = REFUTED, even on the indirect-looking workload.** The parser XML-parse kernel has
   **0% true-indirect JALR mispredicts**. The indirect-branch hypothesis does not hold — don't build
   ITTAGE on this evidence. (Survey's top broad-app pick, killed by measurement.)
2. **NEW REAL LEVER — L1D data-cache capacity / data-memory latency.** Parser is **L1D-miss-bound**:
   24.3% of loads miss the 64KB/4-way L1D → 8-cyc L2; the ezxml node tree (~100KB, pointer-chased
   node→sibling→name→txt) exceeds L1D capacity → saturates the LQ (41% full) → blocks the ROB head
   (47% HEAD_WAIT). IPC 0.76 vs SHA's 2.93. **Lever = bigger L1D (64→128KB to hold the tree).** A
   stride/next-line data prefetcher would NOT help much (pointer-chasing isn't stride-predictable);
   capacity is the right lever. This is the broad-app headroom the small bench suite completely hid.
3. **Compute kernels (sha) are dependency-chain-bound** (operand-not-ready 18.6%, near-zero
   mispredict/memory) — confirms the commit-width/dep-chain floor generalizes; SHA is well-tuned at 73%.

Net: the broad-app upside is REAL and now SIZED — it's **data-cache capacity for pointer-chasing /
large-footprint application code (parser-class)**, NOT branch prediction. Next step to confirm: A/B a
128KB L1D and re-run parser (RTL param + rebuild). Caveat: profiles are bare-metal single-context
direct-kernel runs (not official CoreMark-PRO scores); the parser jalr count required isolating
newlib-sprintf setup from the ezxml kernel (done).

## MEASURED 2026-06-08 — FULL CoreMark-PRO SUITE (8/10 kernel-phase) — THE HEADLINE LEVER

Profiled the full suite bare-metal (kernel-phase, direct-kernel mains). 8/10 done; zip-test +
cjpeg-rose7 sims completing separately (built, running).

| Workload | IPC | JALR-indirect | HEAD_WAIT | SQ-full | L1D-miss | bottleneck |
|---|---|---|---|---|---|---|
| sha-test | 2.93 | ~2% | 2.6% | low | 0.6% | compute/dep-chain |
| core (CoreMark) | 2.16 | ~0% | 6.7% | ~0 | low | compute/dep-chain |
| radix2-big-64k (FP FFT) | 2.49 | 0% | 0.5% | 0.5% | 0% | compute/dep-chain (FP latency) |
| nnet_test (FP) | 1.05 | 0% | 40.3% | **65.0%** | ~0 | **store-throughput** |
| loops-all (FP) | 0.73 | 2.2% | 41.2% | **81.7%** | 12.5%(store) | **store-throughput** |
| linear_alg (FP) | 0.73 | 1.8% | 63.6% | **81.8%** | negl | **store-throughput** |
| parser-125k | 0.76 | 0% | 47.3% | low | 24.3% | L1D-capacity |
| cjpeg-rose7 (JPEG enc) | 1.53 | 0% | 35.5% | **53.3%** | low | **store-throughput** |
| zip-test (DEFLATE) | 2.27 | **9.1%** (40,272 indirect) | 12.9% | 3.2% | ~1% | mixed/compute (some indirect+SQ) |

**HEADLINE: a STORE-COMMIT-BANDWIDTH wall (32-entry SQ) — the #1 lever, hidden by the integer suite.**
[FINAL 10/10: cjpeg JOINED the store-bound cluster -> **4 of 9 workloads** store-bound: nnet (sq_full 65%),
loops (82%), linear_alg (82%), cjpeg (sq_full 53%). zip is NOT L1D-bound (lq_full ~1%) but has the suite's
highest indirect-branch share (jalr 9.1%, 40,272 mispredicts from DEFLATE table-dispatch) — still < ~15%
ITTAGE bar, but the one place indirect prediction isn't zero.]
The store-bound kernels are gated by the SQ filling and stalling rename 53-82% of cycles. In all three: HEAD_WAIT is ~99% stores
waiting on D-cache ACK, LQ empty, ROB-full ~0, operand-not-ready ~0 → unambiguously commit-side store
bandwidth, NOT FP latency / load latency / ordering. nnet shows D-cache store-ack only 35% of cycles +
6M store miss-merges → the wall is likely the COMMIT-BANDWIDTH / coalescing-write path, not just SQ depth
(consistent with the Stage-4 "SQ depth DEAD, drain-bound" finding). CoreMark/Dhrystone are store-light
(~5% stores) so they NEVER showed this; the FP-array workloads are ~50% stores.

**Per-lever verdict (full-suite evidence):**
- **Store-commit throughput = STRONGLY justified, #1 lever** (3 confirmed beneficiaries, broadest reach).
  Lever = deeper SQ AND/OR a store-merge/coalescing-write buffer + wider store-to-D-cache commit. Cheap
  first A/B: SQ 32→48/64 (param) on linear_alg — if sq_full drops proportionally it's depth; if it stays
  high while store-ack ~35% (nnet) it's the commit path → store-merge buffer. CoreMark/DS store-light →
  ≤0.01% no-regression should be free.
- **L1D capacity = weak #2** (parser confirmed; maybe zip). Capacity (pointer-chase), NOT a prefetcher.
- **ITTAGE = NOT justified** (max kernel true-indirect 2.2%, threshold ~15%; zero confirmed beneficiary).
- **TAGE accuracy = NOT justified** (all workloads cond-mispredict <0.01%; tight predictable loops).
- **Data prefetcher = NOT justified** (no strided-load workload; parser is pointer-chase).
- **FP pipeline = NOT a bottleneck** — KEY CORRECTION: the FP workloads revealed a STORE wall, not an
  FP-execution wall (radix2 FP-dep-chain-limited at 2.49; the 3 store-bound have operand-ready ~0 — FP
  units keep up, the SQ doesn't). Lesson: "build store bandwidth, not FLOPs."

Caveat: zip (DEFLATE dictionary-chase — plausible 2nd L1D beneficiary) + cjpeg (JPEG Huffman/DCT — last
plausible ITTAGE home) unprofiled here; finish them before locking the L1D + indirect verdicts.

## Bottom line
Classic uarch levers are at a **genuine floor** (the core is well-tuned). Real remaining headroom:
(1) free software/build wins, (2) boot I-prefetch, (3) **memory-dependence speculation** (the one
critical-path RTL lever the prior campaigns missed), and (4) a large but **currently-unmeasurable**
broad-application tier that's gated behind getting a representative workload into the suite.

# Pipeline Behavior Confirmation

- **Date:** 2026-05-02
- **RTL:** current local rv64gc-v2 tree
- **Simulator:** DSim via `run_dsim.sh`
- **Plusargs:** `+PERF_PROFILE +TRACE_PIPELINE`
- **Artifacts:** `benchmark_results/pipeline_confirm_20260502_202117/`

## Verdict

The pipeline behavior has now been re-tested on the current tree. The result
confirms the earlier diagnosis: CoreMark and Dhrystone are dominated by
`HEAD_WAIT_BACKLOG`, not by ROB depth, IQ capacity, generic ALU count, or CDB
width.

The backend can approach 3.3 IPC on controlled ALU/independent probes, so the
4-wide machine is not fundamentally broken. The score gap appears when real
code creates head-of-ROB completion ordering, load-use, branch/redirect, and
frontend delivery interactions.

## Runs

| Workload | Cycles | Instret | IPC | PASS | Trace lines |
|---|---:|---:|---:|---|---:|
| `bench_loop_100` | 237 | 709 | 2.991561 | yes | 237 |
| `probe_alu_chain_8` | 3042 | 10009 | 3.290270 | yes | 3042 |
| `probe_independent_quad` | 3052 | 10023 | 3.284076 | yes | 3052 |
| `probe_bpu_data_dep_branch` | 13075 | 13512 | 1.033423 | yes | 13075 |
| `dhrystone` | 23514 | 47670 | 2.027303 | yes | 23514 |
| `coremark_iter1` | 199452 | 332110 | 1.665112 | yes | 199452 |

CoreMark emitted a clean benchmark result:

| Field | Value |
|---|---:|
| iterations | 1 |
| timed cycles | 188980 |
| timed instret | 318371 |
| checksum | 59156 |
| flags | 0 |

Dhrystone emitted a clean benchmark result:

| Field | Value |
|---|---:|
| iterations | 100 |
| timed cycles | 23017 |
| timed instret | 47033 |
| checksum | 24 |
| flags | 0 |

## Bubble Taxonomy

| Workload | Peak cycles | HEAD_WAIT_BACKLOG | Frontend-limited | Dispatch-blocked | Flush |
|---|---:|---:|---:|---:|---:|
| `coremark_iter1` | 9.93% | **74.04%** | 11.44% | 2.41% | 2.18% |
| `dhrystone` | 6.81% | **88.48%** | 3.60% | 0.56% | 0.54% |
| `bench_loop_100` | 41.35% | 50.21% | 6.75% | 0.84% | 0.84% |
| `probe_alu_chain_8` | 63.94% | 35.57% | 0.43% | 0.03% | 0.03% |
| `probe_independent_quad` | 49.02% | 50.00% | 0.79% | 0.13% | 0.07% |
| `probe_bpu_data_dep_branch` | 5.50% | **66.90%** | 21.74% | 1.92% | 3.95% |

`HEAD_WAIT_BACKLOG` usually still has issue activity:

| Workload | Head-wait cycles with issue activity | Head-wait cycles with no issue activity |
|---|---:|---:|
| `coremark_iter1` | 81.3% | 18.7% |
| `dhrystone` | 74.5% | 25.5% |
| `probe_alu_chain_8` | 99.9% | 0.1% |
| `probe_bpu_data_dep_branch` | 99.9% | 0.1% |
| `probe_independent_quad` | 99.4% | 0.6% |

This matters: the core is often doing younger work, but commit is throttled by
older not-ready or near-head not-ready uops.

## Frontend Supply

| Workload | Avg fetch | Avg rename | Avg commit | Cycles with rename < 4 |
|---|---:|---:|---:|---:|
| `coremark_iter1` | 1.054 | 1.990 | 1.665 | 68.97% |
| `dhrystone` | 1.059 | 2.064 | 2.027 | 66.73% |
| `bench_loop_100` | 0.207 | 3.093 | 2.992 | 56.54% |
| `probe_alu_chain_8` | 0.019 | 3.303 | 3.290 | 34.02% |
| `probe_independent_quad` | 0.023 | 3.292 | 3.284 | 34.34% |
| `probe_bpu_data_dep_branch` | 0.836 | 2.089 | 1.033 | 68.02% |

The low average fetch count on loop-heavy probes is not a bug by itself; loop
buffer replay can feed rename without fresh fetch. For CoreMark/Dhrystone,
average rename around 2 uops/cycle remains a real feed problem, but the
exclusive bubble taxonomy says head wait is the first-order limiter.

## Capacity Check

| Workload | Avg ROB | Avg INT IQ | Avg LQ | Avg SQ | Max head dwell |
|---|---:|---:|---:|---:|---:|
| `coremark_iter1` | 12.61 / 128 | 4.64 / 72 | 1.61 / 32 | 0.53 / 32 | 24 |
| `dhrystone` | 9.49 / 128 | 1.67 / 72 | 2.29 / 32 | 1.94 / 32 | 16 |
| `probe_alu_chain_8` | 35.02 / 128 | 16.45 / 72 | 0.00 / 32 | 0.00 / 32 | 11 |
| `probe_independent_quad` | 14.45 / 128 | 4.27 / 72 | 0.00 / 32 | 0.00 / 32 | 11 |

These occupancies do not justify widening, more ROB entries, or larger issue
queues as the first response.

## PERF_PROFILE Highlights

CoreMark:

- `Head valid-not-ready cycles`: 94129
- Head not-ready class split, load/store/branch/serial/other:
  `20196 / 3853 / 15926 / 0 / 54154`
- Other-class split, mul/div/csr/bru/unknown:
  `6740 / 14 / 0 / 1037 / 46363`
- Mispredict flushes: 4343
- D-cache load miss allocations: 15 on port 0, 0 on port 1
- New load miss with no free MSHR: 0
- Watchdog fires: 0

Dhrystone:

- `Head valid-not-ready cycles`: 8940
- Head not-ready class split, load/store/branch/serial/other:
  `6438 / 330 / 173 / 0 / 1999`
- Other-class split, mul/div/csr/bru/unknown:
  `0 / 301 / 0 / 412 / 1286`
- Mispredict flushes: 128
- D-cache load miss allocations: 2 on port 0, 0 on port 1
- New load miss with no free MSHR: 0
- Watchdog fires: 0

## Reference Trace Status

NaxRiscv and RSD are useful for trace format and mechanism inspection, but are
not yet apples-to-apples benchmark comparisons.

NaxRiscv smoke trace:

- Artifact:
  `../naxriscv/src/test/cpp/naxriscv/output/pipeline-add/trace.gem5o3`
- Workload: `rv64i_m/I/add-01.elf`
- Result: PASS
- Cycles: 13849
- Commits: 11513
- IPC: 0.831324
- Parsed complete O3PipeView records: 11513
- Average fetch-to-retire: 27.12 cycles
- Average dispatch-to-issue: 6.26 cycles
- Average complete-to-retire: 5.56 cycles

RSD smoke trace:

- Artifacts:
  `../rsd/Processor/Src/Kanata.log`,
  `../rsd/Processor/Src/RSD.log`,
  `../rsd/Processor/Src/Register.csv`
- Workload: `Verification/TestCode/Asm/IntRegImm`
- Result: PC reached `80001004`
- Cycles: 4675
- Committed ops: 4518
- IPC: 0.966417

XiangShan status remains RTL elaboration only:

- Artifacts:
  `../xiangshan/build/rtl/XSTop.sv`,
  `../xiangshan/build/rtl/XSTop.fir`
- Full emulator benchmark execution is still pending.

## Design Implication

The confirmed direction is:

1. Keep BOOM as the quantitative floor, but require the same trace fields before
   comparing design choices.
2. Do not widen first.
3. Prioritize mechanisms that reduce head completion stalls and dynamic uop
   pressure:
   L1D next-line/IP-stride prefetch probes, fusion counters/expansion, UOC
   re-probe, and load/replay/head-readiness instrumentation.
4. Treat FTQ/FDIP frontend work as the owned high-ceiling direction, but do it
   with the head-wait data in view; frontend delivery alone will not close the
   whole gap.


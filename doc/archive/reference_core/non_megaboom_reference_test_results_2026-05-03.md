# Non-MegaBOOM Reference Test Results

- **Date:** 2026-05-03
- **Scope:** XiangShan, NaxRiscv, and RSD reference runs for pipeline-behavior study.
- **Result root:** `benchmark_results/non_megaboom_confirm_20260502_235655/`
- **Latest pointer:** `benchmark_results/non_megaboom_confirm_latest.txt`

## Methodology Alignment

This note follows the evidence ladder now recorded at the top of
`doc/competitor_analysis.md`:

| Tier | Meaning here | Use in this study |
|---|---|---|
| **A** | Same binary, same benchmark window, in-core counters, and pipeline traces | Required for rv64gc-v2/BOOM pass/fail claims. Not available for these non-MegaBOOM references. |
| **B** | Same binary completes, but raw simulator time includes harness effects | Useful for compatibility only. |
| **C** | Source/config audit | Useful to identify mechanisms, not to claim performance. |
| **D** | Published/public scores | Sanity check only. |
| **E** | Other open RV cores | Architectural and instrumentation reference. Do not use as direct signoff targets. |

Compared with the original local methodology in
`doc/pipeline_behavior_confirmation_2026-05-02.md`, the important change is
stricter separation of **core time** from **harness time** and stricter
classification of other cores as Tier E. The original note treated NaxRiscv
and RSD as smoke references; this run expands that into a repeatable Tier E
corpus, but it still must not be used to say rv64gc-v2 is faster or slower than
those cores.

Rules applied below:

1. Use same-binary runs only where the target ISA/runtime accepts them.
2. If same binary fails but native workloads pass, keep both results and do not
   reinterpret native IPC as an apples-to-apples comparison.
3. Preserve raw traces/logs first; summaries are derived artifacts.
4. Map any borrowed idea back to a measured rv64gc-v2 stall class before RTL
   work.
5. Treat XiangShan/NaxRiscv/RSD as references for mechanisms and counters, not
   as implementation bases.

## Result Inventory

| Core | Local repo | HEAD | Status | Primary artifacts |
|---|---|---:|---|---|
| **NaxRiscv** | `../naxriscv` | `9f452d5` | Runnable. Same-binary microbenches pass; same-source CoreMark/Dhrystone attempts trap; native RV64IMAFDC benchmarks pass. | `benchmark_results/non_megaboom_confirm_20260502_235655/nax/*.o3pipe_summary.txt` and `nax/*/trace.gem5o3` |
| **RSD** | `../rsd` | `7b65f6b` | Runnable for native RV32 tests. Four pipeline-oriented tests pass and emit RSD/Kanata logs. | `benchmark_results/non_megaboom_confirm_20260502_235655/rsd/*.summary.txt`, `*.RSD.log`, `*.Kanata.log` |
| **XiangShan** | `../xiangshan` | `4bfb226` | Emulator build attempted. RTL and Verilator C++ generation completed, but C++ compile failed on host/tool-version compatibility. No workload run. | `benchmark_results/non_megaboom_confirm_20260502_235655/xiangshan/emu_build_status.txt`, `xiangshan/time.log` |

## NaxRiscv Results

NaxRiscv was run with its Verilator model:

```text
../naxriscv/src/test/cpp/naxriscv/obj_dir/VNaxRiscv
LD_LIBRARY_PATH=../naxriscv/ext/riscv-isa-sim/lib
```

### Same-binary microbenches

These are the strongest Tier E samples because they use rv64gc-v2-style
microbench workloads adapted only for Nax pass/fail labels.

| Workload | Result | Cycles | Commits | IPC | Fetch-to-retire avg | Dispatch-to-issue avg | Complete-to-retire avg |
|---|---|---:|---:|---:|---:|---:|---:|
| `bench_loop_100` | PASS | 581 | 706 | 1.21515 | 23.49 | 4.30 | 4.89 |
| `probe_alu_chain_8` | PASS | 6191 | 10006 | 1.61622 | 28.75 | 8.39 | 5.16 |
| `probe_bpu_data_dep_branch` | PASS | 24567 | 13511 | 0.549965 | 38.49 | 15.79 | 5.45 |
| `probe_independent_quad` | PASS | 5195 | 10020 | 1.92878 | 22.98 | 4.00 | 3.77 |

Primary summaries:

- `nax/bench_loop_100.o3pipe_summary.txt`
- `nax/probe_alu_chain_8.o3pipe_summary.txt`
- `nax/probe_bpu_data_dep_branch.o3pipe_summary.txt`
- `nax/probe_independent_quad.o3pipe_summary.txt`

### Same-source benchmark attempts

The rv64gc-v2 benchmark sources were rebuilt for RV64GC compatibility and run
with a Nax-specific startup shim that clears full BSS and supplies Nax-visible
pass/fail labels. Both still ended in Nax's endless-trap failure path.

| Workload | Result | Cycles | Commits | IPC | Fetch-to-retire avg | Notes |
|---|---|---:|---:|---:|---:|---|
| `coremark_iter1` | FAIL | 291945 | 373838 | 1.28051 | 40.81 | Trace preserved; failed after entering trap cycle at last committed PC `0x8000002c`. |
| `dhrystone` | FAIL | 37549 | 55689 | 1.48310 | 41.69 | Trace preserved; failed after entering trap cycle at last committed PC `0x8000002c`. |

Interpretation: these traces are useful failure evidence and may still help
inspect pipeline flow, but they must not be used as benchmark throughput
references.

Primary summaries:

- `nax/coremark_iter1.o3pipe_summary.txt`
- `nax/dhrystone.o3pipe_summary.txt`

### Native Nax benchmarks

Native Nax RV64IMAFDC CoreMark/Dhrystone binaries pass and are useful for
stage-latency and retire-width intuition.

| Workload | Result | Cycles | Commits | IPC | Fetch-to-retire avg | Dispatch-to-issue avg | Complete-to-retire avg |
|---|---|---:|---:|---:|---:|---:|---:|
| `native_coremark_rv64imafdc` | PASS | 2233396 | 2632380 | 1.17864 | 42.67 | 14.58 | 8.76 |
| `native_dhrystone_rv64imafdc` | PASS | 1124559 | 1674348 | 1.48889 | 51.87 | 8.96 | 22.62 |

Primary summaries:

- `nax/native_coremark_rv64imafdc.o3pipe_summary.txt`
- `nax/native_dhrystone_rv64imafdc.o3pipe_summary.txt`

### NaxRiscv Verdict

**Use NaxRiscv as an instrumentation and low-cost OoO pipeline reference, not a
performance target.** The gem5-O3 style traces are immediately useful for:

- stage-latency decomposition from fetch through retire,
- retire-width histograms,
- branch/data-dependence probe behavior,
- low-cost load-hit/replay instrumentation ideas.

Do not use the native benchmark IPCs as rv64gc-v2 signoff data. The binaries,
runtime, microarchitecture goals, and simulator accounting differ too much.

## RSD Results

RSD was run through its Verilator/Kanata flow from:

```text
../rsd/Processor/Src
make -f Makefile.verilator.mk kanata
```

RSD is RV32, so it cannot run the rv64gc-v2 RV64 benchmark binaries directly.
The selected tests are native RSD pipeline/replay/memory-dependence tests.

| Test | Result | Cycles | Committed RV ops | IPC | I$ miss | D$ load miss | D$ store miss | Branch miss | Mem-dep miss | Store-load fwd miss |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `IntRegImm` | PASS | 4675 | 4518 | 0.966417 | 60 | 111 | 111 | 2 | 0 | 0 |
| `LoadAndStore` | PASS | 4558 | 4543 | 0.996709 | 76 | 113 | 111 | 3 | 2 | 0 |
| `MemoryDependencyPrediction` | PASS | 6082 | 5469 | 0.899211 | 90 | 111 | 114 | 5 | 11 | 0 |
| `ReplayQueueTest` | PASS | 111570 | 29356 | 0.263117 | 139 | 118 | 4221 | 6 | 0 | 1 |

Primary summaries:

- `rsd/IntRegImm.summary.txt`
- `rsd/LoadAndStore.summary.txt`
- `rsd/MemoryDependencyPrediction.summary.txt`
- `rsd/ReplayQueueTest.summary.txt`

### RSD Verdict

**Use RSD as a compact replay and memory-disambiguation reference.** Its value
is not IPC; it is the combination of:

- readable RV32 OoO control structure,
- Konata visual pipeline logs,
- explicit memory-dependence and replay tests,
- counters for store-load forwarding and memory-dependence misses.

RSD should not drive rv64gc-v2 width, ROB, or frontend decisions because its ISA
target and scale are below the rv64gc-v2/BOOM comparison target.

## XiangShan Status

XiangShan is the strongest open architectural reference in this study, but the
emulator must be treated separately from the source/config audit.

Current local facts:

- Repo: `../xiangshan`
- HEAD: `4bfb226`
- Config attempted: `TLMinimalConfig`
- First command failed because `mill` was not on `PATH`.
- Retried with `PATH=/home/jeremycai/agent-workspace/tools/bin:$PATH`.
- The retry completed Scala/Mill RTL elaboration and Verilator C++ generation.
- The first C++ compile failed on missing `sqlite3.h` and `zstd.h`.
- A bounded retry with local sqlite3/zstd include paths and local library
  shims cleared that dependency blocker.
- The retry then failed in the XiangShan/difftest Verilator wrapper because
  `VerilatedTraceBaseC` is not declared by the host Verilator header setup.
- `build/emu` and `build/verilator-compile/emu` do not exist.

Until the Verilator API/header mismatch is resolved, `build/emu` exists, and a
workload completes, XiangShan remains:

- **Tier C** for architectural/source reference,
- **not Tier B** for local workload compatibility,
- **not a runtime performance comparison point**.

### XiangShan Verdict

**Borrow principles, not implementation.** The mechanisms worth studying are:

- decoupled frontend/FTQ/BPU lifecycle,
- redirect and recovery metadata,
- fusion and move-elimination style dynamic-uop reduction,
- LSU replay structure and memory-dependence bookkeeping,
- L1/L2 prefetch training and counter taxonomy.

Do not build rv64gc-v2 directly on XiangShan. Use it to validate whether our
own abstractions are in the right family after our local counters identify a
specific bottleneck.

## Cross-core Design Verdict

The non-MegaBOOM tests do **not** change the current rv64gc-v2 design priority:

1. **Keep BOOM as the quantitative public floor.** We still need BOOM Tier A
   `mcycle/minstret` and eventually pipe.v1-like counters before claiming an
   architectural gap to BOOM.
2. **Act only on rv64gc-v2 Tier A stall evidence until BOOM counters arrive.**
   The current rv64gc-v2 corpus still says CoreMark/Dhrystone are dominated by
   head-of-ROB completion waits and frontend delivery gaps, not by ROB/IQ/ALU
   capacity.
3. **Use NaxRiscv now for stage-latency intuition.** Its O3Pipe traces give a
   useful external reference for fetch-to-retire, dispatch-to-issue, and
   complete-to-retire distributions.
4. **Use RSD now for replay/memory-dependence flows.** Its native tests are
   directly relevant to LSQ and replay policy discussions, despite not being a
   performance target.
5. **Use XiangShan for architecture patterns after source audit or local emu
   bring-up.** It should inform FTQ/FDIP, prefetch, replay, and fusion
   direction, but not decide pass/fail.

Strong verdict for the next rv64gc-v2 evaluation loop:

| Direction | Verdict | Reason |
|---|---|---|
| L1D next-line prefetch | **Evaluate first.** | Maps to measured load/head-wait cost and is the lowest-risk memory-latency avoidance step. |
| IP-stride/stream prefetch | **Evaluate after NLP.** | Likely useful for Dhrystone/string/stream patterns, but needs pollution/MSHR counters. |
| Load-hit/replay counters | **Add before policy RTL.** | Nax/RSD both reinforce the value of explicit replay accounting. |
| Store-set or memory-dependence prediction | **Conditional.** | RSD shows useful patterns, but rv64gc-v2 must first prove store-blocked load or violation pressure. |
| FDIP/FTQ runahead frontend | **High-ceiling owned design.** | XiangShan/BOOM both support the direction, but it is larger than a first patch. |
| Fusion / dynamic-uop reduction | **Probe/adopt where counters justify.** | Helps head pressure and frontend demand without widening. |
| More ROB/IQ/ALU/CDB/commit width | **Defer/reject for current gap.** | Current rv64gc-v2 Tier A data does not show capacity saturation. |
| Clone XiangShan or BOOM blocks | **Reject.** | Violates design ownership and does not guarantee closure against our measured stalls. |

## Follow-up Work

1. Resolve XiangShan's local Verilator wrapper compatibility issue
   (`VerilatedTraceBaseC` missing with host Verilator 5.020), then build
   `build/emu`; if it succeeds, run `ready-to-run/coremark-2-iteration.bin` and
   record whether local workload execution reaches a clean pass condition.
2. Add bank-conflict, load-replay, prefetch usefulness, and store-blocked-load
   counters to rv64gc-v2 before adopting banked D-cache or memory-dependence
   predictors.
3. Convert NaxRiscv O3Pipe summaries into a side-by-side stage-latency appendix
   next to rv64gc-v2 `pipe.v1` summaries.
4. Use RSD Kanata logs when discussing replay queue and LSQ policy; do not
   extrapolate RSD IPC to RV64GC signoff.
5. Keep `doc/competitor_analysis.md` as the canonical MegaBOOM methodology
   file; this file is the Tier E supplement.

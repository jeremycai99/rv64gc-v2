# Reference Core Unified Audit

- **Date:** 2026-05-03
- **Purpose:** Re-check and consolidate the MegaBOOM, NaxRiscv, RSD, and
  XiangShan study results into one canonical result note.
- **Stable audit artifact root:** `benchmark_results/reference_core_audit_20260503_003434/`
- **Non-MegaBOOM result root:** `benchmark_results/non_megaboom_confirm_20260502_235655/`
- **rv64gc-v2 Tier A corpus:** `benchmark_results/pipeline_confirm_20260502_202117/`

## Executive Verdict

The reference-core study currently provides three different evidence levels:

| Evidence | Current status | Use |
|---|---|---|
| **rv64gc-v2 Tier A** | Complete for the current local corpus. | Decisive for local bottlenecks and near-term RTL choices. |
| **MegaBOOM Tier B** | Historical PASS logs exist, but the current local smoke rerun is blocked. | Confirms earlier compatibility only. Do not use raw BOOM simulation cycles as IPC. |
| **NaxRiscv/RSD/XiangShan Tier E/C** | Nax/RSD runtime references collected; XiangShan now builds and smoke-runs locally, but full benchmark runs are still not performance evidence. | Use for mechanisms, trace formats, runtime/perf-counter hooks, and instrumentation ideas only. |

The unified design verdict is unchanged by this re-check:

1. **Do not claim a measured rv64gc-v2-vs-BOOM performance gap yet.**
   MegaBOOM still lacks benchmark-window `mcycle/minstret` and pipe-level
   counters in the local run.
2. **Use BOOM as the quantitative floor only after the current smoke-run path is
   reproducible and the TestDriver/CSR counter patch lands.**
3. **Use the current rv64gc-v2 Tier A data for immediate RTL decisions.**
   That data says the first actionable direction is L1D next-line prefetch
   evaluation plus better load/replay counters, not ROB/IQ/ALU/CDB widening.
4. **Use XiangShan/NaxRiscv/RSD as references, not as implementation bases.**

## Methodology

This audit applies the evidence ladder used in
`doc/archive/reference_core/competitor_analysis.md`:

| Tier | Requirement | Meaning in this audit |
|---|---|---|
| **A** | Same binary, same counter window, benchmark-window `mcycle/minstret`, and pipeline counters | Required before making IPC or pipeline-performance claims. |
| **B** | Same binary completes, but only harness/simulator total cycles are available | Functional compatibility only. |
| **C** | Source/config audit | Directional feature evidence only. |
| **D** | Published scores | Sanity check only. |
| **E** | Other open RV cores | Architectural and instrumentation reference only. |

Checks repeated for this note:

- Verified Chipyard and BOOM repo heads.
- Verified both MegaBOOM simulators exist.
- Verified the local `MegaBoomV4FastConfig` diff.
- Verified generated collateral contains `FastRAM` for the fast config and
  `SerialRAM` for the original config.
- Verified raw MegaBOOM PASS/FAIL logs and copied them into the stable audit
  artifact root.
- Verified BOOM workload ELF `tohost/fromhost` symbols with `nm`.
- Verified generated `TestDriver.v` prints only simulation cycles and has no
  `mcycle/minstret` path.
- Attempted the BOOM benchmark-window counter hook and repeated smoke tests
  under `benchmark_results/boom_counter_20260503_113936/`.
- Re-read all NaxRiscv O3Pipe summaries.
- Re-read all RSD summaries.
- Re-read XiangShan build status, then reran the local XiangShan build and
  smoke tests under `benchmark_results/xiangshan_retry_20260503_004254/`.

## MegaBOOM Audit

### Build and Config

| Item | Checked value |
|---|---|
| Chipyard HEAD | `48f904a` |
| Chipyard BOOM submodule HEAD | `5223e44c` |
| BOOM simulator | `chipyard/sims/verilator/simulator-chipyard.harness-MegaBoomV4Config` |
| Fast BOOM simulator | `chipyard/sims/verilator/simulator-chipyard.harness-MegaBoomV4FastConfig` |
| Simulator size | Both are `22,338,984` bytes |
| Local Chipyard change | Adds `MegaBoomV4FastConfig` using `WithSimTSIOverSerialTL(fast = true)` |

Generated-collateral check:

| Config | Marker found | Verdict |
|---|---|---|
| `MegaBoomV4FastConfig` | `FastRAM`, `TLSerdesser_FastRAM` | FastRAM path is really present. |
| `MegaBoomV4Config` | `SerialRAM`, `TLSerdesser_SerialRAM` | Original config remains SerialRAM path. |

### Raw Runtime Logs

Stable copies are in `benchmark_results/reference_core_audit_20260503_003434/boom/`.

| Log | Binary | Result | TestDriver simulation cycles | Interpretation |
|---|---|---:|---:|---|
| `boom_exittest_v.log` | `/tmp/boom_workloads/exit_test.elf` | PASS | 1,059,896 | Boot/tohost baseline only. |
| `boom_dhry_global.log` | `/tmp/our_dhry_global.elf` | PASS | 2,242,946 | Our Dhrystone binary completes on BOOM. |
| `boom_cm_global.log` | `/tmp/our_cm_global.elf` | PASS | 6,607,696 | Our CoreMark binary completes on BOOM. |
| `boom_dhry_v.log` | `/tmp/boom_workloads/dhrystone.elf` | PASS | 4,282,036 | Rebuilt Dhrystone also completes. |
| `boom_ourdhry.log` | original non-global-symbol Dhrystone | PASS with warning | 2,062,776 | Not a trusted compatibility result because fesvr warned about missing global `tohost/fromhost`. |
| `boom_cm_v.log` | earlier CoreMark attempt | FAIL timeout | 5,000,001 | Superseded by the later global-symbol PASS run. |

### 2026-05-03 BOOM Counter-Probe Attempt

Result root: `benchmark_results/boom_counter_20260503_113936/`.

I patched the Chipyard/Rocket-Chip `TestDriver.v` locally with an
`RV64GC_BENCH_SNOOP`-guarded benchmark-result store snoop and direct BOOM CSR
reads for `mcycle` and `minstret`. The probed `MegaBoomV4FastConfig` simulator
built successfully and was preserved as
`chipyard/sims/verilator/simulator-chipyard.harness-MegaBoomV4FastConfig.benchsnoop`.

The runtime result is a blocker, not a performance datapoint:

| Log | Simulator | Invocation variant | Result |
|---|---|---|---|
| `boom_dhrystone.log` | rebuilt Fast, `RV64GC_BENCH_SNOOP` | `/tmp/our_dhry_global.elf` | timeout at 5,000,001 cycles |
| `boom_exit_loadmem.log` | rebuilt Fast, `RV64GC_BENCH_SNOOP` | `exit_test.elf` with `+loadmem` | timeout at 2,000,001 cycles |
| `boom_exit_control.log` | rebuilt Fast, no snoop define | `exit_test.elf` | timeout at 2,000,001 cycles |
| `boom_exit_control_loadmem.log` | rebuilt Fast, no snoop define | `exit_test.elf` with `+loadmem` | timeout at 2,000,001 cycles |
| `boom_exit_megaboomv4_existing.log` | existing `MegaBoomV4Config` artifact | `exit_test.elf` | timeout at 2,000,001 cycles |
| `boom_exit_megaboomv4_existing_loadmem.log` | existing `MegaBoomV4Config` artifact | `exit_test.elf` with `+loadmem` | timeout at 2,000,001 cycles |
| `boom_exit_norvc_control.log` | rebuilt Fast, no snoop define | `exit_test_norvc.elf`, no compressed instructions | timeout at 2,000,001 cycles |

Interpretation: the failed probe run cannot be blamed on the counter hook alone,
because the rebuilt no-snoop Fast control also timed out. The old Fast artifact
that produced the saved PASS logs was overwritten during the rebuild, so the
current direct Fast path is a rebuilt artifact rather than the original passing
binary. The existing SerialRAM V4 artifact also timed out under the same 2M
smoke window. The original `exit_test.elf` and a new no-RVC `exit_test_norvc.elf`
both have valid `_start`, `tohost`, and `fromhost` symbols and both timed out,
so the timeout is not explained by compressed instruction encoding. The
`+loadmem` Fast variants are also not canonical, because the generated
FastRAM/SimTSI class switches to an empty `load_mem_write()` implementation
when `+loadmem` is present. The BOOM study is therefore blocked on recovering a
reproducible no-`+loadmem` Fast smoke baseline or the exact prior artifact before
adding counters.

ELF symbol check:

| Binary | `_start` | `tohost` | `fromhost` | `main` |
|---|---:|---:|---:|---:|
| `/tmp/boom_workloads/exit_test.elf` | `0x80000000` | `0x80001000` B | `0x80001008` B | N/A |
| `/tmp/our_dhry_global.elf` | `0x80000000` | `0x80001000` A | `0x80001008` A | `0x800020d0` |
| `/tmp/our_cm_global.elf` | `0x80000000` | `0x80001000` A | `0x80001008` A | `0x800027ce` |
| `/tmp/boom_workloads/dhrystone.elf` | `0x80000000` | `0x80001000` B | `0x80001008` B | `0x800020d8` |

### BOOM Counter Limitation

Generated `TestDriver.v` contains only:

```text
*** FAILED *** ... after %d simulation cycles
*** PASSED *** Completed after %d simulation cycles
```

No `mcycle`, `minstret`, `mhpmcounter`, or benchmark-window IPC print path is
present in the generated TestDriver. Therefore:

- Historical BOOM compatibility is confirmed by the saved PASS logs.
- Current BOOM compatibility is not reproduced by the 2026-05-03 direct smoke
  commands.
- BOOM benchmark IPC is **not** measured.
- BOOM pipeline behavior is **not** measured.
- Raw BOOM simulation cycles are not comparable against rv64gc-v2 DSim cycles.

### MegaBOOM Verdict

**Tier B historical evidence only, current run path blocked.** The other
session successfully got MegaBOOM runnable with our ELFs, but it did not produce
a performance result. The 2026-05-03 rerun did not reproduce even the smoke
baseline from the current direct commands. Any statement like "BOOM is X%
faster/slower than rv64gc-v2" remains blocked until BOOM both reproduces the
smoke PASS and exposes benchmark-window `mcycle/minstret`.

The next BOOM-side task is now:

1. Recover the exact prior passing Fast BOOM run path or artifact and make
   `exit_test.elf` reproducibly pass from a scripted command.
2. Re-apply the `RV64GC_BENCH_SNOOP` counter hook only after that smoke pass is
   stable.
3. Only after that, decide whether BOOM also needs pipe-level counter emission
   matching rv64gc-v2's `[PIPE schema=pipe.v1]` fields.

## rv64gc-v2 Baseline Reminder

The local rv64gc-v2 Tier A corpus remains the only decisive performance data in
this study:

| Workload | Cycles | Instret | IPC | Dominant measured issue |
|---|---:|---:|---:|---|
| `coremark_iter1` | 199,452 | 332,110 | 1.665112 | `HEAD_WAIT_BACKLOG` 74.04% |
| `dhrystone` | 23,514 | 47,670 | 2.027303 | `HEAD_WAIT_BACKLOG` 88.48% |
| `probe_alu_chain_8` | 3,042 | 10,009 | 3.290270 | Backend can approach high IPC on controlled ALU work. |
| `probe_independent_quad` | 3,052 | 10,023 | 3.284076 | Backend width is not fundamentally broken. |
| `probe_bpu_data_dep_branch` | 13,075 | 13,512 | 1.033423 | Branch/data-dependence stress exposes frontend/head-wait cost. |

The current local data does **not** justify widening first. ROB/IQ/LSQ
occupancy is low in the real benchmark runs; the problem is older uops waiting
at or near the head, plus frontend delivery gaps.

## NaxRiscv Audit

| Item | Checked value |
|---|---|
| Repo | `../naxriscv` |
| HEAD | `9f452d5` |
| Result location | `benchmark_results/non_megaboom_confirm_20260502_235655/nax/` |
| Trace format | gem5-O3 style `trace.gem5o3` plus parsed `*.o3pipe_summary.txt` |

### Same-binary microbenches

| Workload | Result | Cycles | Commits | IPC | Fetch-to-retire avg | Dispatch-to-issue avg | Complete-to-retire avg |
|---|---|---:|---:|---:|---:|---:|---:|
| `bench_loop_100` | PASS | 581 | 706 | 1.21515 | 23.49 | 4.30 | 4.89 |
| `probe_alu_chain_8` | PASS | 6,191 | 10,006 | 1.61622 | 28.75 | 8.39 | 5.16 |
| `probe_bpu_data_dep_branch` | PASS | 24,567 | 13,511 | 0.549965 | 38.49 | 15.79 | 5.45 |
| `probe_independent_quad` | PASS | 5,195 | 10,020 | 1.92878 | 22.98 | 4.00 | 3.77 |

### Benchmark attempts

| Workload | Result | Cycles | Commits | IPC | Fetch-to-retire avg | Interpretation |
|---|---|---:|---:|---:|---:|---|
| `coremark_iter1` same-source attempt | FAIL | 291,945 | 373,838 | 1.28051 | 40.81 | Trace preserved, but not a throughput reference. |
| `dhrystone` same-source attempt | FAIL | 37,549 | 55,689 | 1.48310 | 41.69 | Trace preserved, but not a throughput reference. |
| `native_coremark_rv64imafdc` | PASS | 2,233,396 | 2,632,380 | 1.17864 | 42.67 | Native Nax reference only. |
| `native_dhrystone_rv64imafdc` | PASS | 1,124,559 | 1,674,348 | 1.48889 | 51.87 | Native Nax reference only. |

### NaxRiscv Verdict

**Tier E reference.** NaxRiscv is useful for stage-latency decomposition,
retire-width histograms, and low-cost OoO instrumentation patterns. It is not a
BOOM-beating target and its native benchmark IPCs must not be compared directly
with rv64gc-v2 signoff IPCs.

## RSD Audit

| Item | Checked value |
|---|---|
| Repo | `../rsd` |
| HEAD | `7b65f6b` |
| Result location | `benchmark_results/non_megaboom_confirm_20260502_235655/rsd/` |
| Trace/log format | RSD log, Kanata log, register CSV, summary |

RSD is RV32, so it cannot run the rv64gc-v2 RV64 binaries. The checked results
are native RSD pipeline/replay/memory-dependence tests.

| Test | Result | Cycles | Committed RV ops | IPC | I$ miss | D$ load miss | D$ store miss | Branch miss | Mem-dep miss | Store-load fwd miss |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `IntRegImm` | PASS | 4,675 | 4,518 | 0.966417 | 60 | 111 | 111 | 2 | 0 | 0 |
| `LoadAndStore` | PASS | 4,558 | 4,543 | 0.996709 | 76 | 113 | 111 | 3 | 2 | 0 |
| `MemoryDependencyPrediction` | PASS | 6,082 | 5,469 | 0.899211 | 90 | 111 | 114 | 5 | 11 | 0 |
| `ReplayQueueTest` | PASS | 111,570 | 29,356 | 0.263117 | 139 | 118 | 4,221 | 6 | 0 | 1 |

### RSD Verdict

**Tier E reference.** Use RSD for replay queue, dynamic memory-disambiguation,
and Kanata visualization ideas. Do not use it as an IPC target for rv64gc-v2.

## XiangShan Audit

| Item | Checked value |
|---|---|
| Repo | `../xiangshan` |
| HEAD | `4bfb226` |
| Attempted config | `TLMinimalConfig` |
| Stable status copy | `benchmark_results/reference_core_audit_20260503_003434/non_megaboom/xiangshan_emu_build_status.txt` |
| Original status | `benchmark_results/non_megaboom_confirm_20260502_235655/xiangshan/emu_build_status.txt` |
| Current retry artifacts | `benchmark_results/xiangshan_retry_20260503_004254/` |
| Current local emulator | `../xiangshan/build/emu` -> `../xiangshan/build/verilator-compile/emu` |

Build status:

1. First attempt failed because `mill` was not on `PATH`.
2. Retry with local Mill completed Scala/Chisel RTL generation.
3. Verilator C++ generation completed.
4. First C++ compile failed on missing `sqlite3.h` and `zstd.h`.
5. Retry with local sqlite3/zstd include paths cleared those missing headers.
6. Compile then failed in the XiangShan/difftest Verilator wrapper:
   `VerilatedTraceBaseC` is not declared under the host Verilator header setup.
7. Non-source workaround `-DVerilatedTraceBaseC=VerilatedVcdC` cleared the
   Verilator trace-type mismatch and progressed into generated C++ compile.
8. The first `-O3` compile reached generated chunk
   `VSimTop___024root__DepSet_hd5918264__70.o` before a 20-minute wrapper
   timeout.
9. Resume continued to chunk `__202.cpp`, but that single O3 host compile
   reached about 40.5 GB RSS. It was interrupted to avoid host memory pressure.
10. The stale O3 precompiled header was moved aside, then make was resumed with
    `OPT_FAST=-O0`. This rebuilt generated objects at lower host optimization
    and completed successfully.

Final build result:

| Artifact | Result |
|---|---|
| `emu_alias_retry.rc` | `124`, first 20-minute timeout |
| `emu_alias_resume.rc` | `130`, deliberate interrupt at high-memory O3 chunk |
| `emu_alias_o0_resume.rc` | `2`, stale PCH mismatch after changing `OPT_FAST` |
| `emu_alias_o0_pch_resume.rc` | `0`, build completed |
| `status.o0_pch_resume.txt` | `build_emu_exists=yes`, `verilator_compile_emu_exists=yes` |
| `../xiangshan/build/verilator-compile/emu` | executable, 122,687,280 bytes |

Runtime smoke results:

| Workload | Difftest | Result | Evidence |
|---|---:|---|---|
| `coremark-2-iteration.bin` | yes | timeout after 600 s | Image loaded, first instruction committed, difftest enabled, entered CoreMark. |
| `microbench.bin` | yes | timeout after 300 s | Image loaded, first instruction committed, qsort passed, queen started. |
| `microbench.bin` | no | timeout after 300 s | qsort passed, queen started; difftest was not the bottleneck. |
| `flash_recursion_test.bin` | yes | `rc=0` | `HIT GOOD TRAP`, `instrCnt=286`, `cycleCnt=1584`, `IPC=0.180556`, host time 7303 ms. |

The flash recursion smoke also prints PMA/double-trap warning text before the
good trap, so treat it as a simulator/runtime smoke pass, not a clean benchmark
or signoff-quality correctness result.

### XiangShan Verdict

**Tier C plus local smoke evidence.** XiangShan is no longer blocked at local
build: the emulator exists and can execute ready-to-run payloads. However, the
local emulator was built with generated Verilator C++ at `OPT_FAST=-O0`, so
host simulation is too slow for full CoreMark/microbench completion in the
bounded runs above. Use XiangShan for modern frontend/FTQ, fusion, prefetch,
LSU/replay architecture, and perf-counter/instrumentation reference. Do not use
the current local XiangShan runs as benchmark IPC evidence.

## Unified Feature Verdict

| Direction | Current verdict | Why |
|---|---|---|
| BOOM smoke-run recovery | **Mandatory next BOOM step.** | Current commands do not reproduce the earlier PASS logs, so counters cannot be trusted yet. |
| BOOM TestDriver `mcycle/minstret` patch | **Blocked behind smoke recovery.** | Converts BOOM from Tier B compatibility to Tier A IPC evidence only after the baseline run path is stable. |
| BOOM pipe-level counters | **After IPC patch.** | Worth doing if clean BOOM IPC shows a meaningful residual gap. |
| L1D next-line prefetch in rv64gc-v2 | **First RTL evaluation candidate.** | Maps to measured load/head-wait cost and is low risk if MSHR/backpressure-gated. |
| IP-stride/stream prefetch | **Second memory step.** | Plausible for Dhrystone/string/stream patterns; needs usefulness/pollution counters. |
| Load/replay instrumentation | **Add before policy changes.** | Needed before copying Nax/RSD-style replay or memory-dependence policies. |
| Store-set or memory-dependence predictor | **Conditional.** | RSD is useful, but rv64gc-v2 must first show store-blocked-load pressure. |
| FTQ/FDIP frontend | **High-ceiling owned design.** | BOOM/XiangShan support the direction, but it is larger than a first patch. |
| Fusion/dynamic-uop reduction | **Probe with counters.** | Helpful only where dynamic hit-rate is proven. |
| XiangShan perf-counter study | **Useful reference, not signoff evidence.** | Local emu now runs, but O0 build speed prevents full benchmark completion. |
| More ROB/IQ/ALU/CDB/commit width | **Reject/defer for current gap.** | Current rv64gc-v2 Tier A data does not show capacity saturation. |
| Clone XiangShan or BOOM blocks | **Reject.** | References should shape our design, not replace it. |

## Required Next Steps

1. **Recover BOOM smoke-test reproducibility.**
   First target: make `/tmp/boom_workloads/exit_test.elf` pass from a checked-in
   or logged command under the current Chipyard tree. The prior passing Fast
   artifact was overwritten during the rebuild; the 2026-05-03 rerun timed out
   on rebuilt Fast, rebuilt Fast `+loadmem`, existing V4, and existing V4
   `+loadmem` variants. Prefer the no-`+loadmem` Fast path; `+loadmem` is not a
   valid FastRAM/SimTSI loading path in this generated harness.
2. **Patch BOOM for benchmark-window counters.**
   The minimum useful output is one line per workload:
   `IPC: mcycle=N minstret=M IPC=X`, with start/end window defined.
3. **Re-run BOOM Dhrystone/CoreMark with the global-symbol ELFs.**
   Use `MegaBoomV4FastConfig` only after the smoke-test baseline is recovered.
4. **In rv64gc-v2, evaluate L1D next-line prefetch with counters.**
   Acceptance gate: measurable reduction in load/head-wait cycles without
   regressions in frontend, MSHR pressure, or wrong-path pollution.
5. **For XiangShan, only pursue benchmark completion if we need deeper
   reference traces.**
   The next practical route is a host-friendly build profile: keep the trace
   alias and local sqlite/zstd paths, but avoid the O3 `__202.cpp` memory cliff
   with either `OPT_FAST=-O0/-O1` or a properly resourced O3 build. Treat the
   resulting runs as reference instrumentation, not signoff comparison data.
6. **Add load/replay/prefetch-usefulness counters before adopting larger LSU
   ideas.**

## Canonical Status

Use this file as the single consolidated status for the current reference-core
study. Older files remain useful provenance:

- `doc/archive/reference_core/competitor_analysis.md` contains the
  chronological MegaBOOM log.
- `doc/archive/reference_core/non_megaboom_reference_test_results_2026-05-03.md`
  contains the expanded non-MegaBOOM supplement.
- `doc/archive/reference_core/pipeline_behavior_confirmation_2026-05-02.md`
  contains the rv64gc-v2 Tier A confirmation narrative.

The current signoff blocker is not "which reference core is best"; it is that
BOOM currently lacks both a reproducible local smoke-run path and clean
benchmark-window counters. Until both are fixed, rv64gc-v2 RTL work should be
driven by its own Tier A stall data.

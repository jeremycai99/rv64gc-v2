# Stage 1 MegaBOOM Benchmark Comparison, 2026-05-06

## Verdict

The earlier full table exposed a methodology error. Do not use those historical
rows as evidence that rv64gc-v2 beats MegaBOOM.

The issue was the counter window:

- rv64gc-v2 reports the benchmark's internal timed window from
  `rv64gc_bench_begin()` to `rv64gc_bench_end()`.
- The old BOOM `BOOM_PIPE_STATS` hook started when any dispatched PC was
  `>= 0x80000000`, which is `_start`, and stopped on the final `tohost` store.

Therefore BOOM is counting CRT startup, `.bss` clearing, pre-benchmark setup,
benchmark-result writes, and exit code that rv64gc-v2 excludes from its timed
score. That is not apples-to-apples. The apparent 1.5-1.9x rv64gc-v2 advantage
is an artifact of comparing different regions.

Current status: the BOOM harness has been calibrated to the rv64gc-v2 benchmark
MMIO window. It now snoops the `0x80001080..0x80001140` benchmark-result block,
starts on `control=1`, stops on `control=2`, and emits rv64gc-v2-shaped
`[BENCH_RESULT]` `cycles/instret` fields. The short smoke rows below prove the
new path is functional. They do not replace a full shared-row rerun.

Correct Stage 1 policy:

1. Score comparison: only shared MegaBOOM rows with the same benchmark images.
2. Counter window: both cores must measure the same benchmark window, ideally
   by snooping the benchmark-result block or by using equivalent start/stop PCs.
3. Coverage guardrail: run the broad rv64gc-v2 suite now to catch overfitting,
   but do not treat those rows as MegaBOOM score rows until they have a common
   ELF/ABI path on both cores.

Working interpretation after calibration smoke: rv64gc-v2 is not proven ahead
of MegaBOOM. The calibrated Dhrystone 100 and CoreMark 1 samples still show a
roughly 8-10% cycle gap against MegaBOOM, so Stage 1 still needs the frontend
ownership/IBuffer direction rather than benchmark-targeted tuning.

## Methodology

MegaBOOM:

- Simulator:
  `/home/jeremycai/agent-workspace/chipyard/sims/verilator/simulator-chipyard.harness-MegaBoomV4Config`
- Plusargs:
  `+permissive +max-cycles=<N> +boom_timeout=31 +uart_tx=0 +boom_pipe_stats +verbose +permissive-off <elf>`
- Calibrated score window: benchmark-result MMIO block
  `0x80001080..0x80001140`, start on field `control=1`, stop on
  field `control=2`.
- Score parser must use `[BENCH_RESULT] index=3 field=cycles` and
  `[BENCH_RESULT] index=4 field=instret`. The `start_cycle`/`end_cycle`
  fields in `[BOOM_PIPE_STATS]` are TestDriver trace-count diagnostics, while
  the `cycles=` field and emitted `[BENCH_RESULT] cycles` are counted on
  `BOOM_PIPE_CORE.clock`.
- `tohost` remains for FESVR/HTIF pass/fail and as a non-benchmark fallback,
  not as the score window when the benchmark-result block is present.
- Legacy PC-window mode is opt-in only through `+boom_pipe_legacy_pc_window`
  or `+boom_pipe_stop_commit_pc=<pc>`. Do not use it for Stage 1 score rows.
- Optional MMIO overrides:
  `+boom_pipe_bench_result_base=<hex>`,
  `+boom_pipe_bench_result_end=<hex>`,
  `+boom_pipe_tohost_addr=<hex>`,
  `+boom_pipe_no_tohost_stop`.
- Images: copies of the same rv64gc-v2 ELFs, with global `tohost` and
  `fromhost` symbols added for FESVR/HTIF discovery. Code and data payloads were
  otherwise unchanged.
- Source hook:
  `/home/jeremycai/agent-workspace/chipyard/generators/rocket-chip/src/main/resources/vsrc/TestDriver.v`.

rv64gc-v2:

- Command:
  `python3 tools/run_benchmarks.py --manifest tests/benchmarks/stage1_signoff.json --runner dsim --run-class dse --plusarg PERF_PROFILE --plusarg PERF_COUNTERS --plusarg STAT_DUMP --run-dir benchmark_results/megaboom_full_compare_20260506/rv64gc`
- Stop window: benchmark-result block timed cycles, not raw simulator cycles.
- Endpoint: harness-observed store to configurable `TOHOST_ADDR`; the core RTL
  no longer has fixed `tohost` ports or magic `tohost` D-cache behavior.

Primary artifacts:

- `benchmark_results/megaboom_full_compare_20260506/boom`
- `benchmark_results/megaboom_full_compare_20260506/rv64gc`
- `benchmark_results/megaboom_full_compare_20260506/rv64gc_broad`
- `benchmark_results/megaboom_full_compare_20260506/rv64gc_broad_retry`

Toolchain note: the local MegaBOOM simulator was rebuilt from existing generated
collateral with `EXTRA_SIM_PREPROC_DEFINES=+define+BOOM_PIPE_STATS` and
`RISCV=/home/jeremycai/opt/riscv`. A normal clean Chipyard rebuild still needs
`firtool` on `PATH`; without it, Chipyard elaboration stops before the
firtool/split-Verilog step.

## Calibrated Smoke Rows

These rows use the new BOOM benchmark-result MMIO window. They are smoke rows,
not the final Stage 1 score table, because the full shared set still needs to be
rerun through this exact hook.

| Workload | BOOM calibrated cycles | BOOM calibrated retired | rv64gc-v2 timed cycles | rv64gc-v2 timed IPC | Current read |
|---|---:|---:|---:|---:|---|
| Dhrystone 100 | 23,814 | 48,433 | 26,394 | 1.835 | BOOM faster by 9.8% cycles. |
| CoreMark 1 | 192,249 | 318,378 | 207,870 | 1.532 | BOOM faster by 7.5% cycles. |

Smoke evidence:

- Dhrystone 100:
  `status=START source=BENCH_RESULT cycle=643829`,
  `status=BENCH_RESULT cycles=23814 retired=48433`,
  `checksum=24`, `flags=0`.
- CoreMark 1:
  `status=START source=BENCH_RESULT cycle=495615`,
  `status=BENCH_RESULT cycles=192249 retired=318378`,
  `checksum=59156`, `flags=0`, `*** PASSED ***`.

## Non-Scoreable Shared Rows

These rows use the same benchmark images, but they do not use the same counter
window. Keep them only as proof that the BOOM simulator runs the images and that
the old BOOM pipeline hook could emit diagnostic counters.

| Workload | BOOM `_start->tohost` cycles | BOOM diagnostic IPC | rv64gc-v2 timed cycles | rv64gc-v2 timed IPC | Why not scoreable |
|---|---:|---:|---:|---:|---|
| Dhrystone 100 | 50,103 | 1.959 | 26,394 | 1.835 | BOOM includes startup/setup/exit; rv64gc-v2 excludes it. |
| Dhrystone 300 | 119,411 | 2.519 | 76,738 | 1.951 | BOOM includes startup/setup/exit; rv64gc-v2 excludes it. |
| CoreMark 1 | 404,149 | 1.644 | 207,870 | 1.532 | BOOM includes startup/setup/exit; rv64gc-v2 excludes it. |
| CoreMark 10 | 3,671,645 | 1.742 | 2,034,653 | 1.565 | BOOM includes startup/setup/exit; rv64gc-v2 excludes it. |

## MegaBOOM Pipeline Notes

| Workload | Retired | Fetch backpressure | Decode stalls | Dispatch stalls | LDQ full | Branch kill |
|---|---:|---:|---:|---:|---:|---:|
| Dhrystone 100 | 98,172 | 12,667 | 5,438 | 5,428 | 532 | 5,646 |
| Dhrystone 300 | 300,808 | 21,799 | 10,608 | 10,536 | 290 | 7,608 |
| CoreMark 1 | 664,305 | 187,827 | 136,748 | 106,300 | 32,570 | 9,634 |
| CoreMark 10 | 6,394,839 | 1,763,031 | 1,369,964 | 1,074,414 | 325,608 | 61,514 |

Do not compare these historical cycle counts against rv64gc-v2 timed cycles.
Also do not compare BOOM retired counts directly against rv64gc-v2 `minstret`;
the BOOM hook reports its commit-count proxy while rv64gc-v2 reports
architectural instructions.

## rv64gc-v2 Pipeline Notes

The measured rv64gc-v2 rows pass with legacy loop-buffer activity and standalone
decoded-op replay activity at zero.

| Workload | FE zero | Commit zero | `packet_empty_noemit_dup` | `xs_dup_last_emit` | `xs_ftq_occ_max` |
|---|---:|---:|---:|---:|---:|
| Dhrystone 100 | 35.2% | 5.3% | 8,563 | 8,990 | 1 |
| Dhrystone 300 | 34.3% | 6.3% | 24,175 | 25,399 | 1 |
| CoreMark 1 | 41.9% | 21.5% | 76,252 | 82,802 | 1 |
| CoreMark 10 | 41.5% | 19.9% | 725,222 | 783,583 | 1 |

These rv64gc-v2 counters remain valid for local bottleneck analysis. They do
not prove a MegaBOOM win. `xs_ftq_occ_max=1` and high duplicate/no-emit counters
still show the next architectural improvement direction: the frontend is not
running ahead, so the BPU/FTQ/IBuffer ownership refactor remains the right
performance path, not a testbench-targeted patch.

## Broad rv64gc-v2 Coverage

Command:

```bash
python3 tools/sim_platform.py \
    --manifest tests/sim_platform/stage1_broad.json \
    --runner dsim \
    --run-class dse \
    --run-dir benchmark_results/megaboom_full_compare_20260506/rv64gc_broad \
    --plusarg PERF_COUNTERS \
    --plusarg PERF_PROFILE \
    --plusarg STAT_DUMP
```

Initial broad run result: 42 PASS, 1 TIMEOUT. The timeout was
`probe_string_retire_hotspot` at the old 150k cap. A single-row retry with
`--max-cycles 500000` passed at `mcycle=169620`, so this was a false timeout,
not a functional failure. The source manifest cap is now 250k cycles, and a
normal manifest-path cap check passed at the same `mcycle=169620`.

Effective status after cap fix: **43/43 PASS**.

| Coverage class | Rows | Status |
|---|---:|---|
| Dhrystone/CoreMark replicas | 5 | PASS |
| Micro/probe rows | 15 | PASS after string-retire cap fix |
| ISA smoke rows | 8 | PASS |
| C/control smoke rows | 15 | PASS |

## Decision

For Stage 1, do not defer the current broad suite. Run it as an anti-overfit
guardrail before accepting frontend changes. Defer only the larger external
benchmark ports - XiangShan Nexus-AM frontend tests, XiangShan microbench,
Chipyard/riscv-tests benchmark suite, downscaled STREAM, and SPEC/Linux-style
workloads - until the simulator platform has a common source/ELF ABI path.

For the MegaBOOM baseline, the benchmark-window hook is now in place. The next
required step is a full rerun of the shared Dhrystone/CoreMark rows through this
calibrated hook, then use those data to drive the Stage 1 frontend refactor:
split FTQ ownership pointers, add an owner-aware IBuffer, and keep `tohost`
strictly outside the benchmark score window.

## Stage 1 Closure Plan

The first owner-aware response-queue RTL prototype was rejected and removed from
the default frontend. It showed the right failure mode, but not a usable
mechanism: Dhrystone still completed but regressed to roughly 34k cycles with
queue-load SVA failures, and CoreMark iter1 timed out at 300k cycles with heavy
redirect churn. Do not continue that line as a local `fetch_unit.sv` patch.
After removal, the clean baseline was rechecked: DSim build passed, Dhrystone
100 returned `26394` timed cycles with `flags=0`, and CoreMark iter1 returned
`207870` timed cycles with `flags=0`.

The closure path is:

1. Reconfirm the clean baseline with DSim build, anchor Dhrystone/CoreMark rows,
   and the 43-row broad suite.
2. Generate baseline `results.json` with `PERF_PROFILE`, `PERF_COUNTERS`, and
   `STAT_DUMP`; this becomes the required input for counter-movement gating.
3. Harden the existing `+FETCH_DELIVERY_CHECK` checker before changing
   runahead policy. Its strict mode currently false-trips on clean Dhrystone at
   `0x8000003a -> 0x8000004c`, so control-target handling or a golden
   required-PC stream must be fixed before it becomes a gate.
4. Refactor FTQ to expose precise current/next IFU owner state across
   same-cycle `pop+enq`, redirect, epoch, and response lifetime.
5. Add an owner-aware IBuffer of complete fetch packets. This is the real
   replacement for duplicate suppression and the old loop-buffer direction.
6. Enable BPU-owned F1 runahead only when FTQ allocation and IBuffer capacity
   are both available.
7. Rerun the calibrated BOOM shared rows and the rv64gc-v2 signoff manifest.

Stage 1 closes only when rv64gc-v2 beats the calibrated MegaBOOM shared rows and
the local signoff rows pass endpoint identity, golden PC where available,
owner-counter invariants, broad coverage, and declared frontend counter
movement versus baseline.

# DSim First Reproduce — 2026-04-24

First Linux dsim runs of Dhrystone and CoreMark on the current RTL
tree (post tage_sc_l local-pred default-on). Standalone dsim baseline
— a fresh cross-check against xsim is left to the user's active xsim
session.

## TL;DR

- **Dhrystone runs cleanly to PASS** on dsim. Timed window 17,732
  cycles / 47,029 instret / **IPC 2.652**, **5,640.65 Dhrystones/MHz**,
  **3.2103 DMIPS/MHz**.
- **CoreMark COMPLETES on dsim** at cycle 183,249 with a full
  result block (`control=2`, cycles=174,055, instret=318,367,
  checksum=59,156, flags=0). Timed IPC **1.829**, **5.745
  CoreMark/MHz** at iterations=1.
- The CoreMark "no STOP within cap" symptom that was the open
  Priority-1 in the previous handoff did **not** reproduce here —
  whatever was preventing forward progress in that earlier xsim run
  is not present in dsim's view of the same binary.

## Run commands (Linux, this session)

```
cd /home/jeremycai/agent-workspace/rv64gc-v2
./build_dsim.sh
./run_dsim.sh tests/hex/dhrystone.hex 50000
./run_dsim.sh tests/hex/coremark.hex  500000
```

Wall clock on this 16-core x86_64 host:
- dsim build ≈ 90 s
- Dhrystone run (50k cap, finished at 18.7k) ≈ 19 s
- CoreMark run (500k cap, finished at 183.2k) ≈ 3 min

## Dhrystone (dsim)

| Metric | Value |
|---|---:|
| Status | PASS |
| End cycle (tohost) | 18,770 |
| Whole-run mcycle / minstret / IPC | 18,730 / 48,646 / 2.597 |
| Timed cycles (`control=1→2`) | 17,732 |
| Timed instret | 47,029 |
| Timed IPC | **2.652** |
| Iterations | 100 |
| Dhrystones/MHz | 5,640.65 |
| DMIPS/MHz | 3.2103 |

Artifacts:
- `benchmark_results/logs_dsim_first_repro_20260424/dhrystone.log`
- `benchmark_results/logs_dsim_first_repro_20260424/dhrystone_dsim_run.log`

## CoreMark (dsim)

| Metric | Value |
|---|---:|
| Status | PASS |
| End cycle (tohost) | 183,249 |
| Whole-run mcycle / minstret / IPC | 183,209 / 332,108 / 1.813 |
| `control=1` (START) | written |
| `control=2` (STOP) | written |
| Timed cycles | 174,055 |
| Timed instret | 318,367 |
| Timed IPC | **1.829** |
| Iterations | 1 |
| Checksum | 59,156 |
| Flags | 0 |
| CoreMark/MHz (1 iter) | 5.745 |

`iterations=1` means this is a single-iteration smoke binary; per-iter
cycle count is meaningful for comparison but isn't a publishable
multi-iteration steady-state CoreMark/MHz.

Artifacts:
- `benchmark_results/logs_dsim_first_repro_20260424/coremark.log`
- `benchmark_results/logs_dsim_first_repro_20260424/coremark_dsim_run.log`

## Sim-divergence note

The previous handoff flagged "make CoreMark finish at STOP" as the open
Priority-1 because xsim wasn't reaching `control=2` even at 1.19M
cycles. With dsim now completing the same binary at 183k cycles:

1. The CoreMark binary itself reaches START → STOP → tohost from a
   functionally-correct commit stream — dsim observes that path end to
   end.
2. Whatever was blocking forward progress in the prior xsim run is
   sim-tool-specific: either an xsim 4-state X-prop / event-scheduling
   artifact (same family as the `backward_branch_taken`
   registered-vs-combinational issue from earlier), or dsim is
   optimistically resolving an X that xsim correctly latches as a
   stall.
3. Tapeout-correct simulator is xsim per `doc/xsim_lessons_learned.md`,
   so dsim's PASS does not by itself prove the design is correct. It
   does narrow the search space.

### Suggested next actions (out of scope for this session)

- Re-run CoreMark on the current xsim build to see whether the open
  STOP problem still reproduces against today's RTL — the handoff
  number is from an earlier snapshot.
- If xsim still hangs while dsim completes, capture dsim's commit
  trace around the 174k–183k window (the STOP write + tohost path)
  and replay against xsim to identify the first cycle/PC where the
  two simulators diverge.
- Existing sim-only escape hatches `+DISABLE_BRU1_EARLY_REDIRECT` and
  `+DISABLE_LOCAL_PRED` are the obvious bisect axes if divergence is
  prediction/replay-timing related.
- Add a `--simulator dsim` backend to `tools/run_benchmarks.py`
  so dsim runs become first-class regressions instead of one-off
  scripts.

## Other environment work this session

- Installed `gcc-riscv64-unknown-elf` 13.2.0 and
  `gcc-riscv64-linux-gnu` 13.3.0 — unblocks rebuilding tests and gem5
  workloads from source.
- Installed `libtcmalloc-minimal4t64`, `libhdf5-103-1t64`,
  `libhdf5-cpp-103-1t64` — runtime libs for the prebuilt
  `rv64gc-v1/external/gem5-src/build/RISCV/gem5.fast` (binary already
  on disk from a prior build). `gem5.fast --help` runs cleanly. The
  gem5 sweeps under `rv64gc-gem5/study/scripts/` are unblocked at the
  binary level but still need their `D:/agent-workspace/...` path
  strings retargeted to `/home/jeremycai/agent-workspace/...`.
- All three projects' Linux entry points are now executable in
  principle. xsim path remains gated on Vivado being installed (out
  of scope per user).

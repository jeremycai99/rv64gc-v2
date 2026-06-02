# Verification logs

Full output of the verification gates. Current contents are the **Stage 5
instrumentation** verification (sim-only perf profilers added; core verified
bit-identical to the RC) plus the paged-mode performance trajectory:

| Log | Gate | Result |
|---|---|---|
| `compliance.log` | RV64GC ISA compliance (riscv-tests) | **113/113 PASS** (incl. RV64F/D) |
| `signoff.log` | 16-row benchmark signoff (`--goal stage1`) | **16/16 PASS** — CoreMark 6.851 CM/MHz, Dhrystone 4.261–4.273 DMIPS/MHz (cycle-identical to RC → ≤0.01% no-regression) |
| `boot.log` | Linux boot (full profile) — UART console | **BOOT OK** — OpenSBI + Linux 6.6 to userspace, all 8 milestones |
| `stage5_perf_profile_trajectory.log` | 277 `[PERF_PROFILE]` interval samples from the full boot | feeds `tools/paged_ipc_profile.py`; see `doc/stage5_paged_ipc_profile_2026-06-02.md` |

Reproduce with:

```bash
python3 tools/run_rv64gc_compliance.py --build-sim
python3 tools/run_benchmarks.py --runner dsim --goal stage1 --run-class signoff \
    --manifest tests/benchmarks/stage1_signoff.json \
    --plusarg FETCH_DELIVERY_CHECK --plusarg FETCH_DELIVERY_STRICT \
    --plusarg FETCH_OWNER_CHECK --plusarg FETCH_OWNER_STRICT \
    --plusarg PERF_PROFILE --plusarg PERF_COUNTERS --plusarg STAT_DUMP
python3 tools/run_linux_boot.py --run --build-sim --simulator dsim \
    --build-mode linux --linux-profile full --max-cycles 1000000000 \
    --target-milestone boot_ok
```

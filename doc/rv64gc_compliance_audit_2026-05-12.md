# RV64GC Compliance Audit

Date: May 12, 2026
Base commit: `dbda17c`
Candidate: current Stage 3 Linux frontend scrub RTL candidate

Verdict: **PASS, eligible to claim RV64GC instruction compliance for the
covered riscv-tests instruction scope**.

Scope:

- Required instruction suites: `rv64ui`, `rv64um`, `rv64ua`, `rv64uc`,
  `rv64uf`, and `rv64ud` from riscv-tests.
- Required extension checks: `Zifencei` through `rv64ui-p-fence_i`; `Zicsr`
  through `rv64mi-p-csr`, `rv64mi-p-mcsr`, and `rv64mi-p-zicntr`.
- Endpoint policy: riscv-tests `tohost/fromhost` is observed only by the
  simulation platform/testbench. No synthesizable core `tohost` port is part
  of this claim.
- Exclusions from this RV64GC instruction claim: optional bitmanip/Zicond rows,
  full privileged architecture compliance, multi-hart behavior, external
  interrupts, and platform-device completion.

Artifacts:

- Manifest:
  `build/rv64gc_compliance/rv64gc_compliance_manifest.json`
- Results:
  `benchmark_results/rv64gc_compliance_linux_frontend_scrub_profiled_20260512`
- Runner:
  `tools/run_benchmarks.py --runner dsim --run-class signoff`
- Required plusargs:
  `+FETCH_DELIVERY_CHECK +FETCH_DELIVERY_STRICT +FETCH_OWNER_CHECK
  +FETCH_OWNER_STRICT +PERF_PROFILE +PERF_COUNTERS +STAT_DUMP`
- Result count: `113/113` rows endpoint `PASS` and signoff gate `PASS`.

Extension summary:

| Extension | Pass | Fail | Total |
|---|---:|---:|---:|
| RV64I plus Zifencei (`rv64ui`) | 54 | 0 | 54 |
| RV64M (`rv64um`) | 13 | 0 | 13 |
| RV64A (`rv64ua`) | 19 | 0 | 19 |
| RV64C (`rv64uc`) | 1 | 0 | 1 |
| RV64F (`rv64uf`) | 11 | 0 | 11 |
| RV64D (`rv64ud`) | 12 | 0 | 12 |
| Zicsr supplemental (`rv64mi`) | 3 | 0 | 3 |

Claim rule:

- `PASS` requires every required row to finish with `tohost=1`, endpoint
  `PASS`, and signoff gate `PASS`.
- Any required row with `FAIL`, `TIMEOUT`, non-one `tohost`, missing result, or
  signoff gate reason blocks the RV64GC instruction compliance claim.
- After any RTL fix, rerun the failing subset first when applicable, then rerun
  the full profiled compliance gate and the Stage 3 DS/CM hard gate before
  promoting the RTL change.

Stage 3 guard pairing:

- The same candidate also passes the DS/CM hard guard:
  `benchmark_results/stage3_linux_frontend_scrub_guard_20260512`.
- This pairing is required because Linux bring-up RTL changes must not regress
  the committed Dhrystone/CoreMark performance baseline.

Current status:

The full RV64GC instruction compliance gate is closed for this candidate. The
next Linux bring-up work can proceed only while this compliance result and the
DS/CM guard remain clean after each RTL change.

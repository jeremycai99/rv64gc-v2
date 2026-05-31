# RV64GC Compliance Audit

Date: 2026-05-30
Commit: `21842ac`

Verdict: **PASS, eligible to claim RV64GC instruction compliance for the covered standard riscv-tests rows**.

Scope:

- Required instruction suites: `rv64ui`, `rv64um`, `rv64ua`, `rv64uc`, `rv64uf`, and `rv64ud` from standard riscv-tests.
- Required extension checks: `Zifencei` through `rv64ui-p-fence_i`; `Zicsr` through `rv64mi-p-csr`, `rv64mi-p-mcsr`, and `rv64mi-p-zicntr`.
- Endpoint policy: riscv-tests `tohost/fromhost` is observed only by the simulation platform/testbench. No synthesizable core `tohost` port is part of this claim.
- Exclusions from this RV64GC instruction claim: optional bitmanip/Zicond rows, Linux boot, full privileged architecture compliance, multi-hart behavior, external interrupts, and platform devices.

Artifacts:

- Manifest: `/home/jeremycai/agent-workspace/rv64gc-v2/build/rv64gc_compliance/rv64gc_compliance_manifest.json`
- Results directory: `/home/jeremycai/agent-workspace/rv64gc-v2/benchmark_results/rv64gc_compliance_20260530_200920`
- Result count: `113` of `113` manifest rows

Extension Summary:

| Extension | Pass | Fail | Total |
| --- | ---: | ---: | ---: |
| RV64A | 19 | 0 | 19 |
| RV64C | 1 | 0 | 1 |
| RV64D | 12 | 0 | 12 |
| RV64F | 11 | 0 | 11 |
| RV64I | 54 | 0 | 54 |
| RV64M | 13 | 0 | 13 |
| Zicsr | 3 | 0 | 3 |

Claim Rule:

- `PASS` requires every required row to finish with `tohost=1` and a `PASS` signoff gate.
- Any required row with `FAIL`, `TIMEOUT`, non-one `tohost`, missing result, or signoff gate reason blocks the RV64GC compliance claim.
- After any RTL fix, rerun the failing subset first, then rerun the full compliance gate and the Stage 3 DS/CM hard gate before resuming Linux boot.

Current Status:

All required instruction-compliance rows passed in this run. The core is eligible to claim RV64GC instruction compliance for the covered standard riscv-tests scope, while privileged/Linux/platform signoff remains separate.

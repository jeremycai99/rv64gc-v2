# RV64GC Compliance Audit

Date: 2026-05-12
Base commit before this validation slice: `a489034`

Verdict: **RV64GC instruction compliance PASS for the covered standard riscv-tests rows. Stage 3 DS/CM and broader RTL guard also PASS for the current L2/LSU contract RTL.**

Scope:

- Required instruction suites: `rv64ui`, `rv64um`, `rv64ua`, `rv64uc`, `rv64uf`, and `rv64ud` from standard riscv-tests.
- Required extension checks: `Zifencei` through `rv64ui-p-fence_i`; `Zicsr` through `rv64mi-p-csr`, `rv64mi-p-mcsr`, and `rv64mi-p-zicntr`.
- Endpoint policy: riscv-tests `tohost/fromhost` is observed only by the simulation platform/testbench. No synthesizable core `tohost` port is part of this claim.
- Exclusions from this RV64GC instruction claim: optional bitmanip/Zicond rows, Linux boot, full privileged architecture compliance, multi-hart behavior, external interrupts, and platform devices.

Compliance Artifact:

- Manifest: `/home/jeremycai/agent-workspace/rv64gc-v2/build/rv64gc_compliance/rv64gc_compliance_manifest.json`
- Results directory: `/home/jeremycai/agent-workspace/rv64gc-v2/benchmark_results/rv64gc_compliance_full_20260512_l2_lsu_contract_refined`
- Result count: `113` of `113` manifest rows passed.

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

Stage 3 RTL Guard:

- Guard artifact: `/home/jeremycai/agent-workspace/rv64gc-v2/benchmark_results/stage3_l2_lsu_contract_guard_refined_20260512`
- Guard result: all `16` Stage 1/Stage 3 broader rows passed with strict fetch owner/delivery and branch recovery checks.
- Legacy loop buffer active cycles: `0` on all rows.
- Standalone decoded-op replay active cycles: `0` on all rows.

Performance Gate Versus Locked Stage 3 Reference:

| Row | Locked timed cycles | Current timed cycles | Current metric | Gate status |
| --- | ---: | ---: | ---: | --- |
| DS100 | 18,082 | 18,080 | 3.147964 DMIPS/MHz | PASS |
| DS300 | 53,360 | 53,047 | 3.218761 DMIPS/MHz | PASS |
| CM1 | 154,184 | 150,394 | 6.649201 CM/MHz | PASS |
| CM10 | 1,491,293 | 1,454,994 | 6.872881 CM/MHz | PASS |

L2/LSU Contract Fix:

- Blocker found after promoting ALU-only issue enqueue bypass: `hotspot_matrix_store` timed out at `9,999,960` cycles with only `15` retired instructions.
- Root cause: two early D-cache load misses exposed two independent contract bugs.
- DCache accepted only one new load miss allocation per cycle. Port 1 could miss on a different line after port 0 consumed the allocation slot, while LSU still allocated a Load Miss Buffer entry for port 1 as if a fill had been requested.
- L2 also treated same-line outstanding misses as a single-source duplicate. If an I-cache line fill was already outstanding and D-cache requested the same line, L2 suppressed the D-cache MSHR allocation and later returned the data only to I-cache. D-cache then waited forever for a fill that L2 would never send.
- Fixes:
  - DCache now exports a `load_miss_retry` indication for a load miss that did not attach to an allocation, merge, or same-line fill source.
  - LSU uses that indication to requeue port 1 through the existing retry path and prevents a dead LMB allocation for the unaccepted miss.
  - L2 MSHR duplicate detection is source-aware. A same-line request from a different requester gets its own MSHR instead of being dropped.
- Focused reproducer after the fix: `hotspot_matrix_store` passes at `84,357` cycles and `253,255` retired instructions.

Current Status:

The core is eligible to claim RV64GC instruction compliance for the covered standard riscv-tests scope. The Stage 3 RTL performance preservation gate is also clean for the current validated artifact. Linux boot remains a separate Stage 3 platform and privileged-software bringup task.

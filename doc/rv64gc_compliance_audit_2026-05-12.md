# RV64GC Compliance Audit

Date: 2026-05-12
Commit: `2bba306`

Verdict: **FAIL / BLOCKED, not eligible to claim full RV64GC instruction compliance.**

This audit is intentionally strict. A claim is blocked by any required row that fails, times out, is killed, or is still missing from the run.

Scope:

- Required instruction suites: `rv64ui`, `rv64um`, `rv64ua`, `rv64uc`, `rv64uf`, and `rv64ud` from standard riscv-tests.
- Required extension checks: `Zifencei` through `rv64ui-p-fence_i`; `Zicsr` through `rv64mi-p-csr`, `rv64mi-p-mcsr`, and `rv64mi-p-zicntr`.
- Endpoint policy: riscv-tests `tohost/fromhost` is observed only by the simulation platform/testbench. No synthesizable core `tohost` port is part of this claim.
- Exclusions from this instruction-compliance claim: optional bitmanip/Zicond rows, Linux boot, full privileged architecture compliance, multi-hart behavior, external interrupts, and platform devices.

Run Method:

- DSim was not usable for this run because the license lease was unavailable; XSim was used as the fallback runner.
- XSim RTL rebuild from the current working tree completed successfully before the compliance run.
- Generated images use the standard riscv-tests source from `../rv64gc-v1/tests/riscv-tests/isa` and a reset stub at `0x80000000` that jumps to riscv-tests `_start` at `0x80000040`.
- Compliance rows were run with `+PERF_PROFILE +PERF_COUNTERS +STAT_DUMP +FETCH_DELIVERY_CHECK +FETCH_DELIVERY_STRICT +FETCH_OWNER_CHECK +FETCH_OWNER_STRICT`.

Artifacts:

- Manifest: `/home/jeremycai/agent-workspace/rv64gc-v2/build/rv64gc_compliance/rv64gc_compliance_manifest.json`
- Results directory: `/home/jeremycai/agent-workspace/rv64gc-v2/benchmark_results/rv64gc_compliance_20260512_full_rv64gc_xsim_profiled`
- Aggregate `results.json` is empty because the sweep was stopped before `run_benchmarks.py` reached its final write; this report is built from the per-row `*/result.json` files.
- Per-row result count: `39` of `113` manifest rows

Result Summary:

| Extension | Pass | Fail or Blocked | Missing | Total |
| --- | ---: | ---: | ---: | ---: |
| RV64A | 0 | 0 | 19 | 19 |
| RV64C | 0 | 0 | 1 | 1 |
| RV64D | 0 | 0 | 12 | 12 |
| RV64F | 0 | 0 | 11 | 11 |
| RV64I | 34 | 5 | 15 | 54 |
| RV64M | 0 | 0 | 13 | 13 |
| Zicsr | 0 | 0 | 3 | 3 |

Status Counts:

| Status | Gate | Return Code | Rows |
| --- | --- | ---: | ---: |
| `PASS` | `PASS` | 0 | 34 |
| `TIMEOUT` | `FAIL` | 0 | 3 |
| `TOHOST_5` | `FAIL` | 0 | 1 |
| `UNKNOWN` | `FAIL` | -15 | 1 |

Blocking Rows:

| Test | Extension | Status | Gate | Return Code | Tohost | Cycle | Reason |
| --- | --- | --- | --- | ---: | ---: | ---: | --- |
| `rv64ui_p_fence_i` | RV64I | `TOHOST_5` | `FAIL` | 0 | 5 | None | status=TOHOST_5 |
| `rv64ui_p_ld_st` | RV64I | `TIMEOUT` | `FAIL` | 0 | None | 300000 | status=TIMEOUT |
| `rv64ui_p_ma_data` | RV64I | `TIMEOUT` | `FAIL` | 0 | None | 300000 | status=TIMEOUT |
| `rv64ui_p_sb` | RV64I | `TIMEOUT` | `FAIL` | 0 | None | 300000 | status=TIMEOUT |
| `rv64ui_p_sh` | RV64I | `UNKNOWN` | `FAIL` | -15 | None | None | status=UNKNOWN; counter_invariant:xs_f2_owner_no_head=missing; counter_invariant:xs_f2_owner_idx_mismatch=missing; counter_invariant:xs_f2_owner_epoch_mismatch=missing; counter_invariant:xs_f2_owner_tag_mismatch=missing; counter_invariant:xs_packet_stale_idx_mismatch=missing; counter_invariant:xs_packet_stale_epoch_mismatch=missing; counter_invariant:xs_packet_stale_tag_mismatch=missing; counter_invariant:xs_delivery_owner_switch=missing; counter_invariant:xs_delivery_noncontig_pcs=missing |

Failure Notes:

- `rv64ui_p_fence_i`: Functional fail. `tohost=5` is riscv-tests fail encoding for TEST_CASE 2, the I-cache-hit self-modifying-code case after `fence.i`. This points at missing or incomplete instruction-fetch visibility after data-side code modification, not at a tohost harness miss.
- `rv64ui_p_ld_st`: Timed out while still retiring instructions. The log shows 375,140 retired instructions at the 300k-cycle cap and a store/JAL-dominated tail consistent with the riscv-tests pass/fail tohost loop not being observed after a store-heavy row. Treat as an endpoint/store-drain blocker until root caused.
- `rv64ui_p_ma_data`: Timed out while still retiring instructions. This row stresses misaligned data loads/stores; the exact compliance policy for misaligned support versus EEI trap behavior must be decided, but under the current full riscv-tests scope it is a blocker.
- `rv64ui_p_sb`: Timed out at the 300k-cycle cap in a store-focused row. Clustered with the store-heavy tohost observation/drain issue.
- `rv64ui_p_sh`: Run was stopped manually after XSim consumed CPU for more than five wall-clock minutes without new simulation-log progress. Per-row result is UNKNOWN with missing final counters because the process was killed.

Missing Rows:

- `rv64mi_p_csr`
- `rv64mi_p_mcsr`
- `rv64mi_p_zicntr`
- `rv64ua_p_amoadd_d`
- `rv64ua_p_amoadd_w`
- `rv64ua_p_amoand_d`
- `rv64ua_p_amoand_w`
- `rv64ua_p_amomax_d`
- `rv64ua_p_amomax_w`
- `rv64ua_p_amomaxu_d`
- `rv64ua_p_amomaxu_w`
- `rv64ua_p_amomin_d`
- `rv64ua_p_amomin_w`
- `rv64ua_p_amominu_d`
- `rv64ua_p_amominu_w`
- `rv64ua_p_amoor_d`
- `rv64ua_p_amoor_w`
- `rv64ua_p_amoswap_d`
- `rv64ua_p_amoswap_w`
- `rv64ua_p_amoxor_d`
- `rv64ua_p_amoxor_w`
- `rv64ua_p_lrsc`
- `rv64uc_p_rvc`
- `rv64ud_p_fadd`
- `rv64ud_p_fclass`
- `rv64ud_p_fcmp`
- `rv64ud_p_fcvt`
- `rv64ud_p_fcvt_w`
- `rv64ud_p_fdiv`
- `rv64ud_p_fmadd`
- `rv64ud_p_fmin`
- `rv64ud_p_ldst`
- `rv64ud_p_move`
- `rv64ud_p_recoding`
- `rv64ud_p_structural`
- `rv64uf_p_fadd`
- `rv64uf_p_fclass`
- `rv64uf_p_fcmp`
- `rv64uf_p_fcvt`
- `rv64uf_p_fcvt_w`
- `rv64uf_p_fdiv`
- `rv64uf_p_fmadd`
- `rv64uf_p_fmin`
- `rv64uf_p_ldst`
- `rv64uf_p_move`
- `rv64uf_p_recoding`
- `rv64ui_p_sltu`
- `rv64ui_p_sra`
- `rv64ui_p_srai`
- `rv64ui_p_sraiw`
- `rv64ui_p_sraw`
- `rv64ui_p_srl`
- `rv64ui_p_srli`
- `rv64ui_p_srliw`
- `rv64ui_p_srlw`
- `rv64ui_p_st_ld`
- `rv64ui_p_sub`
- `rv64ui_p_subw`
- `rv64ui_p_sw`
- `rv64ui_p_xor`
- `rv64ui_p_xori`
- `rv64um_p_div`
- `rv64um_p_divu`
- `rv64um_p_divuw`
- `rv64um_p_divw`
- `rv64um_p_mul`
- `rv64um_p_mulh`
- `rv64um_p_mulhsu`
- `rv64um_p_mulhu`
- `rv64um_p_mulw`
- `rv64um_p_rem`
- `rv64um_p_remu`
- `rv64um_p_remuw`
- `rv64um_p_remw`

Claim Rule:

- `PASS` requires every required row to finish with `tohost=1`, return code `0`, and a `PASS` signoff gate.
- Any required row with `FAIL`, `TIMEOUT`, `UNKNOWN`, non-one `tohost`, missing result, killed simulator, or signoff gate reason blocks the RV64GC compliance claim.
- After any RTL fix, rerun the failing subset first, then rerun the full compliance gate and the Stage 3 DS/CM hard gate before resuming Linux boot.

Go / No-Go Verdict:

- **No-Go for RV64GC claim today.** The run has a confirmed `fence.i` functional failure, multiple store/misaligned/store-heavy timeout blockers, one killed XSim row, and the M/A/C/F/D/Zicsr suites are not yet covered in a completed sweep.
- The current evidence is enough to prioritize compliance debug before Linux boot. It is not enough to claim RV64GC, even though 34 completed RV64I rows did pass.

Next Required Work:

1. Reproduce and fix `rv64ui_p_fence_i`; likely direction is a real `fence.i` instruction-fetch coherency/invalidation path, not a benchmark workaround.
2. Root cause the store-heavy timeouts (`rv64ui_p_ld_st`, `rv64ui_p_sb`, and likely `rv64ui_p_sh`) by tracing committed stores, CSB dequeue, D-cache store request, and the simulation endpoint observer for the riscv-tests tohost loop.
3. Decide and document the misaligned-access policy for `rv64ui_p_ma_data`: either support the row as part of the strict riscv-tests claim, or explicitly scope the RV64GC claim to an EEI where misaligned access may trap and replace this row with trap-compliance evidence.
4. Add a wall-clock guard or incremental aggregate write to the compliance runner so an XSim hang cannot erase already completed row evidence.
5. After fixes, rerun the failing subset, the full 113-row compliance sweep, and the DS/CM no-regression gate before continuing Stage 3 Linux boot.

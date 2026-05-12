# RV64GC Compliance Audit

Date: 2026-05-12
Commit under test: `c30ad54`
Working tree: dirty, because this audit includes uncommitted LSU compliance fixes and runner fixes.

Verdict: **NO GO. The core is not yet eligible to claim full RV64GC instruction compliance.**

This is a strict instruction-compliance audit. A claim is blocked by any required row that fails, times out, hangs, is killed, returns non-one `tohost`, or has missing evidence.

## Scope

- Required instruction suites: `rv64ui`, `rv64um`, `rv64ua`, `rv64uc`, `rv64uf`, and `rv64ud` from standard riscv-tests.
- Required extension checks: `Zifencei` through `rv64ui-p-fence_i`; `Zicsr` through `rv64mi-p-csr`, `rv64mi-p-mcsr`, and `rv64mi-p-zicntr`.
- Endpoint policy: riscv-tests `tohost/fromhost` is observed only by the simulation platform/testbench. No synthesizable core `tohost` port is part of this claim.
- Exclusions from this audit: optional bitmanip/Zicond rows, Linux boot, full privileged architecture compliance, multi-hart behavior, external interrupts, and platform devices.

## Run Method

- XSim was rebuilt from the current working tree before the audit.
- Generated images use standard riscv-tests sources from `../rv64gc-v1/tests/riscv-tests/isa`.
- The runner now discovers `tohost` and `fromhost` from ELF symbols and passes `TOHOST_ADDR`/`FROMHOST_ADDR` into the simulation platform. This is required because riscv-tests rows do not all place `tohost` at the old fixed default address.
- The full sweep used:
  - `+PERF_PROFILE`
  - `+PERF_COUNTERS`
  - `+STAT_DUMP`
  - `+FETCH_DELIVERY_CHECK`
  - `+FETCH_DELIVERY_STRICT`
  - `+FETCH_OWNER_CHECK`
  - `+FETCH_OWNER_STRICT`
- The run was executed with `--skip-rtl-lock-check` because the audit intentionally includes uncommitted compliance fixes. Do not treat this as an accepted signoff artifact until the fixes are committed and rerun.

## Artifacts

- Manifest: `/home/jeremycai/agent-workspace/rv64gc-v2/build/rv64gc_compliance/rv64gc_compliance_manifest.json`
- Focused refresh: `/home/jeremycai/agent-workspace/rv64gc-v2/benchmark_results/rv64gc_compliance_20260512_focused_dirty_refresh`
- Full sweep: `/home/jeremycai/agent-workspace/rv64gc-v2/benchmark_results/rv64gc_compliance_20260512_full_dirty_refresh`
- Lean `rv64ud_p_ldst` debug rerun: `/home/jeremycai/agent-workspace/rv64gc-v2/benchmark_results/rv64gc_compliance_20260512_rv64ud_ldst_debug_1k`
- Partial DS/CM no-regression check: `/home/jeremycai/agent-workspace/rv64gc-v2/benchmark_results/stage3_ds_cm_gate_20260512_compliance_dirty`
- Fresh DSim CoreMark no-regression check: `/home/jeremycai/agent-workspace/rv64gc-v2/benchmark_results/stage3_coremark_gate_20260512_compliance_dirty_dsim_fresh`

## Summary

The full manifest has `113` rows. All `113` rows were attempted. `102` rows passed and `11` rows failed or remained blocked.

| Extension | Pass | Fail or Blocked | Total | Verdict |
| --- | ---: | ---: | ---: | --- |
| RV64I | 52 | 2 | 54 | Blocked |
| RV64M | 13 | 0 | 13 | Clean in this sweep |
| RV64A | 19 | 0 | 19 | Clean in this sweep |
| RV64C | 1 | 0 | 1 | Clean in this sweep |
| RV64F | 8 | 3 | 11 | Blocked |
| RV64D | 7 | 5 | 12 | Blocked |
| Zicsr | 2 | 1 | 3 | Blocked |

Status counts:

| Status | Rows |
| --- | ---: |
| `PASS` | 102 |
| `TOHOST_5` | 7 |
| `TOHOST_1337` | 1 |
| `TOHOST_21` | 1 |
| `TOHOST_27` | 1 |
| `UNKNOWN` | 1 |

## Blocking Rows

| Test | Extension | Status | Meaning | Evidence |
| --- | --- | --- | --- | --- |
| `rv64ui_p_fence_i` | RV64I, Zifencei | `TOHOST_5` | TEST_CASE 2 failed | Self-modifying code after `fence.i` still does not become visible to instruction fetch. |
| `rv64ui_p_ma_data` | RV64I | `TOHOST_1337` | Trap path | Strict riscv-tests `ma_data` expects misaligned data loads/stores to complete; current core traps on the first misaligned load. |
| `rv64uf_p_fcvt` | RV64F | `TOHOST_5` | TEST_CASE 2 failed | F32 conversion path is not compliant. |
| `rv64uf_p_fcvt_w` | RV64F | `TOHOST_5` | TEST_CASE 2 failed | F32 integer conversion path is not compliant. |
| `rv64uf_p_fdiv` | RV64F | `TOHOST_5` | TEST_CASE 2 failed | F32 divide/sqrt path is not compliant. |
| `rv64ud_p_fcvt` | RV64D | `TOHOST_5` | TEST_CASE 2 failed | F64 conversion path is not compliant. |
| `rv64ud_p_fcvt_w` | RV64D | `TOHOST_5` | TEST_CASE 2 failed | F64 integer conversion path is not compliant. |
| `rv64ud_p_fdiv` | RV64D | `TOHOST_5` | TEST_CASE 2 failed | F64 divide/sqrt path is not compliant. |
| `rv64ud_p_ldst` | RV64D | `UNKNOWN` | Simulator row did not terminate | Full profiled row was manually terminated after runaway wall time and memory growth; lean debug rerun with `MAX_CYCLES=1000` also failed to reach PASS/FAIL/TIMEOUT before manual termination. |
| `rv64ud_p_recoding` | RV64D | `TOHOST_21` | TEST_CASE 10 failed | F64 recoding corner case is not compliant. |
| `rv64mi_p_csr` | Zicsr | `TOHOST_27` | TEST_CASE 13 failed | CSR behavior is not fully compliant for the riscv-tests CSR row. |

## Fixed Since Previous Audit

The previous audit had store-heavy RV64I timeouts. The focused refresh and full sweep show those specific blockers are fixed in the current dirty working tree:

| Test | Previous status | Current status | Root cause / fix |
| --- | --- | --- | --- |
| `rv64ui_p_ld_st` | `TIMEOUT` | `PASS` | Runner now discovers ELF `tohost`/`fromhost` symbols instead of assuming a fixed `0x80001000` endpoint. |
| `rv64ui_p_sb` | `TIMEOUT` | `PASS` | LSU now treats partial committed-store-buffer overlap as a wait condition for younger wider loads. |
| `rv64ui_p_sh` | `UNKNOWN` / killed | `PASS` | Same CSB partial-forwarding fix as `sb`. |

These fixes are validated for the affected compliance rows and for the DS/CM no-regression gate below. They do not close the full RV64GC compliance claim.

## Performance Gate Status

Because this audit includes RTL changes in the LSU, the Stage 3 rule requires DS/CM performance non-regression before accepting or committing the fix.

No-regression check completed:

| Benchmark | Current timed cycles | Reference timed cycles | Delta | Status |
| --- | ---: | ---: | ---: | --- |
| `dhrystone_100_checkedin` | 18,082 | 18,161 | -0.44% | Pass, no regression |
| `dhrystone_300_stage1_anchor` | 53,360 | 53,469 | -0.20% | Pass, no regression |
| `coremark_iter1_generalization` | 154,184 | 154,233 | -0.03% | Pass, no regression |
| `coremark_iter10_checkedin` | 1,491,293 | 1,491,334 | -0.003% | Pass, no regression |

The CoreMark rows were run with a freshly rebuilt DSim image after a stale DSim image produced invalid early timeouts. This closes the no-regression gate for the current LSU/tool fixes.

## Architectural Findings

1. `tohost` is still correctly outside the synthesizable core boundary. Searches show `tohost/fromhost` handling in `src/tb` and tools/docs, not as a fixed core port.
2. The core has integrated FPU RTL through `fpu_top`/`fpnew`, but current F/D compliance is incomplete. Passing some FP rows is not enough to claim RV64GC.
3. FENCE.I support is incomplete. Current `fence_i_signal` invalidates the fetch side, uop cache, and L2, but D-cache dirty data is not flushed into the instruction-visible hierarchy before refetch. That matches the `rv64ui_p_fence_i` self-modifying-code failure.
4. Misaligned data support must be explicitly decided. A strict riscv-tests `rv64ui_p_ma_data` pass requires hardware completion of misaligned data loads/stores. If the intended EEI is trap-on-misaligned, the claim must replace this row with explicit trap-compliance evidence; the current strict riscv-tests claim remains blocked.
5. `rv64ud_p_ldst` is an execution/simulation liveness blocker. Because even `MAX_CYCLES=1000` did not return a timeout promptly, this should be debugged as a possible zero-time simulator loop, unbounded handshake, or FP load/store pipeline liveness bug.

## Claim Rule

- Full RV64GC instruction compliance requires every required row to finish with `tohost=1` and a `PASS` signoff gate.
- Any `TOHOST_*` failure, `UNKNOWN`, manual termination, missing final counter, or missing row blocks the claim.
- A partial statement is allowed only if worded narrowly, for example: “RV64M/A/C and most RV64I rows pass the current riscv-tests sweep.” Do not state “RV64GC compliant.”

## Go / No-Go

**No-Go for RV64GC claim.**

The current design cannot be claimed as a fully compliant RV64GC core because RV64I/Zifencei, RV64F, RV64D, and Zicsr still have blocking failures. Linux boot should remain paused behind this compliance gate unless the boot work is explicitly labeled exploratory.

## Required Closure Plan

1. Commit the current LSU partial-forwarding fix, runner endpoint/parsing fix, and this no-go audit so the repository is trackable.
2. Fix FENCE.I as a real data-to-instruction coherence path: drain older stores, flush or make D-cache dirty data visible, invalidate fetch/uop state, and restart fetch after the fence.
3. Decide the misaligned data EEI. Either implement strict hardware misaligned data support for `ma_data`, or document trap-on-misaligned and add explicit trap evidence instead of using `ma_data` as a required row.
4. Debug FP compliance in this order: `rv64ud_p_ldst` liveness first, then F/D conversion, divide, and recoding failures.
5. Fix `rv64mi_p_csr` TEST_CASE 13 and rerun all Zicsr rows.
6. Rerun the full 113-row compliance sweep from a clean committed RTL state.
7. Rerun the Stage 3 DS/CM hard gate and require less than `0.01%` performance regression before any RTL compliance fix is accepted.

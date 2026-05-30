# Documentation Index

Use this file as the starting point for repo navigation. The top-level `doc/`
folder is intentionally small; dated investigations and superseded plans live
under `doc/archive/`.

## Current Source Of Truth

- `reference_core_unified_audit_2026-05-03.md` - canonical competitor-core
  status, evidence tiers, and current performance-direction verdict.
- `stage1_frontend_refactor_status_2026-05-06.md` - active Stage 1 frontend
  refactor status, current numbers, bottleneck analysis, calibrated baseline
  methodology, and XiangShan-aligned ownership plan. Slimmed 2026-05-05
  (was 2078 lines, now ~250); detailed iteration history in
  `archive/stage1_frontend_refactor_history_2026-05-05.md`.
- `stage1_megaboom_benchmark_comparison_2026-05-06.md` - current local
  MegaBOOM V4 versus rv64gc-v2 methodology audit, plus the broad
  rv64gc-v2 coverage decision. The current BOOM rows are diagnostic, not
  scoreable.
- `stage2_frontend_optimization_target_2026-05-06.md` - Stage 2 frontend
  optimization target: structural runahead, IFU work cursor, runahead
  opportunities, and evidence gates.
- `stage2_bottleneck_dse_plan_2026-05-09.md` - active long-form DSE plan for
  selecting the next structural bottleneck target from full
  `+BOTTLENECK_PROFILE` evidence.
- `stage3_linux_boot_plan_2026-05-10.md` - Stage 3 Linux boot plan, v1
  infrastructure references, ASIC-style endpoint policy, and mandatory DS/CM
  performance regression gate for any RTL change.
- `stage4_perf_campaign_plan_2026-05-28.md` - Stage 4 performance campaign plan
  of record (supersedes `stage4_performance_exploration_2026-05-28.md`, which is
  a failed-attempt log).
- `stage4_phase0_findings_2026-05-28.md` - Stage 4 Phase 0 evidence refresh:
  per-row commit-stall breakdown, Slices 2/3 refuted, Slice 1 refuted at the
  fusibility gate.
- `stage4_lever_ceiling_verdict_2026-05-28.md` - **Stage 4 close-out (SIGN OFF):**
  lever-ceiling probe + current-baseline confirmation. Well-tuned floor; the
  "25% ALU chain" is a pre-bypass artifact (registered CDB resolves 81-86%);
  no lever clears the +3% gate.
- `stage4_critical_path_profile_2026-05-28.md` - empirical per-uop critical-path
  profile (`+TRACE_UOPLIFE`, current baseline, `tools/uoplife_critical_path.py`):
  execute latency 0.16 cyc/uop (dcache 2→1 / chained-ALU dead); bottleneck is
  operand-wait + head-commit-wait (recurrence latency). Confirms the floor.
- `stage4_dhrystone_binary_normalization_2026-05-29.md` - **the Dhrystone-vs-BOOM
  gap was the BINARY, not the uarch:** old `-fno-builtin` forced byte-at-a-time
  strcpy/strcmp/memcpy. Normalized to BOOM/riscv-tests `-O2` methodology →
  **4.27 DMIPS/MHz (DS300), above BOOM's 3.93**, IPC unchanged. DS signoff
  re-baselined. rv64gc-v2 now beats BOOM's public floor on CoreMark AND Dhrystone.
- `stage4_uvm_verification_placeholder_2026-05-12.md` - Stage 4 placeholder
  for UVM-based verification infrastructure after Stage 3 bring-up.
- `rv64gc_v2_uarch.md` - current rv64gc-v2 microarchitecture specification.
- `partial_replay_spec.md` - selective replay design note; keep here while LSU
  replay policy remains under evaluation.

## Workflow References

- `xsim_workflow.md` - authoritative Vivado xsim workflow.
- `xsim_lessons_learned.md` - simulator and verification lessons.
- `linux_env_setup_2026-04-24.md` - Linux dsim/tooling setup note.
- `../tools/audit_goal_runs.py` - classifies recent `benchmark_results/`
  directories as goal pass/fail, DSE smoke-only, or legacy non-goal artifacts.

## Archive Map

- `archive/reference_core/` - superseded BOOM, XiangShan, NaxRiscv, RSD, and
  feature-matrix provenance. Current decisions belong in
  `reference_core_unified_audit_2026-05-03.md`.
- `archive/4wide/` - 6-wide to 4-wide pivot history, signoff refreshes,
  hypothesis/result iterations, and bubble/headwait deep dives.
- `archive/debug_history/` - old CoreMark, Dhrystone, dsim, and ASIC signoff
  handoff notes.
- `archive/design_experiments/` - shelved design experiments such as the uop
  cache plan.

## Artifact Policy

- `benchmark_results/`, `xsim.dir/`, waveform files, simulator journals, and
  generated ELF/HEX images are local artifacts and are intentionally ignored.
- Keep raw logs only while actively debugging. Promote stable numbers, command
  lines, and log paths into docs before pruning logs.
- Prefer timestamped log directories:
  `benchmark_results/logs_<bench>_<purpose>_YYYYMMDD`.
- Keep root clean. Put reusable scripts in `tools/` or `scripts/`; keep one-off
  dumps and trace batch files ignored or archived.

# Documentation Index

Use this file as the starting point for repo navigation. The top-level `doc/`
folder is intentionally small; dated investigations and superseded plans live
under `doc/archive/`.

## Current Source Of Truth

- `reference_core_unified_audit_2026-05-03.md` - canonical competitor-core
  status, evidence tiers, and current performance-direction verdict.
- `boom_pipeline_stats_2026-05-03.md` - active Stage 1 frontend signoff
  status, current numbers, bottleneck analysis, and the
  BOOM-grounded F1-proactive RTL plan. Slimmed 2026-05-05
  (was 2078 lines, now ~190); detailed iteration history in
  `archive/boom_pipeline_stats_history_2026-05-05.md`.
- `rv64gc_v2_uarch.md` - current rv64gc-v2 microarchitecture specification.
- `partial_replay_spec.md` - selective replay design note; keep here while LSU
  replay policy remains under evaluation.

## Workflow References

- `xsim_workflow.md` - authoritative Vivado xsim workflow.
- `xsim_lessons_learned.md` - simulator and verification lessons.
- `linux_env_setup_2026-04-24.md` - Linux dsim/tooling setup note.

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

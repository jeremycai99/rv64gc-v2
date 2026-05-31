# Documentation Index

Use this file as the starting point for repo navigation. The top-level `doc/`
folder is intentionally small; dated investigations and superseded plans live
under `doc/archive/`.

## Release Docs

- `release_candidate_signoff_2026-05-29.md` - **RELEASE CANDIDATE signoff** —
  authoritative current state: final benchmark scores (CoreMark 6.85 CM/MHz,
  Dhrystone 4.27 DMIPS/MHz — both above BOOM's public floor), the release gates,
  the Stage 4 performance verdict, and deferred items.
- `rv64gc_v2_uarch.md` - the rv64gc-v2 microarchitecture specification (as-built).
- `rv64gc_compliance_audit_2026-05-12.md` - RV64GC ISA compliance audit.

## Workflow / Operational References

- `../tools/audit_goal_runs.py` - classifies `benchmark_results/` runs as goal
  pass/fail, DSE smoke-only, or legacy non-goal artifacts.

## Archive Map

The development journey (DSE plans, findings, verdicts, competitive audits) lives
under `doc/archive/` for provenance — it is not release documentation. The RC
signoff doc summarizes the load-bearing conclusions.

- `archive/stage1/` - Stage 1 frontend-refactor status; MegaBOOM comparison.
- `archive/stage2/` - Stage 2 bottleneck / frontend / Dhrystone-backend DSE plans.
- `archive/stage3/` - Stage 3 Linux boot plan.
- `archive/stage4/` - Stage 4 performance campaign: campaign plan, Phase 0
  findings + implementation plan, lever-ceiling verdict (well-tuned floor),
  critical-path profile, Dhrystone binary normalization, the failed-attempt
  exploration log, and the UVM-verification placeholder.
- `archive/reference_core/` - competitor-core unified audit + BOOM/XiangShan/
  NaxRiscv/RSD provenance and feature matrix.
- `archive/4wide/` - 6-wide → 4-wide pivot history, signoff refreshes, and
  bubble/headwait deep dives.
- `archive/design_experiments/` - shelved design notes (uop cache, partial-replay
  spec).
- `archive/debug_history/` - old CoreMark/Dhrystone/dsim/ASIC handoff notes.
- `archive/benchmark_coverage_expansion_2026-05-05.md` - benchmark coverage plan.

## Artifact Policy

- `benchmark_results/`, waveform files, simulator journals, and
  generated ELF/HEX images are local artifacts and are intentionally ignored.
- Keep raw logs only while actively debugging. Promote stable numbers, command
  lines, and log paths into docs before pruning logs.
- Prefer timestamped log directories:
  `benchmark_results/logs_<bench>_<purpose>_YYYYMMDD`.
- Keep root clean. Put reusable scripts in `tools/` or `scripts/`; keep one-off
  dumps and trace batch files ignored or archived.

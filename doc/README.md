# Documentation Index

Starting point for repo navigation. Top-level `doc/` holds the current
authoritative docs; dated investigations and superseded plans live under
`doc/archive/`.

## Current state (2026-06-14)

rv64gc-v2 — 4-wide OoO RV64GC, scalar. **SonicBOOM tier** of the open-source RISC-V
OoO field; a generation below the XiangShan flagship by scope (vector/silicon), not
tuning; ~2–2.5× above the in-order open cores.

- **3.x-IPC roster (≥2.95): 8 members** (committed), +1 reachable zero-RTL (multiply via GCC-14).
- **CoreMark 6.96 CM/MHz** (iter10, DSim-signed), **Dhrystone 4.27 DMIPS/MHz**.
- **Suite geomean ≈ −3.5% cycles** this campaign (cursor-fix + noclobber, committed).
- **Linux boots on Verilator** (BOOT OK, lockstep with DSim, ~2h, parallel) — SPEC/userspace unlocked.
- The scalar core is at its **conventional-lever floor** (every width/capacity/port lever measured-dead;
  chain + misp-entropy bands certified irreducible). Past the BOOM tier needs vector (out-of-POR).

## Authoritative — read these first

- **`perf_before_after_2026-06-14.md`** — consolidated before→current per-workload table
  (the de-chaos doc): roster 6→8, the gated/funded levers, what's certified dead.
- **`perf_scoreboard_2026-06-13.md`** — 42-row IPC scoreboard with measured per-row binder.
- **`rv64gc_v2_uplift_roadmap_2026-06-13.md`** — the POR uplift roadmap (funded levers,
  the measured-dead list, the 4-decision DSE adjudication §6).
- **`opensource_perf_comparison_2026-06-14.md`** — positioning vs BOOM / XiangShan / CVA6 / Rocket.
- `rv64gc_v2_uarch.md` — the microarchitecture specification (as-built).
- `rv64gc_compliance_audit_2026-05-12.md` — RV64GC ISA compliance (113/113).

## This campaign's studies (2026-06-11 → 06-14)

3.x gate campaign + cursor fixes:
- `ipc3x_gate_results_2026-06-11.md` — the §4 gate campaign (cursor fixes minted roster 6→8;
  P1/Zicond/G0 killed; the idea ledgers; M1/M2 BP-perturbation root-cause).

Fresh-lever program (data-backed, all gated default-off):
- `fresh_lever_program_2026-06-14.md` — the program + the 4-gate synthesis.
- `dprefetch_census_2026-06-14.md` / `dprefetch_impl_2026-06-14.md` — D-side stride prefetcher
  (FUND; real-kernel −67% D-miss, memcpy +14%@L=80; committed gated).
- `dprefetch_streaml2_throttle_2026-06-14.md` — stream-l2 throttle = no separator (root-caused).
- `tage_entropy_gate_2026-06-14.md` / `tage512_promotion_validation_2026-06-14.md` — TAGE 256→512:
  partial-capacity but HOLD (regresses funded nnet).
- `value_pred_gate_2026-06-14.md` — value-prediction KILL (chain band certified irreducible).
- `software_axis_3x_2026-06-14.md` — GCC-14 +1 roster (multiply 1.21→3.37); rest maintenance.

Real-workload pivot:
- `realkernel_profile_2026-06-14.md` — real paged-kernel profiling (system-level levers NO-GO;
  D-cache the one bare-metal-hidden signal).

Cache / store / earlier-phase:
- `cache_sizing_results_2026-06-13.md` — FINAL: 512K L2 / 64K L1D / 5-cyc hit (−1.28% real-app, −73% RAM).
- `m2_spill_policy_campaign_2026-06-13.md` — M2-spill REFUTED.
- `uoc_repack_gate_2026-06-13.md` — UOC-repack gate (fill built, replay on-cone = deferred).
- `br0_mul_unshare_under_uoc_2026-06-13.md` — BR0/MUL port un-share = out-of-POR (≈0%).

## Open items (user decisions, not in-flight work)

- Adopt GCC-14 (multiply → roster 9, zero RTL); SPEC harness on the booted Linux (last
  measurement hole); branch sign-off / merge of `backend/lq-instrument`.
- Gated-but-validated levers ready to flip: D-prefetcher (real-kernel/memcpy axis),
  F1 (FP cadence), cache 512K/lat5. TAGE-512 HELD (needs a targeted de-aliasing fix).

## Superseded

- `release_candidate_signoff_2026-05-29.md` — pre-campaign RC (CoreMark 6.85); superseded by
  the current state above.

## Archive Map

Development journey under `doc/archive/` for provenance (not release docs): `stage1/`
(frontend refactor), `stage2/` (bottleneck/DSE), `stage3/` (Linux boot), `stage4/`
(perf campaign + well-tuned-floor verdict), `reference_core/` (open-OoO audits),
`4wide/` (6→4 pivot), `design_experiments/` (uop cache, partial-replay), `debug_history/`.

## Artifact Policy

`benchmark_results/`, waveforms, simulator journals, generated ELF/HEX, and
`verilator_bench_*`/`*_work` build dirs are local artifacts (reproducible from the
committed tree) — keep raw logs only while actively debugging; promote stable numbers
+ command lines + log paths into docs before pruning. Keep root clean; reusable scripts
in `tools/`/`scripts/`.
</content>

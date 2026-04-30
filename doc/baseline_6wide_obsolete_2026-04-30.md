# 6-wide rv64gc-v2 Baseline — OBSOLETE design, archive only

**Captured:** 2026-04-30
**RTL HEAD at measurement:** `fb2d9cc` (doc-only; the on-disk RTL state actually corresponded to the in-flight 6-wide IPC bundle that has since been committed as `4f28619`).
**RTL state actually measured:** `4f28619` (`feat(core): 6-wide IPC bundle — uop cache gen-2 + LB exit predictor + BPU update-path split + ROB commit bypass + MUL/DIV latency cut`).
**Simulator:** DSim 2026.0.0
**Plusargs:** `+PERF_PROFILE`

> ## ⚠ This design is OBSOLETE; cross-width comparison is meaningless
>
> The 6-wide configuration measured here will be **replaced** by the
> 4-wide refactor on the `4wide-pivot` branch (not yet started as of this
> doc). These numbers are kept as an archival snapshot of the design
> being retired — nothing more.
>
> **Cross-width comparison (this 6-wide vs the future 4-wide RTL) is
> apple-to-orange and cannot validate the refactor.** The two designs
> have different param tables, different module structures, and
> different bottlenecks; their cycle counts on the same workload do not
> share a meaningful axis. The 4-wide refactor will be evaluated against
> external 4-wide references (MegaBoom CM/MHz ≥ 6.2, Cortex-A72 ≥ 8.24)
> — NOT against the numbers in this document.
>
> **No future implementation should reference the data or the design
> decisions reflected in this RTL.** Specifically:
>
> - The 6-wide PIPE_WIDTH / ROB_DEPTH=192 / IQ × 3 × 2-port / etc. param
>   table is being narrowed; do not optimise against the 6-wide values.
> - The 5.83 CM/MHz / 3.04 DMIPS/MHz figures used in earlier planning
>   docs (`doc/4wide_pivot_plan_2026-04-25.md`) reflect a still-older
>   build (2026-04-25). Today's numbers below are the up-to-date 6-wide
>   measurement; both are obsolete for forward design.
> - The perf-model calibration data in `../rv64gc-perf-model/` is
>   **paused on a structural toolchain dead-end** (see that repo's
>   `doc/phase_2_5_signoff.md`) and must not be referenced for forward
>   design either.
>
> **This doc records what was; it does not predict what will be.**

---

## Sign-off targets (still valid as design goals)

| Tier | CM/MHz | DMIPS/MHz | Source |
|---|---:|---:|---|
| Baseline must-match | ≥ 6.2 | ≥ 4.00 | MegaBoom (4-wide) |
| **Sign-off must-beat** | **≥ 8.24** | **≥ 4.72** | ARM Cortex-A72 (3-wide OoO) |

These are external benchmarks; the targets remain the bar the 4-wide
refactor must clear at sign-off.

---

## Measurement (current 6-wide, 4f28619)

| Workload | RTL cycles | instret | IPC | iterations | metric |
|---|---:|---:|---:|---:|---|
| dhrystone | 18730 | 48646 | 2.597 | 100 | **3.04 DMIPS/MHz** |
| coremark iter=1 | 183141 | 332108 | 1.813 | 1 | **5.46 CM/MHz** (iter=1) |
| bench_loop_100 | 238 | 711 | 2.987 | 100 | n/a (cold-start microbench) |

All three runs reached `PASS at cycle … (tohost=1)` — STOP, not TIMEOUT,
not IterLimit. Per the perf-discipline rule (`memory/feedback_perf_discipline.md`),
this satisfies the precondition for IPC claims.

### Derivation

- **DMIPS/MHz** = `iterations * 1e6 / (cycles * 1757)`
  - dhry: `100 * 1e6 / (18730 * 1757) = 3.038`
- **CM/MHz** = `iterations * 1e6 / cycles`
  - cm iter=1: `1 * 1e6 / 183141 = 5.460`

### Vs the 2026-04-25 baseline figure (5.83 CM/MHz) — same-design check only

The earlier `doc/4wide_pivot_plan_2026-04-25.md` cites 5.83 CM/MHz as the
6-wide baseline. Today's iter=1 measurement is 5.46 — a different number
on the SAME design family, explained by:
- Iteration count differs: 5.83 was likely measured with iter=10 (which
  amortises CoreMark's per-run setup) while today is iter=1.
- RTL has changed since 2026-04-25 (LSU correctness fixes, perf
  instrumentation, BPU/FTQ/IFU refactor) — both could shift CM/MHz.

This is a same-design comparison (6-wide-then vs 6-wide-now) and is the
only meaningful comparison this doc supports. Cross-design comparison
(this 6-wide vs the future 4-wide) is not.

---

## Reproducing this measurement

```bash
cd /home/jeremycai/agent-workspace/rv64gc-v2
export LD_LIBRARY_PATH=  # work around shell_activate.bash's `set -u` issue

# (Build only if dsim_work/tb_image.so is stale)
# bash build_dsim.sh

bash run_dsim.sh tests/hex/dhrystone.hex      100000 +PERF_PROFILE
bash run_dsim.sh tests/hex/coremark.hex       500000 +PERF_PROFILE
bash run_dsim.sh tests/hex/bench_loop_100.hex   5000 +PERF_PROFILE

# Each run produces dsim_run.log; grep for:
#   IPC: mcycle=… minstret=… IPC=…
#   PASS at cycle … (tohost=1)
```

Captured logs (transient, regenerable): `/tmp/baseline_{dhry,coremark,bench_loop_100}.log`
on the captured-at machine.

---

## What happens next (and what this doc does NOT contribute to)

1. RTL refactor `4wide-pivot` branch will be cut from `fb2d9cc`.
2. Per `doc/4wide_pivot_plan_2026-04-25.md` §"RTL refactor scope":
   PIPE_WIDTH=4, ROB=128, IQ × 3 × 2 (or 2 IQs), ALU=3, CDB=4, etc.
   (textbook 4-wide, no perf-model gating).
3. After each module group: build + clockcheck microbench + functional
   regression must pass before proceeding.
4. **Sign-off is against external 4-wide references, not this doc.**
   The 4-wide design will be measured on its own terms; the bar is
   MegaBoom CM/MHz ≥ 6.2 (floor) and Cortex-A72 ≥ 8.24 (stretch).
   This 6-wide doc plays no role in that decision.

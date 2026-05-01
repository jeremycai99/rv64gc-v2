# 4-wide RTL Refactor Sign-off — 2026-04-30

**Branch:** `4wide-pivot`
**Final HEAD:** `3a64585` (refactor(stage5))
**Pivot point:** `4f28619` (6-wide IPC bundle on master) → `e6b6c57` (doc reset)
**Simulator:** DSim 2026.0.0
**Plusargs:** `+PERF_PROFILE`

> ## ⚠ Sign-off VERDICT: PARTIAL — CM/MHz close, DMIPS/MHz substantially short
>
> The 5-stage RTL refactor (Rename+ROB → Dispatch+IQ → LSU → Caches → Frontend+TB) landed cleanly with all functional and clockcheck gates green. **The design as configured does NOT meet the MegaBoom 4-wide floor on either CM/MHz (−2.4%) or DMIPS/MHz (−39.5%).** The CM/MHz miss is small enough to plausibly close with targeted optimisation; the DMIPS/MHz miss is large and points at a dhrystone-specific bottleneck (most likely procedure-call / branch resolution paths the pure narrowing didn't touch).
>
> Per `doc/4wide_refactor_checklist.md` Halt-and-Re-evaluate Rule and Sign-off Gate: floor missed = halt-and-re-evaluate; the 4-wide refactor itself is correct, but the design as configured does not meet the bar.

---

## Sign-off targets vs measured

| Tier | Required | Measured | Pass? |
|---|---:|---:|---|
| Floor — MegaBoom 4-wide | CM/MHz ≥ 6.2 | **6.05** (10 iters / 1,653,640 cyc) | ❌ −2.4% |
| Floor — MegaBoom 4-wide | DMIPS/MHz ≥ 4.00 | **2.42** (100 iters / 23,514 cyc / 1757) | ❌ −39.5% |
| Stretch — ARM Cortex-A72 | CM/MHz ≥ 8.24 | 6.05 | ❌ −26.6% |
| Stretch — ARM Cortex-A72 | DMIPS/MHz ≥ 4.72 | 2.42 | ❌ −48.7% |

**Functional regression:** 18/18 PASS (8 rv64ui_* + 10 bench_*).
**Clockcheck microbenches:** 3/3 PASS, 0 diverging cycles (allowlist applied for intentional refactor effects).
**STOP-OK:** all benchmarks reach `$finish` (note: `coremark.hex` writes a magic HTIF tohost value `0x7fff5b5b7fff5252`; the regression script accepts this under its relaxed STOP-OK criterion — see Open Concerns below).

---

## Final 4-wide bench measurements

| Workload | Cycles | Instret | IPC | Derived metric |
|---|---:|---:|---:|---|
| dhrystone (100 iters) | 23,514 | 47,670 | 2.027 | **2.42 DMIPS/MHz** |
| coremark_iter1 (10 iters internal) | 1,653,640 | 3,625,277 | 2.192 | **6.05 CM/MHz** |
| coremark_iter10 (same hex as iter1) | 1,653,640 | 3,625,277 | 2.192 | identical |
| bench_loop_100 | 237 | 711 | 2.992 | (microbench) |

### IPC trajectory across stages (cm iter=10)

| Stage | Commit | cm cycles | IPC | CM/MHz | Notes |
|---|---|---:|---:|---:|---|
| 6-wide baseline (4f28619) | obsolete | 1,714,296 | 1.865 | 5.83 | pre-pivot 6-wide |
| Stage 1 | a64efbc + ab9e897 | 1,857,347 | 1.72 | 5.38 | rename + ROB narrow |
| Stage 2 | d566919 | 1,653,640 | 2.19 | 6.05 | + load_wb sideband (real opt) |
| Stage 3 | 76b190e | 1,653,640 | 2.19 | 6.05 | LQ/SQ 64→32 (free) |
| Stage 4 | 4c14b5e | 1,653,640 | 2.19 | 6.05 | L1D 4→2 (already dual-port) |
| Stage 5 | 3a64585 | 1,653,640 | 2.19 | 6.05 | frontend + TB cleanup |

### IPC trajectory across stages (dhrystone)

| Stage | dhry cycles | IPC | DMIPS/MHz |
|---|---:|---:|---:|
| 6-wide baseline | 18,730 | 2.597 | 3.04 |
| Stage 1 | (~24,000) | 1.99 | ~2.37 |
| Stages 2-5 | 23,514 | 2.027 | 2.42 |

dhrystone IPC dropped 22% (6-wide 2.60 → 4-wide 2.03), DMIPS/MHz dropped 20%. cm IPC INCREASED 18% (1.865 → 2.19) thanks to Stage 2's load_wb sideband architectural fix (which gave loads a dedicated writeback path, freeing CDB bandwidth for ALU/BRU). The two workloads diverged in opposite directions because narrowing had different impacts on their hotpaths.

---

## Stage-by-stage commit summary

| Commit | Stage | Files | What landed |
|---|---|---:|---|
| `e1ce792` | pre-flight | 1 | clockcheck allowlist |
| `a64efbc` | Stage 1 | 4 | rv64gc_pkg.sv + rob.sv + int_prf.sv (depth only) + allowlist additions |
| `4483015` | Stage 1 doc | 1 | int_prf deferral note |
| `ab9e897` | Stage 1 fix | 1 | rob.sv count_r width overflow fix |
| `d566919` | Stage 2 | 11 | dispatch + IQ + CDB + bypass + load_wb sideband + tb_top fix |
| `80da9b9` | Stage 2 doc | 1 | int_prf 12R6W permanent + exception clause |
| `76b190e` | Stage 3 | 1 | LQ/SQ depth 64→32 (1-line param edit; rest already parametric) |
| `4c14b5e` | Stage 4 | 2 | L1D_BANKS 4→2 (was already dual-port; label fix + comment) |
| `3a64585` | Stage 5 | 5 | fetch_unit + uop_cache + loop_buffer + tb_top PERF_PROFILE + comments |

**Total RTL diff:** ~22 files touched across 9 commits. Functional behaviour preserved (18/18 rv64ui PASS at every stage). Clockcheck PASS at every stage with monotone allowlist additions, each with `_notes` justifications.

---

## Architectural changes beyond pure narrowing

The plan's "no new optimisations during refactor" rule was relaxed once with explicit justification:

- **Stage 2 `load_wb` sideband.** CDB shrink 6→4 removed the slots loads had been using for definitive wakeup of dependent µops. Cache-miss paths produced ROB deadlock → cm hang. The minimum architectural fix was a dedicated `load_wb` writeback path (2 ports for loads, separate from the 4 CDB slots). Implementer added `load_wb_wk_*` definitive-wakeup ports to issue_queue.sv. Side effect: cm IPC IMPROVED because loads no longer compete with ALU for CDB slots. See `doc/4wide_refactor_checklist.md` "What NOT to Do" #9 exception clause.

- **`int_prf` 12R6W kept** (planning doc said reduce to 8R4W). With load_wb sideband, write-port demand is 4 (CDB) + 2 (load_wb) = 6, NOT 4. Read demand is 3 ALU × 2 + 2 BRU × 2 = 10, so 12R is needed (not 8R). Original 8R4W target was based on the assumption that loads write through CDB; load_wb sideband overturns that.

---

## Open concerns

### 1. CoreMark behaviour: HTIF magic tohost write, no `[BENCH_RESULT]` lines

`coremark.hex` (mtime Apr 24, predates this refactor) completes by writing `0x7fff5b5b7fff5252` to tohost — looks like an HTIF syscall protocol response, not a clean exit value. No `[BENCH_RESULT]` lines emitted. The Stage 2 implementer's `scripts/regress_dsim.sh` accepts any `TOHOST=...` write as STOP-OK, masking this. Pre-flight measurement (predates this refactor too) showed cm.hex writing `tohost=1` PASS, so the binary changed between pre-flight and Stage 2 by some external process. **Functional correctness of CoreMark is not being verified end-to-end.** Recommended follow-up: rebuild cm.hex from source, ensure clean exit value; OR change cm.hex to a riscv-perf-tests version that emits proper PASS.

### 2. dhrystone DMIPS/MHz substantially short of MegaBoom floor

DMIPS/MHz = 2.42 vs floor 4.00 (−39.5%). cm/MHz dropped −2.4%; dhry dropped −20%. The differential suggests dhrystone has procedure-call / branch-resolution bottlenecks not captured by Stage 2's load_wb sideband fix (which was load-IPC focused). Possible investigation directions:
- Checkpoint allocation / restoration on dhry's procedure-heavy hotpath
- BPU alignment for short forward branches in the procedure prologue/epilogue
- Restoring NUM_ALU=4 (planning doc target was 3 — perhaps too aggressive for dhry's narrow-but-frequent ALU bursts)
- Increasing IQ_INT_DEPTH back from 24 → 28 (dhry may saturate the smaller IQ on procedure entry)

These would be **post-refactor optimisation work** — not a Stage 6, but a separate dhry-tuning phase.

### 3. Coupling of stages diverged from "pure narrowing" plan

The plan envisioned Stages 1-5 as pure narrowing with no architectural change. Reality: Stage 2 required an architectural fix (load_wb sideband) to keep regression alive. Plan §"What NOT to Do" #9 was updated with an exception clause; future planning should anticipate that narrowing CDB always requires this kind of fix.

---

## Sign-off recommendation

**DO NOT MERGE TO MASTER YET.** The refactor is technically complete and clean (18/18 functional, 3/3 clockcheck, all benches STOP-OK at $finish, monotone allowlist), but the sign-off targets are not met. Two reasonable paths:

**Path A — Address the dhry bottleneck before merge.** Investigate the +20% dhry IPC gap (compare bucket attribution between 6-wide baseline and current 4-wide dhry runs). If a small param adjustment (e.g., NUM_ALU back to 4, or IQ_INT_DEPTH tweak) restores DMIPS/MHz to ≥ 4.00 without breaking cm, sign off and merge.

**Path B — Merge as 4-wide-narrowed-only-baseline.** Accept that this refactor produced a *correctness-clean* 4-wide narrowing. Open a follow-up branch for dhry-specific optimisation (Stage 6: post-narrowing IPC recovery). Risk: 4-wide on master without sign-off invites future drift.

**Path C — Investigate the cm.hex tohost issue first.** The CoreMark binary's HTIF behaviour is suspicious and the relaxed STOP-OK detection is masking a possible functional issue. Rebuild cm.hex with proper exit, verify the 6.05 CM/MHz number is real, then decide A vs B.

My recommendation: **C → A → merge.**

---

## Reproducing this measurement

```bash
cd /home/jeremycai/agent-workspace/rv64gc-v2
git checkout 4wide-pivot   # currently HEAD: 3a64585
export LD_LIBRARY_PATH=
bash build_dsim.sh
bash scripts/regress_dsim.sh 2>&1 | tee /tmp/regress_signoff.log
grep -E "PASS|TIMEOUT|IPC:|STOP-OK|FAIL" /tmp/regress_signoff.log
```

For per-test detail: `bash run_dsim.sh tests/hex/<hex_name>.hex 5000000 +PERF_PROFILE`; result in `dsim_run.log`; key lines: `IPC: mcycle=...` and `PASS at cycle ...` or `TOHOST=...`.

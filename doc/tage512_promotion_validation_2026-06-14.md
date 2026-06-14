# TAGE_TABLE_ENTRIES 256→512 Promotion Validation — VERDICT: HOLD (gated) (2026-06-14)

**Headline.** The funded misp-band capacity win **reproduces exactly** (aha-mont64 −5.50% misp, sglib-combined
−4.49%, qrduino −2.36% — decimal-matching the sim gate `doc/tage_entropy_gate_2026-06-14.md` A4-512 column),
but the **suite no-regression gate FAILS**: a 256→512 TAGE bump deterministically **regresses nnet-kernel
−2.63% IPC (mispredicts +77.7%, 26,141→46,443)**, a funded FP-cluster row, plus ~6 misp-asymptote rows by
0.1–1.3%. The change is **functionally correct** (zero compliance miscompare) and **lint-clean** (15 UNOPTFLAT,
zero new TAGE-path loops), and the capacity sub-band geomean holds at **+1.34%**. But the strict no-regression
invariant (every row within +0.01% of the 7fa9096 baseline) is **violated**, and the violation is not noise —
the simulator is bit-deterministic (3× identical re-runs) so nnet's +78% misp is a real destructive-aliasing
interaction at 512 entries. **Recommendation: HOLD 256→512 (keep gated). Do NOT promote default-on.** The
geomean lever's +0.14% full-band IPC does not justify a −2.63% regression on a roster-adjacent FP row, and the
timing question is still only a yosys relative-depth estimate, not STA. **Tree restored to committed 256.**

---

## 1. The change (verified pure-param, scales cleanly)

One-line flip, `rv64gc_pkg.sv:314`:

```diff
-    localparam int TAGE_TABLE_ENTRIES = 256;               // 256 entries each
+    localparam int TAGE_TABLE_ENTRIES = 512;               // 512 entries each
```

Param-scaling audit (RTL-confirmed, no co-scaling needed):
- `TAGE_IDX_BITS = $clog2(TAGE_TABLE_ENTRIES)` auto-widens 8→9 (`tage_sc_l.sv:51`).
- Index hash `pc[TAGE_IDX_BITS+1:2] ^ fold_idx[t] ^ TAGE_IDX_BITS'(pc[21:12]>>t)` — all three terms
  `TAGE_IDX_BITS`-wide / cast, auto-widen (`tage_sc_l.sv:207`).
- GHR fold arrays `[TAGE_IDX_BITS-1:0]` auto-widen; reset/clear loops `for(e<TAGE_TABLE_ENTRIES)` auto-scale.
- `TAGE_TAG_BITS=12` is a fixed localparam, **entry-count-independent** — correctly NOT co-scaled (tag width
  should not move with capacity). Counter (3b) / useful (2b) likewise fixed.
- `TAGE_TABLE_ENTRIES`/`TAGE_IDX_BITS` consumed **only** in `tage_sc_l.sv`. `checkpoint.sv` / `uarch_pkg.sv`
  have **zero** dependence (only GHR_BITS=64 ripples into checkpoint, and GHR is untouched). SC (1024) and
  loop-pred (64) untouched — the KILL'd dead-silicon axes stay put.
- SRAM exactly 2×: 4 tables × (256→512) × 18 bits = 18,432→36,864 bits. Matches synth check (+1 index bit, 2× SRAM).

## 2. Validation ladder

| Gate | Result | Verdict |
|---|---|---|
| **1. Lint UNOPTFLAT** | 15 warnings (5 pre-existing FTQ/IFU/fetch_top + 10 cvfpu FPU); **zero new TAGE/BPU-path loops** | **PASS** |
| **2. Misp-band A/B** | capacity rows improve as funded (aha −5.50% misp, sglib −4.49%, qrduino −2.36%); entropy rows flat-to-noise | **PASS** (funded win holds) |
| **3. Suite no-regression** | **nnet-kernel −2.63% IPC (misp +77.7%)** + 6 asymptote rows −0.1…−1.3%; 8 rows bit-identical | **FAIL** |
| **4. Compliance (correctness)** | **109/113 explicit PASS, 0 functional miscompare**; 4 TIMEOUT are a tb_xsim artifact (256/512 bit-identical instret) | **PASS** (correctness) / DSim-runner blocked (pre-existing) |
| **5. Timing** | yosys relative-depth +1 mux level only; **no STA** | caveat stands |

### 2a. Misp-band A/B (Gate 2 — funded win reproduces exactly)

| row | IPC 256→512 | ΔIPC | misp 256→512 | Δmisp | gate-doc A4-512 |
|---|---|---|---|---|---|
| aha-mont64 | 1.5357→1.5596 | **+1.56%** | 77,103→72,862 | **−5.50%** | −5.5% ✓ |
| sglib-combined | 1.4712→1.4978 | **+1.81%** | 95,510→91,218 | **−4.49%** | −4.5% ✓ |
| qrduino | 1.5302→1.5405 | **+0.67%** | 107,019→104,491 | **−2.36%** | −2.4% ✓ |
| md5sum | 1.8149→1.8043 | −0.58% | 52,580→53,632 | +2.00% | +2.0% ✓ (entropy) |
| rvb-qsort | 1.3587→1.3484 | −0.76% | 11,059→11,215 | +1.41% | entropy |
| huffbench | 1.5420→1.5352 | −0.44% | 77,144→76,998 | −0.19% | entropy(net) |
| rvb-median | 1.3137→1.2973 | −1.25% | 498→517 | +3.82% | noise (498 total) |
| crc32 (control) | 2.3004→2.3004 | 0.00% | 12→12 | 0% | flat ✓ |

- A0 256 reproduces the scoreboard IPCs to 4 decimals (faithful baseline).
- **Misp-band geomean (7 rows): 1.5023 → 1.5044 = +0.138%.** Capacity sub-band (3 funded rows): +1.34%.
  Entropy sub-band: −0.76% (timing reshuffle on data-dependent-random branches; the doc's +1.51% was the
  **1024** geomean — at 512 the entropy drag eats most of the full-band lift).

### 2b. Suite no-regression (Gate 3 — THE GATE THAT FAILS)

Sim is bit-deterministic (verified: 3× identical rvb-median re-runs → identical IPC) so all deltas are real.

| category | rows |
|---|---|
| **IMPROVE** (6) | sglib(+1.81%), aha(+1.56%), coremark_iter10(+0.90%), qrduino(+0.67%), nettle-sha256(+0.42%), nettle-aes(+0.20%) |
| **FLAT / bit-identical** (8) | crc32, rvb-rsort, statemate, dhrystone, sha-kernel, linear_alg-kernel, loops-kernel (and nnet by instret-at-cap is NOT flat — see below) |
| **REGRESS** (7) | **nnet-kernel(−2.63%)**, rvb-median(−1.25%), rvb-qsort(−0.76%), rvb-multiply(−0.74%), md5sum(−0.58%), huffbench(−0.44%), wikisort(−0.15%), rvb-spmv(−0.07%) |

Roster (≥2.95) rows are SAFE: rvb-rsort / statemate / dhrystone / crc32 bit-identical; sha-kernel 3.3456
identical; nettle-sha256/aes improve. The well-predicted backbone is unperturbed.

**The disqualifier — nnet-kernel (2026-06-14 confirmed, FP-cluster funded row):**
256 IPC 2.1326 → 512 IPC 2.0765 (**−2.63%**), driven by **misp 26,141 → 46,443 (+77.7%)**. Reproduced at a
3M-cycle short cap (256 misp 8,681 → 512 misp 14,457, IPC −2.56%). The 512-entry index creates a destructive
aliasing pattern for nnet's (PC×history) footprint that the 256-entry table happened to avoid — the exact
"bigger predictor perturbs a well-behaved row" failure mode the gate exists to catch. Real, deterministic,
significant, and on a row the FP campaign is actively trying to *raise*.

### 2c. Compliance (Gate 4 — correctness, PASS)

DSim runner (`tools/run_rv64gc_compliance.py`) is **blocked by a PRE-EXISTING, TAGE-orthogonal break**: the
7fa9096 D-prefetcher introduced a `dc_pf_req_valid` `[Redefinition]` in `rv64gc_core_top.sv` that DSim 2026
rejects — **proven on the committed 256 tree** (`git stash` → identical build failure, exit 1). The Jun-13
`dsim_work` image was from an older tree; 7fa9096 was never DSim-built.

Substitute: ran the full **113-test riscv-tests ISA suite** (54 ui + 13 um + 19 ua + 1 uc + 11 uf + 12 ud +
3 mi) on the 512 Verilator binary via tb_xsim's tohost convention. **109/113 explicit PASS, 0 FAIL-at-cycle.**
The 4 TIMEOUTs (rv64uc-p-rvc, rv64ud-p-move, rv64ui-p-ld_st, rv64ui-p-ma_data) are a tb_xsim/Verilator
tohost-monitor artifact (these self-checkers loop; DSim terminates them) — **256 and 512 retire bit-identical
instret** on every one (e.g. ld_st 748,359 = 748,359; ma_data 746,005 = 746,005; rvc 1,249,564 = 1,249,564),
so zero architectural divergence. TAGE 512 introduces **no correctness regression**.

### 2d. Timing caveat (Gate 5)

The synth-cone PASS was **yosys relative-depth (+1 mux level), not true STA**. The TAGE read sits on the F0/F1
fetch critical path; a +1 index-mux level on the fetch frequency-limiting cone cannot be cleared without real
STA. Even absent the regression, this caveat alone warrants gating until STA.

## 3. Verdict — HOLD (keep gated), do not promote default-on

Three independent reasons, any one sufficient:
1. **No-regression gate FAILS** — nnet-kernel −2.63% IPC (misp +78%) is a real, reproducible regression on a
   funded FP-cluster row; 6 asymptote rows also dip 0.1–1.3%.
2. **The geomean lever is weak at 512** — full misp-band geomean only +0.14% IPC (the funded +1.51% was the
   1024 number; entropy drag eats the 512 gain). Capacity sub-band +1.34% is real but buys no roster crossing
   (best row sglib 1.498, nowhere near 2.95).
3. **Timing is unsettled** — relative-depth estimate only, no STA on the fetch cone.

A geomean/maintenance lever that improves 6 rows by ≤1.8% while regressing a funded FP row by 2.6% is a net
**negative** trade at the suite level. KILL stands on loop-pred and SC (untouched). If the architect still wants
the three-row capacity win, the path is a **targeted** fix (e.g. better index hashing / per-table tag-width to
de-alias nnet) measured against this exact no-reg suite — not a blind entry-count bump.

## 4. Reproduction / artifacts

- Arms: `verilator_bench_tage512/Vtb_xsim` (live tree=512 during runs) and `/tmp/tage256_shadow/.../Vtb_xsim`
  (symlink-farm shadow, pkg=256). Both built `nice -n 10`, matched binaries.
- A/B driver: `log/tage512_ab/run_ab.sh` (21 rows × 2 arms, ≤6 concurrent). Compliance: `run_compliance.sh`.
  Analysis: `analyze.sh`. Raw logs: `log/tage512_ab/{a256,a512,compliance512}/`.
- **Tree state at finish:** `rv64gc_pkg.sv` restored to committed 256 (git-clean for this change). Note:
  `src/rtl/core/cache/dcache.sv` carries a concurrent-session (store-engine S1-fix) edit — NOT from this work.
- **Side effect:** `build_dsim.sh`'s `rm -rf dsim_work` ran before the pre-existing `dc_pf_req_valid` failure,
  so the stale Jun-13 DSim image is gone. No loss — that image was from an older tree and 7fa9096 doesn't
  DSim-build until the `dc_pf_req_valid` redefinition is fixed (separate, TAGE-orthogonal work item).

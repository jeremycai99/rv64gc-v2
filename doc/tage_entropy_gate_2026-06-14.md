# TAGE Entropy-vs-Capacity Gate (Lever B) — VERDICT: PARTIAL CAPACITY (2026-06-14)

**Headline.** The misp-asymptote band is **not** uniformly "information-theoretic /
irreducible" as the scoreboard asserted. A zero-RTL TAGE-capacity sweep splits it cleanly into
two sub-bands: **(1) a pure-entropy sub-band** (md5sum, rvb-qsort, huffbench-net) that is flat
under any predictor enlargement — the scoreboard's irreducibility verdict is now **MEASURED, not
asserted, and confirmed** for these rows; and **(2) a genuinely capacity-limited sub-band**
(sglib-combined, aha-mont64, qrduino) where the small 4×256-entry TAGE under-covers the
multi-loop branch working set. Enlarging TAGE table entries 256→1024 cuts mispredicts
**−6% to −12%** and lifts IPC **+0.03 to +0.07** on those three rows (misp-band geomean
**+1.51%**), **monotonic** in table size, and isolated to **TAGE entries** (loop-pred 4× and
SC 2× contribute nothing). **No row crosses 2.95** — zero roster expansion, exactly as the prior
projected. So Lever B is a **geomean/maintenance lever, NOT a roster expander**, and the FUND
decision rests entirely on whether **a larger TAGE read fits the F0/F1 fetch timing cone** —
which this sim-only gate cannot settle. **Recommendation: a TAGE 256→512 entry bump is the
defensible promote** (captures ~half the gain at min area/timing risk) **gated behind a synth/STA
timing check**; the loop-predictor and SC enlargements are **dead silicon — KILL.**

Tree at `e3c6f06` (branch `backend/lq-instrument`); pkg `rv64gc_pkg.sv` git-clean before and after
(md5 `ddc620db…`). All arms freshly built from the current pkg, A/B on matched binaries, all rows
PASS to STOP, all with `+PERF_PROFILE` (internally consistent). Did not disturb the running Linux
boot (pid 2196358) or the D-prefetch census agent.

---

## 1. The sweep (pure param, zero RTL)

The predictor geometry params are all `localparam` in `rv64gc_pkg.sv:267–292`, and every index/tag
width is `$clog2`-derived (`tage_sc_l.sv:50–53`: `TAGE_IDX_BITS=$clog2(TAGE_TABLE_ENTRIES)`,
`SC_IDX_BITS`, `LOOP_IDX_BITS`). The lookup hash (`tage_sc_l.sv:207`,
`tage_lkp_idx = pc[TAGE_IDX_BITS+1:2] ^ fold_idx[t] ^ …`) and the GHR fold
(`fold_idx[t]` is `[TAGE_IDX_BITS-1:0]`) **auto-widen** with the entry count, so entry scaling is
genuinely pure-param and lint-clean. **Verified clean to scale:** TAGE table entries, SC entries,
loop-pred entries (all powers of 2). **NOT scaled (would need RTL):** additional tables or longer
GHR histories — the geometric history lengths are hardcoded 8/16/32/64 capped at `GHR_BITS=64`
(`tage_sc_l.sv:87–90`), and `GHR_BITS>64` ripples into `checkpoint.sv`/`uarch_pkg.sv`. Per the
gate scope, the sweep is **entry-count + loop-pred scaling only.**

Build = param-flip-in-place → build into a per-arm `VERILATOR_BENCH_WORK_DIR` → `git checkout`
restore. Each arm built `nice -n 10`, ≤4 concurrent sims alongside the boot + D-prefetch census.
**Lint:** every arm built clean; the only UNOPTFLAT warnings are the pre-existing FTQ +
cvfpu-library set — **zero BPU/TAGE-path comb loops in any arm** (grep of build logs for
`tage|bpu|loop_pred` UNOPTFLAT = empty). The bigger-table binaries are larger on disk
(a0 4,983,768 B → a1 5,000,256 B), an independent confirmation the geometry actually scaled.

| Arm | TAGE entries/table | SC entries | Loop-pred entries | Isolates |
|---|---:|---:|---:|---|
| **A0 baseline** | 256 | 1024 | 64 | (current tree) |
| **A4 TAGE-512** | **512** | 1024 | 64 | pure TAGE 2× (SC/loop held) |
| **A1 TAGE-1024** | **1024** | **2048** | 64 | TAGE 4× (+ SC 2×) |
| **A2 LOOP-256** | 256 | 1024 | **256** | loop-pred 4× only |
| **A3 BIG-ALL** | **1024** | **2048** | **256** | everything 4×/2× |

A0 reproduces the scoreboard IPCs **exactly** (md5sum 1.815, aha-mont64 1.536, sglib 1.471,
qrduino 1.530, huffbench 1.542, median 1.314, qsort 1.359) — the baseline is faithful to the
current tree.

---

## 2. Results — per row (the deliverable table)

IPC and total cond-mispredicts (`bpu_dyn_total misp`, from the `tage_sc_l`-bound dynamic profiler).
Δmisp/ΔIPC vs A0. crc32 = chain-control (low misp → expected flat).

| row | A0 base IPC / misp | A1 TAGE-1024 IPC / misp (Δmisp, ΔIPC) | A2 LOOP-256 (Δmisp) | A3 BIG-ALL (Δmisp) | **verdict** |
|---|---|---|---|---|---|
| **sglib-combined** | 1.4712 / 95,510 | **1.5448 / 84,248 (−11.79%, +0.0735)** | 95,807 (+0.31%) | 84,608 (−11.41%) | **CAPACITY** |
| **aha-mont64** | 1.5357 / 77,103 | **1.5908 / 68,985 (−10.53%, +0.0551)** | 78,775 (+2.17%) | 72,470 (−6.01%) | **CAPACITY** |
| **qrduino** | 1.5302 / 107,019 | **1.5588 / 100,193 (−6.38%, +0.0286)** | 106,522 (−0.46%) | 101,302 (−5.34%) | **CAPACITY (modest)** |
| rvb-median | 1.3137 / 498 | 1.3319 / 473 (−5.02%, +0.0182) | 503 (+1.00%) | 467 (−6.22%) | capacity-shaped but **498 misp total = noise** |
| md5sum | 1.8149 / 52,580 | 1.8207 / 51,615 (−1.84%, +0.0058) | 52,643 (+0.12%) | 51,616 (−1.83%) | **ENTROPY** |
| rvb-qsort | 1.3587 / 11,059 | 1.3504 / 11,199 (+1.27%, −0.0083) | 11,075 (+0.14%) | 11,222 (+1.47%) | **ENTROPY** |
| huffbench | 1.5420 / 77,144 | 1.5285 / 77,563 (+0.54%, −0.0135) | 79,955 (+3.64%) | 77,769 (+0.81%) | **ENTROPY (net)** |
| crc32 (control) | 2.3004 / 12 | 2.3004 / 12 (+0.00%, +0.0000) | 12 (0%) | 12 (0%) | **flat — control valid** |

**Misp-band geomean IPC (7 misp rows, excl. crc32 control):** baseline **1.5023** → A1 **1.5249**,
**+1.51%**.

### 2a. Monotonicity + axis isolation (the load-bearing controls)

Mispredicts fall **monotonically** with TAGE entry count on the capacity rows, and **A4 holds SC at
the baseline 1024** — so the win is **TAGE table entries, not SC**:

| row | 256 (base) misp | 512 misp (Δ) | 1024 misp (Δ) | trend |
|---|---:|---:|---:|---|
| aha-mont64 | 77,103 | 72,862 (−5.5%) | 68,985 (−10.5%) | **monotonic ↓** |
| sglib-combined | 95,510 | 91,218 (−4.5%) | 84,248 (−11.8%) | **monotonic ↓** |
| qrduino | 107,019 | 104,491 (−2.4%) | 100,193 (−6.4%) | **monotonic ↓** |
| md5sum | 52,580 | 53,632 (+2.0%) | 51,615 (−1.8%) | **noise around 0 — no trend** |

- **A2 (loop-pred 64→256, TAGE/SC held): flat everywhere** (+2.2% / +0.3% / −0.5% / +0.1%).
  Loop-predictor capacity is **definitively not the lever**. → loop-pred enlargement is dead silicon.
- **A3 (BIG-ALL) ≈ A1 (TAGE-only)** within noise on every row → the SC 2× and loop 4× add **nothing**
  on top of the TAGE-entry bump. The entire effect is TAGE table capacity.

---

## 3. The discriminator — why two sub-bands (per-PC entropy census)

Per-PC `bpu_dyn_pc` fingerprint at baseline (`tage_hit` = a TAGE tagged table provided the
prediction; `loop_hit` = loop predictor fired; "no-cover" = neither, fell to bimodal base):

| row | distinct misp PCs | PCs carrying 90% of misp | TAGE-tracked (entropy) | loop-pred (loop-exit) | no-cover (capacity-suspect) |
|---|---:|---:|---:|---:|---:|
| **md5sum** | 16 | **1** | **98%** | 0% | 2% |
| rvb-qsort | 19 | 6 | 71% | 16% | 12% |
| aha-mont64 | 17 | 7 | 72% | 1% | 27% |
| huffbench | 47 | 10 | 20% | 10% | 70% |
| **sglib-combined** | **111** | **40** | 7% | 46% | 47% |
| **qrduino** | **128** | **32** | 3% | 49% | 47% |

**The prior was right about md5sum and wrong about the band.**

- **md5sum (ENTROPY, confirmed exactly as the prior predicted):** one branch, `0x800021dc`, is
  **51,424 of 52,580 mispredicts = 98% of the row's misp**, at **76.2% misp-rate WITH 100%
  TAGE-hit**. TAGE already tracks this branch perfectly every single time and still cannot predict
  it — the textbook signature of a data-dependent-random branch. A bigger table cannot help a
  branch it already covers. md5sum is flat under 4× TAGE (−1.8%, noise). **KILL.** rvb-qsort is the
  same shape (71% entropy-tracked, flat/slight-regress). **KILL.**

- **sglib / qrduino / aha-mont64 (CAPACITY) — where the prior's reasoning broke.** The prior
  argued "hot branch set 19–128 PCs ≪ 1024 entries ⇒ no aliasing pressure." That conflates
  **PC count** with **(PC × history-context) demand**. sglib/qrduino have **111–128 distinct
  mispredicting PCs**, with **40+ PCs each carrying the misp mass** — and TAGE indexes on
  `PC ^ fold(GHR)`, so each PC needs a **distinct entry per distinct history context**. With only
  256 entries/table the working set thrashes. The proof is direct: enlarging the tables **raises
  TAGE coverage** exactly on these rows —
  sglib `tage_hit` 18.4%→26.1%, qrduino 18.8%→28.4%, aha 33.5%→38.6% (longest-table provider3
  rises in lockstep) — i.e. branches that fell through to loop-pred/base at 256 entries now get a
  TAGE entry and are predicted. That is a genuine capacity win, not entropy.

- **huffbench (ENTROPY, net):** coverage rises (36.2%→42.3%) but **net misp does not fall**
  (+0.5%) — the extra-covered branches are themselves low-confidence/random, so coverage buys
  nothing. Net **KILL.**

---

## 4. The honest bottom line

**Is any misp-band row capacity-limited?** **Yes — three of them measurably are**
(sglib-combined, aha-mont64, qrduino), against the scoreboard's blanket "irreducible" assertion.
The 4×256-entry TAGE is genuinely undersized for the multi-loop kernels' (PC×history) working set;
256→1024 cuts their mispredicts 6–12% and lifts IPC +0.03 to +0.07, monotonic in table size and
isolated to TAGE entries. **The scoreboard's irreducibility verdict is now MEASURED — and it is
correct for the entropy core of the band (md5sum, qsort, huffbench-net) but over-broad: it
incorrectly swept three capacity-limited rows into the "irreducible" bucket.**

**Is bigger-predictor a fresh lever?** **A weak one, and only for TAGE entries.** Caveats that
keep it off the roster:

1. **No roster crossing.** Best row sglib 1.471→1.545 — nowhere near 2.95. Lever B is a
   **geomean/maintenance** mover (+1.51% band geomean), exactly as the program projected; it
   **expands zero roster members.**
2. **Loop-pred + SC enlargement are dead silicon — hard KILL.** A2 (loop 4×) and the SC-2× delta
   in A1-vs-A4 are flat-to-negative on every row. Do not spend area there.
3. **The decision is a fetch-timing-cone question this gate cannot answer.** The TAGE read sits on
   the F0/F1 fetch critical path. A 4× (256→1024) entry table is a 2-bit-wider index + 4× the SRAM
   per tagged table × 4 tables — plausible to push fetch frequency. **This sim-only gate cannot
   settle timing; a synth/STA check must.** That is the real gate on funding, not the IPC delta.

**Recommendation (sized).** If the architect wants the geomean: promote **TAGE_TABLE_ENTRIES
256→512 only** (`rv64gc_pkg.sv:269`), parametric, `ENABLE`-equivalent bit-exact, leaving
SC=1024 and loop=64 untouched. Rationale: A4 shows 512 already captures **roughly half** the
1024-gain (aha −5.5%, sglib −4.5%, qrduino −2.4%) at **one index bit and 2× SRAM** — the
favorable area/timing point on the curve. **Gate the promote behind a synthesis timing-cone check
on the F0/F1 TAGE read**; if 512 fails timing, the lever is dead and the band's irreducibility
verdict stands hardened with measured proof. Do **not** go to 1024 without timing headroom — the
marginal +0.04 IPC on three non-roster rows does not justify risking fetch frequency.

**ITTAGE-for-boot (the gate's secondary question):** out of scope for this bare-metal cond sweep —
jalr indirect misp ≈ 0 on all eight rows (the profiler tracks the cond update port). The boot
jalr-10.6%-of-misp question needs the boot per-type counters (`commit.sv:587`), deferred per the
program's "last priority" framing; this sweep neither funds nor refutes it.

---

## 5. Reproduction

- Arms: `verilator_bench_tage_{a0,a1,a2,a3,a4}/Vtb_xsim` (param-flip-then-restore from
  `rv64gc_pkg.sv:269/273/276`).
- Runner: `tools/tage_gate_run.sh <bin> <outdir>` (8 rows + crc32 control, `+PERF_PROFILE`).
- Analysis: `tools/tage_gate_analyze.sh`; per-PC entropy census from `bpu_dyn_pc` lines
  (profiler `src/rtl/sim/bpu_dynamic_profiler.sv`, bound to `tage_sc_l`).
- Raw logs: `/tmp/tage_gate/{a0..a4}/<row>.log`.
- Tree state at finish: pkg git-clean (md5 `ddc620db334602ef136c8a1dfe81cc4f`); no RTL promoted.

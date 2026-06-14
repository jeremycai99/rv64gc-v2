# Fresh 3.x-Uplift Lever Program — rv64gc-v2 (2026-06-14)

**Scope.** rv64gc-v2 is a 4-wide scalar OoO RV64GC core at its **measured floor on conventional levers**.
This doc synthesizes four independent gap analyses (industry-trend map, band/occupancy
re-audit, ranked-fresh-lever pass, vector/software-axis pass) into the architect's fresh-lever
program. Goal: keep/expand the 3.x roster with **band-grounded, industry-grounded** levers that are
**not retreads** of the killed ledger (`doc/ipc3x_gate_results_2026-06-11.md`,
`doc/rv64gc_v2_uplift_roadmap_2026-06-13.md`). All four analyses **converge** — that convergence is
the headline, not a coincidence.

Cross-references: scoreboard `doc/perf_scoreboard_2026-06-13.md` (42 bare-metal rows),
real-kernel `doc/realkernel_profile_2026-06-14.md`, killed ledger above, M2-spill
`doc/m2_spill_policy_campaign_2026-06-13.md`.

---

## 1. Honest framing: rv64gc-v2 vs industry

The machine is **starved, not saturated**. Measured floor, suite-wide:
execute **0.16 cyc/uop**; ROB median **<32/128**; in-flight L ≈ **12**; `rob_full ≤1.16%`;
`backend_stall ≤4.4%` (backend ~84% idle); `cw5 = cw6 = 0` on **42/42** rows (commit never
wants a 5th slot). This is *why* every width/capacity/port lever in the killed ledger is correctly
dead — wider rename/dispatch/commit, 2nd FP pipe, dual-IQ-select, CDB widening, more AGUs,
MUL/DIV sideband, deeper ROB/PRF/IQ. **Do not retry any of these.**

Industry has six structural feature-classes we lack entirely. Verdict per class, against **our**
measured bottleneck bands:

| Industry feature we lack | Verdict for our bands | Why |
|---|---|---|
| **D-side HW prefetcher** (stride/stream) | **REAL LEVER — fresh** | Zero D-prefetcher in RTL (grep `prefetch\|stride\|nlpb` in `dcache.sv`+`lsu.sv` = **empty**, verified 2026-06-14). Real-kernel D$ miss **8–13%** vs bare 1.7% — the one signal bare-metal hid. Killed ledger only ever killed **I-side/L2-side** prefetchers. |
| **Larger/smarter cond predictor** (TAGE-SC-L 8–15 components, long history) | **REAL but gated — likely entropy** | Our TAGE is genuinely small (4 tables × 256 × 12b tag, GHR≤64, SC 1024, loop-pred 64 — verified). Capacity has **never** been A/B-discriminated from information-theoretic floor. Prior on the band: entropy. |
| **Value / address prediction** | **Context — chain-only, high-risk** | Only lever that breaks the chain band, but execute=0.16 cyc/uop means it helps **load hops only**; correctness blast radius is severe. |
| **ITTAGE** (indirect-target) | **Context / boot-only** | Bare-metal jalr misp ≈ **0** (md5sum 1, sglib 0, loops 2/518k). Only zip (7.4% jalr, capped) and Linux boot (10.6% of boot misp) see it. Not a roster lever. |
| **L3 cache** | **Measured-dead** | L2 (2M/8-way) is LLC; `wt_full=0`, multi-outstanding-L2 already refuted redundant. |
| **Decoupled FTQ-runahead frontend** | **Measured-dead** | G0 killed: uncovered taken edges 91–95% zero-bubble; full elimination buys ≤0.02–0.09 IPC. |

**Where the scalar core is genuinely capped (state plainly):**

- **Chain band** is a **true structural minimum.** `alu.sv` is purely combinational — no `clk` port,
  no `always_ff`/`posedge` in 292 lines; 1-cyc/hop is the dataflow optimum. czero/Zicond already
  1-cyc; no CLMUL lever (refuted — crc32 binder is the PRNG seed memory-recurrence, not the CRC
  table). On a scalar core, **only value-prediction or an ISA datapath-shortener breaks a chain**,
  and the suite is scalar-only (no V/RVV). ~6 chain rows are **software-axis-only** (±30–50% compiler
  variance).
- **Compute/dense-FP band** (matmul/dotproduct/nnet/stream) is **vectorizable-shaped but
  scalar-capped.** FP lever F1 (`FPU_PIPELINED_ISSUE_ENABLE`) tops out at nnet **2.65, not 2.95**;
  the residual binder is **FP-operand-latency**, a scalar chain length the core cannot shorten.
  There is **no funded scalar path above ~2.65** on the FP rows.
- **Width/translation/L2-QoS/ICache-MSHR bands** are closed by measurement (post-VIPT
  `fe_stall_xlate=0`, ICache-starve 0.25%).

**The two genuinely-open measured gaps a fresh mechanism can attack** (verified outside the killed
ledger by grep of all four source docs): **(1) the memory/D-cache band** (no D-prefetcher exists),
and **(2) the misp band's "information-theoretic" assertion** (never capacity-discriminated). Both
lead with a **cheap sim-only/static gate before any RTL**.

---

## 2. The prioritized fresh-lever program

### (a) Fresh levers that could ADD 3.x roster members

#### LEVER A — D-side L1D demand-stride prefetcher  ★ TOP PRIORITY

All four analyses independently surface this as the #1 fresh lever. Strong convergence.

- **Novelty (not in killed ledger).** The ledger killed **L2-prefetch** (L2-into-L2, sign-inverted
  by a no-latency TB — `ipc3x_gate §5`), **L0/victim-cache**, **ICache-MSHR**, **TLB/PTW-hierarchy**,
  and **NLPB-under-VM** (I-side). A **demand-load-trained stride/stream engine on the D-path** was
  **never proposed or measured** (grep of all 4 docs = empty). Structurally distinct: it issues into
  the existing **L1D 16-MSHR** (demand-fill today), attacks the **miss-COUNT** axis (vs the ledger's
  G4 LMB-drain / G5 multi-fill, which only touch **fill-latency/throughput**), and is cross-line
  address prediction (vs killed same-line-dual-load). Cache-sizing is FINAL (512K-L2/64K-L1D) and is
  capacity — orthogonal to a prefetch-**distance** engine.
- **Band + rows.** Memory/D-cache band. Bare-metal: **stream-l2** (2.322, lat2-proxy ceiling
  **2.871**, LINEAR), **stream-l1** (2.257), **parser** (0.623, lat2 **+57.5%** → ~0.9–0.98),
  **rvb-memcpy** (2.607), **zip** (2.524 mem residual). Plus the **real-kernel** paged D$ miss
  **8–13%** feeding 73%-of-fetch-stall backend back-pressure.
- **Projected 3.x impact.** Honest: most **bare-metal** resident loops have ~0 exposed fill latency
  at L=1 (P1 refuted), so the win is **real-kernel-weighted + geomean/boot**. Roster-crossing is
  **narrow**: stream-l2 2.32 → 2.7–2.9 (toward ≥2.95 only **jointly** with the funded FP+fill
  levers); memcpy → ~2.8. Conservative roster count: **~0–1 new bare-metal member**, but it is the
  **single largest real-kernel/geomean mover** available and the only attack on the one elevated
  real-kernel signal. **Note the exclusions up front:** spmv is **GATHER not stride**
  (`val(k)*x(idx(k))`, binder=misp) — **not a beneficiary**; rsort/memcpy show 0% at L=1.
- **Cost / risk class.** **GATE = sim-only, ~0 RTL** (~20–30-line census). RTL if funded: **~80–150
  lines** (PC-indexed stride table + confidence + degree-1 issue into a free L1D MSHR slot or the
  existing L2 pf port), gated `ENABLE=0` bit-exact. **HIGH interaction** with NWA/L2-arb → mandatory
  stream-l2 re-sign at **L=1 and L=80** (G5 precedent) + boot `+WEDGE_DUMP` (L2F-comb +11.2% precedent).
- **Pre-RTL gate.** Census on `fill_snoop` (`dcache.sv:54`) + the real-kernel boot trace + stream-l2/
  parser traces: per-load-PC **stride coverage × timeliness(8-cyc L2-hit) × miss-rate**, and L1D-MSHR
  free-slot availability. **FUND if** regular-stride loads ≥~30–40% of D-misses on ≥2 memory rows
  **AND** MSHR free ≥~50% of miss cycles **AND** projected timely conversion lifts a row UB ≥0.2 IPC
  (or crosses stream-l2 jointly) **or** cuts ≥3% of paged cycles. **Expect** stream-l2/parser PASS,
  spmv/memcpy/rsort FAIL.

#### LEVER B — Enlarged TAGE-SC-L, **entropy-vs-capacity gated**  (likely a KILL that hardens a verdict)

- **Novelty.** Our TAGE is small (4 tables × 256, GHR≤64) vs industry 8–15+ components / histories
  in the hundreds. The killed ledger attacks predictor **penalty** (early-redirect, DELIVERED) and
  **update-bandwidth** (M2-spill, REFUTED 2026-06-13) — predictor **table CAPACITY/geometry has
  zero A/B** in any of the 4 docs (grep-confirmed). The scoreboard **asserts** the ~10-row misp band
  is "information-theoretic / irreducible loop-exit," but that assertion has **never been tested**.
  Orthogonal to M2-spill (that's WHICH committed cond trains per batch, not table capacity).
- **Band + rows.** Misp-asymptote band, ~10 rows at the 1.5–1.9 asymptote: md5sum (2.01% cond-misp,
  ~27% cyc), qrduino (3.55%), huffbench (3.66%), mont64 (3.68%), sglib (3.85%, ~49% cyc),
  aha-mont64 (43% cyc), slre, ud, spmv; plus boot flush_commit 232,884.
- **Projected 3.x impact.** Honest: **NONE projected to cross 2.95** — loop-exit fraction caps them.
  This is a **geomean/boot lever IF capacity-limited**, else a **measured closure** of the band's
  irreducibility verdict. Either outcome is a deliverable the current *assertion* lacks.
- **Cost / risk class.** **GATE = pure param-sweep, ZERO RTL.** `TAGE_TABLE_ENTRIES` 256→512/1024,
  `LOOP_PRED_ENTRIES` 64→128, `SC_ENTRIES` 1024→2048 are all localparams (`rv64gc_pkg.sv:268–276`);
  DSim param-override → no-rebuild sweep. ~4–6 nice'd dsim-only A/B runs (no license-strand). RTL if
  a material capacity fraction is found: parametric, moderate area, lint + `ENABLE=0` bit-exact —
  **but the predictor read is on the F0/F1 fetch cone; a larger table must not push fetch critical
  path** (synth/timing gate).
- **Pre-RTL gate.** Per-branch-PC misp-**entropy census** on the band (reuse `commit.sv:587`
  per-type counters): classify each mispredicting PC as **under-trained/capacity-evicted** vs
  **genuinely-random/loop-exit**. **FUND** a geometry bump only if doubling entries moves misp-rate
  ≥~15% relative on ≥2 rows. **KILL (expected-likely)** — prior is strong: md5sum top misp PC 0x21dc
  is **76% misp WITH 97% TAGE-hit** = pure entropy; hot branch set is **19–128 PCs vs 1024-entry**
  tables (no aliasing pressure); capacity-suspect misp is 0–5% of mass. This same census also settles
  whether ITTAGE is worth it for boot (jalr 10.6% of boot misp).

### (b) The software axis — zero-RTL 3.x **maintenance** (not a roster expander)

The cheapest per-row lever measured: production-compiler variance **±30–50% in cycles**
(multiply gcc 1.05 → **clang 2.37**, −57%; nsichneu −26%; median +35%), DS word-wide-strings +6%,
parser +5.3% ww. **Zero RTL, dwarfs every RTL lever across 5 gap-closure cycles.**

But it is **REFUTED as a roster EXPANDER** on the rows that need it, by direct measurement:
- Zicond/GCC-14 czero moves **mispredict** rows, **not the chain band**, and **lengthens** the
  loop-carried chain (mont64 3→6 ops → honest net **−2.2%**).
- The chain band "has no in-reach ISA shortcut on a scalar-only core" (roadmap §6.3 D4).
- **multiply's clang-2.37 is the ONLY clean software-only roster crossing** — and it is
  compiler-generic, not a uarch property.

**Use it for 3.x maintenance** (compute-row health, word-wide-strings on DS-class rows), not
expansion. One **-flto cross-TU** probe on the GEMM nests is worth a static-objdump check (the per-TU
audits structurally couldn't see cross-TU inlining); **gate = static-first**, fund ~5 sim A/B runs
only if the inner loop materially tightens; report on **both IPC and elements/cycle**. A null result
is itself load-bearing — it forces the vector decision.

### (c) The big-product question — VECTOR / RVV

**Verdict: a separate product, not an rv64gc-v2 POR item. KILL as a roster-expander; document as the
throughput-product fork.**

- The compute band is **genuinely vectorizable-shaped** (confirmed in source): matmult-int = textbook
  GEMM, linear_alg = SAXPY/dotproduct, nnet = dense FP matmul, stream = STREAM copy/scale/add/triad,
  vvadd = literal vector-add. A VLEN=128/SEW=32 unit would buy **~2–4× elements/cycle** (NEON/SVE/RVV
  industry-wide). Vector is **entirely absent from the killed ledger** — the only transformative lever
  not measured-killed, precisely because it is out of the scalar frame.
- **But it is a different product on a different KPI.** Cost: RVV decode + vector RF (32×VLEN=512B) +
  vector FMA lanes + a **dedicated wide vector LSU** (the current 2×64b-load/1×64b-store scalar LSU
  would gate it) = **thousands of lines, FP-compliance-class blast radius**, the "V" the product does
  not carry. **Critically, vectorized code structurally CANNOT win the 3.x-IPC contest as scored:**
  instret/cycle **drops** when each instruction does 4× work. The 3.x-roster KPI is a **scalar-instret
  artifact**; vector wins must be framed as **elements/cycle / wall-clock**.
- **Pre-commitment gate (zero-build):** (1) compile the 6 compute kernels `-march=rv64gcv` (GCC-14
  autovec / rvv intrinsics) and confirm via objdump they **actually emit vector loops** (autovec
  failure on these nests is common — if GCC refuses, the premise is moot for free); (2) trivial
  spreadsheet: elements/cycle = min(FMA-lanes/cyc, vector-LSU-bytes/cyc) on captured trip counts.
  **Fund a vector-product STUDY only if** both autovec emits AND model shows ≥2× elements/cycle on ≥3
  rows under realistic narrow-LSU bandwidth **AND the architect rescopes the KPI** to elements/cycle.

### (Deferred) ITTAGE indirect-target predictor

Missing component (jalr from BTB only, `bpu.sv:256-258`; `commit.sv:587` names it), but **conditional
resize is dead by entropy** and indirect misp is **only material on zip (capped, 92% cond-dominated)
and Linux boot**. **Gate already measured (free):** per-type misp split. **Last priority** — payoff is
one capped row; revisit only if a representative boot/server KPI is adopted.

---

## 3. What kills each fresh lever (the skeptical case)

- **D-prefetcher (Lever A) — coverage uncertainty.** Kills if D-misses are **pointer-chase /
  irregular** (parser is a known byte-serial/pointer binary problem — may fall out of coverage) or if
  the L1D MSHR is **demand-saturated** (no free slot to issue into without contending demand).
  **spmv is already excluded (gather, not stride).** Most bare-metal loops have ~0 exposed fill at
  L=1, so a high-coverage census still might not cross a *bare-metal* roster row — the honest win is
  real-kernel/geomean. The census exists to **kill it cheaply before any RTL** if stride coverage
  <30–40%.
- **Enlarged TAGE (Lever B) — it's entropy, not capacity.** The skeptical case is the **expected
  case**: md5sum 76%-misp WITH 97% TAGE-hit, hot-PC set 19–128 ≪ 1024 entries, capacity-suspect
  misp 0–5% of mass. Bigger tables = **dead silicon** on the fetch critical path. The budget then
  correctly stays on M2-spill (misp count) and the band's irreducibility verdict is **hardened with
  measured proof** — which is the deliverable.
- **Value prediction (the chain-band temptation) — correctness blast radius.** Not funded for RTL.
  `checkpoint.sv` (64 ckpts) is **branch-triggered**; VP needs **per-value selective replay**, a new
  squash mechanism with blast radius into FP-bypass and the M1/M2 paths (cf. the 21842ac FP-bypass
  bug). execute=0.16 cyc/uop means VP helps **load hops only**. **Gate = zero-cost offline**:
  `tools/uoplife_critical_path.py` on crc32/mont64 to confirm the load hop is on the critical chain,
  then feed the load-result sequence to a software LCG/stride/last-value model. **Fund RTL only if**
  ≥1 row ≥70% predictable AND collapse >5%. Expect crc32's deterministic LCG recurrence predictable,
  pointer-chase not. **Do not start RTL without the offline result.**
- **Vector — scope/cost/KPI.** Thousands of lines, FP-compliance-class risk, a product-line decision
  (rv64gcv). Even if built, it **loses the 3.x-IPC contest by construction** (instret drops). The
  autovec-emit gate may kill it for free if GCC won't vectorize the nests.

---

## 4. The honest bottom line

**Can the scalar core meaningfully expand the 3.x roster with fresh levers?** Mostly **no** — and the
architect should hear that plainly.

- The scalar machine is at a **genuine floor**. The chain band is a **proven structural minimum**
  (combinational ALU, 1-cyc/hop); the dense-FP/compute band is **scalar-capped at ~2.65** with no
  funded path to 2.95; width/translation/QoS bands are measured-closed. **Five gap-closure cycles and
  the entire killed ledger agree.** The two fresh levers below are the **only** band-grounded,
  ledger-fresh candidates — and their honest roster math is modest.
- **Of the two fresh levers, exactly one has roster/geomean upside, and it is real-kernel-weighted.**
  **Lever A (D-side L1D stride prefetcher)** is the program's center of gravity: it attacks the one
  elevated real-kernel signal (D$ 8–13%), has a textbook win shape on the stream rows
  (stream-l2 lat2-ceiling **2.871**), costs **~0 RTL to gate** and ~80–150 lines if funded. Expect
  **~0–1 new bare-metal roster member** but a **material real-kernel/geomean/boot mover** — the best
  available fresh expansion, with a cheap census that kills it if coverage is irregular.
- **Lever B (enlarged TAGE) is most likely a high-value KILL.** The prior says entropy, not capacity;
  the value is converting the scoreboard's *assertion* into *measured fact* for ~half a day of
  dsim-only sweeps, with **upside only if a capacity fraction is found** (none projected to cross 2.95
  regardless).
- **Real roster expansion into the dense-compute regime needs vector — a different product on a
  different KPI (elements/cycle), not a scalar uplift.** The software axis is the right tool for
  **3.x maintenance** (zero-RTL, ±30–50%/row) but is **refuted as an expander** on the chain band;
  only multiply's clang-2.37 is a clean software crossing.

**Recommended program order:**
1. **Lever A D-prefetch census** (sim-only, ~0 RTL) — the highest-EV fresh action. Fund RTL on
   coverage ≥30–40% + MSHR headroom + ≥0.2 IPC row lift (or stream-l2 joint-cross / ≥3% paged cycles).
2. **Lever B TAGE entropy census** (param-sweep, zero RTL, dsim-only) — cheap; fund geometry only on
   ≥15% relative misp move on ≥2 rows + fetch-timing close; else **harden the irreducibility verdict
   and bank the closure**. Settles ITTAGE-for-boot in the same census.
3. **Software-axis maintenance** in parallel (-flto static probe on GEMM nests, word-wide-strings on
   DS-class) — zero-RTL geomean/maintenance, not counted as expansion.
4. **Vector** = a **scoped pre-RTL study only** (autovec-emit + elements/cycle model), explicitly
   forked as the **throughput product (rv64gcv)** with a **rescoped KPI** — not an rv64gc-v2 POR item.

**Do-not-retry (killed/dead, all four docs agree):** wider rename/dispatch/commit, 2nd FP pipe,
dual-IQ-select, CDB widening, more AGUs, MUL/DIV sideband, deeper ROB/PRF/IQ, L2-prefetch,
L0/victim-cache, ICache-MSHR, TLB/PTW-hierarchy, NLPB-under-VM, FTQ-runahead/G0,
same-line-dual-load, conditional-predictor-resize-for-its-own-sake, crc32-clmul, L3,
multi-outstanding-L2-fill.

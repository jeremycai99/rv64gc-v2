# rv64gc-v2 vs. the Open-Source RISC-V Field — Performance Comparison (2026-06-14)

**Purpose.** A rigorous, data-backed positioning of rv64gc-v2 against the main
open-source RISC-V CPU designs (BOOM/SonicBOOM, XiangShan, CVA6, Rocket, and the
adjacent in-order field). This is a **study artifact**, not a marketing sheet: every
cross-suite and cross-compiler caveat is flagged, and IPC is separated from frequency
throughout.

**Read-only on our side.** No sims were run for this document (a Verilator boot and a
gate agent are running). Our numbers are taken from the promoted-config docs cited inline.

---

## 0. The methodology rules this comparison obeys (read these first)

These are the rules that make the table below honest. Violating any one of them is how
RISC-V CoreMark/DMIPS comparisons usually go wrong.

1. **Pin the compiler.** A single compiler-version bump is worth **±0.5–2.2 IPC per row**
   on our suite — *larger than any RTL lever we found in five gap-closure cycles*
   (`doc/software_axis_3x_2026-06-14.md` headline). Our suite is built with **GCC-13.4,
   `czero`-blind** (GCC-13.4 emits *zero* `czero` despite the `_zicond` march flag —
   Zicond codegen only landed in GCC-14). BOOM publishes against **GCC-11.1**, XiangShan
   Nanhu against **GCC-10.2 `-O2`**, XiangShan Yanqihu against **GCC-9.3 `-O2`**. These
   are *not* the same compiler. Every cross-core delta below carries this caveat.

2. **CoreMark is signedness- and flag-sensitive.** The published BOOM CoreMark/MHz swings
   **5.49 → 6.89** purely from `-O2` vs `-O3`, `signed` vs `unsigned ee_u32`, and SFB
   on/off (`luffca.com/2022/04`). "CoreMark/MHz" is not one number; it is a *recipe*.

3. **IPC ≠ frequency.** CoreMark/MHz and DMIPS/MHz are **per-clock** metrics (IPC
   proxies) and say nothing about achievable Fmax. XiangShan Nanhu @ 2 GHz / 14 nm and
   SonicBOOM synthesized @ 1 GHz are *frequency* facts; their CoreMark/MHz are *IPC*
   facts. We keep them in separate columns.

4. **Cross-suite ≠ comparable.** CoreMark/MHz, DMIPS/MHz, and SPEC/GHz measure different
   things. A core's SPEC standing cannot be inferred from its CoreMark standing — SPEC's
   large working sets stress the memory hierarchy and branch predictor far harder than
   CoreMark's tiny resident loops. We never convert one into the other.

5. **Our SPEC number does not exist yet.** We measure **bare-metal** embench / CoreMark /
   Dhrystone + paged-Linux **boot-IPC**. We **cannot yet run SPEC** — the Linux boot only
   just reached early userspace (`doc/realkernel_profile_2026-06-14.md`); there is no SPEC
   harness, no ref-input runs, no rate/speed methodology. Any SPEC positioning below is
   explicitly labeled **UNMEASURED / inferred** and is the weakest claim in this document.

---

## 1. Apples-to-apples: CoreMark/MHz and Dhrystone DMIPS/MHz

The metrics the open cores actually publish. **Compiler/flags annotated per row** — they
are not the same, so this table ranks *recipes*, not just cores.

| Core | Class | CoreMark/MHz | Dhrystone DMIPS/MHz | Compiler / flags | Source |
|---|---|---|---|---|---|
| **rv64gc-v2 (ours)** | 4-wide OoO | **6.96** (iter10, IPC 2.185) | **4.273** (IPC 2.62) | **GCC-13.4**, suite CFLAGS, czero-blind | `ipc3x_gate_results_2026-06-11.md`, `stage5b_vipt_results_2026-06-04.md` |
| SonicBOOM (MegaBoom) | 4-wide OoO | **6.2** nominal (5.49–6.89 by recipe) | **3.93** | GCC-11.1, `-O2`/`-O3` ±SFB ±signedness | CARRV'20 Fig 7 + Table 1; luffca 2022/04 |
| XiangShan Yanqihu (Gen1) | superscalar OoO, 11-stage | **5.3** | (not published) | GCC-9.3 `-O2` | XiangShan HPCA'25 slides p.14 |
| NaxRiscv | OoO | 4.59 | 2.94 | GCC-11.1 `-O3 -funroll…` / `-O3 -fno-inline` | luffca 2022/07 |
| SiFive U74 | 2-wide in-order | 4.9 | 2.5 | (vendor) | SiFive U74 manual; CARRV'20 Fig 7 |
| **CVA6 / Ariane** | in-order, 6-stage scoreboard, single-issue | **3.10** | ~1.7 | (OpenHW reference) | arXiv 2410.01442 (superscalar-CVA6); CVA6 docs |
| BOOMv2 (prior gen) | 3-wide OoO | 3.2 | 1.91 | (CARRV'20) | CARRV'20 Fig 7 + Table 1 |
| **Rocket** | 5-stage in-order, single-issue | **2.2** | **1.72** | (Chipyard reference) | CARRV'20 Fig 7; Chipyard/Rocket docs |

### What this table says (with the caveats forced in)

- **On CoreMark/MHz, rv64gc-v2 (6.96, GCC-13.4) is at the top of the open-source OoO
  band, nominally edging SonicBOOM's 6.2.** But the honest read is **"competitive /
  roughly co-leading, not decisively ahead"**: SonicBOOM's *best* published recipe is
  **6.89** (`-O2`, signed `ee_u32`, SFB on), which sits *on top of* our 6.96. The gap is
  inside the recipe noise (rule #2). Both cores are 4-wide OoO at ~6+ CM/MHz — this is the
  same performance class, and CoreMark is too small a benchmark to separate them.

- **On Dhrystone DMIPS/MHz, rv64gc-v2 (4.273) is nominally ahead of SonicBOOM (3.93)** —
  and this is the "DS 3.22 vs BOOM 3.93" reference in our memory *flipped in our favor*
  by the word-wide-strings rebuild (the 05-29 `-ww` Dhrystone lift; our internal
  pre-`ww` DS was ~3.22, now 4.273). **Caveat:** Dhrystone is a tiny, string-heavy
  benchmark dominated by `strcpy`/`strcmp`/`memcpy` codegen; the 3.93→4.273 delta is
  **partly the benchmark binary, not the µarch** (our own root-cause:
  `dhrystone_gap_rootcause` memory — DS is "the binary not the uarch"). It is a *fair*
  win only because we matched the word-wide-string methodology; it is **not** evidence of
  a 9% µarch IPC advantage over BOOM.

- **rv64gc-v2 sits comfortably above the in-order field** (CVA6 3.10 / Rocket 2.2 CM/MHz;
  CVA6 ~1.7 / Rocket 1.72 DMIPS/MHz). The OoO machinery is doing real work: ~2× Rocket
  and ~2.2× CVA6 on CoreMark, ~2.5× on Dhrystone.

- **Compiler-pinning matters here and we state it loudly.** Our 6.96 is on **czero-blind
  GCC-13.4**. We have *measured* that a GCC-14 rebuild lifts individual rows hard
  (rvb-multiply **1.21 → 3.37 IPC, +178%**, via a single branchless `czero.eqz`;
  `software_axis_3x`). We have **not** rebuilt CoreMark on GCC-14, so the 6.96 is a
  *conservative, understated* figure on the modern-compiler axis — the suite "understates
  ~2.8× on some rows" (per the campaign brief). If anything, a like-for-like GCC-14
  CoreMark rebuild would *widen* our lead over the GCC-11-published BOOM number — but we
  refuse to claim that until measured. **Stated honestly: our CM/DS lead over BOOM is
  real but thin and compiler-confounded; treat us as BOOM-co-class, not BOOM-beating.**

---

## 2. Microarchitectural positioning

Width / window / issue / pipeline / frequency / cache / vector. This is where the *class*
of each core is unambiguous, independent of benchmark recipe.

| Dimension | **rv64gc-v2 (ours)** | SonicBOOM | XiangShan Nanhu (Gen2) | XiangShan Kunminghu (Gen3) | CVA6 | Rocket |
|---|---|---|---|---|---|---|
| ISA | RV64GC (scalar) | RV64GC | RV64GC**BK** | RV64GC**BKHV** | RV64GC | RV64GC |
| Exec model | OoO | OoO | OoO | OoO | **in-order** (scoreboard) | **in-order** |
| Decode/rename width | **4** | **4-wide fetch / 8-wide issue** | superscalar (~4–6) | wider, ~6-class | 1 (single-issue) | 1 |
| ROB / window | **128** | 128 | large (undisclosed here) | larger | n/a (scoreboard) | n/a |
| Phys regs | INT 160 / FP 96 | INT 128 / FP 128 / pred 48 | — | — | n/a | n/a |
| Issue queues | 6 distributed IQs (INT 3×24, LSU 3×32) | INT/FP/MEM 32 each | distributed | distributed | scoreboard | — |
| Load/Store | 2 load AGUs, 1 STA, 1 STD; LQ/SQ via rename | 2 loads or 1 store/cyc; LQ 32 / SQ 32 | dual-issue LSU | wider LSU | 1-wide | 1-wide |
| Pipeline depth | **2-stage fetch**, short OoO pipe; ~12-cyc misp recovery class | 4-cyc decode, **12-cyc** misp penalty | deeper (freq-tuned) | deeper | 6-stage | 5-stage |
| Branch pred | TAGE-class + BTB 2048×8-way + RAS | **TAGE-L** + uBTB + RAS + SFB recoder | decoupled BP, TAGE/ITTAGE | advanced | simple | simple (BTB) |
| L1I / L1D | **32KB 8-way VIPT** / **64KB 4-way 2-bank** | 32KB 8-way / 32KB 8-way dual-port | larger, freq-tuned | larger | 16–32KB | 16KB |
| L2 / L3 | **2MB 8-way, 8-cyc** / none | 512KB 8-way / 4MB (sim) L3 | freq-tuned L2 + L3 + HW prefetch | CHI-mesh L2/L3 | — | — |
| Prefetch | NLPB next-line (**OFF under VM**) | next-line | hybrid prefetchers | hybrid prefetchers | — | — |
| **Vector (RVV)** | **none (scalar only)** | none ("future work") | none | **yes (RVV) + Hypervisor + RVA23** | none | none |
| Freq / node (silicon or target) | RTL/Verilator only (no synth freq published) | 1 GHz synth (FinFET); 3.2 GHz FireSim model | **2 GHz @ 14nm** (silicon, to 2.5 GHz) | **3 GHz**, advanced node | ~1.7 GHz @ 22nm (Ariane silicon) | ~1.5 GHz class |

### What this says

- **rv64gc-v2 is configurationally a near-twin of SonicBOOM:** both are **4-wide, 128-ROB,
  scalar RV64GC OoO** cores with TAGE-class prediction, ~32KB L1s, and a short OoO
  pipeline. We carry a **larger L2 (2MB 8-way vs BOOM's 512KB)** and a **larger L1D
  (64KB vs 32KB)**; BOOM carries a more aggressive **8-wide issue** and the **SFB
  short-forward-branch recoder** (worth up to 1.7× IPC on the affected code, and the
  single biggest contributor to its 6.2 vs 4.9 CoreMark/MHz). Net: **same class, different
  emphasis** — we spend area on caches, BOOM spends it on issue width and a predication
  recoder. This is the strongest single result in this document: *rv64gc-v2 is a
  BOOM-class core by construction, not just by benchmark.*

- **XiangShan is a generation (or two) above us in scope, not just tuning.** Nanhu/Kunminghu
  are wider, deeper, frequency-hardened (2–3 GHz silicon), have **L3 + hybrid HW
  prefetchers**, and — decisively — **Kunminghu has the Vector extension, Hypervisor, and
  the RVA23 profile**. We are scalar-only with no L3 and no published synthesis frequency.
  This is a *class* gap, enumerated in §4.

- **The in-order field (CVA6, Rocket) is structurally below us:** single-issue, no rename,
  no ROB. Our OoO window is doing exactly what it should.

---

## 3. The SPEC gap (honest: UNMEASURED on our side)

This is the section where the methodology discipline matters most, because it is the one
metric where **we have no number** and the competition does.

### What the field publishes (per-GHz, IPC-proxy)

| Core | SPECint2006 / GHz | SPECfp2006 / GHz | SPEC IPC | Source |
|---|---|---|---|---|
| XiangShan Yanqihu (Gen1) | **7.03** (silicon) | 7.00 | — | HPCA'25 slides p.15 |
| XiangShan Nanhu (Gen2) | **9.55** (19.10@2GHz, est. RTL sim) | 11.09 (22.18@2GHz) | — | HPCA'25 slides p.17 (GCC-10.2 `-O2`) |
| XiangShan Kunminghu (Gen3) | **15.0** (45@3GHz, est.) | — | ~1.5× Nanhu IPC | HPCA'25 slides p.20 (targets Neoverse N2) |
| SonicBOOM | — | — | **SPECint2006 IPC 0.86**; SPEC17 HARMEAN IPC **0.94** | CARRV'20 Table 1, Fig 6 |
| (ref) ARM Cortex-A76 | 9.90 /GHz | — | — | XiangShan slides p.13 |
| (ref) Apple M1 | 21.69 /GHz | — | — | XiangShan slides p.13 |

For scale, SonicBOOM's SPEC17 HARMEAN IPC of **0.94** is *competitive with AWS Graviton
(0.86)* and on some benchmarks (625.x264, 648.exchange2) matches Intel Skylake (CARRV'20
Fig 6) — though the authors correctly note ISA differences skew cross-ISA IPC.

### Where rv64gc-v2 would *plausibly* land — labeled inference, not measurement

We have two data anchors that bound a guess, and we state both with their confidence:

1. **Bare-metal IPC ceiling.** Our 42-row suite tops out at **IPC ~3.3** (sha/linear_alg),
   CoreMark iter10 at **2.185**, with a documented commit-width-utilization ceiling
   (`perf_scoreboard_2026-06-13.md`). These are *tiny resident working sets* — they are an
   **upper bound** on what SPEC (large footprint, branchy, memory-bound) would show. SPEC
   IPC is *always well below* CoreMark IPC on the same core (BOOM: CoreMark IPC ~2.5 region
   vs SPEC06 IPC 0.86).

2. **Real-kernel boot-IPC — our closest SPEC proxy.** Under a *real paged Linux kernel*
   (Sv48, real TLB/page-walk/cold-I-cache/D-miss traffic), rv64gc-v2 runs at
   **paged-S-mode IPC 1.40**, **overall boot IPC 1.58**, with the unpaged OpenSBI region at
   **2.64** (`doc/realkernel_profile_2026-06-14.md`). The paged kernel's D-cache miss rate
   (8–13%) and backend back-pressure (73% of fetch stalls) are the *same character* SPEC
   would exercise — a large, branchy, cache-stressing real workload. This 1.40–1.58 band is
   **the most SPEC-representative number we own.**

**Inference (UNMEASURED, low-confidence):** A core whose real-kernel IPC is ~1.4–1.6 and
whose CoreMark IPC (~2.2) tracks SonicBOOM's (~2.5) would **plausibly land in
SonicBOOM's SPEC neighborhood — i.e. SPEC06 IPC roughly 0.7–0.9, well below XiangShan
Nanhu/Kunminghu.** We are scalar-only with no L3 and no SPEC-tuned prefetchers, so the
realistic expectation is **at or slightly below BOOM on SPEC, not above it.** *This is a
hypothesis, not a result. We cannot rank ourselves on SPEC until a harness exists — this
is the single largest measurement gap in our campaign.*

---

## 4. Verdict — where rv64gc-v2 ranks in the open-source field

**rv64gc-v2 is a BOOM-class mid-to-upper-range open-source RISC-V OoO core: co-leading the
open-source CoreMark/MHz band, ahead on Dhrystone DMIPS/MHz (partly by benchmark), well
above the in-order field (CVA6/Rocket), and a clear generation below the XiangShan
flagship.** The campaign's expected positioning is **confirmed** by the data.

### Tier placement (open-source RISC-V, application class)

```
  XiangShan Kunminghu  ── SPEC ~15/GHz, RVV+H+RVA23, 3GHz        ← flagship, out of reach
  XiangShan Nanhu      ── SPEC ~9.55/GHz, 2GHz silicon, B+K      ← 1 gen above us
  ─────────────────────────────────────────────────────────────
  rv64gc-v2 (ours)     ── CM 6.96, DMIPS 4.27, boot-IPC 1.4–1.58  ┐
  SonicBOOM            ── CM 6.2, DMIPS 3.93, SPEC06 IPC 0.86     ┘ ← same class (co-lead)
  ─────────────────────────────────────────────────────────────
  XiangShan Yanqihu    ── CM 5.3, SPEC ~7/GHz (older OoO)
  NaxRiscv             ── CM 4.59
  ─────────────────────────────────────────────────────────────
  SiFive U74 / BOOMv2  ── CM 4.9 / 3.2 (in-order / older OoO)
  CVA6 (Ariane)        ── CM 3.10, in-order 6-stage
  Rocket               ── CM 2.2, in-order 5-stage
```

### Confirm / refute against the data

- **"Competitive-to-slightly-behind BOOM on CM/DS"** → **REFINED.** On *published nominal*
  numbers we are slightly *ahead* (CM 6.96 vs 6.2; DMIPS 4.27 vs 3.93). On *best-recipe /
  compiler-fair* numbers we are **co-class, inside the noise** (BOOM best CM 6.89; our DS
  lead is partly the `-ww` binary). Honest verdict: **co-leading BOOM, not beating it.**
- **"Well below XiangShan flagship"** → **CONFIRMED, decisively.** §4 gaps below.
- **"Well above CVA6/Rocket in-order"** → **CONFIRMED** (≈2–2.5× on every shared metric).

### The specific gaps that separate us from XiangShan

1. **Width & window.** XiangShan is wider (≈6 vs our 4 decode/rename) with larger ROB/IQ
   structures. *Note:* our own DSE measured 4-wide as IPC-optimal **for our suite** (6-wide
   ran worse per slot; `rv64gc_v2_uplift_roadmap` §intro) — but that conclusion is
   *benchmark-scoped to tiny resident loops*. On SPEC-class ILP, more width plausibly pays,
   and that is exactly what XiangShan's SPEC tuning exploits.
2. **Vector.** XiangShan Kunminghu has **RVV**; we are **scalar-only**. On any
   data-parallel SPEC component or real vector workload this is an uncloseable gap without
   a vector unit. BOOM lacks it too — so this separates *both* of us from Kunminghu.
3. **SPEC-tuning of the memory hierarchy.** XiangShan has **L3 + hybrid HW prefetchers**
   tuned against SPEC's large footprints. We have **no L3**, and our NLPB prefetcher is
   **hard-disabled under VM** (`ifu_line_fetch.sv:225`) — i.e. it does nothing precisely
   when the working set is largest. Our real-kernel D-miss rate (8–13%) is the symptom.
4. **Frequency / physical realization.** XiangShan is **2–3 GHz silicon** (14nm / advanced
   node). rv64gc-v2 has **no published synthesis frequency** — we are RTL/Verilator-validated
   only. Even at equal IPC, a core with no Fmax story is not in the same product tier. This
   is orthogonal to every per-MHz number above and must not be conflated with them.
5. **Profile / privilege scope.** Kunminghu supports **Hypervisor + RVA23**; we are GC +
   paged-Sv48 Linux (boot just reaching userspace). XiangShan is a server-class profile
   target; we are an embedded/application-class scalar core.

### Bottom line for the architect

rv64gc-v2 has **reached the SonicBOOM tier** — the canonical open-source RISC-V OoO
reference — on the metrics open cores actually publish, and **exceeded the in-order field
by a wide, unambiguous margin.** That is a genuine, defensible result. The honest framing
is **"co-class with BOOM, compiler-confounded, SPEC-unproven"** — not "fastest open OoO."
The roadmap to the *next* tier (XiangShan) is not tuning; it is **scope**: a vector unit, an
L3 + VM-aware prefetch, a SPEC harness to measure the gap honestly, and a synthesis
frequency story. Those are the four named levers that stand between us and the flagship —
and none of them is reachable inside the current scalar 4-wide envelope.

---

## Sources

**Internal (ours):**
- `doc/perf_scoreboard_2026-06-13.md` — 42-row promoted-config IPC suite, 3.x roster
- `doc/ipc3x_gate_results_2026-06-11.md` — DSim sign-off: CoreMark 6.96 CM/MHz @ iter10 (IPC 2.185), Dhrystone 13,501 cyc/100-iter, compliance 113/113
- `doc/stage5b_vipt_results_2026-06-04.md` — Dhrystone 4.2731 DMIPS/MHz
- `doc/release_candidate_signoff_2026-05-29.md` — Dhrystone 4.273 DMIPS/MHz (IPC 2.62)
- `doc/realkernel_profile_2026-06-14.md` — paged-Linux boot IPC: overall 1.58, paged 1.40, OpenSBI 2.64
- `doc/software_axis_3x_2026-06-14.md` — GCC-14 multiply 3.371 IPC (+178%); ±0.5–2.2 IPC/row compiler variance; GCC-13.4 czero-blind
- `doc/rv64gc_v2_uarch.md`, `doc/rv64gc_v2_uplift_roadmap_2026-06-13.md` — config (4-wide, 128-ROB, 160 INT / 96 FP PRF, L1I 32KB 8-way VIPT, L1D 64KB 4-way, L2 2MB 8-way, scalar-only)

**External (web):**
- Zhao et al., *SonicBOOM: The 3rd Generation Berkeley Out-of-Order Machine*, CARRV 2020 — https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf (config Fig 1; Table 1 DMIPS/MHz 3.93, SPEC06 IPC 0.86; Fig 6 SPEC17 IPC; Fig 7 CoreMark/MHz 6.2)
- Luffca, *Running CoreMark on SonicBOOM Simulator* (2022-04) — https://www.luffca.com/2022/04/benchmark-boom-simulator/ (MegaBoom CoreMark/MHz 5.49–6.89 by recipe, GCC-11.1; SFB impact)
- Luffca, *Benchmarks on RV64GC RISC-V OoO Simulator* (2022-07) — https://www.luffca.com/2022/07/benchmark-rv64gc-riscv-ooo-simulator/ (NaxRiscv CoreMark 4.59 / DMIPS 2.94, GCC-11.1)
- XiangShan team, *XiangShan: An Open-Source High-Performance RISC-V Processor*, HPCA'25 tutorial — https://tutorial.xiangshan.cc/hpca25/slides/20250302-HPCA25-1-Introduction-XiangShan.pdf (Yanqihu CM 5.3, SPEC06 7.03/GHz; Nanhu SPECint 19.10@2GHz / SPECfp 22.18@2GHz, GCC-10.2 -O2; Kunminghu 45@3GHz, RVV+H+RVA23)
- XiangShan repo / docs — https://github.com/OpenXiangShan/XiangShan , https://docs.xiangshan.cc
- *Using a Performance Model to Implement a Superscalar CVA6* — https://arxiv.org/pdf/2410.01442 (reference CVA6 CoreMark/MHz 3.10)
- CVA6 (OpenHW Group) — https://github.com/openhwgroup/cva6 , https://docs.openhwgroup.org/projects/cva6-user-manual/
- *The Cost of Application-Class Processing* (Ariane, 22nm FDSOI, 1.7GHz) — https://arxiv.org/pdf/1904.05442
- SiFive U74 Core Complex Manual (U74: 2.5 DMIPS/MHz, 4.9 CoreMark/MHz) — https://starfivetech.com/uploads/u74_core_complex_manual_21G1.pdf
- RISC-V International, *Understanding the Performance of Processor IP Cores* — https://riscv.org/blog/understanding-the-performance-of-processor-ip-cores/

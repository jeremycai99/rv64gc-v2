# Software-Axis 3.x-Maintenance Audit — rv64gc-v2 (2026-06-14)

**Zero-RTL software lever.** The cheapest per-row lever measured (production-compiler variance
±30–50% in cycles, `ipc3x_gate_results_2026-06-11.md` §4.3/§4.5). This audit closes the one
genuinely-open ISA-codegen datapoint flagged by the fresh-lever program
(`fresh_lever_program_2026-06-14.md` §2(b), D3 "GCC-14 czero audit" + D4 Zicond) and re-asks the
EXPANDER-vs-MAINTENANCE question with a modern GCC arm built this session.

**Provenance.** STATIC-FIRST (objdump/`-S` codegen audit before any sim). GCC-14.2.0 cross
(`gcc-14-riscv64-linux-gnu` + `cpp-14`, extracted to `/tmp/gcc14-tc` without sudo; cc1 emits asm,
Xilinx `as`/`ld` assemble+link — identical methodology to the clang-18 `-zc` arm). All sims on the
committed-default binary `verilator_bench_dupfix_on/Vtb_xsim` (cursor-fixes-ON = HEAD default), both
arms of every A/B through the SAME binary (self-consistent). ≤4 sims, `nice -n 10`, boot (pid
2196358) untouched and healthy throughout. czero asm artifacts `/tmp/czero_audit/`, ww disasm
`/tmp/ww_audit/`. Core extensions confirmed from `src/rtl/core/execute/alu.sv` (line 2 + opcodes):
**Zba/Zbb/Zbs/Zicond**, czero+zbb-min/max at 1 cyc; **NO Zbc/clmul, NO V** — so autovec and CLMUL
are correctly out of scope on this scalar core.

---

## HEADLINE

**The software axis is 3.x MAINTENANCE, not an EXPANDER — with exactly one clean crossing, now
proven GCC-native.** A modern compiler (GCC-14 / clang-18) moves the misp-hammock rows, but only
**rvb-multiply** crosses 2.95, and it does so on EITHER modern compiler: **GCC-14 multiply = 3.371
IPC** (gcc-13.4 baseline 1.209, **+178%**, branchless `czero.eqz` loop, misp 1,231→41). This
**upgrades** the §4.3 finding — multiply's crossing was attributed to "clang codegen"; GCC-14
reproduces it and lands HIGHER than clang (3.37 vs 2.37), so it is a **compiler-generic ISA-codegen
property, not a clang artifact**. Every other audited row is software-dead or sign-mixed: mont64
gcc-14 +13.7% (1.535→1.746) but nowhere near 2.95; median gcc-14 REGRESSES (−24% cyc, 1.313→1.052);
word-wide strings already shipped on all CoreMark-PRO/embench rows except dhrystone (DS the unique
beneficiary, already at +6.7% ww). **No new bare-metal roster member.** Methodology rider:
cross-core IPC comparisons MUST pin the compiler — a one-compiler bump is worth ±0.5–2.2 IPC/row,
larger than any RTL lever in five gap-closure cycles.

---

## 1. The czero / GCC-14 audit (D3) — STATIC FIRST

Does GCC-14.x emit czero where the suite's GCC-13.4 emits ZERO? **Yes, on multiply and mont64.**
Static `-march=rv64gc_zba_zbb_zbs_zicond -O2` codegen, czero-instruction count per kernel:

| row | GCC-13.4 (suite) | GCC-14.2 | clang-18 | min/max (zbb) |
|---|---|---|---|---|
| **multiply** | 0 | **1** | 1 | 0 |
| **aha-mont64** | 0 | **4** | 15 | 0 |
| median | 0 | 0 | 0 | 2 (both g13 & g14) |
| nsichneu | 0 | 0 | 0 | 0 |
| qsort (ctrl) | 0 | 0 | 0 | 0 |

GCC-13.4 emits **zero czero everywhere** (Zicond codegen landed in GCC-14 — confirmed). GCC-14 emits
czero on exactly the two branchless-convertible hammock rows. median is czero-DEAD on all three
compilers but **already has zbb `max` ×2 on both GCCs** (confirms §4.3 premise-error #1: "only
codegen missing" was false; median's binder is irreducible misp).

### 1.1 multiply — the crossing (sim-confirmed)

GCC-13.4 emits a **branchy** inner loop (`beq a5,zero,.L2` on the multiplier bit → 1,231 misp →
fetch-redirect bubbles). GCC-14 emits the **branchless** loop, identical shape to clang:

```
.L2:  bexti  a5,a4,0
      czero.eqz a5,a1,a5      # multiplicand if bit set, else 0
      addw   a0,a0,a5         # accumulate — NO inner branch
      sraiw  a4,a4,1 ; slliw a1,a1,1 ; bne a3,...,.L2
```

| arm | cycles | instret | misp(flush) | IPC | Δcyc vs g13 |
|---|---|---|---|---|---|
| gcc-13.4 (suite base) | 40,558 | 49,061 | 1,231 | **1.209** | — |
| **gcc-14** | 14,269 | 48,110 | **41** | **3.371** | **−64.8%** |
| clangnoz | 20,489 | 54,489 | 20 | 2.659 | −49.5% |
| clang-zc | 20,290 | 48,089 | 20 | 2.370 | −50.0% |

**GCC-14 wins outright (3.371):** it keeps instret nearly flat (49,061→48,110) AND collapses misp,
whereas clang bloats instret (54,489 noz / 48,089 zc). The czero is on a per-iteration independent
slot (not loop-carried — `a0` accumulation is the only carry, a 1-cyc add), so unlike mont64 the
branchless form does NOT lengthen the critical chain. This is the **single clean software-only roster
crossing**, and it is now GCC-native.

### 1.2 mont64 — moves but stays in the misp-asymptote band

GCC-14's 4 czero hit the modul64 hammock (`bexti…czero.eqz…sub`), the same site as clang's (clang
emits 15 — a more aggressive conversion).

| arm | cycles | instret | misp(flush) | IPC |
|---|---|---|---|---|
| gcc-13.4 (base) | 1,395,813 | 2,143,590 | 78,973 | 1.535 |
| **gcc-14** | 1,225,275 | 2,139,822 | 62,312 | **1.746** (**−12.2% cyc**) |
| clangnoz | 1,594,147 | 2,854,526 | — | 1.790 |
| clang-zc | 1,355,470 | 2,671,469 | — | 1.970 |

GCC-14 is the **honest GCC-vs-GCC czero win: −12.2% cycles / +0.21 IPC** with instret essentially
flat (2.1436M→2.1398M), misp −21%. This is materially better than §4.3's clang honest figure
(−2.2%) precisely BECAUSE GCC-14's 4-czero is restrained — it does not pay clang's +24.6% instret /
chain-lengthening tax. clang-zc reaches the highest IPC (1.970) but via instret bloat. **None crosses
2.95** — mont64 stays in the misp-asymptote band (43% cyc misp + modul64 carried chain). czero
helps; it does not promote.

### 1.3 median — software-DEAD, GCC-14 REGRESSES it

| arm | cycles | instret | IPC |
|---|---|---|---|
| gcc-13.4 (base) | 7,985 | 10,490 | **1.313** |
| gcc-14 | 9,986 | 10,507 | **1.052** (−24% cyc) |
| clang(=zc) | 10,786 | 10,942 | 1.014 |

Both GCCs already emit zbb `max` ×2; no czero on any compiler. GCC-14 restructures into a branchier
form (same direction as clang's +35% regression in §4.3). **A newer compiler is NOT uniformly
better** — median is the counter-example. Binder = irreducible loop-exit misp.

---

## 2. Word-wide string idioms — DS is the UNIQUE beneficiary

Static scan of all 42 baremetal ELFs for out-of-line byte-serial string functions (objdump,
lbu-loop vs ld-loop):

- **The CoreMark-PRO suite + embench/rvb rows ALREADY link word-wide newlib strings.** parser, cjpeg,
  linear_alg, nnet, zip, sha, radix2, loops, md5sum, qrduino, wikisort, stream-*, rvb-mm: every one
  shows `strcpy(lbu8/ld2)`, `strcmp(lbu2/ld7)`, `strlen(lbu8/ld1)`, `memcpy(lbu5/ld12)` — the SWAR
  word-at-a-time newlib variants (the `ld` loops are the body; `lbu` only in head/tail alignment).
- **dhrystone is the ONLY purely byte-serial row:** baseline `strcpy(lbu1/ld0)`, `strcmp(lbu5/ld0)`,
  `memcpy(lbu1/ld0)` — no `ld`, strictly `lbu…sb…bnez`. The committed `dhrystone-ww.elf` upgrades to
  SWAR (`strcpy(lbu4/ld2)`, `strcmp(lbu7/ld4)`; the `0x0101…/0xfeff…` zero-byte-detect magic + 8-byte
  `ld`). **Already measured/committed: DS 2.614 → DS-ww 2.789 (+6.7%).**

**parser is NOT a word-wide string-library target.** Its binder is the byte-at-a-time `strcspn`
scan (newlib's reject-bitmap variant, 179 insns, but the per-input-char probe is `lbu a4,0(a0);
beq a4,…` by algorithm necessity — the `ld`/`sd` are stack-bitmap clears, not the scan). A
*library* swap cannot help; parser needs an algorithmic SIMD-within-register charset-match rewrite,
out of scope for a binary-normalization lever. The parser +57.5% datapoint (§4.6) is the **lat-2
memory-latency** arm — a separate axis (cache), not word-wide strings.

**Verdict: word-wide is MAINTENANCE on exactly one row (DS, already shipped). Every other
string-touching row already has it. No new crossing.**

---

## 3. -flto cross-TU probe — NULL (load-bearing)

The compute/GEMM nests are **single-TU at -O2**, so `-flto` (whose only delta over -O2 is cross-TU
inlining) has nothing to inline:

- embench matmult-int / nbody / st = **1 TU each**. matmult-int (1.927) is already adjudicated
  fetch-fragmentation + store-commit-wait (single-TU; -flto inert).
- linear_alg / loops (CoreMark-PRO) are multi-TU in the suite but the bare-metal kernel-direct build
  is a self-contained kernel TU. **linear_alg is already the TOP roster member (3.317@cap) and
  already FMA-fused (64 `fmadd` in the binary).** No -flto headroom at the cap.

The compute band is scalar-capped at the ceiling (`fresh_lever_program` §1); -flto buys nothing
here. The null result is load-bearing: it removes -flto from the maintenance toolbox and reinforces
that dense-compute expansion needs **vector** (a different product/KPI), not a compiler flag.

---

## 4. The compiler-variance map (per-row best compiler, zero RTL)

Best-IPC-per-row across the 4 arms, all on the committed-default binary. **Bold = crosses 2.95.**

| row | gcc-13.4 (suite) | gcc-14 | clang-noz | clang-zc | best | crosses 2.95? |
|---|---|---|---|---|---|---|
| rvb-multiply | 1.209 | **3.371** | 2.659 | 2.370 | **gcc-14 3.371** | **YES — the one crossing** |
| aha-mont64 | 1.535 | 1.746 | 1.790 | 1.970 | clang-zc 1.970 | no (misp asymptote) |
| rvb-median | 1.313 | 1.052 | — | 1.014 | gcc-13.4 1.313 | no (sw-dead; newer = worse) |
| nsichneu (ctrl) | 1.890 | 2.094 | 2.117 | — | clang-noz 2.117 | no |

nsichneu control: gcc-14 2.094 (+10.8% vs gcc-13) and clang-noz 2.117 both beat the suite baseline,
but via OPPOSITE instret moves — gcc-14 BLOATS instret (2.246M→2.558M, yet fewer cycles) while
clang SHRINKS it (→2.010M, the §4.3 "24%-smaller kernel"). Same IPC ballpark, different codegen;
neither crosses 2.95. This is the §4.3 control confound made concrete: IPC alone hides that the two
compilers reach ~2.1 by different routes.

**Direction is SIGN-MIXED** (multiply +178% gcc-14, median −20% gcc-14): a suite-wide compiler swap
is NOT a recommendation; it is a per-row tool. The ±30–50%/row variance from §4.3 is reconfirmed and
extended with a GCC-14 arm.

---

## 5. Verdict + methodology note

**EXPANDER vs MAINTENANCE: MAINTENANCE.** The software axis adds **zero new bare-metal roster
members**. The 3.x roster stays at 8.

- The **one** clean software-only crossing is **rvb-multiply**, and the new fact is that it is
  **compiler-generic** (GCC-14 3.371 ≥ clang 2.37), not a clang property — D3 closed, D4 (Zicond)
  hardened REFUTED-as-expander (czero moves misp rows, never the chain band; mont64 gcc-14 +13.7%
  caps at 1.746). czero is a correct, cheap, 1-cyc ISA feature the core already executes; it is a
  **maintenance** tool (multiply health, mont64 −12%), folded under Tier-0b binary normalization.
- **Word-wide strings: already shipped everywhere except DS** (CoreMark-PRO/embench link SWAR
  newlib). DS-ww +6.7% is the only delta and is committed. parser is an algorithmic/cache problem,
  not a string-library swap.
- **-flto: null** (single-TU kernels; top compute row already FMA-capped).

**Methodology rider (binds all cross-core claims):** one production-compiler version is worth
±0.5–2.2 IPC on a single row (multiply 1.21↔3.37) — larger than every RTL lever measured across five
gap-closure cycles. Any rv64gc-v2-vs-BOOM / -vs-industry IPC comparison MUST pin the compiler
(version + flags + march), or the result is dominated by codegen, not microarchitecture. The suite's
GCC-13.4 is czero-blind; reporting "multiply 1.21" understates the core by ~2.8× vs what a GCC-14
binary measures on the SAME RTL.

**Recommended (zero-RTL maintenance, not roster math):** (1) regenerate the multiply suite binary
with GCC-14 (or clang) for an honest single-row health number — it is a measurement artifact, not a
core change; (2) keep DS-ww as the DS binary; (3) drop -flto and Zicond-as-expander from the lever
list. No RTL action. The expansion budget stays on Lever A (D-prefetch) / Lever B (TAGE entropy) /
the funded FP campaign per the fresh-lever program.

**Artifacts:** GCC-14 binaries `tests/{riscv-bench,embench}/baremetal/*-g14.elf`, hexes
`tests/hex/*-g14.hex` (multiply, mont64, median, nsichneu) — uncommitted; batch with the next
sign-off. Toolchain `/tmp/gcc14-tc` (GCC-14.2 cross, no sudo). czero asm `/tmp/czero_audit/`,
ww disasm `/tmp/ww_audit/`.

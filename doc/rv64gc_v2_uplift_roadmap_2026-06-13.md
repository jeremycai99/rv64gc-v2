# rv64gc-v2 POR Uplift Roadmap (2026-06-13)

**This is one design — the rv64gc-v2 plan of record.** There is no "gen-1/gen-2" split;
the items below are all rv64gc-v2 POR work, sequenced by readiness and risk, not by
generation. Bigger/later items (UOC-repack) are still this POR — just gated behind their
measurements and the smaller wins.

**Architect's constraints:** decode/rename stay 4-wide; ports stay shared (BR0/MUL split
is out of this POR — see §5). Everything else open where contention is *measured*.
Inputs: the fetch-supply study + the 3-study backend workflow (port census, memory
pipeline, dispatch/issue topology) + the uop-cache vs 2-block decision, all read-only vs
the promoted-config 42-row suite (`log/piece2_runs/suite_on/`) and RTL at HEAD. Baselines:
`doc/perf_scoreboard_2026-06-13.md`, `doc/ipc3x_gate_results_2026-06-11.md`.

**Why 4-wide decode/rename is right:** max suite IPC 3.32; execute 0.16 cyc/uop average;
rob_full ≤1.59%; 6-wide ran worse per slot. The machine is not width-limited — it is
fetch-*supply*-limited on one band, port-*protocol*-limited (FP cadence) on another, and
program-limited (misp entropy, chains) on the rest.

---

## 1. The roadmap (sequenced by readiness)

| phase | item | rows moved | cost | status |
|---|---|---|---|---|
| **0** | F3 unified counter batch (gate factory: fpu_b2b_lost, alu3_starved, mul/div-hold, slot-2 would-fire, hsST cross-product + depth histogram, cw4-with-5th-ready, DQ/dispatch-cap, int-FIFO HOL, eligible_avg overflow fix; + `bru_wb_displaced_alu`/`mul_cdb2_deferred` for the deferred BR0/MUL study) | none directly — funds/kills the gated items, closes dispatch/commit width | ~50 sim-only lines | ride next sign-off commit |
| **1** | **F1: FP true-1.0 cadence** — FP-aware `fpu_out_valid`/div suppress (FP-after-FP collision-free on CDB[3], RTL-verified) | **MEASURED (gated `FPU_PIPELINED_ISSUE_ENABLE`, off-default): nnet 2.133→2.650 (+24%, does NOT reach 2.95 — binder shifts to FP-operand-latency), stream-l1 2.257→2.405, stream-l2 2.322→2.487 (fill is its other half), loops →2.356, st/minver/cubic/radix2/nbody +2–17%.** No roster crossing F1-alone; fu_contention→~0 on every FP row. | ~20 lines `core_top:2409-2439` | **DONE, PROMOTE-READY (geomean lever, not roster)** — 113/113 compliance, bit-exact OFF, ≤0.01% non-FP. nnet UB needs F1+**G1(FP-WB)+operand**. |
| **1** | **F2: store-commit harvest A1** — STA/STD sideband into ROB head ready-bypass | 1-cyc term on matmult 21.3% / tarfind 10.6% / md5sum 9.3% / ud+loops 7.4% / nnet 6.4% head-store stalls | 2–10 lines `rob.sv:817-827` | **FUNDED** (§4.5.6 gate passed) |
| **2** | G1 FP-dest WB→`fp_prf wr[3]` · G2 harvest A2 (commit-time PRF data read) · G3 ROB slot-2 bypass | residual un-starve · full hsST tail (matmult→~2.06, tarfind→~2.28) · +0.1–0.5% on 6 roster rows | 100–200 / 80–150 / 2 lines | **GATED** — read free from the F1/F2 arms + F3 counters |
| **3** | G4 LMB port-1 drain · G5 multi-outstanding L1D fills — decided jointly with the cache decision | 1–3% linalg/stream-l2/zip · rsort +18.5% cyc @L=80, parser service-latency, stream-l2 −19.1% | 30–60 / 100–250 lines (G5 HIGH-interaction, NWA precedent) | **GATED on L=80 sweep rows** (cache sweep landing) |
| **4** | **Supply lever = UOP-CACHE-REPACK** — fill-time dense-trace packing across taken edges + line boundaries; existing UOC RTL (740L) revived (invert 5 as-built behaviors). *Realizes UB×hit-rate — sidesteps the emit-repacker's donor-unrequested kill (dense trace resident from a prior loop pass).* **OFF the F1 cone; RAM shrinks 82-91KB→~18-25KB.** | **MEASURED (gate PASSED): rsort 3.141→3.467 (HR 100%), DS-ww 2.789→3.598 (new roster), DS 2.614→3.135 (new roster), statemate 2.973→3.358 (HR 79.5%, set-conflict 7.69/8); crc32 HOLDS (chain-capped, 0 gain); CM DEAD 2.648** | FILL DONE; replay = bigger | **PARTIAL (RTL build 2026-06-14): fill side BUILT+TB-PROVEN, gain UNREALIZABLE without the on-cone replay refactor.** Fill accumulator (#1/#5, dense pack-through-taken), satp/SFENCE invalidation (#6, latent-bug fix), rebuilt tb_uop_cache 14/14 — all done, ENABLE=0 bit-exact, lint 15. BUT ENABLE=1 A/B REGRESSES (rsort −28%, misp inflates statemate +99%) because the dense entries are refused by the safe replay policy (zero supply realized) while the as-built frontend-hold/flush perturbs BP. **COST CORRECTION: the realizable gain (#2 live-TAGE / #3 serve-control / #4 FTQ-bypass replay) requires repositioning the UOC into the frontend (fetch_top/ifu/bpu/FTQ) = the 600–1000-L "Reference-Core-B-class" refactor, ON the frozen F1 cone** — NOT the off-cone 430–600 L the gate estimated. The fill+invalidation+TB are a correct foundation to resume from. |

**Parallel tracks (also rv64gc-v2 POR):**
- **M2 spill-policy — REFUTED (2026-06-13, `doc/m2_spill_policy_campaign_2026-06-13.md`).** No static RTL scope separates ud (corrector adequately-trained → spill HURTS, +0.86%) from minver (under-trained → spill helps, −9%); they're identical batch geometry differing only in runtime predictor state. On the COMMITTED tree (matched baseline) every scope makes ud worse — the "fixes ud" premise was vs the pre-cursor baseline. ud +2.37%/minver +1.44% residuals **stay documented-and-accepted**; tree at default (SPILL=0). nsichneu's "+1.47%" was a baseline artifact (matched A/B = flat) — and it's the **control that drops M2-spill from the UOC prerequisite chain** (below).
- **Cache sizing — FINAL (sweep complete, 12/12 arms): 512K L2 / 64K L1D / 5-cyc hit.** Real-app geomean **−1.28%** (net faster), 576 KB cache RAM (−73% vs 2112). 1M-64k-lat6 is a dead heat on perf (−1.25%, 1088 KB) → the conservative fallback (worst-member zip +1.1% vs 512K's sha +4.6%, a roster member 3.31→3.17). 64K is the L1D floor (128K bit-identical=waste; 32K cliffs linalg +16%). **Load-bearing = the 5-cyc-on-512K-macro synth/STA close** (modeled latency). Full: `doc/cache_sizing_results_2026-06-13.md`.
- **Software axis** — chain band (~6 rows) + multiply (clang 2.37 measured) + parser ww strings: ±30–50% per row, the largest per-row lever, zero RTL. Methodology decision.

**The 2-block-fetch program is KILLED** (uop-cache study wf_3081983c): double-width-sequential leaves the dominant taken-edge truncation on the table (taken = 29–77% of partial-emit causes); full-2-block is highest cost/risk and lands ON the frozen F1 cone. UOC-repack captures it off-cone, reuses 740 lines, costs negative area.

## 2. Measured-dead (do not revisit without new data)

6/8-wide dispatch (stall_dq ≤0.06%; LQ/SQ/ROB alloc at rename ⇒ backlog can't exist) ·
wider commit (cw5+ = 0 by hardware) · 2nd FP pipe / dual-IQ2-select (post-fix worst demand
0.69 uop/cyc; dual-select = orphaned-entry correctness bug) · CDB 4→5/6 (+504 comparators
for zero queueing; loads off-CDB) · integer select widening (arb-loss maxima are FP rows
or roster-at-ceiling) · 2nd STA AGU / 3rd load port (AGUs already fully dedicated) · dual
store-commit pipe (knife-edge dissolved post-NWA: 0.772 vs 0.820) · multi-outstanding fills
*at L=1* (tarfind −0.005%; revival is an L=80 play) · same-line fetch-through-taken
standalone · the full standing-refutation ledger.

## 3. Projected scoreboard (rv64gc-v2 POR, all phases)

**Roster: 8 today → 8 (F1-alone, MEASURED — no crossing; nnet 2.65) → 10 (UOC-repack adds
DS 3.135 + DS-ww 3.598, MEASURED) → 11–12 (if the full FP stack F1+G1+operand mints nnet
and stream-l2+fill crosses — both now UNPROVEN, binder = FP-operand-latency).** F1 is a
geomean lever (+1.8–24% on 9 FP rows), not a roster lever on its own — the §3/§6.5
"F1 mints nnet" projection is REFUTED at F1-alone scope. The solid measured roster gain is
the UOC-repack (+2). Suite geomean: F1 FP-rows + store + UOC supply, concentrated.

Certified unmoved, by measurement: the ~10-row misp-asymptote band (wrong-path fetch;
budget = M2 spill), the ~6-row chain band (software only), CM (UB 2.93, permanently below
2.95), parser (cache + ww binary), memcpy (LSU; G5 candidate @L=80).

## 4. Risks carried forward

1. **BP-perturbation precedent**: the cursor fixes produced M1/M2; fuller UOC delivery
   worsens M2's one-update-per-commit-batch starvation — M2-spill is sequenced as a
   prerequisite, not an option.
2. **UOC correctness contract** (the 2026-05-05 rejection's lesson): cede next-PC to FTQ,
   live TAGE per replayed group (not stored), serve control/partial, FTQ-bypass (no
   frontend-hold / no per-exit flush), **add satp/SFENCE.VMA invalidation** (FENCE.I-only
   today = latent paged bug), rebuilt unit TB. Non-negotiable checklist before any A/B.
3. **G5 × NWA interaction** (L2F-comb +11.2% stream-l2 precedent): mandatory stream-l2
   re-sign @L=1 AND L=80 + `+WEDGE_DUMP` boot on any fill-engine change.
4. FP correctness history (21842ac): full RV64F/D compliance on every F1/G1 arm.
5. Standard ladder on all arms: lint-15, ENABLE=0 bit-exact, strict-mode checkers, CM/DS
   at STOP, ≤0.01% suite invariant (waivers documented).

## 5. Deferred — needs a dedicated study (OUT of this POR)

**BR0 / MUL port un-sharing.** Measured ≈0% incremental IPC even under the UOC
(`doc/br0_mul_unshare_under_uoc_2026-06-13.md`): branch-resolve demand scales only to
0.17–0.67/cyc vs the 2/cyc 2-BRU cap (DS-ww worst, 66% idle); MUL head-stall literally 0
on all UOC beneficiaries. The projection rests on CDB-conflict counters that don't exist
yet (`bru_wb_displaced_alu`, `mul_cdb2_deferred` — folded into the F3 batch for a future
direct read). **Not split in this POR;** reconsider only as its own study if those
counters go non-trivial on a beneficiary row after the UOC-repack lands.

Source studies: fetch (task a84c8045), backend (wf_e2ce6bc4), uop-cache (wf_3081983c),
BR0/MUL (task a7f73e11). Supersedes `doc/arch_refactor_plan_gen2_2026-06-13.md`.


---

# §6. DSE Integration — Architect's 4 Decisions Adjudicated (2026-06-12)

*Appends to `doc/rv64gc_v2_uplift_roadmap_2026-06-13.md`. Constraint frame held: decode/rename 4-wide, ports shared, ONE POR (no gen split). Four DSE explorations closed against the promoted 42-row suite. Net: ZERO new band-wide RTL levers fund; one single-workload play DEFERS behind two gates; one ISA-codegen lever (Zicond/GCC-14) is the only genuinely-open static datapoint. All four decisions are CONSISTENT with the existing POR — they HARDEN it with the scaled/per-PC numbers the §4 gates and §3 certifications called for.*

---

## 6.1 Per-decision status + the OPEN-part next experiment

| # | Decision (as the architect framed it) | Verdict | Deciding number | Slots into POR as |
|---|---|---|---|---|
| **D1** | Frontend: inline decoded-op repacker + fetch-ahead + dual-line as a **band-wide** supply lever | **partially-measured-dead → DEFER (single-workload)** | UOC-HR on nsichneu = **4.7%** MEASURED (WS 1503 vs 256-cap = 5.9× over); coverage-delta = **{nsichneu} only** | §4 UOC-repack gate gets its first two measured rows; nsichneu carved out behind a 2-gate sub-track |
| **D2** | Backend width > decode width (dispatch 6/8, 8-class issue, wider commit, decode-cracking, per-pipe-IQ) | **MEASURED-DEAD (4 of 5 parts) + GATE-behind-F1 (FP-IQ-split only)** | cw5=cw6=**0 on 42/42**; max post-UOC scaled IPC **3.55 < 4.0** commit cap; misalign+cross-line=**0 on 42/42**; IQ2 issues **0.28–0.44/cyc** << 1.0 | §2 measured-dead ledger absorbs 4 parts with scaled numbers; FP-IQ-split → new gate **G-IQ2** downstream of F1 |
| **D3** | Misp entropy: SW if-conversion FIRST, HW short-diamond predication | **SW partial-dead + HW DEFER (target-dependent)** | HW-only incremental misp = **~94k of 583k (~16%)**, 2 rows (qrduino/huffbench); carried-chain derate caps even success at **−2.2%** (mont64) | §3 misp-asymptote certification hardened; SW arm folds into software axis; HW-pred OUT of POR (target-gated) |
| **D4** | Dep-chains: ISA/dataflow shortening; **headline crc32-via-clmul** | **headline REFUTED + Zbc DEFER + premise CONFIRMED** | crc32 binder = **PRNG seed-recurrence ~10cyc** (not CRC table); clmul touches off-critical sub-chain → UB **~0** | §3 chain-band certification hardened; Zicond/GCC-14 = the one OPEN ISA-codegen lever → software axis |

### The OPEN parts only (concrete experiment / gate / cost)

**D1-OPEN → `G-NSI` sub-track (DEFER, two gates, behind FP+store):**
- **Gate 1 (FP-FIRST, cost 0):** Read the F1 nnet row. If nnet crosses 2.95 (UB 3.15–3.59), the +1 roster slot is bought off-cone for ~10–30 lines → **KILL/indefinitely-defer** the on-cone nsichneu rebuild. nsichneu and nnet compete for the *same single roster slot*; FP wins on cost/risk (off-cone vs frozen-F1-cone Reference-Core-B-class refactor).
- **Gate 2 (only if nsichneu becomes a shipping requirement):** Pre-RTL, extend `tools/uoc_repack_model.py` with a **2-deep demand-runahead + dual-line dense-delivery** mode against the captured nsichneu trace (`/tmp/uocgate/nsichneu_uoctrace.log`). FUND RTL only if projected nsichneu ≥ 2.95 **AND** the F1-port/dual-line synth cone stays off the ifu runahead-pending critical path. **Default verdict: KILL on cone-cost** — it re-opens the §4.2b single-F1-port (`ifu.sv:113` MAX_DEMAND_RUNAHEAD=1, demand_alloc first-fail 152,670) AND the KILLED dual-line I$ banking (packet_empty_f2_data 138,268), both on the frozen cone. **Cost: ~0 model extension; RTL = HIGH (frozen cone).**

**D2-OPEN → `G-IQ2` (FP-IQ-split, GATED behind F1):**
- **Sequence:** Run F1 (FPU_PIPELINED_ISSUE_ENABLE=1, already FUNDED) FIRST. Then add a **~3-line sim-only counter** `iq2_fp_and_other_coready/cyc` (cycles where an FP op AND a ready ALU3/DIV/CSR both want IQ2 port-0) + read residual IQ2 arb-loss. **FUND the split ONLY IF** post-F1 residual arb-loss ≥ ~15% **AND** co-ready ≥ ~10% on ≥2 FP rows with a bar-crossing UB. **KILL** (expected) if the post-F1 residual collapses to the FP∩other term — then F1 alone owns the FP cluster and the split is dead silicon. **Cost: +3 counter lines folded into the F3 batch; split itself ~100–200 lines IF gate passes (do not write pre-gate). Honest prior: ≤+1–3% incremental, sub-roster-crossing → KILL.**

**D3-OPEN → `G-SW` (the one open SW datapoint) + `G-HWP-SCOPE` (deferred):**
- **G-SW (cheap, static-first):** 3-arm objdump czero/min-max count on the pure-hammock rows (median/mont64/multiply), extending §4.3 to the **untested GCC-14 arm**. FUND software-normalization for a row only if a production compiler emits the conversion **AND** honest net cycles improve >5% with controls (qsort/nsichneu) <2%. KILL the row's SW path if both compilers refuse (median — clang already refused, GCC13.4 at zbb-max) OR carried-chain derate keeps it <5% (mont64 −2.2%). **Cost: 0 sims for the objdump; ~5 short nice'd A/B runs only if GCC-14 emits new czero.**
- **G-HWP-SCOPE (deferred, target-gated):** ~20-line sim-only predicated-store eligibility census on qrduino/huffbench (classify each mispredicting cond PC's then/else as pure-ALU-select / contains-store / fault-risk / multi-block). **FUND the HW-predication design study ONLY when a deployment target adds a qsort/median/data-random-branch workload requiring >2.0 AND the census shows store-bearing-hammock ≥ ~40% of misp AND ≥ ~25% of cycles.** No suite row meets all four. **Cost: ~20 lines on the next +PERF_PROFILE pass.**

**D4-OPEN → `G-CRC` (confirmatory KILL) + Zicond=G-SW (above):**
- **G-CRC (cheapest confirmatory):** `tools/uoplife_critical_path.py` on the existing crc32 trace to nail the PRNG-vs-CRC chain split. KILL clmul the moment it shows the CRC table sub-chain is <40% of the carried-chain length (predicted <20%). **Cost: ~0, one nice'd analysis run, no build.**
- **Zbc clmul RTL = E3 (DEFER, precondition-gated):** DO-NOT-FUND until a chain-band row is *demonstrated* (E1-class readout on a representative binary) to have the polynomial-multiply ON its carried critical chain. Build a clmul-using microbench first (codegen, free), measure its standalone chain length. embench-crc32 is the wrong binary (PRNG-bound). **RTL ~30–60 lines (CLMUL/CLMULH/CLMULR combinational, fit the 1-cyc ALU) — cheap IF ever justified.**

---

## 6.2 Where each surviving experiment slots into the POR (by priority)

The four decisions add **no new phase** — every survivor rides an existing funded arm or a sim-only counter pass. Updated sequencing:

| POR slot | DSE survivors that ride it | net new cost |
|---|---|---|
| **Phase 0 — F3 counter batch** | D2 `iq2_fp_and_other_coready` (+3 lines); D3 `G-HWP-SCOPE` census (~20 lines, deferred-arm, only if a target appears) | +3 lines now; +20 lines deferred |
| **Phase 1 — F1 (FUNDED)** | D1-Gate1 (read nnet row, cost 0); D2 `G-IQ2` reads out *after* F1 lands | 0 |
| **Phase 1 — F2 (FUNDED)** | D1 nsichneu sits behind FP+store (this is the "FP/store first" sequencing) | 0 |
| **Software axis (parallel track)** | D3 `G-SW` GCC-14 czero audit; D4 Zicond=GCC-14 (same toolchain bump — **one rebuild serves both D3 and D4**); D4 clmul microbench codegen | 0 RTL; 1 toolchain rebuild (shared) |
| **Phase 4 — UOC-repack gate (IN FLIGHT)** | D1 delivered the gate's first two measured rows: **nsichneu 4.7% (thrash) / rsort 100% (fit)** via `tools/uoc_repack_model.py` — these seed the not-yet-written `doc/uoc_repack_gate_2026-06-13.md` | 0 (done) |
| **§2 measured-dead ledger** | D2 width parts (dispatch/commit/issue/cracking) with **scaled numbers attached**; D4 crc32-clmul-on-existing-suite | 0 (documentation) |
| **§5 deferred / OUT of POR** | D1 nsichneu inline+fetch-ahead (own 2-gate sub-track); D3 HW-predication (target-dependent); D4 Zbc clmul RTL (precondition-gated) | 0 until gated-in |

**Priority verdict:** nothing the architect proposed jumps ahead of F1/F2. The single genuinely-open *cheap* play is the **shared GCC-14 toolchain bump** (serves D3-median/mont64/multiply AND D4-Zicond AND seeds D4-clmul-microbench), and it is a **static czero-emission audit first** (free) before any sim. The single genuinely-open *RTL* play (D2 FP-IQ-split) is strictly downstream of F1 and expected to KILL at its post-F1 gate.

---

## 6.3 Architect's intuition vs the measurement (per decision)

**D1 — Frontend supply: intuition RIGHT in kind, WRONG in scope.** The architect's instinct that a fetch-supply lever exists is correct — but the **UOC-repack already funded in §4 captures the entire supply band** (rsort 100%-HR→3.47 MEASURED; statemate/DS/DS-ww fit). The inline+fetch-ahead+dual-line stack's *only* coverage-delta over the funded UOC is **{nsichneu} + cold/non-resident code** (and the bare suite has ~0 cold code). nsichneu genuinely thrashes the UOC (4.7% HR, body 4472 insns >> 1024-uop capacity), so the architect is right that *only* inline+fetch-ahead can reach its UB — but lifting that ONE row (+1.1 to +1.5 IPC) costs re-opening two already-KILLED programs on the frozen F1 cone, while the **already-funded FP arm mints the same +1 roster slot (nnet) off-cone for ~10–30 lines.** **The GOAL (frontend supply) is served — by the UOC-repack band-wide and by FP for the marginal roster slot — so the inline path is correctly band-dead, single-workload-deferred.**

**D2 — Backend width: intuition WRONG on mechanism, but the GOAL was already maxed.** The architect proposed widening dispatch/commit/issue past decode width. The measurement says this **cannot help by hardware fact**: LQ/SQ/ROB indices allocate at RENAME (capped PIPE_WIDTH=4), so a wider dispatch read-port has no supply; cw5=cw6=0 on 42/42 because rename caps in-flight uops; max post-UOC scaled IPC (DS-ww 3.55) sits below the 4/cyc commit cap; misalign+cross-line=0 kills decode-cracking (RV64GC byte-merges unaligned stores natively, AMO is already 1 uop, no CISC to crack). **The "backend wider than decode" goal is moot — the 4-wide machine is not width-limited at any post-UOC operating point.** The ONLY real sharing contention (IQ2 arb-loss 30–92%) is FP-exclusive and is the **F1 FP-cadence suppress masquerading as a port deficit** (IQ2 issues 0.28–0.44/cyc << 1.0). So the architect's "per-pipe-IQ instead of 3-shared" is right *only for the FP slice and only downstream of F1* — and even then the incremental over F1 is a co-ready residual (likely sub-roster-crossing). **Width: dead. FP-IQ-split: F1's residual, gated.**

**D3 — Misp entropy: intuition RIGHT to put SW first, but SW is partial-dead where it matters, and HW is target-dependent.** The architect's "software-if-conversion FIRST, HW-predication only if the target requires it" is the correct ordering and is *confirmed*. The new per-PC data HARDENS the DEFER: the pure-hammock rows (median 99%, mont64 99%, multiply 92%) are SW territory where the win is **compiler-refused** (median — both GCC13.4-at-zbb-max and clang refuse) or **carried-chain-derate-capped** (mont64 czero lengthens the loop-carried chain 3→6 ops → honest −2.2%). The genuinely-HW-only fraction (predicated-store rows qrduino 55% / huffbench-body 20%) is real but **~94k of 583k band misp (~16%), concentrated in 2 rows**, each also carrying large irreducible loop-exit fractions that cap them at the 1.6–2.0 asymptote — **no predication path produces a 2.95 member.** HW predication is a from-scratch major semantic addition (predicate bits + predicated-WB + store-kill + exception-mask + ROB-recovery) at FP-compliance-class blast radius (the M1/M2 + FP-bypass precedent). **The GOAL (cut misp-bound cycles) stays where the scoreboard puts it: M2-spill on misp COUNT, not penalty/predication machinery. HW-pred OUT of POR, target-gated.**

**D4 — Dep-chains: premise CONFIRMED-CORRECT, headline REFUTED on the specimen.** The architect's premise — chains are supply==IPC, 1-cyc/hop is already optimal (multiplier 1-cyc, czero 1-cyc), scheduler polish is futile, only ISA/dataflow shortens the carried chain — is **measured-correct and already the POR.** But the specific headline, **crc32-via-clmul, is REFUTED**: crc32's binding carried chain is the **PRNG seed memory-recurrence** (ld→mul→add→slli→srli→sd seed, store-to-load through memory), NOT the CRC table-lookup; clmul collapses only the off-critical table sub-chain → UB ~0 (consistent with structural-study line 27 "UNREACHABLE" and gate-doc line 296 "fetch, not the chain, was crc32's binder at 11"). **The architect's general claim "CRC is O(1)/word via clmul" is true — for a tight table-free CRC loop, which this suite does not contain.** The clmul RTL is cheap (~1-cyc combinational ALU) IF a justifying workload is ever added (E3 precondition). The one *live* ISA-codegen lever near this region is **Zicond via GCC-14** — but it moves MISPREDICT-bound rows (median UB 2.3–2.8), NOT the chain band; the chain band (crc32/CM/towers/sglib/cjpeg/picojpeg/wikisort) has no in-reach ISA shortcut on a scalar-only (no V/RVV/SIMD) core. **Goal served by software axis (Zicond/GCC-14, chain-band software-only); clmul deferred to a demonstrated workload.**

---

## 6.4 Prioritized next-3 DSE experiments (sim-first) and what each settles

| rank | experiment | sim? | settles | cost | expected outcome |
|---|---|---|---|---|---|
| **1** | **F1 land + read nnet row** (already FUNDED) → then **G-IQ2** post-F1 IQ2 residual + `iq2_fp_and_other_coready` counter | yes (F1 suite pass + 1 readout) | (a) D1-Gate1: does FP mint the roster slot nsichneu wanted? (b) D2: is the FP-IQ-split a real lever or just F1's shadow? | F1 already costed; +3 counter lines in F3 | nnet crosses 2.95 → nsichneu inline path KILLED/deferred; IQ2 residual collapses → FP-IQ-split KILLED. **One pass settles two decisions.** |
| **2** | **GCC-14 toolchain bump → static czero-emission audit** on median/mont64/multiply (D3 `G-SW`) AND crc32/mispredict rows (D4 Zicond) — **shared rebuild, objdump only, no sim yet** | no (static first) | The one genuinely-open ISA-codegen datapoint: does GCC-14 emit czero where GCC-13.4 refuses? Gates whether ANY sim A/B is worth running. | 1 toolchain rebuild (shared D3+D4); objdump free | median likely stays dead (only GCC-14 untested); mont64 marginal (derate-capped); multiply confirms (compiler-generic, already known). If czero emits → ~5 nice'd A/B runs; else KILL the SW arm statically. |
| **3** | **`uoplife_critical_path.py` on crc32** (D4 `G-CRC`) — confirmatory KILL of clmul | yes (1 nice'd analysis run, no build) | Nails PRNG-recurrence vs CRC-table split; closes the headline crc32-clmul question with a direct critical-path readout instead of inference. | ~0, minutes | Predicted: CRC table sub-chain <20% of carried chain → clmul UB ~0 → **headline formally REFUTED**, E3 (Zbc RTL) stays precondition-gated. |

**Why this order:** #1 is already-funded and resolves the two decisions with the highest *roster* stakes (D1 nsichneu slot, D2 FP-IQ-split) in a single F1 pass — the cheapest high-value settlement. #2 is the only genuinely-open *new* lever, and it is **static-first** (objdump czero count is free; sim is deferred until the audit justifies it and the license frees from the cache sweep). #3 is a near-zero confirmatory run that converts an *inferred* clmul-kill into a *measured* one. None of the three writes new RTL; all three are sim-only or static.

---

## 6.5 Updated roster / geomean projection if the surviving DSE levers land

The four decisions add **no new band-wide RTL lever**, so the roster/geomean trajectory is **unchanged from §3** — the DSE's contribution is to *remove* speculative width/predication/clmul work from the POR and *confirm* that the funded F1/F2/UOC-repack stack already captures the reachable headroom. Concretely:

| scenario | roster (≥2.95) | suite geomean Δcyc | what the DSE changed |
|---|---|---|---|
| **today (promoted)** | 8 | baseline | — |
| **F1 + F2 land** | **9–10** (nnet near-certain; stream-l2 joint, stream-l1 marginal) | −4 to −7% (FP/store) | D1-Gate1 satisfied: nnet is the marginal roster slot, bought off-cone — **nsichneu inline path stays deferred (not funded).** D2 FP-IQ-split reads out here — **expected KILL** (F1 owns the cluster), no roster delta. |
| **+ UOC-repack (gated)** | **11–13** (DS-ww certain-band → 3.55, DS knife-edge → 3.13, statemate → 3.37, rsort → 3.47) | −2.5 to −4% (supply) on top | D1 confirmed the band is UOC-covered **except nsichneu**; UOC-repack delivers the band, nsichneu remains the lone uncovered row. |
| **+ surviving DSE levers (G-IQ2 / G-SW / G-CRC)** | **11–13 (no change)** | **≤−0.5% additional, likely ~0** | D2 FP-IQ-split: ≤+1–3% on FP rows IF it survives F1 (expected sub-crossing). D3 G-SW: multiply already-known (clang 2.37, software axis), mont64 −2.2% (no crossing), median dead. D4 Zicond/GCC-14: median 1.31→2.3–2.8 *if GCC-14 emits* (mispredict-row, not roster-crossing), no chain-band movement. **No surviving DSE lever crosses a row to 2.95.** |

**Honest bottom line for the design-of-record:** the architect's four decisions, fully measured, **converge on the existing POR rather than expanding it.** Frontend supply (D1) is already funded band-wide (UOC-repack) with the marginal roster slot bought cheaper by FP; backend width (D2) is dead by the rename-cap hardware fact at every post-UOC operating point, leaving only an FP-IQ-split that is F1's residual; misp-entropy (D3) is SW-partial-dead and HW-target-dependent; chains (D4) confirm the premise but refute the clmul headline on the only available specimen. **The roster trajectory remains 8 → 9–10 (F1/F2) → 11–13 (UOC-repack); the surviving DSE experiments are confirmatory/gating, not roster-moving.** What kills each: D1-inline = frozen-F1-cone cost vs off-cone FP for the same slot; D2-width = cw5=cw6=0 + rename-cap; D2-IQ-split = IQ2 issues <1.0/cyc (F1's domain); D3-SW = compiler-refusal + carried-chain derate; D3-HW = no row meets the 4-part store-hammock bar; D4-clmul = PRNG-recurrence binder, not the table sub-chain.

**Artifacts seeded by this DSE** (reusable, for `doc/uoc_repack_gate_2026-06-13.md`): `/tmp/uocgate/nsichneu_uoctrace.log`, `/tmp/uocgate/rsort_uoctrace.log`, `/tmp/uocgate/run_nsi.py`; engine = `tools/uoc_repack_model.py` + `+UOCTRACE` plumbing (`src/rtl/sim/fetch_frontend_profiler.sv:2668-2702`, `verilator_bench_uoctrace/Vtb_xsim`); confirmatory tool = `tools/uoplife_critical_path.py` (D4 G-CRC). Key RTL refs preserved: `ifu.sv:113` (MAX_DEMAND_RUNAHEAD=1), `rv64gc_core_top.sv:2409-2419` (FP suppress, F1 target), `rename.sv:921-946` (rename-time LQ/SQ/ROB alloc), `alu.sv:184-284` (no CLMUL), `alu.sv:283-284`+`decode_slice.sv:472-477` (czero 1-cyc, Zicond zero-RTL).

---

NOTE: This is the synthesized design-of-record content for §6 of the roadmap. I have NOT written it to disk (per the no-report-file instruction and because the orchestrator owns the file write). If you want it appended to `/home/jeremycai/agent-workspace/rv64gc-v2/doc/rv64gc_v2_uplift_roadmap_2026-06-13.md`, say so and I'll Edit it in.
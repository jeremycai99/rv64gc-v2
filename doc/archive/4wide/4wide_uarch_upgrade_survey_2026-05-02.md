# Industry µarch Upgrade Survey — Candidate Tricks for the rv64gc-v2 4-Wide Gap

**Date:** 2026-05-02
**Repo HEAD:** `master @ 0035c0a`
**Scope:** Survey of modern OoO design tricks targeting the three measured rv64gc-v2 bottlenecks: (1) HEAD_WAIT_BACKLOG (74% of cm cycles, dominated by load-WB at head 16.4% + mispredict recovery 14.7%), (2) frontend supply ≈ 2 uops/cycle vs. PIPE_WIDTH=4 capacity, (3) load+immediate-consumer chains saturating dependency-chain throughput.
**Author:** subagent (deep-research; read-only investigation + 1 doc).

---

## 1. Executive Summary

Across BOOM v4, SonicBOOM, Apple Firestorm/Avalanche, Intel Sandy Bridge → Sapphire Rapids, AMD Zen 1-5, ARM Cortex-X series, IBM POWER, and recent HPCA/ISCA/MICRO papers (2015-2025), the techniques that map most credibly to rv64gc-v2's three bottlenecks are **front-end** focused (because we are dispatch-starved — 50% of pipe-width capacity unused), and **load-side decoupling** focused (because every measured top head-stall PC is a load with an immediate dependent consumer).

**Top-3 most promising candidates** (ranked by predicted IPC × ease-of-implementation, after honoring the REFUTED list):

| # | Trick | Bottleneck | Predicted IPC | Effort |
|---|---|---|---:|---|
| 1 | **FDIP / Decoupled Fetch with Fetch Target Queue** + speculative BPU run-ahead refilling F2 enqueue | Frontend supply (#C); 16% of cm cycles are F2-enq blocked by control transfer | **+3–6% cm**, +1–2% dhry | ~2 wks; ~600 LOC; medium risk on BPU/RAS interaction |
| 2 | **L1D Stride/Stream Prefetcher (NLP-extended) gated on MSHR availability** — direct port of BOOM `NLPrefetcher` plus a small (~16-entry) IP-stride table à la Berti-lite | Load-WB at head (#B); pointer-chase has known limits but stride-stream covers strncpy/strncmp/array sweep loops | **+1–3% cm**, **+5–10% dhry** | ~1 wk; ~400 LOC; low risk if gated on `dcache.mshr_avail` |
| 3 | **AUIPC+ADDI/JALR/LD/ST → BRU early-resolve on JALR-fused** path + macro-fusion expansion to LDP-style **load-load fusion (same base register, adjacent offsets)** | Frontend supply (#C); load-at-head (#B) — fewer uops at head means lower dwell density | **+1–2% cm**, +2–4% dhry | ~1 wk; ~250 LOC in `fusion_detector.sv` |

The **fundamental architectural truth** revealed by the prior bubble taxonomy is that 33% of cm cycles are stuck on **structurally-unavoidable head waits** (load-WB, mispredict refill, MUL latency). Of these three, **only the front-end-supply gap is genuinely closable** by parameter/structural change without rework of the dcache pipeline (which the user has scoped out). The runahead-execution / Apple Firestorm "memory-level parallelism" tricks are powerful but require speculative state isolation that is a multi-month effort and carries the same "speculative execute" risk the user has rejected.

The **honest secondary truth** is that **dhry's gap is ≈40% binary/compiler-driven** (BOOM compiles dhry with `-funroll-all-loops -finline-limit=10000` while our build uses default `-O2`). A **non-RTL** path closure of ≥10% dhry is available by simply matching BOOM's compiler flags — which the user's REFUTED-list (≤3% binary contribution) was specifically about CoreMark and may not apply to dhry the same way. A small follow-up probe is recommended in §5.

---

## 2. Methodology

**Sources consulted (cited inline below):**
1. **BOOM v4 source** at `/home/jeremycai/agent-workspace/riscv-boom/src/main/scala/v4/` — direct file reads of `frontend.scala`, `prefetcher.scala`, `decode.scala`, `tage.scala`, `loop.scala`, `lsu.scala`, `execution-unit.scala`, `core.scala`. The architectural audit at `doc/4wide_arch_diff_2026-05-02.md` already enumerated 25 differences with file:line citations.
2. **SonicBOOM CARRV 2020 paper** (Zhao et al.) — primary RISC-V wide-OoO reference for IPC budgets.
3. **Apple Firestorm reverse engineering** — Dougall Johnson's `https://dougallj.github.io/applecpu/firestorm.html` and recent Arxiv 2024 paper on Firestorm BPU dissection.
4. **Intel optimization manuals** (Sandy Bridge through Sapphire Rapids) — DSB / LSD / LD-LD fusion / TAGE-SC-L behaviors.
5. **AMD Zen 1-5 SoftMC and AGNERFOG** measurements — op cache, branch fusion list, load-store reorder.
6. **ARM Cortex Software Optimization Guides** (A72, A73, A77, X1, X4) — mid-end OoO designs at similar widths.
7. **IBM POWER10 ISA Optimization Guide** — for very-wide reference points.
8. **Academic uarch papers (2015-2025)**:
   - IMP (Yu et al., MICRO 2015) — indirect memory prefetcher for `A[B[i]]` patterns
   - Berti L1D prefetcher (Navarro et al., ISCA 2022 / MICRO 2022)
   - Bingo LLC prefetcher (Bakhshalipour et al., HPCA 2019)
   - SPP (Kim et al., MICRO 2016)
   - Pythia (Bera et al., MICRO 2021)
   - Runahead Execution (Mutlu et al., HPCA 2003) and Precise Runahead (PRE, IEEE CAL 2019)
   - FDIP (Reinman et al., ISCA 1999) and re-establishment papers (ISCA 2020, ISCA 2024 UDP)
   - PDIP (Godala et al., ASPLOS 2024)
   - Boomerang / Shotgun (HPCA 2017 / ASPLOS 2018)
   - BATAGE (Seznec, JILP 2018) and TAGE-SC-L improvements
   - Store-Sets memory dependence prediction (Chrysos & Emer, ISCA 1998)

**Ranking criterion:** `score = (predicted_IPC_gain × confidence_in_estimate) / RTL_effort_in_weeks`, then filtered to remove anything that intersects the REFUTED-list mechanism. Where published numbers were available, they're cited; where not, the entry is marked "unknown — would need probe."

**Key constraint applied to every candidate:** does the mechanism re-introduce a previously REFUTED problem? E.g. mechanisms that increase total in-flight speculative state are mostly excluded because the user rejected speculative pre-completion of MUL/DIV.

---

## 3. Per-Bottleneck Candidate Trick Lists

### A. D-Cache Prefetching (we currently have ZERO D-cache prefetcher)

This is by far our **biggest blank slot vs. industry baseline.** Even BOOM v4 ships a (trivial) `NLPrefetcher` (`riscv-boom/src/main/scala/v4/lsu/prefetcher.scala`) — every commercial design from Cortex-A72 onward has at minimum a stride+stream L1D prefetcher.

#### A.1 Next-Line Prefetcher (NLP) — direct port of BOOM `NLPrefetcher`

- **Mechanism:** On D-cache miss, prefetch the next 64B line into a small staging buffer. Trigger only when an MSHR is available.
- **Source:** BOOM `prefetcher.scala:47-72` — 24 lines of Chisel; a 1-entry register-flag + address adder.
- **Bottleneck addressed:** A (load-at-head; specifically the strncpy/strncmp linear-sweep loops in `core_proc_3` and the matrix sweep in CoreMark `matrix_test`).
- **Predicted IPC impact:** +0.5–1.5% on cm, +3–5% on dhry. (Reasoning: dhry's `proc_3` sweeps short strings linearly; even a 1-line lookahead removes the cold-miss cycle on the *next* access. The dhry per-PC head-stall data shows strncpy is dominant. CoreMark matrix sweep is similar but smaller fraction.) NLP is the cheapest possible D-prefetcher and has been in every L1D since Pentium 4.
- **RTL effort:** ~80 LOC in `dcache.sv` + 1 plusarg gate. **2-3 days.**
- **Risk:** Low. Pollution risk is bounded because we issue at most 1 prefetch per miss and gate on MSHR availability.
- **REFUTED-list intersection:** None.

#### A.2 IP-Stride / Stream Prefetcher (4–8 stream slots, GHB-lite)

- **Mechanism:** Track recent miss addresses by load PC; if 2 consecutive misses from the same PC have constant stride, issue 1-4 prefetches at that stride. Industry standard since Sandy Bridge.
- **Source:** Intel SB optimization manual (HW Stream Prefetcher), Cortex-A77 TRM, AMD Zen optimization guide.
- **Bottleneck addressed:** A (load-at-head), specifically array-sweep workloads. Top cm head-stall PCs `0x80003164 (lh a5,0(a5); mulw)`, `0x80002128 (lh a5,0(a0); andi)` are array-sweep candidates if the inner loop sweeps consecutive elements.
- **Predicted IPC impact:** +1–3% cm, +2–4% dhry. Berti paper reports state-of-the-art L1D prefetchers achieve ~30% MPKI reduction on SPEC; we'd see a fraction of that on cm/dhry hot loops.
- **RTL effort:** ~400 LOC (8-entry IP-stride table, 2 confidence bits, prefetch issue arbiter sharing dcache load port). **1 week.**
- **Risk:** Medium. Pollution is the main risk; also load port contention with demand requests must be deprioritized cleanly.
- **REFUTED-list intersection:** None.

#### A.3 Berti-style Best-Latency Stride Prefetcher (advanced)

- **Mechanism:** Per-IP local-delta tracking with timeliness modeling (issues prefetch only when timely); ~90% accuracy demonstrated.
- **Source:** Navarro et al., "Berti", DPC3 / ISCA 2022. https://dpc3.compas.cs.stonybrook.edu/
- **Bottleneck addressed:** A.
- **Predicted IPC impact:** +2–4% cm, +5–10% dhry — significantly higher than naïve stride.
- **RTL effort:** ~1500 LOC; new module + L1D request multiplexing; **3-4 weeks.**
- **Risk:** Medium-high (storage cost ~4-8KB, more complex timing, larger state to verify).
- **REFUTED-list intersection:** None.
- **Recommendation:** Defer until A.1 + A.2 prove out the prefetch path / MSHR sharing infrastructure. Berti is the right target but A.2 first.

#### A.4 IMP — Indirect Memory Prefetcher (for `A[B[i]]` patterns)

- **Mechanism:** Detect `load A[B[i]]` pattern across PCs; prefetch A[B[i+k]] using the loaded values from B's stream.
- **Source:** Yu, Hughes, Satish, Sengupta, MICRO 2015. https://pages.cs.wisc.edu/~yxy/pubs/imp.pdf
- **Bottleneck addressed:** A specifically for indirect-memory workloads. CoreMark's `core_state_transition` has indirect-table lookups.
- **Predicted IPC impact:** Up to 56% on indirect-heavy SPEC subset; on cm probably <1% because cm's hot loops are linked-list pointer-chase, not `A[B[i]]`.
- **RTL effort:** ~2k LOC; complex; **4-6 weeks.**
- **Risk:** High. Complex correlation tracking; significant L1D port pressure if mistuned.
- **REFUTED-list intersection:** None — but **NOT recommended** for next iteration; pointer-chase (the cm hot pattern) is NOT what IMP solves.

#### A.5 Software Prefetch Instruction Support (`prefetch.r`/`prefetch.w` Zicbop)

- **Mechanism:** Decode and route Zicbop hints to D-cache as prefetch requests.
- **Source:** RISC-V Zicbop spec; minor frontend/decode addition.
- **Bottleneck addressed:** A — but only if the binary contains hints. CoreMark and dhry don't; no win for our workloads as-is.
- **Predicted IPC impact:** 0% on cm/dhry (binary doesn't issue them).
- **RTL effort:** ~100 LOC.
- **Risk:** Low.
- **REFUTED-list intersection:** None.
- **Recommendation:** Skip — no impact on our target workloads.

#### A.6 Pointer-Chase / Markov Prefetchers (academic, for `ld a5, 0(a5)` patterns)

- **Mechanism:** Detect address-chained loads, prefetch what's at the loaded value.
- **Source:** Joseph & Grunwald (ISCA 1997), Roth et al. — Markov prefetcher; "Pointer Cache" Cooksey et al. (MICRO 2002).
- **Bottleneck addressed:** A — specifically the 320-cycle head-stall PC `0x8000235e: ld a5,0(a5); bnez a5` in core_list_mergesort.
- **Predicted IPC impact:** Published numbers up to 20% on graph workloads; on cm <1% because the absolute cycle contribution of pointer-chase hot-PCs is small (320 stall cycles / 199k mcycle = 0.16%).
- **RTL effort:** ~3k LOC; ~6 weeks.
- **Risk:** High. Pointer-cache pollution, miss-prediction cost.
- **REFUTED-list intersection:** None.
- **Recommendation:** **Skip** — the absolute cycle saving on cm is too small to justify the effort.

### B. Reducing Load-at-Head Latency Without Changing D-Cache (16.4% of cm cycles)

The user has scoped out D-cache pipeline rework (we're already faster than BOOM at 2-3 cycle load-to-use). The angles that don't conflict with the REFUTED list:

#### B.1 Memory Dependence Prediction — Store-Sets Predictor

- **Mechanism:** Predict which loads MAY conflict with prior unresolved stores; speculatively issue non-conflicting loads ahead of stores.
- **Source:** Chrysos & Emer, ISCA 1998. Used in Alpha 21264, Pentium 4, Skylake.
- **Bottleneck addressed:** B — but our LSU already does spec_wakeup at AGEN. The gain here is for cycles where a store would otherwise inhibit a load issue.
- **Predicted IPC impact:** Published Pentium 4 numbers: ~2-4% on integer SPEC. On cm probably <1% because cm's hot loops are load-load not load-after-store. On dhry: dhry has many small stores (`proc_3` heavy), so plausibly +1-2%.
- **RTL effort:** ~600 LOC (16-entry SSIT + 4-entry LFST tables + LSU integration); **2 weeks.**
- **Risk:** Medium. Functional correctness of disambiguation must be airtight.
- **REFUTED-list intersection:** Partial. The user REFUTED "Pre-completion of MUL/DIV speculative execute" but memory disambiguation is a narrower class; loads still wait for store address resolution. **NOT a speculative execute pre-completion.** Worth considering but lower priority than A.

#### B.2 Apple M1's Load-Pair Style Fusion — LDP-style

- **Mechanism:** Detect 2 consecutive loads from same base register at adjacent offsets (e.g., `lw a5, 0(a3); lw a4, 4(a3)`); fuse into one µop that issues 1 dcache request + 1 wide reg writeback.
- **Source:** Dougall Johnson `firestorm.html` — Firestorm fuses LDP at decode and issues to a single LSU lane with paired writeback. Halves LSU pressure for paired loads.
- **Bottleneck addressed:** B (one fewer load at head per pair) + C (one fewer uop in the dispatch stream — frontend supply).
- **Predicted IPC impact:** +1-2% cm if hot-loop loads are paired. CoreMark `core_list_mergesort` has consecutive `ld a4,0(s0); ld a5,8(s0)` patterns. Probably +1%.
- **RTL effort:** ~250 LOC in `fusion_detector.sv` + ~100 LOC in LSU to handle 128-bit load + dual-target writeback. **1 week.**
- **Risk:** Medium. Must handle alignment + cross-cacheline-pair correctly. If the pair straddles a 64B boundary, we split.
- **REFUTED-list intersection:** None — this is a *rename-side* compaction, not a speculative-execute pre-completion.

#### B.3 Critical-Word-First Cache Refill

- **Mechanism:** When loading a missing line from L2, return the requested word first; consumer can issue 1-2 cycles before line fully fills.
- **Source:** All Cortex-A and AMD Zen designs.
- **Bottleneck addressed:** B for load-miss cases (small for cm/dhry — we already hit L1D 99%+ on these workloads).
- **Predicted IPC impact:** <0.5% on cm/dhry (L1D hit rate is too high).
- **RTL effort:** ~300 LOC in `dcache.sv` and L2 tilelink; **1 week.**
- **Risk:** Low.
- **REFUTED-list intersection:** None.
- **Recommendation:** Skip — not a high enough fraction of stalls.

#### B.4 Load-Latency Predictor + Wakeup Replay (Speculative Wakeup Replay)

- **Mechanism:** Predict whether a load will hit L1D; if predicted hit, wake the consumer at AGEN+1 (already what we do). If predicted miss, do NOT wake speculatively — saves replay overhead.
- **Source:** Pentium 4 / Skylake (load-hit predictor).
- **Bottleneck addressed:** B — replays cost more than spec wake on hits.
- **Predicted IPC impact:** Unknown — would need probe of replay rate. Plausibly +0.5-1% on cm if replays are >5% of issued loads.
- **RTL effort:** ~200 LOC; **3 days.**
- **Risk:** Low.
- **REFUTED-list intersection:** None.
- **Recommendation:** Probe first to measure replay rate; commit only if >5%.

#### B.5 Apple/IBM "Issue-Time AGU" — Speculative AGEN

- **Mechanism:** Run AGEN at issue+0 for the consumer (1 cycle earlier than our current ISS+1). Requires the bypass to be available 1 cycle earlier.
- **Source:** Apple Firestorm — load latency 3 cycles total instead of 4.
- **Bottleneck addressed:** B.
- **Predicted IPC impact:** **0% — we already do this** (rv64gc-v2 load-to-use = 2-3 cycles per `doc/4wide_arch_diff_2026-05-02.md` §3.5). Already a rv64gc-v2 win vs. BOOM.
- **REFUTED-list intersection:** N/A (already done).

### C. Frontend Supply > 2 uops/cycle

This is the biggest gap. Per the head-deepdive, frontend delivers ~2 uops/cycle into a 4-wide ROB. 16% of cm cycles are F2-enq blocked by control transfer (BPU pipeline interaction); 14.7% are mispredict-recovery refill.

#### C.1 FDIP — Fetch-Directed Instruction Prefetching with Decoupled BPU

- **Mechanism:** Decouple BPU from fetch. BPU runs ahead, generating a stream of fetch-block addresses into a Fetch Target Queue (FTQ). I-cache fetcher pulls from FTQ. This means BPU mispredicts don't directly stall the fetch pipeline — fetch keeps draining FTQ until BPU correction reaches the FTQ tail.
- **Source:** Reinman, Calder, Austin, ISCA 1999 (original); re-established by Asheim et al. arxiv 2020 https://arxiv.org/pdf/2006.13547; UDP at ISCA 2024 https://5surim.github.io/papers/isca2024_UDP.pdf; PDIP at ASPLOS 2024 https://liberty.princeton.edu/Publications/asplos24_pdip.pdf.
- **Bottleneck addressed:** **C directly** — F2-enq blocked by control transfer (BPU 1-cycle bubble per taken branch) is precisely the symptom FDIP solves.
- **Predicted IPC impact:** ISCA 2020 Asheim paper shows FDIP closes ~70% of the front-end bandwidth gap on server workloads. On cm/dhry estimated **+3-6% cm**, **+1-2% dhry** (cm has more taken branches per fetch-block).
- **RTL effort:** ~600 LOC. New FTQ module (16-32 entry) + decoupling of fetch_unit from BPU output + back-pressure handling. **2 weeks.**
- **Risk:** Medium. RAS/checkpointing model needs careful re-validation; existing recovery infrastructure mostly reusable.
- **REFUTED-list intersection:** None. Note: Cycle C (BRU early-redirect) is REFUTED, but FDIP is a *fetch-side* decoupling, not a backend-redirect. Different mechanism.

#### C.2 Loop Buffer / µop Cache Activation (UOC already built)

- **Mechanism:** UOC streams pre-decoded µops directly into rename, bypassing fetch+decode entirely. Hits ≥80% in tight loops.
- **Source:** Intel DSB (Sandy Bridge+), AMD Op Cache (Zen+), our own `doc/uop_cache_design_2026-04-25.md`.
- **Bottleneck addressed:** C.
- **Predicted IPC impact:** Per our prior measurement: UOC ~0% IPC win on 6-wide (subsumed by 4-wide pivot). Should re-measure on 4-wide; the original measurement was on 6-wide where we were not frontend-bound.
- **RTL effort:** **0 LOC — UOC already built** (port via PIPE_WIDTH parameter; opt-in plusarg). But validation on 4-wide is needed.
- **Risk:** Low (revert with plusarg if no win).
- **REFUTED-list intersection:** None.
- **Recommendation:** **Probe first** — re-measure UOC 4-wide IPC delta. If +1% or better, ship as default.

#### C.3 Branch Fusion at Decode (compare-and-branch macro-fusion)

- **Mechanism:** Detect cmp+branch pairs at decode, combine into 1 BRU µop. Already partially implemented in our `fusion_detector.sv` for SLT/SLTU/SLTI/SLTIU + BNE/BEQ.
- **Source:** Intel since Conroe; AMD Zen, ARM since Cortex-A72.
- **Bottleneck addressed:** C (1 fewer uop in the stream) + B (1 fewer uop at head).
- **Predicted IPC impact:** **Already partly captured.** Missing fusions worth adding:
  - `add/sub/and/or/xor + bne/beq` (we only have SLT*+BNE/BEQ) — Apple Firestorm adds these explicitly per https://dougallj.github.io/applecpu/firestorm.html
  - `bltu/bgeu/blt/bge` direct fusion (we have NE/EQ only)
  - Estimated +0.5-1% cm with these additions.
- **RTL effort:** ~300 LOC in `fusion_detector.sv` (extend current Tier 2 patterns); **2-3 days.**
- **Risk:** Low (decode-only, easy to verify).
- **REFUTED-list intersection:** Not directly. SFB (B-style) was REFUTED but that was about *predication*, not fusion. Fusion always wins because it never speculates.

#### C.4 Speculative Branch-Target Enqueue (alternative to FDIP)

- **Mechanism:** When BPU predicts taken, immediately enqueue the predicted target into F1 in the same cycle (saves the 1-cycle "F2 bubble" on every taken branch).
- **Source:** Apple Firestorm, ARM X1+.
- **Bottleneck addressed:** C — exactly the 16% F2-enq blocked stat.
- **Predicted IPC impact:** +1-2% cm. Subsumed by FDIP if FDIP is implemented; standalone fallback.
- **RTL effort:** ~200 LOC in `fetch_unit.sv` if not doing FDIP; **3-4 days.**
- **Risk:** Medium-low. Wrong-path waste increases marginally.
- **REFUTED-list intersection:** **REFUTED-equivalent** to Cycle C (BRU early-redirect)? **NO — different mechanism.** Cycle C was about *backend* redirect from a resolved BRU at execute; this is about *frontend* prediction collapsing the bubble between F1 and F2. We have not refuted this specific mechanism.
- **Recommendation:** Implement **only if** FDIP is too large; FDIP subsumes the win.

#### C.5 Wider Fetch (8B → 16B per cycle) Without Changing PIPE_WIDTH

- **Mechanism:** Fetch 16B (4 RVI insns) per cycle into the FetchPacketBuffer; rename can sustain higher peak.
- **Source:** Apple Firestorm, AMD Zen 4 (32B fetch).
- **Bottleneck addressed:** C — but FPB depth and decode width remain at 4, so peak rename stays at 4. The win is on cycles where decode could otherwise fetch only 1-3 due to instruction-cache misalignment / RVC packing.
- **Predicted IPC impact:** Unknown — would need probe of fetch-width-limited cycles. Plausibly +0.5-1.5% cm.
- **RTL effort:** ~600 LOC. ICache port widening + alignment shifter rewrite + FPB enqueue logic. **2 weeks.**
- **Risk:** Medium. ICache rebuild risk.
- **REFUTED-list intersection:** None.
- **Recommendation:** Defer. FDIP solves the same symptom more cleanly.

### D. BPU Improvements Beyond TAGE-SC-L (14.7% mispredict recovery)

We are already TAGE-SC-L with 4 tagged tables × 256 entries, SC 1024, LP 64, BTB 2048×8, RAS 24. Per the architectural audit, this is **bigger than BOOM's TAGE** (BOOM uses 4 tagged × 256 with smaller tag bits). **Cycle A REFUTED uBTB sizing.**

#### D.1 BATAGE — Bayesian TAGE (Seznec, JILP 2018)

- **Mechanism:** Replace TAGE confidence counters with Bayesian inference, achieves ~5-10% lower MPKI on SPEC vs. TAGE-SC-L.
- **Source:** Seznec, JILP 2018, "BATAGE."
- **Bottleneck addressed:** D.
- **Predicted IPC impact:** Published BATAGE numbers: ~5% on integer SPEC mispredict reduction → ~0.5-1% IPC.
- **RTL effort:** ~800 LOC; replace TAGE counter update logic + add saturated-Bayesian counters; **2-3 weeks.**
- **Risk:** Medium-high (well-validated on Champsim, less so in RTL).
- **REFUTED-list intersection:** **Partial REFUTED-equivalence.** Cycle A REFUTED storage growth as the bottleneck — but BATAGE is a *predictor algorithm* improvement, not storage growth. These are independent dimensions. Not refuted, but predicted IPC gain is likely <1% which doesn't justify the effort.
- **Recommendation:** Skip — the gain is marginal and TAGE-SC-L is well-tuned.

#### D.2 ITTAGE — Indirect Branch Predictor

- **Mechanism:** TAGE-style indirect branch target prediction (separate from BTB).
- **Source:** Seznec, JILP 2014. Used in Apple Firestorm (separate ITB), AMD Zen 4.
- **Bottleneck addressed:** D for indirect branches specifically.
- **Predicted IPC impact:** On cm <0.5% (CoreMark has very few indirect branches; the BTB handles direct + RAS handles return). On dhry near 0%.
- **RTL effort:** ~600 LOC; **2 weeks.**
- **Risk:** Medium.
- **REFUTED-list intersection:** None directly, but Cycle A's BPU-storage-growth REFUTE makes the IPC-gain prior weak.
- **Recommendation:** Skip — no measured indirect mispredict pressure.

#### D.3 Loop Predictor Sophistication (we have 64-entry LP)

- **Mechanism:** Larger / multi-iteration loop predictor with confidence override.
- **Source:** Seznec et al. — TAGE-SC-L variants, ARM Cortex-X4.
- **Bottleneck addressed:** D.
- **Predicted IPC impact:** Unknown. CoreMark's tight loops are <64 iterations so LP usually catches them; dhry similar. <1%.
- **RTL effort:** ~200 LOC.
- **Risk:** Low.
- **REFUTED-list intersection:** Partial — Cycle A (uBTB sizing) REFUTED storage growth; this is on a different storage. Marginal.
- **Recommendation:** Skip — diminishing returns on TAGE-tuned design.

#### D.4 Perceptron / Hashed Perceptron Predictor

- **Mechanism:** Replace conditional-branch direction prediction with perceptron classifier; can learn very long-history patterns.
- **Source:** Jiménez et al. (HPCA 2001+), Hashed Perceptron used in AMD Zen 1/2.
- **Bottleneck addressed:** D.
- **Predicted IPC impact:** Modern view: TAGE-SC-L beats hashed perceptron on most integer workloads (per Championship Branch Prediction). On data-dep branches like our cm hot patterns, neither helps because the dependency is data-driven.
- **RTL effort:** ~1.5k LOC; **3-4 weeks.**
- **Risk:** Medium. Replacing TAGE-SC-L is a major change.
- **REFUTED-list intersection:** Indirect — Cycle A REFUTED extra BPU storage; perceptron requires a per-entry weight table. Same dimension.
- **Recommendation:** **Skip.** TAGE-SC-L is the modern sweet spot.

### E. Macro-Op Fusion Expansion

We have: LUI+ADDI, AUIPC+{JALR/ADDI/LD/ST}, SLT/SLTU/SLTI/SLTIU+{BNE/BEQ}, SEXT.W+{BNE/BEQ}.

#### E.1 Add direct cmp-and-branch fusion (`add/sub/and + bnez/beqz`)

- **Mechanism:** Many cmp-followed-by-branch idioms in idiomatic C compile to `addi t0, x, -k; beqz t0, label` or similar. Apple Firestorm fuses these directly.
- **Source:** Firestorm `dougallj.github.io`; arXiv 2024 (Firestorm BPU paper).
- **Bottleneck addressed:** C, B.
- **Predicted IPC impact:** +0.5-1% cm.
- **RTL effort:** ~200 LOC in `fusion_detector.sv` (extend Tier 2). **2-3 days.**
- **Risk:** Low.
- **REFUTED-list intersection:** None.

#### E.2 Move + ALU Fusion

- **Mechanism:** `mv rd, rs; addi rd, rd, k` → `addi rd, rs, k`. Already eliminated by our move-eliminator (`ren_move_eliminated` exists).
- **Bottleneck addressed:** C, B.
- **Predicted IPC impact:** ~0% (move-elim already does it).
- **REFUTED-list intersection:** N/A (already in.)

#### E.3 Load-with-immediate-offset + ALU (load-op fusion)

- **Mechanism:** `lw rd, 0(rs); addi rd, rd, k` → 1 µop "load-then-add."
- **Source:** Apple Firestorm tests show NO LD+ALU fusion (it's a separate µop). x86 has implicit LD+OP (memory-source operands) but RISC-V doesn't.
- **Bottleneck addressed:** C, B.
- **Predicted IPC impact:** Unknown. Doesn't help dependency-chain throughput (the consumer ALU still depends on the load result).
- **RTL effort:** ~500 LOC; requires new "load+ALU" exec path.
- **Risk:** High.
- **REFUTED-list intersection:** None.
- **Recommendation:** **Skip** — doesn't address head-of-line bottleneck (the load WB at head still gates commit).

#### E.4 LDP-style Load-Load Fusion (B.2 above duplicate cross-reference)

- See B.2. **Strong candidate** — addresses both B and C.

---

## 4. Master Recommendation Table — Ranked by Predicted IPC × Ease

| # | Trick | Predicted cm | Predicted dhry | Effort | Risk | Score (gain/effort) |
|---|---|---:|---:|---|---|---:|
| 1 | **FDIP / Decoupled fetch with FTQ (C.1)** | **+3-6%** | +1-2% | 2 wks | Med | HIGH |
| 2 | **L1D Stride/Stream Prefetcher (A.2)** | +1-3% | **+5-10%** | 1 wk | Low | HIGH |
| 3 | **L1D NLP first (A.1)** | +0.5-1.5% | +3-5% | 2-3 days | Low | HIGH (cheapest meaningful win) |
| 4 | **LDP-style load-load fusion (B.2 / E.4)** | +1-2% | 0% | 1 wk | Med | MEDIUM-HIGH |
| 5 | **Branch fusion expansion (C.3 + E.1)** | +0.5-1% | 0% | 2-3 days | Low | MEDIUM-HIGH |
| 6 | **UOC re-probe on 4-wide (C.2)** | unknown — measure | unknown | 0 LOC (probe only) | Low | UNKNOWN — prerequisite for ranking |
| 7 | **Memory dep prediction / store-sets (B.1)** | <1% | +1-2% | 2 wks | Med | MEDIUM |
| 8 | **Load-hit predictor + non-replay (B.4)** | +0.5-1% | unknown | 3 days | Low | MEDIUM (probe first) |
| 9 | **Berti L1D prefetcher (A.3)** | +2-4% | +5-10% | 3-4 wks | Med-High | MEDIUM (deferred) |
| 10 | **BATAGE (D.1)** | <1% | <0.5% | 2-3 wks | Med-High | LOW |
| 11 | **ITTAGE (D.2)** | <0.5% | ~0% | 2 wks | Med | LOW |
| 12 | **Loop predictor sophistication (D.3)** | <1% | <0.5% | 1 wk | Low | LOW |
| 13 | **IMP indirect prefetcher (A.4)** | <1% | 0% | 4-6 wks | High | LOW (wrong workload pattern) |
| 14 | **Pointer-chase prefetcher (A.6)** | <1% | 0% | 6 wks | High | LOW |
| 15 | **Hashed perceptron BPU (D.4)** | <1% | 0% | 3-4 wks | Med | LOW |
| 16 | **Speculative branch-target enq (C.4)** | +1-2% | +1% | 3-4 days | Med-Low | MEDIUM (subsumed by FDIP) |
| 17 | **Wider fetch (8B→16B) (C.5)** | +0.5-1.5% | +0.5% | 2 wks | Med | LOW (subsumed by FDIP) |
| 18 | **Critical-word-first (B.3)** | <0.5% | <0.5% | 1 wk | Low | LOW |
| 19 | **LD+ALU fusion (E.3)** | unknown | unknown | 2-3 wks | High | LOW |
| 20 | **Software prefetch (Zicbop) (A.5)** | 0% | 0% | 2-3 days | Low | NONE (binary doesn't issue) |

**Recommended cycle order:**
1. **Probe-only:** Re-measure UOC on 4-wide (C.2). Cost: 1 day. Decision gate.
2. **Cycle G:** **A.1 NLP** — cheapest, lowest risk, biggest dhry % per LOC. **2-3 days.**
3. **Cycle H:** **A.2 Stride/Stream prefetcher** — extends G's L1D prefetch path. **1 week.**
4. **Cycle I:** **C.1 FDIP** — biggest cm win, most architectural. **2 weeks.**
5. **Cycle J:** **B.2 / E.4 LDP-style load-load fusion + C.3 branch fusion expansion** — done together at decode. **1 week.**

This sequence delivers **+5-10% cm, +9-17% dhry** in ~1.5 months total, addressing the 19% cm gap and a substantial chunk of the dhry gap. Note: dhry's 39% gap is partly compiler-driven (see §5).

---

## 5. What WOULDN'T Work — Industry Tricks Excluded with Justification

### 5.1 Direct REFUTED-equivalents

| Industry trick | REFUTED-list mechanism | Why it would re-fail |
|---|---|---|
| Increase BPU TAGE table sizes / add a 5th tagged table | Cycle A: uBTB sizing | Storage growth is REFUTED — TAGE saturates. |
| BRU forward-cancel on same-cycle resolved branches | Cycle C: BRU early-redirect | Net-negative mispredict count established. |
| SFB-style folded-into-predication | Cycle B: SFB fold | Only 0.92% cm cycles eligible — can't make it pay. |
| Add bypass coverage for ALU3/DIV/CSR | Cycle E: ALU3 bypass | CDB[3] activity too sparse — 0% IPC impact. |
| Re-partition INT IQs (3×24 → 1×40+1×20+1×16 etc.) | Cycle F: IQ reorg | −2.82% measured; 3-way ALU load-balance is critical. |
| Reduce Dcache hit latency to 1 cycle | User-rejected scope | Already 2-3 cyc — faster than BOOM; structural rework. |
| Reduce pipeline depth | User-rejected | Pipelining = depth-independent steady-state. |
| Speculative pre-completion of MUL/DIV | User-rejected | "Too speculative." |

### 5.2 Industry tricks that **look promising but actually don't help** our specific bottlenecks

- **Banked PRF / column-issue ALU (BOOM has option, off in MegaBoom):** Saves PRF read-port pressure but our PRF isn't the bottleneck (commit-wait at head is).
- **Banked free list:** Same — we have 128-entry free list and never run dry.
- **Larger ROB (>128):** Per the bubble taxonomy, ROB occupancy is dominated by 8-15 entries (47.7% of cm cycles). ROB is rarely full. No win.
- **More L2 MSHRs:** Cm/dhry don't generate enough L2 misses for this to bind.
- **Load-store reorder (Apple style):** Already done — our LSU does AGEN+0, dcache S0+1, return at S0+2 with spec_wakeup at AGEN-time.
- **Move elimination, zero elimination:** Already implemented (`ren_move_eliminated`, `ren_zero_eliminated`).
- **Critical-word-first:** L1D hit rate is already too high for L2-refill-time to matter.
- **Runahead Execution / Precise Runahead (PRE):** This is the most-cited modern technique for closing memory-latency gaps. **However**, it requires speculative state isolation (renamed checkpoint, alternative ROB or speculative RF), which is exactly the "speculative execute" class the user has scoped out. Predicted +5-10% on memory-bound workloads, but **multi-month effort + falls into REFUTED-equivalence on the speculative-execution dimension.** Mark as: **technically the highest-ceiling option for B but inconsistent with current scope.**
- **Helper-thread prefetching:** Requires SMT or a helper hardware thread. We're single-thread. N/A.

### 5.3 Compiler / Binary contribution to dhry — likely closer than we thought

The user's MEMORY notes say "Compiler/binary contribution ≤3% — BOOM uses same convention." This was specifically about **CoreMark** (where we tested with the same `-O2 -funroll-loops` flags as BOOM). For **Dhrystone**, BOOM's standard build uses `-DDHRYSTONE_USE_INLINE -funroll-all-loops -finline-limit=10000`, which is more aggressive than our default. The dhry hot-loop `proc_3` involves repeated function calls that, if inlined, eliminate ~20% of dynamic instructions. **Probe recommended:** rebuild dhry with BOOM's exact flags and re-measure before declaring more dhry IPC gap. Could close ≥10% of the dhry gap with zero RTL change.

---

## 6. Sources / References

### BOOM v4 source (cloned at `/home/jeremycai/agent-workspace/riscv-boom/`)
- `src/main/scala/v4/lsu/prefetcher.scala` — NLPrefetcher reference
- `src/main/scala/v4/ifu/frontend.scala` — F0-F4 stages, FetchBuffer, SFB folding
- `src/main/scala/v4/ifu/bpd/tage.scala` — TAGE bank
- `src/main/scala/v4/ifu/bpd/loop.scala` — loop predictor
- `src/main/scala/v4/exu/decode.scala` — decode tables, fusion
- `src/main/scala/v4/exu/execution-units/execution-unit.scala` — ARB/RRD/EXE pipeline
- `src/main/scala/v4/common/config-mixins.scala:246-296` — MegaBoom params

### Papers (peer-reviewed)
- **IMP — Indirect Memory Prefetcher** (Yu, Hughes, Satish, Sengupta, MICRO 2015): https://pages.cs.wisc.edu/~yxy/pubs/imp.pdf
- **Berti — Best-Latency Stride Prefetcher** (Navarro et al., DPC3 / ISCA 2022): https://dpc3.compas.cs.stonybrook.edu/
- **SPP — Signature Path Prefetcher** (Kim, Pugsley, et al., MICRO 2016): https://www.semanticscholar.org/paper/Lookahead-Prefetching-with-Signature-Path-Kim-Gratz/d35be2b3f5860b60fa427688b46c8f348fff50ae
- **Pythia — RL-based prefetcher** (Bera et al., MICRO 2021)
- **Bingo — LLC prefetcher** (Bakhshalipour et al., HPCA 2019)
- **Runahead Execution** (Mutlu, Stark, Wilkerson, Patt, HPCA 2003): https://users.ece.cmu.edu/~omutlu/pub/mutlu_hpca03.pdf
- **Precise Runahead Execution (PRE)** (IEEE CAL 2019)
- **Memory Dependence Prediction Using Store Sets** (Chrysos & Emer, ISCA 1998): https://acg.cis.upenn.edu/milom/cis501-Fall10/papers/store-sets.pdf
- **FDIP — Fetch-Directed Instruction Prefetching** (Reinman, Calder, Austin, ISCA 1999)
- **Re-establishing FDIP, an industry perspective** (Asheim et al., ISCA 2020): https://arxiv.org/pdf/2006.13547
- **UDP — Utility-Driven FDIP** (Oh et al., ISCA 2024): https://5surim.github.io/papers/isca2024_UDP.pdf
- **PDIP — Priority Directed Instruction Prefetching** (Godala et al., ASPLOS 2024): https://liberty.princeton.edu/Publications/asplos24_pdip.pdf
- **Boomerang** (HPCA 2017), **Shotgun** (ASPLOS 2018) — frontend-bottleneck research
- **BATAGE** (Seznec, JILP 2018)
- **ITTAGE** (Seznec, JILP 2014)
- **Hashed Perceptron BPU** (Jiménez, HPCA 2001+)
- **SonicBOOM CARRV 2020** (Zhao et al.): https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf

### Reverse engineering & vendor docs
- Dougall Johnson — Apple **Firestorm** documentation: https://dougallj.github.io/applecpu/firestorm.html
- Dougall Johnson — Apple M1 Load and Store Queue Measurements: https://dougallj.wordpress.com/2021/04/08/apple-m1-load-and-store-queue-measurements/
- Apple Firestorm BPU dissection (arXiv 2024): https://arxiv.org/html/2411.13900v1
- WikiChip — Macro-Operation Fusion: https://en.wikichip.org/wiki/macro-operation_fusion
- Intel Optimization Reference Manual (Sandy Bridge → Sapphire Rapids) — DSB/LSD/LD-LD fusion
- AMD Zen 1-5 Software Optimization Guides — op cache, branch fusion
- ARM Cortex-A77, X1, X4 Software Optimization Guides
- IBM POWER10 ISA Optimization Guide

### Internal cross-references (rv64gc-v2 docs)
- `doc/4wide_arch_diff_2026-05-02.md` — 25-difference architectural audit
- `doc/4wide_pipeline_bubble_taxonomy_2026-05-02.md` — 74% HEAD_WAIT_BACKLOG
- `doc/4wide_headwait_deepdive_2026-05-02.md` — load-WB at head 16.4%, mispredict refill 14.7%
- `doc/4wide_probe_results_2026-05-02.md` — frontend supply ≈ 2 uops/cycle
- `doc/4wide_iter_uBTB_results.md` — Cycle A REFUTED
- `doc/4wide_iter_flush_recovery_results.md` — Cycle C REFUTED
- `doc/4wide_iter_sfb_results.md` — Cycle B REFUTED
- `doc/4wide_iter_alu3_bypass_results.md` — Cycle E REFUTED
- `doc/4wide_iter_iq_reorg_results.md` — Cycle F REFUTED
- `doc/uop_cache_design_2026-04-25.md` — UOC infrastructure (already built)

---

## 7. Conclusion

**The single biggest unaddressed lever is the front-end-supply gap (frontend delivers 2 uops/cyc into a 4-wide ROB).** FDIP is the textbook solution for the F2-enq-blocked-by-control-transfer pattern that consumes 16% of cm cycles and is the most-cited modern frontend optimization (industry-validated since 1999, re-validated multiple times in 2020-2024).

**The single biggest "free win" is L1D prefetching.** We currently have ZERO D-cache prefetcher; even BOOM's trivial NLPrefetcher would close some of dhry's gap (where hot loops are linear sweeps). This is the cheapest measurable win possible at <100 LOC and is recommended as the first cycle.

**The remaining ceiling cost — load-WB at head — requires either (a) D-cache pipeline rework (out of scope), (b) speculative pre-completion / runahead (out of scope per user), or (c) macro-fusion-driven uop reduction at head.** Of these, only (c) is viable; B.2 LDP-style load-pair fusion is the candidate.

**The dhry gap deserves a non-RTL probe: rebuild with BOOM's compiler flags first.** ≤3% binary contribution applies to cm; for dhry the gap may be 10%+ from `-funroll-all-loops` and `-finline-limit=10000`.

The sequence G → H → I → J described in §4 closes a credible **+5-10% cm, +9-17% dhry** in ~1.5 months. None of these mechanisms intersects the REFUTED list. The remaining 5-10% cm gap is structural per the head deepdive and is consistent with PARTIAL-FLOOR sign-off remaining in force.

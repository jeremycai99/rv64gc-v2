> Controller note (2026-06-09): the load-bearing RTL claim — the S1 store re-latch bubble at dcache.sv:291-292 capping the single store pipe at ~0.5 ack/cyc — was independently verified by reading the RTL (s1_st_valid <= (grant_a||grant_b) && !store_ack_matches_head). The store-ack arithmetic and the parser 97:3 phase split remain MODEL estimates pending sim/per-phase-profiler confirmation.

# All-Workloads ≥ 2.0 IPC — Feasibility Map

*rv64gc-v2 (4-wide OoO RV64GC) · synthesis of store-ceiling, latency-mechanism, parser-MLP, and per-workload analyses, reconciled against two adversarial verifies and confirming RTL reads. Today's date: 2026-06-09.*

---

## 1. Bottom line

**"All workloads ≥ 2.0 IPC" is NOT achievable on the as-built RTL with the levers as originally scoped, but it is plausibly achievable with a correctly-scoped store-engine rebuild plus a (mostly-software) parser fix.** Two independent claims in the input package were overstated and are corrected here by the adversarial verifies, which I trust:

- **Store-bound cluster (linear_alg, loops, nnet, cjpeg).** No-write-allocate (NWA) is the *right lever direction* — that is robustly confirmed by RTL + counters. But the headline "NWA alone → 1.0 store-ack/cyc → IPC 2.04" is **REFUTED**. A **per-store S1 re-latch bubble (dcache.sv:291-292, read & confirmed this session)** caps the single store pipe at **~0.5 ack/cyc**, not 1.0, corroborated by the measured non-fill hit-ack rate of **0.4375/cyc** (1,919,693 hit_acks / 4,387,646 non-fill cycles). Reaching 2.0 needs **three** components, not one: (1) NWA/write-around to delete the 274K read-for-ownership fills, (2) a 2-wide store-commit pipe, **and** (3) a redesign of the S1 store re-latch to sustain 1 ack/cyc/port. cjpeg clears easily; nnet is a knee; linear_alg/loops are a **knife-edge** (store fraction ≈ 0.4997 demands a sustained ≥0.9994 drain/cyc).

- **Parser.** The "permanent exception, locked ~1.16, serial-pointer-chase wall" verdict is **REFUTED**. The dominant phase is *not* the traverse pointer-chase (~3% of instrs) but `ezxml_parse_str`'s **byte-at-a-time `strcspn`/`strspn` scan over 125 KB (~97%)** — a stride-1, data-independent, compulsory-miss streaming scan. A zero-RTL word-wide string fix (the same methodology gap already documented for Dhrystone) plus the **already-half-wired** stride/next-line data prefetcher plausibly clears 2.0. *Caveat: the 97:3 split is an analytical estimate, not a measured per-phase profile — it must be confirmed before funding.*

**Honest status:** no individual claimed lever, taken at its original scope, delivers all-workloads-2.0. The *program* below can — but every "yes" past cjpeg is **model-estimated and sim-unconfirmed**, and three of the five sub-2.0 workloads are marginal/knife-edge.

---

## 2. Per-workload feasibility table

| Workload | Current IPC | Binding constraint | Lever | Post-lever IPC (est.) | Reach 2.0? | Confidence |
|---|---|---|---|---|---|---|
| sha | 2.93 | compute/dep-chain floor | — | 2.93 | **yes (already)** | high (measured) |
| radix2 | 2.49 | compute/dep-chain floor | — | 2.49 | **yes (already)** | high (measured) |
| zip | 2.27 | compute/dep-chain floor | — | 2.27 | **yes (already)** | high (measured) |
| core (CoreMark) | 2.16 | compute/dep-chain floor | — | 2.16 | **yes (already)** | high (measured) |
| boot (paged Linux) | ~2.04 | (above 2.0) | — | ~2.04 | **yes (already)** | high (measured) |
| **cjpeg** | 1.53 | SQ-full 53% (store-bound, sf≈0.24) | NWA(+S1-fix) | ~2.0–2.6 (work-bound) | **yes** | medium |
| **nnet** | 1.05 | SQ-full 65% (store-bound, sf≈0.34) | NWA + S1-fix (+dual port) | ~1.9–2.1 | **marginal** | low–medium |
| **linear_alg** | 0.73 | SQ-full 82%; serialized RFO fills (sf≈0.4997) | NWA + dual port + S1-fix (all 3) | ~2.0 (knife-edge) | **marginal** | low |
| **loops** | 0.73 | SQ-full 82% (sf≈0.49) | NWA + dual port + S1-fix (all 3) | ~2.0 (knife-edge) | **marginal** | low |
| **parser** | 0.76 (1.16 fast-L2) | 97% byte-at-a-time string scan; 3% pointer-chase | word-wide strings (SW) + stride prefetcher | ~2.1–2.5 (model) | **marginal/yes** | low |

Five workloads are already ≥2.0 (measured). The five below 2.0 split into a **store-bound cluster** (cjpeg/nnet/linear_alg/loops) and a **single string-scan/pointer-chase outlier** (parser). Note: the "yes" for cjpeg and the entire parser row rest on a corrected phase-attribution that has **not been sim-confirmed**.

---

## 3. The store-engine lever

### Mechanism (measured + RTL-confirmed)
The committed-store path is **strictly 1-wide end-to-end**: ROB commits ≤4 stores/cyc into the SQ; SQ drains **1/cyc** into the CSB; the CSB dequeues **1/cyc** (`committed_store_buffer.sv` single `head_r`/`deq_ack` @79,355) to the D-cache, which wins a **shared** RAM read port only when a load port is idle (dcache.sv:219; `port_wait=40` confirms loads don't contend in the pure-store phase). `store_ack_s1` (dcache.sv:911-915, read this session) fires **only** on a cache hit or the same-cycle fill-install merge. A store-**miss** sets `fill_pend=1` (write-allocate), is **not** acked, and is held at the CSB head, re-presented every cycle until its line's **read-for-ownership fill** returns through the single-outstanding L1D-side L2 FSM (dcache.sv:662-715).

The linear_alg counters decompose **exactly** to an 8-stores-per-cold-line streaming pattern: 274,085 fills × 1 fill_ack/line + ~7 hit_acks/line = 2,193,778 total acks; `miss_merge` (1,611,770) ≈ `wait_fill` (1,611,774) = the 5.88 followers/line held behind each serialized fill. Latency-insensitivity (wait_fill **byte-identical** at L2 lat 8 vs 2) proves the cost is **FSM serialization throughput**, not fill latency. The L2 itself is fully pipelined (l2_cache.sv 8-deep hit_pipe, 32-MSHR) and accepts a write in 1 cyc — it is **not** the serializer.

### Achievable ceiling (arithmetic, with the verify correction)
Canonical model: **IPC = store_ack_rate / store_fraction**. Validated: linear_alg sf = 2,193,778/4,390,376 = **0.4997**; 0.366/0.50 = 0.747 vs measured 0.732 (tight).

- **Original claim (A/B):** NWA → 1.0 ack/cyc → IPC = 1.0/0.4997 = **2.04**.
- **Corrected (verify, RTL-confirmed):** the **S1 re-latch bubble at dcache.sv:291-292** forces `s1_st_valid<=0` the cycle after an ack advances the CSB head, so back-to-back stores ack **once every 2 cycles = ~0.5/cyc**. Independent confirmation: non-fill hit-ack rate = 1,919,693 / (5,999,420 − 1,611,774) = **0.4375/cyc**, with `port_wait=40` ruling out load contention.
  - NWA **alone** on the existing pipe → ~0.5/cyc → IPC = 0.5/0.4997 ≈ **1.0** (roughly flat). **Does NOT clear 2.0.**
  - NWA + **dual store-commit port** but leaving the bubble → 2.0/cyc port halved by the bubble back to ~1.0/cyc → IPC ≈ **1.0**. Still short.
  - NWA + dual port + **S1 re-latch redesign** (1 ack/cyc/port × 2 ports = ~2.0/cyc, or 1.0/cyc on a single fixed port) → IPC = ~1.0/0.4997 ≈ **2.0** — a bare pass with **zero margin** (needs sustained ≥0.9994 drain/cyc).

For the lower-sf workloads the same fixed pipe is comfortable: **cjpeg** sf≈0.24 needs only 0.47/cyc (clears with margin, then work-bound ~2.0–2.6); **nnet** sf≈0.34 needs 0.68/cyc (a knee at ~1.9–2.1). **Multi-outstanding L2 is REDUNDANT** on top of NWA (`wt_full=0`, `wt_occ_max=2` prove the 4-deep WT queue never backs up) — for the store cluster it is subsumed by NWA and should not be funded *for them*.

### RTL scope
Per design doc (no_write_allocate_design_2026-06-08.md:52-72), gated by existing `NO_WRITE_ALLOCATE_ENABLE` (rv64gc_pkg.sv:159):
1. **dcache.sv store-miss MSHR @1230-1267** — gate `fill_pend` off for full-mask streaming lines; accumulate `store_line_mask`/data; new write-validate install path (~parallel to fill_done install @855-869).
2. **dcache.sv store_ack_s1 @911-915 + CSB-hold semantics** — ACK a missing streaming store immediately (write-around) instead of CSB-holding it.
3. **The S1 re-latch bubble fix @291-292** *(verify's third component, omitted by A/B)* — gate the duplicate-write guard on the data-RAM write-enable rather than on `s1_st_valid`, or latch the next CSB head a cycle earlier, to sustain 1 ack/cyc/port.
4. **lsu.sv CSB completion path @~1306-1313.**
5. **Write-combining buffer** feeding the WT queue (dcache.sv:717-737) so 8 same-line stores collapse to 1 L2 write.
6. **Dual store-commit port** (only if linear_alg/loops must clear 2.0): 2-wide CSB deq (2nd head/ack @79,355) + a 2nd D-cache write port (today stores share the 2 *load* read ports → needs dedicated 2nd write port or banked RAM) + 2/cyc WT enqueue. ~200–400 lines, RAM-macro implications.

**Total: ~300–600 RTL lines across dcache + lsu + CSB** (the verify's bubble fix and the dual port push this above A/B's 150–300 estimate). No L2 RTL change required.

### Does NWA alone suffice?
**No — confirmed false by the verify and the RTL.** For cjpeg/nnet (low sf), NWA + S1-fix suffices. For **linear_alg/loops (sf≈0.5), all three of NWA + dual store-commit port + S1 re-latch redesign are required**, and even then it is a knife-edge that any RMW/AMO/cross-line-split-store (lsu.sv:1283-1333, 2 acks) contamination can break below 2.0.

---

## 4. Parser: honest verdict

**The "permanent exception at 1.16" verdict is refuted, but the refutation is model-based and unconfirmed.**

- **Why 1.16 is not a fundamental wall (RTL/disasm evidence):** the "128 KB-on-fast-L2 adds zero ⇒ capacity-insensitive ⇒ serial-latency-bound" inference is a **non-sequitur** — a stride-1 streaming scan with no intra-pass reuse is *equally* capacity-insensitive (compulsory misses), so the A/B does not discriminate streaming-compulsory from serial-latency. The actual discriminator (a stride prefetcher or word-wide scan) was never tested.
- **What the kernel does:** `parser_kernel_direct.c` → memcpy(125 KB) → `ezxml_parse_str(125 KB)` → traverse. The parse phase scans every byte through **byte-at-a-time `strcspn`/`strspn`** (confirmed @0x80006196 in the ELF: `lbu` per char, nested reject-set loop) — ~97% of dynamic instrs. The traverse pointer-chase is ~3%. The measured profile (operand-not-ready 62%, low MLP, 24.3% L1D miss) is exactly byte-at-a-time scanning over 125 KB + ~1,953 compulsory line misses — **not** a data-dependency chain.

### Menu of options
| Option | Expected parser IPC | RTL cost | Confidence | Verdict |
|---|---|---|---|---|
| **Word-wide / bitmap char-class string scan (SW/toolchain)** | parse phase ~2.2–2.6; combined ~2.1–2.5 | **zero RTL** | low (unmeasured split) | **DO FIRST** — also the owed Dhrystone-class fair-methodology fix |
| **Stride/next-line DATA prefetcher** (already-wired L2 port l2_cache.sv:34-39, icache-only today) | hides the ~1,953 compulsory misses | modest, low-med | medium | **DO SECOND** (after measuring) |
| Dependence-based pointer prefetcher (Roth/Cooksey) | +5–25% on the 3% chase → small | moderate-large | medium | not worth it for 3% |
| Runahead / DAE | +3–10% (SpecInt-class) | very large (rename/ROB/PRF/LSU) | high cost | **no** |
| Address/value prediction | +0–5%, can regress | large | high risk | **no** |
| Larger window / wider issue / deeper LQ-SQ | **~0%** (already A/B-refuted) | n/a | — | **no** |

**Recommendation:** treat parser as **conditionally feasible, not a permanent exception** — but gate the verdict on **two cheap discriminators (per-phase counter + word-wide-scan A/B)** before funding the prefetcher. If the per-phase split turns out far less lopsided than 31:1 (e.g. ezxml's per-tag malloc/realloc + th_strcmp carry heavy dependent-load traffic), the latency-wall framing returns and a documented exception at ~1.16–1.45 becomes the honest fallback. The runahead/value-pred/larger-window dismissals stand regardless.

---

## 5. Recommended program (ordered, cheapest-highest-confidence first)

1. **[ZERO RTL, measure first] Per-phase profiler + word-wide string fix for parser/Dhrystone.** Add a marker-bracketed cycle/instret counter around `ezxml_parse_str` vs `traverse_tree` to confirm the 97:3 split; replace byte-at-a-time `strcspn`/`strspn` with word-wide/bitmap scans. Cheapest possible, attacks the owed fair-methodology gap, and either lands parser near 2.0 or proves it can't. **Decided to try; outcome sim-gated.**

2. **[Small RTL, high confidence] NWA + S1 re-latch bubble fix.** Implement write-around full-line write-validate (dcache MSHR + store_ack_s1 + CSB completion) **and** fix dcache.sv:291-292 in the same change. Clears **cjpeg** with margin and lifts nnet toward the knee. The S1 fix is mandatory — without it NWA alone is ~flat (verify-confirmed). Validate: lint_unoptflat=15, RV compliance 113 (esp. rv64ua), CM/DS bit-exact at ENABLE=0, boot-clean.

3. **[Modest RTL, medium confidence] Write-combining buffer + measure nnet at the knee.** Collapse 8 same-line stores → 1 L2 write. A sim A/B at ENABLE=1 is the **only** way to resolve nnet's 1.9 vs 2.1.

4. **[Larger RTL, low confidence, knife-edge] Dual store-commit port + S1 redesign for linear_alg/loops.** Only fund if step 2+3 confirm linear_alg/loops still sit ~1.0. This is the all-three-components requirement for sf≈0.5 workloads, and even then it is a zero-margin pass. **Decide AFTER the model is confirmed by sim** — do not build speculatively.

5. **[Modest RTL, gated] Stride/next-line data prefetcher** (drives the existing L2 prefetch port). Fund only after the parser per-phase split + word-wide A/B (step 1) confirm a streaming scan to accelerate. May need throttling on the single-outstanding L1D FSM.

**Explicitly NOT recommended:** multi-outstanding L1D L2 FSM *for the store cluster* (redundant under NWA, `wt_full=0`); runahead/DAE; value/address prediction; larger window/wider issue (all A/B-refuted or near-zero payoff). Multi-outstanding L1D FSM retains *only* a cross-workload argument if the data prefetcher (step 5) is built and demand-contention appears — re-evaluate then.

**Already decided vs needs confirmation:** *Decided by measurement/RTL:* the 1-wide store pipe + S1 bubble (~0.5/cyc ceiling), NWA-as-lever-direction, multi-outstanding-L2 redundancy, parser kernel disasm. *Needs cycle-accurate sim before any IPC is claimed:* every post-lever IPC in the table except the five already-≥2.0 workloads; specifically the nnet knee, the linear_alg/loops knife-edge, and the entire parser path.

---

## 6. Open questions / what to measure next

1. **Post-NWA store-ack rate at ENABLE=1 (the decisive A/B).** Does write-validate ack the *same cycle* the missing store presents, and does the S1 fix actually reach 1/cyc/port? This is the 2.04-vs-1.0 difference. Measure `store_ack_s1` rate on the implemented build.
2. **Parser per-phase split (parse vs traverse).** The 97:3 estimate is *unmeasured*. A marker-bracketed counter discriminates "binary methodology fix" from "documented exception." **Highest-value cheap measurement in the whole program.**
3. **Store fraction stability.** Is sf≈0.49–0.50 across the whole linear_alg/loops region or only the streaming inner loop? If non-streaming stretches are mixed in, the IPC=rate/sf formula is locally optimistic (Amdahl caps the gain).
4. **Full-line vs partial-line/RMW store fraction per workload.** Load-modify-store reverts a line to write-allocate (load-upgrade fallback), re-introducing fills and holding the rate near 0.366 for those lines. Need the in-loop load:store ratio for linear_alg/loops (looked ~pure-store) and nnet/cjpeg (likely more RMW).
5. **Cross-line split-stores + AMO frequency** (lsu.sv:1283-1333, 2 acks each) in linear_alg/loops — any non-trivial fraction breaks the 0.9994/cyc knife-edge.
6. **Secondary re-cap after stores ack at ~1/cyc.** Does SQ-full (82%) actually drop, or does the stall move to commit-width / load-use latency / a residual SQ-full? Need an SQ-*issue* counter, not just SQ-full.
7. **WT/L2 write throughput under combining** — re-measure `wt_occ_max` at ENABLE=1 to confirm the WT queue still sustains 1/cyc once the FSM no longer pauses on fills.
8. **Boot cross-effect.** Kernel page-zero/memcpy are streaming stores ⇒ likely a free NWA win, but must confirm no wedge and the standing **≤0.01% CM/DS no-regression invariant**.

---

*Confidence summary: the five already-≥2.0 workloads and cjpeg's feasibility are high-to-medium confidence (measured/strongly-evidenced). nnet, linear_alg, loops, and parser are LOW confidence — they rest on corrected models that no simulation has yet confirmed at ENABLE=1. The honest headline: **a credible program to all-workloads-2.0 exists, but "all ≥2.0" is not yet demonstrated, and three of five sub-2.0 workloads are marginal or knife-edge.***

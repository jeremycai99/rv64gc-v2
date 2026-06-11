# 3.x-IPC Structural Feasibility Study (2026-06-10)

**Core:** rv64gc-v2, 4-wide OoO RV64GC (shipping config, ER-off, honest suite).
**Inputs:** Studies A–D (READ-ONLY RTL + landed 41-workload `+PERF_PROFILE` sweep, `log/onboard_runs/`) + adversarial verification of all 13 proposals. Builds on `doc/perf_lever_study_2_2026-06-10.md`, `doc/bottleneck_map_41w_2026-06-10.md`, `doc/dse_headroom_map_2026-06-07.md`. No new sims were run for this study.

**Headline answer.** Exactly **two structural mechanisms** can mint new 3.x members, and both are *conditional on one cheap measurement*:

1. **Fetch-through-taken-branch delivery** (decoupled FTQ-runahead frontend, or an FTQ-attached µop-cache loop replayer) — lifts the *supply-bound* subset of the 2.5–2.8 band (rsort, statemate, DS) to 2.9–3.2, **iff** the P0 census proves the ~2.1–2.8 wall is supply-induced rather than chain-saturated.
2. **Multi-outstanding L1D fills** (replace the serial 1-line-in-flight fill FSM) — lifts integer streaming (rsort, memcpy) across 3.0, **iff** the exposed-fill-stall share measures ≥ the required 7–12% of cycles.

Everything else examined — mispredict-recovery latency, re-widening, select width, ROB/PRF capacity, L2 prefetch, L0/victim structures, UOC-as-built — is either a low-band floor-raiser or a verified kill. The one zero-RTL structural lever is a **toolchain bump for Zicond codegen**, which lifts the hammock-mispredict low band by 25–100% relative but stops short of 3.x.

The structural reason 3.x is hard here: the machine has **two co-located ceilings** — effective fetch supply (2.0–2.9 after taken-edge truncation + residual bubbles) and dep-chain completion rate (~2.0–2.5 for 3–4-hop carried chains at the already-optimal 1 cyc/hop). Different mid-band members bind on different sides, which is why every single-side lever measured ~0 suite-wide across five prior cycles. The 128-entry ROB runs ~10% occupied (L≈12); Little's law says 3.x needs a standing window of L≈17–22 at today's residency W≈5.6 — i.e. **~2 more fetch packets in flight, not more capacity**.

---

## 1. The 3.x feasibility map

| Category | Members (IPC) | Binding constraint (named, verified) | 3.x verdict |
|---|---|---|---|
| **At the supply ceiling** | linalg 3.23, vvadd 3.19, edn 3.01, nettle-aes 3.01, nettle-sha256 2.98, sha 2.95 | Fetch truncation ceiling B/⌈B/4⌉ ≈ 3.0–3.3 on big-body loops (nothing in the suite sits between 3.23 and 4.0) | **Already 3.x** (sha/nettle-sha256 within noise). Further growth = width territory — skip (§3). |
| **Supply-side mid-band** | rsort 2.80, statemate 2.65, DS 2.57 (2.73 word-wide) | Taken-edge bubbles u·b (uncovered fraction of predicted-taken redirects) + small standing window L≈12; **premise unproven** — could be chain-saturated instead | **REACHABLE-WITH-STRUCTURE**, conditional on P0 census. G0/G1′ at +5–15%: rsort → 2.9–3.2 (strongest), statemate → 3.05 only at range-top, DS → 3.14 only on ww binary *and* with live-RAS work (call/return-dense — stored RET targets are wrong in a replayer). |
| **Integer streaming** | memcpy 2.61, rsort 2.80 (dual-listed) | Serial L1D→L2 fill engine: 1 distinct line in flight, 10 cyc/line measured (`dcache.sv:640-774`); second serializer = LMB drain ≤1 follower-load/cyc, port-0 only | **REACHABLE-WITH-STRUCTURE** via P1, conditional: rsort 3.0 needs a 6.7% cycle cut, memcpy 2.9 needs ~10% (≈1–2 exposed cyc/fill) — plausible, **unmeasured** (no fill-stall attribution exists for either). Note memcpy is LSU-bound, *not* a frontend-lift beneficiary. |
| **Chain-bound mid-band** | crc32 2.09, cubic 2.02, towers 2.00, sglib 1.47, nnet 2.13, cjpeg 2.09, picojpeg 2.16, wikisort 2.31; CM 2.16 (mixed); zip 2.38 (mixed + 40k indirect misp) | Dep-chain completion rate of -O2 integer mixes; ALU hops already 1 cyc, load-use 1 cyc, mul-use 2 cyc. crc32 specimen: 9–11-cyc loop-carried PRNG chain vs 11.0 cyc/iter measured — fetch needs only 7–9 | **UNREACHABLE via any machinery in this study.** No frontend/window/recovery/select growth moves them. CM ceiling post-frontend ≈ 2.4–2.8 (chain term binds). Only axes: software (chain shortening, -flto, word-wide idioms) or value speculation (unproposed, unscoped). |
| **Streaming FP** | stream-l1 2.25, stream-l2 2.32 | FP cadence cap 0.5 op/cyc + 2-cyc links + single-select IQ2. Proof: stream-l1 (zero L1D misses) runs *no faster* than stream-l2 — fills are near-IPC-neutral today | **Gated on the separately-queued FP campaign.** P1 alone caps stream-l2 at ~2.3–2.4. 3.x only if FP cadence lifts *and* P1 lands. |
| **Mispredict-bound, hammock-shaped** | mont64 1.47 (43% of cycles in misp at P≈8), median 1.31 (58%), multiply 1.05 (21% — primarily *fetch*-bound, rename-zero 36.5% of cycles), slre 2.05 (partial) | Mispredict events × effective P≈8 (2 visibility + 4 pipe + ~2 head-wait/ramp), on branches the compiler *should have* converted — current GCC 13.4 emits **zero** czero despite the `_zicond` march flag (silently inert; Zicond codegen landed in GCC 14) | **NOT 3.x, but the largest floor lift in the study, zero RTL:** Zicond toolchain bump → median 2.3–2.8 (UB 3.09 — closest approach), mont64 1.8–2.3 (select adds to the carried chain — derated from the naive 2.59 UB), multiply ≤ ~1.30 then fetch-after-taken-bound. |
| **Mispredict-bound, loop-exit-shaped** | qsort 1.36 (56%), huffbench 1.53 (45%), parser's branch term | ~1 irreducible mispredict per inner-loop exit × P ≥ 6 (structural minimum 6 cyc resolve-to-corrected-commit, verified cycle-exact). Not Zicond-convertible (exit branches control iteration count) | **UNREACHABLE this generation.** Asymptote ≈ 1.6–2.0; recovery polish (#6 + DQ flow-through) buys 3–8% relative. Moves only with a much shorter total pipeline — not proposed. |
| **Memory-footprint / latency** | parser 0.60; spmv 1.48 | parser: byte-serial string scan (software) + capacity-class L1D misses + program-MLP=1 (window can't hold 2 line-misses at 320–960 instr/line); spmv: actually **mispredict-bound** at suite scale (1 cond misp / 33 instr, LQ-full 0.4%) | **UNREACHABLE.** parser stacked ceiling ≈ 2.0 (ww strings × P1 × P2 × possibly 128KB); honest-binary A/Bs don't exist yet. spmv's memory story is refuted at this dataset size. |
| **FP-subsystem laggards** | radix2 0.92, st 0.89, loops ~1.6 | FP cap 0.5/cyc, 2-cyc links, single-select IQ2 + shared FPU request register | **Out of scope** — the queued FP campaign. (Note: IQ2's limiter is the port-0 suppress chain, *not* select width — §3 item 2 must not be read as killing FP lever #11.) |
| **Needs re-attribution** | nsichneu 1.73, matmult-int 1.91, ud 1.85, md5sum 1.66, minver 1.62, qrduino 1.49 | nsichneu is **NOT** mispredict-bound (3.2% of cycles at P=8, 0.84% branch-miss) — Study II's attribution is dead; the rest are unclassified | Classify in the P0 census pass before assigning any lever. |

**Roster arithmetic:** 6 workloads ≥2.95 today; the structural package can plausibly add **rsort, statemate, memcpy, DS** (up to 10 total) — and *nothing else* on the suite, because every other member has a named non-supply binder.

---

## 2. The gen-2 growth plan (cost-ranked packages)

### Tier 0 — Software/toolchain (zero RTL; cost = qualification + full re-baseline)

**0a. Zicond toolchain bump (GCC 14+ or LLVM 18 suite rebuild).** The march flag is already passed and the ALU already executes czero.eqz/nez at 1 cyc (`alu.sv:283-284`, `decode_slice.sv:472-477`); only codegen is missing. Confirmed convertible sites by disasm: multiply's beqz-over-addw, median's mv-hammock, mont64's xbinGCD parity diamond.
Model: `cycles_new = cycles − misp_cond_removed×P − taken_break_savings + Δinstr/width`, P≈8 (treat as a parameter, calibrate from the A/B — it tensions with Study II's multiply attribution, and the A/B resolves that for free).
Per-category: median 1.31→2.3–2.8, mont64 1.47→1.8–2.3, multiply 1.05→≤1.30. Verdict: needs-measurement, Step-1 gate is hours of work and zero sims (§4.3).
Caveat: czero has never executed in a real workload on this core (FP-bypass-precedent first-use risk, low for plain R-type).

**0b. Binary normalization (word-wide strings, -flto).** Already proven: DS +6% (2.57→2.73), parser parse-phase 1.73×. This is the **only** axis that moves the chain-bound band, and it is a prerequisite multiplier for parser under P1/P2.

### Tier 1 — Instrumentation batch #3 (sim-only, ~30–80 lines, one rebuild, one suite pass) — the gate for everything below

Most of it already exists and prints today (`fetch_frontend_profiler.sv` is bound and compiled in; `frontend_hist`/`macro_fused_*` already in tb_top — fusion is already answered: ~0.01% dynamic coverage on CM, the dormant fusion asset is dead on -O2). Genuinely new: ROB-occupancy histogram × dispatch-starved-with-headroom cross-tab, taken-branch bubble histogram, runahead disqualifier census, per-workload B, DQ-refill root classifier (f), #6 would-have-fired counter, fill/MLP/exposed-stall counters. Full list in §4. **No structural RTL is funded before this lands.**

### Tier 2 — P1: Multi-outstanding L1D fill engine (~150–250 lines, dcache control only)

Replace the blocking `L2_FILL_WAIT` FSM with per-MSHR fill-issued credits, ~8 outstanding into the already-pipelined L2 hit pipe; response side needs zero change (all-MSHR address match already exists, `dcache.sv:1556-1589`). **Simplification found in verification:** the dirty-victim writeback path is dead code (write-through L1D, dirty bits never set) — drop that work item; keep WT>fill priority, per-set victim-way reservation (precedent `l2_cache.sv:344`), respq overflow guard.
Model: gain = **exposed-stall share only** (not channel occupancy — stream-l2's 64.5% occupancy is mostly overlapped, proven by the stream-l1 control), bounded by the LMB ≤1-follower/cyc drain.
Targets: rsort →3.0–3.2, memcpy →2.9 (both conditional, §4.5); stream-l2 →~2.3–2.4 only; spmv direction-right/magnitude-unmeasured; parser only compounds with the ww binary.
Cost is verification, not lines: the NWA same-cycle fill/validate race class previously caused silent corruption (fix 8b536b0) and multi-outstanding fills touch exactly that machinery.

### Tier 3 — G0: Decoupled FTQ-runahead frontend (fetch-through-taken)

The uarch doc's own intended endpoint: F1 walks FTQ-owned predicted blocks independent of F2 — generalize `MAX_DEMAND_RUNAHEAD` 1→4–8, drop the direct-only/owner-delivered/depth-1 qualifiers (`ifu.sv:112, 285-344`), deepen ICQ 4→8.
**Honest cost (corrected):** Reference-Core-B-class refactor, not qualifier deletion — the single pending register becomes a pending queue with per-entry cancel/dup-block/match; request-time RET service needs speculative RAS-at-prediction (doesn't exist — RAS updates at F2 predecode); runahead-chain predictions are BTB-only quality (wrong-path pollution on the single I$ port). Prior depth-1 lever measured +0.25–0.45% on the old frontend; the successor runahead measured +17% — per-event value post-VIPT is the key unknown.
Corrected model: `λ = min(4, B_eff/(ceil_align(B/4) + u·b) − fe_other, R_chain(L))` — b applies only to the uncovered fraction u (today's runahead already converts 88k events/CM10 at 99.6%); fe_other (icache wait 1.9% + recovery 1.8% + dup-suppression ~3.0% + straddle ~2.2% on CM10) is untouched by b=0.
Realistic if the supply-bound premise survives: CM +5–15% (→2.3–2.5), B≥6 predictable members →2.8–3.2. Chain-bound members: 0 by construction. Drop memcpy (LSU-bound) and slre (recovery-bound) from the lifted set.
**Minimal causal probe first:** depth 1→2 with a 2-entry pending queue, qualifiers kept, as an A/B for marginal value per runahead block.

### Tier 4 — G1′: FTQ-attached UOC delivery accelerator (600–1,000+ lines floor; highest ceiling, highest risk)

Corrected architecture from the G1 verdict: the UOC must **not** own next-PC selection — BPU/FTQ keeps generating predicted blocks during replay; UOC supplies decoded µops for FTQ-approved blocks; stored bp_* used as lookup hints only, with **live TAGE direction** per replayed group (the only variant that fixes both 2026-05-05 rejection shapes: checksum divergence *and* mispredict inflation 945→1,411). Mandatory scope additions: ifu.sv (FTQ single-enq-port bypass for replayed entries), bpu.sv (speculative GHR/RAS during replay), satp/SFENCE.VMA invalidation (~2 lines, currently FENCE.I-only — a paged-mode correctness bug as-built), rebuilt unit TB (tb_uop_cache.sv was deleted; "21/21 PASS" is April/6-wide provenance). Area: ~18–20KB compressed data RAM (as-built ~91KB).
Value over G0: B→0 including cold/budget-missed edges, fetch+decode removed from loop steady state, and a re-packing fill re-runs fusion across packet boundaries for free. Only rsort crosses at the +10% midpoint; statemate/memcpy/DS only at range-top.
**Sequencing rule: fund at most one of G0/G1′, adjudicated by the census** — G0 if bubbles are broad and shallow across workloads; G1′ only if loop-resident streaks dominate *and* the offline replay model shows streak-length × per-group gain ≫ restart cost.

### Polish tier — explicitly NOT 3.x levers (fund only on their own counter gates)

- **#6 Branch WB commit-bypass** (~40 lines, rob.sv slots 0/1 — *not* the dead slot-2 blocks): saving per mispredict ∈ {0,1} cyc, upper bounds median →1.41, qsort →1.46; 3–8% relative on the low band.
- **DQ empty flow-through** (enqueue-only variant, realistically 150–300 lines): saves f×1 cyc/refill where f = non-ALU-rooted refills (ALU roots already covered by the enq-issue bypass); joint with #6: `C/(C − (0.5+f)·misp)` ≈ half the naive deltas.
- **P2 L1D stride/NL prefetcher** (~250–350 lines): parser floor only, triple-gated (§4.6); rides P1; redundant with P1 on streams.
- **128KB L1D:** HOLD — one-workload (parser) silicon-expensive lever; re-A/B on the current binary only if parser becomes a shipping requirement.

---

## 3. What 3.x does NOT require (verified skip list)

1. **Re-widening to 6/8-wide rename/dispatch.** Rename width 4.0 exceeds every measured workload (max 3.23); the 6-wide ran at 0.97 CM/MHz-per-slot (CM IPC/slot 0.30) from *frontend starvation*; "6-wide measured worse" is a cross-design datum, no controlled A/B exists or is needed. The A76-class structural gap maps onto this core as **delivery across taken edges** (G0/G1′, an emit-buffer matter), not slots. Note for the do-not-retry list: IQ1 NUM_SELECT=1 *predates* the narrowing (orphaned-ROB-entry correctness fix; port 1 has no FU).
2. **Dual-select IQ1/IQ2.** As-is it is a correctness bug (port-1 selections retire with no FU → orphaned ROB entries, documented at `core_top:2354-2357`); with new EUs it feeds a non-binding constraint (peak issue 8 vs commit 4; execute ≈0.16 cyc/uop). **Scope carve-out:** this does not refute FP lever #11 — IQ2's FP limiter is the port-0 suppress chain + shared FPU request register, not select width.
3. **UOC revival as-is.** Shipping config refuses control and partial groups (cannot shortcut any redirect), holds the frontend during playback, and pays a full fetch flush at every stream exit; 4-µop entries reproduce line-path packetization bit-for-bit. The measured ~0% on 6-wide is the structurally expected outcome. Only the G1′ rework (different design) matters.
4. **Early-redirect un-gate on bare metal.** REFUTED. Ungated-no-suppressor measured CM +3.0%/DS +5.8% *cycles regression* (per-fire quarantine cost > savings when branches resolve near head); the feature was retired default-off at 8a4299e (priv-blind satp gate corrupted Linux boot; the 1.41→2.04 boot win is *withdrawn* — it measured a poisoned udelay spin). RET already passes the rd_valid guard, so the "JALR/CALL extension" adds only ~7–10% of events at checkpoint-restore-correctness cost. Boot asset downgraded to an 18–29%-of-boot-cycles static bound, behind the revisit bar (§4.7).
5. **Bigger ROB/PRF/IQ.** The 128-entry ROB runs at L≈12; 3.x needs L≈17–22 delivered by the frontend, not more capacity. Standing refutation confirmed by occupancy data.
6. **L2 prefetcher.** KILL, sign-inverted: sim memory is 1-cycle, and an L2 *miss* (~3 cyc via mem_resp_direct bypass) is **faster than an L2 hit** (8-cyc hit pipe) — prefetching into L2 has per-line value ≤ 0. The tb memory equals L2 size exactly (compulsory-only misses). Reopen only with a parameterized DRAM model, and re-time the miss path then.
7. **L0/victim cache.** KILL: no latency exists below the 1-cyc L1-hit load-use; parser's misses are capacity/compulsory class (a KB-scale victim covers none of a ~61KB overflow).
8. **Mispredict-recovery latency as a 3.x lever.** The full recovery stack (#6 + DQ + ER) removes ≤~3 of the effective 8 cycles → cluster ceilings ~1.7–2.2. Recovery and Zicond are non-additive on hammocks (Zicond deletes the events recovery shortens).
9. **Standing refutations unchanged:** 0-cyc wakeup, memory-dependence/store-set speculation (addr-unknown∩HEAD_WAIT ~0%), same-line dual-load, PRF/ROB/throttle retries.
10. **ITTAGE.** tarfind's 12%-jalr tail is the suite's only candidate, below the 15–20% build threshold.
11. **Hardware fusion expansion.** Dynamic coverage measured ~0.01% on CM (60 fused µops/159k cyc); -O2 emits native compare-branches. Cross-packet re-packing belongs to G1′'s fill path, not decode.

---

## 4. Measurement gates before any structural commit

All gates are sim-only counters or existing build knobs; fold into instrumentation batch #3 (one rebuild, one `+PERF_PROFILE` suite pass) per experiment hygiene. House discipline applies throughout: counters before RTL, CM/DS finish-at-STOP, ≤0.01% suite no-regression invariant, 113/113 compliance, `+WEDGE_DUMP` boot, `scripts/lint_unoptflat.sh`, synth slack spot-check on any new comb cone.

**4.1 P0 supply census (gates G0 and G1′; two steps).**
Step 1, zero rebuild: read `frontend_hist`/`xs_*`/`macro_fused_*` from the existing binary on the 11 mid-band workloads; compute supply_raw and supply_delivering per workload; first-cut rule: kill frontend levers where supply ≥ IPC + 0.5.
Step 2 (~30 lines, the genuinely new piece): delivered-slots histogram conditioned on backend_stall + ROB-occupancy histogram + dispatch-starved-with-ROB-headroom flag.
**Decision rule:** fund G0/G1′ only where IPC ≈ non-stalled supply AND the window is starved; if ROB-full dominates, the 2.1 wall is chain-saturated and the frontend package is **refuted for the mid-band** — the 3.x roster then grows only via P1.

**4.2 G0-specific (same pass):** (a) taken-branch bubble histogram (work_redirect_o → next emit, split runahead-covered/not); (b) runahead disqualifier census per term of `runahead_candidate_c`; (c) per-workload B (instr per taken branch). **GO:** b̄ ≥ ~0.4 cyc/taken-branch on ≥3 mid-band targets AND starved-with-headroom ≥ ~10%. Then the depth-1→2 causal probe before the full cursor split.

**4.3 Zicond (zero sims first):** compile mont64/median/multiply with GCC 14.x or LLVM 18 at exact suite CFLAGS; objdump the three hot sites for czero/min/max. **0 czero on all three on both compilers → refuted-as-stated.** Else run only the 3 binaries + 2 controls (qsort, nsichneu) A/B on the unchanged core; gates: mont64 ≥2.0, median ≥2.0, multiply ≥1.25, cond-misp counters drop as predicted, controls <2%. Extract effective P from the mont64 pair (calibrates every future branch model). Only then fund toolchain qualification + 41-workload re-baseline.

**4.4 Recovery polish:** #6 — would-have-fired counter (head-blocking branch with matching cdb_r writeback, + slot-1 clone); ship-gate ≥1% of cycles on ≥2 targets. DQ flow-through — f classifier (non-ALU enqueue-ready refill roots, mostly free via the unexported `enq_bypass_fu_blocked_*` signals); gate f×misp/C ≥ ~1% on ≥2 targets.

**4.5 P1:** (A) decisive ceiling proxy, no new RTL — `L2_HIT_LATENCY` 8→2 rebuild, run rsort/memcpy/stream-l2/wikisort/zip/tarfind/spmv; **promote only where this arm clears ≥ half the claimed lift (rsort ≥ ~2.9, memcpy ≥ ~2.75)**; non-movers are refuted as P1 beneficiaries. (B) counters: fill count, channel-busy, distinct-missing-lines-in-LQ at fill-issue (program MLP), commit==0-while-fill-outstanding. **GO:** program-MLP ≥ 2 AND exposed-stall ≥ ~10% on ≥2 of {rsort, memcpy, wikisort, stream-l2}.

**4.6 P2 (parser only):** (1) phase-split via the built parseonly/full + old/ww binary pairs (replaces the unconfirmed 97:3 estimate); (2) honest-binary 2×2 — l2fast × l1d128 (bench dirs exist); (3) ~15-line dcache-side next-line/stride coverability census. **FUND only if** honest l2fast uplift ≥ ~15% AND coverable misses ≥ ~50% AND the 128KB arm doesn't already capture the bulk.

**4.7 ER revisit bar (unchanged from 8a4299e):** (a) priv-aware gating (priv < M AND satp mode), (b) one honest cycles-to-boot_ok A/B; bare-suite reconsideration additionally needs the resolve-to-head-distance histogram mean tail > ~3 cyc on median/qsort/huffbench/mont64. Evidence-based prior: flat-to-negative.

**4.8 G1′-specific (only after 4.1/4.2 pass):** offline replay model of the 32×8 cache against captured fused-group traces — median streak length × per-group gain ≫ the ~4-cyc restart cost, and capacity re-validation under set-conflict skew. Then the full validation ladder: endpoint-exact CM/DS, 113/113, `+WEDGE_DUMP` boot, GHR/RAS equivalence checks.

**Bookkeeping commits with this study:** record the corrected width do-not-retry paragraph (§3.1 wording incl. the IQ1 NUM_SELECT provenance fix); update Lever Study II's multiply attribution (fetch-bound, not misp ~5–6 cyc/iter); drop nsichneu from the mispredict cluster; mark the fusion dormant asset answered-dead; note `parser`'s bound class as memory/binary, not mispredict.

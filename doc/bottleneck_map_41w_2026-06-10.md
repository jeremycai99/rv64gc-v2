# 41-Workload Bottleneck Map (2026-06-10)

Evidence pass over the 41-workload +PERF_PROFILE sweep (`/tmp/prof_<workload>.log`), shipping config (NWA + store no-bubble ON, FPU output-port fix, ER off). Resolves the measurement gates defined in `doc/perf_lever_study_2_2026-06-10.md` §3 (Phase-0 item 2). Spot-verified against the raw logs (parser `lsu_lmb_wb_blocked` 253,933, Fill matches 7,737,137; linalg 4,060,404; stream-l2 295,010 / 598,223 — all match).

**Run-validity legend:** †TIMEOUT cycle-cap steady-state sample (not run-to-STOP); ‡startup-scale micro-run (percentages carry large small-N error); ✗invalid run. All other logs PASS at tohost=1.

---

## 1. Bottleneck map

### Cluster: memory-irregular — verdict: only parser is genuinely memory-bound

| Workload | IPC | Binder | Decisive counter | Lever |
|---|---|---|---|---|
| parser-kernel-direct † | 0.603 | L2-fill FSM serialized at MLP≈1 — head-wait IS fill latency; LQ saturation is the dispatch echo | 7,772,282 new-line allocs ≈ 7,737,137 fills in 120M cyc = 1/15.4 cyc; ×10-cyc fill period = 64.5% of runtime ≈ MEMDEP headwait 65.70%; LQ-at-gate 68.9% | **#2 sub-fix A** (+2–3% derated, 12.9% gross); B≈0 (spacing 15.4 > 10-cyc period); **#8 KILLED** (blocked 0.21%) |
| rvb-spmv | 1.481 | FP accumulate chain at ROB head + 32.3% cond mispredict | other-class head stall 16,092 = 38.3% of cyc; 1,892/5,864 cond misp = 1 flush/22.2 cyc | #2 marginal (1 fill/50.8 cyc); FP campaign secondary |
| rvb-qsort | 1.359 | Mispredict primary (20.4% cond, 1 flush/14.4 cyc); L1-hit load-use secondary | 11,562/56,768 cond misp; 259 new-line misses/166k cyc (1/641); ~9.5-cyc bubble → ~66% of cyc | #6 (derated); NOT #2/#8 |
| embench-sglib-combined | 1.467 | Mispredict (19.0% cond + 9,480 RAS) + L1-hit pointer-chase chains | 29 new-line allocs total in 1.85M cyc; 113,022 flushes = 1/16.4 cyc; sqblock&hw only 0.78% | #6; **DROP from #2 beneficiary list** |
| embench-huffbench | 1.533 | Cond mispredict 17.9% (value-dependent tree-walk) + L1-hit chains | 17 new-line allocs total / Fill matches 16 in 1.6M cyc; 89,941/502,497 misp = 1 flush/17.8 cyc | #6; **DROP from #2 beneficiary list** |
| rvb-median ‡ | 1.313 | Mispredict 21.5% — hot branch is a structural coin flip (398 taken/398 not-taken, untrainable) | 574/2,664 cond misp = 1 flush/13.9 cyc; window arithmetic → ~9.3-cyc bubble | #6 (mostly irreducible); the 5.80% LMB-blocked figure is a cold-start artifact (7,988-cyc run, 190 LMB allocs) — NOT a #8 signal |

### Cluster: fp-laggards

| Workload | IPC | Binder | Decisive counter | Lever |
|---|---|---|---|---|
| radix2-big-64k ✗ | 0.922 | **INVALID — exception/trap livelock** (harness/binary defect), not an FP datapoint | 0 loads committed in 100M cyc; 9,895,124 exceptions = 1/10.11 cyc in lockstep with iq2 issued 9,895,128; 99.99% of headwait at PC 0x80000064 | Fix the run BEFORE radix2 can gate #7/#10/#11 |
| embench-st | 0.891 | FP completion latency through single-select IQ2 — canonical #7 profile; memory exonerated | iq2_full 77.4%, arb_loss 91.9% of cyc, FP issue 0.33/cyc vs 0.5 cap; 9,056/9,077 load WBs are 1-cyc hits | **#7** (gate: Phase-2 FP partition + uoplife f) |
| loops-all-mid-10k-sp † | 1.506 | Mixed: SQ/forwarding coupling + LQ-full + real miss component + IQ2 congestion — NOT pure FP | sqblock 22.19% (&hw 8.57%), sq_fwd_wait 20.3%, lq_full 19.5%, CSB deq_wait 16.1%, 2.78M LMB-serviced loads | FP-campaign **mandatory canary** (now explained); #8 kill here (0.81%) |
| embench-cubic | 2.020 | FP at head (libm, div/sqrt-suspected) + 11.4% mispredict secondary | 88.2% of head samples 'other'; 12,980 flushes = 1/48 cyc; 66 LMB loads total | **#4** candidate — gate (FDIV occ ≥5%) UNRESOLVABLE with existing counters |
| embench-minver | 1.618 | FP completion (74.8% 'other') + genuine SQ-forwarding coupling | 12.0% of load results SQ-forwarded, sq_fwd_wait 10.2%, sqblock 10.39%; 7 LMB loads (cache clean) | #4 candidate (gate unresolved) |
| embench-ud | 1.850 | Pure latency/ILP: long-latency IQ2-class (div) producers + 12.7% mispredict; zero structural backpressure | ALL structural stall counters = 0, IQ avgs ≤0.96; 50,393 flushes = 1/29 cyc | Needs Phase-2 FDIV/IDIV split before any lever claims ud |
| embench-nbody ‡ | 0.737 | FP-subsystem (st signature) — LOW CONFIDENCE, 2,178 committed instr | headwait 63.25%, 90.7% 'other', iq2_full 36.0%, arb_loss 53.8% | #4 motivator; needs a longer run to gate |
| nnet-kernel-direct | 2.128 | LQ-full backpressure coupled to FP-gated commit rate (LQ-free-at-commit) | lq_full 32.8% with 98% 1-cyc load hits; LQ in 24–31 band 60.0% of cyc; IQ2 full 36.3%, arb_loss 61.0% | **#10/#7** motivator (sizing unresolved); #8 kill (0.06%); CSB enq_stall 4.2% secondary |

### Cluster: mispredict-suspects — 5/7 confirmed, picojpeg partial, nsichneu REFUTED

| Workload | IPC | Binder | Decisive counter | Lever |
|---|---|---|---|---|
| rvb-multiply | 1.050 | Branch-resolution-bound on a random bit (16.4% misp despite TAGE hit) + serial shift-add feeder chain | PC 0x800020c4: 1,052 misp/6,399 updates; branch-class head stall 13,817 = 29.6% of cyc; 1,224 flushes ×~9.5 cyc ≈ 25% | Irreducible; hammock fusion stays refuted; memory clean (21 store miss allocs) |
| embench-nsichneu | 1.733 | **Mispredict REFUTED** — front-end fetch-packet fragmentation (branch every ~3.6 instr) delivers 1.81 instr/cyc | misp rate 0.84%; redirect recovery 0.4% of cyc; fetch≥4 only 4% of cyc; frontend_hold=0; 446K load-at-head cyc with 0 new misses | Front-end packet-formation lever (none in queue); remove from misp beneficiary sets |
| embench-slre | 2.053 | Mispredict (8.76%, nested/backtracking speculation) | 38,295 flushes ×~9.5 cyc ≈ 29% of cyc; 56,317 CDB misp slots vs 38,295 committed flushes (~18K squashed-nested) | **#6** (~1–2%) |
| embench-tarfind | 2.081 | Mispredict incl. indirect (1,551 jalr/ITTAGE + 1,551 jal) + div-at-head 8.2% + SQ occupancy | 12,742 flushes ≈ 25% of cyc; deepest squash profile (age sum 389,760); sqblock 23.75% but &hw 0.41% | #6; sqblock does NOT displace misp attribution |
| embench-picojpeg | 2.160 | PARTIAL — misp ~13.4% of cyc; dominant = dep-chain completion (unknown head 15.2% + mul 4.0%) + non-misp fetch holes | only 23,495 of 365,841 fetch=0 cyc (6.4%) are redirect recovery; 152.7 instr/flush | #6 derated ~0.5–1% (consistent with study) |

### Cluster: mid-band — dep-chain completion rate confirmed 11/12; one memory outlier (zip)

| Workload | IPC | Binder | Decisive counter | Lever |
|---|---|---|---|---|
| coremark_iter10 | 2.160 | Dep-chain completion rate (width utilization); modest 5.80% misp tax | headwait 6.62% (matches archived 6.65%); 53 miss detects, 14 LMB-blocked cyc in 1.48M | None memory-side; #6 minor |
| dhrystone | 2.574 | Dep-chain (documented byte-wise strcpy/strcmp binary) | headwait 10.54% (matches archived 10.49%); sqblock 11.63% but &hw 1.46%; 16 load misses | Software (word-wide strings), no RTL |
| zip-kernel-direct † | 2.377 | **OUTLIER: D-cache miss + LMB writeback-port bound** — not dep-rate | LMB WB blocked 3,315,339 = **3.32%** (clears #8 fund gate); 4.15M miss detects; CSB deq_wait 20.0%, worst run 108 cyc; wt_full 55,747 | **#8 (rescoped)**; reclassify out of dep-rate band |
| embench-crc32 | 2.091 | Pure serial chain (load→xor→shift per byte) | sqblock raw count = 2, addrunk = 1; 43 miss detects; 14 misp; headwait 18.18% IS the chain | None — irreducible |
| embench-wikisort | 2.312 | Dep-chain + 14.7% mispredict co-binder | headwait 10.38%; 25,597 flushes = 1/~35 cyc; 339 miss detects | #6 co-beneficiary |
| rvb-rsort | 2.800 | Width underutilization on ready work — cleanest confirmation | headwait 1.76% (band minimum); sqblock 5.46% with &hw exactly 0.00 | None; LMB 2.07% sits between #8's kill/fund gates |
| embench-statemate | 2.652 | Dep-chain; heavy store traffic proven fully hidden | sqblock 16.70%/addrunk 16.18% with &hw = **0.00**; 0.69 store acks/cyc yet SQ cyc_at_gate=0; 1 load miss | None; strongest store-set kill evidence |
| cjpeg-kernel-direct | 2.087 | Dep-chain (DCT mul-add) + 13.2% mispredict | 1,404,115 flushes = 1/~40 cyc; store port_wait 4.36% only memory note; LMB 0.44% | #6; watch store port post-NWA |
| embench-md5sum | 1.661 | Serial add/rotate chain + 17.6% mispredict (chain+branch mix) | headwait 22.69%; 52,646 flushes = 1/~30 cyc; 57 miss detects, 12 LMB-blocked | #6; 3-input-ADD fusion stays refuted |
| embench-matmult-int | 1.906 | MUL + load-use inner-product chain — purest long-latency-chain datapoint (memory AND misp both excluded) | headwait 24.56% (band max) with 284 miss detects, 93 LMB-blocked, misp only 3.1% | **#5/#9 gate population** |
| embench-aha-mont64 | 1.468 | MUL-dependent chain (17-cyc) COMPOUNDED by 21.9% mispredict | 3 load misses, 0 LMB-blocked, 1,062 stores/2.14M instr (register-resident); 78,972 flushes = 1/18.5 cyc | **#5 primary** — uoplife gate must net out the misp co-binder first |
| embench-qrduino | 1.493 | Mispredict-heavy (28.5% = band max, 1 flush/18.8 cyc) + GF chains | 125,546 flushes; addrunk&hw 1.01% = band's highest overlap, still ~1% | #6; store-set refuted at its worst case |

### Cluster: streaming-compute — store path post-NWA healthy in all 10 logs

| Workload | IPC | Binder | Decisive counter | Lever |
|---|---|---|---|---|
| stream-l1 | 2.249 | L1-hit load-use + FP-add chain; startup-skewed short run | 81.4% load WBs dchit at 1–2 cyc; head-load 18.0% of cyc; fill_ack=1, wt_full=0 | None |
| stream-l2 | 2.322 | L2-fill queueing exposed through LQ — but MLP covers it (IPC EXCEEDS stream-l1) | 88.4% load WBs via LMB; hot PC 0x8000273a avg_lat 29.32 vs 8-cyc L2 hit; LQ-at-gate 38.2%; 1 fill/13.6 cyc = 73% of FSM cap | **#2 sub-fix B** funded at LOW end of 0–3%; #8 secondary (3.62%) |
| sha-kernel-direct † | 2.946 | Integer ALU chain (rotate/xor) at commit width; fully memory-clean | 46 cond misp in 206M instr; 72,256 new fills/70M cyc; LMB blocked 5 cyc | None |
| linear_alg-kernel-direct † | 3.232 | Cond mispredict (2.97 MPKI ≈ 10% of cyc) + **LMB port-0-only drain serialization** | 576,200 misp conditionals; lsu_lmb_wb_blocked 4,060,404 = **6.77%** — only at-scale #8 fund-gate hit; 1.25M merged-load wakeups drain 1/cyc | **#8 FUND target**; #6 minor |
| rvb-vvadd ‡ | 3.191 | Cold-miss fills on a 2,127-cyc run; already near width limit | ~60 cold fills; LMB blocked 36.8% = cold transient, NOT a #8 datapoint | None |
| rvb-memcpy ‡ | 2.607 | Cold-miss fills both copy legs; NWA showcase | 253 fills/10,679 cyc; 6 hit acks, 0 fill acks, 20 wait_fill | None |
| embench-edn | 3.011 | MUL completion at head + store S0-lookup arbitration | mul-at-head 35,241 = 3.3% of cyc (only direct mul datapoint — below #5 gate); port_wait 22,809 | #5 reference point |
| embench-nettle-aes | 3.009 | L1-hit dependent T-table lookup chain (load→xor→index→load) | head-load 195,672 = 14.9% of cyc with 197 new fills/1.31M cyc — every stall a HIT | None — irreducible 1-cyc load-use |
| embench-nettle-sha256 | 2.975 | Balanced ALU-chain + load-use ready-rate — purest ~3.0-band member | head split 63,270 load / 63,760 unknown; max contiguous head wait 10 cyc; 4 new fills | None |
| rvb-towers ‡ | 1.998 | SQ store-to-load through recursion stack (startup-scale) | sqblock 29.31%/addrunk 19.17% (15× cluster next) with &hw 0.49% — never reaches head | None; not a steady-state datapoint |

---

## 2. Resolved gates

| Gate (study §3) | Verdict | Decisive numbers |
|---|---|---|
| **#8 LMB port-1 drain** — kill if parser <1%, fund if ≥3% | **KILL as specified** (parser-keyed); fund only if **re-scoped to linear_alg (+stream-l2/zip)** | parser 253,933/119,999,961 = 0.21%; spmv 2.11%; qsort 1.84%; **linalg 6.77%** (only at-scale hit); stream-l2 3.62%, zip 3.32%; sub-gate: rsort 2.07%, loops 0.81%, nnet 0.06%. median's 5.80% = cold-start artifact. Per Phase-3 note: re-size after #2A lands |
| **#2 L2-fill FSM operating point** | **CONFIRMED**: A live on parser (+2–3%); B≈0 on parser (MLP≈1); B funded LOW end on stream-l2; **drop sglib/huffbench (and effectively qsort)** | parser: 7,772,282 allocs ≈ 7,737,137 fills = 1/15.4 cyc; 64.5% of runtime ≈ headwait 65.70%; spacing 15.4 > 10-cyc period → no chaining window. stream-l2: 1 fill/13.6 cyc = 73% of cap, IPC 2.322 > stream-l1 2.249 (no residency deficit; queueing tail only). spmv 1/50.8 (marginal stands); qsort 1/641; sglib 29 / huffbench 17 new lines total |
| **Per-type mispredict attribution** (multiply/median/qsort) | **CONFIRMED** (nsichneu refuted — see §3); adds spmv 32.3% | multiply 9.3% w/ PC 0x20c4 at 16.4% despite TAGE hit; median 21.5% w/ 398/398 coin-flip PC; qsort 20.4%, 1 flush/14.4 cyc; cross-run inferred flush bubble ~9.3–9.5 cyc |
| **Mid-band dep-chain-rate hypothesis** | **CONFIRMED on the memory axis 11/12**; literal "<10% headwait" form holds only for the upper half; zip is a memory outlier; misp co-binder dominates the band floor | Upper half: rsort 1.76 / statemate 5.67 / CM 6.62 / wikisort 10.38 / dhry 10.54%. Lower half 15.97–24.56% with memory affirmatively excluded. Floor misp: qrduino 28.5%, mont64 21.9%, md5sum 17.6% |
| **Store-set / memory-dependence speculation** | **STAYS REFUTED at every operating point** | sqblock&hw max = sglib 0.78%; addrunk&hw max = qrduino 1.01%; statemate: sqblock 16.70% w/ &hw 0.00; tarfind 23.75% w/ &hw 0.41% |
| **Post-NWA store-path health** | **CONFIRMED healthy** — held-until-fill dead, no WT backpressure | fill_ack ≤2 everywhere (8 of 10 logs = 0); stream-l2 97.6% acks via write-around; wait_fill ≤0.47% except stream-l2 3.17% (transient NWA-accept arbitration); wt_full ≈0; LMB re-probe fires = 0 in all 10 |
| **#6 sizing via existing counter** | **CONFIRMED structurally impossible** — Phase-2 counter remains required | "Same-cycle WB ready bypass candidates: branch" = 0 on all 7 mispredict-cluster logs |

---

## 3. Contradictions / surprises

1. **radix2 run INVALID** — exception/trap livelock: 0 loads committed in 100M cyc, 9,895,124 exceptions (1/10.11 cyc) lockstepped with iq2 issued, 99.99% of headwait at PC 0x80000064, tohost never written. The study's "radix2 0.92, ~0.32 FP ops/cyc, latency/slot-bound" claim is NOT supported by this log (0.099 IQ2 ops/cyc). Harness/binary must be fixed before radix2 can gate #7/#10/#11.
2. **nsichneu mispredict attribution REFUTED** — 0.84% misp rate, redirect recovery 0.4% of cyc. Real binder: fetch-packet fragmentation (fetch ≥4 only 4% of cyc → 1.81 instr/cyc effective vs IPC 1.73, frontend_hold=0) + L1-hit load-use (446K load-at-head cyc, 0 new misses). Remove from all mispredict-lever beneficiary sets.
3. **#2 beneficiary list partially wrong** — sglib (29 new lines/1.85M cyc) and huffbench (17/1.6M) measured-refuted; qsort effectively out (1 fill/641 cyc); spmv "marginal" stands.
4. **#8 beneficiary list inverted** — the doc's beneficiaries (parser/linalg/spmv/qsort) split: parser 0.21%/spmv 2.11%/qsort 1.84% sub-fund, while linalg 6.77% clears — and the two strongest secondary signals (stream-l2 3.62%, zip 3.32%) were not in the lever table at all. If built, #8 is a linalg/stream-l2/zip lever, not a parser lever.
5. **Counter fidelity** — `bpu_dyn_total` misp undercounts vs commit flush-cause on large-footprint runs (slre 5,955 vs 38,295; tarfind 2,905 vs 12,742; finite tracked-PC table). The COMMIT FLUSH-CAUSE BREAKDOWN is authoritative; never gate a lever on bpu_dyn totals.
6. **Mid-band "<10% headwait" literal prediction fails on the band's lower half** (crc32 18.18% … matmult-int 24.56%) — but with memory excluded the headwait IS the chain reaching head unfinished; same binder, threshold form should be restated in the doc.
7. **zip contradicts the mid-band label** — memory-bound outlier (4.15M miss detects, LMB blocked 3.32%, CSB deq_wait 20.0%, wt_full 55,747); reclassify.
8. **loops is not a pure FP-laggard** — sqblock 22.19% (&hw 8.57%), lq_full 19.5%, sq_fwd_wait 20.3%, 2.78M LMB-serviced loads. This is WHY it is the mandatory FP-campaign canary: suppress-chain changes perturb a store/LQ-coupled machine (consistent with P1's measured −40%).
9. **Run-validity caveats** — parser/zip/loops/sha/linalg end at TIMEOUT cycle caps (steady-state samples); vvadd (2,127 cyc), memcpy (10,679), towers (4,101), median (7,988), nbody (2,955) are startup-dominated — do not treat their percentages (incl. vvadd's 36.8% LMB-blocked, towers' 29.31% sqblock) as steady-state datapoints.

---

## 4. Implementation order (merged with lever-study §3 queue)

**Phase 0 — DONE.** Item 2 (this sweep read) is resolved; item 1 (doc/model corrections) proceeds as written, plus the §3 restatements above (mid-band threshold form, #2/#8 beneficiary corrections, zip reclassification, nsichneu).

**Phase 1 — build now (gates cleared):**
1. **#2 sub-fix A** (L2 IDLE comb-assert) — fully funded by parser (7.74M firing opportunities, 12.9% gross / +2–3% derated). Then **B** behind the same review with the `l2_active_mshr_q` mask — expectations reset to the LOW end of 0–3%, stream-l2 only (parser B≈0 at MLP≈1). Gates unchanged: `scripts/lint_unoptflat.sh`, full bench, +WEDGE_DUMP boot.
2. **NEW, promoted: fix the radix2 harness/binary** (trap livelock — likely a faulting instruction with a software handler). No RTL; blocking prerequisite for every FP gate (#7/#10/#11). Cheap and on the critical path of Phase 2.

**Phase 2 — one instrumentation rebuild + one +PERF_PROFILE pass (unchanged from study, with target updates):**

3. **Instrumentation batch (#3)** — full list in §5. Same pass: `tools/uoplife_critical_path.py` on **(valid) radix2**, st, aha-mont64; +ROB_COMMIT_WB_BYPASS ceiling A/B on sha/nettle/edn/linalg/vvadd + CM guard. **Add a longer-iteration nbody run** to the pass.
4. **Root-cause the P1 loops 1.63→0.98 collapse** — hard gate for the FP campaign, unchanged; this sweep strengthens the mandate (loops measured as store/LQ-coupled).

**Phase 3 — measured RTL, gated order (updated):**

5. **#4 divsqrt bump** if FDIV occupancy ≥5% on cubic/minver/nnet/nbody — beneficiary set intact; cubic now carries a measured 11.4%-misp secondary, so derate expectations.
6. **#5 MUL sideband** if mont64 mul-edge critical-path share ≥ ~8% **after netting out the measured 21.9% mispredict co-binder** (1 flush/18.5 cyc — first-order, must be separated by uoplife). matmult-int (24.56% headwait, misp 3.1%) is the cleaner confirmation target; edn's 3.3% mul-at-head is the floor reference. Fallback #9 unchanged.
7. **#6 branch WB commit-bypass** if the new counter shows ≥1% on ≥2 targets — beneficiary set updated: slre, tarfind, picojpeg, CM **+ band floor qrduino/mont64/md5sum/wikisort/cjpeg + qsort/median/sglib/huffbench**; **remove nsichneu**. The ~9.3–9.5-cyc measured flush bubble vs the 1-cyc recoverable slice keeps the derated ~0.5–2% estimate honest.
8. **FP campaign #10 → #7 → #11**, each gated on its Phase-2 counter, loops as mandatory canary (justification now measured), 113/113, cycle-exact CM/DS, ≤0.01% suite invariant. nnet is the new #10 motivator (lq_full 32.8% with 98% 1-cyc hits = commit-rate-coupled). If divsqrt-parking dominates the partition, ship only the IQ2 class-gating mini-lever.
9. **#8 LMB port-1 drain** — last among memory levers, **re-scoped to linear_alg/stream-l2/zip** (parser kill stands); re-size after #2A and the word-wide-strings parser binary, both of which shrink its share.

---

## 5. Unresolved — Phase-2 instrumentation list

| Gate | Needs |
|---|---|
| #4 divsqrt (FDIV/FSQRT occ ≥5% on cubic/minver/nnet) | FDIV/FSQRT occupancy counters — nothing in cubic (88.2% 'other'), minver (74.8% 'other' + 12.0% SQ-forwarding), or nbody separates div/sqrt parking from FMA chains; nbody also needs a longer run (2,178 instr, cold-cache) |
| #7 FP fall-through (f ≥40–50%) | uoplife_critical_path.py on radix2/st/mont64 + FP cycle partition (suppressed-w/-int-work / FP-bandwidth / FP-chain / divsqrt-parking); **valid radix2 re-run**; P1 loops root-cause (hard gate). st is consistent with #7 but cannot split chain-latency vs cadence-cap vs div-parking |
| #10 dedicated FP writeback (theft ≥3–5% of cyc) | FP-dest theft-with-work-waiting counter + commit-width histogram; nnet motivates but cannot size |
| #11 FP issue queue | 4-way cycle partition on (valid) radix2 + loops; loops head-PC sample covers only ~6% of its 33.13% headwait |
| #5 MUL sideband (mont64 mul-edge ≥ ~8%) | uoplife mul-edge share + mul camp counters; must separate the 21.9% misp co-binder; edn's 3.3% is below gate |
| #6 branch WB bypass (≥1% on ≥2 targets) | New head-blocking-branch-lag counter — existing counter proven structurally zero on all 7 logs |
| #9 CDB[2] MUL-yield (camp ≥0.5–1%) | Mul camp counters: `alu2_issue && mul_valid_live`, `mul_hold_valid_r` cycles, `mul_enqueue_fresh` |
| (carry-over from #3) | Slot-2 fire counters moved out of the `!ready_r[head_r]` guard; `p1_fwd_blocked` counter; flush-terminated commit groups bucketed separately |

Known dump blind spots (cannot be read from existing counters): mispredict-shadow vs load-use overlap, squash cost in cycles (only uop-age sums), the untyped 'unknown'/'other' head-stall class, int-div vs FP-div on IQ2, and ptw_busy_cycles (known-broken stuck flag).

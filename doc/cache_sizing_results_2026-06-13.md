# Cache-Sizing DSE — Results (2026-06-13)

Decision readout for the L1D × L2 balance-point study planned in
`doc/cache_sizing_dse_plan_2026-06-11.md`, against the user's PPA acceptance bar
(≤3–4% suite perf cost is a good trade for the 2M→1M area saving ≈20–25% of die,
2M→512K ≈30–37%). Binders/mechanism: `doc/perf_scoreboard_2026-06-13.md`;
sim-memory 1-cycle artifact (now fixed by the `+MEM_LATENCY` model) caveat:
`doc/ipc3x_gate_results_2026-06-11.md` §5. Data: `log/cache_sweep/<arm>/<wl>.log`,
re-extracted with `log/cache_sweep/extract_sweep.py`; analysis `/tmp/cache_dse_analyze.py`.

**READ-ONLY snapshot.** A detached sim pool (PID 2111341) is still draining the
last arms; this report is completable as logs land — every pending cell is marked.

## 0. How to read this — PASS vs TIMEOUT metric

Most capacity-discriminating kernel-direct members **TIMEOUT** at L=80 (they do
not reach `tohost` in the 30–60M-cycle budget). The comparison metric is therefore
split, by construction:

- **PASS↔PASS rows** → **cycle ratio** (`base_cyc / arm_cyc`); >1.00 = arm faster.
- **TIMEOUT↔TIMEOUT rows at the same cycle cap** → **instret-ratio-at-cap**
  (`arm_instret / base_instret`); more work in the same budget = faster.
- **mixed PASS/TIMEOUT** (only stream-l2: base PASSes, 512K arms TIMEOUT) →
  **IPC-rate ratio** (`arm_IPC / base_IPC`), the rate-of-work invariant across
  different end points. (Reduces to the other two when caps/end-points match.)

All TIMEOUT-derived numbers are *at-cap, perf-only* — admissible for ratio
comparison, not for absolute-IPC claims (per the scoreboard "cap" convention).

## 1. PPA table per arm (L=80 decision point, vs 2m-64k baseline)

10-member L=80 set: coremark_iter10, dhrystone, embench-tarfind, embench-wikisort,
cjpeg-kd, linear_alg-kd, parser-kd, sha-kd, stream-l2, zip-kd.
`cost% = (1/geomean − 1)·100` = suite slowdown.
Data RAM KB = L1D+L2 data SRAM; tag KB is the SRAM tag/valid/dirty overhead
(separate column — leakage scales with the sum). User bar = ≤3–4% cost.

| arm | L2/L1D/lat | data KB (Δ vs 2M) | tag KB | geomean ALL | geomean **real-app** (no stream) | cost real-app | worst real-app member | rows >1% slower | bar ≤3–4% |
|---|---|---|---|---|---|---|---|---|---|
| **2m-64k** (base) | 2M/64K/8 | 2112 (—) | 198.5 | 1.0000 | 1.0000 | — | — | — | — |
| 512k-32k | 512K/32K/8 | 544 (−74.2%) | 53.3 | 0.8144 | 0.9697 | **+3.12%** | linear_alg −13.8% | 5† | borderline |
| 512k-64k | 512K/64K/8 | 576 (−72.7%) | 56.5 | 0.8311 | **0.9919** | **+0.81%** | sha −4.40% | 2 (sha, zip) | **PASS** |
| 512k-128k | 512K/128K/8 | 640 (−69.7%) | 63.0 | 0.8311 | **0.9919** | **+0.81%** | sha −4.40% | 2 (sha, zip) | **PASS** |
| **512k-64k-lat5** | 512K/64K/5 | 576 (−72.7%) | 56.5 | 0.8472 | **1.0130** | **−1.28%** (net win) | sha −4.37% | 2 (sha, zip) | **PASS** |
| 512k-128k-lat5 | 512K/128K/5 | 640 (−69.7%) | 63.0 | 0.8472 | **1.0130** | **−1.28%** (net win) | sha −4.37% | 2 (sha, zip) | **PASS** |
| 1m-64k *(PARTIAL 5/10)* | 1M/64K/8 | 1088 (−48.5%) | 104.5 | 0.9973 | 0.9973 | +0.27% (partial) | zip −1.34% | 1 (zip) | **PASS** (so far) |
| 1m-64k-lat6 | 1M/64K/6 | 1088 (−48.5%) | 104.5 | — | — | — | — | — | **PENDING** |
| 1m-128k | 1M/128K/8 | 1152 (−45.5%) | 111.0 | — | — | — | — | — | **PENDING** |
| 1m-32k | 1M/32K/8 | 1056 (−50.0%) | 101.3 | — | — | — | — | — | **PENDING** |
| 2m-32k | 2M/32K/8 | 2080 (−1.5%) | 195.3 | — | — | — | — | — | **PENDING** |
| 2m-128k | 2M/128K/8 | 2176 (+3.0%) | 205.0 | — | — | — | — | — | **PENDING** |

† 512k-32k "5 rows >1%" is dominated by 32K-L1D effects (linear_alg −13.8%,
cjpeg −1.07%), not L2 capacity — see §4. **Note on the geomean ALL column:** it is
crushed to ~0.81–0.85 purely by the stream-l2 canary (−83%); the **real-app
geomean is the decision basis** (§2).

**Per-member L=80 speed-ratio matrix** (>1.00 = arm faster; `--` = pending):

| workload | metric | 512k-32k | 512k-64k | 512k-128k | 512k-64k-lat5 | 512k-128k-lat5 | 1m-64k |
|---|---|---|---|---|---|---|---|
| coremark_iter10 | cyc | 1.0000 | 1.0000 | 1.0000 | 1.0002 | 1.0002 | 1.0000 |
| dhrystone | cyc | 1.0000 | 1.0000 | 1.0000 | 1.0062 | 1.0062 | 1.0000 |
| embench-tarfind | cyc | 1.0000 | 1.0000 | 1.0000 | 1.0000 | 1.0000 | 1.0000 |
| embench-wikisort | cyc | 1.0000 | 1.0000 | 1.0000 | 1.0000 | 1.0000 | 1.0000 |
| cjpeg-kd | cyc | 0.9893 | 1.0000 | 1.0000 | 1.0015 | 1.0015 | -- |
| linear_alg-kd | instret@cap | 0.8623 | 1.0000 | 1.0000 | 0.9996 | 0.9996 | -- |
| parser-kd | instret@cap | 0.9680 | 0.9991 | 0.9991 | **1.1934** | **1.1934** | -- |
| sha-kd | instret@cap | 0.9560 | 0.9560 | 0.9560 | 0.9563 | 0.9563 | -- |
| stream-l2 | IPC-rate | 0.1692 | 0.1692 | 0.1692 | 0.1695 | 0.1695 | -- |
| zip-kd | instret@cap | 0.9603 | 0.9735 | 0.9735 | 0.9770 | 0.9770 | 0.9866 |

Observations: at L1D≥64K the L2-capacity effect saturates — **512k-64k and
512k-128k are bit-for-bit identical** across every member (the extra 64K of L1D
buys nothing the 512K L2 doesn't already cover; 128K L1D also doubles ways/area
for zero return). The lat-scaled arms add a uniform parser windfall on top.

## 2. The stream-l2 caveat — handled honestly

**stream-l2 at 512K = 0.392 IPC vs 2.317 at 2M (−83.1%).** This is the synthetic
L2-bandwidth canary: the array is deliberately sized **L2-resident**, so dropping
the L2 below the footprint converts every steady-state hit into a refill and the
kernel TIMEOUTs (12.94M instret at the 33M cap vs an 8.17M-cycle PASS at 2M). It is
**not a real-application signal** — it exists to expose the L2-fill path, and it
does. Two consequences, reported both ways:

- **geomean ALL (with stream-l2):** 512K arms 0.81–0.85 → "+18–23% cost". This is
  the canary swamping the suite and is **not** the decision basis.
- **geomean real-app (stream-l2 excluded):** 512K arms **0.99–1.01 → +0.81% / −1.28%**.
  This is the correct basis: stream-l2 is a microbenchmark whose footprint is
  hand-tuned to whatever L2 you build, so including it just measures "did you
  shrink the L2," not "does it cost real applications." The real-app rows are nine
  actual kernels with real footprints.

**Decision basis = the real-app geomean.** Note this is the same row triple-claimed
in the gate doc (FP-cadence / fill-levers / P1) — its capacity sensitivity is a
*known* artifact of array sizing, not a generalizable capacity wall.

### Every other genuinely capacity-sensitive row (footprint-vs-capacity)

| member | 512K cost (cap-only, lat8) | story | latency-recoverable? |
|---|---|---|---|
| **sha-kd** | **−4.40%** | working set spills 512K; lat5 → −4.37% (flat) | **No** — pure capacity. The one true real-app capacity casualty. |
| **zip-kd** | **−2.65%** | mixed: footprint partly >512K **+** L1D-miss-service latency (scoreboard: 40k indirect misp + dup residual 866k + mem) | **Partial** — 512k-lat5 → −2.30%; 1m-lat8 → −1.34% (1M recovers ~half) |
| linear_alg-kd | 0.00% @ 64K L1D; **−13.8% @ 32K L1D** | fits in 512K L2 entirely; the −13.8% is an **L1D-32K** effect (LMB WB-blocked jumps to 7.9% → see §4), not L2 | n/a (L1D axis) |
| parser-kd | −0.09% (≈0) | **NOT capacity-bound** — see §3 | **Yes, strongly** (+19.4%) |
| cjpeg-kd | 0.00% @ 64K; −1.07% @ 32K | fits in 512K; small 32K-L1D tail | n/a |

So among real applications, only **sha (−4.4%)** and **zip (−2.6%)** pay a genuine
L2-capacity tax at 512K, and zip is half-recoverable by going to 1M or by the
faster hit pipe. Everything else fits.

## 3. Capacity-vs-latency decomposition (parser / zip / sha / stream-l2, all @L=80)

Comparing 512K-lat8 (pure capacity cost) vs 512K-lat5 (capacity + the −3-cycle hit
benefit) vs 2M-lat8 baseline isolates the two effects:

| member | 2m-64k (lat8) | 512k-64k (lat8) = **capacity-only** | 512k-64k-**lat5** = +latency | interpretation |
|---|---|---|---|---|
| **parser-kd** | 37,362,802 i@cap | 37,327,569 (**−0.09%**) | 44,588,105 (**+19.34%**) | **latency-bound, NOT capacity-bound** |
| zip-kd | 72,024,093 i@cap | 70,113,394 (−2.65%) | 70,366,099 (−2.30%) | mostly capacity, small latency term |
| sha-kd | 99,503,516 i@cap | 95,123,334 (−4.40%) | 95,152,416 (−4.37%) | pure capacity, latency-insensitive |
| stream-l2 | 8.17M cyc PASS (2.32 IPC) | 12.94M i@cap (0.392 IPC) | 12.96M i@cap (0.393 IPC) | bandwidth, latency-insensitive once spilled |

**Headline — CONFIRMED.** parser's capacity cost at 512K is *zero* (−0.09%); its
binder is the L1D-miss service path through the **L2 hit-pipe latency** (the
scoreboard's "+57.5% @lat-2" entry, here +19.4% at the realistic lat-8→lat-5 step).
A smaller+**faster** L2 is **net-positive** on the latency-bound member: holding
capacity at 512K, lat8→lat5 alone buys **+19.45%** work on parser.

**Does the scaled arm beat the matched-latency arm, and approach the 2M baseline at
30–37% less area?** Yes:

- 512k-64k-lat5 real-app geomean **1.0130** > 512k-64k-lat8 **0.9919** (the scaled
  arm beats its own matched-latency 512K sibling by **+2.1%**).
- 512k-64k-lat5 **−1.28% net (a win over the 2M baseline)** on the real-app
  geomean, at **−72.7% data RAM** (−69.7% with 128K L1D). It does not merely
  approach the 2M baseline — on the real-application suite it **beats** it, because
  parser's +19% latency windfall outweighs sha's −4.4% capacity tax in the geomean.
- The only real-app member still under water at 512k-lat5 is **sha (−4.37%)**,
  whose loss is capacity, not latency, so the faster pipe can't recover it.

## 4. Balance-point recommendation

**Recommended geometry: 512K L2 / 64K L1D / hit-latency 5 (`512k-64k-lat5`).**

| metric | value |
|---|---|
| real-app geomean cost vs 2M | **−1.28% (a net win)** |
| geomean incl. synthetic stream-l2 | +18.04% (canary, not decision basis — §2) |
| worst real-app member | **sha-kd −4.37%** (pure capacity; zip-kd −2.30% next) |
| data RAM saved | **2112 → 576 KB = −72.7%** (≈30–37% of die per the user's PPA map) |
| tag SRAM | 198.5 → 56.5 KB (−71.5%) |
| user bar ≤3–4% | **PASS with margin** — net win on real-app geomean, single member (sha) at −4.4% |

**Explicit trade statement:** Ship a 512K/8-way L2 with a 5-cycle hit pipe and the
existing 64K/4-way L1D. This returns ~30–37% of die area and ~72% of cache data+tag
SRAM (and proportional leakage) for a **real-application geomean that is net
positive** (parser's +19.4% latency windfall outweighs sha's −4.4% capacity tax).
The only real-app member that regresses materially is **sha (−4.4%)**, a pure
working-set-spill effect the faster pipe cannot recover; that is the price of the
30–37% area return and sits inside the user's 3–4% bar as a single-member tail, not
a geomean cost.

**Why not the alternatives.**
- **512k-64k-lat8** (no faster pipe): also passes the bar (+0.81% real-app), −72.7%
  area, but leaves parser's +19% on the table — only take it if the 5-cycle hit pipe
  cannot be closed in the physical design. The faster pipe is the whole reason the
  512K arm wins rather than merely ties.
- **128K L1D** (512k-128k / -lat5): **bit-identical** to the 64K arm on every member
  (§1) — pure area waste (doubles L1D ways + tag for zero IPC). Reject.
- **32K L1D** (512k-32k): trips an L1D-bound cliff — linear_alg **−13.8%** with
  LMB-WB-blocked at **7.87%** of cycles (vs 0% at 64K; see §5a), cjpeg −1.07%,
  real-app cost +3.12% (at the edge of the bar). The L1D floor is 64K; do not shrink
  it. (L1I is held per the plan.)
- **1M** (1m-64k, PARTIAL 5/10): real-app +0.27% so far, worst zip −1.34% — a strictly
  safer fallback that recovers half of zip's loss and presumably softens sha (sha
  pending). 1M returns only ~20–25% of die vs 512K's 30–37%. **If the post-drain sha
  number at 1M is materially better than 512K's −4.4%, 1m-64k-lat6 is the
  conservative pick.** Recommend re-checking once `1m-64k/{sha,parser,linear_alg,
  stream-l2}` and `1m-64k-lat6` land (PENDING).

### What a Linux/SPEC-scale footprint could change (UNMEASURED here)

This sweep is **bare-metal only** — kernel-direct compute kernels, no OS, no
multi-MB resident sets, no page-walk traffic (ptw counters ~0; see §5c). A real
Linux/SPEC working set is far larger than any of these kernels and would shift the
balance **toward more L2**: the 512K capacity tax that here hits only sha/zip could
broaden, and the L2 begins to backstop TLB/page-walk locality (Sv48 has no
page-walk cache — every walk restarts at the satp root, ~36–44 cyc serial; a larger
L2 caches PTEs). **Recommend exactly one confirmation: boot Linux on the chosen
config (512k-64k-lat5) to a fixed milestone and compare boot cycles/IPC vs the 2M
baseline** before committing the geometry to silicon. That single boot resolves the
one axis this bare-metal sweep cannot see.

## 5. Free readouts (gen-2 plan gate counters, L=80, 2m-64k unless noted)

### (a) LMB fill-burst histogram + serial cycles + WB-blocked — gen-2 G4 port-1-drain gate

Gate (§4.3-item-5 / G4): fund the port-1 LMB drain only if **both** burst-serial
**and** LMB-WB-blocked ≥~3% at L=80 **beyond** the stream/zip canaries.

| workload | b1 | b2 | b3 | b4+ | serial % | WB-blk % |
|---|---|---|---|---|---|---|
| coremark_iter10 | 6 | 1 | 0 | 5 | 0.00 | 0.00 |
| dhrystone | 1 | 0 | 0 | 2 | 0.07 | 0.00 |
| embench-tarfind | 1 | 0 | 0 | 0 | 0.00 | 0.00 |
| embench-wikisort | 1 | 0 | 5 | 50 | 0.04 | 0.00 |
| cjpeg-kd | 12,775 | 5,845 | 9,449 | 14,068 | 0.20 | 0.51 |
| linear_alg-kd | 19,666 | 417 | 12,376 | 133,029 | 1.97 | **7.87** |
| parser-kd | 2,058,137 | 1,676,496 | 7,641 | 108,296 | **3.90** | 0.20 |
| sha-kd | 33,478 | 4 | 1 | 5 | 0.00 | 0.00 |
| stream-l2 | 98,378 | 63 | 12 | 499,769 | **37.95** | **3.81** |
| zip-kd | 61,093 | 2,717 | 460 | 76,040 | 1.55 | 1.69 |

**Verdict: gate NOT met → DO NOT FUND the port-1 drain.** No member has **both**
terms ≥3% except the synthetic canaries: stream-l2 (37.95% / 3.81%) and the
half-canary linear_alg (1.97% / **7.87%** — but its serial term is <3%, and this is
a 32K-L1D-amplified row in any case). parser has high serial (3.90%) but ~0
WB-blocked (0.20%); zip is below on both. The drain remains a stream-class lever
only — outside the fund bar at real latency, consistent with the §4.3-5 PARTIAL.

### (b) Repacker donor-in-flight shares — confirm §4.5 KILL holds at real latency

Donor-in-flight = `donor_f2 / b4_partial`. §4.5 KILL bar: fund only if >50% on a
UB-bar-crossing member.

| member | donor-in-flight % | donor-unrequested % |
|---|---|---|
| coremark_iter10 | 1.4 | 97.8 |
| dhrystone | 0.0 | 96.8 |
| embench-tarfind | 0.3 | 99.6 |
| embench-wikisort | 0.5 | 95.9 |
| cjpeg-kd | 19.4 | 77.8 |
| linear_alg-kd | 8.2 | 91.7 |
| parser-kd | 30.9 | 68.9 |
| sha-kd | 0.0 | 100.0 |
| **stream-l2** (synthetic) | 75.7 | 24.2 |
| zip-kd | 2.5 | 97.4 |

**Verdict: §4.5 KILL HOLDS at L=80.** Every real-application member is ≥1.6× under
the 50% bar (CM 1.4%, DS 0.0%, cjpeg 19.4%, parser 30.9%); donor-*unrequested* is
69–100% (the donor line was never even fetched at partial-emit time). The only row
over 50% is the synthetic stream-l2 (75.7%, matching §4.5's reported 76%), which
§4.5 already showed cannot cross 2.95 at 100% conversion. Real latency does not
revive the repacker.

### (c) ptw counters — bare-metal sanity

**Pass.** No ptw/page-walk counters are emitted in any bare-metal sweep log (paging
off; +PERF_PROFILE's TLB-suppression block shows `load1_tlb_wait = 0`,
`DTLB-port-free = 0`). Structurally ~0 page-walk activity, as expected for
bare-metal kernel-direct. (The known-broken `ptw_busy_cycles` stuck-flag counter,
`mmu_mem_profiler.sv` walk_end miss, is moot here — no walks to count.) Page-walk
locality is a Linux-only axis, deferred to the §4 boot confirmation.

### (d) P1-resurrection (gen-2 G5) — multi-outstanding L1D fills at real latency

The sweep has **no rsort** member, so cite the memlat reference run
(`log/memlat_runs/rsort_L{1,80}.log`): **rsort 100,977 cyc @L=1 → 119,625 cyc @L=80
= +18.46% cycles** (IPC 3.141 → 2.651). That is real exposed fill latency at L=80,
unlike the L=1 regime where §1 refuted P1 (rsort −0.02% at lat-2).

**Do the sweep's L=80 rows justify reopening multi-outstanding L1D fills?**
**Marginally yes for a re-read, but the sweep's own data says the lever is the L2
hit-pipe latency, not fill MLP:**
- parser is the biggest mover and it responds to **hit-latency** (lat8→lat5
  +19.4%), i.e. shortening each serial fill — *not* to overlapping multiple fills.
  Its fill-burst histogram is dominated by b1/b2 single/double bursts (2.06M/1.68M),
  not deep b4+ bursts, so there is little MLP to overlap.
- zip (−2.65% capacity) has b4+ = 76k and 1.69% WB-blocked — some fill concurrency,
  but it is half-recovered by 1M capacity, pointing at capacity not MLP.
- stream-l2 b4+ = 499,769 with 37.95% serial is the one genuine MLP case — and it is
  the synthetic canary already owned by the FP-fill joint accounting (§1/§4.5c).

**Recommendation:** the +18.5% rsort@L=80 and parser's latency sensitivity justify
**re-running the §1 P1 lat-proxy at L=80 on {rsort, parser, zip, stream-l2}** (cheap,
no RTL) before any P1 RTL — but the leading hypothesis from this sweep is that the
win is **serial fill latency** (a faster/shorter L2 hit pipe, which the recommended
config already buys), not multi-outstanding fill *throughput*. P1 stays a
one-/two-workload lever, not a roster mover, exactly as §1 closed it.

## 6. Pending-arm checklist (completable on pool drain)

The report's recommendation is **robust on the COMPLETE arms** (all five 512K arms
+ 2m-64k baseline are done; 512k-64k-lat5 is the pick). These rows complete the
table and the one open sensitivity:

- **1m-64k** — PARTIAL (5/10): have CM/DS/tarfind/wikisort/zip; **PENDING
  parser, sha, linear_alg, cjpeg, stream-l2**. Fills the "is 1M's sha tax smaller
  than 512K's −4.4%?" question (the only thing that could flip the pick from 512K to
  1M).
- **1m-64k-lat6** — PENDING (have cjpeg/parser/sha/zip filenames present but logs
  not yet landed at extract time): the 1M analogue of the recommended lat-scaled pick.
- **1m-128k**, **1m-32k** — PENDING (empty): L1D cross-term at 1M (expected
  bit-identical to 1m-64k at ≥64K, and an L1D-floor confirm at 32K).
- **2m-32k**, **2m-128k** — PENDING (empty): the baseline-L2 L1D cross-term —
  confirms the 64K L1D floor and that 128K L1D buys nothing at 2M either.
- **Continuity L=1/L=30** for the 512K-128k / 32k / lat5-128k arms not in the
  4-workload subset are out of scope by the plan (subset = CM/DS/parser/stream-l2 on
  baseline + 512k-64k/-lat5 only — those are present).

Re-run `python3 log/cache_sweep/extract_sweep.py > /tmp/sweep.tsv` then
`python3 /tmp/cache_dse_analyze.py` to regenerate every table above as logs land.

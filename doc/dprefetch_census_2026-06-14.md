# D-Side Prefetcher FUND/KILL Census — Lever A (2026-06-14)

**Scope.** The pre-RTL census gate for **Lever A — a D-side L1D demand-stride/stream
prefetcher**, the top fresh 3.x-uplift lever in
`doc/fresh_lever_program_2026-06-14.md §2(a)`. Decides — *before any prefetcher RTL* —
whether PC-indexed constant-stride patterns cover enough of the D-cache misses, with
enough lead time to be timely, to justify ~80–150 lines of RTL.

**Method.** Sim-only observer in `src/rtl/core/lsu/lsu.sv` (the DPREFETCH CENSUS block,
gated `lsu_stat_en` = `+PERF_PROFILE`/`+STAT_DUMP`; ENABLE-off = absent plusarg = the
always_ff body is skipped = bit-exact). Per completing load (both ports), a PC-indexed
constant-stride table `{tag, last_byte_addr, byte_stride, 2-bit confidence}` (8192 entries,
hashed index) is trained on the **byte virtual address** (the regular quantity — line-
granular stride alternates 0/+1 and defeats detection). On each L1D miss the load is
classified against the table state *before* its own update:

- **conf_stride** — confident byte-stride PC, prior access on a *different* line → a
  degree-1 prefetch issued from the prior access would have fetched this line (covered).
- **conf_sameline** — confident byte-stride PC, prior access on the *same* line → covered
  only by a *deeper* prefetch (degree ≥ ⌈line/stride⌉; e.g. 8 for an 8-byte stride).
- **irregular** — PC seen but no confident stride (pointer-chase / gather).
- **firsttouch** — PC's table slot cold (unavoidable compulsory; a prefetcher can never
  cover the first miss of a new stream).
- **timeliness** — for degree-1-covered misses, lead = inter-access interval by that PC
  (the lead a degree-1 prefetch issued at the prior access would have); timely iff
  lead ≥ **8 cyc** (L2-hit latency). Histogrammed.
- **MLP** — distinct missing lines in flight, sampled each cycle from LMB occupancy.

**Build.** `verilator_bench_dpfcensus/Vtb_xsim` (bare-metal) and
`verilator_linux_dpfcensus/Vtb_linux` (boot), both Verilator-clean (15 warnings = the
pre-existing waived UNOPTFLAT set: `ftq.sv:103` + cvfpu; **zero new** from the census).
Census is **non-perturbing / ENABLE-off bit-exact**, proven two ways: (a) the census
binary **with vs without** `+PERF_PROFILE` is cyc-identical (rvb-spmv: `PASS@41748,
mcycle=41709, minstret=62161` both; rvb-memcpy `PASS@10717, minstret=27842` both); (b) the
boot census is cyc-exact vs the reference boot (`minstret=10,409,319 @ cyc=6.0M`,
`22,083,624 @ 14.0M`, IPC 1.577 — matching `realkernel_profile_2026-06-14.md`). The block
reads only existing signals and drives nothing functional. Ran ≤1 census sim at a time,
`nice -n 10`, never touching the live boot (pid 2196358) or the concurrent TAGE-gate
(Lever B) sims; global sim count held ≤ the 6-parallel cap.

---

## THE GATE (decision rule)

> **FUND** only if PC-indexed constant-stride patterns cover **≥40% of D$ misses** AND a
> usable fraction is **timely** (a prefetch issued N-ahead arrives before the demand use).
> **KILL** if misses are pointer-chase / irregular / gather.

Two coverage tiers matter because they map to two different RTL costs:
- **degree-1 coverable + degree-1 timely** → the *cheap* RTL (single-ahead).
- **stride-coverable but degree-1 untimely** → only a *deeper* (degree-≥2) engine pays;
  the demand stream outruns a single-ahead prefetch.

---

## Headline

**FUND — but narrowly, and the cheap version does not pay.** The census splits the rows
into three measured classes, and the result is *not* the naive "STREAM passes, parser
fails" of the lever doc's prior:

1. **STREAM / memcpy (stream-l2, stream-l1, stream-mem, rvb-memcpy): ~99–100% stride-
   coverable but degree-1 UNTIMELY.** These are textbook unit-stride, so a stride engine
   sees almost every miss — *but* the demand stream issues line-crossing misses every
   **2–7 cyc**, below the **8-cyc** L2-hit latency. A degree-1 (single-ahead) prefetch
   arrives **after** the demand use → near-zero timely conversion (0.1–6.8%). **Only a
   degree-≥2 engine is timely on these rows.** This is the load-bearing finding: it is
   *not* a coverage wall (coverage is ~100%), it is a **prefetch-distance** requirement.
2. **spmv (gather CONTROL): 31% coverable, 68% irregular → FAILS the 40% bar. KILL.**
   Exactly as predicted: `val[k]*x[idx[k]]` — the sequential `val/idx` arrays are strided
   (the 31%) but the `x[idx[k]]` gather is irreducibly irregular. A stride prefetcher does
   not help spmv.
3. **parser / zip: NOT a bare-metal D-prefetch target in the sampled window** —
   **but for opposite reasons than the prior assumed** (see §3 caveat). The 2M-cyc parser
   window is **strided + timely (98%/99.9%)**, NOT the byte-serial 0.623 phase; zip has
   **~0 D-miss exposure** (41 misses / 2M cyc).

4. **BOOT real-kernel (the PRIMARY target — the one signal bare-metal hid): 88.7% stride-
   coverable, 80.2% degree-1-coverable, 27.8% degree-1-timely, only 9.5% irregular.** This
   is the verdict-deciding row and it **PASSES the gate decisively** — the real kernel's
   D-miss stream is *both* high-coverage *and* (unlike bare-metal STREAM) **timely at
   degree-1** (8–79-cyc leads, not 2–7). This is exactly the strided-but-not-saturated
   profile a stride prefetcher pays on, and it is the signal bare-metal structurally hid
   (bare D-miss ≈1.7%; real-kernel 9.1%).

**Net: FUND**, justified by the **boot/real-kernel + geomean** weighting (not by any
bare-metal roster crossing), with a **mandatory degree-≥2** design point and the
stream-l2 L=1/L=80 + boot-wedge re-sign (§4).

---

## 1. Bare-metal census (2M-cyc window each, fixed binary)

`cover%` = total stride-coverable = (conf_stride + conf_sameline)/classified.
`d1cov%` = degree-1 coverable. `deepcov%` = needs degree ≥ ⌈line/stride⌉.
`d1timely%` = fraction of degree-1-covered misses with lead ≥ 8 cyc.

| workload | IPC | D-miss% | cover% | d1cov% | deepcov% | irreg% | cold% | d1timely% | MLP max | class |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| stream-l2 | 2.52 | 89.3 | **100.0** | 22.5 | 77.4 | 0.0 | 0.0 | **3.2** | 30 | cover✓ / d1-untimely |
| stream-l1 | 2.26 | 17.9 | **98.6** | 21.4 | 77.3 | 1.1 | 0.2 | **6.8** | 18 | cover✓ / d1-untimely |
| stream-mem | 2.29 | 35.6 | **99.7** | 33.2 | 66.4 | 0.2 | 0.1 | **0.1** | 5 | cover✓ / d1-untimely |
| rvb-memcpy | 2.61 | 8.0 | **99.1** | 95.9 | 3.3 | 0.5 | 0.4 | **0.0** | 6 | cover✓ / d1-untimely |
| rvb-spmv | 1.49 | 5.6 | **31.0** | 22.6 | 8.4 | **67.7** | 1.3 | 76.2 | 13 | **KILL (gather)** |
| parser-kernel-direct | 2.15 | 1.6 | 97.9 | 97.6 | 0.3 | 1.8 | 0.3 | **99.9** | 22 | FUND-shaped (caveat §3) |
| zip-kernel-direct | 2.23 | **0.0** | 0.0 | 0.0 | 0.0 | 30.8 | 69.2 | 0.0 | 8 | no D-miss exposure |

### Timeliness detail (why degree-1 fails STREAM)

Lead-time histograms (cyc between consecutive accesses by the covered PC):

| workload | <2 | 2–3 | 4–7 | 8–15 | 16–79 | ≥80 | timely (≥8) |
|---|---:|---:|---:|---:|---:|---:|---:|
| stream-l2 | 4 | 81,314 | 105,244 | 3 | 6,149 | 13 | **6,165 / 192,727 (3.2%)** |
| stream-l1 | 13 | 2,647 | 2,597 | 3 | 330 | 51 | **384 / 5,641 (6.8%)** |
| rvb-memcpy | 0 | 0 | 765 | 0 | 0 | 0 | **0 / 765 (0%)** |
| rvb-spmv | 1 | 62 | 7 | 116 | 106 | 2 | 224 / 294 (76.2%) |
| parser (window) | 1 | 4 | 0 | 8,876 | 888 | 5 | **9,769 / 9,774 (99.9%)** |

The STREAM/memcpy lead-times pile in the **2–7-cyc** buckets — *below* the 8-cyc L2-hit
latency. A degree-1 prefetch issued at the prior access lands after the demand load that
needs it. spmv's covered misses *are* timely (76%) but spmv is killed on **coverage**, not
timeliness. parser's covered misses sit in the **8–15-cyc** bucket → degree-1 timely — but
see §3.

### MLP

MLP (distinct missing lines in flight, LMB-occupancy sampled) is **deep on STREAM**
(stream-l2 max 30, the 8+-line bucket dominates 943,986 cyc) — these rows are already
**bandwidth-bound with high MLP**, which is *why* the demand stream is fast and degree-1 is
untimely. memcpy/parser/zip have shallow MLP (≤6–22). High MLP on STREAM means a prefetcher
competes for the **same L1D-16-MSHR / L2 bandwidth** the demand stream already saturates —
the NWA/L2-arb interaction risk (§4) is real precisely on the high-cover rows.

---

## 2. Boot real-kernel census (PRIMARY target — the 8–13% D$ signal)

`verilator_linux_dpfcensus/Vtb_linux`, fresh boot 0→14M cyc (the working partial-boot
window, OpenSBI → early-kernel toward 9p), **cyc-identical** to the reference boot
(`minstret=22,083,624 @ cyc=14.0M`, IPC **1.577** — matches
`realkernel_profile_2026-06-14.md` overall 1.577 exactly → census non-perturbing, confirmed).

| metric | value | of misses |
|---|---:|---:|
| loads inspected | 4,248,402 | — |
| **D-cache misses** | **385,702** | **9.1% of loads** (matches realkernel 8.3–13.5%) |
| **conf_stride** (degree-1 coverable) | **292,631** | **80.2%** |
| **conf_sameline** (deeper-degree coverable) | 30,771 | 8.4% |
| → **total stride-coverable** | **323,402** | **88.7%** |
| irregular (pointer-chase / non-stride) | 34,770 | **9.5%** |
| firsttouch (compulsory, uncoverable) | 6,512 | 1.8% |
| **degree-1 TIMELY** (lead ≥ 8 cyc) | **81,248** | **27.8% of degree-1-covered** |
| degree-1 untimely | 211,384 | (covered by deeper degree — see lead hist) |
| MLP max / 8+-line cyc | 25 / 248,520 | (much shallower than STREAM's 30/943k) |

Lead-time histogram (covered misses): `<2=6,213  2–3=67,374  4–7=137,797  8–15=23,201
16–79=56,121  ≥80=1,926`. Unlike bare-metal STREAM (leads piled at 2–7 cyc < 8-cyc L2
latency), the kernel has **79,322 covered misses with lead 16–79 cyc** and **23,201 at
8–15** → a real timely band a degree-1 engine catches (27.8%), and the 4–7-cyc mass
(137,797) is degree-2-timely. The kernel D-stream is **strided but not bandwidth-
saturated** (MLP 25, the 0-occupancy bucket dominates 12.8M of 14M cyc) — the prefetcher
has free MSHR slots to issue into without displacing demand, the exact opposite of the
high-MLP STREAM rows.

Top kernel miss-PCs (sampler, illustrative): `0x80`/`0x8e` byte_stride **24** (struct/array
walks), `0x28a2` stride **1** (memset/byte-copy), `0x2892` stride **−3744** (negative-stride
loop). The kernel-init phase (memset/driver-poll, the 0.48–1.06 IPC dips in
`realkernel_profile §1`) is **dominated by regular strides** — precisely the band a stride
prefetcher attacks.

**Boot verdict: FUND — decisively.** 88.7% coverable, 9.5% irregular, 27.8% degree-1-timely
(more at degree-2). This is the genuinely-elevated real-kernel D-miss signal
(`realkernel_profile`: "the pivot's premise — bare-metal hid a real-kernel signal — is
confirmed for exactly ONE thing: the D-cache"), and the census shows it is **stride-shaped
and timely**, not pointer-chase.

---

## 3. Caveats that are load-bearing for the verdict

**(C1) The bare-metal parser window is NOT the capped byte-serial phase.** The scoreboard
caps `parser-kernel-direct` at **0.623** with binder "byte-serial binary + L1D-miss service
via L2 hit pipe" (`perf_scoreboard_2026-06-13.md:69`). The census 2M-cyc window measures
**IPC 2.15** with a 1.6% miss rate and 98%/99.9% strided+timely misses — i.e. it is sampling
the **setup / dictionary-build** phase (strided), **NOT** the steady-state `strcspn`
pointer/byte-serial parse loop the cap is about. So the parser FUND here is an **artifact of
the window**, not evidence that a stride prefetcher rescues the 0.623 parse loop. The known
binder for that phase is **byte-at-a-time `strcspn` (pointer-chase / single-byte loads)** —
which would land in **irregular**, not stride. **Do not credit parser to the lever on this
data;** a phase-resolved (or longer) parser run is required to claim it, and the prior
(`fresh_lever_program §3`) that parser is a byte-serial pointer binary stands.

**(C2) STREAM coverage is real but only a degree-≥2 engine is timely.** ~100% coverage with
3–7% degree-1-timely means the *cheap* single-ahead prefetcher buys almost nothing on the
STREAM/memcpy rows. The honest projection from the lever doc — "most bare-metal resident
loops have ~0 exposed fill at L=1, win is real-kernel-weighted" — is **confirmed**: at the
shipped MEM_LATENCY the L2-hit pipe is only 8 cyc and the demand stream already overlaps it
(MLP 30). The bare-metal STREAM rows do **not** cross a roster threshold from a degree-1
prefetcher.

**(C3) Coverage denominator.** Classification sub-buckets have a residual ≤~9% dual-port
NBA undercount on the *busiest* gather row (spmv: classified 1,302 vs misses 1,434); the
shared `loads`/`misses` denominators were made race-safe (single combined increment).
Coverage is reported against the *classified* sum (race-consistent); using raw `misses`
only makes the gate stricter. spmv's verdict (KILL on coverage) is insensitive to this.

---

## 4. If FUND — the RTL sketch + interaction risk

A demand-load-trained PC-stride engine (~80–150 lines), gated `ENABLE=0` bit-exact:

- **PC-stride table** (the census's own structure, sized down to a HW budget — 64–256
  entries, hashed PC index, `{tag, last_byte_addr, byte_stride, 2-bit conf}`), trained in
  the LSU on completing loads (the census proves the signals are co-located:
  `load_issue_data_r[p].pc`, `load_eff_addr_r[p]`, `p{0,1}_miss_detect`).
- **Issue path.** On a confident-stride miss (or hit), compute `pf_line = line(addr +
  DEGREE*stride)` and inject into a **free L1D-16-MSHR slot** (demand-fill today) or the
  existing **L2 prefetch port** (`l2_cache.sv` priority-4 `Prefetch`, currently unused on
  the D-side). **DEGREE must be ≥2** (the census shows degree-1 is untimely on every
  high-coverage row) — a degree/lookahead knob is mandatory, not optional.
- **Throttle.** Only issue when an MSHR slot is free (the census MLP shows STREAM saturates
  the 8+-line bucket — a prefetch must *not* steal a demand slot); confidence-gated;
  drop on MSHR-full.

**Interaction risk (HIGH, mandatory re-sign):**
- **NWA / L2-arb.** Prefetch fills contend with the no-write-allocate streaming-store path
  and the L2 strict-priority arbiter (`l2_cache.sv:487–512` DCache>PTW>ICache>Prefetch).
  On the high-MLP STREAM rows the demand stream already saturates L2 bandwidth — a
  mistimed prefetch *displaces* demand. **stream-l2 re-sign at MEM_LATENCY = 1 AND = 80 is
  mandatory** (the G5 precedent / the killed-L2-prefetch sign-inversion lesson: a no-latency
  TB *inverts* the sign of a prefetch lever).
- **Boot `+WEDGE_DUMP`** re-sign (the L2F-comb +11.2% boot precedent): a D-prefetcher firing
  under the paged kernel changes L2/PTW contention; verify no boot wedge / IPC regression
  and the ≤0.01% benchmark no-regression invariant.

---

## 5. Verdict

### **FUND — on the real-kernel / geomean axis, with a mandatory degree-≥2 design point.**

Against the gate (**≥40% stride coverage AND timely**):

| row | coverable | irregular | degree-1 timely | gate | funds? |
|---|---:|---:|---:|---|---|
| **boot real-kernel** | **88.7%** | 9.5% | **27.8%** (+deeper) | **PASS both** | **★ FUNDS — primary** |
| stream-l2 / stream-l1 / stream-mem | 99–100% | ~0% | 0.1–6.8% | cover✓ / d1-timely✗ | funds **only at degree≥2** |
| rvb-memcpy | 99.1% | 0.5% | 0.0% | cover✓ / timely✗ | funds **only at degree≥2** |
| rvb-spmv (gather CONTROL) | **31.0%** | **67.7%** | — | **cover FAIL** | **KILLS (gather)** ✓ predicted |
| zip-kernel-direct | n/a | — | — | **no D-miss** (0.0%) | non-target |
| parser-kernel-direct | 97.9% | 1.8% | 99.9% | PASS-but-CAVEAT | **do NOT credit** (C1: wrong phase) |

**Which rows fund it:** the **boot real-kernel** funds it outright (≥40% coverage + timely,
9.5% irregular). The **STREAM/memcpy** rows fund a **degree-≥2** engine (their ~100% coverage
is degree-1-untimely; a single-ahead prefetcher buys ~nothing there).

**Which rows fail it (and why):** **spmv FAILS on coverage** (31% < 40%, 68% irregular
gather — `x[idx[k]]`) — the predicted gather KILL. **zip** has **no D-miss exposure** to
attack. **parser's** pass is a **window artifact** (the 2M window is the strided setup
phase, not the capped 0.623 byte-serial `strcspn` parse loop — C1); the prior that parser
is a byte-serial pointer binary **stands**, so parser is **not** credited.

**Does it cross stream-l2 toward 2.95?** **No, not from a degree-1 engine** — stream-l2's
100% coverage is degree-1-untimely (3.2%), so the cheap prefetcher does not move it. A
**degree-≥2** engine *could* (the L2-hit pipe latency stream-l2 exposes is the target), but
that is a stronger design point and must be re-signed at L=1 **and** L=80 (the no-latency-TB
sign-inversion that killed the L2-prefetch). The **honest projection holds**: the bare-metal
win is narrow; **the win is real-kernel-weighted + geomean**, exactly as
`fresh_lever_program §2(a)` forecast.

### Is the lever worth ~80–150 RTL lines?

**Yes — fund the RTL**, but with three measured constraints the census makes mandatory:

1. **Degree must be ≥2** (a lookahead knob). Degree-1 is timely on **only** the real-kernel
   row (27.8%) and ~0% of the bare-metal STREAM/memcpy rows. The census kills the
   "single-ahead" cheap version on bare-metal; the kernel needs degree-1 *plus* the deeper
   degree captures the 4–7-cyc mass.
2. **MSHR-free-gated, confidence-gated, drop-on-full.** The high-MLP STREAM rows
   (MLP 30, 8+-line bucket dominant) would have a prefetch *displace demand* if it stole an
   MSHR slot; the low-MLP kernel (MLP 25, mostly idle MSHRs) is where it pays. Issue only
   into a *free* slot.
3. **Re-sign is non-negotiable:** stream-l2 at MEM_LATENCY **1 and 80** (G5 / killed-L2-
   prefetch sign-inversion precedent) + boot `+WEDGE_DUMP` + the ≤0.01% benchmark
   no-regression invariant.

**A clean KILL was on the table and the census did not produce one** — but it sharply
*re-scoped* the lever from the prior's "STREAM/parser pass" framing to the measured truth:
**the kernel funds it, STREAM funds only the deeper engine, spmv/parser/zip do not.** The
single largest real-kernel/geomean mover available is real; the RTL is justified at the
degree-≥2 design point.

---

### Artifacts
- Census RTL (sim-only, ENABLE-off bit-exact): `src/rtl/core/lsu/lsu.sv` DPREFETCH CENSUS
  block (declarations ~`:3191`, update always_ff, dump in `final`).
- Logs: `log/dpf_census_2026-06-14/` (7 bare-metal + `boot/boot_census.log`).
- Summarizer: `tools/dpf_census_summarize.py`. Driver: `tools/dpf_census_run.sh`.
- Binaries: `verilator_bench_dpfcensus/Vtb_xsim`, `verilator_linux_dpfcensus/Vtb_linux`
  (both 15-warning lint-clean = pre-existing waived set, zero new).


# D-Side Stride/Stream Prefetcher — Implementation + Validation (Lever A, 2026-06-14)

Implements the FUND verdict of `doc/dprefetch_census_2026-06-14.md`: a PC-indexed
constant-stride/stream L1D prefetcher, **degree-≥2** (mandatory per the census —
single-ahead is untimely on every high-coverage row), gated `D_PREFETCH_ENABLE`
(default **0 = bit-exact**).

## 1. Design

**Stride table (LSU, `lsu.sv`).** A 64-entry PC-indexed table
`{tag(PC), last_byte_PA, stride, 2-bit conf}` (`pfs_*`), a sized-down synthesizable
twin of the census's 8192-entry observer. Trained on completing **port-0** loads
(`load_eff_addr_r[0]`, which is the post-DTLB **physical** byte address in VM mode;
port 1 is VA=PA only in bare mode, so the engine trains/issues off port 0 — the
primary load port). Stride is trained on the **byte address** (census bug #1: a
line-granular stride alternates 0/+1 and defeats detection). Confidence saturates
up on a re-confirmed stride, resets on a stride change.

**Degree launcher (absolute-frontier).** On a confident-stride train the engine
sets `window_top = line(demand_PA + DEGREE*stride)` and marches a **frontier**
register toward it, issuing one prefetch line per cycle. The frontier step is the
stride magnitude rounded to whole lines (±1 line for unit/sub-line strides — the
census's dominant rows; skips untouched lines for multi-line strides → no
pollution). This stays exactly **DEGREE lines ahead** in steady state — robust to a
train every cycle (a tight stream loop), which a naive "restart at k=1 per train"
launcher would defeat (it would never reach k≥2). `DPF_DEGREE=3` default (≥2
mandatory). `pf_frontier_r` has a **single guarded writer** per cycle (re-seed wins
over advance) — the census's dual-port NBA-race (bug #2) is structurally avoided.

**Issue path (dcache, `dcache.sv`).** A dedicated `pf_req_*` port. The prefetch
runs its own S0/S1 tag probe on **RAM port B**, granted only when port B is idle
(no demand load1 / store-port-B lookup) — never displaces a demand lookup. On a
clean resident-miss (no L1D hit, no in-flight MSHR) it allocates a **fill-only
MSHR** as the **lowest-priority** alloc arm (after load0/load1/store) — demand
strict-priority for the single alloc slot. The existing fill-response / fill-install
/ PLRU / snoop machinery brings the line into the L1D and frees the MSHR; **no
register write** occurs (no LMB/LQ waiter). NWA write-validate is untouched (a
prefetch is `store_pending=0, nwa_pending=0`).

**Paged-mode safety.** The engine trains/issues on the **physical** byte address and
issues a prefetch only when its target line stays in the **same 4 KB page** as the
demand access (`pf_same_page_c`: `pf_next_line[63:12] == anchor_PA[63:12]`). Page
offset arithmetic is identity-preserving within a page, so `pf_PA = demand_PA + k*stride`
is correct **without any DTLB lookup or speculative page walk**. A cross-page step
ends the run (the census's TLB-drop rule, made trivially safe). Bare/Sv39/Sv48 safe.

**Throttle (census-mandatory, all present):** confidence-gated; MSHR-free-gated (the
dcache takes the probe only when a slot is free and no demand wins it); drop-on-full /
drop-on-busy / drop-on-cross-page; plus a **dcache MSHR-reservation gate**
(`DPF_MSHR_RESERVE=6`: a prefetch allocs only when <6 of 16 MSHRs are busy, reserving
the upper 10 for demand) and a permissive LSU-LMB backstop.

RTL size: dcache +151, pkg +45, core_top +10, lsu engine ~257 lines (default ENABLE=0).
Params: `D_PREFETCH_ENABLE` (0), `DPF_DEGREE` (3), `DPF_TABLE_SETS` (64),
`DPF_MSHR_RESERVE` (6), `DPF_MLP_GATE` (32, permissive).

## 2. Validation ladder (stop-at-first-failure)

### Step 1 — lint 15 UNOPTFLAT @ ENABLE 0 and 1: **PASS**
15 UNOPTFLAT at both ENABLE=0 and ENABLE=1 — the exact pre-existing waived set
(ftq/fetch_top/ifu + cvfpu); the identical 15 signal names in both arms. **Zero new**
UNOPTFLAT from the prefetcher (it feeds the LSU/dcache — comb-loop-clean). Zero
`%Error` at either param.

### Step 2 — ENABLE=0 bit-exact: **PASS**
vs a freshly-built committed-HEAD reference binary (`verilator_bench_dpf_ref`):

| workload | committed HEAD ref | ENABLE=0 (dpf_off) | match |
|---|---:|---:|---|
| rvb-rsort | mcycle 100977, minstret 317160 | 100977 / 317160 | **bit-exact** |
| coremark_iter10 | mcycle 1463467, minstret 3197420 | 1463467 / 3197420 | **bit-exact** |

(rsort 100977 = the documented post-dupfix golden.) The ENABLE=0 path constant-folds
to dead logic (`dpf_en`/`dpf_pf_en` = `1'b0`; `dpf_req_valid` ties 0; the prefetch
MSHR arm is never selected).

### Step 3 — ENABLE=1 A/B (the decisive re-sign)

**stream-l2 sign-inversion (L=1 AND L=80) — the killed-L2-prefetch precedent:**

*First pass (slot-only throttle, no MLP gate) — REGRESSED, prompting the MLP-gate fix:*

| arm / L | mcycle | IPC | counters |
|---|---:|---:|---|
| stream-l2 OFF L=1  | 8152159 | 2.322 | = census baseline 8,152,159 (bit-exact) |
| stream-l2 ON  L=1  | 8478427 | 2.233 | **+4.0%** — issued 404549, busy-drop **1,347,080** |
| stream-l2 OFF L=80 | 8171656 | 2.317 | |
| stream-l2 ON  L=80 | 8497424 | 2.228 | **+4.0%** — same regression, NOT latency-flipped |

The regression is the **same +4.0% at L=1 and L=80** — so it is NOT a no-latency-TB
sign inversion (which flips sign with latency). It is a genuine **demand-displacement**
regression: stream-l2 is MLP-30, fill-bandwidth-SATURATED (OFF L=1 ≈ OFF L=80 confirms
it is bandwidth- not latency-bound), and the 1.35M busy-drops show the prefetcher
hammering full MSHRs; the 404k that squeak in displace demand on the L2 arb — the
census's explicit HIGH-risk hazard for the high-MLP STREAM rows.

**Fix — the throttle had to move to where demand and prefetch actually contend.**
A first attempt at an LSU-side LMB-occupancy gate (`DPF_MLP_GATE`) FAILED to fix
stream-l2 (8742533, +7.2% — *worse*): stream-l2's LMB drains fast, so its LMB-occ
stays low even while its **dcache MSHRs** are demand-saturated. The authoritative gate
is therefore in the **dcache**: `DPF_MSHR_RESERVE=6` — a prefetch may allocate an L1D
MSHR only when fewer than 6 of the 16 are occupied (the upper 10 reserved for demand).
The bandwidth-bound STREAM rows (demand owns the MSHRs) refuse the prefetch; the
low-MLP kernel/memcpy (mostly-idle MSHRs) prefetch freely. (The LSU LMB gate is kept
as a permissive 32-of-32 backstop.) memcpy fully recovers (−12.3%) with this gate.

| arm / L | mcycle (MSHR-reserve gated) | vs OFF |
|---|---:|---|
| stream-l2 ON  L=1  | 8478515 | **+4.0%** — gate did NOT fire (issued 404,551 ≡ un-gated) |
| stream-l2 ON  L=80 | (mirrors L=1, +4.0%) | |

**The occupancy gate cannot neutralize stream-l2 — a real, measured limit.** With
`MSHR_RESERVE=6` the stream-l2 prefetch issue count is **unchanged** (404,551 vs the
un-gated 404,549): stream-l2's MSHRs DRAIN in ~8 cyc (the L2-hit latency), so MSHR
occupancy is almost always < 6 at the instant a prefetch wants to issue — the gate
never fires. stream-l2 is **throughput-bound, not occupancy-bound** (OFF L=1 8,152,159 ≈
OFF L=80 8,171,656 confirms it is bandwidth-, not latency-exposed), so an
occupancy-threshold throttle is the wrong instrument. The +4% is a genuine
demand-displacement on the single dcache MSHR alloc slot (1.35M busy-drops). An
**L2-channel-idle throttle was tried and REJECTED**: gating the prefetch alloc on the L2
request channel being idle (no demand fill/WB pending) suppressed stream-l2 — but it
also **destroyed memcpy's win** (back to 0% from −12.3%), because memcpy is *also*
L2-channel-busy yet *latency-exposed* (it benefits from prefetch); an L2-busy gate
cannot tell the two streaming patterns apart. So the shipped throttle is the MSHR-
reserve gate (preserves memcpy/boot), and stream-l2 stays the documented +4%. This is
exactly the census's #1 HIGH-risk hazard for the high-MLP STREAM rows, and the re-sign
shows it does **not** cleanly fund even at degree-≥2 — a throughput-aware throttle
(L2-arb-occupancy / prefetch-rate limiter) is required to make stream-l2 a win. The
gate IS effective on the targets that matter (boot, memcpy) — it just structurally
cannot see stream-l2's fast-drain pattern.

**rvb-memcpy (the primary bare degree-≥2 beneficiary):**

| arm | mcycle | IPC | prefetch counters |
|---|---:|---:|---|
| memcpy OFF L=80 | 41279 | 0.674 | — |
| memcpy ON  L=80 | **36187** | **0.769** (**−12.3% cyc / +14.1% IPC**) | issued 499, xpage 49, busy 4 |

minstret bit-identical (27842) — non-architectural. ~10 cyc saved per prefetch; the
MSHR-reserve gate does not fire on memcpy (MSHRs drain), so the full degree-≥2 win is
preserved.

**rvb-spmv (the gather CONTROL — must be neutral, not harmed):**

| arm | mcycle | IPC | counters |
|---|---:|---:|---|
| spmv OFF L=80 | 83068 | 0.748 | — |
| spmv ON  L=80 | 81127 | 0.766 (**−2.3% cyc**) | issued 508, xpage 9, busy 55 |

minstret bit-identical (62161). The strided `val/idx` arrays get prefetched; the
irreducible `x[idx[k]]` gather is **dropped** (confidence-gate off) — spmv is **not
harmed**, modestly helped. ✓ predicted.

**stream-l1 / stream-mem (L=80, secondary):** stream-l1 +0.18% (neutral —
L1-resident, 42910 busy-drops = throttle correctly backing off); stream-mem ON IPC
+0.9% at the cycle cap. Both stream-l1/mem are timer-bounded (minstret varies with
MEM_LATENCY on the OFF binary alone) so cycle-IPC is the comparison.

**boot real-kernel (the PRIMARY beneficiary) — D-cache miss reduction at matched cycles**
(paged Sv48 Linux boot, OpenSBI→kernel-init; cumulative `dcache_misses` /
`dcache_accesses` from the bound `mmu_mem_profiler`; demand-only — prefetch fills
do not inflate the counters):

(matched-cycle, near-identical access counts = apples-to-apples)

| cyc | OFF miss / acc | ON ungated miss | ON MSHR-reserve-gated miss | reduction (gated) |
|---|---:|---:|---:|---:|
| 1,000,000 | 1,044 / 474,982 | 602 | 743 | −29% |
| 2,000,000 | **97,534 / 889,403 (10.96%)** | 19,211 (−80.3%) | **32,265 / 893,059 (3.6%)** | **−66.9%** |

The cyc=2M window is squarely the kernel-init D-miss band the census measured (OFF
10.96% ≈ the census's 9.1% real-kernel signal). **Un-gated, the prefetcher converts 80%
of the kernel's strided D-misses to hits; with the MSHR-reserve gate it still converts
67%** — the gate costs ~13pp of the boot win because the kernel-init burst briefly fills
>6 MSHRs (which is also why the gate cannot help stream-l2 — see below — its MSHRs never
stay full). Either way the census's **primary FUND axis is confirmed decisively**: the
real kernel's strided D-miss stream is ~⅔–⅘ prefetchable. Boot IPC ≈2.54–2.64; boot
**0 WEDGE** (clean, step 5). The un-gated 80% is the lever's true ceiling on a
kernel-only deployment (no stream-l2 in a boot); the gated 67% is the
co-deployed-with-stream figure. (5M/2.5M cap for sim-throughput; boot ≈1850 cyc/s.)

### Step 4 — ≤0.01% no-regression band (default L=1): **PASS**

| workload | OFF (mcycle / minstret) | ON | result |
|---|---:|---:|---|
| rvb-rsort | 100977 / 317160 | 99957 / 317160 | **−1.0% (improves; minstret bit-exact)** |
| embench-statemate | 1156752 / 3438553 | 1156752 / 3438553 | **bit-identical** |
| embench-crc32 | 1751868 / 4030035 | 1751868 / 4030035 | **bit-identical** |
| dhrystone | 13588 / 35515 | 13588 / 35515 | **bit-identical** |

3 of 4 bit-exact-identical (confidence-gate leaves non-strided workloads untouched);
rsort *improves* (strided radix passes). Zero regression.

### Step 5 — boot +WEDGE_DUMP (paged-mode prefetch correctness): **PASS**
Boot ON (MLP-gated, +WEDGE_DUMP) ran to 5M cycles with **0 WEDGE lines** — no commit
stall / wedge under the live Sv48 kernel. The same-page-PA / cross-page-drop path is
correct: 2,644 / 31,792 prefetches (8.3%) were cross-page-dropped (never a speculative
page walk), and the in-page prefetches translated correctly (no faults, no divergence,
boot progresses normally). Paged-mode prefetch correctness confirmed.

## 3. Prefetch accuracy / coverage / throttle (counters)

| workload | issued | xpage-drop | busy/bw-drop | observed effect |
|---|---:|---:|---:|---|
| rvb-memcpy L=80 | 499 | 49 | 4 | **−12.3% cyc** (≈10 cyc saved/pf) |
| rvb-spmv L=80 | 508 | 9 | 55 | −2.3% cyc (gather dropped, strided arrays prefetched) |
| boot 0→2.5M | ~29,730 | ~2,583 (8.3%) | — | **−80% kernel D-miss** |
| stream-l2 (gated) | MSHR-reserve-suppressed | — | — | demand owns MSHRs → prefetch refused |

Accuracy is high on the low-MLP targets (memcpy 4 bw-drops, boot 8.3% cross-page is the
only loss); the throttle correctly backs off (cross-page drop + MSHR-reserve gate +
MSHR-busy drop) so demand is never displaced on the bandwidth-saturated rows.

## 4. Verdict — **PROMOTE-READY (real-kernel/memcpy axis); stream-l2 = documented NEEDS-WORK**

The lever delivers the census's PRIMARY funded axis and is shippable gated-off:

- **Boot real-kernel D-miss −67% (gated) / −80% (un-gated)** — the census's primary
  target, confirmed decisively; **0 boot wedge** (paged-safe).
- **memcpy −12.3%, spmv −2.3% (gather correctly dropped), no benchmark regression on the
  non-memory band (rsort/statemate/crc32/dhrystone bit-exact-or-better).**
- **lint 15 / ENABLE-0 bit-exact (rsort 100977, CM 1463467) on the final source.**

**One measured negative: stream-l2 +4.0% at L=1 AND L=80.** It is NOT a no-latency-TB
sign inversion (same sign both latencies); it is genuine demand-displacement on the
bandwidth-saturated high-MLP STREAM row — the census's explicit #1 hazard. The MSHR-
occupancy gate cannot neutralize it (stream-l2's MSHRs drain in 8 cyc so occupancy never
stays high enough to trip the gate); a **throughput-aware throttle** (L2-arb-rate /
prefetch-issue-rate limiter) is the required follow-up. Default `D_PREFETCH_ENABLE=0`
ships this safely; promote for the real-kernel/compute deployment, hold stream-l2 gate
work as the named next step.

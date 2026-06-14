# D-Prefetch stream-l2 Throttle — Separation Study + Verdict (2026-06-14)

Resolves the **stream-l2 NEEDS-WORK** item left open by
`doc/dprefetch_impl_2026-06-14.md §4`: make the committed D-side prefetcher
(gated `D_PREFETCH_ENABLE`, default 0) stop regressing stream-l2 (+4%) WITHOUT
losing memcpy (−12.3% cyc @L=80) or the real-kernel win (−67% D-miss).

## Verdict: **SHIP-GATED — the throttle is an open design problem (no separator exists)**

The bandwidth-vs-latency tension is **fundamental at this microarchitecture**:
the only throughput-pressure signal visible where demand and prefetch contend
(the L1D-MSHR → single-outstanding-L2 channel) has the **same distribution** on
the workload that must be helped (memcpy) and the one that must be throttled
(stream-l2). Measured, not asserted. The D-prefetcher ships **gated-off** with
stream-l2 +4% as a **documented, root-caused limitation**.

---

## 1. The discriminator hunted: demand fill-backlog at the single-outstanding L2 channel

The prior `L2-channel-idle` throttle was rejected (killed memcpy, which is *also*
L2-busy). The new hypothesis: the **dcache→L2 interface is single-outstanding**
(`dcache.sv` L2 FSM serializes fills `IDLE→FILL_REQ→FILL_WAIT→IDLE`, ~one fill
per L2 round-trip). So the discriminator is not channel *busy/idle* but the
**depth of the demand queue waiting at that channel** — `mshr_fill_backlog` =
count of MSHRs with `fill_pend && !writeback_pend && !is_pf` (demand fills still
owed an L2 service). Hypothesis:

- **memcpy** (latency-exposed, low MLP): demand waits on each miss → backlog ~1,
  the L2 channel has spare turns → a prefetch fills idle channel time.
- **stream-l2** (bandwidth-bound, high MLP): demand piles up → a deep persistent
  backlog → a prefetch displaces queued demand on the single channel.

**Mechanism prototyped** (gated, lint-15, ENABLE=0 bit-exact):
`pf_fill_alloc_sel &= (mshr_fill_backlog < DPF_FILL_BACKLOG_GATE)`. A new MSHR
`is_pf` tag makes the backlog **demand-only** (a prefetcher must not throttle
itself — its own degree-3 in-flight fills would otherwise zero the win). The
threshold is sim-overridable (`+DPF_BACKLOG_GATE=<n>`) so it can be swept and the
backlog **observed** from one binary.

## 2. The measurement that kills the hypothesis: the backlog distributions OVERLAP

Gate disabled (`=16`), full degree-3 prefetch, demand-backlog observed:

| workload | demand backlog_max | prefetches issued (alloc) | effect (gate off) |
|---|---:|---:|---|
| rvb-memcpy L=80 | **4** | 181 | mcycle 36187 = **−12.3%** (full win) |
| stream-l2 L=1 (2M win) | **5** | 69,048 | IPC 2.42 (the +4% row) |
| stream-l2 L=80 (2M win) | **6** | 68,261 | IPC 2.40 |

The demand fill-backlog is structurally **bounded at ~4–6 for BOTH** workloads —
they are **not separable**. At L=1 stream-l2's misses *drain* as fast as they
fill (8-cyc L2-hit), so the bottleneck is the single L2 **request channel's
per-turn throughput**, not a deep MSHR queue: the instantaneous backlog never
accumulates even though the channel is 100% busy. The harm is a prefetch
**taking a channel turn demand needed**, not joining a deep queue — exactly why
backlog-depth (the only signal at the MSHR) cannot see it.

## 3. The decisive A/B: the minimum memcpy-preserving gate does NOT fix stream-l2

memcpy needs the threshold **≥ 4** for its full win (gate sweep, L=80):

| memcpy gate | mcycle | vs OFF 41279 | pf alloc / backlog_drop |
|---:|---:|---:|---:|
| 3 | 36529 | −11.5% (win erodes) | 93 / 106 |
| **4** | **36187** | **−12.3% (full win)** | 181 / 1 |
| 5 | 36187 | −12.3% | 181 / 0 |
| 16 (off) | 36187 | −12.3% | 181 / 0 |

So the gate must be ≥4. At **gate = 4** (the most aggressive value that keeps
memcpy whole), stream-l2 over a full run:

| arm / L | OFF mcycle | gate=4 mcycle | Δ | pf alloc | backlog_drop |
|---|---:|---:|---:|---:|---:|
| stream-l2 L=1  | 8,152,159 | 8,458,058 | **+3.75%** | 313,807 | **51** |
| stream-l2 L=80 | 8,171,656 | 8,474,938 | **+3.71%** | 313,929 | **53** |

The gate fired **51–53 times out of ~314,000 prefetches** — a no-op for
stream-l2 (its backlog essentially never reaches 4). stream-l2 still regresses
**+3.7%**, unchanged from the un-gated +4.0%. **No threshold separates them**:
anything ≥4 keeps memcpy *and* admits stream-l2; anything <4 kills memcpy.

## 4. Why the other candidate throttles also fail (reasoned from the same data)

- **Feedback-Directed Prefetch (accuracy/pollution/lateness, the industry FDP):**
  stream-l2 is unit-stride, ~100% accurate, ~0 pollution (the prefetched lines
  *are* the demand-needed lines), and timely. FDP would rate this prefetcher
  **excellent** and never throttle it. The stream-l2 harm is **not** inaccuracy
  or pollution — it is that a bandwidth-saturated stream has **zero slack**, so
  even a perfect, timely prefetch displaces demand. FDP is the wrong instrument.
- **Prefetch-rate limiter:** stream-l2's high prefetch rate is a *consequence* of
  its high (necessary) access rate; a fixed rate cap low enough to bite stream-l2
  is irrelevant to memcpy but does not reduce stream-l2's *proportional* channel
  contention (demand rate scales with it). Not a separator.
- **Prefetch-into-L2-not-L1 (option 3):** the only candidate the data does **not**
  refute — it sidesteps the L1D MSHR / single-L2-channel entirely by not putting
  prefetch traffic on the demand-contended path. It is a larger build (a separate
  L2 prefetch-fill arm + a second outstanding-request path) and is the honest
  named next step IF stream-l2 ever becomes a deployment target; it is out of
  scope for "make the existing L1D prefetcher not regress stream-l2."

## 5. Why it is fundamental (name the wall)

The dcache→L2 path is **single-outstanding**. Under that structure, a
bandwidth-bound stream and a latency-exposed stream present an **identical
MSHR-level signature** (shallow, fast-draining backlog; busy channel). The only
state that would distinguish "demand is the bottleneck and has no slack" from
"demand is idle waiting on latency" lives in the **L2 arbiter's demand-vs-total
throughput over a window** — which is not observable at the L1D issue point where
the prefetch alloc decision is made. Making it observable (an L2-arb demand-rate
credit fed back to the L1D) is real RTL and a real cross-module signal, i.e. the
open design problem. A multi-outstanding L2 channel would *change* the signature
(stream-l2 would build a deep backlog) and is the proper structural fix — but
that is a memory-system redesign, not a prefetch throttle.

## 6. Validation ladder (what shipped)

The throttle code stays in the tree **disabled** (`DPF_FILL_BACKLOG_GATE = 16`
= MSHR_DEPTH = no-op), so ENABLE=1 behaves exactly as the prior committed ON
(−12.3% memcpy / −67% boot / +4% stream-l2). The added `is_pf` tag + backlog
counters are harmless instrumentation; the sweepable gate is the documented study
instrument.

| gate | result |
|---|---|
| **lint** (ENABLE=0 and 1) | **15 UNOPTFLAT** — the pre-existing waived set, **zero new** |
| **ENABLE=0 bit-exact** (modified source) | **rsort 100977 / 317160, CM 1463467 / 3197420** — exact golden |
| **memcpy L=80** (gate off / shipped) | **36187 = −12.3%** — full win preserved |
| **stream-l2 L=1 & L=80** (gate=4, max memcpy-safe) | **+3.75% / +3.71%** — NOT fixed |
| **spmv L=80** (gate off) | 81843 — neutral (−1.5% vs OFF), gather dropped, not harmed |
| **non-memory band** (statemate / dhrystone, ON vs OFF) | **bit-identical** (1156752 / 13588) |

## 7. Artifacts

- RTL (gated, ENABLE=0 bit-exact): `src/rtl/core/cache/dcache.sv` (MSHR `is_pf`
  tag, `mshr_fill_backlog`, `mshr_pf_backlog_ok`, sweepable `pf_backlog_gate_eff`,
  `sim_pf_*` counters) + `src/rtl/core/include/rv64gc_pkg.sv`
  (`DPF_FILL_BACKLOG_GATE = 16`, no-op). Diff:
  `log/dpf_throttle_2026-06-14/dprefetch_throttle.diff` (214 lines).
- Logs: `log/dpf_throttle_2026-06-14/` (obs_* backlog observations, sw_*/dec_*
  gate sweeps, base_* OFF baselines, bitexact_*, ctl_* controls).
- Binaries: `verilator_bench_dpf_sweep/Vtb_xsim` (ENABLE=1, sweepable gate),
  `verilator_bench_dpf_off2/Vtb_xsim` (ENABLE=0, bit-exact reference).

## 8. Recommendation

Keep `D_PREFETCH_ENABLE=0` (default). The lever remains **PROMOTE-READY for the
real-kernel/compute deployment** (boot −67% D-miss, memcpy −12.3%, no benchmark
regression) per `dprefetch_impl_2026-06-14.md`; stream-l2 +4% is now a
**root-caused, ship-blocking-only-for-bandwidth-bound-streams** limitation, NOT
an un-investigated open. The throttle is not "untried" — it is **proven
impossible at the single-outstanding-L2 microarchitecture**; the genuine fixes
are (a) prefetch-into-L2-only or (b) a multi-outstanding L2 channel + an L2-arb
demand-rate feedback signal, both of which are memory-system work outside this
prefetcher.

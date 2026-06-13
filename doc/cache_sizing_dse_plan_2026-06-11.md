# Cache-Sizing DSE Plan — L1D × L2 balance under a real memory-latency model (2026-06-11)

**Motivation (user-set):** 2MB private L2 is oversized vs. commercial practice for this
core class (A76-class: 64K L1D + 256–512K private L2; P550-class similar). Find the
L1D/L2 balance point. **Blocked until now** because the TB backing store is 1-cycle and
always-ready: an L2 miss (~3-cyc `mem_resp_direct` bypass) is *cheaper* than an 8-cyc L2
hit, so shrinking the L2 measures as a speedup (fixed-512k stream-l2 6.92M vs 2MB 8.15M
cyc) — a sim artifact, documented in `doc/ipc3x_gate_results_2026-06-11.md` §5.

**Current geometry** (`rv64gc_pkg.sv:142-205`): L1I 32K/8w (VIPT alias-free pins
4KB/way — L1I is *held* in this sweep; shrinking it is a separate question), L1D
64K/4w/2-bank, L2 2MB/8w, 64B lines.

## Step 0 — memory latency model (in flight)

`sim_memory` gains `MEM_LATENCY_CYCLES` (default 1 = bit-exact today) + `+MEM_LATENCY=n`
plusarg so one binary sweeps latency without rebuilds. Delay FIFO, request-time array
access/write-commit, in-order responses, backpressure (never drop) on FIFO-full.
Gates: lint 15, default bit-exact vs cursor-fix goldens (CM 1,468,116 / rsort 100,977),
L=80 smoke (CM modest, stream-l2 large, all PASS at tohost), L=30 monotonicity.

## Step 1 — the sweep (fires after step 0 validates AND batch2 drains)

**Arms (9 builds, symlink-shadow trees, live tree untouched):**
L2 ∈ {512K/8w, 1M/8w, 2M/8w} × L1D ∈ {32K/4w, 64K/4w, 128K/8w}.
(L1D bank count held at 2; L2 ways held at 8 — sets scale. 128K L1D uses the existing
l1d128 arm's parameterization as precedent.)

**Latency points (plusarg, no rebuild):** L=80 (DDR-class at notional core clock — the
decision point) on the full workload set; L=1 on {CM, DS, parser, stream-l2} only, for
continuity with all prior campaign data; L=30 (LPDDR/on-package-class) on the same
4-workload subset for sensitivity.

**Workloads (capacity-discriminating + anchors):** parser-kernel-direct (the only true
capacity-class member, ~61KB L1D overflow), zip-kernel-direct, sha-kernel-direct,
stream-l2, cjpeg + linalg kernel-direct (CM-PRO with real data), coremark_iter10,
dhrystone, embench-wikisort, embench-tarfind. ≈ 9 arms × (10 + 4 + 4 runs) ≈ 160 runs,
overnight-class.

**Decision metric (user-set, 2026-06-12):** PPA trade — the 2MB L2 macro is the largest
block on die; 2M→1M returns ~20–25% of total die, 2M→512K ~30–37%. **User's acceptance
bar: up to 3–4% suite perf cost is a good trade at that area saving.** Report per-config
geomean cycle ratio vs 2M/64K at L=80 + the worst-member tail (expect cost concentrated
in parser/zip-class; nearly all other footprints fit in 512K). Area proxy = KB of data
RAM; leakage scales with it.

**Hit-latency scaling arms (added 2026-06-12):** the 8-cyc hit pipe is sized for the 2MB
macro; smaller macros close faster. Run the 512K and 1M arms at BOTH the pessimistic
latency (8, isolates pure capacity cost) AND a scaled latency (512K→5, 1M→6, via
L2_HIT_LATENCY in the same shadow build) — the batch2 finding that parser gains +57.5%
instret at lat-2 means the scaled arms may be net-POSITIVE on the most capacity-exposed
member; without the scaled arms the sweep systematically under-credits small L2.
(Adds 4 builds: 512K/1M × lat-scaled × {64K, 32K or 128K L1D as the cross-term demands};
prune to the interesting corners after the first 9-arm readout.)

**Hygiene:** every arm built from a shadow tree; baselines re-run on the same binary
generation (no cross-generation deltas); all runs PASS-at-tohost or flagged; suite
no-regression invariant applies only to the shipping config (2M/64K), not the DSE arms.

## Side-effects unlocked by step 0 (queued, not in this sweep)

- **P1 multi-outstanding fills re-read:** the §1 P1 refutation is conditional on the
  1-cycle memory (fills nearly free). At L=80 with MLP>1 workloads, multi-outstanding
  fills may matter again — re-run the lat-proxy logic there before re-closing.
- **L2 prefetcher re-read** (§3.6 kill was sign-inverted by the same artifact).
- **L2 hit-latency 8 vs the L2_FILL_COMB arm** re-read at real miss costs.

# Real-Kernel (Paged Linux Boot) Bottleneck Map — 2026-06-14

**The point of the pivot:** measure rv64gc-v2 under a *real paged kernel* (Sv48, satp
set, real TLB/page-walk/memory traffic, cold I-cache over the kernel code footprint)
instead of bare-metal benchmarks — to see whether the system-level levers deferred in
`doc/rv64gc_v2_uplift_roadmap_2026-06-13.md` §6 ("unmeasurable on bare-metal, needs a
paged workload": idea-3 TLB/PTW hierarchy, idea-7 L2-QoS, idea-8 ICache-MSHR) have real
headroom that bare-metal hid.

**Tree:** committed at `e3c6f06`. Functional RTL untouched (READ-only); the only changes
are sim-only profiler counters (`src/rtl/sim/mmu_mem_profiler.sv`,
`src/tb/tb_linux.sv` dump) — proven non-perturbing (see Methodology).

**Workload:** `build/linux_boot_full/fw_payload.hex` (OpenSBI v1.3 + Linux, Sv48), the
WORKING PARTIAL boot that reaches early kernel up to the `9p: Installing v9fs` milestone
(~14.5M cyc) before the post-9p hang a separate agent is fixing. The 0→14M window is the
real paged kernel: OpenSBI (M-mode) → kernel-init → paging-on → device/subsystem init.

**Runs (both cycle-identical, see Methodology):**
- `log/realkernel_2026-06-14/boot_14M_perf.log` — 14.0M cyc, base profiler. Authoritative
  full-to-9p translation/fetch/IPC dataset.
- `log/realkernel_2026-06-14/boot_qos_10M.log` — 10.0M cyc, +L2-QoS/ICache-MSHR counters.
  Authoritative L2-arbitration dataset.

**Tool:** `tools/realkernel_bottleneck_map.py` (parses the paired
`[LINUX_STATUS]`+`[PERF_PROFILE]` interval dump).

---

## Headline

| Phase | window (cyc) | IPC | character |
|---|---|---|---|
| **M-mode / OpenSBI** | 0 → 2.0M | **2.635** | unpaged, ≈ bare-metal CoreMark (2.18–2.65) |
| **Paged S-mode kernel** | 2.0M → 14.0M | **1.401** | the real-kernel signal |
| **Overall boot** | 0 → 14.0M | **1.577** | 22.08M instret / 14.0M cyc |

For reference the Stage-5 pre-VIPT boot (`doc/stage5_paged_ipc_profile_2026-06-02.md`) was
overall **0.90** / paged **0.758**. **VIPT (Stage-5b) nearly doubled paged IPC** — and the
profile below shows *why*: the dominant Stage-5 bottleneck is gone.

### The one-line read

**The real-kernel execution does NOT reveal the system-level translation/fetch/L2-QoS
bottlenecks the deferred levers were meant to attack. Post-VIPT the front end is clean
(`fe_stall_xlate = 0`, ITLB ~98% hit, L1I supply ~6% of cyc, L2 ICache-starve 0.25%). The
2.6→1.4 paged-IPC drop is BACKEND back-pressure (73% of fetch stalls) + D-cache misses
(8.3%) + the irreducible character of kernel-init code (memset/driver-poll phases). That
is the same backend/chain band the bare-metal scoreboard already maps — the kernel is a
bigger instance of it, not a new system-level wall. GO/NO-GO below: all three deferred
levers read NO-GO or WEAK on the real-kernel data.**

---

## 1. The real-kernel bottleneck map (paged region, cyc 2.0M→14.0M, 12.0M cyc)

Counters: `mmu_mem_profiler` (family 1/3/4/5) + `fetch_frontend_profiler` fe_stall split.
`itlb_*`/`dtlb_*`/`ptw_*`: `mmu_mem_profiler.sv`. `fe_stall_*`:
`fetch_frontend_profiler.sv:1533-1537`. L2-QoS/MSHR (family 5): the QoS-boot 8M window
(cyc 2.0M→10.0M), `mmu_mem_profiler.sv` family-5 block.

### TRANSLATION — idea-3 (TLB/PTW hierarchy)
| counter | value | rate |
|---|---|---|
| itlb_lookups | 11,750,612 | — |
| itlb_misses | 168,999 | **1.44%** of lookups |
| dtlb_lookups | 9,107,197 | — |
| dtlb_misses | 453,975 | **4.99%** of lookups |
| ptw_walks (itlb+dtlb) | 33,773 | 6,077 I + 27,696 D |
| ptw_busy_cycles | 606,594 | **5.05%** of paged cyc |
| **cyc / walk** | **18.0** | Sv48 4-level, **no page-walk cache** |
| ptw_faults | 655 | — |
| **fe_stall_xlate** | **0** | **0.000% of paged cyc** |

- **`fe_stall_xlate = 0` over the ENTIRE paged boot.** The Stage-5 dominant bottleneck
  (fetch translation-stage stall, ~47% of all cycles, `stage5_paged_ipc_profile_2026-06-02.md`)
  is *completely eliminated* by VIPT fetch. Verified directly — confirms the Stage-5b win
  holds under the real kernel. (Driver: `fetch_frontend_profiler.sv:1536`, fired only when
  fetch presents a VA and the icache req has not launched; VIPT launches them in parallel.)
- **ITLB ~98.6% hit, DTLB ~95% hit** under the real kernel footprint. The TLBs are
  **ASID-tagged** (16-bit, `itlb.sv:21,47,73`; selective ASID invalidation
  `itlb.sv:126-138`) so context switches across the boot's many processes do NOT
  blanket-flush — that is why miss rates stay low even at multi-process kernel scale.
  `flush_satp = 3` (whole boot) confirms near-zero global TLB flush.
- **Sv48 walk cost is real but small in aggregate:** 18 cyc/walk × 33,773 walks ≈ 607K cyc
  = 5.05% of paged cyc. There is **no page-walk cache** (confirmed: `ptw.sv` walks
  `walk_level 3→0` serially, `ptw.sv:295,303-332`, each level a fresh L2 round-trip at PTW
  priority). The 18 cyc/walk is *below* a worst-case 4×L2-latency because most walks hit
  warm upper-level PTEs in L2 (an implicit cache in the L2 itself).

### FETCH / I-SIDE — idea-8 (ICache MSHR / NLPB)
| counter | value | of paged cyc |
|---|---|---|
| fe_stall_total | 3,120,094 | **26.0%** |
| — fe_stall_backend | 2,274,007 | **72.9% of fe_stall** |
| — fe_stall_xlate | 0 | 0.0% |
| — fe_stall_icache (supply) | 846,087 | **27.1% of fe_stall** (≈ 7.1% of cyc) |
| ic_mshr_full_cyc | 102,270 (QoS 8M win) | **1.28%** of paged cyc |

- The front end stalls 26% of paged cycles, but **73% of that is BACKEND back-pressure**
  (the front end has packets, the backend can't take them) — not an I-side supply problem.
- I-cache *supply* stall (fe_stall_icache) is 7.1% of cycles. The 32 KB 8-way VIPT L1I
  holds the kernel code footprint well; the supply stalls are cold-fill bursts during new
  driver/subsystem code, not steady thrash.
- **NLPB next-line prefetcher is hard-gated OFF under VM:** `nlpb_trigger = !instr_vm_active_i
  && ...` (`ifu_line_fetch.sv:225-226`); the merged-resp / lookup paths are likewise
  `!instr_vm_active_i`-gated (`ifu_line_fetch.sv:226,364`). So under the paged kernel the
  I-prefetcher *never fires* — every I-miss is demand. This is the idea-8 structural fact:
  the prefetcher that hides cold I-fetch on bare-metal is disabled exactly when the kernel
  code footprint is largest.
- **ICache MSHR (IC_MSHR_DEPTH=2, `icache.sv:225`) full only 1.28% of cyc.** Even with NLPB
  off and the large footprint, two outstanding I-misses are almost never both occupied.

### MEMORY / L2 QoS — idea-7 (L2 source arbitration)
L2 strict fixed priority **DCache > PTW > ICache > Prefetch** (`l2_cache.sv:487-512,
526-537`). QoS-boot 8M paged window (cyc 2.0M→10.0M):
| counter | value | rate |
|---|---|---|
| dcache_accesses | 1,783,644 | — |
| dcache_misses | 240,697 | **13.5%** of accesses (this window) |
| L2 grants total | 1,208,807 | — |
| — DCache (prio 1) | 1,080,455 | **89.4%** |
| — PTW (prio 2) | 69,427 | **5.7%** |
| — ICache (prio 3) | 58,925 | **4.9%** |
| l2_icache_req_cyc | 79,296 | cyc ICache wanted L2 |
| **l2_icache_starve** | **20,358** | 25.7% of ICache-L2-req cyc; **0.25% of paged cyc** |
| — lost to DCache | 20,064 | (98.6% of starves) |
| — lost to PTW | 294 | (1.4% of starves) |
| l2_dc_ptw_collide | 9,840 | cyc DCache AND PTW both want L2 |

- **D-cache miss rate is the genuinely-elevated real-kernel signal: 8.3% (full 14M window) /
  13.5% (8M window).** The real kernel working set stresses L1D far more than the
  bare-metal resident loops (Stage-5 measured ~1.7%). This is a *D-side memory* signal — it
  feeds the backend back-pressure above (load-use latency), not the I-side or translation.
- **L2-QoS is a non-issue.** ICache loses L2 arbitration only **0.25% of paged cycles**, and
  98.6% of those losses are to DCache (not PTW). DCache+PTW collide only 9,840 cyc. ICache
  barely touches L2 at all (4.9% of grants) because the L1I hit rate is high. The fixed
  DCache>PTW>ICache priority does **not** starve the I-side under kernel D+PTW traffic.

### FLUSHES
flush_commit 232,884 (trap/exception/sret path) · flush_bru 0 · flush_satp 3. Negligible.

### Per-phase IPC (boot taxonomy)
The boot is not uniform. Representative interval IPCs (full table in tool output):
- **OpenSBI / kernel-init (0→3M):** 2.2–2.85 — clean, near bare-metal.
- **Paging-on + early driver (3.25M→6.25M):** dips to **0.48–1.06**, fe_stall_backend
  spikes to **47%**, fe_stall_icache to **25%** — a cold-code + backend-bound band
  (subsystem init: memset-heavy + driver probe).
- **Mid kernel-init (6.5M→8M):** recovers to 2.0–2.8.
- **Driver-reg / 9p approach (8M→14M):** settles ~1.1–1.9 with periodic
  fe_stall_backend 47–50% dips (12M–13.75M) — backend-bound driver loops.
- `fe_stall_xlate = 0.00%` in **every** interval — translation never stalls fetch, in any
  phase.

---

## 2. Per-deferred-lever headroom + GO/NO-GO

| lever (roadmap §6) | real-kernel signal | apparent headroom | verdict |
|---|---|---|---|
| **idea-3 — TLB/PTW hierarchy** (bigger ITLB/DTLB, page-walk cache) | ITLB 98.6% hit, DTLB 95% hit (ASID-tagged); ptw_busy 5.05% of cyc, 18 cyc/walk, no PWC | ITLB enlarge ≈ **0** (already ~98.6%). A page-walk cache could shave part of the 5.05% ptw_busy, but most walks already hit warm upper PTEs in L2. **Ceiling ≈ a few % of paged cyc, D-side only.** | **NO-GO / WEAK.** TLBs are already well-sized + ASID-tagged. A PWC is the only non-trivial idea here and its ceiling is ~5% (and partly captured by L2 already). Revisit only if a steady-state (post-boot, multi-process) workload pushes DTLB miss higher. |
| **idea-7 — L2 QoS** (de-prioritize/credit the ICache fill port vs DCache/PTW) | ICache loses L2 arb **0.25% of paged cyc**; 98.6% of losses to DCache; ICache = 4.9% of L2 grants | **≈ 0.25% of cyc**, and re-prioritizing ICache over DCache would *hurt* the dominant D-side. | **NO-GO.** The premise (ICache starves under kernel D+PTW traffic) is **measured-false**. ICache rarely needs L2 (high L1I hit); when it does, the conflict is with DCache, where DCache should win. No QoS lever clears noise. |
| **idea-8 — ICache MSHR depth** (deeper than 2; re-enable NLPB under VM) | ic_mshr_full 1.28% of cyc; fe_stall_icache 7.1% of cyc; **NLPB OFF under VM** (`ifu_line_fetch.sv:225`) | MSHR-depth: **≈ 1.3%** ceiling. NLPB-under-VM: bounded by fe_stall_icache 7.1%, but most of that is cold compulsory fill the prefetcher can't fully hide. | **WEAK.** Deeper MSHR ≈ 1.3% ceiling — sub-noise. **Re-enabling NLPB under VM is the only idea here with a plausible >1% return** (it currently does literally nothing in paged mode while the kernel footprint is largest) — but it's bounded by ~7% fe_stall_icache and requires a VIPT-safe prefetch-translation path. **Candidate for a *separate* boot-I-prefetch study, NOT a system-level-program justification.** |

### The verdict the user asked for ("do we see perf under the current implementation?")

**NO-GO on the system-level program (TLB/PTW hierarchy + L2 QoS + ICache MSHR depth as a
bundle).** The real-kernel execution does **not** expose the translation / I-side / L2-QoS
bottlenecks those levers target:

1. **Translation is already solved** post-VIPT (`fe_stall_xlate = 0`), and the TLBs are
   well-sized + ASID-tagged (ITLB 98.6%, DTLB 95% hit). idea-3's biggest sub-idea (PWC)
   has a ~5% D-side ceiling, mostly L2-absorbed.
2. **L2-QoS premise is measured-false** — ICache starves 0.25% of cyc, and against DCache
   (where DCache rightly wins). idea-7 = noise.
3. **ICache MSHR depth = 1.3% ceiling** — sub-noise. idea-8 = noise *except* the
   NLPB-OFF-under-VM observation, which is a real but bounded (~≤7%) and *separate* lever.

**Where the real-kernel cycles actually go:** the paged 2.6→1.4 IPC drop is **backend
back-pressure (73% of the 26% fetch-stall) + D-cache misses (8.3–13.5%, the one genuinely
real-kernel-elevated signal) + the irreducible memset/driver-poll character of kernel-init
code** (the 0.48–1.06 IPC dips). That is the *same* backend/chain/memory band the bare-metal
42-row scoreboard already maps (roadmap §3 chain band, §4.5 store-commit, G4/G5 LSU) — the
kernel is a larger instance of the known backend story, not a new system-level wall.

**The honest positive finding:** the pivot's *premise* — that bare-metal hid a real-kernel
signal — is **confirmed for exactly ONE thing: the D-cache.** Real-kernel L1D miss (8–13%)
vs bare-metal (~1.7%) is the only metric that materially worsens under the real workload.
That points back at the **already-gated** LSU levers (G4 LMB port-1 drain, G5
multi-outstanding L1D fills, roadmap §1 phase-3) and the cache-sizing track — not at the
TLB/PTW/L2-QoS system-level bundle.

**The one new lever this surfaced:** **NLPB next-line prefetch is disabled under VM**
(`ifu_line_fetch.sv:225-226`) — so the kernel runs with *zero* I-prefetch over its largest-ever
code footprint. fe_stall_icache 7.1% of paged cyc is the bound. This is worth a dedicated,
small boot-I-prefetch study (VIPT-safe prefetch-translation), but it is **not** a
justification for the deferred system-level program.

---

## 3. Methodology / validity

- **Counters non-perturbing (proven):** the base 14M boot and the +QoS 10M boot are
  **bit-identical** at cyc 6.0M on every shared counter (itlb_misses=162,287,
  dtlb_misses=356,186, ptw_walks_dtlb=14,154, dcache_misses=99,683, fe_stall_total=1,537,064,
  minstret=10,409,319 — all exact). The family-5 L2-QoS/MSHR counters are pure observers
  (`always_ff` reads of existing L2 ports `u_l2_cache.*` and `u_icache.ic_mshr_free_avail`);
  they drive nothing. So the two logs are one coherent cycle-identical dataset.
- **`ptw_busy_cycles` counter VERIFIED FIXED:** the Stage-5 stuck-flag bug (boot read ~93%,
  ~580 cyc/walk) is gone — the flush-clear terms (`ptw_walk_end` now includes
  `ptw_itlb_fault || ptw_dtlb_fault || ptw_flush_abort`, `mmu_mem_profiler.sv:57-59`) make it
  read **18 cyc/walk** (realistic Sv48). Confirmed sane at every interval.
- **Lint:** the +QoS build is Verilator-clean apart from the pre-existing waived UNOPTFLAT
  set (ftq.sv:103 + the external cvfpu library) — **zero** new warnings from the added
  counters. SIMULATION-gated (compiled out of synthesis).
- **No functional RTL touched** — `git diff --name-only` = `src/rtl/sim/mmu_mem_profiler.sv`,
  `src/tb/tb_linux.sv` only. The 9p-hang debug agent's runs coexisted (≤4 sims, load <4 on
  16 cores, all `nice -n 10`).

### Key file:line references
- VIPT fetch-translation (fe_stall_xlate driver): `fetch_frontend_profiler.sv:1533-1537`
- ptw_busy_cycles flush-clear fix (VERIFIED): `mmu_mem_profiler.sv:57-59` (`ptw_walk_end` now ORs in fault + flush-abort)
- Sv48 4-level walk, no PWC: `ptw.sv:295,303-332`
- TLB sizing + ASID: `rv64gc_pkg.sv:92-93` (ITLB 16 / DTLB 32), `itlb.sv:21,47,73,126-138`
- L2 strict fixed priority DCache>PTW>ICache>Prefetch: `l2_cache.sv:487-512,526-537`
- ICache MSHR depth 2: `icache.sv:225`
- NLPB gated OFF under VM: `ifu_line_fetch.sv:225-226,364`
- L1I 32KB/8-way VIPT, L1D 64KB/4-way, L2 2MB/8-way 8-cyc: `rv64gc_pkg.sv:141-154,255-261`
- New family-5 L2-QoS/MSHR counters: `mmu_mem_profiler.sv` (Family 5 block + bind)

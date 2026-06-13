# UOP-CACHE-REPACK pre-RTL gate (2026-06-13)

The §4.8 offline replay model the prior repacker studies lacked, executed for the
**uop-cache-REPACK** lever (`doc/arch_refactor_plan_gen2_2026-06-13.md` stage 4;
decision context `doc/ipc3x_gate_results_2026-06-11.md` §4.5). This is the
data-before-RTL gate that must clear before the ~600-line RTL revival of the
as-built UOC (`src/rtl/core/uop_cache/`, 740 L).

**Thesis under test.** A *fill-time-packed* UOC delivers DENSE 4-µop traces that
cross taken edges + line boundaries, filling the truncation slots the line-path
leaves empty (10–46% of cycles on supply rows). It realizes **UB × hit-rate**
(the dense trace is RESIDENT from a prior loop pass) — sidestepping the
emit-time repacker's donor-unrequested-90-100% kill (§4.5 item 1), because the
donor is the resident dense entry, not a co-in-flight packet. Geometry = the
as-built **32 sets × 8 ways × 4 µops/entry = 1024-µop** capacity
(`rv64gc_pkg.sv:117-119`).

## 1. Method

### 1.1 Trace instrument (`+UOCTRACE`, sim-only)
Added a minimal per-delivered-group dump to the existing fetch profiler
(`src/rtl/sim/fetch_frontend_profiler.sv`, ~40 lines, following the census2 /
batch-#4 idiom). One `[UOCG]` line per delivery cycle (`fetch_count != 0`, i.e.
`packet_buf_head` drained to decode), one `[UOCF]` line per backend/commit flush
(`redirect_valid` → trace-restart marker). Each `[UOCG]` carries: head PC, raw
fetch count 1–4, the **batch-#4 group-end cause** classifier verbatim
(taken-ctl / line-complete-seq / redirect-tail / backend-zeroout / straddle-guard
/ other / full-4), the 4 slot PCs + is-RVC + **expanded-32-bit** raw insns
(for indirect/serializing detection in the model), `ifu_line_addr`,
`ftq_owner_complete`, the bp-taken mask, and the taken target.

**Gates passed (the standard ladder):**
- **lint = 15 UNOPTFLAT** (baseline; the dump adds no combinational logic).
- **ENABLE-off bit-exact**: same instrumented binary, `+UOCTRACE` OFF vs ON, rsort
  PASS at **cycle 101016, mcycle 100977, minstret 317160 — identical** both arms,
  and identical to the `log/piece2_runs/suite_on/` golden. The instrument is a
  pure observer (timing-neutral).
- Built in a fresh work dir (`verilator_bench_uoctrace/`) — the promoted tree and
  existing arms untouched.

### 1.2 Offline repack model (`tools/uoc_repack_model.py`, rerunnable)
Replays the trace through a model of the fill-time-packed UOC:
1. **FILL** — accumulate decoded µops into DENSE entries (≤4 µops) ACROSS
   packet / line / *direct*-taken-edge boundaries. Seal-and-restart on: entry
   full at 4; **indirect** target (JALR / RET / C.JR / C.JALR — successor PC not
   statically known at fill time); **serializing** op (CSR / FENCE / FENCE.I /
   AMO / ECALL / EBREAK / *RET); flush/exception. Direct control (JAL / Bcc) is
   packed *through* — the whole point of the lever.
2. **INSTALL** — 32 sets × 8 ways, index = head_PC[5:1], tag = head_PC≫6,
   tree-pLRU victim (the as-built geometry).
3. **LOOKUP** — at each dense-entry head, HIT iff a matching entry was resident
   BEFORE this pass (re)installs it → **MEASURED residency = realized hit**.
4. **RECOVERY** — a truncating group's empty slots (4−n) are recovered iff a
   *resident* dense entry packs through it (this is UB × hit-rate by
   construction); `recovered_cycles = recovered_slots / 4`. Then two measured
   caps: **wrong-path derate** (recovery on squashed/wrong-path delivery saves 0
   commit cycles; factor = instret / delivered-µops) and the **chain/backend
   ceiling** (a fetch lever cannot exceed the rate the backend retires when not
   fetch-starved — the supply==IPC identity of §3.1).

**Stated optimism (where the model could over-credit):**
- Packs *through* direct conditional branches assuming the resident entry's
  prediction matches this pass — intra-loop branch flips beyond the `[UOCF]`
  restart are not modeled. Optimistic where a dense entry spans a flipping
  conditional.
- Assumes every recovered delivery cycle is on the IPC critical path (1:1) —
  the standard supply-UB optimism, identical to the §4.3 fusion-corrected UB the
  proxy targets were derived from, so the model output is *directly comparable*
  to the proxy.
- The chain/backend ceilings (crc32 2.30, CM 2.80) are **measured inputs** from
  `ipc3x_structural_study_2026-06-10.md:27` + §3.1, not derived from the trace —
  flagged explicitly. They are what keep the chain-bound control honest.

## 2. Results — MEASURED hit-rate + realizable IPC vs proxy

All baselines = promoted config, `log/piece2_runs/suite_on/`. Traces:
`/tmp/uoctrace/*.log` (rsort `/tmp/uoc_rsort.log`). Model output:
`/tmp/uoc_model_full.txt`. CM ran iter1 (`coremark.hex`, PASS 158,721 cyc) — the
2.93 UB and 2.4–2.8 chain band apply identically to iter10.

| workload | base IPC | MEASURED HR | recovered (post-derate) | **PROJECTED IPC** | proxy | divergence | bar | verdict |
|---|---:|---:|---:|---:|---:|---:|---|---|
| **rsort** | 3.141 | **100.0%** | 9.4% of cyc | **3.467** | 3.47 | −0.003 | ≥~3.4 | **CONFIRM** |
| **DS-ww** | 2.789 | **100.0%** | 22.5% of cyc | **3.598** | 3.55 | +0.048 | ≥~3.5 | **CONFIRM** |
| **DS** | 2.614 | **100.0%** | 16.6% of cyc | **3.135** | 3.13 | +0.005 | ≥~3.1 | **CONFIRM** |
| **statemate** | 2.973 | **79.5%** | 11.5% of cyc | **3.358** | 3.37 | −0.012 | ≥~3.2 | **CONFIRM** |
| crc32 (ctrl) | 2.300 | 100.0% | **0** (chain) | **2.300** | ~0 gain | 0.000 | control | **HOLDS** |
| CM (ctrl) | 2.093 | 98.5% | 21.0%→capped | **2.648** | DEAD | — | ≤2.93 | **DEAD/HOLDS** |

**Where measurement diverges from proxy:**
- **rsort / DS / statemate land within ±0.013 of proxy** — the model independently
  reproduces the §4.3 fusion-corrected UBs almost exactly. statemate confirms
  *despite* losing 20.5% of its UB to set conflict (see §3): proxy 3.37 assumed
  near-full residency; measured HR 79.5% pulls realizable to 3.358, still clearing
  ≥3.2.
- **DS-ww measures ABOVE proxy (3.598 vs 3.55)** at full residency. DS-ww's working
  set (220 trace heads) fits the 256-entry cache; the lever realizes its UB. The
  proxy was conservative.
- **No crossing collapses.** Every UB-bar-crosser confirms; the divergences are all
  small and favorable except statemate's −0.012 (noise).

**Controls reproduced (the model-correctness test):**
- **crc32**: MEASURED HR 100% (4-instr tight loop, fully resident, 64 trace heads)
  but **realized recovery = 0 cycles → projected IPC = 2.300 = base, exactly.**
  The raw supply pool is large (32.5% of cycles are truncation slots, taken=33%
  + straddle=22%) but it is **HIDDEN BY THE 9–11 cyc PRNG carried chain**
  (study:27) — supply==IPC, no fetch bubble to fill. This is precisely the
  required control behavior; the chain ceiling drives realized gain to 0.
- **CM**: projected 2.648, **capped under both the 2.80 chain ceiling and the
  2.93 perfect-frontend UB** → CM stays DEAD (never reaches the 2.95 roster bar).
  It lands squarely in the study's measured "post-frontend 2.4–2.8" band. The
  wrong-path derate is material here (82.2% commit fraction — CM is misp-heavy,
  mean streak 23.6, 3,882 flushes).

**A model bug found and fixed (recorded for reuse).** The `fetch_insn[]` field in
the trace stores the **expanded 32-bit form** of every slot even for RVC
(verified: low-2-bits == 0b11 on all RVC slots — the IFU expands C.* → 32-bit in
the fetch group). The first model decode keyed on `is_rvc` and mis-classified
expanded `ret`/`jalr` (opcode 0x67) as plain → the dense builder packed *through*
indirect edges, inventing bogus long traces that inflated the DS-ww/statemate
working sets and produced a **false** 71.9% DS-ww HR. Fixed to always decode the
32-bit field; DS-ww HR corrected to 100% (WS 374→220 heads) and statemate's HR
moved to the true 79.5% (its real set conflict). The control crc32/CM were
unaffected by the bug (their gain is chain-capped regardless). `tools/` decoder
now documents this; any future trace consumer must decode the expanded field.

## 3. Set-conflict / working-set-overflow findings

Per-set pressure (distinct dense-trace heads competing for the 8 ways) at the
as-built 1024-µop geometry:

| workload | distinct trace heads | cap mult | sets >8 | evicts | **MEASURED HR** | note |
|---|---:|---:|---:|---:|---:|---|
| crc32 | 64 | 0.25× | 0/32 | 0 | 100.0% | trivially fits |
| rsort | 181 | 0.71× | 1/32 | 1 | 100.0% | fits |
| DS | 200 | 0.78× | 6/32 | 9 | 100.0% | fits |
| DS-ww | 220 | 0.86× | 7/32 | 14 | 100.0% | fits (knife-edge) |
| **statemate** | **352** | **1.38×** | **23/32** | **183,330** | **79.5%** | **real set conflict** |
| CM (iter1) | 1,255 | 4.90× | 32/32 | 2,491 | 98.5% | pLRU holds hot WS |
| parser | 1,657 | 6.47× | 32/32 | 109,306 | 92.0% | pLRU holds hot WS |
| cjpeg | 2,843 | 11.1× | 32/32 | 81,490 | 94.4% | pLRU holds hot WS |

- **statemate's set conflict is the one that bites a UB-bar-crosser** (final
  occupancy **7.69/8**, matching the docs' "7.81/8" finding; 23/32 sets with
  avg 12.6 heads contending for 8 ways). It costs statemate **20.5% of its UB**
  (HR 79.5%), yet it still clears ≥3.2 at the realized 3.358. The other crossers
  (rsort/DS/DS-ww) fit the cache outright (HR 100%).
- **parser / cjpeg do NOT catastrophically thrash at 1024-µop.** Their static
  trace-head footprint overflows the cache 6–11× and oversubscribes **all 32
  sets**, but the *hot* loop nest stays resident under tree-pLRU → **HR 92–94%**
  (same regime as CM at 98.5% / 4.9×). The 1024-µop cache is conflict-pressured
  on big-body code but the eviction is on cold heads; the hot path survives. This
  is a useful sizing datapoint: a bigger UOC would help parser/cjpeg residency at
  the margin, but the current geometry is not a wall for them. (parser/cjpeg ran
  to ~1.9M cyc of a 5M cap — steady-state WS is fully established; logs
  `/tmp/uoctrace/{parser,cjpeg}.log`.)

## 4. FUND / KILL verdict

**FUND rule** (from the task): FUND if ≥2 of {rsort ≥ ~3.4, DS-ww ≥ ~3.5, DS ≥
~3.1} confirm AND statemate's measured set-conflict keeps it ≥ ~3.2.

| crosser | bar | measured | pass? |
|---|---|---:|---|
| rsort | ≥ ~3.4 | **3.467** | ✅ |
| DS-ww | ≥ ~3.5 | **3.598** | ✅ |
| DS | ≥ ~3.1 | **3.135** | ✅ |
| statemate | ≥ ~3.2 (post-conflict) | **3.358** | ✅ |

**All 4 crossers confirm** (4/4, not just the required 2/3) AND statemate holds
≥3.2 despite a measured 20.5%-of-UB set-conflict loss. The controls hold: crc32
realized gain = 0 (chain hides the supply pool), CM stays DEAD ≤2.93. The HR does
NOT collapse the crossings — three of four fit the cache at 100% HR; statemate's
79.5% is survivable.

### **VERDICT: FUND.**

The repack thesis is confirmed by measurement: a fill-time dense-packed UOC
realizes UB × hit-rate, and on the supply-bound roster band the hit-rate is high
enough (79.5–100%) that the realizable IPC clears every bar. The lever adds
**rsort 3.14→3.47, DS-ww 2.79→3.60, DS 2.61→3.14, statemate 2.97→3.36** —
i.e. statemate joins the ≥2.95 roster outright and DS/DS-ww become new roster
members (the gen-2 plan's "DS-ww certain-band, DS knife-edge" → both now
certain). crc32 and CM are pre-killed by the chain ceiling, as designed.

This is a *different* result from the emit-time repacker (§4.5 item 1, KILLED):
that lever needed a co-in-flight donor (90–100% donor-unrequested → dead). The
repack UOC's donor is the **resident dense entry** — and residency is exactly
what the measured 79.5–100% HR establishes.

## 5. RTL work-list to revive the UOC for repack (the FUND deliverable)

The as-built UOC (`src/rtl/core/uop_cache/`, 740 L, `UOP_CACHE_ENABLE` default 0)
fills **one post-fusion fetch-group at a time** — it caches exactly the truncated
1–3-µop groups the line path produced (`fused_insn[0..fused_count-1]` keyed by
`fused_insn[0].pc`, `data_wcount_c = fused_count`, `uop_cache.sv:488-531`). That
is the opposite of what this gate proved valuable. The revival inverts five
as-built behaviors; the model above is the executable spec for the fill path.

**The 5 inversions** (sized; all in `uop_cache.sv` unless noted):
1. **Fill accumulator (the core inversion), ~150–200 L.** Replace the single-group
   fill (`fill_pending_c`/`do_fill_c`, :488-531) with a **dense-trace builder**:
   a fill-build register accumulating decoded µops across consecutive fused
   groups, sealing-and-installing on {4 µops, indirect, serializing, flush} per
   the model's §1.2 rules. Install keys on the *build-head* PC, not each group's.
2. **Group-boundary segmentation, ~40–60 L.** Add the seal-stop predicates
   (indirect = JALR/RET/C.JR/C.JALR; serializing = SYSTEM/MISC-MEM/AMO) — decode
   off the fused-group control metadata already present (`pd_ctl_type`, fused
   flags), not a fresh decoder. Direct taken edges (JAL/Bcc) must NOT seal.
3. **Dense replay/emit, ~80–120 L.** On a PLAYING hit the emit must stream the
   **full dense entry** (`uoc_count` up to 4) and advance the lookup PC to the
   entry's *successor* (the post-seal PC, which the entry must store), not to the
   next sequential group. The handoff (`handoff_pc`, :41-42) must carry the dense
   successor.
4. **Lookup-PC source, ~30–50 L.** The as-built lookup drives
   `predicted_next_pc_c` (one group ahead, :260). Repack lookup must key on the
   **trace-head PC** (the dense entry boundary), so the BPU/FTQ predicted next-PC
   feeding the lookup must align to entry heads — the FTQ-validation tie the
   original module deferred (`uop_cache.sv:4-6`).
5. **Dup-detect/victim under dense keys, ~20–30 L.** `dup_skip_c` (:501-503) and
   the pLRU victim (:506-507) assume per-group keys; re-key them to build-head
   PCs (otherwise dense entries duplicate and capacity halves — the model's
   eviction accounting assumes head-keyed pLRU).

**Plus correctness (VA-tagged trace invalidation), ~30–40 L:**
- **satp-write + SFENCE.VMA invalidation.** The trace is VA-tagged; the as-built
  `invalidate` wires only `fence_i_signal` (`core_top:488`). A VM context switch
  (satp write) or SFENCE.VMA aliases stale dense entries. Add satp-write and
  SFENCE.VMA to the `invalidate` term (`rob_head_is_sfence_vma` already exists,
  `core_top:623`). Bare-metal roster is unaffected (no paging) but the gate must
  not ship a paging-incorrect cache.

**Plus TB + ladder, ~50–80 L:**
- Re-enable the smoke TB (`benchmark_results/20260506_uop_cache_folder_split_smoke`
  provenance) under the repack contract; golden-PC scoreboard A/B (dense replay
  must produce a bit-identical commit PC stream vs the legacy frontend);
  lint-15 / ENABLE=0 bit-exact / CM-DS-at-STOP / ≤0.01% suite invariant; the
  `+UOCTRACE` instrument here is the in-RTL validation oracle (the model's dense
  segmentation IS the RTL spec — divergence is a bug).

**Total ≈ 430–600 L** (the gen-2 plan's ~600-L estimate is the upper bound).
RAM **shrinks** vs the as-built (dense entries hold no duplicate packet copies);
the data path is OFF the F1 critical cone (the lever the §4.5.2/§4.5.6 backend
plan froze at 4-wide). Sequence AFTER the F1/F2 backend arms and the M2-spill
prerequisite (the gen-2 plan's stage ordering), and re-sign the standing
ud/minver BP-perturbation residuals — a denser frontend perturbs BP training in
the same class as the cursor fixes (§4.4 M1/M2), so the spill campaign is a hard
prerequisite, not an option.

## 6. Reproduce

```bash
# instrumented binary (fresh work dir, promoted tree untouched):
VERILATOR_BENCH_WORK_DIR=verilator_bench_uoctrace bash scripts/build_verilator.sh
# trace dump (one delivered group per line; ENABLE-off = bit-exact):
VERILATOR_BENCH_BIN=verilator_bench_uoctrace/Vtb_xsim \
  bash scripts/run_verilator.sh tests/hex/rvb-rsort.hex 200000 +UOCTRACE +PERF_PROFILE > rsort.log
# model:
python3 tools/uoc_repack_model.py --name rsort --trace rsort.log
python3 tools/uoc_repack_model.py --name parser --trace parser.log --wsonly
```
Logs of record: `/tmp/uoctrace/*.log`, `/tmp/uoc_rsort.log`, full model output
`/tmp/uoc_model_full.txt`. Instrument: `src/rtl/sim/fetch_frontend_profiler.sv`
(`+UOCTRACE` block, ~40 L). Model: `tools/uoc_repack_model.py`.

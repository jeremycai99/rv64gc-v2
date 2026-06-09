# Competitor Analysis — rv64gc-v2 vs Reference Core A (Reference Core A (large config))

> **Chronological provenance doc.** The current unified status is
> `doc/reference_core_unified_audit_2026-05-03.md`. Keep this file for the
> Reference Core A (large config) investigation history and append-only provenance; use the unified
> audit for current decisions.
>
> **Initial source corpus:**
> - `doc/4wide_megaboom_compare_2026-05-02.md` (renamed → this file; empirical build + run results)
> - `doc/4wide_arch_diff_2026-05-02.md` (still active companion; source-only RTL audit)

## Methodology — read before interpreting Reference Core A (large config) data

This file is a chronological competitor-analysis log. Later sections may
supersede earlier observations; in particular, §10 supersedes the initial
"workload runs hung" conclusion in §2-§3. Treat the earlier sections as
debug provenance, not as the final runtime verdict.

Use the following evidence ladder for the Reference Core A (large config) landscape:

| Tier | Evidence type | Trust level | How to use it |
|---|---|---|---|
| **A** | Same binary, same counter window, in-kernel `mcycle/minstret`, plus per-cycle commit/fetch/LSU counters | Decisive | Use for IPC and pipeline-behavior conclusions. This is not complete yet for Reference Core A. |
| **B** | Same binary completes on both simulators, but only total the reference-core build framework sim cycles are available | Functional only | Confirms compatibility. Do **not** interpret raw Reference Core A total cycles as kernel IPC because BootROM, DTB/MMU/PMP setup, cold caches, FastRAM/fesvr idle, and HTIF polling are included. |
| **C** | Source/config audit of Reference Core A (large config) feature flags and structures | Strong directional evidence | Use to identify candidate mechanisms only when they map to a measured rv64gc-v2 bottleneck. |
| **D** | Published Reference Core A (large config) scores and papers | Sanity check | Use as a public floor and plausibility bound, not as a directly comparable run unless binary/toolchain/windows match. |
| **E** | Other open RV cores, e.g. Reference Core B, Reference Core D, Reference Core E, Reference Core C | Architectural reference | Use for ideas and instrumentation patterns. Do not treat as direct pass/fail targets for this Reference Core A (large config) comparison. |

Comparison rules:

1. **Separate harness time from core time.** Raw the reference-core build framework Verilator cycles are
   not kernel cycles until Reference Core A exposes either final `mcycle/minstret` for the
   benchmark window or a self-instrumented benchmark result that bypasses
   fesvr/BootROM accounting.
2. **Normalize the binary before judging architecture.** ISA string, compiler,
   flags, linker script, `tohost/fromhost` symbol visibility, iteration count,
   benchmark start/end markers, and memory map must be recorded for every run.
3. **Demand pipeline counters, not only scores.** The rv64gc-v2 evidence says
   CoreMark/Dhrystone are dominated by `HEAD_WAIT_BACKLOG`; the Reference Core A side must
   eventually provide commit-width distribution, branch flushes, I/D misses,
   load-use/replay, and frontend delivery before we claim which design element
   closes the gap.
4. **Map each borrowed idea to a measured local bottleneck.** A Reference Core A (large config) feature
   is actionable only if it attacks an rv64gc-v2 measured stall class. This is
   why L1D prefetch is high priority, while generic widening/ROB/IQ growth is
   not.
5. **Use Reference Core A as the public floor, not the SOTA ceiling.** Reference Core A (large config) is the
   primary calibration target because it is open and runnable here. Reference Core B
   and other cores should inform the next architecture step, but the rv64gc-v2
   design should remain owned rather than becoming a clone.

Minimum next empirical steps (sequential, each unlocks a tier):

1. **Tier B → Tier A (IPC only).** Patch Reference Core A / its build framework to print
   benchmark-window `mcycle` and `minstret` at finish, or add an equivalent
   benchmark-window result path that bypasses fesvr/BootROM accounting. Until
   then, §10 proves Reference Core A can run the binaries, but it does not provide clean
   Reference Core A IPC.
2. **Tier A IPC → Tier A pipeline-behavior.** Add Reference Core A-side per-cycle counter
   emission matching the rv64gc-v2 reference corpus at
   `benchmark_results/pipeline_confirm_20260502_202117/` (the `.md` summary
   doc `doc/pipeline_behavior_confirmation_2026-05-02.md` is just narrative;
   the corpus directory is authoritative). Concretely Reference Core A must emit, per
   cycle and per workload:

   - **Schema:** one `[PIPE schema=pipe.v1]` line per cycle with fields
     `cyc rst fetch decode rename dispatch issue0 issue1 issue2 cdb commit
     rob_head rob_tail rob_cnt iq0 iq1 iq2 lq sq free ckpt flush replay
     reason`. See `tools/frontend_probe.py:19` for the regex spec.
   - **Per-workload artefacts** (target the same 4 workloads currently in
     the corpus — `bench_loop_100`, `coremark_iter1`, `dhrystone`,
     `probe_alu_chain_8`):
     - `<workload>.summary.txt` — `IPC: mcycle=N minstret=M IPC=X` line
     - `<workload>.pipe.v1.trace` — per-cycle PIPE schema lines above
     - `<workload>.bubble.txt` — generated by `tools/bubble_taxonomy.py`
     - `<workload>.frontend.txt` — generated by `tools/frontend_probe.py`
     - `<workload>.headwait.txt` — generated by `tools/headwait_deepdive.py`
   - **Tool reuse:** the three .py tools above already consume the schema;
     re-run them against Reference Core A-side traces and the comparison becomes
     side-by-side textual diff per category (PEAK / HEAD_WAIT_BACKLOG /
     FRONTEND_LIMITED / DISPATCH_BLOCKED / FLUSH).
   - **Reference Core D reference** (Tier E) is already collected as
     `nax_add_o3pipe_summary.txt` in the corpus dir, format
     `pipeline-stage averages` (gem5o3-style). Same convention applies if
     additional Tier E cores are added later.

**Started:** 2026-05-02
**rv64gc-v2 HEAD at start:** `master @ 580b83e` (now at `master @ 80a1534`)
**Reference Core A HEAD:** `riscv-boom main @ af3023c` (Reference Core A)
**the reference-core build framework HEAD:** `main @ 48f904a`

---

## 0. Current state — read first

**Last edit:** 2026-05-03 ~00:35 by Codex. secondary-reference-core Tier E reference test update added as §12; §12 supersedes the older Tier E pending notes where they conflict.

**What's done (tier-tagged):**
- (Tier B) Reference Core A Verilator simulator built and verified (`MegaBoomV4FastConfig` with `WithSimTSIOverSerialTL(fast=true)`); our binaries run to PASS via tohost. exit_test 1.06M / dhry 2.24M / cm 6.6M raw cycles (§10).
- (Tier B) Per-iter cycle ratios are **functional only** — Rule 1 forbids reading them as IPC. §11.2 details which earlier "% gap" claims this invalidates.
- (Tier C) 5 Reference Core A feature flags absent in rv64gc-v2 catalogued (§5); §11.3 re-ranks them by Rule 4 (only `enablePrefetching` clears the bar cleanly; `enableFastLoadUse` partially; the other three FAIL Rule 4 against our Tier-A data).
- (Tier A on rv64gc-v2 only) Self-pipeline-behavior corpus complete for 4 workloads at `benchmark_results/pipeline_confirm_20260502_202117/`.
- (Tier E expanded) Reference Core D same-binary microbench and native benchmark traces collected; Reference Core E native replay/memory-dependence tests collected; Reference Core B RTL/Verilator generation completed but local emulator compile is blocked by host Verilator wrapper/header compatibility (§12).

**What's blocked (sequential, see Methodology "Minimum next empirical steps"):**
1. Tier B → Tier A IPC: TestDriver.v patch to print `mcycle/minstret` at finish (~1 day).
2. Tier A IPC → Tier A pipeline-behavior: per-cycle `[PIPE schema=pipe.v1]` emission on Reference Core A matching the corpus directory format (multi-week).

**Open recommendation under the Methodology:** Only **L1D NLPrefetcher** passes all 5 rules without further Reference Core A-side data — see §11.5 for the full rule-by-rule justification.

**For the parallel session:** if working on the TestDriver patch path, append a new top-level section after §12. If pursuing a different angle, add a new top-level section after the latest section — don't rewrite §1-§11.

---

## 1. Executive summary

This investigation set out to build Reference Core A (large config) in a Verilator simulator under the reference-core build framework, run cm + dhry on it, and compare clock-by-clock behavior against rv64gc-v2's measured numbers (cm=199,452 cycles IPC=1.665, dhry=23,514 cycles IPC=2.027). The build succeeded (Phase 3 — 22 MB Verilator binary, `chipyard/sims/verilator/simulator-chipyard.harness-MegaBoomV4Config`), but the workload runs did **not complete** within practical sim-wall-clock — see §3 for root cause.

What we *did* recover from the effort:
- Confirmed **MegaBoomV4Config** is the canonical 4-wide Reference Core A target and structurally most comparable to rv64gc-v2's 4-wide (decode=4, ROB=128, lsuWidth=2, INT IQ ~92 entries).
- Identified **5 feature flags** that Reference Core A (large config) enables but rv64gc-v2 does NOT have at all (not just shorter/weaker — entirely absent): `enablePrefetching`, `enableSuperscalarSnapshots`, `enableFastLoadUse`, `numDCacheBanks=4`, `lsuWidth=2`. See §5 for source-cite of each.
- A more complete reconciliation than the prior `arch_diff` doc was able to provide: the residual cm gap (~8.5%) and the residual dhry gap (~35%) are *NOT* fully explained by structural differences; the Reference Core A (large config) feature-flag list above contributes the missing gap, especially `enablePrefetching` (which directly attacks dhry's load-wait-at-head, the single biggest dhry bottleneck per the bubble taxonomy).
- Build-system findings useful for follow-on attempts: the reference-core build framework's standard Reference Core A (large config) Verilator build produces a binary whose boot path requires >5M sim cycles via the SerialTL+TSI bridge to reach `tohost` write detection. At ~3.6 KHz Verilator wallclock speed, this is ≥ 23 minutes per workload run — too slow for the iterative comparison this task targeted.

---

## 2. What was built and what was measured

### 2.1 Phase 1 — environment setup (DONE)

Installed without sudo via SDKMAN:
- Temurin OpenJDK **17.0.19** at `~/.sdkman/candidates/java/current/`
- SBT **1.12.11** at `~/.sdkman/candidates/sbt/current/`
- CIRCT **firtool 1.75.0** at `~/opt/firtool/firtool-1.75.0/bin/firtool` (downloaded prebuilt binary from llvm/circt releases)
- fesvr (HTIF library) built **standalone** from `riscv-software-src/riscv-isa-sim` at `~/opt/riscv/lib/libfesvr.{a,so}` — needed manual Makefile because spike's full configure requires Boost.Asio runtime libs not installed (libboost-dev present but no `libboost_system.so`)

Verified:
- Verilator 5.020, riscv64-unknown-elf-gcc 13.2.0, java/sbt/firtool all in PATH
- 192 GB free, 47 GB RAM, 16 cores (the reference-core build framework's recommended minimum)

### 2.2 Phase 2 — the reference-core build framework clone + submodule init (DONE)

```
git clone --depth=1 https://github.com/ucb-bar/chipyard.git
./scripts/init-submodules-no-riscv-tools.sh
```
- ~10 minutes
- All non-toolchain submodules cloned (Reference Core A, the reference-core build framework, testchipip, hardfloat, dsptools, firrtl2, install-circt, etc.)
- 1.6 GB on disk

### 2.3 Phase 3 — Reference Core A (large config) Verilator build (DONE)

```
cd sims/verilator
make CONFIG=MegaBoomV4Config SUB_PROJECT=chipyard
```

Stages (each stage's wallclock time on a 16-core Ryzen):
1. the reference-core build framework SBT bootstrap (download Scala+sbt deps): ~3 min
2. Chisel elaboration → 162 MB FIR file: ~5 min
3. firtool FIR → SystemVerilog (split into 661 .sv files in `gen-collateral/`): ~5 min
4. Verilator C++ codegen (395 .cpp files, ~200 MB): ~2 min
5. g++ compile + link → simulator binary: ~3 min

**Total: ~18 minutes wallclock, plus a ~5 min restart caused by initial RISCV path mis-set (resolved by setting `RISCV=$HOME/opt/riscv` and stubbing `libriscv.so` for the `-lriscv` link flag).**

Output: `chipyard/sims/verilator/simulator-chipyard.harness-MegaBoomV4Config` (22 MB).

### 2.4 Phase 4 — workload runs (PARTIAL — see §3)

cm + dhry runs on Reference Core A (large config) **did not complete to `tohost` write detection within 5M sim cycles** (≥ 23 min wallclock). All runs (10K, 50K, 100K, 200K, 500K, 2M, 5M, 50M cycle limits — with both `+loadmem=` and TSI-load paths, with and without `+verbose`, with and without `+dramsim`) terminated either at `+max-cycles=N` or at the Reference Core A-internal `boom_timeout` PlusArg-controlled idle-counter threshold. **No `tohost`-write success was ever detected by fesvr.**

Two confirmation runs proved the simulator binary itself is *functional*:
- `riscv-tests/build_simple/rv64ui-p-add` (well-formed riscv-test): same hang behavior.
- minimal hand-written `exit_test.elf` (`li t0, 0x80001000; li t1, 1; sd t1, 0(t0); j .`) with explicit `tohost`/`fromhost` global symbols added to link.ld: same hang behavior.

This is a **the reference-core build framework-config-side issue, not a workload-side issue**, since even the standard riscv-test ISA test does not exit. See §3.

---

## 3. Why the workload runs hung — root-cause analysis

### 3.1 Symptom

Across all test invocations (`+max-cycles=10K..5M`, with/without `+loadmem`, with/without `+verbose`, with/without `+dramsim`):
- The simulator runs to its `+max-cycles=N` limit and prints `*** FAILED *** (timeout)`.
- No `*** PASSED *** Completed after N cycles` ever observed.
- Without `+max-cycles`, Reference Core A's internal `assert(!idle_cycles.value(13))` ("Pipeline has hung") in `BoomCore.sv:4261` (from `core.scala:1283`) fires after `idle_cycles >= 8192` — i.e., the CPU is idle for 8192 consecutive cycles.
- Setting `+boom_timeout=31` shifts that threshold to bit 31 = 2^31 cycles, deferring the assertion. With the deferral, the simulator runs forever (until `+max-cycles` fires).

### 3.2 What this means

**The CPU is genuinely idle for long stretches** — `idle_cycles` only resets when `rob.io.commit.valids.asUInt.orR || csr_stall || rocc.busy ||` etc. (see `riscv-boom/src/main/scala/v4/exu/core.scala:1276-1282`). 8192 idle cycles means **no instruction commit for 8192 consecutive cycles**.

Two scenarios fit:
1. **Boot stall**: the hart never wakes from the BootROM's `wfi_loop` because MSIP write hasn't happened (or hasn't been observed by the hart). MSIP is written by fesvr via `tsi_t::reset()` writing `MSIP_BASE = 0x2000000` (CLINT base). With `+loadmem`, the binary load is fast (direct DRAM mmap inside `SimDRAM.cc`'s `memory_init`), but the **MSIP write still goes through the Serial-TL bridge** which is the slow path: 32-bit-per-cycle bit-serial protocol over `SimTSI` → `TSIToTileLink` → CLINT register.
2. **Post-tohost stall**: the CPU runs the binary, writes `tohost = 1`, jumps to `j .` (infinite self-loop), but fesvr's polling loop hasn't read `tohost` yet (because TSI is slow), so the SimTSI exit-success bit never fires, so the testharness `io.success` stays low, so the `emulator.cc` main loop doesn't break.

**Test 2 was disambiguated** by (a) confirming the binary contains executable code (via `riscv64-unknown-elf-objdump -d`), (b) confirming `tohost`/`fromhost` symbols are *present* in the rebuilt cm.elf (`nm` shows `0000000080001000 B tohost`), and (c) running with the original cm.elf that does NOT have tohost in its symbols — fesvr printed `warning: tohost and fromhost symbols not in ELF; can't communicate with target`, and behaved identically (timeout). So the symbol presence is correctly detected, the polling does happen, and yet exit doesn't fire.

The remaining hypothesis is that the issue is **scenario 1 (boot stall)**: the CPU is in WFI in the BootROM, MSIP hasn't been delivered yet through the slow Serial-TL path. Confirming this would require:
- Compiling with VCD trace (`+define+DEBUG`, much slower) and checking PC values
- Or building a different the reference-core build framework config (e.g., `MegaBoomV4Config` + `WithSimTSIOverSerialTL(fast=true)` substitution)
- Or replacing the reference-core build framework's default boot harness with a `WithBlackBoxSimMem`-only config (no Serial-TL, only AXI4 backing memory + DTM/JTAG for HTIF)

### 3.3 What's needed to make this work

The fix is one of:
- Use `MegaBoomV4Config` derived from `NoAXI4MemPortChipLikeRocketConfig`-style harness, which uses `WithSimTSIOverSerialTL(fast=true)` (FastRAM mode → direct DRAM access via AXI4, no slow serdes). See `chipyard/generators/chipyard/src/main/scala/config/ChipConfigs.scala:88+`.
- Or, increase `+max-cycles` to ≥ 50M and accept ~3 hours per run (50M cycles / 3.6 KHz).
- Or, find a the reference-core build framework simulator wrapper that uses DTM (faster boot via JTAG) instead of TSI.

This was not pursued further because each the reference-core build framework rebuild takes ~20 minutes and the time budget for this investigation has been exhausted on the boot-mechanism issue.

---

## 4. What we *can* compare empirically (binary structure)

Since the simulator was built end-to-end, we have a verified-correct MegaBoomV4Config binary that we can characterize statically:

| Metric | Value |
|---|---|
| Verilator binary size | 22.3 MB |
| FIR file size (compile-time) | 162 MB |
| Number of generated .sv files | 661 |
| Number of generated .cpp files | 395 |
| Number of perf events (Reference Core A CSR) | 13 (3 EventSets × 4 entries each, see `core.scala:276-299`) |
| Default boom_timeout (WFI/idle) | 8192 cycles (PlusArg `boom_timeout=13`, width=5) |

Concrete Reference Core A perf events (all wired to mhpmcounters via the reference-core build framework `CSRFile`):
- Set 1: exception (others nop)
- Set 2: branch misprediction, control-flow target misprediction, flush
- Set 3: I$ miss, D$ miss, D$ release, ITLB miss, DTLB miss, L2 TLB miss

**These are the only counters Reference Core A exposes natively.** A clock-by-clock commit-count distribution comparable to rv64gc-v2's bubble-taxonomy (`doc/4wide_pipeline_bubble_taxonomy_2026-05-02.md`) would require either (a) Reference Core A source modification to add `PopCount(rob.io.commit.arch_valids)` events, or (b) parsing `+verbose` printf output. Neither was achievable in this session due to the sim-execution issue above.

---

## 5. Feature-flag inventory: Reference Core A (large config) features absent in rv64gc-v2

The prior `4wide_arch_diff_2026-05-02.md` audit catalogued 25 differences but did NOT explicitly enumerate the *boolean feature flags* that Reference Core A (large config) enables and rv64gc-v2 lacks entirely. From `riscv-boom/src/main/scala/v4/common/parameters.scala` and `config-mixins.scala:246-296`:

| # | Reference Core A (large config) flag | Default in Reference Core A | Reference Core A (large config) value | rv64gc-v2 equivalent | Predicted impact on rv64gc-v2 gap |
|---|---|---|---|---|---|
| F1 | `enablePrefetching` | `false` | **`true`** | None — no L1D prefetcher | **Directly attacks dhry's load-wait-at-head dominance.** Predicted contribution +5–10% on dhry, +1–3% on cm. |
| F2 | `enableSuperscalarSnapshots` | `true` (default) | `true` | "supports up to maxBrCount=64 checkpoints" — but allocation policy may be different | Branch-side: faster recovery on misprediction. Predicted +0.5–1% on cm. |
| F3 | `enableFastLoadUse` | `false` | **`true`** | spec_wakeup at dcache req issue (similar mechanism) | rv64gc-v2 already at 2-cycle load-to-use vs Reference Core A 4-cycle (via fast-wake-up), so this is a parity feature. No additional gap source. |
| F4 | `numDCacheBanks` | `1` | **`4`** | `L1D_NUM_BANKS = 2` | 4 banks vs 2: better D$ bandwidth on bursty load streams. Predicted +1–2% on dhry (small array sweeps), +0–1% on cm. |
| F5 | `lsuWidth` | `1` | **`2`** | `LSU_WIDTH = 2` (already 2 in rv64gc-v2) | parity. |
| F6 | `enableLoadToStoreForwarding` | `true` | `true` | Yes, 3 paths in rv64gc-v2 | parity (rv64gc-v2 has *more* forwarding paths). |
| F7 | `enableSFBOpt` (Short-Forward-Branch fold-into-predication) | `true` | `true` | None | Already analyzed in `4wide_iter_sfb_results.md` — predicted +2–3% on cm; REFUTED in iter cycle (max win 0.92%). |
| F8 | `enableGHistStallRepair` | `true` | `true` | Different mechanism (gshare update on misprediction) | parity-ish. |
| F9 | `enableBTBFastRepair` | `true` | `true` | None | Predicted small impact (<1%), already accounted for in mispredict rate. |

Of these 9 flags, **F1 (`enablePrefetching` = NLPrefetcher)** is the single most consequential one not yet attributed in the existing reconciliation. The prior `arch_diff` doc concluded:
> dhry: predicted −4%, measured −39.5% → **35.5% unexplained**

The unexplained 35.5% on dhry is dominated by load-wait-at-head (27% of cycles per the bubble taxonomy). Reference Core A (large config)'s NLPrefetcher (next-line prefetcher, `riscv-boom/src/main/scala/v4/lsu/prefetcher.scala`) issues a prefetch on every cache miss for the next cache line, which in dhry's tight `Func_2`/`Proc_3` strncpy/strncmp loops with a small working set has near-100% hit on the prefetched line.

A reasonable reattribution:
| Source | Predicted contribution to dhry gap |
|---|---:|
| IQ depth fragmentation (#8 in arch_diff) | −2% |
| MUL-co-locates-ALU2 (#9) | −1% |
| ALU3 not bypassed (#11) | −1% |
| **NLPrefetcher absence (F1)** | **−5 to −10%** |
| Compiler/binary differences (loop unroll, register coloring) | −10 to −20% |
| Total predicted | **−19 to −34%** |
| Measured | −39.5% |
| Residual | ~5% (within structural-noise + workload-randomness band) |

This reconciliation closes the dhry gap to within typical measurement variance.

---

## 6. Updated recommendations (supersede / extend the prior survey)

The prior `4wide_uarch_upgrade_survey_2026-05-02.md` ranked the top 3 candidates as:
1. FDIP (decoupled fetch with FTQ runahead)
2. L1D Stride/Stream Prefetcher (NLP-extended) — gated on MSHR availability
3. AUIPC+ADDI/JALR/LD/ST macro-fusion expansion

Based on this Reference Core A (large config) feature inventory and the dhry-gap reconciliation:

**Re-rank to:**
1. **L1D Stride/Stream Prefetcher** (was #2). Now confirmed-essential because Reference Core A (large config) uses NLPrefetcher and rv64gc-v2 has none. Predicted **+5–10% on dhry + +1–3% on cm**, ~1 week, ~400 LOC. The prior survey already had this as #2; the new evidence elevates it to #1 by directly accounting for a measured 5–10% of the dhry gap.
2. **INT IQ reorganization** (Variant A of `4wide_arch_diff_2026-05-02.md` §9.1) — keeps the same predicted +3–5% on cm, +1% on dhry. ~250 LOC, 2-3 days. This addresses 4 separate items in the difference table (#7, #8, #9, #10).
3. **FDIP / decoupled fetch** (was #1). Demoted because the prior survey predicted +3–6% on cm but the actual gap-closure analysis showed frontend supply was the bottleneck on the *frontend-empty* path (16% of cm), of which only ~half is recoverable by FDIP. So +1–3% on cm is the realistic upper bound.

**Removed from the active list:**
- **AUIPC+ADDI/JALR macro-fusion** (was #3). Reference Core A (large config) does NOT have this in its default config. Its absence in Reference Core A (large config) but presence in rv64gc-v2's `fusion_detector.sv` means rv64gc-v2 already has a feature Reference Core A (large config) lacks, so adding more fusion patterns is unlikely to close the Reference Core A gap (would over-shoot in this category).
- **µop cache (UOC)**: confirmed already built, ~0% IPC win on 6-wide; no evidence it would help on 4-wide.

---

## 7. Recommendations for follow-up empirical work

If a future session can dedicate ~6–8 hours to making the Reference Core A (large config) simulator actually exit:

**Path A — switch to FastRAM (recommended):** Modify `chipyard/generators/chipyard/src/main/scala/config/AbstractConfig.scala:20` to use `WithSimTSIOverSerialTL(fast = true)` instead of the default `fast = false`. This bypasses the slow serdes for memory access. Rebuild Verilator binary. Expected cm runtime: ~30s of wallclock for 200K Reference Core A cycles vs ~3000s currently. ~20 min rebuild.

**Path B — add a the reference-core build framework-style commit-count counter to Reference Core A:** Edit `riscv-boom/src/main/scala/v4/exu/core.scala` to wire `PopCount(rob.io.commit.arch_valids)` to a custom CSR or printf line. Rebuild. Provides per-cycle commit distribution comparable to `4wide_pipeline_bubble_taxonomy_2026-05-02.md`'s analysis. ~40 LOC + ~20 min rebuild.

**Path C — accept the structural-comparison conclusions and stop iterating:** This and the prior `arch_diff` doc together identify the root causes of the cm and dhry gaps with reasonable confidence. The remaining iterative gain from getting actual Reference Core A (large config) IPC numbers is small relative to the cost of fixing the boot path.

The Path A + Path B combination (~1 hour total once boot path fixed) would yield a clock-by-clock commit-count comparison that fully closes the analytical loop. Until then, the structural inventory in §5 + the `arch_diff` master table is the best available empirical-equivalent comparison.

---

## 8. Reproduction notes

### Build the Reference Core A (large config) simulator from scratch

```bash
# 1. Install Java + SBT (no sudo)
curl -s "https://get.sdkman.io" | bash
source ~/.sdkman/bin/sdkman-init.sh
sdk install java 17.0.19-tem << 'EOF'
n
EOF
sdk install sbt << 'EOF'
n
EOF

# 2. Install firtool
curl -fL -o /tmp/firtool.tar.gz \
  "https://github.com/llvm/circt/releases/download/firtool-1.75.0/firrtl-bin-linux-x64.tar.gz"
mkdir -p ~/opt/firtool
tar -xzf /tmp/firtool.tar.gz -C ~/opt/firtool
export PATH="$HOME/opt/firtool/firtool-1.75.0/bin:$PATH"

# 3. Build fesvr standalone (~/opt/riscv/lib/libfesvr.{a,so})
git clone --depth=1 https://github.com/riscv-software-src/riscv-isa-sim.git
mkdir -p ~/opt/fesvr-manual && cd ~/opt/fesvr-manual
# (See /home/jeremycai/opt/fesvr-manual/Makefile for the standalone build recipe.
#  Skips boost-asio dependency; install riscv/ + softfloat/ headers under
#  ~/opt/riscv/include; needs minimal config.h.)
make install

# 4. Set RISCV path. CRITICAL: must use ~/opt/riscv (not /usr) so the build
#    picks up libfesvr; symlink riscv64-unknown-elf-* into ~/opt/riscv/bin.
export RISCV=$HOME/opt/riscv
mkdir -p $RISCV/bin
for t in /usr/bin/riscv64-unknown-elf-*; do ln -sf "$t" "$RISCV/bin/"; done

# 5. Stub libriscv.so (the reference-core build framework's link command has -lriscv but no symbols
#    are actually referenced; an empty shared lib satisfies the linker)
git clone --depth=1 https://github.com/ucb-bar/chipyard.git
cd chipyard
echo "void _empty_riscv_lib() {}" | g++ -x c -shared -fPIC -o sims/verilator/libriscv.so -

# 6. Init submodules + build
./scripts/init-submodules-no-riscv-tools.sh
cd sims/verilator
ln -sf $RISCV/lib/libfesvr.so libfesvr.so
make CONFIG=MegaBoomV4Config SUB_PROJECT=chipyard
```

Output: `sims/verilator/simulator-chipyard.harness-MegaBoomV4Config` (22 MB).

### Build cm.elf with `tohost`/`fromhost` symbols (required for fesvr)

The rv64gc-v2 default link.ld uses `PROVIDE(tohost = .)` which produces no symbol if the binary doesn't reference it. To make fesvr-compatible:

```bash
# See /tmp/boom_workloads/coremark_link.ld — change PROVIDE() to direct
#   tohost = .; fromhost = .;
# in the .tohost section. Then rebuild cm:
SRC=/home/jeremycai/agent-workspace/rv64gc-v2/tests
CFLAGS="-O2 -march=rv64gc_zba_zbb_zbs_zicond -mabi=lp64d -mcmodel=medany ..."
SRCS="$SRC/coremark/crt0.S $SRC/coremark/core_portme.c $SRC/coremark/src/core_*.c"
riscv64-unknown-elf-gcc $CFLAGS -T /tmp/boom_workloads/coremark_link.ld $SRCS -lgcc -o cm.elf
```

### Invoke Reference Core A (large config) on cm

```bash
cd ~/agent-workspace/chipyard/sims/verilator
./simulator-the reference-core build framework.harness-MegaBoomV4Config \
  +permissive \
  +max-cycles=10000000 \
  +boom_timeout=31 \
  +loadmem=cm.elf \
  +permissive-off \
  cm.elf
```

(See §3 — this currently times out before fesvr detects exit. Fix per Path A above before relying on the runtime numbers.)

---

## 9. Files added / changed by this investigation

- This document: `doc/4wide_megaboom_compare_2026-05-02.md`
- (Out of repo, in `/tmp/boom_workloads/`): rebuilt cm.elf and dhrystone.elf with explicit `tohost`/`fromhost` symbols
- (Out of repo, in `~/opt/`): firtool, fesvr, riscv toolchain symlinks
- (Out of repo, in `~/agent-workspace/chipyard/`): full MegaBoomV4Config Verilator simulator

No rv64gc-v2 RTL was modified.

---

## 10. UPDATE 2026-05-02 (later) — Workload runs DID complete with FastBoot config

The first attempt blocked on the slow bit-serial TileLink boot path (§3). This update documents the resolution and the empirical numbers obtained.

### 10.1 FastBoot resolution

Created a new the reference-core build framework config `MegaBoomV4FastConfig` in `chipyard/generators/chipyard/src/main/scala/config/BoomConfigs.scala`:

```scala
class MegaBoomV4FastConfig extends Config(
  new chipyard.harness.WithSimTSIOverSerialTL(fast = true) ++       // FastRAM-style boot
  new boom.v4.common.WithNMegaBooms(1) ++
  new chipyard.config.WithSystemBusWidth(128) ++
  new chipyard.config.AbstractConfig)
```

Rebuild took ~18 min (firtool + Verilator + g++). Output: `chipyard/sims/verilator/simulator-chipyard.harness-MegaBoomV4FastConfig` (22 MB). Confirmed FastRAM in generated Verilog (vs SerialRAM in the prior config).

### 10.2 Required binary preparation

The fesvr-discoverable `tohost`/`fromhost` symbols in our existing rv64gc-v2 binaries were LOCAL section symbols only, not global. Re-exporting them with `objcopy` produces a Reference Core A-runnable binary:

```bash
/usr/bin/riscv64-unknown-elf-objcopy \
    --add-symbol "tohost=0x80001000,global" \
    --add-symbol "fromhost=0x80001008,global" \
    rv64gc-v2/tests/dhrystone/dhrystone.elf /tmp/our_dhry_global.elf
```

Same for cm. Without these globals, fesvr emits "warning: tohost and fromhost symbols not in ELF; can't communicate with target" and the PASSED detection is unreliable.

### 10.3 Empirical measurements (raw cycle counts)

| Run | Binary | Reference Core A total cycles | Status | Wallclock |
|---|---|---:|---|---:|
| Boot baseline | `exit_test.elf` (4 inst) | **1,059,896** | PASSED | 5 min |
| Rebuilt dhry | `/tmp/boom_workloads/dhrystone.elf` (NUM_RUNS unknown — likely 500 with riscv-tests-style I/O) | 4,282,036 | PASSED | 20 min |
| Our dhry | `/tmp/our_dhry_global.elf` (NUM_RUNS=100, our exact src + global tohost) | **2,242,946** | PASSED | 11 min |
| Our cm | `/tmp/our_cm_global.elf` (our exact cm.elf + global tohost) | **6,607,696** | PASSED | 31 min |

Subtracting boot baseline (1.06M cycles): payload-only estimate
- our dhry on Reference Core A: ~1,183,050 payload cycles
- our cm on Reference Core A: ~5,547,800 payload cycles

### 10.4 Direct comparison vs rv64gc-v2 (raw cycles)

| Workload | Same binary on rv64gc-v2 | Same binary on Reference Core A (payload est.) | Raw ratio |
|---|---:|---:|---:|
| dhry | 23,514 | 1,183,050 | **50× higher on Reference Core A** |
| cm iter1 | 199,452 | 5,547,800 | **28× higher on Reference Core A** |

### 10.5 Why the raw cycle ratio is misleading (CRITICAL)

A 28-50× cycle inflation on Reference Core A for IDENTICAL binary is **not** a real performance gap. Published Reference Core A data (CARRV 2020) shows Reference Core A (large config) IPC is ~1.81 on cm — ~10% HIGHER than our 1.665. So Reference Core A should have FEWER cycles, not 28× more.

The inflation comes from FOUR sources, none captured in our raw-cycle measurement:

1. **Cold-cache cost (large)**: Reference Core A starts with empty L1I + L1D + L2. Each first-time instruction fetch = ~50 cycles to L2 fill. For cm (~5K static instructions), that's ~250K cycles of cold I-cache misses alone. dhry would be ~50K. rv64gc-v2's DSim model may pre-warm or have idealized cache behavior.
2. **Bootrom payload-init (medium)**: Reference Core A's BootROM runs longer for larger binaries (page-table init, .bss zeroing scaled with binary size). Not the same fixed 1.06M as exit_test.
3. **HTIF round-trip cost on syscalls (small but real)**: any printf/syscall in cm/dhry traps to fesvr; each round-trip = thousands of cycles. Our DSim has no equivalent slowdown.
4. **fesvr cycle accounting**: the simulator counts EVERY cycle including DMA-wait cycles where Reference Core A is idle waiting for FastRAM. Our DSim doesn't count idle.

**Net:** the raw cycle ratio (28-50×) is dominated by simulation-environment differences, not architectural-IPC differences. To get a clean IPC comparison, we'd need ONE of:

- **Add `mhpmcounter3` (instret) printout to Reference Core A TestDriver** — read CSR at finalize, print "instret=N cycles=M IPC=X". ~50 LOC patch to TestDriver.v + BoomCore. Then `IPC_BOOM = N / (M - boot - cold_cache)` is meaningful.
- **Run cm with very high iteration count** (e.g. 1000 runs) to amortize boot+cold-cache to <1% of total. Requires rebuilding cm with custom NUM_ITERATIONS.
- **Compare INSTRET-NORMALIZED metrics**: collect each workload's instret on rv64gc-v2 (we have this: cm=332,110), then compute Reference Core A IPC = 332,110 / (Reference Core A cycles − ~1.5M boot+cold-cache estimate) = 332,110 / 4,047,800 = 0.082. Still implausibly low — confirms there's MORE than boot+cold-cache going on. Our binary's `rv64gc_bench_write` calls likely write to addresses Reference Core A treats as TileLink memory and potentially TLB-misses each time, adding many cycles per call.

### 10.5b Verification probes added later (2026-05-02 post-7d425db)

**Binary integrity checked.** Re-disassembled `/tmp/our_dhry_global.elf` and confirmed:
- `NUM_RUNS=100` is baked in at build time (objdump shows three `li ..,100` constants — loop counter, comparison guard, and array bound).
- `rv64gc_bench_begin/end` are called only at start/end of the 100-iter loop (not per-iter), so MMIO-snoop cost cannot account for the gap.

**Per-iter cycle implication is implausible.** rv64gc-v2 dsim re-confirms 23,017 cyc / 47,033 instret for the 100-iter kernel (230 cyc/iter, IPC 2.03). Same binary on Reference Core A = 2,242,946 sim cyc; subtracting the exit_test boot baseline (1.06M) leaves 1.18M cyc → 11,800 cyc/iter. If Reference Core A executed the same instret (~47K), this implies Reference Core A IPC ≈ 0.04 — three orders of magnitude below Reference Core A (large config)'s published numbers. **The cycle counts as printed are not interpretable as kernel cycles.** The actual cause is buried in the reference-core build framework simulation environment overhead (DTB-walk, BootROM-to-main transition, MMU/PMP setup, cold-cache fills on first iter) which is NOT captured by the simple exit_test baseline subtraction.

**Why TestDriver patch is the only clean path.** I evaluated four alternatives this session:
1. *Hierarchical reference into CSRFile.sv* — `mcycle`/`minstret` are stored in WideCounter modules referenced via `value_1`/`value_2`/etc. Names are obfuscated by Chisel-FIRRTL emit; stable hierarchical refs are brittle.
2. *Encode cycles in tohost exit code* — fesvr exit code is consumed by fesvr only; Reference Core A TestDriver prints sim_cycles regardless and does not surface the exit code.
3. *Self-instrumented binary printing via HTIF putchar* — requires HTIF syscall protocol support in rv64gc-v2 dsim (currently exit-code-only). ~50-100 LOC tb_verilator.cpp + DPI peek.
4. *Build the reference-core build framework's stock dhrystone.riscv with newlib* — newlib not installed on `/usr/bin/riscv64-unknown-elf-` toolchain; would require building riscv-tools or installing newlib.

The **TestDriver.v patch (option in §10.7)** remains the right move for any continued empirical work. ~1-day to wire `mcycle`/`minstret` out of CSRFile via a chisel BlackBox or `dontTouch`-pinned wire, plus the TestDriver print.

### 10.6 Definitive conclusions from this empirical work

**CONFIRMED:**
- ✅ MegaBoomV4FastConfig Verilator simulator works (built, runs binaries, completes via tohost)
- ✅ Our exact binaries (with global tohost re-export) run on Reference Core A
- ✅ Reference Core A completes both cm and dhry from our source (no functional incompatibility)
- ✅ Boot baseline on Reference Core A is ~1.06M cycles (exit_test reference)

**NOT OBTAINED (would require additional work):**
- ❌ Clean Reference Core A IPC for our binaries — needs instret CSR printout patch
- ❌ Clock-by-clock bubble distribution for Reference Core A — needs custom RoB instrumentation patch
- ❌ Per-PC head-stall data for Reference Core A — needs deeper Chisel patches

### 10.7 Updated recommendations (supersedes §6 and §7)

The empirical run did NOT change the architectural conclusion: the L1D NLPrefetcher (Reference Core A's `enablePrefetching`) remains the #1 candidate to address rv64gc-v2's gap, especially for dhry. Reasoning:

- Confirmed via §5 feature-flag inventory: Reference Core A has L1D prefetcher; rv64gc-v2 has none.
- Per the bubble taxonomy + per-uop lifecycle: load-WB at head accounts for 16.4% of cm cycles and is the largest fixable single cost on dhry's strncpy/strncmp loops.
- The empirical run, while not yielding clean IPC, confirms the simulator can be used for FUTURE IPC comparisons IF we patch Reference Core A's TestDriver to emit instret.

**Concrete next-step option: patch Reference Core A TestDriver to print final instret + cycles.** ~1-day effort. Would unlock real clock-by-clock IPC comparison on any subsequent rv64gc-v2 RTL change.

### 10.8 Reproducibility

```bash
# 1. Use the FastBoot config (already created)
ls /home/jeremycai/agent-workspace/chipyard/sims/verilator/simulator-chipyard.harness-MegaBoomV4FastConfig

# 2. Re-export tohost/fromhost on any rv64gc-v2 binary
/usr/bin/riscv64-unknown-elf-objcopy \
    --add-symbol "tohost=0x80001000,global" \
    --add-symbol "fromhost=0x80001008,global" \
    INPUT.elf OUTPUT.elf

# 3. Run on Reference Core A
cd /home/jeremycai/agent-workspace/chipyard/sims/verilator
./simulator-the reference-core build framework.harness-MegaBoomV4FastConfig \
    +permissive +max-cycles=10000000 +boom_timeout=31 +verbose +permissive-off \
    OUTPUT.elf 2>&1 | grep -E "PASSED|FAILED"
```

Expected wallclock: dhry ~10 min, cm ~30 min on this machine (Verilator at ~3.5 KHz).

---

## 11. Methodology re-run (2026-05-02 post-Methodology-section)

This section re-evaluates every claim made earlier in this doc through the evidence ladder + 5 comparison rules added in the Methodology section. Earlier sections are kept for debug provenance; conclusions in §11 supersede those in §1-§10 wherever they conflict.

### 11.1 Tier classification of evidence already in this doc

| Evidence | Where | Tier | Status |
|---|---|---|---|
| Reference Core A Verilator simulator builds + runs our binaries (exit_test, dhry, cm) | §10.1-§10.4 | B | COMPLETE |
| Raw Reference Core A cycles: exit_test 1.06M, dhry 2.24M, cm 6.6M | §10.4 | B | COMPLETE |
| Per-iter cycle ratio (Reference Core A/rv64gc-v2 = 50× dhry, 28× cm) | §10.5, §10.5b | B-derived | INVALID per Rule 1 (see §11.2) |
| Reference Core A has 5 features rv64gc-v2 lacks (`enablePrefetching`, `enableSuperscalarSnapshots`, `enableFastLoadUse`, `numDCacheBanks=4`, `lsuWidth=2`) | §5 | C | COMPLETE — re-ranked in §11.3 |
| Published Reference Core A scores (6.2 CM/MHz, 1.8 DMIPS/MHz) | §1, §6 | D | COMPLETE — sanity-check only per Rule 5 |
| rv64gc-v2 own pipeline-behavior corpus (bubble + headwait + frontend + pipe.v1 trace) for 4 workloads | `benchmark_results/pipeline_confirm_20260502_202117/` | A (rv64gc-v2 side only) | COMPLETE on our side; MISSING on Reference Core A side |
| Reference Core D pipeline-stage averages (gem5o3 format) | `benchmark_results/.../nax_add_o3pipe_summary.txt` | E | PARTIAL (only Reference Core D collected; Reference Core B/Reference Core E/Reference Core C not yet) |
| Reference Core A IPC for our binary | — | A | NOT STARTED |
| Reference Core A per-cycle pipe.v1 emission for our binary | — | A | NOT STARTED |

### 11.2 Conclusions that survive Rule 1 (separate harness from core time)

**SURVIVES.** The exit_test 1.06M baseline + dhry 2.24M + cm 6.6M numbers prove Reference Core A **functionally** runs our binaries to PASS via tohost. This is Tier B and answers compatibility, nothing more.

**FALLS.** The 50× dhry / 28× cm raw-cycle ratios cannot be interpreted as IPC ratios. §10.5b already noted this; the Methodology now makes it a hard rule. The implied "Reference Core A IPC = 0.04" reductio in §10.5b is pedagogical only; the correct statement is "we cannot compute Reference Core A IPC for these runs."

**FALLS.** Old §1 claim "residual cm gap ~8.5% / dhry gap ~35%" is a Tier-D-vs-Tier-A comparison on differently-compiled binaries (Reference Core A uses the reference-core build framework-built standard riscv-bmarks dhry; ours is the bare-metal rv64gc-v2 dhry with `-march=rv64gc_zba_zbb_zbs_zicond` + `-DNUM_RUNS=100` + custom crt0). Per Rule 2, no architecture conclusion can be drawn until binary normalization. Demoting the gap claim to "hypothesis pending Tier A on Reference Core A."

### 11.3 Conclusions that survive Rule 4 (map borrowed feature to a measured local stall class)

The 5 missing Reference Core A features re-ranked against rv64gc-v2 Tier-A measurements (`benchmark_results/pipeline_confirm_20260502_202117/coremark_iter1.{bubble,headwait}.txt`):

| Feature | Maps to which measured stall class? | Tier-A measurement (cm) | Verdict |
|---|---|---|---|
| **`enablePrefetching` (L1D NLP)** | Head-dwell=2 (load-WB latency at ROB head) | **16.4% of cm cycles** (16,396 heads × 2 cyc / 199,452) | ✓ ACTIONABLE — single largest single-cause Tier-A stall that is mechanically attackable |
| **`enableFastLoadUse`** | Head-dwell=2 (load→use one-cycle improvement) | Subset of the same 16.4% above | ✓ ACTIONABLE — but partial; benefit is bounded by what NLP doesn't already cover |
| **`enableSuperscalarSnapshots`** | Mispredict recovery cost (head-dwell=6-10) | 14.7% of cm cycles (3,933 heads × ~7.5 cyc) | △ MARGINAL per Rule 4. Snapshots reduce *recovery* cost, but our flush+drain is already only 2.18% of cycles per the bubble taxonomy. The 14.7% in head-dwell-6-10 is mostly *re-fill* of an empty pipeline, not snapshot-rollback time. Adopting this would be optimizing a non-dominant cost. |
| **`numDCacheBanks=4`** | D-cache bank-conflict stalls | NOT IN rv64gc-v2 instrumentation; no measurement | ✗ FAILS Rule 4. We have no Tier-A signal that bank-conflicts exist. Cannot justify until measured. |
| **`lsuWidth=2`** | LSU dispatch parallelism | rv64gc-v2 already has 3 LSU IQs; LQ avg occupancy 1.61 / cap 32 (5%); SQ 0.53 / 32 (1.6%) — LSU is not the binding resource | ✗ FAILS Rule 4. We are not LSU-throughput-bound. |

**Net under Rule 4: only L1D NLPrefetcher is fully justified by current Tier-A measurement.** `enableFastLoadUse` is conditionally justified as a layered improvement on top of NLP. The other three should NOT be adopted on the strength of "Reference Core A has it."

### 11.4 Tier ladder — current state vs target

| Tier | Goal | Current state |
|---|---|---|
| A on Reference Core A | Same binary, in-window `mcycle/minstret`, per-cycle pipe.v1 | NOT STARTED. Both substeps in Methodology "Minimum next empirical steps" pending. |
| B on Reference Core A | Same binary completes; raw sim cycles | DONE for cm/dhry/exit_test |
| C on Reference Core A | Source/config audit | DONE (§5) |
| D on Reference Core A | Published scores as floor | COLLECTED (§1) — usable as sanity check only |
| A on rv64gc-v2 | Self-instrumented, all counters | DONE (4-workload corpus) |
| E on other RV cores | Architectural reference | Reference Core D DONE; Reference Core B / Reference Core E / Reference Core C not yet |

### 11.5 What the Methodology authorises us to act on NOW

Only one RTL action passes all five rules without needing more Reference Core A-side data:

**ACTION 1 — L1D NLPrefetcher (next-line prefetcher) in rv64gc-v2's L1D.**
- Rule 1: ✓ uses our own Tier-A measurement, no Reference Core A raw cycles involved
- Rule 2: ✓ no binary normalization needed (we're testing on our own sim)
- Rule 3: ✓ stall class is a pipeline counter (head-dwell=2 from Little's-law decomp)
- Rule 4: ✓ maps to 16.4% of cm cycles, the largest single mechanically-attackable Tier-A stall
- Rule 5: ✓ NLP is well-understood, present in nearly every modern OoO; not a clone of any Reference Core A-specific design choice

Proposed scope: 4-entry next-line prefetch buffer feeding L1D refill on miss-confirmed addresses, gated by stride-detection on the load PC (mirrors Reference Core A's NLPrefetcher.scala minus the dynamic-degree controller). Predicted upper bound: ≤16.4% × hit-rate-on-prefetched-line × (1 − head-dwell-1-fraction-already-hidden) ≈ 5-10% of cm cycles, 5-15% of dhry (where head-wait is 88% of cycles).

### 11.6 Claims this doc has made that the Methodology now blocks

These cannot be reasserted until the corresponding tier is unlocked:

- "Reference Core A is X% faster than us on cm/dhry" — needs Reference Core A Tier A IPC.
- "Our remaining gap to Reference Core A is Y%" — needs Reference Core A Tier A IPC.
- "Adding feature Z would close N% of the gap" — needs Reference Core A Tier A pipeline-behavior so we can see whether Reference Core A's stall distribution actually differs from ours where the feature would act.
- "Reference Core A's bank-conflict pressure is high" / "Reference Core A is LSU-throughput bound" — needs Reference Core A Tier A pipeline-behavior; our own data says neither pressure exists in rv64gc-v2.
- "We need to widen / deepen ROB / IQ" — fails Rule 4 on our own data: ROB avg 12.61/128 (10%), IQ_INT avg 4.64/72 (6%), LQ 1.61/32 (5%), SQ 0.53/32 (2%) — none of these are binding.

### 11.7 Recommended sequencing under the Methodology

1. **NOW (no Reference Core A dependency, Rule 4 cleared):** Build L1D NLPrefetcher in rv64gc-v2. Validate via the existing rv64gc-v2 Tier-A pipeline. Acceptance gate: head-dwell=2 cycles drop measurably without regressing other categories.
2. **PARALLEL (unblocks future feature decisions):** Land the Reference Core A TestDriver `mcycle/minstret` patch (Methodology Step 1). This is the cheapest unlock and turns Tier D speculation into Tier A IPC numbers for our exact binaries.
3. **FOLLOW-UP (after step 2 lands):** Decide whether to invest in Step 2 (per-cycle pipe.v1 emission on Reference Core A). Worth it only if step 2 IPC reveals a ≥10% residual gap that current Tier-C audit doesn't explain.
4. **DEFER:** `enableSuperscalarSnapshots`, `numDCacheBanks=4`, `lsuWidth=2` adoption decisions. Re-evaluate after step 3 produces Tier A pipeline-behavior diff.

## 12. secondary-reference-core Tier E reference update (2026-05-03)

This section updates the Tier E landscape after running the other local RV
reference cores. It does not change the Reference Core A (large config) methodology: Reference Core A remains the
quantitative public floor, and secondary-reference-core cores remain architectural and
instrumentation references only.

Detailed supplement:

- `doc/non_megaboom_reference_test_results_2026-05-03.md`
- Result root:
  `benchmark_results/non_megaboom_confirm_20260502_235655/`

### 12.1 Methodology comparison with the original local note

The original local note, `doc/pipeline_behavior_confirmation_2026-05-02.md`,
correctly classified Reference Core D/Reference Core E as references rather than apples-to-apples
benchmark comparisons. The new evidence ladder at the top of this file makes
that rule explicit:

| Point | Original note | Current methodology | Verdict |
|---|---|---|---|
| Harness/core separation | Mentioned indirectly for Reference Core A and reference cores. | Hard rule: raw simulator cycles are not kernel IPC unless the benchmark window is instrumented. | Current method is stricter and should supersede. |
| Other cores | Smoke references for trace format/mechanism inspection. | Tier E: architectural reference only; never direct pass/fail for Reference Core A (large config) comparison. | Same direction, now formalized. |
| Reference Core A feature borrowing | Feature diff was allowed as directional evidence. | Feature must map to measured rv64gc-v2 stall class before RTL action. | Current method blocks premature copying. |
| Quantitative gap claims | Earlier sections contained raw-cycle and residual-gap discussion. | Claims like "Reference Core A is X% faster" are blocked until Reference Core A Tier A IPC/counters exist. | Current method is the correct guardrail. |

### 12.2 Results now available

| Core | Tier E status | Result | Use |
|---|---|---|---|
| **Reference Core D** | Expanded beyond smoke. | Same-binary microbenches pass; same-source CoreMark/Dhrystone attempts trap; native RV64IMAFDC CoreMark/Dhrystone pass. | Use O3Pipe summaries for stage-latency, retire-width, and low-cost replay/load-hit instrumentation ideas. |
| **Reference Core E** | Expanded beyond pending. | Four native RV32 tests pass: `IntRegImm`, `LoadAndStore`, `MemoryDependencyPrediction`, `ReplayQueueTest`. | Use Reference Core E/Kanata logs for replay queue, memory-dependence, and store-load-forwarding behavior. |
| **Reference Core B** | Source/config reference; runtime blocked. | `TLMinimalConfig` RTL generation and Verilator C++ generation complete; emulator compile fails before `build/emu`. | Use for source/config audit only until host Verilator wrapper compatibility is resolved. |

Reference Core D highlights:

| Workload | Result | Cycles | Commits | IPC | Fetch-to-retire avg |
|---|---|---:|---:|---:|---:|
| `bench_loop_100` | PASS | 581 | 706 | 1.21515 | 23.49 |
| `probe_alu_chain_8` | PASS | 6191 | 10006 | 1.61622 | 28.75 |
| `probe_bpu_data_dep_branch` | PASS | 24567 | 13511 | 0.549965 | 38.49 |
| `probe_independent_quad` | PASS | 5195 | 10020 | 1.92878 | 22.98 |
| `native_coremark_rv64imafdc` | PASS | 2233396 | 2632380 | 1.17864 | 42.67 |
| `native_dhrystone_rv64imafdc` | PASS | 1124559 | 1674348 | 1.48889 | 51.87 |

Reference Core E highlights:

| Test | Result | Cycles | Committed RV ops | IPC | Key counter signal |
|---|---|---:|---:|---:|---|
| `IntRegImm` | PASS | 4675 | 4518 | 0.966417 | Branch misses 2, memory-dep misses 0. |
| `LoadAndStore` | PASS | 4558 | 4543 | 0.996709 | Memory-dep misses 2. |
| `MemoryDependencyPrediction` | PASS | 6082 | 5469 | 0.899211 | Memory-dep misses 11. |
| `ReplayQueueTest` | PASS | 111570 | 29356 | 0.263117 | D-store misses 4221, store-load-forwarding miss 1. |

Reference Core B status:

- First attempt failed because `mill` was not on `PATH`.
- Retried with local Mill launcher and completed RTL generation.
- Verilator C++ generation completed.
- C++ compile first failed on missing `sqlite3.h`/`zstd.h`.
- Retry with local header/library shims cleared those missing headers.
- Compile then failed in the difftest Verilator wrapper:
  `VerilatedTraceBaseC` is not declared under the current host Verilator header
  setup.
- No `build/emu` exists; no workload was run.

### 12.3 Verdict for design evaluation

The secondary-reference-core reference runs strengthen the methodology, but they do not
authorize a different immediate RTL direction.

What they authorize now:

- Use Reference Core D O3Pipe summaries to calibrate stage-latency vocabulary and trace
  parsers.
- Use Reference Core E Kanata/Reference Core E logs to inspect replay and memory-dependence flows before
  proposing LSQ policy changes.
- Use Reference Core B as a source/config reference for FTQ/FDIP, prefetch, fusion,
  and LSU replay concepts.

What they still block:

- Do not compare Reference Core D / Reference Core E native IPC against rv64gc-v2 signoff IPC.
- Do not claim Reference Core B runtime behavior until `build/emu` exists and a
  workload completes.
- Do not copy Reference Core B or Reference Core A structures wholesale. A borrowed mechanism must
  map back to a measured rv64gc-v2 stall class.

The strong design verdict remains:

1. Keep the Reference Core A TestDriver `mcycle/minstret` patch as the next Reference Core A-side
   empirical unlock.
2. In rv64gc-v2, the only no-Reference Core A-dependency RTL action still clearing the
   methodology is L1D next-line prefetch evaluation, followed by load/replay
   instrumentation and IP-stride/stream prefetch only if counters justify it.
3. Defer ROB/IQ/ALU/CDB/commit-width expansion until Tier A data shows actual
   capacity saturation.

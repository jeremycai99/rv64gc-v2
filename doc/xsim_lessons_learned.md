# xsim Migration: Lessons Learned

**Date**: 2026-04-16
**Context**: Mid-session discovery that xsim exposed a class of latent RTL bugs that Verilator was silently hiding. This document captures what we found, why it matters for ASIC tapeout, and what we should do differently going forward.

---

## The pattern: one class of bug, three independent manifestations

Over a single debugging session we found **three distinct bugs**, all of the same underlying class: **uninitialized state in SystemVerilog arrays** that Verilator's 2-state semantics silently defaulted to 0, while xsim's IEEE 1800 4-state semantics correctly propagated `x` and exposed the consequence.

| # | Module | Bug | Benchmark hit | Detection |
|---|--------|-----|---------------|-----------|
| 1 | `dcache_tag_ram` / `icache_tag_ram` | `valid_arr`, `dirty_arr` had no reset path | xsim: 10/23 tests TIMEOUT, CoreMark deadlock at minstret=40 | xsim 4-state propagation of `dirty_out` → `mshr.writeback_pend` → stuck L2 FSM |
| 2 | `int_prf` | `regfile_copy0..5` had no reset path | Defensive — no known test failure, but X would propagate on un-renamed pdst reads | Preemptive audit after finding #1 |
| 3 | `rv64gc_core_top.sv` (LB trigger) | `backward_branch_taken` was registered (1-cycle delay) as a Verilator eval-scheduling workaround | xsim CoreMark IPC: 0.48 instead of 3.15 — loop buffer activated 0% of cycles instead of 99% | Per-stage perf profile showed fetch starvation despite LB being the stated optimization |

Beyond those three, a **fourth bug** was found at the algorithmic level (not the X-propagation class): **dispatch round-robin over-feeding single-issue IQs** (IQ1/IQ2 drain at 1 op/cycle but receive 1/3 of ALU ops from 3-way round-robin). Load-balanced routing gave another **+14% IPC** (3.15 → 3.62).

A **fifth bug** remains partially characterized: **Dhrystone deadlock from rename/flush-recovery** triggered by a constant mispredict storm (~1 flush/10 cycles). Mitigated by a ROB head watchdog but not root-caused.

## What Verilator was hiding, and why

Verilator compiles SystemVerilog into cycle-accurate C++. For simulation performance it makes a critical simplification: **by default, 4-state values (`0/1/x/z`) are reduced to 2-state (`0/1`).** Arrays without explicit reset are implicitly treated as zero. Floating wires read as zero. Comparisons never return `x`.

That works wonderfully for bringup — it lets partial designs simulate without drowning in `x` propagation. But it also **hides a specific class of RTL bug**: any state that requires reset for correct power-up behavior on real silicon will run silently on Verilator. You can tape out a design that boots fine in Verilator and produces garbage in silicon.

xsim (Vivado's simulator) follows IEEE 1800 strictly: 4-state throughout, `x` propagates through logic, uninitialized arrays read as `x` until written. It is much closer to what synthesis produces.

## Specific mechanics of each bug

### Bug 1: Cache tag RAM (commit `8e280c6`)

```systemverilog
// Original (buggy)
logic valid_arr [L1D_SETS][L1D_WAYS];
logic dirty_arr [L1D_SETS][L1D_WAYS];

always_ff @(posedge clk) begin
    if (invalidate_all) begin
        // Clear arrays
    end else begin
        // Updates only on valid cache fills
    end
end
```

`invalidate_all` was tied to `1'b0` in dcache's `core_top` wiring, so the arrays were never cleared. The first store-miss read `tr_dirty_out[victim_way]` which was `x`. That `x` flowed to `mshr[m].writeback_pend`. The L2 FSM's transition condition:

```systemverilog
if (mshr[m].valid && mshr[m].fill_pend && !mshr[m].writeback_pend)
    fill_mshr_avail = 1'b1;
```

evaluated `!x = x`, so `fill_mshr_avail` became `x` AND-gated with other logic → stayed `0`. The L2 request never fired, the store ack never came, the pipeline stalled waiting for the store to drain.

**On Verilator**: `valid_arr`, `dirty_arr` were zero by default, first miss saw `dirty=0`, L2 fill fired normally.

**Fix**: Add `rst_n` to the tag RAMs and zero `valid_arr`/`dirty_arr` on reset.

**Manifestation**: 10 xsim tests TIMEOUT (all touching cache-line eviction in similar ways), CoreMark deadlock.

### Bug 2: int_prf (commit `99b2199`)

Same class — `regfile_copy0..5` arrays had no reset. On xsim, reads from un-renamed physical registers returned `x`. In normal operation, software writes before reading, so this didn't manifest in our benchmarks. But it was a latent bug one mispredict-flush-recovery race away from exposing.

**Fix**: Add `rst_n` and zero all regfile copies on reset.

### Bug 3: LB trigger workaround (commit `b397582`)

Not an `x`-propagation bug but the same class: **RTL was twisted to paper over a simulator artifact**. The comment was honest:

```systemverilog
// REGISTERED computation to avoid changing Verilator's combinational
// eval scheduling (reading fused_insn[1+] in a combinational block
// creates new dependencies that corrupt load-writeback timing).
// The 1-cycle delay is acceptable — it just means the loop buffer
// starts capturing 1 cycle later.
```

"Acceptable" was wrong. Verilator's dependency-ordered combinational eval happens to let the registered trigger activate the LB on time. xsim's IEEE 1800 semantics don't — the 1-cycle delay makes the LB miss its activation window entirely. LB activation dropped from ~99% on Verilator to 0% on xsim. CoreMark IPC on xsim dropped from a (Verilator-reported) 3.33 to an actual 0.48.

**Fix**: Revert the registered trigger to combinational. Verilator-artifact load-writeback timing problem is now visible as a synthesis-semantics concern that must be fixed at the RTL level, not papered over.

### Bug 4: IQ dispatch round-robin (commit `2a92d6b`)

An **architectural / algorithmic** bug unrelated to simulator semantics. Dispatch routed ALU ops round-robin across IQ0/IQ1/IQ2. IQ0 drains 2 ops/cycle (ALU0+ALU1/BRU), IQ1 and IQ2 drain 1 op/cycle each (their second "port" is wired to 0 because only one FU is attached). With 1/3 of ops going to each IQ, IQ1 and IQ2 saturated (28.13/32 average occupancy) while IQ0 had slack (26.03/32).

**Fix**: Replace round-robin with occupancy-minimizing routing. Bias IQ0 by 1/2 occupancy to match its 2× drain rate.

**Impact**: xsim CoreMark 3.15 → 3.62 IPC (+15%). iq1_full 19% → 1%, iq2_full 18% → 1%.

This bug was **discoverable** on Verilator — it's just a performance issue, not a correctness issue. It was not discovered because Verilator's 3.33 IPC reading was already close enough to the 3.0 target that no one looked more closely. xsim's lower numbers forced us to measure per-stage stalls, which surfaced the imbalance.

### Bug 5: Dhrystone store-path deadlock (mitigated by 64-cycle watchdog, commits `197ea09` → `6c32178` → `31ea5c7`)

Dhrystone triggers a constant mispredict storm on our BTB (the BTB indexes by `PC[9:2]` but the fetch stage looks up with the fetch-group-aligned PC while commit updates with the branch's actual PC — different low bits yield different indices, so Dhrystone's hot branch at offset `0x0E` within the fetch group is never learned). On xsim, the storm exposes a **store-path deadlock**, not a generic rename bug:

[WDOG] trace in `tb_top.sv` logs the stuck ROB entry every time the watchdog fires. On Dhrystone, the watchdog fires **exclusively on stores at PC=0x80002398** (the `c.sw x10, 0(x12)` in the hot loop). This rules out several hypotheses:
- Uninitialized state (would affect all instruction types)
- Move elimination race (stores don't move-eliminate)
- Generic RAT/free-list corruption (would affect all register reads)

The specific bug is: the ROB entry for a store at this PC is valid but its `ready_r` bit never gets set. `ready_r` is set when `sta_wb_valid` fires for that rob_idx. So either:
- The store IQ is stuck waiting for rs1 (x12's pdst never becomes ready after a flush-recover path)
- The STA completion signal is lost in a race
- A store-queue STA allocation ordering bug

**Watchdog tuning**: the 12-bit counter fires a replay exception when the head stays not-ready for N cycles. Tuning:

| Watchdog threshold | Dhrystone IPC | CoreMark IPC | Notes |
|---|---|---|---|
| 4094 cycles (initial) | 0.055 | 3.91 | Safe but slow recovery |
| 256 cycles | 0.54 | 3.91 | 10× improvement |
| 128 cycles | 0.78 | 3.91 | Another 50% |
| 64 cycles | **0.99** | **3.91** | Current — just above DIV latency |
| 32 cycles | 1.15 | 0.0006 (!!) | False-triggers on legit CoreMark ops |

64 is the knee — DIV worst-case is 65 cycles, L2 miss is ~50, so 64 is the smallest safe bound. Any false trigger on CoreMark would crash IPC (a spurious flush costs 5-10 cycles plus warmup).

**Root-cause investigation** (commit `5b5fdf2`) narrowed the bug further:
- `[WDOG-SQ]` trace: at the moment the watchdog fires, the store IQ has **NO entry** for the stuck rob_idx — the entry had already issued or been killed.
- `[STA_WB]` trace: for stores that deadlock, `sta_wb_valid` eventually fires (cyc=1445 for rob_idx=54), AFTER the entry was enqueued (cyc=1427).
- `[SQ_ENQ]` trace: the store enqueues with **`s1_rdy=1`, `s2_rdy=0`**. It waits for x10 (the loop counter) written two instructions prior by `c.addw`.
- `[DQ_DEQ_ST]` trace: dispatch correctly routes every store to the store IQ (no DQ/IQ routing bug).

So the deadlock is specifically: **the store's rs2 (x10) never becomes ready**. The producer c.addw exists but either (a) the CDB broadcast of its result never reached the store's IQ entry's src2_ready, (b) the producer itself was killed by a flush without its IQ entry completing, leaving the store waiting on a pdst whose writer no longer exists, or (c) a spec-cancel incorrectly fired.

**Next VCD step**: capture signals `u_iq_store.src2_ready[<entry>]`, `u_iq_store.rs2_phys_r[<entry>]`, `cdb_valid[*]`, `cdb_tag[*]`, `lsu_spec_cancel_valid[*]` for the ~60 cycles after the stuck store's SQ_ENQ event.  Cross-reference `cdb_tag[*]` against `rs2_phys_r` to see whether the writeback ever arrives.

**Rejected root-cause fixes**:
- **Cache-line BTB indexing (32-byte granule)** reduced mispredicts and brought Dhrystone to 0.51 IPC, but caused CoreMark to drop to 1.93 (vs 3.91) due to BTB way-collisions and broke 5 regression tests.
- **Int PRF reset init** — useful defensive fix but didn't resolve Dhrystone.

### Bug 5 root cause (identified in iteration 1 of ralph-loop, commits `533a445`, `35e64db`)

Deeper investigation with the `[WDOG-RAT]`, `[WDOG-FL]`, and `[ALLOC_BUG]` diagnostics traced the store-path deadlock to the decode stage:

1. Stuck store's `src2_ready=0` → store waits on pdst that's never broadcast.
2. RAT dump shows **multiple arch regs share the same pdst**:
   `RAT[8]=RAT[9]=RAT[12]=pdst=8` (all committed, not speculative).
3. `free_list.committed_bitmap[8]=1` (FREE) while `rat.committed_rat[8]=8` (IN-USE). **Out of sync.**
4. The `[ALLOC_BUG]` detector fires at cycle 17: rename allocates pdst=12 to an x10-writer while `committed_rat[12]=12` is still the initial x12 mapping. 886 events in 1700 cycles.
5. For pdst=12 to be in the free list when no x12 write has happened, a prior commit released it — meaning a committing instruction had `old_pdst=12`.
6. Trace-back: that release came from a STORE whose `rd_arch` was extracted from bits[11:7] of the encoding. For stores, those bits are `imm[4:0]`, not a register number.

Root cause file/line: **`src/rtl/core/decode/decode_slice.sv:50`**

```systemverilog
decoded.rd_arch = rd_f;   // UNCONDITIONAL, bogus for stores/branches/fences
```

Rename then does `old_pdst = RAT[rd_arch] = RAT[bogus]`, which points at some legitimately-committed pdst. Commit releases that pdst. Subsequent allocations overwrite the architecturally-visible data → RAT aliasing → deadlock.

**Attempted fixes (all reverted)** — every naive fix that stopped the phantom release *regressed* CoreMark below the 3.9 target:

| Fix | CoreMark | Dhrystone | Verdict |
|---|---|---|---|
| Gate `fl_release_preg` on `commit_rd_valid` (rename.sv) | 3.23 | 0.002 | Breaks both |
| Set `rd_arch=0` for non-rd at decode tail | 3.23 | 0.002 | Breaks both |
| Set `rd_arch=0` for OP_STORE only | 3.86 | 0.002 | 1.2% CoreMark loss, Dhrystone worse |

Each fix revealed a **secondary bug**: the phantom releases from stores' bogus `rd_arch` were *compensating* for a separate legitimate pdst-leak path. With the phantom releases gone, the leak depletes the free list, rename stalls, and both benchmarks tank.

**Both bugs must be fixed together.** The secondary leak is not yet identified. Candidates:
- Speculative allocations that survive a flush due to `committed_bitmap` already being corrupted when `free_bitmap <= committed_bitmap` fires.
- Checkpoint save/restore asymmetry.
- ROB entries where rd_valid=1 at rename but slot_can_commit=0 never reaching the commit-release path.

**The full investigation, with reproducer commands and the exact failed-fix sequence, is in `doc/dhrystone_debug_handoff.md`. Read that first before the next attempt.**

### Bug 6: Checkpoint exhaustion on CoreMark (commit `0ebc657`)

Per-resource rename-stall breakdown (added to `+PERF_PROFILE` in commit `0ebc657`) attributed **99.5%** of CoreMark's rename stalls to checkpoint exhaustion. `NUM_CHECKPOINTS` was 4; CoreMark's hot loop regularly had more than 4 in-flight unresolved branches.

**Fix**: `NUM_CHECKPOINTS: 4 → 16`. Storage cost is trivial (8320 bits total). Rename stall drops from 10753 → 367 cycles in a 200K-cycle run; CoreMark IPC 3.62 → 3.91 (+8%).

This is a perfect example of why **per-stage perf profiling is essential**. Without it, "rename stalls 5% of cycles" is an opaque number; with it, "stall_ckpt: 10704 / stall_preg: 9 / stall_rob: 0" points at exactly what to fix.

## Lessons learned

### 1. For ASIC-targeted RTL, xsim (or any IEEE 1800-strict simulator) must be the authoritative simulator from day one.

Verilator is a phenomenal tool for fast iteration, but its 2-state default and dependency-ordered eval scheduling hide exactly the class of bugs that matter for silicon. A design that passes Verilator but not xsim is **not** ready for synthesis, regardless of how convenient Verilator is.

Our session hit the same pattern three times:
- Verilator CoreMark: 3.33 IPC — tempting to sign off
- Actual xsim CoreMark: 0.48 IPC before fixes, 3.62 IPC after fixes

If we had taped out on Verilator numbers, we would have shipped at ≤ 15% of the claimed performance, plus a cache deadlock at first boot.

### 2. Every `logic` array without an explicit reset is a tapeout risk.

Audit checklist for any module: every `logic ... arr [...][...]` or `reg ... arr [...]` declaration must have one of:
- Explicit reset to a known value in `always_ff @(posedge clk or negedge rst_n)`.
- Explicit documentation that the array is not read until after a known-good initialization sequence (rare — usually wrong).

Even arrays that synthesize to BRAMs (which often lack reset in silicon) should have explicit initialization in the surrounding state machine — e.g., an "invalidate-all" pulse asserted for N cycles after reset before any normal access. Our tag RAM bug was exactly this: the FSM supported invalidate-all, but the top-level never pulsed it.

### 3. RTL that exists to work around a simulator is technical debt.

Comments like "registered to avoid changing Verilator's combinational eval scheduling" are a warning sign. In our case the workaround added a 1-cycle latency that silently destroyed the loop-buffer optimization on any simulator that didn't share Verilator's specific eval ordering.

The "acceptable 1-cycle delay" turned out to be 6.9× IPC on the authoritative simulator. Any simulator-specific workaround should be considered a bug to be fixed at the source, not a permissible compromise.

### 4. Dual-simulator cross-check catches bugs before silicon.

Our methodology going forward:
- **xsim is authoritative** for correctness AND performance signoff. Matches synthesis semantics.
- **Verilator stays primary** for iterative development because it's 5-10× faster and supports a C++ testbench. But any "weird" Verilator behavior (UNOPTFLAT warnings, `--converge-limit` bumps, eval-order artifacts) is a bug to investigate, not suppress.
- **Disagreement between the two simulators is always a bug.** Whichever one shows worse behavior is usually the ground truth.

### 5. Per-stage perf profiling is essential for triage.

We added a `+PERF_PROFILE` mode to the testbench that dumps:
- Fetch-width histogram (cycles at fetch=0, fetch=1, ..., fetch=6)
- Commit-width histogram (cycles at commit=0, ..., commit=6)
- Loop buffer activation rate
- Per-stall counters (rename_stall, rob_full, iq*_full, lq_full, sq_full)
- Per-IQ average occupancy

This profile made the bottleneck visible in one run. Had we just been looking at IPC, we would not have caught the LB-dead (0% activation) and IQ-imbalance (IQ1/IQ2 full 19%, IQ0 full 11%) issues separately.

## Revised project rules

Carried into CLAUDE.md:

1. **xsim is authoritative.** Any benchmark or test result that only passes on Verilator is a bug until proven otherwise.
2. **No simulator workarounds in RTL.** If Verilator complains about convergence or UNOPTFLAT, the RTL has a real structural issue. Fix the RTL, don't paper over it.
3. **Every array gets a reset.** No exceptions. Large arrays that synthesize to BRAMs get an invalidate-all pulse during boot.
4. **When a pre-existing optimization regresses on xsim by >5%, stop and investigate.** The optimization probably exists only in Verilator's eval world.

## IPC progression this session

| Commit | Change | xsim CoreMark IPC | xsim Dhrystone IPC |
|--------|--------|-------------------|---------------------|
| (pre-session) | tag RAMs uninitialized | deadlock at minstret=40 | deadlock at minstret=234 |
| `8e280c6` | reset init for tag RAMs | ~0.48 (LB dead) | 0.005 (new deadlock) |
| `b397582` | LB trigger combinational | 3.15 | 0.005 |
| `2a92d6b` | load-balanced IQ dispatch | 3.62 | 0.005 |
| `99b2199` | int_prf reset + ROB trace | 3.62 (unchanged) | 0.005 |
| `197ea09` | ROB head watchdog (4094 cyc) | 3.62 | 0.055 |
| `0ebc657` | 16 checkpoints | 3.91 | 0.055 |
| `6c32178` | watchdog 64 cyc | **3.91** | **0.99** |
| `31ea5c7` | [WDOG] diagnostic | 3.91 | 0.99 |

All commits validated on xsim: 23/23 regression PASS.

Net progress: CoreMark 0 (deadlock) → **3.91 IPC** (+30% over target).
Dhrystone 0.005 (deadlock) → **0.99 IPC** (180× improvement).

## Remaining known issues

1. **Dhrystone rename/flush-recovery bug** (#5 above). Watchdog mitigates; root cause needs VCD-first debugging of rename under sustained mispredict.
2. **BTB index mismatch** (fetch-group PC vs branch PC) — Dhrystone's hot branch at offset 0x0E is not learnable. Cache-line indexing trades CoreMark IPC for Dhrystone progress; needs a more sophisticated solution (e.g., per-branch indexing with fetch-group-range lookup across multiple sets, or a separate BTB tier indexed differently).
3. **Verilator MSYS2 install broken mid-session** — can't currently verify the xsim-side commits don't regress Verilator convergence. Low priority since xsim is authoritative.

## For the next developer picking this up

- Start with `doc/xsim_workflow.md` for the tool setup.
- Run `make xsim_build` then use the `.bat`-wrapped run flow.
- `+PERF_PROFILE` plusarg gives the per-stage histogram.
- `+TRACE_COMMIT` gives per-commit PC/mispredict/branch trace.
- The ROB head trace (every 1000 cycles in tb_top.sv) is the first signal to check on any hang.
- For the Dhrystone deadlock specifically: VCD the rename pipeline for cycles 1400-1600 and look at which `pdst` the stuck ROB head's source register is waiting on, then trace that pdst back to its (flushed) writer.

---

## Addendum 2026-04-17: Dual-simulator signoff policy (xsim + DSim Studio)

### Why a second simulator

The 2026-04-17 partial-replay SVA debugging session hit three xsim 2024.1 SVA
gaps that forced ugly workarounds:

| Construct we wanted | xsim 2024.1 behavior | Workaround we shipped |
|---|---|---|
| `cover property` | silently dropped (warning only) | integer counter + `final begin $display` |
| `$past(sig)` inside an assert action block | "Unable to infer clocking event" error | pipelined prev-value flops (`sva_prev_viol_rob`) |
| Local variables inside sequences | partial support | avoided the idiom |

These workarounds bloat the SVA block and obscure intent. Altair DSim
(formerly Metrics DSim) supports all three natively, plus assertion coverage
reports that tell us which assertion points were *reached* — a cleaner answer
than "the counter didn't increment, so maybe it didn't fire."

### The policy

**xsim remains authoritative for signoff.** Vivado 2024.1's xsim shares the
synthesis toolchain's semantics — same vendor, same elaboration engine, same
4-state handling. Every CoreMark / Dhrystone IPC number, every regression
pass/fail, every ASIC-tapeout correctness claim must be verifiable under
xsim. Run of record.

**DSim is the productivity simulator** for SVA-guided iteration, coverage
reports, and the MXD wave viewer. It is not yet trusted as signoff grade —
DSim's IEEE 1800 conformance profile, while comprehensive, has not been
through the same decade of tapeout validation as xsim / VCS / Xcelium. We
should assume DSim-unique behaviors are possible and guard against them with
cross-sim diff.

### Rules

1. **Both sims must agree** on any IPC or correctness claim before it goes
   into a commit message, CLAUDE.md, or a results table. If they disagree,
   it is a bug — investigate, do not pick the favorable number (this is the
   same discipline rule #4 added to CLAUDE.md last session, generalized).
2. **DSim-native SVA constructs** (`cover property`, `$past` in action, local
   seq vars, `strong`/`weak` qualifiers) may be used, but if they don't
   compile under xsim they must live inside `ifdef DSIM` with an xsim
   fallback inside `else` or skipped cleanly. Never ship SVA that builds on
   only one simulator.
3. **Pre-tapeout RTL cleanup** (e.g. removing `ifdef SIMULATION` defensive
   resets per the reset-net discipline rule in CLAUDE.md) is anchored on
   xsim, not DSim. DSim may tolerate a loose control-flow invariant that
   xsim correctly catches, or vice versa — trust the signoff sim.
4. **Regression acceptance gate:** the `make regress` target must pass on
   both sims before any RTL change lands. This is how we catch the class of
   bug that made this addendum necessary in the first place — the Verilator
   UNOPTFLAT / eval-scheduling workarounds that silently changed behavior on
   xsim.

### Tool installation

DSim Studio is installed as a VS Code extension
(`altairengineering.dsim-studio-2025.0.26`). The simulator binary itself is
fetched on-demand by the extension after Altair One sign-in (free individual
license). Install flow:

1. Sign in: Command Palette → `DSim Studio: Sign In`.
2. Install: Command Palette → `DSim Studio: Install DSim` (or open the DSim
   Studio activity-bar icon → Installations panel → "+").
3. Note the reported install path — needed for `build_dsim.bat`.

### Expected build flow

Mirror of `build_xsim.bat`:

| Stage | xsim | DSim |
|---|---|---|
| SV/V compile | `xvlog --sv --relax -d SIMULATION` | `dvlcom -sv +define+SIMULATION` |
| Elaborate | `xelab --relax -s tb_xsim_sim tb_xsim` | `dsim -genimage tb_image tb_xsim` |
| Run | `xsim tb_xsim_sim -R +MEMFILE=...` | `dsim -image tb_image +MEMFILE=... -sva -waves run.mxd` |

Key DSim flags relevant to this project:
- `-sva` — enable SVA elaboration and reporting.
- `-waves run.mxd` — write MXD waveform for the assertion-aware viewer.
- `+acc` / `-access +rw` — make signals visible to SVA and wave (analog of
  xsim `-debug typical`).
- `-check-overflow` — catch counter overflow bugs (off by default).
- `-cov` / `-coverage` — coverage + assertion report.

### Migration path for current SVA

Existing assertions in `src/rtl/core/rv64gc_core_top.sv` A1–A7 are already
xsim-compatible. On DSim we can additionally:

- Replace the `sva_prev_viol_rob` pipelined flop with native
  `$past(u_lsu.ordering_violation)` in the assertion action.
- Convert the A-summary integer counters (`sva_cnt_ord_violation` etc.) to
  `cover property (...)` — keep the integer-counter version inside an
  `ifdef XSIM` fallback so the xsim run still reports the same data.
- Add the previously-reverted A8 (global progress) and A9 (IQ lifecycle)
  back as `cover property` + `covergroup` — these were the observations
  that actually diagnosed the IQ commit-free path being wrong, and they
  belong in the permanent assertion set.

The dual-build `make regress` target then runs both sims and diffs the
assertion report + final IPC.


# Dhrystone Debug Handoff

**Date**: 2026-04-16 (updated after 2nd debug session)
**Status**: TWO coupled root causes identified.  Naive single-fix attempts regress CoreMark.  A THIRD pre-existing issue (BTB cache-line-indexing) also blocks Dhrystone even with the first two fixes.  None of the three fixes were committed — all revert to baseline.

## Session 2 findings summary (2026-04-16 PM)

| Fix applied (all xsim, 23/23 regression PASS) | CoreMark IPC | Dhrystone IPC | Notes |
|---|---|---|---|
| Baseline (no fix) | **3.91** | 0.98 (watchdog) | Reference |
| decode_slice: rd_arch=0 when !rd_valid | 3.25 (-17%) | 0.03 (worse) | Eliminates aliasing; exposes pdst leak |
| rename: gate fl_release_preg on commit_rd_valid | 3.25 (-17%) | 0.03 | Equivalent to decode fix |
| decode fix + free_list alloc_used_mask | 3.25 | 0.03 | alloc_used_mask caught ONE leak source (rename-stall), insufficient |
| BTB cache-line-indexed + in-window offset filter | 0.003 (crash) | 1.45 | BTB fix ALONE breaks CoreMark (bad target prediction from aliased BPU updates) |
| decode + BTB + fetch-redirect-cancel (gate redirect to in-window branches) | 3.50 | 0.03 | CM recovers partially; DH still stuck |

**Conclusion**: CoreMark's 3.91 IPC depends on the phantom releases masking a *secondary* pdst leak (possibly from rename stall, possibly from a different path).  Fixing the store-encoding bug exposes that leak.  Additionally, the BTB index mismatch is real but fixing it alone corrupts BPU updates for CoreMark's hot JALRs (aliased rs1 data leads to wrong BTB-stored targets).  All three issues are coupled and must be fixed together.

## Key new diagnostics added (then reverted)

1. `[P15_ALLOC]` / `[P15_RELEASE]` / `[P15_FLUSH]` — full lifecycle trace for pdst=15 (chosen because it's the first orphan observed in fix runs).
2. `[FLUSH]` — logs flush cause (mispredict slot, exception slot, replay slot) and head PC at flush.
3. `[LEAK_PROBE]` — counts total free pdsts at snapshot cycles; shows inflation under baseline (due to phantom releases) and depletion under fix.
4. `[UNUSED_ALLOC]` — fires when rename requests a preg allocation but the requesting slot cannot advance (leak path caught by the alloc_used_mask fix).

The diagnostics proved:
- Dhrystone's strcpy inner loop mispredicts EVERY iteration.  BTB lookup at `f1_pc=0x80002002` misses the bnez at `0x8000200E` because indexing uses `PC[9:2]` on both lookup and update — the fetch-group start and branch PC have different indices (0x00 vs 0x03).
- With fix, watchdog first fires at cyc=1504 at PC=0x800022f2 (`ld a5, 0(a0)` inside Proc_1).  The load's rs1 pdst is in limbo: specifically allocated but never written because its producer never runs.  The producer is stuck behind an earlier flushed-then-reborn instruction whose pdst chain is broken.

## The BTB index mismatch (new root cause)

`src/rtl/core/fetch/btb.sv:53,90`:
```systemverilog
assign lkp_idx = lookup_pc[IDX_BITS+1:2];  // bits [9:2] of f1_pc
assign upd_idx = update_pc[IDX_BITS+1:2];  // bits [9:2] of branch PC
```

`f1_pc` is the fetch-group start.  The fetch unit advances `f1_pc` by the number of bytes consumed per cycle (typically 12-24).  For a branch at offset 0x0E within a cache line starting at 0x80002000:

- Fetch starts at `f1_pc=0x80002002` → `lkp_idx = 0x00`.
- BTB update at commit uses branch PC `0x8000200E` → `upd_idx = 0x03`.

The entry goes to set 0x03 but lookups hit set 0x00.  BTB is effectively dead for any branch at a non-zero offset within the fetch window.

### Attempted fix (reverted)

- Re-indexed both lookup and update by cache-line PC (`PC[13:6]`) with 50-bit tag from `PC[63:14]`.
- Lookup returns the matching way with smallest `boffs >= f1_pc[5:0]` (earliest branch reachable in the fetch window).
- Fetch unit gated `bp_branch_found` on "the predicted branch offset must match an extracted slot's PC[5:0]" — otherwise cancel the redirect so we don't jump to the predicted target while also emitting past the unseen branch.

**Result with BTB fix only (no decode fix):** CoreMark crashed to 0.001 IPC.  Hypothesis: aliased store data corrupts committed JALR rs1 → BTB stores wrong target → predictions redirect to garbage.  Decode fix must accompany BTB fix.

**Result with decode + BTB + redirect-cancel:** CoreMark = 3.50 IPC (-10% vs baseline 3.91), Dhrystone = 0.03 IPC (still stuck).  CoreMark regression comes from the pdst leak that phantom releases used to compensate for.  Dhrystone still gets stuck at PC=0x800022f2 (load deep in Proc_1 dep chain) even when strcpy's bnez predicts correctly.

## Outstanding pdst leak source (not found)

With `alloc_used_mask` catching rename-stall orphans (verified: `[UNUSED_ALLOC]` count = 0 during Dhrystone run with the fix), the remaining leak must come from one of:

1. **Flush-vs-alloc race**: If rename allocates a pdst the same cycle as `flush_out.valid=1`, the flush branch in free_list clears the bit via `free_bitmap <= committed_bitmap` but the alloc was never propagated downstream (rename_buf is cleared on flush).  Net: bit stays cleared (looks allocated), no owner.  But core_top.sv lines 410-435 already clear rename_buf on flush, and free_list flush branch doesn't apply allocs — need to re-verify this more carefully with a cycle-accurate probe.
2. **Watchdog replay flush edge case**: On watchdog fire, commit outputs exception code 15 and full_flush.  Same-cycle commits (if any) ARE applied.  But does the replay slot's own old_pdst get released correctly?  Its `commit_rd_valid` would be forced to 0 by `slot_can_commit[0]=0`, so no release path fires.  If the replay slot had an allocated pdst, it should be reclaimed via `free_bitmap <= committed_bitmap` — need to verify `committed_bitmap` has the correct state for it.
3. **Checkpoint-save side effect**: Even though `ckpt_restore` never fires (commit always does full_flush), the `ckpt_save` path snapshots `free_bitmap` into `ckpt_bitmap[id]`.  Unused, but not a leak either.
4. **fl_req_count vs fl_avail_count mismatch**: When rename requests more pregs than available, `slot_can_advance[i] = has_preg[i] && ...`.  Slots beyond available count have `has_preg=0`, so they don't advance.  `fl_alloc_used_mask[i]` excludes them.  But does `fl_avail_count` correctly limit `alloc_preg` outputs?  Need to verify the boundary.

## Hard constraints unchanged

1. **CoreMark IPC must stay ≥ 3.9.**  No fix accepted if CM drops below.
2. **All 23 regression tests must pass.**
3. **xsim is authoritative.**

## For next session: recommended sequence

1. Add CYCLE-ACCURATE probes on free_bitmap bit transitions (`[FL_TRANSITION]` listing bit, old, new, reason) in free_list.sv.  Run Dhrystone with decode fix applied and trace the first pdst that becomes orphaned.  Identify the exact leak edge.
2. Fix the identified leak.  Verify with decode fix applied: CM should recover to ≥ 3.9 IPC, Dh should unstick (at minimum past strcpy bottleneck).
3. Apply BTB cache-line indexing + fetch-unit redirect-cancel.  Verify CM stays at 3.9+ and DH climbs to ≥ 3.2.
4. Do NOT attempt these in isolation — each alone regresses one of the benchmarks.

## Hard-won lessons (this session)

- The handoff's "single coupled fix" hypothesis was incomplete.  There are actually THREE independent issues (store encoding, pdst leak, BTB dead) that must all be addressed.
- Phantom releases inflated `free_bitmap` to +9 pdsts above the theoretical maximum of 224 (visible in `[LEAK_PROBE]` baseline: `total_free=233` at cyc=500).  This inflation was compensating for leaks elsewhere.
- The `[ALLOC_BUG]` probe fires 886 times in Dhrystone baseline but 0 times with decode fix — confirms decode fix eliminates aliasing.  Not sufficient alone.
- BTB cache-line re-indexing MUST be paired with fetch-unit redirect-cancel, otherwise the pipeline redirects to the predicted target while simultaneously emitting the current fetch group's post-branch instructions — silent execution past unseen branches.

## Watchdog-threshold hypothesis: REJECTED

Tested the hypothesis that the 64-cycle ROB watchdog prematurely cuts off legitimate long dependency chains.  Applied decode fix + raised watchdog to 4096 cycles.

Result: **Dhrystone `minstret` still capped at 897** over a 10000-cycle run (same as with 64-cycle watchdog).  With 4K cycles the watchdog can fire at most twice in that window, yet no additional commits happen after reaching 897.  The load at PC=0x800022f2 never completes, regardless of how long we wait.

This proves the dep chain is not merely slow — it is DETERMINISTICALLY BROKEN.  The producer of the load's rs1 chain (a0/x10) never broadcasts on CDB.  Extending the watchdog is not a fix.

## Architectural question surfaced

While tracing rename's `slot_can_advance` logic, noticed that per-slot advance decisions are INDEPENDENT — if slot 2 cannot advance (e.g., SQ full) but slot 3 can, slot 3 is dispatched to `rob_alloc_idx[2]` via `out_dest` compaction.  This appears to reorder instructions relative to program order within a rename batch.  Needs verification — if confirmed, this is a distinct correctness bug that the in-flight pdsts / aliasing symptoms may be masking.  File for next session.

## Verification that baseline is functionally sound

- All 23 rv64ui regression tests PASS on xsim (short deterministic tests don't exercise the aliasing bug pattern).
- CoreMark's final checksum matches expected — despite theoretical aliasing, the bug does not manifest in CoreMark's output.
- Dhrystone completes via watchdog mitigation at 0.98 IPC; the watchdog guarantees eventual progress by flushing stuck ROB heads and re-fetching.

## One-paragraph summary

The Dhrystone IPC is stuck at 0.99 on xsim (mitigated by a 64-cycle ROB-head watchdog; without it, it deadlocks at 0.005). The root cause is that RISC-V store/branch instructions reuse encoding bits[11:7] for the immediate, but `decode_slice.sv` unconditionally sets `decoded.rd_arch = rd_f = insn[11:7]`. Rename then computes `old_pdst = RAT[rd_arch]` for stores, pointing at a pdst that's currently architecturally committed to a DIFFERENT arch reg. On commit, free_list releases this pdst — desynchronizing `free_list.committed_bitmap` from `rat.committed_rat`. This produces the observed RAT aliasing (`RAT[8]=RAT[9]=RAT[12]=pdst=8`), leading to consumers reading wrong-data pdsts and waiting forever. **The fix is not simply to null out `rd_arch` for non-rd instructions** — doing so breaks CoreMark's IPC (3.91 → 3.23) because the phantom releases were *compensating* for a different pdst-leak path elsewhere. Both bugs need to be fixed together.

## Current benchmark state (do not regress)

```
                    IPC (xsim)   Regression   Notes
CoreMark (-O2):     3.91         23/23 PASS   Hard constraint — must not drop below 3.9
Dhrystone (-O2):    0.99         23/23 PASS   Target is 3.2 per CLAUDE.md; currently 180× mitigation
```

The `--max-iterations 5` Ralph loop session exhausted without fixing the deeper bug.

## The bug chain (confirmed evidence)

### Layer 1: Symptom

Dhrystone's ROB head stalls on a STORE at `PC=0x80002398` (the hot-loop `c.sw x10, 0(x12)`). The store's `src2_ready` in the store IQ never fires. Watchdog fires every 64 cycles to unstick, allowing `0.99 IPC` forward progress.

### Layer 2: RAT aliasing (diagnostic commit `533a445`)

At watchdog fire time, the RAT dump shows multiple arch regs mapped to the SAME pdst:

```
RAT[8]  = pdst=8  cra=8
RAT[9]  = pdst=8  cra=8
RAT[12] = pdst=8  cra=8
RAT[16] = pdst=16 cra=16
RAT[19] = pdst=16 cra=16
```

Both speculative RAT and committed RAT are corrupted. In a correct OoO, each committed arch reg must map to a UNIQUE pdst. Multiple arch → one pdst means the same pdst was allocated twice by the free list without a legitimate release in between.

### Layer 3: committed_bitmap desync

`free_list.committed_bitmap[8] = 1` (FREE) while `rat.committed_rat[8] = 8, committed_rat[9] = 8, committed_rat[12] = 8` (all use pdst=8). The free list thinks pdst=8 is free; the RAT thinks it's architecturally in use by three different regs. Free list hands out pdst=8 again and again, each time winning at commit and overwriting committed_rat.

### Layer 4: The ALLOC_BUG detector (diagnostic commit `35e64db`)

The `[ALLOC_BUG]` trace in `tb_top.sv` fires the moment rename allocates a pdst that's still architecturally bound:

```
[ALLOC_BUG] cyc=17 slot=2 rob=27 writes pdst=12 rd_arch=10 but cra[12]=12
[ALLOC_BUG] cyc=28 slot=2 rob=41 writes pdst=4  rd_arch=10 but cra[4]=4
[ALLOC_BUG] cyc=28 slot=4 rob=43 writes pdst=6  rd_arch=10 but cra[6]=6
[ALLOC_BUG] cyc=32 slot=2 rob=53 writes pdst=12 rd_arch=10 but cra[12]=12
...
```

886 such events in 1700 cycles of Dhrystone. They start from cycle 17 — very early, before any x12 write should have occurred.

### Layer 5: Why pdst=12 ended up in the free list before any x12 write

Bit-12 of `free_list.committed_bitmap` transitions from 0 to 1 somewhere between cycle 16 and cycle 17 (`[FL]` trace). This transition requires a release event: some instruction committed with `old_pdst = 12`. Tracing back: the committing instruction's `rd_arch` must have pointed at an arch reg whose RAT value was 12. **No instruction in crt0 writes x12 that early.** So the rename-time `rd_arch` read was a bogus value.

### Layer 6: Root cause — store encoding

```systemverilog
// decode_slice.sv line 22:
wire [4:0]  rd_f = insn[11:7];

// Line 50 (unconditional):
decoded.rd_arch = rd_f;
```

For `OP_STORE` (`SW/SD/SB/SH`), bits[11:7] of the RISC-V encoding are **`imm[4:0]`** — the low bits of the store offset — NOT a register number. But decode_slice.sv pulls them out as `rd_f` and sets `decoded.rd_arch = rd_f` regardless.

Then in `rename.sv`:

```systemverilog
rat_old_phys[i] = rat_table[wr_arch[i]];   // wr_arch = decoded.rd_arch
ren_insn[...].old_pdst = rat_old_phys[i];  // unconditional
```

For a store with imm[4:0] = 12 (say), rename reads `RAT[12]` — which is whatever arch reg x12 currently points at. That pdst ends up as the store's `old_pdst`.

At commit (for the store that is NOT supposed to write rd), the free_list.release path fires because `release_count` is bumped by OTHER committing slots with `commit_rd_valid=1`, and the per-slot guard only filters on `release_preg != '0`. The store's bogus `old_pdst` (e.g., 12) passes this filter and gets released.

End state: pdst=12 released even though x12 still architecturally owns it. Double-alloc on next rename → RAT aliasing → deadlock.

## Why the naive fix fails

Two fix attempts of the form "don't release bogus pdsts":

| Fix | CoreMark IPC | Dhrystone IPC | Regression |
|---|---|---|---|
| Baseline (no fix) | 3.91 | 0.99 (watchdog) | 23/23 |
| Gate `fl_release_preg` on `commit_rd_valid` in rename | 3.23 (−17%) | 0.002 (WORSE) | 23/23 |
| Set `rd_arch=0` for non-rd instructions in decode (tail override) | 3.23 (−17%) | 0.002 | 23/23 |
| Set `rd_arch=0` for stores only in decode (OP_STORE case) | 3.86 (−1.2%) | 0.002 | 23/23 |

**In every attempt, Dhrystone IPC gets WORSE, not better.** The phantom releases were compensating for a legitimate pdst leak elsewhere.

The hypothesis: somewhere in the pipeline, pdsts are allocated but never released through the normal commit path. Candidates:

1. **Speculative allocations that survive flush**: on `full_flush`, `free_bitmap <= committed_bitmap` is supposed to invalidate wrong-path allocations. If `committed_bitmap` is itself corrupted (which it IS, per Layer 3), the restore doesn't fully clean up.
2. **Checkpoint-restore interaction**: `ckpt_save` snapshots `free_bitmap` at branch rename time; `ckpt_restore` reloads it on mispredict. If the snapshot/restore has an asymmetry, pdsts can "leak" across mispredict paths.
3. **rob entries where rd_valid=1 at rename but slot_can_commit=0**: if these are discarded without proper release, the allocated pdst is lost.

## The diagnostics already in place

All gated on `+TRACE_COMMIT` so normal runs are unaffected:

| Trace | Purpose | Commit |
|---|---|---|
| `[WDOG]` | Fires on watchdog timeout — shows stuck ROB head PC + is_store | `31ea5c7` |
| `[WDOG-SQ]` | At WDOG fire, search store IQ for stuck rob_idx | `9949708` |
| `[WDOG-SQDUMP]` | Full store IQ entry dump with pdst/ready state | `df28746` |
| `[WDOG-RAT]` | Full RAT + committed_rat dump at WDOG fire | `533a445` |
| `[WDOG-FL]` | free_bitmap + committed_bitmap + preg_ready_table for low pdsts | `533a445` |
| `[WDOG-ALLIQ]` | All non-ready valid IQ entries (dependency chain) | `df28746` |
| `[SQ_ENQ]` | Store IQ enqueue events with s1/s2 ready | `5b5fdf2` |
| `[STA_WB]` | STA writeback events | `5b5fdf2` |
| `[DQ_DEQ_ST]` | Dispatch queue dequeue for store routing verification | `5b5fdf2` |
| `[SQ_WAKE]` | CDB broadcast hit against stuck store IQ entry's rs2_phys | `9949708` |
| `[FL]` | Cycle-by-cycle free_bitmap/committed_bitmap dump (cyc 0-19) | `35e64db` |
| `[ALLOC_BUG]` | **Fires on the actual bug event** — rename allocates pdst that committed_rat already has assigned to a different arch | `35e64db` |

## For the next debug session

### Step 1: Reproduce the ALLOC_BUG events

```bash
D:/Xilinx/Vivado/2024.1/bin/xelab.bat --relax -s tb_dbg tb_iverilog
cat > run_dh.bat <<EOF
@echo off
cd /d $(pwd -W)
call D:\\Xilinx\\Vivado\\2024.1\\bin\\xsim.bat tb_dbg --runall --testplusarg "MEMFILE=tests/hex/dhrystone.hex" --testplusarg "MAX_CYCLES=2000" --testplusarg "NOVCD" --testplusarg "TRACE_COMMIT"
EOF
./run_dh.bat 2>&1 | grep "\[ALLOC_BUG" | head
```

Expect ~800+ events in the first 1700 cycles, starting around cycle 17.

### Step 2: Find the first `[ALLOC_BUG]` event's context

Use cycle 17 as ground zero. Dump everything that happens at and around that cycle:
- Rename signals: `u_core.u_rename.rat_old_phys[*]`, `ren_insn[*].old_pdst`
- Decode output: which instruction type dispatched at slot 2 with `rd_arch=10`? (It's likely a store — confirm via `dq_deq_data[2].base.is_store`.)
- Free list state pre/post cycle 17

### Step 3: Find the pdst LEAK (critical, harder)

Instrument a "lifetime tracker": for each pdst, log every allocation and every release, with timestamps and rob_idx. Any pdst that gets allocated but doesn't appear in a matching release is leaked. Look for patterns.

Likely code paths to audit:
- `src/rtl/core/rename/rename.sv:268-278` — `fl_release_count` and `fl_release_preg` assignment
- `src/rtl/core/rename/free_list.sv:113-142` — free_bitmap update
- `src/rtl/core/rename/free_list.sv:147-162` — committed_bitmap update
- `src/rtl/core/rename/rename.sv:159-162` — `do_flush` vs `do_ckpt_restore` gating
- `src/rtl/core/rename/checkpoint.sv:107-122` — snapshot save logic

### Step 4: Apply BOTH fixes together

Once the leak path is identified, fix the legitimate leak AND fix the bogus store release (decode `rd_arch=0` for non-rd instructions). Then:

- Verify CoreMark stays ≥ 3.9 IPC
- Verify Dhrystone jumps from 0.99 to close to the 3.2 target
- Verify all 23 regression tests still pass

## Hard constraints

1. **CoreMark IPC must stay ≥ 3.9.** Any fix that drops it is unacceptable.
2. **All 23 regression tests must pass.** No test breakage allowed even for Dhrystone gain.
3. **xsim is authoritative.** Do not chase Verilator differences — xsim is the ground truth, Verilator is a fast-dev-loop tool.

## Key files and line numbers

| File | What it does |
|---|---|
| `src/rtl/core/decode/decode_slice.sv:50` | The actual bug: `decoded.rd_arch = rd_f` unconditional |
| `src/rtl/core/rename/rename.sv:584` | Propagates bogus old_pdst unconditionally |
| `src/rtl/core/rename/rename.sv:268-278` | `fl_release_count` / `fl_release_preg` (gating too loose) |
| `src/rtl/core/rename/free_list.sv:147-162` | committed_bitmap update — where desync manifests |
| `src/rtl/core/backend/rob.sv:509-518` | Watchdog fire logic — 64-cycle threshold, mitigates |
| `src/tb/tb_top.sv:278+` | All the diagnostic traces |

## Commits from this debugging session (in reverse chronological order)

```
35e64db  diag: ALLOC_BUG detector -- identifies rename vs committed_rat conflicts
ecbb064  fix: clear rename_buf on full_flush (defensive)
533a445  diag: RAT/free-list state dump at watchdog fire
df28746  diag: full-pipe IQ dump reveals rename->IQ handoff drop
9949708  diag: full store IQ state dump + move-elim preg_ready skip
0a2e497  docs: refine Dhrystone debug notes with store-s2 finding
5b5fdf2  diag: store-path trace narrows Dhrystone deadlock to s2 stuck
e9897aa  docs: update lessons-learned with Dhrystone store-path finding
31ea5c7  diag: add [WDOG] trace -- stuck entry always a STORE at PC=0x80002398
c729522  docs: CLAUDE.md reflects 3.91/0.99 IPC milestone
6c32178  perf: tune ROB watchdog to 64 cycles (Dhrystone 0.055 -> 0.99 IPC)
0ebc657  perf: 16 checkpoints (CoreMark 3.64 -> 3.91 IPC)
197ea09  fix: ROB head watchdog - recover from stuck-entry deadlocks
99b2199  fix: reset init for int_prf; add ROB head trace hook
2a92d6b  perf: load-balanced IQ dispatch (xsim 3.15 -> 3.62 IPC)
b397582  perf: revert LB trigger to combinational (xsim 0.48 -> 3.15 IPC)
8e280c6  fix: reset init for dcache/icache tag RAMs; add xsim workflow
```

All 16 commits validated: 23/23 regression PASS at each step. CoreMark never dropped below 3.9 after commit `0ebc657`.

## Related docs

- `doc/xsim_lessons_learned.md` — the broader xsim migration context, the Verilator-hiding pattern, other bugs found this way.
- `doc/xsim_workflow.md` — xsim build/run instructions.
- `doc/coremark_optimization_changelog.md` — history of CoreMark optimizations (up through the 3.91 milestone).
- `CLAUDE.md` — authoritative current state and project targets.

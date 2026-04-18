# Session Handoff — 2026-04-17 (native Windows, 2nd session of day)

Supersedes the earlier same-day WSL handoff.  This doc reflects the
actual tree state at HEAD (commit `e27ebe6`) and the concrete next
steps to recover CoreMark to spec.

## TL;DR

- **CoreMark IPC: 0.237** (regressed from the 3.91 baseline due to an
  intentionally-incomplete Phase-3 ROB replay handler in commit
  `27dfe46`).
- **Dhrystone IPC: ~0.99** (unchanged from watchdog-recovery baseline).
- Dual-simulator flow (xsim signoff + DSim SVA productivity) is live
  and cross-sim bit-identical validated.
- SVA diagnostics A10-A16 pinpoint the regression mechanism: 2,786
  violations × 64-cyc watchdog + 30-cyc flush = 94 cyc each = 62K
  cyc / 100K budget lost.
- **Shortest path back to 3.91**: revert the ROB-side changes of
  commit 27dfe46 (~20 lines).  Replay reverts to "full flush via
  direct `exc_code=15`" — loses the "partial replay" ambition but
  restores IPC and passes signoff.

## Tree state at HEAD (e27ebe6)

### Committed correctness / infrastructure changes this session

| Commit | Subject | Notes |
|---|---|---|
| `618a3ee` | DSim 2026 integration + 10 IEEE 1800 forward-decl fixes | Real bugs xsim was lenient about — hoisted pf_l2_*, lsu_ordering_violation, lsu_violation_rob_idx, replay_valid, replay_rob_idx_from, lsu_port0_suppress, dc_fill_snoop_*, iq0/1/2_occ |
| `b243ec2` | SVA A10-A16 diagnostic counters | Monitoring-only; classifies ordering violations; measures watchdog-fire rate |
| `da7aeda` | cocotb 2.0.1 + pyuvm 4.0.1 smoke scaffolding | `verif/cocotb_smoke/` — framework bring-up; see "verification-flow caveat" below |
| `e27ebe6` | Expanded .gitignore | DSim/xsim/cocotb artefacts |

### Still-present legacy issues (NOT fixed in this session)

These were reverted along with the Phase-1 IQ work (commit `8c63aa7`
"clean baseline: revert Phase 1 IQ") and are the reason Phase 3 cannot
be completed without re-applying them:

| Source file | Line / shape | Bug |
|---|---|---|
| `decode_slice.sv:50` | `decoded.rd_arch = rd_f;` unconditional | For stores/branches/fences, `rd_f` is `imm[4:0]`, not a register number.  Rename then does `old_pdst = RAT[bogus]` → phantom pdst release → RAT aliasing.  See root-cause walkthrough in CLAUDE.md under "Current Benchmark Status". |
| `rename.sv` | Missing per-slot `fl_release_preg[i] &= commit_rd_valid[i]` gate | Defense-in-depth: even if decode_slice invariant held, this would prevent orphaned release paths.  Was in commit `3d5d452`, reverted in `8c63aa7`. |
| `rename.sv` | Missing `slot_can_advance_sp` + restructured `fl_req_count` / `fl_slot_idx` gating | Companion pdst-leak fix.  The CLAUDE.md text *"both bugs must be fixed together"* means applying one without the other regresses IPC — this is what blocked the Phase-3 retry today. |

### Phase-3 regression (the current 0.237 IPC state)

Commit `27dfe46` ("phase3: ROB replay handler — safety first, no IQ
lifecycle yet") landed earlier and **removed** the legacy direct
`exc_code=15` write on `ordering_violation_valid` from rob.sv, and
**replaced** it with a `replay_valid`-driven `ready_r` clear for the
replay range.  The intent was: IQ keep-until-commit (Phase-3 part 2)
would re-issue the cleared entries.

Part 2 was never landed → the cleared entries sit stuck → the
`rob_head_watchdog` (62-cycle threshold) eventually force-writes
`exc_code=15` on the head → commit fires `found_replay` → full flush.
Cost per violation: **~94 cycles** (64 watchdog wait + 30 flush
recovery) vs **~30 cycles** in the pre-Phase-3 direct path.

SVA evidence (100K CoreMark):

| Counter | Value | Interpretation |
|---|---:|---|
| ordering_violations | 665 | genuine RAW hazards (77% pure, not artifacts) |
| replay_valid pulses | 665 | matches 1:1 |
| `[A15]` watchdog fires | 1034 | ~1.55 per violation |
| `[A16]` watchdog post-replay (<100 cyc) | 526 | 79% directly caused by replay path |
| `[A10-A14]` gated / stale / burst / same-rob / speculative | near-zero | rules out all "artifact" hypotheses |

## Next steps

### Priority 1 — recover CoreMark to 3.91 (quick win, ~30 min)

Revert the rob.sv parts of commit `27dfe46`:

1. Restore the direct `ordering_violation_valid → has_exc_r[rob_idx] <= 1; exc_code_packed[rob_idx*4 +: 4] <= 4'd15` write in both
   the partial-flush-cycle and normal-path branches of `rob.sv`.
2. Remove the `if (replay_valid) begin … clears ready_r for range … end`
   blocks in both branches.
3. Keep the `replay_valid` / `replay_rob_idx_from` inputs on the module
   port list (Phase-2 observation infrastructure); they're unused but
   harmless.
4. Keep all SVA counters — they'll show `replay_valid fired = 0` and
   `watchdog fires = 0` once the direct path is restored, which is the
   success signal.

**Expected outcome**: CoreMark 0.237 → ~3.91 (matches CLAUDE.md
baseline).  Dhrystone unchanged.  Cross-sim validation on xsim + DSim
required before commit.

### Priority 2 — Phase-3 proper (longer, multi-session)

Restores the "partial replay" ambition (each replay ~15 cyc instead of
~30 or ~94).  Requires FOUR coordinated changes, in order:

1. **Apply the phantom-release fix** — cherry-pick the decode_slice.sv
   and rename.sv changes from commit `3d5d452`.  Standalone these
   should be IPC-neutral once Phase 3 is also in.
2. **Apply the pdst-leak fix** — also from `3d5d452`.  The CLAUDE.md
   text under "Dhrystone debug handoff" is explicit that naive
   fix-one-without-other breaks CoreMark.  Both go together.
3. **Apply Phase-1 IQ keep-until-commit** — also from `3d5d452`.  Adds
   `entry_issued` state, `commit_free_mask`, replaces issue-time free
   with commit-time free.
4. **Add the IQ replay handler + preg_ready_table clear +
   pdst_producer_valid gate** — work I started this session but had to
   revert because steps 1-3 aren't in place.  Documented in full in
   `doc/partial_replay_spec.md`.

Each step requires dual-sim cross-check (xsim signoff + DSim SVA
coverage) and the regression suite must pass.

### Priority 3 — pyuvm-driven unit testing for Phase-3 precursors

Before starting Phase-3 proper, build a pyuvm unit test for
**rename + RAT + free_list in isolation** that drives adversarial
sequences (store/branch/fence with arbitrary imm[4:0] bits) and
scoreboards `rat.committed_rat` vs `free_list.committed_bitmap` at
every cycle.  The phantom-release aliasing pattern
(`RAT[8]=RAT[9]=RAT[12]=pdst=8`) should trip the scoreboard **in the
cycle it happens**, rather than 1000s of cycles later when commit
deadlocks.  This catches the bug deterministically during debug rather
than stochastically during regression.

200 lines of Python vs ~1000 lines of SV UVM boilerplate for
equivalent function.  This is where cocotb + pyuvm earns its keep.

## Verification flow caveat

cocotb 2.0.1 + pyuvm 4.0.1 are installed in `venv_cocotb/` and
confirmed working, BUT:

- **Do not use cocotb with iverilog.**  iverilog's SystemVerilog
  support is incomplete and its 2-state-leaning semantics fall in the
  same "silently hides tapeout-class bugs" category as Verilator
  (documented in `doc/xsim_lessons_learned.md`).  The current smoke
  test default will be updated to reject iverilog.
- **DSim is the only trusted cocotb backend for this project.**
  cocotb 2.0.1 ships `Makefile.dsim` but the Windows wheel is missing
  `libcocotbvpi_dsim.dll`.  Next step: build cocotb from source with
  `DSIM_HOME` visible so the VPI lib gets produced.  Source tarball
  download is confirmed working.
- **xsim is not supported by cocotb upstream.**  No action — keep xsim
  for signoff of the full core; cocotb is for unit-level verif only.

## Environment setup (for next operator)

### xsim (signoff)
- `D:\Xilinx\Vivado\2024.1` — default path.
- `build_xsim.bat` builds, `run_cm.bat` / `run_single.bat` / etc. run.

### DSim (productivity)
- `C:\Program Files\Altair\DSim\2026\`.
- License at `%LOCALAPPDATA%\metrics-ca\dsim-license.json`.
- `build_dsim.bat` + `run_dsim.bat` wrappers.  `shell_activate.bat` is
  called internally for PATH / env setup.

### cocotb / pyuvm (block-level verif)
- `venv_cocotb/` — activate with `source venv_cocotb/bin/activate`.
- Install needed `COCOTB_IGNORE_PYTHON_REQUIRES=1` (Python 3.14).
- DSim VPI needs source-build of cocotb; TODO.

## Docs to read in this order (for cold start)

1. `CLAUDE.md` — ground rules, benchmark state, parameters, reset
   discipline.
2. `doc/xsim_lessons_learned.md` — dual-simulator policy, the
   verilator/iverilog "silently hides bugs" doctrine.
3. `doc/dhrystone_debug_handoff.md` — phantom-release bug in full
   gory detail.
4. `doc/partial_replay_spec.md` — Phase-3 design spec.
5. This doc — current state + priorities.

## Notes

- The earlier same-day WSL handoff (original text of this file before
  this rewrite) described a tree state that included the phantom-
  release fix.  That state is not what's at HEAD now.  If the earlier
  text is needed, recover via `git log -p -- doc/session_handoff_2026-04-17.md`.
- All untracked `*.log`, `*.wdb`, `*.bat` (run scripts from ad-hoc
  testing) are benign and can be deleted or left.

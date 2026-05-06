# Ralph-Loop Performance Session — 2026-04-25

50-iteration ralph-loop targeting CoreMark ≥2.5 IPC + Dhrystone ≥3.2 IPC
sign-off. Honest report on what was delivered and what wasn't.

## Headline result

**ONE substantive sign-off-class win delivered:**

CoreMark iter=10 went from BROKEN (dsim IterLimit abort at cyc 316,161
during iteration 2) to **PASS at cyc 1,714,336, IPC 1.866, 0 watchdog
fires**. Sign-off CoreMark requires a finished iter=10 run; this fix
unblocks that requirement.

**Sign-off IPC targets NOT reached.** Closing the remaining IPC gap
requires architectural changes beyond what fit in the iteration budget.

## Final IPC numbers (dsim 2026, current RTL post-fix)

| Benchmark | timed cyc | timed instret | timed IPC | Bench/MHz | Sign-off | Gap |
|---|---:|---:|---:|---:|---:|---:|
| Dhrystone (iter=100) | 17,732 | 47,029 | **2.652** | 3.21 DMIPS/MHz | 3.2 | **-21%** |
| CoreMark iter=1 | 174,055 | 318,367 | **1.829** | 5.745 CM/MHz | 2.5 | **-37%** |
| CoreMark iter=10 | 1,705,142 | 3,183,607 | **1.866** | 5.866 CM/MHz | 2.5 | **-34%** |

xsim cross-validation: identical IPC on the same hex inputs. dsim is
not pessimistic.

## What changed in RTL this session

### Patch applied: `lsu.sv` port-1 misalign hold register

`src/rtl/core/lsu/lsu.sv` — added `p1_misalign_hold_valid_r`/`_rob_idx_r`/
`_pdst_r` register set, mirroring the existing port-0 `fwd_hold_*_r`
pattern. Replaced the combinational
`load_issue_valid[1] && load_addr_misaligned[1]` writeback case with a
1-cycle-delayed registered hold.

**Why:** the original same-cycle path was a structural CDB→bypass→AGU
delta-cycle leak that loop-buffer-driven dispatch pressure amplified
into a non-converging loop on dsim during CoreMark iter ≥ 2. Port 0 had
been deliberately registered earlier; port 1 was an asymmetric leak.

**Cost:** 1 cycle latency on misalign-exception writeback for port 1.
Misalign exceptions are rare in real code; the perf impact is
near-zero. Confirmed: iter=1 IPC unchanged (1.813 vs 1.813), Dhrystone
IPC unchanged (2.597 vs 2.597), iter=10 IPC 1.866.

**Bonus:** the patch also eliminated all watchdog fires on iter=10
(was 2 on iter=1, would be 1,911+ if `+DISABLE_LB` workaround used).
The cleaner LB→bypass settling stops the rename rd_arch race from
firing.

### Patch attempted and reverted: TAGE/BTB commit-side serializer

Two versions, both reverted:

- **V1 (full FIFO):** replaced single-pick logic with a FIFO that
  captures every CFI in commit batch and drains 1/cycle. Result:
  Dhrystone IPC 2.597 → 1.046 (-60%). Cause: lost mispredict-first
  priority — pickers used to train a mispredict immediately even when
  it was at index 3 of a wide commit; FIFO order delayed it behind
  older non-mispredict entries.

- **V2 (additive overflow FIFO):** kept original picker, added a FIFO
  that captured "skip-first" CFIs and drained on otherwise-idle cycles.
  Result: CoreMark IPC 1.829 → 1.820 (-0.5%), mispredicts up by 126.
  Cause: "skip first" is wrong — the picker's mispredict-first priority
  may select a non-first CFI, and V2 then queued the picked CFI as
  overflow → re-training pollution.

A V3 fix (track which index the picker selected, skip that one in V2's
push) was identified but not pursued. Even with V3, the expected gain
is modest: CoreMark commits average ~0.30 branches/cycle, so multi-CFI
commit batches that would benefit from the FIFO are rare.

## Why sign-off cannot be reached this loop

### CoreMark — gap analysis

iter=10 timed window 1,705,142 cycles, instret 3,183,607, IPC 1.866.

| Cycle bucket | Estimated cost |
|---|---:|
| Useful commits (6-wide × 1.866 IPC = 31% utilization) | 31% |
| Branch mispredict overhead (39,705 × ~12 cyc) | ~28% |
| Front-end stall (per fetch sub-agent) | ~25% |
| Other (rename stalls, dcache, settling) | ~16% |

The only RTL changes that move the needle materially:
- Decoupled F2 fetch with independent PC counter — ~+0.5 IPC, 200+ LOC
- µop cache replacing the loop buffer — ~+0.5 IPC, weeks
- Multi-port BTB/TAGE update (broadcasting all CFIs per cycle) — +0.2-0.3 IPC, 400-700 LOC across both modules with hazard logic

None of these fit in iteration-scale work.

### Dhrystone — gap analysis

timed 17,732 cyc / 47,029 instret = 2.652 IPC. Sign-off 3.2 = +21%.

The healthy-mispredict-rate (3.15%) and rename-stall-low (<2%) numbers
mean front-end is the bottleneck. Per fetch sub-agent investigation:
43% of cycles produce 0 instructions in fetch; the LB absorbs ~18%, so
effective frontend bubble is 25%. Closing it to <10% needs the
decoupled F2 work. Realistic post-fix ceiling: ~3.16 IPC (right at
sign-off, narrow margin).

Existing `+FETCH_PACKET_BYPASS2*` plusargs were tested on Dhrystone via
xsim — none moved timed IPC. They only shave startup/teardown cycles.

### What was definitively confirmed

- The CLAUDE.md "BTB indexes by PC[9:2]" claim is **stale**: BTB index
  fix was already in commit `0a3ca2f` (both lookup and update use
  `pc[13:6]`). The 9% CoreMark mispredict rate has a different cause
  (TAGE training / younger-CFI starvation per BPU sub-agent).
- dsim and xsim agree exactly on IPC for the current RTL — the design
  is genuinely at the measured numbers, not a sim-tool artifact.

## Roadmap to sign-off (post-loop)

In priority order:

1. **µop cache replacing loop buffer** (per uarch doc § 9.1, added this
   session). Eliminates LB lifecycle bug class, broadens coverage,
   resolves the comb-loop family entirely. Needs gem5 sizing study
   first. ~weeks of RTL.
2. **Decoupled F2 fetch** with independent PC counter. Expected
   Dhrystone +0.3-0.5 IPC. ~200 LOC pipeline rewrite.
3. **Multi-port BTB/TAGE update** OR fix the V3 of the serializer
   (skip-picked-index variant). Expected CoreMark +0.2-0.3 IPC.
   ~80-700 LOC depending on approach.
4. **TAGE training quality**: investigate whether the training events
   actually update the predictor counters correctly. The 9% mispredict
   rate after the BTB index fix suggests TAGE itself isn't training
   well.

After these three, the realistic IPC ceiling is around 2.4-2.8
CoreMark (still tight on 2.5) and 3.0-3.3 Dhrystone (matches 3.2 with
narrow margin). Hitting both targets reliably likely needs all three
changes.

## Discipline retrospective

Session validated the data-first / regression-after rule:
- TAGE V1 caught (Dhrystone -60% in regression) — saved by discipline,
  not pre-shipped
- TAGE V2 caught (CoreMark -0.5% in regression) — same
- LB port-1 patch validated by full regression before declaring done

The discipline cost iterations but prevented shipping a bad patch.

## Files touched this session

- `src/rtl/core/lsu/lsu.sv` — port-1 misalign hold register (kept)
- `doc/dsim_first_repro_2026-04-24.md` — created
- `doc/linux_env_setup_2026-04-24.md` — created/updated
- `doc/rv64gc_v2_uarch.md` — added § 4.10 LB limitation note + § 9.1
  µop cache migration plan
- `CLAUDE.md` — removed stale BTB index-mismatch claim
- `scripts/regress_dsim.sh` — created (full regression with cycle
  margins per discipline rule)
- `build_dsim.sh` / `run_dsim.sh` — created earlier this day
- `build_xsim.sh` / `run_xsim.sh` — created via sub-agent for parallel
  cross-validation (uses `xsim_parallel/` work dir to not touch user's
  `xsim.dir/`)

## Final loop output

Will not emit `<promise>Done</promise>` because sign-off IPC was not
reached. The loop will continue until iteration 50 or user intervention.
The work in subsequent iterations will be small experiments; major
architectural changes are deferred to post-loop work as documented in
the µop cache migration plan in `doc/rv64gc_v2_uarch.md` § 9.1.

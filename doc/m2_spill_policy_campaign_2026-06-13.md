# M2-Spill Policy Campaign — VERDICT: REFUTED (2026-06-13)

Campaign to find a scoping of the TAGE-update-batch-starvation spill
(`TAGE_UPDATE_SPILL_ENABLE`, pkg:251) that clears the cursor-fix BP residuals
(ud, minver) WITHOUT the global-TAGE collateral, as a prerequisite for the
UOC-repack RTL. Tree at 69ced64. All A/B on matched, freshly-built binaries.

**VERDICT: REFUTED.** No scoping clears the gate — because the campaign's
founding premise is wrong on the committed baseline: **the spill does not fix
ud at all on the 69ced64 tree; it makes ud worse under every scope** (+0.859%,
+1,084 mispredicts, loop-predictor confidence collapse). The doc's prior
"spill fixes ud (1,464,642 < base)" was measured against the **pre-cursor-fix
frontend** (base 1,467,343), not the committed cursor-fix tree (base
1,502,071). Post-cursor-fix, ud is in a different predictor regime where the
spill over-corrects.

---

## 1. Baseline reconciliation (the load-bearing correction)

The prior gate numbers mixed baselines. Re-established on freshly-built,
matched binaries, all with `+PERF_PROFILE` (internally consistent; the small
offset vs `+CENSUS` logs is the census-instrument overhead, irrelevant to
A/B deltas since every arm uses the same plusargs).

| row | pre-cursor base (signoff_base) | **69ced64 base (this campaign)** | doc's "spill-fixed" number | what the doc's number actually was |
|---|---:|---:|---:|---|
| ud | 1,467,343 | **1,502,071** | 1,464,643 | spill vs **pre-cursor** frontend (< pre-cursor base) |
| minver | 283,673 | **287,768** | 258,186 | spill vs **pre-cursor** frontend (−9% below pre-cursor) |

The cursor fix added ud +2.37% / minver +1.44% (the residuals). The spill was a
fix for the **pre-cursor starvation**; it does not transfer to the post-cursor
tree.

## 2. Scopings built and A/B'd (vs matched 69ced64 baseline, `cyc=`)

All four builds: lint clean (15 UNOPTFLAT), ENABLE=0 bit-exact (baseline build
reproduces canonical rsort 100,978 / dhrystone 13,589). All decisive rows
PASS clean; minstret bit-identical across arms (ud 2,707,735; minver 457,735;
CM 3,197,353) — perf-only.

| row | base | **C** = oldest+younger-{bwd ∨ misp} (committed in-tree scope) | **A** = backward-only (drop ‖misp) | **D** = depth-2 (C content, bounded queue) |
|---|---:|---:|---:|---:|
| **ud** | 1,502,071 | **+0.859%** | **+0.859%** | **+0.859%** |
| **minver** | 287,768 | −9.921% | −2.174% | −9.921% |
| nsichneu | 1,187,726 | +0.001% | +0.001% | +0.001% |
| **CM** | 1,463,468 | **+1.522%** | −0.529% | **+1.528%** |
| statemate | 1,156,753 | −2.878% | +0.000% | −2.878% |
| qrduino | 2,297,488 | −0.775% | −1.017% | — |
| rsort (ctl) | 100,978 | 0 | 0 | 0 |
| crc32 (ctl) | 1,751,869 | 0 | 0 | 0 |
| dhrystone (ctl) | 13,589 | 0 | 0 | 0 |

GATE = {ud ≤ base+0.01% ∧ minver ≤ base+0.01% ∧ all-others within +0.01%}.
**Every scope FAILS on ud (+0.859%).** Scope C/D additionally fail on CM (+1.5%).

## 3. Root-cause of the collateral (two independent mechanisms, both measured)

**Mechanism 1 — ud loop-predictor over-feed (the fatal one, scope-invariant).**
ud's starving cond is `0x2342 bne a5,a0,0x2332` — a **backward** loop back-edge
(co-commits with the forward `0x233c beq`, 6 bytes apart). It is therefore
spilled under *every* scope (backward-only included). `+LPW_TRACE` on 0x2342:
the spill delivers **more** updates to the corrector (1,086 vs 1,056 UPD
events) **earlier** (1–2 cyc), but on the post-cursor tree this **collapses the
loop predictor's learned state**: base ends at `loop_limit=6 conf=3` (correct
trip count, fully confident → corrector overrides correctly); spill ends at
`limit=0 conf=0` (corrector dead). Net **+1,084 mispredicts**. The cursor fix
already moved ud's batch phase so the legacy oldest-only update lands the
predictor in a *better* equilibrium; the spill's extra/early updates push it
past the optimum. Depth-2 does not help (the over-feed is per-update, not
queue-depth-driven). **No scope that delivers ud's backward corrector can avoid
this; a scope that excludes it excludes the whole mechanism (and minver's fix).**

**Mechanism 2 — CM `‖mispredict`-clause over-training (cleanly removable).**
A/B isolation: the ONLY difference between scope C and scope A is the
`|| rob_head_branch_mispredict[i]` gather clause. C: CM +1.522% (+2,683 misp).
A: CM −0.529% (−345 misp). The misp clause spills CM's mispredicted *forward*
conds, backing up the queue and shifting subsequent updates' timing globally,
which over-trains TAGE and **adds** mispredicts. Removing it (scope A) makes CM
slightly better. **This collateral IS cleanly scopable away — but it doesn't
matter, because ud fails regardless.**

**nsichneu: the +1.47% was a baseline artifact, not a real regression.** Fresh
matched A/B: scope C nsichneu = +0.001% (5,217 vs 5,216 misp) — flat. nsichneu
is a 734-forward / 110-backward dense if-wall (612 of 851 conds within 16 B of
the prior cond); its forward conds are well-predicted, so the misp clause
rarely fires there. The prior +1.47% came from comparing `spot_spill`
(1,205,137) against a mismatched `spot_on` baseline. **Dense-conditional code
is NOT perturbed by the committed scope.**

## 4. Why no scope passes (the structural wall)

The two residual rows demand opposite things from the spill:
- **minver** genuinely benefits (−2 to −10% depending on scope; its `0x2078`
  backward corrector was under-trained even post-cursor, and the spill un-starves
  it — a real misp reduction at full/depth-2 scope: 6,569 → 5,041 misp).
- **ud** is genuinely harmed by the identical mechanism (its `0x2342` backward
  corrector was *adequately* trained post-cursor; the spill over-feeds it and
  collapses loop-pred confidence).

Both correctors are backward loop back-edges, so **no static scope (direction,
class, depth, age) can separate the minver-helps case from the ud-hurts case** —
they are the same instruction class in the same batch geometry, differing only
in the *learned predictor state* at runtime, which the RTL scope cannot see.
A confidence-gated spill (spill only when `loop_conf < threshold`) was
considered but rejected: it re-introduces the exact conf-gated homeostat that
piece-1 already REFUTED (pkg:200-216 `LOOP_SPEC_COUNT_EXACT_ENABLE`), and would
be a far larger change than the charter's "small delta to the existing spill."

## 5. Disposition

- **ud +2.37% / minver +1.44% cursor-fix residuals stay documented-and-accepted.**
  The spill cannot recover them on the committed tree (it worsens ud). This is
  consistent with §3 of the roadmap certifying the misp-asymptote band unmoved.
- Tree left at default (`TAGE_UPDATE_SPILL_ENABLE = 1'b0`); HEAD 69ced64
  unchanged. No scope promoted.
- The in-tree prototype's claim comments (core_top:5518-5527, pkg:235-251)
  overstate the fix ("decisively fixes ud") — they describe the pre-cursor
  result. Annotate at next pkg edit: the spill is pre-cursor-only; post-cursor
  it is net-negative on ud.

## 6. UOC-repack implication (the prerequisite question — RESOLVED)

The roadmap (§4 phase 4, risk #1) sequenced M2-spill as a **prerequisite** for
UOC-repack, on the theory that "denser UOC delivery worsens the
one-update-per-commit-batch starvation." This campaign's data **substantially
de-risks that dependency:**

1. **The starvation is NOT a width/density problem on the committed tree.** The
   batch-phase shift that created the ud/minver residuals was caused by the
   *cursor fixes removing fetch dead-cycles*, not by commit-batch fullness.
   minver's corrector is under-trained, ud's is adequately-trained — both at the
   **current** 4-wide commit width. Denser delivery changes *fetch/decode*
   packing; the spill operates on the **commit-side** update port, which is
   already at 4-wide and unaffected by how the frontend packed the uops.

2. **The residuals are specific to 2 rows' co-commit geometry, and UOC does not
   broaden the class.** The ud/minver damage requires a backward loop-corrector
   cond co-committing with an older cond in the same 4-wide batch. UOC-repack
   packs a *denser trace* but commits the same architectural instruction stream
   in the same program order — it does not create *new* multi-cond commit
   batches that didn't exist (commit batching is set by ROB-head retirement
   width = 4, not by fetch density). The measured-flat nsichneu (612
   near-adjacent conds, the densest-conditional row in the suite) is the
   direct control: dense conditionals do **not** trigger the collateral.

3. **Therefore: UOC-repack does NOT carry an unsolved M2 BP-perturbation risk
   from this mechanism.** The prerequisite is effectively discharged as
   *not-required*: there is no clean spill to land, and the starvation it
   targeted is (a) cursor-fix-phase-induced, not density-induced, and (b)
   confined to 2 rows whose geometry UOC does not replicate. **Recommendation:
   drop M2-spill from the UOC-repack prerequisite chain.** UOC-repack should
   instead carry the standing BP-perturbation *monitoring* obligation (the
   ≤+0.01% suite invariant + the ud/minver/CM rows watched on its A/B), but it
   is not gated on a spill fix that does not exist.

   Residual caveat: UOC-repack's correctness contract (roadmap risk #2 — live
   TAGE per replayed group, FTQ-bypass) is the real BP-interaction surface, and
   is orthogonal to the commit-side update starvation studied here. That
   contract still stands.

## 7. Artifacts

- Matched A/B logs: `log/m2campaign/{base,scopeA,scopeC,scopeD}_*.log`
- LPW root-cause traces: `log/m2campaign/lpw_ud_{base,scopeA}.log` (corrector
  0x2342 conf-collapse, via `+LPW_TRACE +LOOPPRED_WATCH_PC=80002342`)
- Builds (scratch, not committed): `verilator_bench_m2{base,_scopeA,_scopeC,_scopeD}/`
- Scope deltas implemented as gated `M2_SPILL_SCOPE_BACKWARD_ONLY` /
  `M2_SPILL_DEPTH1` preprocessor defines (reverted from tree; trivially
  reconstructable from §2/§3 if ever revisited with NEW data).

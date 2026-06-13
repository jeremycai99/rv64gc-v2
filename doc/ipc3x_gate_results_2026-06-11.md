# 3.x Gate Results (2026-06-11)

Execution of the §4 measurement gates from `doc/ipc3x_structural_study_2026-06-10.md`.
**Provenance:** all runs on the uncommitted tree at `bcba1a6` + sim-only TB instruments
(`+CENSUS`/`+L2PROBE`, uncommitted in `src/tb/tb_xsim.sv`). Binaries:
`verilator_bench_census` (default params, L2 hit 8 cyc) and `verilator_bench_l2lat2`
(`L2_HIT_LATENCY` 8→2, verified `hit_pipe` depth 2 in generated model). Every cited run
terminates at tohost PASS unless marked; logs in `log/zicond_ab/`, `log/p1_proxy/`,
`log/census_runs/`. Analyses: workflow `wf_5f9d8f00` (census-verdict + zicond-disasm
agents, adversarially cross-checked against §1 attributions).

**Headline (final, after the same-day §4.2a/b direct readout in §3.1): every funded
gate resolved, and every §4-gated mechanism is dead as proposed. P1 refuted for the
integer roster; Zicond refuted as stated; G0 (deeper runahead / fetch-through-taken)
NO-GO — the census b̄-proxy overstated taken-edge bubbles 6–9×, and full bubble
elimination buys ≤0.02–0.09 IPC on the funded targets. The depth-1→2 probe is
unfunded. What survives is a re-scoped supply problem: the starvation mass is
same-line dup-suppression holds (~11% of cycles on rsort/statemate/sha) plus
packet-truncation fragmentation — emit-repacking-shaped (G1′ territory or a cheaper
packet-buffer re-entry fix), newly scoped in §4, gated on RTL root-cause.**

---

## 1. P1 multi-outstanding-fill proxy (§4.5A) — REFUTED for the integer roster

`L2_HIT_LATENCY` 8→2 is a *strict superset* of P1's possible benefit (−6 cyc latency
**and** 2.5× fill throughput vs. multi-outstanding's throughput-only gain):

| workload | base cyc | lat2 cyc | Δcyc | IPC base→lat2 | §4.5 gate | verdict |
|---|---|---|---|---|---|---|
| rvb-rsort | 113,272 | 113,252 | −0.02% | 2.800→2.800 | ≥ ~2.9 | **REFUTED** |
| rvb-memcpy | 10,679 | 10,679 | 0 (bit-identical) | 2.607→2.607 | ≥ ~2.75 | **REFUTED** |
| embench-wikisort | 895,584 | 895,557 | −0.003% | 2.312→2.312 | — | no exposure |
| embench-tarfind | 484,310 | 484,288 | −0.005% | 2.081→2.081 | — | no exposure |
| rvb-spmv | 41,965 | 41,309 | −1.56% | 1.481→1.505 | — | marginal |
| **stream-l2** | **8,152,716** | **6,596,059** | **−19.1%** | **2.322→2.871** | — | **exposed** |
| zip-kernel-direct | 60M cap | 60M cap | +1.06% instret @equal-cyc | 2.351→2.376 | — | not a beneficiary |

- The integer-streaming premise is dead: rsort/memcpy don't move *at all* under a 6-cycle
  fill cut — there is **zero exposed fill latency** in these kernels, not "unmeasured"
  exposure. The §1 "Integer streaming → REACHABLE via P1" row is closed REFUTED.
- **stream-l2 −19.1% is the surprise.** It invalidates the stream-l1 control inference
  ("stream-l1 runs no faster ⇒ fills near-IPC-neutral") — stream-l2 under lat2 (2.87)
  far exceeds stream-l1 (2.25), so the FP-cadence cap claimed at ~2.3–2.4 was wrong and
  fills are a first-order term for spilling FP streams. P1's one real beneficiary.
- **Disposition:** P1 closes as a 3.x-roster lever (one-workload lever, same class as the
  128KB-L1D/parser HOLD). Ownership transfers to the queued FP campaign, where it
  compounds with the cadence fix; ceiling for stream-l2 ≥ 2.87.

## 2. Zicond toolchain bump (§4.3) — REFUTED as stated; czero ≈ noise except mont64

Three-arm design (the third arm became mandatory mid-experiment, see Controls):
GCC 13.4 suite baseline / clang-18 **without** `_zicond` (`-clangnoz`) / clang-18 with
`_zicond` (`-zc`). Same crt0/trap-catcher/link.ld/newlib in all arms (verified
byte-identical `_start` modulo bss bounds); only benchmark-TU codegen differs.

| workload | arm | cycles | instret | bpu misp | IPC |
|---|---|---|---|---|---|
| rvb-multiply | gcc | 46,711 | 49,061 | 1,133 | 1.050 |
| | clangnoz | 20,491 | 54,489 | 20 | 2.659 |
| | zc | 20,292 | 48,089 | 20 | 2.370 |
| embench-aha-mont64 | gcc | 1,459,813 | 2,143,590 | 77,103 | 1.468 |
| | clangnoz | 1,607,852 | 2,854,526 | 13,495 | 1.775 |
| | zc | 1,427,291 | 2,671,469 | 6,436 | 1.872 |
| rvb-median | gcc | 7,988 | 10,490 | 498 | 1.313 |
| | clangnoz = zc | 10,789 | 10,942 | 764 | 1.014 |
| rvb-qsort (ctrl) | gcc | 166,080 | 225,655 | 11,059 | 1.359 |
| | clangnoz = zc | 174,769 | 264,939 | 11,204 | 1.516 |
| embench-nsichneu (ctrl) | gcc | 1,296,205 | 2,245,818 | 5,215 | 1.733 |
| | clangnoz ≈ zc | 960,382 | 2,010,291 | 11,349 | 2.093 |

**Gates (study §4.3):** multiply PASS (2.37 ≥ 1.25) · mont64 FAIL (1.87 < 2.0) ·
median FAIL (1.01 < 2.0, **+35% cycle regression**) · misp-drop sub-gates PASS beyond
prediction (mont64 −92%, multiply −98%) · **controls VIOLATED** (qsort +5.2%,
nsichneu −25.9% cycles).

**Attribution (zc vs clangnoz, czero-specific):**
- multiply **−1.0%** cycles (czero condenses the branchless idiom, −11.7% instret, same
  speed — the carried chains bind; the extra instructions were free width).
- mont64 **−11.2%** cycles (real: 6 inlined `czero.nez` modul64 hammock conversions,
  misp 13,495→6,436) — but vs. the GCC baseline the *honest* net is only **−2.2%**,
  because branchless conversion costs +24.6% instret and lengthens the loop-carried
  x-chain 3→6 ops. The study's "select adds to the carried chain" derate is
  quantitatively confirmed.
- median/qsort/nsichneu: **zero** (bit-identical or ≈identical arms).

**Why the headline numbers are not Zicond:** the −56.6% on multiply and −25.9% on
nsichneu are clang-18 codegen (branchless restructuring without czero; 24%-smaller
nsichneu kernel). The controls breaching ±2% establishes the compiler confound; any
future toolchain lever must use the three-arm design. Single-pair "Zicond A/B" results
are inadmissible.

**Premise errors found by disasm (corrections to the study):**
1. **median (§1, §4.3): factually wrong premise.** GCC 13.4 *already* emits zbb
   `max` ×2 at the hot site; "only codegen is missing" was false, and clang-18 emitted a
   *branchier* diamond (0 czero, 0 min/max, 2→2.5 data-dep branches/iter). The
   1.31→2.3–2.8 projection is dead on this pairing.
2. **multiply attribution (Study II + §1): REFUTED.** Branch-free multiply runs **2.37
   IPC through the unchanged frontend** — the 36.5% rename-zero was mispredict-redirect
   fetch bubbles, not a steady-state fetch ceiling. The "multiply ≤ ~1.30 then
   fetch-after-taken-bound" row is voided. (Generalizes: rename-zero alone cannot
   attribute fetch-bound; see census instrument blind spot, §3.)
3. mont64's *named* site (xbinGCD parity diamond) was NOT converted by clang; the win
   came from the unnamed modul64 division hammock (~86% of its data-dep branches).

**Side-finding — the real software lever:** per-workload codegen variance between two
production compilers is **±30–50% in cycles** (multiply −57%, nsichneu −26%, median
+35%, mont64-noz +10%, qsort +5%), dwarfing every RTL lever measured in five gap-closure
cycles. This extends Tier-0b (binary normalization) beyond string idioms and binds any
cross-core comparison claim to a pinned-compiler methodology. It is *not* a suite
migration recommendation (sign-mixed).

**Effective-P:** not cleanly extractable — both informative pairs are confounded by
instret/chain deltas (mont64 same-compiler pair gives ~8–13 cyc/misp after
width-amortized instret correction). Calibration deferred to the #6 would-have-fired
counter (§4.4).

**Disposition:** Zicond-as-stated closes REFUTED (median dead, mont64 honest −2.2%,
multiply's win is compiler-generic). czero remains a correct-and-cheap ISA feature the
core already executes at 1 cyc; it is folded into the Tier-0b software-normalization
umbrella, not a standalone lever.

## 3. P0 supply census (§4.1/4.2) — CONDITIONAL-GO for G0

14-workload `+CENSUS` sweep (commit-width + ROB-occupancy histograms + starved-with-
headroom cross-tab) + frontend_hist supply computation. Full table in the workflow
result (`wf_5f9d8f00`); decisives:

- **The chain-saturation refutation branch never fires.** rob_full ≤ 1.16% (suite max,
  CM); ROB median occupancy < 32/128 *everywhere*; backend_stall ≤ 4.4%. The window is
  starved, never saturated — L≈12 and "more packets in flight, not more capacity"
  confirmed suite-wide.
- **Step-1 kill rule** (supply ≥ IPC+0.5) kills spmv (+1.50), md5sum (+0.57), tarfind
  (+0.51 fusion-corrected uop domain). **memcpy independently drops out of the G0
  roster** (starved-with-headroom 0.48%, suite minimum; it was P1's — and P1 died, so
  memcpy exits the 3.x roster entirely).
- **Fund condition holds on exactly the predicted supply-side targets:**
  rsort (supply−IPC +0.08, starved 19.2%, b̄-proxy 1.61 cyc/taken, misp≈0),
  statemate (uop-domain +0.04, 20.3%, 2.82), DS (+0.24, 11.7%, 0.50), plus sha already
  at the ceiling. §4.2 GO bar passes on every criterion *that exists in the logs*.
- **CONDITIONAL because:** (a) the §4.2a taken-branch bubble histogram and §4.2b
  per-term runahead disqualifier census do not exist yet (b̄ is a fe0/taken proxy, clean
  only where misp≈0 — true on all three funded targets); (b) DS-ww (the binary the 3.14
  target requires) sits at 7.9% starved, marginally under the 10% bar; (c) today's
  depth-1 runahead covers only 11–31% of taken edges on the targets — headroom real,
  disqualifier mix unmeasured.
- **crc32 contradiction reconciled in the chain's favor** (and the instrument blind spot
  documented): its 18.2% "starvation" is lock-step slack under the 9–11-cyc carried
  chain (supply == uop-IPC at 1.91 exactly; fe0 = exactly 2 cyc/iter). Rename-zero-with-
  headroom cannot discriminate causal starvation from chain-hidden slack; adjudication
  needs the supply≈IPC identity + a chain specimen for any member with gap +0.1…+0.4
  (picojpeg, wikisort, matmult, CM).
- **Re-attributions:** nsichneu and matmult-int are fetch-fragmentation supply-bound
  (supply capped 1.81/2.06, B=12/8.4 — G0-liftable but from 1.7–1.9, not 3.x members);
  md5sum is misp-heavy despite suite-max starvation 30.6%; sglib's chain tag is in
  tension with ~49%-of-cycles misp cost (needs census before lever assignment).
- **Fusion is NOT dead suite-wide** (corrects the study's CM-only bookkeeping):
  statemate commits **31.4%** of instructions fused, crc32 17.4%, tarfind 14.4%.
  Mandatory in kill-rule arithmetic (it flipped tarfind) and in any G1′ §4.8 model.
- **G0-vs-G1′ sequencing:** bubbles are broad and shallow (G0-first per the Tier-4
  rule), but 50–62% of zero-supply cycles on tight-loop members are same-line
  dup-suppression holds — a loop-replayer-shaped component. G1′ stays gated on §4.8
  streak-length traces; nothing here funds it yet.

### 3.1 §4.2a/b direct readout (same day, later) — G0 resolves **NO-GO**

Counters landed sim-only in `src/rtl/sim/fetch_frontend_profiler.sv` (+182/−2, hierarchical
refs via the existing `bind fetch_top`; zero synthesizable RTL touched; lint 15 baseline;
new binary `verilator_bench_census2` **bit-exact** in cycle counts vs `census` on all 5
reruns — timing-neutral proven). Logs `log/census2_runs/`.

**§4.2a taken-branch bubble histogram** (redirect → next emit, covered/uncovered split):

| target | coverage | b̄ uncovered | b̄ all | bubble cyc as % of total | §4.2 bar (b̄≥0.4 ∧ starved≥10%) |
|---|---|---|---|---|---|
| rsort | 30.1% | 0.087 | 0.061 | 0.73% | **FAIL** (b̄ 6.6× under) |
| statemate | 8.5% | 0.047 | 0.043 | 0.52% | **FAIL** |
| DS | 3.5% | 0.043 | 0.042 | 1.68% | **FAIL** |
| DS-ww | 5.0% | 0.092 | 0.087 | 3.32% | **FAIL** (both arms) |
| crc32 (ctrl) | ~0% | 0.00002 | 0.00002 | 0.0005% | (control behaves as §4.1 predicted) |

Uncovered taken edges are **91–95% zero-bubble** — they resolve next-cycle without
runahead (same-line/recent-line F2 replay path). Marginal value of covering one more
edge ≈ 0.05–0.09 cyc. **Hard upper bound of the whole G0 mechanism (all edges covered,
b→0): rsort 2.800→2.821, statemate 2.652→2.666, DS 2.574→2.618, DS-ww 2.732→2.826** —
nowhere near the 2.9–3.2 / 3.05 / 3.14 targets. The §3 b̄-proxies (1.61/2.82/0.50) were
ren_zero/taken and attributed *all* rename-zero cycles to taken edges; in truth only
2.5–3.8% of starved cycles sit between a redirect and the next emit. **Depth-1→2 probe:
predicted yield ≈ 0 — do not fund. DS-ww 3.14 path: dead on direct evidence.** crc32
control: b̄≈0 with 18.2% "starved" — confirms the lock-step-slack reconciliation and the
ren_zero blind spot.

**§4.2b disqualifier census** (first-fail share of rejected runahead opportunities):
demand_alloc dominates (rsort 40%, statemate 69%, DS 79%, crc32 ~100%) with
not_delivered second (11–27%) — the blockers are **structural slot conflicts** (the
demand fetch owns the single F1 request port; work blocks transit F2 in ~1 cycle leaving
no idle slot), not the relaxable qualifiers (not_direct 0–3.3%, budget/pending ≈0).
Relaxing G0's qualifier list was never going to fire more runahead.

**Where the starvation mass actually is:** same-line dup-suppression holds — ~59% of
fe0 cycles on rsort (≈11% of all cycles), 55% statemate, 62% sha — plus packet
truncation/fragmentation at B≈22–23. Both are emit-repacking-shaped costs (a taken
back-edge into a still-live line, and B/⌈B/4⌉ packing loss), claimable by G1′'s replay
path or possibly by a much cheaper packet-buffer same-line re-entry fix. Neither was
claimed by the G0 gate; both are unsized in RTL terms — root-cause dispatched.

## 4. Updated roster arithmetic + funding decision

≥2.95 today: 6 (linalg 3.23, vvadd 3.19, edn 3.01, nettle-aes 3.01, nettle-sha256 2.98,
sha 2.95). Changes vs. the study's §1 roster claim ("up to 10"):

| candidate | study path | status after gates |
|---|---|---|
| rsort 2.80 | G0 → 2.9–3.2 | **DEAD via G0** (§3.1: bubble-elimination UB 2.821); re-scoped to dup-hold/repacking (UB ~3.1 if its ~11%-of-cycles hold is fully recoverable — unsized) |
| statemate 2.65 | G0 → 3.05 range-top | DEAD via G0 (UB 2.666); dup-hold share ≈11% of cycles — re-scoped same as rsort |
| DS 2.57/2.73ww | G0+ww+live-RAS → 3.14 | **DEAD on direct evidence** (UB 2.618/2.826 with ALL bubbles gone) |
| memcpy 2.61 | P1 → 2.9 | DEAD (P1 refuted; G0 non-beneficiary, starved 0.48%) |
| stream-l2 2.32 | (FP campaign) | ceiling raised: ≥2.87 demonstrated under lat2 proxy |

Realistic 3.x roster **as of these gates: stays at 6** (sha within noise). Every §4-gated
mechanism is dead as proposed. The only unresolved supply-side claim is the re-scoped
emit-repacking/dup-hold term (G1′-shaped or cheaper), which is **unsized** — no roster
addition is claimable until its RTL root-cause and recoverability are established.

### 4.1 Dup-hold root-cause readout (same day) — lever REAL, ~25 lines, G1′ not required

The hold is **not** taken-edge related (`dup with taken control` = 0 everywhere; the
docs' guess was wrong). It is two 1-cycle work-cursor artifacts at **cache-line
crossings** in straight-line code, which is why §4.2a's redirect-anchored histogram was
structurally blind to it. Two flavors partition the counter exactly (±2 events, 5/5
workloads):

- **Flavor A — straddle re-extraction:** a line-straddling 32-bit instr defeats every
  structured cursor-advance path; the catch-all fallback `work_pc_next = f1_pc_r`
  (`ifu.sv:612`) re-lands on the just-emitted PC → `ifu_duplicate_guard` vetoes the
  re-emit (1 dead cycle), then the straddle-advance + remainder-stitch proceed.
- **Flavor B — consumed-remainder echo:** the cycle after a remainder consume-emit, the
  `consumed_remainder_r` cursor-mux branch (`ifu.sv:605-606`) outranks same-owner
  advance and re-loads the PC being emitted that very cycle → 1 dead cycle (the
  day-late `work_same_owner_dup_advance_c` then does the identical advance). Proof:
  echo count ≡ consumed-remainder cycles exactly (statemate 89,943/89,943).

Ground truth reproduced: crc32 = 11.00 cyc/hold = exactly 1 hold/iter, all flavor A,
fe0 = 2×holds exactly; rsort = 3 holds/iter across two line crossings (8,205 echo +
4,122 straddle = 12,327 = 10.9% of all cycles). **Recoverability proven by the
profiler's strictest classifier:** during ≥97.7% of holds the line is live, the
successor is on the same live line, the ibuffer is empty, and nothing downstream
blocks (`xs post delivery dup ready`); fill latency is uninvolved (`f2 data wait` = 57
cyc total on rsort). The guard itself (e42589e provenance) is a double-enqueue backstop
for the f1 fallback, not a comb-loop breaker — it stays; the fixes stop the cursor from
*landing* on duplicates.

**Fix:** ~6–10 lines (echo: drop `!consumed_remainder_r` from same-owner advance +
mux priority, **with the mandatory F1 re-pin companion** at `ifu.sv:710-711` — without
it F1/cursor diverge and a fresh-owner double-enqueue becomes reachable that the guard
cannot catch) + ~10–15 lines (straddle: explicit advance-to-straddle-PC term ahead of
the fallback, 1 new port from `fetch_top`). No runahead/VIPT interaction (verified).

**Sizing (1:1 recovery = UB):** rsort 2.800→**3.14** (crosses 2.95 at 47% recovery —
the near-certain mint), sha 2.946→**3.31**, statemate 2.652→**2.99** (knife-edge, needs
~89%), DS 2.64 (stays dead), crc32 arithmetic-2.30 but **~0 real** (chain slack — and
the functional canary: 175k holds, any double-enqueue corrupts the checksum; the fix
must be cycle-neutral there). G1′'s incremental claim after this fix shrinks to
fragmentation + straddle-advance cycles — re-run §4.8 arithmetic only then.

### 4.2 Cursor fixes IMPLEMENTED + MEASURED (same day) — ship-candidate

Both fixes landed gated (`IFU_REMAINDER_ECHO_FIX_ENABLE` / `IFU_STRADDLE_ADVANCE_FIX_ENABLE`,
pkg:188/199, default 0), +52/+5/+20 lines in ifu.sv / fetch_top.sv / pkg, with the
mandatory F1 re-pin companion (textually identical guard — lockstep proven in-RTL, not
assumed). Gates: lint **15 at all four param points**; ENABLE=0 **bit-exact** (rsort/crc32/
DS/CM cycle- and counter-identical to census golden); 9/9 runnable functional smokes PASS
ON (two TIMEOUTs bit-identical on both arms = pre-existing bench-TB gaps); **minstret
bit-identical baseline↔ON on all 7 A/B workloads**; synth cone **measured, not just
argued** (yosys 0.33 `ltp` A/B at ifu scope, params 0 vs 1): longest topological path an
**exact tie in all three readouts** — 54/54 coarse, 69/69 gate-level, 23/23 on the carved
`work_r`+`f1_pc_r` cone — endpoints node-for-node identical pre-existing logic (the
runahead/FTQ-alloc chain, not the new terms); the new `work_straddle_emit_advance_c` arc
tops out at depth 9 vs the 23-level cone ceiling; +0.7% cells (wider, not deeper). Bonus
finding: ifu's own critical path (runahead-pending chain, 54/69 levels) is ~2.3× the
cursor cone — the fixes sit in timing slack. Artifacts `/tmp/yosys_f2_ab/`. Logs
`log/dupfix_runs/`, arms `verilator_bench_dupfix_{off,on}`.

| workload | Δcycles | IPC | hold recovery |
|---|---|---|---|
| rvb-rsort | **−10.85%** | 2.800→**3.141** | 99.7% (12,327→0) — §4.1 UB hit exactly |
| embench-statemate | **−10.79%** | 2.652→**2.973** | 95.4% — crosses 2.95 |
| embench-crc32 | **−9.09%** | 2.091→**2.300** | 99.99% — **unforecast beneficiary** |
| dhrystone / -ww | −1.50% / −2.03% | 2.574→2.614 / 2.732→2.789 | stays dead, as predicted |
| coremark (PASS at STOP) | −0.82% | 2.160→2.178 | 28% (residual flavor-A corners, guard-caught) |
| embench-wikisort | −1.41% | 2.312→2.345 | 44% |

No workload regressed; echo flavor = 0 everywhere ON. **crc32 adjudication:** the
"cycle-neutral" criterion (from §4.1's chain-slack model) failed in the favorable
direction — adjudicated **model error, not RTL bug** (bit-identical minstret suite-wide,
verified checksum, 1:1 hold↔cycle accounting; the carried chain is ~10 cyc, inside §3's
own 9–11 band, and the 11th cyc/iter *was* the hold — fetch, not the chain, was crc32's
binder at 11). §4.1's slack model stands for wikisort/CM (44%/28% recovery), falls for
crc32. Optional confirmatory readout: `tools/uoplife_critical_path.py` on crc32.

**Measured roster impact: 6 → 8** (rsort 3.14, statemate 2.97 in; sha expected to harden
from 2.95 toward its 3.31 UB — not yet re-measured ON).

**DSim sign-off (same night, params default-on): CLEAN.** Functional 17/17 PASS at STOP;
bench rows PASS at STOP with exact checksums (DS-100 13,501 cyc **−1.48%**, CM-iter10
1,444,630 **−1.61%** vs the Jun-09 pre-fix control, instret bit-identical — DSim win
slightly larger than the Verilator prediction); the strict signoff arm
(`+FETCH_OWNER/DELIVERY/BRANCH_RECOVERY_CHECK STRICT`) ran cycle-bit-identical with
**zero invariant violations** — the strongest available evidence class for a frontend
cursor change. **Compliance 113/113, all gate=PASS.** Linux boot relaunched detached
with `+WEDGE_DUMP` (OpenSBI banner up, early IPC ~2.78, ETA ~5.5–6 h to boot_ok — VIPT
sim-cost cut confirmed vs the legacy 19 h). Pre-existing harness notes (reproduced
bit-identically on the Jun-09 control, not attributable to the fixes): dhrystone hex sha
≠ manifest golden since the 05-29 ww rebuild (DMIPS not manifest-comparable; CM shas
match); `regress_dsim.sh` dies under `set -u` when `LD_LIBRARY_PATH` is unset
(worked around, unfixed). Remaining promotion gates: Verilator 63-run suite comparison +
boot_ok.

**Next steps, in order:**
1. ~~Implement the cursor fixes~~ — **done, ship-candidate** (§4.2); batched DSim
   sign-off is the remaining promotion gate.
2. **G1′ §4.8 offline replay model** (fusion-aware per §3) — only after (1) reads out;
   its claim is now the residual.
3. ~~Depth-1→2 runahead probe~~ — **unfunded** (§3.1: predicted yield ≈0).
4. P1, Zicond, G0: closed (dispositions above). L2-fill comb-request arm (`bcba1a6`,
   gated 0) promotion still deferred to the next batched sign-off; its stream-l2
   interaction (−2.38%) should be re-read against today's finding that stream-l2 has
   real fill-latency exposure.

## 4.3 Idea ledger from the parallel session — AUDITED (wf_09ca3ff9, 5 auditors +
synthesis, 2026-06-12; full results in the workflow output)

**Zero RTL fundable today** — 3 PARTIAL, 1 BLOCKED, 1 REFUTED; every live idea resolves
through counters or queued runs. Funding order: L2F promotion (batch2) → FP fund/kill
table → repacker batch-#4 counters → LMB burst histogram @L=80 → TLB (parked) →
MUL/DIV (closed).

1. **Decoded-op repacker — PARTIAL, as-specced ≈0 yield.** Truncation loss is real and
   disjoint from the cursor fixes (partial-width cycles 21.6% rsort / 23.9% statemate /
   45–50% DS/CM; honest fusion-corrected UBs rsort→3.49, statemate→3.44, DS-ww→3.64,
   DS→3.19, **CM→2.93 dead even at 100% conversion**; crc32 chain-capped ~+0). But
   **donor co-residency ≈ 0** (packet buffer empty 91–100% of cycles; flow-through
   delivery 82–94%) — a zero-latency emit-buffer has no second fragment to merge, and
   the steady-state identity (emit ≤ extract ≤ 4 instr/cyc from one line) makes real
   yield require dual-line extract / fetch-ahead, the territory §4.2b measured
   port-blocked (demand_alloc 40–79% first-fail). GATE before any RTL: ≤20-line
   batch-#4 counters (partial-emit cause split + donor-availability) — fund only if
   donor-in-flight covers >50% of partial emits on a UB-bar-crossing workload.
   Fusion lesson quantified: uop-domain arithmetic overstates statemate by +0.54 IPC —
   all supply arithmetic in the raw-fetch (instruction) domain from now on.
2. **Real FP cluster — PARTIAL, gates on the FP signoff rows.** All structural claims
   verified at HEAD (0.5/cyc suppress cap `rv64gc_core_top.sv:2409-2419`; FP→IQ2 with
   DIV/CSR `dispatch_queue.sv:219`; single select; CDB[3] shared; **fp_prf write
   port[3] exists and is tied off** — the WB half is nearly free). radix2 at the new
   default: 1.042 IPC, arb_loss 29.9%, fu_contention 21.3%, queueing UB →1.32–1.45
   (crosses no bar alone). **0eab856 reinterpreted:** the ENABLE=1 arm still suppressed
   every second cycle mechanically (fpu_out_valid comb term), so that rejection carries
   ZERO information about 1.0-cadence value; only the loops-partitioning harm stands.
   FUND/KILL: ≥2 FP members besides radix2 at fu_contention ≥15% AND a bar-crossing UB,
   from the in-flight signoff FP rows (zero sim cost).
3. **TLB/PTW — BLOCKED, correctly parked.** Geometry verified (ITLB 16/DTLB 32
   fully-assoc RR, single PTW, no L2-TLB, **no page-walk cache: every Sv48 walk
   restarts at satp root, ~36–44+ cyc serial**). `ptw_busy_cycles` root-caused:
   `mmu_mem_profiler.sv` walk_end misses flush-aborted walks (ptw.sv:269-277 →
   S_IDLE) — 4-line fix drafted. Boot UB ~2% of cycles; bare roster 0%. Next: land the
   counter fix, piggyback +PERF_PROFILE on the next boot, then pick the paged Tier-2
   vehicle. Kill bar: (ptw_busy + fe_stall_xlate) < ~3% on representative paged compute.
4. **MUL/DIV sideband — REFUTED, closed.** The idea's own gate was run (+TRACE_UOPLIFE
   on mont64, signoff binary): MUL+DIV = 0.49% of commits, sideband UB ≤0.75% of cycles
   — **20–27× under the 15–20% bar**; zero MUL PCs in the top-24 critical-path list
   (all modul64 shift-subtract ALU/branch); MUL effective latency 2 cyc, sideband saves
   1. edn supply-capped, MULs off-chain. matmult already retired. No revival gate.
5. **LMB/L2 fill polish — PARTIAL, owned by batch2 + the L=80 sweep.** Port-0-only
   drain verified (`lsu.sv:3760-3782`, port-1 mux has no LMB arm); blocked-cycle UB at
   L=1 only 2–5% on memcpy/stream-l2/zip/rsort/spmv, ~0 on CM/DS. New probe specced:
   drains-per-fill burst histogram (lsu.sv stat block), read at L=1 and L=80 inside the
   sweep. Comb-arm promotion = batch2; its stream-l2 NWA interaction must re-sign at
   L=80.

## 4.4 Full-suite re-baseline at the new default (41/41, 2026-06-12) — roster 8 CONFIRMED, strict invariant FAILS on 4

35/41 improve or flat (biggest: multiply −13.2%, statemate −10.8%, rsort −10.9%, nettle-sha256 −9.8%, crc32 −9.1%, md5sum −8.5%, nettle-aes −8.5%, nsichneu −8.4%, picojpeg −7.5%, cjpeg −6.7%); zero PASS→TIMEOUT flips; rsort sanity bit-exact.
**3.x roster at the new default = 8:** linalg 3.317@cap, **sha 3.311@cap (hits its §4.1 UB exactly)**, nettle-sha256 3.299, nettle-aes 3.288, vvadd 3.204, rsort 3.141, edn 3.104, statemate 2.973.
**STRICT ≤+0.01% INVARIANT: FAIL — 4 named violations**, all minstret-bit-identical (perf-only), all the same mechanism — dup-holds collapse as designed but **conditional mispredicts rise** (recovered fetch dead-cycles perturb BP training/speculation timing):
minver **+3.70%** (misp +9.0%), ud **+2.37%** (misp +24.4%), nnet +0.56% (misp +9.9%), matmult-int +0.46% (misp +12.9%). ud arithmetic closes: +12.3k misp × ~9.5 cyc ≈ +117k vs −73k holds recovered.
**Root-cause (same day): the legacy dead cycle was a PARASITIC BPU RE-LOOKUP** — the F1
fallback re-ran the primary lookup at the just-emitted PC and refreshed the F2 prediction
snapshot before the stitched packet emitted; the fixes remove it, so branches within one
packet of a line crossing validate against one-lookup-staler state, amplified by the
loop-predictor's conf-gated count-bypass homeostat (quantized exit-misp plateaus: nnet's
gainer at exactly 3/4 vs 1/2 of exits, straddle-free twin loop bit-unchanged). Artifact,
not fundamental — but no cheap fix (freshness restoration re-encounters the single-F1-port
conflict, §4.2b). Flavor attribution measured: minver/matmult 100% straddle; ud/nnet echo
(ud straddle-only is net-positive −1.8%, but forfeits statemate). minver sub-mechanism:
its worst PC commits via a fused path that never trains the predictor — deterministic,
persistent. Update-port contention REFUTED (updates ≡ committed conds in all arms).

**DECISION (user, 2026-06-12): FIX-THEN-PROMOTE.** Commit held.

**Piece 1 (loop-corrector hardening): FAILED 0/6 crisp criteria — homeostat theory
REFUTED as the dominant carrier.** Implemented correctly (LOOP_SPEC_COUNT_EXACT_ENABLE,
pkg:216, gated 0, in-tree; lint 15; OFF bit-exact — which also PROVED batch-#4 counter
timing-neutrality: rsort 100,977 / CM 1,468,116 exact). Evidence: matmult's victim is
bit-identical with the bypass ungated (lookups never in the ±1-cyc window — pure
F2-snapshot staleness); nnet's victim is bit-equal at exactly 75% even while piece 1
recovers 82% of its OTHER-PC misp (staleness > 1 cyc; variable trip count, limit updates
12.5% of exits); minver's loop-reachable misp fully recovered (total below base!) — its
whole residual is the fused-path 0x2078 term (~518 never-training commits; legacy
accuracy came from re-lookup freshness, NOT training → a fresh-at-source prediction
restores it). Partial cycle recovery: minver 66%, ud 52%, nnet 17%, matmult −5%;
collateral rsort +0.044%/qrduino +0.125%. RTL kept in-tree gated-off.
**Piece 2: PARTIAL — snapshot-staleness theory MEASURED-REFUTED at the victims; the two
real mechanisms found by first-divergence event tracing (`+SNAPWATCH`/`+LPW_TRACE`
probes, both reusable):**
- **M1 — loop-predictor commit-side spec-count clobber** (pre-existing race, BOTH arms):
  the committed-exit handler zeroed `loop_spec_count` unconditionally, destroying the
  next instance's in-flight speculative fires whenever the exit committed after them;
  the cursor fixes merely flipped the race phase. **FIXED + PROMOTED:**
  `LOOP_SPEC_COMMIT_NOCLOBBER_ENABLE=1` (2-line gate: clear only under flush).
  matmult → 1,445,375 and nnet → 52,083,533 — **both BELOW the params-0 baselines**;
  nnet's victim back to exactly 50.00% exit-misp.
- **M2 — one-TAGE-update-per-commit-batch starvation** (pre-existing): only the oldest
  cond per 4-wide commit batch trains; the cursor fixes shifted batch phase so ud/minver's
  co-committing conds starve (ud victim-visible updates 64,199→60,476 on an identical
  stream → loop corrector dead). The prior "fused-path-never-trains" attribution is
  REFUTED (mv+bne is not a fusion pattern; the missing updates are batch-starved).
  A spill-FIFO fix exists in-tree (TAGE_UPDATE_SPILL_ENABLE, default 0, ~120 gated
  lines): decisively fixes ud (1,464,642 < base) and minver (**258,186 = −9.0% BELOW
  base** — the starvation costs minver 9% even pre-cursor-fix!) but shifts global TAGE
  equilibria (nsichneu +1.47%, CM +0.15%; scope variants move the loss around) — the
  classic refuted-lever pattern; PARKED for its own policy campaign.
**Promoted-arm suite (42 rows vs better-of-both):** 7 wins (matmult −1.12%, radix2
−0.91%, CM −0.32%, nnet −0.24%, nettle-aes −0.17%, …), 33 flat (32 bit-identical),
**2 residuals: ud +2.37%, minver +1.44%** (geomean drag ≈ +0.09%), zero flips; spot set
bit-identical incl. rsort/statemate. Piece 1 combined arm: worse — stays 0. Ladder:
lint 15 at all params, OFF bit-exact (incl. fresh final-tree all-legacy build —
constant-folding equivalence of the gated-off prototype proven).

**Boot v1 TIMEOUT was a BUDGET ARTIFACT, not a wedge:** prior `final_boot_ok` PASS took
**~129M mcycles** (212.7M instret); v1's 50M cap was undersized.

**Boot v2 RESULT (170M cap, 2026-06-13): HEALTHY, INCOMPLETE-on-budget, ~10–11% boot
slowdown vs baseline — not a wedge, not a correctness issue.** At the cap: mcycle
127.7M / instret 212.7M, full normal kernel progression to driver-init (serial/radeon/
e1000e/usb/sdhci loaded, IPVS registered, no panic), clean `sim_returncode=0`. Reconcile:
v2 at mcycle 127.7M is at kernel-time 1.19s; baseline `final_boot_ok` reached BOOT OK
(kernel-time 1.39s) at mcycle 128.7M — i.e. **same instret/cycle execution rate, but v2
needs ~10–11% more cycles to reach the same milestone**, consistent with the BP-timing-
perturbation mechanism (§4.4's M1/M2) at boot scale; boot is timer/delay-loop-dominated
in this phase so the exact crossing is fuzzy (~143–150M est). NOT a commit blocker: the
functional gates already passed (compliance 113/113, DSim regress func 17/17 + CM/DS at
STOP + strict checkers zero-violations). boot_ok confirmation = one ~150M rerun on the
final committed tree; the ~10% boot cost is a recorded characteristic of the BP
perturbation, to be netted against the −3.5% suite geomean win. Verilator tb_linux
time-path fix remains the standing unlock for cheap boot iteration.

**Batch2 readouts (2026-06-12): L2F comb-arm promotion = HOLD** — at the new default
stream-l2 degrades **+11.2% cycles** (8,152,159→9,067,336; was −2.38% pre-cursor-fix — the
NWA validate→fill-upgrade conversion amplifies under faster fetch), parser +5.8% instret,
CM/DS/qsort/tarfind neutral (≤55 cyc). Re-sign at L=80 only. **Parser §4.6 l2fast gate:
PASS at +57.5% instret** (0.623→0.982 IPC at equal cycles on the lat-2 arm) — parser's
binder = L1D-miss service latency through the L2 hit pipe; phase-split flat
(parse-dominated window); ww binary +5.3%. Folds into the cache-sizing sweep (parser =
key member; the L1D 128K arm answers §4.6's last gate).
Also material: large flavor-A dup residuals concentrate in kernel-direct members (cjpeg 1.01M, zip 866k, parser 622k, loops 460k, linalg 337k) — G1′-residual ledger input. radix2's onboard 100M-livelock datapoint obsolete (PASSes both arms ~23M). Logs: `log/signoff_runs/` (ON), `log/signoff_base/` (fresh OFF), `compare.py`.

**Cross-cutting corrections (synthesis):** (a) stream-l2 is triple-claimed (FP cadence /
fill levers / P1-resurrection) — fill term −19.1% belongs to fill levers, cadence binds
only post-fill; no single lever may book stream-l2 ≥2.95, joint accounting required.
(b) crc32 chain-cap carries one prior model strike (the cursor-fix −9.09% vs predicted
neutral) — the uoplife chain-floor readout is the tiebreaker before closing crc32.
(c) radix2 1.042 (signoff, new default) supersedes both the invalid 2.49 and the
0.92–0.94 era numbers. (d) stale `MUL_LATENCY=3` (pkg:99) has no RTL consumer —
annotate at next pkg edit.

## 4.5 Idea batch 2 — gated (wf_0bc384cb, 2026-06-13, read-only on promoted-config logs)

1. **Decoded-op repacker: KILL, closed for good** (both conjuncts fail with full counter
   coverage). Donor-in-flight on the UB-bar-crossers: rsort 9.6%, statemate 1.2%, DS
   3.2%, DS-ww 0.0%, CM 1.9% — ≥5× under the 50% bar; **donor-unrequested 90–100%**
   (the would-be donor line was never even fetched at partial-emit time). High-donor
   members (nnet 71%, stream-l2 76%, st 84%) can't cross 2.95 at 100% conversion of ALL
   partial emits. L=80 donor hypothesis measured-refuted (shares invariant ±0.3pp; zip
   moves DOWN). Perfect zero-cost repacker yield: rsort +1.6%, DS +1.1%, rest ≤+0.2%.
   The real truncation loss (taken-edge 29–77% + line-complete-seq of partial-emit
   causes) belongs to fetch-ahead/dual-line extract — the §4.2b port-blocked program.
2. **FP cluster: FUND — the fund/kill rule passes decisively.** 8 of 12 non-radix2 FP
   rows clear the 15% filter: **nnet fu_contention 32.3% → UB 3.15–3.59 (a 3.x-roster
   crossing)**, loops 31.5% → UB 2.52–2.86 (crosses ≥2.0), stream-l2 31.4% → needs only
   6.9% of its fu-exposure disjoint from the fill term to clear 2.95 jointly; st 62.5%,
   nbody 44.8%, minver 33.8%, stream-l1 25.3%, cubic 21.7%. Next gate: a TRUE
   1.0-cadence A/B arm (fix the `fpu_out_valid` comb suppress so ENABLE=1 actually
   issues 1/cyc — 0eab856's arm never did) + bring up the tied-off fp_prf write port[3];
   round-robin dispatch kept (no static partition — the loops harm from 0eab856 stands).
3. **Rename skid/tail-merge: KILL by existing counters.** The exact population counter
   already exists (partial-advance = any_stall − full_stall, rename.sv:1134-1135):
   12/42 rows exactly 0, CM 0.024%, best embench 0.83%; the only material rows (nnet
   11.2%, radix2 6.7%, loops 1.6%) are preg/LQ pool exhaustion where a merge changes
   nothing. Reconciles with the empty-packet-buffer evidence.
4. **Multi-branch checkpoint bandwidth: KILL.** One save/packet/cycle confirmed
   (rename.sv:541-562) but the multi-branch stall IS counted and ≈0 (Save blocked = 0
   suite-wide), consistent with the re-audit P5 ≤0.5%.
5. **Move elimination: KILL.** `is_move_elim` hardwired 0 with the lifetime/refcount
   comment (rename.sv:466,475-479) — claim verified; zero-elim is already live (CM 35k
   elims). mv density: CM 8.0%/DS 7.7% but ~0 on the chain-bound members (crc32 0.004%);
   with execute at 0.16 cyc/uop and PRF non-binding, no value channel.
6. **Store-data decoupling (idea-6): SURVIVES ITS GATE — the one new live thread.**
   store-commit-wait: **matmult 21.3%**, tarfind 10.6% (latency-INsensitive, ==L=80),
   md5sum 9.3%, ud 7.4%, loops 7.4%, nnet 6.4% (+LQ-full 35%); SQ addr→data lag ≥6 cyc
   on 43–85% of stores (radix2 72%, stream-l2 85%). Pre-RTL gate: 1-line strict
   cross-product counter (commit-zero ∩ head-is-store-not-ready, rob.sv:1221) in the
   next batched counter commit, + the remaining sweep L=80 rows.
Parked per prerequisites: DTLB-replay/L2-QoS/I-side-depth → one boot-v3 +PERF_PROFILE
run post-commit answers all three. Early-recovery: stays behind the §4.7 measured-
negative bar; the M2 spill campaign is the funded branch-side play.

## 5. Ledger / open items

- zip-l2lat2: landed (+1.06% instret at equal cycles — not a P1 beneficiary; §1 table
  final, P1 refutation unchanged).
- **sim_memory 2MB truncation bug — CLOSED, all gates passed** (separate background
  hunt, this session): backing-store writes/reads wrap mod 2MB
  (`sim_memory.sv:68` index truncation × `tb_top.sv` 2MB default), aliasing the
  bare-metal stack (offset 127.5MB) onto bss/heap. Invisible at default config (2MB L2 =
  memory, no post-warmup refills); corrupts any L2-capacity A/B arm. **The L2 eviction
  RTL is exonerated** (full-run WT-shadow checker: drop/wipe/dirtyloss/instmm/wbmm all 0
  across 525k fills/385k WBs; fillmm=170 all in the mod-2MB alias band). TB-only fix
  applied (`tb_top.sv` sim_memory → 128MB, matching tb_linux). Validation: 512k
  stream-l2 PASS fillmm=0, zip clean through 55M (orig corruption at 41.9M), CM
  **cycle-exact golden 1,480,199** on the fixed default arm, lint 15. All prior 512k-L2
  arm results remain invalid. Three statically-found latent L2 corners never fire;
  proposed fixes parked unapplied (`/tmp/l2_evict_fix_proposal.diff`) per perf
  discipline, plus an unapplied sim_memory out-of-range `$fatal` tripwire proposal.
  **Interpretation caveat for all capacity/latency A/Bs through this TB:** sim_memory
  has no latency model (1-cycle fills, ready=1) — fixed-512k stream-l2 finishes FASTER
  (6.92M) than the 2MB baseline (8.15M) because the L2 miss path (~3 cyc direct bypass)
  beats the 8-cyc hit pipe. This corroborates §1's stream-l2 finding (its exposure is
  L2 *hit-pipe latency*) and re-confirms the study §3.6 prefetch sign-inversion; any
  DRAM-realistic conclusion needs a parameterized latency model first.
- Census instrument + L2PROBE + census/onboard logs + this doc + `-zc`/`-clangnoz`
  build scripts: uncommitted; batch-commit with the next sign-off.
- Data gaps carried: nnet/cjpeg have no profiler logs anywhere; sha/zip census arms are
  TIMEOUT-capped (steady-state metrics valid, inadmissible for IPC claims); stream-l2
  census-arm rerun is NOT needed (completed clean post-analysis; the "truncated" read
  was mid-flight).

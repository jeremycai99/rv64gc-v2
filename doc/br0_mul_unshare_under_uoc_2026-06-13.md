# BR0 / MUL port un-sharing under the UOC-repack lever (2026-06-13)

**Architect's question:** *"If BR0 (branch) and MUL are not shared, will performance
be better because backed by the uop cache?"* — i.e. does the UOC-repack supply uplift
(gen-2 stage 4, `doc/arch_refactor_plan_gen2_2026-06-13.md:27`) move the issue/writeback
binder onto the branch or MUL ports that are slack today.

**Method:** the same supply-scaling the FP census used — take each UOC-beneficiary row's
*current* branch-resolve and MUL demand from `log/piece2_runs/suite_on/*.log`, scale by the
row's UOC supply-uplift factor, and compare scaled demand against the structural caps
(branch-resolve = 2/cyc, MUL = ~1/cyc). READ-ONLY: no sims, no builds. All numbers below
are from the promoted-config 42-row suite at HEAD.

---

## 1. Topology at HEAD (verified, not trusted)

`src/rtl/core/rv64gc_core_top.sv`:

- **IQ0** (`u_iq0`, `:2313`, `NUM_SELECT=2`, `:2316` "BRU can issue from either port") =
  **ALU0+ALU1+BRU**. Two BRU lanes (BRU0, BRU1).
- **IQ1** (`u_iq1`, `:2358`, `NUM_SELECT=1`) = **ALU2+MUL**. Single select; port 1 hard-tied
  off (`:2398` `iq1_issue_valid[1]=1'b0`).
- **CDB lane map** (`:3832-3835`, `:3877-3925`, `:4068-4079`):
  - `CDB[0] = ALU0 / BRU` — `:3879 cdb_valid[0]=iq0_issue_valid[0]`; `:3897` muxes
    `cdb_data[0]=bru_result` when `bru_issue`, else `alu0_result`.
  - `CDB[1] = ALU1 / BRU1` — `:3905`; `:3923` muxes `bru1_result` else `alu1_result`.
  - `CDB[2] = ALU2 / MUL` — `:4071` ALU2 wins same-cycle; `:4076` MUL on the delayed
    cycle, drained from a hold/3-deep FIFO (`:3929`, `:4063-4066`).

**The real cost model (the load-bearing finding).** Branches do **not** own a dedicated
writeback lane. A branch issuing on IQ0 port 0 *displaces* the ALU0 writeback that cycle
(the `cdb_data[0]` mux is branch-XOR-ALU, `:3897-3899`). Likewise MUL on CDB[2] is
deferred whenever ALU2 issues (`:4071`). So:

- **branch-resolve capacity = 2/cyc** (2 BRUs), but each branch consumes one of the two
  IQ0 ALU writeback slots. "Un-share BR0" = add a dedicated BRU writeback lane so a branch
  + ALU0 + ALU1 can all retire in one cycle.
- **MUL effective capacity < 1/cyc** when ALU2 is busy (single shared CDB[2]).

**No CDB-conflict / port-collision counter exists.** Grep of `src/rtl/` for
`cdb_conflict` / `cdb.*loss` returns nothing; the only mul/bru observability is the ROB
*head-stall* sub-bucket `other-class: mul/div/csr/bru` (`rob.sv:1325`), which counts
*commit-latency* cycles, not issue/writeback contention. This projection therefore rests
on a counter that does **not** exist yet (see §6).

---

## 2. Current per-row demand (measured, full-run PASS rows)

Branch-resolve demand = **all BRU traffic** = committed `cond+jal+jalr+call+ret`
("Committed control summary"), NOT just `bpu_dyn_total` (which counts only conditionals —
e.g. rsort `updates=15507` = cond only; the call/ret/jal go through the BRU too).
MUL demand is taken from the ROB head-stall `other-class: mul` bucket and the IQ1
issued/operand split — there is **no per-FU MUL issue counter** (§6).

| row | cyc | branches (cond+jal+call+ret) | **br/cyc** | misp | MUL head-stall cyc | IQ0 issued/cyc | IQ1 issued/cyc |
|---|---:|---:|---:|---:|---:|---:|---:|
| rvb-rsort | 100,978 | 15,507+13+14+14 = **15,548** | **0.154** | 42 | **0** (`:706`) | 1.121 | 0.349 |
| dhrystone | 13,589 | 4,980+107+1,108+1,108 = **7,303** | **0.537** | 234 | 0 (`:709`) | 1.082 | 0.373 |
| dhrystone-ww | 10,155 | 2,968+207+1,108+1,108 = **5,391** | **0.531** | 31 | 0 (`:708`) | 1.043 | 0.400 |
| statemate | 1,156,753 | 140,179+6,670+23,325+23,325 = **193,499** | **0.167** | 3,378 | 0 (`:839`) | 1.020 | 0.207 |

Source lines: rsort `:215/:217/:140-141/:706`; DS `:222/:224/:140-141/:709`;
DS-ww `:218/:220/:140-141/:708`; statemate `:317/:319/:245-246/:839`. br/cyc and
issued/cyc computed = count / Total-cycles (`:18`/`:18`/`:18`/`:123`).

Today every beneficiary row is **deeply slack on both ports**: max branch-resolve is
DS at 0.537/cyc vs a 2/cyc cap (27% utilized); MUL head-stall is **literally zero** on
all four (these are integer-shuffle / string / state-machine rows with negligible
multiply). IQ0 arb-loss is ≤211/run except DS-ww (201) — fractions of a percent.

---

## 3. Scale by the UOC supply uplift

UOC-repack uplift factors (from the plan, `:27`): rsort ×1.10 (3.141→~3.47),
DS ×1.20 (2.614→~3.13), DS-ww ×1.27 (2.789→~3.55), statemate ×1.13 (2.973→~3.37).

**Honest super-linear model (prompt §3).** The UOC's entire value is delivering uops
*across taken edges* — a dense resident trace crosses the taken boundary instead of
truncating on it. So branch *density per delivered uop is preserved or rises*, and
branch-resolve/cyc scales **with the IPC uplift** (the uplift IS denser taken-edge
delivery). Modeled post-UOC br/cyc = current br/cyc × uplift (a faithful upper estimate —
it assumes the entire IPC gain is delivered as proportionally more branch resolves/cyc):

| row | current br/cyc | uplift | **post-UOC br/cyc** | vs **2/cyc** cap | MUL post-UOC | vs **1/cyc** cap | **verdict** |
|---|---:|---:|---:|---:|---:|---:|---|
| rvb-rsort | 0.154 | ×1.10 | **0.169** | 8.5% util | ~0 | 0% | **doesn't bind** |
| dhrystone | 0.537 | ×1.20 | **0.645** | 32% util | ~0 | 0% | **doesn't bind** |
| dhrystone-ww | 0.531 | ×1.27 | **0.674** | 34% util | ~0 | 0% | **doesn't bind** |
| statemate | 0.167 | ×1.13 | **0.189** | 9.4% util | ~0 | 0% | **doesn't bind** |

Even with the super-linear taken-edge model, the **highest** post-UOC branch-resolve
demand is DS-ww at **0.674/cyc against a 2/cyc cap (66% headroom)**. MUL demand is zero on
every beneficiary row regardless of uplift.

**Why branch-resolve cannot bind even in the worst case.** For the 2/cyc BRU cap to bind,
a row would need >2 branches resolved per cycle sustained. The densest beneficiary
(DS at 0.537 br/cyc today) would need a **3.7× uplift on branch density alone** to reach
the cap — far beyond the ×1.20 IPC uplift, and the UOC cannot manufacture branches that
aren't in the committed stream (the cond+call+ret count is program-fixed; the UOC only
changes *when* they arrive, compressing them into fewer cycles). At ×1.20 the branches
arrive 1.20× denser → 0.645/cyc, nowhere near 2.

**The writeback-displacement second-order check.** Even though branches steal an IQ0 ALU
writeback slot, the combined IQ0 demand stays far under its 2-wide-select capacity:
post-UOC IQ0 issued + branch-displacement is bounded by (IQ0 issued/cyc × uplift). DS is
the tightest: 1.082 × 1.20 = 1.30/cyc against the 2-select IQ0 — 35% headroom. The branch
writebacks fit inside the existing ALU0/ALU1 slack; they do not force a third lane.

---

## 4. Controls — the mul-heavy rows are NOT UOC beneficiaries

| row | MUL head-stall cyc | binder (scoreboard) | UOC beneficiary? |
|---|---:|---|---|
| embench-aha-mont64 | **23,529** (`:856`) | misp 43% cyc + modul64 carried chain | **NO** |
| embench-matmult-int | **38,043** (`:846`) | fetch-fragmentation (B=8.4) + store-commit 21.3% | **NO** |

mont64 and matmult are the only rows with material MUL pressure (23.5k / 38.0k head-stall
cycles). But the plan and scoreboard (`perf_scoreboard_2026-06-13.md:52,59`) classify both
as **misp / fetch-fragmentation / store-commit bound — explicitly NOT supply-bound**, so
the UOC delivers them ~0 IPC (CM-class: dense trace doesn't help a wrong-path / fetch-frag
machine). Therefore the UOC cannot push their MUL demand up: **un-sharing MUL helps these
rows only via raw MUL throughput if it bound *today*, which it does not — matmult IQ1
issued is 650,939 over ~838k cyc with ALU2 winning, and the MUL head-stall is a
*commit-latency* artifact (3-cyc MUL on the critical chain), not a CDB[2] *contention*
artifact.** Un-sharing MUL's writeback would not shorten the 3-cyc MUL latency that
actually stalls these chains. **MUL un-sharing does not help, under UOC or otherwise.**

---

## 5. The misp-band honesty check (throughput vs resolution latency)

Un-sharing BR0 has two distinct potential effects; only one is even in scope here:

- **Branch RESOLUTION latency** (cutting the path from branch-issue to redirect) — matters
  only on misp-heavy rows. But the UOC beneficiaries are **misp ≈ 0**: rsort 42 misp /
  15.5k branches (0.27%), DS-ww 31 (0.57%), statemate 3,378 / 193k (1.7%); DS is the
  outlier at 234 but still supply-bound at ceiling (UB 2.62, `scoreboard:37`). So
  resolution-latency gains from un-sharing BR0 are **≈0 on exactly the rows the UOC helps.**
- **Branch THROUGHPUT under dense delivery** (the real candidate effect) — measured in §3:
  even with the super-linear taken-edge model, peaks at 0.674/cyc vs a 2/cyc cap.

The two are cleanly separated: the rows where BR0-unshare *could* cut latency (the
misp-asymptote band — md5sum, qsort, mont64, qrduino) are **not UOC beneficiaries**
(`scoreboard:54-66`, `plan:55-57`), and the rows the UOC *does* help have no latency to
cut. There is no row where the UOC's supply uplift and a branch-port bind coincide.

---

## 6. Answer

**Is it better backed by the uop cache? No — neither BR0 nor MUL binds under UOC.**
The ports stay slack. **Do not un-share.**

- **Branch-resolve:** max post-UOC demand **0.674/cyc (DS-ww) against a 2/cyc cap** — 66%
  idle even under the super-linear taken-edge model. The program's branch count is fixed;
  the UOC only compresses ~0.5 br/cyc into ~0.67 br/cyc, not past 2. Incremental IPC of
  un-sharing BR0 on top of the UOC = **~0%** (and the writeback-displacement headroom check
  §3 confirms the branches already fit inside IQ0's existing 2-select slack).
- **MUL:** zero head-stall on every beneficiary row; the only mul-pressured rows
  (mont64/matmult) are misp/fetch-frag bound and get ~0 from the UOC, and their MUL stall
  is 3-cyc *latency* not CDB[2] *contention* — un-sharing the writeback wouldn't touch it.
  Incremental IPC of un-sharing MUL on top of the UOC = **~0%**.

This is a clean "don't un-share." The UOC's value is its own IPC gain (§3 uplifts); it does
**not** create a downstream branch/MUL port bind to chase. Do **not** add this to the UOC
RTL scope — it is dead silicon (a dedicated BRU writeback lane is ~CDB-width comparators +
a 5th CDB consumer the plan already rejected at `plan:39` "CDB 4→5/6 … for zero measured
queueing").

### What would *confirm* this projection (the F3 counter that does not exist)

This rests on the absence of a **CDB-conflict / port-collision counter** (§1). Two
sim-only counters, folded into the gen-2 **stage-0 F3 batch** (`plan:22`), would close it:

1. **`bru_wb_displaced_alu` / cyc** — count cycles where a branch issues on IQ0 port N
   AND an ALU op was eligible-but-not-issued on that same port that cycle (i.e. the branch
   actually stole an ALU writeback). Today's model assumes this is ~0 because IQ0 issued/cyc
   ≤1.30 post-UOC vs 2-select; this counter measures it directly. ~3 lines at
   `core_top:3879/:3905`.
2. **`mul_cdb2_deferred` / cyc** — count cycles where MUL had a live result but ALU2 won
   CDB[2] (`:4071`), forcing the hold FIFO. Today's model assumes ~0 on beneficiary rows;
   this counter measures CDB[2] contention vs the existing head-stall *latency* bucket.
   ~2 lines at `core_top:4068`.

If, post-UOC-RTL, either counter is non-trivial on a beneficiary row, re-open this verdict.
Until then: **ports stay shared; the UOC ships without a BR0/MUL un-share follow-on.**

---

## Appendix: data provenance

All counters from `log/piece2_runs/suite_on/` (promoted config, 2026-06-13, Verilator,
PASS rows at tohost): `rvb-rsort.log`, `dhrystone.log`, `dhrystone-ww.log`,
`embench-statemate.log` (beneficiaries); `embench-aha-mont64.log`,
`embench-matmult-int.log` (mul-heavy controls). Topology from
`src/rtl/core/rv64gc_core_top.sv` at HEAD (commit `bcba1a6`). UOC uplift factors from
`doc/arch_refactor_plan_gen2_2026-06-13.md:27`. CDB-conflict counter absence confirmed by
`grep cdb_conflict src/rtl/` (empty).

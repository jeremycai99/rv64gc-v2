# Cycle B Investigation — SFB Eligibility

**Date:** 2026-05-01
**Repo HEAD:** master @ 05c8e3d
**Plan:** `doc/4wide_iter_sfb_plan_2026-05-01.md`

## Branch inventory (dhry)

```
Total disassembly lines:           678
Total conditional branches:         92
  Backward (loop edges):            83
  Forward >32 bytes:                 2
  SFB-eligible (<=32 bytes fwd):     7
Zicond (czero) actual:               0   (compiler did not apply -march=zicond)
```

All 7 SFB-eligible static dhry branches:

| PC | Offset (B) | Asm |
|---|---:|---|
| 0x800002a8 | +16 | beqz a0, ... |
| 0x80002016 | +12 | bnez a5, strcmp+0x10 |
| 0x8000201e | +22 | beqz a5, strcmp+0x22 |
| 0x80002046 | +22 | beqz a2, memcpy+0x16 |
| 0x800022ea | +8  | beqz a5, Proc_3+0x12 |
| 0x8000235c | +20 | beqz a0, Proc_6+0x2a |
| 0x800023c4 | +8  | beqz a4, Proc_1+0x4c |

## Branch inventory (cm)

```
Total disassembly lines:          2749
Total conditional branches:        289
  Backward (loop edges):          195
  Forward >32 bytes:               59
  SFB-eligible (<=32 bytes fwd):   35
Zicond (czero) actual:              0   (compiler did not apply)
```

35 SFB-eligible static cm branches (full list captured by `/tmp/sfb_classify.py`).

## Top mispredict PCs cross-reference

### dhry (from `benchmark_results/perf_full_4wide_dhrystone.log`, 19 PCs, 128 events)

| PC | Mispredict count | SFB-eligible? | Branch asm |
|---|---:|---|---|
| 0x80002028 | 100 | N (offset out of <=32B fwd window) | cond branch in strcmp body |
| 0x8000200e |   6 | N | cond |
| 0x800021e0 |   5 | N | cond |
| 0x80002226 |   2 | N | cond |
| 0x80002016 |   1 | **Y (+12)** | bnez a5, strcmp+0x10 |
| 0x800002a8 |   1 | **Y (+16)** | beqz a0 (boot) |
| (15 others) | 1-1 | N | cond/ret mix |

**SFB-eligible mispredict events captured: 2 of 123 cond mispredicts (1.6%).**

### cm (from `benchmark_results/perf_full_4wide_cm_iter1.log`, ~150 PCs, 4343 events)

Top 10 hottest mispredict PCs:

| PC | Mispredict count | SFB-eligible? | Branch asm |
|---|---:|---|---|
| 0x800031ec | 324 | N (offset >32 fwd) | cond, mergesort body |
| 0x800036b4 | 521 | N | cond, core_state_transition |
| 0x80002446 | 204 | N | cond |
| 0x800023ae | 203 | N | cond |
| 0x80003710 | 186 | N | cond |
| 0x80002380 | 168 | N | cond |
| 0x80003aea | 138 | N | cond |
| 0x800036bc | 134 | N | cond |
| 0x80003648 | 129 | N | cond |
| 0x80003704 | 119 | N | cond |
| 0x8000235a | **103** | **Y (+10)** | bge s0,s5 — list mergesort hot mispredict |
| 0x8000242e |  95 | **Y (+12)** | beqz a5, core_bench_list+0x44 |

**SFB-eligible mispredict events captured: 307 of 4256 cond mispredicts (7.2%).**

The single largest SFB-eligible captured PC is `0x8000235a` at 103 mispredicts (the previously-noted cm hot mispredict). The next-largest is `0x8000242e` at 95.

## Predicted SFB win

Per-mispredict recovery cost: ~6 cycles (frontend redirect window for the 4-wide pipeline).

```
DHRY:  saved_cyc = 2 events  * 6 = 12 cyc
       total_cyc = 23,514
       predicted_win = 12 / 23514 = 0.05%
       threshold (1%) = 235 cyc        -> FAIL

CM:    saved_cyc = 307 events * 6 = 1842 cyc
       total_cyc = 199,452
       predicted_win = 1842 / 199452 = 0.92%
       threshold (2%) = 3989 cyc       -> FAIL
```

(Note: 6 cyc per mispredict is the lower-bound recovery cost; even at 10 cyc the predicted dhry win is 0.09% and cm 1.54% — still below thresholds.)

## Decision

**REFUTE-on-investigation.** Predicted dhry +0.05%, predicted cm +0.92%; both below the 1%/2% thresholds defined in the plan.

Three observations reinforce the decision:

1. **dhry is structurally hostile to SFB.** Of 92 cond branches, 83 are backward loop edges (not SFB by definition) and only 7 are forward <=32B. Of those 7, only 2 ever appear in the top mispredict list — and each at count = 1.

2. **cm is also dominated by long-distance forward branches** (59 forward >32B vs 35 SFB-eligible) and the hottest mispredict PCs (324, 521, 204, 203, 186, 168...) are all *outside* the SFB window. Even the SFB-eligible PCs that DO mispredict (0x8000235a at 103, 0x8000242e at 95) account for only 7.2% of cond mispredicts.

3. **Implementing SFB infrastructure costs ~250 lines of RTL across 4-5 files** (decode pattern detection, predicate signal in uop, rename propagation, ALU writeback suppression, ROB tracking) plus 3-5 build/test cycles plus clockcheck allowlist work. For predicted gains <1% (dhry) and <1% (cm), the engineering cost is not justified.

## Conservative recommendation

Skip RTL implementation. Document the finding. Adopt PARTIAL-FLOOR (`doc/4wide_signoff_2026-05-01.md`) as final per the cumulative 3-cycle outcome (see `doc/4wide_iter_sfb_results.md`).

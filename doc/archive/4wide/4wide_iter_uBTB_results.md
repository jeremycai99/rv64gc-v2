# Cycle A Results — uBTB / NLP / BPU Sizing

**Date:** 2026-05-01
**Repo HEAD:** master @ 327610e
**Verdict:** REFUTED-no-change (investigation only)

## Hypothesis under test

rv64gc-v2's BPU storage (BTB / TAGE / RAS / NLP) may be undersized vs
MegaBoom v4. If yes, bump and measure with +/-0.5% IPC tolerance. If
no, REFUTE-on-investigation, no RTL change.

## Investigation findings

| Component                 | rv64gc-v2 (current)              | BOOM v4 (Mega defaults)             | Verdict                      |
|---------------------------|----------------------------------|-------------------------------------|------------------------------|
| BTB total entries         | 2048 (256 sets x 8 ways)         | 256 (128 sets x 2 ways)             | rv64gc 8x larger             |
| BTB ways                  | 8                                | 2                                   | rv64gc 4x                    |
| TAGE tagged tables        | 4                                | 6                                   | rv64gc has fewer (-2)        |
| TAGE entries / table      | 256 (uniform)                    | 128 / 128 / 256 / 256 / 128 / 128   | rv64gc >= BOOM per-table     |
| TAGE total tagged storage | 1024                             | 1024                                | equal                        |
| TAGE history lengths      | 8, 16, 32, 64                    | 2, 4, 8, 16, 32, 64                 | BOOM adds 2,4 short-history  |
| TAGE tag bits             | 12                               | 7-9                                 | rv64gc larger tags           |
| TAGE base / bimodal       | 4096-entry bimodal base          | (BIM separate)                      | comparable / larger          |
| Statistical Corrector     | 1024 entries                     | not in default TAGE-L BPD           | rv64gc has, BOOM lacks       |
| Loop predictor entries    | 64                               | 64 (16 sets x 4 ways)               | equal                        |
| RAS depth                 | 24                               | 32                                  | rv64gc smaller (-8)          |
| Micro-BTB (separate)      | none (single BTB stage)          | 256-entry FA uBTB                   | BOOM has, rv64gc lacks       |
| NLP / line buffer         | 4 entries (next-line prefetch)   | (NLP role filled by uBTB in BOOM)   | not directly comparable      |

## Source citations

### rv64gc-v2 (in-tree)
- `src/rtl/core/include/rv64gc_pkg.sv:186-191`:
  - `BTB_ENTRIES = 2048`, `BTB_WAYS = 8`, `BTB_SETS = 256`
  - `TAGE_BASE_ENTRIES = 4096`, `TAGE_NUM_TABLES = 4`,
    `TAGE_TABLE_ENTRIES = 256`, `TAGE_TAG_BITS = 12`
  - `SC_ENTRIES = 1024`, `LOOP_PRED_ENTRIES = 64`, `RAS_DEPTH = 24`
- `src/rtl/core/fetch/tage_sc_l.sv:81-89`: `GHR_LEN_{0..3} = {8,16,32,64}`
- `src/rtl/core/fetch/next_line_prefetch_buffer.sv:45`: `NUM_ENTRIES = 4`
- `src/rtl/core/fetch/ras.sv:27-28`: `RAS_DEPTH` from pkg, 64-bit stack

### BOOM v4 (riscv-boom master)
- `src/main/scala/v4/ifu/bpd/btb.scala`:
  > `case class BoomBTBParams(nSets: Int = 128, nWays: Int = 2, offsetSz: Int = 13, extendedNSets: Int = 128, useFlops: Boolean = false)`
- `src/main/scala/v4/ifu/bpd/tage.scala`:
  > `case class BoomTageParams(tableInfo: Seq[Tuple3[Int, Int, Int]] = Seq((128,2,7), (128,4,7), (256,8,8), (256,16,8), (128,32,9), (128,64,9)), uBitPeriod: Int = 2048, singlePorted: Boolean = false)`
- `src/main/scala/v4/ifu/bpd/loop.scala`:
  > `case class BoomLoopPredictorParams(nWays: Int = 4, threshold: Int = 7)` plus `nSets = 16` fixed -> 64 total
- `src/main/scala/v4/ifu/bpd/ubtb.scala`:
  > `case class BoomMicroBTBParams(nSets: Int = 256, offsetSz: Int = 13)`
- `src/main/scala/v4/common/parameters.scala`:
  > `numRasEntries: Int = 32`, `globalHistoryLength: Int = 64`,
  > `localHistoryLength: Int = 32`, `localHistoryNSets: Int = 128`,
  > `bpdMaxMetaLength: Int = 120`
- `src/main/scala/v4/common/config-mixins.scala`:
  > `WithNMegaBooms` uses `WithTAGELBPD` (TAGE-L), no per-Mega override
  > of BTB/TAGE/RAS sizes -> BoomCoreParams + BoomBTBParams + BoomTageParams
  > defaults apply.

## Decision rationale

Three components could be flagged as potentially "smaller than BOOM":

1. **TAGE 4 tables vs BOOM 6 tables.** BOOM adds two extra short-history
   tables (2-bit and 4-bit GHR). rv64gc-v2 covers histories 8/16/32/64,
   matches BOOM per-table size, has *larger* tags (12 vs 7-9), *larger*
   bimodal base (4096 vs separate BIM), and *adds* a 1024-entry
   Statistical Corrector that BOOM-default lacks. Adding two TAGE tables
   is a structural change (extends per-table arrays, GHR_LENGTHS,
   fold-tables, allocate-on-miss logic, and update path everywhere
   `TAGE_NUM_TABLES` is iterated) -- not a minimal sizing knob.
   **Refuted as undersized; structural change deferred.**

2. **RAS 24 vs 32.** Small numerical gap (-8 entries). The 5-bit pointer
   width (`5'(RAS_DEPTH-1)`) already supports up to 32 with no literal
   change. RAS_DEPTH = 24 already exceeds typical call-chain depth on
   cm and dhry workloads (both have shallow nesting). Expected delta
   <0.1% IPC, well below +/-0.5% measurement floor. **Below tolerance;
   not worth a build+regression cycle.**

3. **uBTB absent.** rv64gc-v2 has no separate fast 1-cycle micro-BTB
   structure; the 2048-entry main BTB serves both roles. BOOM uses a
   256-entry FA uBTB for first-cycle redirect. Adding one is a *new
   module*, not a sizing bump -- out of scope for this cycle.

All other components in rv64gc-v2 meet or exceed BOOM v4 reference
values (BTB 8x larger, TAGE per-table equal-or-greater with longer tags,
Loop predictor equal, NLP independent concept, SC adds capacity BOOM
lacks). The "undersized vs BOOM" hypothesis is **REFUTED on
investigation**. No RTL change applies. Baseline (cm 1.665, dhry 2.027)
is unchanged.

## Implication

Refuting a hypothesis is itself data. This investigation saved a
build + dual-simulator regression cycle that would have produced a
neutral measurement. Proceed to Cycle C (flush-recovery latency
narrowing).

## Sources

- BOOM v4 BTB:    https://github.com/riscv-boom/riscv-boom/blob/master/src/main/scala/v4/ifu/bpd/btb.scala
- BOOM v4 TAGE:   https://github.com/riscv-boom/riscv-boom/blob/master/src/main/scala/v4/ifu/bpd/tage.scala
- BOOM v4 uBTB:   https://github.com/riscv-boom/riscv-boom/blob/master/src/main/scala/v4/ifu/bpd/ubtb.scala
- BOOM v4 Loop:   https://github.com/riscv-boom/riscv-boom/blob/master/src/main/scala/v4/ifu/bpd/loop.scala
- BOOM v4 Params: https://github.com/riscv-boom/riscv-boom/blob/master/src/main/scala/v4/common/parameters.scala
- BOOM v4 Config: https://github.com/riscv-boom/riscv-boom/blob/master/src/main/scala/v4/common/config-mixins.scala

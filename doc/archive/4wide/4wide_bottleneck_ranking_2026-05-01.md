# 4-Wide Bottleneck Ranking — 2026-05-01

**Source:** `doc/4wide_perf_inventory_2026-05-01.md` (Phase A output)
**Repo HEAD:** `master @ 4a78605`

---

## CoreMark iter1 (mcycle=199,452, IPC=1.665)

`peak_retire_cycles = ceil(332,110 / 4) = 83,028`
`gap_cycles = mcycle − peak_retire = 116,424`

| Bucket | Cycles | % of mcycle | % of gap | Notes |
|---|---:|---:|---:|---|
| **Issue (operand-stall)** | 69,426 | 34.8% | 59.6% | IQ has entries but NO eligible — waiting on producer |
| **Head-wait: unknown (plain-ALU producer)** | 46,363 | 23.2% | 39.8% | Subset of head_not_ready_other |
| **Head-wait: load** | 20,196 | 10.1% | 17.3% | Loads complete in 1 cycle but consumer can't issue immediately |
| **Head-wait: branch (BRU resolution)** | 15,926 | 8.0% | 13.7% | Drives the 4,343 flush cycles indirectly |
| Issue (arb-loss) | 11,286 | 5.7% | 9.7% | Eligible_count > NUM_SELECT |
| Head-wait: MUL | 6,740 | 3.4% | 5.8% | Real but minor |
| Frontend (flushes) | 4,343 | 2.2% | 3.7% | 8% cond-mispredict rate |
| Head-wait: store | 3,853 | 1.9% | 3.3% | Minor |
| Head-wait: BRU | 1,037 | 0.5% | 0.9% | Negligible |
| Head-wait: DIV / CSR | 14 / 0 | <0.1% | <0.1% | Negligible |
| Rename / Dispatch / IQ-full | 20 | 0.0% | 0.0% | Refuted as bottleneck |

**Top-3 cm iter1 buckets:**
1. **Issue operand-stall** (34.8% of cycles, 59.6% of gap)
2. **Head-wait unknown (plain-ALU producer)** (23.2%, 39.8%)
3. **Head-wait load** (10.1%, 17.3%)

(Note: bucket overlaps possible — operand-stall and head-wait can co-occur. Together they paint a single picture: cm is bottlenecked by ALU-producer dependency-resolution latency.)

---

## CoreMark iter10 (mcycle=1,860,512, IPC=1.719)

Same proportional profile as iter1 (confirms iter1 isn't an artifact). Top-3:
1. Issue operand-stall (36.3% of cycles, 63.6% of gap)
2. Head-wait unknown (23.7%, 41.6%)
3. Head-wait load (9.9%, 17.4%)

iter10's slightly better IPC (1.719 vs 1.665) reflects amortized one-time setup; the bottleneck shape is identical.

---

## Dhrystone (mcycle=23,514, IPC=2.027)

`peak_retire_cycles = ceil(47,670 / 4) = 11,918`
`gap_cycles = 11,596`

| Bucket | Cycles | % of mcycle | % of gap | Notes |
|---|---:|---:|---:|---|
| **Head-wait: load** | 6,438 | 27.4% | 55.5% | DOMINANT — top PC `0x80002002` accounts for 3,170 of these |
| **Issue (operand-stall)** | 3,744 | 15.9% | 32.3% | Likely waiting on the same load chain |
| **Head-wait: unknown (plain-ALU)** | 1,286 | 5.5% | 11.1% | Smaller share than cm |
| Head-wait: BRU | 412 | 1.8% | 3.6% | |
| Head-wait: store | 330 | 1.4% | 2.8% | |
| Head-wait: DIV | 301 | 1.3% | 2.6% | dhry has visible DIV usage |
| Head-wait: branch | 173 | 0.7% | 1.5% | BPU healthy |
| Frontend (flushes) | 128 | 0.5% | 1.1% | 1.6% mispredict rate |
| Head-wait: MUL / CSR | 0 / 0 | 0% | 0% | dhry doesn't use MUL |
| Issue arb-loss | 2 | 0.0% | 0.0% | Negligible |
| Rename / Dispatch / IQ-full | 0 | 0.0% | 0.0% | Refuted |

**Top-3 dhry buckets:**
1. **Head-wait load** (27.4% of cycles, 55.5% of gap)
2. **Issue operand-stall** (15.9%, 32.3%)
3. **Head-wait unknown (plain-ALU)** (5.5%, 11.1%)

---

## Per-PC Hot-Wait Sources (top contributors to head-stall)

### cm (top 5 by head-stall cycles)

| PC | Cycles | Class | Notes |
|---|---:|---|---|
| `0x80002440` | 6,528 | load | In CoreMark hot loop |
| `0x80003164` | 2,951 | load | In CoreMark hot loop |
| `0x80003564` | 525 | load | In `core_list_mergesort` |
| `0x80002128` | 317 | load | |
| `0x8000235e` | 320 | load | Adjacent to the BPU mispredict PC `0x8000235a` |

### dhry (top 5 by head-stall cycles)

| PC | Cycles | Class | Notes |
|---|---:|---|---|
| `0x80002002` | 3,170 | load | DOMINANT — single PC accounts for 36% of all load head-wait |
| `0x80002022` | 1,402 | load | |
| `0x80002010` | 306 | other | |
| `0x80002340` | 102 | store | |
| `0x80002492` | 103 | load | |

**For dhry, just two PCs (`0x80002002` + `0x80002022`) account for 4,572 / 6,438 = 71% of all load head-stall cycles.** This is hyper-concentrated; a small RTL change that helps these two PCs dominates dhry IPC.

---

## Cross-Workload Synthesis

The two workloads have **converging bottleneck profiles** despite different surface signatures:

- Both are dominated by **producer-dependent issue/commit waits** (issue operand-stall + head-wait load + head-wait plain-ALU)
- Together these account for: cm = 116k of 116k gap cycles (≥100% with overlap); dhry = 11k of 12k gap cycles (~95%)

**The narrowing penalty is concentrated in dependency-resolution paths**, not in:
- Structural capacity (IQ depth, ROB depth, LQ/SQ depth — all 0% saturation)
- Rename throughput (rename_stall=0 across the board)
- MUL/DIV pipeline (3-4% of cm gap, negligible for dhry)
- CSR serialization (0% everywhere)
- Issue port arbitration (5-6% of cm gap, ~0% for dhry)

Phase D RTL hypotheses must concentrate on:
1. **Bypass coverage / wakeup latency** — what's the round-trip for ALU0→ALU1 dep-chain in 4-wide vs 6-wide?
2. **Load-to-consumer issue gap** — load completes at T+2; consumer wakes at T+2; consumer issues at T+3. Can this be tightened?
3. **PRF read-port pressure during high-IQ-occupancy cycles** — if PRF reads stall, eligible drops to 0, drives operand-stall

These three areas are the entire focus of Phase C hypothesis enumeration.

---

## Refuted Seed Hypotheses (data-driven elimination)

| Hypothesis | Refute Evidence | Status |
|---|---|---|
| dhry-H4: IQ_INT_DEPTH=24 too small | `iq{0,1,2}_full_cyc = 0` for both workloads | REFUTED |
| dhry-H2 (partial): checkpoint back-pressure | `stall_ckpt_cyc = 0` everywhere | REFUTED |
| cm-H3: NUM_ALU=3 ALU contention | `issue_stall_arb_cyc` only 5.7% cm, ~0% dhry | REFUTED (arb isn't the dominant Issue sub-class) |
| Generic: structural capacity | All `*_full_cyc = 0` and `rename_stall_cyc = 0` | REFUTED across all workloads |
| Generic: rename pressure | All `stall_*_cyc = 0` | REFUTED |
| dhry-H3: BPU return-stack degradation | dhry mispredict rate 1.6%, ret mispredicts only 5/1210 = 0.4% | REFUTED (BPU healthy on dhry) |
| dhry-H1 (partial): "head waits on load WB" — CONFIRMED but mechanism is consumer-can't-issue, not WB-pending | head_wait_load=27% but load_lat 1-cycle 94% | RECAST as Phase C cm-H4/dhry-H5 below |

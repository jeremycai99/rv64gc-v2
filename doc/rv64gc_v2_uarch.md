# RV64GC v2 Microarchitecture Specification

## Document Purpose

This document specifies a **6-wide out-of-order RV64GC core** as the
v2 design. It is a clean-sheet architecture specification for RTL
implementation — not an incremental upgrade from v1.

The design is informed by a gem5 surrogate study (2026-04-05/06) that
produced five sweep datasets, a full v1 RTL audit, and a ROB
sensitivity analysis. All supporting data is in the gem5 study
workspace.

**ISA:** `rv64imafdc_zba_zbb_zbs_zicond_zicsr_zifencei`

**Performance targets:**
- **CoreMark IPC: 2.5 (minimum 2.0, stretch 3.0)**
- **Dhrystone IPC: 3.2 (minimum 2.6)**
- **gem5 ceiling: 3.15 CoreMark / 3.92 Dhrystone**
- With ISA extensions + macro-op fusion + compiler optimizations, the
  stretch goal of 3.0 becomes the expected outcome on CoreMark.

**Key engineering constraints validated by gem5 sweeps:**
- ROB=192 is the optimal size (192→320 = +0.05% IPC for +67% area)
- 4 ALUs is sufficient (5th ALU = +0.000 IPC despite 82% fewer busy events)
- L1 64kB + L2 2MB is sufficient (larger = zero gain)
- TAGE-SC-L is the correct predictor (+15% Dhrystone vs LTAGE)

---

## 1. Design Overview

### 1.1 Design Parameters

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| ISA | rv64imafdc_zba_zbb_zbs_zicond | Zba/Zbb/Zbs/Zicond add ~10–15% effective IPC from reduced dynamic insn count |
| Pipeline width | 6-wide fetch / decode / rename / dispatch / commit | gem5: 4w→6w = +17% CoreMark; 6w→8w = diminishing returns |
| Rename semantics | Per-slot independent advance | Eliminates group-hold artifact (was 57% of cycles in v1) |
| Dispatch width | 6-wide, round-robin with fallback | Eliminates 4→2 narrowing artifact from v1 |
| Issue | 3 int IQs × 32 entries, dual-select (2 ports/IQ), max 4 int issue/cycle | Reduces ROB-head "other" blocking from 62% to <10% |
| Memory issue | 2 load AGU + 1 store AGU, from Ld/StA/StD IQs (32 entries each) | Dual load port matches 6-wide demand |
| ROB depth | **192 entries** | ROB sensitivity: 192→256 = +0.0001 IPC. 192 is the knee. |
| Integer PRF | **256 × 64-bit**, 12R6W | 32 arch + 224 rename temps. PRF never exhausts at ROB=192. |
| FP PRF | 128 × 64-bit | 32 arch + 96 rename temporaries |
| Free list | Bitmap-based, 256-bit | Match PRF depth |
| Branch predictor | **TAGE-SC-L** (statistical corrector + loop predictor) | gem5 measured: +15% Dhrystone IPC vs LTAGE |
| BTB | 1024-entry, 4-way | 4× v1; reduces miss rate on Linux-scale code |
| RAS | 24 entries | Deeper call stacks than v1's 16 |
| L1 I-cache | 32 kB, 4-way, 1-cycle hit | Must implement (v1 has none) |
| L1 D-cache | 64 kB, 4-way, 4-bank interleaved, 1-cycle hit | Banked eliminates load/store port serialization |
| L2 cache | 2 MB, 8-way, 8-cycle hit, 32 MSHRs | gem5: 2 MB sufficient, 4 MB = zero gain |
| LQ / SQ | **48 / 48** | Sufficient at ROB=192 |
| Committed store buffer | 24 entries | Wider drain path than v1's 16 |
| Dispatch queue | 32 int + 32 mem | Absorb 6-wide rename bursts |
| Recovery | Checkpoint-based (4 checkpoints) | Flush to branch, not commit; ~3 cycles saved per mispredict |
| Squash | 1-cycle combinational, 8 ROB entries/cycle | Fast restart from checkpoint |
| Move elimination | At rename: `mv`, `li 0`, `xor rd,rd,rd` bypass backend | ~10% IQ + FU pressure reduction |
| Speculative wakeup | All fixed-latency FUs (ALU, MUL, load-on-hit) | Removes 1 cycle from every dependency chain |
| Loop buffer | 64-entry decoded µop cache | Zero-stall hot loops |
| Macro-op fusion | Decode-stage pair detection + merge | +1% CoreMark, +10–15% Linux boot |

### 1.2 Pipeline Diagram

```
                         FRONT-END (6-wide)
  ┌─────────┐ ┌──────────────┐ ┌─────────┐ ┌─────────┐
  │  IF1     │ │ IF2/DE       │ │  RN     │ │  DQ     │
  │          │ │              │ │         │ │         │
  │ PC gen   │→│ Fetch+Decode │→│ Rename  │→│Dispatch │
  │TAGE-SC-L │ │ 6-wide       │ │ 6-wide  │ │ Queue   │
  │ BTB(1K)  │ │ I$32kB       │ │ per-slot│ │ 32-deep │
  │ RAS(24)  │ │ macro-op     │ │ mv-elim │ │ 6-wide  │
  │          │ │ fusion       │ │         │ │         │
  └─────────┘ └──────────────┘ └─────────┘ └─────────┘
       │                                        │
       │  ┌─────────────────────────────────────┘
       │  │     BACK-END
       │  ▼
  ┌─────────┐ ┌─────────┐ ┌──────────┐
  │  IQ     │ │  RD     │ │  EX      │
  │         │ │         │ │          │
  │3×32 int │→│PRF Read │→│ ALU ×4   │  (Zba: sh1add/sh2add/sh3add)
  │ 2sel/IQ │ │+Bypass  │ │ MUL ×1   │  (Zbb: clz/ctz/min/max/rol)
  │ spec    │ │ 12R6W   │ │ DIV ×1   │  (Zbs: bset/bclr/bext)
  │ wakeup  │ │         │ │ BRU ×1   │  (Zicond: czero.eqz/nez)
  └─────────┘ └─────────┘ │ LdAGU×2  │  (fused CMP+BR)
       ↑ loop              │ StAGU×1  │
       ↑ buffer            │ FPU ×1   │
       ↑ (64 µop)          │ FMA ×1   │
       ↑                   └──────────┘
  ┌─────────┐ ┌─────────┐       │
  │  WB     │ │  CM     │       │
  │         │ │         │←──────┘
  │Writeback│→│ Commit  │
  │ CDB 6-w │ │ 6-wide  │
  │         │ │ 4 ckpt  │
  └─────────┘ └─────────┘

Pipeline: IF1 → IF2/DE → RN → DQ → IQ → RD → EX → WB → CM
```

### 1.3 Functional Unit Inventory

| FU | Count | Latency | Pipelined? | IQ | Notes |
|----|-------|---------|------------|-----|-------|
| IntALU | 4 | 1 cycle | Yes | IQ0: ALU0+ALU1, IQ1: ALU2, IQ2: ALU3 | Handles Zba (sh*add), Zbb (min/max/clz/ctz/rol/ror), Zbs (bset/bclr/bext), Zicond (czero) |
| BRU | 1 | 1 cycle | Yes | IQ0 (shared with ALU0) | Handles fused compare-and-branch µops |
| IntMul | 1 | 3 cycles | Yes | IQ1 (shared with ALU2) | |
| IntDiv | 1 | ~20–33 cycles | No | IQ2 (shared with ALU3) | |
| CSR/System | 1 | 1 cycle | Yes | IQ2 | |
| Load AGU | 2 | 1 cycle | Yes | Ld IQ (dual-port select) | |
| Store AGU | 1 | 1 cycle | Yes | StA IQ | |
| Store Data | 1 | 1 cycle | Yes | StD IQ | |
| FP Add/Cmp/Cvt | 1 | 2 cycles | Yes | FP IQ | |
| FP Mul/FMA | 1 | 4–5 cycles | Yes | FP IQ | |
| FP Div/Sqrt | 1 | 12–24 cycles | No | FP IQ | |

---

## 2. ISA Extensions

### 2.1 Zba — Address Generation

Replaces 2–3 instruction array-indexing sequences with 1 instruction.
All are 1-cycle ALU operations.

| Instruction | Operation | Replaces |
|---|---|---|
| `sh1add rd, rs1, rs2` | `rd = (rs1 << 1) + rs2` | `slli + add` (2 insns) |
| `sh2add rd, rs1, rs2` | `rd = (rs1 << 2) + rs2` | `slli + add` (2 insns) |
| `sh3add rd, rs1, rs2` | `rd = (rs1 << 3) + rs2` | `slli + add` (2 insns) |
| `add.uw rd, rs1, rs2` | `rd = zext32(rs1) + rs2` | `slli + srli + add` (3 insns) |
| `sh{1,2,3}add.uw` | Unsigned-word shift-add | 3 insns |
| `slli.uw rd, rs, shamt` | `rd = zext32(rs) << shamt` | `slli + srli` (2 insns) |

RTL: ~50 lines (shifted-add path in ALU). Expected: **+5–8% IPC**.

### 2.2 Zbb — Basic Bit Manipulation

| Instruction | Operation | Replaces |
|---|---|---|
| `clz / ctz / cpop` | Count leading/trailing zeros, popcount | 15–20 insn software loops |
| `min / max / minu / maxu` | Integer min/max | `blt + mv + j` (3–4 insns + branch mispredict) |
| `sext.b / sext.h / zext.h` | Sign/zero extend | `slli + srai` (2 insns) |
| `andn / orn / xnor` | AND-NOT, OR-NOT, XNOR | 2 insns |
| `rev8` | Byte-reverse (endian swap) | 8+ insns |
| `orc.b` | Byte-wise OR-combine | multiple insns |
| `rol / ror / rori` | Rotate left/right | `sll + srl + or` (3 insns) |

RTL: ~150 lines (CLZ/CTZ share priority-encoder; min/max = comparator
+mux; rotates = barrel-shifter extension). Expected: **+3–5% IPC**.

### 2.3 Zbs — Single-Bit Operations

| Instruction | Operation | Replaces |
|---|---|---|
| `bset / bseti` | Set bit N | `li + sll + or` (3 insns) |
| `bclr / bclri` | Clear bit N | 3 insns |
| `binv / binvi` | Invert bit N | 3 insns |
| `bext / bexti` | Extract bit N (→ 0 or 1) | 2 insns |

RTL: ~30 lines (single-bit shift-and-mask in ALU). Expected: **+1% IPC**.

### 2.4 Zicond — Conditional Operations

| Instruction | Operation | Replaces |
|---|---|---|
| `czero.eqz rd, rs1, rs2` | `rd = (rs2 == 0) ? 0 : rs1` | `beqz + mv` (branch + move) |
| `czero.nez rd, rs1, rs2` | `rd = (rs2 != 0) ? 0 : rs1` | `bnez + mv` (branch + move) |

Eliminates short branches on data-dependent selects. Each eliminated
branch removes a potential misprediction (~15 cycle penalty).

RTL: ~20 lines (comparator + mux in ALU). Expected: **+2–3% IPC**.

### 2.5 Combined ISA Extension Impact

| Extension | RTL cost | IPC impact |
|---|---|---|
| Zba | ~50 lines | +5–8% |
| Zbb | ~150 lines | +3–5% |
| Zbs | ~30 lines | +1% |
| Zicond | ~20 lines | +2–3% |
| **Total** | **~250 lines** | **~+10–15%** |

All extensions use the existing ALU pipeline — 1-cycle latency, fully
pipelined, no new FUs, no new pipeline stages. Only decoder + ALU
datapath additions.

Compiler flag: `-march=rv64gc_zba_zbb_zbs_zicond` (gcc 13.3 supports
all of these).

---

## 3. Macro-Op Fusion

### 3.1 Overview

Decode-stage pattern matching detects adjacent instruction pairs and
merges them into a single fused µop. The fused µop occupies one ROB
entry, one IQ entry, and one FU cycle — saving pipeline resources.

Fusion is **architecturally transparent** — the ISA is unchanged, the
processor still executes every individual instruction correctly. No
compiler support needed; gcc already emits these pairs because the
RISC-V ISA requires them for these operations.

### 3.2 Fusion Pairs

**Tier 1 — High frequency:**

| Pattern | Fused µop | Where it appears |
|---|---|---|
| `lui rd, imm` + `addi rd, rd, imm` | 32-bit immediate load | Every constant load |
| `auipc rd, imm` + `jalr ra, rd, imm` | PC-relative function call | Every function call |
| `auipc rd, imm` + `addi rd, rd, imm` | PC-relative address | Address-of globals |
| `auipc rd, imm` + `ld rd, imm(rd)` | PC-relative load | Global variable access |
| `auipc rd, imm` + `sd rs, imm(rd)` | PC-relative store | Global variable store |

**Tier 2 — Compare-and-branch:**

| Pattern | Fused µop | Where it appears |
|---|---|---|
| `slt rd, rs1, rs2` + `bne rd, x0` | Compare-and-branch (signed less-than) | Comparison branches |
| `sltu rd, rs1, rs2` + `bne rd, x0` | Compare-and-branch (unsigned) | Bounds checks |
| `slt` / `sltu` + `beq rd, x0` | Compare-and-branch (≥) | Inverted comparisons |
| `slti` / `sltiu` + `bne` / `beq` | Compare-immediate-and-branch | Loop bounds |

### 3.3 Binary Analysis — Actual Fusable Pairs

Counts from disassembly of existing binaries:

| Binary | Total static insns | Fusable pairs | Fusion rate |
|---|---|---|---|
| `coremark_iter1000.elf` | 2,523 | 147 (mostly `auipc+jalr`) | 5.8% static |
| `dhrystone.elf` (w/ glibc) | 92,966 | ~3,782 (mostly `auipc+addi/ld`) | 4.1% static |

Dynamic fusion rate varies by workload: ~1% on CoreMark (tight loop),
~3–4% on Dhrystone, **~10–15% on Linux boot** (call-heavy kernel code).

### 3.4 Implementation

**Fusion detector** (~300 lines): combinational pattern matcher at
decode output, checks each adjacent pair (i, i+1) for fusion
eligibility. At 6-wide, up to 5 pairs checked per cycle.

**Compaction network** (~100 lines): after fusion, shift remaining
µops to fill gaps left by fused pairs. Priority-shift network,
same topology as rename intra-group bypass.

**BRU enhancement** (~50 lines): execute fused compare-and-branch
in 1 cycle. The BRU performs comparison (SLT/SLTU) and branch
resolution (BEQ/BNE) in a single pipeline stage.

**µop format extension** (~20 bits/µop): fused flag, comparison type,
branch type, 32-bit fused immediate.

Total: **~500 lines**. No new FUs, no new pipeline stages.

### 3.5 Fusion Constraints

- Both instructions must be in the same fetch block (not split across
  cache lines)
- First instruction's `rd` must match second instruction's source
- `rd` must not be `x0`
- For compare-and-branch: second instruction's other operand must be `x0`
- Fusion is never attempted across taken-branch boundaries

---

## 4. Detailed Microarchitecture

### 4.1 Frontend — Fetch and Decode (6-wide)

Fetch delivers up to 6 instructions per cycle from a 64-byte fetch
buffer aligned to cache-line boundaries. The I-cache is 32 kB, 4-way,
with 1-cycle hit latency. RISC-V C-extension (16-bit) instructions
are handled at decode — the fetch buffer may contain more than 6
instructions when compressed instructions are present.

Decode expands C-extension instructions to their 32-bit equivalents,
detects and applies macro-op fusion (§3), and produces up to 6 decoded
µops per cycle. Stores are split into STA (store address) and STD
(store data) µops at decode.

### 4.2 Branch Predictor — TAGE-SC-L

**gem5 measured: +15.1% IPC on Dhrystone vs LTAGE.**

| Component | Entries | Purpose |
|-----------|---------|---------|
| TAGE base (bimodal) | 4K | Default prediction |
| TAGE tagged tables | 4 × 256, 12-bit tags | History-length-indexed prediction |
| Statistical corrector | ~2–4 KB | Corrects TAGE on correlated branches |
| Loop predictor | 64 entries | Exact loop iteration count prediction |
| BTB | 1024 × 4-way | Branch target cache |
| RAS | 24 entries | Return address stack |
| Indirect predictor | 256 × 2-way | Function pointer / vtable targets |

### 4.3 Rename — Per-Slot Independent Advance

Rename processes up to 6 µops per cycle. Each slot independently
checks resource availability and advances when ready:
- Free PRF entry available for this slot's destination
- ROB entry available
- Dispatch queue has space

Slots that cannot advance retain their valid bit. Decode fills only
cleared slots next cycle. There is **no group hold**.

**Intra-group bypass:** Slot N sees mappings from slots 0..N-1 via
combinational bypass. At 6-wide: 30 comparators (15 pairs × 2).

**Move elimination:** `mv rd, rs` → copy RAT pointer, mark ROB
complete at rename. `li rd, 0` / `xor rd, rd, rd` → map to zero
register, mark complete. No PRF allocation, no dispatch, no issue.

**Free list:** 256-bit bitmap, 6-wide priority-encoder scan, 0–6
allocations per cycle (incremental, not atomic).

### 4.4 Dispatch — 6-Wide

Dispatch queue: 32-deep int FIFO + 32-deep mem FIFO. Accepts up to 6
µops/cycle from rename, drains up to 6/cycle to IQs.

Round-robin IQ targeting with fallback. Each integer IQ has 2 enqueue
ports (worst case: 6 dispatched to 3 IQs, physically limited to 2/IQ
with 1-cycle staging latch for overflow).

### 4.5 Issue Queues — Dual-Select, 32 Entries

Each of 3 integer IQs: 32 entries, 2 select ports. Issues up to 2
instructions per IQ per cycle to 2 different FUs.

**Selection:** Oldest-ready by ROB distance. Second port excludes
first port's winner.

**Speculative wakeup:**
- ALU (1-cycle): wake dependents at issue
- MUL (3-cycle): wake dependents 2 cycles after issue
- Load (1-cycle hit): wake at AGU, cancel + replay on miss

**Wakeup width:** 6 CDB tags/cycle. Each entry's rs1/rs2 matches
against all 6 — most timing-critical logic in the design.

**Total integer issue:** up to 4/cycle across 3 IQs (PRF 12R limit).

### 4.6 Physical Register File — 256 × 64-bit, 12R6W

| Port | Assignment |
|------|------------|
| Read [0:1] | EX0 (ALU0 rs1, rs2) |
| Read [2:3] | EX1 (ALU1 rs1, rs2) |
| Read [4:5] | EX2 (ALU2/MUL rs1, rs2) |
| Read [6:7] | EX3 (ALU3/DIV rs1, rs2) |
| Read [8:9] | MEM (Ld0 rs1, Ld1 rs1) |
| Read [10:11] | MEM (StA rs1, StD data) |
| Write [0] | ALU0/BRU |
| Write [1] | ALU1 |
| Write [2] | ALU2/MUL |
| Write [3] | ALU3/DIV |
| Write [4] | Load 0 |
| Write [5] | Load 1 / FP (deferral on contention) |

6 register-file copies (ASIC-style flip-flop arrays), each 2 read
ports. All 6 write ports broadcast. Write-first bypass.

### 4.7 Bypass Network

ALU0–3 (end of EX1), MUL (end of EX3), Load (end of cache stage) →
bypass to EX1 input next cycle.

Per int issue port: 2 operands × 6 bypass sources = 12 comparators.
4 issue ports total: 48 tag comparators + 48 × 64-bit muxes.
Critical timing path.

### 4.8 Memory Subsystem

**L1 D-cache:** 64 kB, 4-way, 4-bank by `addr[4:3]`. 1-cycle hit/bank.
2 load + 1 store port. Bank conflict → 1-cycle replay.

**L1 I-cache:** 32 kB, 4-way, 64-byte lines, 1-cycle hit.

**L2 cache:** 2 MB, 8-way, 8-cycle hit, 32 MSHRs.

**LQ:** 48 entries. Store-to-load ordering violation detection.

**SQ:** 48 entries. STA/STD split fill. Byte-level forwarding CAM.

**Committed store buffer:** 24 entries. Drains to D-cache in order.

### 4.9 Reorder Buffer and Commit — 192 Entries, 6-Wide

192-entry circular buffer. 6-wide commit.

**Checkpoint recovery (4 checkpoints):**

Each checkpoint:
- Integer RAT: 32 × 8-bit = 256 bits
- FP RAT: 32 × 7-bit = 224 bits
- Free-list bitmap: 256 bits
- ROB tail: 8 bits
- Total per ckpt: 744 bits. Total: 4 × 744 = **2,976 bits** (372 bytes)

Allocate checkpoint at every predicted-taken branch. Restore on
mispredict (preserves speculative work between commit and branch).

**Squash:** 1-cycle combinational, 8 entries/cycle. Pipeline restarts
from checkpoint immediately; ROB clears in background.

**Mispredict penalty:** ~6 cycles (v1: ~9 cycles).

### 4.10 Loop Buffer — 64-Entry Decoded µop Cache

64-entry µop FIFO. Captures hot loop body when backward taken branch
detected and body fits. Feeds rename directly, bypassing fetch+decode.
Delivers up to 6 µops/cycle. Clock-gates frontend during playback.

---

## 5. Compiler Build Recipe

### 5.1 Standard Flags

```bash
CFLAGS="-O3 \
        -march=rv64gc_zba_zbb_zbs_zicond \
        -mabi=lp64d \
        -mtune=generic \
        -flto \
        -funroll-loops \
        -fomit-frame-pointer"
```

### 5.2 Profile-Guided Optimization (for peak performance)

```bash
# Pass 1: instrument
gcc $CFLAGS -fprofile-generate -o bench bench.c
./bench   # run on v2 RTL or gem5
# Pass 2: optimize with profile
gcc $CFLAGS -fprofile-use -o bench bench.c
```

Expected: +10–20% IPC from PGO alone (better code layout, branch
hints, selective unrolling).

### 5.3 Linker Relaxation

Use `-mrelax` (default) for statically-linked binaries. The linker
converts `auipc+jalr` → `jal` when target is within ±1MB, directly
reducing instruction count without fusion.

Note: v1's CoreMark used `-mno-relax` (required for freestanding SE
startup). v2 kernel and userspace should use `-mrelax`.

---

## 6. gem5 Study Evidence

### 6.1 v1 Baseline (Audited from RTL, 2026-04-05)

| Parameter | Audited value | Source |
|-----------|---------------|--------|
| Width | 4-wide fetch/decode/rename/commit, **2-wide dispatch/issue** | `rv64gc_pkg.sv:23-24`, `rv64gc_core_top.sv:792` |
| Int PRF | **120** × 64-bit (doc said 96) | `rv64gc_pkg.sv:28` |
| ROB | **120** entries (doc said 96) | `rv64gc_pkg.sv:33` |
| Int IQs | 3 × 32, 1 select port each | `rv64gc_pkg.sv:45`, `issue_queue.sv:312` |
| Rename | Group hold (entire bundle stalls) | `rename.sv:71-75` |
| Recovery | Architectural RAT, 2-cycle shadow flush | `rename.sv:631`, `commit.sv:311` |
| CoreMark IPC | **0.472** | RTL measurement |
| Linux boot IPC | **~0.13** | RTL measurement (avg over full boot) |

### 6.2 v1 Bottleneck Profile

| Counter | Value | What it means |
|---------|-------|---------------|
| rename_stall | 68.38% | Dominant bottleneck |
| hold_valid | 56.88% | Group-hold burns most rename cycles |
| ROB_head_blocked | 49.68% | Oldest instruction stuck waiting |
| ROB_head_other | 61.57% of blocked | IQ partition + select contention |
| fetch_stall | 11.87% | Minor |
| mem_load_blocked | 1.07% | Memory is NOT the bottleneck |

### 6.3 gem5 Sweep Summary

| Sweep | Key finding |
|-------|-------------|
| Designed-config 6w | IPC 2.873 CoreMark / 3.233 Dhrystone (realistic FU, LTAGE, 1c L1) |
| Innovation (TAGE-SC-L) | +15.1% Dhrystone IPC vs LTAGE |
| Innovation (prefetcher) | +0.0% on both workloads |
| Innovation (decoupled FE) | –23% (gem5 25.1 bug, do not trust) |
| Advanced (11 variants) | No innovation moves CoreMark past 3.15 at 6-wide |
| Corrected (PRF=384) | 19M PRF stalls eliminated, +0.025 IPC only |
| **ROB sensitivity** | **192 is the knee. 256/320/384 = zero gain.** |

### 6.4 Bottleneck Analysis at gem5 Ceiling (6-wide, ROB=320, IPC=3.125)

| Bottleneck | Cycles | % | Actionable? |
|---|---|---|---|
| Rename running (useful work) | 69.7M | 60.4% | — |
| **Rename unblocking** | **33.4M** | **28.9%** | PRF/LQ exhaustion → fixed by proper PRF sizing |
| Rename idle (starved by fetch) | 11.7M | 10.1% | Frontend BW ceiling: taken branches end fetch blocks |
| IntALU FU busy | 20.5M events | 89% of FU-busy | Symptom, not cause — 5th ALU gains +0.000 IPC |
| Branch MPKI | 0.20 | — | Excellent — TAGE-SC-L working correctly |
| L1I miss | 70K cycles | 0.06% | Negligible on CoreMark |

### 6.5 gem5 Accuracy

gem5 O3 predicts real silicon IPC within 10–15% when properly
configured (Butko 2012, Akram & Sawalha 2019). v1's 80% gap (0.47
vs 2.45) was due to four implementation artifacts, not gem5 error.
Clean v2 implementation: 85–90% of gem5 ceiling.

---

## 7. Performance Targets

```
                     CoreMark IPC    Dhrystone IPC
                     ────────────    ─────────────
v1:                     0.47            ~0.13 (Linux boot)
gem5 ceiling:           3.15            3.92

(before ISA ext / fusion / compiler opts)
TARGET:                 2.5             3.2         (79% of gem5)
Minimum:                2.0             2.5         (63% of gem5)

(after ISA ext + fusion + -O3 -flto + PGO)
EXPECTED:              ~3.0            ~3.8         (+20% from SW stack)
```

The ISA extensions (Zba/Zbb/Zbs/Zicond), macro-op fusion, and compiler
optimizations (-O3, -flto, PGO) add ~20–30% effective IPC on top of
the microarchitecture alone. With these, the 3.0 stretch target becomes
the expected outcome, not a stretch.

**Linux boot IPC estimate: 0.8–1.5** (vs v1's 0.13). Lower than
CoreMark due to cold caches, TLB walks, indirect branches. L1 I-cache
(absent in v1) is the single biggest Linux boot win.

### 7.1 Measurement Counters

| Counter | v1 | Target |
|---------|-----|--------|
| **IPC** | **0.472** | **>2.5 (expect ~3.0 with full SW stack)** |
| avg rename / cycle | 0.643 | >4.5 |
| hold_valid | 56.88% | <2% |
| rename_stall | 68.38% | <10% |
| ROB_head_blocked | 49.68% | <10% |
| ROB_head_other | 61.57% of blocked | <10% |
| fetch_stall | 11.87% | <2% |
| avg commit / cycle | 0.472 | >2.5 |

---

## 8. What NOT to Do

- Do not go 8-wide. gem5: 6w→8w = +5% for ~50% more area.
- Do not grow ROB beyond 192. Sweep: 192→320 = +0.05% for +67% area.
- Do not add more than 4 ALUs. Sweep: 5th ALU = +0.000 IPC.
- Do not grow L1 beyond 64kB or L2 beyond 2MB. Sweep: zero gain.
- Do not add a stride prefetcher for benchmarks. Sweep: zero gain.
- Do not use a perceptron predictor. gem5: –20% regression on RISC-V.
- Do not implement RVV (vector extension) in v2. Scope for v3.

---

## 9. Future Optimizations (v3 scope)

| Innovation | Impact | When |
|---|---|---|
| µop cache (1K+ entries, replaces loop buffer) | +5–10% | If fetch_stall >2% on real code |
| Value prediction | +10–20% | If ROB-head load class stays high |
| Clustered backend | Fmax improvement | If timing closure is the constraint |
| Hardware prefetcher (stride/stream) | +5–15% on Linux | When targeting memory-heavy workloads |
| RVV (vector extension) | +50–100% on data-parallel | v3 feature |
| 8-wide pipeline | +5% scalar IPC | Only after 6-wide ceiling proven |

---

## 10. v1 Reference

| v1 File | v1 Value | v2 Change |
|---------|----------|-----------|
| `rv64gc_pkg.sv` | RENAME_WIDTH=4, ROB=120, PRF=120, IQ=32, LQ/SQ=24 | Width→6, ROB→192, PRF→256, LQ/SQ→48 |
| `rename.sv` | Group-hold (lines 71-75) | Per-slot advance + move elimination |
| `rv64gc_core_top.sv` | 2-wide dispatch (lines 757-802) | 6-wide dispatch |
| `issue_queue.sv` | 1 select port (lines 312-336) | 2 select ports + spec wakeup |
| `commit.sv` | 2-cycle shadow flush (lines 311-341) | 1-cycle combinational + checkpoint |
| `int_prf.sv` | 120×64, 8R4W | 256×64, 12R6W |
| `rob.sv` | 120 entries | 192 entries |
| `tage_bpu.sv` | TAGE (bimodal + 4 tagged) | TAGE-SC-L |
| `btb.sv` | 256×4-way | 1024×4-way |
| `dcache.sv` | 32kB, 4-way, single-port | 64kB, 4-way, 4-bank |
| `fetch_unit.sv` | No I-cache | 32kB I-cache |
| Decoder | RV64IMAFDC only | + Zba + Zbb + Zbs + Zicond + fusion |

# RV64GC v2 Microarchitecture Specification

**Status:** CURRENT (4-wide OoO implementation; supersedes original 6-wide spec)
**Last revised:** 2026-05-02
**Repo HEAD at revision:** `master @ a6a0443`
**Authoritative sources:** `src/rtl/core/include/rv64gc_pkg.sv` (parameters); `src/rtl/core/rv64gc_core_top.sv` (top-level wiring); per-module RTL.

> ## ⚠ Major revision history
>
> The original v2 spec described a **6-wide OoO** target. After the
> 2026-04-25 design pivot (`doc/4wide_pivot_plan_2026-04-25.md`), the
> design was narrowed to **4-wide** in 5 staged refactors. The
> Stage-2 Load1-bypass functional bug was diagnosed and fixed at
> commit `cd54cf1`. Five follow-up gap-closure cycles (A, C, B, E, F)
> all REFUTED with data; design is structurally well-tuned for the
> current parameter point.
>
> **Final sign-off:** PARTIAL-FLOOR (`doc/4wide_signoff_2026-05-01.md`) —
> functional 20/20 PASS, clockcheck 3/3 PASS, cm iter1 5.01 CM/MHz,
> cm iter10 5.37 CM/MHz, dhrystone 2.42 DMIPS/MHz.

---

## 1. Design Overview

### 1.1 ISA

`rv64imafdc_zba_zbb_zbs_zicond_zicsr_zifencei`

- **Base:** RV64I (64-bit integer)
- **M:** integer multiply/divide
- **A:** atomics
- **F+D:** single+double-precision FP (path implemented; FP perf is not the focus)
- **C:** compressed instructions (RVC)
- **Zba:** address generation (`sh1add`, `sh2add`, `sh3add`, `.uw` variants)
- **Zbb:** bit manipulation (clz, cpop, min, max, etc.)
- **Zbs:** single-bit operations
- **Zicond:** conditional zero (`czero.eqz`, `czero.nez`)
- **Zicsr:** control/status registers
- **Zifencei:** instruction-fetch fence

### 1.2 Pipeline Width (4-wide superscalar)

| Parameter | Value | Notes |
|---|---|---|
| `PIPE_WIDTH` | **4** | fetch / decode / rename / dispatch / commit |
| `FETCH_WIDTH` | 4 | |
| `DECODE_WIDTH` | 4 | |
| `RENAME_WIDTH` | 4 | per-slot independent advance (no group-hold) |
| `DISPATCH_WIDTH` | 4 | route per `fu_type` to one of 6 IQs |
| `COMMIT_WIDTH` | 4 | in-order; in-window prefix of ready uops |
| `FETCH_BYTES` | 16 | 4 × 4-byte ALIGN slots (RVC handled in decompress) |

### 1.3 Performance Targets vs Achieved (current)

| Metric | Target (MegaBoom 4-wide floor) | Stretch (Cortex-A72) | Achieved |
|---|---:|---:|---:|
| CoreMark CM/MHz (iter1) | ≥ 6.2 | ≥ 8.24 | **5.01** |
| CoreMark CM/MHz (iter10) | ≥ 6.2 | ≥ 8.24 | **5.37** |
| Dhrystone DMIPS/MHz | ≥ 4.00 | ≥ 4.72 | **2.42** |

### 1.4 Top-Level Pipeline Diagram

```
                              FRONT-END (4-wide, ~5 stages incl. UOC bypass)
   ┌───────┐  ┌─────────────┐  ┌──────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐
   │  PC   │  │  IF1 / IF2  │  │  PRED2   │  │  DECODE │  │ FUSION  │  │  RENAME │
   │       │  │  L1I + ITLB │  │  TAGE-SC │  │         │  │ DETECT  │  │  + RAT  │
   │ +BTB  │→ │  +UOC bypass│→ │  +RAS    │→ │ 4-wide  │→ │ + LB    │→ │  + free │
   │ +TAGE │  │  +NLP fetch │  │  +update │  │ + RVC   │  │ + emit  │  │   list  │
   │ +RAS  │  │             │  │          │  │ decomp  │  │         │  │ +ckpt   │
   └───────┘  └─────────────┘  └──────────┘  └─────────┘  └─────────┘  └─────────┘
                                                                            │
                                                                            ▼
                                                                  ┌────────────────┐
                                                                  │  DISPATCH (4w) │
                                                                  │  per fu_type → │
                                                                  │  6 IQs total   │
                                                                  └────────────────┘
                                                                            │
                                                                            ▼
                                       BACK-END
                            ┌───────────────────────────────────┐
                            │  6 IQs total:                     │
                            │   3 INT IQs (24 entries each)     │
                            │   1 LD IQ  (32 entries)           │
                            │   1 STA IQ (32 entries)           │
                            │   1 STD IQ (32 entries)           │
                            └────────────┬──────────────────────┘
                                         │  4 INT issue ports + 2 LD + 1 STA + 1 STD
                                         ▼
                            ┌───────────────────────────────────┐
                            │  EXECUTE                          │
                            │   4× ALU (combinational, 1 cycle  │
                            │       issue→cdb)                  │
                            │   2× BRU (1 cycle)                │
                            │   1× MUL (1 cycle hw latency)     │
                            │   1× DIV (multi-cycle FSM)        │
                            │   1× CSR (serializing)            │
                            │   LSU: 2 LD AGU + 1 STA AGU + 1   │
                            │       STD path; 2-stage dcache    │
                            │       (S0/S1)                     │
                            │  Bypass network: 5 sources        │
                            │   [0..2] CDB[0..2] (registered)   │
                            │   [3]    Load0 wb (combinational) │
                            │   [4]    Load1 wb (combinational) │
                            │   (NOTE: ALU3 was tested in       │
                            │    Cycle E; REFUTED; reverted)    │
                            └────────────┬──────────────────────┘
                                         │
                                         ▼ CDB_WIDTH=4 + load_wb 2-port sideband
                            ┌───────────────────────────────────┐
                            │  WRITEBACK + PRF                  │
                            │   INT PRF: 160 × 64-bit           │
                            │     12R6W (6 wr = 4 CDB + 2       │
                            │     load_wb sideband)             │
                            │   FP PRF:  96 × 64-bit            │
                            └────────────┬──────────────────────┘
                                         │
                                         ▼
                            ┌───────────────────────────────────┐
                            │  ROB (128 entries) + COMMIT (4w)  │
                            │   in-order, head-prefix commit    │
                            │   head_wb_bypass: same-cycle      │
                            │     wb→commit if head ready       │
                            └───────────────────────────────────┘
```

---

## 2. Front-End

### 2.1 Fetch Unit (`src/rtl/core/fetch/fetch_unit.sv`)

- **Width:** 16 bytes/cycle (`FETCH_BYTES = 16`); up to 4 instructions (RVC: up to 8 if all compressed)
- **Pipeline:** 2 stages (IF1: PC gen + L1I tag/data probe + BPU lookup; IF2: way mux + predecode)
- **PC redirect sources** (priority order):
  1. Reset / external
  2. Commit-time flush (full architectural flush from ROB on mispredict reaching commit)
  3. BRU early redirect (mechanism present but plusarg-gated OFF by default — Cycle C REFUTED enabling it)
  4. BPU redirect (taken-branch BTB+TAGE prediction)
  5. Sequential PC + 16
- **L1I:** see §11
- **Stall sources:** I-cache miss, pipeline backpressure (FTQ full / packet buffer full / rename stall), wait-for-Icresp, NLP miss

### 2.2 BPU: TAGE-SC-L (`src/rtl/core/fetch/tage_sc_l.sv`)

- **Bimodal base table:** 4096 entries (`TAGE_BASE_ENTRIES`)
- **Tagged tables:** 4 tables × 256 entries each (`TAGE_NUM_TABLES=4`, `TAGE_TABLE_ENTRIES=256`), 12-bit tags
- **Statistical Corrector (SC):** 1024 entries
- **Loop predictor:** 64 entries (`LOOP_PRED_ENTRIES=64`)
- **GHR:** 64 bits (`GHR_BITS=64`)
- **Per-PC mispredict instrumentation** (`+PERF_PROFILE`): top mispredict PCs reported at end of run
- **Comparison vs BOOM v4 MegaBoom:** rv64gc-v2's BPU is BIGGER in most dimensions (8× BTB, has SC that BOOM-default lacks, larger TAGE tags). See `doc/4wide_iter_uBTB_results.md` for the full audit.

### 2.3 BTB (`src/rtl/core/fetch/btb.sv`)

- **Geometry:** 2048 entries, 8-way set-associative, 256 sets (`BTB_ENTRIES=2048`, `BTB_WAYS=8`, `BTB_SETS=256`)
- **Indexed by:** cache-line address; per-line stores byte offset of each control-flow site
- **Replacement:** round-robin per set
- **Read latency:** combinational (same cycle as fetch)
- **Lookup output:** primary hit + alternate hit (for two control transfers in same line)

### 2.4 RAS (`src/rtl/core/fetch/ras.sv`)

- **Depth:** 24 (`RAS_DEPTH`)
- **Push:** call instructions at predict time
- **Pop:** ret instructions at predict time
- **Restore:** on flush, RAS depth is restored from checkpoint

### 2.5 NLP — Next-Line Prefetch Buffer (`src/rtl/core/fetch/next_line_prefetch_buffer.sv`)

- **Entries:** 4 (`NUM_ENTRIES=4`)
- **Purpose:** small prefetch buffer for sequential-access lines (warm-cache helper, not primary predictor)

### 2.6 µop Cache (UOC) (`src/rtl/core/fetch/uop_cache.sv`)

- **Geometry:** 32 sets × 8 ways × 4 µops/entry = 1024 µop slots (`UOC_SETS=32`, `UOC_WAYS=8`, `UOC_PER_ENTRY=PIPE_WIDTH=4`)
- **Indexed by:** fetch-group start PC
- **Replacement:** tree-pLRU (7-bit per set)
- **Bring-up:** UOC is opt-in via `+UOC_ENABLE` plusarg (gen-2 design; loop buffer remains primary)
- **Comparison:** modeled after Intel DSB / AMD Zen op-cache / ARM Mop-cache
- **Status:** functional 21/21 PASS, ~0% IPC win on 6-wide measurements; ports cleanly to 4-wide

### 2.7 Loop Buffer (`src/rtl/core/loop_buffer.sv`)

- **Depth:** 64 entries (`LOOP_BUF_DEPTH`)
- **Activation:** detected backward branches with body ≤ 64 entries enter LB-replay mode
- **Exit prediction:** instrumented with exit_pred_learn/use/bad counters
- **Forward-progress monitor:** tracks `commit_no_load` cycles to prevent stuck states
- **Known structural concern:** the prior 6-wide spec flagged a CDB→bypass→AGU→fwd→CDB delta-cycle loop class triggered by LB lifecycle interactions. The current 4-wide RTL has not surfaced this issue post-cd54cf1, but the LB→bypass interface remains a watchpoint.

### 2.8 Decode (`src/rtl/core/decode/decode.sv`, `decode_slice.sv`)

- **Width:** 4 slices/cycle
- **RVC handling:** `rvc_decompress.sv` expands compressed to 32-bit equivalents pre-decode
- **Output:** 4 decoded uops with `fu_type` (ALU/BRU/MUL/DIV/LOAD/STA/STD/CSR), source/dest arch regs, immediate, control flags

### 2.9 Fusion Detector (`src/rtl/core/decode/fusion_detector.sv`)

- **Adjacent-pair fusion** at decode (e.g., `auipc + addi` → `LI64`)
- **Status:** detection logic present; commit_count statistics in PERF_PROFILE include fused vs non-fused breakdown

### 2.10 Frontend Queues

- **FTQ (Fetch Target Queue):** 24 entries (`FTQ_DEPTH=24`), 16-bit alloc tag
- **Fetch packet buffer** (`fetch_packet_buffer.sv`): between IF2 and decode; absorbs decode backpressure

---

## 3. Rename + Map Tables + Free List + Checkpoints

### 3.1 Rename (`src/rtl/core/rename/rename.sv`)

- **Width:** 4 slots/cycle
- **Per-slot independent advance:** each slot can stall independently without holding back others (eliminates the 6-wide group-hold artifact)
- **Move/zero elimination:** `mv rd, rs1`, `addi rd, rs1, 0`, `xor rd, rd, rd`, `li rd, 0` are eliminated at rename — bypassed to commit without consuming FU/IQ resources
- **Stall reasons** (per-slot, instrumented in `+PERF_PROFILE` rename summary):
  - `has_preg=0`: free list empty (pdst allocation)
  - `has_rob=0`: ROB full
  - `has_ckpt=0`: checkpoint pool full
  - `has_lq=0`: LQ full (loads only)
  - `has_sq=0`: SQ full (stores only)
  - `has_dq=0`: dispatch queue full

### 3.2 RAT — Register Alias Table (`src/rtl/core/rename/rat.sv`)

- **Speculative RAT:** 32 entries (one per arch reg), maps arch → phys
- **Committed RAT (cRAT):** 32 entries, updated only at commit; restore source on flush
- **Per-slot read/write ports for 4-wide rename**

### 3.3 Free List (`src/rtl/core/rename/free_list.sv`)

- **Mechanism:** bitmap-based, 128-bit (`INT_FREE_LIST_DEPTH = INT_PRF_DEPTH - ARCH_REGS = 128`)
- **Allocation:** up to 4 pdsts per cycle from priority encoder over free bitmap
- **Release:** at commit (old pdst), or at flush (full restore from committed bitmap)
- **Min-popcount sampling:** instrumented to track underutilization

### 3.4 Checkpoints (`src/rtl/core/rename/checkpoint.sv`)

- **Capacity:** 64 checkpoints (`NUM_CHECKPOINTS=64`)
- **Allocation:** at branch rename time
- **Restore:** at BRU mispredict (full pipeline rewind to checkpoint state); also fires on commit-time architectural flush
- **Instrumentation:** save/release counts, max-occupied, full-pre-release vs full-after-release cycles

---

## 4. Dispatch

### 4.1 Decode/Dispatch Queues

- **Decode queue:** 32 entries (`DECODE_QUEUE_DEPTH=32`); buffers decoded uops between rename and dispatch
- **DQ_INT:** 32 entries (`DQ_INT_DEPTH=32`); INT-bound uops waiting to enter INT IQs
- **DQ_MEM:** 32 entries (`DQ_MEM_DEPTH=32`); LD/STA/STD waiting for LSU IQs
- **DQ_FP:** 16 entries (`DQ_FP_DEPTH=16`); FP-bound uops

### 4.2 Routing per fu_type → IQ

`uarch_pkg::fu_type_e`:

- `FU_ALU=0` → INT IQ (which IQ depends on dispatch routing — see §5.1)
- `FU_BRU=1` → INT IQ (typically u_iq0)
- `FU_MUL=2` → INT IQ u_iq1 (co-located with ALU2)
- `FU_DIV=3` → INT IQ u_iq2 (co-located with ALU3+CSR)
- `FU_LOAD=4` → MEM IQ u_iq_ldst (load)
- `FU_STA=5` → MEM IQ u_iq_st_addr (store address)
- `FU_STD=6` → MEM IQ u_iq_st_data (store data)
- `FU_CSR=7` → INT IQ u_iq2 (co-located with ALU3+DIV)

The dispatch routing is in `src/rtl/core/dispatch/dispatch_queue.sv`.

---

## 5. Issue + Wakeup + Speculative Wakeup

### 5.1 Issue Queues

**6 IQs total**, parameterized by `issue_queue` module (`src/rtl/core/issue/issue_queue.sv`):

| IQ | Depth | NUM_ENQUEUE | NUM_SELECT | FUs served |
|---|---:|---:|---:|---|
| `u_iq0` | 24 | 2 | **2** | ALU0 + ALU1 + BRU0 + BRU1 |
| `u_iq1` | 24 | 2 | 1 | ALU2 + MUL |
| `u_iq2` | 24 | 2 | 1 | ALU3 + DIV + CSR |
| `u_iq_ldst` | 32 | 2 | 2 | Load AGU (2 ports: Load0 + Load1) |
| `u_iq_st_addr` | 32 | 2 | 1 | Store address AGU |
| `u_iq_st_data` | 32 | 2 | 1 | Store data |

- **Total INT IQ capacity:** 72 entries (3×24); **total LSU IQ capacity:** 96 entries (3×32)
- **Max INT issue per cycle:** 4 (2+1+1)
- **Max LSU issue per cycle:** 4 (2 LD + 1 STA + 1 STD)
- **Theoretical peak:** 8 issues/cycle, but commit width is 4

### 5.2 Wakeup Network (`src/rtl/core/issue/wakeup_network.sv`)

- **CDB wakeup ports:** 4 (each IQ entry CAM-matches 4 CDB tags)
- **Load_wb wakeup ports:** 2 (Load0, Load1 — definitive wakeup, combinational)
- **Spec wakeup ports:** 2 (Load0, Load1 — fired at AGU time, 1 cycle BEFORE wb, allows consumer issue back-to-back with load wb on cache hit)

### 5.3 Speculative Wakeup Mechanism

For loads on cache hit:
- T: load AGU computes address → spec_wakeup fires → IQ marks load's pdst as ready
- T+1: load result on dcache S1 → wb fires → load_wb sideband broadcasts pdst+data
- T+1: consumer wakes via spec_wakeup, eligibility set
- T+2: consumer issues, reads operand via combinational bypass slot[3]/[4] (Load0/Load1)
- T+2: PRF write hasn't latched (will at T+3 edge), so bypass IS the only source

Cancellation: if cache miss, spec_wakeup is canceled; consumer must wait for actual wb.

### 5.4 Issue Selection Policy

Per `issue_queue.sv`:
- **Eligibility:** `entry_valid AND src1_ready AND src2_ready` (combinational from `next_src*_ready`)
- **Port 0:** oldest eligible entry (minimum ROB age)
- **Port 1:** second-oldest eligible entry (excluding port 0 winner)

---

## 6. Execute

### 6.1 Functional Units

| FU | Module | Count | Hardware Latency | Pipelined? | CDB slot |
|---|---|---:|---:|---|---|
| ALU0 | `alu.sv` | 1 | 0 (combinational) | N/A | CDB[0] |
| ALU1 | `alu.sv` | 1 | 0 | N/A | CDB[1] |
| ALU2 | `alu.sv` | 1 | 0 | N/A | CDB[2] (shared with MUL) |
| ALU3 | `alu.sv` | 1 | 0 | N/A | CDB[3] (shared with DIV+CSR) |
| BRU0 | `bru.sv` | 1 | 1 cycle | N/A | CDB[0] (shared with ALU0) |
| BRU1 | `bru.sv` | 1 | 1 cycle | N/A | CDB[1] (shared with ALU1) |
| MUL | `multiplier.sv` | 1 | 1 cycle | combinational + reg | CDB[2] |
| DIV | `divider.sv` | 1 | multi-cycle FSM (~30+ cyc) | No | CDB[3] |
| CSR | `csr_file.sv` | 1 | serializing (multi-cycle) | No | CDB[3] |

**Note on ALU latency:** ALU is purely combinational. The "1 cycle issue→cdb" latency comes from the registered CDB stage between execute and the bypass/PRF write.

**Note on stale `MUL_LATENCY` parameter:** `rv64gc_pkg.sv` declares `MUL_LATENCY = 3`, but the actual `multiplier.sv` is 1-cycle (per its source comment "Latency from valid_in to valid_out is now 1 cycle"). The `MUL_LATENCY` parameter may be a stale wakeup-scheduling hint; needs investigation.

### 6.2 Bypass Network (`src/rtl/core/bypass_network.sv`)

`NUM_BYPASS_SRCS = 5` slots:

| Slot | Source | Timing |
|---|---|---|
| [0] | `cdb_data_r[0]` (ALU0/BRU0) | Registered (1-cycle delay) |
| [1] | `cdb_data_r[1]` (ALU1/BRU1) | Registered |
| [2] | `cdb_data_r[2]` (ALU2/MUL) | Registered |
| [3] | `load_wb_data[0]` (Load0) | **Combinational** (0-cycle) |
| [4] | `load_wb_data[1]` (Load1) | **Combinational** — added at `cd54cf1` to fix Stage 2 cm bug |

**ALU3/DIV/CSR (CDB[3]) is NOT bypassed.** Cycle E tested adding bypass[5]=cdb_r[3] and measured 0% IPC impact (REFUTED). Consumers of CDB[3] producers fall back to PRF read at T+3 (1 extra cycle vs bypass).

The bypass mux at each ALU operand selects between PRF read result and any matching bypass source.

### 6.3 Critical Bypass Timing Note

For LOADS [slot 3, 4] — combinational bypass is REQUIRED:
- Spec wakeup fires consumer at T+2
- PRF write doesn't latch until T+3
- Without combinational bypass at T+2, consumer reads stale PRF → spurious result

This was the Stage 2 cm functional bug (NUM_BYPASS_SRCS shrunk 6→4 with only Load0 restored, leaving Load1 with wakeup but no bypass → consumers read stale PRF → BPU mistraining cascade → 11× cm runtime). Fixed at `cd54cf1`.

---

## 7. Load/Store Unit

### 7.1 Module Structure

- `lsu.sv`: top-level LSU (AGU, dcache request, load wb path, store-forward, replay)
- `load_queue.sv` (LQ): 32 entries (`LQ_DEPTH=32`)
- `store_queue.sv` (SQ): 32 entries (`SQ_DEPTH=32`)
- `committed_store_buffer.sv` (CSB): 32 entries (`CSB_DEPTH=32`); committed-but-not-drained stores

### 7.2 Load Pipeline

- **Issue → AGU (S0):** address computation in IQ select cycle
- **Tag/Data lookup (S1):** dcache 1 cycle (2-stage pipeline: S0 issue, S1 tag/data/way-select)
- **WB at T+2:** combinational bypass slot[3] or [4] active
- **2 load ports:** Load0 (port 0), Load1 (port 1)
- **Spec wakeup:** fires at AGU time (T+1) — consumer can issue at T+2 with combinational bypass

### 7.3 Store Pipeline

- **STA (store address):** 1 issue port, AGU computes address, allocates SQ entry
- **STD (store data):** 1 issue port, captures store data
- **Store-forward:** loads check SQ for matching address; full forward if size matches, partial forward if not

### 7.4 LMB / MSHR

- **L1D MSHR depth:** 16 (`L1D_MSHR_DEPTH=16`)
- **Allocation:** on dcache miss; subsequent loads to same line merge into existing MSHR

### 7.5 load_wb Sideband (Architectural Addition from Stage 2)

Originally CDB carried load writebacks (CDB[4]/[5] in 6-wide). When CDB shrank 6→4, loads needed a new path:
- Dedicated 2-port `load_wb` sideband (Load0, Load1)
- Each port has: pdst, data, valid signals
- Definitive wakeup port in IQs (`load_wb_wk_valid0/1`)
- Used for both bypass (slot 3, 4) and PRF write (PRF write port 4, 5)

**INT PRF write ports:** 4 (CDB) + 2 (load_wb sideband) = 6 total (`PRF_WRITE_PORTS=6`).

### 7.6 LSU iter=10 Misalign-Hold Patch (FROZEN)

`src/rtl/core/lsu/lsu.sv` contains a sign-off-class IPC win for cm iter=10 (misalign-hold special case). **This patch must NEVER be modified.** Documented in `AGENTS.md` and respected by all gap-closure cycles.

### 7.7 Per-Port LSU Pressure Counters (PERF_PROFILE)

- `ld0_candidate / ld0_issue / ld0_suppress`
- `ld1_candidate / ld1_issue / ld1_suppress`
- `sq_fwd_wait` (load waiting for store-forward)
- `storeIQ_block_ld0/1` (load blocked by store IQ activity)
- `p0/p1 same_cycle/csb_hit` (forwarding fast paths)
- `sq_wait_p1`, `p1_wait_req`, `p1_dcache_conflict`
- Load latency histogram (10 buckets: 0/1/2/3/4/5/6-7/8-15/16-31/32+)

---

## 8. Writeback + Common Data Bus + PRF

### 8.1 CDB

- **Width:** 4 (`CDB_WIDTH=4`)
- **Routing:**
  - CDB[0] ← ALU0 OR BRU0 (arbitrated)
  - CDB[1] ← ALU1 OR BRU1
  - CDB[2] ← ALU2 OR MUL
  - CDB[3] ← ALU3 OR DIV OR CSR
- **Registered:** CDB outputs are registered; consumers see results 1 cycle after wb fires (via bypass slot[0..2]) or 2 cycles later (via PRF read)

### 8.2 INT PRF (`src/rtl/core/regfile/int_prf.sv`)

- **Depth:** 160 (`INT_PRF_DEPTH=160`); 32 arch + 128 rename temps
- **Read ports:** 12 (3 ALU × 2 srcs + 2 BRU × 2 srcs + 1 MUL × 2 srcs = 14 demand, but tagged via bank/conflict logic to 12)
- **Write ports:** 6 (4 CDB + 2 load_wb)
- **Read latency:** 1 cycle (registered output)
- **p0 (zero) suppress:** PRF reads of p0 always return 0; CDB writes to p0 are suppressed

### 8.3 FP PRF

- **Depth:** 96 (`FP_PRF_DEPTH=96`)
- (FP path is implemented but not the focus of perf work)

---

## 9. Commit + ROB

### 9.1 ROB (`src/rtl/core/backend/rob.sv`)

- **Depth:** 128 entries (`ROB_DEPTH=128`)
- **Index bits:** 7 (`ROB_IDX_BITS=7`)
- **Per-entry state:**
  - Architectural rd, pdst, old_pdst
  - `wb_done` flag (set on CDB write or load_wb sideband)
  - `is_load`, `is_store`, `is_branch`, `is_csr`, `is_mul`, `is_div`, `is_bru` flags
  - `is_fence`, `is_fencei`, `is_mret`, `is_sret`, `is_sfence_vma`, `is_ecall`, `is_wfi` flags
  - PC (for trace), exception code

### 9.2 Commit (`src/rtl/core/backend/commit.sv`)

- **Width:** 4 (`COMMIT_WIDTH=4`)
- **Policy:** in-order, head-prefix
  - Read head + 3 next slots' `wb_done` flags
  - Commit count = consecutive ready uops starting from head
  - If head not ready: commit_count = 0
  - If head ready but slot 1 isn't: commit_count = 1
  - Etc.

### 9.3 Head WB Bypass (`rob.sv` instrumentation summary)

- **Same-cycle wb→commit bypass:** if head's CDB write happens in the same cycle as commit reads head_ready, the bypass forwards the result directly (saves 1 cycle of head-wait)
- **Per-slot bypass:** slot 1 / slot 2 also have wb-bypass paths (extends to commit-window prefix)
- **Per-class instrumentation:** load/store/branch/serial/other bypass-fire counts
- **For cm:** 17,470 head-load-wb-bypass fires + 46,440 head-arith-wb-bypass fires (active mechanism)

### 9.4 Head-Stall Instrumentation

- `rob_head_not_ready_cyc` (94k cycles for cm)
- Class breakdown: load/store/branch/serial/other
- Other-sub-class (added 2026-05-01): mul/div/csr/bru/unknown
- Per-PC head-stall sample table (top 32 PCs)

---

## 10. Cache Hierarchy

### 10.1 L1 I-Cache (`src/rtl/core/cache/icache.sv`)

| Param | Value |
|---|---|
| Size | 32 KB (`L1I_SIZE=32768`) |
| Associativity | 4-way (`L1I_WAYS=4`) |
| Sets | 128 (`L1I_SETS=128`) |
| Line size | 64 B (`LINE_SIZE=64`) |
| Hit latency | 1 cycle (registered S1 address) |
| MSHR | (not separately specified; uses inline state) |

### 10.2 L1 D-Cache (`src/rtl/core/cache/dcache.sv`, `dcache_data_ram.sv`, `dcache_tag_ram.sv`)

| Param | Value |
|---|---|
| Size | 64 KB (`L1D_SIZE=65536`) |
| Associativity | 4-way (`L1D_WAYS=4`) |
| Banks | 2 (`L1D_BANKS=2`) — was 4 pre-Stage-4 |
| Sets | 256 (`L1D_SETS=256`) |
| Line size | 64 B |
| Hit latency | **2 cycles total (S0 issue + S1 tag/data/way-select)** |
| Load-to-use | **3 cycles** (issue → AGU → S0 → S1 wb → consumer issue at T+2 via combinational bypass) |
| MSHR depth | 16 (`L1D_MSHR_DEPTH=16`) |
| Banking | Implicit via dual-port RAM (Stage-4 simplification) |

**Comparison vs BOOM v4:** rv64gc-v2 dcache is 2× bigger (64 KB vs typical 32 KB), 2× more MSHRs (16 vs 8), and 1-2 cycles FASTER load-to-use (~3 vs BOOM 4-5).

### 10.3 L2 Cache (`src/rtl/core/cache/l2_cache.sv`)

| Param | Value |
|---|---|
| Size | 2 MB (`L2_SIZE=2097152`) |
| Associativity | 8-way (`L2_WAYS=8`) |
| Sets | 4096 (`L2_SETS=4096`) |
| Hit latency | 8 cycles (`L2_HIT_LATENCY=8`) |
| MSHR depth | 32 (`L2_MSHR_DEPTH=32`) |

---

## 11. Performance Instrumentation

All gated on `+PERF_PROFILE` plusarg unless otherwise noted.

### 11.1 Per-Cycle Counters (Aggregated)

- **Stall breakdown:** rename_stall, backend_stall, rob_full, dq_full, lq_full, sq_full, iq{0,1,2}_full
- **Rename slot-attribution:** stall_{preg,ckpt,rob,dq,other}
- **Issue-stall classification (added 2026-05-01):** operand_not_ready, fu_contention, arb_loss
- **IQ avg occupancy:** iq{0,1,2}_avg
- **Flush count:** total + per-cause (mispredict, exception, replay, ret, interrupt)

### 11.2 Histograms

- **`commit_hist[0..6]`:** cycles where commit_count = N (the bubble distribution)
- **`fetch_hist[0..6]`:** cycles where fetch_count = N
- **`frontend_hist[0..6]`:** cycles where rename sees N instructions
- **`fused_hist[0..6]`:** non-LB cycles, fused_count distribution
- **`lb_replay_hist[0..6]`:** LB-active replay distribution
- **`load_lat_hist[10 buckets]`:** load issue-to-WB latency

### 11.3 ROB Head-Stall Detail (`rob.sv` final block)

- `rob_head_not_ready_cyc` (per-class: load/store/branch/serial/other)
- Other-sub-class: mul/div/csr/bru/unknown (added 2026-05-01)
- `rob_head_wb_bypass_cand_cnt` + per-class
- `rob_head_load_wb_bypass_fires`, `rob_head_arith_wb_bypass_fires`
- Slot1/Slot2 wb_bypass fires
- Top 32 head-not-ready PCs with class breakdown

### 11.4 LSU Pressure Detail

(See §7.7)

### 11.5 BPU Detail

- Top mispredict PCs with cond/jal/jalr/call/ret split + taken/not-taken
- Loop predictor hot-PC summary (per-PC lookup/hit/override counters)
- BPU hot-PC summary (per-table override counts)
- GHR / RAS restore counts

### 11.6 Per-Cycle Pipeline Trace (gated on `+TRACE_PIPELINE`)

`[PIPE schema=pipe.v1]` — emits per cycle:
- `cyc, rst, fetch, decode, rename, dispatch, issue0, issue1, issue2, cdb, commit`
- `rob_head, rob_tail, rob_cnt, iq0, iq1, iq2, lq, sq, free, ckpt`
- `flush, replay, reason`

Used by `tools/bubble_taxonomy.py` and `tools/headwait_deepdive.py` for per-cycle bubble classification.

### 11.7 Other Traces (gated on specific plusargs)

- `+TRACE_HEAD_STALL`: per-cycle head PC + flags
- `+TRACE_LOWPC`: per-uop tracking through fetch/decode/rename/dispatch/issue/commit
- `+TRACE_CM`: CoreMark-specific progress markers
- `[CPC]`, `[DEP schema=dep.v1]`: per-uop committed PC + dependency info

---

## 12. Refactor History (chronological)

### 12.1 Stage 1-5 (pre-merge, 4wide-pivot branch)

| Stage | Commit | Files | Summary |
|---|---|---:|---|
| Pre-flight | `e1ce792` | 1 | clockcheck allowlist for 4-wide pivot |
| Stage 1 | `a64efbc` + `ab9e897` | 5 | rename + ROB cascade (PIPE_WIDTH 6→4, ROB 192→128, INT_PRF 256→160). count_r width fix. |
| Stage 2 | `d566919` + `80da9b9` | 12 | dispatch + IQ + CDB + bypass + load_wb sideband. **Stage-2 cm bug introduced (Load1 bypass missing).** |
| Stage 3 | `76b190e` | 1 | LSU LQ/SQ depth 64→32 |
| Stage 4 | `4c14b5e` | 2 | L1D 4-bank → 2-bank (already dual-port) |
| Stage 5 | `3a64585` | 5 | frontend + uop cache + LB + tb_top PERF_PROFILE to 4-wide |

### 12.2 Critical Bug Fix

| Commit | Summary |
|---|---|
| `cd54cf1` | **fix(stage2-bypass): restore Load1 bypass slot** — `NUM_BYPASS_SRCS=5`, add `bypass[4]` for Load1. Resolves cm 11× spurious-instret cascade. |

### 12.3 Gap-Closure Cycles (all REFUTED with data)

| Cycle | Hypothesis | Result |
|---|---|---|
| A — uBTB sizing | BPU undersized vs BOOM | REFUTE-on-investigation (we're bigger) |
| C — BRU early-redirect | Reduce flush penalty | REFUTE (mechanism increased mispredicts +7.1%) |
| B — SFB | Eliminate predictable branches | REFUTE (only 0.92% of cm cycles eligible) |
| E — ALU3 bypass | Reduce operand-stall | REFUTE (0% IPC impact) |
| F — INT IQ reorg | More issue parallelism | REFUTE (regressed cm by −2.82%) |

### 12.4 Phase A.2 Instrumentation (added during gap analysis)

| Commit | Files | Summary |
|---|---|---|
| `766f8d7` | `rob.sv`, `rv64gc_core_top.sv` | ROB other-class sub-decomposition (mul/div/csr/bru/unknown) |
| `4a78605` | `tb_top.sv` | Issue-stall classification (operand/fu/arb) |

---

## 13. Current Performance State

### 13.1 Measurements (master @ `a6a0443`)

| Workload | Cycles | Instret | IPC | Metric |
|---|---:|---:|---:|---|
| dhrystone (100 iter) | 23,514 | 47,670 | 2.027 | 2.42 DMIPS/MHz |
| coremark iter1 | 199,452 | 332,110 | 1.665 | 5.01 CM/MHz |
| coremark iter10 | 1,860,512 | 3,197,342 | 1.719 | 5.37 CM/MHz |
| bench_loop_100 | 237 | 709 | 2.992 | (microbench) |

### 13.2 Functional + Clockcheck

- Functional regression: 20/20 PASS (8 rv64ui_* + 10 bench_* + dhry + cm iter1 + cm iter10)
- Clockcheck: 3/3 microbench PASS (bench_loop_100, bench_load, bench_unrolled_5), 0 diverging cycles

### 13.3 Pipeline Bubble Profile (cm iter1)

Per `doc/4wide_pipeline_bubble_taxonomy_2026-05-02.md` and `doc/4wide_headwait_deepdive_2026-05-02.md`:

| Category | % of cm cycles |
|---|---:|
| HEAD_WAIT_BACKLOG | **74.04%** |
| FRONTEND_LIMITED | 11.44% |
| PEAK (commit=4) | 9.93% |
| DISPATCH_BLOCKED | 2.41% |
| FLUSH | 2.18% |

HEAD_WAIT_BACKLOG dwell-time decomposition:
- Dwell=1 (productive): 64.7% of cm cycles
- Dwell=2 (load-WB at head): **16.4%**
- Dwell=3 (MUL at head): 2.6%
- Dwell=6-10 (mispredict recovery): **14.7%** (matches 4,343 misps × ~7 cyc exactly)
- Other long-tail: ~1%

### 13.4 Little's-Law Decomposition (cm)

| Stage | Avg occupancy | Avg time per uop |
|---|---:|---:|
| ROB (rename → commit) | 12.61 | **7.57 cycles** |
| IQ_INT_TOTAL | 4.64 | 2.79 cycles |
| LQ | 1.61 | 0.96 cycles |
| SQ | 0.53 | 0.32 cycles |
| Implied post-IQ → commit | — | **4.78 cycles** |

The 4.78 cycles "post-IQ → commit" exceeds the typical 3-cyc (execute + WB + commit) by ~1.78 cycles — this is the **commit-wait** (head-of-line blocking).

### 13.5 Top Head-Stall PCs (cm) — All Are Load+Consumer Chains

| PC | Cycles | Disasm | Pattern |
|---|---:|---|---|
| `0x80002440` | 6,528 | `ld a4, 0(s0); bnez a4` | Linked-list walk in `core_bench_list` |
| `0x8000235e` | 320 | **`ld a5, 0(a5)`**; `bnez a5` | **Pure pointer chase in `core_list_mergesort`** |
| `0x80003164` | 2,951 | `lh a5, 0(a5); mulw a5,a5,a1` | Load → MUL chain (matrix_test) |
| `0x80003326` | 114 | `lw a3, 0(a3); slt a5,a5,a3` | Load → ALU |
| (10+ more) | varies | Similar load+immediate-consumer | All same pattern |

These are intrinsic serial dependencies in the workload. No OoO depth/IQ size/BPU helps when iteration N's load address depends on iteration N-1's load result.

---

## 14. Open Issues / Structural Ceilings

### 14.1 Settled (do NOT re-investigate)

The following hypotheses have been data-driven REFUTED in prior cycles and should not be re-investigated:
- BPU storage size (we're bigger than BOOM)
- BRU early-redirect (mechanism net-negative)
- SFB pattern density (insufficient in workloads)
- ALU3/DIV/CSR bypass coverage (CDB[3] activity too sparse)
- INT IQ reorganization (consolidation hurts)
- Dcache hit latency 2→1 (we're already faster than BOOM; structural rework)
- Compiler/binary contribution (≤3%)

### 14.2 Stale Parameters (low-priority cleanup)

- `MUL_LATENCY = 3` in pkg.sv vs hardware latency = 1 in multiplier.sv
- `IQ_INT_DEPTH = 24` in pkg.sv refers to all 3 INT IQs uniformly; if differentiation is wanted (e.g., u_iq0 deeper than u_iq1/2), would need to break this out

### 14.3 Theoretical IPC Ceiling for cm

If all 3 structural waits (load-WB at head, mispredict recovery, MUL at head) could be eliminated:
- Save 33.7% of cm cycles
- Theoretical IPC = 2.51 → CM/MHz = 7.55 (would beat MegaBoom 6.2)

But each elimination requires structural change beyond this design point:
- Load-WB: dcache hit latency 2→1 (VIPT + way-prediction; structural)
- Mispredict recovery: shorter flush pipe OR fewer mispredicts (both REFUTED)
- MUL at head: faster MUL (large area cost)

### 14.4 Auxiliary Instrumentation Items

- Frontend bubble sub-classification (`fetch_zero_*` counters) is rich (~25 sub-buckets); could be summarized per-cycle for taxonomy purposes
- Per-PC head-stall classification could be extended to track issue→wb time per occurrence

---

## 15. Tools

| Tool | Path | Purpose |
|---|---|---|
| `bubble_taxonomy.py` | `tools/bubble_taxonomy.py` | Per-cycle bubble classification from pipe.v1 trace |
| `headwait_deepdive.py` | `tools/headwait_deepdive.py` | Little's-law decomposition + head-dwell analysis |
| `clockcheck` | `../rv64gc-perf-model/tools/rtl_clockcheck.py` | Per-cycle pipeline trace divergence check vs baseline |
| `regress_dsim.sh` | `scripts/regress_dsim.sh` | Functional + bench regression runner; tightened STOP-OK detection (requires `PASS at cycle` not just `TOHOST=`) |
| `build_dsim.sh` | `build_dsim.sh` | Top-level DSim image build |
| `run_dsim.sh` | `run_dsim.sh` | Single-test DSim invocation |

---

## 16. Documentation Index

### Active design + analysis docs

- `doc/rv64gc_v2_uarch.md` — **this doc** (current µarch spec)
- `doc/4wide_signoff_2026-05-01.md` — refreshed PARTIAL-FLOOR sign-off
- `doc/4wide_pipeline_bubble_taxonomy_2026-05-02.md` — bubble taxonomy
- `doc/4wide_headwait_deepdive_2026-05-02.md` — HEAD_WAIT_BACKLOG decomposition + per-PC analysis
- `doc/4wide_arch_diff_2026-05-02.md` — BOOM v4 ↔ rv64gc-v2 architectural audit
- `doc/4wide_methodology_retrospective_2026-05-02.md` — methodology retrospective

### Refactor execution docs

- `doc/4wide_refactor_checklist.md` — execution checklist (all 90 items complete)
- `doc/4wide_pivot_plan_2026-04-25.md` — original RTL pivot plan (historical)

### Gap-closure cycle docs (all REFUTED)

- `doc/4wide_gap_closure_sequence_2026-05-01.md` — sequence design
- `doc/4wide_iter_uBTB_*.md` — Cycle A
- `doc/4wide_iter_flush_recovery_*.md` — Cycle C
- `doc/4wide_iter_sfb_*.md` — Cycle B
- `doc/4wide_iter_alu3_bypass_*.md` — Cycle E
- `doc/4wide_iter_iq_reorg_*.md` — Cycle F

### Stale (do not refer to for current numbers)

- `doc/4wide_signoff_2026-04-30.md` — superseded; numbers inflated by cm bug
- `doc/baseline_6wide_obsolete_2026-04-30.md` — obsolete 6-wide archive

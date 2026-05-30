# AGENTS.md — rv64gc-v2

Project guidance for agentic developers (Claude Code, Codex, Cursor, etc.).
Vendor-neutral — written to the [agents.md](https://agents.md) convention.

Companion: `../rv64gc-perf-model/AGENTS.md` (perf-model side that drives
the 4-wide pivot decision before any RTL refactor here).

## Ground Rules

1. Think before acting. Read existing files before writing code
2. Be concise in output but thorough in reasoning
3. Prefer editing over rewriting whole files unless instructed by user
4. Do not re-read files you have already read
5. Test your code before declaring done
6. No sycophantic openers or closing fluff
7. Keep solutions simple and direct
8. User instructions always override this file

## Project Overview

Out-of-order RV64GC processor core (v2). Pivoted from 6-wide to **4-wide**
in April 2026 (see `doc/archive/4wide/` for pivot history and
`memory/project_4wide_pivot.md`). The v1 codebase at
`D:/agent-workspace/RV64GC/` is the naming/interface reference.

**ISA:** `rv64imafdc_zba_zbb_zbs_zicond_zicsr_zifencei`

Microarchitecture spec: `doc/rv64gc_v2_uarch.md`. Stage 1 frontend refactor
status: `doc/stage1_frontend_refactor_status_2026-05-06.md`. Reference cores:
`doc/reference_core_unified_audit_2026-05-03.md`.

## Current Status (2026-05-29 — Release Candidate)

Authoritative RC state: `doc/release_candidate_signoff_2026-05-29.md`. Stage 4
(architectural performance) is CLOSED at a well-tuned floor
(`doc/stage4_lever_ceiling_verdict_2026-05-28.md`); the Dhrystone binary was
normalized to BOOM/riscv-tests methodology
(`doc/stage4_dhrystone_binary_normalization_2026-05-29.md`).

| Workload | Score | vs BOOM public floor |
|---|---:|---|
| CoreMark iter10 | 6.85 CM/MHz | > 6.2 ✅ |
| CoreMark iter1 | 6.65 CM/MHz | — |
| Dhrystone 300 | 4.27 DMIPS/MHz | > 3.93 ✅ |
| Dhrystone 100 | 4.26 DMIPS/MHz | — |

rv64gc-v2 beats BOOM's public floor on **both** benchmarks. Release gates: 16-row
signoff, RV64GC compliance, and Stage 3 Linux `BOOT OK` (RTL byte-identical to the
boot-OK commit `ce93aea`). The historical Stage 1 status below is retained for
provenance.

### Key recent commits

- `8b30714` — Stage 1 prep: harness (golden PC scoreboard, counter
  invariants, image_diff), iter α' (explicit `!packet_buf_full`
  backpressure on F2 emit), FTQ-split scaffold (3-pointer FTQ:
  `wr_ptr_r`/`ifu_ptr_r`/`commit_ptr_r`), loop_buffer.sv deletion, doc
  cleanup.
- `18007b7` — Stage 1 closure plan refined: BPU runahead requires
  icache response queue prerequisite (γ' phase 0).
- `5fd8577` — Harness enforces data-driven discipline: signoff with
  RTL changes vs HEAD requires `--mechanism-class non-default`,
  `--targets-counter`, and `--expect-counter-decrease` predictions
  that the harness verifies against measurement.

### Stage 1 closure plan

The remaining gap is structural: BPU/F1/F2 lockstep pins
`xs_ftq_occ_max=1`. Architectural unlock requires F1-stage runahead
with an icache response queue absorbing rate mismatch. Iteration
sequence in `doc/stage1_frontend_refactor_status_2026-05-06.md`:

| Step | Description | Status |
|---|---|---|
| α' | F2 backpressure on `!packet_buf_full` | LANDED |
| α'' | Delete dup suppressor | BLOCKED (needs F2 data-lifecycle change) |
| β' | Owner-tagged packets epoch-filter at decode pop | PARTIAL (struct fields exist, decode-pop wiring pending) |
| γ' phase 0 | Icache response queue (NEW — discovered as prerequisite) | DESIGN-PENDING |
| γ' phase 1 | F1 BTB-driven advance | BLOCKED on phase 0 |
| γ' phase 2 | FTQ alloc rate decoupling | BLOCKED on phase 1 |
| γ'' | ICache prefetch by FTQ entry | BLOCKED on phase 2 |

## Data-Driven Iteration Discipline

Per `feedback_perf_discipline.md` (memory) — every RTL iteration MUST
be predicted-then-measured, not trial-and-error. Workflow:

```bash
# 1. Identify dominant bottleneck from baseline result.json
./tools/bottleneck_analysis.py benchmark_results/<baseline>/<bench>/result.json

# 2. Apply RTL change targeting that counter
# 3. Run signoff with mechanism class + targeted counter + prediction
python3 tools/run_benchmarks.py --runner dsim --goal stage1 --run-class signoff \
    --manifest tests/benchmarks/stage1_signoff.json \
    --plusarg FETCH_DELIVERY_CHECK --plusarg FETCH_DELIVERY_STRICT \
    --plusarg FETCH_OWNER_CHECK --plusarg FETCH_OWNER_STRICT \
    --plusarg PERF_PROFILE --plusarg PERF_COUNTERS --plusarg STAT_DUMP \
    --mechanism-class ftq_owned_delivery \
    --mechanism-name <descriptive-name> \
    --baseline-results <baseline_results.json> \
    --targets-counter <counter_name> \
    --expect-counter-decrease <counter_name>:<predicted_delta> \
    --run-id <run_id>
```

The harness enforces this in `validate_run_class_args`:
- Signoff with `--mechanism-class default_rtl` is REJECTED if
  `git diff HEAD -- src/rtl src/tb/tb_top.sv` shows uncommitted RTL.
- Real `--goal stage1` runs reject dirty goal-contract files
  (`tests/benchmarks/stage1_signoff.json` and `tools/run_benchmarks.py`).
- Non-default mechanism class REQUIRES `--targets-counter`.
- `--targets-counter` REQUIRES matching `--expect-counter-decrease`.
- Predictions are verified against measurement; failure to materialize
  fails the gate even if cycles improved.

The golden PC scoreboard (`+CHECK_GOLDEN_PCS=...`) catches architectural
divergence within microseconds (vs ~2M cycles to a CoreMark CRC fail).
Goldens at `tests/golden_pc/*.golden.hex`, hash-gated to image SHA256.

### Earlier-session known issues (still applicable)

- **CoreMark mispredict rate ~9% on dsim iter=1 (2026-04-25)**: BTB
  index-mismatch fixed (commit 0a3ca2f). Remaining cause suspected
  TAGE training in `rv64gc_core_top.sv:3683-3770`. Investigate before
  claiming BTB causes mispredicts.
- **xsim vs Verilator residual gap** (~5%): Verilator eval-scheduling
  artifacts. Not blocking; xsim is authoritative.

### Infrastructure

- **L2 prefetch port**: 3-way arbitration (dcache > icache > prefetch).
- **NLPB**: 4-entry next-line prefetch buffer.
- **Multi-MSHR icache**: 2-entry MSHR array, miss-under-miss.
- **FTQ-split delivery scaffold**: 3-pointer FTQ (alloc/ifu/commit)
  with `count_alloc_to_ifu` and `count_ifu_to_commit` counts; 5
  owner-identity invariants hold zero.

## Performance Targets

4-wide regime (current):

| Workload | Stage 1 target (timed cycles) | Stage 2 stretch | gem5 4-wide ceiling |
|---|---:|---:|---:|
| Dhrystone 300 | < 70,783 | 4.0 DMIPS/MHz | ~3.93 |
| CoreMark iter10 | < 1,850,040 | 7.5 CM/MHz | ~6.2 |

Stage 1 target = match the previous-clean-loop-buffer baseline without
the loop buffer (now banished). Stage 2 = stretch via loop predictor,
ICache prefetch upgrades, optional UOP cache.

## gem5 Study Provenance

The design is backed by a 9-step gem5 surrogate study (2026-04-05/06):

1. **v1 RTL audit** — PRF=120, ROB=120 (not 96 as documented)
2. **Gap analysis** — four artifacts causing v1's 0.47 IPC
3. **Vanilla sweep** — 4w through 10w width sensitivity
4. **Designed sweep** — realistic FU pool, LTAGE, 1-cycle L1
5. **Innovation sweep** — TAGE-SC-L (+15% Dhrystone), prefetcher (zero)
6. **Advanced sweep** — 11 innovations (only ROB moves CoreMark)
7. **Corrected baseline** — PRF undersizing fix (19M stalls → zero)
8. **ROB sensitivity** — ROB=192 is the knee; 320/384 = zero gain
9. **Bottleneck analysis** — per-stage cycle breakdown at gem5 ceiling

## Build and Simulation

Verilator is the primary simulation tool. The v1 build pattern (to be adapted for v2):

```bash
# Build RTL with Verilator
make build

# Run a test hex file
make run                                    # default test
make run SIM_BIN=... +MEMFILE=path/to.hex   # specific test

# Clean build artifacts
make clean
```

Verilator flags from v1 that carry forward: `--cc --exe --trace --build -j 4` plus width/latch/multidriven warning suppressions.

Run a single test: `./obj/Vtb_top +MEMFILE=tests/hex_simple/rv64ui_add.hex`

## Source Layout (v1 convention, expected for v2)

```
src/
  rtl/
    core/
      include/       # rv64gc_pkg.sv, isa_pkg.sv, uarch_pkg.sv
      fetch/          # fetch_unit, icache, tage_bpu, btb, ras, rvc_decompress
      decode/         # decode, decode_slice, fusion_detector (new)
      rename/         # rename, rat, free_list, checkpoint, rename_buffer
      dispatch/       # dispatch_queue
      issue/          # issue_queue, wakeup_network
      execute/        # alu, bru, multiplier, divider, fpu_top
      regfile/        # int_prf, fp_prf
      backend/        # rob, commit
      lsu/            # lsu, load_queue, store_queue, committed_store_buffer
      cache/          # dcache, icache, l2_cache + data/tag RAMs
      mmu/            # dtlb, itlb, ptw
      rv64gc_core_top.sv
    platform/         # clint, plic, uart, mmio_router
    sim/              # sim_memory, mem_if_pkg
  tb/                 # tb_top.sv, tb_verilator.cpp
  sim/                # test hex files
tests/                # assembly tests (.S), hex files, benchmarks
sw/                   # Linux boot: opensbi, device tree, initramfs
```

## Key Design Parameters (from uarch spec)

These are the **as-built** values, verified against
`src/rtl/core/include/rv64gc_pkg.sv` (2026-05-29). Several are smaller than the
original gem5-study targets (ROB, Int PRF, Int IQ, LQ/SQ were sized down); do not
deviate without data.

| Parameter | As-built value | Note |
|-----------|-------|------------------|
| Pipeline width | **4-wide** (decode/rename/commit) | 6-wide is a structural question, not a parameter tweak |
| ROB | **128** entries (`ROB_DEPTH`) | gem5-study knee was 192; as-built is 128 |
| FTQ | 24 entries, 3-pointer split | — |
| Int PRF | **160** × 64-bit, 12R6W (`INT_PRF_DEPTH`) | gem5 target was 256 |
| FP PRF | **96** × 64-bit (`FP_PRF_DEPTH`) | (was documented 128) |
| Int IQs | **3 × 24** (`IQ_INT_DEPTH`); IQ0 dual-select, IQ1/IQ2 single | MEM IQs 3 × 32 (`IQ_MEM_DEPTH`) |
| ALUs | 4 | 5 = +0.000 IPC |
| LQ / SQ / CSB | **32 / 32 / 32** (`LQ_DEPTH`/`SQ_DEPTH`/`CSB_DEPTH`) | was documented 64/64 |
| L1D | 64 kB, 4-way | >64 kB = zero gain |
| L1I | 32 kB, 4-way | — |
| L2 | 2 MB, 8-way | >2 MB = zero gain |
| L1D MSHR | 16 (`L1D_MSHR_DEPTH`) | miss-under-miss |
| Branch predictor | TAGE-SC-L | Perceptron −20% on RISC-V |
| BTB | 2048 × 8-way | (8× larger than BOOM v4 Mega) |
| Recovery | **64** checkpoints (`NUM_CHECKPOINTS`) | was documented 16 |
| Loop buffer | **REMOVED** (banished, was 64 µops) | DO NOT RE-ADD; loop-exit prediction belongs in BPU/FTQ |
| `fetch_packet_buffer` | 8-entry FIFO (operationally 1-deep) | — |

## Critical v1→v2 Architectural Changes

These are the bottlenecks that caused v1's 0.47 IPC. Every v2 module must eliminate these:

1. **Rename:** v1 uses group-hold (56.88% of cycles wasted). v2 uses per-slot independent advance + move elimination.
2. **Dispatch:** v1 narrows 4→2 at dispatch. v2 is 6-wide throughout.
3. **Issue:** v1 has 1 select port per IQ. v2 has 2 select ports + speculative wakeup.
4. **Recovery:** v1 uses 2-cycle architectural RAT shadow flush. v2 uses 1-cycle checkpoint restore.

## Modules to Build

### Core Pipeline

| Module | Description |
|--------|-------------|
| `decoder` | RV64IMAFDC + Zba + Zbb + Zbs + Zicond, 6-wide |
| `fusion_detector` | Macro-op fusion: `lui+addi`, `auipc+jalr`, `slt+bne`, etc. (~500 lines) |
| `rename` | 6-wide per-slot advance, move elimination, 256-bit free list |
| `dispatch` | 6-wide, round-robin with fallback, 32-deep int + mem FIFOs |
| `issue_queue` | 3 × 32 entries, 2 select ports/IQ, speculative wakeup |
| `int_prf` | 256×64-bit, 12R6W (6 copies) |
| `rob` | 192 entries, 6-wide commit, checkpoint recovery (4 ckpts) |
| `commit` | 1-cycle combinational squash, checkpoint restore |
| `bypass` | 6 bypass sources, 48 comparators + 48 × 64-bit muxes |

### Frontend

| Module | Description |
|--------|-------------|
| `icache` | 32 kB, 4-way, 1-cycle hit (new — v1 has none) |
| `tage_bpu` | TAGE-SC-L (base + 4 tagged + stat. corrector + loop pred) |
| `btb` | 1024 × 4-way (v1: 256) |
| `ras` | 24 entries (v1: 16) |
| `loop_buffer` | 64-entry decoded µop cache (new) |

### Memory

| Module | Description |
|--------|-------------|
| `dcache` | 64 kB, 4-way, 4-bank interleaved, 1-cycle hit |
| `l2_cache` | 2 MB, 8-way, 8-cycle hit, 32 MSHRs |
| `lq` / `sq` | 48 / 48 entries (v1: 24) |
| `csb` | 24-entry committed store buffer (v1: 16) |

### ALU Extensions (Zba/Zbb/Zbs/Zicond) — ~250 lines total

| RTL change | Lines | Instructions added |
|---|---|---|
| ALU: shifted-add path | ~50 | `sh1add/sh2add/sh3add`, `.uw` variants |
| ALU: CLZ/CTZ/CPOP | ~60 | `clz`, `ctz`, `cpop` |
| ALU: min/max/sext/rev | ~50 | `min/max/minu/maxu`, `sext.b/h`, `rev8`, `orc.b` |
| ALU: rotate | ~20 | `rol/ror/rori` |
| ALU: AND-NOT etc. | ~20 | `andn/orn/xnor` |
| ALU: single-bit | ~30 | `bset/bclr/binv/bext` + imm variants |
| ALU: conditional zero | ~20 | `czero.eqz/nez` |

## RTL Conventions (from v1)

- SystemVerilog, Verilator-compatible (no unsynthesizable constructs in RTL)
- Package files define all parameters, types, and structs (`rv64gc_pkg.sv`, `isa_pkg.sv`, `uarch_pkg.sv`)
- Module names match filenames: `module foo` lives in `foo.sv`
- `snake_case` for signals, modules, and packages
- Parameters in `UPPER_CASE`
- Testbench files use `tb_` prefix
- Top module: `rv64gc_core_top.sv`

## 4-State Variables and ASIC-Correct Reset Discipline

Simulation uses 4-state logic (`0/1/X/Z`); synthesis is 2-state. Hardware comes
up in an undefined state at power-on and control-flow discipline (not blanket
reset) is what keeps the design correct. This has implications for every RTL
review.

**Reset MANDATORY for:** valid bits, ready bits, state-machine registers,
head/tail/count pointers, small control vectors.

**Reset FORBIDDEN for (ASIC-tapeout path):** register files (`int_prf`,
`fp_prf`), cache/SRAM data arrays, FIFO/queue payload fields, ROB payload
fields, BTB/TAGE data entries, any wide data-path flop array (>~64 flops).
Reason: reset-net max fanout at modern nodes is ~20-30; a 256×64 PRF under
reset is ~16 K flops of fanout — unbuildable without a reset-buffer tree
that costs area and CTS.

**Correct ways to eliminate X-propagation in simulation without adding
synthesis reset load:**

1. `ifdef SIMULATION` / `initial` blocks — zero at time 0, never drive
   synthesis.
2. `$readmemh` / ROM init — sim + FPGA, not ASIC; benign for simulation X.
3. Boot ROM / boot firmware (e.g. BSS clear, page-table init for Linux) —
   the ASIC-correct path for software-visible memory regions.
4. Tighten the control-flow invariant — the data flop is read only when its
   guarding valid bit is 1, so its reset value is irrelevant at synthesis.

**Workflow rule for new RTL and reviews:**
- Classify every flop array as *control* (reset) or *data* (no-reset, guarded
  by control).
- Reject review findings of the form "data field not cleared on flush — add
  defensive clear" unless an un-reset valid bit AND a demonstrated X-prop
  escape path are both shown.
- For Linux boot: memory zero-init lives in boot software, not hardware
  reset. The design must support uninitialized memory coming out of reset.
- The recent commits `8e280c6` (tag-RAM reset), `99b2199` (int_prf reset),
  and similar defensive clears are **sim-only workarounds**; before tapeout
  each should be gated behind `ifdef SIMULATION` (or converted to
  `initial` blocks) to keep the synthesis reset net sane.

## Compiler Flags for Benchmark Software

```bash
CFLAGS="-O3 -march=rv64gc_zba_zbb_zbs_zicond -mabi=lp64d \
        -mtune=generic -flto -funroll-loops -fomit-frame-pointer"
```

Requires GCC 13.3+ for full Zba/Zbb/Zbs/Zicond support.

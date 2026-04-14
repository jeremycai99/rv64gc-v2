# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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

Clean-sheet 6-wide out-of-order RV64GC processor core (v2). This is a ground-up redesign, not an incremental v1 upgrade. The v1 codebase lives at `D:/agent-workspace/RV64GC/` — reference it for naming conventions and module interfaces, but do not carry over its architectural bottlenecks.

**ISA:** `rv64imafdc_zba_zbb_zbs_zicond_zicsr_zifencei`

The full microarchitecture spec is at `doc/rv64gc_v2_uarch.md`. The gem5 sweep data is at `D:/agent-workspace/rv64gc-gem5/`. Companion SoC peripherals spec (UART, GPIO, SPI, I2C, DMA, JTAG, PMU, watchdog, framebuffer): `D:/agent-workspace/rv64gc-gem5/study/rv64gc_next_gen_soc.md`.

## Current Benchmark Status (2026-04-13)

```
                    IPC (measured)   Verification            Status
CoreMark (-O2):     3.33             CSR + VCD cross-check   23/23 regressions pass
Dhrystone (-O2):    2.13             CSR                     23/23 regressions pass
CoreMark (-O3):     0.37             CSR (fixed)             runs, separate perf bug
```

### CoreMark IPC Signoff

| Method | IPC | Window |
|--------|-----|--------|
| CSR (mcycle/minstret) | 3.3332 | 0-2M cycles |
| VCD sum(commit_count) | 3.3333 | 2K-5K warm window |
| Steady-state windowed | 3.3333 | 100K-2M (excludes startup) |
| Wall-clock (sim cycles) | 3.3326 | 0-2M cycles |
| gem5 ceiling (no LB/dual-BRU) | 3.05-3.12 | — |

Conservative signoff: **3.33 IPC** (steady-state, cross-validated).
Startup bias: 0.021% at 2M cycles (negligible).
Margin over 3.0 target: **+11.1%**.

Optimization log: `doc/coremark_optimization_changelog.md`

### Key Optimizations Applied
1. BTB offset-based truncation (fetch delivers full group, not just slot 0)
2. BPU update type (CALL/RET/JALR stored in BTB for RAS prediction)
3. BRU early fetch redirect (redirect at execute, not commit)
4. 1-cycle redirect bubble (icache + f2_pc bypass on BPU redirect)
5. Loop buffer all-slot trigger (registered to avoid Verilator eval artifact)
6. Forwarding hold register (breaks CDB→bypass→SQ_fwd→CDB loop)
7. SQ/LQ power-of-2 depths (fixes pointer-wrap count overflow)
8. Dispatch load cap (limits to 2 loads/cycle matching IQ NUM_ENQUEUE)
9. Combinational preg_ready_table (includes rename clears for IQ enrollment)
10. Dual-port dcache tag/data RAM (restores dual-select load IQ)
11. Dual BRU on IQ0 (port 0 + port 1 both handle branches, eliminates BRU bottleneck)

### Known Issues
- **Dhrystone 2-cycle fetch cadence**: 60% of cycles produce 0 instructions. Root cause: F2 extraction feeds back to F1 through registered SRAM, creating an emit-bubble-emit alternation. Active IPC is 2.91 when pipeline is fed. Fix requires NLPB integration (blocked by single-MSHR icache) or pipeline restructuring.
- **BTB dead for Dhrystone**: BTB indexes by PC[9:2] but lookup uses fetch-group PC while update uses branch PC — index mismatch. Cache-line indexing (PC[13:6]) fixes index alignment but the hot branch falls just beyond the 6-slot extraction window (offset 14 vs window 2-13). Fix requires either wider extraction or eliminating the 2-cycle cadence first.
- **CoreMark -O3 slow (0.37 IPC)**: CSR corruption fixed (write_op pipeline). The low IPC is a separate performance bug from -O3 code patterns.
- **Verilator convergence**: structural CDB→bypass loop settled by forwarding hold register + address gating. Reading `fused_insn[1+]` in combinational context changes Verilator eval scheduling — use `always_ff` for signals derived from multi-slot decode arrays.

### Infrastructure Ready (not yet active)
- **L2 prefetch port**: 3-way arbitration (dcache > icache > prefetch) committed. Tied off, ready for NLPB.
- **NLPB module**: `next_line_prefetch_buffer.sv` — 2-entry line buffer with FSM-driven L2 prefetch engine. Standalone, not yet wired into fetch pipeline. Activation blocked by icache single-MSHR (can't handle fetch running ahead via NLPB while icache fills an old miss).
- **iverilog testbench**: `tb_iverilog.sv` wrapper for cross-simulator validation. iverilog 13.0 blocked by SV struct limitations in decode.sv.

## Performance Targets

```
                    CoreMark      Dhrystone     Linux boot
v1 (current):       0.47          —             0.13
v2 hw-only:         2.5 target    3.2 target    0.8–1.2
v2 + SW stack:     ~3.0 expected ~3.8           1.1–1.5
gem5 ceiling:       3.15          3.92          —
v2 measured:        3.33          2.13          —
```

The ISA extensions + macro-op fusion + compiler opts add ~20–30% effective IPC on top of the microarchitecture alone.

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

These are the authoritative values — do not deviate without gem5 evidence:

| Parameter | Value | Do NOT change to |
|-----------|-------|------------------|
| Pipeline width | 6-wide | 8-wide (+5% IPC, +50% area) |
| ROB | 192 entries | >192 (+0.05% IPC, +67% area) |
| Int PRF | 256 × 64-bit, 12R6W | — |
| FP PRF | 128 × 64-bit | — |
| Int IQs | 3 × 32, dual-select | >32 per IQ (symptom, not cause) |
| ALUs | 4 | 5 (+0.000 IPC) |
| LQ/SQ | 64/64 (power-of-2) | 48 (pointer-wrap bug) |
| L1D | 64 kB, 4-way, 4-bank | >64 kB (zero gain) |
| L1I | 32 kB, 4-way | — |
| L2 | 2 MB, 8-way, 32 MSHRs | >2 MB (zero gain) |
| Branch predictor | TAGE-SC-L | Perceptron (−20% on RISC-V) |
| BTB | 1024 × 4-way | >1024 (+0.003 IPC) |
| Recovery | 4 checkpoints | — |
| Loop buffer | 64 µops | — |

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

## Compiler Flags for Benchmark Software

```bash
CFLAGS="-O3 -march=rv64gc_zba_zbb_zbs_zicond -mabi=lp64d \
        -mtune=generic -flto -funroll-loops -fomit-frame-pointer"
```

Requires GCC 13.3+ for full Zba/Zbb/Zbs/Zicond support.

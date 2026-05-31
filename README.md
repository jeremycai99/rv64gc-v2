# rv64gc-v2 — a 4-wide out-of-order RV64GC core

`rv64gc-v2` is a synthesizable, out-of-order RISC-V application-class core
implementing **RV64GC + Zba/Zbb/Zbs/Zicond**. It is a 4-wide superscalar
out-of-order machine with speculative wakeup, checkpoint-based recovery, a
TAGE-SC-L branch predictor, and an FPnew floating-point unit. It passes the
RV64GC ISA test suite, boots mainline Linux, and exceeds BOOM's published
single-thread benchmark floor on both CoreMark and Dhrystone.

## Status

| | Result |
|---|---|
| ISA | `rv64imafdc_zba_zbb_zbs_zicond_zicsr_zifencei` |
| RV64GC compliance | **113 / 113** riscv-tests pass (incl. RV64F/D) |
| CoreMark | **6.85 CoreMark/MHz** (BOOM public floor ≈ 6.2) |
| Dhrystone | **4.27 DMIPS/MHz** (BOOM public floor ≈ 3.93) |
| Linux | boots OpenSBI + Linux 6.6 to userspace (`BOOT OK`) |
| Primary sim | DSim 2026 (authoritative); Verilator (open-source) |

Benchmarks are compiled to the standard riscv-tests/BOOM methodology and measured
on the cycle-accurate RTL. See `doc/release_candidate_signoff_2026-05-29.md` for
the signoff detail and `doc/rv64gc_v2_uarch.md` for the full microarchitecture
specification.

## Microarchitecture

A classic Tomasulo-style out-of-order pipeline, 4-wide end to end
(fetch → decode → rename → dispatch → commit):

**Frontend.** Decoupled fetch with a TAGE-SC-L predictor (base + 4 tagged tables
+ statistical corrector + loop predictor), a 2048×8-way BTB, a 24-entry RAS, and
a 3-pointer split FTQ. 32 kB 4-way L1I with a multi-entry MSHR and a next-line
prefetch buffer. RVC instructions are decompressed in the fetch path.

**Rename / dispatch.** Per-slot independent rename with move/zero elimination, a
160-entry integer PRF (12read/6write) and a 96-entry FP PRF, and 64 recovery
checkpoints for single-cycle misprediction/exception restore.

**Issue.** Three integer issue queues (3×24) feeding four ALUs, two branch units,
a multiplier, a divider, and CSR logic; three memory issue queues (3×32) for
load-address, store-address, and store-data. Oldest-ready select with two select
ports on the primary integer queue, plus a speculative load-use wakeup path.

**Execute / forwarding.** A registered common-data-bus (CDB) breaks the
select→execute→wakeup→re-select timing loop; a 6-source bypass network (4 CDB +
2 combinational load-writeback lanes) forwards results to dependent integer *and*
floating-point operands so the non-write-first register files never deliver stale
data. Floating point is the PULP **FPnew** unit (single + double), integrated with
NaN-boxing and `fcsr`/`fflags` accumulation.

**Memory.** 64 kB 4-way 2-cycle-hit L1D with 16 MSHRs; 32/32/32-entry
load/store/committed-store queues with same-cycle store-to-load forwarding (SQ
CAM); 2 MB 8-way L2 with an L2 prefetch port. Sv39/Sv48 MMU with split TLBs and a
hardware page-table walker.

**Backend.** 128-entry ROB with 4-wide in-order commit and combinational squash.

### Key parameters (as built)

| Block | Value | Block | Value |
|---|---|---|---|
| Pipeline width | 4 | ROB | 128 |
| Int PRF | 160 × 64b (12R/6W) | FP PRF | 96 × 64b |
| Int IQs | 3 × 24 | Mem IQs | 3 × 32 |
| ALUs | 4 (+ BRU×2, MUL, DIV) | LQ / SQ / CSB | 32 / 32 / 32 |
| Recovery | 64 checkpoints | L1I / L1D | 32 kB / 64 kB, 4-way |
| L1D hit | 2 cycle, 16 MSHR | L2 | 2 MB, 8-way |
| Branch pred. | TAGE-SC-L | BTB / RAS | 2048×8-way / 24 |
| FTQ | 24, 3-pointer | FPU | FPnew (F + D) |

These are the authoritative as-built values from
`src/rtl/core/include/rv64gc_pkg.sv`.

## Repository layout

```
src/rtl/core/      RTL: fetch/ decode/ rename/ issue/ execute/ regfile/
                        backend/ lsu/ cache/ mmu/ + rv64gc_core_top.sv
src/rtl/platform/  CLINT, PLIC, UART, MMIO router (SoC platform for Linux)
src/tb/            testbenches (tb_top.sv benchmarks, tb_linux.sv boot)
tests/             assembly tests, CoreMark, Dhrystone, golden-PC streams
sw/linux_boot/     OpenSBI + device tree + initramfs Linux image
scripts/           build + run wrappers (DSim / Verilator; core + Linux)
tools/             benchmark/compliance/boot runners + analysis scripts
doc/               µarch spec, compliance audit, release signoff
```

## Build & run

Two simulators are supported: **DSim** (authoritative) and **Verilator**
(open-source, no license required).

```bash
# --- DSim ---
scripts/build_dsim.sh                                # build the core sim image
scripts/run_dsim.sh tests/hex/coremark.hex 10000000  # run a hex

# --- Verilator ---
scripts/build_verilator.sh
scripts/run_verilator.sh tests/hex/coremark.hex 10000000
```

Benchmark signoff, ISA compliance, and Linux boot are driven by the runners in
`tools/`:

```bash
# 16-row benchmark signoff (DSim)
python3 tools/run_benchmarks.py --runner dsim --goal stage1 --run-class signoff \
    --manifest tests/benchmarks/stage1_signoff.json

# RV64GC ISA compliance (riscv-tests)
python3 tools/run_rv64gc_compliance.py

# Linux boot (full profile)
python3 tools/run_linux_boot.py --run --build-sim --simulator dsim \
    --linux-profile full --target-milestone boot_ok
```

Benchmark binaries, hex/elf images, simulator work directories, and run logs are
build artifacts and are not tracked (see `.gitignore`).

## License

See `LICENSE` (if present). This is a research/simulation core.

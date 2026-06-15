# rv64gc-v2 — a 4-wide out-of-order RV64GC core

`rv64gc-v2` is a synthesizable, out-of-order RISC-V application-class core
implementing **RV64GC + Zba/Zbb/Zbs/Zicond**. It is a 4-wide superscalar
out-of-order machine with speculative wakeup, checkpoint-based recovery, a
TAGE-SC-L branch predictor, and an FPnew floating-point unit. It passes the
RV64GC ISA test suite, boots mainline Linux, and reaches 6.96 CoreMark/MHz and
4.27 DMIPS/MHz single-thread.

## Status

| | Result |
|---|---|
| ISA | `rv64imafdc_zba_zbb_zbs_zicond_zicsr_zifencei` |
| RV64GC compliance | **113 / 113** riscv-tests pass (incl. RV64F/D) |
| CoreMark | **6.96 CoreMark/MHz** |
| Dhrystone | **4.27 DMIPS/MHz** |
| 3.x-IPC roster | **8 workloads ≥ 2.95 IPC** (per-workload table below) |
| Linux | boots OpenSBI + Linux 6.6 to userspace (`BOOT OK`) on DSim **and Verilator** |
| Primary sim | DSim 2026 (authoritative); Verilator (open-source) |

Benchmarks are compiled to the standard riscv-tests / embench methodology and
measured on the cycle-accurate RTL (DSim-authoritative, IPC). See
`doc/perf_before_after_2026-06-14.md` and `doc/perf_scoreboard_2026-06-13.md` for
the full per-workload binder analysis, and `doc/rv64gc_v2_uarch.md` for the
microarchitecture specification.

## Benchmark performance

Per-workload IPC on the cycle-accurate RTL — default config, DSim-authoritative,
GCC-13.4 `-O2`, riscv-tests / embench methodology. CoreMark's 2.178 IPC is the
**6.96 CoreMark/MHz** headline; Dhrystone is **4.27 DMIPS/MHz**. The top 8 rows
(≥ 2.95 IPC) are the 3.x roster.

| workload | IPC | workload | IPC |
|---|---|---|---|
| linear_alg | 3.317 | cubic | 2.080 |
| sha | 3.311 | slre | 2.065 |
| nettle-sha256 | 3.299 | towers | 2.002 |
| nettle-aes | 3.288 | matmult-int | 1.897 |
| vvadd | 3.204 | nsichneu | 1.891 |
| rsort | 3.141 | md5sum | 1.815 |
| edn | 3.104 | ud | 1.807 |
| statemate | 2.973 | loops | 1.728 |
| dhrystone-ww | 2.789 | minver | 1.560 |
| dhrystone | 2.614 | huffbench | 1.542 |
| memcpy | 2.607 | aha-mont64 | 1.536 |
| zip | 2.524 | qrduino | 1.530 |
| wikisort | 2.345 | spmv | 1.490 |
| picojpeg | 2.335 | sglib | 1.471 |
| stream-l2 | 2.322 | qsort | 1.359 |
| crc32 | 2.300 | median | 1.314 |
| stream-l1 | 2.257 | multiply | 1.210 |
| cjpeg | 2.236 | radix2 | 1.042 |
| coremark | 2.178 | st | 0.892 |
| nnet | 2.116 | nbody | 0.741 |
| tarfind | 2.083 | parser | 0.623 |

The scalar core is at its conventional-lever floor: the chain (dataflow-bound) and
misprediction-entropy bands are certified irreducible, and every width / capacity /
port lever has been measured-dead. Remaining headroom is software (GCC-14 codegen
lifts `multiply` 1.21 → 3.37, a 9th roster member, zero RTL) and the
real-kernel / memory axis (a gated D-side stride prefetcher). The L2 is sized for PPA
at 512 KB (2 MB → 512 KB returns ~30–37% of die area for an accepted ≈−0.8% real-app
cost at realistic DRAM latency; the compute-IPC table above is at the latency-removed
basis and is capacity-invariant). Per-workload binders and the funded/gated lever
projections are in `doc/perf_before_after_2026-06-14.md`.

## Microarchitecture

A classic Tomasulo-style out-of-order pipeline, 4-wide end to end
(fetch → decode → rename → dispatch → commit):

**Frontend.** Decoupled fetch with a TAGE-SC-L predictor (base + 4 tagged tables
+ statistical corrector + loop predictor), a 2048×8-way BTB, a 24-entry RAS, and
a 3-pointer split FTQ. 32 kB 8-way L1I (alias-free VIPT, 4 kB/way = page size) with
a multi-entry MSHR and a next-line prefetch buffer. RVC instructions are decompressed
in the fetch path.

**Rename / dispatch.** Per-slot independent rename with zero elimination (move
elimination is wired into the datapath but disabled in the as-built config), a
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
CAM); 512 KB 8-way L2 with an L2 prefetch port. Sv39/Sv48 MMU with split TLBs and a
hardware page-table walker.

**Backend.** 128-entry ROB with 4-wide in-order commit and combinational squash.

### Key parameters (as built)

| Block | Value | Block | Value |
|---|---|---|---|
| Pipeline width | 4 | ROB | 128 |
| Int PRF | 160 × 64b (12R/6W) | FP PRF | 96 × 64b |
| Int IQs | 3 × 24 | Mem IQs | 3 × 32 |
| ALUs | 4 (+ BRU×2, MUL, DIV) | LQ / SQ / CSB | 32 / 32 / 32 |
| Recovery | 64 checkpoints | L1I / L1D | 32 kB 8-way / 64 kB 4-way |
| L1D hit | 2 cycle, 16 MSHR | L2 | 512 KB, 8-way |
| Branch pred. | TAGE-SC-L | BTB / RAS | 2048×8-way / 24 |
| FTQ | 24, 3-pointer | FPU | FPnew (F + D) |

These are the authoritative as-built values from
`src/rtl/core/include/rv64gc_pkg.sv`.

## Repository layout

```
src/rtl/core/      RTL: frontend/ decode/ rename/ issue/ execute/ regfile/
                        backend/ lsu/ cache/ mmu/ + rv64gc_core_top.sv
src/rtl/platform/  CLINT, PLIC, UART, MMIO router (SoC platform for Linux)
src/tb/            testbenches (tb_top.sv benchmarks, tb_linux.sv boot)
tests/             assembly tests, CoreMark, Dhrystone, golden-PC streams
sw/linux_boot/     OpenSBI + device tree + initramfs Linux image
scripts/           build + run wrappers (DSim / Verilator; core + Linux)
tools/             benchmark/compliance/boot runners + analysis scripts
doc/               µarch spec, compliance audit, perf scoreboard
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

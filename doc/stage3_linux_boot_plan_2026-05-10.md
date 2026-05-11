# Stage 3 Linux Boot Plan

Date: May 10, 2026

Status: performance optimization is paused. Stage 3 is the Linux boot bring-up
phase. L0 platform smoke and L1 OpenSBI platform-probe milestones are now
working through the ASIC-style core boundary; the next architecture milestone
is Sv48 MMU/PTW/TLB support for Linux entry.

## Goal

Bring rv64gc-v2 from reset into a real RISC-V Linux boot flow while preserving
the ASIC-style core boundary.

The target is not another benchmark ABI. The target is a normal CPU plus
platform simulation stack:

- reset into M-mode firmware at `0x80000000`,
- run OpenSBI as the machine-mode runtime,
- enter an S-mode Linux kernel with a DTB,
- print deterministic boot progress through a real platform console,
- terminate simulation through platform-level events or log milestones, not
  through a core-specific `tohost` port.

## Ground Rules

- Do not add `tohost`, benchmark-result MMIO, HTIF, CoreMark, Dhrystone, or
  Linux-specific pass/fail logic into synthesizable core RTL.
- Keep endpoint handling in the simulation platform, testbench, or runner.
- Treat Linux boot as a SoC/platform contract, not as a bare-metal test ABI.
- Use v1 as infrastructure reference only. Do not copy v1 debug shortcuts that
  made Linux progress look like core architecture.
- Prefer standard components and device-tree-visible devices: OpenSBI,
  NS16550A UART, CLINT or ACLINT timer/software interrupt, PLIC when external
  interrupts are needed, and a normal DRAM region.
- Every RTL modification made for Stage 3 must preserve the committed
  Dhrystone and CoreMark performance baseline. Linux boot progress is not a
  substitute for this regression gate.

## Hard RTL Modification Gate

This is mandatory for every Stage 3 RTL change, including changes that appear
to be platform-only. A Linux boot fix is not promotable if it regresses the
committed DS/CM performance baseline.

Baseline reference:

Reference artifact: `benchmark_results/dse_stage2_ds_viability_profile_20260510`
on commit `bddfed8`.

The reference cycle counts are diagnostic thresholds, not hard limits. A run is
acceptable only when the measured performance regression is no more than
`0.01%` versus the reference. The wrapper reports cycle movement against the
same `0.01%` envelope, but the hard performance gate is the reported metric:
it must not drop by more than `0.01%`.

| Row | Reference timed cycles | Diagnostic cycles at 0.01% | Reference metric | Hard min metric with 0.01% tolerance |
|---|---:|---:|---:|---:|
| Dhrystone 100 | `18,161` | `18,162` | `3.133924 DMIPS/MHz` | `3.133611 DMIPS/MHz` |
| Dhrystone 300 | `53,469` | `53,474` | `3.193357 DMIPS/MHz` | `3.193038 DMIPS/MHz` |
| CoreMark 1 | `154,233` | `154,248` | `6.483697 CM/MHz` | `6.483049 CM/MHz` |
| CoreMark 10 | `1,491,334` | `1,491,483` | `6.705406 CM/MHz` | `6.704735 CM/MHz` |

Required regression command shape after each RTL slice:

```bash
python3 tools/run_stage3_rtl_guard.py --runner dsim --run-id <date>_<slice>
```

The wrapper rebuilds the selected simulator, runs the four locked DS/CM rows
with the strict owner, delivery, branch-recovery, performance, stat, and
bottleneck plusargs, then reports timed cycles and checks metrics against the
table above using the default `--max-regression-pct 0.01` tolerance. Use
`--runner xsim-sh` when DSim is blocked by license availability.
The current OpenSBI platform-probe slice used that fallback for the hard DS/CM
gate because the DSim benchmark row hit a simulator scheduler iteration limit
on CoreMark before the timed window completed, while XSim completed all four
rows cleanly.

The equivalent expanded command remains:

```bash
python3 tools/run_benchmarks.py --runner dsim --run-class dse \
  --manifest tests/benchmarks/stage1_signoff.json \
  --bench dhrystone_100_checkedin \
  --bench dhrystone_300_stage1_anchor \
  --bench coremark_iter1_generalization \
  --bench coremark_iter10_checkedin \
  --mechanism-name stage3_linux_rtl_guard \
  --mechanism-class default_rtl \
  --plusarg +FETCH_DELIVERY_CHECK \
  --plusarg +FETCH_DELIVERY_STRICT \
  --plusarg +FETCH_OWNER_CHECK \
  --plusarg +FETCH_OWNER_STRICT \
  --plusarg +BRANCH_RECOVERY_CHECK \
  --plusarg +BRANCH_RECOVERY_STRICT \
  --plusarg +PERF_PROFILE \
  --plusarg +PERF_COUNTERS \
  --plusarg +STAT_DUMP \
  --plusarg +BOTTLENECK_PROFILE
```

Gate rules:

- Rebuild the simulator from the current RTL before running the guard.
- All four rows must pass endpoint checks.
- Timed cycles are reported against the diagnostic `0.01%` cycle envelope, but
  cycle count alone is not a hard failure.
- Performance metrics must stay within the `0.01%` regression tolerance versus
  the baseline table above.
- Owner, delivery, branch-recovery, stale-owner, legacy loop-buffer, and
  standalone decoded-op replay checks must remain clean.
- Any performance regression blocks the RTL commit unless the change is
  explicitly separated as a performance trade-off and approved before
  promotion.
- The existing bare-metal `tohost` ABI is allowed for this regression gate
  because it is a testbench endpoint. It must not be used as the Linux boot
  endpoint or reintroduced into the core RTL.

## rv64gc-v1 Reference

Useful v1 assets:

| v1 asset | What to reuse | What to change for v2 |
|---|---|---|
| `sw/build_mainline_linux.sh` | Linux plus OpenSBI build flow, initramfs creation, DTB compile, `fw_payload.elf` image generation | Move to a v2 `sw/` or `tools/linux_boot/` flow with reproducible output paths and no WSL/PowerShell assumption |
| `sw/dts/rv64gc_mainline.dts` | Simple single-core Linux device tree with DRAM at `0x80000000`, CLINT, and NS16550A UART at `0x10000000` | Use `mmu-type = "riscv,sv48"` as the primary Linux target, with Sv39 retained as a directed-test fallback |
| `sw/initramfs/mainline/init.c` | Tiny initramfs milestone that prints `BOOT OK` | Keep the milestone idea, but terminate through UART/log matching or platform poweroff, not `tohost` |
| `src/rtl/platform/clint.sv`, `plic.sv`, `uart_16550.sv` | Concrete platform-device implementation references | Port deliberately under `src/rtl/platform/` with clean core memory-bus/MMIO boundaries |
| `src/rtl/core/mmu/{itlb,dtlb,ptw}.sv` | Translation architecture reference | Re-evaluate before porting; v2 backend/frontend contracts differ and need a clean integration plan |
| `src/sim/run_mainline_linux*.ps1` | Run knobs, UART log, status interval, max-cycle controls | Replace with Linux-friendly Python runner in v2; keep PowerShell only as optional wrapper |

v1 method to avoid:

- `+TOHOST_ADDR=80040f10` and HTIF-style DTB nodes were useful for old harness
  completion, but they are not the right Stage 3 termination mechanism.
- Linux boot should not depend on a `tohost` symbol or a fixed `tohost` address.
- A Linux-capable core should not know whether the software is OpenSBI, Linux,
  riscv-tests, Dhrystone, or CoreMark.

v1 status caveat:

- The archived v1 boot logs show useful progress into S-mode Linux, but also
  long stalls after entering high kernel virtual addresses. Treat v1 as a map
  of required components, not as a known-good implementation to clone.
- The strongest archived v1 console logs reach Linux user-space handoff:
  `Run /init as init process`. They do not show the final `BOOT OK` line from
  the tiny initramfs. For v2, `/init` handoff and `BOOT OK` are separate
  milestones.

### v1 Full Linux Methodology Reference

The v1 full Linux flow is the right starting methodology for v2 because it
used a real firmware/kernel/initramfs stack instead of a benchmark image:

1. Build a tiny static initramfs `/init`.
   - v1 used a small C init program built with `riscv64-linux-gnu-gcc -static`
     and configured through Linux `CONFIG_INITRAMFS_SOURCE`.
   - The init program printed an early boot marker before more complex device
     setup. v2 should keep this early marker and make `BOOT OK` the final
     Stage 3 userspace milestone.
2. Build a reduced single-core Linux kernel.
   - v1 started from defconfig, disabled SMP/modules/network/USB and optional
     ISA extensions that were not part of the target, kept MMU support, early
     console, SBI, timer, and initramfs support, then built `Image`.
   - v2 should follow the same reduction discipline, but keep the target ISA
     aligned with current RTL: `rv64imafdc_zicsr_zifencei`, ABI `lp64d`, and
     Sv48 as the primary target.
3. Compile a simple mainline DTB.
   - v1's mainline DTS used DRAM at `0x80000000`, CLINT at `0x02000000`, and a
     polling NS16550A UART at `0x10000000`.
   - The useful v1 DTS shape is the `rv64gc_mainline.dts` style, not the older
     HTIF or LupIO variants.
4. Build OpenSBI generic `fw_payload.elf`.
   - v1 used `FW_TEXT_START=0x80000000`, `FW_PAYLOAD_OFFSET=0x200000`, and
     `FW_PAYLOAD_FDT_ADDR=0x86000000`.
   - v2 should keep those addresses unless the memory map changes, so reset,
     firmware, kernel payload, and DTB placement stay easy to compare.
5. Convert the firmware payload to the simulator memory format.
   - v1 converted `fw_payload.elf` to a hex image for the simulator.
   - v2 should keep this as an artifact-producing build step under
     `build/linux_boot/`, with source/config files tracked and large generated
     artifacts left out of git.
6. Run with two independent evidence streams.
   - v1 kept a UART console log for Linux-visible progress and a simulator
     status log for internal PC, privilege, CSR, trap, MMU, load/store, timer,
     and platform state.
   - v2 should preserve this split. UART proves software-visible progress;
     simulator status explains stalls and pipeline/platform failures.

v2 milestone order should be:

| Milestone | Evidence source | Why it matters |
|---|---|---|
| OpenSBI banner | UART log | Firmware image, reset PC, UART MMIO, and basic M-mode execution work |
| OpenSBI platform probe | UART plus simulator status | CLINT/timer and platform DTB data are plausible |
| Linux early console | UART log | OpenSBI entered S-mode payload and Linux can print early |
| `clocksource: riscv_clocksource` | UART log | timer and SBI time path are far enough for Linux timekeeping |
| `10000000.serial: ttyS0` | UART log | normal UART driver is bound after earlycon |
| `Freeing unused kernel image` | UART log | kernel init progressed beyond early memory setup |
| `Run /init as init process` | UART log | initramfs handoff happened |
| `BOOT OK` | UART log or syscon poweroff | v2 Stage 3 userspace pass milestone |

What v2 should copy from v1 methodology:

- the OpenSBI generic payload flow,
- the minimal Linux config discipline,
- the Sv48 mainline DTS shape with DRAM, CLINT, and NS16550A UART,
- the small static initramfs with an early marker,
- the dual log model: UART console plus simulator status/deadlock trace,
- periodic status snapshots with enough architectural state to root cause a
  stall without re-running blindly.

What v2 should not copy:

- HTIF or a `tohost` DTB node as the Linux completion mechanism,
- fixed `+TOHOST_ADDR` pass/fail handling for Linux,
- old LupIO devices before the simpler UART/CLINT path is fully working,
- direct testbench snooping of core-internal pipeline state for functional
  completion,
- PowerShell-specific runner structure as the primary v2 flow.

Implemented methodology adjustment for v2:

- `tools/run_linux_boot.py` classifies the milestone table above and can
  report the last reached milestone on timeout.
- The Linux simulation status path can dump the same kind of actionable
  state v1 used: committed PC, privilege mode, trap cause, `satp`, interrupt
  CSRs, outstanding load/store or MMIO request, `mtime`, `mtimecmp`, and UART
  state.
- `/init` handoff and `BOOT OK` are separate pass levels. This prevents a
  kernel boot from being mistaken for a complete userspace milestone.
- Keep the DS/CM hard gate before and after any RTL changes made while chasing
  Linux progress.

## Current v2 Starting Point

| Area | Current v2 state | Stage 3 implication |
|---|---|---|
| Core boundary | `rv64gc_core_top.sv` exposes memory request/response, interrupt inputs, and `time_val`; no fixed `tohost` port | Good ASIC-style boundary to preserve |
| Reset | frontend reset vector is `0x80000000` | Compatible with OpenSBI `FW_TEXT_START=0x80000000` |
| Privilege CSRs | `csr_file.sv` has M/S privilege state, delegation CSRs, `satp`, traps, `mret`, `sret`, interrupt inputs | Basic OpenSBI trap and handoff validation now passes; Sv48 and Linux exception behavior still need directed validation |
| RV64GC ISA | Integer, atomics, compressed, and now F/D floating point are integrated in the core RTL and advertised through `misa` | Keep FP support in the ASIC-style core datapath; do not emulate FP in the testbench |
| MMU | `src/rtl/core/mmu/` is empty; caches use physical addresses | Linux cannot boot until instruction/data translation and page faults are implemented |
| Platform devices | L0 `tb_linux` now has an uncached MMIO path, polling UART, and CLINT timer/software interrupt block; PLIC is only a reserved zero-response range | OpenSBI platform probing now passes; Linux needs larger memory and real external interrupt behavior before enabling more devices |
| Simulation memory | `sim_memory.sv` is a 2 MB byte-addressed RAM loaded by `$readmemh` | Linux needs much larger DRAM and an image loader that can handle OpenSBI plus kernel payload |
| Interrupt hookup | `tb_linux.sv` connects CLINT `mtime`, `mtip`, and `msip`; the existing benchmark `tb_top.sv` still ties interrupts low | OpenSBI reaches platform probing with the CLINT path present; Linux timer and external interrupt validation remain ahead |
| Endpoint | Current bare-metal rows use testbench-observed stores to configurable `TOHOST_ADDR` | Keep for bare-metal tests only; Stage 3 uses UART/log/syscon milestones |

## Current Scaffold Status

Implemented scaffold commit: `3d100ef`.

What exists now:

- `tools/run_stage3_rtl_guard.py` rebuilds the selected simulator and enforces
  the four-row DS/CM gate before any Stage 3 RTL promotion.
- `tools/run_linux_boot.py` builds and later runs Linux-platform images through
  UART/log milestones rather than `tohost`.
- `tools/run_linux_boot.py` now classifies staged boot milestones:
  M-mode UART smoke, OpenSBI banner, OpenSBI platform probe, Linux early
  console, RISC-V clocksource, NS16550 UART driver bind, kernel image free,
  `/init` handoff, and final `BOOT OK`.
- `tb_linux.sv` supports opt-in `+STATUS` snapshots with PC, privilege, `satp`,
  timer, interrupt, MMIO, ROB, and UART counter state. This is simulation
  boundary visibility only; it does not add Linux-specific logic to the core.
- `sw/linux_boot/` contains the Sv48 DTS, minimal initramfs source, M-mode UART
  smoke source, linker script, and Linux/OpenSBI build wrapper.
- The M-mode smoke image builds to `build/linux_boot/m_mode_uart_smoke.hex`.
- The OpenSBI banner image builds to
  `build/linux_boot/fw_payload_opensbi_banner.hex` using a tiny S-mode hang
  payload. This isolates M-mode firmware and platform probing from the later
  Linux/MMU problem.

Current L0 RTL slice:

- `rv64gc_core_top.sv` now exposes a clean uncached data MMIO request/response
  interface at the core boundary. This is a CPU platform bus, not a benchmark
  endpoint.
- `lsu.sv` routes UART, CLINT, and reserved PLIC range load/store accesses to
  that uncached interface instead of the D-cache. Store requests are issued
  after commit through the committed store buffer, and a response acknowledges
  the store buffer entry.
- `src/rtl/platform/uart_16550.sv`, `clint.sv`, and `mmio_platform.sv` provide
  synthesizable platform RTL for the first UART and timer/software interrupt
  milestones. UART TX capture and pass/fail matching stay in `tb_linux.sv`.
- `build_dsim_linux.sh` builds a separate `tb_linux` DSim image so Linux
  bring-up does not disturb the existing benchmark harness image.
- `build_xsim_linux.sh` and `run_xsim_linux.sh` provide an equivalent XSim
  `tb_linux` snapshot for workflow fallback when the single DSim cloud lease is
  unavailable. DSim remains the practical long-run backend for now; the XSim
  Linux snapshot builds but is too slow for promoted OpenSBI milestone evidence
  on the current host.
- The M-mode UART smoke now passes through the platform path:
  `linux_boot_results/stage3_l0_uart_smoke_clint_lane_fix`.
- The required DS/CM RTL guard passed after the L0 RTL slice:
  `benchmark_results/stage3_rtl_guard_20260510_l0_mmio_platform_clint_lane`.

Resolved L0 blocker:

- The earlier blocker was the absence of a device-visible uncached MMIO path.
  This is now implemented without snooping internal LSU store signals in the
  testbench and without reintroducing `tohost` into core RTL.
- The first smoke issue after the path landed was an LSU MMIO store replay:
  the committed store buffer entry remained visible during the response
  acknowledge cycle, allowing the same UART store to launch twice. The fix
  blocks a new MMIO store launch on the store-response fire cycle, so each
  committed MMIO store produces exactly one platform request.
- CLINT `mtime` and `mtimecmp` accesses are byte-lane aware, so 32-bit high
  word accesses are right-justified on reads and update the addressed byte
  lanes on writes. This keeps the device model suitable for OpenSBI rather
  than only for the current UART smoke.

Current RV64GC/FPU slice:

- v1's FPnew-based out-of-shell FPU has been integrated as real core RTL:
  FP decode, FP rename/RAT/free-list state, FP physical register file,
  serialized FPU issue path, FP CDB writeback, FP load/store data movement,
  NaN boxing for `FLW`, and CSR `fflags`/`frm`/FS dirty plumbing.
- The core now advertises RV64GC through `misa` (`A`, `C`, `D`, `F`, `I`,
  `M`, `S`, `U`). The Linux DTS and OpenSBI build flow use
  `rv64imafdc_zicsr_zifencei` with `lp64d`.
- The L2/I-cache fill interface now has an accepted handshake. The I-cache
  holds a fill request until L2 accepts either a miss allocation or hit replay,
  then stops retrying. This removed duplicate L2 fill traffic exposed by the
  corrected L2 response queue and preserved the DS/CM performance gate.
- DSim builds default to `-no-sva` because DSim's SVA finalization path can
  hang on the bound frontend assertions and FPnew common-cell assertions. The
  procedural strict owner, delivery, branch-recovery, performance, stat, and
  bottleneck checkers remain enabled by plusarg in the guard runs.

Validation for this slice:

- DSim FP smoke `tests/asm/rv64ufd_fp_smoke.S` passes:
  `PASS at cycle 95`, `mcycle=55`, `minstret=63`. Covered operations include
  `FMV.D.X`, `FMV.X.D`, `FADD.D`, `FMUL.D`, `FSD`, `FLD`, `FLW` NaN boxing,
  `FCVT.L.D`, and `FCVT.D.L`.
- Stage 3 DS/CM hard guard passed after the FPU and L2 accepted-handshake
  slice:
  `benchmark_results/stage3_rtl_guard_rv64gc_fpu_guard_icfill_accept_20260510`.

| Row | Timed cycles | Limit | Metric |
|---|---:|---:|---:|
| Dhrystone 100 | `18,155` | `18,161` | `3.134960 DMIPS/MHz` |
| Dhrystone 300 | `53,440` | `53,469` | `3.195090 DMIPS/MHz` |
| CoreMark 1 | `154,185` | `154,233` | `6.485715 CM/MHz` |
| CoreMark 10 | `1,491,294` | `1,491,334` | `6.705586 CM/MHz` |

OpenSBI status after RV64GC/FPU integration:

- `linux_boot_results/stage3_rv64gc_fpu_opensbi_1m_final_20260510` reaches the
  1M-cycle cap with no illegal-instruction or FPU wedge evidence. It retires
  `2,155,026` instructions, with the ROB empty at timeout and no architectural
  ordering assertion failures.
- Last symbolized committed PC is in OpenSBI `sbi_math.c:17`; the debug state
  shows an outstanding platform MMIO request rather than an FP pipeline hold.
  The next blocker is still platform/privileged bring-up, not the FPU datapath.
- XSim can compile the FP-enabled design, but its FP smoke conversion result
  has not been promoted as authority yet. Use DSim for the current FP signoff
  until the XSim `FCVT` mismatch is separately root-caused.

Current v1-methodology runner slice:

- M-mode UART smoke passes through the milestone classifier:
  `linux_boot_results/stage3_runner_milestone_smoke_20260510`.
- A short timeout sanity run emits `[LINUX_STATUS]` snapshots with PC,
  privilege, `satp`, timer, interrupt, MMIO, ROB, and UART counter state.
- `build_dsim_linux.sh` passes after the status snapshot addition.
- The Stage 3 DS/CM hard guard still passes:
  `benchmark_results/stage3_rtl_guard_stage3_linux_runner_status_20260510`.

| Row | Timed cycles | Limit | Metric |
|---|---:|---:|---:|
| Dhrystone 100 | `18,155` | `18,161` | `3.134960 DMIPS/MHz` |
| Dhrystone 300 | `53,440` | `53,469` | `3.195090 DMIPS/MHz` |
| CoreMark 1 | `154,185` | `154,233` | `6.485715 CM/MHz` |
| CoreMark 10 | `1,491,294` | `1,491,334` | `6.705586 CM/MHz` |

Current OpenSBI platform-probe slice:

- A frontend RVC straddle blocker was root-caused at OpenSBI PC
  `0x8000b53a`: a same-owner prior-line ICQ response could remain at the head
  after the IFU work cursor advanced to the next line, leaving
  `packet_buf_count=0`, `icq_count=4`, and frontend stall asserted. The generic
  fix treats a same-owner ICQ head older than the current work line as stale, so
  the IFU can drain it and continue. This is an IFU/ICQ ownership fix, not
  firmware-specific logic.
- A targeted relocation-line trace showed a generic D-cache correctness bug:
  a cold write-allocate store miss was acknowledged before the line fill became
  resident, then the later L2 fill could overwrite the store data. The D-cache
  store-miss acknowledgement contract is now tightened so a store miss remains
  in the committed store buffer until a cache hit or same-line fill merge
  preserves the bytes.
- The committed store buffer forwarding path now searches newest to oldest and
  accounts for same-cycle committed-store enqueue visibility. This keeps
  load-after-store behavior correct while preserving the ordered committed
  store drain model.
- Divider issue is suppressed while the divider is busy, preventing a younger
  DIV from entering the shared serialized pipe while an older DIV result is
  still outstanding.
- Commit now treats serializing instructions as true commit-group boundaries.
  This fixed the OpenSBI semihosting probe sequence where a CSR write to
  `mtvec` and the following `ebreak` had previously retired in the same group,
  letting the exception observe the old trap vector.
- The Linux runner now streams simulator output directly to log files and the
  Linux testbench supports a generic UART milestone pattern. Milestone
  classification uses UART text, not simulator command-line text, so a target
  string in a plusarg cannot create a false pass.

Promoted validation for this slice:

- DSim OpenSBI platform-probe milestone passes:
  `linux_boot_results/stage3_opensbi_platform_dsim_pass_20260511`.
  The UART log reaches the OpenSBI platform block, reports
  `Platform Name : rv64gc-v2-linux-sim`, advertises `rv64imafdc`, and enters
  the payload handoff path. The UART milestone matcher exits at cycle
  `1,444,216`.
- The Stage 3 DS/CM hard guard passes on the rebuilt XSim benchmark snapshot:
  `benchmark_results/stage3_rtl_guard_opensbi_platform_probe_xsim_guard_20260511`.

| Row | Timed cycles | Diagnostic 0.01% cycles | Metric |
|---|---:|---:|---:|
| Dhrystone 100 | `18,082` | `18,162` | `3.147616 DMIPS/MHz` |
| Dhrystone 300 | `53,360` | `53,474` | `3.199880 DMIPS/MHz` |
| CoreMark 1 | `154,184` | `154,248` | `6.485757 CM/MHz` |
| CoreMark 10 | `1,491,293` | `1,491,483` | `6.705590 CM/MHz` |

DSim benchmark caveat:

- The DSim OpenSBI milestone is valid, but the DSim CoreMark guard row hit a
  DSim scheduler `IterLimit` at cycle `59,013` before the timed benchmark
  window completed. Raising the DSim iteration limit did not move the timestamp.
  The XSim guard above is therefore the promoted Stage 3 DS/CM gate for this
  slice. The DSim CoreMark convergence issue should be treated as simulator
  debug debt, not as evidence of a DS/CM functional or performance regression.

## Stage 3 Architecture Direction

### Platform Shape

Use a simple single-core SoC shell around the existing core:

| Address | Device | Required for first Linux boot? | Notes |
|---:|---|---|---|
| `0x8000_0000` | DRAM | yes | Start with 128 MB to match v1 DTS; allow larger later |
| `0x0200_0000` | CLINT or ACLINT | yes | Provides `mtime`, `mtimecmp`, and `msip` for OpenSBI/Linux timer flow |
| `0x1000_0000` | NS16550A UART | yes | Use polling first; interrupts can come later |
| `0x0c00_0000` | PLIC | optional for first polling-UART boot | Needed when UART/external interrupts are enabled |
| `0x2000_5000` or similar | syscon poweroff | optional | Useful for clean simulation exit from initramfs |

The first DTB should advertise only devices that actually work. Do not expose a
PLIC, block device, or LupIO device until the RTL/sim platform supports it.

### Software Shape

Initial software image:

1. Build an OpenSBI-only banner image:
   - OpenSBI generic platform,
   - `FW_TEXT_START=0x80000000`,
   - `FW_FDT_PATH=<rv64gc-v2 DTB>`,
   - tiny S-mode hang payload,
   - FDT and payload addresses kept inside the current 2 MB smoke memory.
2. Build a minimal Linux kernel with:
   - `CONFIG_SMP=n`,
   - `CONFIG_MMU=y`,
   - `CONFIG_PGTABLE_LEVELS=4`,
   - `CONFIG_RISCV_ISA_V=n`,
   - no modules,
   - initramfs embedded,
   - early console enabled.
3. Build OpenSBI generic firmware for Linux:
   - `FW_TEXT_START=0x80000000`,
   - `FW_PAYLOAD_PATH=<Linux Image>`,
   - `FW_FDT_PATH=<rv64gc-v2 DTB>`,
   - `FW_PAYLOAD_OFFSET=0x200000`,
   - DTB placed at a stable high DRAM address such as `0x86000000`.
4. Load `fw_payload.elf` or a generated memory image into simulated DRAM.

Initial kernel command line:

`console=ttyS0 earlycon=uart8250,mmio,0x10000000 loglevel=8 ignore_loglevel nokaslr`

Use `nokaslr` during bring-up to keep traces stable.

### Endpoint Shape

Stage 3 completion should be one of:

- UART log contains a chosen milestone, for example `BOOT OK`,
- kernel panic/oops is detected and the run is marked failed,
- platform syscon poweroff is written and the harness exits,
- max-cycle timeout is reached and the run is marked incomplete.

`tohost` remains available only for existing bare-metal score rows. It is not a
Linux boot mechanism and must not be required by OpenSBI, Linux, the core, or
the Linux DTB.

## Bring-Up Gates

### L0: Platform Skeleton And Loader

Goal: run a tiny M-mode firmware image from larger DRAM and print over UART.

Tasks:

- Add or port a large simulation DRAM model, parameterized to at least 128 MB.
- Add an MMIO decode shell outside the core.
- Add a simple UART model with TX capture to a log file.
- Add an ELF or binary loader path for OpenSBI-style images.
- Keep existing bare-metal `tohost` benchmark flow working as a separate ABI.

Pass criteria:

- M-mode UART hello-world prints a known string.
- Existing DS/CoreMark smoke still passes through the current harness ABI.
- If any RTL changed, the full hard RTL modification gate above passes.
- No synthesizable core RTL contains benchmark endpoint logic.

### L1: OpenSBI M-Mode Boot

Goal: boot OpenSBI far enough to print the banner and probe platform devices.

Tasks:

- Add CLINT or ACLINT timer/software interrupt model.
- Connect `mtip`, `msip`, and `time_val` through the platform shell.
- Build `fw_payload.elf` with a tiny payload or dummy next stage first.
- Validate CSR trap/delegation and `mret` behavior with OpenSBI.

Pass criteria:

- UART log reaches OpenSBI banner and platform probe.
- No illegal instruction, trap-loop, or silent WFI/deadlock before payload handoff.
- If any RTL changed, the full hard RTL modification gate above passes.

### L2: MMU Bring-Up

Goal: support Sv48 instruction and data translation well enough for S-mode
Linux entry, with Sv39 retained as a compatibility and directed-test subset.

Tasks:

- Implement or port ITLB, DTLB, and PTW under v2 frontend/LSU contracts.
- Support `satp` mode Bare, Sv48, and Sv39.
- Walk four Sv48 levels and three Sv39 levels through one parameterized PTW.
- Enforce Sv48 canonical virtual addresses by sign extension from bit 47.
- Implement page fault causes and `stval`/`mtval` behavior needed by Linux.
- Handle `sfence.vma` as a serializing TLB flush.
- Add translation-aware instruction fetch and load/store exception paths.

Pass criteria:

- Bare-metal Sv48 page-table smoke passes for fetch, load, store, execute
  permission, user/supervisor permission, superpage, canonical-address, and
  page-fault cases.
- The same directed page-table suite has Sv39 coverage for the shared PTW/TLB
  subset.
- OpenSBI can enter S-mode payload with virtual memory still disabled or with
  simple test page tables before full Linux.
- If any RTL changed, the full hard RTL modification gate above passes.

Execution status:

- First RTL slice completed: `l2_cache.sv` now has a dedicated read-only PTW
  source port with `ready`, `accepted`, and 64-byte response routing. The port
  uses the existing L2 MSHR and response-source machinery (`SRC_PTW = 2'd3`)
  instead of bypassing the cache hierarchy or adding a simulation-only memory
  path.
- `rv64gc_core_top.sv` ties this PTW port off until the walker/TLB slice is
  connected. This is behavior-neutral for Bare-mode DS/CM and creates the
  ASIC-style memory-hierarchy seam required by the Sv48 PTW.
- Validation for this slice:
  `benchmark_results/stage3_rtl_guard_20260511_l2_ptw_port`.
- Second RTL slice completed: `itlb.sv`, `dtlb.sv`, and `ptw.sv` were added
  under `src/rtl/core/mmu/` and included in all DSim/XSim build scripts. They
  are intentionally uninstantiated until the next fetch/LSU integration slice.
  The shared PTW supports Sv48 and Sv39 walks, canonical-address checks, page
  faults, superpage alignment checks, and cache-line PTE extraction through the
  L2 PTW port.
- Validation for the standalone MMU module slice:
  `benchmark_results/stage3_rtl_guard_20260511_mmu_modules`.
- Third RTL slice completed: `rv64gc_core_top.sv` now instantiates the shared
  PTW and connects it to the L2 PTW source port. ITLB/DTLB miss request inputs
  remain tied off, so this validates elaboration and the PTW/L2 memory
  hierarchy seam without enabling translation yet.
- Validation for the PTW-to-L2 integration slice:
  `benchmark_results/stage3_rtl_guard_20260511_ptw_l2_integrated`.
- Fourth RTL slice completed: `csr_file.sv` now exposes the translation
  permission state needed by the TLBs (`mstatus.MPRV`, `MPP`, `SUM`, `MXR`).
  `rv64gc_core_top.sv` instantiates ITLB and DTLB, connects PTW fill outputs
  into both TLBs, derives the data privilege mode for future MPRV handling, and
  drives a shared TLB/PTW invalidation pulse on committed `SFENCE.VMA` or
  `satp` writes. Lookup requests remain tied off, so this slice validates the
  CSR/PTW/TLB scaffold without enabling virtual-address translation yet.
- Validation for the CSR/PTW/TLB scaffold slice:
  `benchmark_results/stage3_rtl_guard_20260511_tlb_scaffold_dsim`.
- Fifth RTL slice completed: `lsu.sv` now exposes a DTLB sideband interface
  for data-translation lookup and PTW miss requests. `rv64gc_core_top.sv`
  connects that sideband into the instantiated DTLB/PTW chain, but keeps
  `data_vm_active_i` tied low until the translated data-cache/MMIO address path
  is ready. This creates the LSU-to-DTLB/PTW seam without changing Bare-mode
  memory behavior.
- Validation for the disabled LSU DTLB sideband slice:
  `benchmark_results/stage3_rtl_guard_20260511_lsu_dtlb_sideband`.
- Sixth RTL slice completed: the load/store issue contract is now
  DTLB-miss-aware while data translation remains disabled. `lsu.sv` consumes
  the STA issue candidate separately from final STA issue valid, so a future
  store-address DTLB miss can suppress the store IQ entry without forming a
  ready/valid loop or marking the store address complete. Load port 0 now has
  a DTLB-miss suppression hook, and load port 1 is held when data VM is active
  until a second translated load path is deliberately added. `data_vm_active_i`
  remains tied low in `rv64gc_core_top.sv`, so Bare-mode memory behavior is
  unchanged.
- Validation for the DTLB issue-suppression contract slice:
  `benchmark_results/stage3_rtl_guard_20260511_lsu_dtlb_suppress_contract`.

| Row | Timed cycles | Diagnostic 0.01% cycles | Metric |
|---|---:|---:|---:|
| Dhrystone 100 | `18,082` | `18,162` | `3.147616 DMIPS/MHz` |
| Dhrystone 300 | `53,360` | `53,474` | `3.199880 DMIPS/MHz` |
| CoreMark 1 | `154,184` | `154,248` | `6.485757 CM/MHz` |
| CoreMark 10 | `1,491,293` | `1,491,483` | `6.705590 CM/MHz` |

### L3: Linux Early Boot

Goal: enter Linux and reach early console output.

Tasks:

- Build v2 DTB with only working devices.
- Build minimal Linux plus initramfs.
- Use OpenSBI `fw_payload.elf` or equivalent payload image.
- Add Linux-specific progress probes in the simulation boundary only:
  UART log scanner, trap-loop detector, WFI/no-retire watchdog, optional PC
  symbolization from `vmlinux`.

Pass criteria:

- UART shows Linux decompression/early boot messages.
- The run reaches `start_kernel` progress or first initramfs output.
- If any RTL changed, the full hard RTL modification gate above passes.

### L4: Initramfs Milestone

Goal: reach userspace `/init` and print `BOOT OK`.

Tasks:

- Keep the initramfs tiny and deterministic.
- Avoid block devices initially.
- Add optional syscon poweroff after printing `BOOT OK`.

Pass criteria:

- UART log includes `BOOT OK`.
- Simulation terminates by syscon or runner log match.
- No `tohost` dependency.
- If any RTL changed, the full hard RTL modification gate above passes.

### L5: Robustness And Regression

Goal: make Linux boot repeatable enough to use as a regression target.

Tasks:

- Add a `tools/run_linux_boot.py` runner with manifest, image provenance,
  timeout, UART log, and status summary.
- Keep Linux artifacts out of git unless they are tiny source/config files.
- Archive exact build hashes and command lines in result directories.
- Add short privileged/MMU/unit tests so Linux is not the first debug point for
  every bug.

Pass criteria:

- Rebuilt image boots to the same milestone.
- Runner emits PASS/FAIL/TIMEOUT with log paths.
- Existing bare-metal benchmark runner remains unchanged except for sharing
  loader utilities where useful.
- Every RTL commit in the Stage 3 sequence has an attached DS/CM guard run with
  no performance regression.

## First Implementation Order

1. Create the v2 Linux software/platform directory structure and copy only the
   reusable v1 source/config ideas:
   - DTS template,
   - initramfs `init.c`,
   - Linux/OpenSBI build script skeleton.
2. Build an M-mode UART hello-world image before Linux:
   `sw/linux_boot/build_linux_boot.sh --smoke`.
3. Add the platform shell and UART/DRAM loader around the core. Done for the
   M-mode UART smoke path using the existing hex memory loader.
4. Validate CLINT timer/software interrupt behavior under OpenSBI and reach the
   OpenSBI platform-probe milestone. Done in
   `linux_boot_results/stage3_opensbi_platform_dsim_pass_20260511`.
5. Implement Sv48 MMU/PTW/TLB and privileged regression tests, keeping Sv39 as
   a fallback mode.
6. Boot minimal Linux to early console.
7. Boot to initramfs `BOOT OK`.

Current Stage 3 scaffold commands:

```bash
sw/linux_boot/build_linux_boot.sh --smoke
sw/linux_boot/build_linux_boot.sh --opensbi
python3 tools/run_linux_boot.py --build --build-mode smoke
python3 tools/run_linux_boot.py --build-sim --build --build-mode smoke --run \
  --smoke-check --target-milestone m_mode_uart_smoke
python3 tools/run_linux_boot.py --build --build-mode opensbi --run \
  --target-milestone opensbi_platform_probe
python3 tools/run_linux_boot.py --build --build-mode linux
```

The Linux runner can now run the M-mode UART smoke and has a dedicated OpenSBI
banner mode. It records reached milestones and the last reached milestone in
`summary.json` and `summary.md`, so a timeout now reports the exact boot level
instead of only `PASS` or `TIMEOUT`. RV64GC/FPU support is integrated and
guarded against DS/CM regression. OpenSBI platform probing now works through
the ASIC-style core/platform boundary. Full Linux remains blocked until larger
image loading is validated and Sv48 translation is implemented.

## Near-Term Non-Goals

- Do not boot a disk-backed root filesystem.
- Do not add SMP.
- Do not enable vector, hypervisor, Zicbom/Zicboz, crypto, Zfh, or Zcb.
- Do not revive HTIF/tohost as the Linux pass/fail path.
- Do not optimize Linux performance before the boot contract is correct.
- Do not expose devices in the DTB before the platform implements them.

## Open Questions To Resolve Before Next RTL Work

| Question | Default decision |
|---|---|
| Sv39 or Sv48 first? | Sv48 first for the Linux signoff target. Sv39 remains a directed-test and compatibility subset. |
| UART or SBI console first? | UART first for Linux visibility; SBI console is useful during OpenSBI but should still write through platform UART. |
| CLINT or ACLINT? | CLINT is acceptable for first boot because v1 already used it; ACLINT can replace it later if we want newer platform naming. |
| ELF loader or hex only? | Add ELF/binary loading in the runner or memory model. Keep byte-hex compatibility for existing tests. |
| How to stop the sim? | UART milestone or syscon poweroff. Never a core `tohost` port. |
| What is the first success milestone? | OpenSBI platform probe is achieved; next Linux success is early console, then initramfs `BOOT OK`. |

## Current Verdict

Stage 3 remains feasible, but not by just running v1's image on v2. The first
platform blockers are resolved: v2 can execute an M-mode UART smoke and reach
the OpenSBI platform-probe milestone through device-visible UART and CLINT
paths while preserving the DS/CM performance gate. The remaining blockers are
larger platform completeness and privileged-memory support, not benchmark
harness policy:

- v2 has the right clean core boundary for ASIC-style Linux bring-up.
- v2 now has an L0 UART/CLINT platform path for early M-mode smoke and L1
  OpenSBI platform probing.
- v2 now has real RV64GC F/D execution in core RTL, with DSim FP smoke passing
  and DS/CM performance preserved.
- v2 does not yet have the Sv48 MMU/PTW/TLB path Linux requires.
- v2 does not yet have large-memory loading, Linux-visible PLIC/external
  interrupts, or validated Linux timer behavior.
- v1 provides useful references for those pieces, but its `tohost`/HTIF-style
  completion should not be carried forward.

The next Stage 3 implementation should move to Sv48 MMU/PTW/TLB support before
attempting a full Linux kernel boot. Sv39 should stay as a directed-test subset,
but the primary Linux path is four-level Sv48 because that matches the intended
Linux signoff configuration.

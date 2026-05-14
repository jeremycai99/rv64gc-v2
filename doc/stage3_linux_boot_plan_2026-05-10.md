# Stage 3 Linux Boot Plan

Date: May 10, 2026

Status: performance optimization is paused. Stage 3 is the Linux boot bring-up
phase. The RV64GC instruction compliance prerequisite is closed on the current
RTL candidate, the DS/CM hard performance gate is clean, and the trimmed
OpenSBI plus Linux image now reaches the Linux early console milestone through
the ASIC-style core boundary. The next Linux target is continuing beyond
`earlycon:` toward timer, UART-driver, kernel-init, and userspace milestones.

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

## Highest Priority: RV64GC Instruction Compliance Gate

Linux kernel bring-up must stay behind a full RV64GC instruction compliance
gate. This gate is now passing for the current RTL candidate, and it remains
mandatory after any further RTL change. Custom ISA smokes and directed VM
smokes are valuable, but they are not enough evidence for Linux-scale
execution.

Rationale:

- Linux setup and early boot exercise broad integer, multiply/divide, atomic,
  compressed, floating-point, CSR, fence, trap, and memory-ordering behavior.
- A kernel stall can be a pipeline bug, an MMU bug, or a basic ISA semantic
  bug. Without full instruction compliance, Linux traces are too ambiguous.
- The F/D integration and `misa` advertising make the core claim RV64GC. That
  claim must be backed by standard test evidence before using Linux as the
  primary correctness workload.

Required scope before continuing Linux kernel debug:

- RV64I base integer tests: `rv64ui`.
- RV64M multiply/divide tests: `rv64um`.
- RV64A atomic tests: `rv64ua`.
- RV64C compressed tests: `rv64uc`.
- RV64F single-precision floating-point tests: `rv64uf`.
- RV64D double-precision floating-point tests: `rv64ud`.
- `Zicsr` and `Zifencei` coverage.
- Directed privilege, trap, interrupt, and Sv48/Sv39 MMU smokes remain
  required, but they are additional Linux readiness checks rather than a
  substitute for RV64GC instruction compliance.

Compliance infrastructure direction:

1. Reuse the v1 `riscv-tests` infrastructure as a methodology reference, or
   import a standard `riscv-tests` or `riscv-arch-test` flow into v2.
2. Add a v2 compliance manifest and runner that builds or consumes ELF/hex
   images and reports per-test `PASS`, `FAIL`, or `TIMEOUT`.
3. Support the standard compliance-suite `tohost/fromhost` convention only in
   the simulation platform, testbench, or runner. Do not add a `tohost` port or
   compliance-specific endpoint logic to synthesizable core RTL.
4. Keep optional non-GC extensions such as Zba, Zbb, Zbs, and Zicond in a
   separate optional-extension row. They must not be counted as RV64GC
   compliance evidence.
5. If an RTL fix is required, rerun the failing compliance subset first, then
   rerun the Stage 3 DS/CM hard gate before committing the RTL change.

Compliance acceptance:

- All required RV64GC rows pass on a rebuilt DSim or XSim image from the
  current working tree.
- No hidden allowlist is permitted for required RV64GC failures. Any waiver
  must be explicit, documented, and limited to unsupported optional extensions.
- The existing Stage 3 DS/CM hard gate passes after every RTL change made to
  fix compliance.
- Only after this gate passes should Stage 3 resume Linux kernel debug.

Current compliance status:

- Full profiled RV64GC compliance passes on the current RTL candidate:
  `benchmark_results/rv64gc_compliance_linux_frontend_scrub_profiled_20260512`
  reports `113/113` rows with endpoint `PASS` and signoff gate `PASS`.
- The compliance audit is captured in
  `doc/rv64gc_compliance_audit_2026-05-12.md`.
- v2 has directed Sv48 MMU, permission, A/D, fault, and canonical-address
  smokes. These prove important privileged-memory contracts but do not replace
  instruction compliance.
- Linux kernel debug may proceed only while this compliance gate and the DS/CM
  hard performance gate stay clean after each RTL change.

## Current Linux Evidence

Latest validated Linux milestone:

- Artifact:
  `linux_boot_results/stage3_linux_clean_version_early_console_dsim_20260512`.
- Result: `PASS`, target milestone `linux_early_console`.
- UART reached `earlycon:` at cycle `3,973,283`.
- The same run prints the OpenSBI banner, OpenSBI platform probe data, Linux
  version line, machine model, SBI extension detection, and Linux early
  console marker.
- Kernel version metadata is intentionally pinned by
  `sw/linux_boot/build_linux_boot.sh`: `CONFIG_LOCALVERSION="-rv64gc-v2-sim"`,
  `CONFIG_LOCALVERSION_AUTO=n`, `KBUILD_BUILD_USER=rv64gc-v2`,
  `KBUILD_BUILD_HOST=linux-sim`, and a deterministic
  `KBUILD_BUILD_TIMESTAMP`. This keeps the UART banner tied to the v2 Linux
  simulation image instead of leaking the reused v1 Linux tree's SCM dirty
  state.
- Current UART banner:
  `Linux version 6.6.130-rv64gc-v2-sim (rv64gc-v2@linux-sim) ... #18 Tue May 12 12:52:57 PDT 2026`.

Next milestone attempt:

- Artifact:
  `linux_boot_results/stage3_linux_clocksource_10m_dsim_20260512`.
- Command target: `riscv_clocksource`, cycle cap `10,000,000`.
- Result: failed before the clocksource milestone. Linux reached early console,
  enabled Sv48 paging, then reported a kernel NULL pointer dereference:
  `Unable to handle kernel NULL pointer dereference at virtual address 0000000000000000`
  followed by `Oops [#1]`.
- Useful progress points from the DSim status log:
  at `2,000,000` cycles Linux was still in S-mode setup with `satp=0` and
  active retirement; at `3,000,000` cycles Linux had enabled paging with
  `satp=9000000000080a05`; at `4,000,000` cycles the core was still retiring
  while the Oops was being printed through early UART.
- The status PCs after the Oops symbolize into console/printk code
  (`serial8250_early_in`, `_printk`), so they are not the root fault PC. The
  next required run must enable `+LINUX_TRACE_TRAP` and avoid periodic status
  interleaving so the actual fault `sepc/scause/stval` and the full Linux Oops
  register dump are captured.

Latest clocksource investigation:

- The v1 reference boot log reaches `clocksource: riscv_clocksource`,
  `sched_clock`, and delay-loop calibration after `riscv-intc`. That sequence
  is the right next v2 milestone, but current v2 evidence does not yet prove a
  clocksource bug.
- The latest full-memory v2 clocksource probe,
  `linux_boot_results/stage3_linux_clocksource_probe_dsim_30m_retry2_20260513a`,
  was stopped after 15M cycles while still before the Linux clocksource path.
  UART reached Linux memory setup through `Initmem setup node 0
  [mem 0x80000000-0x83ffffff]`; it did not reach `Memory:`, `SLUB`,
  `NR_IRQS`, `riscv-intc`, `time_init`, or
  `clocksource: riscv_clocksource`.
- The same run shows no architectural deadlock at the stop point:
  `last_commit_cyc` tracked current cycle, no trap was reported, `time`
  advanced every cycle, `timecmp` remained disabled, and PCs symbolized into
  memory initialization (`memmap_init_range` and `__memset`). This is
  pre-clocksource forward progress, not a proven CLINT or Linux clocksource
  stall.
- OpenSBI timer evidence is clean in the current v2 image. OpenSBI discovers
  the CLINT path for IPI and timer and reports
  `Platform Timer Device     : aclint-mtimer @ 1000000Hz`. Linux also prints
  `SBI TIME extension detected` before the long memory-init region.
- Temporary `mem=24M` and `mem=48M` DTS probes are invalid for the clocksource
  milestone. Both enter Linux and recover from the expected MMU relocation
  exception, but then panic before `time_init()`:
  `Kernel panic - not syncing: memory_present: Failed to allocate 16777216 bytes
  align=0x40`. These runs prove the shorter memory cap is too small for the
  current kernel sparse-memory configuration; they do not implicate
  clocksource, CLINT, or CSR `time`.
- Do not use sub-64M memory-cap runs as clocksource evidence unless the kernel
  sparse-memory configuration is changed and the image proves it can pass
  `memory_present`.

SATP interpretation:

- A long window with `satp=0` is not by itself a deadlock. OpenSBI runs in
  M-mode with `satp=0`, and early Linux can still be executing identity-mapped
  S-mode setup code before enabling the final page table.
- The useful liveness signal is commit progress. In the latest passing run, the
  `2,000,000` cycle status line has `priv=1`, `satp=0`,
  `last_commit_cyc=1999998`, `commit_count=1`, active UART traffic, and no
  trap. This is forward progress, not a deadlock.
- Treat repeated identical `satp` values as a blocker only when paired with a
  stalled `last_commit_cyc`, no UART/MMIO movement, or a stable frontend/backend
  stall signature.

Frontend fix note:

- A broad predicted-control ICQ flush fixed the stale fallthrough boot hang but
  caused a large DS/CM regression. It is rejected and must not be revived as a
  full response-queue flush.
- The accepted candidate is a targeted redirect scrub in `ifu_line_fetch.sv`:
  after a predicted-control redirect it drains only queued current-owner lines
  whose line address does not match the redirected work line. This preserves
  Linux early-console progress without perturbing steady-state I-cache response
  delivery.
- Guard artifact:
  `benchmark_results/stage3_linux_frontend_scrub_guard_20260512` passes the
  Stage 3 DS/CM hard gate:
  DS100 `18,080` cycles, `3.147964 DMIPS/MHz`;
  DS300 `53,047` cycles, `3.218761 DMIPS/MHz`;
  CM1 `150,394` cycles, `6.649201 CM/MHz`;
  CM10 `1,454,994` cycles, `6.872881 CM/MHz`.

## Hard RTL Modification Gate

This is mandatory for every Stage 3 RTL change, including changes that appear
to be platform-only. A Linux boot fix is not promotable if it regresses the
committed DS/CM performance baseline.

Baseline reference:

Reference artifact: `benchmark_results/dse_stage2_ds_viability_profile_20260510`
on commit `bddfed8`.

The reference cycle counts are diagnostic anchors, not hard limits. A run is
acceptable only when the measured performance regression is no more than
`0.01%` versus the reference metric. The wrapper reports cycle movement so we
can spot suspicious drift, but the hard performance gate is the reported
DMIPS/MHz or CoreMark/MHz metric: it must not drop by more than `0.01%`.

| Row | Diagnostic cycle reference | Reference metric | Hard min metric with 0.01% tolerance |
|---|---:|---:|---:|
| Dhrystone 100 | `18,161` | `3.133924 DMIPS/MHz` | `3.133611 DMIPS/MHz` |
| Dhrystone 300 | `53,469` | `3.193357 DMIPS/MHz` | `3.193038 DMIPS/MHz` |
| CoreMark 1 | `154,233` | `6.483697 CM/MHz` | `6.483049 CM/MHz` |
| CoreMark 10 | `1,491,334` | `6.705406 CM/MHz` | `6.704735 CM/MHz` |

Required regression command shape after each RTL slice:

```bash
python3 tools/run_stage3_rtl_guard.py --runner dsim --run-id <date>_<slice>
```

The wrapper rebuilds the selected simulator, runs the four locked DS/CM rows
with the strict owner, delivery, branch-recovery, performance, stat, and
bottleneck plusargs, then reports timed-cycle deltas and checks metrics against
the table above using the default `--max-regression-pct 0.01` tolerance. It also
overrides the per-row simulator timeout with a generous `--sim-max-cycles`
budget, so `MAX_CYCLES` is only a liveness guard and not a performance threshold.

Simulator backend policy:
- DSim remains the main simulator for Stage 3 and the preferred source for
  promoted RTL evidence.
- Verilator is approved to replace XSim as the current Stage 3 turnaround
  fallback only when DSim is blocked by license availability. Its purpose is to
  accelerate Linux boot/debug iteration, not to lower the signoff bar.
- XSim is demoted to a last-resort cross-check because it is too slow for this
  workload.
- Any RTL slice debugged with Verilator still needs the locked DS/CM guard to
  remain clean, with DSim evidence preferred before promotion whenever the
  license is available.

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
- The simulator max-cycle budget is a timeout guard only; it must not be used
  as the performance acceptance rule.
- Timed cycles are reported as diagnostic movement against the reference, but
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
   - v2 keeps reset and payload placement, but the first trimmed 64 MB memory
     map places the Linux DTB at `0x82000000`.
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
| Privilege CSRs | `csr_file.sv` has M/S privilege state, delegation CSRs, `satp`, traps, `mret`, `sret`, interrupt inputs, `SUM`, `MXR`, and `MPRV` state | Basic OpenSBI trap and handoff validation now passes; Sv48 permission behavior is now covered by directed VM smoke rows |
| RV64GC ISA | Integer, atomics, compressed, and F/D floating point are integrated in the core RTL and advertised through `misa`; full profiled RV64GC compliance now passes `113/113` rows | Keep FP support in the ASIC-style core datapath and rerun full compliance after any RTL change that can affect ISA, CSR, memory, frontend delivery, or exception behavior |
| MMU | `src/rtl/core/mmu/` now contains Sv39/Sv48 ITLB, DTLB, and shared PTW blocks; instruction and data translation are wired through `rv64gc_core_top.sv` | Directed Sv48 data, instruction, fault, A/D, permission, superpage, and canonical-address smokes pass; remaining MMU work is broader coverage and Linux-scale integration |
| Platform devices | L0 `tb_linux` now has an uncached MMIO path, polling UART, and CLINT timer/software interrupt block; PLIC is only a reserved zero-response range | OpenSBI platform probing and Linux early console now pass; next work is Linux timekeeping, UART-driver bind, kernel init, and userspace handoff |
| Simulation memory | `sim_memory.sv` defaults to 2 MB for benchmark sims and is parameterized; `tb_linux.sv` raises the Linux platform instance to 64 MB | Enough for the trimmed OpenSBI plus Linux `fw_payload` image, initramfs, and DTB at `0x82000000`; benchmark harness memory sizing is unchanged |
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
- Verilator is the approved Stage 3 Linux boot/debug fallback when the single
  DSim cloud lease is unavailable. It replaces XSim for normal fallback
  turnaround on this workload. DSim remains the authoritative simulator for
  promoted evidence, and XSim is retained only as a last-resort cross-check
  because it is too slow for current Linux boot iteration.
- The Verilator Linux fallback is wired through `build_verilator_linux.sh`,
  `run_verilator_linux.sh`, and `tools/run_linux_boot.py --simulator verilator`.
  The binary builds, but first execution currently aborts before reset on a
  Verilator active-region convergence failure from existing `UNOPTFLAT`
  combinational-settle loops. Treat this as a fallback-enablement blocker, not
  Linux boot evidence, until the loop source is isolated or DSim is available.
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

| Row | Timed cycles | Diagnostic cycle reference | Metric |
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

| Row | Timed cycles | Diagnostic cycle reference | Metric |
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

| Row | Timed cycles | Diagnostic cycle reference | Metric |
|---|---:|---:|---:|
| Dhrystone 100 | `18,082` | `18,161` | `3.147616 DMIPS/MHz` |
| Dhrystone 300 | `53,360` | `53,469` | `3.199880 DMIPS/MHz` |
| CoreMark 1 | `154,184` | `154,233` | `6.485757 CM/MHz` |
| CoreMark 10 | `1,491,293` | `1,491,334` | `6.705590 CM/MHz` |

- Fourteenth RTL slice completed: data-side Sv48 store permission faults are
  now covered by a directed smoke. The LSU DTLB arbitration is age aware between
  a store-address translation and load port 0, and a store-address uop waits
  when an older load owns the single DTLB lookup port instead of writing a
  virtual address into the SQ. Commit also no longer increments the SQ
  side-effect commit count for an exceptioning store. The store still retires
  precisely to take the trap, but the faulting store is not marked as a
  committed memory side effect and is discarded by the exception flush. This
  matches the architectural contract inspected in v1: page-table and platform
  work may use the existing SQ/CSB path, but exceptioning stores must never be
  promoted to a drainable committed store.
- Directed store-fault Sv48 proof added:
  `tests/asm/vm_store_fault_sv48_smoke.S` extends the Stage 3 VM smoke
  manifest. The test keeps fetch in M-mode physical addressing, uses
  `MPRV`/`MPP=S` for S-mode LSU translation, maps VA `0x9000` as a read-only
  Sv48 leaf, verifies a translated load succeeds, then verifies the store traps
  with `mcause=15` and `mtval=0x9000`.
- Validation for the data-side store-fault slice:
  `benchmark_results/stage3_vm_smoke_20260511_store_fault_no_side_effect_commit`
  passed `vm_data_sv48_smoke`, `vm_ifetch_sv48_smoke`, and
  `vm_store_fault_sv48_smoke`.
- DS/CM regression validation for the data-side store-fault slice:
  `benchmark_results/stage3_rtl_guard_20260511_store_fault_no_side_effect_commit`.
  The hard metric gate passed with no DS/CM metric regression beyond the
  `0.01%` tolerance.

| Row | Timed cycles | Diagnostic cycle reference | Metric |
|---|---:|---:|---:|
| Dhrystone 100 | `18,082` | `18,161` | `3.147616 DMIPS/MHz` |
| Dhrystone 300 | `53,360` | `53,469` | `3.199880 DMIPS/MHz` |
| CoreMark 1 | `154,184` | `154,233` | `6.485757 CM/MHz` |
| CoreMark 10 | `1,491,293` | `1,491,334` | `6.705590 CM/MHz` |

DSim benchmark caveat:

- The DSim OpenSBI milestone is valid, but the DSim CoreMark guard row hit a
  DSim scheduler `IterLimit` at cycle `59,013` before the timed benchmark
  window completed. Raising the DSim iteration limit did not move the timestamp.
  The XSim guard above is therefore the promoted Stage 3 DS/CM gate for this
  slice. The DSim CoreMark convergence issue should be treated as simulator
  debug debt, not as evidence of a DS/CM functional or performance regression.

First trimmed Linux image boot attempt:

- The full Linux software build now produces a trimmed single-hart image using
  the v2 DTS, OpenSBI generic firmware, Linux `Image`, and a static initramfs
  `/init` that prints `BOOT OK`. The build disables SMP, modules, networking,
  EFI, USB, DRM, framebuffer, input, ext4, NFS, ACPI, vector, and other
  nonessential paths. The DTS exposes 64 MB DRAM, CLINT, and NS16550A UART
  only.
- `sim_memory.sv` remains 2 MB by default for the benchmark harness, and
  `tb_linux.sv` overrides only the Linux platform instance to 64 MB. This keeps
  the larger DRAM model at the simulation platform boundary instead of changing
  the core or benchmark path.
- The build fragment requests four-level page tables with
  `CONFIG_PGTABLE_LEVELS=4`, but the referenced v1 Linux tree hard-defaults
  `CONFIG_PGTABLE_LEVELS=5` for 64-bit builds. The DTS still advertises
  `mmu-type = "riscv,sv48"` for runtime. If compile-time four-level-only Linux
  is required, that should be a controlled kernel-tree configuration patch, not
  an RTL workaround.
- Current generated image sizes are approximately:
  `fw_payload.bin` 18 MB, `fw_payload.elf` 17 MB, `fw_payload.hex` 54 MB,
  static initramfs `/init` 464 KB, and DTB 1.3 KB.
- The promoted first trimmed image boot run was:

```bash
python3 tools/run_linux_boot.py --run --build-mode linux \
  --run-dir linux_boot_results/stage3_l9_linux_image_boot_trimmed_20260512 \
  --target-milestone linux_early_console \
  --max-cycles 2000000 \
  --status-interval 1000000 \
  --sim-plusarg +LINUX_TRACE_REGS
```

- UART log path for this first attempt:
  `linux_boot_results/stage3_l9_linux_image_boot_trimmed_20260512/uart.log`.
- Sim log path for this first attempt:
  `linux_boot_results/stage3_l9_linux_image_boot_trimmed_20260512/dsim.log`.
- Result: OpenSBI reaches platform probing, reports UART and CLINT, and hands
  off to Linux at `0x80200000` with DTB argument `0x82000000`. No Linux early
  console text appears by the 2M-cycle bound. The runner summary classifies
  the last milestone as `opensbi_platform_probe`.
- First blocker after the trimmed rebuild: the core reaches Linux `setup_vm`
  before `satp` is enabled, then stops making forward progress with the load
  queue full. The 2M-cycle status snapshot reports `priv=1`, `satp=0`,
  `last_pc=0x8080563c`, `last_commit_cycle=1617832`, `rename_stall=1`, and
  `lq_full=1`. Symbolizing `0x8080563c` against the Linux image at payload base
  `0x80200000` maps to `setup_vm`, at a relocation-table load sequence.
- Parked Linux debug target after compliance: root-cause the early `setup_vm`
  load-queue stall. The next Linux-specific run should add a focused trace for
  the head load at `0x8080563c/0x8080563e/0x80805642`, including virtual
  address, DTLB/PTW state, LQ allocation/free state, and the data-cache
  miss/response path. This is not the next RTL priority until full RV64GC
  instruction compliance passes.
- DS/CM guard for the Linux image-memory slice passed:
  `benchmark_results/stage3_rtl_guard_stage3_l9_linux_image_boot_trimmed_20260512`.

| Row | Timed cycles | Diagnostic cycle reference | Metric |
|---|---:|---:|---:|
| Dhrystone 100 | `18,082` | `18,161` | `3.147616 DMIPS/MHz` |
| Dhrystone 300 | `53,360` | `53,469` | `3.199880 DMIPS/MHz` |
| CoreMark 1 | `154,184` | `154,233` | `6.485757 CM/MHz` |
| CoreMark 10 | `1,491,293` | `1,491,334` | `6.705590 CM/MHz` |

## Stage 3 Architecture Direction

### Platform Shape

Use a simple single-core SoC shell around the existing core:

| Address | Device | Required for first Linux boot? | Notes |
|---:|---|---|---|
| `0x8000_0000` | DRAM | yes | First trimmed image boot uses 64 MB; keep the DTS and `tb_linux` memory window aligned |
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
   - DTB placed at `0x82000000` inside the 64 MB first-boot DRAM window.
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

- Add or port a large simulation DRAM model, parameterized for the chosen
  Linux image window. The first trimmed boot uses 64 MB.
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
- Seventh RTL slice completed: `rob.sv` now carries an exception `tval`
  alongside the exception cause, and exposes a generic sideband exception
  write port for long-latency units. `rv64gc_core_top.sv` connects DTLB PTW
  faults into that sideband so data page faults can mark the precise ROB entry
  ready with `EXC_LOAD_PAGE_FAULT` or `EXC_STORE_PAGE_FAULT` and the faulting
  virtual address. Commit now forwards the ROB exception `tval` into
  `csr_file.sv` for `mtval` or `stval`. Instruction page faults still need the
  fetch-side integration path because the current PTW does not yet receive an
  instruction ROB index.
- Validation for the PTW-to-ROB fault sideband slice:
  `benchmark_results/stage3_rtl_guard_20260511_ptw_rob_fault_sideband`.
- Eighth RTL slice completed: DTLB permission faults are now handled through
  the same precise ROB sideband as PTW walk faults. `lsu.sv` reports immediate
  DTLB hit faults with the faulting VA, ROB index, and load or store page-fault
  cause; it also suppresses the issuing load or store-address IQ entry so the
  core does not access memory or mark a store address complete while a
  translation permission fault is pending. `rv64gc_core_top.sv` prioritizes
  one-cycle PTW data faults over repeatable LSU DTLB faults on the shared ROB
  sideband.
- Validation for the DTLB immediate-fault sideband slice:
  `benchmark_results/stage3_rtl_guard_20260511_dtlb_fault_sideband`.
- Ninth RTL slice completed: the LSU now has a physical-address-selected
  memory address path for store-address issue and load port 0. Store queue,
  load queue, committed-store-buffer forwarding, D-cache, MMIO, AMO, and
  load-miss-buffer launch points consume the translated address when a DTLB
  hit is selected; otherwise they retain the Bare-mode effective address.
  Load port 0 now waits when store-address translation owns the single DTLB
  lookup port, and load port 1 remains held under data VM until a deliberate
  second translated-load path is added. `rv64gc_core_top.sv` still keeps
  `data_vm_active_i` disabled, so this slice is a behavior-neutral PA mux
  setup for the later data-VM enable step.
- Validation for the LSU data PA-mux slice:
  `benchmark_results/stage3_rtl_guard_20260511_lsu_data_pa_mux`.
- Tenth RTL slice completed: PTW TLB-fill permission tagging now sets the
  RISC-V `A` bit on successful fills and sets `D` only for store-originated
  fills using explicit bit masks. This fixes the inherited v1-style
  concatenation that intended hardware-managed A/D tagging but actually set
  `G` and misplaced the store bit. The PTW still preserves the original PTE
  permission bits and data translation remains disabled at the LSU top-level
  input until the next promotion slice.
- Validation for the PTW A/D fill-bit slice:
  `benchmark_results/stage3_rtl_guard_20260511_ptw_ad_fill_bits`.
- Eleventh RTL slice completed: `rv64gc_core_top.sv` now wires the computed
  `data_vm_active` signal into `lsu.sv` instead of holding the LSU DTLB
  sideband disabled. This promotes the data-side DTLB/PTW/PA-mux path from
  scaffold to an active architectural path whenever `satp` enables Sv39 or
  Sv48 and the effective data privilege is not M-mode. The committed DS/CM
  rows still run Bare mode, so this slice proves non-regression and clean
  elaboration; a directed VM data-translation smoke remains required before
  claiming functional data-MMU completion.
- Validation for the data-VM activation slice:
  `benchmark_results/stage3_rtl_guard_20260511_data_vm_active`.
- Twelfth RTL slice completed: commit now treats VM-state CSR writes
  (`satp`, `mstatus`, `sstatus`) and `sfence.vma` as translation
  serialization redirects. The first directed Sv48 data-translation smoke
  showed why this is required: without the redirect, a younger load after
  `csrw satp` and `csrw mstatus` issued before those CSRs committed and used
  the old Bare-mode address. The fix retires the serializing side effect, then
  full-flushes and refetches at `pc + 4` so younger memory operations execute
  under the committed VM contract.
- Directed data-side Sv48 proof added:
  `tests/asm/vm_data_sv48_smoke.S` with manifest
  `tests/benchmarks/stage3_vm_smoke.json`. The test keeps fetch in M-mode
  physical addressing, uses `MPRV` with `MPP=S` to force S-mode LSU
  translation, maps virtual `0x9000` to physical `0x80008000` through a
  four-level Sv48 page table, validates a translated load, performs a
  translated store, clears `MPRV`, and confirms the backing physical line
  changed.
- Validation for the CSR/VM serialization and data-side Sv48 smoke slice:
  `benchmark_results/stage3_vm_data_smoke_20260511_csr_flush` passed with
  `tohost=1`, `mcycle=88`, and `minstret=69`.
- DS/CM regression validation for the CSR/VM serialization slice:
  `benchmark_results/stage3_rtl_guard_20260511_vm_csr_serial_redirect`.
  The hard metric gate passed with the same preserved metrics as the prior
  data-VM activation slice.
- Thirteenth RTL slice completed: instruction fetch now has an ITLB lookup in
  front of the I-cache when `instr_vm_active` is set. The frontend keeps
  virtual PCs for FTQ, owner tracking, decode, and commit identity, but sends
  the translated physical address to the I-cache and L2 fill path on ITLB hit.
  On ITLB miss, fetch holds the current F1 PC and requests the shared PTW;
  next-line prefetch is disabled while instruction VM is active so early
  Linux bring-up does not issue untranslated prefetches.
- Directed instruction-side Sv48 proof added:
  `tests/asm/vm_ifetch_sv48_smoke.S` extends the Stage 3 VM smoke manifest.
  The test enables Sv48 in M-mode, sets `mstatus.MPP=S`, writes `mepc` to a
  supervisor virtual address, executes `mret`, fetches the S-mode payload via
  an executable Sv48 mapping from VA `0x4000` to PA `0x80009000`, then stores
  PASS through a translated S-mode data mapping to the physical tohost word.
- Validation for the ITLB fetch slice:
  `benchmark_results/stage3_vm_smoke_20260511_itlb` passed both
  `vm_data_sv48_smoke` and `vm_ifetch_sv48_smoke`.
- DS/CM regression validation for the ITLB fetch slice:
  `benchmark_results/stage3_rtl_guard_20260511_itlb_fetch`. The hard metric
  gate again passed with no DS/CM metric regression beyond the `0.01%`
  tolerance.
- Fourteenth RTL slice completed: instruction page faults now enter the
  architectural trap path instead of remaining a fetch-side stall. The core
  records a pending fetch exception from either direct ITLB permission fault or
  PTW instruction-side fault, injects one ready decoded exception into rename,
  carries `exc_tval` through decoded/renamed state into the ROB, and commits the
  trap with `mtval` equal to the faulting virtual PC. The slice also fixed the
  pre-existing commit/CSR trap-vector contract: commit now uses `medeleg` and
  `mideleg` when selecting `mtvec` versus `stvec`, matching the CSR file's trap
  state update instead of redirecting every non-M exception to `stvec`.
- Directed instruction-page-fault proof added:
  `tests/asm/vm_ifetch_fault_sv48_smoke.S` maps VA `0x4000` through a readable
  but non-executable Sv48 leaf, enters S-mode through `mret`, and verifies
  `mcause=12` plus `mtval=0x4000` in the M-mode trap handler.
- Validation for the instruction page-fault slice:
  `benchmark_results/stage3_vm_smoke_20260511_ifetch_fault_delegation_fix`
  passed `vm_data_sv48_smoke`, `vm_ifetch_sv48_smoke`,
  `vm_ifetch_fault_sv48_smoke`, and `vm_store_fault_sv48_smoke`.
- DS/CM regression validation for the instruction page-fault slice:
  `benchmark_results/stage3_rtl_guard_20260511_ifetch_fault_delegation_fix`.
  The hard metric gate passed with no DS/CM metric regression beyond the
  `0.01%` tolerance; timed cycles remain diagnostic only.

| Row | Timed cycles | Diagnostic cycle reference | Metric |
|---|---:|---:|---:|
| Dhrystone 100 | `18,082` | `18,161` | `3.147616 DMIPS/MHz` |
| Dhrystone 300 | `53,360` | `53,469` | `3.199880 DMIPS/MHz` |
| CoreMark 1 | `154,184` | `154,233` | `6.485757 CM/MHz` |
| CoreMark 10 | `1,491,293` | `1,491,334` | `6.705590 CM/MHz` |

- Fifteenth RTL slice completed: hardware-managed Sv48 PTE A/D updates now
  write back to memory before the TLB fill or dirty-hit store can proceed. The
  PTW performs A-bit and store-originated D-bit updates through the coherent
  D-cache store path, so later software page-table reads see the updated PTE
  through the same L1D path. DTLB dirty-hit upgrades are backpressured by PTW
  readiness, preventing a store from completing when the D-bit writeback request
  cannot be accepted.
- Directed PTE A/D proof added:
  `tests/asm/vm_ad_update_sv48_smoke.S` extends the Stage 3 VM smoke manifest.
  The test starts with a valid read/write leaf with `A=0,D=0`, performs an
  S-effective translated load and checks that memory PTE `A=1,D=0`, then
  performs an S-effective translated store and checks that memory PTE `D=1` and
  the physical data line changed.
- Validation for the A/D memory-writeback slice:
  `benchmark_results/stage3_vm_smoke_20260511_ad_dcache_store_clean_full`
  passed
  `vm_data_sv48_smoke`, `vm_ifetch_sv48_smoke`,
  `vm_ifetch_fault_sv48_smoke`, `vm_store_fault_sv48_smoke`, and
  `vm_ad_update_sv48_smoke`.
- DS/CM regression validation for the A/D memory-writeback slice:
  `benchmark_results/stage3_rtl_guard_20260511_ad_dcache_store_clean`. The
  guard ran with `--max-cycles 10000000`; this is only a liveness timeout. The
  hard acceptance gate remained the DS/CM metric, and all four rows stayed
  within the `0.01%` regression tolerance.

| Row | Timed cycles | Diagnostic cycle reference | Metric |
|---|---:|---:|---:|
| Dhrystone 100 | `18,082` | `18,161` | `3.147616 DMIPS/MHz` |
| Dhrystone 300 | `53,360` | `53,469` | `3.199880 DMIPS/MHz` |
| CoreMark 1 | `154,184` | `154,233` | `6.485757 CM/MHz` |
| CoreMark 10 | `1,491,293` | `1,491,334` | `6.705590 CM/MHz` |

- v1 MMU reference audit completed for this slice:
  `rv64gc-v1/src/rtl/core/mmu/{itlb,dtlb,ptw}.sv` and `rv64gc-v1/handoff.md`
  identify three Linux-facing MMU contracts that must not be skipped:
  SUM/MXR/U permission checks, filtered `SFENCE.VMA` invalidation, and
  hardware-managed PTE A/D writeback. v2 now has A/D memory writeback and
  matches the v1-style DTLB permission checks for SUM, MXR, and U/S data
  access. Filtered `SFENCE.VMA` remains a future refinement; the current v2
  integration still performs full TLB invalidation on `sfence.vma` and `satp`
  commit, which is functionally conservative for single-hart bring-up.
- Directed Sv48 permission proof added:
  `tests/asm/vm_perm_sv48_smoke.S` extends the Stage 3 VM smoke manifest. It
  uses M-mode fetch plus `MPRV` to force S-effective and U-effective data
  translation. The test verifies that S-mode access to a U page faults when
  `SUM=0`, load from an execute-only page faults when `MXR=0`, U-effective load
  from a supervisor page faults, and the matching `SUM=1`, `MXR=1`, and U-page
  success cases all return the expected data.
- Validation for the permission smoke:
  `benchmark_results/stage3_vm_smoke_20260512_perm_full` passed
  `vm_data_sv48_smoke`, `vm_ifetch_sv48_smoke`,
  `vm_ifetch_fault_sv48_smoke`, `vm_store_fault_sv48_smoke`,
  `vm_ad_update_sv48_smoke`, and `vm_perm_sv48_smoke`. This is a test-only
  coverage slice, so the DS/CM RTL guard was not rerun.
- Directed Sv48 superpage and canonical-address proof added:
  `tests/asm/vm_superpage_sv48_smoke.S` verifies positive DTLB translation
  through 1 GiB and 2 MiB Sv48 leaf mappings.
  `tests/asm/vm_superpage_fault_sv48_smoke.S` verifies the PTW rejects
  misaligned 1 GiB and 2 MiB leaf PPNs before DTLB fill.
  `tests/asm/vm_canonical_sv48_smoke.S` verifies noncanonical data and
  instruction virtual addresses raise load and instruction page faults with
  `mtval` equal to the rejected VA.
- Validation for the expanded VM smoke:
  `benchmark_results/stage3_vm_smoke_20260512_sv48_mmu_full_clean` passed
  `vm_data_sv48_smoke`, `vm_ifetch_sv48_smoke`,
  `vm_ifetch_fault_sv48_smoke`, `vm_store_fault_sv48_smoke`,
  `vm_ad_update_sv48_smoke`, `vm_perm_sv48_smoke`,
  `vm_superpage_sv48_smoke`, `vm_superpage_fault_sv48_smoke`, and
  `vm_canonical_sv48_smoke`. This is a test-only coverage slice, so the DS/CM
  RTL guard was not rerun.

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
6. Build and pass the full RV64GC instruction compliance gate:
   - standard `rv64ui`, `rv64um`, `rv64ua`, `rv64uc`, `rv64uf`, `rv64ud`,
     `Zicsr`, and `Zifencei` coverage,
   - endpoint handling kept in the simulation platform or runner only,
   - impacted compliance subset plus DS/CM hard gate after any RTL fix.
7. Resume Linux-specific debug, starting with the parked `setup_vm` load-queue
   stall only after the compliance gate passes.
8. Boot minimal Linux to early console.
9. Boot to initramfs `BOOT OK`.

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
python3 tools/run_linux_boot.py --run --build-mode linux \
  --target-milestone linux_early_console --max-cycles 6000000
```

The Linux commands above are parked for RTL-debug priority until the compliance
gate passes. The next implementation slice should add a command shape like:

```bash
python3 tools/run_rv64gc_compliance.py --build --suite riscv-tests --runner dsim
python3 tools/run_rv64gc_compliance.py --run --isa rv64gc --runner dsim
```

Use the Verilator fallback only when DSim is blocked by license availability.
XSim should only be used as a last-resort cross-check because it is too slow for
this workload. The runner must archive per-test logs, the ELF/hex provenance,
and a summary table with pass, fail, timeout, and first failing PC or trap when
available.

The Linux runner can now run the M-mode UART smoke and has a dedicated OpenSBI
banner mode. It records reached milestones and the last reached milestone in
`summary.json` and `summary.md`, so a timeout now reports the exact boot level
instead of only `PASS` or `TIMEOUT`. RV64GC/FPU support is integrated and
guarded against DS/CM regression. OpenSBI platform probing now works through
the ASIC-style core/platform boundary. The first full Linux image is loadable
in the 64 MB Linux platform memory, reaches the OpenSBI S-mode handoff, and
now reaches Linux early console output. The old early `setup_vm` load-queue
stall is no longer the active blocker.

### Current Linux Oops Status

The previous kernel-visible Oops was real, but the evidence points to frontend
owner identity rather than Linux software:

- Failing run: `linux_boot_results/stage3_linux_oops_regs_dsim_20260513`
  reported `Unable to handle kernel NULL pointer dereference` and `Oops [#1]`
  while repeatedly trapping at `0xffffffff805c5b54`.
- Root cause 1: predicted-control slot matching compared only low offsets, so
  a BTB/alternate-BTB hit from the next line could be treated as a valid
  control instruction in the current fetched packet.
- Root cause 2: an IFU demand-runahead target owner could be consumed as the
  next ordinary FTQ owner before an intervening sequential successor owner was
  delivered, then be allocated again when the real call redirect arrived.

The current RTL fixes both contracts:

- `pred_checker.sv` now requires line identity as well as low-offset identity
  when matching FTQ, BTB, and alternate-BTB predicted-control slots.
- `ifu.sv` cancels or replaces a pending runahead owner when a real successor
  owner must be delivered first, and blocks pending-runahead owners from being
  consumed through the ordinary next-owner path.
- The simulation-only Linux trace was extended in `tb_linux.sv` so future
  frontend owner failures can be isolated without adding debug behavior to
  synthesizable RTL.

Validation after the fix:

- `linux_boot_results/stage3_linux_runahead_successor_cancel_dsim_10m_20260513a`
  ran to 10M cycles with no `Oops`, no `Kernel panic`, and no
  `Unable to handle` signature. It reached Linux early console and timed out
  while executing kernel `__memset` around `0xffffffff805c5dxx`, which is a
  long memory-clear path, not the previous `__memcpy` Oops.
- The run did not reach the `riscv_clocksource` milestone yet. The next Linux
  debug target is therefore forward progress through the long `__memset`
  region and then timer/clocksource bring-up, not the old Oops.
- DS/CM hard guard after the RTL change passed:
  `benchmark_results/stage3_rtl_guard_stage3_linux_oops_frontend_fix_dsim_20260513a`.
  Results: DS100 3.150055 DMIPS/MHz, DS300 3.218761 DMIPS/MHz,
  CM1 6.649201 CM/MHz, CM10 6.872881 CM/MHz. Loop buffer and standalone
  decoded-op replay remained inactive.

### Current Linux Frontend Progress Status

The previous Oops path remains fixed. A later 50M status run exposed a
different frontend no-progress condition, not a kernel panic:

- Failing run:
  `linux_boot_results/stage3_linux_50m_frontend_oops_fix_dsim_20260513a`
  reached Linux early console and memory-zone enumeration with no `Oops`, no
  `Kernel panic`, and no `Unable to handle` signature.
- It then stopped retiring after cycle 11,668,002 while the backend was empty.
  The frozen state was `work_pc=0xffffffff8060da00`, `last_commit_pc=
  0xffffffff8060d9fa`, `icq_count=4`, and ICQ head PC
  `0xffffffff80611626`. Those PCs symbolize into
  `get_pfn_range_for_nid` / `__next_mem_pfn_range`.
- Root cause: the ICQ could hold a future same-owner or next-owner line in
  front of the current required line. If the one-entry future-line side buffer
  was already occupied, `icq_deq_ready` stopped popping speculative future
  entries, so a mandatory current-owner line could not enter the ICQ.
- Fix: `ifu_line_fetch.sv` now treats non-current-line ICQ entries belonging
  to the active IFU owner or the next IFU owner as future-line candidates. The
  first such line is captured into the future-line side buffer; overflow future
  entries are dropped because they are speculative and can be refetched. Current
  matching lines still deliver normally, stale lines still use the existing
  stale-drop path.

Validation after the ICQ future-line ordering fix:

- `linux_boot_results/stage3_linux_icq_future_capture_any_owner_dsim_15m_20260513a`
  ran to 15M cycles with no Oops or panic and did not reproduce the
  `8060da00` freeze. It advanced beyond the old 12M deadlock point, reaching
  `minstret=12,860,114` and Linux log output through initmem setup, CPU ISA
  fallback parsing, per-CPU allocation, dentry/inode hash setup, zonelist
  build, and memory auto-init.
- The 15M run still timed out before `riscv_clocksource`. At the cap it was
  still retiring (`last_commit_cycle=14,999,999`) with an active ROB, so the
  next debug target is later Linux boot progress rather than frontend
  no-progress at the old site.
- DS/CM hard guard after the RTL change passed:
  `benchmark_results/stage3_rtl_guard_stage3_linux_icq_future_capture_any_owner_dsim_20260513a`.
  Results: DS100 3.150055 DMIPS/MHz, DS300 3.218761 DMIPS/MHz,
  CM1 6.649201 CM/MHz, CM10 6.872881 CM/MHz. This is within the Stage 3
  0.01% regression gate and preserves the committed performance baseline.

### Current Linux Clocksource Status

The v1 reference console makes `clocksource: riscv_clocksource` the right next
v2 milestone. The latest v2 evidence now reaches Linux `time_init()` and the
RISC-V timer probe with coherent 128M DRAM, so the old pre-clocksource
memory-clear uncertainty and the 64M page-allocation blocker are resolved. The
current blocker is the post-irq-domain RISC-V timer path after
`timer_common domain=...`; it is not an observed RTL trap.

Evidence summary:

- Older `#18` image runs such as
  `linux_boot_results/stage3_linux_oops_regs_dsim_20260513` did hit a real
  `Oops [#1]` in the printk path. That evidence drove the frontend owner-line
  and runahead-successor fixes, but it is not the latest signature.
- Later runs with the ICQ future-line fix no longer reproduce that Oops. They
  advanced into Linux memory setup and device-tree parsing.
- The current generated DTB contains `/cpus`,
  `/cpus/timebase-frequency = <1000000>`, `/cpus/cpu@0`, CLINT at
  `0x02000000`, and UART at `0x10000000`. Linux debug output confirms the
  unflattened OF tree contains `/cpus`, `/cpus/cpu@0`, and
  `timebase=1000000`.
- The OpenSBI platform path is clean for timer discovery. Current runs show
  CLINT matched for IPI and timer, then OpenSBI reports
  `Platform Timer Device     : aclint-mtimer @ 1000000Hz`. Linux also reports
  `SBI TIME extension detected`.
- The earlier full-memory DSim clocksource probe,
  `linux_boot_results/stage3_linux_clocksource_probe_dsim_30m_retry2_20260513a`,
  was stopped after 15M cycles. It had not reached `Memory:`, `SLUB`,
  `NR_IRQS`, `riscv-intc`, `time_init`, or
  `clocksource: riscv_clocksource`. The last PCs symbolize to
  `memmap_init_range` and `__memset`, and `last_commit_cyc` kept advancing.
  That is pre-clocksource forward progress, not a proven CLINT or Linux
  clocksource deadlock.
- The 50M-default-memory DSim run
  `linux_boot_results/stage3_linux_default64_dsim_50m_20260513a` was stopped
  after the first real software blocker was captured. It reached `Memory:`,
  `SLUB`, `NR_IRQS`, `riscv-intc`, `time_init before timer_probe`,
  `riscv_timer_init_dt()`, and `timer_common domain=...`. RTL status remained
  clean (`trap=0`, no pending interrupt, recent `last_commit_cyc`) through the
  sampled path. The run then printed `swapper: page allocation failure` from
  `riscv_timer_init_dt -> irq_create_mapping_affinity -> __irq_alloc_descs`.
  The kernel reported `free:0`, so this is memory exhaustion during early timer
  IRQ descriptor allocation, not a core exception.
- The root platform mismatch was that `sw/linux_boot/link.ld` already uses a
  128M DRAM region, while `sw/linux_boot/dts/rv64gc_v2_linux.dts` and
  `src/tb/tb_linux.sv` still exposed only 64M. The boot platform has been
  aligned to 128M for the next run.
- The coherent 128M DSim run
  `linux_boot_results/stage3_linux_128m_dsim_50m_20260513a` rebuilt the current
  RTL and Linux payload, exposed `Memory: 93544K/131072K available`, reached
  `SLUB`, `NR_IRQS`, `riscv-intc`, `time_init before timer_probe`,
  `riscv_timer_init_dt()`, and `timer_common domain=ffffaf8001454000`, and did
  not reproduce the 64M `swapper: page allocation failure`. It timed out at the
  intentional 50M cycle cap before `clocksource: riscv_clocksource`. The final
  status was still architecturally active: `mcycle=50000000`,
  `minstret=45018326`, `IPC=0.900367`, `last_commit_cycle=49999992`,
  `trap=0`, `irq_pending=0`, `mtip=0`, `msip=0`, no SVA ordering violations,
  and no `Oops`, `BUG`, `Kernel panic`, or `Unable to handle` signature.
- The `mem=24M` and `mem=48M` acceleration probes are invalid for this
  milestone. Both boot into Linux and recover from the expected MMU relocation
  exception, but both panic before `time_init()` with
  `memory_present: Failed to allocate 16777216 bytes align=0x40`. These are
  kernel sparse-memory configuration failures caused by the temporary memory
  cap, not clocksource failures.

Working verdict:

- Do not claim that v2 has the v1-style clocksource stuck issue. The current
  evidence reaches `time_init()` and enters the timer probe.
- Do not claim that v2 clocksource is proven good yet. The latest valid run
  reached timer setup with coherent 128M memory but did not print the standard
  `clocksource: riscv_clocksource` banner by the 50M cap.
- The immediate blocker is now narrower: instrument and classify the path after
  `timer_common domain=...`, especially IRQ mapping, `rdtime`,
  `clocksource_register_hz()`, `sched_clock_register()`,
  `request_percpu_irq()`, and timer CPU hotplug setup. The current evidence
  indicates forward progress through 50M, not a hard RTL deadlock.

Next diagnostic step before RTL changes:

1. Keep DSim as the primary evidence source. XSim is only a last-resort
   cross-check, and Verilator is not Linux evidence until the existing
   convergence issue is fixed.
2. Do not use sub-128M `mem=` caps with the current kernel config. The 64M
   default run reached timer setup but ran out of early kernel memory; the 24M
   and 48M caps fail even earlier in `memory_present`.
3. Continue the Linux-only probes in `arch/riscv/kernel/time.c` and
   `drivers/clocksource/timer-riscv.c`: `time_init()` before and after
   `of_clk_init()`, before and after `timer_probe()`, `riscv_timer_init_dt()`,
   irq-domain discovery, `clocksource_register_hz()`, explicit `rdtime`,
   `sched_clock_register()`, `request_percpu_irq()`, and CPU hotplug timer
   setup.
4. Preserve `vmlinux` or `System.map` from the Linux build in the next payload
   rebuild so final PCs such as `ffffffff80157664` can be symbolized instead of
   inferred from UART progress alone.
5. Do not change core RTL until a valid run proves whether the failure is in
   software time-init, CSR `time`, CLINT/SBI timer programming, memory/L2
   progress, or simulator runtime behavior.
6. Do not promote any RTL change from this path until the impacted VM or Linux
   smoke passes and the Stage 3 DS/CM hard guard remains within the 0.01%
   metric-regression gate.

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
| What is the first success milestone? | OpenSBI platform probe, full RV64GC instruction compliance, and Linux early console are achieved. Next Linux success is `riscv_clocksource`, then initramfs `BOOT OK`. |

## Current Verdict

Stage 3 remains feasible. The first platform blockers are resolved: v2 can
execute an M-mode UART smoke, reach the OpenSBI platform-probe milestone
through device-visible UART and CLINT paths, pass the full RV64GC instruction
compliance prerequisite, and reach Linux early console while preserving the
DS/CM performance gate.

- v2 has the right clean core boundary for ASIC-style Linux bring-up.
- v2 now has an L0 UART/CLINT platform path for early M-mode smoke and L1
  OpenSBI platform probing.
- v2 now has real RV64GC F/D execution in core RTL, with DSim FP smoke passing,
  full RV64GC instruction compliance closed for the current RTL candidate, and
  DS/CM performance preserved.
- v2 now has the Sv48 MMU/PTW/TLB scaffold, L2 PTW source port, data-side
  PTW and DTLB fault sidebands, LSU PA mux setup, data-side VM activation
  wired into the LSU, a commit-time VM serialization redirect for relevant CSR
  writes and `sfence.vma`, and a passing directed Sv48 LSU load/store
  translation smoke. The instruction fetch path now also has ITLB/PTW
  translation with a passing S-mode Sv48 ifetch smoke. Data-side store page
  faults and instruction page faults are now precise through the ROB/CSR trap
  path and are covered by directed Sv48 smokes. Hardware-managed PTE A/D memory
  writeback, SUM/MXR/U data permission behavior, DTLB superpage translation,
  superpage-alignment faults, and Sv48 canonical-address faulting are now
  covered by directed Sv48 smokes. Broader privileged/MMU directed tests remain
  open.
- v2 now has a coherent 128 MB trimmed Linux image path and can execute OpenSBI
  through S-mode payload handoff from that image. It reaches Linux early
  console. The previous Oops path is fixed by frontend owner-line identity
  and runahead-successor ordering repairs, and the later 11.668M frontend
  no-progress point is fixed by ICQ future-line capture/drop for active and
  next FTQ owners. The CPU-node/timebase discovery blocker is also resolved in
  the latest OF-base probe: Linux can find `/cpus`, `/cpus/cpu@0`, and
  `timebase-frequency = 1000000` after unflattening. The 64M early timer
  allocator failure is also fixed by making the DTS and simulation DRAM match
  the 128M linker region. The active Linux-debug target is now the next RISC-V
  timekeeping milestone after `timer_common domain=...`. Current evidence
  therefore does not prove a v1-style clocksource stuck issue; it proves that
  `clocksource: riscv_clocksource` has not been reached by the 50M cap while
  the core continues retiring instructions.
- v2 does not yet reach the Linux `riscv_clocksource` milestone, Linux-visible
  PLIC/external interrupts, or validated Linux timer behavior.
- v1 provides useful references for those pieces, but its `tohost`/HTIF-style
  completion should not be carried forward.

The next Stage 3 implementation should continue Linux boot debug from the
current `timer_common domain=...` state. Use Linux-only probes first to
determine whether the remaining gap is irq-domain/timer IRQ mapping, CSR `time`
access, `clocksource_register_hz()`, `sched_clock_register()`, CLINT/SBI timer
programming, memory/L2 progress, or DSim runtime behavior. Any RTL change on
that path must still pass impacted compliance tests and the DS/CM hard guard
before promotion. Sv39 should stay as a directed-test subset, but the primary
Linux path is four-level Sv48 because that matches the intended Linux signoff
configuration.

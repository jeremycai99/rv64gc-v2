# Benchmark Coverage Expansion From Reference Core B References, 2026-05-05

## Verdict

Use Reference Core B's benchmark landscape to broaden coverage, but do not use the
prebuilt Reference Core B `.bin` files as scoreable signoff images yet.

The right near-term path is source-level porting into the rv64gc-v2 bare-metal
harness:

1. Add Reference Core B `frontendtest` microbenchmarks first, because they directly
   stress the BPU/FTQ ownership refactor.
2. Add Reference Core B `microbench` algorithm kernels next, because they broaden
   integer, branch, pointer, compression, sort, hash, and graph behavior.
3. Add downscaled memory/STREAM-style rows after that, because they expose LSU,
   cache, and prefetch behavior without becoming the Stage 1 optimization target.
4. Keep Linux, SPEC checkpoints, vector, hypervisor, cache-op, IOPMP, and
   multi-core tests out of the immediate RTL signoff loop.

This should be used as anti-overfit coverage. Stage 1 can still be measured
against Dhrystone/CoreMark, but every frontend RTL change should also pass a
broader smoke matrix before being accepted.

## Current Run Status, 2026-05-06

The existing broad suite should run in Stage 1, not be deferred wholesale to
Stage 2.

Command used:

```bash
python3 tools/sim_platform.py \
    --manifest tests/sim_platform/stage1_broad.json \
    --runner dsim \
    --run-class dse \
    --run-dir benchmark_results/megaboom_full_compare_20260506/rv64gc_broad \
    --plusarg PERF_COUNTERS \
    --plusarg PERF_PROFILE \
    --plusarg STAT_DUMP
```

Result: 42 PASS and one false timeout at the old 150k cycle cap. The timeout
row was `probe_string_retire_hotspot`; retrying only that row with a 500k cap
passed at `mcycle=169620`. The manifest cap is now 250k, so the effective broad
coverage status is 43/43 PASS. A follow-up run through the normal manifest path
with no command-line cap override also passed at `mcycle=169620`.

This run covers 5 Dhrystone/CoreMark replicas, 15 micro/probe rows, 8 ISA smoke
rows, and 15 C/control smoke rows. These rows are guardrails, not the Reference Core A (large config)
score target. Reference Core A (large config) methodology details are in
`doc/stage1_megaboom_benchmark_comparison_2026-05-06.md`.

## Sources Inspected

- Local Reference Core B checkout: `/home/jeremycai/agent-workspace/xiangshan`,
  commit `4bfb226`.
- Reference Core B ready-to-run README:
  `/home/jeremycai/agent-workspace/xiangshan/ready-to-run/README.md`.
- Reference Core B CI workload selector:
  `/home/jeremycai/agent-workspace/xiangshan/scripts/xiangshan.py`.
- Upstream Reference Core B project `nexus-am` source tree, shallow inspection at commit
  `b2470bd`.
- Local reference-core build framework/Reference Core A (large config) harness:
  `/home/jeremycai/agent-workspace/chipyard/generators/chipyard`,
  `/home/jeremycai/agent-workspace/chipyard/generators/testchipip`, and
  `/home/jeremycai/agent-workspace/chipyard/sims/verilator`.

## Current rv64gc-v2 Harness Constraints

| Constraint | Current rv64gc-v2 state | Impact |
|---|---|---|
| Image format | `$readmemh` byte-per-line hex loaded at `0x80000000` | Raw Reference Core B `.bin` can be converted with `scripts/elf2hex.py --binary`, but endpoint handling still differs. |
| Memory model | 2 MB byte-addressed sim memory | Small bare-metal apps fit; STREAM/SPEC/Linux/checkpoints do not fit without scaling or memory-model changes. |
| Pass/fail | Harness observes an ordinary committed store to configurable `TOHOST_ADDR` defaulting to `0x80001000`; core RTL no longer exposes fixed `tohost` ports | Reference Core B AM images use `_halt()` custom trap and UART/RTC MMIO, so they are not scoreable without a compatibility shim. |
| Perf result block | Stores to `0x80001080` produce `[BENCH_RESULT]` | Source ports should call our bench-result API to make cycles/instret/checksum machine-checkable. |
| ISA target | `rv64gc_zba_zbb_zbs_zicond`; no RVV/H/Zfh/Zcb/Zacas/crypto | Scalar RV64GC and selected bitmanip rows are usable; vector, hypervisor, half-float, Zcb, Zacas, and crypto rows are excluded. |
| Runtime | Bare-metal M-mode, no OS/proxy/checkpoint restore | Linux, SPEC checkpoints, syscall-heavy, and device-heavy workloads are deferred. |

## Reference Core B Ready-To-Run Binaries

| Binary | Reference Core B description | Can run on rv64gc-v2 now? | Verdict |
|---|---|---|---|
| `microbench.bin` | Bare-metal `nexus-am/apps/microbench` | Loadable after raw-bin-to-hex conversion, but not scoreable | Rebuild from source with rv64gc-v2 CRT/bench MMIO. |
| `coremark-2-iteration.bin` | Bare-metal 2-iteration `nexus-am/apps/coremark` | Loadable after conversion, but uses Reference Core B AM exit convention | Do not replace our CoreMark image; use only as a source/reference variant. |
| `copy_and_run.bin` | Loader that copies CoreMark from flash | Needs Reference Core B flash/runtime assumptions | Not useful for current harness. |
| `flash_recursion_test.bin` | Flash recursion test | Flash/runtime-specific | Exclude. |
| `linux.bin` | OpenSBI + Linux boot smoke | Needs OS boot path, devices, larger memory | Exclude until a Linux-capable SoC/harness exists. |

The prebuilt images start at `0x80000000` and small images fit the current
memory model, but they do not write our `tohost` or benchmark-result block.
The portable direction is to rebuild source, not to tune the testbench around
Reference Core B's AM ABI.

## Reference Core A / its build framework Test ABI Reference

Reference Core A (large config) in the local reference-core build framework tree does not use a core-internal benchmark
escape either. It uses the reference-core build framework TestHarness around the core:

- `MegaBoomV4Config` inherits `AbstractConfig`, which adds `WithSimTSIOverSerialTL`.
- `WithSimTSIOverSerialTL` instantiates `SimTSI`, `SerialRAM`, and a TSI/HTIF
  host path in the harness.
- `SimTSI` returns `exit == 1` for success and `exit >= 2` for failure; the
  harness converts this to the simulator success signal.
- The Verilator run target passes the ELF as `BINARY`, with optional
  `+loadmem=<elf>` support. FESVR/HTIF discovers `tohost/fromhost` from the ELF
  instead of requiring one hard-coded address.
- the reference-core build framework still carries riscv-tests/arch-test environments with
  `.tohost/.fromhost` symbols. That is the standard Spike/HTIF ecosystem path.

The Reference Core A lesson is therefore different from Reference Core B's: adopt a more general
test platform ABI, not Reference Core A-specific core logic. For compatibility with Reference Core A
and riscv-tests, rv64gc-v2 should move from a fixed-address-only `tohost` flow
toward symbol-driven ELF loading plus standard `tohost/fromhost` handling in
the simulator harness.

## Compatibility Refactor Direction

The core must stay free of benchmark-exit policy. The compatibility layer should
live in the simulator/test platform and support multiple software ABIs:

1. Native rv64gc-v2 ABI:
   - fixed `tohost` at `0x80001000`;
   - benchmark result block at `0x80001080`;
   - current CoreMark/Dhrystone score flow.
2. Reference Core A / its build framework-compatible ABI:
   - load ELF segments directly, not only byte-per-line hex;
   - discover `tohost` and `fromhost` symbols from the ELF when present;
   - accept standard riscv-tests/HTIF pass/fail encodings;
   - keep optional `+loadmem=<elf>` behavior for faster initialization.
3. Reference Core B/Nexus-AM source-port ABI:
   - rebuild Nexus-AM apps against an rv64gc-v2 platform shim;
   - provide `_halt(code)` as a store to the harness endpoint;
   - provide `uptime`, UART stubs, and bounded heap locally;
   - use the same bench-result block for scoreable rows.

Do not make Reference Core B's prebuilt `_halt()` custom instruction part of the core
ISA. Supporting that exact instruction can be a simulation-only debug adapter
later, but it should not gate Stage 1 coverage because it would make the
benchmark image compatibility problem look like a core architecture feature.

Cleanup status: the fixed-address test ABI has been removed from the core
boundary. `rv64gc_core_top.sv` no longer has `tohost_addr/tohost_wr_*` ports,
and `dcache.sv` no longer has a magic-address exemption for `0x80001xxx`.
Endpoint detection now belongs to `tb_top.sv` and the platform runner through
`TOHOST_ADDR` plusargs. This keeps the CPU RTL closer to an ASIC/general-core
style: memory stores are just memory stores, and benchmark exit policy is a
simulation-platform concern.

Initial platform files:

- `tools/sim_platform.py`: prepares platform manifests, converts ELF/binary
  images to byte-hex when needed, discovers ELF `tohost` symbols when the local
  toolchain is available, and delegates runs to `tools/run_benchmarks.py`.
- `tests/sim_platform/stage1_broad.json`: broad Stage 1 coverage manifest that
  includes anchors, existing micro-probes, ISA smoke rows, C smoke rows,
  control-flow rows, and loop rows.
- `Makefile` targets: `sim_platform_list`, `sim_platform_prepare`, and
  `sim_platform_dry`.

## Candidate Matrix

| Suite | Reference Core B source | Coverage value | rv64gc-v2 feasibility | Verdict |
|---|---|---|---|---|
| Frontend microbench | `nexus-am/tests/frontendtest` | Direct BPU, BTB, RAS, IFU width, fetch fragmentation, branch density, and prediction pattern stress | Source is mostly small C loops; port to our CRT and bench MMIO | Highest priority. Add as Stage 1 smoke coverage. |
| Conditional branch patterns | `frontendtest/cond_br_test` | Always/never taken, alternating, 2-bit, 3-bit, prime, nested, switching, rare, early-exit patterns | Pure scalar C; very suitable for BPU ownership validation | Highest priority. |
| Branch target patterns | `frontendtest/br_target_test` | Calls, returns, indirect branches, jumps | Pure scalar C; useful for RAS/BTB/target ownership | Highest priority. |
| MicroBench algorithms | `nexus-am/apps/microbench` | qsort, queen, bf, fib, sieve, 15pz, dinic, lzip, ssort, md5 | Needs AM `uptime`, heap, printf, and `_halt` replaced; algorithms are portable | High priority after frontend microbench. |
| CPUTest scalar programs | `nexus-am/tests/cputest/tests` | Small compiler-generated scalar correctness and control-flow coverage | Very easy to port; not a performance benchmark | Add as fast correctness smoke suite. |
| CoreMark variant | `nexus-am/apps/coremark` | Cross-check image/build diversity | We already have a controlled CoreMark; direct Reference Core B image is not scoreable | Optional source comparison only. |
| Dhrystone variant | `nexus-am/apps/dhrystone` | Cross-check image/build diversity | We already have a controlled Dhrystone | Optional source comparison only. |
| STREAM | `nexus-am/apps/stream` | Sequential memory bandwidth, copy/scale/add/triad loops | Default arrays exceed current memory; can run only with downscaled arrays | Add later as LSU/cache coverage, labelled non-standard STREAM. |
| Mem latency/bandwidth tests | `nexus-am/apps/mem_test/*` | Cache-line, same-set, and memory access behavior | Current constants use addresses beyond 2 MB and Reference Core B cache assumptions | Port after memory sizing/address parameters are cleaned up. |
| RISC-V tests | Reference Core B CI `riscv-tests`; local reference-core build framework riscv-tests also available | ISA and simple scalar benchmark coverage | Scalar `rv64ui/um/ua/uf/ud/uc` are feasible if rebuilt for our tohost; privileged/S-mode rows need care | Add scalar subset as correctness, not perf signoff. |
| RISC-V benchmark suite | Local reference-core build framework `riscv-tests/benchmarks` | mm, qsort, towers, memcpy, median, multiply, rsort, spmv, vvadd | Scalar single-thread subset can be rebuilt for our harness; vector and mt rows excluded | Good second-wave perf diversity. |
| TSVC | `nexus-am/apps/tsvc` | Loop/vectorization-oriented kernels | Default `MARCH` enables RVV/crypto/extra bitmanip; scalar override may be possible | Defer; use only scalarized build if it compiles cleanly. |
| Maprobe/cache probes | `nexus-am/apps/maprobe`, cacheop tests | Cache replacement/latency/bandwidth diagnostics | Uses Reference Core B cache hierarchy/device assumptions | Defer until cache-specific harness support. |
| F16/BF16/vector tests | `nexus-am/tests/bf16`, RVV CI lists | FP/vector extension stress | Requires unsupported ISA extensions | Exclude for current core. |
| H-extension, Svinval, Svnapot, PMP/ASID/system tests | Reference Core B misc/rvh CI lists | Privileged architecture coverage | Requires S/H-mode, MMU, interrupt/device behavior beyond current perf harness | Exclude from Stage 1. |
| Zcb/Zacas/crypto/IOPMP tests | Reference Core B misc CI lists | Extension/device coverage | Unsupported or out of current SoC scope | Exclude. |
| Linux/SPEC checkpoints | Reference Core B CI workload/checkpoint lists | Real workload coverage | Needs OS, devices, checkpoint restore, much larger memory | Long-term only. |

## Recommended Stage 1 Coverage Expansion

### Tier A: immediate smoke suite

Port these first and run them after each BPU/FTQ frontend change:

- `frontendtest/tests`: `2fetch`, `aluwidth`, `brnum`, `brnum2`,
  `brnum2_uftb`, `brnum3`, `brsimple`, `brwidth`, `fetchfrag`, `forloop`,
  `ifuwidth`, `ittage`, `ras_recursive`, `rastest`, `renamewidth`,
  `resolve`, `tage1`, `tage2`, `tage3`, `tage4`, `tage5`.
- `frontendtest/cond_br_test`: `always_taken`, `never_taken`, `alternating`,
  `two_bit_pattern`, `three_bit_pattern`, `prime_based_pattern`,
  `switching_pattern`, `nested_branches`, `rare_branches`,
  `early_exits`, `gradual_transition`, `aliasing_pattern`,
  `all_patterns`.
- `frontendtest/br_target_test`: `call_branch`, `return_branch`,
  `jump_branch`, `indirect_branch`.

Acceptance for this tier should be endpoint identity plus owner-invariant pass.
Do not require every row to improve cycles; these rows are mainly regression
and bottleneck-localization coverage.

### Tier B: algorithm diversity

Port `apps/microbench` with the `test` setting first:

- `qsort`: branchy sorting and memory swaps.
- `queen`: recursion/search.
- `bf`: interpreter-style indirect/control-heavy behavior.
- `fib`: call/return pressure.
- `sieve`: dense loops and stores.
- `15pz`: A* search and heap/list pressure.
- `dinic`: graph traversal.
- `lzip`: compression-style byte streams.
- `ssort`: suffix sort.
- `md5`: hash/rotate/bit-mix workload.

These are the best anti-overfit complement to Dhrystone/CoreMark because they
exercise different control-flow and memory shapes without needing an OS.

### Tier C: memory and scalar benchmark suite

Add after Tier A is stable:

- Downscaled `stream` with explicit `STREAM_ARRAY_SIZE` and `NTIMES` chosen to
  fit 2 MB.
- Downscaled `mem_test_latency` / `mem_test_bw` with test addresses inside the
  rv64gc-v2 sim memory window.
- Scalar single-thread `riscv-tests/benchmarks`: `mm`, `qsort`, `towers`,
  `memcpy`, `median`, `multiply`, `rsort`, `spmv`, `vvadd`.

These should run as DSE/nightly coverage first. Promote a subset to scoreable
coverage only after endpoint, hash, and golden PC generation are stable.

## Harness Work Needed

1. Use the dedicated platform manifest now added at
   `tests/sim_platform/stage1_broad.json`.
2. Extend the host-side image path:
   - current: convert ELF/raw binary to byte-per-line hex via
     `scripts/elf2hex.py` and parse `tohost`/`fromhost` symbols when present;
   - next: add true PT_LOAD segment loading into the simulator memory model so
     the reference-core build framework-style ELF loading does not need an intermediate hex image;
   - keep byte-per-line hex as a compatibility fallback.
3. Split pass/fail handling into selectable simulator ABIs:
   - current: `SIM_ABI=rv64gc-fixed-tohost`, configurable `TOHOST_ADDR`;
   - next: `htif` for Reference Core A/Spike/riscv-tests-compatible symbol-driven
     `tohost`;
   - next: `xs-am-port` for source-rebuilt Nexus-AM `_halt()` mapped to
     rv64gc/htif endpoint stores.
4. Add a small source-port wrapper that provides:
   - `_start` and `.bss` clear.
   - `tohost` write at `0x80001000`.
   - `rv64gc_bench_begin/end/report` at `0x80001080`.
   - `uptime()` backed by `mcycle` or explicit benchmark timer windows.
   - A bounded heap inside the existing 2 MB memory image.
5. For frontend microbench rows, capture at least:
   - endpoint pass/fail,
   - timed cycles and instret,
   - `packet_empty_noemit_dup`,
   - `xs_dup_last_emit`,
   - `redirect_recovery`,
   - `xs_ftq_occ_max`,
   - owner-invariant counters.
6. Keep these rows out of the Stage 1 score target initially. They are coverage
   guardrails against overfitting while Dhrystone/CoreMark remain the baseline
   comparison rows.

## Non-Goals

- Do not implement Reference Core B's custom AM `_halt()` trap just to make prebuilt
  images pass. That would optimize the testbench ABI rather than core behavior.
- Do not add vector/H-extension/Zcb/Zacas/crypto rows to the current core's
  performance matrix.
- Do not claim STREAM-compliant or SPEC-compliant numbers from downscaled or
  checkpoint-free runs. Label them as coverage/probe rows.

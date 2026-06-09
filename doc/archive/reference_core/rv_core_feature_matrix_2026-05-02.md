# RV Core Feature Matrix and Upgrade Verdict

- **Date:** 2026-05-02
- **Scope:** Architectural reference matrix for closing the rv64gc-v2 4-wide
  performance gap versus Reference Core A, with strong verdicts before any RTL
  modification.

## Executive Verdict

Reference Core A should remain the **public calibration floor**, not the SOTA
ceiling. Reference Core B is the most relevant open high-performance reference, but it
must be used as a source of architectural patterns, not as a blueprint. The
rv64gc-v2 path to beating Reference Core A should be an owned design built from three
compound moves:

1. **Frontend decoupling:** implement an FDIP/FTQ-runahead style frontend that
   allows prediction to run ahead of I-cache fetch and packet delivery.
2. **Memory latency avoidance:** add a real L1D prefetch path, starting with
   next-line and IP-stride/stream, then evaluate deeper L2/SMS/BOP class
   prefetch only if misses remain measurable.
3. **Dynamic uop reduction:** expand fusion and default any proven uop-cache or
   loop-delivery path so the backend commits fewer head-blocking uops.

Do **not** widen the core first. The current evidence says the machine is not
ROB/IQ/ALU/CDB limited; it is head-of-ROB/load-use and frontend-delivery
limited. A 5/6-wide backend before fixing feed and memory only buys area and
verification risk.

## Current rv64gc-v2 Baseline

Reference local docs:

- `rv64gc_v2_uarch.md`: 4-wide fetch/decode/rename/dispatch/commit, 128-entry
  ROB, 3 INT IQs, 3 ALUs, 32/32 LQ/SQ, TAGE-SC/loop/BTB frontend.
- `4wide_signoff_2026-05-01.md`: CoreMark iter1 5.01 CM/MHz, iter10
  5.37 CM/MHz, Dhrystone 2.42 DMIPS/MHz.
- `4wide_pipeline_bubble_taxonomy_2026-05-02.md`: CoreMark cycles dominated by
  `HEAD_WAIT_BACKLOG` at 74.04%, with frontend-limited cycles at 11.44%.
- `4wide_headwait_deepdive_2026-05-02.md`: top head stalls are loads with
  immediate consumers; CoreMark long dwell also matches mispredict recovery.
- `4wide_uoplife_findings_2026-05-02.md`: average CoreMark ROB lifetime is
  6.04 cycles/uop, dominated by dispatch-to-issue and writeback-to-commit, not
  rename or ROB-full stalls.
- `pipeline_behavior_confirmation_2026-05-02.md`: fresh current-tree DSim
  confirmation run with `+PERF_PROFILE +TRACE_PIPELINE` for CoreMark,
  Dhrystone, and four microbench/probe workloads.

Gap to Reference Core A floor:

| Metric | rv64gc-v2 current | Reference Core A floor | Required lift |
|---|---:|---:|---:|
| CoreMark/MHz iter1 | 5.01 | 6.2 | +23.8% |
| CoreMark/MHz iter10 | 5.37 | 6.2 | +15.5% |
| Dhrystone DMIPS/MHz | 2.42 | 3.93 to 4.00 | +62% to +65% |

The gap is too large for one local knob. We need a compound design change and
an apples-to-apples benchmark audit before declaring any architecture inferior.

## Bring-Up Evidence and Locked Study Set

This study now has a concrete local reference setup, not just paper references.
The purpose is still architecture calibration; no reference core should become
the rv64gc-v2 implementation base.

Local reference status:

| Reference | Local status | Evidence artifact | Immediate use |
|---|---|---|---|
| **Reference Core A / its build framework** | Existing sibling checkout at `../chipyard`; another session is building and measuring it. | Pending Reference Core A-side counters from that session. | Public floor and trace parity target. |
| **Reference Core B** | Sibling checkout `../xiangshan`; `TLMinimalConfig` elaborated to split RTL. Full emulator run is still pending because it is the heavyweight step. | `../xiangshan/build/rtl/XSTop.sv`, `../xiangshan/build/rtl/XSTop.fir`, 1835 generated RTL files. | Architectural reference for decoupled frontend, wide backend bookkeeping, fusion, and memory prefetch/replay structure. |
| **Reference Core D** | Sibling checkout `../naxriscv`; Verilator simulator built and smoke-run with gem5-O3 style trace enabled. | `../naxriscv/src/test/cpp/naxriscv/output/pipeline-add/trace.gem5o3`, 80983 lines, plus `PASS`. | Low-cost OoO pipeline trace format and load-hit/replay instrumentation reference. |
| **Reference Core E** | Sibling checkout `../rsd`; Verilator 4.228 model built and run through the Konata trace flow. | `../rsd/Processor/Src/Kanata.log`, `../rsd/Processor/Src/RSD.log`, and `../rsd/Processor/Src/Register.csv`. | Compact scheduler, replay, and memory-disambiguation reference with visual pipeline traces. |

Locked initial benchmark set:

| Workload | Required participants | Reason for lock |
|---|---|---|
| **CoreMark short** | rv64gc-v2, Reference Core A first; Reference Core D / Reference Core E only if binary support is practical. | Primary signoff gap and existing rv64gc-v2 taxonomy data. |
| **Dhrystone short** | rv64gc-v2, Reference Core A first; Reference Core D / Reference Core E optional. | Current gap is very large and may include compiler/library/window mismatch. |
| **Branch-loop microbench** | rv64gc-v2, Reference Core A, Reference Core D if easy. | Separates predictor/redirect/refill cost from general backend noise. |
| **Load-use dependency loop** | rv64gc-v2, Reference Core A, Reference Core D, Reference Core E. | Directly targets current head-of-ROB load-use stall evidence. |
| **Memcpy / stream loop** | rv64gc-v2, Reference Core A, Reference Core D if easy. | Tests whether L1D next-line and IP-stride prefetchers can close useful score. |

Do not expand this set until every row has a normalized binary record and at
least rv64gc-v2 plus Reference Core A counters. Extra cores are useful for mechanism
inspection, but the pass/fail floor is still Reference Core A.

Normalized measurement schema:

| Field | Required content |
|---|---|
| Binary identity | Source, compiler version, flags, linker script, libraries, ISA string, and entry/pass symbols. |
| Counter window | Start PC/symbol, end PC/symbol, warmup policy, iteration count, and timeout. |
| Throughput | Cycles, committed instructions, committed uops if available, IPC, and score/MHz where applicable. |
| Frontend | Fetch/rename delivery histogram, empty fetch cycles, branch misses, redirect cycles, and top miss PCs. |
| Backend | ROB occupancy, head-wait classes, issue wait, writeback-to-commit dwell, and commit histogram. |
| Memory | I/D misses, load-hit/miss split, load-use dwell, replays/reschedules, store-load hazards, and MSHR pressure. |
| Trace artifact | Stable local path to the raw trace/log plus a short parser command or notebook reference. |

Current runnable trace samples:

| Core | Workload | Result | Cycles | Commit / uops | IPC | Notable counters |
|---|---|---:|---:|---:|---:|---|
| **Reference Core D** | `rv64i_m/I/add-01.elf` | PASS | 13849 | 11513 commits | 0.831324 | reschedules 17, trap 0, branch miss 0, jump miss 0, store-to-load hazard 0, load hit-miss 0 |
| **Reference Core E** | `Verification/TestCode/Asm/IntRegImm` | PC reached `80001004` | 4675 | 4518 committed ops | 0.966417 | I$ misses 60, D$ load misses 111, D$ store misses 111, branch prediction misses 2, memory-dependence misses 0 |
| **Reference Core B** | `TLMinimalConfig` elaboration | RTL generated | N/A | N/A | N/A | ROB 48, commit width 8, Int IQ 13, FP IQ 4, Vec IQ 4, LQ RAR/RAW/replay 24/12/24, SQ 20, TAGE-SC/BTB-family frontend present |

Five-action completion verdict:

| Action | Status | Next use |
|---|---|---|
| Lock small benchmark set | **Done for Phase 0.** | Use the five rows above as the only required sweep until parity exists. |
| Normalize measurements | **Done for Phase 0 schema; sample data captured for Reference Core D / Reference Core E.** | Apply the same fields to rv64gc-v2 and Reference Core A before ranking features. |
| Use runnable traces first | **Done for first pass.** | Parse Reference Core D / Reference Core E traces for stage timing examples; wait for Reference Core A trace parity for quantitative floor. |
| Maintain feature matrix doc | **Done in this document.** | Keep design debates anchored to the verdict table below and the fresh confirmation run in `pipeline_behavior_confirmation_2026-05-02.md`. |
| Decide upgrade vector | **Done for first pass.** | P0 remains binary/Reference Core A parity, L1D NLP, IP-stride probe, fusion counters, UOC re-probe, then owned FTQ/FDIP frontend. |

## Reference Core Matrix

Verdict key:

- **Use as floor:** compare against it and mine deltas, but do not copy it.
- **Borrow principles:** copy ideas only after adapting them to rv64gc-v2.
- **Probe only:** inspect for a narrow mechanism; not a design anchor.
- **Not a perf target:** useful for infrastructure or methodology, not IPC.

| Core / project | Relevant public features | What matters for rv64gc-v2 | Verdict |
|---|---|---|---|
| **Reference Core A** | Open RV64GC OoO core. Reference Core A docs describe fetch buffer, FTQ, two-level branch prediction, ROB, issue, LSU, and memory system. Reference Core A reports TAGE, redesigned fetch, multiple loads/cycle, 6.2 CoreMark/MHz, and 3.93 DMIPS/MHz. | Best public floor and diff target. Its gains came from frontend redesign, TAGE, execution path cleanup, and multi-load LSU, not just width. | **Use as floor.** Treat as minimum public signoff, not SOTA. Every proposed feature should predict which Reference Core A delta it closes. |
| **Reference Core B** | 6-wide decode/rename/dispatch, 160-entry ROB, up to 8 retire/cycle, instruction fusion, move elimination, snapshot recovery, rename buffer/RAB, nonblocking FTQ/BPU flow, frontend predecode repair, L1/SMS prefetch hooks, L2 BOP, early load wakeup. | Most relevant open reference for a modern RV backend/frontend split. It shows the direction: decoupled frontend lifecycle, explicit redirect metadata, stronger memory prefetch/replay, and uop-count reduction. | **Borrow principles.** Do not clone. Use it to validate our chosen abstractions and counter names. |
| **Reference Core C** | Reference Core C RTL release with Verilog source, simulation environment, implementation scripts, and user/integration manuals. Commercial-style 12-stage OoO RV64 core with vector lineage, but public docs are uneven. | Useful for concrete RTL examples of mature control/LSU/physical implementation tradeoffs. Harder to mine than Reference Core A / Reference Core B because documentation is sparse. | **Probe only.** Inspect narrow modules if a specific RTL question appears. Not the primary design reference. |
| **Reference Core D** | Open OoO core in SpinalHDL. Documented as superscalar, register-renamed, Linux-capable, low-area FPGA-targeted, nonblocking D-cache, BTB+GShare+RAS, 3-cycle load-to-use via speculative cache-hit predictor, Konata visualization. | Good reference for simple, measurable OoO machinery and pipeline visualization. Its design goals favor FPGA area/fmax over max IPC. | **Borrow instrumentation and low-cost memory ideas.** Not a Reference-Core-A-beating target. |
| **Reference Core E** | RV32 OoO superscalar. 2-fetch frontend, 6-issue backend, up to 64 in-flight instructions, speculative scheduler with replay, speculative OoO load/store, dynamic memory disambiguation, nonblocking L1D, Konata logs. | Good compact reference for scheduler replay and dynamic memory disambiguation. ISA/scale are below rv64gc-v2 target. | **Probe scheduler/LSQ concepts.** Not a direct architecture target. |
| **Reference Core F / Reference Core F (enhanced) / HPDCache** | Reference Core F is a configurable Linux-capable 6-stage RV core with branch prediction and perf model. Reference Core F (enhanced) work reports branch prediction, register renaming, operand forwarding, and HPDCache integration with large cache-bandwidth improvement. | Strong memory-system and performance-model reference. Less relevant for a full OoO backend. HPDCache-style nonblocking bandwidth ideas are useful if L1D/L2 pressure becomes measurable. | **Borrow methodology and memory-system ideas.** Not a core IPC target. |
| **Reference Core G** | Linux-capable RV64GC+ multicore, modular/coherent system, BedRock coherence, strong integration and silicon-validation orientation. | Useful for SoC/coherence methodology, not for single-thread OoO IPC. | **Not a perf target.** Keep as integration reference only. |
| **various open scalar/in-order/embedded cores** | Important open cores, mostly scalar/in-order or embedded/FPGA oriented. | Useful for style, verification, and ecosystem, but their frontend/backend assumptions do not address the Reference Core A gap. | **Reject as performance architecture references** for this effort. |

## Feature Direction Matrix

Priority key:

- **P0:** evaluate or implement before any width change.
- **P1:** next wave if P0 does not close the gap.
- **P2:** credible but high effort or workload-dependent.
- **P3:** long-term or non-signoff.
- **Reject:** do not spend design time unless new data invalidates current
  traces.

| Direction | References | rv64gc-v2 evidence | Expected impact | Effort / risk | Verdict |
|---|---|---|---:|---|---|
| **Benchmark/compiler parity audit** | Reference Core A reports public CoreMark/Dhrystone scores; local docs disagree on Dhrystone flag contribution. | Dhrystone gap is too large to trust without identical flags, linker script, libraries, iteration counts, and counter windows. | Unknown; could be large for Dhrystone. | 1-2 days, no RTL. | **P0, mandatory.** No architecture verdict until binaries are normalized. |
| **Reference Core A trace parity pack** | Reference Core A has event tracking and clear frontend/LSU docs. | We need Reference Core A-side frontend delivery, branch misses, ROB dwell, load-use, and top PCs to know whether our gap is truly architectural. | Prevents wrong RTL work. | 1-3 days once Reference Core A build is ready. | **P0, mandatory.** Ask other session for same counters, not just total cycles. |
| **FDIP / decoupled fetch with FTQ runahead** | FDIP literature; Reference Core A FTQ/fetch buffer; Reference Core B FTQ where BPU can run ahead and feed IFU/prefetch. | Current fetch delivers about 2 uops/cycle into 4-wide; packet/control interaction leaves empty delivery cycles; mispredict refill is visible. | +3-8% CoreMark plausible; lower Dhrystone. | 2-3 weeks, medium redirect/RAS risk. | **P0 adopt.** This is the highest-ceiling frontend feature. |
| **I-cache prefetch from FTQ/runahead stream** | Reference Core B FTQ can send prefetch requests; FDIP uses branch-predicted future fetch blocks. | I$ miss wait is small in current CoreMark, but runahead naturally creates an I-prefetch stream. | +0-2% current benches; more on larger code. | Small if built with FDIP. | **P1 piggyback.** Do not build standalone first. |
| **Fetch packet flow-through/bypass tweaks** | Reference Core A fetch buffer supports flow-through queues. rv64gc-v2 already has packet-bypass plusargs. | Historical packet bypass variants did not move steady-state IPC; packet_empty_enq is often an artifact of buffer timing. | Near 0% if isolated. | Low effort but distracting. | **Reject as standalone.** Only revisit inside full decoupled frontend. |
| **More BPU capacity only** | Reference Core A TAGE; Reference Core B TAGE-SC. | Prior uBTB/TAGE growth did not materially help; current predictor is already larger than Reference Core A in several dimensions. | Low unless Reference Core A trace proves PC-specific misses. | Low-medium. | **Reject generic sizing.** Allow only PC-targeted predictor fixes. |
| **Indirect/return/target predictor fixes** | Reference Core A NLP/BPD split; Reference Core B FTQ redirect and RAS metadata. | CoreMark long dwell includes mispredict refill. We need top mispredict PCs to know if indirect/ret/BTB target, not direction, dominates. | 0-4% if a target class is exposed. | Medium. | **P1 conditional.** Probe before implementation. |
| **FTB / multi-CFI fetch block prediction** | Reference Core B FTB/FTQ style frontend; fetch-target-buffer literature. | Current 16B packet path is sensitive to taken/control transfers. | +2-5% if multi-CFI/taken density is high. | High frontend complexity. | **P1 after FDIP.** Do not start before runahead FTQ exists. |
| **Dual-cacheline or 32B fetch** | Reference Core B IFU documents dual-cacheline fetch handling. | Current frontend supply is low, but raw bytes are not yet proven as the limiter; CFI and packet control dominate. | 0-5%, workload dependent. | High align/RVC/I$ cost. | **P2 defer.** Evaluate after FDIP counters. |
| **Default uop cache / uop cache re-probe** | Local `uop_cache_design_2026-04-25.md`; x86 DSB/op-cache analogy. | UOC was not beneficial in an older 6-wide context; 4-wide frontend data now justifies re-probe. | 0-4% if hot loops hit and rename accepts. | Probe is low; productizing medium. | **P0 probe.** Enable by default only if 4-wide delta is repeatable. |
| **Loop buffer improvements** | Local loop-buffer path; industry loop stream detectors. | Current LB replay creates many fetch=0/rename>0 cycles, meaning it already supplies rename. | Small unless replacing decode path. | Medium. | **P1 only as UOC path cleanup.** Do not tune LB as a separate feature. |
| **L1D next-line prefetcher** | Reference Core A notes small next-line prefetch; Reference Core B has explicit prefetch hooks. | Current head stalls are load-use heavy; not all are miss-related, but Dhrystone/string/matrix loops can benefit. | +0.5-2% CoreMark, +3-6% Dhrystone. | 2-4 days, low risk if MSHR-gated. | **P0 adopt.** Cheapest memory feature with bounded downside. |
| **IP-stride / stream L1D prefetcher** | Common commercial baseline; Reference Core B L1/SMS prefetch training path. | Matrix/string loops likely have recurring strides; current design has no real D-prefetcher. | +1-4% CoreMark, +4-10% Dhrystone. | 1-2 weeks, medium pollution risk. | **P0/P1 adopt after NLP.** Gate by confidence and MSHR availability. |
| **BOP/SMS/L2 prefetcher** | Reference Core B L2 includes BOP and receives L1-trained prefetches. | Current benches are not proven L2-miss limited, but stronger prefetch is needed for broader signoff. | Low on tiny benches, higher on larger workloads. | 3-6 weeks, memory-system risk. | **P2 defer.** Build only after L1 prefetch counters show demand. |
| **Advanced spatial/temporal prefetchers (Berti/Bingo/SPP/Pythia)** | Recent data-prefetch literature. | CoreMark/Dhrystone are too small to justify complex metadata first. | Potentially large on SPEC-like suites, uncertain here. | High. | **P3 research.** Not first gap-closure work. |
| **Pointer-chase or Markov prefetch** | Pointer-chase prefetch literature; Reference Core B docs note no load point-chasing support. | One top PC is pointer chasing, but absolute contribution appears too small for a large mechanism. | <1% current CoreMark likely. | High correctness/pollution risk. | **Reject near-term.** Revisit only for graph workloads. |
| **Load-hit predictor / miss-aware wakeup replay** | Reference Core D documents speculative cache-hit predictor and 3-cycle load-to-use. | rv64gc-v2 already has aggressive load wakeup; unknown replay waste. | 0-2% if replay rate is high. | 2-4 days for counters, ~1 week RTL. | **P1 probe.** Implement only if replays exceed threshold. |
| **Store sets / memory dependence predictor** | Store-sets literature; Reference Core E dynamic memory disambiguation; Reference Core A LSU memory-order failure model. | Current hot CoreMark patterns are mostly load-load/load-use; Dhrystone may be more store-heavy. | 0-2% current benches; more general workloads. | 2-3 weeks, high verification sensitivity. | **P1 conditional.** Probe store-blocked load cycles first. |
| **Nonblocking D-cache / more MSHRs** | Reference Core D/Reference Core E nonblocking D-cache; HPDCache. | Current traces do not show long D$ miss tails; loads with issue-to-WB >20 cycles are absent. | Near 0% on current benches; future value. | Medium-high. | **P2 defer.** Do not use for CoreMark/Dhrystone closure first. |
| **Critical-word-first / early refill wakeup** | Reference Core B L2 early load wakeup. | Only helps miss/refill cases, which are currently a small fraction. | <1% current benches. | Medium. | **P2 defer.** Pair with stronger cache study later. |
| **L1D hit latency 2-to-1 cycle / way prediction** | Commercial high-performance cache design. | Top head stalls are immediate load consumers; this is the direct structural fix. | Very high ceiling, potentially >10%. | Very high timing/area/verification risk. | **P2 escalation.** Consider only if P0/P1 still leave >10% CoreMark gap. |
| **Load-load pair fusion / paired load uop** | a commercial high-performance core vendor-style LDP fusion analogy; Reference Core B instruction fusion as reference. | CoreMark has adjacent field/list loads; fewer load uops means fewer head blockers and less LSU pressure. | +0.5-2% if patterns exist. | 1-2 weeks, alignment/cross-line risk. | **P1 probe/adopt.** Start with static pattern counter before RTL. |
| **Load-store or store-data/address fusion/splitting policy** | Reference Core A LSU handles store address/data tradeoffs; Reference Core E/Reference Core A memory scheduling. | Dhrystone has many stores; current store path should be profiled for STA/STD or store-data readiness blocking. | 0-3% if store-heavy stalls exist. | Medium. | **P1 probe.** Do not assume until store-block counters exist. |
| **Compare/branch and ALU/branch macro-fusion expansion** | Reference Core A SFB and common commercial macro-fusion; Reference Core B instruction fusion. | Current partial fusion exists; dynamic uop count still matters because head wait amplifies each uop. | +0.5-2%. | 2-5 days, low-medium risk. | **P0/P1 adopt.** Low-cost, but validate with dynamic fusion hit counters. |
| **Move elimination / zero idiom elimination** | Reference Core B move elimination and rename machinery. | Dynamic uop reduction helps frontend and commit density; actual `mv`/zero count unknown. | 0-2% depending binary. | 1 week if rename hooks are clean. | **P1 probe.** Implement only with dynamic count evidence. |
| **Head-aware issue scheduling** | General OoO scheduling policy; local head-wait evidence. | Head stalls arise when loads/MULs reach head before WB. Issuing likely-to-be-head loads earlier may reduce dwell without changing semantics. | 0-3%, uncertain. | 1-2 weeks; policy can backfire. | **P1 experiment.** Sim/probe first, plusarg-gated. |
| **No-stall/fast-track commit hints** | Local idea from headwait deep dive. | In-order commit cannot be relaxed, but decode/dispatch can favor uops likely to complete before reaching head. | Unknown. | Medium-high conceptual risk. | **P2 research.** Not first implementation. |
| **More ROB entries** | Reference Core A / Reference Core B have large ROBs. | rv64gc-v2 ROB occupancy averages around 10-13, not full. | Near 0%. | Low RTL, area cost. | **Reject.** Current workload is not ROB-depth limited. |
| **More IQ entries / IQ reorg** | Prior local Cycle F. | IQ wait exists but prior reorg did not help; bottleneck is completion/head wait. | Near 0%. | Medium. | **Reject unless new counters change.** |
| **More ALUs / CDB / bypass ports** | Prior local Cycle E and ALU3 bypass work. | Existing changes produced marginal gains; head loads/MULs dominate. | Near 0-1%. | Medium timing risk. | **Reject generic expansion.** |
| **Faster or more pipelined MUL** | Head dwell shows MUL/multi-cycle contribution around 2.6% CoreMark cycles. | Small but real CoreMark anchor; not enough alone. | +0.5-1.5%. | Medium area/timing. | **P1 only if cheap.** Avoid exotic 1-cycle multiplier as first move. |
| **DIV/SQRT acceleration** | Backend latency feature. | Current benches do not show meaningful DIV head dwell except small Dhrystone cases. | Near 0%. | Medium-high. | **Reject for signoff.** |
| **Wider commit / ROB compression / 8-retire** | Reference Core B retires up to 8 and compresses ROB entries. | Current problem is head readiness, not retire bandwidth. | Low until head wait reduced. | High. | **P2 after P0/P1.** Useful only if commit_count reaches 4 often. |
| **5-wide or 6-wide full backend** | Reference Core B 6-wide, Reference Core A 4-wide fetch/8-wide issue class. | Current 4-wide pipe is underfed and head-blocked. Widening now hides neither load-use nor mispredict refill. | Could be high after feed/memory fixes; poor now. | Very high. | **P3 defer.** Reconsider only when rename delivery >3 uops/cycle and head wait <50%. |
| **Vector/RVV unit** | Reference Core A future work; Reference Core B vector backend. | CoreMark/Dhrystone scalar signoff will not use RVV. | 0% for current signoff. | Very high. | **Reject for this goal.** Future product feature only. |
| **Zicbop software prefetch hints** | RISC-V cache-block operation extension. | Existing benchmark binaries do not issue hints. | 0% unless compiler/source changes. | Low. | **Reject for core IPC signoff.** Keep as later ISA completeness. |
| **Custom ISA or benchmark-specific source tuning** | Not a core microarchitecture reference. | Could improve scores but would weaken signoff credibility. | Unknown. | Low RTL, high credibility risk. | **Reject as architecture closure.** Compiler parity is allowed; benchmark-specific tricks are not. |
| **SMT / helper threading / runahead execution** | Runahead literature and commercial latency-hiding concepts. | Could hide long misses, but current misses are not dominant and speculative state cost is high. | Low current; high future memory workloads. | Very high verification risk. | **Reject near-term.** Not compatible with current schedule. |
| **Clock/frequency retiming only** | Physical implementation concern. | Metrics are per-MHz IPC-like scores; frequency does not close CM/MHz or DMIPS/MHz. | 0% for normalized scores. | Could help ASIC product separately. | **Reject for performance-gap metric.** Track separately for signoff. |

## Proposed Evaluation Sequence

### Phase 0: Data Lockdown Before RTL

Verdict: **mandatory**.

1. Normalize CoreMark and Dhrystone binaries between rv64gc-v2 and Reference Core A:
   compiler version, flags, linker script, libraries, iteration counts, and
   exact counter window.
2. Capture Reference Core A-side counters matching rv64gc-v2 categories:
   frontend delivery histogram, commit histogram, ROB occupancy, branch
   miss count and top PCs, load-use head dwell, D$ miss/replay statistics.
3. Re-probe existing rv64gc-v2 features with plusargs:
   UOC enable, packet-bypass variants, loop-buffer toggles, and any existing
   fetch guard modes. Promote only repeatable wins.

Exit criteria:

- If Dhrystone improves materially after binary parity, separate compiler gap
  from architecture gap.
- If Reference Core A has similar head-load dwell but better frontend delivery, prioritize
  FDIP/UOC/fusion.
- If Reference Core A has much lower load dwell or better miss behavior, prioritize
  L1D prefetch and load/replay mechanisms.

### Phase 1: Low-Risk Compound Gains

Verdict: **start here after Phase 0**.

1. L1D next-line prefetcher with strict MSHR/backpressure gating.
2. IP-stride/stream prefetcher, plus pollution/usefulness counters.
3. Macro-fusion expansion with dynamic fusion-hit counters.
4. UOC default path only if the 4-wide re-probe shows a repeatable win.
5. Load/replay and store-blocked-load probes before adding predictors.

Target outcome: +5-10% CoreMark combined, larger Dhrystone lift if memory and
uop-count effects are real.

### Phase 2: Owned Frontend Recalibration

Verdict: **required to beat Reference Core A, not just approach it**.

Build a decoupled frontend around an FTQ/runahead contract:

- Predictor can generate future fetch blocks independent of immediate I-cache
  acceptance.
- FTQ owns prediction metadata, RAS/global-history recovery data, and redirect
  repair.
- IFU consumes blocks from FTQ and can use unused depth for I-cache prefetch.
- Fetch packet buffer should become a consumer queue, not the timing center of
  the frontend.

Success criteria:

- Reduce packet/control empty cycles by at least 30%.
- Increase average rename supply toward 2.4-2.8 uops/cycle on CoreMark.
- Do not increase branch mispredict count.
- Show positive or neutral Dhrystone change.

### Phase 3: Escalation Only If Needed

Verdict: **defer until Phase 1/2 data exists**.

Escalate in this order:

1. Targeted indirect/return/FTB predictor features if top mispredict PCs demand
   it.
2. L1D hit-latency structural work only if head-load dwell remains the largest
   gap after prefetch/fusion.
3. Commit/ROB compression and width only after commit is frequently saturated.
4. 5/6-wide backend only after frontend and memory can feed sustained
   >3 uops/cycle.

## Strong Non-Goals

- Do not clone Reference Core B wholesale. That would produce a derivative design, not
  an rv64gc-v2 architecture.
- Do not chase more ROB/IQ/ALU/CDB capacity without a counter proving the exact
  structure is limiting.
- Do not use benchmark-specific source hacks as architectural closure.
- Do not pursue RVV, SMT, runahead execution, or pointer-chase prediction for
  CoreMark/Dhrystone signoff.
- Do not treat Reference Core A as SOTA. Treat it as a public floor and a measurement
  harness.

## Source Links

- Reference Core A documentation: https://docs.boom-core.org/en/latest/
- Reference Core A instruction fetch and FTQ docs:
  https://docs.boom-core.org/en/latest/sections/instruction-fetch-stage.html
- Reference Core A branch prediction docs:
  https://docs.boom-core.org/en/latest/sections/branch-prediction/index.html
- Reference Core A BPD/FTQ metadata docs:
  https://docs.boom-core.org/en/latest/sections/branch-prediction/backing-predictor.html
- Reference Core A LSU docs:
  https://docs.boom-core.org/en/latest/sections/load-store-unit.html
- Reference Core A CARRV 2020 paper:
  https://people.eecs.berkeley.edu/~krste/papers/SonicBOOM-CARRV2020.pdf
- Reference Core B backend overview:
  https://docs.xiangshan.cc/projects/design/en/kunminghu-v3/backend/
- Reference Core B FTQ docs:
  https://docs.xiangshan.cc/projects/design/en/kunminghu-v3/frontend/FTQ/
- Reference Core B IFU docs:
  https://docs.xiangshan.cc/projects/design/en/kunminghu-v3/frontend/IFU/
- Reference Core B TAGE-SC docs:
  https://docs.xiangshan.cc/projects/design/en/kunminghu-v3/frontend/BPU/TAGE-SC/
- Reference Core B LoadUnit docs:
  https://docs.xiangshan.cc/projects/design/en/kunminghu-v3/memblock/LSU/LoadUnit/
- Reference Core B L2/cache prefetch docs:
  https://docs.xiangshan.cc/projects/design/en/kunminghu-v3/cache/l2cache/CoupledL2/
- Reference Core C repository:
  https://github.com/XUANTIE-RV/openc910
- Reference Core D docs:
  https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/introduction/index.html
- Reference Core E repository:
  https://github.com/rsd-devel/rsd
- Reference Core F repository:
  https://github.com/openhwgroup/cva6
- Reference Core F (enhanced) paper:
  https://arxiv.org/abs/2505.03762
- Reference Core G repository:
  https://github.com/black-parrot/black-parrot
- Fetch Directed Instruction Prefetching:
  https://cseweb.ucsd.edu/~calder/abstracts/MICRO-99-FDP.html
- Store Sets memory dependence prediction:
  https://people.csail.mit.edu/emer/media/papers/1998.06.isca.storesets.pdf
- Berti prefetcher:
  https://dpc3.compas.cs.stonybrook.edu/pdfs/Berti.pdf
- Bingo spatial data prefetcher:
  https://github.com/bakhshalipour/Bingo

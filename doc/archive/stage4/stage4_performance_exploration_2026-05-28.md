# Stage 4 Performance Exploration

Date: May 28, 2026

Status: active performance phase. Stage 3 Linux boot is closed; Stage 4 now
returns to architectural performance improvement. The UVM placeholder is parked
and is not the active Stage 4 plan.

## Baseline

Fresh baseline artifact:
`benchmark_results/stage4_profiled_baseline_20260528a`.

The run is a clean current-tree DSim build with the full 16-row signoff
manifest, strict fetch owner/delivery checks, strict branch recovery checks,
`+PERF_PROFILE`, `+PERF_COUNTERS`, `+STAT_DUMP`, and
`+BOTTLENECK_PROFILE`.

| Row | Timed cycles | Metric |
|---|---:|---:|
| Dhrystone 100 | `18,068` | `3.150055` DMIPS/MHz |
| Dhrystone 300 | `53,047` | `3.218761` DMIPS/MHz |
| CoreMark 1 | `150,396` | `6.649113` CM/MHz |
| CoreMark 10 | `1,459,538` | `6.851483` CM/MHz |

Stretch targets remain `4.0` DMIPS/MHz and `7.5` CM/MHz.  These require
multiple structural improvements; Stage 4 must not chase benchmark-shaped
thresholds or software changes.

## First Branch: LSU Store-Address Visibility

Chosen first branch: Dhrystone-oriented load/store dependency timing with
CoreMark non-regression.

Current DS evidence:

- DS100 has `xs_bottleneck_dep_wait_on_load=14,772`,
  `xs_bottleneck_lsu_load_issue_lost_slots=2,117`, and store-order blocks
  `ld0=800`, `ld1=997`.
- DS300 has `xs_bottleneck_dep_wait_on_load=44,643`,
  `xs_bottleneck_lsu_load_issue_lost_slots=8,708`, and store-order blocks
  `ld0=2,998`, `ld1=3,892`.
- Store-order blocks are almost all same-cycle STA proxy events, but the SQ CAM
  already has exact same-cycle STA visibility.  Therefore the first slice moves
  load/store ordering ownership to the SQ CAM and removes the coarse store-IQ
  older-entry proxy from the load suppress path.

The first slice was not unresolved-store speculation.  A load may issue only
when the LSU/SQ path proves there is no older address-unknown wait, no data
missing wait, no partial forwarding hazard, no AMO/MMIO/fence/VM suppression,
and no flush suppression.  The store-IQ older-entry signal remains available
for profiling but is no longer an architectural load suppress source.

Result artifact:
`benchmark_results/stage4_lsu_sq_owned_gate_smoke_20260528a`.

Verdict: quarantined as DSE-only evidence, not a promotion candidate.  The
strict DS100 and CM1 smoke was endpoint-clean, but cycles and target counters
were identical to baseline:

| Row | Baseline cycles | Trial cycles | Verdict |
|---|---:|---:|---|
| Dhrystone 100 | `18,068` | `18,068` | no movement |
| CoreMark 1 | `150,396` | `150,396` | no movement |

The DS100 LSU counters also did not move:
`xs_bottleneck_lsu_load_issue_lost_slots=2,117`,
`xs_bottleneck_lsu_load_issue_store_order_ld0=800`,
`xs_bottleneck_lsu_load_issue_store_order_ld1=997`,
`xs_bottleneck_lsu_sq_addr_unknown_p0=800`, and
`xs_bottleneck_lsu_sq_addr_unknown_p1=997`.
Therefore the coarse store-IQ proxy was restored to the load suppress path.
The true Dhrystone store-order blocker remains inside the SQ address/data
readiness path, not this top-level proxy.

## Second Branch: IQ2 ALU Ready-Enqueue Bypass

Chosen second branch: scheduler ready-at-enqueue visibility for the IQ2 ALU
lane, targeting CoreMark ALU dependency counters with Dhrystone non-regression.

Current CoreMark evidence:

- CM1 has `xs_bottleneck_dep_wait_on_alu=915,721`,
  `xs_bottleneck_dep_alu_wait_not_issued=833,504`, and
  `xs_bottleneck_iq2_enq_ready_hidden=20,033`.
- CM10 has `xs_bottleneck_dep_wait_on_alu=8,965,092`,
  `xs_bottleneck_dep_alu_wait_not_issued=8,165,615`, and
  `xs_bottleneck_iq2_enq_ready_hidden=194,866`.
- IQ0 and IQ1 already use ALU-only enqueue issue bypass.  IQ2 has the same
  issue queue support but had bypass disabled because the port is shared with
  CSR, DIV, and serialized FPU traffic.

The IQ2 trial kept bypass ALU-only and added a separate
`enq_issue_bypass_suppress` input so enqueue bypass selection does not depend
on the external resident-entry `issue_suppress` network.  This preserves an
acyclic ready/select path and blocks IQ2 enqueue bypass whenever shared CDB
traffic from FPU or DIV could collide.

Result artifact:
`benchmark_results/stage4_iq2_alu_enq_bypass_smoke_20260528a`.

Verdict: rejected due to CoreMark timed-cycle regression.  The smoke was
endpoint-clean, and the intended local counter moved, but the global bottleneck
did not improve.

| Row | Baseline timed cycles | Trial timed cycles | Verdict |
|---|---:|---:|---|
| Dhrystone 100 | `18,068` | `18,068` | neutral |
| CoreMark 1 | `150,396` | `150,667` | regressed `0.18%` |

Counter movement explains the rejection:

- CM1 `xs_bottleneck_iq2_enq_ready_hidden` dropped from `20,033` to `3,397`.
- CM1 `xs_bottleneck_iq2_enq_ready_issued_bypass` rose from `0` to `19,381`.
- CM1 `xs_bottleneck_dep_wait_on_alu` worsened from `915,721` to `935,577`.
- CM1 `xs_bottleneck_dep_alu_wait_not_issued` worsened from `833,504` to
  `860,829`.
- CM1 `xs_bottleneck_dep_alu_wait_not_issued_producer_blocked_single_alu`
  worsened from `695,745` to `724,418`.

Interpretation: IQ2 ready-at-enqueue slots are real, but using them locally
does not remove the critical CoreMark ALU dependency chain.  In this form it
changes scheduling order/port timing enough to increase producer-blocked
cycles.  Do not promote IQ2-only enqueue bypass.  Future scheduler work should
target oldest-ready producer selection, ALU port balance, or wakeup/select
latency across all integer queues rather than filling only IQ2 idle enqueue
slots.  The RTL was restored to the committed baseline after this smoke.

## Promotion Gates

Each DSE slice must pass in this order:

1. Rebuild DSim from the current RTL.
2. Strict DS100 and CM1 smoke with bottleneck counters.
3. Four-row anchor: DS100, DS300, CM1, CM10.
4. Full 16-row signoff if the four-row anchor is clean.
5. RV64GC compliance and full DSim Linux `BOOT OK` replay before final
   promotion of any accepted RTL, because Stage 3 established Linux boot as a
   hard architectural gate.

Promotion requires:

- The targeted primary rows improve by at least `3%`.
- DS100, DS300, CM1, and CM10 do not regress beyond the `0.01%` hard gate.
- `xs_bottleneck_lsu_ordering_violations`,
  `xs_bottleneck_lsu_spec_replays`, and `xs_bottleneck_lsu_replay_valid` stay
  at zero.
- Fetch owner, stale packet, delivery, and branch recovery invariant counters
  stay clean.

If a branch does not move its target counters materially, quarantine it as
DSE-only evidence and restore the last accepted RTL baseline before continuing.

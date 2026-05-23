# Stage 3 Linux Boot Plan

Date: May 10, 2026

Status: performance optimization is paused. Stage 3 is the Linux boot bring-up
phase. The RV64GC instruction compliance prerequisite is closed on the current
RTL candidate and the DS/CM hard performance gate remains mandatory. Linux
panic/no-retire chasing is paused while the Verilator `Active region did not
converge` failure is treated as an RTL convergence and ASIC-quality blocker.
Do not resume Linux long-run debug until in-core combinational feedback is
removed without breaking strict owner checks or the DS/CM performance guard.

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

- All required RV64GC rows pass on a rebuilt DSim image from the current
  working tree. Verilator is the Stage 3 Linux-debug fallback when the DSim
  lease is unavailable, but it does not lower the compliance or DS/CM
  promotion bar.
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

## May 23 AMO Wait Owner Checker Update

The May 23 Verilator lost-load-owner stop was root-caused as a Stage 3
testbench checker contract bug, not as an RTL LSU owner loss.

Evidence:

- Failing artifact:
  `linux_boot_results/stage3_lost_owner_terms_verilator_20260523a`.
- The run stopped at cycle `20,700,837` with LQ entry `2`, ROB `41`,
  physical address `0x8108b940`, and D-cache MSHR `0` tracking the same line
  behind a dirty eviction.
- Focused trace showed the load was an AMO/LR-class load:
  `is_amo=1`, `load_nocache_r=1`, `amo_wait_load_r=1`.
- The data path was legal: AMO load waits for either the D-cache hit response
  or `amo_load_fill_fire` from the matching D-cache fill. The generic LMB path
  intentionally excludes AMO loads.
- The lost-owner checker already counted load pipe stages, retries,
  forwarding holds, D-cache holds, split load, MMIO response hold, AMO
  writeback, and LMB entries, but it did not count `amo_wait_load_r`.

Implemented testbench repair:

- `src/tb/tb_linux.sv` now treats `amo_wait_load_r` with matching `lq_idx` as
  a legal owner in `linux_lq_entry_has_owner`.
- The failure dump now prints the AMO wait/writeback/store state to avoid
  misclassifying AMO fill wait as an ownerless load again.
- The p1 retry RTL experiment from the earlier hypothesis did not change this
  failure and was reverted. No synthesizable RTL change is promoted by this
  checker fix.

Validation:

- Verilator Linux platform rebuild: pass, with the existing frontend/CVFPU
  `UNOPTFLAT` warnings still visible and unsuppressed.
- Focused 25M-cycle backup run:
  `linux_boot_results/stage3_amo_owner_25m_verilator_20260523a`.
- Result: `PASS` by `TIMEOUT` at `25,000,000` cycles with
  `+LINUX_STOP_ON_NO_COMMIT` and `+LINUX_STOP_ON_LOST_LOAD_OWNER` enabled.
- The run crossed the previous `20,700,837`-cycle stop point and still had
  active retirement at the `25,000,000`-cycle status checkpoint.

Current verdict:

- The old May 23 `LINUX_STOP_LOST_LOAD_OWNER` at `0x8108b940` is closed as a
  false checker stop.
- This is not 100M Linux milestone proof. The next proof run should use the
  corrected checker and keep the no-commit and lost-owner stops enabled.
- Because this slice changes only testbench/debug logic, the DS/CM 0.01%
  performance gate is not required for this commit. The performance gate
  remains mandatory before any Stage 3 RTL modification is promoted.

## May 20 Panic Debug Pivot

The 100M-cycle Linux run is no longer the active action item while a panic is
suspected. The DSim timer-divided runs
`linux_boot_results/stage3_timer_div_100m_unblock_dsim_20260520b`,
`linux_boot_results/stage3_timer_div_100m_unblock_dsim_20260520d`, and
`linux_boot_results/stage3_100m_unblock_dsim_20260520a` were stopped for
triage at the user's request instead of waiting for the 100M cap.

Current evidence from those stopped runs:

- The run used the rebuilt timer-divided DSim image from the current RTL.
- `stage3_timer_div_100m_unblock_dsim_20260520b` is clean through the last
  emitted `55,000,000`-cycle status checkpoint.
- `stage3_timer_div_100m_unblock_dsim_20260520d` is clean through the last
  emitted `40,000,000`-cycle status checkpoint.
- `stage3_100m_unblock_dsim_20260520a` is clean through the last emitted
  `30,000,000`-cycle status checkpoint and was stopped before a summary file
  was written.
- No current `Kernel panic`, `Oops`, `BUG:`, `Unable to handle`, or
  `LINUX_STOP` marker is present in those stopped 2026-05-20 artifacts.
- The old `ffffffff805c5dec` trap-frame/`strcmp` panic window is passed in the
  current run without a trap by the `10,000,000`-cycle checkpoint.
- The old low-physical-fetch panic at `0000000080003f7c` is also passed in the
  current `20260520d` run: the UART log reaches `Mountpoint-cache`,
  `devtmpfs`, `HugeTLB`, and `raid6` output without `Unable to handle`, `Oops`,
  or `Kernel panic`.
- The old `watchdog: BUG:` artifact
  `linux_boot_results/stage3_current_100m_goal_dsim_20260519223941` is stale
  for current RTL because it predates the CLINT `mtime` divider. In that old
  run Linux time reached `52.017374` seconds by `68,563,458` core cycles. In
  the current run, `mtime=mcycle/100`, and the `55,000,000`-cycle checkpoint is
  still at Linux time `0.356237` seconds in `raid6` probing.

Debug verdict:

- There is no fresh current-RTL panic artifact in the checked Linux run
  directories as of May 20, 2026.
- The latest reproducible panic-class signature in the repo is the stale
  `watchdog: BUG:` path from May 19, 2026. Its timing is consistent with the
  old CLINT timer running too fast relative to the DTS `timebase-frequency =
  <1000000>`.
- Do not make a pipeline RTL change for this stale signature. First reproduce a
  current-RTL `Kernel panic`, `Oops`, `BUG:`, or `Unable to handle` marker with
  delayed UART failure capture enabled, then debug that fresh artifact.

## May 21 Kernel Panic Debug Pivot

The current action item is debug, not waiting for a longer Linux timeout.  A
fresh 100M DSim run,
`linux_boot_results/stage3_100m_first_failure_dsim_20260521a_retryloop`,
did not reproduce the old `ffffffff805c5dec` Oops or the low-fetch panic, but
it also did not prove boot progress.  It froze after the 62,720,377-cycle
commit point:

- final committed PC: `0x000000008000c83e`, in OpenSBI `mtimer_event_start`;
- ROB head PCs: `0x8000c840`, `0x8000c842`, with the head load not ready;
- status stayed unchanged from 65M through 100M cycles while `mtime` kept
  advancing past `mtimecmp`.

Latest May 21 triage update:

- A newer rebuilt DSim run,
  `linux_boot_results/stage3_lsu_lmb_owner_retry_100m_unblock_dsim_retry_20260521a`,
  was stopped deliberately at cycle `60,681,812` after the debug pivot.  It is
  not a 100M signoff artifact.
- That stopped run has no current `Unable to handle`, `Oops`, `BUG:`,
  `Kernel panic`, or `LINUX_STOP` marker.  UART reaches
  `clocksource: Switched to clocksource riscv_clocksource`.
- The historical `ffffffff805c5dec` Oops symbolizes to kernel `strcmp`, called
  by `try_enable_preferred_console` with return address
  `ffffffff80059a4a`.  The reported cause was `0xC`, an instruction page fault
  on a mapped kernel text PC.  Current rebuilt Linux runs pass that early
  window, so this is not the live May 21 blocker unless reproduced by a fresh
  current-RTL run.
- The `stage3_100m_first_failure_dsim_20260521a_retryloop` timeout is now
  classified as false PASS evidence: it matched the timeout pass pattern, but
  `last_commit_cycle=62,720,377` while `max_cycles=100,000,000`, leaving
  `37,279,623` stale cycles.
- `tools/run_linux_boot.py` now fails timeout runs when the final
  `[LINUX_DEBUG] last_commit_cycle` is older than the cycle cap by more than
  the default `50,000` cycles, and it treats `[LINUX_STOP_NO_COMMIT]` as a
  failure marker.  This prevents a dead core from being hidden behind a timeout
  pass pattern.
- Current live debug target is therefore no-retire at the OpenSBI timer path,
  not kernel panic.  The next proof run must keep
  `+LINUX_STOP_ON_NO_COMMIT +LINUX_NO_COMMIT_LIMIT=50000` enabled and must
  cross the old `62,720,377`-cycle freeze point with retirement still moving.

May 21 latest debug update:

- A fresh scan of May 21 Linux logs found no current `Kernel panic`,
  `Unable to handle`, `Oops`, or `BUG:` marker.  The historical
  `ffffffff805c5dec` and low-physical-fetch panic artifacts remain stale
  unless reproduced by a rebuilt current-RTL run.
- Verilator was rebuilt from the current tree and reached the OpenSBI platform
  probe in
  `linux_boot_results/stage3_verilator_current_smoke_2m_20260521b`, but then
  aborted with `Active region did not converge`.  This is not Linux progress
  evidence beyond the early OpenSBI milestone.
- `tools/run_linux_boot.py` now treats `%Error:` as a failure marker and makes
  any nonzero simulator exit override an early milestone PASS.  This prevents
  the Verilator OpenSBI probe from being misreported as a successful Linux run
  after the simulator aborts.
- A focused 63M DSim first-failure capture,
  `linux_boot_results/stage3_lmb_owner_retry_firstfail_63m_dsim_20260521c`,
  acquired the DSim lease and reached the OpenSBI domain handoff text, but was
  stopped because it produced no dense progress status before the first 5M
  checkpoint.  Treat it as aborted non-evidence.
- A follow-up 2M DSim progress probe,
  `linux_boot_results/stage3_lmb_owner_retry_progress_2m_dsim_20260521d`,
  was blocked by the DSim lease (`Already at maxLeases`).  The next DSim retry
  should be a short dense-status progress probe before another 63M capture.

## May 21 RTL Convergence Blocker

Linux long-run and panic chasing are paused while the Verilator
`Active region did not converge` failure is treated as an ASIC-quality RTL
blocker.  This is not accepted as a Verilator script issue or Linux/OpenSBI
software issue: the full-image Verilator build succeeds and then exposes
same-cycle combinational feedback in the core during the OpenSBI platform
probe window.

Ground rules for this blocker:

- Do not raise convergence limits as a fix.
- Do not add `UNOPTFLAT` suppressions, `lint_off` pragmas, or simulator-only
  workarounds in synthesizable RTL.
- Do not claim the current kernel panic/no-retire path is root-caused by this
  convergence issue unless the panic reproduces after the RTL feedback loops
  are removed.
- Do not promote or commit a structural slice until rebuilt simulation is
  acyclic for in-core RTL and the Stage 3 DS/CM 0.01% performance guard is
  clean.

Current root-cause audit:

| Area | Evidence | Current verdict | Required structural direction |
| --- | --- | --- | --- |
| Frontend packet-buffer ready/owner feedback | The latest audit experiments show in-core UNOPTFLAT around `ifu.runahead_candidate_c`, `fetch_top.ic_resp_valid`, FTQ same-cycle pop-to-head visibility, and successor/runahead owner selection. The path runs from F2 data/predecode/pred-check to successor allocation, FTQ enqueue/cancel, FTQ head/next-owner visibility, and back into IFU request selection. | Active blocker. The owner-register experiments `cut16/cut19`, `ftqheadreg`, `minimal5`, and `reghead_liveic` are quarantined because they either broke owner/stale counters, regressed DS materially, or stalled the OpenSBI payload before UART output. | Split same-cycle F2 successor production from IFU/FTQ allocation with a real registered owner/request queue, or make the FTQ-to-line-fetch boundary a proper elastic stage. Readiness and cancel side effects must come from registered state, not live packet data. |
| Rename/free-list/checkpoint readiness feedback | No current in-core UNOPTFLAT path is reported through rename, free-list, or checkpoint readiness after the ready-table cuts already in the tree. | Monitor only. | Keep rename backpressure driven from registered state. Recheck after every frontend or backend structural slice. |
| Issue queue ready-at-enqueue/select/wakeup feedback | Earlier LSU/load-wakeup feedback was reduced by registering load writeback and LSU sideband signals before they re-enter issue readiness. No current in-core UNOPTFLAT path is reported through IQ select/wakeup in the latest log. | Not the active convergence blocker. | Do not revive same-cycle issue/select/CDB/wakeup loops while debugging Linux. |
| CDB/PRF/LSU/store-forward feedback | The current latest UNOPTFLAT log no longer points at LSU, PRF, CDB, or store-forward paths. Port-0 retry and LMB-owner retry remain separate Linux no-retire candidates that already passed DS/CM guard before this convergence pivot. | Not the active convergence blocker, but still must be guarded. | Keep LSU request accept, retry, and wakeup side effects registered at module boundaries where needed. |
| Branch recovery/BPU update/frontend feedback | A registered BPU speculative-update sideband removed one candidate feedback path during experiments, but the branch/successor path still participates in the frontend loop through `successor_req_valid`, redirect target matching, and FTQ next-owner matching. | Still open through IFU ownership. The registered sideband is not promoted because the surrounding frontend slice failed validation. | Separate prediction/training side effects from current-cycle owner allocation and line delivery. |
| External cvfpu IP | Verilator also reports UNOPTFLAT warnings under `external/cvfpu-src`, for example `fpnew_opgroup_block`, `fpnew_fma`, `lzc`, and div/sqrt control. | Third-party IP debt, not the current core RTL blocker. | Track separately. Do not hide in-core feedback by globally suppressing warnings. |

Latest convergence evidence and quarantine status:

- `linux_boot_results/convergence_audit_20260521a_ftqheadreg/build_verilator_unoptflat.log`
  removes the earlier FTQ cancel-next and LSU/top-level feedback paths, but
  still leaves the IFU successor/runahead ownership loop active.
- `linux_boot_results/convergence_audit_20260521a_ftqnextreg/build_verilator_unoptflat.log`
  removes in-core UNOPTFLAT warnings, but the combined candidate is rejected:
  DS100 later shows a large cycle regression and `xs_f2_owner_no_head=203`.
- `linux_boot_results/convergence_audit_20260521a_minimal5/build_verilator_unoptflat.log`
  also removes in-core UNOPTFLAT warnings, but the narrowed candidate is
  rejected: DS100 reports nonzero `xs_f2_owner_idx_mismatch` and
  `xs_packet_stale_idx_mismatch`.
- `linux_boot_results/convergence_audit_20260521a_reghead_liveic/build_verilator_unoptflat.log`
  removes in-core UNOPTFLAT warnings while preserving IC response bypass, but
  the OpenSBI payload Verilator smoke
  `linux_boot_results/stage3_verilator_convergence_opensbi_2m_20260521a`
  stalls before UART output with an ownerless ICQ line.  This candidate is
  rejected.
- The failed frontend convergence RTL has been reverted/quarantined.  The
  current dirty working tree keeps the pre-existing Stage 3 LSU/debug changes
  and this documentation update, but no accepted frontend convergence slice is
  present.
- The active loop is:
  F2 line/data availability, instruction boundary, RVC expansion, predecode,
  predicted-control check, successor request, IFU request selection, FTQ
  enqueue/cancel, FTQ next-owner visibility, and IFU successor/runahead
  matching.
- Linux boot debug must resume only after this in-core feedback loop is
  removed and DS/CM performance guard remains within tolerance.

May 22 convergence audit update:

- Current-tree `VERILATOR_REPORT_UNOPTFLAT=1 ./build_verilator_linux.sh`
  reported in-core frontend feedback paths in
  `linux_boot_results/convergence_audit_20260522a_current/build_verilator_unoptflat.log`.
  The active paths crossed FTQ cancel/next-owner visibility, IFU runahead and
  successor matching, line-fetch owner association, and predicted-control
  redirect generation.
- Local cuts that registered or narrowed FTQ/IFU owner visibility can remove
  the in-core `UNOPTFLAT` warnings, but they are rejected because they change
  delivery behavior:
  `convergence_audit_20260522a_ftq_registered_owner_outputs` regressed DS100
  heavily and timed out CoreMark 1 and CoreMark 10, while
  `convergence_audit_20260522a_linefetch_work_owner` timed out DS300 during
  the DS/CM guard.
- The later active-only/registered-match attempt also removed in-core
  `UNOPTFLAT`, but strict Verilator OpenSBI smoke failed before UART output
  with `[FETCH_OWNER_CHECK] skipped PC owner idx=10 tag=2907`. This proves the
  patch lost owner delivery identity, so it is rejected without promotion.
- DSim was lease-blocked during the final rejected candidate, but the strict
  owner failure is already sufficient to reject it. No validated May 22 RTL
  convergence slice is available to commit.
- A follow-up May 22 audit rebuilt the flow with DSim available and tested
  narrower structural cuts:
  - `convergence_audit_20260522c_qualified_ftq_head` removed all in-core
    `UNOPTFLAT` paths by registering FTQ head visibility. It is rejected:
    `stage3_rtl_guard_convergence_qualified_ftq_20260522c` regressed
    `dhrystone_100_checkedin` from 3.133924 DMIPS/MHz to 2.683540 DMIPS/MHz
    and timed out both CoreMark rows.
  - `convergence_audit_20260522c_linefetch_owner_snapshot` kept FTQ same-cycle
    owner bypass internal to IFU and registered only the FTQ owner snapshot
    used by `ifu_line_fetch`. It also removed all in-core `UNOPTFLAT` paths,
    but `stage3_rtl_guard_convergence_linefetch_snapshot_20260522c` timed out
    DS100, DS300, CM1, and CM10, with `xs_f2_owner_idx_mismatch=1` on DS300.
  - These failures show the frontend convergence loop is not a cosmetic
    Verilator artifact. The current frontend depends on same-cycle FTQ owner
    visibility for correct packet delivery. Local register cuts can make the
    graph acyclic but break the owner contract or performance gate.
- The frontend convergence-trial RTL was reverted to avoid carrying a broken
  pipeline. The remaining dirty tree reflects pre-existing Stage 3 Linux,
  LSU/debug, and documentation work, not an accepted frontend convergence fix.
- The next acceptable fix is not another local owner-output patch. It must
  redesign the boundary as a real elastic owned-request protocol between
  predicted-control production, IFU request selection, FTQ allocation, and
  line-fetch association. The proof order is strict owner/delivery smoke,
  DS/CM 0.01% performance guard, Verilator OpenSBI smoke, then Linux panic
  debug. Do not resume Linux panic chasing before this convergence blocker is
  fixed.

May 22 fresh convergence blocker audit:

- Artifact:
  `linux_boot_results/convergence_audit_20260522d_current/build_verilator_unoptflat.log`.
- Current rebuilt Verilator report contains four in-core `UNOPTFLAT` warnings:
  `ftq.ifu_cancel_next_possible_c`, `fetch_top.f2_has_emit_payload_c`,
  `ifu.required_ftq_need_alloc_c`, and `ifu.runahead_candidate_c`.
- These four warnings are different entry points into one frontend feedback
  graph:
  FTQ cancel or next-owner visibility, ICQ owner match/stale decision, F2 data
  validity, RVC/predecode/pred-check, successor request, IFU request selection,
  FTQ allocation/cancel, and the BPU loop speculative-count lookup/update.
- The same fresh report has no in-core `UNOPTFLAT` warnings in rename,
  free-list, checkpoint, issue queue, CDB, PRF, LSU, store-forward, or dcache.
  Older root logs that mention those areas predate the current cuts and should
  not drive the May 22 fix list.

| Area | Fresh current evidence | Verdict | Structural fix direction |
| --- | --- | --- | --- |
| Frontend packet-buffer ready/owner feedback | The current loop crosses `ftq.sv`, `ifu_line_fetch.sv`, `instr_boundary.sv`, `predecode.sv`, `pred_checker.sv`, `ifu.sv`, and `tage_sc_l.sv`. The packet buffer itself now drives `enq_ready` from registered occupancy, but its owner-visible output participates in the broader same-cycle owner graph. | Active blocker. | First cut the BPU speculative-count lookup feedback, then replace the remaining FTQ/IFU owner same-cycle graph with an elastic owned request/response boundary. |
| Rename/free-list/checkpoint readiness feedback | No current in-core `UNOPTFLAT` warning in rename, free-list, RAT, or checkpoint readiness. | Monitor only. | Keep rename readiness driven from registered free-list/checkpoint state. |
| Issue queue ready-at-enqueue/select/wakeup feedback | No current in-core `UNOPTFLAT` warning in issue queue select/wakeup. | Monitor only. | Do not reintroduce same-cycle issue/select/CDB/wakeup loops while fixing Linux. |
| CDB/PRF/LSU/store-forward feedback | No current in-core `UNOPTFLAT` warning in LSU, CDB, PRF, store-forward, or dcache. | Monitor only. | Keep LSU retry, store-forward, and load-writeback side effects registered at module boundaries. |
| Branch recovery/BPU update/frontend feedback | `f2_has_emit_payload_c` feeds `pred_checker` speculative update, which feeds the BPU loop speculative-count lookup and returns as `owner_tage_pred_taken` into the same F2 predecode/pred-check chain. | Active blocker. | Remove same-cycle speculative-count update-to-lookup feedback. Speculative count updates must be registered before influencing future lookups. |
| External CVFPU IP | The same report still shows third-party `external/cvfpu-src` `UNOPTFLAT` warnings. | Separate debt. | Track separately after in-core convergence is fixed. Do not hide in-core loops with global warning suppression. |

May 22 follow-up convergence DSE:

- `convergence_loop_spec_registered` and `convergence_loop_bypass_split`
  removed all in-core Verilator `UNOPTFLAT` warnings, but both are rejected
  as promotion candidates because the Stage 3 DS/CM hard gate regressed
  materially.  The split-bypass result matched the aux-disabled performance
  signature exactly: DS300 `3.190910 DMIPS/MHz`, CM1 `6.002797 CM/MHz`, and
  CM10 `6.116081 CM/MHz`.
- Restoring raw owner completion remains acyclic in Verilator, but is rejected:
  strict owner checks report nonzero `xs_f2_owner_idx_mismatch` on all four
  DS/CM rows and CoreMark still regresses.
- Restoring live FTQ owner visibility for IFU runahead recovers the old fast
  dependency direction, but reintroduces the FTQ same-cycle pop/head loop:
  `ftq.ifu_req_pop_existing_c`, `ftq.ifu_req_pop_from_enq_c`, and
  `fetch_top.ftq_head_idx`.
- The `convergence_owner_token` trial replaced live FTQ owner visibility with
  a local `work_r.owner_delivered` runahead token.  Verilator reported no
  in-core `UNOPTFLAT` paths and strict owner checks stayed clean, but the
  Stage 3 guard still matched the aux-disabled performance signature:
  DS300 `3.190910 DMIPS/MHz`, CM1 `6.002797 CM/MHz`, and CM10
  `6.116081 CM/MHz`.  It is rejected because it does not preserve the
  performance-critical owner-timing contract.
- The `convergence_redirect_gated` trial additionally gated BPU redirects
  through the frontend stall signal.  Artifact
  `benchmark_results/stage3_rtl_guard_convergence_redirect_gated_dsim_20260522d`
  is endpoint-clean, but it fails the hard performance gate:
  DS300 regresses `0.07663%`, CM1 regresses `7.41706%`, and CM10 regresses
  `8.78881%` versus the locked Stage 3 baseline.  It is rejected and must not
  be promoted.
- Verdict: do not promote local scalar patches on loop-spec timing or live FTQ
  owner visibility.  The next structural fix should add a registered
  runahead/owner-eligibility token or elastic owned-request stage that is
  captured from live owner state after delivery, then consumed by IFU request
  selection without feeding the current-cycle FTQ pop/allocation network.
  This preserves the fast architectural intent while keeping readiness and
  owner visibility acyclic.

Root cause found:

- D-cache can assert `load_miss_retry[0]` when a port 0 load miss cannot attach
  to a fill source, for example when no L1D MSHR is free.
- LSU already had a retry holder for port 1, but port 0 treated the same
  condition as a real miss and could allocate an LMB entry even though D-cache
  had not accepted the request into an MSHR.
- That creates a lost-load state: no future fill is guaranteed to wake the ROB
  head load.  This matches the stuck OpenSBI timer load in the 100M artifact.

Implemented RTL repair:

- `src/rtl/core/lsu/lsu.sv` now has a port 0 retry holder mirroring the port 1
  miss-retry contract.
- Port 0 retry requests are re-fired through D-cache port 0 before new port 0
  loads.
- Port 0 miss detection now excludes `dcache_load_miss_retry[0]`, so the LSU
  does not allocate an LMB entry for a request the D-cache explicitly rejected.

Additional current repair candidate:

- The newer `src/rtl/core/lsu/lsu.sv` candidate also keeps a missed load live
  when an LMB completion owner cannot be reserved.  Both load ports capture a
  retry request when a miss is detected but the LMB allocation side is full.
- This addresses the deeper lost-load class where the data cache may already
  be tracking the line miss, but LSU has no completion owner to attach the ROB
  and LQ entry to the eventual fill.  Retrying lets the request merge with the
  existing MSHR or hit after the line installs, instead of leaving a ROB-head
  load permanently not ready.
- This is still a current-RTL candidate until a rebuilt DSim Linux run crosses
  the old `62,720,377`-cycle freeze point with no no-commit stop and no fresh
  UART failure marker.

Validation completed before promotion:

- Linux DSim image rebuild from current RTL: pass.
- Generic DSim image rebuild from current RTL: pass.
- Directed MSHR-pressure probe:
  `benchmark_results/stage3_lsu_p0_retry_probe24_profile_dsim_20260521a`.
  The probe passes with loop buffer and standalone decoded-op replay at zero.
  It exercises the retry condition: D-cache reports `ld0 new/alloc/merge =
  29 / 23 / 0` and `new load miss no free MSHR = 7`.
- Stage 3 DS/CM hard regression gate:
  `benchmark_results/stage3_rtl_guard_lsu_p0_retry_20260521a`.
  Result: pass within the 0.01% regression tolerance.  Guard metrics were
  DS100 `3.150055 DMIPS/MHz`, DS300 `3.218821 DMIPS/MHz`, CM1
  `6.649025 CoreMark/MHz`, and CM10 `6.851474 CoreMark/MHz`.
- Current LMB-owner retry directed probes:
  `benchmark_results/stage3_probe_mtimer_head_load_pressure_dsim_fix_20260521a`
  and
  `benchmark_results/stage3_probe_lq_full_load_completion_dsim_fix_20260521a`
  both pass.  The mtimer-head probe retires `67` loads with `66` LMB fill
  matches while creating `25` no-free-MSHR load-miss events.  The LQ-pressure
  probe retires `193` loads with `192` LMB fill matches while creating `104`
  no-free-MSHR load-miss events.  Both have `LMB WB blocked cycles = 0`.
- Current LMB-owner retry DS/CM hard gate:
  `benchmark_results/stage3_rtl_guard_lsu_lmb_owner_retry_20260521a`.
  Result: pass within the 0.01% regression tolerance.  Guard metrics were
  DS100 `3.150055 DMIPS/MHz`, DS300 `3.218821 DMIPS/MHz`, CM1
  `6.649025 CoreMark/MHz`, and CM10 `6.851474 CoreMark/MHz`.

Remaining proof before claiming the Linux milestone:

- A focused Linux image run still must cross the old 62.72M-cycle freeze point
  with retirement moving and no fresh `Oops`, `BUG:`, `Kernel panic`, low-fetch
  stop, or watchdog marker.
- A current no-trap DSim run from the rebuilt LSU port-0 retry RTL,
  `linux_boot_results/stage3_lsu_p0_retry_100m_dsim_notrap_20260521a`, was
  stopped deliberately at the user's request to pivot back to panic debug
  instead of waiting for the 100M cap.  Its `summary.json` is stale from an
  earlier lease failure, so use the newer `dsim.log` and `uart.log` timestamps
  for evidence.  The run retired cleanly through the 45M-cycle status
  checkpoint with `last_commit_cyc=44,999,994`, no trap, no `LINUX_STOP`, and no
  UART `Unable to handle`, `Oops`, `BUG:`, or `Kernel panic` marker.  It is not
  100M proof, but it is negative evidence for the old early panic signatures.
- The historical `watchdog: BUG:` artifact
  `linux_boot_results/stage3_current_100m_goal_dsim_20260519223941` remains
  stale for current RTL.  That run reached Linux time `52.017374` seconds by
  68,563,458 core cycles because `mtime` was advancing at core-cycle rate.  In
  the stopped current run, `mtime=450,000` at `mcycle=45,000,000`, matching the
  intended `mtime=mcycle/100` divider and keeping the UART log in the
  sub-second `raid6` calibration window.
- The historical `bad_range` page fault at virtual address
  `ffffffffeffff9a0` and the older `ffffffff805c5dec` trap-frame Oops are not
  current actionable RTL signatures unless a rebuilt current-RTL run
  reproduces them.  The current run passed the corresponding early boot windows
  without those UART markers.
- A 70M DSim attempt,
  `linux_boot_results/stage3_lsu_p0_retry_70m_dsim_20260521b`, was stopped
  deliberately because it remained in early OpenSBI output without a useful
  status checkpoint.  This artifact is not evidence for or against the fix.
- Verilator is useful for compile and selected directed turnaround, but the
  current full Linux Verilator image aborts near the OpenSBI platform probe with
  `Active region did not converge`.  Do not use that full-image Verilator path
  as Linux milestone evidence until the in-core RTL convergence issue is fixed.

Debug policy from this point:

- Do not debug stale panic signatures unless a rebuilt current-RTL run
  reproduces them.
- For any fresh panic/Oops/BUG, capture the complete UART text before making an
  RTL change. `src/tb/tb_linux.sv` now supports
  `+LINUX_UART_FAIL_DELAY=<cycles>` so the testbench can delay `$finish` after
  matching `Kernel panic`, `Oops`, or `BUG:`. The default remains immediate
  stop when the plusarg is omitted.
- DSim remains the primary simulator. When the DSim lease is blocked, Verilator
  is the approved backup for debug-turnaround validation. The delayed-failure
  harness was rebuilt and smoke-tested with Verilator in
  `linux_boot_results/stage3_uart_fail_delay_smoke_verilator_20260520a`.
- A current DSim rerun of the short directed panic-class smokes was attempted
  in `benchmark_results/stage3_current_panic_class_dsim_20260520a`, but the
  DSim lease was denied with `Already at maxLeases (1)`. This is a license
  availability result, not RTL evidence.
- A later primary-simulator retry with the Linux platform runner passed the
  current directed panic-class rows:
  `linux_boot_results/stage3_current_vm_mtimer_vector_dsim_20260520a` matches
  `M TIMER VECTOR OK`,
  `linux_boot_results/stage3_current_vm_mtimer_to_stimer_dsim_20260520a`
  matches `M TIMER TO STIMER OK`, and
  `linux_boot_results/stage3_current_amo_sc_irq_dsim_20260520a` matches
  `AMO_SC_IRQ_OK`.
- Current Verilator backup smokes pass:
  `linux_boot_results/stage3_current_vm_mtimer_vector_verilator_20260520a`
  matches `M TIMER VECTOR OK`,
  `linux_boot_results/stage3_current_vm_mtimer_to_stimer_verilator_20260520a`
  matches `M TIMER TO STIMER OK`, and
  `linux_boot_results/stage3_current_amo_sc_irq_verilator_20260520a` matches
  `AMO_SC_IRQ_OK`.
- The generic AUIPC fault-precision smoke is not valid under `tb_linux` because
  it uses the generic `tohost` endpoint instead of UART. Keep using the
  existing generic simulator evidence for that row until a Verilator generic
  `tb_top` runner exists.

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

Latest focused Linux evidence:

- Artifact:
  `linux_boot_results/stage3_linux_trappc_dsim_17m_20260517a`.
- Result: `TIMEOUT` at the 17M-cycle cap because the target remained
  `boot_ok`, but the run reached the `riscv_clocksource` milestone and
  passed the previous bad-stack crash window.
- UART reached `clocksource: riscv_clocksource`, `sched_clock`, delay-loop
  calibration, PID setup, and LSM initialization without `Oops` or
  `Kernel panic`.
- The focused stop for `rd=x2` above `ffffffff80e04000` did not fire. This
  replaces the earlier bad-`sp` signature as the current evidence point.

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

May 14 timer interrupt blocker:

- The current DSim Linux boot blocker is after Linux reaches the RISC-V
  clocksource path, not in the earlier OF or timebase setup. The UART reaches:
  `clocksource: riscv_clocksource` and `sched_clock`.
- The failing signature is:
  S-mode timer interrupt at a valid kernel PC
  `pc=ffffffff805c5e16 cause=8000000000000007`, followed by an M-mode illegal
  instruction trap at `pc=0000000000000000`, and OpenSBI reports
  `sbi_trap_error ... mepc=0x0000000000000000`.
- The reproduced artifact is
  `linux_boot_results/stage3_linux_interrupt_boundary_30m_dsim_20260514a`.
  This run did not rebuild the Linux DSim image, so it is baseline failure
  evidence only. Do not use it as evidence for any pending RTL fix.
- Root-cause hypothesis: the core's CSR trap update path must be tied to the
  commit block's actual interrupt acceptance, not merely to any full flush
  while an interrupt is pending. A full flush can also be caused by exceptions,
  returns, replays, fences, VM state changes, or branch recovery.
- Current candidate RTL makes interrupt acceptance explicit at commit, prevents
  normal retirement side effects on the interrupt cycle, and updates CSR trap
  state only when the commit block accepted the interrupt.
- Performance gate for that candidate passed before Linux rebuild was available:
  `benchmark_results/stage3_rtl_guard_interrupt_trap_boundary_dsim_20260514b`.
  DS100 `3.150055 DMIPS/MHz`, DS300 `3.218761 DMIPS/MHz`,
  CM1 `6.649201 CM/MHz`, CM10 `6.872881 CM/MHz`.
- Linux validation is still pending. Two DSim Linux rebuild attempts,
  `linux_boot_results/stage3_linux_timer_pc0_trace_dsim_20260514a` and
  `linux_boot_results/stage3_linux_interrupt_boundary_build_dsim_20260514b`,
  were blocked by the shared DSim cloud lease:
  `Already at maxLeases (1)`.
- Do not commit or promote the interrupt-boundary RTL until a rebuilt DSim
  Linux image either passes the previous 16.54M cycle failure window or produces
  a sharper failure signature from the rebuilt image.

May 14 trap-frame overwrite root cause update:

- Rebuilt DSim Linux evidence is now available:
  `linux_boot_results/stage3_linux_trapframe_store_lifecycle_dsim_20260514a`.
  This run includes focused testbench-only tracing for the failing trap-frame
  line and reproduces the same post-`sched_clock` Oops within the 16.7M cycle
  cap.
- The prior CDB3 bypass candidate did not fix the panic. The focused trace
  rules out the earlier CSR-to-store-data hypothesis for the first failing
  trap frame:
  - `pc=ffffffff805dac78` (`sd s1,256(sp)`) issues at cycle `16604028`.
  - STA translates `va=ffffffff80e04070` to `pa=0000000081004070`.
  - STD captures `data=0000000200000120`, `mask=ff`, and SQ accept is `1`.
  - The later return load from `pc=ffffffff805dacd8` reads
    `addr=ffffffff80e04070` and writes back `0`.
- The missing value is not caused by a simple RVC `c.addi16sp` immediate bug.
  Directed smoke `tests/asm/rvc_addi16sp_712d_smoke.S` proves compressed
  instruction `0x712d` updates `sp` by `-288`, matching Linux
  `addi sp, sp, -PT_SIZE_ON_STACK`.
- The same trace shows a more important software-visible overwrite before
  trap return:
  - `pc=ffffffff8007d03a` stores to `ffffffff80e04070`.
  - `pc=ffffffff8007d044` stores to `ffffffff80e04078`.
  - These PCs are inside Linux `update_vsyscall`, which writes
    `vdso_data_store + 112` and `vdso_data_store + 120`.
- Symbol evidence from the current kernel image:
  - `init_stack` and `init_thread_union` start at `ffffffff80e00000`.
  - `__end_init_task` and `vdso_data_store` start at `ffffffff80e04000`.
  - The trap frame is being placed at `ffffffff80e03f70`, so
    `PT_STATUS(sp)` is `ffffffff80e04070`, overlapping `vdso_data_store`.
- Current verdict: the post-`sched_clock` panic is not yet proven to be an RTL
  memory-data corruption. The latest evidence points to a Linux image or stack
  contract problem: the active idle-task kernel stack pointer used at interrupt
  entry leaves the `pt_regs` save area overlapping the adjacent
  `vdso_data_store` object. `update_vsyscall` then legitimately overwrites the
  trap-frame status and EPC-adjacent slots, causing return with corrupted
  `sstatus` or `sepc`.
- Additional May 14 evidence narrows the fault one step earlier. The failing
  trap frame is created from an already suspicious interrupted stack pointer:
  the save-context trace stores `PT_SP=ffffffff80e04090`, while
  `init_stack/init_thread_union` ends at `ffffffff80e04000` and
  `vdso_data_store` starts at that same boundary. This means the next root
  cause target is the first producer of an out-of-range architectural `sp`,
  not `strcmp` and not the later `update_vsyscall` store itself.
- The previous v1 successful Linux log reaches past the same clocksource path:
  `clocksource: riscv_clocksource`, `sched_clock`, clocksource switch,
  `Freeing unused kernel image`, and `Run /init as init process`. Therefore
  clocksource bring-up is a milestone already known to be passable by the
  methodology, and the v2 blocker should be treated as a stack/trap-return
  correctness issue until disproven.
- Current debug instrumentation is testbench-only:
  - `+LINUX_STOP_ON_BAD_KERNEL_SSCRATCH` stops if a kernel trap enters
    `handle_exception` with stale nonzero `sscratch`.
  - `+LINUX_STOP_STORE_PC=<pc>` plus
    `+LINUX_STOP_STORE_DATA_ABOVE=<limit>` stops on a suspicious store-data
    value at a selected store PC.
  - `+LINUX_STOP_COMMIT_RD=<rd>` plus
    `+LINUX_STOP_COMMIT_DATA_ABOVE=<limit>` stops on the first suspicious
    architectural register commit, used for `rd=2` to find the bad `sp`
    producer.
- Verilator is useful as a build sanity check for these hooks, but it still
  aborts on longer Linux runs with `Active region did not converge`. Do not use
  Verilator Linux execution as promotion evidence until that remaining
  in-core RTL convergence issue is fixed. The current DSim lease may remain blocked
  briefly after a killed run; retry only one focused DSim run at a time.
- Two directed Sv48 smokes are useful regression probes:
  - `tests/asm/vm_strap_frame_sv48_smoke.S` passes the simple S-mode interrupt
    trap-frame save/restore path.
  - `tests/asm/vm_dcache_eviction_sv48_smoke.S` passes a dirty-line eviction
    probe for the high-half trap-frame slot.
  - `tests/asm/vm_linux_save_context_pressure_sv48_smoke.S` immediate-forward
    mode passed, but the delayed drain variant times out because it currently
    spins after one interrupt. Keep it as diagnostic work-in-progress, not as a
    promoted compliance row.
- Completed May 17 action: the cycle-windowed DSim stop for the first bad `sp`
  producer used:
  `+LINUX_STOP_COMMIT_RD=2`,
  `+LINUX_STOP_COMMIT_DATA_ABOVE=ffffffff80e04000`,
  `+LINUX_TRACE_CYCLE_LO=16600680`, and
  `+LINUX_TRACE_CYCLE_HI=16600820`. That run found the stale-RA fused-call
  restart bug described below. The Linux stack-layout hypothesis is no longer
  the primary root cause for the May 14 Oops, though the directed stack/trap
  smokes remain useful regression probes.

May 17 fused-uop precise-trap root cause and fix:

- The bad `sp` was not produced by a valid Linux stack adjustment. The prior
  focused trace showed wrong-path execution of the `initcall_blacklisted`
  epilogue:
  - `ffffffff806005f4: ld s4,688(sp)`
  - `ffffffff806005f8: addi sp,sp,736`
  - `ffffffff806005fc: ret`
- The wrong-path entry came from `start_kernel` after returning from an
  interrupt into the second half of a fused `AUIPC+JALR` call at
  `ffffffff80600c98`. Before the fix, the fused uop stored only the branch
  execution PC in the ROB. An interrupt before the fused uop retired therefore
  wrote `sepc=ffffffff80600c98`, skipping the unretired `AUIPC` at
  `ffffffff80600c94`. On `sret`, `ra` still held the older
  `ffffffff80600c6e` value, so the JALR target became the wrong
  `ffffffff806005f4`.
- RTL fix: keep the existing fused branch execution PC in `pc` for BRU,
  branch recovery, and BPU update, and add a separate `trap_pc` sideband that
  carries the first architectural PC of the fused uop through decode, rename,
  and ROB. Commit/CSR trap generation now uses `rob_head_trap_pc`; branch
  execution still uses `rob_head_pc` and IQ `pc`.
- Validation:
  - DSim rebuilt from the patched tree.
  - Focused run `stage3_linux_trappc_dsim_17m_20260517a` passes the previous
    cycle window. At cycle `16600782`, fused `AUIPC+JALR` at
    `ffffffff80600c98` computes target `ffffffff8061461a`, not the old wrong
    `ffffffff806005f4`.
  - `sepc` at the preceding `sret` is `ffffffff80600c94`, proving the restart
    now points at the first unretired architectural instruction.
  - No `LINUX_STOP_COMMIT_DATA_ABOVE` event appears before the 17M timeout.
- Required DS/CM hard gate passed after the RTL change:
  `benchmark_results/stage3_rtl_guard_20260517_trappc_precise_fused_interrupt`.
  Results are unchanged from the current Stage 3 baseline:
  DS100 `18,068` cycles, `3.150055 DMIPS/MHz`;
  DS300 `53,047` cycles, `3.218761 DMIPS/MHz`;
  CM1 `150,394` cycles, `6.649201 CM/MHz`;
  CM10 `1,454,994` cycles, `6.872881 CM/MHz`.

May 19 scheduler BUG current blocker:

- Do not extend the Linux run window while this blocker is present. The current
  first actionable Linux-visible failure is not a timeout and not the older
  `bad_range`, low OpenSBI fetch, or `ffffffff805c5dec` page-fault signature.
- Latest full-context artifact:
  `linux_boot_results/stage3_bug_full_context_dsim_18p2m_20260519a`.
- The run reaches `clocksource: riscv_clocksource`, `sched_clock`,
  delay-loop calibration, PID setup, LSM initialization, mount-cache setup, and
  mountpoint-cache setup. It then reports:
  `BUG: scheduling while atomic: swapper/0/0x00000002`.
- Static symbolization points at the mutex slow path:
  `__mutex_lock.constprop.0 -> _raw_spin_unlock ->
  schedule_preempt_disabled -> schedule -> __schedule`. The relevant
  preempt-count word is `8(tp)`, which currently translates to physical
  address `000000008109f708`.
- Focused traces already narrowed the failure:
  `linux_boot_results/stage3_sched_bug_commit_trace_dsim_20260519a` and
  `linux_boot_results/stage3_sched_bug_preempt_lsu_trace_dsim_20260519a`.
  These traces show the short scheduler handoff sequence is internally
  coherent. `_raw_spin_unlock` stores `2` to `8(tp)`,
  `schedule_preempt_disabled` loads `2` and stores `1`, `schedule` loads `1`
  and stores `2`, and `__schedule` correctly observes `2` before branching to
  `__schedule_bug`.
- Therefore the active question is no longer whether `schedule` missed the
  immediately preceding store. The bad count exists before
  `schedule_preempt_disabled`. The next debug target is the earlier
  `__mutex_lock`/raw-spinlock preempt-count transition:
  `__mutex_lock` at `ffffffff805d705c`, `_raw_spin_lock` at
  `ffffffff805da740`, and `_raw_spin_unlock` at `ffffffff805da85c`.
- Testbench-only hooks used for this debug slice:
  `+LINUX_STOP_COMMIT_PC=<pc>`, `+LINUX_TRACE_LOAD_RANGE`,
  `+LINUX_TRACE_PA_LINE=<pa>`, and
  `+LINUX_STOP_STORE_PC=<pc>` plus
  `+LINUX_STOP_STORE_DATA_ABOVE=<limit>`. A narrower exact-address hook,
  `+LINUX_TRACE_PREEMPT_PA=<pa>`, records STA, STD, SQ-drain, and D-cache
  store events for one physical word without flooding the whole cache line.
  These hooks do not modify synthesizable core RTL and do not affect the
  ASIC-style boundary.
- Focused DSim reproducer used for the completed handoff evidence:

```bash
python3 tools/run_linux_boot.py --run --simulator dsim \
  --build-mode linux \
  --image build/linux_boot/fw_payload.hex \
  --run-dir linux_boot_results/stage3_sched_bug_commit_trace_dsim_<date> \
  --max-cycles 18100000 \
  --target-milestone boot_ok \
  --no-status \
  --no-trace-trap \
  --sim-plusarg LINUX_KEEP_RUNNING_AFTER_UART_FAILURE \
  --sim-plusarg LINUX_TRACE_COMMIT_LO=ffffffff805d3eb0 \
  --sim-plusarg LINUX_TRACE_COMMIT_HI=ffffffff805d5564 \
  --sim-plusarg LINUX_TRACE_CYCLE_LO=17930000 \
  --sim-plusarg LINUX_TRACE_CYCLE_HI=18020000 \
  --sim-plusarg LINUX_TRACE_REGS \
  --sim-plusarg LINUX_STOP_COMMIT_PC=ffffffff805d522e
```

- Next focused yes/no command once the DSim lease is available:

```bash
python3 tools/run_linux_boot.py --run --simulator dsim \
  --build-mode linux \
  --image build/linux_boot/fw_payload.hex \
  --run-dir linux_boot_results/stage3_sched_bug_mutex_preempt_entry_stop_dsim_<date> \
  --max-cycles 18100000 \
  --target-milestone boot_ok \
  --no-status \
  --no-trace-trap \
  --sim-plusarg LINUX_KEEP_RUNNING_AFTER_UART_FAILURE \
  --sim-plusarg LINUX_STOP_STORE_PC=ffffffff805d705c \
  --sim-plusarg LINUX_STOP_STORE_DATA_ABOVE=0000000000000001
```

- Interpretation:
  - If it stops at `ffffffff805d705c`, `__mutex_lock` entered with
    `preempt_count >= 1`; the extra disable predates this mutex slow path.
  - If it does not stop before the BUG, rerun with
    `LINUX_STOP_STORE_PC=ffffffff805da740` and limit `2` to check whether
    `_raw_spin_lock` is creating the extra increment.
  - If those stores are clean, prioritize wrong-path store survival or
    duplicate store issue around the preempt-count physical line.
- Attempted command
  `linux_boot_results/stage3_sched_bug_mutex_preempt_entry_stop_dsim_20260519a`
  did not run because DSim reported `License not obtained: Already at
  maxLeases (1)` while no local simulator process was active. This is a lease
  availability issue, not design evidence.
- Attempted command
  `linux_boot_results/stage3_sched_bug_mutex_preempt_entry_stop_dsim_20260519b`
  reached Linux startup but was stopped manually because it was still a long
  stop-at-late-PC probe. Replace it with the exact-address trace below for the
  next run.
- Exact-address trace hook compile status:
  `linux_boot_results/stage3_preempt_pa_trace_build_verilator_20260519a`
  rebuilt the Linux Verilator platform successfully. DSim rebuild attempts
  `stage3_preempt_pa_trace_build_dsim_20260519a` and `20260519b` were blocked
  by the stale `maxLeases (1)` lease condition, so DSim evidence is still
  pending.
- Next preferred focused command:

```bash
python3 tools/run_linux_boot.py --run --simulator dsim \
  --build-mode linux \
  --image build/linux_boot/fw_payload.hex \
  --run-dir linux_boot_results/stage3_sched_bug_preempt_pa_trace_dsim_<date> \
  --max-cycles 18100000 \
  --target-milestone boot_ok \
  --no-status \
  --no-trace-trap \
  --sim-plusarg LINUX_KEEP_RUNNING_AFTER_UART_FAILURE \
  --sim-plusarg LINUX_TRACE_PREEMPT_PA=000000008109f708 \
  --sim-plusarg LINUX_STOP_COMMIT_PC=ffffffff805d522e
```

- Expected evidence:
  - `LINUX_PREEMPT_STD` shows every preempt-count store-data issue with PC,
    ROB, SQ, data, and flush state.
  - `LINUX_PREEMPT_SQ_DRAIN` shows which entries become committed memory
    side effects.
  - `LINUX_PREEMPT_DC_STORE` shows the final D-cache store request and ack.
    If an extra `+1` store appears on a wrong-path or duplicate issue but also
    drains, debug SQ/commit recovery. If only architecturally expected stores
    drain, debug the mutex owner/lock-state path that led to sleeping in the
    mutex slow path.
- Verilator remains blocked for this Linux window. It builds the platform but
  aborts after `sched_clock` with `Active region did not converge`. The
  generated `UNOPTFLAT` evidence identifies real ready/update loops involving
  `uoc_active`, `bru_issue`, `bru_mispredict`, issue wakeup, BPU update, and
  frontend packet readiness. Do not use Verilator Linux results as evidence
  until that loop is structurally cut or otherwise proven harmless.

Do not run a clean long Linux milestone while the scheduler BUG is active.
The next Linux run should be one of the focused stop-store debug commands
above. After an RTL fix, first run the Stage 3 DS/CM regression guard, then
rerun the focused Linux reproducer, and only then resume a clean milestone
run. The historical clean milestone command remains:

```bash
python3 tools/run_linux_boot.py --run --simulator dsim \
  --build-mode linux \
  --run-dir linux_boot_results/stage3_linux_post_trappc_clean_50m_dsim_<date> \
  --max-cycles 50000000 \
  --target-milestone uart_driver \
  --status-interval 5000000 \
  --no-trace-trap
```

Do not carry the focused `LINUX_STOP_COMMIT_*` or cycle-window trace plusargs
into the next clean milestone run. If the clean run exposes a new RTL issue,
fix it with the same rule: rebuild, rerun the focused Linux reproducer, then
rerun the Stage 3 DS/CM hard gate before promotion.

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
- Current caveat: Verilator builds the Linux platform, but Linux execution still
  aborts around 50K cycles with `Active region did not converge`
  (`linux_boot_results/stage3_linux_trappc_verilator_conv50k_100k_20260517a`).
  Treat Verilator as compile-only for this slice until that in-core RTL
  convergence issue is fixed.
- XSim is demoted to a last-resort cross-check because it is too slow for this
  workload.
- The Linux boot runner default is now `--simulator auto`, which tries DSim
  first and falls back to Verilator on a DSim lease block. Use explicit
  `--simulator dsim` only when DSim evidence is required for promotion.
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
  `run_verilator_linux.sh`, and `tools/run_linux_boot.py --simulator auto`.
  `auto` attempts DSim first and switches to Verilator only for a DSim lease
  block. Direct `--simulator verilator` is allowed for known DSim outages.
  DSim remains the preferred evidence source for promoted RTL, and any
  Verilator-debugged RTL slice still needs the locked DS/CM guard before
  commit.
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
this workload. For Linux boot, prefer `tools/run_linux_boot.py --simulator auto`
so DSim remains first choice and Verilator replaces XSim as the backup. The
runner must archive per-test logs, the ELF/hex provenance, and a summary table
with pass, fail, timeout, and first failing PC or trap when available.

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
v2 milestone. The latest instrumented v2 evidence reached Linux `time_init()`
and the RISC-V timer probe with coherent 128M DRAM, so the old
pre-clocksource memory-clear uncertainty and the 64M page-allocation blocker
are resolved. The clean-image proof is not closed yet: after debug-log cleanup,
the next short run must first reconfirm `/cpus/timebase-frequency` before
resuming the post-irq-domain RISC-V timer path after `timer_common domain=...`.

Evidence summary:

- Older `#18` image runs such as
  `linux_boot_results/stage3_linux_oops_regs_dsim_20260513` did hit a real
  `Oops [#1]` in the printk path. That evidence drove the frontend owner-line
  and runahead-successor fixes, but it is not the latest signature.
- Later runs with the ICQ future-line fix no longer reproduce that Oops. They
  advanced into Linux memory setup and device-tree parsing.
- The current generated DTB contains `/cpus`,
  `/cpus/timebase-frequency = <1000000>`, `/cpus/cpu@0`, CLINT at
  `0x02000000`, and UART at `0x10000000`. The instrumented Linux OF-base probe
  confirmed the unflattened OF tree contains `/cpus`, `/cpus/cpu@0`, and
  `timebase=1000000`; this still needs a clean-image reconfirmation.
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

1. Keep DSim as the primary evidence source. Verilator replaces XSim as the
   approved short-turnaround fallback when the DSim lease is unavailable.
   XSim is only a last-resort cross-check.
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

### Clean Log And Guard Status, May 13

Before continuing Linux long runs, the Stage 3 hard performance gate was rerun
on the current RTL:

- Run: `benchmark_results/stage3_rtl_guard_clean_uart_gate_20260513`.
- Result: PASS within the 0.01% metric regression tolerance.
- DS100: 18,068 cycles, 3.150055 DMIPS/MHz.
- DS300: 53,047 cycles, 3.218761 DMIPS/MHz.
- CM1: 150,394 cycles, 6.649201 CM/MHz.
- CM10: 1,454,994 cycles, 6.872881 CM/MHz.

The Linux and OpenSBI software trees were then cleaned of temporary UART/debug
instrumentation:

- Removed Linux OF path-walk, root-child, `time_init()`, and
  `riscv_timer_init_dt()` debug prints.
- Removed temporary OpenSBI `[rv64gc]` FDT/IPI/timer/coldboot/ecall trace
  prints.
- Rebuilt `build/linux_boot/fw_payload.hex` after the cleanup.

The first clean-image DSim attempt
`linux_boot_results/stage3_linux_128m_clean_uart_dsim_50m_20260513a` was
stopped early because it reproduced the stale clean-image
`timebase-frequency` panic while the previously instrumented OF-base probe had
already proven that the generated DTB and unflattened OF tree can contain
`/cpus`, `/cpus/cpu@0`, and `timebase-frequency = 1000000`. After removing the
remaining stale software debug prints and rebuilding, the short clean rebuild
check
`linux_boot_results/stage3_linux_clean_rebuild_timebase_check_dsim_20m_20260513a`
was intentionally stopped at the user's request before the long proof point.
Its UART log was clean through OpenSBI platform reporting, with no `[rv64gc]`
debug stream.

Current execution rule:

- Do not start a 50M run until the next session.
- Next run should first be a targeted clean checkpoint through Linux
  `time_init()` and `riscv_timer_init_dt()`, using the rebuilt clean payload.
- If the clean payload still panics on `timebase-frequency`, treat that as an
  RTL exposed OF path execution problem and debug it directly; do not mask it by
  hard-coding the timebase in Linux.
- If the clean payload passes `time_init()`, resume the clocksource path from
  `timer_common domain=...` and keep the DS/CM guard as the hard RTL promotion
  gate.

### Current OF Timebase Root Cause, May 14

The clean-image `timebase-frequency` panic is no longer classified as a DTS or
Linux-software problem. The generated DTB is correct, and the failing path is a
core execution bug exposed by Linux OF lookup:

- The clean Linux payload panicked with
  `Kernel panic - not syncing: RISC-V system with no 'timebase-frequency' in DTS`.
- DSim trace showed `of_find_node_opts_by_path("/cpus")` returning null even
  though the DTB contains `/cpus` and `timebase-frequency = <1000000>`.
- The decisive trace is in
  `linux_boot_results/stage3_linux_of_lookup_trace_dsim_165m_20260514a`.
  In `__of_find_node_by_path`, `strcspn("/cpus", "/")` returns `4`, then the
  compiler emits `addiw s3,a0,0` followed by `beqz s3,...`. The trace commits
  the branch PC but not a separate producer PC because the pair was macro-fused.
  Later `mv a2,s3` still observes stale `s3=0`, so `strncmp()` compares length
  zero and the OF path walk fails to match `/cpus`.
- Root cause: fused compare-and-branch uops such as `SEXT.W + BEQ/BNE`,
  `SLT/SLTU + BEQ/BNE`, and `SLTI/SLTIU + BEQ/BNE` retired as two
  instructions but dropped the producer's architectural destination writeback.
  That is illegal when later code reads the producer register.

Fix candidate:

- `fusion_detector.sv` now keeps the producer destination valid for fused
  compare branches while still inheriting branch metadata from the branch slot.
- `bru.sv` now returns the producer result on fused compare branches:
  `SLT/SLTU/SLTI/SLTIU` produce `0/1`, and `SEXT.W` produces the sign-extended
  word result. JAL/JALR fusion continues to return the link address.
- This is a general macro-fusion correctness repair, not a Linux or benchmark
  special case.

Validation status:

- Directed probe:
  `tests/asm/probe_linux_beq_after_call.S` now includes the Linux-shaped
  `call; addiw s3,a0,0; beqz s3; mv a2,s3` case.
- XSim rebuilt from the current RTL and passed the directed probe:
  `benchmark_results/stage3_linux_debug_beq_after_call_xsim_fusionfix_20260514a`
  reports `PASS`.
- DSim Stage 3 DS/CM guard passed after the BRU result repair and after the
  `fused_imm` port-width cleanup:
  `benchmark_results/stage3_rtl_guard_fusion_bru_result_immfix_dsim_20260514a`.
  Locked guard metrics were preserved within the 0.01% regression tolerance:
  DS100 `3.150055 DMIPS/MHz`, DS300 `3.218761 DMIPS/MHz`,
  CoreMark iter1 `6.649201 CM/MHz`, and CoreMark iter10 `6.872881 CM/MHz`.
- The Linux DSim image rebuild passed after the final RTL cleanup:
  `linux_boot_results/stage3_linux_fusionfix_build_dsim_20260514a`.
- A bounded 200M DSim Linux run was started from the rebuilt image but stopped
  intentionally before kernel progress because the long Linux checkpoint was
  deferred. Its UART only contains the Stage 3 smoke banner, so
  `linux_boot_results/stage3_linux_fusionfix_200m_dsim_20260514a` is not Linux
  boot evidence.

### Current Trap Frame Store Data Candidate, May 14

The next real Linux failure is past the earlier OF timebase issue. The valid
DSim run
`linux_boot_results/stage3_linux_irq_target_fix_18m_dsim_20260514a` reaches:

- `clocksource: riscv_clocksource`
- `sched_clock`

It then panics while printing the later Oops path:

- `Unable to handle kernel paging request at virtual address ffffffff805c5dec`
- `Kernel panic - not syncing: Attempted to kill the idle task!`

The trace evidence narrows this to Linux trap-frame corruption, not a missing
kernel mapping:

- The faulting return path executes `ld a0,256(sp); csrw sstatus,a0; sret`.
- At the failing return, `a0` is zero after `ld a0,256(sp)`, so `sret` returns
  with the wrong previous privilege state.
- The corresponding trap entry previously executed
  `csrrc s1,sstatus,t0; sd s1,256(sp)`.
- The saved architectural `s1` value at trap entry was correct
  (`0x0000000200000120`), but the later stack load observes zero.

Root-cause candidate:

- `issue_queue.sv` wakes consumers from all four CDB lanes.
- The integer operand bypass network only had CDB0, CDB1, CDB2, Load0, and
  Load1 as sources.
- CDB3 carries ALU3, DIV, CSR, and FPU results. A consumer awakened by a CSR
  result on CDB3 could issue before the integer PRF read saw the write, with no
  matching CDB3 bypass source.
- The Linux-shaped sequence `csrrc s1,sstatus,t0; sd s1,256(sp)` matches this
  failure mode exactly: the store-data uop can be awakened by the CSR result
  but read stale store data.

RTL candidate in the working tree:

- `NUM_BYPASS_SRCS` is widened from 5 to 6.
- `rv64gc_core_top.sv` now wires registered CDB3 into bypass slot 3 and moves
  Load0/Load1 to bypass slots 4/5.
- `bypass_network.sv` comments now describe the CDB0..3 plus Load0/Load1
  contract.
- This is a general wakeup and operand-delivery contract repair, not a Linux or
  benchmark special case.

Validation status:

- `./build_dsim_linux.sh` rebuilt the Stage 3 DSim Linux image successfully
  from the current RTL candidate.
- A rebuilt DSim Linux run with the CDB3 bypass candidate reached the same
  post-clocksource failure:
  `linux_boot_results/stage3_linux_cdb3_bypass_200m_dsim_20260514a`.
  The UART reaches `clocksource: riscv_clocksource` and `sched_clock`, then
  reports `Unable to handle kernel paging request at virtual address
  ffffffff805c5dec`, `Oops [#1]`, and
  `Kernel panic - not syncing: Attempted to kill the idle task!`.
- The run was stopped after reproducing the panic. It is valid failure
  evidence from the rebuilt RTL image, but it is not a Linux progress
  milestone and does not validate the CDB3 bypass candidate.
- The Verilator Linux fallback was rebuilt successfully from the current RTL,
  but the platform run aborts at time zero with
  `Active region did not converge`:
  `linux_boot_results/stage3_linux_cdb3_bypass_20m_verilator_20260514a`.
  This is not Linux boot evidence.
- Do not commit or promote the current RTL candidate until a narrower trace
  proves the remaining trap-frame corruption root cause, the Linux panic is
  removed, and the Stage 3 DS/CM hard guard passes within the 0.01% metric
  regression gate.

Next debug command:

```bash
python3 tools/run_linux_boot.py \
  --run \
  --simulator auto \
  --build-mode linux \
  --run-dir linux_boot_results/stage3_linux_trapframe_trace_auto_<timestamp> \
  --max-cycles 18000000 \
  --target-milestone uart_driver \
  --no-status \
  --sim-plusarg LINUX_TRACE_REGS \
  --sim-plusarg LINUX_TRACE_PIPE \
  --sim-plusarg LINUX_TRACE_LINE=ffffffff80e04070 \
  --sim-plusarg LINUX_TRACE_LOAD_PC=ffffffff805dacd8 \
  --sim-plusarg LINUX_TRACE_COMMIT_LO=ffffffff805dac40 \
  --sim-plusarg LINUX_TRACE_COMMIT_HI=ffffffff805dad40 \
  --sim-plusarg LINUX_TRACE_CYCLE_LO=16603000 \
  --sim-plusarg LINUX_TRACE_CYCLE_HI=16609000
```

The trace must distinguish:

- whether `sd s1,256(sp)` issues with the expected `s1` data,
- whether the store queue captures and drains that data to
  `sp + 256 == ffffffff80e04070`,
- whether `ld a0,256(sp)` forwards from the store queue or reloads from the
  D-cache,
- and whether the corruption is in operand delivery, store queue state, memory
  writeback, or load/forwarding.

### May 18 Timer Vector Panic Debug

The latest clean 100M DSim attempt exposed a sharper timer-vector panic before
the run cap:

- Artifact:
  `linux_boot_results/stage3_linux_clean_100m_dsim_20260518a`.
- UART reaches OpenSBI, Linux early console, memory setup,
  `clocksource: riscv_clocksource`, `sched_clock`, delay-loop calibration,
  PID setup, LSM setup, and mount-cache setup.
- Failure:
  `Unable to handle kernel paging request at virtual address 0000000080003f7c`,
  `badaddr=0000000080003f7c`, `cause=12`, and `epc=0`.
- `0x80003f7c` symbolizes inside OpenSBI's M-mode timer trap vector path
  (`sbi_trap_handler`, machine timer vector slot). It is not a Linux kernel
  virtual address.

Root-cause findings from the RTL audit:

- Fetch exceptions injected through `fetch_exception_pending_r` set `pc` and
  `exc_tval` but left `trap_pc` zero. That explains the Linux Oops reporting
  `epc=0` for an instruction page fault.
- The frontend used live `csr_priv_mode` as the instruction translation
  context. Trap and return redirects need the privilege of the redirected
  fetch target, not a potentially cycle-mismatched live CSR value.
- `ifu_line_fetch` could still issue an I-cache request during a redirect
  flush. Redirect cycles must not launch stale requests under the old
  fetch context.

Current RTL candidate:

- `csr_file.sv` exposes `mstatus_spp` so SRET target privilege can be derived
  outside the CSR block without adding simulation-only logic.
- `rv64gc_core_top.sv` tracks `frontend_fetch_priv_r` and updates it on
  trap, MRET, SRET, and normal redirects. The ITLB privilege input and
  `instr_vm_active` now use this frontend fetch privilege.
- The synthetic fetch-exception uop now sets `trap_pc=fetch_exception_pc_r`.
- `ifu_line_fetch.sv` gates I-cache request launch with `!flush_i`.

Directed validation:

- New directed smoke:
  `tests/asm/vm_mtimer_vector_sv48_smoke.S`.
- The test enables Sv48, enters S-mode, triggers an M-mode timer interrupt,
  validates `mcause` and interrupted `mepc` in the M-mode vectored handler,
  then returns with `mret` into translated S-mode code that prints through a
  translated UART mapping.

### May 19 Timer-Vector Panic Debug Pivot

The May 18 candidate fixed the earlier `epc=0` symptom, but the rebuilt Linux
slice still panicked before the 100M goal:

- Artifact: `linux_boot_results/stage3_linux_clean_100m_dsim_20260519a`.
- Failure signature: instruction page fault with
  `epc=0000000080003f7c`, `badaddr=0000000080003f7c`, and
  `ra=ffffffff8013dabe`.
- `0x80003f7c` is the OpenSBI M-mode timer path return slot after
  `jal sbi_timer_process`; it is not a Linux high-half virtual address.
- The log reaches Linux clocksource, sched clock, PID setup, LSM setup, and
  mount-cache setup before this panic.

The active root-cause hypothesis is no longer “run longer”.  The panic is a
frontend correctness problem around privileged prediction and fetch-fault
ordering:

- The RAS is shared across M-mode trap code and resumed S-mode Linux code.
  If an M-mode return slot survives across `mret`, an S-mode return can be
  predicted toward OpenSBI physical text while Sv48 translation is active.
- `fetch_exception_pending_r` previously had priority over the decode-facing
  IBuffer output.  That allowed an ifetch page fault to enter rename before
  older fetched packets and before the older branch/return that should recover
  from the bad prediction.

Current unpromoted RTL candidate:

- Clear the RAS on trap entry, `mret`, `sret`, `satp` commit, and
  `sfence.vma` redirect.  This is a context-isolation rule, not a Linux
  benchmark special case.
- Split frontend quiesce into decode-side `frontend_hold` and fetch-side
  `frontend_fetch_halt`.  A pending fetch exception now stops new fetch work
  but lets the IBuffer drain.
- Inject the synthetic fetch exception only when UOP-cache playback is idle
  and the normal decoded frontend path has no older packet to present.

New directed smoke:

- `tests/asm/vm_mtimer_ras_context_sv48_smoke.S` intentionally leaves an
  M-mode return slot in the RAS before `mret`, then executes an S-mode `ret`
  under Sv48.  The S-mode return must not fetch or fault on the M-mode
  physical address.
- Verilator Linux-platform run of this directed smoke passes:
  `M TIMER RAS CONTEXT OK`, matched at cycle 573, with zero SVA violations.
- Rebuilt DSim Linux-platform validation passes the same smoke:
  `linux_boot_results/stage3_vm_mtimer_ras_context_dsim_20260519a`,
  matched at cycle 573, with zero SVA violations and zero exception flushes.
- Rebuilt DSim Linux-platform validation also re-passes the earlier
  `vm_mtimer_vector_sv48_smoke`:
  `linux_boot_results/stage3_vm_mtimer_vector_current_dsim_20260519a`,
  matched at cycle 343, with zero SVA violations and zero exception flushes.
- A trace-heavy rebuilt Linux slice
  `linux_boot_results/stage3_linux_fetch_exception_order_dsim_22m_20260519a`
  was stopped after reaching the OpenSBI banner and the 1M-cycle status point
  because it was too slow for first-pass yes/no validation.  The follow-up
  clean Linux rerun was temporarily blocked by the DSim lease not releasing
  immediately after the interrupted trace run.

Next validation sequence when DSim is available:

1. Rerun Linux without trace past the prior timer-vector panic window using
   the already rebuilt `dsim_linux_work/tb_linux_image.so`.
2. If the clean Linux run fails, rerun with a narrow fault-only trace around
   the new failure signature.
3. If Linux passes the panic window, run the Stage 3 DS/CM RTL guard before
   promotion or commit.
- DSim result:
  `linux_boot_results/stage3_vm_mtimer_vector_dsim_20260518d` passes at
  cycle `343`; the commit summary reports one interrupt and zero exceptions.
- Verilator result:
  `linux_boot_results/stage3_vm_mtimer_vector_verilator_20260518c` also
  passes at cycle `343`. This is useful backup evidence only.
- Fetch-exception EPC cross-check:
  `benchmark_results/stage3_vm_fault_contract_xsim_20260518a` passes
  `vm_ifetch_fault_sv48_smoke` and `vm_canonical_sv48_smoke` on a rebuilt
  XSim snapshot from the current RTL. These rows confirm instruction page
  faults report the faulting virtual PC instead of a zero EPC in the existing
  `tohost` VM-fault smoke harness.
- DSim fault-contract retry after the lease released:
  `benchmark_results/stage3_vm_ifetch_fault_dsim_retry_20260518a` passes
  `vm_ifetch_fault_sv48_smoke`, and
  `benchmark_results/stage3_vm_canonical_dsim_retry_20260518a` passes
  `vm_canonical_sv48_smoke`.
- Stage 3 DS/CM hard guard:
  `benchmark_results/stage3_rtl_guard_timer_fetch_priv_epc_fix_20260518a`
  passes all four locked rows with the 0.01% metric regression gate:
  DS100 `18,068` cycles, `3.150055 DMIPS/MHz`;
  DS300 `53,046` cycles, `3.218821 DMIPS/MHz`;
  CM1 `150,398` cycles, `6.649025 CM/MHz`;
  CM10 `1,459,540` cycles, `6.851474 CM/MHz`.

Linux rerun status:

- A focused DSim Linux rerun was started at
  `linux_boot_results/stage3_linux_timer_fix_clean_dsim_20m_20260518a` and
  reached the OpenSBI UART banner. It was intentionally stopped because at the
  observed DSim speed it would have been a long wait to the previous Linux
  panic window. Do not count this interrupted run as Linux pass evidence.
- The first DSim VM-smoke retries were blocked by the shared cloud lease after
  stopping the Linux run (`Already at maxLeases (1)`), but the later single-row
  DSim retries passed. Use one focused DSim Linux rerun when the lease is free;
  use Verilator only for UART milestone smokes until its full-Linux convergence
  issue is fixed.

Validation still required before promotion:

- Rebuilt DSim Linux must rerun past the previous panic window and show no
  `badaddr=0000000080003f7c`, no `epc=0` fetch-exception report, and no
  kernel panic before the next milestone.
- A Verilator full Linux run is not valid evidence yet because the current
  Linux platform image still aborts in Verilator with
  `Active region did not converge`.

## 2026-05-19 `bad_range` Panic Debug

The latest Linux failure is now a concrete kernel Oops, not a reason to extend
the timeout:

- Failing run:
  `linux_boot_results/stage3_linux_fetch_context_mask_low_ifetch_clean_dsim_20m_20260519a`.
- Kernel signature:
  `Unable to handle kernel paging request at virtual address ffffffffeffff9a0`.
- Trap site:
  `epc : ffffffff8013e3e4`, `bad_range+0xc/0xdc`,
  `cause: 13` load page fault.
- Kernel disassembly from the matching `vmlinux`:
  `bad_range+0x8` is `auipc a5,0xd60`, and `bad_range+0xc` is
  `ld a5,-1632(a5)`, whose correct PC-relative effective address is
  `ffffffff80e9dd80`.
- The observed bad address `ffffffffeffff9a0` matches stale
  `a5=fffffffff0000000` plus the load immediate. That leaves two root-cause
  classes:
  direct execution of the `bad_range+0xc` load with stale `a5`, or a stale
  data-side fault sideband that is attributed to the `bad_range+0xc` ROB entry.

Current evidence:

- The directed high-half Sv48 reproducer
  `tests/hex/vm_auipc_ld_high_sv48_smoke.hex` passes on rebuilt XSim after the
  current RTL changes. This test executes the same `bad_range` AUIPC/LD shape
  with `a5` deliberately poisoned to `fffffffff0000000`, so the simple
  AUIPC+LD dependency and Sv48 PC-relative AGU path are not sufficient to
  reproduce the Linux panic.
- `tests/hex/vm_data_sv48_smoke.hex` also passes on rebuilt XSim after the
  current RTL changes.
- The UART VM timer smokes
  `stage3_vm_mtimer_vector_xsim_ptw_owner_20260519a` and
  `stage3_vm_mtimer_ras_context_xsim_ptw_owner_20260519a` both pass on rebuilt
  XSim.

RTL/debug changes in the current candidate:

- `rob.sv` now gates sideband exception writes with target ROB validity,
  same-cycle allocation conflict detection, and same-cycle flush/range
  filtering before updating `ready`, exception code, and `tval`.
- `rv64gc_core_top.sv` now tracks the accepted data-PTW owner ROB index and
  only forwards a PTW data fault to the ROB when that owner is still live and
  has not been killed by a full flush, partial flush, `satp`, or `sfence.vma`.
  This is a general long-latency fault ownership guard, not a Linux-specific
  PC or address special case.
- `tb_linux.sv` has lightweight stop probes for the exact sideband `tval` and
  the exact `bad_range+0xc` load PC. These are testbench-only diagnostics and
  must not migrate into synthesizable core RTL.

Validation status:

- Rebuilt XSim compile and the four directed Stage 3 VM smokes listed above
  pass.
- Rebuilt DSim Linux first-fault capture:
  `linux_boot_results/stage3_linux_first_fault_capture_dsim_20260519b`.
  This run reached the explicit 18M-cycle cap, not a kernel failure. UART
  reached `clocksource: riscv_clocksource`, `sched_clock`, PID setup, LSM,
  `Mount-cache`, and `Mountpoint-cache`. It reported no `Oops`, no
  `Kernel panic`, no `Unable to handle`, no
  `[LINUX_STOP_LOW_IFETCH_FAULT]`, and no
  `[LINUX_STOP_SIDEBAND_TVAL]`.
- The 18M run passed both saved panic windows for the current candidate:
  no S-mode fetch fault on the OpenSBI physical `0x80003f7c` timer-vector
  path, and no data-side PTW sideband stop for
  `tval=ffffffffeffff9a0`.
- At the 18M cap the core was still making forward progress with
  `mcycle=18000000`, `minstret=15393499`, `IPC=0.855194`, `priv=1`,
  `satp=90000000000811be`, `last_pc=ffffffff80340008`, and no trap. The
  status also showed `mtip=1` with an expired `timecmp`, so the next Linux
  debug focus is timer-interrupt progress after clocksource bring-up.
- Stage 3 DS/CM hard guard:
  `benchmark_results/stage3_rtl_guard_stage3_linux_first_fault_candidate_20260519b`
  passes all four locked rows with the 0.01% metric regression gate:
  DS100 `18,068` timed cycles, `3.150055 DMIPS/MHz`;
  DS300 `53,046` timed cycles, `3.218821 DMIPS/MHz`;
  CM1 `150,398` timed cycles, `6.649025 CM/MHz`;
  CM10 `1,459,540` timed cycles, `6.851474 CM/MHz`.
- Therefore this candidate has passed the performance guard, but is not Linux
  promoted yet. The focused 18M run is kernel panic debug evidence, not Stage
  3 signoff evidence. Required before promotion: a rebuilt DSim Linux slice
  must run beyond the 18M clocksource/timer-interrupt point with no Oops/panic.
- Follow-up bounded 30M attempt:
  `linux_boot_results/stage3_linux_first_fault_candidate_dsim_30m_20260519c`
  was intentionally stopped after the first 1M-cycle status point because the
  wall-clock rate made it another blind wait. It only proves the rebuilt image
  starts cleanly through the OpenSBI banner and does not add Linux panic
  evidence.

Next focused commands:

```bash
python3 tools/run_stage3_rtl_guard.py --runner dsim \
  --run-id stage3_linux_first_fault_candidate_<date>

python3 tools/run_linux_boot.py --run --simulator dsim --build-mode linux \
  --run-dir linux_boot_results/stage3_linux_first_fault_candidate_dsim_30m_<date> \
  --max-cycles 30000000 --target-milestone init_handoff \
  --status-interval 1000000 --no-trace-trap \
  --sim-plusarg +LINUX_STOP_ON_LOW_IFETCH_FAULT \
  --sim-plusarg +LINUX_STOP_SIDEBAND_TVAL=ffffffffeffff9a0
```

If the exact sideband stop fires in a later run, inspect `rob_fire`,
`rob_valid`, `alloc_conflict`, and `not_flushed`. If `rob_fire=0`, the guard
blocked a stale fault and the next run should proceed without the stop plusarg.
If `rob_fire=1`, rerun with:

```bash
python3 tools/run_linux_boot.py --run --simulator dsim --build-mode linux \
  --run-dir linux_boot_results/stage3_linux_bad_range_load_stop_dsim_<date> \
  --max-cycles 20000000 --target-milestone boot_ok \
  --status-interval 1000000 --no-trace-trap \
  --sim-plusarg +LINUX_TRACE_LOAD_PC=ffffffff8013e3e4 \
  --sim-plusarg +LINUX_STOP_ON_TRACE_LOAD_PC
```

That run decides whether the faulting load itself issues with
`addr=ffffffffeffff9a0` and stale `rs1`, or whether the load issues correctly
and the remaining problem is still downstream exception attribution.

Current debug pivot:

- Do not rerun a 50M or 100M boot slice until the next hook is narrower.
- The latest useful status is the 18M line from
  `stage3_linux_first_fault_capture_dsim_20260519b`: `mtip=1` and expired
  `timecmp`, with no trap yet at the sampling point. This is not enough to
  call a timer bug, but it is the next boundary to instrument.
- Add or enable a testbench-only timer interrupt stop/status hook that prints
  CSR interrupt state (`mstatus`, `mie`, effective `mip`, `mideleg`,
  `irq_pending`, `irq_cause`, `trap_valid`, and return PCs) when `mtip` first
  asserts or when the first timer interrupt trap is taken. Keep this out of
  synthesizable RTL.
- `tb_linux.sv` now provides that hook as
  `+LINUX_STOP_ON_TIMER_BOUNDARY`. It prints the CSR timer state at the first
  `mtip` assertion or timer interrupt trap and then terminates the run.
  Verilator Linux-platform compile passes with this hook. DSim rebuild was
  attempted but remained blocked by the shared single-lease limit, so DSim
  execution evidence for the hook is still pending.
- Use the existing directed `vm_mtimer_vector_sv48_smoke` and
  `vm_mtimer_ras_context_sv48_smoke` as the fast correctness guard. The Linux
  run should only be repeated after the timer hook can stop at the boundary
  instead of waiting for another full boot window.

### 2026-05-19 Timer Handoff Debug Update

The latest debug turn should not be treated as another long-run attempt:

- A first DSim Linux timer-boundary run with
  `+LINUX_STOP_ON_TIMER_BOUNDARY` was stopped before useful evidence because
  full Linux still takes about 40 wall-clock minutes to reach the 18M-cycle
  clocksource/timer window.  This confirms that interactive debug needs
  directed smokes or a working faster simulator, not blind 50M or 100M waits.
- The original `vm_mtimer_to_stimer_sv48_smoke` timed out in S-mode because the
  test itself wrote `sie.STIE` and then later overwrote the shared `mie` CSR
  with `MTIE` only.  That cleared STIE before the M-mode timer handler injected
  STIP.  This was a smoke bug, not core evidence.
- After reordering the smoke to program `mie.MTIE` before the delegated
  `sie.STIE` view, both simulators pass the M-timer to S-timer handoff:
  `linux_boot_results/stage3_vm_mtimer_to_stimer_xsim_fixed_20260519a`
  passes at cycle `391`, and
  `linux_boot_results/stage3_vm_mtimer_to_stimer_dsim_fixed_20260519a`
  passes at cycle `394`.  Both runs report zero ordering/replay SVA
  violations, zero exception flushes, and two interrupt flushes, matching the
  intended MTIP then STIP sequence.
- `tests/benchmarks/stage3_vm_smoke.json` now includes
  `vm_mtimer_to_stimer_sv48_smoke` as a Stage 3 directed VM smoke.
- The periodic Linux status line in `tb_linux.sv` now prints `mstatus`, `mie`,
  effective `mip`, and `mideleg`.  This is testbench-only visibility needed to
  interpret the 18M-cycle observation where `mtip=1` and `irq_pending=0`.
- XSim Linux-platform syntax rebuild passes after the status-line change, and
  `linux_boot_results/stage3_vm_mtimer_to_stimer_xsim_status_20260519a`
  re-passes the corrected smoke with the enhanced CSR status fields enabled.

Current panic-debug verdict:

- The older physical fetch panic at `0x80003f7c` and the later
  `bad_range+0xc` stale-address panic are both real failures from earlier RTL
  candidates.
- The current sideband-owner and frontend-context candidate has not reproduced
  either panic through the 18M DSim first-fault capture, but it is not Linux
  signoff because it has not run through the 100M-cycle goal.
- Timer delivery itself is no longer the leading root-cause hypothesis after
  the corrected MTIP-to-STIP smoke.  The next Linux evidence should be either
  a targeted DSim boundary capture with the enhanced CSR status fields or a
  fixed Verilator Linux run.  Verilator currently still aborts immediately
  with `Active region did not converge`, so it is not yet usable as Linux
  execution evidence.

### 2026-05-19 Panic Debug Pivot

Do not extend the Linux cycle cap to debug the current Oops.  The right next
step is a first-event stop run:

- Stop on the stale data-side fault sideband:
  `+LINUX_STOP_SIDEBAND_TVAL=ffffffffeffff9a0`.
- Stop on the exact kernel trap if it recurs:
  `+LINUX_STOP_TRAP_PC=ffffffff8013e3e4` and
  `+LINUX_STOP_TRAP_TVAL=ffffffffeffff9a0`.
- Stop on any LSU load issue in the full `bad_range` body, so fused
  `auipc+ld` and unfused `ld` PCs are both caught:
  `+LINUX_TRACE_COMMIT_LO=ffffffff8013e3d8`,
  `+LINUX_TRACE_COMMIT_HI=ffffffff8013e440`, and
  `+LINUX_STOP_ON_TRACE_LOAD_RANGE`.

Expected interpretation:

- If `[LINUX_STOP_TRACE_LOAD]` reports `addr=ffffffffeffff9a0`, the bug is in
  the Linux-context load issue path or decoded fused-uop metadata.  Inspect
  `fused`, `pc`, `rs1`, and `imm` before touching the MMU sideband path.
- If the bad-range load issues with the correct effective address but
  `[LINUX_STOP_SIDEBAND_TVAL]` or `[LINUX_STOP_TRAP]` still reports the stale
  tval, the bug is stale PTW/DTLB fault ownership or ROB exception attribution.
- If none of these stops fire before the previous panic window, the old
  `bad_range` Oops is not reproduced by the current candidate.  Continue at
  the next architectural boundary, currently timer interrupt delivery after
  `riscv_clocksource`.

Active evidence command:

```bash
python3 tools/run_linux_boot.py --run --simulator dsim --build-mode linux \
  --run-dir linux_boot_results/stage3_linux_bad_range_trap_load_stop_dsim_20m_<date> \
  --max-cycles 20000000 --target-milestone boot_ok \
  --status-interval 5000000 --no-trace-trap \
  --sim-plusarg LINUX_TRACE_CYCLE_LO=12000000 \
  --sim-plusarg LINUX_TRACE_COMMIT_LO=ffffffff8013e3d8 \
  --sim-plusarg LINUX_TRACE_COMMIT_HI=ffffffff8013e440 \
  --sim-plusarg LINUX_STOP_ON_TRACE_LOAD_RANGE \
  --sim-plusarg LINUX_STOP_TRAP_PC=ffffffff8013e3e4 \
  --sim-plusarg LINUX_STOP_TRAP_TVAL=ffffffffeffff9a0 \
  --sim-plusarg LINUX_STOP_SIDEBAND_TVAL=ffffffffeffff9a0
```

### 2026-05-19 UART Failure Stop Harness

The Linux boot harness now treats a kernel Oops or panic as an immediate debug
event instead of allowing the simulator to continue to `MAX_CYCLES`.

- `tb_linux.sv` tracks UART output for `Oops`, `Kernel panic`, and `BUG:`.
- On a match it prints `[LINUX_STOP_UART_FAILURE]` with the current cycle,
  last committed PC, `satp`, trap state, and ROB head/tail, then finishes the
  simulation.
- The stop deliberately does not terminate on the first words
  `Unable to handle`, because that would cut off the faulting virtual address
  that follows on the same UART line. Stopping at `Oops` preserves the fault
  address while still ending the run promptly.
- The monitor is testbench-only. It does not add Linux-specific logic to the
  ASIC-style core RTL.
- The stop can be disabled with `+LINUX_KEEP_RUNNING_AFTER_UART_FAILURE` only
  when collecting a deliberately longer post-panic UART log.

Validation:

- Verilator Linux-platform rebuild passes with the monitor enabled:
  `./build_verilator_linux.sh`.
- OpenSBI UART smoke passes with no false failure stop:
  `linux_boot_results/stage3_uart_failure_stop_smoke_verilator_20260519a`
  reaches the `opensbi_banner` milestone.
- `build_verilator_linux.sh` now disables waveform tracing by default for
  backup Linux execution speed. Rebuild with `VERILATOR_TRACE=1` only when
  waveform capture is required.

### 2026-05-19 Low VM Fetch First-Event Hook

The current panic debug should stop before Linux prints the final Oops.  The
most actionable earlier symptom for the `0x80003f7c` panic class is any
frontend fetch or frontend redirect into the OpenSBI physical text window while
Sv48 translation is active and the frontend fetch privilege is not M-mode.

New testbench-only hook:

- `+LINUX_STOP_ON_LOW_VM_FETCH` stops on low OpenSBI-range frontend PCs before
  the instruction page fault is converted into a Linux kernel Oops.
- The guarded range is `0x8000_0000..0x8005_ffff`, matching the OpenSBI
  reserved text and data region in the generated DTB.
- The stop prints frontend privilege, redirect privilege, `satp`, F1 PC, IFU
  work PC, predicted redirect PC, architectural flush redirect PC, trap and
  return state, RAS state, BRU early redirect state, ROB head and tail, packet
  buffer occupancy, and FTQ count.
- This hook is in `tb_linux.sv` only.  It is not part of the ASIC-style core
  RTL and must not be used as a core behavior fix.

Validation status:

- Verilator Linux-platform rebuild passes with the hook compiled into the
  testbench.
- OpenSBI UART smoke with `+LINUX_STOP_ON_LOW_VM_FETCH` reaches the
  `opensbi_banner` milestone without a false stop:
  `linux_boot_results/stage3_low_vm_fetch_hook_smoke_verilator_20260519a`.
- DSim Linux-platform rebuild passes after the hook addition.
- A Verilator 20M repro attempt with the new hook was stopped after it remained
  in the early OpenSBI window without reaching the first 1M-cycle status line
  quickly enough for interactive debug.  Treat that as non-evidence for Linux
  progress.
- A DSim 20M repro attempt with the new hook reached the 1M OpenSBI status
  point cleanly and was then stopped because it was not producing the next
  checkpoint quickly enough for an interactive turn.  Treat it as OpenSBI
  smoke evidence only, not Linux panic evidence.
- Static symbol correlation of the old low-fetch panic confirms
  `0x80003f7c` is in OpenSBI `sbi_trap_handler`, immediately after
  `jal sbi_timer_process`.  That keeps the debug focus on privileged frontend
  target ownership if this signature recurs on current RTL.

Next focused DSim command:

```bash
python3 tools/run_linux_boot.py --run --simulator dsim --build-mode linux \
  --image build/linux_boot/fw_payload.hex \
  --run-dir linux_boot_results/stage3_low_vm_fetch_repro_dsim_20m_<date> \
  --max-cycles 20000000 --target-milestone boot_ok \
  --status-interval 1000000 --no-trace-trap \
  --sim-plusarg LINUX_STOP_ON_LOW_VM_FETCH \
  --sim-plusarg LINUX_STOP_ON_LOW_IFETCH_FAULT \
  --sim-plusarg LINUX_STOP_SIDEBAND_TVAL=ffffffffeffff9a0 \
  --sim-plusarg LINUX_STOP_TRAP_PC=ffffffff8013e3e4 \
  --sim-plusarg LINUX_STOP_TRAP_TVAL=ffffffffeffff9a0
```

Interpretation:

- If `[LINUX_STOP_LOW_VM_FETCH]` fires before the old UART Oops, debug the
  redirect source first.  A low `req` or `bpu` target points to BPU or RAS
  ownership.  A low architectural `redirect` points to trap, return, or commit
  flush context.  A low `f1` or `work` PC without a low redirect points to IFU
  cursor ownership.
- If only `[LINUX_STOP_LOW_IFETCH_FAULT]` fires, the low target entered the
  frontend before this hook saw the producer.  Re-run with a tighter frontend
  cycle-window trace around the reported cycle.
- If neither low-fetch hook fires and UART still reports a kernel Oops, treat
  the new fault address as the real next blocker instead of assuming the old
  OpenSBI physical fetch bug.

### 2026-05-19 AUIPC Memory-Fusion Root Cause

The current `bad_range+0xc` panic has a concrete RTL root cause candidate, and
the directed evidence is stronger than another blind Linux wait:

- Pre-fix directed reproducer:
  `benchmark_results/stage3_auipc_ld_fault_precision_trace_xsim_20260519b`.
  The test trapped precisely at the Linux-shaped `auipc a5; ld a5,imm(a5)`
  sequence, but failed with `TOHOST=b` because architectural `a5` still held
  stale `fffffffff0000000` in the S-mode trap handler.
- Root cause: `fusion_detector.sv` fused `AUIPC+LD` into one memory uop.  This
  pipeline has one architectural destination per uop and no partial-commit
  path.  On a load page fault, commit correctly suppresses the faulting load
  destination update, but that also loses the already-completed AUIPC result.
  The Linux trap therefore observes stale `a5`, exactly matching
  `fffffffff0000000 - 0x660 = ffffffffeffff9a0`.
- The same structural issue applies to `AUIPC+STORE`, because the AUIPC
  destination would be dropped entirely.  `AUIPC+JALR` is now only fused for
  same-destination call forms where the single fused destination is
  architecturally sufficient.

Current RTL repair:

- `fusion_detector.sv` no longer fuses `AUIPC+LD` or `AUIPC+STORE`.
- `AUIPC+JALR` fusion is restricted to
  `auipc rd; jalr rd, imm(rd)` style same-destination forms.
- This is a general macro-fusion correctness repair, not a Linux address or
  benchmark special case.

Validation:

- XSim post-fix directed smoke:
  `benchmark_results/stage3_auipc_ld_fault_precision_trace_xsim_20260519c`
  passes with `TOHOST=1` at cycle `243`.
- DSim post-fix directed smoke:
  `benchmark_results/stage3_auipc_ld_fault_precision_trace_dsim_20260519a`
  passes with `TOHOST=1` at cycle `244`.
- DSim CoreMark guard on the same RTL:
  `benchmark_results/stage3_rtl_guard_auipc_mem_fusion_off_dsim_20260519a`
  passes CM1 and CM10:
  CM1 `150,398` timed cycles, `6.649025 CM/MHz`;
  CM10 `1,459,540` timed cycles, `6.851474 CM/MHz`.
- DSim Dhrystone guard with stale golden-PC checking disabled:
  `benchmark_results/stage3_rtl_guard_auipc_mem_fusion_off_dsim_ds_skipgolden_20260519a`
  passes DS100 and DS300:
  DS100 `18,068` timed cycles, `3.150055 DMIPS/MHz`;
  DS300 `53,046` timed cycles, `3.218821 DMIPS/MHz`.
- `tools/run_benchmarks.py` now has `--skip-golden-pc`, and
  `tools/run_stage3_rtl_guard.py` uses it.  This is a harness cleanup because
  the Dhrystone golden PC fixtures are stale for the current frontend, while
  the endpoint and score checks remain valid.

Linux checkpoint status:

- The Linux DSim image was rebuilt from the current RTL:
  `linux_boot_results/stage3_rebuild_after_auipc_fusion_fix_20260519a`.
- A 20M targeted Linux probe with exact old-panic stops was started:
  `linux_boot_results/stage3_linux_bad_range_after_auipc_fusion_fix_dsim_20m_20260519a`.
  It was stopped intentionally because wall-clock progress was too slow and it
  had not reached the Linux panic window.  It adds no new kernel-pass evidence.
- Therefore, the directed panic class is fixed and performance guarded, but
Linux boot is not yet promoted.  The next Linux run should be a lean rebuilt
DSim checkpoint with minimal tracing, or a fixed Verilator Linux platform,
and must prove no `bad_range+0xc` Oops before moving to the next boot
blocker.

### 2026-05-19 AMO/SC Commit-Precision Root Cause

The later `BUG: scheduling while atomic` panic is now root-caused as an AMO/SC
precision bug, not as a longer-timeout problem.

Failing evidence:

- Artifact: `linux_boot_results/stage3_sched_bug_preempt_load_context_dsim_20260519a`.
- Linux entered `ret_from_exception`, returned to `mutex_lock`, and committed
  `sc.d` at `ffffffff805d75ac`.
- The following branch at `ffffffff805d75b0` saw `a4=1`, meaning the SC
  architecturally failed.
- The retry LR at `ffffffff805d75a6` then loaded `a5=ffffffff80e9f700` from
  `list_lrus_mutex`, the exact owner value that the failed SC attempted to
  store.
- The scheduler bug branch at `ffffffff805d522e` later committed with `a5=2`
  and `s5=1`, matching the `BUG: scheduling while atomic` path.

Root cause:

- The old AMO/SC path could send a successful SC or AMO store to D-cache before
  the ROB entry reached commit.
- If an interrupt or other full flush arrived after that early D-cache side
  effect but before the AMO/SC retired, the architectural instruction was
  replayed or failed while the speculative memory update remained visible.
- This violates precise side-effect ordering.  It is especially visible in
  Linux mutex code because a failed `sc.d` must not publish the lock owner.

RTL repair:

- `lsu.sv` now separates AMO/SC rd writeback from the D-cache store side
  effect.
- AMO/SC stores are captured in LSU state after the read/SC check, but
  `dcache_store_req_valid` is asserted only after the AMO ROB index enters the
  current commit window.
- A full flush kills an uncommitted AMO store.  If the AMO store has already
  entered the commit window, the LSU keeps it live until the D-cache store
  acknowledges.
- `rv64gc_core_top.sv` passes the total `commit_count` into the LSU so the AMO
  side-effect gate can identify the current commit group.

Validation:

- Directed AMO/SC interrupt precision smoke passes on Verilator:
  `linux_boot_results/stage3_amo_sc_irq_directed_verilator_20260519b`.
- Directed AMO/SC interrupt precision smoke passes on DSim:
  `linux_boot_results/stage3_amo_sc_irq_directed_dsim_20260519f`.
- Focused DSim Linux panic-window run:
  `linux_boot_results/stage3_amo_commit_gate_panic_window_dsim_20260519c`.
  It reaches 19M cycles, passes the old `17,957,555` cycle panic window, and
  has no `BUG`, no `Oops`, no `Unable to handle kernel`, no `Kernel panic`,
  and no actual `[LINUX_STOP_COMMIT_PC]` stop at `ffffffff805d522e`.
- The 19M run still stops by the intentional max-cycle timeout with last
  milestone `riscv_clocksource`.  It is panic-window debug evidence, not full
  Linux boot signoff.
- Stage 3 DS/CM hard guard passes with the AMO/SC fix:
  `benchmark_results/stage3_rtl_guard_amo_sc_commit_gate_20260519a`.

Guard metrics:

| Row | Timed cycles | Metric | Gate |
|---|---:|---:|---|
| `dhrystone_100_checkedin` | 18,068 | 3.150055 DMIPS/MHz | PASS |
| `dhrystone_300_stage1_anchor` | 53,046 | 3.218821 DMIPS/MHz | PASS |
| `coremark_iter1_generalization` | 150,398 | 6.649025 CM/MHz | PASS |
| `coremark_iter10_checkedin` | 1,459,540 | 6.851474 CM/MHz | PASS |

Next debug action:

- Do not wait longer on the old scheduler-atomic panic signature.  That window
  is cleared by the AMO/SC commit-precision repair.
- Continue Linux boot from the latest clean RTL with a lean DSim checkpoint and
  UART panic detection enabled.
- If the next run fails, treat the first new `Oops`, `BUG`, `panic`, trap
  signature, or no-progress condition as the next blocker.  Build a directed
  smoke from that contract before the next RTL promotion.

### 2026-05-19 100M Run Interruption Triage

The first 100M DSim run after the AMO/SC commit-precision fix was intentionally
stopped for panic triage instead of waiting to the full cap:

- Commit under test: `2901e3b` (`Fix AMO SC commit precision for Linux`).
- Artifact:
  `linux_boot_results/stage3_amo_commit_gate_clean_100m_dsim_20260519a`.
- The run was rebuilt from the current RTL and stopped by operator request
  after the latest flushed status at `cyc=30000000`.
- The stopped artifact has no `BUG`, no `Oops`, no `Unable to handle kernel`,
  and no `Kernel panic` marker through the recorded UART/DSim logs.
- UART had progressed past the previously saved panic windows and reached
  `SCSI subsystem initialized`.

Important stale-panic distinction:

- `linux_boot_results/stage3_linux_clean_100m_dsim_20260519a` is an older
  `#34` Linux/RTL run from before `2901e3b`.  Its
  `badaddr=0000000080003f7c` panic is not current evidence unless reproduced
  on `2901e3b` or later.
- The older `ffffffff805c5dec` trap-frame panic is also a historical failure
  class.  It should remain as root-cause documentation, not the active blocker,
  unless it appears again in a current rebuilt run.

Debug rule going forward:

- Do not wait for a 50M or 100M run after a current rebuilt artifact prints
  `Oops`, `BUG`, `Unable to handle kernel`, or `Kernel panic`.
- Stop immediately on the first current failure signature and debug that exact
  artifact.
- If a panic signature comes from an older run, first compare the artifact
  timestamp, Linux build line, and git commit against the current RTL before
  spending debug time on it.

### 2026-05-20 Current Watchdog BUG Triage And Timer-Scale Fix

Current failure artifact:

- Run: `linux_boot_results/stage3_current_100m_goal_dsim_20260519223941`.
- Result: stopped at cycle `68,563,458` on UART failure pattern `BUG:`.
- Visible UART line: `[   52.017374] watchdog: BUG:`.
- Last simulator PC while printing the line: `ffffffff8048f3ba`, which symbols
  to `serial8250_early_out+0x92`.
- No core trap, no stale low-VM fetch, no `Unable to handle kernel paging
  request`, and no old scheduler-atomic panic reproduced in that current run.
- The core was still committing at the stop point:
  `last_commit_cyc=68563455`, three cycles before the stop.

Root cause classification:

- The current `watchdog: BUG:` line maps to the Linux soft-lockup detector in
  `kernel/watchdog.c`, not to the stale paging-request panic class.
- The platform DT advertises `timebase-frequency = <1000000>`.
- Before the fix, `clint.sv` incremented `mtime` once per core clock, so Linux
  interpreted `68M` simulated core cycles as tens of seconds of elapsed kernel
  time.  That made the soft-lockup detector a simulation-timebase artifact
  rather than direct evidence of a core pipeline deadlock.

Accepted fix:

- `src/rtl/platform/clint.sv` now has a synthesizable `MTIME_DIV_P` parameter.
- `src/rtl/platform/mmio_platform.sv` instantiates the CLINT with
  `CLINT_MTIME_DIV_P = 100`.
- The DT remains at `1 MHz`, so the Stage 3 platform now models a 100 MHz core
  clock with a 1 MHz CLINT timebase.  This is an ASIC-style platform-timer
  contract, not a testbench-only watchdog suppressor and not a Linux software
  workaround.

Validation:

- DSim Linux platform rebuild passed:
  `linux_boot_results/stage3_timer_div_build_dsim_20260520a`.
- M-mode UART smoke passed:
  `linux_boot_results/stage3_timer_div_mmode_smoke_dsim_20260520a`.
- Linux early-console checkpoint passed:
  `linux_boot_results/stage3_timer_div_linux_5m_status_dsim_20260520a`.
- Timer-scale evidence from the Linux status lines:
  - `cyc=1,000,000`, `time=0x2710` = `10,000`.
  - `cyc=2,000,000`, `time=0x4e20` = `20,000`.
  - `cyc=3,000,000`, `time=0x7530` = `30,000`.
- This confirms `mtime = mcycle / 100`, matching the 100 MHz core-clock model
  with the advertised 1 MHz CLINT timebase.
- Required Stage 3 DS/CM hard performance guard passed:
  `benchmark_results/stage3_rtl_guard_20260520_clint_mtime_divider`.

DS/CM guard metrics after the RTL change:

| Row | Timed cycles | Metric | Gate |
|---|---:|---:|---|
| Dhrystone 100 | `18,068` | `3.150055 DMIPS/MHz` | pass |
| Dhrystone 300 | `53,046` | `3.218821 DMIPS/MHz` | pass |
| CoreMark 1 | `150,398` | `6.649025 CM/MHz` | pass |
| CoreMark 10 | `1,459,540` | `6.851474 CM/MHz` | pass |

Next debug step:

- Rerun the Linux boot slice beyond the previous `68.56M` cycle point on the
  rebuilt timer-divided platform.
- If another current `Oops`, `BUG`, `Unable to handle`, or panic appears, debug
  that exact signature immediately.
- If no failure appears through the previous watchdog point, continue toward
  the 100M-cycle unblock milestone with the same panic-stop policy.

### 2026-05-20 Panic Debug Recheck

The active debug rule is to stop on a fresh panic, not to wait longer after a
failure signature.  The May 20 recheck did not find a current kernel panic in
the rebuilt timer-divided RTL artifacts:

- `linux_boot_results/stage3_timer_div_100m_unblock_dsim_20260520a` was the
  current rebuilt 100M-goal run. It was operator-stopped around the low-30M
  cycle window for debug triage. The recorded UART/DSim logs have no `Oops`,
  no `BUG:`, no `Unable to handle kernel`, no `Kernel panic`, and no
  watchdog signature.
- `linux_boot_results/stage3_linux_current_first_event_debug_dsim_20m_20260520a`
  enabled low-VM-fetch, stale-sideband, trap, and timer-boundary stops. It
  reached the `14M` status window, passed through the old
  `ffffffff805c5dec`/`strcmp` area, and produced no fresh panic marker before
  the trace-heavy run stopped making useful progress. The run was interrupted;
  its simulator exit-code failure is not a Linux failure.
- `linux_boot_results/stage3_linux_current_panic_debug_notrace_dsim_25m_20260520a`
  was a lightweight replacement with UART panic detection and exact
  `ffffffffeffff9a0` stop hooks. It reached the OpenSBI banner and the `1M`
  status point with no failure marker, then was intentionally stopped because
  it was too slow to add same-turn evidence.

Current verdict:

- The `ffffffff805c5dec`, `0000000080003f7c`, and `ffffffffeffff9a0` panic
  signatures remain historical debug classes unless they reproduce in a
  current rebuilt run.
- No current May 20 artifact examined so far contains a fresh kernel panic.
- Do not debug an old panic transcript without first checking its run
  directory, Linux build line, and RTL commit.  If a current run prints a new
  `Oops`, `BUG:`, `Unable to handle kernel`, or `Kernel panic`, stop that run
  immediately and use that exact artifact as the next root-cause target.

### 2026-05-20 User-Reported Panic Recheck

The 100M-goal DSim run was stopped to pivot into panic debug instead of
waiting for the full timeout:

- Run: `linux_boot_results/stage3_timer_div_100m_panic_capture_dsim_20260520a`.
- It reached the `30M` status point with no `Oops`, no `BUG:`, no
  `Unable to handle kernel`, no `Kernel panic`, and no `LINUX_STOP`.
- It passed the old `ffffffff805c5dec`/`strcmp` region without reproducing the
  May 14 instruction-page-fault panic.
- Its UART log also has no panic marker. The run was killed by operator
  direction, so it is not a 100M success artifact and should not be used as a
  boot signoff result.

Current debug rule:

- Do not continue a long run after a kernel-visible failure marker appears.
- Do not debug a stale panic transcript as the current blocker without a fresh
  rebuilt-run reproduction.
- The next actionable failure must come from a current run directory and must
  capture the first `Oops`, `BUG:`, panic, low-VM-fetch stop, or
  `scause/stval/sepc` signature before any RTL modification.
- If the next current run remains clean, the next milestone is still to run
  past the old `68.56M` watchdog-BUG window on the timer-divided platform.

### 2026-05-20 Latest Panic Interruption Audit

The latest 100M-goal DSim run was stopped immediately after the user reported a
kernel-panic concern:

- Run: `linux_boot_results/stage3_100m_unblock_dsim_20260520c`.
- The DSim and runner processes were interrupted intentionally, so this is not
  a pass/fail boot milestone.
- The stopped artifact reached `cyc=26,928,089` and had status checkpoints
  through `25M`.
- Its UART and DSim logs contain no `Unable to handle kernel`, no `Oops`, no
  `BUG:`, no `Kernel panic`, no `watchdog`, and no `LINUX_STOP`.
- The kernel had reached the early Linux memory/setup path through
  `riscv_clocksource`, `sched_clock`, `Mount-cache`, `Mountpoint-cache`,
  `devtmpfs`, DMA pool setup, `thermal_sys`, `cpuidle`, and `HugeTLB`.

The broader artifact search also found no fresh panic marker in Linux boot logs
modified in the last three hours. The current failure signatures still separate
into historical classes:

- May 14 `ffffffff805c5dec`, instruction page fault in the old trap-frame
  corruption window.
- May 18/19 `0000000080003f7c`, stale low OpenSBI timer-vector fetch.
- May 19 `ffffffffeffff9a0`, stale data-side PTW or DTLB sideband attribution.
- May 19 `watchdog: BUG:`, stale CLINT timebase scaling before `mtime=mcycle/100`.

Current verdict:

- There is no current rebuilt-run kernel panic artifact to root-cause yet.
- Do not claim Linux progress from the interrupted run, but also do not debug
  any old panic transcript as the active blocker unless it reproduces on the
  current rebuilt DSim image.
- The next Linux run should be a first-failure capture slice with
  `LINUX_UART_FAIL_DELAY`, low-VM-fetch stop, exact stale-sideband stop, and
  exact trap stop hooks enabled. If it prints a kernel-visible failure marker,
  stop on that artifact and debug it immediately. If it stays clean, continue
  only to the next bounded progress checkpoint.

### 2026-05-20 Current Panic Debug Stop

The next DSim 100M-goal attempt was also stopped by operator direction to avoid
waiting after a suspected kernel-panic report:

- Run: `linux_boot_results/stage3_100m_unblock_dsim_20260520f`.
- The DSim image was current versus the RTL at launch, and the run used the
  timer-divided CLINT platform with UART failure detection and the old
  `ffffffff805c5dec`, `ffffffffeffff9a0`, low-VM-fetch, and low-ifetch-fault
  stop hooks enabled.
- The run was interrupted manually after the latest flushed status point at
  `cyc=45,000,000`.
- Its UART and DSim logs contain no `Unable to handle kernel`, no `Oops`, no
  `BUG:`, no `Kernel panic`, no `watchdog`, and no `LINUX_STOP`.
- It reached the post-clocksource Linux path through `Mount-cache`,
  `Mountpoint-cache`, `devtmpfs`, DMA pool setup, `thermal_sys`, `cpuidle`,
  `HugeTLB`, and `raid6` output.

Current debug verdict:

- There is still no fresh current-RTL kernel panic artifact from the
  timer-divided platform to root-cause.
- The most recent true `BUG:` artifact remains
  `linux_boot_results/stage3_current_100m_goal_dsim_20260519223941`, where
  Linux time advanced too quickly before the accepted CLINT `mtime` divider
  fix. That artifact is a pre-fix timer-scale failure and should not be used
  as current core-pipeline evidence.
- The right debug action is not to wait after a failure marker, but also not
  to chase stale panic transcripts. The next run must stop on the first fresh
  current marker and preserve the exact UART, CSR, trap, and frontend context.
  If no marker appears, the next evidence target remains crossing the old
  `68.56M` watchdog-BUG window on the timer-divided platform.

### 2026-05-20 Latest 50M Panic Debug Stop And Stale-Panic Audit

The latest DSim retry was stopped deliberately so panic debug could start
instead of waiting for the full 100M timeout:

- Run: `linux_boot_results/stage3_100m_unblock_dsim_20260520_retry_2`.
- The run used the rebuilt timer-divided CLINT platform and the current
  `fw_payload.hex`.
- It reached the `50M` status checkpoint cleanly before being stopped.
- Its UART and DSim logs contain no `Unable to handle kernel`, no `Oops`, no
  `BUG:`, no `Kernel panic`, no `watchdog`, and no `LINUX_STOP`.
- This is negative panic evidence only. It is not a 100M boot signoff result.

Stale-panic audit:

| Artifact | First visible signature | Symbol classification | Current verdict |
|---|---|---|---|
| `stage3_linux_200m_current_rtl_20260514a` | Instruction page fault, `badaddr=ffffffff805c5dec`, `cause=0xc` | `strcmp+0x4` | Historical trap-frame or fetch-identity failure. Not reproduced by May 20 rebuilt runs. |
| `stage3_linux_clean_100m_dsim_20260519a` | Instruction page fault, `badaddr=0000000080003f7c`, `cause=0xc` | OpenSBI `sbi_trap_handler` region, reached from `kernel_init_pages+0x8c` | Historical low-fetch or stale fetch-sideband failure. Not current unless reproduced. |
| `stage3_linux_fetch_context_mask_low_ifetch_clean_dsim_20m_20260519a` | Load page fault, `badaddr=ffffffffeffff9a0`, `cause=0xd` | Linux `bad_range+0xc`, called by `expand+0x52` in page allocator | Historical data-side PTW/DTLB or sideband-attribution failure. Not current unless reproduced. |
| `stage3_current_100m_goal_dsim_20260519223941` | UART `watchdog: BUG:` at `cyc=68,563,458` | Linux soft-lockup detector, print PC in `serial8250_early_out+0x92` | Pre-`MTIME_DIV_P` timer-scale failure. Fixed by the accepted CLINT divider. |

Debug policy from this audit:

- There is no fresh current-RTL kernel panic artifact to root-cause right now.
- Do not chase the May 14 or May 19 Oops transcripts as active blockers unless
  they reproduce on the current rebuilt DSim image.
- The next Linux run must remain a first-failure capture run with UART failure
  stop, low-VM-fetch stop, low-ifetch-fault stop, and exact old-address stop
  hooks enabled.
- If the next current run prints `Oops`, `BUG:`, `Unable to handle kernel`,
  `Kernel panic`, `LINUX_STOP`, or a nonzero trap signature, stop immediately
  and debug that exact artifact.
- If it stays clean, the next meaningful progress checkpoint is crossing the
  old `68.56M` watchdog-BUG window on the timer-divided platform.

Follow-up capture attempt:

- `linux_boot_results/stage3_70m_first_failure_dsim_20260520a` could not run
  because the DSim license server denied the lease with `maxLeases=1`.
- `linux_boot_results/stage3_70m_first_failure_verilator_20260520a` was
  launched as backup debug evidence and then stopped because it was still in
  early Linux after several minutes. It reached the clean `#38` Linux version
  line and produced no panic marker before interruption.
- This Verilator run is not signoff evidence. The boundary-clearing run still
  needs DSim when the shared license is available.

### 2026-05-20 55M Panic Debug Stop

The next DSim first-failure capture was stopped after the latest user-reported
kernel-panic concern so the current artifact could be audited instead of
waiting to 100M:

- Run: `linux_boot_results/stage3_100m_unblock_dsim_20260520i_try1`.
- Follow-up retry-loop run:
  `linux_boot_results/stage3_100m_unblock_dsim_20260521_retryloop`.
- The run used the rebuilt timer-divided CLINT platform, the current
  `fw_payload.hex`, UART failure detection, low-VM-fetch and low-ifetch-fault
  stops, and exact old-address stop hooks for `ffffffff805c5dec` and
  `ffffffffeffff9a0`.
- Both runs reached the `55M` status checkpoint before being stopped for
  panic triage.
- The last checkpoint was clean: `trap=0`, `mtip=0`, `msip=0`,
  `last_pc=ffffffff803fd0ca`, `time=0000000000086470`,
  `timecmp=0000000000087253`.
- Its UART and DSim logs contain no `Unable to handle kernel`, no `Oops`, no
  `BUG:`, no `Kernel panic`, no `watchdog: BUG`, and no `LINUX_STOP`.
- It passed the stale `ffffffff805c5dec`/`strcmp` region and the current
  `raid6` calibration output.  This is negative panic evidence only, not a
  100M boot signoff result.

Debug verdict:

- There is still no fresh current-RTL kernel panic artifact to root-cause.
- The latest true `BUG:` evidence remains the pre-`MTIME_DIV_P`
  `stage3_current_100m_goal_dsim_20260519223941` run, where Linux-visible
  time advanced too quickly and MTIP arrived during early boot.
- The next actionable run should not be a blind 100M wait.  It should be a
  bounded first-failure capture that crosses the old `68.56M` watchdog-BUG
  window on the timer-divided platform.  If it prints a fresh `Oops`, `BUG:`,
  `Unable to handle kernel`, `Kernel panic`, `LINUX_STOP`, or nonzero trap
  signature, stop immediately and debug that exact artifact.
- The bounded DSim first-failure retry
  `linux_boot_results/stage3_72m_first_failure_dsim_20260520b` did not run:
  DSim returned `simulator exit code 105` with `Already at maxLeases (1)`.
  This is a license availability result only.  No RTL or Linux evidence was
  produced by that attempt.

### 2026-05-20 31M Panic Debug Stop

The next bounded first-failure DSim retry was stopped deliberately after the
kernel-panic concern so debug could focus on concrete failure artifacts rather
than waiting for a longer timeout:

- Run: `linux_boot_results/stage3_72m_first_failure_dsim_20260520c_retryloop`.
- The run used the rebuilt timer-divided CLINT platform, current
  `fw_payload.hex`, UART failure detection, low-VM-fetch and low-ifetch-fault
  stops, and exact old-address stop hooks for `ffffffff805c5dec` and
  `ffffffffeffff9a0`.
- The run reached the `31M` status checkpoint before being stopped.
- The last checkpoint was clean: `trap=0`, `mtip=0`, `msip=0`,
  `last_pc=ffffffff803fd5a2`, `time=000000000004baf0`,
  `timecmp=000000000004c017`.
- Its UART and DSim logs contain no `Unable to handle kernel`, no `Oops`, no
  `BUG:`, no `Kernel panic`, no `watchdog: BUG`, and no `LINUX_STOP`.
- It passed the stale `ffffffff805c5dec`/`strcmp` window and reached the
  current `raid6` calibration path. This is negative panic evidence only, not
  a 72M or 100M boot signoff result.

Current debug verdict:

- There is still no fresh current-RTL kernel-panic artifact to root-cause.
- The historical `ffffffff805c5dec` Oops remains classified as the old
  trap-frame or fetch-identity failure. It is not reproduced by the May 20
  rebuilt timer-divided runs.
- The historical `ffffffffeffff9a0` Oops remains classified as the old
  `AUIPC+LD` macro-fusion precise-fault bug. Current RTL keeps
  `AUIPC+LD` and `AUIPC+STORE` unfused because this core has one destination
  per uop and no partial-commit path.
- The historical `watchdog: BUG:` artifact remains classified as the old CLINT
  timebase scaling failure before `mtime=mcycle/100`.
- Do not make a pipeline RTL change for any of those stale panic signatures
  unless a rebuilt current-RTL run reproduces one of them. The next Linux
  action remains a first-failure capture run with the panic and exact-address
  stop hooks enabled, or a narrow directed test if a fresh stop marker appears.

### 2026-05-20 Latest 100M Run Panic Audit Stop

The active 100M-goal DSim retry was stopped immediately after the user reported
a kernel-panic concern, so the current artifact could be audited instead of
waiting for the full timeout:

- Run: `linux_boot_results/stage3_100m_unblock_dsim_20260521b_retryloop`.
- The run used the rebuilt timer-divided CLINT platform, current
  `fw_payload.hex`, UART failure detection, low-VM-fetch and low-ifetch-fault
  stops, and exact old-address stop hooks for `ffffffff805c5dec` and
  `ffffffffeffff9a0`.
- The run reached the `30M` status checkpoint before being stopped by operator
  direction. Its `summary.json` reports `FAIL` only because the simulator was
  terminated with exit code `-15`; it is not a Linux failure signature.
- The last checkpoint was clean: `trap=0`, `mtip=0`, `msip=0`,
  `last_pc=ffffffff803fd506`, `time=00000000000493e0`,
  `timecmp=000000000004a08e`.
- Its UART and DSim logs contain no `Unable to handle kernel`, no `Oops`, no
  `BUG:`, no `Kernel panic`, no `watchdog: BUG`, and no `LINUX_STOP`.
- It passed the stale `ffffffff805c5dec`/`strcmp` window and reached the
  current `raid6` calibration path. This is negative panic evidence only, not a
  100M boot signoff result.

Current debug verdict:

- There is still no fresh current-RTL kernel-panic artifact to root-cause.
- The most recent true failure-class artifact remains the pre-`MTIME_DIV_P`
  `watchdog: BUG:` run, where Linux-visible time advanced too quickly before
  the accepted CLINT divider fix.
- Do not debug a stale May 14 or May 19 panic transcript as the active blocker
  unless it reproduces on the current rebuilt DSim image.
- If a new current run prints a kernel-visible failure marker, stop immediately
  and use that exact run directory as the root-cause target. If no marker
  appears, the next meaningful evidence point remains crossing the old
  `68.56M` watchdog-BUG window on the timer-divided platform.

### 2026-05-21 35M Panic Debug Stop

The latest 72M first-failure capture was stopped after the user asked to debug
the suspected kernel panic instead of waiting for the timeout:

- Run:
  `linux_boot_results/stage3_72m_first_failure_dsim_20260521c_retryloop`.
- The run used the rebuilt timer-divided CLINT platform, current
  `fw_payload.hex`, UART failure stop, low-VM-fetch/low-ifetch stops, and exact
  old-address hooks for `ffffffff805c5dec` and `ffffffffeffff9a0`.
- The run reached the `35M` status checkpoint before it was terminated for
  triage.
- Its UART and DSim logs contain no `Unable to handle kernel`, no `Oops`, no
  `BUG:`, no `Kernel panic`, no `watchdog: BUG`, and no `LINUX_STOP`.
- It crossed the stale `ffffffff805c5dec`/`strcmp` region with `trap=0` at the
  `10M` status checkpoint and reached the current `raid6` calibration path.

Debug verdict:

- The latest stopped current-RTL artifact still does not provide a fresh kernel
  panic to root-cause.
- The known historical signatures remain quarantined until reproduced on a
  current rebuilt DSim image:
  `ffffffff805c5dec` maps to Linux `strcmp`,
  `ffffffffeffff9a0` maps to the stale `bad_range+0xc` data-side fault,
  `0000000080003f7c` maps to the OpenSBI timer-trap return path, and
  `watchdog: BUG:` maps to the pre-`MTIME_DIV_P` timer-scale artifact.
- Do not make an RTL change for one of those stale signatures without a fresh
  reproduction. The correct debug loop is first-failure capture with fail-fast
  UART/trap hooks, then symbolization and a narrow directed smoke.

### 2026-05-21 Latest Panic Debug Stop

The active 100M DSim retry was stopped immediately after the latest
kernel-panic report so the current artifact could be audited instead of waiting
for a long timeout:

- Run:
  `linux_boot_results/stage3_lsu_p0_retry_100m_dsim_notrap_20260521b`.
- The run used the current post-`LSU` port0 miss-retry RTL, the rebuilt DSim
  Linux image, UART failure stop, low-VM-fetch/low-ifetch stops, and exact
  old-address hooks for `ffffffff805c5dec` and `ffffffffeffff9a0`.
- The run reached the `30M` status checkpoint before it was terminated for
  panic triage.
- The last checkpoint was clean: `trap=0`, `mtip=0`, `msip=0`,
  `last_pc=ffffffff803fd506`, `time=00000000000493e0`,
  `timecmp=000000000004a08e`, and
  `last_commit_cyc=29,999,999`.
- Its UART and DSim logs contain no `Unable to handle kernel`, no `Oops`, no
  `BUG:`, no `Kernel panic`, no `watchdog: BUG`, and no `LINUX_STOP`.
- It crossed the stale `ffffffff805c5dec`/`strcmp` region at the `10M`
  checkpoint and reached the current `raid6` calibration path.

Current debug verdict:

- There is still no fresh current-RTL kernel-panic artifact to root-cause.
- The active blocker is evidence collection, not a known current RTL fix.  The
  next run should be a bounded first-failure capture, not a blind signoff wait:
  stop immediately on any fresh `Oops`, `BUG:`, `Unable to handle kernel`,
  `Kernel panic`, low-fetch stop, exact-address stop, or nonzero trap marker.
- If no fresh marker appears, the next meaningful Linux evidence point is
  crossing the old `68.56M` watchdog-BUG window on the timer-divided platform
  with retirement still moving.

### 2026-05-21 100M First-Failure Freeze

The latest completed current-RTL first-failure run did not reproduce a fresh
kernel panic:

- Run:
  `linux_boot_results/stage3_lsu_p0_retry_100m_first_failure_dsim_20260521080525`.
- The run reached OpenSBI, Linux early console, `riscv_clocksource`,
  `clocksource: Switched to clocksource riscv_clocksource`, `PCI: CLS 0 bytes`,
  and `kvm [1]: hypervisor extension not available`.
- Its UART log contains no fresh `Unable to handle kernel`, no `Oops`, no
  `BUG:`, no `Kernel panic`, and no `LINUX_STOP`.
- It does not meet the 100M unblocked goal: retirement stops after
  `last_commit_cyc=62,720,377`, then `minstret=59,805,393` remains constant
  through the 100M timeout.
- The frozen architectural state is M-mode timer handling:
  `priv=3`, `mtip=1`, `mip=0xa0`, `mie=0x28`, `satp=90000000000811be`,
  `last_pc=000000008000c83e`, `f1_pc/work_pc=000000008000c874`,
  `lq_full=1`, `rob_free=27`, `rob_head=4`, `rob_tail=105`.
- The ROB head packet is:
  `pc0=000000008000c840`, `pc1=000000008000c842`,
  `is_load=0101`, `ready=0110`.
- Symbolization against `build/linux_boot/fw_payload.elf` maps
  `0x8000c840` to the compressed `lw a3,40(a5)` in OpenSBI
  `mtimer_event_start`; the fetch cursor at `0x8000c874` is inside the
  neighboring `aclint_mtimer_sync` path.

Current debug verdict:

- The active blocker is a no-retire LSU/LQ/ROB readiness deadlock in the
  OpenSBI M-mode timer path, not the stale May 14/May 19 kernel-panic
  signatures.
- The immediate root-cause question is whether the `0x8000c840` load was:
  lost before LQ execution, captured in LMB but never filled, filled but never
  drained to CDB/ROB, or written back while the ROB/LQ bookkeeping failed to
  observe it.
- A testbench-only no-commit diagnostic hook was added to `tb_linux.sv`:
  `+LINUX_STOP_ON_NO_COMMIT +LINUX_NO_COMMIT_LIMIT=<cycles>`. It prints the
  LQ head/tail/count, live LQ entries, LMB entries, retry state, D-cache
  response state, and load writeback state at the first no-commit stop.
- Verilator rebuild validates the hook syntactically and a 1M Verilator smoke
  prints the new stall dump at timeout. Verilator is still too slow for this
  63M repro; DSim remains the required simulator for the first-failure capture.
- The next run should rebuild the DSim Linux image from the current worktree,
  then run a bounded 63M DSim slice with
  `+LINUX_STOP_ON_NO_COMMIT +LINUX_NO_COMMIT_LIMIT=50000`. Do not run another
  blind 100M wait before collecting that LQ/LMB dump.

### 2026-05-21 LSU Owner-Retry Repair, Directed Validation

Static root-cause inspection found a credible lost-load path that matches the
`mtimer_event_start` freeze:

- D-cache can accept or merge a load miss into its MSHR machinery.
- One cycle later, the LSU miss detector must allocate an LMB entry so that the
  original load still has a completion owner.
- If the LMB has no free entry at that point, the previous RTL counted the miss
  but did not keep the load live. The D-cache line can later fill, but the ROB
  entry for the original load has no LMB owner to wake it up.
- That failure mode explains the observed combination of `lq_full=1`,
  ROB head stuck on a load, and no fresh UART panic in the latest 100M run.

Directed-validated RTL change, still pending full Linux confirmation:

- `src/rtl/core/lsu/lsu.sv` now captures `p*_lmb_retry_req` into the existing
  port retry registers when a miss is detected and no LMB completion owner can
  be reserved.
- The repair intentionally does not feed the late LMB retry signal back into
  same-cycle load issue suppression, because that creates a D-cache response to
  issue-valid combinational dependency. Retry ownership is taken by the
  registered retry path on the following cycle.
- A stale XSim snapshot before rebuild reproduced the directed failure in
  `benchmark_results/stage3_probe_mtimer_head_load_pressure_xsim_50k_dump_20260521a`:
  the run timed out at 50K cycles with `lq_full=49934`, `52` load issues, only
  `43` load writebacks, and nine live load owners that could no longer retire.
  That is debug evidence for the lost-owner class, but not a current RTL result
  because the XSim image was stale.
- After rebuilding the current RTL, the same directed timer-body pressure probe
  passes on both XSim and DSim. The DSim proof point is
  `benchmark_results/stage3_probe_mtimer_head_load_pressure_dsim_fix_20260521a`:
  `PASS`, `mcycle=283`, `minstret=107`, `67` load issues, `67` load writebacks,
  `Fill matches=66`, no live LQ/LMB/MSHR leftovers at finish.
- The broader LQ pressure probe
  `benchmark_results/stage3_probe_lq_full_load_completion_dsim_fix_20260521a`
  also passes: `mcycle=787`, `minstret=222`, `LMB max occupied=16`, and no
  LMB full cycles.
- The required Stage 3 DS/CM hard regression gate passes after rebuilding DSim
  from the same worktree:
  `benchmark_results/stage3_rtl_guard_lsu_lmb_owner_retry_20260521a`.
  Metrics are DS100 `3.150055 DMIPS/MHz`, DS300 `3.218821 DMIPS/MHz`,
  CM1 `6.649025 CoreMark/MHz`, and CM10 `6.851474 CoreMark/MHz`, all within
  the `0.01%` no-regression rule.

Current Linux status:

- There is no fresh UART-visible kernel panic in the latest complete Linux
  first-failure run. The May 14 `Unable to handle kernel paging request` and
  May 19 `BUG: scheduling while atomic` signatures are stale failure classes.
- The latest complete blocker remains the no-retire freeze at
  `last_commit_cyc=62,720,377` with ROB head loads at `0x8000c840/0x8000c842`
  in OpenSBI `mtimer_event_start`.
- The first fresh root-cause candidate is LSU partial-flush owner mismatch.
  The LQ already keeps older entries across a partial flush, but the one-cycle
  LSU load metadata pipe still killed every in-flight load on any flush.  That
  can leave an older LQ entry marked `executed=1` with `has_result=0` and no
  live LMB/retry owner after timer interrupt or branch recovery traffic.  This
  exactly matches the latest no-retire dump: `lq_full=1`, LQ head `idx=14`,
  `rob=4`, `addr=0x8004e3f8`, `result=0`, while `lmb_any=0` and retry state
  is empty.
- A narrow RTL candidate now aligns the LSU load-pipe metadata with the LQ
  owner rule: full flush kills all in-flight endpoint state, while partial
  flush keeps older load-pipe metadata and kills only wrong-path younger
  owners.  This is a correctness fix, not a Linux benchmark tuning change.
- Validation status for this candidate is not yet signoff complete.  Verilator
  Linux elaboration passes after the patch, and a short interrupted smoke
  reaches the OpenSBI banner without the previous immediate active-region
  convergence abort.  DSim Linux rebuild is currently license-blocked
  (`maxLeases`), so the required DSim proof across the old 62.72M freeze and
  the DS/CM performance gate still must run before promotion.
- A 70M DSim confirmation attempt,
  `linux_boot_results/stage3_lsu_lmb_owner_retry_uart_probe_dsim_70m_20260521a`,
  was intentionally stopped during early OpenSBI because it was too slow to be
  useful for this debug turn. Do not use it as pass or fail evidence.

Remaining promotion gate:

- Rebuild with DSim when the lease is available.  The exact first proof should
  be a bounded Linux run with `+LINUX_STOP_ON_LOST_LOAD_OWNER`,
  `+LINUX_STOP_ON_NO_COMMIT`, and the old 62.72M freeze point as the minimum
  crossing target.
- Run a focused DSim Linux first-failure confirmation when runtime budget is
  acceptable, preferably with a shorter checkpoint or snapshot strategy instead
  of another blind 70M to 100M wait.
- The Linux debug gate passes only if retirement continues past the old
  `last_commit_cyc=62,720,377` freeze without a fresh UART `Oops`, `BUG`, or
  kernel panic.

### 2026-05-22 Load Completion Arbiter Repair

The latest current-tree long Linux evidence is still not a boot pass, but it
narrows the active blocker:

- After the issue-queue load-wakeup repair, a 3M DSim smoke passed and entered
  Linux S-mode, and the required Stage 3 DS/CM guard passed.
- The current-tree 100M and 65M DSim runs then both stopped at the same late
  owner-loss point: `LINUX_STOP_LOST_LOAD_OWNER` at cycle `62,720,645`, LQ
  head `idx=14`, ROB `4`, address `0x8004e3f8`, ROB head PC `0x8000c840` in
  OpenSBI `mtimer_event_start`.
- The same-cycle LQ result-fill cleanup passed the directed LSU probes and the
  DS/CM guard, but it reproduced the same `62,720,645` owner-loss signature.
  That proves the failure is not just a stale LQ-result timing window.
- A targeted DSim trace run was stopped at the early Linux window because it
  was too slow to reach the 62.72M-cycle reproduction point in this turn.

Static root cause:

- Port 0 records LQ execution at issue time. One cycle later, a D-cache hit
  must write the result to CDB/ROB and mark the LQ entry complete.
- Before this repair, the port-0 load writeback mux could prefer a pending AMO,
  LR, or SC writeback over a simultaneous port-0 D-cache hit without preserving
  that hit response. The LQ entry then remained `executed=1`, `has_result=0`,
  with no LMB, retry, or D-cache owner left. This matches the final Linux dump.
- The repair adds a real port-0 D-cache-hit skid in `lsu.sv`. If a hit response
  loses writeback arbitration, the LSU captures ROB, physical destination, LQ
  index, result data, and size, cancels the speculative wakeup for that load,
  and drains the held hit through the normal definitive load writeback path.
- AMO writeback is held until the older skid can drain, so the arbiter is
  lossless rather than priority-dropping one completion.

Validation completed for this slice:

- `git diff --check` and Python tool compile are clean.
- Verilator benchmark build passes with the backup-simulator policy: default
  convergence limit is `100`, and UNOPTFLAT is reported as a nonfatal warning
  so the backup simulator remains usable without hiding RTL convergence debt.
- DSim was attempted first for the focused probes, but the shared license was
  blocked with `Already at maxLeases (1)`.
- Verilator directed probes passed:
  `benchmark_results/stage3_p0_dcache_hit_skid_probe_verilator_20260522a`.
  `probe_lq_full_load_completion`, `probe_mtimer_head_load_pressure`, and
  `probe_mtimer_head_load_lq_full` all pass.
- Stage 3 DS/CM performance guard passed under the Verilator backup:
  `benchmark_results/stage3_rtl_guard_20260522_p0_dcache_hit_skid`.
  The hard metrics are DS100 `3.139802 DMIPS/MHz`, DS300
  `3.276072 DMIPS/MHz`, CM1 `6.605412 CoreMark/MHz`, and CM10
  `6.793229 CoreMark/MHz`, all above the 0.01% no-regression minima.
- Verilator Linux 3M smoke passed by timeout:
  `linux_boot_results/stage3_p0_dcache_hit_skid_verilator_3m_20260522a`.
  It reaches Linux S-mode with Sv48 enabled (`satp=9000000000080a05`) and no
  no-commit or lost-owner stop. This is a backup-simulator smoke only, not the
  62.72M-cycle DSim crossing proof.

Remaining proof:

- Rebuild and run DSim when the lease is available. DSim remains the primary
  Stage 3 simulator.
- The next DSim Linux run should target crossing the old `62,720,645` cycle
  lost-owner point with `+LINUX_STOP_ON_LOST_LOAD_OWNER`,
  `+LINUX_STOP_ON_NO_COMMIT`, and panic/Oops/BUG UART stops enabled.
- Only after that crossing is clean should the session resume the longer 100M
  Linux run.

### 2026-05-23 Port-1 Load Completion Skid Repair

The DSim primary simulator is available again, and the current Linux blocker
has moved from the earlier p0-only analysis to a more general load-completion
lossless-arbitration requirement.

Fresh DSim evidence:

- Commit baseline before this slice: `080d5d2`, `stage3: guard load queue
  result ownership`.
- Latest complete DSim Linux run:
  `linux_boot_results/stage3_100m_unblocked_dsim_20260522e_lq_owner_guard`.
- It stops on `LINUX_STOP_LOST_LOAD_OWNER` at cycle `62,720,645`, with LQ
  `idx=14`, ROB `4`, address `0x8004e3f8`, ROB head PCs
  `0x8000c840/0x8000c842`, `lq_count=32`, `lmb_any=0`, retry state empty,
  and no UART `Oops`, `BUG`, or kernel panic.
- The final LQ dump also shows a suspicious younger entry with
  `valid=1`, `addr_v=0`, `exec=0`, `result=1`, which reinforces that load
  completion ownership and result fill must be fully owner matched and
  lossless under pressure.

Static root cause:

- Port 0 already had a D-cache hit skid after the previous repair, so a hit
  response that loses writeback arbitration to AMO/LR/SC does not disappear.
- Port 1 still had no equivalent D-cache hit skid. A port-1 D-cache hit could
  be lower priority than an already registered port-1 misalign completion in
  the writeback mux. The LQ entry had already been marked executed, but the
  definitive result could be dropped without a retry, LMB, or hold owner.
- This is an ASIC-style structural bug, not a Linux-specific workaround: every
  executed load completion must either write back in that cycle or be owned by
  a registered completion state until it writes back.

RTL/TB change:

- `src/rtl/core/lsu/lsu.sv` now has a port-1 D-cache hit hold register that
  mirrors the port-0 skid behavior. It captures ROB index, destination physical
  register, LQ index, result data, and memory size when a port-1 D-cache hit
  loses writeback arbitration.
- Port-1 speculative load wakeup is cancelled when the hit is postponed into
  the skid, so dependent consumers do not observe a result before definitive
  load writeback.
- The port-1 SQ-forward hold drain check now treats port-1 D-cache hold,
  misalign hold, and direct D-cache hit as port-1 writeback owners, preventing
  local result drops between registered hold paths.
- `src/tb/tb_linux.sv` now recognizes p0 and p1 D-cache hold entries in the
  lost-load-owner checker and prints those hold states in the existing
  `LINUX_DEBUG_LOAD_HOLD` failure dump. This is testbench-only visibility.

Validation completed:

- `./build_dsim.sh` passes for the normal benchmark image.
- Directed DSim LSU probes pass in
  `benchmark_results/stage3_lsu_p1_dcache_skid_probes_dsim_20260522a`:
  `probe_lq_full_load_completion` `mcycle=787`,
  `probe_mtimer_head_load_pressure` `mcycle=283`, and
  `probe_mtimer_head_load_lq_full` `mcycle=798`.
- The hard Stage 3 DS/CM performance guard passes under DSim in
  `benchmark_results/stage3_rtl_guard_lsu_p1_dcache_skid_dsim_20260522a`.
  Metrics remain at the accepted baseline: DS100 `3.150055 DMIPS/MHz`,
  DS300 `3.218821 DMIPS/MHz`, CM1 `6.649025 CoreMark/MHz`, and CM10
  `6.851474 CoreMark/MHz`, all above the `0.01%` no-regression gate.
- `./build_dsim_linux.sh` passes for the Linux image after the TB checker
  update.

Pending Linux confirmation:

- A bounded DSim Linux smoke was started in
  `linux_boot_results/stage3_lsu_p1_dcache_skid_lost_owner_smoke_dsim_20260523a`
  with `+LINUX_STOP_ON_LOST_LOAD_OWNER` and `+LINUX_STOP_ON_NO_COMMIT`, but it
  was intentionally stopped during early OpenSBI because DSim had not reached
  the first 5M-cycle status interval after several minutes. Do not count this
  run as pass or fail evidence.
- The next Linux proof should still be scoped to cross the old `62,720,645`
  lost-owner point. It is not the full 50M or 100M clean-boot gate.
- If it crosses the old point without lost-owner/no-commit/panic, promote the
  Linux evidence for this slice and schedule the longer clean-log run
  separately.
- If it fails again at the same point, the new `LINUX_DEBUG_LOAD_HOLD` dump
  should identify whether a registered LSU completion owner is still missing
  or whether the remaining bug is inside LQ result lifetime/ROB owner matching.

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
  next FTQ owners. The clean-payload `timebase-frequency`, timer-vector,
  `bad_range+0xc`, and scheduler-atomic panic classes each have directed
  root-cause evidence and repaired RTL candidates with DS/CM guard coverage.
  The latest AMO/SC commit-precision repair passes the old scheduler panic
  window to 19M cycles and reaches `clocksource: riscv_clocksource`,
  `sched_clock`, and mount-cache setup without a kernel panic.
- v2 has reached the Linux `riscv_clocksource` console banner and scheduler
  setup in the latest path, but it does not yet reach the UART driver milestone,
  Linux-visible PLIC/external interrupts, or validated Linux timer behavior.
- v1 provides useful references for those pieces, but its `tohost`/HTIF-style
  completion should not be carried forward.

The next Stage 3 action is not to wait blindly. Rebuild the DSim Linux image
from the current worktree and capture the no-commit LQ/LMB dump for the
`mtimer_event_start` freeze. If a fresh UART-visible `Oops`, `BUG`, or panic
appears instead, use that exact run as the root-cause artifact. Do not add
debug logic to synthesizable core RTL. Any RTL change on that path must still
pass impacted compliance tests and the DS/CM hard guard before promotion.
Sv39 should stay as a directed-test subset, but the primary Linux path is
four-level Sv48 because that matches the intended Linux signoff configuration.

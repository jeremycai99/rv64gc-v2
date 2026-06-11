# Core Performance Lever Study II (2026-06-10)

Static RTL lever study, branch `backend/lq-instrument`, repo `/home/jeremycai/agent-workspace/rv64gc-v2`. Four study areas (FP subsystem, audit-backlog implementability, commit-width mechanics, dep-chain scheduling latency), each lever adversarially verified against the RTL. Baseline = honest 41-workload suite (shipping config: NWA + store no-bubble ON, FPU output-port fix, ER off). Suite floor: parser 0.60; FP laggards radix2 0.92 / st 0.89; low-integer cluster 1.05–1.66.

---

## 1. New RTL facts established (durable knowledge)

### FP execution subsystem
- **All FP ops are pinned to IQ2** at dispatch (`dispatch_queue.sv:261-263`), which is single-select (NUM_SELECT=1) and shared with FU_DIV, FU_CSR, and least-loaded-steered ALU traffic. **`IQ_FP_DEPTH=32` (`rv64gc_pkg.sv:65`) is a stillborn constant** — no FP issue queue exists anywhere in `src/`.
- **fpnew is fully combinational**: `PipeRegs='{default:0}`, FPNEW_SMOKE_IMPL (`fpu_fpnew_wrapper.sv:96-105`). ADDMUL/NONCOMP/CONV accept-and-complete same cycle; the limiter is NOT fpnew, it is the issue suppress chain.
- **FP cadence is hard-capped at 0.5 ops/cyc and every FP op burns 2 IQ2 slots**: `iq2_issue_suppress` (`rv64gc_core_top.sv:2409-2419`) blocks port 0 on both `fpu_req_valid_r` (occupancy) and `fpu_out_valid` (completion). The 1-deep request register adds +1 cycle to every FP op vs ALU3 (which executes comb-from-issue, `:2862-2869`).
- **FP-to-FP chain latency = 2 cyc/link** (req-reg +1, registered CDB wakeup +1); int ALU chains run 1 cyc/link. radix2 (0.92, ~0.32 FP ops/cyc) is below the 0.5 cap — it is latency/slot-bound, not cadence-bound.
- **FDIV/FSQRT**: PULP mvp, unpipelined, `Iteration_unit_num_S=2'b10` (3 bits/cyc): FP64 ≈ 22–24 cyc issue→CDB, FP32 ≈ 12–14. A second divsqrt-class op parks in the request register and **stalls ALL of IQ2 for ~20 cycles**. Max FP ops in flight in the whole subsystem = 2. Corrected iteration table for `2'b11`: FP64 19→**14** iterations (−5 cyc, ~22% cut), FP32 9→**7** (−2 cyc) — better than the proposal claimed.
- **P1 post-mortem (statically proven)**: with relaxed suppress, `fpu_out_valid` still fires every comb-completion cycle, so P1 never raised throughput or cut latency — a provable no-op for pure-FMA streams (matches bit-identical radix2/linalg A/B). The loops 1.63→0.98 collapse is attributed to div-shadow port monopolization but **was never root-caused** — hard gate before any suppress-chain rewrite. Lesson: fixes must remove FP from the shared port, never relax pacing on it.
- **Free resources in tree**: `fp_prf` write port [3] tied off (`:4432-4434`); the load_wb sideband (dedicated ROB completion + IQ wakeup lanes, PRF ports [4:5]) is a complete precedent for an FP writeback lane; fpnew `early_valid_o` unconnected. **PARALLEL DIVSQRT is NOT available** in this cvfpu copy (slice instance commented out, `fpnew_opgroup_fmt_slice.sv:149-179`).
- **Correctness trap for comb FP issue**: `fpnew_top.sv:82` in_ready tracks the rr_arb_tree grant — a divsqrt completing the same cycle a comb op is presented can droop in_ready and drop the op (435e8f5 wedge class). Any fall-through design needs the req-reg as not-accepted fallback.

### L2/dcache/LSU
- **L2 fill FSM wastes 2 req-channel cycles per back-to-back fill**: L2_IDLE registers `L2_FILL_REQ` without asserting `l2_req_valid` (`dcache.sv:739-741`); FILL_WAIT bounces through IDLE. Fill period = **10 cycles on an 8-cycle L2 hit** (verified cycle-exact). The WT drain at `:731-735` is the in-tree proof of the loop-safe comb-assert pattern. `fill_pend` clear is registered (`:1586`) — any FILL_WAIT chaining MUST mask `l2_active_mshr_q`.
- **LMB drain is port-0-only, lowest priority** (alloc is 2-wide; port-1 mux has no LMB arm, `lsu.sv:3680` comment). A fill waking N same-line loads drains 1/cycle, each requiring a p0-idle cycle. The discriminator counter **`lsu_lmb_wb_blocked_cnt` already exists on this branch** (`lsu.sv:3255-3256`) and prints under +PERF_PROFILE.
- **p1 fwd-hold runs at half duty**: capture only when hold empty + `p1_fwd_blocked` suppresses through the drain cycle (`lsu.sv:3647-3659, 1906-1927`) → back-to-back p1 forwards ≤ 1 per 2 cycles. Port 0 has capture-while-drain (full duty). No counter exists for `p1_fwd_blocked` (1-line add).

### Commit/ROB
- **Completion→commit-visible lag = 2 register stages** (FU result T → `cdb_valid_r` T+1 → ready_r read at T+2). Shipping WB bypasses cut it to 1 **only for slots 0/1 and only ALU/MUL/DIV/load** — branches, stores, CSR excluded everywhere; slot-2 logic is fully built but dead (`rob.sv:415-464` vs mux `:495-510`); slot 3 absent.
- **Mispredict tax with ER off**: commit-time flush pays the full 2-cycle visibility lag after BRU resolution (`branch_mispredict_r` written T+1, read T+2). Upper bound: slre 3.04%, tarfind 2.63%, picojpeg 1.41% of cycles.
- **Group-ender census** (`commit.sv:196-275`): correctly-predicted taken branches and stores do NOT end groups; no line/wrap term exists. Serializers cost ≥1 alignment + 1 solo cycle. Interrupt-pending zeroes the whole group.
- **Mid-band ~2.1 uniformity is NOT a commit-mechanics artifact** — cluster members span 3 orders of magnitude in mispredict density (crc32: 14 total) on the same commit hardware that sustains 3.23 elsewhere. It is the dep-chain completion rate (~2.1 ready-ops/cyc for -O2 integer mixes).
- **Counter traps**: `rob_slot2_*_wb_bypass_fire_cnt` are gated on slot-0-stalled (`rob.sv:1139`) — they measure the wrong conditional in both directions and cannot size the slot-2 lever. `rob_head_wb_bypass_branch_cnt` is structurally ~0 (its candidate requires `!wb_is_branch`). The 2026-06-09 audit inherited both errors.
- **Slot-2 wiring was already measured and REJECTED**: `doc/archive/stage2/stage2_frontend_optimization_target_2026-05-06.md:409` — DS/branch-hotspot unchanged, **CM regressed −0.6%** (plusarg all-slot ceiling: −1.8%). The audit and Study-2 both missed this.

### Scheduling latency (the model corrections)
- **ALU→ALU dep hop is already 1 cycle** — issue and execute are the same cycle; registered CDB wakeup costs zero dep-chain cycles vs any legal alternative. Any earlier broadcast is a structural comb loop (`rv64gc_core_top.sv:4265-4268`).
- **`MUL_LATENCY=3` is a dead constant** — the multiplier is 1-stage (`multiplier.sv:24-29`). Effective mul→use = **2 cycles uncontended**, +1 per cycle ALU2 wins CDB[2]; the 3-deep `mul_hold` FIFO has no backpressure and no wakeup of its own.
- **L1-hit load-use is 1 cycle**, not 2: dcache request fires comb at issue, hit response comb from S1, `load_wb_wk` comb wakeup at T+1. **Registered spec_wakeup (T+2) is strictly subsumed for hits** — miss-cancel bookkeeping only. Comments at `rv64gc_core_top.sv:4450-4456` and `rv64gc_pkg.sv:101-104` are stale. sglib pointer-chase hops are already 1 cycle.
- **rvb-multiply contains NO hardware mul** — software shift-add with a random-bit `beqz` (~50% taken, irreducible). It is mispredict-bound (~5–6 of ~7.3 cyc/iter), as are median/qsort. 1.05 is not a mul-latency datapoint.
- **Int rs3 datapath does not exist**: IQ storage/wakeup and rename translation are plumbed, but `decode_slice.sv:1011` sets rs3_valid only for FP and the only rs3 data read is from fp_prf. Any 3-source int uop costs a 13th int PRF read port (+1 full regfile copy) + bypass instance.
- **Fusion is intra-fetch-packet only** (instr_boundary/ibuffer, no re-packing); rvb-multiply's hammock permanently splits slot-3 | next-packet-slot-0 — structurally unfusable.

---

## 2. Lever table (ranked by verified gain/risk)

| # | Lever | Mechanism | Beneficiaries | Corrected gain | Scope | Verdict |
|---|-------|-----------|---------------|----------------|-------|---------|
| 1 | **Doc/model correction** | Fix dead MUL_LATENCY=3, stale T+2 load-bypass comments, spec_wakeup role; record per-workload bound attributions as hypotheses pending sweep | All future perf work | 0% IPC; prevents refuted-lever cycle #6 | Comments/doc only | **sound** |
| 2 | **L2-fill FSM dead-cycle removal** (A: IDLE comb-assert; B: FILL_WAIT chaining w/ `l2_active_mshr_q` mask) | Cut fill dispatch dead cycles; period 10→8 back-to-back | parser (floor), stream-l2 (B), spmv/qsort/sglib/huffbench marginal | parser **+2–3% (A only**; B ~0 at MLP≈1); stream-l2 0–3% (B); store cluster ~0 | ~27 lines, `dcache.sv` FSM only | **sound** |
| 3 | **Instrumentation batch** (commit-width histogram + corrected counters) | Sim-only counters: width histogram + frontier cross-tab, fixed slot-2/branch-lag counters, p1_fwd_blocked, mul camp, FP suppress partition, FDIV occupancy | All — decision gate for ~6 levers below | 0% direct; converts 6 levers to measured go/no-go in one pass | ~20–30 sim-only lines + 1 rebuild | **sound** |
| 4 | **L4: divsqrt iteration bump** (`Iteration_unit_num_S` 2'b10→2'b11) | FP64 div 19→14 iter (−5 cyc, ~22%), FP32 9→7; shrinks every second-div IQ2 stall window identically | cubic, minver, nnet, nbody | cubic +4–6%, minver +2–4% as **upper bounds** conditional on unmeasured div-share; radix2/st ~0 | 1 line, vendored cvfpu | needs-measurement (gate: FDIV occupancy from sweep; verify rounding vs 2'b10 oracle + 113/113) |
| 5 | **MUL completion sideband** (load_wb-style: 7th PRF write port, dedicated wakeup, delete mul_hold) | mul→use 2→1 cyc, contention-free; CDB[2] becomes ALU2-only | aha-mont64 primarily | mont64 **+8–13%** (chain 17→14 cyc, not 12→9); matmult-int/qrduino 0–3%; rest of cluster 0 | ~150–250 lines, 4 files | needs-measurement (gate: mul-edge critical-path share via `uoplife_critical_path.py` ≥ ~8%) |
| 6 | **Branch WB commit-bypass** (mispredict flush T+2→T+1) | Head-slot bypass + **full 4-field** forwarding (incl. `taken_target` — omission trains BTB to 0); must relax BOTH `!is_branch_r` and `!wb_is_branch` guards | slre, tarfind, picojpeg, CM, branchy low band | ~1–2% slre/tarfind, ~0.5–1% picojpeg/CM (derated: slots 0–1 only); **as literally specified: 0%, fixed-as-proposed: net negative** | ~40 lines `rob.sv` + synth slack check | needs-measurement (gate: new head-blocking-branch-lag counter ≥1% on ≥2 targets) |
| 7 | **L1: FP fall-through issue** (comb FP for non-divsqrt, req-reg as fallback) | FP 0.5→1.0/cyc, 2→1 cyc/link, 1 IQ2 slot/op; needs in_ready-droop fallback designed in | radix2, st, loops, nbody | radix2 **+15% to +85% spanning the unmeasured FP-critical fraction f** (speedup = 1/(1−f/2)); st similar | ~100 lines core_top; frequency-hostile (sim-only flag) | needs-measurement (gate: f via `uoplife_critical_path.py` ≥40–50%; hard gate: root-cause P1 loops collapse first) |
| 8 | **LMB port-1 drain arm** | Second LMB selector into p1 WB mux, won-the-mux clear discipline | parser, linalg, spmv, qsort | parser 0 to +1.5% unless `lsu_lmb_wb_blocked_cnt` ≥3% of cycles | ~30 lines `lsu.sv`; deadlock-class invariant | needs-measurement (gate: read existing counter from in-flight sweep — zero new sims) |
| 9 | **CDB[2] MUL-yield** (IQ1 issue_suppress) | Priority-inversion fix: camped MUL takes CDB[2], ALU slips 1 cyc | aha-mont64, CM, matmult-int, ud | mont64 0 to +2%, CM 0 to +1%; suite EV <1%. **As specified: comb-loop oscillator** (enq-bypass path); loop-safe variant ~5 lines | ~5 lines core_top | needs-measurement (gate: camp-cycle counters ≥0.5–1% on a beneficiary; subsumed by #5 if it ships) |
| 10 | **L2-lane: dedicated FP writeback** (fp_prf port [3] + ROB/IQ sideband) | FP completions off CDB[3]/IQ2 slot; **narrow** the suppress (pdst≥FP_PHYS_BASE), never delete it (int-dest FP ops + fpu_unsupported stay on CDB[3]) | loops?, FP+int mixes | radix2/st 0 to +15%; **loops sign unknown** (only adjacent measurement was −40%); needs fflags plumbing incl. head-merge | Medium, 4 files | needs-measurement (gate: FP-dest theft-with-work-waiting counter ≥3–5% of cycles) |
| 11 | **L3: activate FP issue queue** (full port separation; requires #10) | 4th scheduler, FP off IQ2; + IQ2-internal divsqrt class-gating | loops, minver; cubic via class-gating | L3-marginal: loops +0.1–0.3 IPC, minver similar; **radix2 ~0 per P1 A/B; st ~0 (chain-bound → that gain belongs to L1)**; headline numbers were stack-conflated | Largest; + int-PRF read-port hazard for i2f/fmv (unscoped) | needs-measurement (gate: 4-way cycle partition on radix2/loops; if div-parking dominates, ship class-gating mini-lever only) |
| — | ROB slot-2/3 WB-bypass wiring | 2-line head-read mux wire | mid/high band | **~0%, measured CM regression −0.6%** (Stage-2 archive); plusarg ceiling −1.8% | 2 lines | **refuted** (resurrection only via +ROB_COMMIT_WB_BYPASS ceiling A/B clearing noise AND no CM regression) |
| — | 3-input ADD fusion | CSA + rs3 int uop | md5sum, mont64 | md5sum +2–5% real, suite <0.5% vs +1 PRF copy + 13th bypass | Large, understated | **refuted** |
| — | Hammock if-conversion fusion | Predicated uop Tier 4 | multiply, median | multiply ~0–3% (**hammock structurally never intra-packet**); median ≤15% UB residual | Large | **refuted** as specified |
| — | Earlier/comb ALU wakeup | — | — | 0% — no removable cycle exists | n/a | **refuted** (re-skin of 0-cyc wakeup) |
| — | Comb-CDB ROB writeback | — | — | Net negative — structural comb loop via head-bypass→commit→flush→cdb_valid_live | n/a | **sound as anti-lever** — add to do-not-retry |
| — | FP anti-levers (PipeRegs>0, PARALLEL DIVSQRT, P1 re-enable, input FIFO w/o WB fix) | — | — | 0 or negative (P1: loops −40% measured) | n/a | **sound as anti-levers** |

---

## 3. Implementation queue (cheapest-confident first)

**Phase 0 — free, no sims, do immediately:**
1. **Doc/model correction** (#1): fix `rv64gc_pkg.sv:99` MUL comment, `rv64gc_core_top.sv:4450-4456` + `rv64gc_pkg.sv:101-104` bypass comments, CDB[2] mux "3-cycle" comment; record "every L1-hit dep hop is already 1 cycle" + the slot-2 Stage-2 rejection in project docs.
2. **Read the in-flight 41-workload +PERF_PROFILE sweep when it lands** (zero new sims):
   - `lsu_lmb_wb_blocked_cnt`/cycles on parser/linalg/spmv/qsort → go/no-go for #8 (kill if parser <1%, fund if ≥3%).
   - parser/stream-l2 miss density → confirms #2's operating point.
   - Per-type mispredict counts → confirms multiply/median/qsort mispredict attribution.

**Phase 1 — sound RTL, build now (gated only on sweep reads above):**
3. **L2-fill FSM sub-fix A** (#2) — ~15 lines, mirrors in-tree WT pattern; carries essentially all of parser's gain. Then **B** behind the same review with the mandatory `l2_active_mshr_q` mask. Gates: `scripts/lint_unoptflat.sh`, full bench, +WEDGE_DUMP boot.

**Phase 2 — one instrumentation rebuild + one +PERF_PROFILE pass (after the running sweep completes; experiment hygiene forbids mid-arm edits):**
4. **Instrumentation batch** (#3), all sim-only: commit-width histogram + frontier cross-tab (flush-terminated groups bucketed separately); slot-2 fire counters moved out of the `!ready_r[head_r]` guard; head-blocking-branch-lag counter (the structurally-zero `rob_head_wb_bypass_branch_cnt` cannot size #6); `p1_fwd_blocked` counter; mul camp counters (`alu2_issue && mul_valid_live`, `mul_hold_valid_r` cycles, `mul_enqueue_fresh`); FP cycle partition (suppressed-with-int-work-waiting / FP-bandwidth-bound / FP-chain-bound / divsqrt-parking) + FP-dest theft counter; FDIV/FSQRT occupancy. Same pass: run `tools/uoplife_critical_path.py` on radix2, st, aha-mont64 (FP-link fraction f; mul-edge share). Same pass, no rebuild: **+ROB_COMMIT_WB_BYPASS ceiling A/B** on sha/nettle/edn/linalg/vvadd + CM guard (the only slot-2 resurrection path).
5. **Root-cause the P1 loops 1.63→0.98 collapse** from the existing verilator_bench_p1 artifacts — hard gate for the entire FP campaign (#7, #10, #11).

**Phase 3 — measured RTL, in gated order:**
6. **L4 divsqrt bump** (#4) if FDIV occupancy ≥5% on cubic/minver/nnet: 1-line flip; gate with 113/113 + directed random div/sqrt cross-check vs the 2'b10 config as oracle; A/B cubic/minver/nnet/nbody.
7. **MUL sideband** (#5) if mont64 mul-edge critical-path share + camp share ≥ ~8%: full sideband, NOT the issue_suppress fallback (its age claim is wrong). If the gate fails but camp cycles ≥0.5–1%, consider the loop-safe **CDB[2] yield** (#9) instead.
8. **Branch WB commit-bypass** (#6) if the corrected counter shows ≥1% of cycles on ≥2 mid-band targets: implement with full 4-field forwarding, relax both guard sites, synth slack spot-check on the cdb_r→flush cone, compliance + boot + CM/DS exact.
9. **FP campaign** sequenced #10 (narrowed-guard writeback lane) → #7 (fall-through issue with in_ready fallback) → #11 decision, each gated on its Phase-2 counter and each A/B'd with **loops as the mandatory canary**, 113/113, cycle-exact CM/DS, ≤0.01% suite invariant. If divsqrt-parking dominates the partition, ship only the IQ2 class-gating mini-lever.
10. **LMB port-1 drain** (#8) last among memory levers — re-size after L2-FSM and the word-wide-strings parser binary, both of which shrink its share.

---

## 4. Refuted this round (do not re-chase)

- **Earlier/combinational ALU wakeup (any form, incl. broadcast-at-execute-start)** — ALU→ALU is already 1 cyc; execute-start IS issue; anything earlier is a structural comb loop. 0%.
- **ROB slot-2 WB-bypass wiring (+ slot-3 clone)** — already A/B'd and rejected in Stage 2 (CM −0.6%, all-slot plusarg −1.8%); the audit's 0.1–0.5% estimate rests on counters gated on the wrong conditional.
- **3-input ADD fusion** — md5sum has 1 fusable hop per 9-hop round (interleaved lw breaks the run), measured IPC contradicts chain-boundedness; mont64's add+sltu idiom ineligible; needs a 13th int PRF read port. Suite <0.5%.
- **Hammock if-conversion fusion (as specified)** — multiply's hammock permanently spans fetch packets (slot-3 | slot-0); the +80–150% headline can structurally never fire. Residual median-only variant is low-single-digit.
- **Comb-CDB ROB writeback** — structural comb loop (head-bypass→commit-scan→flush_out→cdb_valid_live), not merely an Fmax hazard; foregone gain <1% inside a 6.65–10.49% HEAD_WAIT budget. On the do-not-retry list.
- **fpnew PipeRegs>0 / PipeConfig** — strict sim-IPC loss under the unchanged 0.5/cyc cap.
- **PARALLEL DIVSQRT UnitType** — non-functional in this vendor copy (lane commented out, undriven outputs).
- **FPU_PIPELINED_ISSUE re-enable (P1)** — measured −40% on loops; statically a no-op for comb FP classes.
- **2-deep FP request FIFO without a writeback fix** — both real limiters (`fpu_out_valid` slot theft, CDB[3] ownership) untouched; P1's failure shape with more state.
- **"Mid-band ~2.1 is a commit-scan artifact"** — refuted by counter arithmetic across the cluster; it is dep-chain completion rate. Removing all incidental group-breakers cannot lift it.
- **"multiply 1.05 is a mul-latency datapoint"** — the binary contains no hardware mul in the hot loop; it is mispredict-bound on a random bit.
- **L1's headline as proposed (+50–85% radix2 unconditional)** — not refuted as a lever, but the operating point is unmeasured; quote +15–85% spanning f until `uoplife_critical_path.py` lands.

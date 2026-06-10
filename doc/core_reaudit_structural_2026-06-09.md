# Core Design Re-Audit — Structural Optimization Opportunities (2026-06-09)

Synthesis of 8 subsystem audits (25 findings; 24 unique — the same-set dual-load guard was found independently by lsu-load-path and dcache-l2). The 8 non-low findings received adversarial verification: **1 confirmed, 6 partial, 1 refuted**. Where the verifier contradicts the audit, the verifier's corrected numbers are used throughout. The 17 low/niche findings were not verified and are listed separately as audit-estimate backlog.

---

## 1. Executive summary

- **5 verified findings carry material residual value** after correction (FPU suppress, L2 FSM dead cycles, fetch line-straddle, dispatch int-FIFO HOL, checkpoint save port). **2 partials were corrected to do-not-pursue** (rename hold-buffer lockout ≤0.1%; one-shot partial-recovery window ~0.02% boot). **1 fully refuted** (WT-queue IDLE-only drain — measured `wt_full=0`).
- **Suite-integrity finding (verified fact, highest immediate value):** the **radix2 2.49 IPC datapoint is invalid** — the run TIMEOUT'd inside newlib `_malloc_r`'s free-list scan (39.5M iterations of a 5-insn integer loop = ~99% of commits; only 479K stores total); the FFT butterfly kernel **never executed**. It violates the standing finish-at-STOP discipline and the "FP-dep-chain-limited" row in `doc/dse_headroom_map_2026-06-07.md:128` is wrong.
- **Top 3 by impact × confidence:**
  1. **FPU request-register suppress** (`rv64gc_core_top.sv:2404-2413`) — mechanism confirmed exactly: hard 0.5 FP-arith/cyc cap. ~0% today, but it is the **mathematically certain post-NWA ceiling** for nnet/loops/linalg (IPC ≤ 0.5/FP-fraction ≈ 1.2–2.0) and binds at ~1.4 IPC on the real radix2 butterfly (+60–90% kernel-phase once the harness is fixed).
  2. **L1-side L2 FSM dead cycles** (`dcache.sv:683-724`) — confirmed 10-cycle period on an 8-cycle L2 hit; parser ~1–4%; the only verified bare-metal gain independent of the store campaign.
  3. **Mid-packet line-straddle 2-dead-cycle fetch bubble** (`instr_boundary.sv:133-173`) — cadence confirmed line-by-line; suite aggregate <1% (IBuffer absorbs most), but locally tens-of-% on an unluckily aligned fetch-bound hot loop. Counter-gate before fixing.

---

## 2. Verified findings (confirmed / partial only)

| # | Finding | file:line | Cadence defect (1 line) | Workloads + corrected gain | Fix scope | Priority |
|---|---------|-----------|--------------------------|----------------------------|-----------|----------|
| 1 | FPU req-register suppress half-duties FP lane | `rv64gc_core_top.sv:2404-2413, 2931-2952`; `fpu_fpnew_wrapper.sv:96-105` | FP op holds the 1-deep req register 2 cycles; bare `fpu_req_valid_r` in `iq2_issue_suppress` kills all IQ2 issue on the drain cycle → hard 0.5 FP-arith/cyc into a **combinational** fpnew | Today ~0% (verified); **latent**: post-NWA ceiling for nnet/loops/linalg (≤0.5/FP-frac ≈ 1.2–2.0 IPC); real radix2 kernel +60–90% phase | ~5-line suppress rewrite (gate FP on `fpu_req_valid_r && !fpu_ready`); **correctness-sensitive** — full RV64F/D compliance rerun (FP-bypass/flush-deadlock history) | **P1** — must land before post-NWA FP-trio results are read |
| 2 | L2 FSM: 2 dead req-channel cycles per fill | `dcache.sv:683-697, 709-716, 718-724` | IDLE decides but asserts `l2_req_valid` one cycle later; resp bounces FILL_WAIT→IDLE→FILL_REQ → 10-cyc period per 8-cyc L2 hit; +1 cyc per isolated miss | parser ~1–4% (upper end only if fills dense); store cluster 0–0.5% (**measured** L2-latency-insensitive); rest ~0 | FSM-only: comb-assert from IDLE (mirrors proven WT pattern) + FILL_WAIT chaining; must exclude just-completed MSHR (registered `fill_pend` clear) and keep WT priority | **P2** |
| 3 | Mid-packet 32-bit line-straddle: 2 dead fetch cycles | `instr_boundary.sv:133-173`; `pred_checker.sv:523-531`; `ifu.sv:396-426`; `ifu_duplicate_guard.sv:79-85` | Straddle kills same-owner advance → 1 duplicate-suppressed re-extract cycle + 1 separate straddle-advance cycle before the next-line req even fires (aligned variant pays 1) | Suite aggregate <1%: sha 0–2%, DS/zip/CM/boot 0–1.5%, store cluster ~0; locally tens-of-% per affected loop | Emit + straddle-advance same cycle (remainder already latched); new advance must gate on `will_emit`, preserve straddle+taken-branch terminal | **P3** — add 1-line occurrence counter first; fix only if a hot workload shows recurring hits |
| 4 | Dispatch int-FIFO HOL behind full IQ2 (int-side only) | `dispatch_queue.sv:252-327`; `rv64gc_core_top.sv:2404-2413` | First unroutable FP op at int-FIFO head stops ALL younger ALU/BRU dispatch while IQ2 (drained ~1/FPU-latency) is full; loads/stores still dispatch 2+2 (audit's mem-demotion claim wrong in those episodes) | nnet/loops/linalg **0–3%, doubly conditional** (post-NWA *and* post-#1; FPU serialization is the first-order binder); mem-side skip ~0% — do not build; CM/DS/sha/zip nil | Bounded skip-ahead N=2 at int dequeue (correctness-safe: rob/lq/sq idx pre-allocated) — real timing cost (per-cycle compaction mux); group-aware `full` cheap | **P4** — sim counter (head=FP && `iq_full[2]`) first; only after NWA + #1 |
| 5 | Single-ported checkpoint save | `rename.sv:503-553`; `rat.sv:158-176`; `checkpoint.sv:91-98` | Only surviving trigger: NT-cond + predicted-TAKEN-cond in one ≤4-insn packet → one 1-wide hold cycle (taken branch is packet-last, so no younger-insn blocking; NT/NT case already split at fetch) | CM/DS ≤0.5% (likely 0.1–0.3%, hot loops are load-use bound); rest ~0 | Degrade-to-no-checkpoint — provably free on bare-metal (ckpt restore is VM-gated and never fires there; commit mispredict recovery is already a checkpoint-free full flush) | **P5** — gate on `stall_ckpt_cnt` − `ckpt_save_block_full_cnt` readout |
| 6 | Rename hold-buffer lockout | `rename.sv:440, 947-948, 1011-1018` | Mechanism confirmed (drain cycle narrows to tail width), but measured precondition rate ~0.007% of CM cycles; store cluster structurally nil (in-order rename can't bypass the held store; ack-rate-bound) | ≤0.1% branchy set; ~0% store cluster now and post-NWA | Multi-source partial-accept handshake; reopens the exact lost-insn bug class commit 3e58a93 fixed | **Do not pursue** |
| 7 | One-shot partial-recovery window (boot) | `rv64gc_core_top.sv:3120-3131, 983-998` | Mechanism confirmed, magnitude refuted ~2 orders: 43 reject-rename events / 16M cycles (0.13% of opportunities, not O(10%)) | ~0.01–0.02% boot; 0% benchmarks (VM gate) | Pending-recovery register; proposed hijack gate unsound as written (needs age compare) | **Do not pursue.** Adjacent measured lever in same subsystem: checkpoint *coverage* (1405/24323 quarantine runs strand with no checkpoint ≈ 0.4% boot upper bound) |

### Unverified backlog (audit estimates only — never adversarially checked; all low/niche)

- **commit-rob:** slot-2 WB-bypass dead logic (`rob.sv:412-510`; 2-line wire, 0.1–0.5% on the 5 width-bound benches — cheapest fix-per-risk in the whole audit, size via STAT_DUMP first); MSTATUS/SSTATUS SIE-toggle full flush (`commit.sv:284-301`; boot 1–3%); branch exclusion from commit WB bypass (≤0.3%; free counter `rob_head_wb_bypass_branch_cnt` decides).
- **issue-execute:** CDB[2] MUL-broadcast starvation by ALU2 (`rv64gc_core_top.sv:3959-4074`; CM 0.5–2%; ~3-line `issue_suppress` yield); IQ2 select-then-suppress CSR/DIV port lock (boot ~1%).
- **lsu-load:** port-1 fwd-hold half-duty (`lsu.sv:3593, 1933-1935`; store cluster 0.5–2%); load port 1 disabled under VM (`lsu.sv:406-410`; boot 1–3%, counter exists); LMB 1-wide port-0-only lowest-priority drain (`lsu.sv:3359-3379, 1590-1593`; parser/linalg 1–3%); same-set dual-load guard stale (`lsu.sv:1661-1675`; niche, `sim_p1_conf_diff_line_cnt` decides — single fix covers the duplicate dcache-l2 finding).
- **lsu-store-csb (all boot-only niche):** swallowed store ack in AMO pre-commit window (`lsu.sv:2178-2179`; duplicate idempotent L1/L2 writes — one-line-class hygiene fix); single dTLB port STA vs load0 (~1% boot); AMO full-CSB-drain serialization (`lsu.sv:1594-1608`; <1–2% boot).
- **dcache:** fill/NWA install blanket-blocks unrelated-line store in S1 (`dcache.sv:945-1032`; store cluster 0.5–2% — **fold into campaign**, see §5).
- **fetch:** single-pred-ctl packet splits (low, CM 0.5–1.5%); redirect cycle wasted, first packet at R+2 (niche, boot 1–2%).
- **branch-recovery:** E+1 double-redirect voids the early redirect's F0 head start (+1 cyc/recovery, ~0.5–1% boot; also identifies why the +SUPPRESS_REDUNDANT A/B failed — GHR/RAS restore was left ungated — worth re-running that arm correctly).

**Correctness watch-list (not perf):** `mul_hold` FIFO entries are never filtered on partial flush (only full-flush reset, `rv64gc_core_top.sv:4016`) — stale-pdst broadcast risk now that early-redirect is ON; needs a directed look independent of any perf work.

---

## 3. Refuted claims (do not re-chase)

1. **WT queue IDLE-only drain freezes store acks** — measured `sim_store_wt_full_cyc=0`, `wt_occ_max=2` on linear_alg (the claim's own worst case); tail-merge + write-allocate hold paths prevent fill-up; ~0% now. Re-check only at NWA ENABLE=1 (already open question #7).
2. **radix2 +5–15% today from the FPU fix** — the 2.49 datapoint is a TIMEOUT/malloc artifact; the FFT kernel never ran.
3. **"IQ2 issues nothing for an entire fdiv"** — lone fdiv is accepted in 1 cycle (divsqrt `in_ready` when IDLE); only back-to-back divsqrt camps.
4. **Hold-buffer lockout at medium impact** — 14 stalled slot-cycles per ~200K CM cycles; hold never engaged; store-cluster benefit structurally nil.
5. **`dq_full` as a partial-advance/hold trigger** — group-wide bit; cannot create a hold episode.
6. **NT/NT two-branch rename groups exercising the checkpoint port** — split at fetch (`pred_checker.sv:453-468`); unrecoverable at rename.
7. **Mem-FIFO credit skip-ahead (incl. cjpeg gain)** — SQ addr-unknown conservatism re-serializes the skipped load behind the same store; ~0% everywhere.
8. **L2 FSM fix helping the store cluster 1–4%** — contradicted by measured L2-latency insensitivity; 0–0.5%.
9. **One-shot partial-recovery rejects at O(10%)** — measured 43/33,577 = 0.13%; ≤0.02% boot cycles.
10. **Recovery-hijack window as a real hazard** — fires only inside already-stranded windows; commit full flush backstops; perf-neutral, not a correctness bug.

---

## 4. Subsystems declared clean

**No audit returned `clean: true`** — all 8 reported findings. Explicitly **verified-clean sub-areas** (branch-recovery audit): commit-flush path is fully combinational same-cycle (`commit.sv:264-268, 379-398`); RAT/free-list/ROB/FTQ restores are all 1-cycle broadside (`rat.sv:105-124`, `free_list.sv:271-281`, `rob.sv:682-714`, `ftq.sv:150, 367-375`); checkpoint capacity (64) never binds.

---

## 5. Integration with the active store-engine campaign (NWA in flight; S1-bubble + dual store-commit port planned)

**Stacks (gains only realized together with the campaign):**
- **FPU suppress (#1)** — the FP trio's post-store-fix ceiling. If NWA lands first, its FP-trio gains will read artificially low against the 0.5 FP/cyc wall. Land #1 (or at minimum its counter) before the post-NWA measurement pass.
- **Dispatch int-FIFO HOL (#4)** — same benches, only visible after SQ-full relief *and* #1.
- **Port-1 fwd-hold half-duty (backlog)** — forwarding-heavy store cluster; size post-campaign.

**Competes for the same RTL window (fold into the campaign's edits, don't ship separately):**
- **Fill/NWA-install blanket store block** (`dcache.sv:945-1032`) — same S1 write mux and `store_produces_wt`/`nwa_validate_avail` terms the S1-bubble fix and NWA install path are already rewriting; narrowing the blanket `!fill_done_avail/!nwa_validate_avail` to same-line belongs inside that edit.
- **Swallowed AMO-window ack** (`lsu.sv:2178-2179`) — `csb_deq_ack` steering is the same ack path the dual store-commit port rewires; fix the keying (`amo_store_req_valid` not `amo_store_valid_r`) in that change.
- **WT-queue FILL_WAIT drain** — refuted today; re-measure `wt_occ_max` at NWA ENABLE=1 (open Q#7) before funding.

**Orthogonal (no file/mux overlap):** L2 FSM (#2, fill request channel), line-straddle (#3, fetch), ROB slot-2 wiring (commit), all boot-only items (CSR flush, redirect cycle, dTLB ports, AMO serialization, E+1 double-redirect).

---

## 6. Recommended insertion order (steps 2–5; step 1 = in-flight NWA + S1-bubble + dual-port)

| Step | Action | Justification (measured impact / RTL risk) |
|------|--------|--------------------------------------------|
| **2** | **Fix the radix2 harness** (malloc pathology) and re-run to STOP | Zero RTL risk; restores an invalid suite datapoint and the headroom map; mandatory falsifier for step 3; enforces the finish-at-STOP discipline |
| **3** | **FPU suppress rewrite (#1)** + RV64F/D compliance rerun | ~5-line edit but correctness-sensitive (FP history); gates correct interpretation of step-1's FP-trio results; certain latent ceiling (0.5 FP/cyc) + radix2 kernel +60–90% phase once step 2 lands |
| **4** | **L2 FSM dead-cycle removal (#2)** with MSHR-exclusion guard | FSM-only, no datapath, low risk; parser ~1–4% — the only verified bare-metal gain independent of the store campaign; zero file overlap with step 1 |
| **5** | **Instrumentation batch, one PERF_PROFILE/STAT_DUMP pass** (all 1-line/free): straddle occurrence counter (#3), dispatch-HOL counter (#4), `stall_ckpt_cnt`−`ckpt_save_block_full_cnt` (#5), `rob_head_wb_bypass_branch_cnt`, LOAD1-TLB-WAIT, `sim_p1_conf_diff_line_cnt`, sstatus-write frequency | Near-zero risk, converts every remaining counter-gated candidate into a measured go/no-go; promote only material hits. ROB slot-2 wiring (2 lines) rides along immediately if its STAT_DUMP sizing is non-trivial |

Standing invariants apply to every step: CM/DS must finish at STOP before any IPC claim; ≤0.01% benchmark no-regression for any boot-affecting change; paged-boot +WEDGE_DUMP clean for anything touching flush/redirect/store-ack paths.

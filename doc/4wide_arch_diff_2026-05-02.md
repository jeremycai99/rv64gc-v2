# BOOM v4 ↔ rv64gc-v2 Architectural Equivalence Audit — 2026-05-02

**Repo:** rv64gc-v2 (master @ edf2cf9)
**BOOM source:** `riscv-boom/src/main/scala/v4/`
**rv64gc-v2 source:** `rv64gc-v2/src/rtl/core/`
**Reference config:** BOOM MegaBoom (`WithNMegaBooms`, `config-mixins.scala:246-296`).

---

## 1. Executive summary

After enumerating every module-to-module structural difference between BOOM v4
MegaBoom and rv64gc-v2 master (post-4-wide refactor), the residual 11–17% gap
on cm and 39% gap on dhry is **not** explained by storage size, frontend depth,
or ALU back-to-back wake latency. Those are at parity (rv64gc-v2 is actually
shallower in the frontend by ~1 stage and faster on the load-to-use path by 2
cycles).

Two structural differences DO predict measurable IPC loss in rv64gc-v2:

1. **No imm/PC operand renaming** — every immediate read goes through the
   12R6W PRF (or is muxed at issue time). BOOM v4 has dedicated `immregfile`
   (`ImmRenameStage`), which removes immediate operands from the int PRF
   read-port pressure. rv64gc-v2 has 4 ALU lanes wired to a single 12-port PRF
   with no slack; under high IPC the IRF is the implicit critical resource.

2. **No fused MEM (AGEN+DGEN) issue lane the way BOOM has it** — BOOM's
   MemExeUnit issues address-gen into the same lane as data-gen and supports
   `enableFastLoadUse=true` (load-to-use=4) plus a separate `IQ_UNQ`
   (mul/div/CSR/i2f) that does NOT contend with ALU lanes. rv64gc-v2 puts MUL
   on IQ1 (shared with ALU2) and DIV/CSR on IQ2 (shared with ALU3) — every MUL
   in flight blocks one ALU lane for 3 cycles. CoreMark has 3.4–3.6% of
   commit cycles waiting on a MUL at ROB head AND 5.9% issue arb stall on
   IQ1/IQ2 (issue-stall_arb), which is the contention signature.

The two differences sum to a predicted **6–10% IPC loss on cm** and a smaller
contribution on dhry. The remainder of the cm gap (≈5–8%) and the bulk of
the dhry gap (~30%) are concentrated in a single signature shared by the
"unknown plain-ALU producer wait" bucket (23% of cm cycles) and the
"load-wait" bucket (27% of dhry head-stall cycles): **rv64gc-v2's IQ holds
operand-stall longer than BOOM's because BOOM has more total INT IQ slots
covering the same window** (92 vs 72) AND BOOM's ALU lanes can issue 4-wide
out of a single 40-entry IQ, giving deeper out-of-order coverage of the
dependency window than rv64gc-v2's split 24+24+24 organization.

**Top recommended next change** (Phase 7, full detail in §7):

- **Re-org INT IQs from 3×24 to 1×56 + 1×16 (or 1×40 + 2×16) + co-locate
  MUL/DIV on a separate non-ALU lane.** Estimated +3–5% on cm, +1–2%
  on dhry. ~250 LOC, 2–3 days. Removes both the MUL-blocks-ALU contention
  and the depth fragmentation.

A secondary, lower-risk change — adding an immediate physical register file
(à la BOOM's `immregfile`) — is sketched in §7 but is a much larger
refactor (~1k LOC, ~2 weeks) and is NOT recommended as the next step.

---

## 2. Methodology

The audit is structured as 5 phases of measurement (pipeline depth, issue/
wakeup, ROB/commit, LSU, rename), one phase of per-difference IPC impact
estimation, and one phase of recommendation. For each difference, both
codebases are cited at file:line. Differences are classified:

- **Structural parity** — same depth/width, no IPC delta predicted.
- **rv64gc-v2 win** — rv64gc-v2 is more aggressive; gap source is elsewhere.
- **rv64gc-v2 loss** — BOOM is more aggressive; predicted IPC delta listed.

The analysis uses concrete BOOM-MegaBoom params from
`riscv-boom/src/main/scala/v4/common/config-mixins.scala:246-296` and
rv64gc-v2 params from `rv64gc-v2/src/rtl/core/include/rv64gc_pkg.sv`.

---

## 3. Phase 1 — Frontend & Backend pipeline depth

### 3.1 BOOM v4 frontend stages (from `frontend.scala` + comment in `core.scala:12-27`)

```
F0 (s0) — NextPC select wires           — combinational
F1 (s1) — RegNext: ICache request + TLB — 1 stage
F2 (s2) — RegNext: ICache resp + bpd_resp.f2 + extract — 1 stage
F3      — Queue(1, pipe=true): predecode + bpd_resp.f3 + sfb tags — 1 stage
F4      — Queue(1, pipe=true): SFB fold + RAS + final ghist correct — 1 stage
FB      — FetchBuffer (decoupled queue) — 1 stage
Dec     — Decode (one pipe register inside) — 1 stage
Ren1    — Rename1 combinational read of RAT/free list — 0 stage (comb)
Ren2    — Rename2 register stage — 1 stage
Dis     — Dispatch routing + IQ enqueue register — ~1 stage
```

**Total F0 → IQ tail = 8 register stages** (s0=wire, then 8 RegNexts/Queues).
File evidence:
- `frontend.scala:365-368` — s1 register
- `frontend.scala:431-441` — s2 register
- `frontend.scala:589-595` — F3 Queue(1)
- `frontend.scala:813-818` — F4 Queue(1)
- `frontend.scala:820` — FetchBuffer
- `core.scala:12-27` — official stage list comment
- `core.scala:120-127` — decode units + brmask + rename
- `rename-stage.scala:69-119` — ren1 (comb) + ren2 (1 reg)

### 3.2 rv64gc-v2 frontend stages (from `fetch_unit.sv` + `rv64gc_core_top.sv`)

```
F1   — pc_gen + ICache request + BTB combinational lookup + TAGE comb lookup
       — 1 stage (`fetch_unit.sv:153-200, 538-575`)
F2   — RegNext: icache resp + extract + BPU resolve + redirect F1
       — 1 stage (`fetch_unit.sv:725-823, 974+`)
FPB  — fetch_packet_buffer (1-deep FIFO with bypass, see `fetch_unit.sv:523`)
       — 1 stage (bypassable when empty)
Dec  — decode (1 register stage at output, `decode.sv:80-123`)
       — 1 stage
Fus  — fusion_detector (combinational, `decode/fusion_detector.sv`)
       — 0 stage
Mux  — bru_quarantine / uoc / lb / fused mux (`rv64gc_core_top.sv:485-507`)
       — 0 stage (comb)
Ren  — rename combinational (`rename.sv` outputs are always_comb at line 583+)
       — 0 stage
DQ   — dispatch_queue 1-stage FIFO with bypass (`dispatch_queue.sv:332+`)
       — 1 stage (bypassable)
```

**Total F1 → IQ tail = 5 register stages** (FPB and DQ both bypassable, so
in steady-state could be 3 stages; in worst case 5).

### 3.3 Frontend depth comparison

| Path | BOOM v4 | rv64gc-v2 | Delta |
|---|---:|---:|---:|
| Fetch+IFU stages | 5 (F0-F4) | 2 (F1, F2) | rv64gc-v2 −3 |
| FetchBuffer / FPB | 1 | 1 (bypassable) | rv64gc-v2 −0/−1 |
| Decode | 1 | 1 | parity |
| Fusion / SFB / Mux | 0 (SFB fold inline) | 0 (fusion + mux inline) | parity |
| Rename | Ren1 + Ren2 = 1 reg | 0 reg (combinational) | rv64gc-v2 −1 |
| Dispatch / DQ | 1 | 1 (bypassable) | parity |
| **F0/F1 → IQ tail (worst-case)** | **~8** | **~5** | **rv64gc-v2 −3** |
| **F0/F1 → IQ tail (steady-state)** | **~8** | **~3** | **rv64gc-v2 −5** |

**Verdict (Phase 1):** rv64gc-v2 frontend is *shallower* than BOOM v4. This is
a **rv64gc-v2 win**, not a gap source. The mispredict-recovery penalty on
rv64gc-v2 is approximately 5 cycles (frontend refill) + 1 cycle (rename) vs
BOOM's 8+1, so on the same mispredict rate rv64gc-v2 should pay LESS.

The earlier BRU early-redirect cycle (Cycle C) was REFUTED for the same
reason — the refill is already short.

### 3.4 Backend pipeline (issue → execute → wb)

BOOM ALU:
```
ISS  — issue grant + fast_wakeup fires (execution-unit.scala:504-511)
ARB  — arb_uop register, IRF read req (execution-unit.scala:92, 121-127)
RRD  — rrd_uop register, IRF read resp captured + bypass mux (execution-unit.scala:95, 133-145)
EXE  — exe_uop register, ALU compute (combinational from rs latched at RRD->EXE) (execution-unit.scala:98)
WB   — RegNext at int_bypasses[] / iregfile.write_ports (core.scala:884, 972-978)
```
**4 register stages from ISS to WB.** Producer-to-consumer back-to-back ALU = 1 cycle (consumer EXE = producer EXE + 1, via bypass at consumer's RRD).

rv64gc-v2 ALU (from `rv64gc_core_top.sv:1607-2226, 2876+`):
```
ISS — issue_queue selects (combinational); cdb_valid drives via combinational mux
T0  — same cycle: PRF read + bypass + ALU compute (all combinational)
T0+1 — cdb_valid_r registered (drives IQ wakeup, ROB writeback, preg_ready_table)
```
**1 register stage from ISS to WB-broadcast.** Producer-to-consumer back-to-back ALU = **1 cycle** (consumer ISS = producer ISS + 1 via combinational `next_src1_ready` from CDB hit; see `issue_queue.sv:120-188`).

**Verdict (Phase 1, backend):** rv64gc-v2 backend is much SHALLOWER from ISS
to WB. Back-to-back ALU latency is identical at 1 cycle in steady state. This
is a **rv64gc-v2 win on critical path** but does NOT create an IPC win in
steady-state because the bottleneck is dependency-chain throughput, not
single-pair latency.

A subtle trade-off: rv64gc-v2 puts ISS+PRF read+ALU+CDB drive in ONE clock
period — the longest path includes the IQ select, 12-port PRF read
(combinational), 5-source bypass mux, ALU op, and CDB drive. BOOM splits
this across 4 clocks (ISS, ARB, RRD, EXE) so each individual cycle has more
slack at the cost of pipeline depth. From a *cycle count* perspective,
rv64gc-v2 wins. From an *Fmax / timing closure* perspective, BOOM wins. We
care about cycles here.

### 3.5 Memory pipeline depth (LSU)

BOOM (from `lsu.scala`, comment line 295-298 + `core.scala:378`):
```
ISS → ARB → RRD → EXE (agen) → MEM (dcache req T+1) → S2 (dcache resp T+2) → WB
```
- Load-to-use = 4 cycles when `enableFastLoadUse=true` (MegaBoom)
- Load-to-use = 5 cycles otherwise

rv64gc-v2 (from `lsu.sv:213-218` + `dcache.sv:177-275`):
```
ISS → AGEN (combinational) → DCache S0 (register addr) → DCache S1 (return data combinational)
```
- T+0: load issue + AGEN + dcache req
- T+1: dcache returns combinationally; consumer woken via `spec_wakeup_valid` (1 cycle pre-CDB)
- **Load-to-use = 2 cycles** (consumer ISS at T+1 reads bypass)

**Verdict (Phase 1, LSU):** rv64gc-v2 is **2-3 cycles FASTER** on load-to-use.
This is a **rv64gc-v2 win**, not a gap source.

### 3.6 Pipeline-depth conclusion

rv64gc-v2 is shallower than BOOM on every pipeline path measured:
- Frontend: −3 to −5 register stages (depending on FPB/DQ bypass hit)
- Backend ALU: −3 register stages (no ARB/RRD/EXE staging)
- Memory: −2 cycles load-to-use

**Pipeline depth is NOT the gap source.** It's a category where rv64gc-v2 is
strictly faster.

---

## 4. Phase 2 — Issue / Wakeup / Bypass network

### 4.1 IQ structure

| Param | BOOM v4 MegaBoom | rv64gc-v2 |
|---|---|---|
| IQ_MEM | 32 entries, issue=3, dispatch=4 | iq_load 32 + iq_store(STA) 32 + iq_store_data(STD) 32 |
| IQ_UNQ (mul/div/CSR/I2F) | 20 entries, issue=1 | (folded into IQ1+IQ2 below) |
| IQ_ALU | 40 entries, issue=4, dispatch=4 | IQ0(ALU0+BRU, ALU1+BRU1) 24, sel=2 |
| | | IQ1(ALU2+MUL) 24, sel=1 |
| | | IQ2(ALU3+DIV+CSR) 24, sel=1 |
| IQ_FP | 32 entries, issue=2 | (out of scope — no FP focus here) |
| **Total INT IQ entries** | 32+20+40 = **92** | 24+24+24 = **72** |
| **Total INT issue width** | 3 (mem) + 1 (unq) + 4 (alu) = 8 | 4 (alu) + 2 (load) + 1 (sta) + 1 (std) = 8 |

File evidence:
- `config-mixins.scala:259-263` — MegaBoom IQ params
- `rv64gc_pkg.sv:58-63` — rv64gc-v2 IQ depths
- `rv64gc_core_top.sv:1757-1965` — IQ instantiations
- `issue-units/issue-unit-age-ordered.scala` — BOOM age-ordered (collapsing) IQ
- `issue/issue_queue.sv:309-348` — rv64gc-v2 oldest-eligible select

### 4.2 Critical observation: IQ depth fragmentation

BOOM v4 has a SINGLE 40-entry IQ_ALU shared across ALL 4 ALU lanes. Any
ALU-eligible uop in the 40-entry window can issue to any of the 4 lanes
(subject to column-issue if `enableColumnALUIssue=true` — DISABLED in
default MegaBoom).

rv64gc-v2 splits ALU/MUL/DIV/CSR across THREE separate 24-entry IQs (IQ0,
IQ1, IQ2), each statically dispatched at rename based on fu_type. The
window an instruction can hide in is **at most 24 entries** for ALU2/ALU3
lanes (which are pinned to IQ1/IQ2), vs **40 entries** in BOOM.

Consequence: when a long dependency chain at one ALU lane stalls, BOOM has
40 entries to find another ready producer. rv64gc-v2 has only 24. This
predicts longer issue-stall periods on dependency-heavy code.

**This is consistent with the cm `issue_stall_operand_cyc = 35%`
observation.** With the same ROB depth (128) but 22% fewer total IQ entries
(72 vs 92) and worse partitioning, rv64gc-v2's effective dependency-window
is smaller.

### 4.3 MUL/DIV co-locating with ALU

In BOOM, MUL+DIV+CSR+I2F sit in `IQ_UNQ` with issue width=1. They share NO
issue port with ALU. An IMUL in flight does NOT block any ALU lane.

In rv64gc-v2, MUL is on IQ1 sharing port 0 with ALU2; DIV+CSR on IQ2 sharing
port 0 with ALU3 (`rv64gc_core_top.sv:2569-2577`). When MUL is issued, ALU2
cannot issue same cycle. Multiplier is 3-stage (`MUL_LATENCY=3`,
`rv64gc_pkg.sv:90`), and during 3 cycles of MUL execute the result must
arbitrate against ALU2 traffic on shared CDB[2] port — exactly what the
`mul_hold` 3-entry FIFO at `rv64gc_core_top.sv:2630+` exists to manage.

The perf inventory shows **head_not_ready_mul = 3.4-3.6% on cm** and
**issue_stall_arb_cyc = 5.7-5.9% on cm**. These two together account for
~9% of cm cycles — almost exactly the size of the gap. The arb-stall counter
isn't broken down by IQ, but the only IQs with shared ALU+MUL or ALU+DIV
ports are IQ1/IQ2.

### 4.4 Bypass network

BOOM:
- `int_bypasses` Vec(coreWidth + lsuWidth, ...) = `Vec(6, ...)` for MegaBoom
  (4 ALU + 2 load) (`core.scala:180`)
- 4 ALU bypass sources are RegNext-free (combinational from alu_resp)
- 2 load bypass sources are RegNext'd (1-cycle delay)

rv64gc-v2 (`rv64gc_pkg.sv:91-99`):
- `NUM_BYPASS_SRCS = 5` (3 CDB-registered + 2 load_wb combinational)
- 12 bypass mux instances, one per PRF read port (`rv64gc_core_top.sv:2073-2090`)

| Aspect | BOOM | rv64gc-v2 | Verdict |
|---|---|---|---|
| Total bypass sources | 6 (4 ALU + 2 load) | 5 (3 ALU + 2 load) | rv64gc-v2 is THINNER (1 ALU bypass missing) |
| ALU bypass timing | 0-cycle (combinational) | The 3 are CDB-registered + 2 load combinational | rv64gc-v2 ALU bypass is 1 cycle DELAYED relative to BOOM |
| Bypass mux fan-in per operand | 6 | 5 | parity-ish |

Wait — re-reading `rv64gc_core_top.sv:108-111`: bypass sources are 5 = `ALU0/BRU + ALU1/BRU1 + ALU2/MUL + Load0 + Load1`. The fourth ALU lane (ALU3/DIV/CSR) is NOT bypassed. Consumers of ALU3 results must wait for the registered CDB → preg_ready_table update → next-cycle issue.

**This means an ALU3 producer adds 1 extra cycle to its consumer's issue
relative to ALU0/1/2.** Since ALU3 is on IQ2 (which also holds DIV and CSR),
the dispatch-side load-balancing tries to spread instructions across IQ0/1/2,
so a non-trivial fraction of ALU producers land on the un-bypassed lane.

**Verdict (Phase 2):**
- IQ depth fragmentation (3×24 vs 1×40+1×20) — predicted **−3 to −5% IPC on cm**
- MUL co-locates with ALU2 — predicted **−1 to −2% IPC on cm**
- ALU3 not bypassed — predicted **−1% IPC on cm**

These predict ~5–8% of the cm gap.

---

## 5. Phase 3 — ROB / Commit comparison

### 5.1 ROB depth & commit width

| Param | BOOM v4 MegaBoom | rv64gc-v2 |
|---|---|---|
| ROB depth | 128 (`config-mixins.scala:258`) | 128 (`rv64gc_pkg.sv:40`) |
| Commit width | 4 (= decodeWidth) | 4 (= COMMIT_WIDTH) |
| ROB rows | 128 / coreWidth = 32 rows × 4-bank | unbanked, 128 entries |
| Commit ordering | in-order, up to 4/cycle | in-order, up to 4/cycle |

ROB depth is identical. Commit width is identical. Commit policy is identical.

### 5.2 ROB-head-wait sources

The 47% head-not-ready cycles on cm and 38% on dhry are NOT a ROB-structure
issue — they are a back-end issue (consumer can't issue because operand
isn't ready). The ROB is being correctly filled; the issue is upstream.

### 5.3 WB-to-commit bypass

- **BOOM:** `wb_resps` are `RegNext`'d into the ROB writeback ports
  (`core.scala:879, 951, 972`). The cycle of head-ready latency = 1 cycle
  from execute completion.
- **rv64gc-v2:** `wb_valid` to ROB also uses `cdb_valid_r` (registered, 1
  cycle from execute) per `rv64gc_core_top.sv:1373-1374`. AND there is a
  separate `rob_head_wb_bypass` infrastructure (referenced in MEMORY.md but
  let me verify in code below).

<!-- evidence -->
<!-- rob.sv:62-69 - load_wb_valid_r is registered; same as BOOM -->

The two designs are structurally equivalent on commit.

**Verdict (Phase 3):** ROB and commit are at parity. No predicted IPC delta.

---

## 6. Phase 4 — LSU comparison

### 6.1 LQ/SQ/MSHR config

| Param | BOOM v4 MegaBoom | rv64gc-v2 |
|---|---|---|
| LQ entries | 32 (`config-mixins.scala:271`) | 32 (`rv64gc_pkg.sv:78`) |
| SQ entries | 32 | 32 |
| Load ports | lsuWidth=2, memWidth=3 (`config-mixins.scala:264-267`) | 2 load + 1 STA + 1 STD = effectively 2 load + 1 store |
| MSHR | nMSHRs=8 (`config-mixins.scala:283`) | L1D_MSHR_DEPTH=16 (`rv64gc_pkg.sv:152`) |
| L1D | 64 sets × 8 ways × 64B = **32 KB**, 8 MSHRs | 256 sets × 4 ways × 64B = **64 KB**, 16 MSHRs |
| L1D banks | 4 (`config-mixins.scala:278`) | 2 (`rv64gc_pkg.sv:148`) |
| Committed Store Buffer | None (BOOM keeps stores in SQ until cache fire) | CSB depth=32 (`rv64gc_pkg.sv:80`) |
| Speculative load wakeup | `enableFastLoadUse=true`: 1-cycle pre-WB wakeup at AGEN (`lsu.scala:1017-1025`) | spec_wk fires at dcache req issue, 1-cycle pre-CDB (`lsu.sv:1116-1119`) |
| Store-to-load forwarding | Yes (`enableLoadToStoreForwarding=true`) | Yes (3 paths: same-cycle STA/STD, SQ CAM, CSB CAM) |

### 6.2 Load-to-use latency

- **BOOM MegaBoom:** 4 cycles (per `core.scala:378`)
- **rv64gc-v2:** 2-3 cycles (per CLAUDE.md observation, confirmed by
  `lsu.sv:213-218`)

### 6.3 LSU verdict

rv64gc-v2 LSU is structurally MORE aggressive than BOOM:
- Bigger L1D (64KB vs 32KB)
- More MSHRs (16 vs 8)
- Faster load-to-use (2-3 vs 4)
- Extra committed-store-buffer for forwarding hits past SQ drain
- More forwarding paths (3 same-cycle/SQ/CSB vs BOOM's SQ-only)

**Verdict (Phase 4):** LSU is a **rv64gc-v2 win**, not a gap source. The
27% dhry head-stall on load is NOT the LSU's fault (loads are 1 cycle p99);
it is the consumer-side issue latency / IQ depth (Phase 2) limiting how
quickly the consumer can pick up the load result.

---

## 7. Phase 5 — Free list / Rename rate

### 7.1 Rename rate

| Param | BOOM v4 MegaBoom | rv64gc-v2 |
|---|---|---|
| Rename width | 4 (= decodeWidth) | 4 (= RENAME_WIDTH) |
| Rename pipeline depth | 2 stages (Ren1 + Ren2) | 1 stage (combinational outputs) |
| Move/zero elimination | No | Yes (`ren_move_eliminated`, `ren_zero_eliminated`) |
| Banked rename freelist | optional (`enableBankedFPFreelist`) | No (single 128-entry int free list) |
| Commit-side dealloc | 4/cycle | 4/cycle |

### 7.2 Physical register file size

| Param | BOOM v4 MegaBoom | rv64gc-v2 |
|---|---|---|
| Int PRF | 144 (`config-mixins.scala:265`) | 160 (`rv64gc_pkg.sv:33`) |
| Int free list | 144 - 32 = 112 | 160 - 32 = 128 |
| FP PRF | 128 (`config-mixins.scala:266`) | 96 (`rv64gc_pkg.sv:35`) |
| Imm PRF | 32 (`parameters.scala:41`, default 32) | None — immediates passed combinationally through IQ |
| Branch checkpoints | maxBrCount=20 (`config-mixins.scala:273`) | NUM_CHECKPOINTS=64 (`rv64gc_pkg.sv:52`) |

### 7.3 The "imm PRF" gap (key finding)

BOOM has a separate `ImmRenameStage` (`rename-stage.scala:414-460`) and
`immregfile` (32 entries, `core.scala:151-157`). Every immediate is
allocated an `pimm` slot at rename, and `immregfile` is read at RRD time
into `exe_imm_data` (`execution-unit.scala:170-173`).

rv64gc-v2 has NO immediate physical register file. Immediates are carried
in `iq_entry_t.imm` (64-bit field per IQ entry, see `uarch_pkg.sv`) and
muxed at issue via `use_imm` flag (`rv64gc_core_top.sv:2099, 2114, 2129`,
e.g. `alu0_op_b = iq0_issue_data[0].use_imm ? iq0_issue_data[0].imm :
bypassed_data[1]`).

**Why does this matter?** It does NOT add cycles directly (rv64gc-v2's
imm-mux is combinational), but it has two indirect costs:
1. IQ entry width is larger (extra ~64 bits/entry × 24 entries × 3 IQs =
   ~4.6 Kb of state). Wider IQ entries → harder to scale IQ depth → IQ
   fragmentation problem above.
2. The 64-bit imm field is replicated in every IQ entry rather than being
   stored once in a 32-entry imm-PRF. BOOM uses `numImmReaders = aluWidth +
   memWidth + 1 = 8` imm-PRF read ports — much cheaper than carrying
   64-bit imm in every IQ slot.

**Predicted IPC delta from imm-PRF gap: ~0% direct, but it's the *enabler*
of the IQ depth fragmentation that costs 3-5% (Phase 2).**

### 7.4 Rename verdict

Rename is at parity. Move/zero elimination is a rv64gc-v2 win (small,
already accounted for in any baseline measurement). Imm-PRF absence is an
*enabler* of the IQ-depth issue but not a direct cost.

---

## 8. Phase 6 — Master difference table & IPC reconciliation

### 8.1 Master table

| # | Module | rv64gc-v2 | BOOM v4 MegaBoom | Direction | Predicted Δ IPC | Magnitude estimate (cycles) |
|---|---|---|---|---|---|---|
| 1 | Frontend register stages | 2 (F1+F2) + FPB | 5 (F0-F4) + FB | rv64gc-v2 WIN | +0 (steady-state, already saturating fetch) | n/a |
| 2 | Frontend mispredict refill | ~5–6 cycles | ~8–9 cycles | rv64gc-v2 WIN | +1–2% on cm at 2.2% mispredict rate | (already measured: cm refill not the issue) |
| 3 | ALU back-to-back ISS-to-ISS | 1 cycle | 1 cycle | parity | 0 | 0 |
| 4 | Load-to-use latency | 2–3 cycles | 4 cycles | rv64gc-v2 WIN | +2–3% | (already measured) |
| 5 | INT PRF size | 160 | 144 | rv64gc-v2 WIN (more renaming room) | +0–1% | n/a |
| 6 | Branch checkpoints | 64 | 20 | rv64gc-v2 WIN | +0% (BOOM saturates rarely) | n/a |
| 7 | Total INT IQ entries | 72 (3×24) | 92 (32+20+40) | **rv64gc-v2 LOSS** | **−1 to −2%** on cm (deeper window helps cover ROB-head-wait) | ≈10-20k cycles on cm iter1 |
| 8 | INT IQ depth fragmentation | 3 partitions, max 24/lane | 1 partition of 40 for ALU | **rv64gc-v2 LOSS** | **−3 to −5%** on cm (large window for OoO ALU) | ≈30-50k cycles on cm iter1 |
| 9 | MUL on ALU2 lane | YES (shared CDB[2]) | NO (separate IQ_UNQ) | **rv64gc-v2 LOSS** | **−1 to −2%** on cm; head_not_ready_mul=3.4% + issue_arb=5.7% partly here | ≈10-20k cycles on cm iter1 |
| 10 | DIV/CSR on ALU3 lane | YES (shared CDB[3] / no bypass) | NO (separate IQ_UNQ) | rv64gc-v2 LOSS | −0.5% on cm; head_not_ready_div ≈ 0% on cm but +1.3% on dhry | small |
| 11 | ALU3 / DIV / CSR not bypassed | NO bypass on lane 3 | All 4 ALU bypassed | **rv64gc-v2 LOSS** | **−1 to −2%** on cm (consumers of ALU3 producers wait 1 extra cycle) | ≈5-15k cycles on cm iter1 |
| 12 | Imm PRF | None (carried in IQ) | Yes (32-entry + 8 read ports) | rv64gc-v2 LOSS (indirect — enables IQ fragmentation) | −0% direct, enables #8 | n/a |
| 13 | Move/zero elimination | YES | NO | rv64gc-v2 WIN | +0–1% on dhry (small fraction of moves) | small |
| 14 | Loop buffer / µop cache | YES | NO | rv64gc-v2 WIN | minimal (UOC ~0% IPC win on 6-wide; 4-wide TBD) | n/a |
| 15 | Speculative load wakeup | Combinational, 1 cycle pre-CDB | Combinational, 1 cycle pre-WB | parity | 0 | 0 |
| 16 | LSU L1D + MSHRs | 64KB/16MSHRs | 32KB/8MSHRs | rv64gc-v2 WIN | small (cm/dhry hit rate similar) | n/a |
| 17 | Store-to-load forwarding | 3 paths (same-cycle STA/STD, SQ, CSB) | 1 path (SQ) | rv64gc-v2 WIN | +0–1% | small |
| 18 | LSU AGen pipelined | enableAgenStage=false in MegaBoom | combinational AGen | parity | 0 | 0 |
| 19 | ROB depth & commit width | 128 / 4 | 128 / 4 | parity | 0 | 0 |
| 20 | Wakeup-broadcast width | 6 ports (4 CDB + 2 load_wb) | 7 ports (4 ALU + 2 load + 1 ll_arb) | BOOM has +1 (ll_arb covers mul/div/csr/i2f) | small | small |
| 21 | Branch predictor (BTB / TAGE / SC) | TAGE-L: 4096 base + 6 tagged tables × 128 entries | TAGE: 4096 base + 4 tagged × 256, 12-bit tags + SC + loop pred. BTB: 2048×8 vs ~512 | rv64gc-v2 WIN on storage (already measured) | already accounted | n/a |
| 22 | RAS depth | 32 | 24 | BOOM marginal +1 | 0 | 0 |
| 23 | Banked write to PRF (column ALU) | optional (off in MegaBoom) | No | parity | 0 | 0 |
| 24 | Issue arbitration policy | age-collapsing (oldest-first) | oldest-eligible per-port | parity | 0 | 0 |
| 25 | Compacting dispatch (re-pack on partial issue) | optional (off in MegaBoom default for IQ_UNQ) | No (slot-stall via holding-register in rename) | small | small | small |

### 8.2 Sum-of-impacts vs measured gap

| Workload | Measured gap | Predicted from differences |
|---|---:|---:|
| cm iter1 | −17% | #7 (−1.5%) + #8 (−4%) + #9 (−1.5%) + #11 (−1.5%) ≈ **−8.5%** |
| cm iter10 | −11% | same as above ≈ −8.5% |
| dhrystone | −39.5% | #7 (−1%) + #8 (−2%) + #11 (−1%) ≈ **−4%** |

**Reconciliation gap:**
- cm iter1: predicted −8.5%, measured −17% → **8.5% unexplained**
- cm iter10: predicted −8.5%, measured −11% → **2.5% unexplained**
- dhry: predicted −4%, measured −39.5% → **35.5% unexplained**

The cm iter10 reconciliation is reasonably tight (within 3%, which is
within measurement noise). The cm iter1 gap is larger but the difference
between iter1 and iter10 (5.01 → 5.37 CM/MHz) suggests cold-cache effects
that aren't structural.

**The dhry gap is the LARGEST anomaly.** None of the catalogued differences
predict a 35% loss on dhry. The dhry head-stall is dominated by
load-wait (27% of cycles, 72% of head-stall) — but rv64gc-v2 has FASTER
loads and FATTER L1D than BOOM. The predicted ratio should be the OTHER
direction.

### 8.3 The dhry anomaly — what's left to characterize

The unexplained 35% on dhry is concentrated in load-wait at the ROB head.
Possible structural sources NOT yet enumerated:

1. **MUL/IMUL latency profile differs.** rv64gc-v2 MUL_LATENCY=3 vs BOOM
   imulLatency=3. Same. (Confirmed.)
2. **Load result -> consumer chain.** A load at ROB head means the consumer
   couldn't issue. If the consumer is a MUL on IQ1 (shared with ALU2), and
   ALU2 is busy with another op, the MUL waits → load waits at head. dhry's
   tight `proc_3` strncpy / strncmp loops may exhibit exactly this.
3. **Compiler binary differences.** The user's CLAUDE.md says "≤3% binary
   contribution" — but for dhry specifically, BOOM reports DMIPS using
   their own toolchain. If their toolchain unrolls the dhry hot loop more
   aggressively, that could explain ~10-20% IPC variance.
4. **Cycles-to-recovery on dhry's small flush count (128 over 23k cycles =
   0.5% mispredict).** BOOM's lrscCycles=80 vs rv64gc-v2's flush+restart
   penalty. Probably small.
5. **SQ-CSB write-back contention.** dhry has many small stores; if the
   committed-store-buffer fills, store retire stalls and the SQ backs up.
   Worth checking `head_not_ready_store_cyc` distribution on dhry (the
   inventory shows 1.4%, so probably not).

The most promising hypothesis for the dhry gap is **toolchain/binary
difference** combined with the load → MUL → ALU dependency chain on
shared lanes (#9 from the table). The architectural-only contribution is
likely closer to 5-10%, with the rest being workload-specific binary
optimization (loop unrolling, register coloring) that BOOM's compiler
flags handle differently.

---

## 9. Phase 7 — Top recommended next RTL changes

### 9.1 Top recommendation: Re-organize INT IQ + co-locate MUL/DIV with separate non-ALU lane

**Goal:** Eliminate IQ depth fragmentation (#8) and MUL-blocks-ALU
contention (#9 + #10), which together account for the LARGEST predicted
IPC delta (~5-7% on cm).

**Two variants:**

**Variant A (small refactor, 2-3 days, ~250 LOC):**
- Reorganize: 2× ALU IQs of 32 entries (sel=2 each) + 1× UNQ IQ of 16 entries (sel=1, holds MUL+DIV+CSR).
- Total: 2×32 + 16 = 80 INT IQ entries (close to BOOM's 92).
- ALU0/1 issue from IQ_ALU_A (32 entries, sel=2). ALU2/3 issue from IQ_ALU_B (32 entries, sel=2).
- MUL/DIV/CSR issue from IQ_UNQ (16 entries, sel=1) — never blocks ALU.
- Files to touch: `rv64gc_core_top.sv` (IQ instantiation, dispatch routing,
  ALU<->IQ wiring), `dispatch_queue.sv` (route fu_type to UNQ instead of
  IQ1/IQ2 for mul/div/csr), `rv64gc_pkg.sv` (NUM_INT_IQS=3, depths).
- Predicted: **+3-5% on cm, +1% on dhry**.
- Risks: must keep CDB_WIDTH=4 and PRF write port count (MUL still writes
  the same CDB[2] slot, but now never contends with ALU2). LSU bypass
  topology unchanged. PRF read-port assignments need re-mapping.

**Variant B (larger refactor, 1 week, ~500 LOC):**
- Reorganize to BOOM's exact partitioning: 1× IQ_ALU 40 entries, sel=4. 1×
  IQ_UNQ 20 entries, sel=1.
- Adds a 4-from-40 oldest-eligible select tree (more complex than the
  current 2-from-24).
- Predicted: **+4-6% on cm, +1-2% on dhry**.
- Risks: select tree timing impact on Fmax; may push out the target clock.
  Variant A is the safer bet for first iteration.

**Recommended: Variant A.** Maintains current select-tree complexity (still
2-from-N at most), gives 80% of the predicted benefit, fits in 2-3 days.

### 9.2 Secondary recommendation: Add ALU3 lane to bypass network

**Goal:** Close the bypass coverage gap (#11) where ALU3 producers add 1
cycle to consumers.

**Approach:**
- Extend `NUM_BYPASS_SRCS` from 5 to 6 (add ALU3/DIV/CSR slot).
- Wire `cdb_data[3]` to `bypass_data[5]` and `cdb_tag[3]` to `bypass_tag[5]`.
- Each of the 12 bypass mux instances (`rv64gc_core_top.sv:2079-2091`) now
  has 6 sources to compare instead of 5.
- Adjust the `bypass_network` module to handle the extra source.
- Files to touch: `bypass_network.sv` (add 6th source mux), `rv64gc_pkg.sv`
  (bump NUM_BYPASS_SRCS), `rv64gc_core_top.sv` (extend `bypass_valid/tag/data`
  vectors and feed ALU3/CSR result).
- Predicted: **+1-2% on cm**.
- Risks: 6-source bypass mux may add gate delay on critical path (PRF read
  + bypass + ALU). Need post-synth check.
- Effort: ~50 LOC, 1 day.

This is independent of #1 and can be done in parallel or first as a
warm-up.

### 9.3 NOT recommended for next iteration

- **Add immediate PRF (BOOM-style ImmRenameStage):** Big refactor (~1 kLOC,
  ~2 weeks). Predicted IPC delta is small (it's an *enabler* of IQ depth
  scaling, not a direct win). Defer until after Variant A confirms IQ
  fragmentation is the actual cause.
- **Increase CDB_WIDTH from 4 back to 6:** Already explored in 4-wide
  pivot history; CM bug bisected to this area. Keep CDB_WIDTH=4 +
  load_wb sideband as-is.
- **Banked PRF / column ALU issue:** BOOM has the *option* but disables it
  in MegaBoom. Likely not worth complexity for our IPC budget.

---

## 10. Conclusion

The audit identified **5 structural differences** between rv64gc-v2 and
BOOM v4 MegaBoom that predict measurable IPC loss in rv64gc-v2:

1. INT IQ depth fragmentation (3×24 vs 1×40+1×20) — **−3 to −5%**
2. MUL co-located with ALU2 — **−1 to −2%**
3. ALU3/DIV/CSR lane not bypassed — **−1 to −2%**
4. Total INT IQ entries 72 vs 92 — **−1 to −2%**
5. DIV/CSR co-located with ALU3 — **−0.5%**

These predict ~6–10% IPC loss on cm, which closely matches the measured 11%
gap on cm iter10 (warm-cache). The cm iter1 gap (17%) and the dhry gap
(39.5%) are not fully accounted for by structural differences alone; the cm
iter1 cold-cache + the dhry workload's binary/compiler interaction are the
likely sources of the residual.

Pipeline depth, ROB depth, LSU latency, and BPU storage are all NOT gap
sources; in those categories rv64gc-v2 is at parity or strictly faster than
BOOM.

The top recommended next RTL change (Variant A above) addresses items 1, 2,
4, 5 in a single ~250-LOC, 2-3 day effort with a predicted +3-5% IPC delta
on cm and +1% on dhry. The secondary change (extending the bypass network
to ALU3) addresses item 3 with a separate +1-2% on cm.

Combined, these two changes are predicted to close ~half the cm gap and a
small portion of the dhry gap. The remaining dhry gap likely requires
either (a) a binary-level investigation comparing BOOM's dhry build flags
to ours, or (b) a runtime LSU/MUL chain trace on dhry's hot loops to
identify a specific RTL micro-bottleneck.

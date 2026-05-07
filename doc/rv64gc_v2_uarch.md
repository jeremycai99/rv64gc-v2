# RV64GC v2 Microarchitecture Specification

**Status:** CURRENT (4-wide OoO implementation; supersedes original 6-wide spec)
**Last revised:** 2026-05-07
**Repo HEAD at revision:** current checked-in revision
**Authoritative sources:** `src/rtl/core/include/rv64gc_pkg.sv` (parameters); `src/rtl/core/rv64gc_core_top.sv` (top-level wiring); per-module RTL.

> ## Scope
>
> This document describes the implemented microarchitecture, intended
> architectural contracts, and core/simulator boundary. Performance comparisons
> and run reports belong in the evaluation docs and archives, not in this
> specification.

---

## 1. Design Overview

### 1.1 ISA

`rv64imafdc_zba_zbb_zbs_zicond_zicsr_zifencei`

- **Base:** RV64I (64-bit integer)
- **M:** integer multiply/divide
- **A:** atomics
- **F+D:** single+double-precision FP (path implemented; FP perf is not the focus)
- **C:** compressed instructions (RVC)
- **Zba:** address generation (`sh1add`, `sh2add`, `sh3add`, `.uw` variants)
- **Zbb:** bit manipulation (clz, cpop, min, max, etc.)
- **Zbs:** single-bit operations
- **Zicond:** conditional zero (`czero.eqz`, `czero.nez`)
- **Zicsr:** control/status registers
- **Zifencei:** instruction-fetch fence

### 1.2 Pipeline Width (4-wide superscalar)

| Parameter | Value | Notes |
|---|---|---|
| `PIPE_WIDTH` | **4** | fetch / decode / rename / dispatch / commit |
| `FETCH_WIDTH` | 4 | |
| `DECODE_WIDTH` | 4 | |
| `RENAME_WIDTH` | 4 | per-slot independent advance (no group-hold) |
| `DISPATCH_WIDTH` | 4 | route per `fu_type` to one of 6 IQs |
| `COMMIT_WIDTH` | 4 | in-order; in-window prefix of ready uops |
| `FETCH_BYTES` | 16 | 4 × 4-byte ALIGN slots (RVC handled in decompress) |

### 1.2.1 Width Interpretation

Decode width is only one dimension of a core. Effective work delivered to the
backend also depends on fetch width, fetch buffering, prediction quality, branch
recovery, macro-op/uop treatment, issue topology, LSU provisioning, and commit
policy. The local design should therefore describe each width independently
instead of treating "4-wide" as a single property.

| Dimension | rv64gc-v2 current RTL | Architectural implication |
|---|---|---|
| Fetch bytes | 16 B/cycle | Four aligned 32-bit slots per fetch group; RVC can increase instruction density. |
| Decode / rename / dispatch / commit | 4 / 4 / 4 / 4 | Sustained architectural retirement is commit-bound at 4 uops/cycle. |
| Issue topology | Distributed IQs with more issue ports than commit width | Short bursts can exceed commit bandwidth, but retirement remains in-order. |
| Frontend ownership | FTQ-backed fetch blocks, with F1 still coupled to F2 packet progress | The intended direction is stronger BPU/FTQ ownership and packet buffering, not decode widening. |

Local source anchors:

- rv64gc-v2 widths: `src/rtl/core/include/rv64gc_pkg.sv`.
- rv64gc-v2 distributed issue topology: `src/rtl/core/rv64gc_core_top.sv`.
- Branch predictor wrapper: `src/rtl/core/bpu/bpu.sv`, with BTB, TAGE, and
  RAS leaves in `src/rtl/core/bpu/`.

### 1.3 Frontend Ownership Model

The frontend is moving toward a BPU-owned fetch-block contract, but the
architectural owner remains the FTQ. The BPU may choose the next predicted PC;
the FTQ owns the dynamic block identity, epoch, redirect lifetime, training
metadata, and delivery accounting.

Current default RTL:

- `src/rtl/core/bpu/bpu.sv` is the BPU integration wrapper. It owns the direct
  BTB, TAGE-SC-L, and RAS leaf instances, including lookup/update/restore
  wiring, speculative GHR update routing, request-time FTQ prediction entry
  assembly, auxiliary prediction observation, and the registered F1 to F2
  predictor metadata snapshot consumed by prediction checking and packet
  construction.
- F1 PC generation is still coupled to F2 packet progress and architectural
  redirect priority.
- `ftq.sv` tracks allocated-not-requested, requested-not-written-back, and
  writeback-to-commit occupancy, plus current IFU request owner, current
  IFU-writeback owner, next IFU-writeback owner, commit/training head, and
  allocation tags. The requested-not-written-back occupancy is exposed as its
  own count so future runahead limits can distinguish queued owner requests
  from owners already delivered toward commit.
- Decode/commit visibility is split from IFU-owner completion. The first
  accepted packet for an IFU-writeback owner pushes that FTQ owner into the
  commit/decode-visible region; the IFU-writeback owner may remain live until
  the final packet for that owner is emitted. This lets one predicted fetch
  block span multiple decode packets without making the packet buffer observe a
  stale owner between the first and last packet.
- The IFU request owner and IFU-writeback owner are separate pointers. In the
  current monolithic fetch unit, request-owner progress is driven by the normal
  request allocation event; the FTQ handles same-cycle
  allocation-to-IFU transfer when the owner has not yet reached the registered
  allocation-to-request region. The local IFU request boundary is expressed as
  valid/ready/fire; ready is gated by FTQ enqueue readiness, I-cache response
  queue capacity, and IBuffer capacity so future runahead has a structural
  backpressure point.
- There is no FTQ-level prefetch pointer yet. The existing
  `next_line_prefetch_buffer.sv` is a local line buffer and should not be treated
  as XiangShan-style `pfPtr` ownership.
- `icache_resp_queue.sv` is a line-response FIFO, not an architectural owner.
  The IFU accepts a queue head only when its explicit response-line address
  matches the current IFU work cursor line. Responses with invalid or stale FTQ
  epoch metadata are drained by the FTQ flush/epoch rule and are never exposed
  as instruction data. Each queue entry carries the request PC, FTQ
  idx/epoch/alloc-tag, and full FTQ entry snapshot so a future cursor handoff
  can load PC and owner metadata as one object instead of pairing signals from
  different request phases. Same-line owners may consume the local F2
  line-state record without treating the queue head as the owner cursor.
- `frontend/ifu/ifu.sv` owns a stateful IFU work item carrying valid, PC,
  FTQ idx/epoch/alloc-tag, FTQ entry, line identity, delivery state, and
  completion fields.
  This cursor is the single registered F2 work state; the previous raw F2
  PC/FTQ mirror-register set has been retired. Line acceptance and
  line-state matching use the cursor's active `line_addr`; extraction,
  predecode, owner-live checks, packet metadata, and the named owner-completion
  decision use the `f2_work_*` aliases sourced from this cursor. The FTQ
  IFU-writeback owner remains the architectural completion owner, but it is not
  a combinational substitute for the current in-owner PC. On a clean IFU-owner
  completion, the cursor may take the next FTQ
  IFU-writeback owner identity while keeping the cursor-computed next PC; the
  FTQ entry start PC is request metadata, not a replacement for the in-owner PC.
  Simulation trace/probe consumers that describe the active F2 PC or FTQ owner
  also read the `f2_work_*` aliases, so they follow the same architectural
  cursor rather than a legacy raw-F2 name.
  The RTL names the cursor policy cases explicitly: redirect handoff, matching
  redirect handoff through the FTQ next-owner view, FTQ next-owner completion
  handoff, normal request-owner load, and remainder request-owner load.
  Request-owner cursor loads are sourced from a single combinational request
  work item that carries the request PC, FTQ idx/epoch/alloc-tag, and full FTQ
  entry together, instead of scattering raw `ftq_enq_*` field assignments
  across the cursor policy logic.
  The IFU also owns the last-allocation anti-duplicate register and the
  consumed-remainder/post-remainder cursor used to advance across RVC straddles;
  `fetch_top.sv` only publishes the consumed-remainder state for existing
  simulation binds.
  Simulation invariants check that IFU request-pop is a real ready/enqueue
  handshake, that selected FTQ next-owner handoffs load the cursor on the
  following cycle, and that a wrong-owner IFU completion candidate cannot pop
  the FTQ IFU-writeback owner. The profile counters distinguish architectural
  completion-owner mismatches from diagnostic cursor-vs-writeback skew.
  Owner completion is stricter than packet emission: a packet that consumes a
  straddle remainder, or redirects without an enqueued/registered successor
  owner, keeps the current owner live for the continuation packet. Straight-line
  same-line continuation also keeps the current owner live; the first emitted
  packet records that the owner has been delivered to the commit/decode side,
  while final owner completion is delayed until the continuation is exhausted.
  Same-owner cursor advance is allowed only under a live IFU-writeback owner,
  on the same cache line, with no active remainder/straddle transition. The
  normal path advances after a real packet enqueue. A duplicate-suppressed
  packet may also catch the cursor up only after the owner has already been
  delivered and only when the duplicate guard next PC matches the recomputed
  sequential next PC. If the FTQ owner has predicted-control metadata, either
  advance path may move only when the next packet is entirely before that
  predicted-control PC or starts exactly at it; it must not advance to a PC
  that would make the predicted control a passenger behind earlier
  instructions.
  The next XiangShan-style split is to make this cursor-to-FTQ handoff more
  complete under explicit owner/completion rules.
- `frontend/ifu/ifu_duplicate_guard.sv` contains the legacy same-packet
  duplicate and replay suppression state. It is kept as a behavior-preserving
  IFU helper while the frontend remains conservative; the intended endpoint is
  still to make this structurally unnecessary once FTQ, IFU, and IBuffer
  ownership fully prevent duplicate packet production.
- `frontend/ibuffer/ibuffer.sv` is the decode-facing owner-aware IBuffer
  boundary. It currently wraps `fetch_packet_buffer.sv`, which stores complete
  fetch packets with FTQ idx/epoch/alloc-tag and explicit
  IFU line metadata (`ifu_line_addr`, `ifu_line_reused`), exposes
  enqueue/dequeue fire events, and classifies the head packet as matching,
  stale, or owner-complete against the FTQ commit owner. When empty, it may
  flow an accepted IFU packet directly to decode in the same cycle; this
  flow-through path is still owned by the IBuffer, so decode no longer consumes
  the separate `packet_buf_in` direct-bypass path. The IBuffer wrapper also
  derives decode dequeue readiness from backend stall and frontend hold,
  emits the flow-through observation signals, and emits the decode/commit-side
  FTQ pop request derived from dequeue fire, owner match, and owner-complete.

Intended BPU/FTQ contract:

1. F1 may issue the next predicted fetch block when a matching FTQ owner and
   downstream packet-buffer slot can be reserved.
2. Every request, I-cache response, extracted packet, redirect, and training
   update carries FTQ idx/epoch/alloc-tag identity or is discarded by an
   FTQ-defined flush/epoch rule.
3. F2 consumes owned line state exactly once for each architecturally required
   PC. The IFU work cursor tracks the current PC within the FTQ owner, while
   the FTQ IFU-writeback pointer names the completion owner.
4. The IBuffer stores complete fetch packets with owner identity, block PC,
   per-slot PCs, IFU line identity, predicted-control metadata, and
   owner-complete state.
5. Duplicate suppression should become structurally unnecessary once packets
   are produced and consumed under explicit owner identity.

Same-line fetch ownership is explicit at the line-data boundary. The frontend
can create multiple request/allocation events within the same I-cache line. F2
may share the physical line data across those events only when the line-state
address and epoch match the IFU work cursor, but it must not replay an earlier
owner stream under a younger FTQ owner. Packet production remains per FTQ owner
even when the line fill is shared.

Non-architectural local recovery patterns:

- F2 or `icache_resp_queue` must not recover correctness by dropping entries
  based only on current queue head, last-emitted PC, or a local stale-entry
  heuristic.
- Standalone decoded-op replay, same-line handoff, same-FTQ tail carry, and
  sequential lookahead are not part of the active frontend architecture because
  they bypass the FTQ/BPU ownership contract. Their opt-in plusarg controls
  have been retired from the active RTL control surface.
- Verification hooks such as golden PC checking and owner-identity counter
  invariants validate the contract; they are not pipeline mechanisms.

### 1.3.1 ASIC-Clean Core Boundary

The core must remain a general CPU core. Fixed
`tohost` policy, test pass/fail encoding, and cross-suite ABI adaptation
belong in the simulator platform or SoC wrapper, not in the architectural core.

Current boundary:

| Concern | Owner | Current state |
|---|---|---|
| Architectural CPU pipeline | `rv64gc_core_top.sv` and child RTL | No `tohost_addr` input and no `tohost_wr_*` outputs. |
| L1D/store behavior | `dcache.sv` | No magic-address exemption for `0x80001xxx`; endpoint stores follow normal store-miss behavior. |
| Simulation endpoint detection | `tb_top.sv` | Harness observes ordinary LSU store traffic to configurable `TOHOST_ADDR`. |
| Workload image/ABI adaptation | `tools/sim_platform.py` | Prepares broad coverage manifests, adds per-row `SIM_ABI`, and derives `TOHOST_ADDR` from ELF symbols when available. |

This mirrors the BOOM/Chipyard separation: the harness may understand HTIF,
ELF symbols, and test exits, but the core itself should only expose normal
architectural interfaces plus implementation counters needed for validation.

### 1.4 Top-Level Pipeline Diagram

#### Front-End → Rename → Dispatch (4-wide)

```
                              FRONT-END (4-wide, BPU/FTQ-owned contract)
   ┌───────┐  ┌─────────────┐  ┌──────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐
   │  BPU  │  │  FTQ / IFU  │  │ PREDCHK  │  │  DECODE │  │ FUSION  │  │  RENAME │
   │       │  │  L1I + ITLB │  │ + IBUF   │  │         │  │ DETECT  │  │  + RAT  │
   │ +BTB  │→ │ fetch block │→ │ control  │→ │ 4-wide  │→ │ + emit  │→ │  + free │
   │ +TAGE │  │ ownership   │  │ repair   │  │ + RVC   │  │         │  │   list  │
   │ +RAS  │  │ + runahead  │  │ + queue  │  │ decomp  │  │         │  │ +ckpt   │
   └───────┘  └─────────────┘  └──────────┘  └─────────┘  └─────────┘  └─────────┘
                                                                            │
                                                                            ▼
                                              ┌─────────────────────────────────────────┐
                                              │  DISPATCH (4w) — route per fu_type       │
                                              │   ALU/BRU → INT IQs (per dispatch policy)│
                                              │   MUL → u_iq1; DIV/CSR → u_iq2           │
                                              │   LOAD → u_iq_ldst                       │
                                              │   STA → u_iq_st_addr; STD → u_iq_st_data │
                                              └─────────────────────────────────────────┘
                                                                            │
                                                                            ▼
```

#### Issue Queues + Execution Units + CDB (separated per EU)

Each EU is its own block; CDB-port sharing and bypass-coverage are explicit.

```
                                         ISSUE QUEUES (6 total)
                                         + ISSUE PORTS (max 8/cyc theoretical, 4 commit-bound)
   ┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐
   │ u_iq0     24 ent │    │ u_iq1     24 ent │    │ u_iq2     24 ent │
   │ NUM_SELECT=2     │    │ NUM_SELECT=1     │    │ NUM_SELECT=1     │
   │ FUs:             │    │ FUs:             │    │ FUs:             │
   │  ALU0+BRU0 (p0)  │    │  ALU2 OR MUL     │    │  ALU3 OR DIV OR  │
   │  ALU1+BRU1 (p1)  │    │   (single port)  │    │  CSR (1 port)    │
   └─┬────────┬───────┘    └────┬─────────────┘    └────┬─────────────┘
     │ port0  │ port1            │ port0                 │ port0
     ▼        ▼                  ▼                       ▼
  ┌─────┐ ┌─────┐         ┌──────┬─────┐         ┌──────┬─────┬─────┐
  │ALU0 │ │ALU1 │         │ ALU2 │ MUL │         │ ALU3 │ DIV │ CSR │
  │+BRU0│ │+BRU1│         │ comb │ 1cy │         │ comb │ FSM │ ser │
  │comb │ │comb │         │      │ pip │         │      │30+cy│multi│
  │/1cy │ │/1cy │         │      │     │         │      │     │ cy  │
  └──┬──┘ └──┬──┘         └──┬───┴──┬──┘         └──┬───┴──┬──┴──┬──┘
     │       │                │      │                 │      │      │
     ▼       ▼                ▼      ▼                 ▼      ▼      ▼
  ┌─────┐ ┌─────┐         ┌─────────────┐         ┌──────────────────┐
  │CDB[0│ │CDB[1│         │   CDB[2]    │         │      CDB[3]      │
  │ ALU0│ │ ALU1│         │   ALU2 OR   │         │   ALU3 OR DIV    │
  │ /BRU0│ │/BRU1│         │   MUL       │         │      OR CSR     │
  │ arb │ │ arb │         │   arbitrated│         │   arbitrated 3-way│
  └──┬──┘ └──┬──┘         └──────┬──────┘         └─────────┬────────┘
     │       │                   │                          │
     │       │       (registered CDB outputs to PRF + bypass slots [0..2])
     ▼       ▼                   ▼                          ▼
  ╔═══════════════════════════════════════════════════════════╗
  ║  REGISTERED CDB → INT PRF write ports [0..3] (CDB_WIDTH=4) ║
  ╚═══════════════════════════════════════════════════════════╝

   ┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐
   │ u_iq_ldst  32 ent│    │u_iq_st_addr 32 ent│   │u_iq_st_data 32 ent│
   │ NUM_SELECT=2     │    │ NUM_SELECT=1     │    │ NUM_SELECT=1     │
   │ FUs:             │    │ FU:              │    │ FU:              │
   │  Load0 AGU (p0)  │    │  Store-Addr AGU  │    │  Store-Data path │
   │  Load1 AGU (p1)  │    │                  │    │                  │
   └─┬────────┬───────┘    └────┬─────────────┘    └────┬─────────────┘
     │ port0  │ port1            │                       │
     ▼        ▼                  ▼                       ▼
  ┌─────┐ ┌─────┐         ┌─────────────┐         ┌─────────────┐
  │Load │ │Load │         │   STA AGU   │         │   STD path  │
  │AGU0 │ │AGU1 │         │   addr-gen  │         │   data cap  │
  │     │ │     │         │   → SQ enq  │         │   → SQ data │
  └──┬──┘ └──┬──┘         └──────┬──────┘         └──────┬──────┘
     │       │                   │                       │
     │       │            (LSU paths to L1D / SQ — see §7)
     ▼       ▼
  ┌──────────────────────────────────────────┐
  │  L1D 64 KB 4-way 2-bank dcache            │
  │   2-stage pipeline (S0 issue, S1 wb)      │
  │   16 MSHRs                                │
  │   load_wb sideband: 2 wr ports (Load0/1)  │
  │   → bypass slot [3]/[4] (combinational)   │
  │   → INT PRF write ports [4]/[5]           │
  └──────────────────────────────────────────┘
```

#### Bypass coverage map (5 slots)

```
      ┌─────────────────────────────────────────────────────────────┐
      │  BYPASS NETWORK (NUM_BYPASS_SRCS = 5)                       │
      │                                                             │
      │   slot[0] ← cdb_data_r[0]   ALU0 / BRU0     REGISTERED      │
      │   slot[1] ← cdb_data_r[1]   ALU1 / BRU1     REGISTERED      │
      │   slot[2] ← cdb_data_r[2]   ALU2 / MUL      REGISTERED      │
      │   slot[3] ← load_wb_data[0] Load0           COMBINATIONAL ★ │
      │   slot[4] ← load_wb_data[1] Load1           COMBINATIONAL ★ │
      │                                                             │
      │   NOT BYPASSED: CDB[3] (ALU3, DIV, CSR)                     │
      │     Consumers fall back to PRF read at T+3 (1 extra cycle). │
      │                                                             │
      │   ★ Combinational bypass is REQUIRED for loads:             │
      │     spec_wakeup → consumer issues at T+2; PRF doesn't       │
      │     latch until T+3, so bypass is the only data source.     │
      └─────────────────────────────────────────────────────────────┘
```

#### Writeback → PRF → Commit

```
                             ┌───────────────────────────────────┐
                             │  WRITEBACK + INT PRF              │
                             │   PRF: 160 × 64-bit, 12R6W        │
                             │   Write ports:                    │
                             │     [0..3] CDB[0..3] (4)          │
                             │     [4]    load_wb sideband Load0 │
                             │     [5]    load_wb sideband Load1 │
                             │   Read ports: 12 (3 ALU × 2 src + │
                             │     2 BRU × 2 src + 1 MUL × 2 src)│
                             │   FP PRF: 96 × 64-bit (separate)  │
                             └────────────┬──────────────────────┘
                                          │
                                          ▼
                             ┌───────────────────────────────────┐
                             │  ROB (128 entries) + COMMIT (4w)  │
                             │   in-order, head-prefix commit    │
                             │   head_wb_bypass: same-cycle      │
                             │     wb→commit if head ready       │
                             │   Per-class wb_bypass instr:      │
                             │     load/arith fires tracked      │
                             └───────────────────────────────────┘
```

#### Key contention points (visible from the diagram)

These are the structural constraint points that any optimization needs to be aware of:

1. **Issue port count is 8 max** (4 INT + 4 LSU) but commit width is 4 → max 4 sustainable issues/cycle
2. **u_iq1 NUM_SELECT=1**: ALU2 OR MUL per cycle — single issue port serializes them
3. **u_iq2 NUM_SELECT=1**: ALU3 OR DIV OR CSR — single issue port serializes 3 FUs
4. **CDB[2] is shared**: ALU2 and MUL writeback contend (arbitration logic in core_top)
5. **CDB[3] is shared 3-way**: ALU3, DIV, CSR — heaviest arbitration contention
6. **CDB[3] is NOT bypassed**: consumers of ALU3/DIV/CSR pay 1 extra cycle PRF-read latency
7. **BRU is 1-cycle latency** (vs ALU 0-cycle combinational): branches add 1 cycle to chain
8. **MUL is 1-cycle hw latency** but `MUL_LATENCY=3` in pkg.sv — stale parameter, may affect IQ wakeup scheduling
9. **LSU: 2 load AGUs + 1 STA + 1 STD** = 4 LSU issue ports; load_wb sideband is independent of CDB

---

## 2. Front-End

### 2.1 Frontend Integration (`src/rtl/core/frontend/top/fetch_top.sv`)

- **Width:** 16 bytes/cycle (`FETCH_BYTES = 16`); up to 4 instructions (RVC: up to 8 if all compressed)
- **Current pipeline:** 2 stages (IF1: PC gen + L1I tag/data probe + BPU lookup; IF2: way mux + predecode).
- **PC redirect sources** (priority order):
  1. Reset / external
  2. Commit-time flush (full architectural flush from ROB on mispredict reaching commit)
  3. BRU early redirect (mechanism present but plusarg-gated OFF by default)
  4. BPU redirect (taken-branch BTB+TAGE prediction)
  5. Sequential PC + 16
- **L1I:** see §11
- **Module boundary:** `fetch_top.sv` is the direct frontend integration top
  instantiated by `rv64gc_core_top.sv`. `frontend/ifu/ifu.sv` is the
  instruction fetch unit block inside that integration layer. A monolithic
  `fetch_unit.sv` is not part of the target structure; any compatibility name
  in this area means the split is incomplete and should be retired. The
  integration top is wire-only RTL: frontend policy and state live in BPU, FTQ,
  IFU, line-fetch, prediction-checker, instruction-helper, and IBuffer blocks,
  while simulation checkers bind from `src/rtl/sim/`.
- **Current advance model:** F1 is still coupled to F2 packet progress. This
  means the BPU can predict a target, but the frontend generally does not build
  a multi-entry predicted-block stream ahead of decode.
- **Current IFU work cursor:** `frontend/ifu/ifu.sv` owns the registered F1
  PC/valid sequencer, the conservative F1 request and FTQ allocation boundary,
  and the stateful F2 work item carrying current PC, line address, FTQ identity,
  FTQ metadata, and delivery state. F1 still advances from the same redirect,
  BPU redirect, duplicate-suppression, and F2 consumption conditions as the
  previous integration-local logic, so this is a structural ownership move
  rather than proactive runahead. The IFU request boundary computes request PC,
  I-cache request valid/address, FTQ enqueue valid, IFU request-pop fire, and
  frontend stall from registered F1/F2 state plus FTQ, ICQ, and IBuffer
  readiness. It also owns the last-allocation anti-duplicate register,
  straddle-remainder cursor, completion owner-live comparison against the FTQ
  IFU-writeback owner, completion-side delivery push, and FTQ IFU-pop decision
  for the active work owner; the decode/commit-side FTQ pop remains tied to the
  IBuffer dequeue owner-complete boundary. The cursor is the single registered
  F2 work state; request anti-duplication, NLPB response matching, line
  acceptance, line-state
  matching, extraction, predecode, owner-live checks, packet construction,
  owner-completion decisions, and debug/profile paths consume the cursor aliases
  rather than raw F2 PC/owner signals. Owner completion is delayed when the
  emitted packet is still carrying
  a same-owner continuation, such as straight-line same-line delivery,
  straddle-remainder consume, or a redirect taken before a successor owner
  exists. The first accepted packet separately marks the owner as delivered to
  the commit/decode-visible side of the FTQ, so multi-packet owners do not look
  stale to the decode-facing packet buffer.
- **Current stall sources:** I-cache miss, pipeline backpressure (FTQ full / packet buffer full / rename stall), wait-for-Icresp, NLP miss
- **Intended ownership contract:** F1 may request the next predicted block when
  a stable FTQ/fetch-block owner and downstream packet-buffer slot are available.
  `icache_resp_queue` absorbs line-response elasticity before F2 packet
  extraction. F2 remains conservative: it consumes owned line state exactly once
  per required PC and relies on redirect/epoch/tag ownership instead of local
  duplicate, same-tail, or sequential-lookahead steering.
- **Current response-queue boundary:** `icache_resp_queue` is consumed through a
  line-qualified ready/valid boundary. A queue head is accepted as IFU data only
  when its explicit response-line address matches `ifu_work_r.line_addr`;
  invalid or stale epoch responses are drained as flushed work. The queue can
  still accept an enqueue on a full cycle when the head also pops, avoiding
  dropped one-cycle I-cache responses.
- **Current line-fetch adapter boundary:** `frontend/ifu/ifu_line_fetch.sv`
  owns the I-cache, next-line prefetch buffer, request-owner retime, and
  `icache_resp_queue` response association. It also owns the line-qualified
  ICQ pop rule, stale epoch drain, IFU-writeback owner-match observation, and
  same-line line-state reuse. It keeps `icache.sv` itself as a separate cache
  block and exposes the accepted line data plus ICQ head metadata back to the
  current integration layer.
- **Current line-state boundary:** `ifu_line_fetch.sv` records a separate
  line-state register for the consumed response line (line address, data, and
  epoch). Packet metadata is sourced from this line identity, while FTQ
  idx/epoch/tag remain the owner cursor in `fetch_top.sv`. The extraction
  datapath may consume the line-state record when the line and epoch match the
  IFU work cursor line; otherwise it waits for an accepted queue response.
- **Current IBuffer boundary:** `frontend/ibuffer/ibuffer.sv` is the
  decode-facing packet boundary and currently wraps the existing
  `fetch_packet_buffer` FIFO implementation. It is the only packet source for
  decode and owns the packet-to-decode signal adaptation for `fetch_count`,
  instruction words, PCs, RVC flags, branch-prediction metadata, and the
  monitor-facing packet observation. Its empty-buffer flow-through preserves the
  previous fast path without letting `fetch_top.sv` bypass the owner-aware
  buffer. F2 emission is gated by the IBuffer enqueue-ready signal rather than
  the raw full flag, so a full buffer can still accept a packet on a same-cycle
  dequeue. The old `FETCH_PACKET_BYPASS2` direct-bypass control surface has
  been removed; the current debug/profiling signal is an IBuffer flow-through
  observation, not an alternate decode data path. Decode-side dequeue readiness
  is also owned by the IBuffer boundary, with `fetch_top.sv` observing the
  resulting `packet_buf_deq` signal for simulation binds and FTQ wiring.
- **Instruction helper leaves:** `frontend/instr/instr_boundary.sv`,
  `frontend/instr/rvc_expander.sv`, `frontend/instr/predecode.sv`, and
  `frontend/instr/instr_compact.sv` hold parcel extraction, compressed
  expansion, control-flow predecode, and mechanical fetch-packet assembly.
  `instr_boundary.sv` also owns the F2 sequential next-PC output used by IFU
  cursor updates and straddle/remainder handoff. `instr_compact.sv` owns the
  packet emit gate from payload-valid, duplicate-suppression, IBuffer-ready,
  and line-straddle consume inputs, while preserving the exported emit
  observation wires used by IFU and simulation binds.
- **Prediction checker boundary:** `frontend/pred/pred_checker.sv` owns
  predicted-control validation, static-control override, subgroup split
  selection, same-owner continuation classification, owner-complete
  classification, stall-qualified BPU redirect fire, RAS/GHR action requests,
  and the registered subgroup seed state used to carry branch-owner prediction
  metadata into the following request. The production subgroup-split defaults
  are owned inside `pred_checker.sv`; `fetch_top.sv` no longer wires fixed
  production policy controls through the integration layer. Old simulation
  plusarg controls for disabling this behavior have been retired from the core.
- **BPU boundary:** `core/bpu/bpu.sv` owns BTB, TAGE, RAS, GHR repair, request
  prediction assembly, aux prediction observation, the BPU-to-FTQ request entry
  adapter, and the registered F1 to F2 BTB/TAGE/GHR snapshot. `fetch_top.sv`
  consumes the assembled FTQ entry and registered F2 predictor metadata instead
  of locally rebuilding predictor state.
- **Simulation boundary:** `src/rtl/sim/fetch_delivery_checker.sv`,
  `src/rtl/sim/fetch_owner_checker.sv`,
  `src/rtl/sim/fetch_frontend_profiler.sv`,
  `src/rtl/sim/fetch_trace_probe.sv`, and
  `src/rtl/sim/fetch_frontend_assertions.sv` bind to `fetch_top` in simulation.
  They own the strict delivery stream checker, same-line owner contract checker,
  frontend performance/profile counters, optional fetch trace output, and
  frontend timing invariants. This keeps checker, profiler, trace, and
  assertion `$display`, `$fatal`, `$error`, and plusarg handling out of the
  frontend integration RTL.
- **Current runahead precondition:** the IFU work cursor is still conservative
  and mirror-locked to the registered F1/F2 flow. Before F1 can run ahead by
  default, this cursor must become the independently advanced work item for the
  FTQ IFU-writeback owner, not a local PC-steering shortcut. Retired
  same-line, same-tail, sequential-lookahead, and weak-bias controls must not
  be reintroduced as a substitute for FTQ/IBuffer capacity-owned runahead; the
  corresponding dead RTL paths have been removed. A hold-only cursor split is
  not sufficient: the cursor handoff must be driven by the FTQ IFU-writeback
  owner when the previous owner completes.
- **Accepted ownership rule:** BPU prediction may choose the next PC, but FTQ
  owns the dynamic block. Any request, response, packet, redirect, and training
  update must carry the FTQ idx/epoch/alloc-tag identity or be explicitly
  discarded by an FTQ-defined flush/epoch rule.
- **Rejected ownership rule:** F2 or `icache_resp_queue` must not recover
  correctness by dropping "stale" entries based only on current queue head or
  last-emitted PC.
- **Verification role:** golden PC checking and owner-identity counter
  invariants protect architectural identity during frontend changes. They are
  not pipeline mechanisms.
- **Excluded from active frontend architecture:** legacy loop buffer revival,
  standalone UOC replay, same-line handoff, same-FTQ tail carry, static
  direction shortcuts, sequential lookahead, weak static branch bias, and
  decode/rename/commit widening.

### 2.2 BPU: TAGE-SC-L (`src/rtl/core/bpu/tage_sc_l.sv`)

- **Bimodal base table:** 4096 entries (`TAGE_BASE_ENTRIES`)
- **Tagged tables:** 4 tables × 256 entries each (`TAGE_NUM_TABLES=4`, `TAGE_TABLE_ENTRIES=256`), 12-bit tags
- **Statistical Corrector (SC):** 1024 entries
- **Loop predictor:** 64 entries (`LOOP_PRED_ENTRIES=64`)
- **GHR:** 64 bits (`GHR_BITS=64`)
- **Per-PC mispredict instrumentation** (`+PERF_PROFILE`): top mispredict PCs reported at end of run
- **Reference note:** the BPU includes a large BTB, TAGE tables, SC, loop
  predictor, and RAS. Comparative sizing notes live in the reference-core audit
  docs, not in this spec.

### 2.3 BTB (`src/rtl/core/bpu/btb.sv`)

- **Geometry:** 2048 entries, 8-way set-associative, 256 sets (`BTB_ENTRIES=2048`, `BTB_WAYS=8`, `BTB_SETS=256`)
- **Indexed by:** cache-line address; per-line stores byte offset of each control-flow site
- **Replacement:** round-robin per set
- **Read latency:** combinational (same cycle as fetch)
- **Lookup output:** primary hit + alternate hit (for two control transfers in same line)

### 2.4 RAS (`src/rtl/core/bpu/ras.sv`)

- **Depth:** 24 (`RAS_DEPTH`)
- **Push:** call instructions at predict time
- **Pop:** ret instructions at predict time
- **Restore:** on flush, RAS depth is restored from checkpoint

### 2.5 NLP — Next-Line Prefetch Buffer (`src/rtl/core/frontend/ifu/next_line_prefetch_buffer.sv`)

- **Entries:** 4 (`NUM_ENTRIES=4`)
- **Purpose:** small prefetch buffer for sequential-access lines (warm-cache helper, not primary predictor)
- **Integration:** reached through `frontend/ifu/ifu_line_fetch.sv`, which
  retimes NLPB hits and only exposes them as line data when the response line
  matches the current IFU work cursor.

### 2.6 UOP Cache (UOC) (`src/rtl/core/uop_cache/uop_cache.sv`)

- **Geometry:** 32 sets × 8 ways × 4 µops/entry = 1024 µop slots (`UOC_SETS=32`, `UOC_WAYS=8`, `UOC_PER_ENTRY=PIPE_WIDTH=4`)
- **Indexed by:** fetch-group start PC
- **Replacement:** tree-pLRU (7-bit per set)
- **Architectural role:** not currently the authoritative frontend backbone. A
  decoded-op cache can only be enabled behind the same owner, redirect, fill,
  invalidation, and branch/exit prediction contract as normal fetch delivery.
- **Comparison:** modeled after Intel DSB, AMD Zen op-cache, and Arm macro-op caches; this repo uses the single local name "UOP cache" / `UOC`
- **Inactive replay path:** standalone UOC replay plusargs are simulation
  experiments only. The default core architecture keeps decoded-op replay
  inactive unless it is integrated through FTQ-owned delivery.

### 2.7 Legacy Loop Buffer

- **Status:** removed from the active RTL. `src/rtl/core/loop_buffer.sv` is
  deleted and no loop-buffer instance is present in `rv64gc_core_top.sv`.
- **Compatibility counter:** the simulator may still print a legacy activity
  counter so old tooling can confirm the removed path is inactive.
- **Replacement architecture:** prediction, loop-exit state, redirect identity,
  and packet delivery are owned by the BPU/FTQ fetch-block contract, not by a
  local replay buffer.
- **Excluded local shortcuts:** same-line handoff, same-FTQ tail carry,
  guarded loop-tail lookahead, sequential lookahead, and weak static branch
  bias are not implementation candidates because they do not preserve general
  fetch-block ownership.

### 2.8 Decode (`src/rtl/core/decode/decode.sv`, `decode_slice.sv`)

- **Width:** 4 slices/cycle
- **RVC handling:** `src/rtl/core/frontend/instr/rvc_decompress.sv`
  expands compressed to 32-bit equivalents pre-decode
- **Output:** 4 decoded uops with `fu_type` (ALU/BRU/MUL/DIV/LOAD/STA/STD/CSR), source/dest arch regs, immediate, control flags

### 2.9 Fusion Detector (`src/rtl/core/decode/fusion_detector.sv`)

- **Adjacent-pair fusion** at decode (e.g., `auipc + addi` → `LI64`)
- **Status:** detection logic present; commit_count statistics in PERF_PROFILE include fused vs non-fused breakdown
- **BRU fused-immediate contract:** fused `slti/sltiu + beq/bne` branches must
  carry the compare immediate separately from the branch redirect offset. The
  BRU consumes `fused_imm` for the compare and uses the branch op to invert the
  equality sense for BEQ versus BNE. This is a correctness contract, not a
  frontend ownership mechanism.

### 2.10 Frontend Queues

- **FTQ (Fetch Target Queue):** 24 entries (`FTQ_DEPTH=24`), 16-bit alloc tag.
  Current RTL has separate allocation-to-request, request-to-writeback, and
  writeback-to-commit counts, current IFU request owner, current IFU-writeback
  owner, next IFU-writeback owner after same-cycle pop/request movement, and
  commit/training owner aliases. Decode/commit visibility is advanced by an
  explicit first-packet delivery push, not by final IFU-owner completion, so a
  single FTQ owner can remain active in the IFU while already being visible to
  the decode/commit side. The FTQ is already the right place to own
  prediction-block metadata.
- **FTQ ownership gaps:** the current RTL has an explicit monolithic IFU request
  valid/ready/fire boundary. Remaining gaps are redirect/epoch lifetime for
  outstanding I-cache responses, clear squashing rules for younger predicted
  owners, and converting the IFU work cursor from lockstep packet processing to
  a capacity-bounded FTQ/IBuffer-driven work item. These belong in `ftq.sv` and
  the IFU/IBuffer boundary before proactive F1 runahead is enabled.
- **I-cache response queue** (`icache_resp_queue.sv`): 4-entry line-response
  FIFO instantiated by `frontend/ifu/ifu_line_fetch.sv`. It is an elasticity
  mechanism, not the architectural owner. It carries request PC, explicit
  response-line address, FTQ identity, and the full FTQ entry snapshot, but it
  must not decide correctness by local stale-entry filtering. F2 accepts only
  matching-line responses; flushed responses are drained by invalid/stale FTQ
  epoch metadata. It accepts a replacement response on a full-plus-pop cycle so
  a one-cycle I-cache response is not dropped when F2 frees a slot at the same
  edge.
- **Owner-aware IBuffer**
  (`src/rtl/core/frontend/ibuffer/ibuffer.sv`): current wrapper between IF2 and
  decode; wraps `fetch_packet_buffer.sv`, which stores complete fetch packets
  with per-packet FTQ
  idx/epoch/alloc-tag, block PC, start offset, IFU line address/reuse bit,
  per-slot PCs, predicted-control metadata, and `owner_complete`. The IFU line
  address names the cache-line data used by F2; for a line-straddling 32-bit
  instruction, slot 0 may still have a PC in the previous line. It exposes head
  owner match/stale/complete signals for FTQ commit-pop. Decode-accept tracking
  and proactive runahead capacity rules are still future work.

---

## 3. Rename + Map Tables + Free List + Checkpoints

### 3.1 Rename (`src/rtl/core/rename/rename.sv`)

- **Width:** 4 slots/cycle
- **Per-slot independent advance:** each slot can stall independently without holding back others (eliminates the 6-wide group-hold artifact)
- **Move/zero elimination:** `mv rd, rs1`, `addi rd, rs1, 0`, `xor rd, rd, rd`, `li rd, 0` are eliminated at rename — bypassed to commit without consuming FU/IQ resources
- **Stall reasons** (per-slot, instrumented in `+PERF_PROFILE` rename summary):
  - `has_preg=0`: free list empty (pdst allocation)
  - `has_rob=0`: ROB full
  - `has_ckpt=0`: checkpoint pool full
  - `has_lq=0`: LQ full (loads only)
  - `has_sq=0`: SQ full (stores only)
  - `has_dq=0`: dispatch queue full

### 3.2 RAT — Register Alias Table (`src/rtl/core/rename/rat.sv`)

- **Speculative RAT:** 32 entries (one per arch reg), maps arch → phys
- **Committed RAT (cRAT):** 32 entries, updated only at commit; restore source on flush
- **Per-slot read/write ports for 4-wide rename**

### 3.3 Free List (`src/rtl/core/rename/free_list.sv`)

- **Mechanism:** bitmap-based, 128-bit (`INT_FREE_LIST_DEPTH = INT_PRF_DEPTH - ARCH_REGS = 128`)
- **Allocation:** up to 4 pdsts per cycle from priority encoder over free bitmap
- **Release:** at commit (old pdst), or at flush (full restore from committed bitmap)
- **Min-popcount sampling:** instrumented to track underutilization

### 3.4 Checkpoints (`src/rtl/core/rename/checkpoint.sv`)

- **Capacity:** 64 checkpoints (`NUM_CHECKPOINTS=64`)
- **Allocation:** at branch rename time
- **Restore:** at BRU mispredict (full pipeline rewind to checkpoint state); also fires on commit-time architectural flush
- **Instrumentation:** save/release counts, max-occupied, full-pre-release vs full-after-release cycles

---

## 4. Dispatch

### 4.1 Decode/Dispatch Queues

- **Decode queue:** 32 entries (`DECODE_QUEUE_DEPTH=32`); buffers decoded uops between rename and dispatch
- **DQ_INT:** 32 entries (`DQ_INT_DEPTH=32`); INT-bound uops waiting to enter INT IQs
- **DQ_MEM:** 32 entries (`DQ_MEM_DEPTH=32`); LD/STA/STD waiting for LSU IQs
- **DQ_FP:** 16 entries (`DQ_FP_DEPTH=16`); FP-bound uops

### 4.2 Routing per fu_type → IQ

`uarch_pkg::fu_type_e`:

- `FU_ALU=0` → INT IQ (which IQ depends on dispatch routing — see §5.1)
- `FU_BRU=1` → INT IQ (typically u_iq0)
- `FU_MUL=2` → INT IQ u_iq1 (co-located with ALU2)
- `FU_DIV=3` → INT IQ u_iq2 (co-located with ALU3+CSR)
- `FU_LOAD=4` → MEM IQ u_iq_ldst (load)
- `FU_STA=5` → MEM IQ u_iq_st_addr (store address)
- `FU_STD=6` → MEM IQ u_iq_st_data (store data)
- `FU_CSR=7` → INT IQ u_iq2 (co-located with ALU3+DIV)

The dispatch routing is in `src/rtl/core/dispatch/dispatch_queue.sv`.

---

## 5. Issue + Wakeup + Speculative Wakeup

### 5.1 Issue Queues

**6 IQs total**, parameterized by `issue_queue` module (`src/rtl/core/issue/issue_queue.sv`):

| IQ | Depth | NUM_ENQUEUE | NUM_SELECT | FUs served |
|---|---:|---:|---:|---|
| `u_iq0` | 24 | 2 | **2** | ALU0 + ALU1 + BRU0 + BRU1 |
| `u_iq1` | 24 | 2 | 1 | ALU2 + MUL |
| `u_iq2` | 24 | 2 | 1 | ALU3 + DIV + CSR |
| `u_iq_ldst` | 32 | 2 | 2 | Load AGU (2 ports: Load0 + Load1) |
| `u_iq_st_addr` | 32 | 2 | 1 | Store address AGU |
| `u_iq_st_data` | 32 | 2 | 1 | Store data |

- **Total INT IQ capacity:** 72 entries (3×24); **total LSU IQ capacity:** 96 entries (3×32)
- **Max INT issue per cycle:** 4 (2+1+1)
- **Max LSU issue per cycle:** 4 (2 LD + 1 STA + 1 STD)
- **Theoretical peak:** 8 issues/cycle, but commit width is 4

### 5.2 Wakeup Network (`src/rtl/core/issue/wakeup_network.sv`)

- **CDB wakeup ports:** 4 (each IQ entry CAM-matches 4 CDB tags)
- **Load_wb wakeup ports:** 2 (Load0, Load1 — definitive wakeup, combinational)
- **Spec wakeup ports:** 2 (Load0, Load1 — fired at AGU time, 1 cycle BEFORE wb, allows consumer issue back-to-back with load wb on cache hit)

### 5.3 Speculative Wakeup Mechanism

For loads on cache hit:
- T: load AGU computes address → spec_wakeup fires → IQ marks load's pdst as ready
- T+1: load result on dcache S1 → wb fires → load_wb sideband broadcasts pdst+data
- T+1: consumer wakes via spec_wakeup, eligibility set
- T+2: consumer issues, reads operand via combinational bypass slot[3]/[4] (Load0/Load1)
- T+2: PRF write hasn't latched (will at T+3 edge), so bypass IS the only source

Cancellation: if cache miss, spec_wakeup is canceled; consumer must wait for actual wb.

### 5.4 Issue Selection Policy

Per `issue_queue.sv`:
- **Eligibility:** `entry_valid AND src1_ready AND src2_ready` (combinational from `next_src*_ready`)
- **Port 0:** oldest eligible entry (minimum ROB age)
- **Port 1:** second-oldest eligible entry (excluding port 0 winner)

---

## 6. Execute

### 6.1 Functional Units

| FU | Module | Count | Hardware Latency | Pipelined? | CDB slot |
|---|---|---:|---:|---|---|
| ALU0 | `alu.sv` | 1 | 0 (combinational) | N/A | CDB[0] |
| ALU1 | `alu.sv` | 1 | 0 | N/A | CDB[1] |
| ALU2 | `alu.sv` | 1 | 0 | N/A | CDB[2] (shared with MUL) |
| ALU3 | `alu.sv` | 1 | 0 | N/A | CDB[3] (shared with DIV+CSR) |
| BRU0 | `bru.sv` | 1 | 1 cycle | N/A | CDB[0] (shared with ALU0) |
| BRU1 | `bru.sv` | 1 | 1 cycle | N/A | CDB[1] (shared with ALU1) |
| MUL | `multiplier.sv` | 1 | 1 cycle | combinational + reg | CDB[2] |
| DIV | `divider.sv` | 1 | multi-cycle FSM (~30+ cyc) | No | CDB[3] |
| CSR | `csr_file.sv` | 1 | serializing (multi-cycle) | No | CDB[3] |

**Note on ALU latency:** ALU is purely combinational. The "1 cycle issue→cdb" latency comes from the registered CDB stage between execute and the bypass/PRF write.

**Note on stale `MUL_LATENCY` parameter:** `rv64gc_pkg.sv` declares `MUL_LATENCY = 3`, but the actual `multiplier.sv` is 1-cycle (per its source comment "Latency from valid_in to valid_out is now 1 cycle"). The `MUL_LATENCY` parameter may be a stale wakeup-scheduling hint; needs investigation.

### 6.2 Bypass Network (`src/rtl/core/bypass_network.sv`)

`NUM_BYPASS_SRCS = 5` slots:

| Slot | Source | Timing |
|---|---|---|
| [0] | `cdb_data_r[0]` (ALU0/BRU0) | Registered (1-cycle delay) |
| [1] | `cdb_data_r[1]` (ALU1/BRU1) | Registered |
| [2] | `cdb_data_r[2]` (ALU2/MUL) | Registered |
| [3] | `load_wb_data[0]` (Load0) | **Combinational** (0-cycle) |
| [4] | `load_wb_data[1]` (Load1) | **Combinational** — added at `cd54cf1` to restore Load1 bypass coverage |

**ALU3/DIV/CSR (CDB[3]) is NOT bypassed.** Consumers of CDB[3]
producers fall back to PRF read at T+3 (1 extra cycle vs bypass).

The bypass mux at each ALU operand selects between PRF read result and any matching bypass source.

### 6.3 Critical Bypass Timing Note

For LOADS [slot 3, 4] — combinational bypass is REQUIRED:
- Spec wakeup fires consumer at T+2
- PRF write doesn't latch until T+3
- Without combinational bypass at T+2, consumer reads stale PRF → spurious result

During the 4-wide transition, `NUM_BYPASS_SRCS` was reduced from 6 to 4 with
only Load0 restored. Load1 consumers could then wake up without a matching
combinational bypass path and read stale PRF data. Commit `cd54cf1` restores
the Load1 bypass slot.

---

## 7. Load/Store Unit

### 7.1 Module Structure

- `lsu.sv`: top-level LSU (AGU, dcache request, load wb path, store-forward, replay)
- `load_queue.sv` (LQ): 32 entries (`LQ_DEPTH=32`)
- `store_queue.sv` (SQ): 32 entries (`SQ_DEPTH=32`)
- `committed_store_buffer.sv` (CSB): 32 entries (`CSB_DEPTH=32`); committed-but-not-drained stores

### 7.2 Load Pipeline

- **Issue → AGU (S0):** address computation in IQ select cycle
- **Tag/Data lookup (S1):** dcache 1 cycle (2-stage pipeline: S0 issue, S1 tag/data/way-select)
- **WB at T+2:** combinational bypass slot[3] or [4] active
- **2 load ports:** Load0 (port 0), Load1 (port 1)
- **Spec wakeup:** fires at AGU time (T+1) — consumer can issue at T+2 with combinational bypass

### 7.3 Store Pipeline

- **STA (store address):** 1 issue port, AGU computes address, allocates SQ entry
- **STD (store data):** 1 issue port, captures store data
- **Store-forward:** loads check SQ for matching address; full forward if size matches, partial forward if not

### 7.4 LMB / MSHR

- **L1D MSHR depth:** 16 (`L1D_MSHR_DEPTH=16`)
- **Allocation:** on dcache miss; subsequent loads to same line merge into existing MSHR

### 7.5 load_wb Sideband

Originally CDB carried load writebacks (CDB[4]/[5] in 6-wide). When CDB shrank 6→4, loads needed a new path:
- Dedicated 2-port `load_wb` sideband (Load0, Load1)
- Each port has: pdst, data, valid signals
- Definitive wakeup port in IQs (`load_wb_wk_valid0/1`)
- Used for both bypass (slot 3, 4) and PRF write (PRF write port 4, 5)

**INT PRF write ports:** 4 (CDB) + 2 (load_wb sideband) = 6 total (`PRF_WRITE_PORTS=6`).

### 7.6 LSU Misalign-Hold Fast Path

`src/rtl/core/lsu/lsu.sv` contains a misalign-hold special case that is part of
the current LSU behavior. Changes to this path require targeted load/store
correctness checks and pipeline-counter review.

### 7.7 Per-Port LSU Pressure Counters (PERF_PROFILE)

- `ld0_candidate / ld0_issue / ld0_suppress`
- `ld1_candidate / ld1_issue / ld1_suppress`
- `sq_fwd_wait` (load waiting for store-forward)
- `storeIQ_block_ld0/1` (load blocked by store IQ activity)
- `p0/p1 same_cycle/csb_hit` (forwarding fast paths)
- `sq_wait_p1`, `p1_wait_req`, `p1_dcache_conflict`
- Load latency histogram (10 buckets: 0/1/2/3/4/5/6-7/8-15/16-31/32+)

---

## 8. Writeback + Common Data Bus + PRF

### 8.1 CDB

- **Width:** 4 (`CDB_WIDTH=4`)
- **Routing:**
  - CDB[0] ← ALU0 OR BRU0 (arbitrated)
  - CDB[1] ← ALU1 OR BRU1
  - CDB[2] ← ALU2 OR MUL
  - CDB[3] ← ALU3 OR DIV OR CSR
- **Registered:** CDB outputs are registered; consumers see results 1 cycle after wb fires (via bypass slot[0..2]) or 2 cycles later (via PRF read)

### 8.2 INT PRF (`src/rtl/core/regfile/int_prf.sv`)

- **Depth:** 160 (`INT_PRF_DEPTH=160`); 32 arch + 128 rename temps
- **Read ports:** 12 (3 ALU × 2 srcs + 2 BRU × 2 srcs + 1 MUL × 2 srcs = 14 demand, but tagged via bank/conflict logic to 12)
- **Write ports:** 6 (4 CDB + 2 load_wb)
- **Read latency:** 1 cycle (registered output)
- **p0 (zero) suppress:** PRF reads of p0 always return 0; CDB writes to p0 are suppressed

### 8.3 FP PRF

- **Depth:** 96 (`FP_PRF_DEPTH=96`)
- (FP path is implemented but not the focus of perf work)

---

## 9. Commit + ROB

### 9.1 ROB (`src/rtl/core/backend/rob.sv`)

- **Depth:** 128 entries (`ROB_DEPTH=128`)
- **Index bits:** 7 (`ROB_IDX_BITS=7`)
- **Per-entry state:**
  - Architectural rd, pdst, old_pdst
  - `wb_done` flag (set on CDB write or load_wb sideband)
  - `is_load`, `is_store`, `is_branch`, `is_csr`, `is_mul`, `is_div`, `is_bru` flags
  - `is_fence`, `is_fencei`, `is_mret`, `is_sret`, `is_sfence_vma`, `is_ecall`, `is_wfi` flags
  - PC (for trace), exception code

### 9.2 Commit (`src/rtl/core/backend/commit.sv`)

- **Width:** 4 (`COMMIT_WIDTH=4`)
- **Policy:** in-order, head-prefix
  - Read head + 3 next slots' `wb_done` flags
  - Commit count = consecutive ready uops starting from head
  - If head not ready: commit_count = 0
  - If head ready but slot 1 isn't: commit_count = 1
  - Etc.

### 9.3 Head WB Bypass (`rob.sv` instrumentation summary)

- **Same-cycle wb→commit bypass:** if head's CDB write happens in the same cycle as commit reads head_ready, the bypass forwards the result directly (saves 1 cycle of head-wait)
- **Per-slot bypass:** slot 1 / slot 2 also have wb-bypass paths (extends to commit-window prefix)
- **Per-class instrumentation:** load/store/branch/serial/other bypass-fire counts
- **For cm:** 17,470 head-load-wb-bypass fires + 46,440 head-arith-wb-bypass fires (active mechanism)

### 9.4 Head-Stall Instrumentation

- `rob_head_not_ready_cyc` (94k cycles for cm)
- Class breakdown: load/store/branch/serial/other
- Other-sub-class (added 2026-05-01): mul/div/csr/bru/unknown
- Per-PC head-stall sample table (top 32 PCs)

---

## 10. Cache Hierarchy

### 10.1 L1 I-Cache (`src/rtl/core/cache/icache.sv`)

| Param | Value |
|---|---|
| Size | 32 KB (`L1I_SIZE=32768`) |
| Associativity | 4-way (`L1I_WAYS=4`) |
| Sets | 128 (`L1I_SETS=128`) |
| Line size | 64 B (`LINE_SIZE=64`) |
| Hit latency | 1 cycle (registered S1 address) |
| MSHR | (not separately specified; uses inline state) |

### 10.2 L1 D-Cache (`src/rtl/core/cache/dcache.sv`, `dcache_data_ram.sv`, `dcache_tag_ram.sv`)

| Param | Value |
|---|---|
| Size | 64 KB (`L1D_SIZE=65536`) |
| Associativity | 4-way (`L1D_WAYS=4`) |
| Banks | 2 (`L1D_BANKS=2`) |
| Sets | 256 (`L1D_SETS=256`) |
| Line size | 64 B |
| Hit latency | **2 cycles total (S0 issue + S1 tag/data/way-select)** |
| Load-to-use | **3 cycles** (issue → AGU → S0 → S1 wb → consumer issue at T+2 via combinational bypass) |
| MSHR depth | 16 (`L1D_MSHR_DEPTH=16`) |
| Banking | Implicit via dual-port RAM |

### 10.3 L2 Cache (`src/rtl/core/cache/l2_cache.sv`)

| Param | Value |
|---|---|
| Size | 2 MB (`L2_SIZE=2097152`) |
| Associativity | 8-way (`L2_WAYS=8`) |
| Sets | 4096 (`L2_SETS=4096`) |
| Hit latency | 8 cycles (`L2_HIT_LATENCY=8`) |
| MSHR depth | 32 (`L2_MSHR_DEPTH=32`) |

---

## 11. Performance Instrumentation

All gated on `+PERF_PROFILE` plusarg unless otherwise noted.

### 11.1 Per-Cycle Counters (Aggregated)

- **Stall breakdown:** rename_stall, backend_stall, rob_full, dq_full, lq_full, sq_full, iq{0,1,2}_full
- **Rename slot-attribution:** stall_{preg,ckpt,rob,dq,other}
- **Issue-stall classification (added 2026-05-01):** operand_not_ready, fu_contention, arb_loss
- **IQ avg occupancy:** iq{0,1,2}_avg
- **Flush count:** total + per-cause (mispredict, exception, replay, ret, interrupt)

### 11.2 Histograms

- **`commit_hist[0..6]`:** cycles where commit_count = N (the bubble distribution)
- **`fetch_hist[0..6]`:** cycles where fetch_count = N
- **`frontend_hist[0..6]`:** cycles where rename sees N instructions
- **`fused_hist[0..6]`:** non-LB cycles, fused_count distribution
- **`uoc_replay_hist[0..6]`:** standalone decoded-op replay distribution
- **`load_lat_hist[10 buckets]`:** load issue-to-WB latency

### 11.3 ROB Head-Stall Detail (`rob.sv` final block)

- `rob_head_not_ready_cyc` (per-class: load/store/branch/serial/other)
- Other-sub-class: mul/div/csr/bru/unknown (added 2026-05-01)
- `rob_head_wb_bypass_cand_cnt` + per-class
- `rob_head_load_wb_bypass_fires`, `rob_head_arith_wb_bypass_fires`
- Slot1/Slot2 wb_bypass fires
- Top 32 head-not-ready PCs with class breakdown

### 11.4 LSU Pressure Detail

(See §7.7)

### 11.5 BPU Detail

- Top mispredict PCs with cond/jal/jalr/call/ret split + taken/not-taken
- Loop predictor hot-PC summary (per-PC lookup/hit/override counters)
- BPU hot-PC summary (per-table override counts)
- GHR / RAS restore counts

### 11.6 Per-Cycle Pipeline Trace (gated on `+TRACE_PIPELINE`)

`[PIPE schema=pipe.v1]` — emits per cycle:
- `cyc, rst, fetch, decode, rename, dispatch, issue0, issue1, issue2, cdb, commit`
- `rob_head, rob_tail, rob_cnt, iq0, iq1, iq2, lq, sq, free, ckpt`
- `flush, replay, reason`

Used by `tools/bubble_taxonomy.py` and `tools/headwait_deepdive.py` for per-cycle bubble classification.

### 11.7 Other Traces (gated on specific plusargs)

- `+TRACE_HEAD_STALL`: per-cycle head PC + flags
- `+TRACE_LOWPC`: per-uop tracking through fetch/decode/rename/dispatch/issue/commit
- `+TRACE_CM`: workload-specific progress markers
- `[CPC]`, `[DEP schema=dep.v1]`: per-uop committed PC + dependency info

---

## 12. Tools

| Tool | Path | Purpose |
|---|---|---|
| `bubble_taxonomy.py` | `tools/bubble_taxonomy.py` | Per-cycle bubble classification from pipe.v1 trace |
| `headwait_deepdive.py` | `tools/headwait_deepdive.py` | Little's-law decomposition + head-dwell analysis |
| `clockcheck` | `../rv64gc-perf-model/tools/rtl_clockcheck.py` | Per-cycle pipeline trace divergence check vs baseline |
| `regress_dsim.sh` | `scripts/regress_dsim.sh` | Functional regression runner; tightened STOP-OK detection requires an explicit pass event, not just a `TOHOST=` print |
| `build_dsim.sh` | `build_dsim.sh` | Top-level DSim image build |
| `run_dsim.sh` | `run_dsim.sh` | Single-test DSim invocation |

---

## 13. Documentation Index

- `doc/rv64gc_v2_uarch.md` — this document; architectural specification only.
- `doc/stage1_frontend_refactor_status_2026-05-06.md` — frontend refactor
  status, performance methodology, raw rows, and evaluation status.
- `doc/competitor_analysis.md` — external core architecture references and
  comparison methodology.
- `doc/archive/4wide/` — historical pivot notes, run reports, and retired
  analysis artifacts.

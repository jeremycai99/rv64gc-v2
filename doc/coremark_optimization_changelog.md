# CoreMark IPC Optimization Changelog

**IPC progression**: 0.45 → 0.87 → 2.10 → 2.76 → 2.98 → 2.73 → 2.80 → **3.33**

All 23 regression tests pass. Verilator converge-limit = 500 (default).
Conservative signoff: **3.33 IPC** (cross-validated CSR + VCD, +11% over 3.0 target).

---

## 1. Correctness Fixes (from prior session, prerequisite)

### 1a. Icache L2 fill_resp_addr filter
**Files**: `icache.sv`, `fetch_unit.sv`, `rv64gc_core_top.sv`

The L2 hit-pipe re-emits earlier responses 8 cycles after delivery (stages
not invalidated). The icache was accepting stale replays as fresh fills.
Added `fill_resp_addr` port; icache now compares `fill_resp_addr` against
its `miss_addr_q` before accepting a fill.

### 1b. LSU AUIPC+LD/ST fusion AGU
**Files**: `lsu.sv`

Fused AUIPC+load/store uops used `rs1` (= x0 for fused ops) instead of `pc`
for the AGU base. Added `is_fused` mux: `eff_addr = is_fused ? pc + imm : rs1 + imm`.

### 1c. LSU load_rs1 port crossing
**Files**: `rv64gc_core_top.sv`

The packed concat `{bypassed_data[9], bypassed_data[8]}` mapped port 0's rs1
to port 1's bypass and vice versa (SystemVerilog brace-list MSB-first vs
unpacked-array index-0-first). Replaced with explicit per-index assignment.

---

## 2. BTB Offset-Based Truncation (IPC 0.45 → 0.87)
**Files**: `btb.sv`, `fetch_unit.sv`

**Problem**: Every BTB hit truncated the fetch group to 1 instruction
(`bp_truncated_count = 1`). The BTB had no record of WHICH instruction in
the group was the branch, so it conservatively kept only slot 0.

**Fix**: Added a 6-bit `branch_offset` field to the BTB (stores `update_pc[5:0]`).
On lookup, the fetch unit scans extracted slots for one whose `slot_pc[5:0]`
matches `f2_btb_offset_r`. Truncation happens at the matching slot + 1.
If no slot matches (aliased BTB hit), all instructions are emitted — this
also fixed the CoreMark livelock from BTB bit-[1] aliasing.

---

## 3. BPU Update Type (enables RAS prediction)
**Files**: `rv64gc_core_top.sv`, `rob.sv`

**Problem**: BTB update type was hardcoded to `BT_COND` or `BT_JAL`. Returns
and indirect calls were never stored as `BT_RET`/`BT_CALL`, so the RAS
never pushed or popped.

**Fix**: Compute the branch type at dispatch from `br_op`, `rd_arch`,
`rs1_arch` (CALL = JAL/JALR with rd=x1|x5; RET = JALR with rs1=x1|x5,
rd=x0). Store in a 3-bit `bpu_type_r` field in the ROB. Output at commit
for the BPU update. Also added RAS empty guard (don't predict BT_RET when
`ras_pop_addr == 0`).

---

## 4. Forwarding Hold Register (breaks Verilator convergence loop)
**Files**: `lsu.sv`, `store_queue.sv`, `committed_store_buffer.sv`

**Problem**: A structural combinational loop through
`CDB → bypass → IQ eligible → issue → load_eff_addr → SQ fwd → load_wb → CDB`
caused Verilator `DIDNOTCONVERGE` whenever pipeline utilization increased.

**Fix (3 parts)**:

1. **Address gating**: SQ `fwd_req_addr`, CSB `fwd_addr`, and
   `same_cycle_addr_match` are gated on `load_issue_valid[0]`. When no load
   issues, addresses are forced to 0, preventing stale values from driving
   the forwarding CAM.

2. **CAM valid gating**: SQ and CSB `addr_match` now includes `fwd_req_valid`
   / `fwd_valid` as a guard, preventing comparison when no load is active.

3. **Forwarding hold register**: Same-cycle SQ/CSB forwarding results and
   misalign exceptions are captured into a 1-cycle hold register instead of
   driving `load_wb` immediately. The CDB fires at T+1 instead of T,
   breaking the combinational loop. Normal dcache-hit loads remain 2-cycle
   latency. Only same-cycle forwarded loads (rare) get +1 cycle.

---

## 5. BRU Early Fetch Redirect (IPC 0.87 → 2.10)
**Files**: `rv64gc_core_top.sv`, `commit.sv`

**Problem**: Branch mispredicts were only detected at commit time. Fetch
continued on the wrong path until the mispredicting instruction reached the
ROB head (~8 cycles later), then a full pipeline flush redirected fetch.

**Fix**: Added `bru_early_redirect` signal: when the BRU resolves a mispredict
at execute time, it immediately redirects the fetch unit to `bru_target`.
The commit module still does a full pipeline flush when the branch reaches
the head (for ROB/IQ/LQ/SQ cleanup). The early redirect saves ~5 cycles
of wrong-path fetch.

Fetch redirect mux: `redirect_valid = flush_out.valid || bru_early_redirect`,
with `flush_out` taking priority.

---

## 6. 1-Cycle Redirect Bubble (IPC 2.10 → 2.76)
**Files**: `fetch_unit.sv`

**Problem**: Each BPU redirect (predicted taken branch) caused a 2-cycle
fetch bubble: cycle T (redirect), T+1 (icache lookup at new PC), T+2
(data available). 52% of cycles had BPU redirects → 40%+ bubble cycles.

**Fix (2 parts)**:

1. **Icache request bypass**: On `f2_bpu_redirect`, the icache request
   address is combinationally muxed to the redirect target instead of
   waiting for `f1_pc` to update: `ic_req_addr = f2_bpu_redirect ? target : f1_pc`.

2. **f2_pc bypass**: On `f2_bpu_redirect`, the `f2_pc_r` register is set
   to the redirect target at the next edge (new `else if` branch in the
   f2 pipeline register update). This ensures the icache response at T+1
   matches the expected PC, allowing immediate instruction extraction.

Result: redirect bubble reduced from 2 cycles to 1 cycle.

---

## 7. Loop Buffer All-Slot Trigger (IPC 2.76 → 2.98)
**Files**: `rv64gc_core_top.sv`, `loop_buffer.sv`

**Problem**: The loop buffer trigger (`backward_branch_taken`) only checked
`fused_insn[0]` — slot 0. Backward branches in CoreMark's inner loops land
at later slots (since BPU truncation puts the branch at the LAST slot of
the group). The loop buffer never activated.

**Fix**: Scan all 6 slots for a backward taken branch using a REGISTERED
`always_ff` block. The 1-cycle registration delay is necessary because
reading `fused_insn[1..5]` in a combinational context changes Verilator's
evaluation scheduling (a known Verilator artifact that corrupts load
writeback timing). The delay only means the loop buffer starts capturing
1 cycle later — negligible impact.

Also added a capture-overflow guard in `loop_buffer.sv`: if `cap_len >= DEPTH`
during CAPTURING, the state machine returns to IDLE instead of wrapping.

**Result**: CoreMark's hottest loop (21 instructions, `core_list_init`) is
captured and replayed from the loop buffer. Fetch delivers 6 instructions
every cycle (100%), IC miss drops to 0%, backend stall drops to 0%.

---

---

## 8. SQ/LQ Power-of-2 Depths + Load Writeback Flush Gating (IPC 2.98, correctness)
**Files**: `rv64gc_pkg.sv`, `lsu.sv`

LQ/SQ depth changed from 48 to 64 (power-of-2) to fix pointer-wrap
overflow after full flush. CSB depth 24→32. Load writeback de-gated from
flush (dcache response must write back even on same-cycle flush).

---

## 9. Dispatch Load Cap + Preg Ready Table + Single-Select Load IQ (IPC 2.98 → 2.73)
**Files**: `dispatch_queue.sv`, `rv64gc_core_top.sv`, `issue_queue.sv`

Three fixes for Dhrystone correctness:
1. **Dispatch load cap**: limit to 2 loads/cycle matching load IQ NUM_ENQUEUE.
2. **Combinational preg_ready_table**: feed IQs with version including current
   rename clears to prevent stale enrollment after flush.
3. **Single-select load IQ**: NUM_SELECT=1 workaround for single-ported dcache
   tag RAM (port-1 starvation). Dropped CoreMark from 2.98 to 2.73.

---

## 10. Dual-Port Dcache Tag/Data RAM (IPC 2.73 → 2.80)
**Files**: `dcache_tag_ram.sv`, `dcache_data_ram.sv`, `dcache.sv`, `rv64gc_core_top.sv`

Added second read port (port B) to both dcache tag and data RAMs. Load
port 1 uses independent tag/data ports — no bank-conflict suppression
needed. Restored load IQ to NUM_SELECT=2.

---

## 11. Dual BRU on IQ0 (IPC 2.80 → 3.33)
**Files**: `rv64gc_core_top.sv`

CoreMark's hot loop has 7 instructions with 2 branches. Single BRU was
the bottleneck (1 branch/cycle → 2.5 cycles/iteration). Added BRU1 on
IQ0 port 1 (combinational, zero area cost). Removed PORT0_ONLY_FU
restriction. Both branches resolve in 1 cycle → 2 cycles/iteration.

BRU0-only early redirect: only the oldest branch (port 0) triggers
early fetch redirect. Port 1 defers to commit flush to prevent
wrong-path redirect storms from younger speculative branches.

---

## 12. CSR Write-Op Pipeline (correctness, fixes -O3 hang)
**Files**: `rv64gc_core_top.sv`, `rob.sv`, `commit.sv`

`write_op` to the CSR file was hardcoded to CSRRW (2'b00). CSRRS with
rs1=x0 (a read-only alias per RISC-V spec) was treated as CSRRW with
write_data=0, resetting mcycle every time the benchmark read the cycle
counter. Threaded `csr_op` through CDB→ROB→commit. Gated `csr_we` on
actual write (CSRRW always, CSRRS/CSRRC only when rs1 value ≠ 0).

---

## 13. RTL Coding Convention Refactoring (no IPC change)
**Files**: 14 RTL files + tage_sc_l.sv

Removed all 48 `automatic` variable declarations and 2 `function
automatic` definitions from synthesizable RTL. Converted to module-level
signals with `always_comb`/`assign`. tage_sc_l.sv unpacked array
parameter converted to wire array for iverilog compatibility.

---

## Summary

| # | Change | Files | IPC effect |
|---|--------|-------|-----------|
| 1a | Icache L2 fill filter | icache, fetch_unit, core_top | correctness |
| 1b | AUIPC+LD/ST fusion AGU | lsu | correctness |
| 1c | load_rs1 port crossing | core_top | correctness |
| 2 | BTB offset truncation | btb, fetch_unit | 0.45 → 0.87 |
| 3 | BPU update type / RAS | rob, core_top, fetch_unit | enables RAS |
| 4 | Fwd hold register | lsu, store_queue, csb | convergence fix |
| 5 | BRU early redirect | core_top, commit | 0.87 → 2.10 |
| 6 | 1-cycle redirect bubble | fetch_unit | 2.10 → 2.76 |
| 7 | Loop buffer all-slot | core_top, loop_buffer | 2.76 → 2.98 |
| 8 | SQ/LQ power-of-2 + flush gate | rv64gc_pkg, lsu | correctness |
| 9 | Dispatch cap + preg table + 1-sel LQ | dispatch_queue, core_top, iq | 2.98 → 2.73 |
| 10 | Dual-port dcache | dcache_tag/data_ram, dcache, core_top | 2.73 → 2.80 |
| 11 | Dual BRU on IQ0 | core_top | 2.80 → 3.33 |
| 12 | CSR write-op pipeline | core_top, rob, commit | -O3 fix |
| 13 | automatic/function refactor | 14 files | convention |

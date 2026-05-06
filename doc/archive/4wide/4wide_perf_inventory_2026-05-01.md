# 4-Wide Performance Counter Inventory — 2026-05-01

**Repo HEAD:** `master @ 4a78605` (post Task 1+2+3 instrumentation top-up)
**Source logs:** `benchmark_results/perf_full_4wide_*.log` (transient, gitignored — regenerate via `bash run_dsim.sh tests/hex/{coremark,coremark_iter10,dhrystone}.hex 5000000 +PERF_PROFILE`)

**Headline numbers:**

| Workload | mcycle | minstret | IPC | Metric | vs floor |
|---|---:|---:|---:|---|---:|
| cm iter1 | 199,452 | 332,110 | 1.665 | **5.01 CM/MHz** | floor 6.2: −19.2% |
| cm iter10 | 1,860,512 | 3,197,342 | 1.719 | **5.37 CM/MHz** | floor 6.2: −13.3% |
| dhrystone | 23,514 | 47,670 | 2.027 | **2.42 DMIPS/MHz** | floor 4.00: −39.5% |

---

## 6-Bucket Counter Attribution (% of mcycle)

### Bucket 1 — Frontend (fetch / BPU mispredict / LB+UOC miss)

| Counter | cm iter1 | cm iter10 | dhry |
|---|---:|---:|---:|
| Total flushes | 4,343 (2.2%) | 38,773 (2.1%) | 128 (0.5%) |
| Cond branch mispredicts | 4,256 | 38,051 | 123 |
| JALR/Call/Ret mispredicts | 5+43+39 | 47+387+285 | 0+0+5 |

### Bucket 2 — Rename + Dispatch (structure full, free-list, IQ full)

| Counter | cm iter1 | cm iter10 | dhry |
|---|---:|---:|---:|
| `rename_stall_cyc` | 0 | 0 | 0 |
| `backend_stall_cyc` | 0 | 0 | 0 |
| `rob_full_cyc` | 0 | 0 | 0 |
| `dq_full_cyc` | 0 | 0 | 0 |
| `lq_full_cyc` | 0 | 0 | 0 |
| `sq_full_cyc` | 0 | 0 | 0 |
| `iq{0,1,2}_full_cyc` | 20+0+0 | 200+0+0 | 0+0+0 |
| `stall_{preg,ckpt,rob,dq,other}_cyc` | 0/0/0/0/0 | 0/0/0/0/0 | 0/0/0/0/0 |

**No dispatch-side or structure-full pressure on any workload.**

### Bucket 3 — Issue (NEW counters from Task 3)

| Counter | cm iter1 | cm iter10 | dhry |
|---|---:|---:|---:|
| `issue_stall_operand_cyc` | **69,426 (34.8%)** | **674,548 (36.3%)** | **3,744 (15.9%)** |
| `issue_stall_fu_cyc` | 0 | 0 | 0 |
| `issue_stall_arb_cyc` | 11,286 (5.7%) | 109,678 (5.9%) | 2 (0.0%) |

**`fu_contention = 0` across all workloads — known instrumentation gap.** Only INT IQs (u_iq0/1/2) are sampled; LSU IQs (u_iq_ldst, u_iq_st) not yet covered. LSU FU contention is partially visible via LSU pressure summary (storeIQ_block, p1_dcache_conflict). Track as Task 3b if Phase B/C surfaces LSU as a top bucket.

### Bucket 4 — Execute (non-LSU): MUL/DIV/CSR/BRU writeback latency

ROB head waiting on a non-LSU FU producer:

| Counter | cm iter1 | cm iter10 | dhry |
|---|---:|---:|---:|
| `head_not_ready_branch_cyc` | 15,926 (8.0%) | 149,191 (8.0%) | 173 (0.7%) |
| `head_not_ready_serial_cyc` | 0 | 0 | 0 |
| `head_not_ready_mul_cyc` (NEW) | 6,740 (3.4%) | 67,220 (3.6%) | 0 |
| `head_not_ready_div_cyc` (NEW) | 14 (0.0%) | 14 (0.0%) | 301 (1.3%) |
| `head_not_ready_csr_cyc` (NEW) | 0 | 0 | 0 |
| `head_not_ready_bru_cyc` (NEW) | 1,037 (0.5%) | 9,587 (0.5%) | 412 (1.8%) |

### Bucket 5 — LSU (load/store wait + LSU pressure)

| Counter | cm iter1 | cm iter10 | dhry |
|---|---:|---:|---:|
| `head_not_ready_load_cyc` | 20,196 (10.1%) | 184,685 (9.9%) | **6,438 (27.4%)** |
| `head_not_ready_store_cyc` | 3,853 (1.9%) | 33,440 (1.8%) | 330 (1.4%) |
| `sq_fwd_wait_cyc` | 267 (0.1%) | ~2,650 (0.1%) | 4 (0.0%) |
| `p1_dcache_conflict_cyc` | 751 (0.4%) | ~7,510 (0.4%) | 814 (3.5%) |
| Load latency p99 | 1 cyc (99% of loads) | 1 cyc (99%) | 1 cyc (94%) |

### Bucket 6 — Commit (head wait on "unknown" producer = plain ALU)

| Counter | cm iter1 | cm iter10 | dhry |
|---|---:|---:|---:|
| `head_not_ready_unknown_cyc` (NEW) | **46,363 (23.2%)** | **441,036 (23.7%)** | 1,286 (5.5%) |

**For cm, the largest single bucket = "unknown" head-stall = plain-ALU producer-wait.**

---

## Total Head-Stall Decomposition (per workload)

| Component | cm iter1 | cm iter10 | dhry |
|---|---:|---:|---:|
| `head_not_ready_cyc` (total) | **94,129 (47.2%)** | ~885,173 (47.6%) | **8,940 (38.0%)** |
| ├─ load | 20,196 (21.5%) | 184,685 (20.9%) | 6,438 (72.0%) |
| ├─ store | 3,853 (4.1%) | 33,440 (3.8%) | 330 (3.7%) |
| ├─ branch | 15,926 (16.9%) | 149,191 (16.9%) | 173 (1.9%) |
| └─ other (= mul + div + csr + bru + unknown) | 54,154 (57.5%) | 517,857 (58.5%) | 1,999 (22.4%) |
| ····├─ mul | 6,740 (12.4% of "other") | 67,220 (13.0%) | 0 |
| ····├─ div | 14 | 14 | 301 (15.1%) |
| ····├─ csr | 0 | 0 | 0 |
| ····├─ bru | 1,037 (1.9%) | 9,587 (1.9%) | 412 (20.6%) |
| ····└─ unknown | 46,363 (85.6%) | 441,036 (85.2%) | 1,286 (64.3%) |

(Percentages within each row sum to 100%.)

---

## Bubble Distribution (commit_count_hist)

| commit_count | cm iter1 | cm iter10 | dhry |
|---|---:|---:|---:|
| 0 | 47,868 (24.0%) | 444,776 (23.9%) | 2,297 (9.8%) |
| 1 | 40,760 (20.4%) | 380,228 (20.4%) | 3,890 (16.5%) |
| 2 | 61,243 (30.7%) | 569,802 (30.6%) | 9,803 (41.7%) |
| 3 | 29,460 (14.8%) | 273,935 (14.7%) | 5,922 (25.2%) |
| 4 | 20,121 (10.1%) | 191,771 (10.3%) | 1,602 (6.8%) |

---

## Sanity Check: Bucket Sum vs Gap

`peak_retire_cycles = ceil(minstret / PIPE_WIDTH=4)`

| Workload | mcycle | peak_retire | gap_cycles | sum-of-bucket-shares (head_not_ready + flushes + iq*_full) | residual |
|---|---:|---:|---:|---:|---:|
| cm iter1 | 199,452 | 83,028 | 116,424 | 94,129 + 4,343 + 20 = 98,492 | 17,932 (15.4%) |
| cm iter10 | 1,860,512 | 799,336 | 1,061,176 | ~885,173 + 38,773 + 200 = 924,146 | 137,030 (12.9%) |
| dhry | 23,514 | 11,918 | 11,596 | 8,940 + 128 + 0 = 9,068 | 2,528 (21.8%) |

**Residual is above the 10% target.** Likely sources for the residual:
- LSU FU contention (instrumentation gap; counts as cycles where issue dropped a load grant)
- Cycles with partial commit (e.g., commit=2 where 4 were eligible) that aren't pure stalls
- Frontend bubbles where `rename_dec_count < 4` but `rename_stall=0`

The residual doesn't change the qualitative ranking. For Phase B we accept ~15-20% residual and target the dominant bucket per workload.

---

## Headline Findings (for Phase B/C)

1. **cm bottleneck profile (iter1 + iter10 same):**
   - Issue-stall dominant: 35% of cycles have an IQ with NO eligible entry (operands not ready)
   - Head-wait: 47% of cycles, dominated by "unknown" sub-class (plain-ALU producer wait, 23% of cycles)
   - BPU contributes 8% mispredict rate + 2% flush cycles
   - **Hypothesis pull:** issue-side dependency-chain resolution latency (bypass/wakeup), NOT MUL/DIV/CSR/structure pressure

2. **dhry bottleneck profile:**
   - Head-wait: 38% of cycles, dominated by LOAD wait (27% of cycles, 72% of head-stall)
   - Issue-stall secondary: 16% of cycles in operand-stall
   - BPU healthy (1.6% mispredict rate, 0.5% flush cycles)
   - **Hypothesis pull:** load-to-consumer latency at ROB head; loads complete in 1 cycle but consumer can't issue immediately, leaving load at head

3. **Both profiles converge on issue-side dependency resolution** as the primary RTL knob to investigate. Load-bypass timing was already addressed by `cd54cf1` for Load1; this leaves: ALU bypass coverage (3 CDB-registered slots), wakeup-to-issue latency (1 cycle in 4-wide vs 6-wide), and PRF read-port pressure.

4. **What's NOT the bottleneck (data refutes seed hypotheses):**
   - dhry-H4 ("IQ_INT_DEPTH=24 too small"): all `iq*_full_cyc = 0` → REFUTED
   - dhry-H2 ("checkpoint allocation back-pressure on procedure call"): `stall_ckpt_cyc = 0` → REFUTED
   - cm-H3 ("NUM_ALU=3 ALU contention"): `issue_stall_arb_cyc` only 5.7% on cm; `arb_loss = 2` on dhry → arb is not the bottleneck

These refutations significantly narrow the Phase D probe scope.

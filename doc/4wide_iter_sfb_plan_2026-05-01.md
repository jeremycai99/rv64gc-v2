# Cycle B — SFB Fold-into-Predication — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Investigate whether Short-Forward-Branch (SFB) fold-into-predication, the SonicBOOM-cited technique credited with up to 1.7× IPC on branch-dense sequences, is applicable to rv64gc-v2's cm + dhry workloads. If applicable in meaningful volume: implement minimal predication infrastructure. If not: REFUTE-on-investigation, no RTL change.

**Architecture:** Investigation-first. Cycle A (uBTB sizing) and Cycle C (BRU early-redirect) both REFUTED, indicating the design is structurally well-tuned. Cycle B's RTL effort is large (decode + rename + ALU predicate + ROB tracking; estimated 2-4 days), so the gating investigation must produce a confident PROCEED signal before committing to RTL effort.

**Tech Stack:** SystemVerilog + DSim 2026 + python3 clockcheck + RISC-V toolchain (`/usr/bin/riscv64-unknown-elf-objdump`).

**Companion docs:**
- `doc/4wide_gap_closure_sequence_2026-05-01.md` — sequence design (this is Cycle B)
- `doc/4wide_iter_uBTB_results.md` — Cycle A REFUTE (BPU bigger than BOOM)
- `doc/4wide_iter_flush_recovery_results.md` — Cycle C REFUTE (early-redirect net-negative)
- `doc/4wide_perf_gap_results_2026-05-01.md` — gap analysis findings

---

## Pre-recon (already done by plan author, recorded for reference)

- **No SFB / fold-into-predication infrastructure** exists in rv64gc-v2 (zero matches for `SFB`/`short_forward`/`predicate`/`FoldBranch` in `src/rtl/core/`).
- **Zicond IS implemented** in decode (`czero.eqz`/`czero.nez` at `src/rtl/core/decode/decode_slice.sv:441-446`).
- **Zero Zicond instructions in dhrystone binary** despite `-march=rv64gc_zba_zbb_zbs_zicond`. Either GCC didn't apply Zicond conversion, or dhry's branch patterns aren't Zicond-eligible.
- **dhry has 92 conditional branches total**; the first 10 sampled are .bss-clear-loop (long-distance, not SFB-eligible).

These signals point toward likely REFUTE-on-investigation. The plan invests effort in investigation accordingly.

---

## File Structure

| File | Purpose |
|---|---|
| `doc/4wide_iter_sfb_investigation.md` | (create, Task 4) Investigation findings — branch pattern analysis, SFB-eligibility breakdown, PROCEED-or-REFUTE decision |
| `doc/4wide_iter_sfb_prediction.md` | (create, Task 5, ONLY if PROCEED) Predicted IPC delta + criteria; committed BEFORE any RTL change |
| `doc/4wide_iter_sfb_results.md` | (create, Task 8) Final outcome (REFUTE-on-investigation OR REFUTE-on-measurement OR success) |
| `src/rtl/core/decode/decode_slice.sv` | (modify, ONLY if PROCEED) SFB pattern detection at decode |
| `src/rtl/core/include/rv64gc_pkg.sv` | (modify, ONLY if PROCEED) SFB-related typedefs |
| `src/rtl/core/rename/rename.sv` | (modify, ONLY if PROCEED) propagate predicate through rename |
| `src/rtl/core/execute/alu.sv` | (modify, ONLY if PROCEED) consume predicate; suppress writeback on false |

---

## Task 1: Inventory SFB-eligible branches in dhry binary

**Files (read-only):** `tests/dhrystone/dhrystone.elf`

- [ ] **Step 1: Disassemble + classify branch distances**

```bash
/usr/bin/riscv64-unknown-elf-objdump -d tests/dhrystone/dhrystone.elf > /tmp/dhry_disasm.txt 2>&1
echo "Total disassembly lines: $(wc -l < /tmp/dhry_disasm.txt)"
echo "Total conditional branches:"
grep -cE "[[:space:]]b(eq|ne|lt|ge|ltu|geu)[z]?[[:space:]]" /tmp/dhry_disasm.txt
echo "Total Zicond (czero):"
grep -cE "czero" /tmp/dhry_disasm.txt
```

- [ ] **Step 2: Build SFB-eligibility classifier**

A branch is SFB-eligible if:
- It's a conditional branch (beq/bne/blt/bge/bltu/bgeu, optionally `z` variants)
- Forward direction (target > PC)
- Target offset ≤ 32 bytes (typically 1-8 instructions)
- The instructions in [PC+4, target) are all simple ALU/load/store ops (not other branches, not loads-from-stack-overflowing, no system instructions)

Use this Python (you may invoke via `python3 -c '...'`):

```python
import re, subprocess

dis = open('/tmp/dhry_disasm.txt').read()
lines = dis.splitlines()

# Parse address + instruction
parsed = []
for ln in lines:
    m = re.match(r'^\s*([0-9a-f]+):\s+([0-9a-f]+)\s+(.*?)$', ln)
    if m:
        parsed.append({'addr': int(m.group(1), 16), 'enc': m.group(2), 'asm': m.group(3).strip()})

# Find conditional branches
branches = []
for i, p in enumerate(parsed):
    asm = p['asm']
    m = re.match(r'(b(?:eq|ne|lt|ge|ltu|geu)z?)\s+(.+?),\s*([0-9a-f]+)', asm)
    if m:
        try:
            target = int(m.group(3), 16)
        except ValueError:
            continue
        offset = target - p['addr']
        branches.append({'idx': i, 'addr': p['addr'], 'target': target, 'offset': offset, 'asm': asm})

# Classify
sfb_eligible = [b for b in branches if 0 < b['offset'] <= 32]
back_edges  = [b for b in branches if b['offset'] < 0]
long_fwd    = [b for b in branches if b['offset'] > 32]

print(f"Total cond branches: {len(branches)}")
print(f"  Backward (loop)  : {len(back_edges)}")
print(f"  Forward >32 byte : {len(long_fwd)}")
print(f"  SFB-eligible (≤32 bytes forward): {len(sfb_eligible)}")
print()
print("First 15 SFB-eligible:")
for b in sfb_eligible[:15]:
    print(f"  pc={b['addr']:08x} offset=+{b['offset']} asm={b['asm']}")
```

- [ ] **Step 3: Cross-reference with hot-PC mispredict data**

Read the existing PERF_PROFILE log `benchmark_results/perf_full_4wide_dhrystone.log` (or regenerate via `bash run_dsim.sh tests/hex/dhrystone.hex 100000 +PERF_PROFILE`). Extract the "top mispredict PCs" section.

For each top mispredict PC: is it in the SFB-eligible list from Step 2? Compute "% of dhry mispredicts that are SFB-eligible".

If <20% of mispredicts are SFB-eligible: SFB won't help dhry meaningfully. Track this as a REFUTE signal.

---

## Task 2: Inventory SFB-eligible branches in cm binary

**Files (read-only):** `tests/coremark/coremark.elf` (if present, else find the elf via `find . -name "coremark.elf"`)

Same structure as Task 1 but on cm.

- [ ] **Step 1: Find the cm elf**

```bash
find tests -name "coremark*.elf" 2>/dev/null
```

If no .elf is committed, you can disassemble from .hex via:
```bash
# Convert hex back to elf is non-trivial; if no .elf exists, the cm sources should be at tests/coremark/. Build the elf with the project's build_coremark.sh equivalent (look for it).
ls tests/coremark/
```

If reconstructing .elf is hard: use the .hex directly with python to dump instructions starting at 0x80000000, OR rebuild from sources.

- [ ] **Step 2-3: Same classifier + hot-PC cross-reference as Task 1**

Use `benchmark_results/perf_full_4wide_cm_iter1.log` for the hot mispredict PCs (top mispredict PC was `0x8000235a` at 100% mispredict rate per prior analysis).

Specifically check: is `0x8000235a` SFB-eligible? It's a `bge s0, s5` per the prior cm bug investigation. The target offset will tell us if it's an SFB candidate.

---

## Task 3: Compute predicted SFB win

**No files modified — analysis only.**

- [ ] **Step 1: Build the predicted-impact table**

For dhry:
- Total mispredict cycles ≈ (128 mispredicts × ~6 cyc/mispredict) ≈ 768 cyc
- SFB-eligible mispredict cycles = (SFB-eligible-mispredict-count × ~6 cyc)
- Predicted IPC win = (SFB-eligible-mispredict-cycles / total-cycles) × (mispredict reduction fraction, e.g., 100% if folded)
- For dhry total cycles = 23,514: even if ALL 128 mispredicts were SFB-eligible and all eliminated, max win = 768/23514 = 3.3%. Realistic with partial coverage: <2%.

For cm iter1:
- Total mispredict cycles ≈ (4,343 mispredicts × ~6 cyc/mispredict) ≈ 26,058 cyc
- For cm total cycles = 199,452: max win if ALL eliminated = 26058/199452 = 13.1%
- Realistic with partial coverage (e.g., 30% of mispredicts SFB-eligible): ~4%

- [ ] **Step 2: Decision rule**

PROCEED if BOTH:
- dhry SFB-eligible-mispredict cycles ≥ 1% of dhry total cycles (i.e., ≥235 cyc), AND
- cm SFB-eligible-mispredict cycles ≥ 2% of cm total cycles (i.e., ≥3989 cyc)

OTHERWISE REFUTE-on-investigation. The RTL effort (2-4 days, 4-6 files) is not justified by predicted win <1%/<2%.

- [ ] **Step 3: Document the decision in scratch buffer**

```
DECISION: PROCEED — predicted dhry +<X%>, cm +<Y%>; SFB-eligible coverage is sufficient
OR
DECISION: REFUTE-on-investigation — predicted dhry +<X%>, cm +<Y%>; below 1%/2% threshold; RTL effort not justified
```

---

## Task 4: Write investigation doc + commit (always)

**Files:**
- Create: `doc/4wide_iter_sfb_investigation.md`

- [ ] **Step 1: Write findings**

```markdown
# Cycle B Investigation — SFB Eligibility

**Date:** 2026-05-01
**Repo HEAD:** master @ <git log -1 --format=%h>

## Branch inventory (dhry)

Total conditional branches: <Task1 count>
  Backward (loop edges):  <count>
  Forward >32 bytes:      <count>
  SFB-eligible (≤32 bytes forward): <count>
Zicond (czero) actual:    0  (compiler didn't apply despite -march=zicond)

## Branch inventory (cm)

(same structure)

## Top mispredict PCs cross-reference

dhry top mispredict PCs (from benchmark_results/perf_full_4wide_dhrystone.log):
| PC | Mispredict count | SFB-eligible? | Branch asm |
|---|---:|---|---|
| <PC> | <N> | <Y/N> | <asm> |
... (top 5-10)

cm top mispredict PCs:
| PC | Mispredict count | SFB-eligible? | Branch asm |
|---|---:|---|---|
| 0x8000235a | 103 | <Y/N> | bge s0,s5 ... |
... (top 5-10)

## Predicted SFB win

(Use Task 3 calculations.)

## Decision

PROCEED — predicted dhry +<X%>, cm +<Y%>
OR
REFUTE-on-investigation — predicted dhry +<X%>, cm +<Y%>; below 1%/2% threshold

If REFUTE: full RTL infrastructure (decode + rename + ALU predicate + ROB) costs
2-4 days for predicted gain that doesn't justify the effort. The conservative
recommendation is to skip RTL implementation and document the finding.
```

- [ ] **Step 2: Commit investigation doc**

```bash
git add doc/4wide_iter_sfb_investigation.md
git -c user.email="jeremycai@local" -c user.name="Jeremy Cai" commit -q -m \
  "doc: Cycle B investigation — SFB eligibility + decision

Inventory of SFB-eligible branches in dhry + cm binaries, cross-referenced
with hot mispredict PCs. Predicted win + decision (PROCEED or REFUTE-on-
investigation).

See doc/4wide_iter_sfb_investigation.md.

Plan: doc/4wide_iter_sfb_plan_2026-05-01.md"
```

---

## Task 5: Branch on decision

If Task 4 said REFUTE-on-investigation: skip directly to Task 8c.

If Task 4 said PROCEED: continue to Task 5 (write prediction note) and beyond. **STOP and report back to controller.** The actual RTL implementation (Tasks 5-7) requires a separate dispatch with sufficient context — do not attempt all of it in a single subagent run.

The controller will review the investigation findings and either dispatch the RTL implementation cycle (Tasks 5-7 below) or, if findings warrant, surface to the user for re-strategy.

---

## Task 5 (PROCEED branch only): Write + commit prediction note BEFORE RTL change

**Files:**
- Create: `doc/4wide_iter_sfb_prediction.md`

- [ ] **Step 1: Write prediction**

```markdown
# Cycle B Prediction — SFB Fold-into-Predication

**Hypothesis:** Implementing decode-time SFB detection + minimal predication
infrastructure (predicate flag through rename, ALU writeback suppression on
false predicate) eliminates the prediction need for SFB-eligible branches,
saving the per-mispredict recovery cost.

**Predicted IPC delta:**
- cm iter1: 1.665 → <X> (predicted +<Y>%, in-band [+<Y-30% rel>%, +<Y+30% rel>%])
- cm iter10: 1.719 → <X> (predicted +<Y>%)
- dhry: 2.027 → <X> (predicted +<Y>%)

(Use the predicted-win values from Task 3, with relative 30%-rule since
predicted win is now ≥3%.)

**Confirmation criterion:** Measured IPC delta within 30% relative of predicted
on cm AND no regression beyond ±2% on dhry AND functional 21/21 PASS AND
clockcheck PASS or only documented allowlist divergences.

**Refutation criterion:** Out-of-band measurement OR regression OR functional
break OR clockcheck divergence on non-SFB cycles.
```

- [ ] **Step 2: Commit BEFORE RTL change**

```bash
git add doc/4wide_iter_sfb_prediction.md
git -c user.email="jeremycai@local" -c user.name="Jeremy Cai" commit -q -m \
  "doc: Cycle B prediction — SFB predicted +<X>% cm, +<Y>% dhry

Tolerance: 30% relative (predicted win >=3%).
Plan: doc/4wide_iter_sfb_plan_2026-05-01.md"
```

---

## Task 6 (PROCEED branch only): Implement minimal SFB infrastructure

**Files:**
- Modify: `src/rtl/core/include/rv64gc_pkg.sv` — add SFB typedefs (predicate signal width, max SFB body length)
- Modify: `src/rtl/core/decode/decode_slice.sv` — detect SFB pattern at decode (cond branch with offset ≤ N bytes); emit predicate-marker
- Modify: `src/rtl/core/rename/rename.sv` — propagate predicate through rename (each predicated uop gets a predicate-source pdst)
- Modify: `src/rtl/core/execute/alu.sv` — consume predicate; if false, suppress writeback (or write old-pdst value)
- (Possibly) Modify: `src/rtl/core/backend/rob.sv` — track predicated uops; commit handles per predicate

This is the most invasive task in the entire 3-cycle sequence. **Do NOT execute this task in a single subagent dispatch.** It requires:
1. Architectural review of the rename/ALU pipeline first
2. Stepwise build-and-test (modify decode, build, run rv64ui_*, then add rename, build, run, etc.)
3. Per-step regression check

Recommend the controller dispatch this as 4-5 sequential mini-subagents, one per file modification, each with build+test gate.

**STOP THIS PLAN HERE.** When Task 4's decision is PROCEED, escalate to controller for sequenced RTL dispatch — don't attempt monolithic implementation.

---

## Task 7 (PROCEED branch only): Validate + measure

After all RTL changes land cleanly:

```bash
export LD_LIBRARY_PATH=
bash build_dsim.sh
bash scripts/regress_dsim.sh                    # functional
# clockcheck
mkdir -p traces/iter_sfb
for hex in bench_loop_100 bench_load bench_unrolled_5; do
    bash run_dsim.sh tests/hex/${hex}.hex 5000 +PERF_PROFILE +TRACE_PIPELINE
    grep "^\[PIPE schema=pipe.v1\]" dsim_run.log > traces/iter_sfb/${hex}.pipe.v1.trace
done
for hex in bench_loop_100 bench_load bench_unrolled_5; do
    python3 ../rv64gc-perf-model/tools/rtl_clockcheck.py \
        --baseline-pipe traces/baseline_6wide/${hex}.pipe.v1.trace \
        --refactor-pipe traces/iter_sfb/${hex}.pipe.v1.trace \
        --allowlist tools/clockcheck_4wide.allowlist.json
done
# measurement
bash run_dsim.sh tests/hex/coremark.hex 5000000 +PERF_PROFILE
bash run_dsim.sh tests/hex/coremark_iter10.hex 5000000 +PERF_PROFILE
bash run_dsim.sh tests/hex/dhrystone.hex 100000 +PERF_PROFILE
```

Apply confirmation/refutation per Task 5 prediction's tolerance.

---

## Task 8: Commit-or-revert + write results doc (3 branches)

### 8a — Branch SUCCESS (Task 7 in-band)

Commit RTL changes + results doc + (if extended) clockcheck allowlist. Use the prior cycles' SUCCESS commit template.

### 8b — Branch REVERT-on-measurement (Task 7 out-of-band)

`git checkout` the RTL files, write REFUTE-on-measurement doc, commit doc only.

### 8c — Branch REFUTE-on-investigation (Task 4 said skip RTL)

Write `doc/4wide_iter_sfb_results.md`:

```markdown
# Cycle B Results — SFB Fold-into-Predication

**Date:** 2026-05-01
**Verdict:** REFUTED-on-investigation

## Investigation findings (from doc/4wide_iter_sfb_investigation.md)

- dhry SFB-eligible mispredict cycles: <X> of 23,514 total cycles (<Y%>)
- cm SFB-eligible mispredict cycles: <X> of 199,452 total cycles (<Y%>)
- Predicted SFB win: dhry +<A>%, cm +<B>%
- Decision threshold: dhry ≥1%, cm ≥2% — failed.

## Why the RTL effort is not justified

Implementing minimal SFB infrastructure requires:
- Decode-pattern detection (~50 lines)
- Predicate signal added to uop struct (~30 lines)
- Rename pipeline propagation (~80 lines)
- ALU predicate handling + writeback suppression (~50 lines)
- ROB tracking (~40 lines)
- Clockcheck allowlist updates for new predicate-related divergences (multiple entries)
- Functional regression maintenance during stepwise build-up (3-5 build/test cycles)

Total: ~250 lines RTL across 4-5 files, ~2-4 days of careful subagent work.

For a predicted gain of <2% IPC on the workloads we care about, the engineering
cost is not justified. Better to adopt the cumulative state as the final
sign-off.

## Cumulative gap-closure result (Cycles A + C + B)

| Cycle | Verdict | Δ to baseline |
|---|---|---|
| A — uBTB sizing | REFUTE-on-investigation (BPU > BOOM) | 0 |
| C — BRU early-redirect | REFUTE-on-measurement (mechanism net-negative) | 0 |
| B — SFB | REFUTE-on-investigation (insufficient eligible patterns) | 0 |

Final 4-wide measurements remain at:
- cm iter1: 5.01 CM/MHz
- cm iter10: 5.37 CM/MHz
- dhrystone: 2.42 DMIPS/MHz

PARTIAL-FLOOR sign-off (`doc/4wide_signoff_2026-05-01.md`) stands as final.

## What this tells us

The 3-cycle gap-closure sequence ran the data-driven methodology to its
conclusion. All three cycles produced data-grounded REFUTEs:
- A: design is well-equipped (BPU > BOOM)
- C: mechanism that "should" help is net-negative
- B: workload doesn't have enough SFB-eligible patterns

This is consistent with the prior gap analysis that classified most
remaining gap as INTRINSIC. The design's narrowing is correct; the
remaining −19%/−39% gap is structural (workload + 4-wide narrowing),
not addressable via parameter tuning, mechanism enabling, or feature
addition without major redesign.

## Recommendation

Adopt PARTIAL-FLOOR as the final sign-off. Document this 3-cycle
sequence as the closing record of the rv64gc-v2 4-wide refactor's
performance work.
```

Commit:
```bash
git add doc/4wide_iter_sfb_results.md
git -c user.email="jeremycai@local" -c user.name="Jeremy Cai" commit -q -m \
  "perf-iter B: SFB REFUTED-on-investigation — 3-cycle sequence COMPLETE

Investigation found SFB-eligible mispredict cycles below threshold for
both dhry (<X%>) and cm (<Y%>). RTL effort (~250 lines, 2-4 days) not
justified by predicted gain.

Combined with Cycle A (BPU > BOOM, REFUTE) and Cycle C (early-redirect
net-negative, REFUTE), all 3 selected gap-closure candidates produced
data-grounded REFUTEs. The design is structurally well-tuned; remaining
gap is intrinsic per prior gap analysis.

Final sign-off: PARTIAL-FLOOR as documented in doc/4wide_signoff_2026-05-01.md.

See doc/4wide_iter_sfb_results.md for the cumulative summary."
```

---

## Constraints

1. **DSim license is single-seat.** Sequential runs only.
2. **`export LD_LIBRARY_PATH=`** before any DSim invocation.
3. **`src/rtl/core/lsu/lsu.sv`** must NEVER be modified.
4. **Pre-existing housekeeping (~30 files)** must NOT be committed.
5. **Prediction note (Task 5) MUST be committed BEFORE any RTL change (Task 6).**
6. **30% relative tolerance** (predicted win ≥3% in PROCEED branch).
7. **Working on `master`** is correct.
8. **Do NOT modify CDB_WIDTH, IQ depth, NUM_ALU, or any narrowing decision.**
9. **If Task 4 says REFUTE-on-investigation: STOP. Do NOT proceed to RTL implementation.** This is the most likely outcome given the pre-recon findings.
10. **If Task 4 says PROCEED: STOP after Task 5 prediction commit. Escalate to controller for sequenced RTL dispatch (4-5 mini-subagents, one per file).** Do not attempt monolithic RTL implementation in one dispatch.

---

## Self-review

- [x] Spec coverage: investigation tasks (1-3), decision (4), prediction-before-change (5), invasive RTL (6), validate+measure (7), commit-or-revert (8a/8b/8c). Each branch has clean exit.
- [x] Placeholder scan: no TBD/TODO. Code blocks have actual code.
- [x] REFUTE-on-investigation (Task 8c) is explicit and is the likely outcome per pre-recon.
- [x] PROCEED branch is gated on quantitative thresholds (≥1% dhry, ≥2% cm).
- [x] RTL implementation (Task 6) is explicitly NOT to be done in a single subagent dispatch — controller-escalation handoff documented.
- [x] Cumulative-3-cycle results section in 8c gives the final sign-off summary if SFB also REFUTES.

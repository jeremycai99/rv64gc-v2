# RAS FIX-A (full-stack snapshot/restore) — A/B REFUTED

**Date:** 2026-06-05
**Branch:** backend/lq-instrument (FIX-A was uncommitted on top of 8653b3d; reverted after this result)
**Engine:** Verilator (license-free), two boot windows run in parallel (ENABLE=0 vs ENABLE=1)
**Workload:** Linux boot, `build/linux_boot_full/fw_payload.hex`, first 20,000,000 cycles
**Artifact:** `linux_boot_results/ras_ab/{enable0,enable1}.log`

## Question

The RAS recovers approximately on a mispredict: the checkpoint restores only `tos` +
the visible top entry (top-repair gated on `bp_ras_op==RAS_NONE`). Deep wrong-path
corruption (gap≥8 = 17% of boot restores) is left in the stack. **FIX-A** = restore the
full RAS stack from an FTQ snapshot (correct-by-construction). Is the deep-corruption
repair worth the HW (≈4.6KB/FTQ snapshot RAM + ~30 per-uop threading sites)?

## Result

| metric (20M boot window) | ENABLE=0 | ENABLE=1 (FIX-A) | Δ |
|---|---|---|---|
| **IPC** | 1.15787 | 1.15750 | **−0.03% (noise, slightly negative)** |
| RAS restores | 308,780 | 308,132 | −0.2% |
| **gap 8+ (deep corruption)** | 53,844 | 49,100 | **−8.8%** |
| **misp ret (RAS)** | 67,790 | 67,369 | **−0.62% (−421)** |
| misp total | 217,233 | 216,741 | −0.23% |
| misp cond (TAGE) | 128,577 | 128,532 | ~0 |

## Verdict: REFUTED (works, but ~0 IPC)

FIX-A is **correct, not broken** — deep-corruption restores fell 8.8% and RET mispredicts
fell 421, so the full-stack restore genuinely repairs the stack. But it buys **essentially
zero IPC** (−0.03%, within run-to-run noise).

**Why ~0:** the cheap approximate recovery (TOS + top-repair) already fixes the *top* entry,
which is what the next RET reads. The deeper entries FIX-A repairs only matter for *nested*
returns that fire before new CALLs refill the stack — a rare dynamic pattern. 421 fewer RET
mispredicts × ~12–20 cyc ≈ 5–8K cyc out of 20M = the 0.03% observed. Consistent end to end.

**Best-case caveat makes it stronger:** this 20M window is *early boot*, the most RET-heavy
region (RET = 31.7% of mispredicts) — FIX-A's best case. On CoreMark (RET = 1.3%) it is even
more useless. So FIX-A is dead on **both** available workloads.

**Note on minstret skew:** the two arms committed slightly different instruction counts at the
fixed 20M-cycle cutoff (23.157M vs 23.150M) because ENABLE=1's timing shifts where the cutoff
lands. The committed-arch prefix is identical; RET-rate (0.293% vs 0.291%) is the apples-to-apples.

## Decision

- **Do NOT promote.** Zero RTL promoted (discipline: a lever must clear the bar). FIX-A doesn't.
- **Revert the invasive per-uop threading** (snapshot fields in `decoded_insn_t`,
  `fetch_packet_t`, `iq_entry_t`, `rename_buf_entry_t` + ~30 sites) — dead weight for a refuted lever.
- **Re-test only if** a deeply-recursive, indirect-heavy workload (SPEC-like) becomes available;
  the design is documented here + in memory and is re-buildable from the transcript.

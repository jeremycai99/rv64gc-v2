# All-Workloads ≥ 2.0 IPC — Campaign Results (2026-06-10)

Closes the loop on `doc/all_workloads_ge2_feasibility_2026-06-09.md`. Everything below is **measured
on real, verified execution** (run-to-tohost where marked PASS; trap-catcher armed; suite-integrity
fixes in place). Tree: `backend/lq-instrument` @ `435e8f5`.

## Final honest scoreboard (Verilator bench, stack params ON, FPU fix in)

| Workload | IPC | ≥2.0 | Evidence |
|---|---|---|---|
| linear_alg | **3.232** | ✅ | 194M instr real linpack, 60M-cyc window |
| sha | **2.946** | ✅ | 206M instr, 70M window |
| Dhrystone | **2.574** | ✅ | PASS @13,795 |
| zip | **2.377** | ✅ | 238M instr clean (post-fix; pre-fix arms diverged/corrupted) |
| CoreMark | **2.160** | ✅ | PASS @1,480,199 |
| nnet | **2.128** | ✅ | **PASS to tohost** @52.2M — first real completion |
| cjpeg | **2.087** | ✅ | **PASS to tohost** @56.3M |
| loops | 1.506–1.63 | ❌ | window-dependent; P1 lever rejected |
| radix2 | 0.922 | ❌ | first real FFT datapoint (old 2.49 was a malloc-loop artifact) |
| parser | 0.603 | ❌ | honest parse phase (old completions were parse-failing-fast artifacts) |
| boot (paged Linux) | DSim run in flight | ⏳ | IPC 2.15 @ early; Verilator full-boot N/A (tb time-path issue, follow-up) |

**7 of 10 ≥ 2.0.** The store-bound cluster of the original feasibility map (nnet/cjpeg/linalg —
then misattributed to FP kernels that were in fact trap-looping) is fully cleared; the genuine
remaining gap is `loops`/`radix2` (FP-pipeline characterization pending) and `parser`
(L1D pointer-chase + byte-scan; levers: stride prefetcher [gated], word-wide-strings binary fix
[built], L1D capacity).

## What was delivered (committed)

1. **Store engine** (`c405a1e`): NWA write-validate (no-write-allocate for streaming full-line
   stores; install-time full-line WT — 5.8× WT-traffic reduction) + store-pipe no-bubble (CSB head+1
   peek; 0.5→1.0 ack/cyc). Streaming-store throughput ~2.7×; CM −0.04% (faster); DS +0.05%.
2. **NWA same-cycle fill/validate priority race fix** (`8b536b0`+`32dec7e`): validate loses to a
   same-cycle fill consistently across all six consumers. Found via instret-aligned PC-hash
   divergence hunting on zip (silent L2 staleness → corruption surfacing 39M instr later).
   Verified: zip 55/55 hash milestones identical to legacy.
3. **FPnew output-port drop fix** (`435e8f5`): a completing multi-cycle div/sqrt now owns the FPU
   output port; previously its result was popped into the void when an FMV-class op occupied the
   request register → deterministic ROB-head wedges in all real-FP kernels (pre-existing,
   config-independent, masked until FP actually executed).
4. **Suite integrity** (`8b536b0`): crt0 FS-enable (every prior bare-metal FP "measurement" was a
   silent trap loop at mtvec=0), trap-catcher mtvec (silent traps now fail visibly), 5 reproducible
   kernel-direct build stanzas, radix2 bump allocator, parser word-wide string library (fair
   libc-replacement; 1.73× wall-clock on the old-style parse).
5. **Diagnostic toolkit** (tb_xsim, plusarg-gated, inert): `+PC_SAMPLE` (commit-PC/trap sampler +
   instret-aligned PC-hash milestones, `+PC_SAMPLE_IVL`), `+LOAD_LOG_FROM/TO`, `+WATCH_LINE`
   (line lifetime incl. L2/memory boundary), `+SNOOP_FROM/TO`, `[PCS-FPU]` handshake line.

## Sign-off state

- RV compliance: **113/113 PASS** (strict checkers) on `32dec7e`; re-run pending on `435e8f5`.
- DSim functional regress: 17/17 STOP-OK.
- CM/DS: cycle-exact through all fixes (1,480,199 / 13,795).
- Boot: authoritative DSim full boot in flight; benchmark-signoff manifest re-lock is pre-existing
  maintenance (stale hashes from May; flagged, untouched).

## Open items (next campaign)

1. **P1 FPU-issue A/B — CLOSED, REJECTED**: matched 60M windows: radix2 0.9367 bit-identical,
   linalg 3.232 identical, loops 1.630->0.982 (**40% WORSE** with P1 — the relaxed suppress lets FP
   ops monopolize the shared IQ2 port). FPU_PIPELINED_ISSUE_ENABLE ships 1'b0 permanently.
2. **loops/radix2 FP characterization** — the real FP frontier; profile with +PERF_PROFILE on
   honest binaries (FDIV/FSQRT latency, FP scheduling).
3. **parser levers**: stride/next-line data prefetcher (gated, task #28) + word-wide-string binary
   + L1D capacity re-evaluation on the honest binary.
4. **Verilator tb_linux time path**: kernel rdtime start reads −1 → eternal udelay; no Verilator
   full boot has ever passed. Fixing unlocks 16 kcyc/s boot iteration.
5. radix2 60M+ to-halt budget; zip full 5-iteration completion budget (~400M instr).

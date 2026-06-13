# Performance Scoreboard — promoted config (2026-06-13)

The canonical per-workload performance record at the **promoted configuration**:
IFU cursor fixes ON (`IFU_STRADDLE_ADVANCE_FIX_ENABLE` / `IFU_REMAINDER_ECHO_FIX_ENABLE`)
+ `LOOP_SPEC_COMMIT_NOCLOBBER_ENABLE` ON. Source of truth: `log/piece2_runs/suite_on/`
(42 rows, Verilator, every PASS row at tohost; CAP rows = TIMEOUT-capped kernel-direct,
IPC valid at-cap only). Verdict/mechanism trail: `doc/ipc3x_gate_results_2026-06-11.md`.
Supersedes the per-workload rows of `doc/bottleneck_map_41w_2026-06-10.md` and
`doc/all_workloads_ge2_results_2026-06-10.md`.

**Suite geomean vs the pre-campaign (2026-06-11 morning) core: ≈ −3.5% cycles**, with
2 documented residual regressions (ud +2.37%, minver +1.44% — pre-existing M2
batch-starvation mechanism, phase-flipped; see §4.4 of the gate doc).
DSim anchors (regress sign-off): CoreMark **6.96 CM/MHz** (iter10, at STOP),
Dhrystone **DMIPS at 13,501 cyc/100 iters** (sha-mismatch vs manifest golden noted —
not manifest-comparable). Boot: prior PASS 128.7M cyc @ IPC 1.65; promoted-tree boot
v2 in flight tracking **IPC 1.80** (faster).

## 3.x roster (≥2.95): 8 members

| workload | IPC | end |
|---|---|---|
| linear_alg-kernel-direct | 3.317 | cap |
| sha-kernel-direct | 3.311 | cap |
| embench-nettle-sha256 | 3.299 | PASS |
| embench-nettle-aes | 3.293 | PASS |
| rvb-vvadd | 3.204 | PASS |
| rvb-rsort | 3.141 | PASS |
| embench-edn | 3.104 | PASS |
| embench-statemate | 2.973 | PASS |

## Below 2.95 — 34 workloads, by adjudicated binder

| workload | IPC | end | binder (measured) | funded path |
|---|---|---|---|---|
| dhrystone-ww | 2.789 | PASS | supply, at ceiling (G0 UB 2.83) | none (software/binary axis vs BOOM) |
| dhrystone | 2.614 | PASS | supply, at ceiling (UB 2.62) | none |
| rvb-memcpy | 2.607 | PASS | LSU; zero exposed fill latency @L=1 | P1-resurrection re-read @L=80 |
| zip-kernel-direct | 2.524 | cap | mixed: 40k indirect misp + dup residual 866k + mem | partial (fill levers @L=80) |
| embench-wikisort | 2.345 | PASS | chain+misp mixed | none significant |
| embench-picojpeg | 2.335 | PASS | chain (qualified) + dup residual 18k | none significant |
| stream-l2 | 2.322 | PASS | FP cadence (fu_cont 31.4%) + L2-fill 19.1% | **FP campaign + fill, jointly → ≥2.95 claimable** |
| embench-crc32 | 2.300 | PASS | ~10-cyc carried chain (measured by cursor-fix A/B) | closed; software only |
| stream-l1 | 2.257 | PASS | FP cadence (fu_cont 25.3%, UB 3.02) | **FP campaign** |
| cjpeg-kernel-direct | 2.237 | PASS | chain + dup residual 1.0M; fu_cont 0.1% | none significant |
| coremark_iter10 | 2.185 | PASS | chain+misp mixed; **UB 2.93 at perfect frontend** | -flto/software only; never roster |
| nnet-kernel-direct | 2.133 | PASS | **FP cluster: fu_cont 32.3%, UB 3.15–3.59** | **FP campaign — biggest single mover** |
| embench-tarfind | 2.083 | PASS | store-commit-wait 10.6% (latency-insensitive) | **store-data decoupling thread** |
| embench-cubic | 2.080 | PASS | FP (fu_cont 21.7%, UB 2.66) | FP campaign |
| embench-slre | 2.065 | PASS | recovery/misp partial | low headroom |
| rvb-towers | 2.002 | PASS | chain | software only |
| embench-matmult-int | 1.927 | PASS | fetch-fragmentation (B=8.4, supply cap 2.06) **+ store-commit-wait 21.3%** | store-data thread |
| embench-nsichneu | 1.891 | PASS | fetch-fragmentation (supply cap 1.81) | none funded |
| embench-md5sum | 1.815 | PASS | misp-heavy (~27% cyc @P8) | misp asymptote |
| embench-ud | 1.807 | PASS | misp/chain + **M2 starvation residual (+2.37%)** | M2 spill campaign |
| loops-…-sp-kernel-direct | 1.729 | cap | **FP cluster: fu_cont 31.5%, UB 2.52–2.86** | **FP campaign** |
| embench-minver | 1.595 | PASS | **M2 residual (spill arm measured → ~1.77)** + FP fu_cont 33.8% | M2 + FP, double-funded |
| embench-huffbench | 1.542 | PASS | irreducible loop-exit misp | asymptote 1.6–2.0 |
| embench-aha-mont64 | 1.536 | PASS | misp (43% cyc) + modul64 carried chain | Zicond/sideband refuted; asymptote |
| embench-qrduino | 1.530 | PASS | misp-heavy | asymptote |
| rvb-spmv | 1.490 | PASS | misp (1/33 instr); memory story refuted | asymptote |
| embench-sglib-combined | 1.471 | PASS | chain-vs-misp attribution unresolved (~49% cyc) | needs census before assignment |
| rvb-qsort | 1.359 | PASS | irreducible loop-exit misp (P≥6 structural) | asymptote |
| rvb-median | 1.314 | PASS | misp hammock; Zicond pairing dead | asymptote |
| rvb-multiply | 1.210 | PASS | misp-redirect fetch; **binary: clang shows 2.37** | software/binary axis |
| radix2-big-64k-kernel-direct | 1.052 | PASS | FP (fu_cont 21.3%, UB 1.32–1.45) | FP campaign (low band) |
| embench-st | 0.892 | PASS | FP cadence extreme (fu_cont 62.5%, UB 1.34) | FP campaign (low band) |
| embench-nbody | 0.741 | PASS | FP (fu_cont 44.8%); 2,940-cyc run, low confidence | FP campaign |
| parser-kernel-direct | 0.623 | cap | **L1D-miss service via L2 hit pipe (+57.5% @lat-2) + byte-serial binary** | cache-sweep decision + ww strings |

## Structure of the gap (the honest summary)

- **9 workloads are FP-campaign property** (funded; nnet + stream-l2 are the roster
  candidates → realistic roster trajectory 8 → 9–10).
- **~10 are mispredict-asymptote members** — no funded lever moves them; structural
  minimum P≥6, recovery polish ≤3 of 8 cycles, Zicond/sideband refuted. Branch-side
  budget goes to the M2 spill policy (misp *count*), not penalty machinery.
- **~6 chain-bound** — software axis only (the ±30–50% compiler-variance finding).
- **parser** is the largest single untapped number, owned by the cache-sizing decision.
- Frontend-supply levers are **exhausted**: G0, repacker, rename-skid, ckpt-bandwidth,
  move-elim all measured-killed; residual truncation loss sits behind the port-blocked
  fetch-ahead program.

Update policy: regenerate this table whenever a param promotes or a campaign lands;
keep the binder column in sync with the gate doc's verdicts.

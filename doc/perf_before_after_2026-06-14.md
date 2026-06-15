# Workload Performance — Before → Current (consolidated, 2026-06-14)

One table to de-chaos the campaign. **Before** = pre-cursor-fix baseline (session start,
6-member roster). **Current (committed)** = cursor-fixes + loop-pred noclobber, default-on
(`69ced64`), 8-member roster. **Funded/gated** = measured levers that are built+validated
but default-OFF (F1 FP-cadence, GCC-14 codegen, D-prefetcher, TAGE-512) — their projected
add-on if enabled. All IPC; bare-metal suite (GCC-13.4) + kernel-direct rows.

## Headline metrics
| metric | before | current (committed) | + funded/gated |
|---|---|---|---|
| **3.x roster (≥2.95)** | **6** | **8** | **9** (multiply via GCC-14) |
| CoreMark | 2.160 (6.91 CM/MHz) | **2.178 (6.96)** | — |
| Suite geomean | — | **≈ −3.5% cycles** | — |
| Linux boot | DSim only (~12h) | DSim + **Verilator BOOT OK (~2h, parallel)** | — |
| Open-source rank | — | **SonicBOOM tier** (co-leads OoO CoreMark/MHz) | — |

## 3.x roster (current ≥2.95) — committed
| workload | before | current | Δ | note |
|---|---|---|---|---|
| linear_alg | 3.232 | **3.317** | +2.6% | cap row |
| sha | 2.946 | **3.311** | **+12.4%** | cursor (was knife-edge) |
| nettle-sha256 | 2.975 | **3.299** | +10.9% | cursor |
| nettle-aes | 3.009 | **3.288** | +9.3% | cursor |
| vvadd | 3.191 | **3.204** | +0.4% | |
| rsort | 2.800 | **3.141** | **+12.2%** | cursor — NEW member |
| edn | 3.011 | **3.104** | +3.1% | cursor |
| statemate | 2.652 | **2.973** | **+12.1%** | cursor — NEW member |

## Below 2.95 — committed, with funded/gated potential
| workload | before | current | Δ | funded/gated lever (projected) |
|---|---|---|---|---|
| dhrystone-ww | 2.732 | 2.789 | +2.1% | |
| dhrystone | 2.574 | 2.614 | +1.6% | |
| memcpy | 2.607 | 2.607 | 0% | **D-prefetch +14% @L=80** (→~2.97) |
| zip | 2.351 | 2.524 | +7.4% | cursor |
| wikisort | 2.312 | 2.345 | +1.4% | |
| picojpeg | 2.160 | 2.335 | +8.1% | cursor |
| stream-l2 | 2.322 | 2.322 | 0% | **F1 +7%**; D-pf needs throttle (+4% regress now) |
| crc32 | 2.091 | 2.300 | +10.0% | cursor; chain certified irreducible |
| stream-l1 | 2.249 | 2.257 | +0.4% | **F1 +6.6%** |
| cjpeg | 2.087 | 2.236 | +7.2% | cursor |
| coremark | 2.160 | 2.178 | +0.8% | UB 2.93 (perfect-frontend cap) |
| nnet | 2.128 | 2.116 | −0.6%¹ | **F1 +24% → 2.65** (needs FP-operand for UB 3.15) |
| tarfind | 2.081 | 2.083 | +0.1% | store-harvest (funded) |
| cubic | 2.020 | 2.080 | +3.0% | F1 +1.8% |
| slre | 2.053 | 2.065 | +0.6% | |
| towers | 1.998 | 2.002 | +0.2% | chain |
| matmult-int | 1.906 | 1.897 | −0.5%¹ | store-harvest; supply-cap 2.06 |
| nsichneu | 1.733 | 1.891 | +9.1% | cursor; fetch-frag |
| md5sum | 1.661 | 1.815 | +9.3% | cursor; misp-entropy (irreducible) |
| ud | 1.850 | 1.807 | **−2.3%**¹ | M2-residual (accepted; M2-spill refuted) |
| loops | 1.635 | 1.728 | +5.7% | **F1 +23%** |
| minver | 1.618 | 1.560 | **−3.6%**¹ | M2-residual; F1+TAGE partial |
| huffbench | 1.533 | 1.542 | +0.6% | misp-entropy (irreducible) |
| aha-mont64 | 1.468 | 1.536 | +4.6% | TAGE −5.5% misp; GCC-14 1.75 |
| qrduino | 1.493 | 1.530 | +2.5% | TAGE −2.4% misp |
| spmv | 1.481 | 1.490 | +0.6% | gather (D-pf KILL) |
| sglib | 1.467 | 1.471 | +0.3% | TAGE −4.5% misp |
| qsort | 1.359 | 1.359 | 0% | loop-exit misp (irreducible) |
| median | 1.313 | 1.314 | 0% | misp; software-dead both compilers |
| **multiply** | 1.050 | 1.210 | +15.2% | **GCC-14 → 3.371 (CROSSES → roster 9)** |
| radix2 | 1.013 | 1.042 | +2.9% | F1 +2.5% |
| st | 0.891 | 0.892 | 0% | **F1 +17%** |
| nbody | 0.737 | 0.741 | +0.5% | F1 +4.9% (low-conf, 2940-cyc) |
| parser | 0.623 | 0.623 | 0% | cache 512K/lat5 +19%; binder=byte-serial |

¹ the 4 documented cursor-fix BP-perturbation residuals (M1/M2 mechanism); minver/ud carry M2 (refuted-to-fix, accepted); nnet/matmult net-tiny.

## Funded/gated levers (built+validated, default-OFF — not in "current committed")
- **F1 (FP true-1.0 cadence)** — +1.8–24% on 9 FP rows (nnet→2.65, loops→2.36, st→1.04); geomean, no roster alone (binder shifts to FP-operand-latency).
- **GCC-14 codegen** — multiply 1.21→**3.371** (roster crossing, zero RTL); mont64 1.75; rest maintenance.
- **D-prefetcher** — real-kernel D-miss **−67%**, memcpy +14%@L=80; stream-l2 +4% NEEDS-WORK (throttle).
- **TAGE 256→512** — misp −5.5%/−4.5%/−2.4% on mont64/sglib/qrduino; +1.5% geomean, no roster; synth-cone PASS.
- **Store-harvest A1** — tarfind/matmult head-store-wait recovery (funded).

## Cache geometry — COMMITTED 2026-06-14
- **L2 2 MB → 512 KB, 8-way, 8-cyc hit** (`L2_SIZE=524288`; the `512k-64k-lat8` arm). −72.7%
  cache data+tag SRAM (~30–37% die area) for an accepted **+0.81% real-app cost** at realistic
  DRAM latency (L=80: sha −4.4%, zip −2.6%, rest ≈flat). The L=1 compute-IPC table is
  capacity-invariant (CoreMark 2.178→2.185, sha 3.311→3.311, zip 2.524→2.562 re-confirmed on the
  512 KB build). The study's optional **5-cyc hit** (a −1.28% net win) was **not taken** — 8-cyc
  hit retained by design choice; it remains a documented future option.

## What's certified DEAD (measured, not asserted)
Chain band irreducible (value-prediction killed — crc32 LCG value-novel); misp-entropy
core (md5sum/qsort/huffbench) irreducible; backend width/dispatch/commit/AGU/BR0-MUL all
measured-dead; G0-runahead, 2-block-fetch, emit-repacker, Zicond, L2-prefetch, TLB/QoS/
I-MSHR system levers all NO-GO. Real expansion past the BOOM tier needs vector (out-of-POR).
</content>

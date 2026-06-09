# Dhrystone Binary Normalization — beating Reference Core A (root cause + fix)

Date: May 29, 2026
Status: ADOPTED. The Dhrystone build is normalized to Reference Core A/riscv-tests methodology;
the DS signoff rows are re-baselined. Companion to
`doc/stage4_lever_ceiling_verdict_2026-05-28.md` (which closed the *backend IPC*
campaign at a well-tuned floor). This doc resolves the **Dhrystone DMIPS/MHz gap to
Reference Core A** — which turned out to be the binary, not the microarchitecture.

## The question

Dhrystone scored 3.22 DMIPS/MHz vs Reference Core A's published 3.93 (−18%), while CoreMark
already beat Reference Core A (6.85 vs 6.2). Why was Dhrystone behind?

## Root cause: a non-standard `-fno-builtin` self-handicap

DMIPS/MHz depends only on cycles/iteration = instr/iter × CPI. Our backend was
already commit-efficient on Dhrystone (exposed head-stall 3.3%, IPC 2.81) — so the
gap was **not** a microarchitecture stall.

The Dhrystone build (`tests/dhrystone/build_dhrystone.sh`) used **`-fno-builtin`
+ `-ffreestanding`**, which forces `strcpy`/`strcmp`/`memcpy` out-of-line and
**byte-at-a-time** (5 instr/byte; the hand-written `string_bare.c` loops). The
dominant head-stall PC was `0x80002002` — the `lbu` inside `strcpy` — at **66% of
all DS300 head-stall**. ~90% of the 501 instr/iteration were in those byte loops.
The core ran the byte code efficiently; it was the **wrong code**.

## Reference Core A's methodology (confirmed)

The riscv-tests/the reference-core build framework Dhrystone (source of Reference Core A's published 3.93) compiles
with `chipyard/toolchains/riscv-tools/riscv-tests/benchmarks/Makefile`:
```
-O2 -ffast-math -fno-common -fno-builtin-printf -fno-tree-loop-distribute-patterns -march=rv64gcv
```
Only `-fno-builtin-printf` (string/mem builtins **ON**), and **no `-ffreestanding`**.
So Reference Core A's constant-string `strcpy` and struct copies were inlined/word-wide. Our
full `-fno-builtin` + `-ffreestanding` was a non-standard handicap Reference Core A never had.
The comparison is therefore confirmed apples-to-apples once normalized.

## The fix and result (no RTL)

Build change: drop `-fno-builtin` and `-ffreestanding`; add `-ffast-math` and
`-fno-tree-loop-distribute-patterns` (mirroring riscv-tests). String/mem builtins
then widen the constant copies into word stores; the struct copy becomes word
loads/stores. `string_bare.c` is retained for the residual runtime calls.

| Build (DS300, 300 iters) | cyc/iter | instr/iter | IPC | DMIPS/MHz |
|---|--:|--:|--:|--:|
| old (`-fno-builtin`, byte) | 178.5 | 501 | 2.84 | 3.22 |
| **normalized `-O2` (Reference Core A-matched)** | **134.5** | 352 | 2.62 | **4.27** |
| Reference Core A published | 144.8 | — | — | 3.93 |
| (aggressive `-O3 -flto`, not apples-to-apples) | 120.3 | 341 | 2.83 | 4.73 |

**At Reference Core A's own `-O2` methodology, rv64gc-v2 scores 4.27 (DS300) / 4.26 (DS100)
DMIPS/MHz — ~9% above Reference Core A's 3.93.** The 4-wide core beats 6-wide Reference Core A (large config) on
Dhrystone. IPC is essentially unchanged (2.8→2.6); the win is entirely fewer
instructions/cycles for identical work (checksum 24, PASS, both rows).

The official build is `-O2`-matched (apples-to-apples with Reference Core A, not `-flto`).

## Adoption (re-baselined goal contract)

- `tests/dhrystone/build_dhrystone.sh`: normalized flags (above).
- Rebuilt DS100 (`tests/hex/dhrystone.hex` + `tests/dhrystone/dhrystone.elf`) and
  DS300 (`benchmark_results/20260506_stage1_anchor_cont/dhrystone300.{hex,elf}`).
- Regenerated golden PCs (`tools/golden_pc_stream.py emit`): DS100 35,195 PCs,
  DS300 104,795 PCs.
- Updated `tests/benchmarks/stage1_signoff.json` `expected_hex_sha256` /
  `expected_elf_sha256` for both DS rows.
- Verified: both rows PASS (hash match, golden-PC OK, checksum 24, fetch/branch
  invariants clean). New official DS: **DS100 4.26, DS300 4.27 DMIPS/MHz**.

## Follow-ups

- **CoreMark uses the same `-fno-builtin`** (`tests/coremark/build_coremark.sh`).
  CoreMark is compute-bound (it already beats Reference Core A), so the gain is likely small,
  but normalizing it too would make the suite's methodology consistent — open item.
- The backend-IPC floor verdict (`stage4_lever_ceiling_verdict`) is unaffected:
  this was a binary fix, IPC unchanged. rv64gc-v2 now exceeds Reference Core A's public floor
  on **both** CoreMark (6.85 > 6.2) and Dhrystone (4.27 > 3.93).

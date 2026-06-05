# Commit-flush baseline (ENABLE=0) — golden for BRU early-redirect bit-exact compare
Run 2026-06-05 via tools/run_stage3_rtl_guard.py (branch backend/lq-instrument @03b097d).
All early-redirect params 1'b0; bound SVAs +BRANCH_RECOVERY_CHECK/STRICT + fetch checkers ON — clean.

| bench | timed_cycles | instret | score |
|---|---|---|---|
| dhrystone_100  | 13698   | 35515   | 4.2608 DMIPS/MHz |
| dhrystone_300  | 40298   | 105715  | 4.2731 DMIPS/MHz |
| coremark_iter1 | 159083  | 332153  | 6.6491 CoreMark/MHz |
| coremark_iter10| 1468221 | 3197420 | 6.8516 CoreMark/MHz |

GOLDEN for bit-exact = the instret counts + UART transcripts (committed-arch state).
Cycles WILL drop with early-redirect; arch results MUST be identical. Full log: guard_baseline.log.

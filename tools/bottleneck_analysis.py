#!/usr/bin/env python3
"""
bottleneck_analysis.py -- rank frontend/pipeline bottleneck counters from a
run's perf_counters dict to drive data-first RTL iteration discipline.

Methodology (per feedback_perf_discipline.md):
  Phase 1 -- Data-driven analysis BEFORE any RTL change. Always present
  the data first: stall counters, mispredict rates, pipeline stage
  utilization. Quantify the expected IPC delta from the proposed change
  against measured numbers.

This tool reads a results.json (produced by tools/run_benchmarks.py)
and outputs a ranked table of bottleneck counters with cycles, % of
total run, and architectural attribution. The output is meant to be
read BEFORE the user (or another session) proposes an RTL change.

Each candidate RTL change must then declare:
  - which counter it targets (--targets-counter NAME)
  - what movement is predicted (--expect-counter-decrease NAME:DELTA)
The harness verifies prediction vs measurement; rows where the
prediction did not materialize are FAIL even if cycles improved.

Usage:
  ./tools/bottleneck_analysis.py <results.json> [--bench NAME] [--top N]
  ./tools/bottleneck_analysis.py benchmark_results/signoff_pre_alpha_baseline/coremark_iter10_checkedin/result.json
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


# Counters whose "high" values indicate frontend bubble or pipeline stall.
# Each entry: (counter_name, attribution, what_it_means).
BOTTLENECK_COUNTERS = [
    # Full bottleneck DSE grouped counters.
    ("xs_bottleneck_dep_wait_on_load", "dependency/wakeup", "IQ source-wait slots whose producer was a load"),
    ("xs_bottleneck_dep_wait_on_alu", "dependency/wakeup", "IQ source-wait slots whose producer was an ALU uop"),
    ("xs_bottleneck_dep_alu_wait_issue_same_cycle", "dependency/wakeup", "ALU-produced sources waiting in the same cycle their producer issued"),
    ("xs_bottleneck_dep_alu_wait_not_issued", "dependency/wakeup", "ALU-produced sources whose producer had not issued yet"),
    ("xs_bottleneck_dep_alu_wait_not_issued_absent", "dependency/wakeup", "not-yet-issued ALU producer no longer present in an integer IQ"),
    ("xs_bottleneck_dep_alu_wait_not_issued_producer_blocked", "dependency/wakeup", "not-yet-issued ALU producer is still in an integer IQ waiting on operands"),
    ("xs_bottleneck_dep_alu_wait_not_issued_producer_blocked_single_alu", "dependency/wakeup", "blocked ALU producer waiting on one ALU-produced source"),
    ("xs_bottleneck_dep_alu_wait_not_issued_producer_blocked_single_load", "dependency/wakeup", "blocked ALU producer waiting on one load-produced source"),
    ("xs_bottleneck_dep_alu_wait_not_issued_producer_blocked_single_branch", "dependency/wakeup", "blocked ALU producer waiting on one branch/link-produced source"),
    ("xs_bottleneck_dep_alu_wait_not_issued_producer_blocked_single_mul", "dependency/wakeup", "blocked ALU producer waiting on one multiply-produced source"),
    ("xs_bottleneck_dep_alu_wait_not_issued_producer_blocked_single_div", "dependency/wakeup", "blocked ALU producer waiting on one divide-produced source"),
    ("xs_bottleneck_dep_alu_wait_not_issued_producer_blocked_single_store", "dependency/wakeup", "blocked ALU producer waiting on one store-side source"),
    ("xs_bottleneck_dep_alu_wait_not_issued_producer_blocked_single_csr", "dependency/wakeup", "blocked ALU producer waiting on one CSR-produced source"),
    ("xs_bottleneck_dep_alu_wait_not_issued_producer_blocked_single_unknown", "dependency/wakeup", "blocked ALU producer waiting on one unknown-class source"),
    ("xs_bottleneck_dep_alu_wait_not_issued_producer_blocked_multi_src", "dependency/wakeup", "blocked ALU producer waiting on both source operands"),
    ("xs_bottleneck_dep_alu_wait_not_issued_producer_blocked_any_alu", "dependency/wakeup", "blocked ALU producer has at least one missing ALU-produced source, overlapping"),
    ("xs_bottleneck_dep_alu_wait_not_issued_producer_blocked_any_load", "dependency/wakeup", "blocked ALU producer has at least one missing load-produced source, overlapping"),
    ("xs_bottleneck_dep_alu_wait_not_issued_producer_blocked_any_branch", "dependency/wakeup", "blocked ALU producer has at least one missing branch/link-produced source, overlapping"),
    ("xs_bottleneck_dep_alu_wait_not_issued_producer_blocked_any_mul", "dependency/wakeup", "blocked ALU producer has at least one missing multiply-produced source, overlapping"),
    ("xs_bottleneck_dep_alu_wait_not_issued_producer_blocked_any_div", "dependency/wakeup", "blocked ALU producer has at least one missing divide-produced source, overlapping"),
    ("xs_bottleneck_dep_alu_wait_not_issued_producer_blocked_any_store", "dependency/wakeup", "blocked ALU producer has at least one missing store-side source, overlapping"),
    ("xs_bottleneck_dep_alu_wait_not_issued_producer_blocked_any_csr", "dependency/wakeup", "blocked ALU producer has at least one missing CSR-produced source, overlapping"),
    ("xs_bottleneck_dep_alu_wait_not_issued_producer_blocked_any_unknown", "dependency/wakeup", "blocked ALU producer has at least one missing unknown-class source, overlapping"),
    ("xs_bottleneck_dep_alu_wait_not_issued_producer_ready_not_selected", "issue queue", "not-yet-issued ALU producer is ready in an integer IQ but lost selection"),
    ("xs_bottleneck_dep_alu_wait_not_issued_producer_selected", "issue queue invariant", "not-yet-issued ALU producer also appears selected this cycle, should be near zero"),
    ("xs_bottleneck_dep_alu_wait_issued_not_wb", "dependency/wakeup", "ALU-produced sources whose producer issued but had not written back"),
    ("xs_bottleneck_dep_alu_wait_done_stale", "dependency/wakeup invariant", "ALU-produced sources still not ready after producer writeback, should be investigated"),
    ("xs_bottleneck_dep_alu_wait_state_unknown", "dependency/wakeup", "ALU-produced sources with unknown producer lifecycle state"),
    ("xs_bottleneck_dep_alu_blocked_prod_add", "dependency/uop shape", "blocked not-yet-issued ALU producers classified as ADD/ADDI"),
    ("xs_bottleneck_dep_alu_blocked_prod_sub", "dependency/uop shape", "blocked not-yet-issued ALU producers classified as SUB"),
    ("xs_bottleneck_dep_alu_blocked_prod_logic", "dependency/uop shape", "blocked not-yet-issued ALU producers classified as boolean logic"),
    ("xs_bottleneck_dep_alu_blocked_prod_shift", "dependency/uop shape", "blocked not-yet-issued ALU producers classified as shift or rotate"),
    ("xs_bottleneck_dep_alu_blocked_prod_compare", "dependency/uop shape", "blocked not-yet-issued ALU producers classified as compare or conditional zero"),
    ("xs_bottleneck_dep_alu_blocked_prod_zba", "dependency/uop shape", "blocked not-yet-issued ALU producers classified as Zba shifted-add"),
    ("xs_bottleneck_dep_alu_blocked_prod_zbb_zbs", "dependency/uop shape", "blocked not-yet-issued ALU producers classified as Zbb or Zbs"),
    ("xs_bottleneck_dep_alu_blocked_prod_other", "dependency/uop shape", "blocked not-yet-issued ALU producers not covered by the other ALU shape buckets"),
    ("xs_bottleneck_dep_alu_blocked_prod_imm", "dependency/uop shape", "blocked not-yet-issued ALU producers using an immediate operand"),
    ("xs_bottleneck_dep_alu_blocked_prod_reg", "dependency/uop shape", "blocked not-yet-issued ALU producers using register-register operands"),
    ("xs_bottleneck_dep_alu_blocked_prod_move_candidate", "dependency/uop shape", "blocked not-yet-issued ALU producers that are ADDI rd,rs,0 move candidates"),
    ("xs_bottleneck_dep_alu_blocked_prod_zero_candidate", "dependency/uop shape", "blocked not-yet-issued ALU producers that match safe zero-elimination shapes"),
    ("xs_bottleneck_dep_alu_blocked_prod_wop", "dependency/uop shape", "blocked not-yet-issued ALU producers that are RV64 W-suffix ops"),
    ("xs_bottleneck_dep_alu_blocked_prod_fused", "dependency/uop shape", "blocked not-yet-issued ALU producers generated by macro-fusion"),
    ("xs_bottleneck_dep_alu_wakeup_same_cycle_candidate", "dependency/wakeup", "entries made eligible by a same-cycle wakeup from an ALU producer"),
    ("xs_bottleneck_dep_alu_wakeup_same_cycle_missed", "dependency/wakeup", "ALU-woken entries that were not selected in the same cycle"),
    ("xs_bottleneck_dep_alu_ready_not_selected", "issue queue", "ready ALU uops that were eligible but not selected"),
    ("xs_bottleneck_rename_move_candidates", "dependency/uop shape", "dynamic ADDI rd,rs,0 move candidates seen at rename"),
    ("xs_bottleneck_rename_move_candidates_rs1_ready", "dependency/uop shape", "move candidates whose source was ready at rename"),
    ("xs_bottleneck_rename_move_candidates_rs1_wait", "dependency/uop shape", "move candidates whose source was not ready at rename"),
    ("xs_bottleneck_rename_zero_eliminated", "dependency/uop shape", "safe zero-producing ALU instructions eliminated at rename"),
    ("xs_bottleneck_dep_wait_on_branch", "dependency/wakeup", "IQ source-wait slots whose producer was branch/link work"),
    ("xs_bottleneck_dep_wait_on_mul", "dependency/wakeup", "IQ source-wait slots whose producer was multiply"),
    ("xs_bottleneck_dep_wait_on_div", "dependency/wakeup", "IQ source-wait slots whose producer was divide"),
    ("xs_bottleneck_dep_wait_on_store", "dependency/wakeup", "IQ source-wait slots whose producer was store-side work"),
    ("xs_bottleneck_dep_wait_on_csr", "dependency/wakeup", "IQ source-wait slots whose producer was CSR"),
    ("xs_bottleneck_dep_wait_on_unknown", "dependency/wakeup", "IQ source-wait slots with unknown producer class"),
    ("xs_bottleneck_wakeup_same_cycle_missed", "dependency/wakeup", "entries made eligible by wakeup but not selected that cycle"),
    ("xs_bottleneck_iq0_not_ready_entry_sum", "issue queue", "IQ0 valid-entry cycles blocked on operands"),
    ("xs_bottleneck_iq1_not_ready_entry_sum", "issue queue", "IQ1 valid-entry cycles blocked on operands"),
    ("xs_bottleneck_iq2_not_ready_entry_sum", "issue queue", "IQ2 valid-entry cycles blocked on operands"),
    ("xs_bottleneck_iq_load_not_ready_entry_sum", "issue queue", "load IQ valid-entry cycles blocked on operands"),
    ("xs_bottleneck_iq_store_not_ready_entry_sum", "issue queue", "store-address IQ valid-entry cycles blocked on operands"),
    ("xs_bottleneck_iq_std_not_ready_entry_sum", "issue queue", "store-data IQ valid-entry cycles blocked on operands"),
    ("xs_bottleneck_iq0_arb_loss", "issue queue", "eligible IQ0 entries beyond selected issue capacity"),
    ("xs_bottleneck_iq1_arb_loss", "issue queue", "eligible IQ1 entries beyond selected issue capacity"),
    ("xs_bottleneck_iq2_arb_loss", "issue queue", "eligible IQ2 entries beyond selected issue capacity"),
    ("xs_bottleneck_iq_load_arb_loss", "issue queue", "eligible load IQ entries beyond selected issue capacity"),
    ("xs_bottleneck_iq0_enq_ready_hidden", "issue queue", "ready IQ0 enqueues not visible to same-cycle issue"),
    ("xs_bottleneck_iq1_enq_ready_hidden", "issue queue", "ready IQ1 enqueues not visible to same-cycle issue"),
    ("xs_bottleneck_iq2_enq_ready_hidden", "issue queue", "ready IQ2 enqueues not visible to same-cycle issue"),
    ("xs_bottleneck_iq0_enq_spec_wakeup", "dependency/wakeup", "IQ0 enqueues woken by same-cycle speculative load wakeup for next-cycle issue"),
    ("xs_bottleneck_iq1_enq_spec_wakeup", "dependency/wakeup", "IQ1 enqueues woken by same-cycle speculative load wakeup for next-cycle issue"),
    ("xs_bottleneck_iq2_enq_spec_wakeup", "dependency/wakeup", "IQ2 enqueues woken by same-cycle speculative load wakeup for next-cycle issue"),
    ("xs_bottleneck_iq_load_enq_spec_wakeup", "dependency/wakeup", "load IQ enqueues woken by same-cycle speculative load wakeup for next-cycle issue"),
    ("xs_bottleneck_iq_store_enq_spec_wakeup", "dependency/wakeup", "store-address IQ enqueues woken by same-cycle speculative load wakeup for next-cycle issue"),
    ("xs_bottleneck_iq_std_enq_spec_wakeup", "dependency/wakeup", "store-data IQ enqueues woken by same-cycle speculative load wakeup for next-cycle issue"),
    ("xs_bottleneck_iq0_enq_spec_cancelled", "dependency/wakeup", "IQ0 enqueue speculative load wakeups suppressed by same-cycle cancel"),
    ("xs_bottleneck_iq1_enq_spec_cancelled", "dependency/wakeup", "IQ1 enqueue speculative load wakeups suppressed by same-cycle cancel"),
    ("xs_bottleneck_iq2_enq_spec_cancelled", "dependency/wakeup", "IQ2 enqueue speculative load wakeups suppressed by same-cycle cancel"),
    ("xs_bottleneck_iq_load_enq_spec_cancelled", "dependency/wakeup", "load IQ enqueue speculative load wakeups suppressed by same-cycle cancel"),
    ("xs_bottleneck_iq_store_enq_spec_cancelled", "dependency/wakeup", "store-address IQ enqueue speculative load wakeups suppressed by same-cycle cancel"),
    ("xs_bottleneck_iq_std_enq_spec_cancelled", "dependency/wakeup", "store-data IQ enqueue speculative load wakeups suppressed by same-cycle cancel"),
    ("xs_bottleneck_iq0_enq_bypass_suppressed", "issue queue", "ready IQ0 enqueue bypass candidates lost to arbitration or suppression"),
    ("xs_bottleneck_iq1_enq_bypass_suppressed", "issue queue", "ready IQ1 enqueue bypass candidates lost to arbitration or suppression"),
    ("xs_bottleneck_iq2_enq_bypass_suppressed", "issue queue", "ready IQ2 enqueue bypass candidates lost to arbitration or suppression"),
    ("xs_bottleneck_iq0_enq_bypass_fu_blocked", "issue queue", "ready IQ0 enqueue bypass candidates blocked by FU-class policy"),
    ("xs_bottleneck_iq1_enq_bypass_fu_blocked", "issue queue", "ready IQ1 enqueue bypass candidates blocked by FU-class policy"),
    ("xs_bottleneck_iq2_enq_bypass_fu_blocked", "issue queue", "ready IQ2 enqueue bypass candidates blocked by FU-class policy"),
    ("xs_bottleneck_iq0_enq_bypass_fu_blocked_bru_cond", "issue queue", "ready IQ0 conditional BRU bypass candidates blocked by FU-class policy"),
    ("xs_bottleneck_iq1_enq_bypass_fu_blocked_bru_cond", "issue queue", "ready IQ1 conditional BRU bypass candidates blocked by FU-class policy"),
    ("xs_bottleneck_iq2_enq_bypass_fu_blocked_bru_cond", "issue queue", "ready IQ2 conditional BRU bypass candidates blocked by FU-class policy"),
    ("xs_bottleneck_iq0_enq_bypass_fu_blocked_bru_backedge", "issue queue", "ready IQ0 backward predicted-taken conditional BRU bypass candidates blocked by FU-class policy"),
    ("xs_bottleneck_iq1_enq_bypass_fu_blocked_bru_backedge", "issue queue", "ready IQ1 backward predicted-taken conditional BRU bypass candidates blocked by FU-class policy"),
    ("xs_bottleneck_iq2_enq_bypass_fu_blocked_bru_backedge", "issue queue", "ready IQ2 backward predicted-taken conditional BRU bypass candidates blocked by FU-class policy"),
    ("xs_bottleneck_iq0_enq_bypass_fu_blocked_bru_jal", "issue queue", "ready IQ0 JAL bypass candidates blocked by FU-class policy"),
    ("xs_bottleneck_iq1_enq_bypass_fu_blocked_bru_jal", "issue queue", "ready IQ1 JAL bypass candidates blocked by FU-class policy"),
    ("xs_bottleneck_iq2_enq_bypass_fu_blocked_bru_jal", "issue queue", "ready IQ2 JAL bypass candidates blocked by FU-class policy"),
    ("xs_bottleneck_iq0_enq_bypass_fu_blocked_bru_jalr", "issue queue", "ready IQ0 JALR bypass candidates blocked by FU-class policy"),
    ("xs_bottleneck_iq1_enq_bypass_fu_blocked_bru_jalr", "issue queue", "ready IQ1 JALR bypass candidates blocked by FU-class policy"),
    ("xs_bottleneck_iq2_enq_bypass_fu_blocked_bru_jalr", "issue queue", "ready IQ2 JALR bypass candidates blocked by FU-class policy"),
    ("xs_bottleneck_iq0_enq_bypass_fu_blocked_serial", "issue queue", "ready IQ0 MUL/DIV/CSR bypass candidates blocked by FU-class policy"),
    ("xs_bottleneck_iq1_enq_bypass_fu_blocked_serial", "issue queue", "ready IQ1 MUL/DIV/CSR bypass candidates blocked by FU-class policy"),
    ("xs_bottleneck_iq2_enq_bypass_fu_blocked_serial", "issue queue", "ready IQ2 MUL/DIV/CSR bypass candidates blocked by FU-class policy"),
    ("xs_bottleneck_rob_commit_zero_cycles", "commit", "cycles with no committed instructions"),
    ("xs_bottleneck_rob_commit_slots_lost_head_block", "commit", "ready younger commit slots hidden behind a not-ready head"),
    ("xs_bottleneck_lsu_load_reissue_total", "LSU", "load issues that replaced an already tracked pending load"),
    ("xs_bottleneck_lsu_load_latency_8_15", "LSU", "loads with 8-15 cycle issue-to-WB latency"),
    ("xs_bottleneck_lsu_load_latency_16_31", "LSU", "loads with 16-31 cycle issue-to-WB latency"),
    ("xs_bottleneck_lsu_load_latency_32plus", "LSU", "loads with 32+ cycle issue-to-WB latency"),
    ("xs_bottleneck_lsu_store_forward_wait", "LSU", "load cycles waiting for store forwarding"),
    ("xs_bottleneck_lsu_dcache_port_wait", "LSU", "second load blocked by D-cache port/conflict path"),
    ("xs_bottleneck_branch_mispredicts", "control flow", "committed mispredict count"),
    ("xs_bottleneck_branch_ghr_restore", "control flow", "GHR restore events"),
    ("xs_branch_opportunity_cdb_mispredict_cycles", "control flow", "cycles with at least one execute-time branch mispredict on the CDB"),
    ("xs_branch_opportunity_cdb_mispredict_slots", "control flow", "execute-time branch mispredict slots on the CDB"),
    ("xs_branch_opportunity_type_cond", "control flow", "baseline CDB branch mispredict opportunities classified as conditional branches"),
    ("xs_branch_opportunity_type_jal", "control flow", "baseline CDB branch mispredict opportunities classified as JAL"),
    ("xs_branch_opportunity_type_jalr", "control flow", "baseline CDB branch mispredict opportunities classified as JALR"),
    ("xs_branch_opportunity_type_call", "control flow", "baseline CDB branch mispredict opportunities classified as call"),
    ("xs_branch_opportunity_type_ret", "control flow", "baseline CDB branch mispredict opportunities classified as return"),
    ("xs_branch_opportunity_age_head", "control flow", "execute-time branch mispredicts already at ROB head"),
    ("xs_branch_opportunity_age_near", "control flow", "execute-time branch mispredicts with ROB age 1-3"),
    ("xs_branch_opportunity_age_mid", "control flow", "execute-time branch mispredicts with ROB age 4-15"),
    ("xs_branch_opportunity_age_far", "control flow", "execute-time branch mispredicts with ROB age 16-63"),
    ("xs_branch_opportunity_age_older", "control flow", "execute-time branch mispredicts with ROB age 64+"),
    ("xs_branch_opportunity_age_sum", "control flow", "sum of ROB age for execute-time branch mispredicts"),
    ("xs_branch_opportunity_age_max", "control flow", "maximum ROB age for execute-time branch mispredicts"),
    ("xs_branch_opportunity_checkpoint_any", "control flow", "execute-time branch mispredicts with any checkpoint metadata"),
    ("xs_branch_opportunity_checkpoint_at_branch", "control flow", "execute-time branch mispredicts whose checkpoint tail is exactly the branch ROB"),
    ("xs_branch_opportunity_checkpoint_missing", "control flow", "execute-time branch mispredicts missing checkpoint metadata"),
    ("xs_branch_opportunity_side_effect", "control flow", "execute-time branch mispredicts that write an architectural destination"),
    ("xs_branch_opportunity_partial_candidate", "control flow", "execute-time branch mispredicts satisfying current backend-only partial recovery candidate rules"),
    ("xs_branch_opportunity_partial_resource_ok", "control flow", "partial recovery candidates with current resource headroom"),
    ("xs_branch_opportunity_reject_commit", "control flow", "partial recovery candidate rejects because commit flush was active"),
    ("xs_branch_opportunity_reject_rename", "control flow", "partial recovery candidate rejects because rename was stalled"),
    ("xs_branch_opportunity_reject_uoc", "control flow", "partial recovery candidate rejects because decoded-op replay was active"),
    ("xs_branch_opportunity_reject_side_effect", "control flow", "partial recovery candidate rejects because the branch has destination side effects"),
    ("xs_branch_opportunity_reject_checkpoint", "control flow", "partial recovery candidate rejects because checkpoint ownership is insufficient"),
    ("xs_branch_opportunity_reject_rename_headroom", "control flow", "partial recovery resource rejects from rename headroom"),
    ("xs_branch_opportunity_reject_frontend_headroom", "control flow", "partial recovery resource rejects from frontend headroom"),
    ("xs_branch_opportunity_reject_burst", "control flow", "partial recovery resource rejects from recovery burst cooldown"),
    ("xs_branch_opportunity_younger_sum", "control flow", "sum of younger ROB entries behind execute-time mispredicted branches"),
    ("xs_branch_opportunity_younger_ready_sum", "control flow", "sum of ready younger ROB entries behind execute-time mispredicted branches"),
    ("xs_branch_opportunity_younger_max", "control flow", "maximum younger ROB entries behind an execute-time mispredicted branch"),
    ("xs_branch_opportunity_younger_ready_max", "control flow", "maximum ready younger ROB entries behind an execute-time mispredicted branch"),
    ("xs_branch_recovery_saves_blocked_full", "control flow", "checkpoint save requests blocked by full checkpoint state"),
    ("xs_branch_recovery_saves_ignored_recovery", "control flow", "checkpoint save requests ignored because recovery or full flush had priority"),
    ("xs_branch_recovery_invalid_release", "control flow invariant", "checkpoint releases for unoccupied slots, must remain 0"),
    ("xs_branch_recovery_duplicate_release", "control flow invariant", "duplicate checkpoint releases in one cycle, must remain 0"),
    ("xs_branch_recovery_invalid_restore", "control flow invariant", "checkpoint restores for unoccupied slots, must remain 0"),
    ("xs_branch_recovery_save_overwrite", "control flow invariant", "checkpoint saves that would overwrite an occupied post-release slot, must remain 0"),
    ("xs_branch_recovery_save_blocked_with_free", "control flow invariant", "checkpoint save blocked while a post-release slot was free, must remain 0"),
    ("xs_branch_recovery_restore_release_conflict", "control flow invariant", "same checkpoint restored and released in one cycle, must remain 0"),
    ("xs_branch_recovery_restore_mask_mismatch", "control flow invariant", "restore keep-mask differs from sequence-derived expectation, must remain 0"),
    ("xs_branch_recovery_restore_kept_self", "control flow invariant", "restore kept the recovered checkpoint live, must remain 0"),
    ("xs_bottleneck_fe_zero_cycles", "frontend supply", "cycles where rename saw zero frontend instructions"),
    ("xs_bottleneck_fe_redirect_recovery", "control flow", "fetch-zero cycles attributed to redirect recovery"),
    ("xs_bottleneck_fe_packet_empty", "frontend supply", "fetch-zero cycles with empty decode packet"),
    ("xs_bottleneck_fe_packet_empty_f2_data", "frontend supply", "fetch-zero cycles with F2 data but no useful packet"),
    ("xs_bottleneck_fe_packet_empty_noemit_dup", "frontend supply", "fetch-zero cycles suppressed as duplicate/no emit"),
    ("xs_data_present_no_emit", "frontend runahead", "F2 had data and an emit payload, but no packet was emitted"),
    ("xs_data_no_emit_dup", "frontend runahead", "data-present no-emit cycles caused by duplicate suppression"),
    ("xs_data_no_emit_redirect", "frontend runahead", "data-present no-emit cycles blocked by redirect"),
    ("xs_data_no_emit_pkt_not_ready", "frontend runahead", "data-present no-emit cycles blocked by packet enqueue readiness"),
    ("xs_data_no_emit_fe_stall", "frontend runahead", "data-present no-emit cycles blocked by frontend stall"),
    ("xs_data_no_emit_post_ifu_live", "frontend runahead", "data-present no-emit cycles while at least one owner is live after IFU"),
    ("xs_data_no_emit_post_ifu_gt1", "frontend runahead", "data-present no-emit cycles while post-IFU owner depth is greater than one"),
    ("xs_data_no_emit_wb_gt1", "frontend runahead", "data-present no-emit cycles while IFU-to-writeback owner depth is greater than one"),
    ("xs_data_no_emit_pktbuf_empty", "frontend runahead", "data-present no-emit cycles with an empty IBuffer"),
    ("xs_data_no_emit_pktbuf_nonempty", "frontend runahead", "data-present no-emit cycles with resident IBuffer packets"),
    ("xs_data_no_emit_pktbuf_full", "frontend runahead", "data-present no-emit cycles with a full IBuffer"),
    ("xs_data_no_emit_owner_live", "frontend runahead", "data-present no-emit cycles where the F2 owner matches the live IFU owner"),
    ("xs_data_no_emit_owner_not_live", "frontend runahead", "data-present no-emit cycles where the F2 owner is not the live IFU owner"),
    ("xs_data_no_emit_owner_complete", "frontend runahead", "data-present no-emit cycles where the F2 owner is complete"),
    ("xs_data_no_emit_dup_post_ifu_gt1", "frontend runahead", "duplicate no-emit cycles with post-IFU owner depth greater than one"),
    ("xs_data_no_emit_redir_post_ifu_gt1", "frontend runahead", "redirect no-emit cycles with post-IFU owner depth greater than one"),
    ("xs_data_no_emit_dup_pktbuf_empty", "frontend runahead", "duplicate no-emit cycles with an empty IBuffer"),
    ("xs_data_no_emit_redir_pktbuf_empty", "frontend runahead", "redirect no-emit cycles with an empty IBuffer"),
    ("xs_dup_suppressed", "frontend runahead", "duplicate suppression cycles"),
    ("xs_dup_same_owner", "frontend runahead", "duplicate suppression while same-owner continuation was legal"),
    ("xs_dup_no_same_owner", "frontend runahead", "duplicate suppression without same-owner continuation"),
    ("xs_dup_no_owner_control", "frontend runahead", "duplicate no-owner cycles with control in the line"),
    ("xs_dup_no_owner_taken", "frontend runahead", "duplicate no-owner cycles with taken control"),
    ("xs_dup_no_owner_straddle", "frontend runahead", "duplicate no-owner cycles with straddle context"),
    ("xs_dup_no_owner_safe_noctl", "frontend runahead", "duplicate no-owner cycles that look safe and control-free"),
    ("xs_dup_with_runahead_pending", "frontend runahead", "duplicate cycles overlapping current IFU runahead pending state"),
    ("xs_same_owner_candidate", "frontend runahead", "same-owner continuation candidates"),
    ("xs_same_owner_emit_cand", "frontend runahead", "same-owner continuation candidates with emit payload"),
    ("xs_same_owner_advanced", "frontend runahead", "same-owner continuation actually advanced"),
    ("xs_same_owner_block_no_emit", "frontend runahead", "same-owner candidate blocked because no packet emitted"),
    ("xs_same_owner_block_rem", "frontend runahead", "same-owner emit candidate blocked by remainder handling"),
    ("xs_same_owner_block_rem_consume", "frontend runahead", "same-owner remainder block due consume-remainder"),
    ("xs_same_owner_block_rem_consumed", "frontend runahead", "same-owner remainder block due already-consumed remainder"),
    ("xs_same_owner_block_rem_backend", "frontend runahead", "same-owner remainder block overlapping backend stall"),
    ("xs_same_owner_no_emit_dup", "frontend runahead", "same-owner no-emit cycles caused by duplicate suppression"),
    ("xs_same_owner_no_emit_redirect", "frontend runahead", "same-owner no-emit cycles blocked by redirect"),
    ("xs_same_owner_no_emit_pkt_not_ready", "frontend runahead", "same-owner no-emit cycles blocked by packet enqueue readiness"),
    ("xs_same_owner_no_emit_fe_stall", "frontend runahead", "same-owner no-emit cycles blocked by frontend stall"),
    ("xs_runahead_req_valid", "frontend runahead", "IFU runahead request opportunities"),
    ("xs_runahead_req_fire", "frontend runahead", "IFU runahead requests that fired"),
    ("xs_runahead_pending_cycles", "frontend runahead", "cycles with an IFU runahead request pending"),
    ("xs_runahead_redirect_match", "frontend runahead", "runahead duplicate allocation blocked by redirect-match condition"),
    ("xs_runahead_dup_alloc_block", "frontend runahead", "duplicate allocation blocks for IFU runahead"),
    ("xs_ftq_depth_gt1_cycles", "frontend runahead", "cycles where IFU runahead depth exceeded one owner"),
    ("xs_ftq_alloc2ifu_occ_sum", "frontend runahead", "sum of FTQ entries allocated but not yet consumed by IFU"),
    ("xs_ftq_alloc2ifu_occ_max", "frontend runahead", "maximum FTQ allocated-to-IFU depth"),
    ("xs_ftq_alloc2ifu_occ_hist_2to3", "frontend runahead", "cycles with FTQ allocated-to-IFU depth from 2 to 3"),
    ("xs_ftq_ifu2wb_occ_sum", "frontend runahead", "sum of FTQ entries consumed by IFU but not yet written back"),
    ("xs_ftq_ifu2wb_occ_max", "frontend runahead", "maximum FTQ IFU-to-writeback depth"),
    ("xs_ftq_ifu2wb_occ_hist_2to3", "frontend runahead", "cycles with FTQ IFU-to-writeback depth from 2 to 3"),
    ("xs_ftq_ifu2commit_occ_sum", "frontend runahead", "sum of FTQ entries between IFU and commit/training ownership"),
    ("xs_ftq_ifu2commit_occ_max", "frontend runahead", "maximum FTQ IFU-to-commit depth"),
    ("xs_ftq_ifu2commit_occ_hist_2to3", "frontend runahead", "cycles with FTQ IFU-to-commit depth from 2 to 3"),
    ("xs_icq_future_head_block", "frontend runahead", "ICQ has a future line while current F2 work needs another line"),
    ("xs_f2_data_wait", "frontend runahead", "F2 work waiting for line data"),
    ("xs_f2_data_wait_icq_empty", "frontend runahead", "F2 data wait because ICQ is empty"),
    ("xs_f2_data_wait_icq_valid", "frontend runahead", "F2 data wait while ICQ has data"),
    ("xs_f2_data_wait_icq_line_mismatch", "frontend runahead", "F2 data wait because ICQ head line mismatches current work"),
    ("xs_bottleneck_rename_slots_lost_total", "rename/window", "frontend slots that did not advance through rename"),
    ("xs_bottleneck_rename_stall_preg", "rename/window", "rename stalls caused by physical register pressure"),
    ("xs_bottleneck_rename_stall_rob", "rename/window", "rename stalls caused by ROB pressure"),
    ("xs_bottleneck_rename_stall_dq", "rename/window", "rename stalls caused by dispatch queue pressure"),
    ("xs_bottleneck_rename_stall_backend_throttle", "rename/window", "rename stalls caused by the opt-in backend admission governor"),
    ("xs_bottleneck_backend_throttle_active_cycles", "backend admission", "cycles where the opt-in backend admission governor limited rename width"),
    ("xs_bottleneck_backend_throttle_limited_slots", "backend admission", "rename slots intentionally deferred by the backend admission governor"),
    ("xs_bottleneck_backend_throttle_enter_cycles", "backend admission", "cycles where backend pressure entered throttle state"),
    ("xs_bottleneck_backend_throttle_pressure_cycles", "backend admission", "cycles where ROB or physical-register headroom was below throttle threshold"),
    ("xs_bottleneck_backend_throttle_head_block_cycles", "backend admission", "cycles where the ROB head was valid but not ready"),
    # Empty-packet attribution (frontend supply gap)
    ("packet_empty",                 "frontend supply",         "F2 emitted no packet this cycle"),
    ("packet_empty_f2_data",         "frontend supply",         "F2 had no fresh icache data"),
    ("packet_empty_f2_emit",         "frontend supply",         "F2 had data but did not emit"),
    ("packet_empty_noemit_dup",      "frontend supply",         "F2 suppressed re-emit of held packet"),
    ("packet_empty_wait_icresp",     "frontend supply",         "F2 waiting on icache miss/refill"),
    ("packet_empty_ftq_full",        "frontend supply",         "F2 blocked because FTQ full"),
    # Owner-tracking attribution (FTQ/F2 ownership behavior)
    ("xs_dup_last_emit",             "F2 ownership",            "F2 PC matched last-emitted PC (suppressor fired)"),
    ("xs_dup_replay_guard",          "F2 ownership",            "F2 replay-block guard fired"),
    ("xs_f2_owner_no_head",          "F2 ownership",            "F2 had owner but FTQ head drained"),
    ("xs_f2_owner_idx_mismatch",     "F2 ownership invariant",  "F2 owner FTQ idx vs head mismatch (must be 0)"),
    ("xs_f2_owner_epoch_mismatch",   "F2 ownership invariant",  "F2 owner epoch vs head mismatch (must be 0)"),
    ("xs_f2_owner_tag_mismatch",     "F2 ownership invariant",  "F2 owner tag vs head mismatch (must be 0)"),
    # FTQ + packet-buf occupancy (lockstep indicator)
    ("xs_ftq_full_cycles",           "FTQ occupancy",           "FTQ at depth limit"),
    ("xs_ftq_empty_cycles",          "FTQ occupancy",           "FTQ has no entries (decode/IFU starved)"),
    ("xs_packet_buf_empty_cycles",   "packet buffer occupancy", "decode starved by empty packet buf"),
    ("xs_packet_buf_full_cycles",    "packet buffer occupancy", "back-pressure from decode"),
    # Backend stalls
    ("xs_backend_stall_cycles",      "backend",                 "backend back-pressure on packet"),
    ("xs_backend_stall_pkt_ready",   "backend",                 "backend stall while packet was ready"),
    # Redirect cost
    ("redirect_recovery",            "control flow",            "cycles spent recovering from redirect"),
    # ICache request stalls
    ("xs_ic_stall_frontend_hold",    "icache",                  "icache req gated by frontend hold"),
    ("xs_ic_stall_packet_full",      "icache",                  "icache req gated by packet buf full"),
    ("xs_ic_stall_ftq_full",         "icache",                  "icache req gated by FTQ full"),
]


def load_results(path: Path) -> list[dict]:
    """Load a result.json (single-bench) or results.json (multi-bench)."""
    data = json.loads(path.read_text())
    if isinstance(data, dict) and "results" in data:
        return data["results"]
    if isinstance(data, dict):
        return [data]
    return data


def total_cycles(row: dict) -> int | None:
    pc = row.get("perf_counters") or {}
    if (mc := row.get("mcycle")) is not None:
        return int(mc)
    if (cyc := row.get("cycle")) is not None:
        return int(cyc)
    if (mc := pc.get("xs_ic_req_valid_cycles")) is not None:
        return int(mc)
    return None


def render_one(row: dict, top_n: int) -> str:
    name = row.get("name", "<unknown>")
    pc = row.get("perf_counters") or {}
    total = total_cycles(row)
    if not total:
        return f"### {name}: no cycle data\n"

    rows = []
    for counter, attribution, meaning in BOTTLENECK_COUNTERS:
        val = pc.get(counter)
        if val is None:
            continue
        pct = 100.0 * val / total
        rows.append((counter, attribution, meaning, int(val), pct))
    rows.sort(key=lambda r: r[3], reverse=True)

    out = []
    out.append(f"### {name}")
    out.append(f"total cycles: {total:,}    minstret: {row.get('minstret', '-')}    "
               f"IPC: {row.get('ipc', '-')}")
    out.append("")

    # Bypass-corrected decode-supply view. The xs_packet_buf_empty_cycles
    # counter overcounts: it fires whenever count_r=0, including cycles
    # where a packet was delivered to decode via the same-cycle bypass
    # (xs_bypass_valid) without entering the buffer. The TRUE decode-supply
    # rate is bypass_delivered + buf_delivered; everything else is a
    # decode bubble.
    bypassed = int(pc.get("xs_bypass_valid", 0))
    buf_delivered = int(pc.get("xs_packet_buf_occ_sum", 0))
    decode_bubble = max(0, total - bypassed - buf_delivered)
    if bypassed or buf_delivered:
        out.append("**Bypass-corrected decode-supply view (READ THIS FIRST):**")
        out.append("")
        out.append("| Path | Cycles | % of run |")
        out.append("|---|---:|---:|")
        out.append(f"| Packet delivered via same-cycle bypass | {bypassed:,} | {100*bypassed/total:.1f}% |")
        out.append(f"| Packet delivered via buf occupancy | {buf_delivered:,} | {100*buf_delivered/total:.1f}% |")
        out.append(f"| **Decode bubble (no packet delivered)** | **{decode_bubble:,}** | **{100*decode_bubble/total:.1f}%** |")
        out.append("")
        out.append(f"True frontend supply rate: **{100*(bypassed+buf_delivered)/total:.1f}%**. "
                   f"`xs_packet_buf_empty_cycles` reads near-100% on this design because the "
                   f"bypass path keeps the buffer empty even on supply cycles; do NOT treat "
                   f"that counter as a starvation indicator. The actual bottleneck is the "
                   f"decode bubble row above, which equals `packet_empty` to within a cycle.")
        out.append("")

    out.append("**Per-counter ranking (some entries overlap; bypass-corrected view above is authoritative):**")
    out.append("")
    out.append("| Rank | Counter | Count | Count / timed cycle | Attribution | Meaning |")
    out.append("|---:|---|---:|---:|---|---|")
    for i, (counter, attribution, meaning, val, pct) in enumerate(rows[:top_n], 1):
        flag = " ⚠ artifact" if counter == "xs_packet_buf_empty_cycles" else ""
        out.append(f"| {i} | `{counter}`{flag} | {val:,} | {pct:.1f}% | {attribution} | {meaning} |")
    out.append("")

    # Architectural recommendation. Skip xs_packet_buf_empty_cycles (artifact)
    # when picking the dominant bottleneck.
    actionable = [r for r in rows if r[0] != "xs_packet_buf_empty_cycles"]
    if actionable:
        top = actionable[0]
        out.append(f"**Dominant actionable bottleneck:** `{top[0]}` "
                   f"({top[3]:,} count, {top[4]:.1f}% of timed cycles)")
        out.append("")
        out.append("**Required for next RTL iteration (per feedback_perf_discipline.md):**")
        out.append("- Identify a specific RTL change that addresses this counter")
        out.append("- Quantify the expected reduction (predicted_delta)")
        out.append("- Run with `--mechanism-class <class>`, `--targets-counter "
                   f"{top[0]}`, and "
                   f"`--expect-counter-decrease {top[0]}:<predicted_delta>`")
        out.append("- Harness will reject the run if predicted decrease did not materialize")
    return "\n".join(out)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("results", type=Path)
    ap.add_argument("--bench", default=None, help="filter to one bench name")
    ap.add_argument("--top", type=int, default=10, help="show top N counters per bench")
    args = ap.parse_args(argv)

    if not args.results.exists():
        print(f"error: {args.results} does not exist", file=sys.stderr)
        return 2

    rows = load_results(args.results)
    if args.bench:
        rows = [r for r in rows if r.get("name") == args.bench]

    if not rows:
        print("no rows in results.json", file=sys.stderr)
        return 1

    print(f"# Bottleneck Analysis: {args.results}")
    print()
    for row in rows:
        print(render_one(row, args.top))
        print()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

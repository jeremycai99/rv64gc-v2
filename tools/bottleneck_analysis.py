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
    ("xs_bottleneck_iq0_enq_bypass_suppressed", "issue queue", "ready IQ0 enqueue bypass candidates lost to arbitration or suppression"),
    ("xs_bottleneck_iq1_enq_bypass_suppressed", "issue queue", "ready IQ1 enqueue bypass candidates lost to arbitration or suppression"),
    ("xs_bottleneck_iq2_enq_bypass_suppressed", "issue queue", "ready IQ2 enqueue bypass candidates lost to arbitration or suppression"),
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
    ("xs_bottleneck_fe_zero_cycles", "frontend supply", "cycles where rename saw zero frontend instructions"),
    ("xs_bottleneck_fe_redirect_recovery", "control flow", "fetch-zero cycles attributed to redirect recovery"),
    ("xs_bottleneck_fe_packet_empty", "frontend supply", "fetch-zero cycles with empty decode packet"),
    ("xs_bottleneck_fe_packet_empty_f2_data", "frontend supply", "fetch-zero cycles with F2 data but no useful packet"),
    ("xs_bottleneck_fe_packet_empty_noemit_dup", "frontend supply", "fetch-zero cycles suppressed as duplicate/no emit"),
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

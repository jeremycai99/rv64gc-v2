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
    # Prefer the bench-window timed cycles for normalization. Fall back to
    # mcycle if not available.
    if (cyc := row.get("cycle")) is not None:
        return int(cyc)
    if (mc := row.get("mcycle")) is not None:
        return int(mc)
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
    out.append("| Rank | Counter | Cycles | % of run | Attribution | Meaning |")
    out.append("|---:|---|---:|---:|---|---|")
    for i, (counter, attribution, meaning, val, pct) in enumerate(rows[:top_n], 1):
        out.append(f"| {i} | `{counter}` | {val:,} | {pct:.1f}% | {attribution} | {meaning} |")
    out.append("")

    # Architectural recommendation: which bottleneck is the dominant one?
    if rows:
        top = rows[0]
        out.append(f"**Dominant bottleneck:** `{top[0]}` ({top[3]:,} cycles, {top[4]:.1f}% of run)")
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

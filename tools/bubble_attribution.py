#!/usr/bin/env python3
"""
bubble_attribution.py -- per-cycle bubble classification from a pipe.v1 trace.

The aggregate bottleneck_analysis.py output identifies WHICH counter is
dominant. This tool answers WHY: it walks the pipe.v1 cycle-by-cycle trace
and classifies each cycle into bubble categories using exclusive rules,
then surfaces the longest consecutive bubble runs and the dominant
category.

Where bottleneck_analysis.py says "packet_empty=40.5%", this tool says
"of those 827k cycles, 67% are FRONTEND_BUBBLE (fetch=0 + commit could
have used a packet); 33% are PIPELINE_BUBBLE (fetch=0 because backend
already drained ROB)."

Categories (mutually exclusive, applied in priority order):
  FLUSH        : flush=1 this cycle (control-flow recovery)
  REPLAY       : replay=1 this cycle (LSU ordering replay)
  PRODUCTIVE   : commit > 0 (forward progress)
  BACKEND_STALL: fetch > 0 but commit = 0 AND rob_cnt > 0
                 (decode delivered but ROB head not ready)
  FRONTEND_BUBBLE: fetch = 0 AND rob_cnt > 0
                 (decode starved while backend has work)
  IDLE_BUBBLE  : fetch = 0 AND rob_cnt = 0
                 (frontend hasn't filled the pipeline)
  RAMP         : neither fetch=0 nor commit=0 covered (rare edge cases)

Required: a +TRACE_PIPELINE log (one [PIPE schema=pipe.v1] line per cycle).

Usage:
  ./tools/bubble_attribution.py <trace_file> [--top-runs N]
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from collections import Counter


PIPE_RE = re.compile(
    r"\[PIPE schema=pipe\.v1\] cyc=(?P<cyc>\d+) "
    r"rst=(?P<rst>[01]) "
    r"fetch=(?P<fetch>\d+) "
    r"decode=(?P<decode>\d+) "
    r"rename=(?P<rename>\d+) "
    r"dispatch=(?P<dispatch>\d+) "
    r"issue0=(?P<i0>\d+) "
    r"issue1=(?P<i1>\d+) "
    r"issue2=(?P<i2>\d+) "
    r"cdb=(?P<cdb>\d+) "
    r"commit=(?P<commit>\d+) "
    r"rob_head=(?P<rob_head>\d+) "
    r"rob_tail=(?P<rob_tail>\d+) "
    r"rob_cnt=(?P<rob_cnt>\d+) "
    r"iq0=(?P<iq0>\d+) "
    r"iq1=(?P<iq1>\d+) "
    r"iq2=(?P<iq2>\d+) "
    r"lq=(?P<lq>\d+) "
    r"sq=(?P<sq>\d+) "
    r"free=(?P<free>\d+) "
    r"ckpt=(?P<ckpt>\d+) "
    r"flush=(?P<flush>[01]) "
    r"replay=(?P<replay>[01]) "
    r"reason=(?P<reason>\d+)"
)


CATEGORIES = [
    "PRODUCTIVE",
    "FRONTEND_BUBBLE",
    "BACKEND_STALL",
    "IDLE_BUBBLE",
    "FLUSH",
    "REPLAY",
    "RAMP",
]


def classify(rec: dict[str, int]) -> str:
    if rec["rst"]:
        return "RAMP"
    if rec["flush"]:
        return "FLUSH"
    if rec["replay"]:
        return "REPLAY"
    if rec["commit"] > 0:
        return "PRODUCTIVE"
    # commit == 0 from here on
    if rec["fetch"] == 0 and rec["rob_cnt"] > 0:
        return "FRONTEND_BUBBLE"
    if rec["fetch"] == 0 and rec["rob_cnt"] == 0:
        return "IDLE_BUBBLE"
    if rec["fetch"] > 0 and rec["rob_cnt"] > 0:
        return "BACKEND_STALL"
    return "RAMP"


def parse_trace(path: Path) -> list[dict[str, int]]:
    records = []
    with path.open() as f:
        for line in f:
            m = PIPE_RE.search(line)
            if not m:
                continue
            d = m.groupdict()
            rec = {
                k: int(v)
                for k, v in d.items()
            }
            records.append(rec)
    return records


def render(records: list[dict[str, int]], top_runs: int) -> str:
    if not records:
        return "no [PIPE schema=pipe.v1] records found in trace"

    cat_per_cycle = [classify(r) for r in records]
    counts = Counter(cat_per_cycle)
    total = len(records)

    out = []
    out.append(f"# Bubble Attribution: {total:,} cycles classified")
    out.append("")
    out.append("| Category | Cycles | % of run | Meaning |")
    out.append("|---|---:|---:|---|")
    meanings = {
        "PRODUCTIVE":      "commit > 0 (forward progress)",
        "FRONTEND_BUBBLE": "fetch=0 AND rob_cnt > 0 (decode starved while backend has work)",
        "BACKEND_STALL":   "fetch > 0 but commit=0 AND rob_cnt > 0 (decode delivered, ROB head not ready)",
        "IDLE_BUBBLE":     "fetch=0 AND rob_cnt=0 (pipeline empty)",
        "FLUSH":           "control-flow recovery (flush=1)",
        "REPLAY":          "LSU ordering replay (replay=1)",
        "RAMP":            "reset/edge cases",
    }
    for cat in CATEGORIES:
        c = counts.get(cat, 0)
        out.append(f"| {cat} | {c:,} | {100*c/total:.1f}% | {meanings[cat]} |")
    out.append("")

    # Identify the dominant non-PRODUCTIVE category
    bubble_cats = [c for c in CATEGORIES if c != "PRODUCTIVE"]
    bubble_total = sum(counts.get(c, 0) for c in bubble_cats)
    if bubble_total > 0:
        dominant = max(bubble_cats, key=lambda c: counts.get(c, 0))
        dominant_count = counts.get(dominant, 0)
        out.append(f"**Dominant bubble category:** `{dominant}` "
                   f"({dominant_count:,} cycles, {100*dominant_count/total:.1f}% of run, "
                   f"{100*dominant_count/bubble_total:.1f}% of bubble cycles)")
        out.append("")

    # Find longest runs of bubble cycles (consecutive non-PRODUCTIVE)
    runs = []
    i = 0
    while i < len(cat_per_cycle):
        if cat_per_cycle[i] != "PRODUCTIVE":
            start = i
            cat = cat_per_cycle[i]
            while i < len(cat_per_cycle) and cat_per_cycle[i] != "PRODUCTIVE":
                i += 1
            length = i - start
            runs.append((length, start, records[start]["cyc"], cat))
        else:
            i += 1
    runs.sort(reverse=True)

    if runs:
        out.append(f"**Top {min(top_runs, len(runs))} longest non-productive runs:**")
        out.append("")
        out.append("| Rank | Length | Start cycle | First category |")
        out.append("|---:|---:|---:|---|")
        for r, (length, _, cyc, cat) in enumerate(runs[:top_runs], 1):
            out.append(f"| {r} | {length} | {cyc} | {cat} |")
        out.append("")

    # Pipeline-state hints for FRONTEND_BUBBLE cycles
    fe_bubble_cycles = [
        i for i, c in enumerate(cat_per_cycle) if c == "FRONTEND_BUBBLE"
    ]
    if fe_bubble_cycles:
        # In FRONTEND_BUBBLE cycles, what was the IQ/ROB state?
        rob_cnt_avg = sum(records[i]["rob_cnt"] for i in fe_bubble_cycles) / len(fe_bubble_cycles)
        iq_avg = sum(records[i]["iq0"] + records[i]["iq1"] + records[i]["iq2"]
                     for i in fe_bubble_cycles) / len(fe_bubble_cycles)
        out.append(f"**FRONTEND_BUBBLE diagnosis:** {len(fe_bubble_cycles):,} cycles, "
                   f"avg rob_cnt={rob_cnt_avg:.1f}, avg IQ total={iq_avg:.1f}. "
                   f"High rob_cnt + low IQ = backend can't drain dependency chain. "
                   f"Low rob_cnt + low IQ = frontend supply is the cap.")
        out.append("")

    return "\n".join(out)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("trace", type=Path, help="dsim.log or trace file with [PIPE schema=pipe.v1] lines")
    ap.add_argument("--top-runs", type=int, default=10, help="show top N longest non-productive runs")
    args = ap.parse_args(argv)

    if not args.trace.exists():
        print(f"error: {args.trace} does not exist", file=sys.stderr)
        return 2

    records = parse_trace(args.trace)
    print(render(records, args.top_runs))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

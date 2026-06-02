#!/usr/bin/env python3
"""Parse [LINUX_STATUS] + [PERF_PROFILE] logs and rank the paged-mode IPC bottleneck.

Reads a DSim boot log (or stdin), pairs LINUX_STATUS (IPC, satp) with PERF_PROFILE
(event counters) by cyc, computes per-interval deltas, and ranks which event family
accounts for the most lost cycles while paging is on (satp != 0)."""
from __future__ import annotations
import argparse, json, re, sys
from pathlib import Path

PERF_FIELDS = [
    "itlb_lookups","itlb_misses","ptw_walks_itlb","ptw_walks_dtlb","ptw_busy_cycles",
    "ptw_faults","fe_stall_total","fe_stall_xlate","fe_stall_icache","fe_stall_backend",
    "flush_commit","flush_bru","flush_satp","dtlb_lookups","dtlb_misses",
    "dcache_accesses","dcache_misses",
]
# Ranked lost-cycle proxies. ptw_busy_cycles is intentionally excluded: PTW busy
# cycles are the mechanism behind fe_stall_xlate (front-end stalled on translation),
# so counting both double-counts the same lost cycles. fe_stall_xlate is the headline.
STALL_FAMILIES = ["fe_stall_xlate","fe_stall_icache","fe_stall_backend","dcache_misses"]

def _kv(line: str) -> dict:
    # Real LINUX_STATUS lines carry register-dump fields (e.g. work_line=000000020003c0)
    # of arbitrary width. Hex-decode any value that is 16 chars wide or contains a hex
    # letter; otherwise treat as decimal. Counter/cyc fields stay decimal; satp etc. hex.
    out = {}
    for k, v in re.findall(r"(\w+)=([0-9a-fA-F]+)", line):
        out[k] = int(v, 16) if (len(v) == 16 or re.search(r"[a-fA-F]", v)) else int(v)
    return out

def parse(text: str):
    status, perf = {}, {}
    for line in text.splitlines():
        if "[LINUX_STATUS]" in line:
            d = _kv(line); status[d["cyc"]] = d
        elif "[PERF_PROFILE]" in line:
            d = _kv(line); perf[d["cyc"]] = d
    return status, perf

def analyze(text: str) -> dict:
    status, perf = parse(text)
    cycs = sorted(c for c in perf if c in status)
    intervals = []
    for prev, cur in zip(cycs, cycs[1:]):
        s_cur, p_prev, p_cur = status[cur], perf[prev], perf[cur]
        dm = s_cur["mcycle"] - status[prev]["mcycle"]
        di = s_cur["minstret"] - status[prev]["minstret"]
        mmu_on = s_cur.get("satp", 0) != 0
        prev_mmu_on = status[prev].get("satp", 0) != 0
        # When paging has just turned on (prev sample was unpaged), the paged-region
        # counter accumulation starts at the transition: use the raw current counters
        # as the delta rather than subtracting the stale pre-paging (M-mode) baseline.
        base = p_prev if (not mmu_on or prev_mmu_on) else {}
        deltas = {f: p_cur.get(f, 0) - base.get(f, 0) for f in PERF_FIELDS}
        intervals.append({"cyc": cur, "mmu_on": mmu_on,
                          "ipc": (di / dm) if dm else 0.0, "deltas": deltas})
    agg = {f: 0 for f in STALL_FAMILIES}
    for w in intervals:
        if w["mmu_on"]:
            for f in STALL_FAMILIES:
                agg[f] += w["deltas"].get(f, 0)
    attribution = sorted(({"family": f, "delta": d} for f, d in agg.items()),
                         key=lambda x: x["delta"], reverse=True)
    last = status[cycs[-1]] if cycs else {"mcycle": 1, "minstret": 0}
    def inv_lookups():
        return all(perf[c]["itlb_misses"] <= perf[c]["itlb_lookups"] for c in cycs)
    def inv_split():
        return all(perf[c]["fe_stall_xlate"] + perf[c]["fe_stall_icache"]
                   + perf[c]["fe_stall_backend"] == perf[c]["fe_stall_total"] for c in cycs)
    return {
        "overall_ipc": (last["minstret"] / last["mcycle"]) if last["mcycle"] else 0.0,
        "intervals": intervals,
        "paged_attribution": attribution,
        "sanity": {"itlb_misses_le_lookups": inv_lookups(),
                   "fe_stall_split_sums": inv_split()},
    }

def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("log", nargs="?", help="boot log path (or --stdin)")
    ap.add_argument("--stdin", action="store_true")
    ap.add_argument("--json", action="store_true", help="emit JSON")
    a = ap.parse_args(argv)
    text = sys.stdin.read() if a.stdin else Path(a.log).read_text()
    r = analyze(text)
    if a.json:
        print(json.dumps(r)); return 0
    print(f"overall IPC = {r['overall_ipc']:.3f}")
    paged = [w for w in r["intervals"] if w["mmu_on"]]
    if paged:
        print(f"paged intervals: {len(paged)}  mean IPC = "
              f"{sum(w['ipc'] for w in paged)/len(paged):.3f}")
    print("paged-mode stall attribution (lost-cycle proxy, desc):")
    for row in r["paged_attribution"]:
        print(f"  {row['family']:18s} {row['delta']:,}")
    print(f"sanity: {r['sanity']}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())

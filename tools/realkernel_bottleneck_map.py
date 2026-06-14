#!/usr/bin/env python3
"""Real-kernel (paged Linux boot) bottleneck map.

Parses the [LINUX_STATUS] + [PERF_PROFILE] interval dump from a Verilator Linux
boot (scripts/run_verilator_linux.sh ... +STATUS +PERF_PROFILE) and produces the
system-level bottleneck taxonomy that bare-metal benchmarks cannot show:

  - per-phase IPC (M-mode/OpenSBI vs paged S-mode kernel), boot taxonomy
  - TRANSLATION: itlb/dtlb miss rate, ptw walk count + ptw_busy_cycles (the
    flush-clear-fixed counter), fe_stall_xlate (post-VIPT, should be ~0)
  - MEMORY: L1D miss rate, L2 per-source arbitration (DCache>PTW>ICache),
    ICache-starve cycles (idea-7 L2-QoS), ICache MSHR-full cycles (idea-8)
  - FETCH: fe_stall split, ICache-supply stalls under the kernel footprint

Pure read-only over the boot log. No RTL dependency.
"""
from __future__ import annotations
import re, sys
from pathlib import Path

FIELDS = [
    "itlb_lookups","itlb_misses","ptw_walks_itlb","ptw_walks_dtlb","ptw_busy_cycles",
    "ptw_faults","fe_stall_total","fe_stall_xlate","fe_stall_icache","fe_stall_backend",
    "flush_commit","flush_bru","flush_satp","dtlb_lookups","dtlb_misses",
    "dcache_accesses","dcache_misses",
    "l2_grant_dcache","l2_grant_ptw","l2_grant_icache","l2_icache_req_cyc",
    "l2_icache_starve","l2_icache_starve_by_ptw","l2_icache_starve_by_dcache",
    "l2_dc_ptw_collide","ic_mshr_full_cyc",
]

def _ints(line, keys):
    out = {}
    for k in keys:
        m = re.search(rf"\b{k}=([0-9a-fA-F]+)", line)
        if m:
            v = m.group(1)
            out[k] = int(v, 16) if (len(v) == 16 or re.search(r"[a-fA-F]", v)) else int(v)
    return out

def parse(text):
    status, perf = {}, {}
    for line in text.splitlines():
        if "[LINUX_STATUS]" in line:
            d = _ints(line, ["cyc","mcycle","minstret","priv","satp"])
            if "cyc" in d: status[d["cyc"]] = d
        elif "[PERF_PROFILE]" in line:
            d = _ints(line, ["cyc"]+FIELDS)
            if "cyc" in d: perf[d["cyc"]] = d
    return status, perf

def pct(n, d):
    return (100.0*n/d) if d else 0.0

def main(argv):
    text = Path(argv[1]).read_text()
    status, perf = parse(text)
    cycs = sorted(c for c in perf if c in status)
    if len(cycs) < 2:
        print("not enough paired samples"); return 1

    # phase split: paged = satp != 0 at the sample
    def paged(c): return status[c].get("satp", 0) != 0

    first_paged = next((c for c in cycs if paged(c)), None)
    last = cycs[-1]
    print(f"=== samples: {len(cycs)}  cyc range {cycs[0]:,}..{last:,} ===")
    print(f"overall IPC (cumulative) = {status[last]['minstret']/status[last]['mcycle']:.3f}")
    if first_paged:
        print(f"paging turns on at cyc ~{first_paged:,} (satp={status[first_paged]['satp']:#x})")

    # per-interval IPC + phase label
    print("\n=== per-phase IPC (interval) ===")
    print(f"{'cyc':>11} {'phase':<6} {'priv':>4} {'ipc':>6} {'fe_xlate%':>9} {'fe_ic%':>7} {'fe_be%':>7}")
    for a, b in zip(cycs, cycs[1:]):
        dm = status[b]["mcycle"] - status[a]["mcycle"]
        di = status[b]["minstret"] - status[a]["minstret"]
        ipc = di/dm if dm else 0.0
        ph = "PAGED" if paged(b) else "M/SBI"
        dxl = perf[b]["fe_stall_xlate"] - perf[a]["fe_stall_xlate"]
        dic = perf[b]["fe_stall_icache"] - perf[a]["fe_stall_icache"]
        dbe = perf[b]["fe_stall_backend"] - perf[a]["fe_stall_backend"]
        print(f"{b:>11,} {ph:<6} {status[b].get('priv',0):>4} {ipc:>6.3f} "
              f"{pct(dxl,dm):>9.2f} {pct(dic,dm):>7.2f} {pct(dbe,dm):>7.2f}")

    # paged-region aggregate deltas (first_paged -> last)
    if not first_paged:
        print("\n(no paged region reached)"); return 0
    p0, p1 = perf[first_paged], perf[last]
    s0, s1 = status[first_paged], status[last]
    dcyc = s1["mcycle"] - s0["mcycle"]
    dins = s1["minstret"] - s0["minstret"]
    d = {f: p1.get(f, 0)-p0.get(f, 0) for f in FIELDS}
    have_qos = "l2_grant_dcache" in p1

    print(f"\n=== PAGED-REGION aggregate (cyc {first_paged:,}..{last:,}, {dcyc:,} cyc) ===")
    print(f"paged IPC = {dins/dcyc:.3f}   ({dins:,} instret / {dcyc:,} cyc)")

    print("\n-- TRANSLATION (idea-3: TLB/PTW hierarchy) --")
    print(f"  itlb_lookups        {d['itlb_lookups']:>14,}")
    print(f"  itlb_misses         {d['itlb_misses']:>14,}  ({pct(d['itlb_misses'],d['itlb_lookups']):.3f}% of lookups)")
    print(f"  dtlb_lookups        {d['dtlb_lookups']:>14,}")
    print(f"  dtlb_misses         {d['dtlb_misses']:>14,}  ({pct(d['dtlb_misses'],d['dtlb_lookups']):.3f}% of lookups)")
    print(f"  ptw_walks_itlb      {d['ptw_walks_itlb']:>14,}")
    print(f"  ptw_walks_dtlb      {d['ptw_walks_dtlb']:>14,}")
    walks = d['ptw_walks_itlb']+d['ptw_walks_dtlb']
    print(f"  ptw_walks (total)   {walks:>14,}")
    print(f"  ptw_busy_cycles     {d['ptw_busy_cycles']:>14,}  ({pct(d['ptw_busy_cycles'],dcyc):.2f}% of paged cyc)")
    if walks: print(f"  -> cyc/walk         {d['ptw_busy_cycles']/walks:>14.1f}  (Sv48 = up to 4 serial L2 round-trips, no PWC)")
    print(f"  ptw_faults          {d['ptw_faults']:>14,}")
    print(f"  fe_stall_xlate      {d['fe_stall_xlate']:>14,}  ({pct(d['fe_stall_xlate'],dcyc):.3f}% of paged cyc)  [post-VIPT: expect ~0]")

    print("\n-- FETCH / I-SIDE (idea-8: ICache MSHR / NLPB) --")
    fet = d['fe_stall_total']
    print(f"  fe_stall_total      {d['fe_stall_total']:>14,}  ({pct(d['fe_stall_total'],dcyc):.2f}% of paged cyc)")
    print(f"   - backend          {d['fe_stall_backend']:>14,}  ({pct(d['fe_stall_backend'],fet):.1f}% of fe_stall)")
    print(f"   - xlate            {d['fe_stall_xlate']:>14,}  ({pct(d['fe_stall_xlate'],fet):.1f}% of fe_stall)")
    print(f"   - icache supply    {d['fe_stall_icache']:>14,}  ({pct(d['fe_stall_icache'],fet):.1f}% of fe_stall)")
    print(f"  ic_mshr_full_cyc    {d['ic_mshr_full_cyc']:>14,}  ({pct(d['ic_mshr_full_cyc'],dcyc):.3f}% of paged cyc)  [IC_MSHR_DEPTH=2]")

    print("\n-- MEMORY / L2 QoS (idea-7: L2 source arbitration) --")
    print(f"  dcache_accesses     {d['dcache_accesses']:>14,}")
    print(f"  dcache_misses       {d['dcache_misses']:>14,}  ({pct(d['dcache_misses'],d['dcache_accesses']):.3f}% of accesses)")
    if not have_qos:
        print("  (L2-QoS / ICache-MSHR counters not present in this log — use the QoS binary log)")
        print("\n-- FLUSHES --")
        print(f"  flush_commit        {d['flush_commit']:>14,}")
        print(f"  flush_bru           {d['flush_bru']:>14,}")
        print(f"  flush_satp          {d['flush_satp']:>14,}")
        return 0
    gtot = d['l2_grant_dcache']+d['l2_grant_ptw']+d['l2_grant_icache']
    print(f"  L2 grants total     {gtot:>14,}")
    print(f"   - DCache (prio 1)  {d['l2_grant_dcache']:>14,}  ({pct(d['l2_grant_dcache'],gtot):.1f}%)")
    print(f"   - PTW    (prio 2)  {d['l2_grant_ptw']:>14,}  ({pct(d['l2_grant_ptw'],gtot):.1f}%)")
    print(f"   - ICache (prio 3)  {d['l2_grant_icache']:>14,}  ({pct(d['l2_grant_icache'],gtot):.1f}%)")
    print(f"  l2_icache_req_cyc   {d['l2_icache_req_cyc']:>14,}  (cyc ICache wanted L2)")
    print(f"  l2_icache_starve    {d['l2_icache_starve']:>14,}  ({pct(d['l2_icache_starve'],d['l2_icache_req_cyc']):.2f}% of ICache-L2-req cyc; {pct(d['l2_icache_starve'],dcyc):.3f}% of paged cyc)")
    print(f"   - lost to DCache   {d['l2_icache_starve_by_dcache']:>14,}")
    print(f"   - lost to PTW      {d['l2_icache_starve_by_ptw']:>14,}")
    print(f"  l2_dc_ptw_collide   {d['l2_dc_ptw_collide']:>14,}  (cyc DCache AND PTW both want L2)")

    print("\n-- FLUSHES --")
    print(f"  flush_commit        {d['flush_commit']:>14,}")
    print(f"  flush_bru           {d['flush_bru']:>14,}")
    print(f"  flush_satp          {d['flush_satp']:>14,}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

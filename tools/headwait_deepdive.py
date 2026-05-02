#!/usr/bin/env python3
"""
HEAD_WAIT_BACKLOG deep-dive analyzer.

Beyond the bubble taxonomy: applies Little's law to decompose average
in-flight time per pipeline stage, computes head-occupant patterns,
and identifies WHICH stage adds the most cycles to per-uop completion.
"""

import re
import sys
from collections import defaultdict, Counter

PIPE_RE = re.compile(
    r'^\[PIPE schema=pipe\.v1\] '
    r'cyc=(\d+) rst=(\d+) '
    r'fetch=(\d+) decode=(\d+) rename=(\d+) dispatch=(\d+) '
    r'issue0=(\d+) issue1=(\d+) issue2=(\d+) cdb=(\d+) commit=(\d+) '
    r'rob_head=(\d+) rob_tail=(\d+) rob_cnt=(\d+) '
    r'iq0=(\d+) iq1=(\d+) iq2=(\d+) lq=(\d+) sq=(\d+) free=(\d+) ckpt=(\d+) '
    r'flush=(\d+) replay=(\d+) reason=(\d+)'
)

def analyze(path, label):
    sums = defaultdict(int)
    cnt = 0
    instret = 0
    rob_hist = Counter()  # bin -> count
    rob_sum_in_headwait = 0
    headwait_cnt = 0

    # Track rob_head movement (proxy for commit progress)
    prev_rob_head = None
    head_hold_cyc = Counter()  # head value -> consecutive cycles held
    cur_head_hold = 0
    prev_head_value = None

    # iq_int_avg = (iq0+iq1+iq2) / total cycles
    # iq_lsu_avg = (lq+sq) / total cycles
    # rob_avg = rob_cnt / total cycles

    with open(path) as f:
        for line in f:
            m = PIPE_RE.match(line)
            if not m:
                continue
            g = m.groups()
            rec = {
                'cyc':       int(g[0]),
                'rst':       int(g[1]),
                'rename':    int(g[4]),
                'dispatch':  int(g[5]),
                'issue0':    int(g[6]),
                'issue1':    int(g[7]),
                'issue2':    int(g[8]),
                'cdb':       int(g[9]),
                'commit':    int(g[10]),
                'rob_head':  int(g[11]),
                'rob_cnt':   int(g[13]),
                'iq0':       int(g[14]),
                'iq1':       int(g[15]),
                'iq2':       int(g[16]),
                'lq':        int(g[17]),
                'sq':        int(g[18]),
                'flush':     int(g[21]),
            }
            if rec['rst'] == 1:
                continue
            cnt += 1
            instret += rec['commit']
            sums['rob_cnt'] += rec['rob_cnt']
            sums['iq0'] += rec['iq0']
            sums['iq1'] += rec['iq1']
            sums['iq2'] += rec['iq2']
            sums['lq'] += rec['lq']
            sums['sq'] += rec['sq']
            sums['rename'] += rec['rename']
            sums['dispatch'] += rec['dispatch']
            sums['issue_int_total'] += rec['issue0'] + rec['issue1'] + rec['issue2']
            sums['cdb'] += rec['cdb']

            # rob_cnt histogram (in coarse bins)
            rb = rec['rob_cnt']
            if rb == 0:    bin_label = '0'
            elif rb <= 3:  bin_label = '1-3'
            elif rb <= 7:  bin_label = '4-7'
            elif rb <= 15: bin_label = '8-15'
            elif rb <= 31: bin_label = '16-31'
            elif rb <= 63: bin_label = '32-63'
            else:          bin_label = '64+'
            rob_hist[bin_label] += 1

            # Head-wait specific tracking (commit < 4 AND rob_cnt >= 4)
            if rec['commit'] < 4 and rec['rob_cnt'] >= 4 and rec['flush'] == 0:
                headwait_cnt += 1
                rob_sum_in_headwait += rec['rob_cnt']

            # Track head dwell-time: how long does each rob_head value persist?
            head_v = rec['rob_head']
            if head_v == prev_head_value:
                cur_head_hold += 1
            else:
                if prev_head_value is not None and cur_head_hold > 0:
                    head_hold_cyc[cur_head_hold] += 1
                prev_head_value = head_v
                cur_head_hold = 1

    # finalize last hold
    if prev_head_value is not None and cur_head_hold > 0:
        head_hold_cyc[cur_head_hold] += 1

    if cnt == 0:
        return None

    ipc = instret / cnt
    avg_rob = sums['rob_cnt'] / cnt
    avg_iq_int = (sums['iq0'] + sums['iq1'] + sums['iq2']) / cnt
    avg_iq0 = sums['iq0'] / cnt
    avg_iq1 = sums['iq1'] / cnt
    avg_iq2 = sums['iq2'] / cnt
    avg_lq = sums['lq'] / cnt
    avg_sq = sums['sq'] / cnt
    avg_iq_lsu = (sums['lq'] + sums['sq']) / cnt
    avg_rename = sums['rename'] / cnt
    avg_dispatch = sums['dispatch'] / cnt
    avg_issue_int = sums['issue_int_total'] / cnt
    avg_cdb = sums['cdb'] / cnt
    avg_commit = sums['commit'] / cnt

    # Little's law: avg_time_in_X = avg_occupancy_X / throughput_X (uops/cycle)
    # Throughput at each stage = commit rate (in steady state, all stages match)
    avg_time_in_rob   = avg_rob   / ipc if ipc else 0
    avg_time_in_iq_int = avg_iq_int / ipc if ipc else 0  # rough — combines all INT IQs
    avg_time_in_lq    = avg_lq    / ipc if ipc else 0
    avg_time_in_sq    = avg_sq    / ipc if ipc else 0

    # Head-dwell time histogram
    # Most heads should commit in 1 cycle. Heads that dwell > 1 cycle are stalls.
    total_head_changes = sum(head_hold_cyc.values())
    head_dwell_dist = {
        '1':    head_hold_cyc.get(1, 0),
        '2':    head_hold_cyc.get(2, 0),
        '3':    head_hold_cyc.get(3, 0),
        '4-5':  sum(head_hold_cyc.get(x, 0) for x in [4, 5]),
        '6-10': sum(head_hold_cyc.get(x, 0) for x in range(6, 11)),
        '11-20': sum(head_hold_cyc.get(x, 0) for x in range(11, 21)),
        '21-50': sum(head_hold_cyc.get(x, 0) for x in range(21, 51)),
        '51+':  sum(head_hold_cyc.get(x, 0) for x in head_hold_cyc if x >= 51),
    }
    avg_head_dwell = sum(k*v for k, v in head_hold_cyc.items()) / total_head_changes if total_head_changes else 0
    max_head_dwell = max(head_hold_cyc.keys()) if head_hold_cyc else 0

    print(f"=== {label} ===")
    print(f"Total cycles: {cnt:,}")
    print(f"Total instret: {instret:,}")
    print(f"IPC: {ipc:.4f}")
    print()
    print("--- AVERAGE OCCUPANCIES (per cycle) ---")
    print(f"  rob_cnt:        {avg_rob:7.2f}  (capacity 128)")
    print(f"  iq0 (ALU0+1+BRU):  {avg_iq0:7.2f}  (capacity 24)")
    print(f"  iq1 (ALU2+MUL):    {avg_iq1:7.2f}  (capacity 24)")
    print(f"  iq2 (ALU3+DIV+CSR):{avg_iq2:7.2f}  (capacity 24)")
    print(f"  iq_int_total:   {avg_iq_int:7.2f}  (capacity 72)")
    print(f"  lq:             {avg_lq:7.2f}  (capacity 32)")
    print(f"  sq:             {avg_sq:7.2f}  (capacity 32)")
    print(f"  iq_lsu_total:   {avg_iq_lsu:7.2f}  (capacity 64)")
    print()
    print("--- AVERAGE PER-CYCLE FLOW (uops/cycle, expect ≈ IPC in steady state) ---")
    print(f"  rename:    {avg_rename:6.3f}   dispatch: {avg_dispatch:6.3f}")
    print(f"  issue_int: {avg_issue_int:6.3f}   cdb:      {avg_cdb:6.3f}   commit: {avg_commit:6.3f}")
    print()
    print("--- LITTLE'S LAW DECOMPOSITION (avg time per uop in stage = occupancy / throughput) ---")
    print(f"  avg time in ROB (rename → commit): {avg_time_in_rob:6.2f} cycles")
    print(f"  avg time in IQ_INT (dispatch → issue):  {avg_time_in_iq_int:6.2f} cycles")
    print(f"  avg time in LQ:    {avg_time_in_lq:6.2f} cycles")
    print(f"  avg time in SQ:    {avg_time_in_sq:6.2f} cycles")
    print()
    # Implied: time from issue to commit = total_in_rob - time_in_iq
    # But not all uops go through INT IQ; loads/stores go through LQ/SQ via separate IQs.
    # Rough approximation:
    rough_post_iq = avg_time_in_rob - avg_time_in_iq_int
    print(f"  (rough) avg time after-IQ → commit:  {rough_post_iq:6.2f} cycles")
    print(f"          [= execute + writeback + commit-wait for INT uops; ")
    print(f"           for loads/stores: includes their entire LSU pipeline]")
    print()
    print("--- ROB OCCUPANCY HISTOGRAM ---")
    for bin_label in ['0', '1-3', '4-7', '8-15', '16-31', '32-63', '64+']:
        c = rob_hist.get(bin_label, 0)
        pct = 100.0 * c / cnt if cnt else 0
        print(f"  rob_cnt {bin_label:>5}: {c:>10,}  ({pct:5.1f}%)")
    print()
    print(f"--- HEAD DWELL-TIME (consecutive cycles each rob_head value persists) ---")
    print(f"  Average head dwell:  {avg_head_dwell:.2f} cycles")
    print(f"  Max head dwell:      {max_head_dwell} cycles")
    print(f"  Total head changes:  {total_head_changes:,}")
    print(f"  Distribution:")
    for bin_label in ['1', '2', '3', '4-5', '6-10', '11-20', '21-50', '51+']:
        c = head_dwell_dist[bin_label]
        pct = 100.0 * c / total_head_changes if total_head_changes else 0
        # Also show fraction of TOTAL CYCLES this dwell consumes
        if bin_label == '1':         cyc_consumed = c * 1
        elif bin_label == '2':       cyc_consumed = c * 2
        elif bin_label == '3':       cyc_consumed = c * 3
        elif bin_label == '4-5':     cyc_consumed = sum(head_hold_cyc.get(x, 0)*x for x in [4,5])
        elif bin_label == '6-10':    cyc_consumed = sum(head_hold_cyc.get(x, 0)*x for x in range(6,11))
        elif bin_label == '11-20':   cyc_consumed = sum(head_hold_cyc.get(x, 0)*x for x in range(11,21))
        elif bin_label == '21-50':   cyc_consumed = sum(head_hold_cyc.get(x, 0)*x for x in range(21,51))
        else:                        cyc_consumed = sum(head_hold_cyc.get(x, 0)*x for x in head_hold_cyc if x>=51)
        cyc_pct = 100.0 * cyc_consumed / cnt if cnt else 0
        print(f"    dwell {bin_label:>5}: {c:>10,} heads  ({pct:5.1f}% of heads, consumes {cyc_pct:5.1f}% of cycles)")
    print()
    print(f"--- HEAD_WAIT_BACKLOG-SPECIFIC ROB OCCUPANCY ---")
    if headwait_cnt > 0:
        avg_rob_in_headwait = rob_sum_in_headwait / headwait_cnt
        print(f"  Cycles in HEAD_WAIT_BACKLOG: {headwait_cnt:,} ({100*headwait_cnt/cnt:.1f}%)")
        print(f"  Avg rob_cnt during head-wait: {avg_rob_in_headwait:.2f}")
    print()
    print()


if __name__ == '__main__':
    paths = [
        ('/tmp/dhry_pipe.trace', 'dhrystone'),
        ('/tmp/cm_pipe.trace',   'coremark iter1'),
    ]
    for p, l in paths:
        analyze(p, l)

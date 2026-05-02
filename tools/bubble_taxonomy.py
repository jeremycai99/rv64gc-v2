#!/usr/bin/env python3
"""
Bubble Taxonomy Analyzer for rv64gc-v2 4-wide pipeline.

Reads pipe.v1 trace lines and classifies each cycle into mutually-exclusive
bubble categories using the most-upstream-binding-constraint attribution rule.

Per-cycle categories (decision tree, first match wins):
  1. FLUSH                    — pipeline drain (flush asserted)
  2. PEAK                     — commit == PIPE_WIDTH (4)
  3. HEAD_WAIT_BACKLOG        — commit < 4 AND rob_cnt >= 4 (head not ready)
  4. DISPATCH_BLOCKED         — commit < 4 AND rob_cnt < 4 AND rename >= dispatch+1 (backpressure)
  5. FRONTEND_LIMITED         — commit < 4 AND rob_cnt < 4 AND rename < 4 (frontend not delivering)
  6. OTHER                    — residual (should be small)

Also tracks sub-stratification by commit count within each category, and the
issue-stall (operand-not-ready) signal where applicable.
"""

import re
import sys
from collections import defaultdict

PIPE_WIDTH = 4

PIPE_RE = re.compile(
    r'^\[PIPE schema=pipe\.v1\] '
    r'cyc=(\d+) rst=(\d+) '
    r'fetch=(\d+) decode=(\d+) rename=(\d+) dispatch=(\d+) '
    r'issue0=(\d+) issue1=(\d+) issue2=(\d+) cdb=(\d+) commit=(\d+) '
    r'rob_head=(\d+) rob_tail=(\d+) rob_cnt=(\d+) '
    r'iq0=(\d+) iq1=(\d+) iq2=(\d+) lq=(\d+) sq=(\d+) free=(\d+) ckpt=(\d+) '
    r'flush=(\d+) replay=(\d+) reason=(\d+)'
)

def classify(rec):
    """Classify one pipeline-trace record into a bubble category."""
    if rec['flush'] == 1:
        return 'FLUSH'
    if rec['commit'] == PIPE_WIDTH:
        return 'PEAK'
    # commit < 4 from here on
    if rec['rob_cnt'] >= PIPE_WIDTH:
        return 'HEAD_WAIT_BACKLOG'
    # commit < 4 AND rob_cnt < 4
    if rec['rename'] >= PIPE_WIDTH and rec['dispatch'] < rec['rename']:
        return 'DISPATCH_BLOCKED'
    if rec['rename'] < PIPE_WIDTH:
        return 'FRONTEND_LIMITED'
    return 'OTHER'

def parse_line(line):
    m = PIPE_RE.match(line)
    if not m:
        return None
    g = m.groups()
    return {
        'cyc':        int(g[0]),
        'rst':        int(g[1]),
        'fetch':      int(g[2]),
        'decode':     int(g[3]),
        'rename':     int(g[4]),
        'dispatch':   int(g[5]),
        'issue0':     int(g[6]),
        'issue1':     int(g[7]),
        'issue2':     int(g[8]),
        'cdb':        int(g[9]),
        'commit':     int(g[10]),
        'rob_head':   int(g[11]),
        'rob_tail':   int(g[12]),
        'rob_cnt':    int(g[13]),
        'iq0':        int(g[14]),
        'iq1':        int(g[15]),
        'iq2':        int(g[16]),
        'lq':         int(g[17]),
        'sq':         int(g[18]),
        'free':       int(g[19]),
        'ckpt':       int(g[20]),
        'flush':      int(g[21]),
        'replay':     int(g[22]),
        'reason':     int(g[23]),
    }

def analyze(path, label):
    cat_count = defaultdict(int)
    cat_commit_dist = defaultdict(lambda: defaultdict(int))  # category -> commit_count -> N
    headwait_subdist = defaultdict(int)  # commit_count distribution within HEAD_WAIT_BACKLOG
    frontend_subdist = defaultdict(int)  # commit_count distribution within FRONTEND_LIMITED

    # Within FRONTEND_LIMITED, track WHY rename < 4
    frontend_rename_dist = defaultdict(int)

    # Within HEAD_WAIT_BACKLOG, track issue activity
    headwait_with_issue = 0   # head_wait cycles where some issue happened
    headwait_no_issue = 0     # head_wait cycles where issue == 0

    # Within HEAD_WAIT_BACKLOG, track ROB occupancy bins
    headwait_rob_bins = defaultdict(int)

    # Issue total stats (where applicable)
    total_issued = 0
    total_committed = 0

    total_cyc = 0
    total_instret = 0  # commit sum

    with open(path) as f:
        for line in f:
            rec = parse_line(line)
            if rec is None:
                continue
            if rec['rst'] == 1:
                continue
            total_cyc += 1
            total_instret += rec['commit']

            cat = classify(rec)
            cat_count[cat] += 1
            cat_commit_dist[cat][rec['commit']] += 1

            issue_total = rec['issue0'] + rec['issue1'] + rec['issue2']
            total_issued += issue_total
            total_committed += rec['commit']

            if cat == 'HEAD_WAIT_BACKLOG':
                headwait_subdist[rec['commit']] += 1
                if issue_total > 0:
                    headwait_with_issue += 1
                else:
                    headwait_no_issue += 1
                # Bin the rob_cnt
                rb = rec['rob_cnt']
                if rb < 8:
                    bin_label = '4-7'
                elif rb < 16:
                    bin_label = '8-15'
                elif rb < 32:
                    bin_label = '16-31'
                elif rb < 64:
                    bin_label = '32-63'
                else:
                    bin_label = '64+'
                headwait_rob_bins[bin_label] += 1

            if cat == 'FRONTEND_LIMITED':
                frontend_subdist[rec['commit']] += 1
                frontend_rename_dist[rec['rename']] += 1

    return {
        'label': label,
        'total_cyc': total_cyc,
        'total_instret': total_instret,
        'ipc': total_instret / total_cyc if total_cyc else 0,
        'cat_count': dict(cat_count),
        'cat_commit_dist': {k: dict(v) for k, v in cat_commit_dist.items()},
        'headwait_subdist': dict(headwait_subdist),
        'frontend_subdist': dict(frontend_subdist),
        'frontend_rename_dist': dict(frontend_rename_dist),
        'headwait_with_issue': headwait_with_issue,
        'headwait_no_issue': headwait_no_issue,
        'headwait_rob_bins': dict(headwait_rob_bins),
        'total_issued': total_issued,
        'total_committed': total_committed,
    }

def fmt_pct(n, total):
    return f"{n} ({100.0*n/total:.1f}%)" if total else "0 (0.0%)"

def report(r):
    print(f"=== {r['label']} ===")
    print(f"Total cycles: {r['total_cyc']:,}")
    print(f"Total instret: {r['total_instret']:,}  IPC: {r['ipc']:.4f}")
    print()
    cats_in_order = ['PEAK', 'HEAD_WAIT_BACKLOG', 'FRONTEND_LIMITED',
                     'DISPATCH_BLOCKED', 'FLUSH', 'OTHER']
    print(f"{'Category':<24} {'Cycles':>12} {'% of total':>12}")
    print('-' * 50)
    for cat in cats_in_order:
        cnt = r['cat_count'].get(cat, 0)
        pct = 100.0 * cnt / r['total_cyc'] if r['total_cyc'] else 0
        print(f"{cat:<24} {cnt:>12,} {pct:>11.2f}%")
    total = sum(r['cat_count'].values())
    print(f"{'TOTAL':<24} {total:>12,} {100.0*total/r['total_cyc']:>11.2f}%")
    print()

    # Commit-count distribution within each category
    print("Commit-count distribution within each category:")
    print(f"{'Category':<24} {'commit=0':>10} {'=1':>8} {'=2':>8} {'=3':>8} {'=4':>8}")
    for cat in cats_in_order:
        dist = r['cat_commit_dist'].get(cat, {})
        cells = [dist.get(i, 0) for i in range(5)]
        cell_strs = [f"{c:>10,}" if i == 0 else f"{c:>8,}" for i, c in enumerate(cells)]
        print(f"{cat:<24} {' '.join(cell_strs)}")
    print()

    # HEAD_WAIT_BACKLOG sub-detail
    hw = r['cat_count'].get('HEAD_WAIT_BACKLOG', 0)
    if hw > 0:
        print(f"HEAD_WAIT_BACKLOG sub-detail (of {hw:,} cycles):")
        print(f"  with issue activity: {fmt_pct(r['headwait_with_issue'], hw)} (working past head)")
        print(f"  no issue activity:   {fmt_pct(r['headwait_no_issue'], hw)} (truly stalled)")
        print(f"  ROB occupancy bins:")
        for bin_label in ['4-7', '8-15', '16-31', '32-63', '64+']:
            cnt = r['headwait_rob_bins'].get(bin_label, 0)
            print(f"    rob_cnt {bin_label:>5}: {fmt_pct(cnt, hw)}")
        print()

    # FRONTEND_LIMITED sub-detail
    fl = r['cat_count'].get('FRONTEND_LIMITED', 0)
    if fl > 0:
        print(f"FRONTEND_LIMITED sub-detail (of {fl:,} cycles):")
        print(f"  rename count distribution:")
        for n in range(PIPE_WIDTH):
            cnt = r['frontend_rename_dist'].get(n, 0)
            print(f"    rename={n}: {fmt_pct(cnt, fl)}")
        print()

    # Sanity: how many uops issued vs committed
    print(f"Total uops issued (sum issue0+issue1+issue2): {r['total_issued']:,}")
    print(f"Total uops committed:                          {r['total_committed']:,}")
    print(f"Ratio issued/committed: {r['total_issued']/r['total_committed']:.3f} (expect >=1; >1 means re-issue/replay)")
    print()
    print()

if __name__ == '__main__':
    paths = [
        ('/tmp/dhry_pipe.trace', 'dhrystone (100 iter)'),
        ('/tmp/cm_pipe.trace',   'coremark iter1'),
    ]
    for p, l in paths:
        r = analyze(p, l)
        report(r)

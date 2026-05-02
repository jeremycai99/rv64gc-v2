#!/usr/bin/env python3
"""
Frontend supply probe — addresses user hypothesis #1 (rename bubbles).

For each cycle in the pipe.v1 trace:
  - Classify by rename_count (0..4)
  - Cross-tab with ROB occupancy bins (to discriminate frontend-limited
    vs backend-backpressure)
  - Identify whether LB was active (replay vs fresh fetch)
  - Compute per-rename-count distribution + average

Goal: identify where the missing rename bandwidth goes (PIPE_WIDTH=4
but avg rename ~2/cycle in cm).
"""

import re
from collections import Counter, defaultdict

PIPE_RE = re.compile(
    r'^\[PIPE schema=pipe\.v1\] '
    r'cyc=(\d+) rst=(\d+) '
    r'fetch=(\d+) decode=(\d+) rename=(\d+) dispatch=(\d+) '
    r'issue0=(\d+) issue1=(\d+) issue2=(\d+) cdb=(\d+) commit=(\d+) '
    r'rob_head=(\d+) rob_tail=(\d+) rob_cnt=(\d+) '
    r'iq0=(\d+) iq1=(\d+) iq2=(\d+) lq=(\d+) sq=(\d+) free=(\d+) ckpt=(\d+) '
    r'flush=(\d+) replay=(\d+) reason=(\d+)'
)

PIPE_WIDTH = 4

def analyze(path, label):
    rename_hist = Counter()       # rename_count -> # cycles
    fetch_hist = Counter()        # fetch_count -> # cycles
    rename_x_rob = defaultdict(Counter)  # rename_count -> rob_bin -> # cycles
    rename_x_flush = defaultdict(Counter)  # rename_count -> flush -> #
    fetch_vs_rename = Counter()   # (fetch, rename) -> # cycles

    # Frontend-vs-backend attribution for rename<4 cycles
    # Frontend-limited: fetch < 4 (frontend not supplying)
    # Backend-stalled:  fetch >= 4 but rename < fetch (downstream rejected)
    # ROB-full pressure: rob_cnt > 100 (out of 128)
    # Equilibrium: rob_cnt is moderate AND fetch/rename match
    rename_lt4_attribution = Counter()

    total_cyc = 0
    total_rename = 0
    total_fetch = 0
    total_commit = 0

    with open(path) as f:
        for line in f:
            m = PIPE_RE.match(line)
            if not m:
                continue
            g = m.groups()
            rec = {
                'rst':      int(g[1]),
                'fetch':    int(g[2]),
                'decode':   int(g[3]),
                'rename':   int(g[4]),
                'dispatch': int(g[5]),
                'commit':   int(g[10]),
                'rob_cnt':  int(g[13]),
                'flush':    int(g[21]),
                'replay':   int(g[22]),
            }
            if rec['rst'] == 1:
                continue
            total_cyc += 1
            total_rename += rec['rename']
            total_fetch += rec['fetch']
            total_commit += rec['commit']

            rename_hist[rec['rename']] += 1
            fetch_hist[rec['fetch']] += 1

            # ROB occupancy bin
            rb = rec['rob_cnt']
            if rb == 0: rb_bin = '0'
            elif rb <= 3: rb_bin = '1-3'
            elif rb <= 7: rb_bin = '4-7'
            elif rb <= 15: rb_bin = '8-15'
            elif rb <= 31: rb_bin = '16-31'
            elif rb <= 63: rb_bin = '32-63'
            elif rb <= 100: rb_bin = '64-100'
            else: rb_bin = '101+'

            rename_x_rob[rec['rename']][rb_bin] += 1
            rename_x_flush[rec['rename']]['flush' if rec['flush'] else 'noflush'] += 1
            fetch_vs_rename[(rec['fetch'], rec['rename'])] += 1

            # Attribute rename<4 cycles
            if rec['rename'] < PIPE_WIDTH:
                if rec['flush']:
                    cat = 'flush_in_progress'
                elif rec['rob_cnt'] > 100:
                    cat = 'rob_near_full'
                elif rec['fetch'] < PIPE_WIDTH and rec['rob_cnt'] < 16:
                    cat = 'frontend_limited_no_rob_pressure'
                elif rec['fetch'] < PIPE_WIDTH:
                    cat = 'frontend_limited_with_some_rob'
                elif rec['fetch'] >= PIPE_WIDTH and rec['rename'] < rec['fetch']:
                    cat = 'backend_stalled (fetch ok, rename rejected)'
                else:
                    cat = 'other'
                rename_lt4_attribution[cat] += 1

    print(f"=== {label} ===")
    print(f"Total cycles: {total_cyc:,}")
    print(f"Avg fetch:    {total_fetch/total_cyc:.3f}")
    print(f"Avg rename:   {total_rename/total_cyc:.3f}")
    print(f"Avg commit:   {total_commit/total_cyc:.3f}")
    print()

    print(f"--- Rename count histogram ---")
    print(f"{'rename':>8} {'cycles':>10} {'%':>8}")
    for n in range(PIPE_WIDTH + 1):
        c = rename_hist.get(n, 0)
        pct = 100.0 * c / total_cyc if total_cyc else 0
        print(f"{n:>8} {c:>10,} {pct:>7.2f}%")
    print()

    print(f"--- Fetch count histogram ---")
    print(f"{'fetch':>8} {'cycles':>10} {'%':>8}")
    for n in range(PIPE_WIDTH + 5):
        c = fetch_hist.get(n, 0)
        if c > 0:
            pct = 100.0 * c / total_cyc if total_cyc else 0
            print(f"{n:>8} {c:>10,} {pct:>7.2f}%")
    print()

    print(f"--- Rename x ROB occupancy cross-tab (% of all cycles) ---")
    print(f"{'rename\\rob':>12} {'0':>7} {'1-3':>7} {'4-7':>7} {'8-15':>7} {'16-31':>7} {'32-63':>7} {'64-100':>8} {'101+':>7}")
    for r in range(PIPE_WIDTH + 1):
        row = [f"{r:>12}"]
        for b in ['0', '1-3', '4-7', '8-15', '16-31', '32-63', '64-100', '101+']:
            c = rename_x_rob[r].get(b, 0)
            pct = 100.0 * c / total_cyc if total_cyc else 0
            row.append(f"{pct:>6.2f}%")
        print(' '.join(row))
    print()

    print(f"--- Attribution of rename<4 cycles ---")
    rename_lt4 = sum(rename_lt4_attribution.values())
    rename_lt4_pct = 100.0 * rename_lt4 / total_cyc
    print(f"Total cycles with rename<4: {rename_lt4:,} ({rename_lt4_pct:.2f}% of total)")
    print(f"{'category':<48} {'cycles':>10} {'% of rename<4':>15} {'% of total':>12}")
    for cat, cnt in sorted(rename_lt4_attribution.items(), key=lambda x: -x[1]):
        pct_of_lt4 = 100.0 * cnt / rename_lt4 if rename_lt4 else 0
        pct_of_total = 100.0 * cnt / total_cyc if total_cyc else 0
        print(f"  {cat:<46} {cnt:>10,} {pct_of_lt4:>14.2f}% {pct_of_total:>11.2f}%")
    print()

    print(f"--- Top 10 (fetch, rename) pairs by frequency ---")
    print(f"{'fetch':>6} {'rename':>7} {'cycles':>10} {'% of total':>12}  {'note':<40}")
    for (f, r), c in sorted(fetch_vs_rename.items(), key=lambda x: -x[1])[:10]:
        pct = 100.0 * c / total_cyc if total_cyc else 0
        note = ""
        if f == 0 and r == 0:
            note = "fully empty (flush recovery / I-cache miss)"
        elif f > 0 and r == 0:
            note = "fetch supplied but rename = 0 (rename stall)"
        elif r < f:
            note = "rename < fetch (backpressure or stall)"
        elif r == f and r < PIPE_WIDTH:
            note = "rename matches fetch (frontend-limited)"
        elif r == PIPE_WIDTH:
            note = "PEAK"
        print(f"{f:>6} {r:>7} {c:>10,} {pct:>11.2f}%  {note}")
    print()
    print()


if __name__ == '__main__':
    paths = [
        ('/tmp/dhry_pipe.trace', 'dhrystone'),
        ('/tmp/cm_pipe.trace',   'coremark iter1'),
    ]
    for p, l in paths:
        analyze(p, l)

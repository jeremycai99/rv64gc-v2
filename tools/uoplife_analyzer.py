#!/usr/bin/env python3
"""
uoplife_analyzer.py — surface abnormal per-uop lifecycle behavior.

Consumes one [UOPLIFE seq=N rob=X pc=PC fu=F is_load=B is_store=B is_branch=B
mis=B rename=Tr dispatch=Td issue=Ti wb=Tw commit=Tc d_ren_to_disp=Δ
d_disp_to_iss=Δ d_iss_to_wb=Δ d_wb_to_cmt=Δ d_total=Δ] line per retired
uop, emitted by tb_top.sv when run with +TRACE_UOPLIFE.

Goal: identify the per-uop DISTRIBUTION of time-in-stage so that long-tail
patterns (e.g., 100 uops at 50+ cyc) — which an aggregate average hides —
can drive specific RTL change candidates.

Usage:
  ./tools/uoplife_analyzer.py <trace_file> [--label <name>] [--top-pcs N]
"""

import argparse
import re
import sys
from collections import Counter, defaultdict

UOPLIFE_RE = re.compile(
    r'^\[UOPLIFE '
    r'seq=(\d+) '
    r'rob=(\d+) '
    r'pc=([0-9a-fA-F]+) '
    r'fu=(\d+) '
    r'is_load=(\d+) '
    r'is_store=(\d+) '
    r'is_branch=(\d+) '
    r'mis=(\d+) '
    r'rename=(-?\d+) '
    r'dispatch=(-?\d+) '
    r'issue=(-?\d+) '
    r'wb=(-?\d+) '
    r'commit=(-?\d+) '
    r'd_ren_to_disp=(-?\d+) '
    r'd_disp_to_iss=(-?\d+) '
    r'd_iss_to_wb=(-?\d+) '
    r'd_wb_to_cmt=(-?\d+) '
    r'd_total=(-?\d+)'
    r'\]'
)

# fu_type_e enum from uarch_pkg.sv
FU_NAME = {
    0: 'ALU',
    1: 'BRU',
    2: 'MUL',
    3: 'DIV',
    4: 'LOAD',
    5: 'STA',
    6: 'STD',
    7: 'CSR',
}

# Bucket boundaries — left-edge inclusive
# bucket label, predicate
BUCKETS = [
    ('1',     lambda d: d == 1),
    ('2',     lambda d: d == 2),
    ('3',     lambda d: d == 3),
    ('4-5',   lambda d: 4 <= d <= 5),
    ('6-10',  lambda d: 6 <= d <= 10),
    ('11-20', lambda d: 11 <= d <= 20),
    ('21-50', lambda d: 21 <= d <= 50),
    ('51-100',lambda d: 51 <= d <= 100),
    ('100+',  lambda d: d > 100),
    ('0',     lambda d: d == 0),
]

STAGES = [
    ('rename->dispatch', 'd_ren_to_disp'),
    ('dispatch->issue',  'd_disp_to_iss'),
    ('issue->wb',        'd_iss_to_wb'),
    ('wb->commit',       'd_wb_to_cmt'),
    ('TOTAL_in_ROB',     'd_total'),
]


def bucket_of(d):
    for name, pred in BUCKETS:
        if pred(d):
            return name
    return 'other'


def fmt_pct(n, total):
    if total == 0:
        return '  0.00%'
    return f'{n/total*100:6.2f}%'


def parse_trace(path):
    """Yield dicts of parsed UOPLIFE records."""
    with open(path) as f:
        for line in f:
            m = UOPLIFE_RE.match(line.rstrip())
            if not m:
                continue
            g = m.groups()
            yield {
                'seq':       int(g[0]),
                'rob':       int(g[1]),
                'pc':        int(g[2], 16),
                'fu':        int(g[3]),
                'is_load':   int(g[4]),
                'is_store':  int(g[5]),
                'is_branch': int(g[6]),
                'mis':       int(g[7]),
                'rename':    int(g[8]),
                'dispatch':  int(g[9]),
                'issue':     int(g[10]),
                'wb':        int(g[11]),
                'commit':    int(g[12]),
                'd_ren_to_disp': int(g[13]),
                'd_disp_to_iss': int(g[14]),
                'd_iss_to_wb':   int(g[15]),
                'd_wb_to_cmt':   int(g[16]),
                'd_total':       int(g[17]),
            }


def fu_class(rec):
    """One-hot class label for cross-tab purposes."""
    if rec['is_load']:
        return 'LOAD'
    if rec['is_store']:
        return 'STORE'
    if rec['is_branch']:
        return 'BRANCH'
    return FU_NAME.get(rec['fu'], '?')


def histo_for(records, key, filt=None):
    """Bucket counts and cycle-weighted shares."""
    h = Counter()
    h_cyc = Counter()
    n = 0
    total_cyc = 0
    for r in records:
        if filt and not filt(r):
            continue
        d = r[key]
        if d < 0:  # unobserved stage; skip
            continue
        b = bucket_of(d)
        h[b] += 1
        h_cyc[b] += d
        n += 1
        total_cyc += d
    return h, h_cyc, n, total_cyc


def render_histo(label, h, h_cyc, n, total_cyc, out):
    out.write(f'  {label}\n')
    out.write(f'    bucket    #uops      %uops      sum_cyc    %cyc\n')
    out.write(f'    --------- ---------- ---------- ---------- --------\n')
    order = ['0', '1', '2', '3', '4-5', '6-10', '11-20', '21-50', '51-100', '100+']
    for b in order:
        if b not in h:
            continue
        c = h[b]
        cs = h_cyc[b]
        out.write(f'    {b:<9} {c:>10d} {fmt_pct(c,n)} {cs:>10d} {fmt_pct(cs,total_cyc)}\n')
    out.write(f'    -- total: n={n}  total_cyc={total_cyc}  avg={total_cyc/max(n,1):.2f}\n')


def per_pc_top(records, key, top_n=20, filt=None):
    """Top PCs ranked by avg time-in-stage (min support 50 occurrences)."""
    pc_n = Counter()
    pc_sum = Counter()
    pc_max = defaultdict(int)
    for r in records:
        if filt and not filt(r):
            continue
        d = r[key]
        if d < 0:
            continue
        pc = r['pc']
        pc_n[pc] += 1
        pc_sum[pc] += d
        if d > pc_max[pc]:
            pc_max[pc] = d
    rows = []
    for pc, n in pc_n.items():
        if n < 50:
            continue
        avg = pc_sum[pc] / n
        rows.append((pc, n, avg, pc_max[pc], pc_sum[pc]))
    rows.sort(key=lambda r: -r[2])  # by avg desc
    return rows[:top_n]


def cross_tab(records, key):
    """Per-FU bucket distribution."""
    out = {}
    for r in records:
        d = r[key]
        if d < 0:
            continue
        cls = fu_class(r)
        if cls not in out:
            out[cls] = (Counter(), Counter(), [0], [0])
        h, h_cyc, n, total_cyc = out[cls]
        b = bucket_of(d)
        h[b] += 1
        h_cyc[b] += d
        n[0] += 1
        total_cyc[0] += d
    return out


def chain_depth_analysis(records):
    """How often are consecutive uops dispatched in the same cycle?
    Computes a histogram of dispatch-cluster sizes.
    """
    clusters = []
    cur_cyc = None
    cur_size = 0
    for r in records:
        d = r['dispatch']
        if d <= 0:
            if cur_size > 0:
                clusters.append(cur_size)
            cur_cyc = None
            cur_size = 0
            continue
        if d == cur_cyc:
            cur_size += 1
        else:
            if cur_size > 0:
                clusters.append(cur_size)
            cur_cyc = d
            cur_size = 1
    if cur_size > 0:
        clusters.append(cur_size)
    return Counter(clusters)


def long_iss_to_wb_loads(records, threshold=20, max_examples=20):
    """Loads that took >threshold cycles from issue to writeback (likely D$ miss / replay)."""
    out = []
    for r in records:
        if r['is_load'] and r['d_iss_to_wb'] > threshold:
            out.append(r)
    out.sort(key=lambda r: -r['d_iss_to_wb'])
    return out[:max_examples], len([r for r in records if r['is_load']])


def long_total_per_class(records):
    """Long-tail uops with d_total > 50, grouped by class. Returns top 20 PCs by count."""
    long_uops = [r for r in records if r['d_total'] > 50]
    pc_class_n = Counter()
    pc_class_sum = Counter()
    for r in long_uops:
        cls = fu_class(r)
        key = (cls, r['pc'])
        pc_class_n[key] += 1
        pc_class_sum[key] += r['d_total']
    rows = []
    for (cls, pc), n in pc_class_n.items():
        if n < 5:
            continue
        avg = pc_class_sum[(cls, pc)] / n
        rows.append((cls, pc, n, avg, pc_class_sum[(cls, pc)]))
    rows.sort(key=lambda r: -r[2])
    return rows[:25], len(long_uops)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('trace', help='UOPLIFE trace file (filtered to [UOPLIFE ...] lines)')
    ap.add_argument('--label', default=None, help='Workload label for header')
    ap.add_argument('--top-pcs', type=int, default=15, help='Top-N PCs per stage')
    ap.add_argument('--out', default=None, help='Output report file (also stdout)')
    args = ap.parse_args()

    label = args.label or args.trace
    records = list(parse_trace(args.trace))
    if not records:
        print(f'no UOPLIFE records found in {args.trace}', file=sys.stderr)
        sys.exit(1)

    out_files = [sys.stdout]
    if args.out:
        out_files.append(open(args.out, 'w'))

    def w(s=''):
        for f in out_files:
            f.write(s + '\n')

    w('=' * 78)
    w(f'UOPLIFE analysis — {label}')
    w('=' * 78)
    w(f'Total UOPLIFE records: {len(records)}')
    fu_count = Counter(fu_class(r) for r in records)
    w('Per-FU class counts:')
    for cls, n in sorted(fu_count.items(), key=lambda x: -x[1]):
        w(f'  {cls:<8s} {n:>10d}  ({n/len(records)*100:.2f}%)')
    w()

    # ----- Per-stage delta histograms ---------------------------------------
    w('-' * 78)
    w('Per-stage delta histograms (all uops)')
    w('-' * 78)
    for stage_label, key in STAGES:
        h, h_cyc, n, total_cyc = histo_for(records, key)
        # Skip stages with no observations (e.g., wb for stores already excluded)
        if n == 0:
            continue
        w(f'\nStage: {stage_label}')
        # Render directly to all out_files
        from io import StringIO
        s = StringIO()
        render_histo(stage_label, h, h_cyc, n, total_cyc, s)
        for line in s.getvalue().splitlines():
            w(line)
    w()

    # ----- Per-FU breakdown of d_total --------------------------------------
    w('-' * 78)
    w('Per-FU d_total distribution')
    w('-' * 78)
    ct = cross_tab(records, 'd_total')
    for cls in sorted(ct.keys()):
        h, h_cyc, n_box, total_cyc_box = ct[cls]
        n = n_box[0]
        total_cyc = total_cyc_box[0]
        w(f'\nFU class: {cls}')
        from io import StringIO
        s = StringIO()
        render_histo(f'd_total ({cls})', h, h_cyc, n, total_cyc, s)
        for line in s.getvalue().splitlines():
            w(line)
    w()

    # ----- Per-FU breakdown of d_iss_to_wb ----------------------------------
    w('-' * 78)
    w('Per-FU d_iss_to_wb distribution (execution latency)')
    w('-' * 78)
    ct = cross_tab(records, 'd_iss_to_wb')
    for cls in sorted(ct.keys()):
        h, h_cyc, n_box, total_cyc_box = ct[cls]
        n = n_box[0]
        total_cyc = total_cyc_box[0]
        if n == 0:
            continue
        w(f'\nFU class: {cls}')
        from io import StringIO
        s = StringIO()
        render_histo(f'd_iss_to_wb ({cls})', h, h_cyc, n, total_cyc, s)
        for line in s.getvalue().splitlines():
            w(line)
    w()

    # ----- Per-FU breakdown of d_wb_to_cmt ----------------------------------
    w('-' * 78)
    w('Per-FU d_wb_to_cmt distribution (head-of-ROB stall after exec)')
    w('-' * 78)
    ct = cross_tab(records, 'd_wb_to_cmt')
    for cls in sorted(ct.keys()):
        h, h_cyc, n_box, total_cyc_box = ct[cls]
        n = n_box[0]
        total_cyc = total_cyc_box[0]
        if n == 0:
            continue
        w(f'\nFU class: {cls}')
        from io import StringIO
        s = StringIO()
        render_histo(f'd_wb_to_cmt ({cls})', h, h_cyc, n, total_cyc, s)
        for line in s.getvalue().splitlines():
            w(line)
    w()

    # ----- Top PCs per stage by avg time -------------------------------------
    w('-' * 78)
    w(f'Top {args.top_pcs} outlier PCs per stage (min 50 occurrences)')
    w('-' * 78)
    for stage_label, key in STAGES:
        rows = per_pc_top(records, key, top_n=args.top_pcs)
        if not rows:
            continue
        w(f'\nStage: {stage_label} — top {args.top_pcs} PCs by avg cyc')
        w(f'  PC                 #occur     avg_cyc   max  sum_cyc')
        for pc, n, avg, mx, su in rows:
            w(f'  0x{pc:016x} {n:>9d}    {avg:>7.2f} {mx:>4d} {su:>9d}')
    w()

    # ----- Per-class long-tail (d_total > 50) --------------------------------
    w('-' * 78)
    w('Long-tail uops (d_total > 50): top PCs by occurrence')
    w('-' * 78)
    rows, n_long = long_total_per_class(records)
    w(f'Total long-tail uops (d_total>50): {n_long}  '
      f'({n_long/len(records)*100:.2f}% of all uops)')
    w(f'  CLASS    PC                 #occur   avg_cyc  sum_cyc')
    for cls, pc, n, avg, su in rows:
        w(f'  {cls:<8s} 0x{pc:016x} {n:>7d}  {avg:>7.2f} {su:>8d}')
    w()

    # ----- Long iss->wb loads (probable D$ misses / replays) -----------------
    w('-' * 78)
    w('Loads with iss->wb > 20 cyc (probable D$ miss / SQ replay / LMB wait)')
    w('-' * 78)
    long_lds, n_lds = long_iss_to_wb_loads(records)
    if n_lds > 0:
        n_long_lds = sum(1 for r in records if r['is_load'] and r['d_iss_to_wb'] > 20)
        w(f'  long loads (iss->wb > 20 cyc): {n_long_lds} of {n_lds}'
          f' ({n_long_lds/n_lds*100:.2f}% of loads)')
        w(f'  PC                 d_iss_to_wb  d_total  rob   seq')
        for r in long_lds:
            w(f'  0x{r["pc"]:016x} {r["d_iss_to_wb"]:>11d} {r["d_total"]:>8d} {r["rob"]:>5d} {r["seq"]:>9d}')
    else:
        w('  (no loads observed)')
    w()

    # ----- Mispredicted branches: do they have high d_wb_to_cmt? -------------
    w('-' * 78)
    w('Mispredicted branches: d_wb_to_cmt distribution')
    w('-' * 78)
    h, h_cyc, n, total_cyc = histo_for(records, 'd_wb_to_cmt',
                                       filt=lambda r: r['mis'] == 1)
    if n > 0:
        from io import StringIO
        s = StringIO()
        render_histo('mis=1 d_wb_to_cmt', h, h_cyc, n, total_cyc, s)
        for line in s.getvalue().splitlines():
            w(line)
    h, h_cyc, n, total_cyc = histo_for(records, 'd_total',
                                       filt=lambda r: r['mis'] == 1)
    if n > 0:
        w('\n  -- mispredicted-branch d_total --')
        from io import StringIO
        s = StringIO()
        render_histo('mis=1 d_total', h, h_cyc, n, total_cyc, s)
        for line in s.getvalue().splitlines():
            w(line)
    w()

    # ----- Dispatch chain depth (how many uops dispatch same cycle) -----------
    w('-' * 78)
    w('Dispatch cluster sizes (uops dequeued in the same cycle)')
    w('-' * 78)
    cluster_h = chain_depth_analysis(records)
    total_clusters = sum(cluster_h.values())
    total_uops_in_clusters = sum(k*v for k, v in cluster_h.items())
    w(f'  cluster_size  #clusters  %clusters  #uops   %uops')
    for k in sorted(cluster_h.keys()):
        v = cluster_h[k]
        n_in = k*v
        w(f'  {k:>12d}  {v:>9d}  {fmt_pct(v,total_clusters)}  {n_in:>6d} {fmt_pct(n_in,total_uops_in_clusters)}')
    w(f'  total: {total_clusters} clusters, {total_uops_in_clusters} uops')
    w()

    # ----- Summary ranking of stage contribution ------------------------------
    w('-' * 78)
    w('Aggregate stage contribution to mean time-in-ROB')
    w('-' * 78)
    sums = {}
    counts = {}
    for stage_label, key in STAGES:
        s = 0
        n = 0
        for r in records:
            if r[key] >= 0:
                s += r[key]
                n += 1
        sums[stage_label] = s
        counts[stage_label] = n
    total_sum = sums.get('TOTAL_in_ROB', 1)
    w(f'  stage              sum_cyc      avg/uop   %total')
    for stage_label, _ in STAGES:
        s = sums[stage_label]
        n = counts[stage_label]
        avg = s/max(n,1)
        pct = s/max(total_sum,1)*100
        w(f'  {stage_label:<18s} {s:>10d}    {avg:>7.2f}  {pct:>6.2f}%')
    w()

    if args.out:
        out_files[1].close()
        print(f'\nReport saved to {args.out}', file=sys.stderr)


if __name__ == '__main__':
    main()

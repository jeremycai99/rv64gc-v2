#!/usr/bin/env python3
"""uoplife_critical_path.py -- per-PC critical-path / recurrence-latency profile
from a +TRACE_UOPLIFE DSim log.

Each committed uop emits:
  [UOPLIFE seq=.. rob=.. pc=016h fu=.. is_load=.. is_store=.. is_branch=.. mis=..
   rename=.. dispatch=.. issue=.. wb=.. commit=..
   d_ren_to_disp=.. d_disp_to_iss=.. d_iss_to_wb=.. d_wb_to_cmt=.. d_total=..]

Stage deltas map to architectural levers:
  d_disp_to_iss  = operand-wait in IQ      -> faster wakeup / value-pred / MLP
  d_iss_to_wb    = execute/load latency    -> dcache 2->1 (loads) / chained-ALU
  d_wb_to_cmt    = wait at ROB head        -> out-of-order commit

For each hot PC we also estimate the SERIAL RECURRENCE interval = median cycle
gap between consecutive issues of that static PC (the true loop-carried latency
when that PC is the loop's critical instruction).

Usage: uoplife_critical_path.py <uoplife.log> [--top N] [--min-count K] [--pc 0x..,..]
"""
import sys, re, argparse, statistics

LINE = re.compile(
    r'\[UOPLIFE seq=(\d+) rob=(\d+) pc=([0-9a-fA-F]+) fu=(\d+) '
    r'is_load=(\d+) is_store=(\d+) is_branch=(\d+) mis=(\d+) '
    r'rename=(\d+) dispatch=(\d+) issue=(\d+) wb=(\d+) commit=(\d+) '
    r'd_ren_to_disp=(-?\d+) d_disp_to_iss=(-?\d+) d_iss_to_wb=(-?\d+) '
    r'd_wb_to_cmt=(-?\d+) d_total=(-?\d+)\]')

FU = {0: 'ALU', 1: 'BRU', 2: 'MUL', 3: 'DIV', 4: 'LOAD', 5: 'STA', 6: 'STD', 7: 'CSR'}


def parse(path):
    rows = []
    with open(path, errors='replace') as f:
        for ln in f:
            m = LINE.search(ln)
            if not m:
                continue
            g = m.groups()
            rows.append(dict(
                seq=int(g[0]), pc=int(g[2], 16), fu=int(g[3]),
                is_load=int(g[4]), is_store=int(g[5]), is_branch=int(g[6]), mis=int(g[7]),
                issue=int(g[10]), commit=int(g[12]),
                d_rd=int(g[13]), d_di=int(g[14]), d_iw=int(g[15]), d_wc=int(g[16]), d_tot=int(g[17])))
    return rows


def cls(r):
    if r['is_load']:
        return 'load'
    if r['is_store']:
        return 'store'
    if r['is_branch']:
        return 'branch'
    return FU.get(r['fu'], f"fu{r['fu']}")


def mean(xs):
    return sum(xs) / len(xs) if xs else 0.0


def recurrence(issues):
    """median gap between consecutive issues of a static PC (sorted)."""
    s = sorted(issues)
    gaps = [b - a for a, b in zip(s, s[1:]) if 0 < (b - a) < 10000]
    return statistics.median(gaps) if gaps else 0.0


def binding(d_di, d_iw, d_wc):
    pairs = [('operand-wait(IQ)->wakeup/VP/MLP', d_di),
             ('execute/load-lat->dcache2to1/chainedALU', d_iw),
             ('head-commit-wait->OoO-commit', d_wc)]
    return max(pairs, key=lambda x: x[1])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('log')
    ap.add_argument('--top', type=int, default=20)
    ap.add_argument('--min-count', type=int, default=50)
    ap.add_argument('--pc', default='', help='comma list of hex PCs to always include')
    a = ap.parse_args()

    rows = parse(a.log)
    if not rows:
        print('No [UOPLIFE] lines found in', a.log)
        sys.exit(1)
    total_cyc = max(r['commit'] for r in rows)
    print(f'# parsed {len(rows):,} committed uops; last commit cycle {total_cyc:,}\n')

    by = {}
    for r in rows:
        by.setdefault(r['pc'], []).append(r)

    want = set()
    for p in a.pc.split(','):
        p = p.strip()
        if p:
            want.add(int(p, 16))

    # aggregate per PC
    aggs = []
    for pc, rs in by.items():
        if len(rs) < a.min_count and pc not in want:
            continue
        aggs.append(dict(
            pc=pc, n=len(rs), cls=cls(rs[0]),
            d_di=mean([x['d_di'] for x in rs]),
            d_iw=mean([x['d_iw'] for x in rs]),
            d_wc=mean([x['d_wc'] for x in rs]),
            d_tot=mean([x['d_tot'] for x in rs]),
            mis=mean([x['mis'] for x in rs]),
            recur=recurrence([x['issue'] for x in rs]),
            wait_sum=sum(x['d_di'] + x['d_wc'] for x in rs)))  # serial-wait proxy

    aggs.sort(key=lambda x: x['wait_sum'], reverse=True)
    sel = aggs[:a.top] + [x for x in aggs if x['pc'] in want and x not in aggs[:a.top]]

    hdr = f"{'pc':>12} {'cls':>6} {'count':>8} {'d_disp_iss':>10} {'d_iss_wb':>9} {'d_wb_cmt':>9} {'d_total':>8} {'recur':>6} {'mis%':>5}  binding-link"
    print(hdr)
    print('-' * len(hdr))
    for x in sel:
        b, _ = binding(x['d_di'], x['d_iw'], x['d_wc'])
        print(f"0x{x['pc']:010x} {x['cls']:>6} {x['n']:>8,} {x['d_di']:>10.2f} {x['d_iw']:>9.2f} "
              f"{x['d_wc']:>9.2f} {x['d_tot']:>8.2f} {x['recur']:>6.1f} {100*x['mis']:>4.1f}  {b}")

    # global stage decomposition (mean per-uop, all uops)
    print('\n# global mean per-uop stage latency (all committed uops):')
    print(f"  d_disp_to_iss (operand-wait) = {mean([r['d_di'] for r in rows]):.2f}")
    print(f"  d_iss_to_wb   (execute/load) = {mean([r['d_iw'] for r in rows]):.2f}")
    print(f"  d_wb_to_cmt   (head-commit)  = {mean([r['d_wc'] for r in rows]):.2f}")
    print(f"  d_ren_to_disp (front/disp)   = {mean([r['d_rd'] for r in rows]):.2f}")


if __name__ == '__main__':
    main()

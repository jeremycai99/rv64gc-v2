#!/usr/bin/env python3
"""Parse [DPREFETCH CENSUS] blocks from bench/boot logs into a FUND/KILL table.

Usage: dpf_census_summarize.py <log1> [<log2> ...]
Each log must contain one '=== DPREFETCH CENSUS (Lever A) ===' block (+ an
'IPC:' line for bench, or LINUX_STATUS for boot).  Emits per-workload metrics
and the gate verdict (>=40% coverage of WARM misses AND timely).
"""
import re, sys, os

GATE_COV = 0.40       # >=40% of (warm) D$ misses covered by confident stride
L2_LAT   = 8          # L2-hit latency; timely if lead >= L2_LAT

def grab(pat, text, n=1, cast=int, default=0):
    m = re.search(pat, text)
    if not m:
        return [default]*n if n > 1 else default
    if n == 1:
        return cast(m.group(1))
    return [cast(m.group(i+1)) for i in range(n)]

def parse(path):
    t = open(path, errors='replace').read()
    if 'DPREFETCH CENSUS' not in t:
        return None
    d = {}
    d['loads'], d['misses'] = grab(r'DPF loads=(\d+) misses=(\d+)', t, 2)
    cs, csl, irr, ft, al = grab(
        r'DPF miss_conf_stride=(\d+) miss_conf_sameline=(\d+) '
        r'miss_irregular=(\d+) miss_firsttouch=(\d+) miss_alias=(\d+)', t, 5)
    d.update(dict(conf_stride=cs, conf_sameline=csl, irregular=irr,
                  firsttouch=ft, alias=al))
    d['hit_conf_stride'] = grab(r'DPF hit_conf_stride=(\d+)', t)
    tm, utm, lsum = grab(
        r'DPF timely_misses=(\d+) untimely_misses=(\d+) lead_sum=(\d+)', t, 3)
    d.update(dict(timely=tm, untimely=utm, lead_sum=lsum))
    lh = grab(r'DPF lead_hist <2=(\d+) 2-3=(\d+) 4-7=(\d+) 8-15=(\d+) '
              r'16-79=(\d+) >=80=(\d+)', t, 6)
    d['lead_hist'] = lh
    mm = re.search(r'DPF mlp_max=(\d+) mlp_hist 0=(\d+) 1=(\d+) 2=(\d+) 3=(\d+) '
                   r'4=(\d+) 5=(\d+) 6=(\d+) 7=(\d+) 8\+=(\d+)', t)
    if mm:
        d['mlp_max'] = int(mm.group(1))
        d['mlp_hist'] = [int(mm.group(i+2)) for i in range(9)]
    else:
        d['mlp_max'] = 0; d['mlp_hist'] = [0]*9
    ipc = re.search(r'IPC: mcycle=(\d+) minstret=(\d+) IPC=([\d.]+)', t)
    if ipc:
        d['mcycle'] = int(ipc.group(1)); d['minstret'] = int(ipc.group(2))
        d['ipc'] = float(ipc.group(3))
    else:
        # boot: take last LINUX_STATUS mcycle/minstret
        ls = re.findall(r'mcycle=(\d+) minstret=(\d+)', t)
        if ls:
            d['mcycle'] = int(ls[-1][0]); d['minstret'] = int(ls[-1][1])
            d['ipc'] = d['minstret']/d['mcycle'] if d['mcycle'] else 0
        else:
            d['mcycle'] = d['minstret'] = 0; d['ipc'] = 0
    return d

def pct(a, b):
    return 100.0*a/b if b else 0.0

def main(paths):
    # coverage = stride-coverable fraction = (conf_stride + conf_sameline)/classified.
    #   conf_stride   : prior access on a DIFFERENT line -> covered at degree 1.
    #   conf_sameline : confident-stride PC but prior access same line -> covered
    #                   only at higher prefetch degree (>=ceil(line/stride)).
    # timely% is the degree-1-timely subset (lead >= L2 latency) of conf_stride.
    hdr = (f"{'workload':24} {'IPC':>5} {'Dmiss%':>7} {'cover%':>7} "
           f"{'d1cov%':>7} {'deepcov%':>8} {'irreg%':>7} {'cold%':>6} "
           f"{'d1timely%':>9} {'mlp_max':>7} {'verdict':>8}")
    print(hdr); print('-'*len(hdr))
    rows = []
    for p in paths:
        d = parse(p)
        if d is None:
            print(f"{os.path.basename(p):24} (no census block)"); continue
        name = os.path.basename(p).replace('.log','')
        m = d['misses']; loads = d['loads']
        classified = (d['conf_stride'] + d['conf_sameline'] +
                      d['irregular'] + d['firsttouch']) or 1
        coverable = d['conf_stride'] + d['conf_sameline']
        cover    = pct(coverable, classified)          # total stride-coverable
        d1cov    = pct(d['conf_stride'], classified)    # degree-1 coverable
        deepcov  = pct(d['conf_sameline'], classified)  # needs higher degree
        irreg    = pct(d['irregular'], classified)
        cold     = pct(d['firsttouch'], classified)
        timely   = pct(d['timely'], d['conf_stride']) if d['conf_stride'] else 0.0
        dmiss    = pct(m, loads)
        # FUND if stride-coverable >= 40% AND a usable degree-1-timely fraction
        # exists (else it needs a deep prefetcher to be timely — note separately).
        fund = (cover >= 100*GATE_COV) and (d['timely'] > 0) and \
               (pct(d['timely'], coverable) >= 5.0)
        verdict = 'FUND' if fund else 'KILL'
        print(f"{name:24} {d['ipc']:5.2f} {dmiss:7.1f} {cover:7.1f} "
              f"{d1cov:7.1f} {deepcov:8.1f} {irreg:7.1f} {cold:6.1f} "
              f"{timely:9.1f} {d['mlp_max']:7d} {verdict:>8}")
        rows.append((name, d, cover, d1cov, timely, dmiss))
    print()
    for name, d, cov_all, cov_warm, timely, dmiss in rows:
        lh = d['lead_hist']
        print(f"{name}: lead_hist <2={lh[0]} 2-3={lh[1]} 4-7={lh[2]} "
              f"8-15={lh[3]} 16-79={lh[4]} >=80={lh[5]}  "
              f"timely={d['timely']} untimely={d['untimely']}  "
              f"mlp_hist={d['mlp_hist']}")
    return 0

if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

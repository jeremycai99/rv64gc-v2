#!/usr/bin/env python3
"""Summarize +CENSUS sweep logs (P0 supply census, study §4.1-4.2).

Per workload: avg commit width, %cycles width-0, ROB occupancy mode/median
bucket (16-entry buckets), starved-with-headroom %, ROB-full %, backend-stall %.
Tag: SUPPLY iff starved_headroom >= 10% AND median ROB bucket <= 2 (<48 occ);
CHAIN iff median bucket >= 2 AND starved < 10%; else MIXED.
"""
import re, sys, glob, os

LOGDIR = sys.argv[1] if len(sys.argv) > 1 else "log/census_runs"

rows = []
for path in sorted(glob.glob(os.path.join(LOGDIR, "*.log"))):
    name = os.path.basename(path)[:-4]
    txt = open(path, errors="replace").read()
    m_cw = re.search(r"\[CENSUS\] cycles=(\d+) cw0=(\d+) cw1=(\d+) cw2=(\d+) cw3=(\d+) cw4=(\d+)", txt)
    m_rob = re.search(r"\[CENSUS\] rob_occ16=([\d,]+)", txt)
    m_fl = re.search(r"\[CENSUS\] ren_zero=(\d+) starved_headroom=(\d+) rob_full=(\d+) backend_stall=(\d+)", txt)
    m_ipc = re.findall(r"IPC: mcycle=(\d+) minstret=(\d+) IPC=([\d.]+)", txt)
    end = "PASS" if "PASS at cycle" in txt else ("TIMEOUT" if "TIMEOUT" in txt else
          ("TOHOST" if "TOHOST=" in txt else "?"))
    if not (m_cw and m_rob and m_fl):
        rows.append((name, end, None)); continue
    cyc = int(m_cw.group(1))
    cw = [int(m_cw.group(i)) for i in range(2, 7)]
    rob = [int(x) for x in m_rob.group(1).split(",")]
    ren_zero, starved, robfull, bstall = (int(m_fl.group(i)) for i in range(1, 5))
    avg_cw = sum(i * c for i, c in enumerate(cw)) / cyc
    pct = lambda x: 100.0 * x / cyc
    mode_b = max(range(8), key=lambda i: rob[i])
    cum, med_b = 0, 7
    for i in range(8):
        cum += rob[i]
        if cum >= cyc / 2:
            med_b = i; break
    s_pct, rf_pct = pct(starved), pct(robfull)
    if s_pct >= 10.0 and med_b <= 2:
        tag = "SUPPLY"
    elif med_b >= 2 and s_pct < 10.0:
        tag = "CHAIN"
    else:
        tag = "MIXED"
    ipc = float(m_ipc[-1][2]) if m_ipc else float("nan")
    rows.append((name, end, dict(cyc=cyc, ipc=ipc, avg_cw=avg_cw, cw0=pct(cw[0]),
                                 mode_b=mode_b, med_b=med_b, starved=s_pct,
                                 robfull=rf_pct, bstall=pct(bstall),
                                 ren_zero=pct(ren_zero), tag=tag)))

hdr = (f"{'workload':<22} {'end':<7} {'IPC':>5} {'avgCW':>6} {'cw0%':>6} "
       f"{'robMode':>7} {'robMed':>6} {'starv%':>7} {'robF%':>6} {'bstal%':>7} "
       f"{'renZ%':>6} tag")
print(hdr); print("-" * len(hdr))
for name, end, d in rows:
    if d is None:
        print(f"{name:<22} {end:<7} NO [CENSUS] OUTPUT"); continue
    print(f"{name:<22} {end:<7} {d['ipc']:>5.2f} {d['avg_cw']:>6.2f} {d['cw0']:>6.1f} "
          f"{d['mode_b']:>7} {d['med_b']:>6} {d['starved']:>7.2f} {d['robfull']:>6.2f} "
          f"{d['bstall']:>7.2f} {d['ren_zero']:>6.1f} {d['tag']}")

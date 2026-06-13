#!/usr/bin/env python3
"""Align two +LPW_TRACE logs (ON vs OFF arm) and report the first divergence.

UPD events are commit-ordered and align 1:1 across arms (minstret-identical
arms commit the same branch stream).  The first UPD whose value tuple
(taken, misp, cnt, spec, lim, conf, byc) differs is the first
architecturally-visible divergence; the script then dumps the +/-N event
neighborhood (all LPW categories, cycle-ordered) from both logs around it.
"""
import re
import sys

LPW = re.compile(r"\[LPW-(\w+)\] n=(\d+) cyc=(\d+) (.*)")


def parse(path):
    cats = {"UPD": [], "LKP": [], "SPEC": [], "FLUSH": []}
    allev = []
    with open(path, errors="replace") as f:
        for line in f:
            m = LPW.match(line.strip())
            if not m:
                continue
            cat, n, cyc, rest = m.group(1), int(m.group(2)), int(m.group(3)), m.group(4)
            ev = (cat, n, cyc, rest.strip())
            cats.setdefault(cat, []).append(ev)
            allev.append(ev)
    return cats, allev


def main():
    on_path, off_path = sys.argv[1], sys.argv[2]
    ncontext = int(sys.argv[3]) if len(sys.argv) > 3 else 12
    on_cats, on_all = parse(on_path)
    off_cats, off_all = parse(off_path)

    on_upd, off_upd = on_cats["UPD"], off_cats["UPD"]
    print(f"UPD events: on={len(on_upd)} off={len(off_upd)}")
    print(f"LKP events: on={len(on_cats['LKP'])} off={len(off_cats['LKP'])}")
    print(f"SPEC events: on={len(on_cats['SPEC'])} off={len(off_cats['SPEC'])}")
    print(f"FLUSH events: on={len(on_cats['FLUSH'])} off={len(off_cats['FLUSH'])}")

    div = None
    for i in range(min(len(on_upd), len(off_upd))):
        if on_upd[i][3] != off_upd[i][3]:
            div = i
            break
    if div is None:
        print("No UPD divergence in the common prefix.")
        return
    print(f"\nFIRST UPD DIVERGENCE at UPD n={div}")
    print(f"  on : cyc={on_upd[div][2]} {on_upd[div][3]}")
    print(f"  off: cyc={off_upd[div][2]} {off_upd[div][3]}")

    # statistics: count UPD field mismatches over the common prefix
    mism = 0
    for i in range(min(len(on_upd), len(off_upd))):
        if on_upd[i][3] != off_upd[i][3]:
            mism += 1
    print(f"UPD tuple mismatches over common prefix: {mism}")

    for tag, allev, upd in (("ON", on_all, on_upd), ("OFF", off_all, off_upd)):
        cyc0 = upd[div][2]
        idx = next(k for k, ev in enumerate(allev)
                   if ev[0] == "UPD" and ev[1] == div)
        lo, hi = max(0, idx - ncontext), min(len(allev), idx + ncontext + 1)
        print(f"\n--- {tag} neighborhood (divergent UPD cyc={cyc0}) ---")
        for ev in allev[lo:hi]:
            mark = " <== DIVERGENT UPD" if (ev[0] == "UPD" and ev[1] == div) else ""
            print(f"  [{ev[0]}] n={ev[1]} cyc={ev[2]} {ev[3]}{mark}")


if __name__ == "__main__":
    main()

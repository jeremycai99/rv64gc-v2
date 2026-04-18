#!/usr/bin/env python3
"""Extract key partial-replay events from a focused VCD.

Output one event line per cycle edge where anything interesting happens.
Designed to make diff between baseline and Phase 3a easy to read.
"""
import sys
from vcdvcd import VCDVCD


def find_signal(vcd, name):
    """Return the identifier_code for a signal whose reference ends with name.
    Matches on the last component of the hierarchical reference.
    """
    for ref, idcode in vcd.references_to_ids.items():
        if ref.endswith(name) or ref.rsplit('.', 1)[-1] == name:
            return idcode, ref
    return None, None


def extract(vcd_path):
    vcd = VCDVCD(vcd_path, store_tvs=True)

    signals = {
        "replay_valid":     "replay_valid",
        "violation":        "lsu_ordering_violation",
        "violation_rob":    "lsu_violation_rob_idx",
        "flush_valid":      "flush_out.valid",
        "flush_full":       "flush_out.full_flush",
        "flush_redirect":   "flush_out.redirect_pc",
        "commit_count":     "commit_count",
        "head_r":           "head_r",
        "tail_r":           "tail_r",
        "wdog":             "rob_head_watchdog",
        "load_issue_valid": "load_issue_valid",
        "ord_viol":         "ordering_violation",
        "viol_rob":         "violation_rob_idx",
    }

    resolved = {}
    for short, pattern in signals.items():
        code, ref = find_signal(vcd, pattern)
        if code:
            resolved[short] = (code, ref)
        else:
            print(f"// WARN: signal {pattern!r} not found", file=sys.stderr)

    # Collect per-cycle change events.  VCD time is in ps; clock period in
    # our sim is ~10 ns = 10000 ps (rising edges at odd multiples of 5000).
    # We bucket events by cycle = time // 10000.
    events_by_cycle = {}
    for short, (code, ref) in resolved.items():
        tv = vcd.data[code].tv
        for t, v in tv:
            cyc = t // 10000
            events_by_cycle.setdefault(cyc, {})[short] = v

    # Emit a line per cycle where anything of interest fires.
    out = []
    for cyc in sorted(events_by_cycle.keys()):
        ev = events_by_cycle[cyc]
        # Interesting if violation, replay_valid, flush_valid, commit_count>0
        interesting = False
        if ev.get("ord_viol", "0").lstrip("b").strip("0") != "":
            interesting = True
        if ev.get("replay_valid", "0").lstrip("b").strip("0") != "":
            interesting = True
        if ev.get("flush_valid", "0").lstrip("b").strip("0") != "":
            interesting = True
        cc = ev.get("commit_count", None)
        if cc is not None:
            try:
                cc_int = int(cc.lstrip("b"), 2) if cc.startswith("b") else int(cc)
                if cc_int > 0:
                    interesting = True
            except (ValueError, AttributeError):
                pass
        if not interesting:
            continue
        parts = [f"cyc={cyc}"]
        for short in ("ord_viol", "viol_rob", "replay_valid", "violation_rob",
                      "flush_valid", "flush_full", "commit_count", "head_r",
                      "tail_r", "wdog", "load_issue_valid"):
            v = ev.get(short)
            if v is not None:
                parts.append(f"{short}={v}")
        out.append(" ".join(parts))
    return out


def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <vcd>", file=sys.stderr)
        sys.exit(1)
    for line in extract(sys.argv[1]):
        print(line)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Summarize rv64gc-v2 +PERF_PROFILE benchmark logs.

The stage-1 frontend work uses many DSim rows with the same endpoint and
pipeline counters. This script turns those logs into a compact markdown table
so each DSE decision is tied to measured buckets instead of hand-copied notes.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path


BENCH_RE = re.compile(
    r"^\[BENCH_RESULT\].*field=(?P<field>\w+) value=(?P<value>-?\d+)"
)
PASS_RE = re.compile(r"PASS at cycle (?P<cycle>\d+) \(tohost=(?P<tohost>\d+)\)")
IPC_RE = re.compile(
    r"IPC: mcycle=(?P<mcycle>\d+) minstret=(?P<minstret>\d+) IPC=(?P<ipc>[0-9.]+)"
)
TOTAL_RE = re.compile(r"^Total cycles: (?P<value>\d+)")
HIST_RE = re.compile(r"^\s+(?P<name>fetch|frontend|commit)=(?P<idx>\d+)\s*: (?P<value>\d+)")
FETCH0_RE = re.compile(r"^\s+(?P<name>[a-zA-Z0-9_]+(?:_[a-zA-Z0-9_]+)*)\s*: (?P<value>\d+)")
LOOP_RE = re.compile(r"^Loop buffer active: (?P<value>\d+) cycles")
DECODED_OP_RE = re.compile(
    r"^(?:Standalone decoded-op replay|Decoded-op cache) active: "
    r"(?P<value>\d+) cycles"
)
UOC_RE = re.compile(r"^\s+(?P<name>lookups|hits)\s+: (?P<value>\d+)")
XS_RE = re.compile(r"^xs (?P<name>.+?)\s*: (?P<value>\d+)")


KEY_FETCH0 = [
    "redirect_recovery",
    "packet_empty",
    "packet_empty_ftq_full",
    "packet_empty_wait_icresp",
    "packet_empty_f2_data",
    "packet_empty_f2_emit",
    "packet_empty_noemit_dup",
    "packet_empty_noemit_ext0",
]

KEY_XS_PREFIX = [
    "ftq_",
    "packet_buf_",
    "ic_",
    "backend_",
    "frontend_",
    "dup_",
    "f2_owner_",
    "f2_cursor_",
    "packet_stale_",
    "flowthrough_",
    "same_owner_",
]


def parse_label_path(items: list[str]) -> list[tuple[str, Path]]:
    out: list[tuple[str, Path]] = []
    for item in items:
        if "=" not in item:
            raise SystemExit(f"expected LABEL=PATH, got {item!r}")
        label, path = item.split("=", 1)
        out.append((label, Path(path)))
    return out


def parse_log(label: str, path: Path) -> dict[str, object]:
    bench: dict[str, int] = {}
    hist: dict[str, dict[int, int]] = {
        "fetch": {},
        "frontend": {},
        "commit": {},
    }
    fetch0: dict[str, int] = {}
    uoc: dict[str, int] = {}
    xs: dict[str, int] = {}
    pass_cycle = None
    tohost = None
    mcycle = None
    minstret = None
    ipc = None
    total_cycles = None
    loop_active = None
    decoded_op_active = None

    in_fetch0 = False
    for line in path.read_text(errors="replace").splitlines():
        if match := BENCH_RE.match(line):
            bench[match.group("field")] = int(match.group("value"))
            continue
        if match := PASS_RE.search(line):
            pass_cycle = int(match.group("cycle"))
            tohost = int(match.group("tohost"))
            continue
        if match := IPC_RE.search(line):
            mcycle = int(match.group("mcycle"))
            minstret = int(match.group("minstret"))
            ipc = float(match.group("ipc"))
            continue
        if match := TOTAL_RE.match(line):
            total_cycles = int(match.group("value"))
            continue
        if match := HIST_RE.match(line):
            hist[match.group("name")][int(match.group("idx"))] = int(match.group("value"))
            continue
        if line.startswith("Fetch=0 breakdown:"):
            in_fetch0 = True
            continue
        if in_fetch0:
            if line.startswith("Commit histogram"):
                in_fetch0 = False
            elif match := FETCH0_RE.match(line):
                fetch0[match.group("name")] = int(match.group("value"))
                continue
        if match := LOOP_RE.match(line):
            loop_active = int(match.group("value"))
            continue
        if match := DECODED_OP_RE.match(line):
            decoded_op_active = int(match.group("value"))
            continue
        if match := UOC_RE.match(line):
            uoc[match.group("name")] = int(match.group("value"))
            continue
        if match := XS_RE.match(line):
            key = match.group("name").strip().replace(" ", "_").replace("-", "_")
            xs[key] = int(match.group("value"))

    status = "PASS" if pass_cycle is not None and tohost == 1 else "NO_PASS"
    if bench.get("flags", 0) != 0:
        status = f"{status}/flags={bench.get('flags')}"

    return {
        "label": label,
        "path": str(path),
        "status": status,
        "bench": bench,
        "pass_cycle": pass_cycle,
        "mcycle": mcycle,
        "minstret": minstret,
        "ipc": ipc,
        "total_cycles": total_cycles,
        "hist": hist,
        "fetch0": fetch0,
        "loop_active": loop_active,
        "decoded_op_active": decoded_op_active,
        "uoc": uoc,
        "xs": xs,
    }


def fmt(value: object) -> str:
    if value is None:
        return "-"
    if isinstance(value, float):
        return f"{value:.3f}"
    return str(value)


def hist_avg(hist: dict[int, int], width: int) -> float:
    total_cycles = sum(hist.values())
    if total_cycles == 0:
        return 0.0
    total_items = sum(k * v for k, v in hist.items())
    return total_items / total_cycles


def hist_pct(hist: dict[int, int], key: int) -> float:
    total = sum(hist.values())
    return (100.0 * hist.get(key, 0) / total) if total else 0.0


def render(rows: list[dict[str, object]]) -> str:
    lines: list[str] = []
    lines.append("# PERF_PROFILE Summary")
    lines.append("")
    lines.append(
        "| Row | Status | Bench cycles | mcycle | instret | IPC | Frontend avg | FE zero | Commit avg | Commit zero | Legacy LB active | Standalone decoded-op replay active | UOC lookups | IBuffer stale owner |"
    )
    lines.append("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for row in rows:
        bench = row["bench"]  # type: ignore[assignment]
        hist = row["hist"]  # type: ignore[assignment]
        uoc = row["uoc"]  # type: ignore[assignment]
        xs = row["xs"]  # type: ignore[assignment]
        frontend_hist = hist["frontend"]
        commit_hist = hist["commit"]
        xs_stale_owner = xs.get("packet_buffer_stale_owner", "-")
        lines.append(
            "| {label} | {status} | {cycles} | {mcycle} | {instret} | {ipc} | "
            "{fe_avg:.3f} | {fe_zero:.1f}% | {cmt_avg:.3f} | {cmt_zero:.1f}% | "
            "{lb} | {decoded_op_active} | {uoc_lookups} | {xs_stale_owner} |".format(
                label=row["label"],
                status=row["status"],
                cycles=bench.get("cycles", "-"),
                mcycle=fmt(row["mcycle"]),
                instret=bench.get("instret", fmt(row["minstret"])),
                ipc=fmt(row["ipc"]),
                fe_avg=hist_avg(frontend_hist, 4),
                fe_zero=hist_pct(frontend_hist, 0),
                cmt_avg=hist_avg(commit_hist, 4),
                cmt_zero=hist_pct(commit_hist, 0),
                lb=fmt(row["loop_active"]),
                decoded_op_active=fmt(row["decoded_op_active"]),
                uoc_lookups=uoc.get("lookups", "-"),
                xs_stale_owner=xs_stale_owner,
            )
        )
    lines.append("")
    lines.append("## Fetch Zero Breakdown")
    lines.append("")
    header = "| Row | " + " | ".join(KEY_FETCH0) + " |"
    lines.append(header)
    lines.append("|---" + "|---:" * len(KEY_FETCH0) + "|")
    for row in rows:
        fetch0 = row["fetch0"]  # type: ignore[assignment]
        values = " | ".join(str(fetch0.get(key, "-")) for key in KEY_FETCH0)
        lines.append(f"| {row['label']} | {values} |")
    lines.append("")
    xs_keys = sorted(
        {
            key
            for row in rows
            for key in row["xs"]  # type: ignore[index]
            if any(key.startswith(prefix) for prefix in KEY_XS_PREFIX)
        }
    )
    if xs_keys:
        lines.append("## XS Frontend Counters")
        lines.append("")
        header = "| Counter | " + " | ".join(str(row["label"]) for row in rows) + " |"
        lines.append(header)
        lines.append("|---" + "|---:" * len(rows) + "|")
        for key in xs_keys:
            values = " | ".join(
                str(row["xs"].get(key, "-"))  # type: ignore[index]
                for row in rows
            )
            lines.append(f"| {key} | {values} |")
        lines.append("")
    lines.append("## Sources")
    lines.append("")
    for row in rows:
        lines.append(f"- {row['label']}: `{row['path']}`")
    lines.append("")
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("logs", nargs="+", help="LABEL=PATH entries")
    parser.add_argument("--markdown-out")
    args = parser.parse_args()

    rows = [parse_log(label, path) for label, path in parse_label_path(args.logs)]
    markdown = render(rows)
    if args.markdown_out:
        Path(args.markdown_out).write_text(markdown)
    else:
        print(markdown)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Summarize machine-width utilization for rv64gc-v2 and BOOM logs.

rv64gc-v2 input is a DSim log containing +TRACE_PIPELINE output.  The
script prefers pipe.v2 records when present because those include load/store
issue lanes; it falls back to pipe.v1 for older logs.

BOOM input is a log containing one [BOOM_PIPE_STATS] line.
"""

from __future__ import annotations

import argparse
import json
import re
from collections import Counter
from pathlib import Path
from typing import Any


RV_WIDTHS = {
    "fetch": 4,
    "decode": 4,
    "rename": 4,
    "dispatch": 4,
    "issue_int": 4,
    "issue_mem": 4,
    "issue_total": 8,
    "commit": 4,
}

BOOM_WIDTHS = {
    "decode": 4,
    "dispatch": 4,
    "commit": 4,
}

PIPE_RE = re.compile(r"^\[PIPE schema=(pipe\.v[12])\] (?P<body>.*)$")
BOOM_RE = re.compile(r"^\[BOOM_PIPE_STATS\] (?P<body>.*)$")
BENCH_RE = re.compile(r"^\[BENCH_RESULT\].*field=(?P<field>\w+) value=(?P<value>-?\d+)")


def parse_kv_body(body: str) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for token in body.split():
        if "=" not in token:
            continue
        key, value = token.split("=", 1)
        value = value.rstrip(",")
        try:
            out[key] = int(value, 0)
        except ValueError:
            out[key] = value
    return out


def pct(value: float, total: float) -> float:
    return (100.0 * value / total) if total else 0.0


def avg(counter_sum: int, cycles: int) -> float:
    return (counter_sum / cycles) if cycles else 0.0


def hist_value(hist: Counter[int], key: int) -> int:
    return int(hist.get(key, 0))


def parse_label_path(items: list[str] | None) -> list[tuple[str, Path]]:
    parsed: list[tuple[str, Path]] = []
    for item in items or []:
        if "=" not in item:
            raise SystemExit(f"expected LABEL=PATH, got {item!r}")
        label, path = item.split("=", 1)
        parsed.append((label, Path(path)))
    return parsed


def analyze_rv64(label: str, path: Path) -> dict[str, Any]:
    v1_records: list[dict[str, Any]] = []
    v2_records: list[dict[str, Any]] = []
    bench: dict[str, int] = {}

    with path.open(errors="replace") as f:
        for line in f:
            m = PIPE_RE.match(line)
            if m:
                rec = parse_kv_body(m.group("body"))
                if rec.get("rst", 0):
                    continue
                if m.group(1) == "pipe.v2":
                    v2_records.append(rec)
                else:
                    v1_records.append(rec)
                continue

            b = BENCH_RE.match(line)
            if b:
                bench[b.group("field")] = int(b.group("value"))

    records = v2_records if v2_records else v1_records
    schema = "pipe.v2" if v2_records else "pipe.v1"
    cycles = len(records)

    hist: dict[str, Counter[int]] = {
        "fetch": Counter(),
        "decode": Counter(),
        "rename": Counter(),
        "dispatch": Counter(),
        "issue_int": Counter(),
        "issue_mem": Counter(),
        "issue_total": Counter(),
        "commit": Counter(),
        "cdb": Counter(),
    }
    sums = {name: 0 for name in hist}

    indicators = Counter()
    rob_sum = 0
    iq_sum = Counter()

    for rec in records:
        issue_int = int(rec.get("issue0", 0)) + int(rec.get("issue1", 0)) + int(rec.get("issue2", 0))
        issue_mem = int(rec.get("issue_load", 0)) + int(rec.get("issue_sta", 0)) + int(rec.get("issue_std", 0))
        issue_total = int(rec.get("issue_total", issue_int + issue_mem))

        values = {
            "fetch": int(rec.get("fetch", 0)),
            "decode": int(rec.get("decode", 0)),
            "rename": int(rec.get("rename", 0)),
            "dispatch": int(rec.get("dispatch", 0)),
            "issue_int": issue_int,
            "issue_mem": issue_mem,
            "issue_total": issue_total,
            "commit": int(rec.get("commit", 0)),
            "cdb": int(rec.get("cdb", 0)),
        }

        for name, value in values.items():
            hist[name][value] += 1
            sums[name] += value

        rob_cnt = int(rec.get("rob_cnt", 0))
        rob_sum += rob_cnt
        iq_sum["iq0"] += int(rec.get("iq0", 0))
        iq_sum["iq1"] += int(rec.get("iq1", 0))
        iq_sum["iq2"] += int(rec.get("iq2", 0))
        iq_sum["lq"] += int(rec.get("lq", 0))
        iq_sum["sq"] += int(rec.get("sq", 0))

        if values["fetch"] < RV_WIDTHS["fetch"]:
            indicators["fetch_under_width"] += 1
        if values["decode"] < RV_WIDTHS["decode"]:
            indicators["decode_under_width"] += 1
        if values["rename"] < RV_WIDTHS["rename"]:
            indicators["rename_under_width"] += 1
        if values["dispatch"] < RV_WIDTHS["dispatch"]:
            indicators["dispatch_under_width"] += 1
        if values["dispatch"] < values["rename"]:
            indicators["dispatch_less_than_rename"] += 1
        if values["issue_total"] < min(RV_WIDTHS["commit"], values["dispatch"]):
            indicators["issue_less_than_dispatch_or_commit_width"] += 1
        if values["commit"] < RV_WIDTHS["commit"]:
            indicators["commit_under_width"] += 1
        if values["commit"] < RV_WIDTHS["commit"] and rob_cnt >= RV_WIDTHS["commit"]:
            indicators["commit_under_width_with_rob_backlog"] += 1
        if values["commit"] < RV_WIDTHS["commit"] and values["issue_total"] >= RV_WIDTHS["commit"]:
            indicators["issue_ge4_while_commit_under_width"] += 1
        if int(rec.get("flush", 0)):
            indicators["flush_cycles"] += 1
        if int(rec.get("replay", 0)):
            indicators["replay_cycles"] += 1

    stage_summary: dict[str, dict[str, Any]] = {}
    for name in ["fetch", "decode", "rename", "dispatch", "issue_int", "issue_mem", "issue_total", "commit"]:
        width = RV_WIDTHS.get(name, RV_WIDTHS["commit"])
        stage_summary[name] = {
            "width": width,
            "avg": avg(sums[name], cycles),
            "util_pct": pct(sums[name], cycles * width),
            "zero_cycles": hist_value(hist[name], 0),
            "zero_pct": pct(hist_value(hist[name], 0), cycles),
            "full_cycles": sum(v for k, v in hist[name].items() if k >= width),
            "full_pct": pct(sum(v for k, v in hist[name].items() if k >= width), cycles),
            "hist": dict(sorted(hist[name].items())),
        }

    stage_summary["issue_total"]["ge_commit_width_cycles"] = sum(
        v for k, v in hist["issue_total"].items() if k >= RV_WIDTHS["commit"]
    )
    stage_summary["issue_total"]["ge_commit_width_pct"] = pct(
        stage_summary["issue_total"]["ge_commit_width_cycles"], cycles
    )

    limiter = choose_rv_limiter(indicators, cycles, stage_summary)

    return {
        "label": label,
        "core": "rv64gc-v2",
        "path": str(path),
        "schema": schema,
        "cycles": cycles,
        "bench_result": bench,
        "stage_summary": stage_summary,
        "indicators": {k: {"cycles": int(v), "pct": pct(v, cycles)} for k, v in sorted(indicators.items())},
        "rob_avg": avg(rob_sum, cycles),
        "queue_avg": {k: avg(v, cycles) for k, v in sorted(iq_sum.items())},
        "limiter": limiter,
    }


def choose_rv_limiter(
    indicators: Counter[str],
    cycles: int,
    stage_summary: dict[str, dict[str, Any]],
) -> str:
    if cycles == 0:
        return "No pipe trace records found."

    rename_avg = stage_summary["rename"]["avg"]
    dispatch_avg = stage_summary["dispatch"]["avg"]
    issue_avg = stage_summary["issue_total"]["avg"]
    commit_avg = stage_summary["commit"]["avg"]
    commit_per_rename = (commit_avg / rename_avg) if rename_avg else 0.0
    dispatch_per_rename = (dispatch_avg / rename_avg) if rename_avg else 0.0
    commit_per_issue = (commit_avg / issue_avg) if issue_avg else 0.0

    if rename_avg < 3.0 and commit_per_rename >= 0.95:
        return (
            f"frontend/rename delivery: rename avg {rename_avg:.3f}/4 and "
            f"commit tracks rename at {commit_per_rename:.3f}x."
        )
    if dispatch_per_rename < 0.90:
        value = indicators["dispatch_less_than_rename"]
        return f"dispatch/backpressure: dispatch<rename {value} cycles ({pct(value, cycles):.1f}%)."
    if commit_per_rename < 0.90:
        value = indicators["commit_under_width_with_rob_backlog"]
        return (
            f"backend/commit conversion: commit/rename {commit_per_rename:.3f}x, "
            f"commit<4 with ROB backlog {value} cycles ({pct(value, cycles):.1f}%)."
        )
    if commit_per_issue < 0.90:
        return f"commit trails issue: commit/issue {commit_per_issue:.3f}x."
    value = indicators["rename_under_width"]
    return f"mixed width loss: rename<4 {value} cycles ({pct(value, cycles):.1f}%)."


def analyze_boom(label: str, path: Path) -> dict[str, Any]:
    stats: dict[str, Any] = {}
    with path.open(errors="replace") as f:
        for line in f:
            m = BOOM_RE.match(line)
            if m:
                rec = parse_kv_body(m.group("body"))
                if "cycles" in rec:
                    stats = rec

    cycles = int(stats.get("cycles", 0))
    stage_summary: dict[str, dict[str, Any]] = {}

    for stage, prefix, total_key in [
        ("decode", "decode_fire_hist", "decode_fire_uops"),
        ("dispatch", "dispatch_fire_hist", "dispatch_fire_uops"),
        ("commit", "retire_hist", "retired"),
    ]:
        width = BOOM_WIDTHS[stage]
        hist = Counter({i: int(stats.get(f"{prefix}_{i}", 0)) for i in range(width + 1)})
        total = int(stats.get(total_key, 0))
        stage_summary[stage] = {
            "width": width,
            "avg": avg(total, cycles),
            "util_pct": pct(total, cycles * width),
            "zero_cycles": hist_value(hist, 0),
            "zero_pct": pct(hist_value(hist, 0), cycles),
            "full_cycles": hist_value(hist, width),
            "full_pct": pct(hist_value(hist, width), cycles),
            "hist": dict(sorted(hist.items())),
        }

    indicators = {
        "fetch_backpressure_cycles": int(stats.get("fetch_backpressure_cycles", 0)),
        "decode_stall_cycles": int(stats.get("decode_stall_cycles", 0)),
        "dispatch_stall_cycles": int(stats.get("dispatch_stall_cycles", 0)),
        "rob_not_ready_cycles": int(stats.get("rob_not_ready_cycles", 0)),
        "ldq_full_cycles": int(stats.get("ldq_full_cycles", 0)),
        "stq_full_cycles": int(stats.get("stq_full_cycles", 0)),
        "branch_kill_cycles": int(stats.get("branch_kill_cycles", 0)),
    }

    return {
        "label": label,
        "core": "MegaBOOM",
        "path": str(path),
        "cycles": cycles,
        "retired": int(stats.get("retired", 0)),
        "raw_stats": stats,
        "stage_summary": stage_summary,
        "indicators": {k: {"cycles": v, "pct": pct(v, cycles)} for k, v in sorted(indicators.items())},
        "limiter": choose_boom_limiter(indicators, cycles),
    }


def choose_boom_limiter(indicators: dict[str, int], cycles: int) -> str:
    if cycles == 0:
        return "No BOOM_PIPE_STATS row found."
    name, value = max(indicators.items(), key=lambda item: item[1])
    return f"{name}: {value} cycles ({pct(value, cycles):.1f}%)."


def fmt_num(value: Any, digits: int = 3) -> str:
    if value is None:
        return "-"
    if isinstance(value, float):
        return f"{value:.{digits}f}"
    return str(value)


def stage_cell(result: dict[str, Any], stage: str) -> str:
    s = result["stage_summary"].get(stage)
    if not s:
        return "-"
    if stage == "issue_total" and "ge_commit_width_pct" in s:
        return f"{s['avg']:.3f} avg, {s['ge_commit_width_pct']:.1f}% >=4, {s['zero_pct']:.1f}% zero"
    return f"{s['avg']:.3f} avg, {s['full_pct']:.1f}% full, {s['zero_pct']:.1f}% zero"


def result_retired(result: dict[str, Any]) -> str:
    if result["core"] == "rv64gc-v2":
        bench = result.get("bench_result", {})
        if "instret" in bench:
            return str(bench["instret"])
        return "-"
    return str(result.get("retired", "-"))


def render_markdown(results: list[dict[str, Any]]) -> str:
    lines: list[str] = []
    lines.append("# Pipeline Width DSE Summary")
    lines.append("")
    lines.append("| Workload | Core | Cycles | Retired | Fetch | Decode | Rename | Dispatch | Issue total | Commit | Limiter read |")
    lines.append("|---|---|---:|---:|---|---|---|---|---|---|---|")
    for r in results:
        issue = stage_cell(r, "issue_total")
        if r["core"] == "MegaBOOM":
            issue = "-"
        lines.append(
            "| {label} | {core} | {cycles} | {retired} | {fetch} | {decode} | {rename} | {dispatch} | {issue} | {commit} | {limiter} |".format(
                label=r["label"],
                core=r["core"],
                cycles=r.get("cycles", "-"),
                retired=result_retired(r),
                fetch=stage_cell(r, "fetch"),
                decode=stage_cell(r, "decode"),
                rename=stage_cell(r, "rename"),
                dispatch=stage_cell(r, "dispatch"),
                issue=issue,
                commit=stage_cell(r, "commit"),
                limiter=r["limiter"],
            )
        )
    lines.append("")

    rv_results = [r for r in results if r["core"] == "rv64gc-v2"]
    if rv_results:
        lines.append("## rv64gc-v2 Bottleneck Indicators")
        lines.append("")
        lines.append("| Workload | Fetch<4 | Rename<4 | Dispatch<rename | Commit<4 with ROB backlog | Issue>=4 while commit<4 | Flush/replay |")
        lines.append("|---|---:|---:|---:|---:|---:|---:|")
        for r in rv_results:
            ind = r["indicators"]

            def c(key: str) -> str:
                x = ind.get(key, {"cycles": 0, "pct": 0.0})
                return f"{x['cycles']} ({x['pct']:.1f}%)"

            flush = ind.get("flush_cycles", {"cycles": 0, "pct": 0.0})
            replay = ind.get("replay_cycles", {"cycles": 0, "pct": 0.0})
            flush_replay_cycles = flush["cycles"] + replay["cycles"]
            flush_replay_pct = pct(flush_replay_cycles, r["cycles"])
            lines.append(
                f"| {r['label']} | {c('fetch_under_width')} | {c('rename_under_width')} | "
                f"{c('dispatch_less_than_rename')} | {c('commit_under_width_with_rob_backlog')} | "
                f"{c('issue_ge4_while_commit_under_width')} | {flush_replay_cycles} ({flush_replay_pct:.1f}%) |"
            )
        lines.append("")

    boom_results = [r for r in results if r["core"] == "MegaBOOM"]
    if boom_results:
        lines.append("## MegaBOOM Bottleneck Indicators")
        lines.append("")
        lines.append("| Workload | Fetch backpressure | Decode stall | Dispatch stall | ROB not ready | LDQ full | Branch kill |")
        lines.append("|---|---:|---:|---:|---:|---:|---:|")
        for r in boom_results:
            ind = r["indicators"]

            def c(key: str) -> str:
                x = ind.get(key, {"cycles": 0, "pct": 0.0})
                return f"{x['cycles']} ({x['pct']:.1f}%)"

            lines.append(
                f"| {r['label']} | {c('fetch_backpressure_cycles')} | {c('decode_stall_cycles')} | "
                f"{c('dispatch_stall_cycles')} | {c('rob_not_ready_cycles')} | "
                f"{c('ldq_full_cycles')} | {c('branch_kill_cycles')} |"
            )
        lines.append("")

    lines.append("## Notes")
    lines.append("")
    lines.append("- rv64gc-v2 issue total is integer issue plus load, store-address, and store-data issue pipes when `pipe.v2` is present.")
    lines.append("- BOOM stats expose decode, dispatch, and retire histograms, but not a comparable per-cycle issue histogram in the current hook.")
    lines.append("- rv64gc-v2 pipeline counts are uop counts; benchmark endpoint retired counts remain the architectural source of truth for signoff.")
    lines.append("")
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rv64", action="append", help="rv64gc-v2 LABEL=LOG with +TRACE_PIPELINE output")
    parser.add_argument("--boom", action="append", help="MegaBOOM LABEL=LOG with BOOM_PIPE_STATS output")
    parser.add_argument("--json-out")
    parser.add_argument("--markdown-out")
    args = parser.parse_args()

    results: list[dict[str, Any]] = []
    for label, path in parse_label_path(args.rv64):
        results.append(analyze_rv64(label, path))
    for label, path in parse_label_path(args.boom):
        results.append(analyze_boom(label, path))

    payload = {"results": results}
    if args.json_out:
        Path(args.json_out).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    markdown = render_markdown(results)
    if args.markdown_out:
        Path(args.markdown_out).write_text(markdown)
    else:
        print(markdown)


if __name__ == "__main__":
    main()

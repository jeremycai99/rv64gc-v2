#!/usr/bin/env python3
"""Run the Stage 3 DS/CM regression gate after any RTL change.

Stage 3 Linux bring-up is allowed to change the simulation platform and later
the privileged-memory core path, but each RTL slice must preserve the committed
Dhrystone and CoreMark baseline. This wrapper keeps that contract in one place.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
MANIFEST = REPO_ROOT / "tests" / "benchmarks" / "stage1_signoff.json"
DHRYSTONE_VAX_DHRYSTONES_PER_SEC = 1757.0

BENCHES = [
    "dhrystone_100_checkedin",
    "dhrystone_300_stage1_anchor",
    "coremark_iter1_generalization",
    "coremark_iter10_checkedin",
]

BASELINE = {
    "dhrystone_100_checkedin": {
        "timed_cycles": 18161,
        "metric_key": "dmips_per_mhz",
        "metric_min": 3.133924,
    },
    "dhrystone_300_stage1_anchor": {
        "timed_cycles": 53469,
        "metric_key": "dmips_per_mhz",
        "metric_min": 3.193357,
    },
    "coremark_iter1_generalization": {
        "timed_cycles": 154233,
        "metric_key": "coremark_per_mhz",
        "metric_min": 6.483697,
    },
    "coremark_iter10_checkedin": {
        "timed_cycles": 1491334,
        "metric_key": "coremark_per_mhz",
        "metric_min": 6.705406,
    },
}

REQUIRED_PLUSARGS = [
    "+FETCH_DELIVERY_CHECK",
    "+FETCH_DELIVERY_STRICT",
    "+FETCH_OWNER_CHECK",
    "+FETCH_OWNER_STRICT",
    "+BRANCH_RECOVERY_CHECK",
    "+BRANCH_RECOVERY_STRICT",
    "+PERF_PROFILE",
    "+PERF_COUNTERS",
    "+STAT_DUMP",
    "+BOTTLENECK_PROFILE",
]

ZERO_COUNTERS = [
    "xs_f2_owner_no_head",
    "xs_f2_owner_idx_mismatch",
    "xs_f2_owner_epoch_mismatch",
    "xs_f2_owner_tag_mismatch",
    "xs_packet_stale_idx_mismatch",
    "xs_packet_stale_epoch_mismatch",
    "xs_packet_stale_tag_mismatch",
    "xs_delivery_owner_switch",
    "xs_delivery_noncontig_pcs",
]


def run_cmd(cmd: list[str], cwd: Path, dry_run: bool) -> None:
    print("+ " + " ".join(cmd))
    if dry_run:
        return
    subprocess.run(cmd, cwd=cwd, check=True)


def result_metric(row: dict[str, Any], key: str) -> float | None:
    metrics = row.get("metrics", {})
    if key in metrics:
        return float(metrics[key])
    if key == "dmips_per_mhz" and "dhrystones_per_mhz" in metrics:
        return float(metrics["dhrystones_per_mhz"]) / DHRYSTONE_VAX_DHRYSTONES_PER_SEC
    return None


def load_results(path: Path) -> list[dict[str, Any]]:
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict) and isinstance(payload.get("results"), list):
        return payload["results"]
    raise ValueError(f"unexpected results format: {path}")


def evaluate_results(results_path: Path) -> int:
    rows = {str(row.get("name")): row for row in load_results(results_path)}
    failures: list[str] = []

    print("\nStage 3 RTL guard summary:")
    print("benchmark                         cycles      limit       metric")
    for bench in BENCHES:
        if bench not in rows:
            failures.append(f"{bench}: missing from results")
            continue
        row = rows[bench]
        expected = BASELINE[bench]
        metrics = row.get("metrics", {})
        counters = row.get("perf_counters", {})
        cycles = metrics.get("timed_cycles")
        metric = result_metric(row, str(expected["metric_key"]))
        metric_limit = float(expected["metric_min"])
        cycle_limit = int(expected["timed_cycles"])

        print(
            f"{bench:<33} {str(cycles):>10} {cycle_limit:>10} "
            f"{metric if metric is not None else 'missing'}"
        )

        if row.get("status") != "PASS":
            failures.append(f"{bench}: status={row.get('status')}")
        if row.get("gate_status") not in ("PASS", "DSE_ONLY", None):
            failures.append(f"{bench}: gate_status={row.get('gate_status')}")
        if cycles is None:
            failures.append(f"{bench}: missing timed_cycles")
        elif int(cycles) > cycle_limit:
            failures.append(f"{bench}: timed_cycles {cycles} > {cycle_limit}")
        if metric is None:
            failures.append(f"{bench}: missing {expected['metric_key']}")
        elif metric + 1e-6 < metric_limit:
            failures.append(
                f"{bench}: {expected['metric_key']} {metric:.6f} < {metric_limit:.6f}"
            )
        if row.get("loop_buffer_active") not in (None, 0):
            failures.append(f"{bench}: loop_buffer_active={row.get('loop_buffer_active')}")
        if row.get("decoded_op_active") not in (None, 0):
            failures.append(f"{bench}: decoded_op_active={row.get('decoded_op_active')}")
        for counter in ZERO_COUNTERS:
            value = counters.get(counter)
            if value not in (None, 0):
                failures.append(f"{bench}: {counter}={value}")

    if failures:
        print("\nFAIL:")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("\nPASS: DS/CM baseline preserved for Stage 3 RTL work.")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--runner",
        choices=("dsim", "xsim-sh", "xsim-bat"),
        default="dsim",
        help="Simulation runner passed to tools/run_benchmarks.py.",
    )
    parser.add_argument(
        "--run-dir",
        type=Path,
        default=None,
        help="Output directory. Defaults to benchmark_results/stage3_rtl_guard_<timestamp>.",
    )
    parser.add_argument(
        "--run-id",
        default=None,
        help="Stable suffix used when --run-dir is not supplied.",
    )
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument(
        "--evaluate-only",
        action="store_true",
        help="Only evaluate an existing --run-dir/results.json artifact.",
    )
    args = parser.parse_args(argv)

    if args.run_dir is None:
        suffix = args.run_id or datetime.now().strftime("%Y%m%d_%H%M%S")
        run_dir = REPO_ROOT / "benchmark_results" / f"stage3_rtl_guard_{suffix}"
    else:
        run_dir = args.run_dir
        if not run_dir.is_absolute():
            run_dir = REPO_ROOT / run_dir

    if args.evaluate_only:
        return evaluate_results(run_dir / "results.json")

    if not args.skip_build:
        build_script = "./build_dsim.sh" if args.runner == "dsim" else "./build_xsim.sh"
        run_cmd([build_script], REPO_ROOT, args.dry_run)

    bench_cmd = [
        sys.executable,
        "tools/run_benchmarks.py",
        "--runner",
        args.runner,
        "--run-class",
        "dse",
        "--manifest",
        str(MANIFEST.relative_to(REPO_ROOT)),
        "--mechanism-name",
        "stage3_linux_rtl_guard",
        "--mechanism-class",
        "default_rtl",
        "--run-dir",
        str(run_dir),
    ]
    for bench in BENCHES:
        bench_cmd.extend(["--bench", bench])
    for plusarg in REQUIRED_PLUSARGS:
        bench_cmd.extend(["--plusarg", plusarg])

    run_cmd(bench_cmd, REPO_ROOT, args.dry_run)
    if args.dry_run:
        return 0

    return evaluate_results(run_dir / "results.json")


if __name__ == "__main__":
    raise SystemExit(main())

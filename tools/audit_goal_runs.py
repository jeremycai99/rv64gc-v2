#!/usr/bin/env python3
"""Audit benchmark result directories for Stage 1 goal-run drift."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RESULTS_ROOT = REPO_ROOT / "benchmark_results"
STAGE1_MANIFEST = REPO_ROOT / "tests" / "benchmarks" / "stage1_signoff.json"
STAGE1_CONTRACT_VERSION = "stage1-2026-05-06-v1"
STAGE1_REQUIRED_PLUSARGS = {
    "FETCH_DELIVERY_CHECK",
    "FETCH_DELIVERY_STRICT",
    "FETCH_OWNER_CHECK",
    "FETCH_OWNER_STRICT",
    "PERF_PROFILE",
    "PERF_COUNTERS",
    "STAT_DUMP",
}


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def plusarg_name(value: str) -> str:
    return value.lstrip("+").split("=", 1)[0]


def result_gate_summary(run_dir: Path) -> tuple[int, int, list[str]]:
    results_path = run_dir / "results.json"
    if not results_path.exists():
        return 0, 0, ["results.json=missing"]
    rows = load_json(results_path)
    if isinstance(rows, dict):
        rows = rows.get("results", [])
    total = len(rows)
    passed = sum(1 for row in rows if row.get("gate_status") == "PASS")
    reasons: list[str] = []
    for row in rows:
        if row.get("gate_status") != "PASS":
            name = row.get("name", "?")
            gate = row.get("gate_status", "?")
            reasons.append(f"{name}:{gate}")
    return passed, total, reasons


def manifest_matches_stage1(manifest: dict[str, Any]) -> tuple[bool, str]:
    provenance = manifest.get("manifest_provenance")
    if isinstance(provenance, list) and provenance:
        paths = [Path(item.get("path", "")).resolve() for item in provenance]
        if paths != [STAGE1_MANIFEST.resolve()]:
            return False, "manifest_provenance_path_mismatch"
        contract = provenance[0].get("goal_contract") or {}
        if contract.get("name") != "stage1":
            return False, "manifest_goal_contract_name_mismatch"
        if contract.get("version") != STAGE1_CONTRACT_VERSION:
            return False, "manifest_goal_contract_version_mismatch"
        return True, "ok"

    benches = manifest.get("benchmarks") or []
    paths = {Path(row.get("_manifest", "")).resolve() for row in benches}
    if paths == {STAGE1_MANIFEST.resolve()}:
        return False, "legacy_stage1_manifest_without_goal_provenance"
    return False, "manifest_not_stage1"


def classify_run(run_dir: Path) -> dict[str, Any]:
    manifest_path = run_dir / "run_manifest.json"
    if not manifest_path.exists():
        return {
            "run_dir": str(run_dir),
            "class": "NO_RUN_MANIFEST",
            "reason": "run_manifest.json=missing",
        }

    manifest = load_json(manifest_path)
    goal = manifest.get("goal")
    run_class = manifest.get("run_class")
    plusargs = {
        plusarg_name(str(item))
        for item in (manifest.get("global_plusargs") or manifest.get("plusargs") or [])
    }
    missing_plusargs = sorted(STAGE1_REQUIRED_PLUSARGS - plusargs)
    gate_passed, gate_total, gate_reasons = result_gate_summary(run_dir)

    if goal == "stage1":
        ok_manifest, manifest_reason = manifest_matches_stage1(manifest)
        failures = []
        if run_class != "signoff":
            failures.append(f"run_class={run_class}")
        if not ok_manifest:
            failures.append(manifest_reason)
        if missing_plusargs:
            failures.append("missing_plusargs=" + ",".join(missing_plusargs))
        if gate_total == 0 or gate_passed != gate_total:
            failures.extend(gate_reasons or ["no_passing_gate_results"])
        return {
            "run_dir": str(run_dir),
            "created_at": manifest.get("created_at", "-"),
            "class": "GOAL_PASS" if not failures else "GOAL_FAIL",
            "reason": "; ".join(failures) if failures else "ok",
            "goal": goal,
            "run_class": run_class,
            "gate": f"{gate_passed}/{gate_total}",
        }

    if run_class == "dse":
        return {
            "run_dir": str(run_dir),
            "created_at": manifest.get("created_at", "-"),
            "class": "DSE_SMOKE_ONLY",
            "reason": "not scoreable; rerun with --goal stage1 for goal evidence",
            "goal": goal or "-",
            "run_class": run_class,
            "gate": f"{gate_passed}/{gate_total}",
        }

    if run_class == "signoff":
        return {
            "run_dir": str(run_dir),
            "created_at": manifest.get("created_at", "-"),
            "class": "SIGNOFF_WITHOUT_GOAL",
            "reason": "legacy/non-goal signoff; not Stage 1 goal evidence",
            "goal": goal or "-",
            "run_class": run_class,
            "gate": f"{gate_passed}/{gate_total}",
        }

    return {
        "run_dir": str(run_dir),
        "created_at": manifest.get("created_at", "-"),
        "class": "NON_GOAL_ARTIFACT",
        "reason": f"run_class={run_class}",
        "goal": goal or "-",
        "run_class": run_class or "-",
        "gate": f"{gate_passed}/{gate_total}",
    }


def iter_run_dirs(root: Path) -> list[Path]:
    if not root.exists():
        return []
    return sorted(
        [path for path in root.iterdir() if path.is_dir()],
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )


def render_markdown(rows: list[dict[str, Any]]) -> str:
    out = [
        "| Run | Created | Class | Goal | Run class | Gate | Reason |",
        "|---|---|---|---|---|---:|---|",
    ]
    for row in rows:
        out.append(
            "| "
            + " | ".join(
                [
                    f"`{Path(row['run_dir']).name}`",
                    str(row.get("created_at", "-")),
                    str(row.get("class", "-")),
                    str(row.get("goal", "-")),
                    str(row.get("run_class", "-")),
                    str(row.get("gate", "-")),
                    str(row.get("reason", "-")),
                ]
            )
            + " |"
        )
    return "\n".join(out)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=DEFAULT_RESULTS_ROOT)
    parser.add_argument("--limit", type=int, default=12)
    parser.add_argument("--json", action="store_true")
    parser.add_argument(
        "--fail-on-latest-drift",
        action="store_true",
        help="Return nonzero unless the latest run is GOAL_PASS.",
    )
    args = parser.parse_args()

    rows = [classify_run(path) for path in iter_run_dirs(args.root)[: args.limit]]
    if args.json:
        print(json.dumps(rows, indent=2))
    else:
        print(render_markdown(rows))

    if args.fail_on_latest_drift and (not rows or rows[0].get("class") != "GOAL_PASS"):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

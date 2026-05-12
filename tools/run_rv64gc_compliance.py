#!/usr/bin/env python3
"""Build and run the RV64GC riscv-tests compliance gate.

This runner keeps the standard riscv-tests tohost convention at the simulator
platform boundary. It does not require, add, or assume any synthesizable core
tohost port.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from collections import defaultdict
from datetime import date, datetime
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RISCV_TESTS_ISA = (
    REPO_ROOT.parent / "rv64gc-v1" / "tests" / "riscv-tests" / "isa"
)
DEFAULT_BUILD_ROOT = REPO_ROOT / "build" / "rv64gc_compliance"
DEFAULT_RESULTS_ROOT = REPO_ROOT / "benchmark_results"
DEFAULT_REPORT = REPO_ROOT / "doc" / "rv64gc_compliance_audit_2026-05-12.md"

INSTRUCTION_SUITES = {
    "rv64ui": {
        "extension": "RV64I",
        "kind": "rv64gc_rv64i",
        "max_cycles": 300_000,
        "required": True,
        "notes": "Base integer instruction compliance, including the rv64ui fence_i row for Zifencei.",
    },
    "rv64um": {
        "extension": "RV64M",
        "kind": "rv64gc_rv64m",
        "max_cycles": 600_000,
        "required": True,
        "notes": "Integer multiply and divide instruction compliance.",
    },
    "rv64ua": {
        "extension": "RV64A",
        "kind": "rv64gc_rv64a",
        "max_cycles": 800_000,
        "required": True,
        "notes": "Atomic memory operation and LR/SC compliance.",
    },
    "rv64uc": {
        "extension": "RV64C",
        "kind": "rv64gc_rv64c",
        "max_cycles": 500_000,
        "required": True,
        "notes": "Compressed instruction compliance.",
    },
    "rv64uf": {
        "extension": "RV64F",
        "kind": "rv64gc_rv64f",
        "max_cycles": 1_500_000,
        "required": True,
        "notes": "Single precision floating point compliance.",
    },
    "rv64ud": {
        "extension": "RV64D",
        "kind": "rv64gc_rv64d",
        "max_cycles": 1_500_000,
        "required": True,
        "notes": "Double precision floating point compliance.",
    },
}

SUPPLEMENTAL_TESTS = [
    {
        "suite": "rv64mi",
        "test": "csr",
        "extension": "Zicsr",
        "kind": "rv64gc_zicsr",
        "max_cycles": 500_000,
        "required": True,
        "notes": "Machine-mode CSR instruction smoke from riscv-tests.",
    },
    {
        "suite": "rv64mi",
        "test": "mcsr",
        "extension": "Zicsr",
        "kind": "rv64gc_zicsr",
        "max_cycles": 500_000,
        "required": True,
        "notes": "Machine CSR access and WARL behavior smoke from riscv-tests.",
    },
    {
        "suite": "rv64mi",
        "test": "zicntr",
        "extension": "Zicsr",
        "kind": "rv64gc_zicsr",
        "max_cycles": 500_000,
        "required": True,
        "notes": "Counter CSR read smoke from riscv-tests.",
    },
]


def rel(path: Path) -> str:
    try:
        return path.resolve().relative_to(REPO_ROOT.resolve()).as_posix()
    except ValueError:
        return path.resolve().as_posix()


def run(cmd: list[str], cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    print("+ " + " ".join(str(x) for x in cmd), flush=True)
    proc = subprocess.Popen(
        cmd,
        cwd=cwd or REPO_ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    assert proc.stdout is not None
    lines: list[str] = []
    for line in proc.stdout:
        print(line, end="", flush=True)
        lines.append(line)
    returncode = proc.wait()
    return subprocess.CompletedProcess(cmd, returncode, "".join(lines), None)


def must_run(cmd: list[str], cwd: Path | None = None) -> str:
    completed = run(cmd, cwd)
    if completed.returncode != 0:
        sys.stderr.write(completed.stdout)
        raise SystemExit(completed.returncode)
    return completed.stdout


def discover_instruction_tests(isa_dir: Path) -> list[dict[str, Any]]:
    tests: list[dict[str, Any]] = []
    for suite, info in INSTRUCTION_SUITES.items():
        suite_dir = isa_dir / suite
        if not suite_dir.exists():
            raise FileNotFoundError(f"missing riscv-tests suite directory: {suite_dir}")
        for source in sorted(suite_dir.glob("*.S")):
            target = f"{suite}-p-{source.stem}"
            tests.append(
                {
                    "target": target,
                    "suite": suite,
                    "source": source,
                    "extension": info["extension"],
                    "kind": info["kind"],
                    "max_cycles": info["max_cycles"],
                    "required": info["required"],
                    "notes": info["notes"],
                }
            )

    for item in SUPPLEMENTAL_TESTS:
        suite = item["suite"]
        source = isa_dir / suite / f"{item['test']}.S"
        if not source.exists():
            raise FileNotFoundError(f"missing riscv-tests supplemental source: {source}")
        tests.append(
            {
                "target": f"{suite}-p-{item['test']}",
                "suite": suite,
                "source": source,
                "extension": item["extension"],
                "kind": item["kind"],
                "max_cycles": item["max_cycles"],
                "required": item["required"],
                "notes": item["notes"],
            }
        )
    return tests


def build_riscv_tests(
    tests: list[dict[str, Any]],
    isa_dir: Path,
    prefix: str,
    build_root: Path,
    force: bool,
) -> Path:
    elf_dir = build_root / "elf"
    hex_dir = build_root / "hex"
    elf_dir.mkdir(parents=True, exist_ok=True)
    hex_dir.mkdir(parents=True, exist_ok=True)

    env_p = isa_dir.parent / "env" / "p"
    macros = isa_dir / "macros" / "scalar"
    link_ld = env_p / "link.ld"
    for required in (env_p / "riscv_test.h", macros / "test_macros.h", link_ld):
        if not required.exists():
            raise FileNotFoundError(f"missing riscv-tests build input: {required}")

    manifest_entries = []
    for test in tests:
        target = test["target"]
        local_elf = elf_dir / f"{target}.elf"
        local_hex = hex_dir / f"{target}.hex"
        if force or not local_elf.exists():
            must_run(
                [
                    f"{prefix}gcc",
                    "-march=rv64g",
                    "-mabi=lp64d",
                    "-static",
                    "-mcmodel=medany",
                    "-fvisibility=hidden",
                    "-nostdlib",
                    "-nostartfiles",
                    f"-I{env_p}",
                    f"-I{macros}",
                    "-T",
                    str(link_ld),
                    str(test["source"]),
                    "-o",
                    str(local_elf),
                ]
            )
        if force or not local_hex.exists():
            must_run(
                [
                    sys.executable,
                    str(REPO_ROOT / "scripts" / "elf2hex.py"),
                    str(local_elf),
                    str(local_hex),
                    "--base",
                    "0x80000000",
                    "--objcopy",
                    f"{prefix}objcopy",
                    "--objdump",
                    f"{prefix}objdump",
                ]
            )

        manifest_entries.append(
            {
                "name": target.replace("-", "_"),
                "kind": test["kind"],
                "suite": test["suite"],
                "extension": test["extension"],
                "required_for_rv64gc": bool(test["required"]),
                "hex": rel(local_hex),
                "elf": rel(local_elf),
                "max_cycles": int(test["max_cycles"]),
                "require_stop": False,
                "notes": test["notes"],
            }
        )

    manifest = {
        "notes": (
            "Generated RV64GC compliance manifest from standard riscv-tests. "
            "The tohost endpoint is observed by the v2 simulation platform only."
        ),
        "source": str(isa_dir.resolve()),
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "benchmarks": manifest_entries,
    }
    manifest_path = build_root / "rv64gc_compliance_manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest_path


def run_compliance(
    manifest: Path,
    runner: str,
    run_dir: Path,
    build_sim: bool,
    plusargs: list[str],
    iter_limit: int,
) -> int:
    if build_sim:
        if runner == "dsim":
            completed = run([str(REPO_ROOT / "build_dsim.sh")])
        elif runner == "xsim-sh":
            completed = run([str(REPO_ROOT / "build_xsim.sh")])
        else:
            raise ValueError(f"unsupported runner for build: {runner}")
        if completed.returncode != 0:
            sys.stderr.write(completed.stdout)
            return completed.returncode

    cmd = [
        sys.executable,
        str(REPO_ROOT / "tools" / "run_benchmarks.py"),
        "--runner",
        runner,
        "--run-class",
        "signoff",
        "--manifest",
        str(manifest),
        "--run-dir",
        str(run_dir),
        "--iter-limit",
        str(iter_limit),
        "--no-perf-summary",
    ]
    for plusarg in plusargs:
        cmd.extend(["--plusarg", plusarg])
    completed = run(cmd)
    (run_dir / "runner_stdout.log").write_text(
        completed.stdout or "", encoding="utf-8"
    )
    return completed.returncode


def load_manifest_by_name(manifest: Path) -> dict[str, dict[str, Any]]:
    data = json.loads(manifest.read_text(encoding="utf-8"))
    return {entry["name"]: entry for entry in data["benchmarks"]}


def load_results(run_dir: Path) -> list[dict[str, Any]]:
    results_path = run_dir / "results.json"
    if not results_path.exists():
        return []
    return json.loads(results_path.read_text(encoding="utf-8"))


def summarize_results(
    manifest: Path,
    run_dir: Path,
) -> dict[str, Any]:
    manifest_by_name = load_manifest_by_name(manifest)
    results = load_results(run_dir)
    extension_totals: dict[str, dict[str, int]] = defaultdict(
        lambda: {"total": 0, "pass": 0, "fail": 0}
    )
    failures: list[dict[str, Any]] = []

    for result in results:
        entry = manifest_by_name.get(result["name"], {})
        ext = entry.get("extension", "unknown")
        total = extension_totals[ext]
        total["total"] += 1
        passed = result.get("status") == "PASS" and result.get("gate_status") == "PASS"
        if passed:
            total["pass"] += 1
        else:
            total["fail"] += 1
            failures.append(
                {
                    "name": result.get("name"),
                    "extension": ext,
                    "status": result.get("status"),
                    "gate_status": result.get("gate_status"),
                    "tohost": result.get("tohost"),
                    "cycle": result.get("cycle"),
                    "gate_reasons": result.get("gate_reasons", []),
                    "row_dir": result.get("row_dir"),
                }
            )

    manifest_count = len(manifest_by_name)
    result_count = len(results)
    missing = sorted(set(manifest_by_name) - {result["name"] for result in results})
    all_pass = result_count == manifest_count and not failures
    return {
        "manifest": str(manifest),
        "run_dir": str(run_dir),
        "manifest_count": manifest_count,
        "result_count": result_count,
        "missing_results": missing,
        "extension_totals": dict(sorted(extension_totals.items())),
        "failures": failures,
        "all_pass": all_pass,
    }


def git_snapshot() -> dict[str, str]:
    def git(args: list[str]) -> str:
        completed = subprocess.run(
            ["git", *args],
            cwd=REPO_ROOT,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        return completed.stdout.strip()

    return {
        "head": git(["rev-parse", "HEAD"]),
        "head_short": git(["rev-parse", "--short", "HEAD"]),
        "status_short": git(["status", "--short"]),
    }


def write_audit_report(summary: dict[str, Any], report_path: Path) -> None:
    git_info = git_snapshot()
    verdict = (
        "PASS, eligible to claim RV64GC instruction compliance for the covered standard riscv-tests rows"
        if summary["all_pass"]
        else "FAIL, not yet eligible to claim full RV64GC instruction compliance"
    )

    lines = [
        "# RV64GC Compliance Audit",
        "",
        f"Date: {date.today().isoformat()}",
        f"Commit: `{git_info['head_short']}`",
        "",
        f"Verdict: **{verdict}**.",
        "",
        "Scope:",
        "",
        "- Required instruction suites: `rv64ui`, `rv64um`, `rv64ua`, `rv64uc`, `rv64uf`, and `rv64ud` from standard riscv-tests.",
        "- Required extension checks: `Zifencei` through `rv64ui-p-fence_i`; `Zicsr` through `rv64mi-p-csr`, `rv64mi-p-mcsr`, and `rv64mi-p-zicntr`.",
        "- Endpoint policy: riscv-tests `tohost/fromhost` is observed only by the simulation platform/testbench. No synthesizable core `tohost` port is part of this claim.",
        "- Exclusions from this RV64GC instruction claim: optional bitmanip/Zicond rows, Linux boot, full privileged architecture compliance, multi-hart behavior, external interrupts, and platform devices.",
        "",
        "Artifacts:",
        "",
        f"- Manifest: `{summary['manifest']}`",
        f"- Results directory: `{summary['run_dir']}`",
        f"- Result count: `{summary['result_count']}` of `{summary['manifest_count']}` manifest rows",
        "",
        "Extension Summary:",
        "",
        "| Extension | Pass | Fail | Total |",
        "| --- | ---: | ---: | ---: |",
    ]

    for ext, counts in summary["extension_totals"].items():
        lines.append(
            f"| {ext} | {counts['pass']} | {counts['fail']} | {counts['total']} |"
        )

    if summary["missing_results"]:
        lines.extend(["", "Missing result rows:", ""])
        for name in summary["missing_results"]:
            lines.append(f"- `{name}`")

    if summary["failures"]:
        lines.extend(["", "Failures:", ""])
        lines.append("| Test | Extension | Status | Gate | Tohost | Cycle | Reason |")
        lines.append("| --- | --- | --- | --- | ---: | ---: | --- |")
        for failure in summary["failures"]:
            reasons = "; ".join(failure.get("gate_reasons") or []) or "-"
            lines.append(
                "| "
                + " | ".join(
                    [
                        f"`{failure['name']}`",
                        str(failure["extension"]),
                        str(failure["status"]),
                        str(failure["gate_status"]),
                        str(failure["tohost"]),
                        str(failure["cycle"]),
                        reasons,
                    ]
                )
                + " |"
            )

    lines.extend(
        [
            "",
            "Claim Rule:",
            "",
            "- `PASS` requires every required row to finish with `tohost=1` and a `PASS` signoff gate.",
            "- Any required row with `FAIL`, `TIMEOUT`, non-one `tohost`, missing result, or signoff gate reason blocks the RV64GC compliance claim.",
            "- After any RTL fix, rerun the failing subset first, then rerun the full compliance gate and the Stage 3 DS/CM hard gate before resuming Linux boot.",
            "",
            "Current Status:",
            "",
        ]
    )
    if summary["all_pass"]:
        lines.append(
            "All required instruction-compliance rows passed in this run. The core is eligible to claim RV64GC instruction compliance for the covered standard riscv-tests scope, while privileged/Linux/platform signoff remains separate."
        )
    else:
        lines.append(
            "The full compliance gate is not closed. Do not claim RV64GC instruction compliance until every listed failure is fixed or explicitly removed as outside the required RV64GC scope."
        )

    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--riscv-tests-isa", type=Path, default=DEFAULT_RISCV_TESTS_ISA)
    parser.add_argument("--prefix", default="riscv64-unknown-elf-")
    parser.add_argument("--build-root", type=Path, default=DEFAULT_BUILD_ROOT)
    parser.add_argument("--runner", choices=("dsim", "xsim-sh"), default="dsim")
    parser.add_argument("--run-id", default=datetime.now().strftime("%Y%m%d_%H%M%S"))
    parser.add_argument("--run-dir", type=Path, default=None)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--iter-limit", type=int, default=10_000_000)
    parser.add_argument("--build-sim", action="store_true")
    parser.add_argument("--no-build-tests", action="store_true")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--plusarg", action="append", default=[])
    args = parser.parse_args(argv)

    isa_dir = args.riscv_tests_isa.resolve()
    if not isa_dir.exists():
        raise FileNotFoundError(f"riscv-tests isa directory not found: {isa_dir}")

    tests = discover_instruction_tests(isa_dir)
    build_root = args.build_root.resolve()
    manifest = build_root / "rv64gc_compliance_manifest.json"
    if not args.no_build_tests:
        manifest = build_riscv_tests(
            tests,
            isa_dir,
            args.prefix,
            build_root,
            args.force,
        )
    elif not manifest.exists():
        raise FileNotFoundError(f"missing generated manifest: {manifest}")

    run_dir = (
        args.run_dir.resolve()
        if args.run_dir is not None
        else DEFAULT_RESULTS_ROOT / f"rv64gc_compliance_{args.run_id}"
    )
    run_dir.mkdir(parents=True, exist_ok=True)

    rc = run_compliance(
        manifest,
        args.runner,
        run_dir,
        args.build_sim,
        args.plusarg,
        args.iter_limit,
    )
    summary = summarize_results(manifest, run_dir)
    write_audit_report(summary, args.report)
    (run_dir / "compliance_summary.json").write_text(
        json.dumps(summary, indent=2) + "\n", encoding="utf-8"
    )

    print(f"Audit report: {args.report}")
    print(f"Results: {run_dir}")
    if rc != 0:
        return rc
    return 0 if summary["all_pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

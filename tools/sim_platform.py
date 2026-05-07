#!/usr/bin/env python3
"""Prepare and run rv64gc-v2 simulator workloads behind a platform ABI layer.

This script keeps image loading and benchmark-exit conventions outside the CPU
RTL. It accepts a platform manifest, prepares a plain run_benchmarks manifest,
and delegates execution to tools/run_benchmarks.py.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = REPO_ROOT / "tests" / "sim_platform" / "stage1_broad.json"
DEFAULT_RUN_ROOT = REPO_ROOT / "benchmark_results" / "sim_platform"


def repo_path(path: str | Path) -> Path:
    p = Path(path)
    return p if p.is_absolute() else REPO_ROOT / p


def rel_path(path: Path) -> str:
    try:
        return path.resolve().relative_to(REPO_ROOT.resolve()).as_posix()
    except ValueError:
        return path.as_posix()


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def normalize_plusargs(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        return [str(item) for item in value]
    raise TypeError(f"plusargs must be a string or list, got {type(value).__name__}")


def plusarg_name(arg: str) -> str:
    return arg.lstrip("+").split("=", 1)[0]


def plusarg_has(args: list[str], name: str) -> bool:
    return any(plusarg_name(arg) == name for arg in args)


def load_platform_manifest(path: Path) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    manifest_path = repo_path(path)
    data = load_json(manifest_path)
    platform = dict(data.get("platform") or {})
    rows: list[dict[str, Any]] = []

    for include in data.get("include_manifests", []):
        if isinstance(include, str):
            include_info = {"path": include}
        else:
            include_info = dict(include)
        include_path = repo_path(include_info["path"])
        include_data = load_json(include_path)
        for src in include_data.get("benchmarks", []):
            row = dict(src)
            row.setdefault("suite", include_info.get("suite", include_path.stem))
            if include_info.get("tags"):
                row_tags = list(row.get("tags", []))
                row_tags.extend(include_info["tags"])
                row["tags"] = row_tags
            row.setdefault("_source_manifest", rel_path(include_path))
            rows.append(row)

    for src in data.get("benchmarks", []):
        row = dict(src)
        row.setdefault("suite", data.get("suite", "platform"))
        row.setdefault("_source_manifest", rel_path(manifest_path))
        rows.append(row)

    return platform, rows


def selected_rows(rows: list[dict[str, Any]], args: argparse.Namespace) -> list[dict[str, Any]]:
    selected_names = {
        item.strip().lower()
        for value in args.bench
        for item in value.split(",")
        if item.strip()
    }
    selected_suites = set(args.suite)
    out = rows
    if selected_names:
        out = [row for row in out if str(row.get("name", "")).lower() in selected_names]
    if selected_suites:
        out = [row for row in out if str(row.get("suite", "")) in selected_suites]
    return out


def run_checked(cmd: list[str], cwd: Path = REPO_ROOT) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        cwd=cwd,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def read_elf_symbols(elf: Path, nm: str) -> dict[str, int]:
    if not elf.exists() or shutil.which(nm) is None:
        return {}
    completed = subprocess.run(
        [nm, "-n", str(elf)],
        cwd=REPO_ROOT,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    if completed.returncode != 0:
        return {}
    symbols: dict[str, int] = {}
    for line in completed.stdout.splitlines():
        parts = line.split()
        if len(parts) < 3:
            continue
        try:
            addr = int(parts[0], 16)
        except ValueError:
            continue
        symbols[parts[-1]] = addr
    return symbols


def prepare_image(
    row: dict[str, Any],
    image_dir: Path,
    platform: dict[str, Any],
    args: argparse.Namespace,
) -> tuple[str, dict[str, Any]]:
    image_format = row.get("image_format") or platform.get("default_image_format", "hex")
    base = int(str(row.get("dram_base", platform.get("dram_base", "0x80000000"))), 0)
    name = str(row["name"])
    meta: dict[str, Any] = {
        "image_format": image_format,
        "dram_base": f"0x{base:x}",
    }

    if row.get("hex") and not args.rebuild_images:
        hex_path = repo_path(row["hex"])
        meta["prepared_from"] = rel_path(hex_path)
        return rel_path(hex_path), meta

    image_dir.mkdir(parents=True, exist_ok=True)
    out_hex = image_dir / f"{name}.hex"

    if row.get("elf"):
        elf_path = repo_path(row["elf"])
        cmd = [
            sys.executable,
            str(REPO_ROOT / "scripts" / "elf2hex.py"),
            str(elf_path),
            str(out_hex),
            "--base",
            f"0x{base:x}",
            "--objcopy",
            args.objcopy,
            "--objdump",
            args.objdump,
        ]
        run_checked(cmd)
        meta["prepared_from"] = rel_path(elf_path)
        meta["prepared_command"] = " ".join(cmd)
        return rel_path(out_hex), meta

    binary_key = "bin" if row.get("bin") else "binary"
    if row.get(binary_key):
        bin_path = repo_path(row[binary_key])
        cmd = [
            sys.executable,
            str(REPO_ROOT / "scripts" / "elf2hex.py"),
            "--binary",
            str(bin_path),
            str(out_hex),
            "--base",
            f"0x{base:x}",
        ]
        run_checked(cmd)
        meta["prepared_from"] = rel_path(bin_path)
        meta["prepared_command"] = " ".join(cmd)
        return rel_path(out_hex), meta

    raise ValueError(f"{name}: row must provide hex, elf, bin, or binary")


def prepare_row(
    row: dict[str, Any],
    image_dir: Path,
    platform: dict[str, Any],
    args: argparse.Namespace,
) -> dict[str, Any]:
    prepared = dict(row)
    prepared["hex"], image_meta = prepare_image(row, image_dir, platform, args)
    prepared.setdefault("kind", "generic")

    abi = str(row.get("abi", platform.get("default_abi", "rv64gc-fixed-tohost")))
    prepared["_platform"] = {
        "abi": abi,
        "suite": prepared.get("suite"),
        "source_manifest": row.get("_source_manifest"),
        "image": image_meta,
    }

    plusargs = normalize_plusargs(row.get("plusargs"))
    if row.get("elf"):
        symbols = read_elf_symbols(repo_path(row["elf"]), args.nm)
        symbol_meta = {
            name: f"0x{value:x}"
            for name, value in symbols.items()
            if name in ("tohost", "fromhost", "_start", "main")
        }
        if symbol_meta:
            prepared["_platform"]["symbols"] = symbol_meta
        tohost = symbols.get("tohost")
        if tohost is not None and not plusarg_has(plusargs, "TOHOST_ADDR"):
            plusargs.append(f"TOHOST_ADDR={tohost:x}")

    if abi and not plusarg_has(plusargs, "SIM_ABI"):
        plusargs.append(f"SIM_ABI={abi}")
    if plusargs:
        prepared["plusargs"] = plusargs

    return prepared


def write_prepared_manifest(
    rows: list[dict[str, Any]],
    platform: dict[str, Any],
    run_root: Path,
) -> Path:
    run_root.mkdir(parents=True, exist_ok=True)
    manifest_path = run_root / "prepared_manifest.json"
    payload = {
        "created_at": datetime.now().isoformat(timespec="seconds"),
        "platform": platform,
        "benchmarks": rows,
    }
    manifest_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return manifest_path


def print_rows(rows: list[dict[str, Any]]) -> None:
    for row in rows:
        image = row.get("hex") or row.get("elf") or row.get("bin") or row.get("binary")
        print(
            f"{row['name']}: suite={row.get('suite', '-')} "
            f"kind={row.get('kind', 'generic')} image={image}"
        )


def runner_command(args: argparse.Namespace, manifest: Path, run_root: Path) -> list[str]:
    cmd = [
        sys.executable,
        str(REPO_ROOT / "tools" / "run_benchmarks.py"),
        "--manifest",
        str(manifest),
        "--runner",
        args.runner,
        "--run-class",
        args.run_class,
        "--run-dir",
        str(run_root / "runs"),
    ]
    for bench in args.bench:
        cmd.extend(["--bench", bench])
    for plusarg in args.plusarg:
        cmd.extend(["--plusarg", plusarg])
    if args.max_cycles is not None:
        cmd.extend(["--max-cycles", str(args.max_cycles)])
    if args.iter_limit is not None:
        cmd.extend(["--iter-limit", str(args.iter_limit)])
    if args.run_id:
        cmd.extend(["--run-id", args.run_id])
    if args.dry_run:
        cmd.append("--dry-run")
    if args.waves:
        cmd.append("--waves")
    if args.build_xsim:
        cmd.append("--build-xsim")
    if args.no_perf_summary:
        cmd.append("--no-perf-summary")
    if args.skip_rtl_lock_check:
        cmd.append("--skip-rtl-lock-check")
    return cmd


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--bench", action="append", default=[])
    parser.add_argument("--suite", action="append", default=[])
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument(
        "--runner",
        choices=("xsim-bat", "xsim-sh", "dsim"),
        default="dsim",
    )
    parser.add_argument(
        "--run-class",
        choices=("signoff", "dse", "debug"),
        default="dse",
    )
    parser.add_argument("--run-dir", type=Path, default=None)
    parser.add_argument("--run-id", default=None)
    parser.add_argument("--plusarg", action="append", default=[])
    parser.add_argument("--max-cycles", type=int, default=None)
    parser.add_argument("--iter-limit", type=int, default=10000000)
    parser.add_argument("--waves", action="store_true")
    parser.add_argument("--build-xsim", action="store_true")
    parser.add_argument("--no-perf-summary", action="store_true")
    parser.add_argument("--skip-rtl-lock-check", action="store_true")
    parser.add_argument("--rebuild-images", action="store_true")
    parser.add_argument("--objcopy", default="riscv64-unknown-elf-objcopy")
    parser.add_argument("--objdump", default="riscv64-unknown-elf-objdump")
    parser.add_argument("--nm", default="riscv64-unknown-elf-nm")
    args = parser.parse_args(argv)

    platform, rows = load_platform_manifest(args.manifest)
    rows = selected_rows(rows, args)

    if args.list:
        print_rows(rows)
        return 0
    if not rows:
        print("No platform rows selected", file=sys.stderr)
        return 2

    run_id = args.run_id or datetime.now().strftime("%Y%m%d_%H%M%S")
    run_root = repo_path(args.run_dir) if args.run_dir else DEFAULT_RUN_ROOT / run_id
    image_dir = run_root / "images"
    prepared_rows = [
        prepare_row(row, image_dir, platform, args)
        for row in rows
    ]
    prepared_manifest = write_prepared_manifest(prepared_rows, platform, run_root)
    print(f"Prepared manifest: {rel_path(prepared_manifest)}", flush=True)

    if args.prepare_only:
        return 0

    cmd = runner_command(args, prepared_manifest, run_root)
    print("Running:", " ".join(cmd), flush=True)
    completed = subprocess.run(cmd, cwd=REPO_ROOT, check=False)
    return completed.returncode


if __name__ == "__main__":
    raise SystemExit(main())

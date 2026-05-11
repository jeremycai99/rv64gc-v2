#!/usr/bin/env python3
"""Build and run the Stage 3 Linux boot simulation scaffold.

This runner intentionally terminates by platform-visible log milestones, not by
benchmark tohost. It is usable before the RTL platform exists for software image
builds, and it becomes the Linux regression runner once the platform sim image
is available.
"""

from __future__ import annotations

import argparse
import json
import shlex
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
FAIL_PATTERNS = [
    "Kernel panic",
    "Oops",
    "BUG:",
    "Illegal instruction",
    "trap loop",
    "fatal",
]


def run_cmd(cmd: list[str], cwd: Path, log_path: Path | None) -> int:
    print("+ " + " ".join(cmd))
    if log_path is None:
        return subprocess.run(cmd, cwd=cwd).returncode
    with log_path.open("w", encoding="utf-8") as log:
        proc = subprocess.run(
            cmd,
            cwd=cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        log.write(proc.stdout)
    return proc.returncode


def read_text(path: Path) -> str:
    if not path.exists():
        return ""
    return path.read_text(encoding="utf-8", errors="replace")


def summarize(run_dir: Path, payload: dict[str, Any]) -> None:
    run_dir.mkdir(parents=True, exist_ok=True)
    (run_dir / "summary.json").write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    md = [
        "# Stage 3 Linux Boot Run",
        "",
        f"- Status: `{payload['status']}`",
        f"- Image: `{payload.get('image', '')}`",
        f"- UART log: `{payload.get('uart_log', '')}`",
        f"- Simulator log: `{payload.get('sim_log', '')}`",
        f"- Reason: {payload.get('reason', '')}",
        "",
    ]
    (run_dir / "summary.md").write_text("\n".join(md), encoding="utf-8")


def classify_log(uart_text: str, sim_text: str, pass_pattern: str) -> tuple[str, str]:
    combined = uart_text + "\n" + sim_text
    if pass_pattern and pass_pattern in combined:
        return "PASS", f"matched pass pattern: {pass_pattern}"
    for pattern in FAIL_PATTERNS:
        if pattern in combined:
            return "FAIL", f"matched failure pattern: {pattern}"
    if "TIMEOUT" in combined:
        return "TIMEOUT", "simulator reported timeout"
    return "INCOMPLETE", "pass pattern not found"


def default_run_dir() -> Path:
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    return REPO_ROOT / "linux_boot_results" / f"stage3_{stamp}"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", action="store_true", help="Build software image first.")
    parser.add_argument("--build-sim", action="store_true", help="Build Stage 3 DSim platform image.")
    parser.add_argument("--run", action="store_true", help="Run the simulator image.")
    parser.add_argument(
        "--build-script",
        type=Path,
        default=REPO_ROOT / "sw" / "linux_boot" / "build_linux_boot.sh",
    )
    parser.add_argument(
        "--build-mode",
        choices=("smoke", "opensbi", "linux", "all"),
        default="smoke",
    )
    parser.add_argument(
        "--image",
        type=Path,
        default=None,
    )
    parser.add_argument(
        "--sim-image",
        type=Path,
        default=REPO_ROOT / "dsim_linux_work" / "tb_linux_image.so",
        help="Future Stage 3 DSim image. The current benchmark image remains separate.",
    )
    parser.add_argument(
        "--sim-work-dir",
        type=Path,
        default=REPO_ROOT / "dsim_linux_work",
        help="DSim work directory for the Stage 3 platform image.",
    )
    parser.add_argument("--sim-image-name", default="tb_linux_image")
    parser.add_argument(
        "--run-dir",
        type=Path,
        default=None,
        help="Output directory. Defaults to linux_boot_results/stage3_<timestamp>.",
    )
    parser.add_argument("--max-cycles", type=int, default=50_000_000)
    parser.add_argument("--pass-pattern", default=None)
    parser.add_argument("--smoke-check", action="store_true")
    parser.add_argument("--uart-log", type=Path, default=None)
    parser.add_argument(
        "--sim-plusarg",
        action="append",
        default=[],
        help="Additional simulator plusarg. Accepts either NAME or +NAME.",
    )
    args = parser.parse_args(argv)

    if args.image is None:
        image_name = {
            "smoke": "m_mode_uart_smoke.hex",
            "opensbi": "fw_payload_opensbi_banner.hex",
            "linux": "fw_payload.hex",
            "all": "fw_payload.hex",
        }[args.build_mode]
        args.image = REPO_ROOT / "build" / "linux_boot" / image_name

    if args.pass_pattern is None:
        if args.smoke_check:
            args.pass_pattern = "RV64GC-V2 STAGE3 UART OK"
        elif args.build_mode == "opensbi":
            args.pass_pattern = "OpenSBI"
        else:
            args.pass_pattern = "BOOT OK"

    run_dir = args.run_dir or default_run_dir()
    if not run_dir.is_absolute():
        run_dir = REPO_ROOT / run_dir
    run_dir.mkdir(parents=True, exist_ok=True)

    build_log = run_dir / "build.log"
    if args.build_sim:
        sim_build_rc = run_cmd(
            ["bash", str(REPO_ROOT / "build_dsim_linux.sh")],
            REPO_ROOT,
            run_dir / "sim_build.log",
        )
        if sim_build_rc != 0:
            summarize(
                run_dir,
                {
                    "status": "FAIL",
                    "reason": f"sim build failed, see {run_dir / 'sim_build.log'}",
                    "image": str(args.image),
                    "uart_log": "",
                    "sim_log": "",
                },
            )
            return sim_build_rc

    if args.build:
        build_rc = run_cmd(
            ["bash", str(args.build_script), f"--{args.build_mode}"],
            REPO_ROOT,
            build_log,
        )
        if build_rc != 0:
            summarize(
                run_dir,
                {
                    "status": "FAIL",
                    "reason": f"build failed, see {build_log}",
                    "image": str(args.image),
                    "uart_log": "",
                    "sim_log": "",
                },
            )
            return build_rc

    if not args.run:
        summarize(
            run_dir,
            {
                "status": "BUILT" if args.build else "NOOP",
                "reason": "run not requested",
                "image": str(args.image),
                "uart_log": "",
                "sim_log": "",
            },
        )
        return 0

    image = args.image if args.image.is_absolute() else REPO_ROOT / args.image
    sim_image = args.sim_image if args.sim_image.is_absolute() else REPO_ROOT / args.sim_image
    sim_work_dir = args.sim_work_dir if args.sim_work_dir.is_absolute() else REPO_ROOT / args.sim_work_dir
    uart_log = args.uart_log or (run_dir / "uart.log")
    sim_log = run_dir / "dsim.log"

    if not image.exists():
        summarize(
            run_dir,
            {
                "status": "FAIL",
                "reason": f"image not found: {image}",
                "image": str(image),
                "uart_log": str(uart_log),
                "sim_log": str(sim_log),
            },
        )
        return 2
    if not sim_image.exists():
        summarize(
            run_dir,
            {
                "status": "BLOCKED",
                "reason": f"Stage 3 Linux simulator image not built yet: {sim_image}",
                "image": str(image),
                "uart_log": str(uart_log),
                "sim_log": str(sim_log),
            },
        )
        return 2

    raw_cmd = [
        "dsim",
        "-work",
        str(sim_work_dir),
        "-image",
        args.sim_image_name,
        f"+MEMFILE={image}",
        f"+MAX_CYCLES={args.max_cycles}",
        f"+UART_LOGFILE={uart_log}",
    ]
    if args.smoke_check:
        raw_cmd.append("+UART_SMOKE_CHECK")
    for plusarg in args.sim_plusarg:
        raw_cmd.append(plusarg if plusarg.startswith("+") else f"+{plusarg}")
    shell_lines = [
        "set -euo pipefail",
        ': "${DSIM_HOME:=$HOME/AltairDSim/2026}"',
        'if [[ -n "${DSIM_HOME:-}" && -f "$DSIM_HOME/shell_activate.bash" ]]; then',
        "  set +u",
        '  source "$DSIM_HOME/shell_activate.bash" >/dev/null',
        "  set -u",
        "fi",
        'if [[ -z "${DSIM_LICENSE:-}" ]]; then',
        '  if [[ -f "$HOME/metrics-ca/dsim-license.json" ]]; then',
        '    export DSIM_LICENSE="$HOME/metrics-ca/dsim-license.json"',
        '  elif [[ -f "$HOME/.metrics-ca/dsim-license.json" ]]; then',
        '    export DSIM_LICENSE="$HOME/.metrics-ca/dsim-license.json"',
        "  fi",
        "fi",
        shlex.join(raw_cmd),
    ]
    cmd = ["bash", "-lc", "\n".join(shell_lines)]
    rc = run_cmd(cmd, REPO_ROOT, sim_log)
    uart_text = read_text(uart_log)
    sim_text = read_text(sim_log)
    status, reason = classify_log(uart_text, sim_text, args.pass_pattern)
    if rc != 0 and status == "INCOMPLETE":
        status = "FAIL"
        reason = f"simulator exit code {rc}"

    summarize(
        run_dir,
        {
            "status": status,
            "reason": reason,
            "image": str(image),
            "uart_log": str(uart_log),
            "sim_log": str(sim_log),
            "sim_returncode": rc,
        },
    )
    return 0 if status == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())

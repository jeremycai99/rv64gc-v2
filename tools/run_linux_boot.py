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
import os
import re
import shlex
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
FAIL_PATTERNS = [
    "ERROR:",
    "%Error:",
    "Kernel panic",
    "Oops",
    "BUG:",
    "Illegal instruction",
    "trap loop",
    "fatal",
    "[LINUX_STOP_LOST_LOAD_OWNER]",
]
DSIM_LICENSE_BLOCK_PATTERNS = [
    "License not obtained",
    "Already at maxLeases",
    "No DSim license configured",
]
DEFAULT_STALE_COMMIT_LIMIT = 50_000
LAST_COMMIT_RE = re.compile(
    r"\[LINUX_DEBUG\] last_commit_pc=[0-9a-fA-F]+ last_commit_cycle=(\d+)"
)
MILESTONES = [
    {
        "id": "m_mode_uart_smoke",
        "label": "M-mode UART smoke",
        "patterns": ["RV64GC-V2 STAGE3 UART OK"],
    },
    {
        "id": "opensbi_banner",
        "label": "OpenSBI banner",
        "patterns": ["OpenSBI"],
    },
    {
        "id": "opensbi_platform_probe",
        "label": "OpenSBI platform probe",
        "patterns": ["Platform Name", "Platform HART Count", "Boot HART ID"],
    },
    {
        "id": "linux_early_console",
        "label": "Linux early console",
        "patterns": ["Linux version", "earlycon:"],
    },
    {
        "id": "riscv_clocksource",
        "label": "RISC-V clocksource",
        "patterns": ["clocksource: riscv_clocksource"],
    },
    {
        "id": "uart_driver",
        "label": "NS16550 UART driver",
        "patterns": ["10000000.serial: ttyS0", "ttyS0 at MMIO"],
    },
    {
        "id": "freeing_kernel_image",
        "label": "Freeing unused kernel image",
        "patterns": ["Freeing unused kernel image"],
    },
    {
        "id": "init_handoff",
        "label": "Initramfs handoff",
        "patterns": ["Run /init as init process"],
    },
    {
        "id": "boot_ok",
        "label": "Initramfs BOOT OK",
        "patterns": ["BOOT OK"],
    },
]
MILESTONE_IDS = [str(milestone["id"]) for milestone in MILESTONES]
MILESTONE_BY_ID = {str(milestone["id"]): milestone for milestone in MILESTONES}


def run_cmd(
    cmd: list[str],
    cwd: Path,
    log_path: Path | None,
    env: dict[str, str] | None = None,
) -> int:
    print("+ " + " ".join(cmd))
    if log_path is None:
        return subprocess.run(cmd, cwd=cwd, env=env).returncode
    with log_path.open("w", encoding="utf-8") as log:
        proc = subprocess.run(
            cmd,
            cwd=cwd,
            stdout=log,
            stderr=subprocess.STDOUT,
            text=True,
            env=env,
        )
    return proc.returncode


def read_text(path: Path) -> str:
    if not path.exists():
        return ""
    return path.read_text(encoding="utf-8", errors="replace")


def dsim_license_blocked(log_text: str) -> bool:
    return any(pattern in log_text for pattern in DSIM_LICENSE_BLOCK_PATTERNS)


def summarize(run_dir: Path, payload: dict[str, Any]) -> None:
    run_dir.mkdir(parents=True, exist_ok=True)
    (run_dir / "summary.json").write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    reached = payload.get("milestones_reached") or []
    milestone_lines = [
        f"| {item.get('id', '')} | {item.get('label', '')} |"
        for item in reached
    ]
    md = [
        "# Stage 3 Linux Boot Run",
        "",
        f"- Status: `{payload['status']}`",
        f"- Image: `{payload.get('image', '')}`",
        f"- UART log: `{payload.get('uart_log', '')}`",
        f"- Simulator log: `{payload.get('sim_log', '')}`",
        f"- Target milestone: `{payload.get('target_milestone', '')}`",
        f"- Last milestone: `{payload.get('last_milestone', '')}`",
        f"- Reason: {payload.get('reason', '')}",
        "",
    ]
    if milestone_lines:
        md.extend(
            [
                "## Reached Milestones",
                "",
                "| ID | Label |",
                "|---|---|",
                *milestone_lines,
                "",
            ]
        )
    (run_dir / "summary.md").write_text("\n".join(md), encoding="utf-8")


def milestone_reached(combined: str, milestone: dict[str, Any]) -> bool:
    return any(pattern in combined for pattern in milestone["patterns"])


def classify_milestones(uart_text: str, sim_text: str) -> list[dict[str, str]]:
    reached: list[dict[str, str]] = []
    for milestone in MILESTONES:
        if milestone_reached(uart_text, milestone):
            reached.append(
                {
                    "id": str(milestone["id"]),
                    "label": str(milestone["label"]),
                }
            )
    return reached


def last_timeout_commit_cycle(combined: str) -> int | None:
    matches = LAST_COMMIT_RE.findall(combined)
    if not matches:
        return None
    return int(matches[-1])


def classify_log(
    uart_text: str,
    sim_text: str,
    pass_pattern: str | None,
    target_milestone: str,
    max_cycles: int,
    stale_commit_limit: int,
) -> dict[str, Any]:
    combined = uart_text + "\n" + sim_text
    reached = classify_milestones(uart_text, sim_text)
    reached_ids = {item["id"] for item in reached}
    last_milestone = reached[-1]["id"] if reached else ""

    for pattern in FAIL_PATTERNS:
        if pattern in combined:
            return {
                "status": "FAIL",
                "reason": f"matched failure pattern: {pattern}",
                "milestones_reached": reached,
                "last_milestone": last_milestone,
            }
    if "[LINUX_STOP_NO_COMMIT]" in combined:
        return {
            "status": "FAIL",
            "reason": "matched no-commit stop marker",
            "milestones_reached": reached,
            "last_milestone": last_milestone,
        }
    timeout_commit_cycle = last_timeout_commit_cycle(combined)
    if (
        stale_commit_limit > 0 and
        timeout_commit_cycle is not None and
        max_cycles > timeout_commit_cycle
    ):
        stale_commit_cycles = max_cycles - timeout_commit_cycle
        if stale_commit_cycles > stale_commit_limit:
            return {
                "status": "FAIL",
                "reason": (
                    "stale commit at timeout: "
                    f"last_commit_cycle={timeout_commit_cycle} "
                    f"max_cycles={max_cycles} "
                    f"stale_cycles={stale_commit_cycles} "
                    f"limit={stale_commit_limit}"
                ),
                "milestones_reached": reached,
                "last_milestone": last_milestone,
            }
    if pass_pattern and pass_pattern in combined:
        return {
            "status": "PASS",
            "reason": f"matched pass pattern: {pass_pattern}",
            "milestones_reached": reached,
            "last_milestone": last_milestone,
        }
    if target_milestone in reached_ids:
        label = MILESTONE_BY_ID[target_milestone]["label"]
        return {
            "status": "PASS",
            "reason": f"reached target milestone: {label}",
            "milestones_reached": reached,
            "last_milestone": last_milestone,
        }
    if "TIMEOUT" in combined:
        return {
            "status": "TIMEOUT",
            "reason": "simulator reported timeout",
            "milestones_reached": reached,
            "last_milestone": last_milestone,
        }
    return {
        "status": "INCOMPLETE",
        "reason": f"target milestone not reached: {target_milestone}",
        "milestones_reached": reached,
        "last_milestone": last_milestone,
    }


def default_run_dir() -> Path:
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    return REPO_ROOT / "linux_boot_results" / f"stage3_{stamp}"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", action="store_true", help="Build software image first.")
    parser.add_argument("--build-sim", action="store_true", help="Build the selected Stage 3 platform image.")
    parser.add_argument("--run", action="store_true", help="Run the simulator image.")
    parser.add_argument(
        "--simulator",
        choices=("auto", "dsim", "verilator"),
        default="auto",
        help=(
            "Simulator backend for the Stage 3 platform run. "
            "'auto' tries DSim first and falls back to Verilator when the "
            "DSim lease is unavailable."
        ),
    )
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
        "--linux-profile",
        choices=("trimmed", "full"),
        default=os.environ.get("LINUX_PROFILE", "trimmed"),
        help=(
            "Linux kernel image profile used by sw/linux_boot/build_linux_boot.sh. "
            "'trimmed' is the fast Stage 3 boot baseline; 'full' keeps the "
            "broader mainline defconfig surface with only platform-required "
            "constraints and boot-test disables."
        ),
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
        "--verilator-bin",
        type=Path,
        default=REPO_ROOT / "verilator_linux_work" / "Vtb_linux",
        help="Stage 3 Verilator Linux simulation binary.",
    )
    parser.add_argument(
        "--run-dir",
        type=Path,
        default=None,
        help="Output directory. Defaults to linux_boot_results/stage3_<timestamp>.",
    )
    parser.add_argument("--max-cycles", type=int, default=50_000_000)
    parser.add_argument("--pass-pattern", default=None)
    parser.add_argument(
        "--target-milestone",
        choices=MILESTONE_IDS,
        default=None,
        help="Milestone required for PASS when --pass-pattern is not supplied.",
    )
    parser.add_argument(
        "--no-status",
        action="store_true",
        help="Do not request periodic Linux platform status snapshots.",
    )
    parser.add_argument(
        "--status-interval",
        type=int,
        default=1_000_000,
        help="Cycle interval for +STATUS snapshots when enabled.",
    )
    parser.add_argument(
        "--no-trace-trap",
        action="store_true",
        help="Do not request trap/return trace messages from tb_linux.",
    )
    parser.add_argument(
        "--boot-hartid",
        type=lambda value: int(value, 0),
        default=0,
        help="Hart ID passed in a0 by the simulation platform boot stage.",
    )
    parser.add_argument(
        "--dtb-addr",
        type=lambda value: int(value, 0),
        default=None,
        help="FDT pointer passed in a1 by the simulation platform boot stage.",
    )
    parser.add_argument("--smoke-check", action="store_true")
    parser.add_argument("--uart-log", type=Path, default=None)
    parser.add_argument(
        "--sim-plusarg",
        action="append",
        default=[],
        help="Additional simulator plusarg. Accepts either NAME or +NAME.",
    )
    parser.add_argument(
        "--timeout-stale-commit-limit",
        type=int,
        default=DEFAULT_STALE_COMMIT_LIMIT,
        help=(
            "Fail a timeout run when the last committed instruction is older "
            "than this many cycles. Set to 0 to disable the post-run check."
        ),
    )
    args = parser.parse_args(argv)

    if args.build_mode == "smoke" and args.image is not None:
        image_name = args.image.name
        if image_name == "fw_payload.hex":
            args.build_mode = "linux"
        elif image_name == "fw_payload_opensbi_banner.hex":
            args.build_mode = "opensbi"

    if args.image is None:
        image_name = {
            "smoke": "m_mode_uart_smoke.hex",
            "opensbi": "fw_payload_opensbi_banner.hex",
            "linux": "fw_payload.hex",
            "all": "fw_payload.hex",
        }[args.build_mode]
        build_dir_name = (
            "linux_boot_full"
            if args.linux_profile == "full" and args.build_mode in ("linux", "all")
            else "linux_boot"
        )
        args.image = REPO_ROOT / "build" / build_dir_name / image_name

    if args.target_milestone is None:
        if args.smoke_check or args.build_mode == "smoke":
            args.target_milestone = "m_mode_uart_smoke"
        elif args.build_mode == "opensbi":
            args.target_milestone = "opensbi_banner"
        else:
            args.target_milestone = "boot_ok"

    run_dir = args.run_dir or default_run_dir()
    if not run_dir.is_absolute():
        run_dir = REPO_ROOT / run_dir
    run_dir.mkdir(parents=True, exist_ok=True)

    auto_simulator = args.simulator == "auto"
    selected_simulator = args.simulator
    sim_image_probe = args.sim_image if args.sim_image.is_absolute() else REPO_ROOT / args.sim_image
    verilator_bin_probe = args.verilator_bin if args.verilator_bin.is_absolute() else REPO_ROOT / args.verilator_bin

    if auto_simulator and not args.build_sim:
        if sim_image_probe.exists():
            selected_simulator = "dsim"
        elif verilator_bin_probe.exists():
            selected_simulator = "verilator"
        else:
            selected_simulator = "dsim"

    build_log = run_dir / "build.log"
    if args.build_sim:
        sim_build_scripts = {
            "dsim": "scripts/build_dsim_linux.sh",
            "verilator": "scripts/build_verilator_linux.sh",
        }
        build_order = ["dsim", "verilator"] if auto_simulator else [selected_simulator]
        sim_build_rc = 1
        sim_build_log = run_dir / "sim_build.log"
        for build_idx, build_sim in enumerate(build_order):
            sim_build_log = (
                run_dir / f"sim_build_{build_sim}.log"
                if auto_simulator else
                run_dir / "sim_build.log"
            )
            sim_build_script = REPO_ROOT / sim_build_scripts[build_sim]
            sim_build_rc = run_cmd(
                ["bash", str(sim_build_script)],
                REPO_ROOT,
                sim_build_log,
            )
            if sim_build_rc == 0:
                selected_simulator = build_sim
                break
            if not (
                auto_simulator and
                build_idx == 0 and
                build_sim == "dsim" and
                dsim_license_blocked(read_text(sim_build_log))
            ):
                selected_simulator = build_sim
                break
        if sim_build_rc != 0:
            summarize(
                run_dir,
                {
                    "status": "FAIL",
                    "reason": f"sim build failed, see {sim_build_log}",
                    "image": str(args.image),
                    "uart_log": "",
                    "sim_log": "",
                    "simulator": selected_simulator,
                    "linux_profile": args.linux_profile,
                    "target_milestone": args.target_milestone,
                    "last_milestone": "",
                    "milestones_reached": [],
                },
            )
            return sim_build_rc

    if args.build:
        build_env = os.environ.copy()
        build_env["LINUX_PROFILE"] = args.linux_profile
        if (
            args.linux_profile == "full" and
            args.build_mode in ("linux", "all") and
            "OUT_DIR" not in build_env
        ):
            build_env["OUT_DIR"] = str(REPO_ROOT / "build" / "linux_boot_full")
        build_rc = run_cmd(
            ["bash", str(args.build_script), f"--{args.build_mode}"],
            REPO_ROOT,
            build_log,
            build_env,
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
                    "linux_profile": args.linux_profile,
                    "target_milestone": args.target_milestone,
                    "last_milestone": "",
                    "milestones_reached": [],
                },
            )
            return build_rc

    if not args.run:
        summarize(
            run_dir,
            {
                "status": "BUILT" if (args.build or args.build_sim) else "NOOP",
                "reason": "run not requested",
                "image": str(args.image),
                "uart_log": "",
                "sim_log": "",
                "simulator": selected_simulator,
                "linux_profile": args.linux_profile,
                "target_milestone": args.target_milestone,
                "last_milestone": "",
                "milestones_reached": [],
            },
        )
        return 0

    image = args.image if args.image.is_absolute() else REPO_ROOT / args.image
    sim_image = args.sim_image if args.sim_image.is_absolute() else REPO_ROOT / args.sim_image
    sim_work_dir = args.sim_work_dir if args.sim_work_dir.is_absolute() else REPO_ROOT / args.sim_work_dir
    verilator_bin = args.verilator_bin if args.verilator_bin.is_absolute() else REPO_ROOT / args.verilator_bin
    uart_log = args.uart_log or (run_dir / "uart.log")
    sim_log = run_dir / {
        "dsim": "dsim.log",
        "verilator": "verilator.log",
    }[selected_simulator]

    if not image.exists():
        summarize(
            run_dir,
            {
                "status": "FAIL",
                "reason": f"image not found: {image}",
                "image": str(image),
                "uart_log": str(uart_log),
                "sim_log": str(sim_log),
                "linux_profile": args.linux_profile,
                "target_milestone": args.target_milestone,
                "last_milestone": "",
                "milestones_reached": [],
            },
        )
        return 2
    if selected_simulator == "dsim" and not sim_image.exists():
        summarize(
            run_dir,
            {
                "status": "BLOCKED",
                "reason": f"Stage 3 Linux simulator image not built yet: {sim_image}",
                "image": str(image),
                "uart_log": str(uart_log),
                "sim_log": str(sim_log),
                "simulator": selected_simulator,
                "linux_profile": args.linux_profile,
                "target_milestone": args.target_milestone,
                "last_milestone": "",
                "milestones_reached": [],
            },
        )
        return 2
    if selected_simulator == "verilator" and not verilator_bin.exists():
        summarize(
            run_dir,
            {
                "status": "BLOCKED",
                "reason": f"Stage 3 Verilator binary not built yet: {verilator_bin}",
                "image": str(image),
                "uart_log": str(uart_log),
                "sim_log": str(sim_log),
                "simulator": selected_simulator,
                "linux_profile": args.linux_profile,
                "target_milestone": args.target_milestone,
                "last_milestone": "",
                "milestones_reached": [],
            },
        )
        return 2

    raw_plusargs = [f"+UART_LOGFILE={uart_log}"]
    if args.dtb_addr is None:
        args.dtb_addr = {
            "smoke": 0,
            "opensbi": 0x8018_0000,
            "linux": 0x8200_0000,
            "all": 0x8200_0000,
        }[args.build_mode]
    raw_plusargs.append(f"+BOOT_HARTID={args.boot_hartid:x}")
    raw_plusargs.append(f"+DTB_ADDR={args.dtb_addr:x}")
    if args.smoke_check:
        raw_plusargs.append("+UART_SMOKE_CHECK")
    if args.pass_pattern:
        raw_plusargs.append(
            f"+UART_PASS_PATTERN={args.pass_pattern.replace(' ', '_')}"
        )
    elif args.target_milestone:
        patterns = MILESTONE_BY_ID[args.target_milestone]["patterns"]
        raw_plusargs.append(
            f"+UART_PASS_PATTERN={patterns[-1].replace(' ', '_')}"
        )
    if not args.no_status and args.status_interval > 0:
        raw_plusargs.append("+STATUS")
        raw_plusargs.append(f"+STATUS_INTERVAL={args.status_interval}")
    if not args.no_trace_trap:
        raw_plusargs.append("+LINUX_TRACE_TRAP")
    for plusarg in args.sim_plusarg:
        raw_plusargs.append(plusarg if plusarg.startswith("+") else f"+{plusarg}")

    if selected_simulator == "dsim":
        raw_cmd = [
            "dsim",
            "-work",
            str(sim_work_dir),
            "-image",
            args.sim_image_name,
            f"+MEMFILE={image}",
            f"+MAX_CYCLES={args.max_cycles}",
            *raw_plusargs,
        ]
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
    else:
        cmd = [
            "bash",
            str(REPO_ROOT / "scripts" / "run_verilator_linux.sh"),
            str(image),
            str(args.max_cycles),
            *raw_plusargs,
        ]
    rc = run_cmd(cmd, REPO_ROOT, sim_log)
    uart_text = read_text(uart_log)
    sim_text = read_text(sim_log)
    classification = classify_log(
        uart_text,
        sim_text,
        args.pass_pattern,
        args.target_milestone,
        args.max_cycles,
        args.timeout_stale_commit_limit,
    )
    status = str(classification["status"])
    reason = str(classification["reason"])
    if rc != 0 and status not in ("FAIL", "BLOCKED"):
        prior_status = status
        status = "FAIL"
        reason = f"simulator exit code {rc}; prior classification was {prior_status}"

    summarize(
        run_dir,
        {
            "status": status,
            "reason": reason,
            "image": str(image),
            "uart_log": str(uart_log),
            "sim_log": str(sim_log),
            "sim_returncode": rc,
            "simulator": selected_simulator,
            "requested_simulator": args.simulator,
            "linux_profile": args.linux_profile,
            "target_milestone": args.target_milestone,
            "last_milestone": classification.get("last_milestone", ""),
            "milestones_reached": classification.get("milestones_reached", []),
            "pass_pattern": args.pass_pattern or "",
            "status_interval": 0 if args.no_status else args.status_interval,
        },
    )
    return 0 if status == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())

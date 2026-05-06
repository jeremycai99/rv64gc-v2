#!/usr/bin/env python3
"""Run rv64gc-v2 benchmark hex images with signoff-grade gating.

The default mode is intentionally strict. Dhrystone/CoreMark rows are signoff
gates, not design specs, so performance is scored only when endpoint identity
and the anti-overfit rules hold.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
from dataclasses import dataclass
from datetime import date, datetime
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = REPO_ROOT / "tests" / "benchmarks" / "benchmarks.json"
DEFAULT_XSIM = Path("D:/Xilinx/Vivado/2024.1/bin/xsim.bat")
DHRYSTONE_VAX_DHRYSTONES_PER_SEC = 1757.0
WINDOWS_DRIVE_RE = re.compile(r"^[A-Za-z]:[\\/]")

IPC_RE = re.compile(
    r"IPC:\s+mcycle=(?P<mcycle>\d+)\s+minstret=(?P<minstret>\d+)\s+IPC=(?P<ipc>[0-9.eE+-]+)"
)
PASS_RE = re.compile(r"PASS at cycle (?P<cycle>\d+) \(tohost=(?P<tohost>\d+)\)")
FAIL_RE = re.compile(r"FAIL at cycle (?P<cycle>\d+)")
TIMEOUT_RE = re.compile(r"TIMEOUT after (?P<cycle>\d+)")
TOHOST_RE = re.compile(r"^TOHOST=(?P<tohost>\d+)")
BENCH_RESULT_RE = re.compile(
    r"\[BENCH_RESULT\]\s+index=(?P<index>\d+)\s+field=(?P<field>\w+)\s+"
    r"value=(?P<value>\d+)\s+hex=(?P<hex>[0-9a-fA-F]+)"
)
LOOP_BUFFER_RE = re.compile(r"Loop buffer active: (?P<value>\d+) cycles")
CANONICAL_DECODED_OP_ACTIVE_LABEL = "Standalone decoded-op replay"
DECODED_OP_ACTIVE_RE = re.compile(
    r"(?P<label>Standalone decoded-op replay|Decoded-op cache) active: "
    r"(?P<value>\d+) cycles"
)
FETCH0_SECTION_RE = re.compile(r"^Fetch=0 breakdown:")
FETCH0_COUNTER_RE = re.compile(
    r"^\s+(?P<name>[a-zA-Z0-9_]+(?:_[a-zA-Z0-9_]+)*)\s*: (?P<value>\d+)"
)
XS_COUNTER_RE = re.compile(r"^xs (?P<name>.+?)\s*: (?P<value>\d+)")
GOLDEN_TRIP_MISMATCH_RE = re.compile(
    r"\[GOLDEN_PC TRIP\] cycle=(?P<cycle>\d+) seq=(?P<seq>\d+) "
    r"expected=(?P<expected>[0-9a-fA-F]+) actual=(?P<actual>[0-9a-fA-F]+)"
)
GOLDEN_TRIP_OVERFLOW_RE = re.compile(
    r"\[GOLDEN_PC TRIP\] cycle=(?P<cycle>\d+) seq=(?P<seq>\d+) reason=overflow "
    r"size=(?P<size>\d+) actual=(?P<actual>[0-9a-fA-F]+)"
)
GOLDEN_OK_RE = re.compile(
    r"\[GOLDEN_PC OK\] seq=(?P<seq>\d+) size=(?P<size>\d+)"
)
GOLDEN_LOADED_RE = re.compile(
    r"\[GOLDEN_PC LOADED\] path=(?P<path>\S+) entries=(?P<entries>\d+)"
)

SIGNOFF_ALLOWED_PLUSARGS = {
    "PERF_PROFILE",
    "PERF_COUNTERS",
    "STAT_DUMP",
}

# These knobs enable standalone decoded-op replay or rejected local frontend
# lookahead/tail-delivery paths.  They can hold fetch, drive rename, redirect
# fetch on stream exit, or reuse an owner without a real FTQ/IBuffer delivery
# contract.  Keep them DSE-only until the mechanism is FTQ/BPU-owned rather than
# a renamed loop replay source.
SIGNOFF_FORBIDDEN_PLUSARGS = {
    "ENABLE_UOC",
    "UOC_UNSAFE_STREAM",
    "UOC_ALLOW_CONTROL",
    "UOC_ALLOW_PARTIAL_GROUPS",
    "ENABLE_SAME_FTQ_TAIL_CARRY",
    "ENABLE_SAME_FTQ_TAIL_BYPASS",
    "ENABLE_SAME_LINE_FTQ_HANDOFF",
    "ENABLE_XS_SAME_LINE_LOOKAHEAD",
    "ENABLE_XS_SEQ_LOOKAHEAD",
}

SIGNOFF_MECHANISM_CLASSES = {
    "default_rtl",
    "ftq_owned_delivery",
    "ibuffer_delivery",
    "bpu_loop_exit_prediction",
    "fetch_block_handoff",
    "frontend_prefetch_fdip",
    "decoded_op_cache_ftq_attached",
}

SIGNOFF_REJECTED_MECHANISM_CLASSES = {
    "standalone_loop_replay",
    "standalone_uoc_replay",
    "benchmark_pc_special_case",
    "static_direction_shortcut",
}

DEFAULT_COUNTER_EXPECTATIONS = {
    "ftq_owned_delivery": {
        "decrease": [
            ("packet_empty_noemit_dup", 1),
            ("xs_dup_last_emit", 1),
            ("xs_ftq_empty_cycles", 1),
            ("xs_packet_buf_empty_cycles", 1),
        ],
        "nonincrease": [
            "xs_ftq_full_cycles",
            "xs_packet_buf_full_cycles",
            "xs_backend_stall_cycles",
        ],
    },
    "ibuffer_delivery": {
        "decrease": [
            ("packet_empty_noemit_dup", 1),
            ("xs_dup_last_emit", 1),
            ("xs_packet_buf_empty_cycles", 1),
        ],
        "nonincrease": [
            "xs_packet_buf_full_cycles",
            "xs_backend_stall_cycles",
        ],
    },
    "fetch_block_handoff": {
        "decrease": [
            ("packet_empty_noemit_dup", 1),
            ("xs_dup_last_emit", 1),
            ("xs_ftq_empty_cycles", 1),
        ],
        "nonincrease": [
            "xs_ftq_full_cycles",
            "xs_packet_buf_full_cycles",
            "xs_backend_stall_cycles",
        ],
    },
    "bpu_loop_exit_prediction": {
        "decrease": [
            ("redirect_recovery", 1),
            ("xs_dup_last_emit", 1),
        ],
        "nonincrease": [
            "xs_ftq_full_cycles",
            "xs_packet_buf_full_cycles",
        ],
    },
    "frontend_prefetch_fdip": {
        "decrease": [
            ("packet_empty_wait_icresp", 1),
            ("packet_empty_f2_data", 1),
        ],
        "nonincrease": [
            "redirect_recovery",
            "xs_backend_stall_cycles",
        ],
    },
    "decoded_op_cache_ftq_attached": {
        "decrease": [
            ("packet_empty_noemit_dup", 1),
            ("xs_dup_last_emit", 1),
        ],
        "nonincrease": [
            "redirect_recovery",
            "xs_backend_stall_cycles",
        ],
    },
}


@dataclass
class RunResult:
    name: str
    kind: str
    status: str
    cycle: int | None
    tohost: int | None
    mcycle: int | None
    minstret: int | None
    ipc: float | None
    bench_result: dict[str, int]
    metrics: dict[str, float]
    loop_buffer_active: int | None
    decoded_op_active: int | None
    decoded_op_active_label: str | None
    gate_status: str
    gate_reasons: list[str]
    anti_overfit_verdict: str
    run_class: str
    returncode: int
    command: str
    provenance: dict[str, Any]
    row_dir: Path | None
    log_path: Path | None
    runner_log_path: Path | None
    mechanism_class: str = "default_rtl"
    perf_counters: dict[str, int] | None = None
    architectural_counter_checks: list[dict[str, Any]] | None = None


def repo_path(path: str | Path) -> Path:
    p = Path(path)
    return p if p.is_absolute() else REPO_ROOT / p


def is_windows_path(path: str | Path) -> bool:
    return bool(WINDOWS_DRIVE_RE.match(str(path)))


def path_for_windows_cmd(path: str | Path) -> str:
    text = str(path)
    if os.name == "nt" or is_windows_path(text):
        return text.replace("\\", "/")

    wslpath = shutil.which("wslpath")
    if wslpath:
        completed = subprocess.run(
            [wslpath, "-w", text],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        if completed.returncode == 0:
            return completed.stdout.strip().replace("\\", "/")

    return text.replace("\\", "/")


def windows_cmd_executable() -> str:
    for candidate in ("cmd", "cmd.exe"):
        found = shutil.which(candidate)
        if found:
            return found
    for candidate in (
        Path("/mnt/c/Windows/System32/cmd.exe"),
        Path("/mnt/c/Windows/system32/cmd.exe"),
    ):
        if candidate.exists():
            return str(candidate)
    raise FileNotFoundError("Windows cmd.exe not found; cannot launch xsim.bat")


def uses_windows_batch(args: argparse.Namespace) -> bool:
    if getattr(args, "runner", "xsim-bat") != "xsim-bat":
        return False
    xsim = str(args.xsim).lower()
    return os.name == "nt" or xsim.endswith((".bat", ".cmd"))


def plusarg_name(plusarg: str) -> str:
    return plusarg.lstrip("+").split("=", 1)[0]


def dsim_plusarg(plusarg: str) -> str:
    return plusarg if plusarg.startswith("+") else f"+{plusarg}"


def normalize_counter_name(name: str) -> str:
    return name.strip().replace(" ", "_").replace("-", "_")


def parse_perf_counters(text: str) -> dict[str, int]:
    counters: dict[str, int] = {}
    in_fetch0 = False
    for line in text.splitlines():
        if FETCH0_SECTION_RE.match(line):
            in_fetch0 = True
            continue
        if in_fetch0:
            if line.startswith("Commit histogram"):
                in_fetch0 = False
            elif match := FETCH0_COUNTER_RE.match(line):
                counters[normalize_counter_name(match.group("name"))] = int(
                    match.group("value")
                )
                continue
        if match := XS_COUNTER_RE.match(line):
            counters[f"xs_{normalize_counter_name(match.group('name'))}"] = int(
                match.group("value")
            )
    return counters


def parse_counter_decrease_spec(spec: str) -> tuple[str, int]:
    if ":" not in spec:
        return normalize_counter_name(spec), 1
    name, delta = spec.split(":", 1)
    return normalize_counter_name(name), int(delta)


def counter_expectations(args: argparse.Namespace) -> dict[str, Any]:
    mechanism_class = args.mechanism_class or "default_rtl"
    defaults = DEFAULT_COUNTER_EXPECTATIONS.get(mechanism_class, {})
    decreases = list(defaults.get("decrease", []))
    nonincrease = list(defaults.get("nonincrease", []))
    decreases.extend(
        parse_counter_decrease_spec(spec)
        for spec in getattr(args, "expect_counter_decrease", [])
    )
    nonincrease.extend(
        normalize_counter_name(spec)
        for spec in getattr(args, "expect_counter_nonincrease", [])
    )
    return {
        "decrease": decreases,
        "nonincrease": nonincrease,
    }


def load_baseline_results(path: Path | None) -> dict[str, dict[str, Any]]:
    if path is None:
        return {}
    baseline_path = repo_path(path)
    data = json.loads(baseline_path.read_text(encoding="utf-8"))
    rows = data.get("results", data) if isinstance(data, dict) else data
    out: dict[str, dict[str, Any]] = {}
    for row in rows:
        name = row.get("name")
        if not name:
            continue
        counters = dict(row.get("perf_counters") or {})
        if not counters:
            for key in ("runner_log_path", "log_path"):
                log_path = row.get(key)
                if log_path and Path(log_path).exists():
                    counters = parse_perf_counters(
                        Path(log_path).read_text(errors="replace")
                    )
                    break
        out[str(name)] = {
            "row": row,
            "perf_counters": counters,
        }
    return out


def architectural_counter_check_required(args: argparse.Namespace) -> bool:
    if getattr(args, "require_architectural_counter_movement", False):
        return True
    return args.run_class == "signoff" and (
        (args.mechanism_class or "default_rtl") != "default_rtl"
    )


def evaluate_architectural_counter_checks(
    bench_name: str,
    current_counters: dict[str, int],
    args: argparse.Namespace,
) -> tuple[list[dict[str, Any]], list[str]]:
    checks: list[dict[str, Any]] = []
    failures: list[str] = []
    expectations = counter_expectations(args)
    if not expectations["decrease"] and not expectations["nonincrease"]:
        return checks, failures

    baseline_rows = getattr(args, "baseline_results_by_name", {})
    baseline = baseline_rows.get(bench_name)
    if baseline is None:
        failures.append(
            "architectural_counter_baseline_missing: "
            f"{bench_name}; pass --baseline-results for scoreable "
            "mechanism-class runs"
        )
        return checks, failures

    baseline_counters = baseline.get("perf_counters") or {}
    if not baseline_counters:
        failures.append(
            "architectural_counter_baseline_has_no_perf_counters: "
            f"{bench_name}"
        )
        return checks, failures

    for counter, min_delta in expectations["decrease"]:
        current = current_counters.get(counter)
        base = baseline_counters.get(counter)
        ok = current is not None and base is not None and current <= base - min_delta
        checks.append(
            {
                "counter": counter,
                "expect": f"decrease>={min_delta}",
                "baseline": base,
                "current": current,
                "ok": ok,
            }
        )
        if not ok:
            failures.append(
                f"{counter}={current} baseline={base} expected_decrease>={min_delta}"
            )

    for counter in expectations["nonincrease"]:
        current = current_counters.get(counter)
        base = baseline_counters.get(counter)
        ok = current is not None and base is not None and current <= base
        checks.append(
            {
                "counter": counter,
                "expect": "nonincrease",
                "baseline": base,
                "current": current,
                "ok": ok,
            }
        )
        if not ok:
            failures.append(f"{counter}={current} baseline={base} expected<=baseline")

    return checks, failures


def load_manifests(paths: list[Path]) -> list[dict[str, Any]]:
    benchmarks: list[dict[str, Any]] = []
    for path in paths:
        manifest_path = repo_path(path)
        with manifest_path.open("r", encoding="utf-8") as f:
            data = json.load(f)
        for item in data.get("benchmarks", []):
            item = dict(item)
            item.setdefault("_manifest", str(manifest_path))
            benchmarks.append(item)
    return benchmarks


def sha256_file(path: Path) -> str | None:
    if not path.exists():
        return None
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def run_git(args: list[str]) -> str | None:
    completed = subprocess.run(
        ["git", *args],
        cwd=REPO_ROOT,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    if completed.returncode != 0:
        return None
    return completed.stdout.strip()


def git_snapshot() -> dict[str, str | None]:
    return {
        "head": run_git(["rev-parse", "HEAD"]),
        "head_short": run_git(["rev-parse", "--short", "HEAD"]),
        "status_short": run_git(["status", "--short"]),
        "diff_stat": run_git(["diff", "--stat"]),
    }


def benchmark_provenance(bench: dict[str, Any]) -> dict[str, Any]:
    files: dict[str, Any] = {}
    hex_path = repo_path(bench["hex"])
    files["hex"] = {
        "path": str(hex_path),
        "sha256": sha256_file(hex_path),
        "expected_sha256": bench.get("expected_hex_sha256"),
    }
    if bench.get("elf"):
        elf_path = repo_path(bench["elf"])
        files["elf"] = {
            "path": str(elf_path),
            "sha256": sha256_file(elf_path),
            "expected_sha256": bench.get("expected_elf_sha256"),
        }
    return {
        "manifest": bench.get("_manifest"),
        "files": files,
        "expected": {
            key: bench[key]
            for key in (
                "expected_iterations",
                "expected_checksum",
                "expected_flags",
                "expected_control",
                "require_loop_buffer_zero",
                "require_decoded_op_replay_zero",
            )
            if key in bench
        },
    }


def parse_xsim_log(text: str) -> dict[str, Any]:
    status = "UNKNOWN"
    cycle: int | None = None
    tohost: int | None = None
    mcycle: int | None = None
    minstret: int | None = None
    ipc: float | None = None
    loop_buffer_active: int | None = None
    decoded_op_active: int | None = None
    decoded_op_active_label: str | None = None
    bench_result: dict[str, int] = {}
    golden_pc_trip: dict[str, Any] | None = None
    golden_pc_ok: dict[str, int] | None = None
    golden_pc_loaded: dict[str, Any] | None = None

    if "IterLimit" in text:
        status = "ITERLIMIT"

    for line in text.splitlines():
        if match := PASS_RE.search(line):
            cycle = int(match.group("cycle"))
            tohost = int(match.group("tohost"))
            status = "PASS" if tohost == 1 else f"TOHOST_{tohost}"
            continue
        if match := FAIL_RE.search(line):
            cycle = int(match.group("cycle"))
            status = "FAIL"
            continue
        if match := TIMEOUT_RE.search(line):
            cycle = int(match.group("cycle"))
            status = "TIMEOUT"
            continue
        if match := TOHOST_RE.search(line):
            tohost = int(match.group("tohost"))
            if status == "UNKNOWN":
                status = f"TOHOST_{tohost}"
            continue

        ipc_match = IPC_RE.search(line)
        if ipc_match:
            mcycle = int(ipc_match.group("mcycle"))
            minstret = int(ipc_match.group("minstret"))
            ipc = float(ipc_match.group("ipc"))

        bench_match = BENCH_RESULT_RE.search(line)
        if bench_match:
            field = bench_match.group("field")
            value = int(bench_match.group("value"))
            if field in ("cycles", "instret") and bench_result.get(field, 0) and value == 0:
                continue
            bench_result[field] = value

        loop_match = LOOP_BUFFER_RE.search(line)
        if loop_match:
            loop_buffer_active = int(loop_match.group("value"))
        decoded_op_match = DECODED_OP_ACTIVE_RE.search(line)
        if decoded_op_match:
            decoded_op_active = int(decoded_op_match.group("value"))
            decoded_op_active_label = decoded_op_match.group("label")

        if golden_pc_trip is None:
            mtrip = GOLDEN_TRIP_MISMATCH_RE.search(line)
            if mtrip:
                golden_pc_trip = {
                    "kind": "mismatch",
                    "cycle": int(mtrip.group("cycle")),
                    "seq": int(mtrip.group("seq")),
                    "expected": mtrip.group("expected"),
                    "actual": mtrip.group("actual"),
                }
                continue
            mover = GOLDEN_TRIP_OVERFLOW_RE.search(line)
            if mover:
                golden_pc_trip = {
                    "kind": "overflow",
                    "cycle": int(mover.group("cycle")),
                    "seq": int(mover.group("seq")),
                    "size": int(mover.group("size")),
                    "actual": mover.group("actual"),
                }
                continue
        mok = GOLDEN_OK_RE.search(line)
        if mok:
            golden_pc_ok = {
                "seq": int(mok.group("seq")),
                "size": int(mok.group("size")),
            }
            continue
        mload = GOLDEN_LOADED_RE.search(line)
        if mload:
            golden_pc_loaded = {
                "path": mload.group("path"),
                "entries": int(mload.group("entries")),
            }

    return {
        "status": status,
        "cycle": cycle,
        "tohost": tohost,
        "mcycle": mcycle,
        "minstret": minstret,
        "ipc": ipc,
        "bench_result": bench_result,
        "loop_buffer_active": loop_buffer_active,
        "decoded_op_active": decoded_op_active,
        "decoded_op_active_label": decoded_op_active_label,
        "perf_counters": parse_perf_counters(text),
        "golden_pc_trip": golden_pc_trip,
        "golden_pc_ok": golden_pc_ok,
        "golden_pc_loaded": golden_pc_loaded,
    }


def calculate_metrics(bench: dict[str, Any], parsed: dict[str, Any]) -> dict[str, float]:
    metrics: dict[str, float] = {}
    kind = str(bench.get("kind", "generic")).lower()
    bench_result = parsed["bench_result"]
    status = str(parsed.get("status", "UNKNOWN"))
    requires_stop = bool(bench.get("require_stop", kind in ("coremark", "dhrystone", "spec")))
    has_stop = bench_result.get("control") == 2
    flags_ok = bench_result.get("flags", 0) == 0

    has_result_cycles = bool(bench_result.get("cycles"))
    has_timed_result = has_result_cycles and (has_stop or not requires_stop)
    timed_cycles = bench_result.get("cycles") if has_timed_result else (
        parsed.get("mcycle") if status == "PASS" and not requires_stop else None
    )
    timed_instret = bench_result.get("instret") if has_timed_result else (
        parsed.get("minstret") if status == "PASS" and not requires_stop else None
    )
    iterations = bench_result.get("iterations") or bench.get("iterations")

    if timed_cycles:
        metrics["timed_cycles"] = float(timed_cycles)
    if timed_instret:
        metrics["timed_instret"] = float(timed_instret)
    if timed_cycles and timed_instret:
        metrics["timed_ipc"] = float(timed_instret) / float(timed_cycles)

    if (
        timed_cycles
        and iterations
        and flags_ok
        and (has_timed_result or (status == "PASS" and not requires_stop))
        and (status == "PASS" or not requires_stop)
    ):
        iters = float(iterations)
        if kind == "coremark":
            metrics["coremark_per_mhz"] = iters * 1_000_000.0 / float(timed_cycles)
        elif kind == "dhrystone":
            dhrystones_per_mhz = iters * 1_000_000.0 / float(timed_cycles)
            metrics["dhrystones_per_mhz"] = dhrystones_per_mhz
            metrics["dmips_per_mhz"] = (
                dhrystones_per_mhz / DHRYSTONE_VAX_DHRYSTONES_PER_SEC
            )
        elif kind == "spec":
            ref_seconds = bench.get("spec_ref_seconds")
            if ref_seconds is not None:
                metrics["spec_ratio_per_mhz"] = (
                    float(ref_seconds) * 1_000_000.0 / float(timed_cycles)
                )

    return metrics


def expected_int(bench: dict[str, Any], key: str) -> int | None:
    if key not in bench:
        return None
    return int(bench[key])


def evaluate_gate(
    bench: dict[str, Any],
    parsed: dict[str, Any],
    provenance: dict[str, Any],
    args: argparse.Namespace,
) -> tuple[str, list[str], str]:
    reasons: list[str] = []
    kind = str(bench.get("kind", "generic")).lower()
    bench_result = parsed["bench_result"]
    requires_endpoint = bool(
        bench.get("require_stop", kind in ("coremark", "dhrystone", "spec"))
    )

    if parsed["status"] != "PASS":
        reasons.append(f"status={parsed['status']}")
    if requires_endpoint and parsed.get("tohost") != 1:
        reasons.append(f"tohost={parsed.get('tohost')}")

    control_expected = expected_int(bench, "expected_control")
    if control_expected is not None and bench_result.get("control") != control_expected:
        reasons.append(
            f"control={bench_result.get('control')} expected={control_expected}"
        )

    flags_expected = expected_int(bench, "expected_flags")
    if flags_expected is not None and bench_result.get("flags") != flags_expected:
        reasons.append(f"flags={bench_result.get('flags')} expected={flags_expected}")

    checksum_expected = expected_int(bench, "expected_checksum")
    if checksum_expected is not None and bench_result.get("checksum") != checksum_expected:
        reasons.append(
            f"checksum={bench_result.get('checksum')} expected={checksum_expected}"
        )

    iterations_expected = expected_int(bench, "expected_iterations")
    if iterations_expected is None and kind in ("coremark", "dhrystone"):
        iterations_expected = int(bench.get("iterations", 0)) or None
    if iterations_expected is not None and bench_result.get("iterations") != iterations_expected:
        reasons.append(
            f"iterations={bench_result.get('iterations')} expected={iterations_expected}"
        )

    require_lb_zero = bool(bench.get("require_loop_buffer_zero")) or args.require_loop_buffer_zero
    if require_lb_zero and parsed.get("loop_buffer_active") != 0:
        reasons.append(f"loop_buffer_active={parsed.get('loop_buffer_active')} expected=0")

    require_decoded_op_zero = (
        bool(bench.get("require_decoded_op_replay_zero"))
        or args.require_decoded_op_replay_zero
    )
    if require_decoded_op_zero and parsed.get("decoded_op_active") != 0:
        reasons.append(
            f"decoded_op_active={parsed.get('decoded_op_active')} expected=0"
        )
    if (
        args.run_class == "signoff"
        and require_decoded_op_zero
        and parsed.get("decoded_op_active_label") != CANONICAL_DECODED_OP_ACTIVE_LABEL
    ):
        reasons.append(
            "decoded_op_active_label="
            f"{parsed.get('decoded_op_active_label')!r} expected="
            f"{CANONICAL_DECODED_OP_ACTIVE_LABEL!r}; rebuild with the "
            "tightened standalone replay telemetry so stale decoded-op cache "
            "logs cannot be promoted."
        )

    for kind_name, info in provenance.get("files", {}).items():
        expected_hash = info.get("expected_sha256")
        actual_hash = info.get("sha256")
        if expected_hash and actual_hash != expected_hash:
            reasons.append(
                f"{kind_name}_sha256={actual_hash} expected={expected_hash}"
            )

    if architectural_counter_check_required(args):
        reasons.extend(parsed.get("architectural_counter_failures", []))

    counters = parsed.get("perf_counters") or {}
    invariants = bench.get("counter_invariants") or {}
    for cname, bounds in invariants.items():
        actual = counters.get(cname)
        if actual is None:
            reasons.append(f"counter_invariant:{cname}=missing")
            continue
        if "max" in bounds and actual > bounds["max"]:
            reasons.append(f"counter_invariant:{cname}={actual} > max={bounds['max']}")
        if "min" in bounds and actual < bounds["min"]:
            reasons.append(f"counter_invariant:{cname}={actual} < min={bounds['min']}")

    if args.run_class == "signoff":
        targets = bench.get("counter_targets_stage1") or {}
        for cname, bounds in targets.items():
            actual = counters.get(cname)
            if actual is None:
                reasons.append(f"counter_target:{cname}=missing")
                continue
            if "max" in bounds and actual > bounds["max"]:
                reasons.append(f"counter_target:{cname}={actual} > max={bounds['max']}")
            if "min" in bounds and actual < bounds["min"]:
                reasons.append(f"counter_target:{cname}={actual} < min={bounds['min']}")

    golden_trip = parsed.get("golden_pc_trip")
    if golden_trip is not None:
        reasons.append(
            "golden_pc_trip:"
            f"seq={golden_trip.get('seq')} "
            f"expected={golden_trip.get('expected')} "
            f"actual={golden_trip.get('actual')}"
        )

    if args.run_class == "debug":
        return "DEBUG_ONLY", reasons, "debug_only_not_a_performance_score"
    if args.run_class == "dse":
        endpoint = "endpoint_clean" if not reasons else "endpoint_failed"
        return "DSE_ONLY", reasons, f"dse_evidence_only:{endpoint}"

    if reasons:
        return "FAIL", reasons, "rejected_by_signoff_gate"
    mechanism = args.mechanism_name or "default_rtl"
    mechanism_class = args.mechanism_class or "default_rtl"
    return "PASS", [], f"accepted_general_mechanism:{mechanism_class}:{mechanism}"


def build_xsim() -> None:
    cmd_exe = windows_cmd_executable()
    batch = path_for_windows_cmd(REPO_ROOT / "build_xsim.bat")
    subprocess.run([cmd_exe, "/c", batch], cwd=REPO_ROOT, check=True)


def xsim_command(
    bench: dict[str, Any], args: argparse.Namespace, windows_paths: bool = False
) -> str:
    memfile = repo_path(bench["hex"])
    memfile_arg = path_for_windows_cmd(memfile) if windows_paths else memfile.as_posix()
    max_cycles = int(args.max_cycles if args.max_cycles is not None else bench.get("max_cycles", 100000))
    xsim = path_for_windows_cmd(args.xsim) if windows_paths else str(Path(args.xsim))
    xsim_line = [
        f'call "{xsim}"',
        args.snapshot,
        "--runall",
        "--testplusarg",
        f'"MEMFILE={memfile_arg}"',
        "--testplusarg",
        f'"MAX_CYCLES={max_cycles}"',
        "--testplusarg",
        '"NOVCD"',
    ]
    for plusarg in args.plusarg:
        xsim_line.extend(["--testplusarg", f'"{plusarg}"'])
    return " ".join(xsim_line)


def local_runner_command(bench: dict[str, Any], args: argparse.Namespace) -> list[str]:
    memfile = repo_path(bench["hex"])
    max_cycles = int(args.max_cycles if args.max_cycles is not None else bench.get("max_cycles", 100000))
    if args.runner == "xsim-sh":
        cmd = [str(REPO_ROOT / "run_xsim.sh"), memfile.as_posix(), str(max_cycles)]
    elif args.runner == "dsim":
        cmd = [str(REPO_ROOT / "run_dsim.sh"), memfile.as_posix(), str(max_cycles)]
    else:
        raise ValueError(f"unsupported local runner: {args.runner}")
    cmd.extend(args.plusarg)
    return cmd


def dsim_shell_command(
    bench: dict[str, Any], args: argparse.Namespace, row_dir: Path
) -> tuple[list[str], str, Path, Path | None]:
    memfile = repo_path(bench["hex"])
    max_cycles = int(args.max_cycles if args.max_cycles is not None else bench.get("max_cycles", 100000))
    dsim_log = row_dir / "dsim.log"
    waves_path = row_dir / "run.mxd" if (args.waves or args.run_class == "debug") else None
    raw_cmd = [
        "dsim",
        "-image",
        "tb_image",
        "-iter-limit",
        str(args.iter_limit),
        "-l",
        str(dsim_log),
    ]
    if waves_path is not None:
        raw_cmd.extend(["-waves", str(waves_path)])
    raw_cmd.extend([f"+MEMFILE={memfile}", f"+MAX_CYCLES={max_cycles}"])
    raw_cmd.extend(dsim_plusarg(plusarg) for plusarg in args.plusarg)

    golden_pc_path = bench.get("golden_pc_path")
    if golden_pc_path:
        abs_golden = repo_path(golden_pc_path)
        if abs_golden.exists():
            raw_cmd.append(f"+CHECK_GOLDEN_PCS={abs_golden}")
        else:
            sys.stderr.write(
                f"[run_benchmarks] WARNING: bench {bench.get('name')!r} "
                f"declares golden_pc_path={golden_pc_path!r} but file does not "
                f"exist; skipping golden check.\n"
            )

    script = "\n".join(
        [
            "set -euo pipefail",
            f"cd {shlex.quote(str(REPO_ROOT))}",
            ': "${DSIM_HOME:=$HOME/AltairDSim/2026}"',
            'if [[ ! -f "$DSIM_HOME/shell_activate.bash" ]]; then',
            '  echo "ERROR: DSim not found at $DSIM_HOME"',
            "  exit 1",
            "fi",
            'source "$DSIM_HOME/shell_activate.bash" >/dev/null',
            'if [[ -z "${DSIM_LICENSE:-}" ]]; then',
            '  if [[ -f "$HOME/metrics-ca/dsim-license.json" ]]; then',
            '    export DSIM_LICENSE="$HOME/metrics-ca/dsim-license.json"',
            '  elif [[ -f "$HOME/.metrics-ca/dsim-license.json" ]]; then',
            '    export DSIM_LICENSE="$HOME/.metrics-ca/dsim-license.json"',
            "  fi",
            "fi",
            'if [[ ! -f dsim_work/tb_image.so ]]; then',
            '  echo "ERROR: dsim_work/tb_image.so not found. Run ./build_dsim.sh first."',
            "  exit 1",
            "fi",
            shlex.join(raw_cmd),
        ]
    )
    return ["bash", "-lc", script], shlex.join(raw_cmd), dsim_log, waves_path


def resolve_run_root(args: argparse.Namespace) -> Path | None:
    if args.log_dir:
        return repo_path(args.log_dir)
    if args.run_dir:
        return repo_path(args.run_dir)
    run_id = args.run_id or datetime.now().strftime("%Y%m%d_%H%M%S")
    return REPO_ROOT / "benchmark_results" / f"{args.run_class}_{run_id}"


def env_text(args: argparse.Namespace, bench: dict[str, Any]) -> str:
    interesting_env = {
        key: os.environ.get(key, "")
        for key in ("DSIM_HOME", "DSIM_LICENSE", "LD_LIBRARY_PATH", "PATH")
    }
    payload = {
        "runner": args.runner,
        "run_class": args.run_class,
        "mechanism_name": args.mechanism_name,
        "mechanism_class": args.mechanism_class,
        "plusargs": args.plusarg,
        "benchmark": bench.get("name"),
        "env": interesting_env,
    }
    return json.dumps(payload, indent=2) + "\n"


def run_benchmark(
    bench: dict[str, Any],
    args: argparse.Namespace,
    git_info: dict[str, str | None],
) -> RunResult:
    name = str(bench["name"])
    kind = str(bench.get("kind", "generic"))
    memfile = repo_path(bench["hex"])
    if not memfile.exists():
        raise FileNotFoundError(f"{name}: hex image not found: {memfile}")

    row_dir: Path | None = None
    if args.run_root is not None:
        row_dir = args.run_root / name
        if not args.dry_run:
            row_dir.mkdir(parents=True, exist_ok=True)

    windows_paths = uses_windows_batch(args)
    runner_log_path: Path | None = None
    waves_path: Path | None = None
    if args.runner == "xsim-bat":
        command_text = xsim_command(bench, args, windows_paths)
        if args.dry_run:
            print(command_text)
            return RunResult(
                name, kind, "DRYRUN", None, None, None, None, None,
                {}, {}, None, None, None, "DRYRUN", [], "dry_run", args.run_class, 0,
                command_text, {}, None, None, None,
                mechanism_class=args.mechanism_class or "default_rtl",
            )
        assert row_dir is not None
        run_script = row_dir / f"run_xsim_{name}.bat"
        run_script.write_text(
            "@echo off\n"
            f"cd /d {path_for_windows_cmd(REPO_ROOT) if windows_paths else REPO_ROOT}\n"
            f"{command_text}\n",
            encoding="utf-8",
        )
        cmd_exe = windows_cmd_executable()
        run_script_arg = path_for_windows_cmd(run_script) if windows_paths else str(run_script)
        run_cmd = [cmd_exe, "/c", run_script_arg]
    elif args.runner == "dsim" and row_dir is not None:
        run_cmd, command_text, runner_log_path, waves_path = dsim_shell_command(bench, args, row_dir)
        if args.dry_run:
            print(command_text)
            return RunResult(
                name, kind, "DRYRUN", None, None, None, None, None,
                {}, {}, None, None, None, "DRYRUN", [], "dry_run", args.run_class, 0,
                command_text, {}, None, None, None,
                mechanism_class=args.mechanism_class or "default_rtl",
            )
    else:
        run_cmd = local_runner_command(bench, args)
        command_text = shlex.join(run_cmd)
        if args.dry_run:
            print(command_text)
            return RunResult(
                name, kind, "DRYRUN", None, None, None, None, None,
                {}, {}, None, None, None, "DRYRUN", [], "dry_run", args.run_class, 0,
                command_text, {}, None, None, None,
                mechanism_class=args.mechanism_class or "default_rtl",
            )

    assert row_dir is not None
    (row_dir / "command.txt").write_text(command_text + "\n", encoding="utf-8")
    (row_dir / "env.txt").write_text(env_text(args, bench), encoding="utf-8")

    env = os.environ.copy()
    env.setdefault("LD_LIBRARY_PATH", "")
    completed = subprocess.run(
        run_cmd,
        cwd=REPO_ROOT,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=env,
    )

    stdout_path = row_dir / "stdout.log"
    stdout_text = completed.stdout or ""
    stdout_path.write_text(stdout_text, encoding="utf-8")

    runner_log_text = ""
    if runner_log_path is not None and runner_log_path.exists():
        runner_log_text = runner_log_path.read_text(errors="replace")
    elif args.runner in ("xsim-sh", "dsim"):
        legacy_log = REPO_ROOT / ("xsim_run.log" if args.runner == "xsim-sh" else "dsim_run.log")
        if legacy_log.exists():
            runner_log_path = row_dir / f"{name}.{args.runner}.log"
            shutil.copy2(legacy_log, runner_log_path)
            runner_log_text = runner_log_path.read_text(errors="replace")

    parsed = parse_xsim_log(stdout_text + "\n" + runner_log_text)
    arch_checks, arch_failures = evaluate_architectural_counter_checks(
        name, parsed["perf_counters"], args
    )
    parsed["architectural_counter_checks"] = arch_checks
    parsed["architectural_counter_failures"] = arch_failures
    metrics = calculate_metrics(bench, parsed)
    provenance = benchmark_provenance(bench)
    provenance["git"] = git_info
    provenance["waves"] = str(waves_path) if waves_path is not None else None
    provenance["architectural_guidance"] = {
        "mechanism_class": args.mechanism_class or "default_rtl",
        "counter_check_required": architectural_counter_check_required(args),
        "baseline_results": str(args.baseline_results) if args.baseline_results else None,
        "counter_expectations": counter_expectations(args),
        "counter_checks": arch_checks,
    }
    gate_status, gate_reasons, anti_overfit_verdict = evaluate_gate(
        bench, parsed, provenance, args
    )

    result = RunResult(
        name=name,
        kind=kind,
        status=parsed["status"],
        cycle=parsed["cycle"],
        tohost=parsed["tohost"],
        mcycle=parsed["mcycle"],
        minstret=parsed["minstret"],
        ipc=parsed["ipc"],
        bench_result=parsed["bench_result"],
        metrics=metrics,
        loop_buffer_active=parsed["loop_buffer_active"],
        decoded_op_active=parsed["decoded_op_active"],
        decoded_op_active_label=parsed["decoded_op_active_label"],
        gate_status=gate_status,
        gate_reasons=gate_reasons,
        anti_overfit_verdict=anti_overfit_verdict,
        run_class=args.run_class,
        returncode=completed.returncode,
        command=command_text,
        provenance=provenance,
        row_dir=row_dir,
        log_path=stdout_path,
        runner_log_path=runner_log_path,
        mechanism_class=args.mechanism_class or "default_rtl",
        perf_counters=parsed["perf_counters"],
        architectural_counter_checks=arch_checks,
    )
    (row_dir / "result.json").write_text(
        json.dumps(result_to_dict(result), indent=2) + "\n",
        encoding="utf-8",
    )
    (row_dir / "summary.md").write_text(render_row_markdown(result), encoding="utf-8")
    return result


def format_float(value: float | None, digits: int = 6) -> str:
    if value is None:
        return "-"
    return f"{value:.{digits}f}"


def metric_text(result: RunResult) -> str:
    if "dmips_per_mhz" in result.metrics:
        return f"{result.metrics['dmips_per_mhz']:.6f} DMIPS/MHz"
    if "coremark_per_mhz" in result.metrics:
        return f"{result.metrics['coremark_per_mhz']:.6f} CoreMark/MHz"
    if "spec_ratio_per_mhz" in result.metrics:
        return f"{result.metrics['spec_ratio_per_mhz']:.6f} SPECratio/MHz"
    return "-"


def markdown_number(value: int | float | None, digits: int = 6) -> str:
    if value is None:
        return "-"
    if isinstance(value, int):
        return str(value)
    return f"{value:.{digits}f}"


def gate_reason_text(result: RunResult) -> str:
    return "; ".join(result.gate_reasons) if result.gate_reasons else "-"


def print_summary(results: list[RunResult]) -> None:
    print(
        "name                 class    mech_class                 gate       status    "
        "mcycle      minstret    ipc       legacy_lb decop_act metric"
    )
    print("-" * 156)
    for result in results:
        print(
            f"{result.name:<20} {result.run_class:<8} "
            f"{result.mechanism_class:<26} {result.gate_status:<10} "
            f"{result.status:<9} "
            f"{result.mcycle if result.mcycle is not None else '-':>10} "
            f"{result.minstret if result.minstret is not None else '-':>11} "
            f"{format_float(result.ipc):>9} "
            f"{result.loop_buffer_active if result.loop_buffer_active is not None else '-':>9} "
            f"{result.decoded_op_active if result.decoded_op_active is not None else '-':>9} "
            f"{metric_text(result)}"
        )
        if result.gate_reasons:
            print(f"  gate reasons: {gate_reason_text(result)}")


def result_to_dict(result: RunResult) -> dict[str, Any]:
    return {
        "name": result.name,
        "kind": result.kind,
        "run_class": result.run_class,
        "status": result.status,
        "gate_status": result.gate_status,
        "gate_reasons": result.gate_reasons,
        "anti_overfit_verdict": result.anti_overfit_verdict,
        "mechanism_class": result.mechanism_class,
        "returncode": result.returncode,
        "cycle": result.cycle,
        "tohost": result.tohost,
        "mcycle": result.mcycle,
        "minstret": result.minstret,
        "ipc": result.ipc,
        "loop_buffer_active": result.loop_buffer_active,
        "decoded_op_active": result.decoded_op_active,
        "decoded_op_active_label": result.decoded_op_active_label,
        "bench_result": result.bench_result,
        "metrics": result.metrics,
        "perf_counters": result.perf_counters or {},
        "architectural_counter_checks": result.architectural_counter_checks or [],
        "command": result.command,
        "provenance": result.provenance,
        "row_dir": str(result.row_dir) if result.row_dir else None,
        "log_path": str(result.log_path) if result.log_path else None,
        "runner_log_path": str(result.runner_log_path) if result.runner_log_path else None,
    }


def render_row_markdown(result: RunResult) -> str:
    return "\n".join(
        [
            f"# {result.name}",
            "",
            f"- Run class: `{result.run_class}`",
            f"- Mechanism class: `{result.mechanism_class}`",
            f"- Gate: `{result.gate_status}`",
            f"- Anti-overfit verdict: `{result.anti_overfit_verdict}`",
            f"- Status: `{result.status}`",
            f"- Metric: `{metric_text(result)}`",
            f"- Loop buffer active: `{result.loop_buffer_active}`",
            f"- Standalone decoded-op replay active: `{result.decoded_op_active}`",
            f"- Architectural counter checks: `{sum(1 for c in (result.architectural_counter_checks or []) if c.get('ok'))}/{len(result.architectural_counter_checks or [])}`",
            f"- Gate reasons: {gate_reason_text(result)}",
            "",
        ]
    )


def write_markdown(results: list[RunResult], path: Path) -> None:
    rows = []
    run_date = date.today().isoformat()
    for result in results:
        iterations = result.bench_result.get("iterations")
        timed_cycles = result.metrics.get("timed_cycles")
        timed_instret = result.metrics.get("timed_instret")
        timed_ipc = result.metrics.get("timed_ipc")
        note = result.anti_overfit_verdict
        if result.status == "TIMEOUT" and result.kind.lower() == "coremark":
            note = "No STOP marker yet; CM/MHz pending."
        elif result.status == "TIMEOUT":
            note = "No completed timing window."

        rows.append(
            "| "
            + " | ".join(
                [
                    run_date,
                    result.name,
                    result.kind,
                    result.run_class,
                    result.mechanism_class,
                    result.gate_status,
                    result.status,
                    str(iterations) if iterations is not None else "-",
                    markdown_number(result.mcycle),
                    markdown_number(result.minstret),
                    markdown_number(result.ipc),
                    markdown_number(timed_cycles),
                    markdown_number(timed_instret),
                    markdown_number(timed_ipc),
                    str(result.loop_buffer_active) if result.loop_buffer_active is not None else "-",
                    str(result.decoded_op_active) if result.decoded_op_active is not None else "-",
                    metric_text(result),
                    str(result.cycle) if result.cycle is not None else "-",
                    gate_reason_text(result),
                    note,
                ]
            )
            + " |"
        )

    body = [
        "# Benchmark Performance Tracking",
        "",
        "Cycle-normalized scores assume 1 MHz, so one simulated cycle is one microsecond. "
        "CoreMark/MHz is `iterations * 1,000,000 / timed_cycles`; DMIPS/MHz is "
        "`Dhrystones/MHz / 1757`.",
        "",
        "Signoff rows require endpoint identity and anti-overfit compliance. DSE rows "
        "are opportunity evidence only, even when their endpoints are clean.",
        "",
        "| Date | Benchmark | Kind | Class | Mechanism class | Gate | Status | Iterations | mcycle | minstret | IPC | Timed cycles | Timed instret | Timed IPC | Legacy LB active | Standalone decoded-op replay active | Metric | Stop/cap cycle | Gate reasons | Notes |",
        "| --- | --- | --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: | --- | --- |",
        *rows,
        "",
    ]
    repo_path(path).write_text("\n".join(body), encoding="utf-8")


def write_json(results: list[RunResult], path: Path) -> None:
    repo_path(path).write_text(
        json.dumps([result_to_dict(result) for result in results], indent=2) + "\n",
        encoding="utf-8",
    )


def write_run_manifest(
    args: argparse.Namespace,
    benchmarks: list[dict[str, Any]],
    git_info: dict[str, str | None],
) -> None:
    if args.run_root is None or args.dry_run:
        return
    payload = {
        "created_at": datetime.now().isoformat(timespec="seconds"),
        "run_class": args.run_class,
        "runner": args.runner,
        "mechanism_name": args.mechanism_name,
        "mechanism_class": args.mechanism_class,
        "plusargs": args.plusarg,
        "signoff_plusarg_allow": args.signoff_plusarg_allow,
        "baseline_results": str(args.baseline_results) if args.baseline_results else None,
        "counter_expectations": counter_expectations(args),
        "benchmarks": benchmarks,
        "git": git_info,
    }
    (args.run_root / "run_manifest.json").write_text(
        json.dumps(payload, indent=2) + "\n",
        encoding="utf-8",
    )


def write_perf_profile_summary(results: list[RunResult], run_root: Path) -> None:
    entries = []
    for result in results:
        path = result.runner_log_path or result.log_path
        if path is not None and path.exists():
            entries.append(f"{result.name}={path}")
    if not entries:
        return
    out_path = run_root / "perf_profile_summary.md"
    completed = subprocess.run(
        [
            sys.executable,
            str(REPO_ROOT / "tools" / "summarize_perf_profile.py"),
            *entries,
            "--markdown-out",
            str(out_path),
        ],
        cwd=REPO_ROOT,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if completed.returncode != 0:
        (run_root / "perf_profile_summary_error.txt").write_text(
            completed.stdout or "",
            encoding="utf-8",
        )


def validate_run_class_args(args: argparse.Namespace) -> list[str]:
    mechanism_class = args.mechanism_class or "default_rtl"
    allowed = {plusarg_name(arg) for arg in args.signoff_plusarg_allow}
    allowed |= SIGNOFF_ALLOWED_PLUSARGS
    requested = {plusarg_name(arg) for arg in args.plusarg}
    forbidden_requested = sorted(requested & SIGNOFF_FORBIDDEN_PLUSARGS)
    forbidden_allowlisted = sorted(
        {plusarg_name(arg) for arg in args.signoff_plusarg_allow}
        & SIGNOFF_FORBIDDEN_PLUSARGS
    )
    disallowed = [
        plusarg for plusarg in args.plusarg if plusarg_name(plusarg) not in allowed
    ]
    errors = []
    if args.run_class != "signoff":
        return errors
    if mechanism_class in SIGNOFF_REJECTED_MECHANISM_CLASSES:
        errors.append(
            "signoff rejects mechanism class "
            f"{mechanism_class!r}; this class is DSE/debug-only and cannot be "
            "promoted as Stage 1 architectural evidence."
        )
    elif mechanism_class not in SIGNOFF_MECHANISM_CLASSES:
        errors.append(
            "unknown signoff mechanism class "
            f"{mechanism_class!r}; expected one of "
            + ", ".join(sorted(SIGNOFF_MECHANISM_CLASSES))
        )
    if mechanism_class != "default_rtl" and not args.mechanism_name:
        errors.append(
            "--mechanism-class other than default_rtl requires "
            "--mechanism-name so accepted rows identify one general mechanism."
        )
    if architectural_counter_check_required(args) and not args.baseline_results:
        errors.append(
            "scoreable architectural mechanism runs require --baseline-results "
            "so the harness can verify the expected frontend counter movement."
        )
    if args.baseline_results and not repo_path(args.baseline_results).exists():
        errors.append(f"baseline results not found: {repo_path(args.baseline_results)}")
    if forbidden_requested:
        errors.append(
            "signoff run forbids unsafe frontend replay/lookahead plusargs: "
            + ", ".join(forbidden_requested)
            + ". Use --run-class dse for unsafe UOC, same-tail, or local "
            "lookahead experiments; signoff must use FTQ/BPU-owned frontend "
            "mechanisms with decoded-op replay activity gated to zero."
        )

    # Data-driven discipline (per feedback_perf_discipline.md):
    # 1. Any RTL change vs HEAD invalidates --mechanism-class default_rtl
    # 2. Non-default mechanism class must declare --targets-counter
    # 3. The --targets-counter must have a matching --expect-counter-decrease
    if not getattr(args, "skip_rtl_lock_check", False):
        rtl_paths = ["src/rtl", "src/tb/tb_top.sv"]
        try:
            diff = subprocess.run(
                ["git", "diff", "--quiet", "HEAD", "--"] + rtl_paths,
                cwd=REPO_ROOT,
                check=False,
                capture_output=True,
            )
            rtl_dirty = (diff.returncode != 0)
        except Exception:
            rtl_dirty = False
        if rtl_dirty and mechanism_class == "default_rtl":
            errors.append(
                "data-driven-discipline: signoff with --mechanism-class default_rtl "
                "rejects an unlocked RTL state. `git diff HEAD -- src/rtl/ src/tb/tb_top.sv` "
                "shows uncommitted changes since last accepted commit. To proceed, "
                "either: (a) commit the RTL baseline first and re-run, or (b) declare "
                "a non-default --mechanism-class with --mechanism-name, --baseline-results, "
                "--targets-counter NAME, and --expect-counter-decrease NAME:DELTA so the "
                "harness can verify predicted vs measured counter movement. To bypass "
                "(emergency only), pass --skip-rtl-lock-check."
            )

    targets_counter = getattr(args, "targets_counter", None)
    if mechanism_class != "default_rtl" and not targets_counter:
        errors.append(
            "data-driven-discipline: --mechanism-class "
            f"{mechanism_class!r} requires --targets-counter NAME identifying "
            "which bottleneck counter the change is supposed to move. Run "
            "`./tools/bottleneck_analysis.py <baseline_result.json>` against "
            "the baseline first to pick a counter; the dominant bottleneck is "
            "printed at the top."
        )

    if targets_counter:
        normalized = normalize_counter_name(targets_counter)
        declared = {
            parse_counter_decrease_spec(spec)[0]
            for spec in getattr(args, "expect_counter_decrease", [])
        }
        defaults = DEFAULT_COUNTER_EXPECTATIONS.get(
            mechanism_class, {}
        )
        for c, _ in defaults.get("decrease", []):
            declared.add(normalize_counter_name(c))
        if normalized not in declared:
            errors.append(
                f"data-driven-discipline: --targets-counter {targets_counter!r} "
                f"requires --expect-counter-decrease {targets_counter}:<predicted_delta> "
                "so the harness can verify the targeted counter actually moves. The "
                "predicted_delta is the minimum cycle reduction the change should produce."
            )
    if forbidden_allowlisted:
        errors.append(
            "signoff plusarg allowlist cannot override unsafe frontend "
            "forbidden plusargs: "
            + ", ".join(forbidden_allowlisted)
            + ". These knobs are loop-buffer-like ownership paths, not "
            "scoreable Stage 1 mechanisms."
        )
    if disallowed:
        errors.append(
            "signoff run rejects non-allowlisted plusargs: "
            + ", ".join(disallowed)
            + ". Use --run-class dse for exploration, or pair "
            "--mechanism-name with --signoff-plusarg-allow for one named "
            "general architectural mechanism."
        )
    if args.signoff_plusarg_allow and not args.mechanism_name:
        errors.append(
            "--signoff-plusarg-allow requires --mechanism-name so the row is "
            "not an unnamed plusarg cocktail."
        )
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--manifest",
        action="append",
        type=Path,
        default=None,
        help="Benchmark manifest JSON. Can be passed more than once.",
    )
    parser.add_argument("--bench", action="append", default=[])
    parser.add_argument("--list", action="store_true")
    parser.add_argument(
        "--runner",
        choices=("xsim-bat", "xsim-sh", "dsim"),
        default="xsim-bat",
        help="Simulation launcher to use.",
    )
    parser.add_argument(
        "--run-class",
        choices=("signoff", "dse", "debug"),
        default="signoff",
        help="signoff enforces endpoint and anti-overfit gates; dse/debug are not scoreable.",
    )
    parser.add_argument("--mechanism-name", default=None)
    parser.add_argument(
        "--mechanism-class",
        default="default_rtl",
        help=(
            "Architectural class for the tested mechanism. Scoreable signoff "
            "classes include ftq_owned_delivery, ibuffer_delivery, "
            "bpu_loop_exit_prediction, fetch_block_handoff, "
            "frontend_prefetch_fdip, and decoded_op_cache_ftq_attached. "
            "Loop-replay-like classes are DSE/debug-only."
        ),
    )
    parser.add_argument(
        "--signoff-plusarg-allow",
        action="append",
        default=[],
        help="Allow one plusarg in signoff when paired with --mechanism-name.",
    )
    parser.add_argument("--require-loop-buffer-zero", action="store_true")
    parser.add_argument("--require-decoded-op-replay-zero", action="store_true")
    parser.add_argument(
        "--targets-counter",
        default=None,
        help=(
            "Required for non-default --mechanism-class signoff. Names the "
            "single bottleneck counter the change is designed to reduce. Pair "
            "with --expect-counter-decrease NAME:DELTA so the harness can "
            "verify the predicted movement materialized."
        ),
    )
    parser.add_argument(
        "--skip-rtl-lock-check",
        action="store_true",
        help=(
            "Bypass the data-driven discipline check that rejects default_rtl "
            "signoff when RTL has uncommitted changes vs HEAD. Use only in "
            "emergencies; normal workflow is to commit baseline first or use "
            "a non-default mechanism class."
        ),
    )
    parser.add_argument(
        "--baseline-results",
        type=Path,
        default=None,
        help="Prior results.json used to verify architectural counter movement.",
    )
    parser.add_argument(
        "--require-architectural-counter-movement",
        action="store_true",
        help=(
            "Gate this run on expected PERF_PROFILE counter movement versus "
            "--baseline-results. Signoff does this automatically for "
            "non-default mechanism classes."
        ),
    )
    parser.add_argument(
        "--expect-counter-decrease",
        action="append",
        default=[],
        metavar="COUNTER[:MIN_DELTA]",
        help=(
            "Require a counter to decrease versus baseline. Counter names use "
            "log names with spaces converted to underscores; XS counters use "
            "the xs_ prefix, for example xs_dup_last_emit."
        ),
    )
    parser.add_argument(
        "--expect-counter-nonincrease",
        action="append",
        default=[],
        metavar="COUNTER",
        help="Require a counter to be <= baseline.",
    )
    parser.add_argument("--build-xsim", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--xsim", default=str(DEFAULT_XSIM))
    parser.add_argument("--snapshot", default="tb_xsim_sim")
    parser.add_argument("--max-cycles", type=int, default=None)
    parser.add_argument("--iter-limit", type=int, default=10000000)
    parser.add_argument("--plusarg", action="append", default=[])
    parser.add_argument("--run-dir", type=Path, default=None)
    parser.add_argument("--run-id", default=None)
    parser.add_argument(
        "--log-dir",
        type=Path,
        default=None,
        help="Compatibility alias for --run-dir. Prefer --run-dir for long runs.",
    )
    parser.add_argument("--json-out", type=Path, default=None)
    parser.add_argument("--markdown-out", type=Path, default=None)
    parser.add_argument("--waves", action="store_true")
    parser.add_argument("--no-perf-summary", action="store_true")
    args = parser.parse_args(argv)

    errors = validate_run_class_args(args)
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 2
    args.baseline_results_by_name = load_baseline_results(args.baseline_results)

    benchmarks = load_manifests(args.manifest or [DEFAULT_MANIFEST])
    selected = {
        name.lower()
        for requested in args.bench
        for name in requested.split(",")
        if name.strip()
    }
    if selected:
        benchmarks = [b for b in benchmarks if str(b["name"]).lower() in selected]

    if args.list:
        for bench in benchmarks:
            print(f"{bench['name']}: {bench.get('kind', 'generic')} {bench['hex']}")
        return 0

    if not benchmarks:
        print("No benchmarks selected", file=sys.stderr)
        return 2

    args.run_root = resolve_run_root(args)
    if args.run_root is not None and not args.dry_run:
        args.run_root.mkdir(parents=True, exist_ok=True)

    if args.build_xsim and not args.dry_run:
        build_xsim()

    git_info = git_snapshot()
    write_run_manifest(args, benchmarks, git_info)

    results: list[RunResult] = []
    for bench in benchmarks:
        print(f"=== {bench['name']} ===")
        results.append(run_benchmark(bench, args, git_info))

    print_summary(results)

    if args.dry_run:
        return 0

    if args.run_root is not None:
        write_json(results, args.json_out or (args.run_root / "results.json"))
        write_markdown(results, args.markdown_out or (args.run_root / "summary.md"))
        if not args.no_perf_summary:
            write_perf_profile_summary(results, args.run_root)
    else:
        if args.json_out:
            write_json(results, args.json_out)
        if args.markdown_out:
            write_markdown(results, args.markdown_out)

    if args.run_class == "signoff":
        return 0 if all(result.gate_status == "PASS" for result in results) else 1
    return 0 if all(result.returncode == 0 for result in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())

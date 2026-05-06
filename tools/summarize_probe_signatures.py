#!/usr/bin/env python3
"""Summarize traced probe signatures from DSim logs.

The script parses the focused probe logs produced with
``+PERF_PROFILE +TRACE_HEAD_STALL +TRACE_COMMIT_HOTSPOTS`` and emits the same
high-level fields used by the Stage-1 BOOM comparison loop: pass status,
cycle/IPC, pre-bypass ROB head pressure, and raw post-bypass HEADSTALL source
buckets.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from bisect import bisect_right
from collections import Counter, defaultdict
from pathlib import Path


PASS_RE = re.compile(r"PASS at cycle (\d+) \(tohost=(\d+)\)")
FAIL_RE = re.compile(r"\b(FAIL|TIMEOUT)\b")
IPC_RE = re.compile(r"IPC: mcycle=(\d+) minstret=(\d+) IPC=([0-9.]+)")
HEAD_READY_RE = re.compile(r"Head valid-not-ready cycles:(\d+)")
CLASS_RE = re.compile(r"load/store/branch/serial/other: (\d+) / (\d+) / (\d+) / (\d+) / (\d+)")
OTHER_CLASS_RE = re.compile(r"other-class: mul/div/csr/bru/unknown: (\d+) / (\d+) / (\d+) / (\d+) / (\d+)")
HEADSTALL_RE = re.compile(
    r"\[HEADSTALL\] cyc=(\d+) head=\d+ pc=([0-9a-fA-F]+) "
    r"load=([01]) store=([01]) branch=([01]) bpu_type=([0-9a-fA-F]+) "
    r"csr=([01]) fence=([01]) fencei=([01]) mret=([01]) sret=([01]) "
    r"sfence=([01]) ecall=([01]) wfi=([01])"
)

CONTROL_MNEMS = {
    "b", "beq", "beqz", "bge", "bgeu", "bgt", "bgtu", "ble", "bleu",
    "blez", "blt", "bltu", "bnez", "j", "jal", "jalr", "jr", "ret",
}
LOAD_MNEMS = {"lb", "lbu", "lh", "lhu", "lw", "lwu", "ld"}
STORE_MNEMS = {"sb", "sh", "sw", "sd"}
SERIAL_MNEMS = {"ecall", "ebreak", "fence", "fence.i", "mret", "sret", "wfi"}

MOTIFS = {
    "probe_string_retire_hotspot": "Dhrystone string/return motif",
    "probe_state_crc_branch_hotspot": "CoreMark state/CRC branch motif",
    "probe_matrix_bitextract_store_hotspot": "CoreMark matrix bitextract MUL/store motif",
}


def norm_pc(pc: str) -> str:
    return pc.lower().rjust(16, "0")


def run_text(cmd: list[str]) -> str:
    proc = subprocess.run(cmd, text=True, capture_output=True, check=True)
    return proc.stdout


def load_symbols(elf: Path):
    if not elf.exists():
        return lambda pc: "??"
    text = run_text(["riscv64-unknown-elf-nm", "-n", str(elf)])
    syms: list[tuple[int, str]] = []
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[1] in {"T", "t"}:
            syms.append((int(parts[0], 16), parts[2]))
    syms.sort()
    addrs = [addr for addr, _ in syms]

    def label(pc: str) -> str:
        value = int(pc, 16)
        idx = bisect_right(addrs, value) - 1
        if idx < 0:
            return "??"
        addr, name = syms[idx]
        off = value - addr
        return name if off == 0 else f"{name}+0x{off:x}"

    return label


def load_disassembly(elf: Path) -> dict[str, tuple[str, str]]:
    if not elf.exists():
        return {}
    text = run_text(["riscv64-unknown-elf-objdump", "-d", str(elf)])
    insns: dict[str, tuple[str, str]] = {}
    line_re = re.compile(r"^\s*([0-9a-fA-F]+):\s+(?:[0-9a-fA-F]{4,8}\s+)+(.+)$")
    for line in text.splitlines():
        match = line_re.match(line)
        if not match:
            continue
        pc = norm_pc(match.group(1))
        asm = match.group(2).strip()
        mnemonic = asm.split()[0] if asm else "??"
        insns[pc] = (mnemonic, asm)
    return insns


def head_flag_class(match: re.Match[str]) -> str:
    if match.group(3) == "1":
        return "load"
    if match.group(4) == "1":
        return "store"
    if match.group(5) == "1":
        return "branch"
    if match.group(7) == "1":
        return "csr"
    if match.group(8) == "1" or match.group(9) == "1" or match.group(12) == "1":
        return "fence"
    if match.group(10) == "1" or match.group(11) == "1":
        return "return"
    if match.group(13) == "1":
        return "ecall"
    if match.group(14) == "1":
        return "wfi"
    return "other"


def source_class(flag_class: str, mnemonic: str) -> str:
    base = mnemonic.lower()
    if flag_class == "load":
        return "load_ready"
    if flag_class == "store":
        return "store_sq_ack"
    if flag_class in {"branch", "return"}:
        return "branch_ready_redirect"
    if flag_class in {"csr", "fence", "ecall", "wfi"}:
        return "serial_ready"
    if base in CONTROL_MNEMS:
        return "branch_ready_redirect"
    if base in LOAD_MNEMS:
        return "load_ready"
    if base in STORE_MNEMS:
        return "store_sq_ack"
    if base.startswith("mul"):
        return "mul_result_ready"
    if base.startswith("div") or base.startswith("rem"):
        return "div_result_ready"
    if base in SERIAL_MNEMS:
        return "serial_ready"
    if base == ".insn" or base == "??":
        return "unknown"
    return "arith_result_ready"


def analyze_log(log: Path, elf: Path) -> dict[str, object]:
    name = log.name.removesuffix(".dsim.log").removesuffix(".log")
    sym = load_symbols(elf)
    insns = load_disassembly(elf)
    status = "UNKNOWN"
    pass_cycle = None
    mcycle = None
    minstret = None
    ipc = None
    head_valid_not_ready = None
    pre_bypass_class: dict[str, int] = {}
    pre_bypass_other_class: dict[str, int] = {}
    source_total: Counter[str] = Counter()
    flag_total: Counter[str] = Counter()
    by_pc: dict[str, Counter[str]] = defaultdict(Counter)
    flags_by_pc: dict[str, Counter[str]] = defaultdict(Counter)

    class_line_after_head = False
    for line in log.read_text(errors="replace").splitlines():
        if status == "UNKNOWN":
            if PASS_RE.search(line):
                status = "PASS"
                pass_cycle = int(PASS_RE.search(line).group(1))  # type: ignore[union-attr]
            elif FAIL_RE.search(line):
                status = FAIL_RE.search(line).group(1)  # type: ignore[union-attr]
        if mcycle is None:
            match = IPC_RE.search(line)
            if match:
                mcycle = int(match.group(1))
                minstret = int(match.group(2))
                ipc = float(match.group(3))
        match = HEAD_READY_RE.search(line)
        if match:
            head_valid_not_ready = int(match.group(1))
            class_line_after_head = True
            continue
        if class_line_after_head:
            match = CLASS_RE.search(line)
            if match:
                pre_bypass_class = dict(zip(
                    ["load", "store", "branch", "serial", "other"],
                    [int(match.group(i)) for i in range(1, 6)],
                ))
                class_line_after_head = False
                continue
        match = OTHER_CLASS_RE.search(line)
        if match:
            pre_bypass_other_class = dict(zip(
                ["mul", "div", "csr", "bru", "unknown"],
                [int(match.group(i)) for i in range(1, 6)],
            ))
            continue
        match = HEADSTALL_RE.search(line)
        if match:
            pc = norm_pc(match.group(2))
            flag = head_flag_class(match)
            mnemonic = insns.get(pc, ("??", "??"))[0]
            source = source_class(flag, mnemonic)
            source_total[source] += 1
            flag_total[flag] += 1
            by_pc[pc][source] += 1
            flags_by_pc[pc][flag] += 1

    rows = []
    for pc, counts in sorted(by_pc.items(), key=lambda item: sum(item[1].values()), reverse=True)[:16]:
        mnemonic, asm = insns.get(pc, ("??", "??"))
        rows.append({
            "pc": "0x" + pc,
            "function": sym(pc),
            "instruction": asm,
            "total": sum(counts.values()),
            "sources": dict(counts),
            "flags": dict(flags_by_pc[pc]),
        })

    return {
        "name": name,
        "motif": MOTIFS.get(name, ""),
        "log": str(log),
        "elf": str(elf),
        "status": status,
        "pass_cycle": pass_cycle,
        "mcycle": mcycle,
        "minstret": minstret,
        "ipc": ipc,
        "head_valid_not_ready": head_valid_not_ready,
        "pre_bypass_class": pre_bypass_class,
        "pre_bypass_other_class": pre_bypass_other_class,
        "raw_source_total": dict(source_total),
        "raw_flag_total": dict(flag_total),
        "top_pcs": rows,
    }


def fmt_delta(after: int | float | None, before: int | float | None) -> str:
    if after is None or before is None:
        return "-"
    delta = after - before
    pct = 100.0 * delta / before if before else 0.0
    sign = "+" if delta >= 0 else ""
    return f"{sign}{delta:g} ({sign}{pct:.2f}%)"


def render_markdown(results: list[dict[str, object]], baseline: dict[str, dict[str, object]]) -> str:
    lines: list[str] = ["# Probe Signature Summary", ""]
    lines.append("| Probe | Status | mcycle | Baseline delta | IPC | Head pressure | Raw source totals | Verdict |")
    lines.append("|---|---|---:|---:|---:|---:|---|---|")
    for result in results:
        name = str(result["name"])
        base = baseline.get(name, {})
        mcycle = result.get("mcycle")
        ipc = result.get("ipc")
        head = result.get("head_valid_not_ready")
        raw = result.get("raw_source_total") or {}
        raw_text = ", ".join(f"{k}={v}" for k, v in sorted(raw.items()))
        base_mcycle = base.get("mcycle") if base else None
        verdict = "PASS" if result.get("status") == "PASS" else "CHECK"
        lines.append(
            f"| `{name}` | {result.get('status')} | {mcycle} | "
            f"{fmt_delta(mcycle, base_mcycle)} | {ipc} | {head} | {raw_text} | {verdict} |"
        )
    for result in results:
        lines.append("")
        lines.append(f"## {result['name']}")
        for row in result.get("top_pcs", []):  # type: ignore[union-attr]
            pass
        lines.append("")
        lines.append("| PC | Function | Instruction | Total | Sources | Flags |")
        lines.append("|---|---|---|---:|---|---|")
        for row in result.get("top_pcs", []):  # type: ignore[union-attr]
            sources = ", ".join(f"{k}={v}" for k, v in sorted(row["sources"].items()))
            flags = ", ".join(f"{k}={v}" for k, v in sorted(row["flags"].items()))
            lines.append(
                f"| {row['pc']} | {row['function']} | `{row['instruction']}` | "
                f"{row['total']} | {sources} | {flags} |"
            )
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log-dir", type=Path, required=True)
    parser.add_argument("--baseline-json", type=Path)
    parser.add_argument("--json-out", type=Path, required=True)
    parser.add_argument("--markdown-out", type=Path, required=True)
    args = parser.parse_args()

    baseline: dict[str, dict[str, object]] = {}
    if args.baseline_json and args.baseline_json.exists():
        baseline_list = json.loads(args.baseline_json.read_text())
        baseline = {str(item["name"]): item for item in baseline_list}

    results = []
    for log in sorted(args.log_dir.glob("probe_*.dsim.log")):
        name = log.name.removesuffix(".dsim.log")
        elf = Path("tests/obj") / f"{name}.elf"
        results.append(analyze_log(log, elf))

    args.json_out.parent.mkdir(parents=True, exist_ok=True)
    args.markdown_out.parent.mkdir(parents=True, exist_ok=True)
    args.json_out.write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
    args.markdown_out.write_text(render_markdown(results, baseline), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

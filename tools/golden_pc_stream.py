#!/usr/bin/env python3
"""
golden_pc_stream.py -- generate a golden commit-PC file by running the safe
baseline configuration with +EMIT_COMMIT_PC_HEX, then verify it with
+CHECK_GOLDEN_PCS.

Background: src/tb/tb_top.sv supports two new plusargs:

  +EMIT_COMMIT_PC_HEX=<path>
      During the run, every committed PC is appended to <path> as one
      $readmemh-format hex line, slot by slot in retire order. The TB
      emits [GOLDEN_PC EMIT_DONE seq=N] at $finish.

  +CHECK_GOLDEN_PCS=<path>
      The TB loads <path> at simulation start and asserts every committed
      PC matches the next entry. On first divergence it emits a single
      [GOLDEN_PC TRIP cycle=... seq=... expected=... actual=...] line and
      $finish(2). On clean completion it emits [GOLDEN_PC OK seq=N size=M].

This tool wraps both paths so a session can:

  ./tools/golden_pc_stream.py emit --bench-name dhrystone_300_stage1_anchor \\
      --output tests/golden_pc/dhrystone_300_stage1_anchor.golden.hex

  ./tools/golden_pc_stream.py verify --bench-name dhrystone_300_stage1_anchor \\
      --golden tests/golden_pc/dhrystone_300_stage1_anchor.golden.hex

The emit path runs run_benchmarks.py under --run-class dse (so the harness
does not gate on extra plusargs) and forwards EMIT_COMMIT_PC_HEX. The verify
path passes CHECK_GOLDEN_PCS via the manifest-aware dsim shell command.

The committed-only nature of the trace means the golden is the architectural
retire stream -- speculative ops do not appear, so any RTL change that
preserves architectural correctness produces the same stream regardless of
microarchitectural ordering or branch-recovery behavior.
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEFAULT_MANIFEST = REPO / "tests" / "benchmarks" / "stage1_signoff.json"


def run_benchmarks(extra: list[str], log_dir: Path) -> int:
    cmd = [
        sys.executable,
        str(REPO / "tools" / "run_benchmarks.py"),
        "--runner", "dsim",
        "--log-dir", str(log_dir),
    ] + extra
    print("# " + " ".join(cmd), flush=True)
    return subprocess.run(cmd, cwd=REPO).returncode


def cmd_emit(args: argparse.Namespace) -> int:
    out = args.output.resolve()
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists():
        if not args.force:
            sys.stderr.write(
                f"refusing to overwrite existing {out}; pass --force to replace.\n"
            )
            return 2
        out.unlink()

    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    log_dir = REPO / "benchmark_results" / f"golden_emit_{args.bench_name}_{stamp}"
    log_dir.mkdir(parents=True, exist_ok=True)

    rc = run_benchmarks(
        [
            "--manifest", str(args.manifest),
            "--bench", args.bench_name,
            "--run-class", "dse",
            "--plusarg", f"EMIT_COMMIT_PC_HEX={out}",
        ],
        log_dir,
    )
    if rc != 0:
        sys.stderr.write(f"run_benchmarks exited rc={rc}; see {log_dir}\n")
        return rc

    if not out.exists():
        sys.stderr.write(
            f"ERROR: emit completed but {out} does not exist; check "
            f"{log_dir}/{args.bench_name}/dsim.log for [GOLDEN_PC ERROR] lines.\n"
        )
        return 1

    n_pcs = sum(1 for _ in out.open())
    print(f"\n[GOLDEN] wrote {out}")
    print(f"[GOLDEN] commit PCs: {n_pcs}")
    print(f"[GOLDEN] log root:   {log_dir}")

    sha = subprocess.run(
        ["sha256sum", str(out)], capture_output=True, text=True, check=False
    )
    if sha.returncode == 0:
        print(f"[GOLDEN] sha256:     {sha.stdout.split()[0]}")

    return 0


def cmd_verify(args: argparse.Namespace) -> int:
    golden = args.golden.resolve()
    if not golden.exists():
        sys.stderr.write(f"golden file not found: {golden}\n")
        return 2

    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    log_dir = REPO / "benchmark_results" / f"golden_verify_{args.bench_name}_{stamp}"
    log_dir.mkdir(parents=True, exist_ok=True)

    rc = run_benchmarks(
        [
            "--manifest", str(args.manifest),
            "--bench", args.bench_name,
            "--run-class", "dse",
            "--plusarg", f"CHECK_GOLDEN_PCS={golden}",
        ],
        log_dir,
    )

    dsim_log = log_dir / args.bench_name / "dsim.log"
    if dsim_log.exists():
        text = dsim_log.read_text(errors="replace")
        for needle in ("[GOLDEN_PC LOADED]", "[GOLDEN_PC OK]", "[GOLDEN_PC TRIP]"):
            for line in text.splitlines():
                if needle in line:
                    print(line)

    return rc


def cmd_init_manifest(args: argparse.Namespace) -> int:
    """Add golden_pc_path field to a manifest row, pointing at a generated golden."""
    import json
    manifest = json.loads(args.manifest.read_text())
    benches = manifest.get("benchmarks", [])
    target = None
    for b in benches:
        if b.get("name") == args.bench_name:
            target = b
            break
    if target is None:
        sys.stderr.write(f"bench {args.bench_name!r} not in {args.manifest}\n")
        return 2
    target["golden_pc_path"] = str(args.golden.resolve().relative_to(REPO))
    args.manifest.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"[GOLDEN] wired {args.bench_name} -> golden_pc_path={target['golden_pc_path']}")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_emit = sub.add_parser("emit", help="run the bench in EMIT mode and write a golden file")
    p_emit.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    p_emit.add_argument("--bench-name", required=True)
    p_emit.add_argument("--output", type=Path, required=True)
    p_emit.add_argument("--force", action="store_true",
                        help="overwrite if --output exists")
    p_emit.set_defaults(func=cmd_emit)

    p_verify = sub.add_parser("verify", help="run the bench in CHECK mode against a golden")
    p_verify.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    p_verify.add_argument("--bench-name", required=True)
    p_verify.add_argument("--golden", type=Path, required=True)
    p_verify.set_defaults(func=cmd_verify)

    p_init = sub.add_parser("wire-manifest",
                            help="patch a manifest row to point at a golden file")
    p_init.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    p_init.add_argument("--bench-name", required=True)
    p_init.add_argument("--golden", type=Path, required=True)
    p_init.set_defaults(func=cmd_init_manifest)

    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())

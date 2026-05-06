#!/usr/bin/env python3
"""
image_diff.py -- compare two RISC-V test images (ELF or HEX) at multiple
levels to triage benchmark-image rebuild divergence.

Use case: tests/hex/coremark_iter10.hex (checked-in, PASS, checksum 64687)
vs a freshly built image that fails (e.g. flags=1, checksum 28974). This
tool produces a structured report of where they differ:

  1. SHA256 fingerprint
  2. ELF header (entry, machine, endianness)
  3. Section table (sizes, addresses, alignment)
  4. Symbol map (addresses of _start, main, tohost, fromhost, ...)
  5. Disassembly diff (objdump -d) -- summarized by first divergent address
  6. .data/.rodata initializer-bytes hash (CoreMark seed values matter)

It does NOT execute either image; for that, run them through Spike or DSim
separately. This tool localizes the build-side delta first so the user can
decide whether the divergence is structural (compile flags, ITERATIONS define,
linker layout) or only manifests under the core's pipeline.

Usage:
  ./tools/image_diff.py <a.elf> <b.elf>
  ./tools/image_diff.py <a.elf> <b.elf> --hex-a tests/hex/foo.hex --hex-b /tmp/foo.hex
"""
from __future__ import annotations

import argparse
import hashlib
import shutil
import subprocess
import sys
from pathlib import Path


TOOLCHAIN_PREFIX = "riscv64-unknown-elf-"


def have_tool(name: str) -> bool:
    return shutil.which(name) is not None


def tool(name: str) -> str:
    full = f"{TOOLCHAIN_PREFIX}{name}"
    if have_tool(full):
        return full
    if have_tool(name):
        return name
    raise SystemExit(f"required tool not on PATH: {full} (or {name})")


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def run(cmd: list[str]) -> str:
    try:
        out = subprocess.run(
            cmd, check=True, text=True, capture_output=True
        )
    except subprocess.CalledProcessError as e:
        return f"<error running {' '.join(cmd)}: rc={e.returncode}>\n{e.stderr}"
    return out.stdout


def readelf_header(path: Path) -> str:
    return run([tool("readelf"), "-h", str(path)])


def readelf_sections(path: Path) -> str:
    return run([tool("readelf"), "-S", "-W", str(path)])


def nm_sorted(path: Path) -> dict[str, str]:
    text = run([tool("nm"), "-n", str(path)])
    out: dict[str, str] = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 3:
            continue
        addr, ty, name = parts[0], parts[1], " ".join(parts[2:])
        out[name] = f"{addr} {ty}"
    return out


def objdump_disasm(path: Path) -> list[tuple[str, str]]:
    text = run([tool("objdump"), "-d", "-M", "no-aliases", str(path)])
    pairs: list[tuple[str, str]] = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith(("/", "Disassembly", "Section")):
            continue
        # lines like "80000000:	00000297          	auipc	t0,0x0"
        if ":" in line and line[:8].rstrip().endswith(":") is False:
            head, _, rest = line.partition(":")
            if all(c in "0123456789abcdef" for c in head.strip()):
                pairs.append((head.strip(), rest.strip()))
    return pairs


def hash_section_contents(path: Path, section: str) -> str | None:
    cmd = [tool("objcopy"), "-O", "binary",
           "--only-section", section, str(path), "-"]
    try:
        out = subprocess.run(cmd, check=True, capture_output=True)
    except subprocess.CalledProcessError:
        return None
    return hashlib.sha256(out.stdout).hexdigest()


def report_section(label: str, body: str) -> None:
    print(f"\n=== {label} ===")
    print(body if body.strip() else "(empty)")


def diff_text(label: str, a: str, b: str, max_lines: int = 50) -> None:
    a_lines = a.splitlines()
    b_lines = b.splitlines()
    if a_lines == b_lines:
        print(f"\n=== {label}: IDENTICAL ===")
        return
    print(f"\n=== {label}: DIFFERS ===")
    width = max(40, max(len(l) for l in a_lines + b_lines + [""]))
    print(f"  {'A':<{width}}  |  B")
    shown = 0
    for i in range(max(len(a_lines), len(b_lines))):
        la = a_lines[i] if i < len(a_lines) else ""
        lb = b_lines[i] if i < len(b_lines) else ""
        if la != lb:
            print(f"  {la:<{width}}  |  {lb}")
            shown += 1
            if shown >= max_lines:
                print(f"  ... [{max(len(a_lines), len(b_lines)) - i - 1} more lines]")
                break


def diff_symbols(a: dict[str, str], b: dict[str, str]) -> None:
    keys = sorted(set(a) | set(b))
    delta = []
    important = {"_start", "main", "tohost", "fromhost", "_end", "__start_data",
                 "core_main", "Dhrystone", "start_time", "stop_time"}
    for k in keys:
        va, vb = a.get(k, "<missing>"), b.get(k, "<missing>")
        if va != vb:
            delta.append((k, va, vb))
    if not delta:
        print("\n=== SYMBOLS: IDENTICAL ===")
        return
    print(f"\n=== SYMBOLS: {len(delta)} differ ===")
    print("  important symbols first; full diff after")
    shown_important = False
    for k, va, vb in delta:
        if k in important:
            print(f"  [!] {k}: A={va}  B={vb}")
            shown_important = True
    if shown_important:
        print()
    for k, va, vb in delta[:60]:
        if k not in important:
            print(f"      {k}: A={va}  B={vb}")
    if len(delta) > 60:
        print(f"      ... [{len(delta) - 60} more]")


def diff_disasm(a: list[tuple[str, str]], b: list[tuple[str, str]]) -> None:
    if a == b:
        print("\n=== DISASM: IDENTICAL ===")
        return
    print(f"\n=== DISASM: DIFFERS ===")
    a_map = dict(a)
    b_map = dict(b)
    common_addrs = sorted(set(a_map) & set(b_map),
                          key=lambda x: int(x, 16))
    only_a = sorted(set(a_map) - set(b_map), key=lambda x: int(x, 16))
    only_b = sorted(set(b_map) - set(a_map), key=lambda x: int(x, 16))
    first_div = None
    for addr in common_addrs:
        if a_map[addr] != b_map[addr]:
            first_div = addr
            break
    print(f"  A instructions: {len(a)}")
    print(f"  B instructions: {len(b)}")
    print(f"  addresses only in A: {len(only_a)} (first: {only_a[0] if only_a else '-'})")
    print(f"  addresses only in B: {len(only_b)} (first: {only_b[0] if only_b else '-'})")
    if first_div is None:
        print("  no first-divergence among common addresses (length differs only)")
    else:
        print(f"  first-divergence at common address 0x{first_div}")
        print(f"    A: {a_map[first_div]}")
        print(f"    B: {b_map[first_div]}")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("a", type=Path, help="image A (ELF)")
    ap.add_argument("b", type=Path, help="image B (ELF)")
    ap.add_argument("--hex-a", type=Path, default=None,
                    help="optional .hex for image A (byte-compared if both supplied)")
    ap.add_argument("--hex-b", type=Path, default=None,
                    help="optional .hex for image B")
    ap.add_argument("--no-disasm", action="store_true",
                    help="skip the disassembly comparison (slow on big images)")
    args = ap.parse_args(argv)

    for p in [args.a, args.b]:
        if not p.exists():
            print(f"error: {p} does not exist", file=sys.stderr)
            return 2

    print(f"image_diff: A={args.a}  B={args.b}")
    print(f"  A SHA256: {sha256(args.a)}")
    print(f"  B SHA256: {sha256(args.b)}")

    if args.hex_a and args.hex_b:
        if args.hex_a.exists() and args.hex_b.exists():
            ha, hb = sha256(args.hex_a), sha256(args.hex_b)
            print(f"\n=== HEX FINGERPRINT ===")
            print(f"  hex-A: {ha}  ({args.hex_a})")
            print(f"  hex-B: {hb}  ({args.hex_b})")
            print(f"  byte-identical: {ha == hb}")

    diff_text("ELF HEADER", readelf_header(args.a), readelf_header(args.b))
    diff_text("SECTIONS", readelf_sections(args.a), readelf_sections(args.b),
              max_lines=80)
    diff_symbols(nm_sorted(args.a), nm_sorted(args.b))

    for sec in (".text", ".data", ".rodata", ".sdata", ".bss"):
        ha = hash_section_contents(args.a, sec)
        hb = hash_section_contents(args.b, sec)
        if ha is None and hb is None:
            continue
        verdict = "IDENTICAL" if ha == hb else "DIFFERS"
        print(f"\n=== SECTION {sec}: {verdict} ===")
        print(f"  A: {ha or '<absent>'}")
        print(f"  B: {hb or '<absent>'}")

    if not args.no_disasm:
        diff_disasm(objdump_disasm(args.a), objdump_disasm(args.b))

    print("\n=== summary hints ===")
    print("  - if SECTION .text DIFFERS: rebuild-side compiler/-march drift, or different ITERATIONS define")
    print("  - if SECTION .data DIFFERS but .text IDENTICAL: static-initializer drift (CoreMark seed values)")
    print("  - if SYMBOLS differ in tohost/fromhost address: linker layout drift")
    print("  - if SECTIONS IDENTICAL but pipeline still produces different checksum: divergence is in core, not image; rerun both on Spike to confirm")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

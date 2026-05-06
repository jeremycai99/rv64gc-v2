#!/usr/bin/env python3
"""Convert RISC-V ELF to hex format for $readmemh / sim_memory.

Usage:
    elf2hex.py input.elf output.hex [--base 0x80000000]
    elf2hex.py --binary input.bin output.hex [--base 0x80000000]

The script uses riscv64-unknown-elf-objcopy to convert ELF to raw binary,
then outputs one byte per line in hex (matching $readmemh format).

The --base argument specifies DRAM_BASE (default 0x80000000).
The hex file byte 0 corresponds to address DRAM_BASE.

With --binary, skip the objcopy step and read a raw binary directly.
"""

import argparse
import subprocess
import sys
import os
import tempfile


def elf_to_binary(elf_path, objcopy="riscv64-unknown-elf-objcopy"):
    """Convert ELF to raw binary via objcopy, return bytes."""
    with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as tmp:
        tmp_path = tmp.name

    try:
        cmd = [objcopy, "-O", "binary", elf_path, tmp_path]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            print(f"ERROR: objcopy failed: {result.stderr}", file=sys.stderr)
            sys.exit(1)

        with open(tmp_path, "rb") as f:
            return f.read()
    finally:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)


def binary_to_hex(data, output_path):
    """Write binary data as one hex byte per line."""
    with open(output_path, "w") as f:
        for byte in data:
            f.write(f"{byte:02x}\n")


def get_elf_entry_and_load_addr(elf_path, objdump="riscv64-unknown-elf-objdump"):
    """Get the lowest load address of sections objcopy will place in binary."""
    cmd = [objdump, "-h", elf_path]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        return None

    min_lma = None
    candidate = None
    for line in result.stdout.split("\n"):
        parts = line.split()
        # Section header lines: Idx Name Size VMA LMA File-off Algn
        if len(parts) >= 6:
            try:
                lma = int(parts[4], 16)
                size = int(parts[2], 16)
                candidate = (lma, size)
            except (ValueError, IndexError):
                candidate = None
                continue
        elif candidate is not None:
            flags = {flag.strip() for flag in line.split(",")}
            lma, size = candidate
            if size > 0 and "ALLOC" in flags and "CONTENTS" in flags:
                if min_lma is None or lma < min_lma:
                    min_lma = lma
            candidate = None
    return min_lma


def main():
    parser = argparse.ArgumentParser(
        description="Convert RISC-V ELF/binary to hex for $readmemh"
    )
    parser.add_argument("input", help="Input ELF or binary file")
    parser.add_argument("output", help="Output hex file")
    parser.add_argument(
        "--base",
        type=lambda x: int(x, 0),
        default=0x80000000,
        help="DRAM base address (default: 0x80000000)",
    )
    parser.add_argument(
        "--binary",
        action="store_true",
        help="Input is raw binary (skip objcopy)",
    )
    parser.add_argument(
        "--objcopy",
        default="riscv64-unknown-elf-objcopy",
        help="Path to objcopy (default: riscv64-unknown-elf-objcopy)",
    )
    parser.add_argument(
        "--objdump",
        default="riscv64-unknown-elf-objdump",
        help="Path to objdump (default: riscv64-unknown-elf-objdump)",
    )
    parser.add_argument(
        "--pad",
        type=lambda x: int(x, 0),
        default=0,
        help="Pad output to this many bytes (0 = no padding)",
    )
    args = parser.parse_args()

    if args.binary:
        with open(args.input, "rb") as f:
            data = f.read()
    else:
        # Check if ELF load address matches base
        load_addr = get_elf_entry_and_load_addr(args.input, args.objdump)
        if load_addr is not None and load_addr != args.base:
            print(
                f"NOTE: ELF lowest section LMA=0x{load_addr:x}, "
                f"DRAM_BASE=0x{args.base:x}",
                file=sys.stderr,
            )
            if load_addr > args.base:
                offset = load_addr - args.base
                print(
                    f"  Prepending {offset} zero bytes to align",
                    file=sys.stderr,
                )
            # objcopy -O binary handles this automatically:
            # it produces bytes starting from the lowest LMA

        data = elf_to_binary(args.input, args.objcopy)

    # Handle case where ELF base > DRAM_BASE (objcopy binary starts at lowest LMA)
    if not args.binary:
        load_addr = get_elf_entry_and_load_addr(args.input, args.objdump)
        if load_addr is not None and load_addr > args.base:
            offset = load_addr - args.base
            data = b"\x00" * offset + data

    # Pad if requested
    if args.pad > 0 and len(data) < args.pad:
        data = data + b"\x00" * (args.pad - len(data))

    binary_to_hex(data, args.output)
    print(
        f"Wrote {len(data)} bytes to {args.output} "
        f"(base=0x{args.base:x})",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()

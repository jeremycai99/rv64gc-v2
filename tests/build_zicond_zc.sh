#!/usr/bin/env bash
# Zicond lever gate (doc/ipc3x_structural_study_2026-06-10.md §4.3).
#
# Rebuilds rvb-median, rvb-multiply, embench-aha-mont64 (+ controls
# rvb-qsort, embench-nsichneu) with a Zicond-CAPABLE compiler at the exact
# suite CFLAGS.  The suite GCC (Xilinx 13.4) accepts -march=..._zicond but
# emits ZERO czero (Zicond codegen landed in GCC 14); clang 18 converts.
#
# Compiler: Ubuntu clang-18 extracted locally WITHOUT sudo (the driver
# dynamically links libclang-cpp18/libLLVM18, which ARE installed):
#   mkdir -p /tmp/zicond-tc && cd /tmp/zicond-tc
#   apt-get download clang-18 libclang-common-18-dev llvm-18 llvm-18-linker-tools
#   mkdir -p root && for d in *.deb; do dpkg -x "$d" root/; done
#
# clang compiles each TU (--target=riscv64-unknown-elf, newlib headers from
# the Xilinx sysroot); the LINK step is the unchanged baseline Xilinx GCC
# command (same crt0.S / link.ld / libc.a / libm.a / libgcc.a), so the only
# delta vs the originals is benchmark-code codegen.
#
# Outputs (originals NOT overwritten):
#   tests/{riscv-bench,embench}/baremetal/<name>-zc.elf
#   tests/hex/<name>-zc.hex
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BENCH="$ROOT/tests/riscv-bench/external/riscv-tests/benchmarks"
EMB="$ROOT/tests/embench/external/embench-iot"
RVB_BM="$ROOT/tests/riscv-bench/baremetal"
EMB_BM="$ROOT/tests/embench/baremetal"
CMPRO_BM="$ROOT/tests/coremark-pro/baremetal"   # crt0.S / link.ld / syscalls.c

CLANG="${CLANG_ZC:-/tmp/zicond-tc/root/usr/lib/llvm-18/bin/clang}"

TC_PREFIX="/home/jeremycai/Xilinx/2025.2/Vitis/gnu/riscv/lin/bin/riscv64-unknown-elf"
CC="${TC_PREFIX}-gcc"
OBJDUMP="${TC_PREFIX}-objdump"
OBJCOPY="${TC_PREFIX}-objcopy"
NEWLIB_INC="/home/jeremycai/Xilinx/2025.2/Vitis/gnu/riscv/lin/riscv32-xilinx-elf/usr/include"

NEWLIB_MDIR="/home/jeremycai/Xilinx/2025.2/Vitis/gnu/riscv/lin/riscv32-xilinx-elf/usr/lib/rv64imfdc_zicsr/lp64d"
LIBGCC_PATH="$NEWLIB_MDIR/libgcc.a"
LIBC_PATH="$NEWLIB_MDIR/libc.a"
LIBM_PATH="$NEWLIB_MDIR/libm.a"

ELF2HEX="python3 $ROOT/scripts/elf2hex.py --objdump $OBJDUMP --objcopy $OBJCOPY"
mkdir -p "$ROOT/tests/hex"

OBJ_DIR="$(mktemp -d /tmp/zicond_zc_obj.XXXX)"
trap 'rm -rf "$OBJ_DIR"' EXIT

# clang rejects C11 atomic_* on the volatile (non-_Atomic) ints in
# common/util.h's barrier() (GCC accepts).  Shadow util.h with a copy whose
# three atomic calls use the equivalent __atomic builtins; barrier() is
# unused in single-core runs, so this is parse-only with zero codegen impact.
mkdir -p "$OBJ_DIR/shim"
sed -e 's/atomic_fetch_add_explicit(\(&global->count\), 1, memory_order_acq_rel)/__atomic_fetch_add(\1, 1, __ATOMIC_ACQ_REL)/' \
    -e 's/atomic_store_explicit(\(&global->[a-z]*\), \([a-z0-9]*\), memory_order_relaxed)/__atomic_store_n(\1, \2, __ATOMIC_RELAXED)/' \
    -e 's/atomic_store_explicit(\(&global->[a-z]*\), \([a-z0-9]*\), memory_order_release)/__atomic_store_n(\1, \2, __ATOMIC_RELEASE)/' \
    -e 's/atomic_load_explicit(\(&global->sense\), memory_order_acquire)/__atomic_load_n(\1, __ATOMIC_ACQUIRE)/' \
    "$BENCH/common/util.h" > "$OBJ_DIR/shim/util.h"

# Compile-relevant subset of the suites' COMMON_CFLAGS (link-only flags
# live in the GCC link command below, unchanged from the baseline builds).
CLANG_BASE=(
    --target=riscv64-unknown-elf
    -O2
    -march=rv64gc_zba_zbb_zbs_zicond
    -mabi=lp64d
    -mcmodel=medany
    -fno-pic
    -fno-common
    -fno-asynchronous-unwind-tables
    -fno-unwind-tables
    -isystem "$NEWLIB_INC"
)

GCC_LINK_FLAGS=(
    -O2
    -march=rv64gc_zba_zbb_zbs_zicond
    -mabi=lp64d
    -mcmodel=medany
    -fno-pic -fno-pie -fno-common
    -fno-asynchronous-unwind-tables -fno-unwind-tables
    -static -no-pie -Wl,--build-id=none -nostartfiles
)

build() {
    local NAME="$1" OUT_DIR="$2"; shift 2
    local CFLAGS=() SRCS=() IN_SRCS=0
    for a in "$@"; do
        if [[ "$a" == "--" ]]; then IN_SRCS=1; continue; fi
        if [[ $IN_SRCS == 0 ]]; then CFLAGS+=("$a"); else SRCS+=("$a"); fi
    done

    echo "=== Building ${NAME}-zc (clang) ==="
    local OBJS=()
    local i=0
    for s in "${SRCS[@]}"; do
        local o="$OBJ_DIR/${NAME}_$((i++))_$(basename "${s%.c}").o"
        "$CLANG" "${CLANG_BASE[@]}" "${CFLAGS[@]}" -c "$s" -o "$o"
        OBJS+=("$o")
    done

    local OUT_ELF="$OUT_DIR/${NAME}-zc.elf"
    local OUT_HEX="$ROOT/tests/hex/${NAME}-zc.hex"
    "$CC" "${GCC_LINK_FLAGS[@]}" \
        -T "$CMPRO_BM/link.ld" \
        "$CMPRO_BM/crt0.S" \
        "${OBJS[@]}" \
        "$LIBC_PATH" "$LIBM_PATH" "$LIBGCC_PATH" \
        -o "$OUT_ELF"
    eval "$ELF2HEX \"$OUT_ELF\" \"$OUT_HEX\""
    echo "  Built $OUT_ELF -> $OUT_HEX"
}

RVB_CFLAGS=(-DPREALLOCATE=1 -I"$RVB_BM" -I"$OBJ_DIR/shim" -I"$BENCH/common")
EMB_CFLAGS=(-DWARMUP_HEAT=1 -DGLOBAL_SCALE_FACTOR=1 -DCPU_MHZ=1 -I"$EMB/support")

build rvb-median   "$RVB_BM" "${RVB_CFLAGS[@]}" -I"$BENCH/median" -- \
    "$BENCH/median/median_main.c" "$BENCH/median/median.c" \
    "$RVB_BM/util_support.c" "$CMPRO_BM/syscalls.c"

build rvb-multiply "$RVB_BM" "${RVB_CFLAGS[@]}" -I"$BENCH/multiply" -- \
    "$BENCH/multiply/multiply_main.c" "$BENCH/multiply/multiply.c" \
    "$RVB_BM/util_support.c" "$CMPRO_BM/syscalls.c"

build rvb-qsort    "$RVB_BM" "${RVB_CFLAGS[@]}" -I"$BENCH/qsort" -- \
    "$BENCH/qsort/qsort_main.c" \
    "$RVB_BM/util_support.c" "$CMPRO_BM/syscalls.c"

build embench-aha-mont64 "$EMB_BM" "${EMB_CFLAGS[@]}" -I"$EMB/src/aha-mont64" -- \
    "$EMB"/src/aha-mont64/*.c "$EMB/support/main.c" "$EMB/support/beebsc.c" \
    "$EMB_BM/support.c" "$CMPRO_BM/syscalls.c"

build embench-nsichneu "$EMB_BM" "${EMB_CFLAGS[@]}" -I"$EMB/src/nsichneu" -- \
    "$EMB"/src/nsichneu/*.c "$EMB/support/main.c" "$EMB/support/beebsc.c" \
    "$EMB_BM/support.c" "$CMPRO_BM/syscalls.c"

echo "All -zc builds complete."

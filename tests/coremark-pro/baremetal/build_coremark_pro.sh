#!/usr/bin/env bash
# Build CoreMark-PRO workloads for the rv64gc-v2 bare-metal simulator.
#
# Usage:
#   ./build_coremark_pro.sh sha-test
#   ./build_coremark_pro.sh parser-125k
#   ./build_coremark_pro.sh radix2-big-64k
#   ./build_coremark_pro.sh all
#
# Outputs:
#   tests/coremark-pro/baremetal/<workload>.elf
#   tests/hex/<workload>.hex
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

CMPRO_DIR="$ROOT/tests/coremark-pro/external/coremark-pro"
BMETAL_DIR="$SCRIPT_DIR"

TC_PREFIX="/home/jeremycai/Xilinx/2025.2/Vitis/gnu/riscv/lin/bin/riscv64-unknown-elf"
CC="${TC_PREFIX}-gcc"
OBJDUMP="${TC_PREFIX}-objdump"
OBJCOPY="${TC_PREFIX}-objcopy"

# rv64 multilib path (rv64imfdc_zicsr/lp64d) — covers rv64gc lp64d
NEWLIB_MDIR="/home/jeremycai/Xilinx/2025.2/Vitis/gnu/riscv/lin/riscv32-xilinx-elf/usr/lib/rv64imfdc_zicsr/lp64d"
LIBGCC_PATH="$NEWLIB_MDIR/libgcc.a"
LIBC_PATH="$NEWLIB_MDIR/libc.a"
LIBM_PATH="$NEWLIB_MDIR/libm.a"

ELF2HEX="python3 $ROOT/scripts/elf2hex.py --objdump $OBJDUMP --objcopy $OBJCOPY"
mkdir -p "$ROOT/tests/hex"

# ---------- Common compile flags -------------------------------------------

COMMON_CFLAGS=(
    -O2
    -march=rv64gc_zba_zbb_zbs_zicond
    -mabi=lp64d
    -mcmodel=medany
    -fno-pic
    -fno-pie
    -fno-common
    -fno-asynchronous-unwind-tables
    -fno-unwind-tables
    -static
    -no-pie
    -Wl,--build-id=none
    # Use newlib libc/libm (provides malloc/sqrt/exp/pow/string)
    # Do NOT pass -nostdlib: we WANT newlib
    -nostartfiles
    # CoreMark-PRO config:
    -DHOST_EXAMPLE_CODE=0
    -DUSE_SINGLE_CONTEXT=1
    -DFAKE_FILEIO=1
    -DHAVE_FILEIO=1
    -DEE_SIZEOF_PTR=8
    -DEE_SIZEOF_LONG=8
    -DEE_SIZEOF_INT=4
    -DCOMPILE_OUT_HEAP=1
    -DHAVE_MALLOC=1
    -DNO_ALIGNED_ALLOC=1        # avoid posix_memalign (not in this newlib)
    -DHAVE_PTHREAD=0
    -DUSE_NATIVE_PTHREAD=0
    -DUSE_SINGLE_CONTEXT=1
    -DMAX_CONTEXTS=1
    -DHAVE_GETPID=0
    -DHAVE_DIRENT_H=0
    -DHAVE_DIRENT=0
    -DHAVE_UNISTD_H=0
    -DHAVE_SYS_STAT_H=0
    -DUSE_EE_STAT=0
    -DHAVE_SYS_DIR_H=0
    -DHAVE_STRUCT_STAT_ST_BLKSIZE=0
    -DHAVE_STRUCT_STAT_ST_BLOCKS=0
    -DSTUB_STAT=1
    # disable non-portable features
    -DHAVE_VSSCANF=1
    -DHAVE_VFSCANF=0
    -DNEED_STD_FILES=1
    -DNEED_SEEK_PARAMS=1
    -DNEED_MKSTEMP=0
    # include paths
    -I"$CMPRO_DIR/mith/al/include"
    -I"$CMPRO_DIR/mith/include"
    -I"$BMETAL_DIR"
)

MITH_SRCS=(
    "$CMPRO_DIR/mith/src/mith_lib.c"
    "$CMPRO_DIR/mith/src/mith_workload.c"
    "$CMPRO_DIR/mith/src/th_lib.c"
    "$CMPRO_DIR/mith/src/th_rand.c"
    "$CMPRO_DIR/mith/src/th_getopt.c"
    "$CMPRO_DIR/mith/src/th_encode.c"
    "$CMPRO_DIR/mith/src/md5.c"
    "$CMPRO_DIR/mith/src/th_bignum.c"
    "$CMPRO_DIR/mith/src/th_math.c"
    "$CMPRO_DIR/mith/al/src/al_file.c"
    "$CMPRO_DIR/mith/al/src/al_single.c"
    "$CMPRO_DIR/mith/al/src/al_smp.c"
    "$BMETAL_DIR/al_port.c"
    "$BMETAL_DIR/syscalls.c"
)

# ---------- Build function ---------------------------------------------------

build_workload() {
    local WL="$1"
    local OUT_ELF="$BMETAL_DIR/${WL}.elf"
    local OUT_HEX="$ROOT/tests/hex/${WL}.hex"

    echo "=== Building $WL ==="

    local EXTRA_CFLAGS=()
    local EXTRA_SRCS=()
    local BYPASS_MITH=0

    case "$WL" in
    # ------------------------------------------------------------------ sha-test
    sha-test)
        EXTRA_CFLAGS+=(
            -I"$CMPRO_DIR/benchmarks/darkmark/sha"
        )
        # sha_test_small.c: 3 outer iterations (not 10) to fit in ~200M cycles
        EXTRA_SRCS+=(
            "$BMETAL_DIR/sha_test_small.c"
            "$CMPRO_DIR/benchmarks/darkmark/sha/shabench.c"
            "$CMPRO_DIR/benchmarks/darkmark/sha/sha256.c"
        )
        ;;

    # ----------------------------------------------------------------- parser-125k
    parser-125k)
        EXTRA_CFLAGS+=(
            -I"$CMPRO_DIR/benchmarks/darkmark/parser"
        )
        EXTRA_SRCS+=(
            "$CMPRO_DIR/workloads/parser-125k/parser-125k.c"
            "$CMPRO_DIR/benchmarks/darkmark/parser/parser.c"
            "$CMPRO_DIR/benchmarks/darkmark/parser/ezxml.c"
        )
        ;;

    # ---------------------------------------------------------------- radix2-big-64k
    radix2-big-64k)
        EXTRA_CFLAGS+=(
            -I"$CMPRO_DIR/benchmarks/fp/fft_radix2"
            -DFLOAT_SUPPORT=1
            -DFP_KERNELS_SUPPORT=1
            -DUSE_FP64=1
            -DUSE_FP32=0
            -DUSE_MATH_H=1
        )
        # fake_3.c: stubs for all init_preset_N except preset 3.
        # data3_big.c: provides the actual preset 3 data + init_preset_3.
        # Do NOT include 2K.c/4K.c/32K.c/data4_mid.c/data5_small.c —
        # fake_3.c already provides empty stubs for those presets.
        EXTRA_SRCS+=(
            "$CMPRO_DIR/workloads/radix2-big-64k/radix2-big-64k.c"
            "$CMPRO_DIR/benchmarks/fp/fft_radix2/fft_radix2.c"
            "$CMPRO_DIR/benchmarks/fp/fft_radix2/ref/data3_big.c"
            "$CMPRO_DIR/benchmarks/fp/preset/fake_3.c"
        )
        ;;

    # ------------------------------------------------------------ sha-kernel-direct
    # Bypasses mith entirely: calls sha2() directly in a loop.
    # No strstr, no th_parse_flag, no harness overhead.
    sha-kernel-direct)
        EXTRA_CFLAGS+=(
            -I"$CMPRO_DIR/benchmarks/darkmark/sha"
            -DSHA_KERNEL_ITERS=5
            -DSHA_BUF_SIZE=1048576
        )
        EXTRA_SRCS+=(
            "$BMETAL_DIR/sha_kernel_direct.c"
            "$CMPRO_DIR/benchmarks/darkmark/sha/sha256.c"
        )
        BYPASS_MITH=1
        ;;

    # --------------------------------------------------------- parser-kernel-direct
    # Bypasses mith entirely: generates XML once, calls ezxml_parse_str() in loop.
    # No strstr storm, no th_parse_flag, no harness overhead.
    parser-kernel-direct)
        EXTRA_CFLAGS+=(
            -I"$CMPRO_DIR/benchmarks/darkmark/parser"
            -DPARSER_KERNEL_ITERS=30
            -DPARSER_BUF_SIZE=125000
        )
        EXTRA_SRCS+=(
            "$BMETAL_DIR/parser_kernel_direct.c"
            "$BMETAL_DIR/string_opt.c"
            "$CMPRO_DIR/benchmarks/darkmark/parser/ezxml.c"
        )
        BYPASS_MITH=1
        ;;

    # ------------------------------------------------- radix2-kernel-direct
    # Bypasses mith: generates twiddles + data, calls the FFT kernel directly.
    # bump_alloc.c overrides newlib malloc (whose free-list scan degenerated
    # bare-metal: the prior "2.49 IPC" run was 100% malloc loop, kernel never
    # reached).
    radix2-big-64k-kernel-direct)
        EXTRA_CFLAGS+=(
            -I"$CMPRO_DIR/benchmarks/fp/fft_radix2"
            -DFLOAT_SUPPORT=1
            -DFP_KERNELS_SUPPORT=1
            -DUSE_FP64=1
            -DUSE_FP32=0
            -DUSE_MATH_H=1
        )
        EXTRA_SRCS+=(
            "$BMETAL_DIR/radix2-big-64k_kernel_direct.c"
            "$BMETAL_DIR/bump_alloc.c"
        )
        BYPASS_MITH=1
        ;;

    # ------------------------------------------------------ nnet-kernel-direct
    # Bypasses mith: calls t_run_test_nnet directly (back-prop NN training).
    # Double-precision (USE_FP64=1); real libm exp() — do NOT stub.
    # nnet_th_extra.c: store_dp/load_dp/store_sp/load_sp + intparts_zero +
    # parse-flag/fp-bits/aligned-malloc stubs (the HOST_EXAMPLE_CODE variants).
    # th_rand.c: mith PRNG (needs store_dp/store_sp from nnet_th_extra.c).
    nnet-kernel-direct)
        EXTRA_CFLAGS+=(
            -I"$CMPRO_DIR/benchmarks/fp/nnet"
            -DFLOAT_SUPPORT=1
            -DFP_KERNELS_SUPPORT=1
            -DUSE_FP64=1
            -DUSE_FP32=0
            -DUSE_MATH_H=1
        )
        EXTRA_SRCS+=(
            "$BMETAL_DIR/nnet_kernel_direct.c"
            "$CMPRO_DIR/benchmarks/fp/nnet/nnet.c"
            "$CMPRO_DIR/benchmarks/fp/nnet/ref/letters.c"
            "$CMPRO_DIR/benchmarks/fp/nnet/ref/1letter.c"
            "$CMPRO_DIR/mith/src/th_rand.c"
            "$BMETAL_DIR/nnet_th_extra.c"
        )
        BYPASS_MITH=1
        ;;

    # ------------------------------------------------ linear_alg-kernel-direct
    # Bypasses mith: calls t_run_test_linpack directly (100x100 SP LINPACK).
    # Single-precision (USE_FP32=1).  inputs_f32.c provides init_presets_linpack
    # (preset 4 = n=100, ntimes=10).  No linear_alg-specific th_extra exists:
    # nnet_th_extra.c covers store/load_sp/dp + parse-flag stubs, zip_th_extra.c
    # covers th_calloc_x (th_lib.h maps th_calloc -> th_calloc_x).
    linear_alg-kernel-direct)
        EXTRA_CFLAGS+=(
            -I"$CMPRO_DIR/benchmarks/fp/linpack"
            -DFLOAT_SUPPORT=1
            -DFP_KERNELS_SUPPORT=1
            -DUSE_FP64=0
            -DUSE_FP32=1
            -DUSE_MATH_H=1
        )
        EXTRA_SRCS+=(
            "$BMETAL_DIR/linear_alg_kernel_direct.c"
            "$CMPRO_DIR/benchmarks/fp/linpack/linpack.c"
            "$CMPRO_DIR/benchmarks/fp/linpack/ref/inputs_f32.c"
            "$CMPRO_DIR/mith/src/th_rand.c"
            "$BMETAL_DIR/nnet_th_extra.c"
            "$BMETAL_DIR/zip_th_extra.c"
        )
        BYPASS_MITH=1
        ;;

    # -------------------------------------- loops-all-mid-10k-sp-kernel-direct
    # Bypasses mith: calls t_run_test_loops directly (25 Livermore loops).
    # Single-precision (USE_FP32=1); ref-sp/*.c provide init_preset_0..7
    # (loops.c calls all 8 unconditionally).
    # NOTE: loops-all-mid-10k-sp_th_extra.c is NOT linked — its
    # verify_output/reporting_threshold definitions duplicate th_stubs.c
    # (it was written for an earlier ad-hoc link that included mith th_lib.c).
    loops-all-mid-10k-sp-kernel-direct)
        EXTRA_CFLAGS+=(
            -I"$CMPRO_DIR/benchmarks/fp/loops"
            -DFLOAT_SUPPORT=1
            -DFP_KERNELS_SUPPORT=1
            -DUSE_FP64=0
            -DUSE_FP32=1
            -DUSE_MATH_H=1
        )
        EXTRA_SRCS+=(
            "$BMETAL_DIR/loops-all-mid-10k-sp_kernel_direct.c"
            "$CMPRO_DIR/benchmarks/fp/loops/loops.c"
            "$CMPRO_DIR/benchmarks/fp/loops/ref-sp/1k.c"
            "$CMPRO_DIR/benchmarks/fp/loops/ref-sp/10k.c"
            "$CMPRO_DIR/benchmarks/fp/loops/ref-sp/100k.c"
            "$CMPRO_DIR/benchmarks/fp/loops/ref-sp/100.c"
            "$CMPRO_DIR/benchmarks/fp/loops/ref-sp/32.c"
            "$CMPRO_DIR/benchmarks/fp/loops/ref-sp/10kdot.c"
            "$CMPRO_DIR/benchmarks/fp/loops/ref-sp/1kdot.c"
            "$CMPRO_DIR/benchmarks/fp/loops/ref-sp/100kdot.c"
            "$CMPRO_DIR/mith/src/th_rand.c"
            "$BMETAL_DIR/nnet_th_extra.c"
            "$BMETAL_DIR/zip_th_extra.c"
        )
        BYPASS_MITH=1
        ;;

    # ----------------------------------------------------- cjpeg-kernel-direct
    # Bypasses mith: calls cjpeg_main() directly on the embedded Rose256 BMP.
    # Integer/fixed-point JPEG encode (jfdctint) — no FP defines needed.
    # Links all libjpeg compression sources EXCEPT bmark_lite.c/bm_lib.c
    # (replaced by the kernel_direct main).  cjpeg_th_extra.c: Calc_crc8,
    # th_sscanf/th_stat/file-IO extras not in the shared th_stubs.c.
    cjpeg-kernel-direct)
        EXTRA_CFLAGS+=(
            -I"$CMPRO_DIR/benchmarks/consumer_v2/cjpeg"
            -I"$CMPRO_DIR/benchmarks/consumer_v2/cjpeg/data"
        )
        EXTRA_SRCS+=(
            "$BMETAL_DIR/cjpeg_kernel_direct.c"
            "$CMPRO_DIR/benchmarks/consumer_v2/cjpeg/cjpeg.c"
            "$CMPRO_DIR/benchmarks/consumer_v2/cjpeg/cdjpeg.c"
            "$CMPRO_DIR/benchmarks/consumer_v2/cjpeg/filedata.c"
            "$CMPRO_DIR/benchmarks/consumer_v2/cjpeg/jcapimin.c"
            "$CMPRO_DIR/benchmarks/consumer_v2/cjpeg/jcapistd.c"
            "$CMPRO_DIR/benchmarks/consumer_v2/cjpeg/jccoefct.c"
            "$CMPRO_DIR/benchmarks/consumer_v2/cjpeg/jccolor.c"
            "$CMPRO_DIR/benchmarks/consumer_v2/cjpeg/jcdctmgr.c"
            "$CMPRO_DIR/benchmarks/consumer_v2/cjpeg/jchuff.c"
            "$CMPRO_DIR/benchmarks/consumer_v2/cjpeg/jcinit.c"
            "$CMPRO_DIR/benchmarks/consumer_v2/cjpeg/jcmainct.c"
            "$CMPRO_DIR/benchmarks/consumer_v2/cjpeg/jcmarker.c"
            "$CMPRO_DIR/benchmarks/consumer_v2/cjpeg/jcmaster.c"
            "$CMPRO_DIR/benchmarks/consumer_v2/cjpeg/jcomapi.c"
            "$CMPRO_DIR/benchmarks/consumer_v2/cjpeg/jcparam.c"
            "$CMPRO_DIR/benchmarks/consumer_v2/cjpeg/jcprepct.c"
            "$CMPRO_DIR/benchmarks/consumer_v2/cjpeg/jcsample.c"
            "$CMPRO_DIR/benchmarks/consumer_v2/cjpeg/jdatadst.c"
            "$CMPRO_DIR/benchmarks/consumer_v2/cjpeg/jerror.c"
            "$CMPRO_DIR/benchmarks/consumer_v2/cjpeg/jfdctint.c"
            "$CMPRO_DIR/benchmarks/consumer_v2/cjpeg/jmemansi.c"
            "$CMPRO_DIR/benchmarks/consumer_v2/cjpeg/jmemmgr.c"
            "$CMPRO_DIR/benchmarks/consumer_v2/cjpeg/jutils.c"
            "$CMPRO_DIR/benchmarks/consumer_v2/cjpeg/rdbmp.c"
            "$CMPRO_DIR/benchmarks/consumer_v2/cjpeg/data/Rose256_bmp.c"
            "$BMETAL_DIR/cjpeg_th_extra.c"
        )
        BYPASS_MITH=1
        ;;

    # ------------------------------------------------------- zip-kernel-direct
    # Bypasses mith: generates a ~1MB XML-like buffer, calls zlib-1.2.8
    # compress()/uncompress() in a loop.  Integer-only — no FP defines.
    # Links the in-memory zlib subset (no infback.c/gzclose.c/gzlib.c —
    # gz* file API is unused).  zip_th_extra.c: th_calloc_x for zutil.c
    # (this zlib is EEMBC-modified: zutil.h includes th_lib.h/th_file.h).
    zip-kernel-direct)
        EXTRA_CFLAGS+=(
            -I"$CMPRO_DIR/benchmarks/darkmark/zip/zlib-1.2.8"
        )
        EXTRA_SRCS+=(
            "$BMETAL_DIR/zip_kernel_direct.c"
            "$CMPRO_DIR/benchmarks/darkmark/zip/zlib-1.2.8/compress.c"
            "$CMPRO_DIR/benchmarks/darkmark/zip/zlib-1.2.8/uncompr.c"
            "$CMPRO_DIR/benchmarks/darkmark/zip/zlib-1.2.8/deflate.c"
            "$CMPRO_DIR/benchmarks/darkmark/zip/zlib-1.2.8/trees.c"
            "$CMPRO_DIR/benchmarks/darkmark/zip/zlib-1.2.8/inflate.c"
            "$CMPRO_DIR/benchmarks/darkmark/zip/zlib-1.2.8/inffast.c"
            "$CMPRO_DIR/benchmarks/darkmark/zip/zlib-1.2.8/inftrees.c"
            "$CMPRO_DIR/benchmarks/darkmark/zip/zlib-1.2.8/adler32.c"
            "$CMPRO_DIR/benchmarks/darkmark/zip/zlib-1.2.8/crc32.c"
            "$CMPRO_DIR/benchmarks/darkmark/zip/zlib-1.2.8/zutil.c"
            "$BMETAL_DIR/zip_th_extra.c"
        )
        BYPASS_MITH=1
        ;;

    # ---- phase-isolation A/B variants (small iters so they run to halt) ----
    parser-ko-full)
        EXTRA_CFLAGS+=(
            -I"$CMPRO_DIR/benchmarks/darkmark/parser"
            -DPARSER_KERNEL_ITERS=2
            -DPARSER_BUF_SIZE=125000
        )
        EXTRA_SRCS+=(
            "$BMETAL_DIR/parser_kernel_direct.c"
            "$BMETAL_DIR/string_opt.c"
            "$CMPRO_DIR/benchmarks/darkmark/parser/ezxml.c"
        )
        BYPASS_MITH=1
        ;;
    parser-ko-parseonly)
        EXTRA_CFLAGS+=(
            -I"$CMPRO_DIR/benchmarks/darkmark/parser"
            -DPARSER_KERNEL_ITERS=2
            -DPARSER_BUF_SIZE=125000
            -DPARSER_SKIP_TRAVERSE
        )
        EXTRA_SRCS+=(
            "$BMETAL_DIR/parser_kernel_direct.c"
            "$BMETAL_DIR/string_opt.c"
            "$CMPRO_DIR/benchmarks/darkmark/parser/ezxml.c"
        )
        BYPASS_MITH=1
        ;;

    *)
        echo "ERROR: Unknown workload '$WL'. Supported: sha-test parser-125k radix2-big-64k sha-kernel-direct parser-kernel-direct nnet-kernel-direct linear_alg-kernel-direct loops-all-mid-10k-sp-kernel-direct cjpeg-kernel-direct zip-kernel-direct parser-ko-full parser-ko-parseonly all" >&2
        exit 1
        ;;
    esac

    if [[ "${BYPASS_MITH:-0}" == "1" ]]; then
        # Direct-kernel builds: link crt0 + kernel sources + th_stubs + syscalls.
        # th_stubs.c provides thin newlib wrappers for th_malloc/th_memset/etc.
        # syscalls.c provides _sbrk (heap) and other newlib OS stubs.
        # No mith harness (mith_lib, mith_workload, th_rand, md5, th_getopt…)
        # → eliminates al_main / th_parse_flag / strstr storms entirely.
        "$CC" \
            "${COMMON_CFLAGS[@]}" \
            "${EXTRA_CFLAGS[@]}" \
            -T "$BMETAL_DIR/link.ld" \
            "$BMETAL_DIR/crt0.S" \
            "${EXTRA_SRCS[@]}" \
            "$BMETAL_DIR/th_stubs.c" \
            "$BMETAL_DIR/syscalls.c" \
            "$LIBC_PATH" "$LIBM_PATH" "$LIBGCC_PATH" \
            -o "$OUT_ELF"
    else
        "$CC" \
            "${COMMON_CFLAGS[@]}" \
            "${EXTRA_CFLAGS[@]}" \
            -T "$BMETAL_DIR/link.ld" \
            "$BMETAL_DIR/crt0.S" \
            "${MITH_SRCS[@]}" \
            "${EXTRA_SRCS[@]}" \
            "$LIBC_PATH" "$LIBM_PATH" "$LIBGCC_PATH" \
            -o "$OUT_ELF"
    fi

    eval "$ELF2HEX \"$OUT_ELF\" \"$OUT_HEX\""
    echo "  Built $OUT_ELF -> $OUT_HEX"
}

# ---------- Main -------------------------------------------------------------

WORKLOAD="${1:-all}"
if [[ "$WORKLOAD" == "all" ]]; then
    build_workload sha-test
    build_workload parser-125k
    build_workload radix2-big-64k
    build_workload sha-kernel-direct
    build_workload parser-kernel-direct
else
    build_workload "$WORKLOAD"
fi

#!/usr/bin/env bash
# Build Stage 3 Linux boot software artifacts for rv64gc-v2.
set -euo pipefail

MODE="smoke"
case "${1:-}" in
    --smoke|"")
        MODE="smoke"
        ;;
    --opensbi)
        MODE="opensbi"
        ;;
    --linux)
        MODE="linux"
        ;;
    --all)
        MODE="all"
        ;;
    --clean)
        MODE="clean"
        ;;
    *)
        echo "usage: $0 [--smoke|--opensbi|--linux|--all|--clean]" >&2
        exit 2
        ;;
esac

PROJ_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SW_DIR="$PROJ_DIR/sw/linux_boot"
OUT_DIR="${OUT_DIR:-$PROJ_DIR/build/linux_boot}"
DTS="$SW_DIR/dts/rv64gc_v2_linux.dts"
DTB="$OUT_DIR/rv64gc_v2_linux.dtb"
LINUX_DIR="${LINUX_DIR:-$PROJ_DIR/../rv64gc-v1/sw/linux}"
OPENSBI_DIR="${OPENSBI_DIR:-$PROJ_DIR/../rv64gc-v1/sw/opensbi}"
CROSS_ELF="${CROSS_ELF:-riscv64-unknown-elf-}"
CROSS_LINUX="${CROSS_LINUX:-riscv64-linux-gnu-}"
OPENSBI_CROSS="${OPENSBI_CROSS:-$CROSS_LINUX}"
SMOKE_MARCH="${SMOKE_MARCH:-rv64imafdc_zicsr_zifencei}"
SMOKE_MABI="${SMOKE_MABI:-lp64d}"
OPENSBI_MARCH="${OPENSBI_MARCH:-rv64imafdc_zicsr_zifencei}"
OPENSBI_MABI="${OPENSBI_MABI:-lp64d}"
OPENSBI_PAYLOAD_OFFSET="${OPENSBI_PAYLOAD_OFFSET:-0x100000}"
OPENSBI_FDT_ADDR="${OPENSBI_FDT_ADDR:-0x80180000}"
LINUX_PAYLOAD_OFFSET="${LINUX_PAYLOAD_OFFSET:-0x200000}"
LINUX_FDT_ADDR="${LINUX_FDT_ADDR:-0x82000000}"
NPROC="${NPROC:-$(nproc)}"

need_tool() {
    local tool="$1"
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: required tool not found: $tool" >&2
        exit 1
    fi
}

prepare_opensbi_tree() {
    if [[ -d "$OPENSBI_DIR/scripts/Kconfiglib" ]]; then
        chmod u+x "$OPENSBI_DIR"/scripts/Kconfiglib/*.py 2>/dev/null || true
    fi
    if [[ -d "$OPENSBI_DIR/scripts" ]]; then
        chmod u+x "$OPENSBI_DIR"/scripts/*.sh 2>/dev/null || true
    fi
}

prepare_linux_tree() {
    if [[ -d "$LINUX_DIR/scripts" ]]; then
        find "$LINUX_DIR/scripts" -type f -exec chmod u+x {} + 2>/dev/null || true
    fi
    if [[ -d "$LINUX_DIR/arch/riscv/kernel/vdso" ]]; then
        find "$LINUX_DIR/arch/riscv/kernel/vdso" -type f -exec chmod u+x {} + 2>/dev/null || true
    fi
    if [[ -d "$LINUX_DIR/arch/riscv/kernel/compat_vdso" ]]; then
        find "$LINUX_DIR/arch/riscv/kernel/compat_vdso" -type f -exec chmod u+x {} + 2>/dev/null || true
    fi
    if [[ -d "$LINUX_DIR/usr" ]]; then
        find "$LINUX_DIR/usr" -maxdepth 1 -type f -exec chmod u+x {} + 2>/dev/null || true
    fi
}

build_dtb() {
    mkdir -p "$OUT_DIR"
    need_tool dtc
    dtc -I dts -O dtb -o "$DTB" "$DTS"
    echo "DTB: $DTB ($(wc -c < "$DTB") bytes)"
}

build_smoke() {
    mkdir -p "$OUT_DIR"
    need_tool "${CROSS_ELF}gcc"
    need_tool "${CROSS_ELF}objdump"
    need_tool "${CROSS_ELF}objcopy"

    local elf="$OUT_DIR/m_mode_uart_smoke.elf"
    local hex="$OUT_DIR/m_mode_uart_smoke.hex"

    "${CROSS_ELF}gcc" \
        -nostdlib -nostartfiles -ffreestanding \
        -march="$SMOKE_MARCH" -mabi="$SMOKE_MABI" \
        -Wl,--build-id=none \
        -T "$SW_DIR/link.ld" \
        "$SW_DIR/m_mode_uart_smoke.S" \
        -o "$elf"

    python3 "$PROJ_DIR/scripts/elf2hex.py" "$elf" "$hex" \
        --objcopy "${CROSS_ELF}objcopy" \
        --objdump "${CROSS_ELF}objdump"
    echo "M-mode UART smoke ELF: $elf"
    echo "M-mode UART smoke HEX: $hex"
}

build_smode_hang_payload() {
    mkdir -p "$OUT_DIR"
    need_tool "${CROSS_ELF}gcc"
    need_tool "${CROSS_ELF}objcopy"

    local elf="$OUT_DIR/s_mode_hang.elf"
    local bin="$OUT_DIR/s_mode_hang.bin"

    "${CROSS_ELF}gcc" \
        -nostdlib -nostartfiles -ffreestanding \
        -march="$SMOKE_MARCH" -mabi="$SMOKE_MABI" \
        -Wl,--build-id=none \
        -Wl,-Ttext=0x0 \
        "$SW_DIR/s_mode_hang.S" \
        -o "$elf"

    "${CROSS_ELF}objcopy" -O binary "$elf" "$bin"
    echo "S-mode hang payload ELF: $elf"
    echo "S-mode hang payload BIN: $bin ($(wc -c < "$bin") bytes)"
}

build_opensbi_banner() {
    if [[ ! -d "$OPENSBI_DIR" ]]; then
        echo "ERROR: OpenSBI tree not found: $OPENSBI_DIR" >&2
        exit 1
    fi

    need_tool "${OPENSBI_CROSS}gcc"
    need_tool "${OPENSBI_CROSS}objcopy"
    need_tool "${OPENSBI_CROSS}objdump"
    prepare_opensbi_tree

    build_dtb
    build_smode_hang_payload

    local opensbi_build_dir="$OUT_DIR/opensbi_banner_build"
    local payload_bin="$OUT_DIR/s_mode_hang.bin"

    rm -rf "$opensbi_build_dir"
    make -C "$OPENSBI_DIR" O="$opensbi_build_dir" CROSS_COMPILE="$OPENSBI_CROSS" PLATFORM=generic \
        PLATFORM_RISCV_ISA="$OPENSBI_MARCH" \
        PLATFORM_RISCV_ABI="$OPENSBI_MABI" \
        FW_PAYLOAD_PATH="$payload_bin" \
        FW_FDT_PATH="$DTB" \
        FW_TEXT_START=0x80000000 \
        FW_PAYLOAD_OFFSET="$OPENSBI_PAYLOAD_OFFSET" \
        FW_PAYLOAD_FDT_ADDR="$OPENSBI_FDT_ADDR" \
        -j"$NPROC"

    local opensbi_elf="$opensbi_build_dir/platform/generic/firmware/fw_payload.elf"
    cp "$opensbi_elf" "$OUT_DIR/fw_payload_opensbi_banner.elf"
    "${OPENSBI_CROSS}objcopy" -O binary "$opensbi_elf" "$OUT_DIR/fw_payload_opensbi_banner.bin"
    python3 "$PROJ_DIR/scripts/elf2hex.py" "$opensbi_elf" "$OUT_DIR/fw_payload_opensbi_banner.hex" \
        --objcopy "${OPENSBI_CROSS}objcopy" \
        --objdump "${OPENSBI_CROSS}objdump"
    echo "OpenSBI banner ELF: $OUT_DIR/fw_payload_opensbi_banner.elf"
    echo "OpenSBI banner HEX: $OUT_DIR/fw_payload_opensbi_banner.hex"
}

build_linux() {
    if [[ ! -d "$LINUX_DIR" ]]; then
        echo "ERROR: Linux tree not found: $LINUX_DIR" >&2
        exit 1
    fi
    if [[ ! -d "$OPENSBI_DIR" ]]; then
        echo "ERROR: OpenSBI tree not found: $OPENSBI_DIR" >&2
        exit 1
    fi

    need_tool "${CROSS_LINUX}gcc"
    need_tool "${CROSS_LINUX}objcopy"
    need_tool "${CROSS_LINUX}objdump"
    prepare_linux_tree

    build_dtb

    local initramfs_dir="$OUT_DIR/initramfs"
    mkdir -p "$initramfs_dir/dev" "$initramfs_dir/proc" "$initramfs_dir/sys"
    "${CROSS_LINUX}gcc" -static -Os -s \
        "$SW_DIR/initramfs/init.c" \
        -o "$initramfs_dir/init"
    chmod 0755 "$initramfs_dir/init"

    local simcfg
    simcfg="$(mktemp /tmp/rv64gc_v2_linux.XXXXXX.config)"
    trap "rm -f '$simcfg'" EXIT
    cat > "$simcfg" <<SIMCFG
CONFIG_SMP=n
CONFIG_MODULES=n
CONFIG_PRINTK=y
CONFIG_MMU=y
CONFIG_NONPORTABLE=y
CONFIG_PORTABLE=n
CONFIG_RELOCATABLE=y
CONFIG_PGTABLE_LEVELS=4
CONFIG_RISCV_ISA_C=y
CONFIG_RISCV_ISA_V=n
CONFIG_RISCV_ISA_ZBB=n
CONFIG_RISCV_ISA_ZICBOM=n
CONFIG_RISCV_ISA_ZICBOZ=n
CONFIG_RISCV_ISA_SVNAPOT=n
CONFIG_RISCV_ISA_SVPBMT=n
CONFIG_RISCV_ISA_FALLBACK=y
CONFIG_SERIAL_8250=y
CONFIG_SERIAL_8250_CONSOLE=y
CONFIG_SERIAL_EARLYCON=y
CONFIG_SERIAL_EARLYCON_RISCV_SBI=y
CONFIG_HVC_RISCV_SBI=y
CONFIG_RISCV_SBI_V01=y
CONFIG_RISCV_TIMER=y
CONFIG_INITRAMFS_SOURCE="$initramfs_dir"
CONFIG_BLK_DEV_INITRD=y
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y
CONFIG_TTY=y
CONFIG_VT=n
CONFIG_SWAP=n
CONFIG_NET=n
CONFIG_INET=n
CONFIG_USB=n
CONFIG_DRM=n
CONFIG_FB=n
CONFIG_INPUT=n
CONFIG_EXT4_FS=n
CONFIG_NFS_FS=n
CONFIG_EFI=n
CONFIG_ACPI=n
CONFIG_HW_RANDOM=n
CONFIG_IOMMU_SUPPORT=n
CONFIG_COMPAT=n
CONFIG_DEBUG_INFO_NONE=y
SIMCFG

    make -C "$LINUX_DIR" ARCH=riscv CROSS_COMPILE="$CROSS_LINUX" defconfig -j"$NPROC"
    (
        cd "$LINUX_DIR"
        scripts/kconfig/merge_config.sh -m .config "$simcfg"
    )
    make -C "$LINUX_DIR" ARCH=riscv CROSS_COMPILE="$CROSS_LINUX" olddefconfig
    make -C "$LINUX_DIR" ARCH=riscv CROSS_COMPILE="$CROSS_LINUX" -j"$NPROC" Image

    local kernel_image="$LINUX_DIR/arch/riscv/boot/Image"
    local opensbi_build_dir="$OUT_DIR/opensbi_linux_build"
    prepare_opensbi_tree
    rm -rf "$opensbi_build_dir"
    make -C "$OPENSBI_DIR" O="$opensbi_build_dir" CROSS_COMPILE="$OPENSBI_CROSS" PLATFORM=generic \
        PLATFORM_RISCV_ISA="$OPENSBI_MARCH" \
        PLATFORM_RISCV_ABI="$OPENSBI_MABI" \
        FW_PAYLOAD_PATH="$kernel_image" \
        FW_FDT_PATH="$DTB" \
        FW_TEXT_START=0x80000000 \
        FW_PAYLOAD_OFFSET="$LINUX_PAYLOAD_OFFSET" \
        FW_PAYLOAD_FDT_ADDR="$LINUX_FDT_ADDR" \
        -j"$NPROC"

    local opensbi_elf="$opensbi_build_dir/platform/generic/firmware/fw_payload.elf"
    cp "$opensbi_elf" "$OUT_DIR/fw_payload.elf"
    "${OPENSBI_CROSS}objcopy" -O binary "$opensbi_elf" "$OUT_DIR/fw_payload.bin"
    python3 "$PROJ_DIR/scripts/elf2hex.py" "$opensbi_elf" "$OUT_DIR/fw_payload.hex" \
        --objcopy "${OPENSBI_CROSS}objcopy" \
        --objdump "${OPENSBI_CROSS}objdump"
    echo "OpenSBI payload ELF: $OUT_DIR/fw_payload.elf"
    echo "OpenSBI payload HEX: $OUT_DIR/fw_payload.hex"
}

if [[ "$MODE" == "clean" ]]; then
    rm -rf "$OUT_DIR"
    exit 0
fi

if [[ "$MODE" == "smoke" || "$MODE" == "all" ]]; then
    build_smoke
fi

if [[ "$MODE" == "opensbi" || "$MODE" == "all" ]]; then
    build_opensbi_banner
fi

if [[ "$MODE" == "linux" || "$MODE" == "all" ]]; then
    build_linux
fi

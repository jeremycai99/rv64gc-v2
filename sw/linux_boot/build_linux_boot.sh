#!/usr/bin/env bash
# Build Stage 3 Linux boot software artifacts for rv64gc-v2.
set -euo pipefail

MODE="smoke"
case "${1:-}" in
    --smoke|"")
        MODE="smoke"
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
        echo "usage: $0 [--smoke|--linux|--all|--clean]" >&2
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
SMOKE_MARCH="${SMOKE_MARCH:-rv64gc_zicsr_zifencei}"
NPROC="${NPROC:-$(nproc)}"

need_tool() {
    local tool="$1"
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: required tool not found: $tool" >&2
        exit 1
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
        -march="$SMOKE_MARCH" -mabi=lp64d \
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

    build_dtb

    local initramfs_dir="$OUT_DIR/initramfs"
    mkdir -p "$initramfs_dir/dev" "$initramfs_dir/proc" "$initramfs_dir/sys"
    "${CROSS_LINUX}gcc" -static -Os -s \
        "$SW_DIR/initramfs/init.c" \
        -o "$initramfs_dir/init"
    chmod 0755 "$initramfs_dir/init"

    local simcfg
    simcfg="$(mktemp /tmp/rv64gc_v2_linux.XXXXXX.config)"
    trap 'rm -f "$simcfg"' EXIT
    cat > "$simcfg" <<SIMCFG
CONFIG_SMP=n
CONFIG_MODULES=n
CONFIG_PRINTK=y
CONFIG_MMU=y
CONFIG_RELOCATABLE=y
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
CONFIG_USB=n
CONFIG_DRM=n
CONFIG_FB=n
CONFIG_INPUT=n
CONFIG_HW_RANDOM=n
CONFIG_IOMMU_SUPPORT=n
CONFIG_COMPAT=n
CONFIG_DEBUG_INFO_NONE=y
SIMCFG

    make -C "$LINUX_DIR" ARCH=riscv CROSS_COMPILE="$CROSS_LINUX" defconfig -j"$NPROC"
    "$LINUX_DIR/scripts/kconfig/merge_config.sh" -m "$LINUX_DIR/.config" "$simcfg"
    make -C "$LINUX_DIR" ARCH=riscv CROSS_COMPILE="$CROSS_LINUX" olddefconfig
    make -C "$LINUX_DIR" ARCH=riscv CROSS_COMPILE="$CROSS_LINUX" -j"$NPROC" Image

    local kernel_image="$LINUX_DIR/arch/riscv/boot/Image"
    make -C "$OPENSBI_DIR" CROSS_COMPILE="$CROSS_LINUX" PLATFORM=generic \
        FW_PAYLOAD_PATH="$kernel_image" \
        FW_FDT_PATH="$DTB" \
        FW_TEXT_START=0x80000000 \
        FW_PAYLOAD_OFFSET=0x200000 \
        FW_PAYLOAD_FDT_ADDR=0x86000000 \
        -j"$NPROC"

    local opensbi_elf="$OPENSBI_DIR/build/platform/generic/firmware/fw_payload.elf"
    cp "$opensbi_elf" "$OUT_DIR/fw_payload.elf"
    "${CROSS_LINUX}objcopy" -O binary "$opensbi_elf" "$OUT_DIR/fw_payload.bin"
    python3 "$PROJ_DIR/scripts/elf2hex.py" "$opensbi_elf" "$OUT_DIR/fw_payload.hex" \
        --objcopy "${CROSS_LINUX}objcopy" \
        --objdump "${CROSS_LINUX}objdump"
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

if [[ "$MODE" == "linux" || "$MODE" == "all" ]]; then
    build_linux
fi

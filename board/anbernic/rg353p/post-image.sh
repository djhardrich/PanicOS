#!/usr/bin/env bash
# Buildroot post-image for Anbernic RG353P (Rockchip RK3566).
# Buildroot calls post-image scripts as:
#   $0 $BINARIES_DIR $BR2_ROOTFS_POST_SCRIPT_ARGS $BR2_ROOTFS_POST_IMAGE_SCRIPT_ARGS
# So $1 = BINARIES_DIR (also exported as env), $2 = our genimage template path.
# CWD when this script runs is the Buildroot source tree, NOT $BINARIES_DIR.

set -euo pipefail

shift  # drop the BINARIES_DIR arg; we use the env var.
GENIMAGE_TEMPLATE="$1"
: "${BINARIES_DIR:?BINARIES_DIR not set by Buildroot}"
SOC="rockchip-rk3566"

# Read the kernel flavor (mainline | vendor) from Buildroot .config so the
# DTB-handling logic can dispatch.
read_kconfig() {
    local key="$1" def="$2"
    grep "^${key}=" "$BR2_CONFIG" | head -1 | cut -d= -f2- | tr -d '"' || echo "$def"
}
KERNEL_FLAVOR="$(read_kconfig PANICOS_KERNEL_FLAVOR_NAME mainline)"

if [ "$KERNEL_FLAVOR" = "vendor" ]; then
    # TODO(Task 5): Vendor (Knulli BSP) kernel flavor for RK3566 is not yet implemented.
    # When it is, the vendor BSP DTB name should go here. Stub out so the build
    # fails explicitly rather than silently using the wrong DTB.
    echo "error: vendor kernel flavor for RK3566 is not yet implemented" >&2
    exit 1
else
    DEFAULT_DTB="rk3566-anbernic-rg353p.dtb"
fi

echo ">>> post-image: assembling RG353P disk image (kernel: $KERNEL_FLAVOR)"

# Buildroot's uboot package with NEEDS_ROCKCHIP_RKBIN installs u-boot-rockchip.bin
# into BINARIES_DIR via UBOOT_INSTALL_UBOOT_ROCKCHIP_BIN hook. Verify it's there.
if [ ! -f "$BINARIES_DIR/u-boot-rockchip.bin" ]; then
    # Fallback: try fetching directly from the uboot build dir (defensive).
    UBOOT_BUILD_DIR="${BUILD_DIR:-$(dirname "$BINARIES_DIR")/build}/uboot-custom"
    if [ -f "$UBOOT_BUILD_DIR/u-boot-rockchip.bin" ]; then
        cp "$UBOOT_BUILD_DIR/u-boot-rockchip.bin" "$BINARIES_DIR/"
    else
        echo "error: u-boot-rockchip.bin not found in $BINARIES_DIR or $UBOOT_BUILD_DIR" >&2
        exit 1
    fi
fi

mkdir -p "$BINARIES_DIR/dtbs/$SOC"
cp "$BINARIES_DIR"/*.dtb "$BINARIES_DIR/dtbs/$SOC/" 2>/dev/null || true

cp "$BINARIES_DIR/dtbs/$SOC/$DEFAULT_DTB" "$BINARIES_DIR/dtb.img"

cp "$BR2_EXTERNAL_PANICOS_PATH/board/anbernic/rg353p/panicos-active.cfg" \
   "$BINARIES_DIR/panicos-active.cfg"

# RK3566 U-Boot reads extlinux or a u-boot script from the boot partition.
# We use a simple boot.scr for compatibility with both Generic and Specific
# U-Boot tracks. The kernel Image and DTB are loaded from FAT.
cat > "$BINARIES_DIR/boot.cmd" <<'EOF'
setenv bootargs "console=tty1 console=ttyS2,1500000 panic=10"
fatload mmc 0:1 ${kernel_addr_r} Image
fatload mmc 0:1 ${fdt_addr_r} dtb.img
booti ${kernel_addr_r} - ${fdt_addr_r}
EOF
mkimage -A arm64 -O linux -T script -C none -d "$BINARIES_DIR/boot.cmd" \
    "$BINARIES_DIR/boot.scr" >/dev/null

# Stage the squashfs into a system staging dir for genimage to package.
SYSTEM_STAGE="$BINARIES_DIR/system-staging"
mkdir -p "$SYSTEM_STAGE"
GITREV="$(git -C "$BR2_EXTERNAL_PANICOS_PATH" describe --always --dirty 2>/dev/null || echo unknown)"
cp "$BINARIES_DIR/rootfs.squashfs" \
   "$SYSTEM_STAGE/panicos-rg353p-minimal.squashfs"

# Pull partition sizes from Buildroot's .config.
export PANICOS_BOOT_PARTITION_SIZE_MB="$(read_kconfig PANICOS_BOOT_PARTITION_SIZE_MB 256)"
export PANICOS_SYSTEM_PARTITION_SIZE_MB="$(read_kconfig PANICOS_SYSTEM_PARTITION_SIZE_MB 8192)"
export PANICOS_OVERLAY_PARTITION_INITIAL_SIZE_MB="$(read_kconfig PANICOS_OVERLAY_PARTITION_INITIAL_SIZE_MB 64)"

GENIMAGE_CFG="$BINARIES_DIR/genimage.cfg"
envsubst < "$GENIMAGE_TEMPLATE" > "$GENIMAGE_CFG"

GENIMAGE_TMP="$BINARIES_DIR/genimage.tmp"
rm -rf "$GENIMAGE_TMP"
genimage \
    --rootpath "$SYSTEM_STAGE" \
    --tmppath "$GENIMAGE_TMP" \
    --inputpath "$BINARIES_DIR" \
    --outputpath "$BINARIES_DIR" \
    --config "$GENIMAGE_CFG"

gzip -f -9 "$BINARIES_DIR/panicos-rg353p-minimal.img"
mv "$BINARIES_DIR/panicos-rg353p-minimal.img.gz" \
   "$BINARIES_DIR/panicos-rg353p-minimal-$GITREV.img.gz"

echo ">>> post-image done: $BINARIES_DIR/panicos-rg353p-minimal-$GITREV.img.gz"

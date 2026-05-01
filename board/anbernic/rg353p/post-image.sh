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

# Switch to extlinux.conf (plain text, editable on FAT) — no boot.scr.
mkdir -p "$BINARIES_DIR/extlinux"
cat > "$BINARIES_DIR/extlinux/extlinux.conf" <<'EOF'
LABEL PanicOS
  LINUX /Image
  FDT /dtb.img
  APPEND console=ttyS2,1500000 console=tty1 quiet loglevel=3 panic=0 pause_on_oops=300
EOF

GITREV="$(git -C "$BR2_EXTERNAL_PANICOS_PATH" describe --always --dirty 2>/dev/null || echo unknown)"
FLAVOR="$(read_kconfig PANICOS_FLAVOR_NAME minimal)"
export PANICOS_OUTPUT_NAME="panicos-rg353p-${FLAVOR}"
cp "$BINARIES_DIR/rootfs.squashfs" \
   "$BINARIES_DIR/${PANICOS_OUTPUT_NAME}.squashfs"

# panicos-active.cfg ships with IMAGE= pointing at the minimal squashfs by
# default. Rewrite to point at this build's flavor so a fresh flash boots
# straight into it without manual editing.
sed -i "s|^IMAGE=.*|IMAGE=${PANICOS_OUTPUT_NAME}.squashfs|" \
    "$BINARIES_DIR/panicos-active.cfg"

# Ship the wifi-config template on the boot vfat so users can fill in
# SSID/PSK on a PC after flashing without rebuilding. The template is
# entirely commented-out by default — boot is wifi-less until edited.
cp "$BR2_EXTERNAL_PANICOS_PATH/package/panicos-wifi-config/panicos-wifi.cfg.template" \
   "$BINARIES_DIR/panicos-wifi.cfg"

export PANICOS_BOOT_PARTITION_SIZE_MB="$(read_kconfig PANICOS_BOOT_PARTITION_SIZE_MB 6144)"
export PANICOS_STORAGE_PARTITION_INITIAL_SIZE_MB="$(read_kconfig PANICOS_STORAGE_PARTITION_INITIAL_SIZE_MB 64)"

GENIMAGE_CFG="$BINARIES_DIR/genimage.cfg"
envsubst < "$GENIMAGE_TEMPLATE" > "$GENIMAGE_CFG"

GENIMAGE_TMP="$BINARIES_DIR/genimage.tmp"
GENIMAGE_ROOT="$BINARIES_DIR/genimage.root"
rm -rf "$GENIMAGE_TMP" "$GENIMAGE_ROOT"
mkdir -p "$GENIMAGE_ROOT"
# --rootpath must point at an existing dir; genimage cp's it into the tmp
# tree even when no partition references it. Our two-partition layout
# stages everything via --inputpath (BINARIES_DIR), so rootpath is just an
# empty placeholder. Without this genimage falls back to $BUILDROOT/root,
# which buildroot doesn't create, and post-image fails with cp ENOENT.
genimage \
    --rootpath "$GENIMAGE_ROOT" \
    --tmppath "$GENIMAGE_TMP" \
    --inputpath "$BINARIES_DIR" \
    --outputpath "$BINARIES_DIR" \
    --config "$GENIMAGE_CFG"

# Rename .img to final name BEFORE gzip so the inner stored filename
# matches the outer .gz wrapper (otherwise archive managers like
# Balena Etcher extract into a folder).
mv "$BINARIES_DIR/${PANICOS_OUTPUT_NAME}.img" \
   "$BINARIES_DIR/${PANICOS_OUTPUT_NAME}-$GITREV.img"
gzip -f -9 "$BINARIES_DIR/${PANICOS_OUTPUT_NAME}-$GITREV.img"

echo ">>> post-image done: $BINARIES_DIR/${PANICOS_OUTPUT_NAME}-$GITREV.img.gz"

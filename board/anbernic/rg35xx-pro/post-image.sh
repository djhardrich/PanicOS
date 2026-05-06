#!/usr/bin/env bash
# Buildroot post-image for Anbernic RG35XX Pro.
# Buildroot calls post-image scripts as:
#   $0 $BINARIES_DIR $BR2_ROOTFS_POST_SCRIPT_ARGS $BR2_ROOTFS_POST_IMAGE_SCRIPT_ARGS
# So $1 = BINARIES_DIR (also exported as env), $2 = our genimage template path.
# CWD when this script runs is the Buildroot source tree, NOT $BINARIES_DIR.

set -euo pipefail

shift  # drop the BINARIES_DIR arg; we use the env var.
GENIMAGE_TEMPLATE="$1"
: "${BINARIES_DIR:?BINARIES_DIR not set by Buildroot}"
SOC="allwinner-h700"

# Read the kernel flavor (mainline | vendor) from Buildroot .config so the
# DTB-handling logic can dispatch. mainline produces ~17 mainline-named DTBs
# (sun50i-h700-anbernic-*); vendor produces a single BSP DTB (sun50iw9p1-soc).
read_kconfig() {
    local key="$1" def="$2"
    grep "^${key}=" "$BR2_CONFIG" | head -1 | cut -d= -f2- | tr -d '"' || echo "$def"
}
KERNEL_FLAVOR="$(read_kconfig PANICOS_KERNEL_FLAVOR_NAME mainline)"

if [ "$KERNEL_FLAVOR" = "vendor" ]; then
    DEFAULT_DTB="sun50iw9p1-soc.dtb"
else
    DEFAULT_DTB="sun50i-h700-anbernic-rg35xx-pro.dtb"
fi

echo ">>> post-image: assembling RG35XX Pro disk image (kernel: $KERNEL_FLAVOR)"

# Buildroot's u-boot package only copies a subset of build outputs. The
# combined SPL+ATF+U-Boot blob u-boot-sunxi-with-spl.bin is produced by
# binman during U-Boot's build but isn't in UBOOT_BINS, so we fetch it
# directly from the build dir.
UBOOT_BUILD_DIR="${BUILD_DIR:-$(dirname "$BINARIES_DIR")/build}/uboot-custom"
if [ -f "$UBOOT_BUILD_DIR/u-boot-sunxi-with-spl.bin" ]; then
    cp "$UBOOT_BUILD_DIR/u-boot-sunxi-with-spl.bin" "$BINARIES_DIR/"
elif [ ! -f "$BINARIES_DIR/u-boot-sunxi-with-spl.bin" ]; then
    echo "error: u-boot-sunxi-with-spl.bin not found in $UBOOT_BUILD_DIR" >&2
    exit 1
fi

mkdir -p "$BINARIES_DIR/dtbs/$SOC"
cp "$BINARIES_DIR"/*.dtb "$BINARIES_DIR/dtbs/$SOC/" 2>/dev/null || true

cp "$BINARIES_DIR/dtbs/$SOC/$DEFAULT_DTB" "$BINARIES_DIR/dtb.img"

cp "$BR2_EXTERNAL_PANICOS_PATH/board/anbernic/rg35xx-pro/panicos-active.cfg" \
   "$BINARIES_DIR/panicos-active.cfg"

# Use extlinux.conf (plain text, editable on the FAT without reflashing)
# rather than a compiled boot.scr. U-Boot's distro_bootcmd scans for
# /extlinux/extlinux.conf via CONFIG_CMD_SYSBOOT — same path ROCKNIX uses.
mkdir -p "$BINARIES_DIR/extlinux"
cat > "$BINARIES_DIR/extlinux/extlinux.conf" <<'EOF'
LABEL PanicOS
  LINUX /Image
  FDT /dtb.img
  APPEND console=ttyS0,115200 console=tty1 quiet loglevel=3 panic=0 pause_on_oops=300 rtw88_core.disable_lps_deep=Y
EOF

# Drop the squashfs into BINARIES_DIR with its public name. genimage's
# vfat will copy this file directly into the boot partition (no separate
# system.ext4 — the squashfs lives on the boot FAT next to the kernel,
# which means PC users can drag-and-drop new flavors).
GITREV="$(git -C "$BR2_EXTERNAL_PANICOS_PATH" describe --always --dirty 2>/dev/null || echo unknown)"
FLAVOR="$(read_kconfig PANICOS_FLAVOR_NAME minimal)"
export PANICOS_OUTPUT_NAME="panicos-rg35xx-pro-${FLAVOR}"
cp "$BINARIES_DIR/rootfs.squashfs" \
   "$BINARIES_DIR/${PANICOS_OUTPUT_NAME}.squashfs"

# panicos-active.cfg ships with IMAGE= pointing at the minimal squashfs by
# default. Rewrite to point at this build's flavor so a fresh flash boots
# straight into it without manual editing.
sed -i "s|^IMAGE=.*|IMAGE=${PANICOS_OUTPUT_NAME}.squashfs|" \
    "$BINARIES_DIR/panicos-active.cfg"

# Create a kernel modules + firmware tarball on the boot vfat.
# The PanicOS initramfs detects foreign squashfs flavors (e.g. Debian) that
# lack /lib/modules/<kver> and auto-injects this tarball into their overlayfs
# upper layer on first boot, so device drivers (wifi, joypad, etc.) work
# without baking modules into every squashfs variant.
KVER=$(cat "${BUILD_DIR:-$(dirname "$BINARIES_DIR")/build}/linux-"*/include/config/kernel.release 2>/dev/null | head -1)
if [ -n "$KVER" ]; then
    MODULES_SRC="${TARGET_DIR}/usr/lib/modules/$KVER"
    FW_SRC="${TARGET_DIR}/usr/lib/firmware"
    MODULES_TAR="$BINARIES_DIR/panicos-modules.tar.gz"
    TAR_ARGS=()
    [ -d "$MODULES_SRC" ] && TAR_ARGS+=(-C "$TARGET_DIR" "usr/lib/modules/$KVER")
    [ -d "$FW_SRC"      ] && TAR_ARGS+=(-C "$TARGET_DIR" "usr/lib/firmware")
    if [ ${#TAR_ARGS[@]} -gt 0 ]; then
        tar -czf "$MODULES_TAR" "${TAR_ARGS[@]}"
        echo ">>> post-image: panicos-modules.tar.gz ($KVER, $(du -sh "$MODULES_TAR" | cut -f1))"
    fi
fi

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
# matches the outer .gz wrapper. Mismatch causes archive managers
# (Balena Etcher etc.) to extract into a folder.
mv "$BINARIES_DIR/${PANICOS_OUTPUT_NAME}.img" \
   "$BINARIES_DIR/${PANICOS_OUTPUT_NAME}-$GITREV.img"
gzip -f -9 "$BINARIES_DIR/${PANICOS_OUTPUT_NAME}-$GITREV.img"

echo ">>> post-image done: $BINARIES_DIR/${PANICOS_OUTPUT_NAME}-$GITREV.img.gz"

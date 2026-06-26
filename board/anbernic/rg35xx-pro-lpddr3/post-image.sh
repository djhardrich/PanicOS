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

echo ">>> post-image: assembling RG35XX Pro LPDDR3 disk image (kernel: $KERNEL_FLAVOR)"

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

cp "$BR2_EXTERNAL_PANICOS_PATH/board/anbernic/rg35xx-pro-lpddr3/panicos-active.cfg" \
   "$BINARIES_DIR/panicos-active.cfg"

# Switch to extlinux.conf (plain text editable on the FAT) like rg35xx-pro.
# Two kernels can coexist on the FAT: /Image (default, non-RT) and /Image-rt
# (opt-in PREEMPT_RT). image-variant symlinks Image-rt + the RT module tarball
# in from the base build, so when present we emit a second LABEL + a
# DEFAULT/TIMEOUT header for Switch-Kernel.sh to flip.
APPEND_LINE="console=ttyS0,115200 console=tty1 quiet loglevel=3 panic=0 pause_on_oops=300 rtw88_core.disable_lps_deep=Y"
mkdir -p "$BINARIES_DIR/extlinux"
RT_LABEL=""
export PANICOS_RT_FILES=""
if [ -f "$BINARIES_DIR/Image-rt" ]; then
    RT_LABEL=$(printf '\n\nLABEL PanicOS-RT\n  LINUX /Image-rt\n  FDT /dtb.img\n  APPEND %s' "$APPEND_LINE")
    # Tab-indented to match the genimage.cfg.in files block.
    PANICOS_RT_FILES=$(printf '\t\t\t"Image-rt",\n\t\t\t"panicos-modules-rt.tar.gz",')
    export PANICOS_RT_FILES
fi
# DEFAULT/TIMEOUT are emitted unconditionally (even with no Image-rt) so
# Switch-Kernel.sh always has a DEFAULT line to rewrite; harmless no-op with a
# single LABEL.
cat > "$BINARIES_DIR/extlinux/extlinux.conf" <<EOF
DEFAULT PanicOS
TIMEOUT 0

LABEL PanicOS
  LINUX /Image
  FDT /dtb.img
  APPEND ${APPEND_LINE}${RT_LABEL}
EOF

GITREV="$(git -C "$BR2_EXTERNAL_PANICOS_PATH" describe --always --dirty 2>/dev/null || echo unknown)"
FLAVOR="$(read_kconfig PANICOS_FLAVOR_NAME minimal)"
export PANICOS_OUTPUT_NAME="panicos-rg35xx-pro-lpddr3-${FLAVOR}"
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

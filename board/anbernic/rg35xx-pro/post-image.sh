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

cat > "$BINARIES_DIR/boot.cmd" <<'EOF'
setenv bootargs "console=ttyS0,115200 console=tty1 loglevel=8 boot_delay=500 initcall_debug ignore_loglevel panic=0 oops=panic pause_on_oops=300"
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
   "$SYSTEM_STAGE/panicos-rg35xx-pro-minimal.squashfs"

# Pull partition sizes from Buildroot's .config.
read_kconfig() {
    local key="$1" def="$2"
    grep "^${key}=" "$BR2_CONFIG" | head -1 | cut -d= -f2- | tr -d '"' || echo "$def"
}
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

# Rename .img to final name BEFORE gzip so the inner stored filename
# matches the outer .gz wrapper. Mismatch causes archive managers
# (Balena Etcher etc.) to extract into a folder.
mv "$BINARIES_DIR/panicos-rg35xx-pro-minimal.img" \
   "$BINARIES_DIR/panicos-rg35xx-pro-minimal-$GITREV.img"
gzip -f -9 "$BINARIES_DIR/panicos-rg35xx-pro-minimal-$GITREV.img"

echo ">>> post-image done: $BINARIES_DIR/panicos-rg35xx-pro-minimal-$GITREV.img.gz"

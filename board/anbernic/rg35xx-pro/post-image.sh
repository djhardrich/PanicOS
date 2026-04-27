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
DEFAULT_DTB="sun50i-h700-anbernic-rg35xx-pro.dtb"

echo ">>> post-image: assembling RG35XX Pro disk image"

mkdir -p "$BINARIES_DIR/dtbs/$SOC"
cp "$BINARIES_DIR"/*.dtb "$BINARIES_DIR/dtbs/$SOC/" 2>/dev/null || true

cp "$BINARIES_DIR/dtbs/$SOC/$DEFAULT_DTB" "$BINARIES_DIR/dtb.img"

cp "$BR2_EXTERNAL_PANICOS_PATH/board/anbernic/rg35xx-pro/panicos-active.cfg" \
   "$BINARIES_DIR/panicos-active.cfg"

cat > "$BINARIES_DIR/boot.cmd" <<'EOF'
setenv bootargs "console=ttyS0,115200 panic=10"
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

gzip -f -9 "$BINARIES_DIR/panicos-rg35xx-pro-minimal.img"
mv "$BINARIES_DIR/panicos-rg35xx-pro-minimal.img.gz" \
   "$BINARIES_DIR/panicos-rg35xx-pro-minimal-$GITREV.img.gz"

echo ">>> post-image done: $BINARIES_DIR/panicos-rg35xx-pro-minimal-$GITREV.img.gz"

#!/usr/bin/env bash
# Buildroot post-image for TrimUI Brick (Allwinner A133) — blob-staging mode.
# All kernel and bootloader blobs are pre-built; no kernel/U-Boot build occurs.
# post-image-blobs.sh stages them into BINARIES_DIR, then genimage assembles
# the final disk image.

set -euo pipefail

shift  # drop the BINARIES_DIR arg; we use the env var.
GENIMAGE_TEMPLATE="$1"
: "${BINARIES_DIR:?BINARIES_DIR not set by Buildroot}"
: "${BR2_EXTERNAL_PANICOS_PATH:?BR2_EXTERNAL_PANICOS_PATH not set by Buildroot}"

SOC="allwinner-a133"
KERNEL_FLAVOR="vendor"
DEVICE_NAME="trimui-brick"

# Source the blob-staging helper and stage all prebuilt files into BINARIES_DIR.
. "$BR2_EXTERNAL_PANICOS_PATH/soc/_lib/post-image-blobs.sh"

if ! panicos_blob_mode_stage; then
    echo "error: blob staging failed — prebuilt dir not found for $DEVICE_NAME" >&2
    exit 1
fi

echo ">>> post-image: assembling TrimUI Brick disk image (blob mode)"

# panicos-active.cfg goes into the boot VFAT so the initramfs knows which
# squashfs to mount.
cp "$BR2_EXTERNAL_PANICOS_PATH/board/trimui/trimui-brick/panicos-active.cfg" \
   "$BINARIES_DIR/panicos-active.cfg"

# Stage squashfs into a system staging dir for genimage to package.
SYSTEM_STAGE="$BINARIES_DIR/system-staging"
mkdir -p "$SYSTEM_STAGE"
cp "$BINARIES_DIR/rootfs.squashfs" \
   "$SYSTEM_STAGE/panicos-trimui-brick-minimal.squashfs"

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

GITREV="$(git -C "$BR2_EXTERNAL_PANICOS_PATH" describe --always --dirty 2>/dev/null || echo unknown)"
gzip -f -9 "$BINARIES_DIR/panicos-trimui-brick-minimal.img"
mv "$BINARIES_DIR/panicos-trimui-brick-minimal.img.gz" \
   "$BINARIES_DIR/panicos-trimui-brick-minimal-$GITREV.img.gz"

echo ">>> post-image done: $BINARIES_DIR/panicos-trimui-brick-minimal-$GITREV.img.gz"

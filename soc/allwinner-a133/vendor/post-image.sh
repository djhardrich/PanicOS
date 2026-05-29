#!/usr/bin/env bash
# Shared post-image for all Allwinner A133 vendor devices.
#
# All A133 devices boot via Android bootimg on the boot-fw partition
# (bootcmd=run setargs_nand boot_normal). This script:
#   1. Stages partition blobs from vendor/prebuilt/<DEVICE_NAME>/
#   2. Repacks boot.img with the PanicOS initramfs (replaces Knulli ramdisk)
#   3. Runs genimage to produce the final SD card image
#
# Called by Buildroot as:
#   post-image.sh <BINARIES_DIR> <GENIMAGE_TEMPLATE> <DEVICE_NAME>
#
# The GENIMAGE_TEMPLATE and DEVICE_NAME are passed via
# BR2_ROOTFS_POST_SCRIPT_ARGS in the device defconfig.fragment.

set -euo pipefail

shift  # drop the BINARIES_DIR positional arg; we use the env var
GENIMAGE_TEMPLATE="$1"
DEVICE_NAME="$2"

SOC="allwinner-a133"
KERNEL_FLAVOR="vendor"

: "${BINARIES_DIR:?BINARIES_DIR not set by Buildroot}"
: "${TARGET_DIR:?TARGET_DIR not set by Buildroot}"
: "${BR2_EXTERNAL_PANICOS_PATH:?BR2_EXTERNAL_PANICOS_PATH not set by Buildroot}"
: "${BR2_CONFIG:?BR2_CONFIG not set by Buildroot}"

. "$BR2_EXTERNAL_PANICOS_PATH/soc/_lib/post-image-blobs.sh"

if ! panicos_blob_mode_stage; then
    echo "error: blob staging failed — prebuilt dir not found for $DEVICE_NAME" >&2
    echo "  Expected: $(panicos_blob_mode_dir)" >&2
    exit 1
fi

echo ">>> post-image: assembling $DEVICE_NAME disk image (A133 vendor blob mode)"

RAMDISK="$BINARIES_DIR/panicos-bootimg-ramdisk.cpio.gz"
"$BR2_EXTERNAL_PANICOS_PATH/scripts/build-panicos-bootimg-ramdisk.sh" \
    "$TARGET_DIR" \
    "$BR2_EXTERNAL_PANICOS_PATH/panicos-initramfs/init" \
    "$RAMDISK"

VENDOR_BOOTIMG="$BR2_EXTERNAL_PANICOS_PATH/soc/$SOC/$KERNEL_FLAVOR/prebuilt/$DEVICE_NAME/partitions/boot.img"
python3 "$BR2_EXTERNAL_PANICOS_PATH/scripts/build-android-bootimg.py" \
    --vendor-bootimg "$VENDOR_BOOTIMG" \
    --ramdisk "$RAMDISK" \
    --cmdline "console=ttyS0,115200 console=tty1 quiet loglevel=3 panic=10" \
    --out "$BINARIES_DIR/partitions/boot.img"

read_kconfig() {
    local key="$1" def="$2"
    grep "^${key}=" "$BR2_CONFIG" | head -1 | cut -d= -f2- | tr -d '"' || echo "$def"
}

BOARD_DIR="$(find "$BR2_EXTERNAL_PANICOS_PATH/board" -mindepth 3 -maxdepth 3 \
    -path "*/$DEVICE_NAME" -type d | head -1)"
cp "$BOARD_DIR/panicos-active.cfg" "$BINARIES_DIR/panicos-active.cfg"

GITREV="$(git -C "$BR2_EXTERNAL_PANICOS_PATH" describe --always --dirty 2>/dev/null || echo unknown)"
FLAVOR="$(read_kconfig PANICOS_FLAVOR_NAME minimal)"
export PANICOS_OUTPUT_NAME="panicos-${DEVICE_NAME}-${FLAVOR}"
cp "$BINARIES_DIR/rootfs.squashfs" \
   "$BINARIES_DIR/${PANICOS_OUTPUT_NAME}.squashfs"

sed -i "s|^IMAGE=.*|IMAGE=${PANICOS_OUTPUT_NAME}.squashfs|" \
    "$BINARIES_DIR/panicos-active.cfg"

cp "$BR2_EXTERNAL_PANICOS_PATH/package/panicos-wifi-config/panicos-wifi.cfg.template" \
   "$BINARIES_DIR/panicos-wifi.cfg"

export PANICOS_BOOT_PARTITION_SIZE_MB="$(read_kconfig PANICOS_BOOT_PARTITION_SIZE_MB 6144)"
export PANICOS_STORAGE_PARTITION_INITIAL_SIZE_MB="$(read_kconfig PANICOS_STORAGE_PARTITION_INITIAL_SIZE_MB 64)"
export DEVICE_NAME

GENIMAGE_CFG="$BINARIES_DIR/genimage.cfg"
envsubst < "$GENIMAGE_TEMPLATE" > "$GENIMAGE_CFG"

GENIMAGE_TMP="$BINARIES_DIR/genimage.tmp"
GENIMAGE_ROOT="$BINARIES_DIR/genimage.root"
rm -rf "$GENIMAGE_TMP" "$GENIMAGE_ROOT"
mkdir -p "$GENIMAGE_ROOT"
genimage \
    --rootpath "$GENIMAGE_ROOT" \
    --tmppath "$GENIMAGE_TMP" \
    --inputpath "$BINARIES_DIR" \
    --outputpath "$BINARIES_DIR" \
    --config "$GENIMAGE_CFG"

mv "$BINARIES_DIR/${PANICOS_OUTPUT_NAME}.img" \
   "$BINARIES_DIR/${PANICOS_OUTPUT_NAME}-$GITREV.img"
gzip -f -9 "$BINARIES_DIR/${PANICOS_OUTPUT_NAME}-$GITREV.img"

echo ">>> post-image done: $BINARIES_DIR/${PANICOS_OUTPUT_NAME}-$GITREV.img.gz"

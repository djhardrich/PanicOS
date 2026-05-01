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

# Repack the vendor Android bootimg so it boots into the PanicOS initramfs
# (which then loop-mounts our squashfs from SD), instead of the vendor's
# stock TrimUI 1.0.6 ramdisk that mounts /dev/mmcblk0p4 vfat directly.
# Keeps the vendor kernel + header addresses so the vendor U-Boot in
# boot_package.fex still loads it the same way.
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

# Pull partition sizes and flavor from Buildroot's .config.
read_kconfig() {
    local key="$1" def="$2"
    grep "^${key}=" "$BR2_CONFIG" | head -1 | cut -d= -f2- | tr -d '"' || echo "$def"
}

# panicos-active.cfg goes into the boot VFAT so the initramfs knows which
# squashfs to mount.
cp "$BR2_EXTERNAL_PANICOS_PATH/board/trimui/trimui-brick/panicos-active.cfg" \
   "$BINARIES_DIR/panicos-active.cfg"

# Drop the squashfs straight into BINARIES_DIR — genimage's vfat list
# pulls it directly into the boot partition (no separate system.ext4).
GITREV="$(git -C "$BR2_EXTERNAL_PANICOS_PATH" describe --always --dirty 2>/dev/null || echo unknown)"
FLAVOR="$(read_kconfig PANICOS_FLAVOR_NAME minimal)"
export PANICOS_OUTPUT_NAME="panicos-trimui-brick-${FLAVOR}"
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

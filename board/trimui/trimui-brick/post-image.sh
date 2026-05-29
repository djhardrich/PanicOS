#!/usr/bin/env bash
# Buildroot post-image for TrimUI Brick (Allwinner A133).
# Supports two kernel flavors:
#   vendor  — all kernel blobs pre-built; boot via Android bootimg on boot-fw
#             partition (ramdisk repacked with PanicOS init; no kernel compile).
#   mainline — kernel + DTB built by Buildroot from kernel.org; initramfs baked
#              in; boot via boot.scr from VFAT (vendor U-Boot distro-boot path).
#              Vendor bootloader blobs (boot0, boot_package, env) still staged;
#              vendor boot.img kept on boot-fw partition as emergency fallback.

set -euo pipefail

shift  # drop the BINARIES_DIR arg; we use the env var.
GENIMAGE_TEMPLATE="$1"
: "${BINARIES_DIR:?BINARIES_DIR not set by Buildroot}"
: "${BR2_EXTERNAL_PANICOS_PATH:?BR2_EXTERNAL_PANICOS_PATH not set by Buildroot}"

SOC="allwinner-a133"
KERNEL_FLAVOR="vendor"
DEVICE_NAME="trimui-brick"

# Stage vendor bootloader blobs (boot0, boot_package, env, fallback boot.img).
# KERNEL_FLAVOR is always "vendor" here — we stage from vendor prebuilt
# regardless of whether the kernel itself was mainline or vendor blob.
. "$BR2_EXTERNAL_PANICOS_PATH/soc/_lib/post-image-blobs.sh"

if ! panicos_blob_mode_stage; then
    echo "error: blob staging failed — prebuilt dir not found for $DEVICE_NAME" >&2
    exit 1
fi

# Detect mainline kernel build: Buildroot outputs plain "Image" for arm64 mainline.
MAINLINE_IMAGE="$BINARIES_DIR/Image"

if [ -f "$MAINLINE_IMAGE" ]; then
    # ── Mainline kernel path ────────────────────────────────────────────────
    echo ">>> post-image: mainline kernel detected — building VFAT boot layout"

    # mkimage is built by Buildroot's host-uboot-tools package.
    MKIMAGE="${HOST_DIR}/bin/mkimage"
    if [ ! -x "$MKIMAGE" ]; then
        echo "error: mkimage not found at $MKIMAGE — add host-uboot-tools to defconfig" >&2
        exit 1
    fi

    # Stage mainline kernel and DTB under boot/ so boot.scr can load them.
    mkdir -p "$BINARIES_DIR/boot"
    cp "$MAINLINE_IMAGE" "$BINARIES_DIR/boot/Image"

    DTB_SRC="$BINARIES_DIR/allwinner/sun50i-a133-trimui-brick.dtb"
    if [ ! -f "$DTB_SRC" ]; then
        echo "error: mainline DTB not found at $DTB_SRC" >&2
        echo "  Ensure BR2_LINUX_KERNEL_INTREE_DTS_NAME contains allwinner/sun50i-a133-trimui-brick" >&2
        exit 1
    fi
    cp "$DTB_SRC" "$BINARIES_DIR/boot/sun50i-a133-trimui-brick.dtb"

    # Generate mainline boot.scr. The initramfs is built into the kernel Image
    # (CONFIG_INITRAMFS_SOURCE), so no external ramdisk is needed.
    # ttyAS0 is the A100/A133 UART name in mainline (not ttyS0).
    BOOT_CMD_TMP="$(mktemp)"
    trap 'rm -f "$BOOT_CMD_TMP"' EXIT
    cat > "$BOOT_CMD_TMP" <<'BOOTCMD'
setenv bootargs console=ttyAS0,115200 console=tty1 quiet loglevel=3 panic=10 rootwait
load ${devtype} ${devnum}:${bootpart} ${kernel_addr_r} /boot/Image
load ${devtype} ${devnum}:${bootpart} ${fdt_addr_r} /boot/sun50i-a133-trimui-brick.dtb
fdt addr ${fdt_addr_r}
fdt resize
booti ${kernel_addr_r} - ${fdt_addr_r}
BOOTCMD
    "$MKIMAGE" -A arm64 -T script -O linux -d "$BOOT_CMD_TMP" \
        "$BINARIES_DIR/boot/boot.scr"

    # The TrimUI Brick vendor env.img forces bootcmd=run setargs_nand boot_normal
    # which reads the Android boot partition directly — it never checks boot.scr.
    # Override bootcmd in env.img to run distro_bootcmd instead, which will find
    # our boot.scr on the VFAT partition. The compiled-in distro_bootcmd in the
    # vendor U-Boot binary handles MMC scanning even though env.img normally
    # suppresses it.
    VENDOR_ENV_SRC="$BR2_EXTERNAL_PANICOS_PATH/soc/$SOC/$KERNEL_FLAVOR/prebuilt/$DEVICE_NAME/partitions/env.img"
    python3 - "$VENDOR_ENV_SRC" "$BINARIES_DIR/partitions/env.img" <<'PYEOF'
import sys, struct, zlib

src, dst = sys.argv[1], sys.argv[2]
with open(src, 'rb') as f:
    data = f.read()

env_size = len(data)
env_body = data[4:]  # skip CRC32
pairs = [p.decode('latin-1') for p in env_body.split(b'\x00') if p and b'=' in p]
pairs = [p for p in pairs if not p.startswith('bootcmd=')]
pairs.append('bootcmd=run distro_bootcmd')
new_body = b'\x00'.join(p.encode('latin-1') for p in pairs) + b'\x00\x00'
new_body = new_body[:env_size - 4].ljust(env_size - 4, b'\x00')
crc = zlib.crc32(new_body) & 0xFFFFFFFF
with open(dst, 'wb') as f:
    f.write(struct.pack('<I', crc) + new_body)
PYEOF
    cp "$BINARIES_DIR/partitions/env.img" "$BINARIES_DIR/partitions/env-redund.img"

    # Vendor boot.img stays on the boot-fw partition as an emergency fallback:
    # if distro_bootcmd fails to find boot.scr, U-Boot's fallback will try the
    # Android boot partition (which still has the vendor kernel + vendor ramdisk).

    # Switch to mainline genimage template.
    GENIMAGE_TEMPLATE="$BR2_EXTERNAL_PANICOS_PATH/board/trimui/trimui-brick/genimage-mainline.cfg.in"

else
    # ── Vendor blob path (original behavior) ───────────────────────────────
    echo ">>> post-image: assembling TrimUI Brick disk image (vendor blob mode)"

    # Repack the vendor Android bootimg with the PanicOS initramfs.
    # Keeps vendor kernel + header addresses; only the ramdisk is replaced.
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
fi

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

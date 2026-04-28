#!/usr/bin/env bash
# extract-rockchip.sh — Rockchip-specific extractor
#   Extracts idbloader.img + u-boot.itb at known offsets, then mounts
#   FAT boot + ext4 rootfs to extract kernel/DTBs/modules.
#
# Usage: extract-rockchip.sh <img-or-img.gz> <work-dir>
#   <work-dir> must already exist (pre-created by caller).
#
# Bootloader layout (Rockchip conventional):
#   idbloader.img  at sector 64    (offset 32768)     — DDR + miniloader
#   u-boot.itb     at sector 16384 (offset 8 MiB)     — U-Boot FIT image

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib-format.sh"

INPUT="${1:?usage: extract-rockchip.sh <img-or-img.gz> <work-dir>}"
WORK_DIR="${2:?usage: extract-rockchip.sh <img-or-img.gz> <work-dir>}"

INPUT="$(realpath "$INPUT")"
WORK_DIR="$(realpath "$WORK_DIR")"

echo "[rockchip] extracting from $INPUT -> $WORK_DIR" >&2

# ---------------------------------------------------------------------------
# Output directories
# ---------------------------------------------------------------------------
mkdir -p "$WORK_DIR/kernel" "$WORK_DIR/modules" "$WORK_DIR/bootloader/rockchip"

# ---------------------------------------------------------------------------
# Unwrap compressed images
# ---------------------------------------------------------------------------
RAW_IMG=$(vbe_unwrap "$INPUT" "$WORK_DIR")

# ---------------------------------------------------------------------------
# Loop-mount setup using kpartx (works in --privileged containers)
# ---------------------------------------------------------------------------
LOOP_DEV=""
KPARTX_MAPS=""
MNT_BOOT=""
MNT_ROOT=""

cleanup() {
    local rc=$?
    echo "[rockchip] cleanup" >&2
    [ -n "${MNT_BOOT:-}" ] && mountpoint -q "$MNT_BOOT" && umount "$MNT_BOOT" 2>/dev/null || true
    [ -n "${MNT_ROOT:-}" ] && mountpoint -q "$MNT_ROOT" && umount "$MNT_ROOT" 2>/dev/null || true
    [ -n "${LOOP_DEV:-}" ] && kpartx -dv "$LOOP_DEV" 2>/dev/null || true
    [ -n "${LOOP_DEV:-}" ] && losetup -d "$LOOP_DEV" 2>/dev/null || true
    [ -n "${MNT_BOOT:-}" ] && rm -rf "$MNT_BOOT" 2>/dev/null || true
    [ -n "${MNT_ROOT:-}" ] && rm -rf "$MNT_ROOT" 2>/dev/null || true
    exit $rc
}
trap cleanup EXIT

LOOP_DEV=$(losetup --find --show "$RAW_IMG")
echo "[rockchip] loop device: $LOOP_DEV" >&2
KPARTX_MAPS=$(kpartx -av "$LOOP_DEV" 2>&1)
echo "[rockchip] kpartx: $KPARTX_MAPS" >&2
sleep 0.3

# ---------------------------------------------------------------------------
# Bootloader extraction (can happen before mount — reads raw img directly)
# ---------------------------------------------------------------------------
BL_DIR="$WORK_DIR/bootloader/rockchip"
IMG_SIZE=$(stat -c%s "$RAW_IMG")

# --- idbloader.img: sector 64 to sector 16383 (fills gap before u-boot.itb) ---
IDBLOADER_START_SECTOR=64
IDBLOADER_END_SECTOR=16383
IDBLOADER_SECTORS=$(( IDBLOADER_END_SECTOR - IDBLOADER_START_SECTOR + 1 ))

# Verify RKNS magic at sector 64
RKNS=$(dd if="$RAW_IMG" bs=512 skip="$IDBLOADER_START_SECTOR" count=1 2>/dev/null | \
    head -c 4 | od -A n -t x1 | tr -d ' \n' || true)

if echo "$RKNS" | grep -qi "524b4e53"; then
    echo "[rockchip] RKNS magic confirmed at sector 64" >&2
else
    echo "[rockchip] WARNING: no RKNS magic at sector 64 — writing anyway" >&2
fi
dd if="$RAW_IMG" bs=512 skip="$IDBLOADER_START_SECTOR" count="$IDBLOADER_SECTORS" \
    of="$BL_DIR/idbloader.img" 2>/dev/null
echo "[rockchip] wrote idbloader.img ($(stat -c%s "$BL_DIR/idbloader.img") bytes)" >&2

# --- u-boot.itb: sector 16384 (offset 8 MiB) ---
UBOOT_START_SECTOR=16384
UBOOT_START_BYTE=$(( UBOOT_START_SECTOR * 512 ))

if [ "$IMG_SIZE" -gt "$UBOOT_START_BYTE" ]; then
    REMAINING=$(( IMG_SIZE - UBOOT_START_BYTE ))
    UBOOT_MAX=$(( 4 * 1024 * 1024 ))
    UBOOT_SIZE=$(( REMAINING < UBOOT_MAX ? REMAINING : UBOOT_MAX ))
    UBOOT_SECTORS=$(( UBOOT_SIZE / 512 ))

    FIT_MAGIC=$(dd if="$RAW_IMG" bs=512 skip="$UBOOT_START_SECTOR" count=1 2>/dev/null | \
        head -c 4 | od -A n -t x1 | tr -d ' \n' || true)

    dd if="$RAW_IMG" bs=512 skip="$UBOOT_START_SECTOR" count="$UBOOT_SECTORS" \
        of="$BL_DIR/u-boot.itb" 2>/dev/null
    echo "[rockchip] wrote u-boot.itb ($(stat -c%s "$BL_DIR/u-boot.itb") bytes)" >&2

    if ! echo "$FIT_MAGIC" | grep -qi "d00dfeed"; then
        echo "[rockchip] NOTE: u-boot.itb magic not FIT (may be raw U-Boot or packed format)" >&2
    fi
else
    echo "[rockchip] WARNING: image too small to contain u-boot.itb at sector 16384" >&2
fi

# ---------------------------------------------------------------------------
# Partition scan using kpartx mapper devices (/dev/mapper/loopNpM)
# ---------------------------------------------------------------------------
LOOP_BASE=$(basename "$LOOP_DEV")   # e.g. loop0
BOOT_PART=""
ROOT_PART=""

# kpartx maps appear as /dev/mapper/loop0p1, loop0p2, etc.
for map in /dev/mapper/${LOOP_BASE}p*; do
    [ -b "$map" ] || continue
    FSTYPE=$(blkid -o value -s TYPE "$map" 2>/dev/null || true)
    echo "[rockchip] partition $map: fstype=${FSTYPE:-unknown}" >&2
    case "$FSTYPE" in
        vfat)
            [ -z "$BOOT_PART" ] && BOOT_PART="$map"
            ;;
        ext4)
            [ -z "$ROOT_PART" ] && ROOT_PART="$map"
            ;;
    esac
done

echo "[rockchip] boot partition: ${BOOT_PART:-none}" >&2
echo "[rockchip] root partition: ${ROOT_PART:-none}" >&2

# ---------------------------------------------------------------------------
# Extract kernel + DTBs from FAT boot partition
# ---------------------------------------------------------------------------
if [ -n "$BOOT_PART" ]; then
    MNT_BOOT=$(mktemp -d)
    mount -o ro "$BOOT_PART" "$MNT_BOOT"
    echo "[rockchip] mounted boot at $MNT_BOOT" >&2

    IMG_SRC=$(find "$MNT_BOOT" -maxdepth 2 \( -name "Image" -o -name "Image.gz" -o -name "uImage" \) | head -1 || true)
    if [ -n "$IMG_SRC" ]; then
        cp "$IMG_SRC" "$WORK_DIR/kernel/Image"
        echo "[rockchip] copied kernel: $(basename "$IMG_SRC") ($(stat -c%s "$WORK_DIR/kernel/Image") bytes)" >&2
    else
        echo "[rockchip] WARNING: no kernel Image found on boot partition" >&2
    fi

    find "$MNT_BOOT" -name "*.dtb" | while read -r dtb; do
        cp "$dtb" "$WORK_DIR/kernel/"
    done
    DTB_COUNT=$(find "$WORK_DIR/kernel" -name "*.dtb" | wc -l)
    echo "[rockchip] copied $DTB_COUNT DTB(s)" >&2

    umount "$MNT_BOOT"
    rm -rf "$MNT_BOOT"
    MNT_BOOT=""
else
    echo "[rockchip] WARNING: no FAT boot partition found" >&2
fi

# ---------------------------------------------------------------------------
# kernel-info.txt
# ---------------------------------------------------------------------------
KVER_FROM_BINARY=""
if [ -f "$WORK_DIR/kernel/Image" ]; then
    LINUX_VER=$(strings "$WORK_DIR/kernel/Image" 2>/dev/null | grep -m1 '^Linux version' || true)
    if [ -n "$LINUX_VER" ]; then
        echo "$LINUX_VER" > "$WORK_DIR/kernel/kernel-info.txt"
        KVER_FROM_BINARY=$(echo "$LINUX_VER" | awk '{print $3}')
        echo "[rockchip] kernel version: $KVER_FROM_BINARY" >&2
    else
        echo "[rockchip] WARNING: could not extract Linux version from Image" >&2
    fi
fi

# ---------------------------------------------------------------------------
# Extract /lib/modules from ext4 rootfs
# ---------------------------------------------------------------------------
KVER_MODULES=""
MODULES_FOUND=0

if [ -n "$ROOT_PART" ]; then
    MNT_ROOT=$(mktemp -d)
    mount -o ro "$ROOT_PART" "$MNT_ROOT"
    echo "[rockchip] mounted rootfs at $MNT_ROOT" >&2

    MODULES_BASE="$MNT_ROOT/lib/modules"
    if [ -d "$MODULES_BASE" ]; then
        KVER_DIR=$(find "$MODULES_BASE" -mindepth 1 -maxdepth 1 -type d | head -1 || true)
        if [ -n "$KVER_DIR" ]; then
            KVER_MODULES=$(basename "$KVER_DIR")
            echo "[rockchip] found modules: $KVER_MODULES" >&2
            tar -czf "$WORK_DIR/modules/lib-modules.tar.gz" \
                -C "$MNT_ROOT/lib/modules" "$KVER_MODULES"
            echo "$KVER_MODULES" > "$WORK_DIR/modules/kver.txt"
            MODULES_FOUND=1
        fi
    fi

    umount "$MNT_ROOT"
    rm -rf "$MNT_ROOT"
    MNT_ROOT=""
fi

if [ "$MODULES_FOUND" -eq 0 ]; then
    echo "[rockchip] no /lib/modules found in rootfs (expected for minimal images)" >&2
    echo "no modules in source rootfs" > "$WORK_DIR/modules/MISSING.txt"
    KVER="${KVER_MODULES:-${KVER_FROM_BINARY:-unknown}}"
    echo "$KVER" > "$WORK_DIR/modules/kver.txt"
fi

# ---------------------------------------------------------------------------
# extract-meta.yaml
# ---------------------------------------------------------------------------
KVER_FINAL="${KVER_MODULES:-${KVER_FROM_BINARY:-unknown}}"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
BL_FILES=$(ls "$BL_DIR/" 2>/dev/null | tr '\n' ' ')

cat > "$WORK_DIR/extract-meta.yaml" <<EOF
soc: rockchip-rk3xxx
extractor: extract-rockchip.sh
source_image: $INPUT
extracted_at: $TIMESTAMP
kernel_version: $KVER_FINAL
kernel_image: $([ -f "$WORK_DIR/kernel/Image" ] && echo true || echo false)
dtb_count: $(find "$WORK_DIR/kernel" -name "*.dtb" | wc -l)
modules_found: $([ "$MODULES_FOUND" -eq 1 ] && echo true || echo false)
bootloader: rockchip
bootloader_files: $BL_FILES
EOF

echo "[rockchip] extract-meta.yaml written" >&2
echo "[rockchip] done" >&2

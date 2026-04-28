#!/usr/bin/env bash
# extract-allwinner.sh — Allwinner-specific extractor
#   Extracts boot0 SPL, boot_package.fex (TOC1), env.img at known offsets,
#   then mounts FAT boot + ext4 rootfs to extract kernel/DTBs/modules.
#
# Usage: extract-allwinner.sh <img-or-img.gz> <work-dir>
#   <work-dir> must already exist (pre-created by caller).
#
# Bootloader layout:
#   boot0.img       at sector 16  (offset 8192)     — Allwinner SPL / eGON
#   boot_package.fex at sector 32768 (offset 16MiB) — TOC1 U-Boot package
#   env.img         at sector 144 (offset 73728)    — U-Boot environment (optional)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib-format.sh"

INPUT="${1:?usage: extract-allwinner.sh <img-or-img.gz> <work-dir>}"
WORK_DIR="${2:?usage: extract-allwinner.sh <img-or-img.gz> <work-dir>}"

INPUT="$(realpath "$INPUT")"
WORK_DIR="$(realpath "$WORK_DIR")"

echo "[allwinner] extracting from $INPUT -> $WORK_DIR" >&2

# ---------------------------------------------------------------------------
# Output directories
# ---------------------------------------------------------------------------
mkdir -p "$WORK_DIR/kernel" "$WORK_DIR/modules" "$WORK_DIR/bootloader/allwinner"

# ---------------------------------------------------------------------------
# Unwrap compressed images
# ---------------------------------------------------------------------------
RAW_IMG=$(vbe_unwrap "$INPUT" "$WORK_DIR")

# ---------------------------------------------------------------------------
# Loop-mount setup using kpartx (works in --privileged containers)
# ---------------------------------------------------------------------------
LOOP_DEV=""
MNT_BOOT=""
MNT_ROOT=""

cleanup() {
    local rc=$?
    echo "[allwinner] cleanup" >&2
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
echo "[allwinner] loop device: $LOOP_DEV" >&2
kpartx -av "$LOOP_DEV" >&2
sleep 0.3

# ---------------------------------------------------------------------------
# Bootloader extraction
# ---------------------------------------------------------------------------
BL_DIR="$WORK_DIR/bootloader/allwinner"

# --- boot0.img (Allwinner SPL / eGON) at sector 16 (offset 8192) ---
# eGON header: offset 16 from start of boot0 holds image length (4 bytes, LE)
BOOT0_SIZE_BYTES=$(dd if="$RAW_IMG" bs=1 skip=$(( 8192 + 16 )) count=4 2>/dev/null | \
    od -A n -t u4 | awk 'NF{print $1}' | head -1 || true)

if [ -z "$BOOT0_SIZE_BYTES" ] || ! echo "$BOOT0_SIZE_BYTES" | grep -qE '^[0-9]+$' || [ "$BOOT0_SIZE_BYTES" -eq 0 ] 2>/dev/null; then
    BOOT0_SIZE_BYTES=32768
    echo "[allwinner] boot0 header size unreadable, using fallback 32KiB" >&2
fi

BOOT0_SECTORS=$(( (BOOT0_SIZE_BYTES + 511) / 512 ))
echo "[allwinner] boot0: size=$BOOT0_SIZE_BYTES bytes, sectors=$BOOT0_SECTORS" >&2
dd if="$RAW_IMG" bs=512 skip=16 count="$BOOT0_SECTORS" of="$BL_DIR/boot0.img" 2>/dev/null
echo "[allwinner] wrote boot0.img ($(stat -c%s "$BL_DIR/boot0.img") bytes)" >&2

# --- boot_package.fex — detect TOC1 magic at 16 MiB (sector 32768) ---
# TOC1 magic: "TOC1" = bytes 54 4f 43 31
TOC1_OFFSET=$(( 16 * 1024 * 1024 ))
TOC1_MAGIC=$(dd if="$RAW_IMG" bs=1 skip="$TOC1_OFFSET" count=4 2>/dev/null | \
    od -A n -t x1 | tr -d ' \n' || true)

if echo "$TOC1_MAGIC" | grep -qi "^544f4331"; then
    # TOC1 total length at offset 8 from start
    TOC1_SIZE=$(dd if="$RAW_IMG" bs=1 skip=$(( TOC1_OFFSET + 8 )) count=4 2>/dev/null | \
        od -A n -t u4 | awk 'NF{print $1}' | head -1 || true)
    if [ -z "$TOC1_SIZE" ] || ! echo "$TOC1_SIZE" | grep -qE '^[0-9]+$' || [ "$TOC1_SIZE" -eq 0 ] 2>/dev/null; then
        TOC1_SIZE=$(( 4 * 1024 * 1024 ))
    fi
    TOC1_SECTORS=$(( (TOC1_SIZE + 511) / 512 ))
    echo "[allwinner] TOC1 found at 16MiB, size=$TOC1_SIZE bytes" >&2
    dd if="$RAW_IMG" bs=512 skip=32768 count="$TOC1_SECTORS" of="$BL_DIR/boot_package.fex" 2>/dev/null
    echo "[allwinner] wrote boot_package.fex ($(stat -c%s "$BL_DIR/boot_package.fex") bytes)" >&2
else
    echo "[allwinner] no TOC1 magic at 16MiB (magic=$TOC1_MAGIC) — skipping boot_package.fex" >&2
fi

# --- env.img at sector 144 (offset 73728) — U-Boot environment ---
ENV_OFFSET=73728
ENV_SIZE=131072
ENV_CHECK=$(dd if="$RAW_IMG" bs=1 skip="$ENV_OFFSET" count=4 2>/dev/null | \
    od -A n -t x1 | tr -d ' \n' || true)
# U-Boot env magic: 0x923f2153 or 0x923f2154 (little-endian in file: 53 21 3f 92)
if echo "$ENV_CHECK" | grep -qE "^(53213f92|54213f92)"; then
    dd if="$RAW_IMG" bs=1 skip="$ENV_OFFSET" count="$ENV_SIZE" of="$BL_DIR/env.img" 2>/dev/null
    echo "[allwinner] wrote env.img (128KiB)" >&2
else
    echo "[allwinner] no U-Boot env magic at sector 144 (got $ENV_CHECK) — skipping env.img" >&2
fi

# ---------------------------------------------------------------------------
# Partition scan using kpartx mapper devices
# ---------------------------------------------------------------------------
LOOP_BASE=$(basename "$LOOP_DEV")
BOOT_PART=""
ROOT_PART=""

for map in /dev/mapper/${LOOP_BASE}p*; do
    [ -b "$map" ] || continue
    FSTYPE=$(blkid -o value -s TYPE "$map" 2>/dev/null || true)
    echo "[allwinner] partition $map: fstype=${FSTYPE:-unknown}" >&2
    case "$FSTYPE" in
        vfat)
            [ -z "$BOOT_PART" ] && BOOT_PART="$map"
            ;;
        ext4)
            [ -z "$ROOT_PART" ] && ROOT_PART="$map"
            ;;
    esac
done

echo "[allwinner] boot partition: ${BOOT_PART:-none}" >&2
echo "[allwinner] root partition: ${ROOT_PART:-none}" >&2

# ---------------------------------------------------------------------------
# Extract kernel + DTBs from FAT boot partition
# ---------------------------------------------------------------------------
if [ -n "$BOOT_PART" ]; then
    MNT_BOOT=$(mktemp -d)
    mount -o ro "$BOOT_PART" "$MNT_BOOT"
    echo "[allwinner] mounted boot at $MNT_BOOT" >&2

    IMG_SRC=$(find "$MNT_BOOT" -maxdepth 2 \( -name "Image" -o -name "Image.gz" -o -name "uImage" \) | head -1 || true)
    if [ -n "$IMG_SRC" ]; then
        cp "$IMG_SRC" "$WORK_DIR/kernel/Image"
        echo "[allwinner] copied kernel: $(basename "$IMG_SRC") ($(stat -c%s "$WORK_DIR/kernel/Image") bytes)" >&2
    else
        echo "[allwinner] WARNING: no kernel Image found on boot partition" >&2
    fi

    find "$MNT_BOOT" -name "*.dtb" | while read -r dtb; do
        cp "$dtb" "$WORK_DIR/kernel/"
    done
    DTB_COUNT=$(find "$WORK_DIR/kernel" -name "*.dtb" | wc -l)
    echo "[allwinner] copied $DTB_COUNT DTB(s)" >&2

    umount "$MNT_BOOT"
    rm -rf "$MNT_BOOT"
    MNT_BOOT=""
else
    echo "[allwinner] WARNING: no FAT boot partition found" >&2
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
        echo "[allwinner] kernel version: $KVER_FROM_BINARY" >&2
    else
        echo "[allwinner] WARNING: could not extract Linux version from Image" >&2
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
    echo "[allwinner] mounted rootfs at $MNT_ROOT" >&2

    MODULES_BASE="$MNT_ROOT/lib/modules"
    if [ -d "$MODULES_BASE" ]; then
        KVER_DIR=$(find "$MODULES_BASE" -mindepth 1 -maxdepth 1 -type d | head -1 || true)
        if [ -n "$KVER_DIR" ]; then
            KVER_MODULES=$(basename "$KVER_DIR")
            echo "[allwinner] found modules: $KVER_MODULES" >&2
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
    echo "[allwinner] no /lib/modules found in rootfs (expected for minimal images)" >&2
    echo "no modules in source rootfs" > "$WORK_DIR/modules/MISSING.txt"
    KVER="${KVER_MODULES:-${KVER_FROM_BINARY:-unknown}}"
    echo "$KVER" > "$WORK_DIR/modules/kver.txt"
fi

# ---------------------------------------------------------------------------
# extract-meta.yaml
# ---------------------------------------------------------------------------
KVER_FINAL="${KVER_MODULES:-${KVER_FROM_BINARY:-unknown}}"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
BL_FILES=$(ls "$BL_DIR/" | tr '\n' ' ')

cat > "$WORK_DIR/extract-meta.yaml" <<EOF
soc: allwinner-sunxi
extractor: extract-allwinner.sh
source_image: $INPUT
extracted_at: $TIMESTAMP
kernel_version: $KVER_FINAL
kernel_image: $([ -f "$WORK_DIR/kernel/Image" ] && echo true || echo false)
dtb_count: $(find "$WORK_DIR/kernel" -name "*.dtb" | wc -l)
modules_found: $([ "$MODULES_FOUND" -eq 1 ] && echo true || echo false)
bootloader: allwinner
bootloader_files: $BL_FILES
EOF

echo "[allwinner] extract-meta.yaml written" >&2
echo "[allwinner] done" >&2

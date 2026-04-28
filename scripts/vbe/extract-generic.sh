#!/usr/bin/env bash
# extract-generic.sh — fallback extractor: mount FAT boot + ext4 rootfs,
#   extract kernel/DTBs/modules. No SoC-specific bootloader extraction.
#
# Usage: extract-generic.sh <img-or-img.gz> <work-dir>
#   <work-dir> must already exist (pre-created by caller).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib-format.sh"

INPUT="${1:?usage: extract-generic.sh <img-or-img.gz> <work-dir>}"
WORK_DIR="${2:?usage: extract-generic.sh <img-or-img.gz> <work-dir>}"

INPUT="$(realpath "$INPUT")"
WORK_DIR="$(realpath "$WORK_DIR")"

echo "[generic] extracting from $INPUT -> $WORK_DIR" >&2

# ---------------------------------------------------------------------------
# Output directories
# ---------------------------------------------------------------------------
mkdir -p "$WORK_DIR/kernel" "$WORK_DIR/modules" "$WORK_DIR/bootloader"

# ---------------------------------------------------------------------------
# Unwrap compressed images
# ---------------------------------------------------------------------------
RAW_IMG=$(vbe_unwrap "$INPUT" "$WORK_DIR")

# ---------------------------------------------------------------------------
# Bootloader: not extracted — write marker
# ---------------------------------------------------------------------------
cat > "$WORK_DIR/bootloader/UNKNOWN.txt" <<'EOF'
SoC not identified. Bootloader extraction was skipped.
You must handle the bootloader manually for this image.
Use dd to extract at the known offsets for your SoC, e.g.:
  Allwinner: boot0 at offset 8192 (sector 16), boot_package at 16MB
  Rockchip:  idbloader at sector 64, u-boot.itb at sector 16384
EOF

# ---------------------------------------------------------------------------
# Loop-mount setup using kpartx (works in --privileged containers)
# ---------------------------------------------------------------------------
LOOP_DEV=""
MNT_BOOT=""
MNT_ROOT=""

cleanup() {
    local rc=$?
    echo "[generic] cleanup" >&2
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
echo "[generic] loop device: $LOOP_DEV" >&2
kpartx -av "$LOOP_DEV" >&2
sleep 0.3

# ---------------------------------------------------------------------------
# Partition scan using kpartx mapper devices (/dev/mapper/loopNpM)
# ---------------------------------------------------------------------------
LOOP_BASE=$(basename "$LOOP_DEV")
BOOT_PART=""
ROOT_PART=""

for map in /dev/mapper/${LOOP_BASE}p*; do
    [ -b "$map" ] || continue
    FSTYPE=$(blkid -o value -s TYPE "$map" 2>/dev/null || true)
    echo "[generic] partition $map: fstype=${FSTYPE:-unknown}" >&2
    case "$FSTYPE" in
        vfat)
            [ -z "$BOOT_PART" ] && BOOT_PART="$map"
            ;;
        ext4)
            [ -z "$ROOT_PART" ] && ROOT_PART="$map"
            ;;
    esac
done

echo "[generic] boot partition: ${BOOT_PART:-none}" >&2
echo "[generic] root partition: ${ROOT_PART:-none}" >&2

# ---------------------------------------------------------------------------
# Mount and extract kernel + DTBs from FAT boot partition
# ---------------------------------------------------------------------------
if [ -n "$BOOT_PART" ]; then
    MNT_BOOT=$(mktemp -d)
    mount -o ro "$BOOT_PART" "$MNT_BOOT"
    echo "[generic] mounted boot at $MNT_BOOT" >&2

    IMG_SRC=$(find "$MNT_BOOT" -maxdepth 2 \( -name "Image" -o -name "Image.gz" -o -name "uImage" \) | head -1 || true)
    if [ -n "$IMG_SRC" ]; then
        cp "$IMG_SRC" "$WORK_DIR/kernel/Image"
        echo "[generic] copied kernel: $(basename "$IMG_SRC") ($(stat -c%s "$WORK_DIR/kernel/Image") bytes)" >&2
    else
        echo "[generic] WARNING: no kernel Image found on boot partition" >&2
    fi

    find "$MNT_BOOT" -name "*.dtb" | while read -r dtb; do
        cp "$dtb" "$WORK_DIR/kernel/"
    done
    DTB_COUNT=$(find "$WORK_DIR/kernel" -name "*.dtb" | wc -l)
    echo "[generic] copied $DTB_COUNT DTB(s)" >&2

    umount "$MNT_BOOT"
    rm -rf "$MNT_BOOT"
    MNT_BOOT=""
else
    echo "[generic] WARNING: no FAT boot partition found" >&2
fi

# ---------------------------------------------------------------------------
# Write kernel-info.txt from strings on Image
# ---------------------------------------------------------------------------
KVER_FROM_BINARY=""
if [ -f "$WORK_DIR/kernel/Image" ]; then
    LINUX_VER=$(strings "$WORK_DIR/kernel/Image" 2>/dev/null | grep -m1 '^Linux version' || true)
    if [ -n "$LINUX_VER" ]; then
        echo "$LINUX_VER" > "$WORK_DIR/kernel/kernel-info.txt"
        KVER_FROM_BINARY=$(echo "$LINUX_VER" | awk '{print $3}')
        echo "[generic] kernel version: $KVER_FROM_BINARY" >&2
    else
        echo "[generic] WARNING: could not extract Linux version from Image" >&2
    fi
fi

# ---------------------------------------------------------------------------
# Mount ext4 rootfs and extract /lib/modules
# ---------------------------------------------------------------------------
KVER_MODULES=""
MODULES_FOUND=0

if [ -n "$ROOT_PART" ]; then
    MNT_ROOT=$(mktemp -d)
    mount -o ro "$ROOT_PART" "$MNT_ROOT"
    echo "[generic] mounted rootfs at $MNT_ROOT" >&2

    MODULES_BASE="$MNT_ROOT/lib/modules"
    if [ -d "$MODULES_BASE" ]; then
        KVER_DIR=$(find "$MODULES_BASE" -mindepth 1 -maxdepth 1 -type d | head -1 || true)
        if [ -n "$KVER_DIR" ]; then
            KVER_MODULES=$(basename "$KVER_DIR")
            echo "[generic] found modules for kernel: $KVER_MODULES" >&2
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
    echo "[generic] no /lib/modules found in rootfs (expected for minimal images)" >&2
    echo "no modules in source rootfs" > "$WORK_DIR/modules/MISSING.txt"
    KVER="${KVER_MODULES:-${KVER_FROM_BINARY:-unknown}}"
    echo "$KVER" > "$WORK_DIR/modules/kver.txt"
fi

# ---------------------------------------------------------------------------
# Write extract-meta.yaml
# ---------------------------------------------------------------------------
KVER_FINAL="${KVER_MODULES:-${KVER_FROM_BINARY:-unknown}}"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

cat > "$WORK_DIR/extract-meta.yaml" <<EOF
soc: unknown
extractor: extract-generic.sh
source_image: $INPUT
extracted_at: $TIMESTAMP
kernel_version: $KVER_FINAL
kernel_image: $([ -f "$WORK_DIR/kernel/Image" ] && echo true || echo false)
dtb_count: $(find "$WORK_DIR/kernel" -name "*.dtb" | wc -l)
modules_found: $([ "$MODULES_FOUND" -eq 1 ] && echo true || echo false)
bootloader: UNKNOWN - not extracted (see bootloader/UNKNOWN.txt)
EOF

echo "[generic] extract-meta.yaml written" >&2
echo "[generic] done" >&2

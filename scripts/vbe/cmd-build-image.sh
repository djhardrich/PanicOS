#!/usr/bin/env bash
# vbe build-image <archive.tar.gz> <squashfs> --out <flashable.img.gz>
#                 [--system-size 8G] [--overlay-size 64M] [--boot-size 256M]
#                 [--default-dtb <dtb-filename>]
#
# Assembles a complete flashable disk image from:
#   - VBE archive (bootloader blobs + kernel Image + DTBs)
#   - User-supplied squashfs (the rootfs)
#   - PanicOS initramfs (built on demand via scripts/build-initramfs.sh)
#
# Output: gzip-compressed disk image at --out path.
set -euo pipefail

SELF="$(readlink -f "$0")"
VBE_DIR="$(dirname "$SELF")"
ROOT="$(cd "$VBE_DIR/../.." && pwd)"
TEMPLATES_DIR="$VBE_DIR/genimage-templates"

# ---------------------------------------------------------------------------
# Helper: parse size like 8G / 256M / 8192M -> integer MB
# ---------------------------------------------------------------------------
parse_size_mb() {
    local s="$1"
    case "$s" in
        *G) echo $(( ${s%G} * 1024 )) ;;
        *M) echo "${s%M}" ;;
        *)  echo "$s" ;;  # assume already MB
    esac
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
ARCHIVE="${1:?usage: vbe build-image <archive.tar.gz> <squashfs> --out PATH}"
SQUASHFS="${2:?usage: vbe build-image <archive.tar.gz> <squashfs> --out PATH}"
shift 2

OUT=""
SYSTEM_SIZE_MB=8192
OVERLAY_SIZE_MB=64
BOOT_SIZE_MB=256
DEFAULT_DTB=""

while [ $# -gt 0 ]; do
    case "$1" in
        --out)          OUT="$2"; shift 2 ;;
        --system-size)  SYSTEM_SIZE_MB="$(parse_size_mb "$2")"; shift 2 ;;
        --overlay-size) OVERLAY_SIZE_MB="$(parse_size_mb "$2")"; shift 2 ;;
        --boot-size)    BOOT_SIZE_MB="$(parse_size_mb "$2")"; shift 2 ;;
        --default-dtb)  DEFAULT_DTB="$2"; shift 2 ;;
        *) echo "vbe build-image: unknown arg: $1" >&2; exit 2 ;;
    esac
done

[ -z "$OUT" ] && { echo "vbe build-image: --out is required" >&2; exit 2; }

# Validate inputs
[ -f "$ARCHIVE" ]  || { echo "vbe build-image: archive not found: $ARCHIVE" >&2; exit 1; }
[ -f "$SQUASHFS" ] || { echo "vbe build-image: squashfs not found: $SQUASHFS" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Work directory
# ---------------------------------------------------------------------------
WORK=$(mktemp -d -p "${TMPDIR:-/tmp}" vbe-build-image.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

BINDIR="$WORK/binaries"
ROOTPATH="$WORK/rootpath"
TMPPATH="$WORK/genimage.tmp"
mkdir -p "$BINDIR" "$ROOTPATH" "$TMPPATH"

echo ">>> vbe build-image: work dir $WORK"

# ---------------------------------------------------------------------------
# Step 1: Extract archive
# ---------------------------------------------------------------------------
echo ">>> extracting archive: $ARCHIVE"
tar -xzf "$ARCHIVE" -C "$WORK"

# Read extract-meta.yaml
META="$WORK/extract-meta.yaml"
[ -f "$META" ] || { echo "vbe build-image: extract-meta.yaml not found in archive" >&2; exit 1; }

SOC=$(grep '^soc:' "$META" | awk '{print $2}')
echo ">>> SoC hint from archive: $SOC"

# ---------------------------------------------------------------------------
# Step 2: Pick genimage template
# ---------------------------------------------------------------------------
case "$SOC" in
    rockchip-*)  TEMPLATE="$TEMPLATES_DIR/rockchip-rk3xxx.cfg.in" ;;
    allwinner-*) TEMPLATE="$TEMPLATES_DIR/allwinner-sunxi.cfg.in" ;;
    *)
        echo "vbe build-image: unknown SoC '$SOC' — no template available" >&2
        exit 1
        ;;
esac
[ -f "$TEMPLATE" ] || { echo "vbe build-image: template not found: $TEMPLATE" >&2; exit 1; }
echo ">>> using template: $TEMPLATE"

# Derive output image name from archive basename
ARCHIVE_BASE=$(basename "$ARCHIVE" .tar.gz)
export PANICOS_OUTPUT_NAME="$ARCHIVE_BASE"

# Partition sizes (exported for envsubst)
export PANICOS_BOOT_PARTITION_SIZE_MB="$BOOT_SIZE_MB"
export PANICOS_SYSTEM_PARTITION_SIZE_MB="$SYSTEM_SIZE_MB"
export PANICOS_OVERLAY_PARTITION_INITIAL_SIZE_MB="$OVERLAY_SIZE_MB"

# ---------------------------------------------------------------------------
# Step 3: Stage kernel + DTBs
# ---------------------------------------------------------------------------
KERNEL_DIR="$WORK/kernel"

# Kernel image: prefer Image, fall back to uImage / boot.img
if [ -f "$KERNEL_DIR/Image" ]; then
    cp "$KERNEL_DIR/Image" "$BINDIR/Image"
elif [ -f "$KERNEL_DIR/uImage" ]; then
    cp "$KERNEL_DIR/uImage" "$BINDIR/Image"
elif [ -f "$KERNEL_DIR/boot.img" ]; then
    cp "$KERNEL_DIR/boot.img" "$BINDIR/Image"
else
    echo "vbe build-image: no kernel image found in archive (tried Image, uImage, boot.img)" >&2
    exit 1
fi
echo ">>> staged kernel image"

# DTBs — into dtbs/<soc-family>/
SOC_FAMILY="$SOC"
mkdir -p "$BINDIR/dtbs/$SOC_FAMILY"
DTB_COUNT=0
for dtb in "$KERNEL_DIR"/*.dtb; do
    [ -f "$dtb" ] || continue
    cp "$dtb" "$BINDIR/dtbs/$SOC_FAMILY/"
    DTB_COUNT=$((DTB_COUNT + 1))
done
echo ">>> staged $DTB_COUNT DTB(s)"

# Resolve default DTB
if [ -n "$DEFAULT_DTB" ]; then
    if [ -f "$BINDIR/dtbs/$SOC_FAMILY/$DEFAULT_DTB" ]; then
        cp "$BINDIR/dtbs/$SOC_FAMILY/$DEFAULT_DTB" "$BINDIR/dtb.img"
        echo ">>> default DTB (specified): $DEFAULT_DTB"
    else
        echo "vbe build-image: warning: --default-dtb '$DEFAULT_DTB' not found; falling back to first alphabetical" >&2
        DEFAULT_DTB=""
    fi
fi

if [ -z "$DEFAULT_DTB" ]; then
    FIRST_DTB=$(ls "$BINDIR/dtbs/$SOC_FAMILY/"*.dtb 2>/dev/null | sort | head -1 || true)
    if [ -n "$FIRST_DTB" ]; then
        cp "$FIRST_DTB" "$BINDIR/dtb.img"
        echo ">>> default DTB (first alphabetical): $(basename "$FIRST_DTB")"
    else
        # No DTBs — create an empty placeholder so vfat doesn't fail on missing file
        touch "$BINDIR/dtb.img"
        echo ">>> warning: no DTBs found; dtb.img is empty"
    fi
fi

# ---------------------------------------------------------------------------
# Step 4: Stage bootloader blobs
# ---------------------------------------------------------------------------
BL_DIR="$WORK/bootloader"

case "$SOC" in
    rockchip-*)
        IDBLOADER="$BL_DIR/rockchip/idbloader.img"
        UBOOT_ITB="$BL_DIR/rockchip/u-boot.itb"

        [ -f "$IDBLOADER" ] || { echo "vbe build-image: idbloader.img not found in archive" >&2; exit 1; }
        [ -f "$UBOOT_ITB" ] || { echo "vbe build-image: u-boot.itb not found in archive" >&2; exit 1; }

        # Assemble u-boot-rockchip-vbe.bin:
        # genimage writes this blob at disk offset 32K (as specified in the template).
        # idbloader.img must be at blob-offset 0 (-> disk 32K)
        # u-boot.itb must land at disk offset 8M = 8192K; blob offset = 8192K - 32K = 8160K
        BLOB="$BINDIR/u-boot-rockchip-vbe.bin"
        GAP_BYTES=$(( 8 * 1024 * 1024 - 32 * 1024 ))   # 8160 KiB

        # Create zero-filled blob of the required size, then overlay the two images
        dd if=/dev/zero of="$BLOB" bs=1K count=$(( GAP_BYTES / 1024 )) 2>/dev/null
        # Append u-boot.itb after the gap (use cat for simplicity)
        cat "$UBOOT_ITB" >> "$BLOB"
        # Overlay idbloader.img at offset 0 (conv=notrunc preserves the rest)
        dd if="$IDBLOADER" of="$BLOB" bs=512 conv=notrunc 2>/dev/null

        echo ">>> assembled u-boot-rockchip-vbe.bin ($(stat -c%s "$BLOB") bytes)"
        echo "    idbloader@0 (disk+32K) + u-boot.itb@8160K (disk+8M)"
        ;;

    allwinner-*)
        BOOT0="$BL_DIR/allwinner/boot0.img"
        BOOT_PKG="$BL_DIR/allwinner/boot_package.fex"

        [ -f "$BOOT0" ] || { echo "vbe build-image: boot0.img not found in archive" >&2; exit 1; }
        cp "$BOOT0" "$BINDIR/boot0.img"

        if [ -f "$BOOT_PKG" ]; then
            cp "$BOOT_PKG" "$BINDIR/boot_package.fex"
            # Inject the boot_package partition block into the template via envsubst.
            # Offset 16M = 16777216 bytes (standard Allwinner TOC1 location).
            export PANICOS_AW_BOOT_PACKAGE_BLOCK='	partition boot-package {
		in-partition-table = "no"
		image = "boot_package.fex"
		offset = 16777216
	}
'
            echo ">>> staged boot0.img + boot_package.fex"
        else
            export PANICOS_AW_BOOT_PACKAGE_BLOCK=""
            echo ">>> staged boot0.img (no boot_package.fex in archive)"
        fi
        ;;
esac

# ---------------------------------------------------------------------------
# Step 5: Build initramfs if needed
# ---------------------------------------------------------------------------
INITRAMFS="$ROOT/output/panicos-initramfs.cpio.gz"
if [ ! -f "$INITRAMFS" ]; then
    echo ">>> building initramfs (not found at $INITRAMFS)"
    bash "$ROOT/scripts/build-initramfs.sh"
fi
[ -f "$INITRAMFS" ] || { echo "vbe build-image: initramfs not found and build failed" >&2; exit 1; }
cp "$INITRAMFS" "$BINDIR/initramfs.cpio.gz"
echo ">>> staged initramfs ($(stat -c%s "$BINDIR/initramfs.cpio.gz") bytes)"

# ---------------------------------------------------------------------------
# Step 6: Generate boot.scr + panicos-active.cfg
# ---------------------------------------------------------------------------
cat > "$BINDIR/boot.cmd" <<'BOOTEOF'
setenv bootargs "console=tty1 panic=10"
fatload mmc 0:1 ${kernel_addr_r} Image
fatload mmc 0:1 ${ramdisk_addr_r} initramfs.cpio.gz
fatload mmc 0:1 ${fdt_addr_r} dtb.img
booti ${kernel_addr_r} ${ramdisk_addr_r}:${filesize} ${fdt_addr_r}
BOOTEOF

if command -v mkimage >/dev/null 2>&1; then
    mkimage -A arm64 -O linux -T script -C none -d "$BINDIR/boot.cmd" \
        "$BINDIR/boot.scr" >/dev/null
    echo ">>> generated boot.scr via mkimage"
else
    cp "$BINDIR/boot.cmd" "$BINDIR/boot.scr"
    echo ">>> WARNING: mkimage not found; boot.scr has no U-Boot header" >&2
fi

cat > "$BINDIR/panicos-active.cfg" <<CFGEOF
# PanicOS active image selector.
# Edit IMAGE= to switch which squashfs the initramfs loads on next boot.
# The named file must exist in the system partition (/system/<IMAGE>).
IMAGE=${PANICOS_OUTPUT_NAME}.squashfs
CFGEOF

# ---------------------------------------------------------------------------
# Step 7: Stage squashfs into rootpath for genimage system.ext4
# ---------------------------------------------------------------------------
cp "$SQUASHFS" "$ROOTPATH/${PANICOS_OUTPUT_NAME}.squashfs"
echo ">>> staged squashfs ($(stat -c%s "$SQUASHFS") bytes)"

# ---------------------------------------------------------------------------
# Step 8: Render genimage config via envsubst
# ---------------------------------------------------------------------------
GENIMAGE_CFG="$WORK/genimage.cfg"
envsubst < "$TEMPLATE" > "$GENIMAGE_CFG"
echo ">>> rendered genimage config"

# ---------------------------------------------------------------------------
# Step 9: Run genimage
# ---------------------------------------------------------------------------
echo ">>> running genimage..."
genimage \
    --rootpath "$ROOTPATH" \
    --tmppath  "$TMPPATH" \
    --inputpath "$BINDIR" \
    --outputpath "$BINDIR" \
    --config "$GENIMAGE_CFG"

IMG="$BINDIR/${PANICOS_OUTPUT_NAME}.img"
[ -f "$IMG" ] || { echo "vbe build-image: genimage did not produce ${PANICOS_OUTPUT_NAME}.img" >&2; exit 1; }
echo ">>> genimage done: $(stat -c%s "$IMG") bytes"

# ---------------------------------------------------------------------------
# Step 10: Gzip and move to --out
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$OUT")"
gzip -9 -c "$IMG" > "$OUT"
echo ">>> wrote $OUT ($(stat -c%s "$OUT") bytes)"

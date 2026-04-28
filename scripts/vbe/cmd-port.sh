#!/usr/bin/env bash
# vbe port <vendor-image> <panicos-base.squashfs> --out <flashable.img.gz>
#          [--default-dtb NAME] [--system-size 8G] [--overlay-size 64M]
#          [--allow-empty-modules]
#
# Composite: runs extract + inject + build-image in one shot.
set -euo pipefail

SELF="$(readlink -f "$0")"
VBE_DIR="$(dirname "$SELF")"

VENDOR_IMAGE="${1:?usage: vbe port <vendor-image> <squashfs> --out PATH}"
SQUASHFS="${2:?usage: vbe port <vendor-image> <squashfs> --out PATH}"
shift 2

OUT=""
DEFAULT_DTB=""
SYSTEM_SIZE=""
OVERLAY_SIZE=""
ALLOW_EMPTY_MODULES=0

while [ $# -gt 0 ]; do
    case "$1" in
        --out)                 OUT="$2"; shift 2 ;;
        --default-dtb)         DEFAULT_DTB="$2"; shift 2 ;;
        --system-size)         SYSTEM_SIZE="$2"; shift 2 ;;
        --overlay-size)        OVERLAY_SIZE="$2"; shift 2 ;;
        --allow-empty-modules) ALLOW_EMPTY_MODULES=1; shift ;;
        *) echo "vbe port: unknown arg: $1" >&2; exit 2 ;;
    esac
done

[ -z "$OUT" ] && { echo "vbe port: --out is required" >&2; exit 2; }

# Auto-cleaned work dir (in /tmp to avoid polluting output/vbe/)
WORK=$(mktemp -d -p "${TMPDIR:-/tmp}" vbe-port.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

echo ">>> vbe port: work dir $WORK"

# ---------------------------------------------------------------------------
# Step 1: extract
# ---------------------------------------------------------------------------
echo ">>> [1/3] vbe extract"
"$VBE_DIR/cmd-extract.sh" "$VENDOR_IMAGE" --out "$WORK/extracted.tar.gz"

# ---------------------------------------------------------------------------
# Step 2: inject
# ---------------------------------------------------------------------------
echo ">>> [2/3] vbe inject"
INJECT_ARGS=()
[ "$ALLOW_EMPTY_MODULES" -eq 1 ] && INJECT_ARGS+=(--allow-empty)
"$VBE_DIR/cmd-inject.sh" "$WORK/extracted.tar.gz" "$SQUASHFS" \
    --out "$WORK/with-modules.squashfs" \
    "${INJECT_ARGS[@]}"

# ---------------------------------------------------------------------------
# Step 3: build-image
# ---------------------------------------------------------------------------
echo ">>> [3/3] vbe build-image"
BUILD_ARGS=(--out "$OUT")
[ -n "$DEFAULT_DTB"  ] && BUILD_ARGS+=(--default-dtb  "$DEFAULT_DTB")
[ -n "$SYSTEM_SIZE"  ] && BUILD_ARGS+=(--system-size  "$SYSTEM_SIZE")
[ -n "$OVERLAY_SIZE" ] && BUILD_ARGS+=(--overlay-size "$OVERLAY_SIZE")

"$VBE_DIR/cmd-build-image.sh" "$WORK/extracted.tar.gz" "$WORK/with-modules.squashfs" \
    "${BUILD_ARGS[@]}"

echo ">>> vbe port: done — $OUT"

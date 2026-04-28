#!/usr/bin/env bash
# Reproduces the vendor BSP import from Knulli for a given SoC. Idempotent;
# refuses to clobber locally-modified files unless --force.
#
# Usage: sync-knulli.sh --soc <soc-name> [--force]

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib/import-common.sh"

SOC_NAME=""
FORCE=0
args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
    arg="${args[$i]}"
    case "$arg" in
        --soc)
            i=$((i+1)); SOC_NAME="${args[$i]}" ;;
        --soc=*)
            SOC_NAME="${arg#--soc=}" ;;
        --force)
            FORCE=1 ;;
        *)
            echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
    i=$((i+1))
done

if [ -z "$SOC_NAME" ]; then
    echo "Usage: $0 --soc <soc-name> [--force]" >&2
    exit 2
fi

CONF="$ROOT/scripts/imports/$SOC_NAME.conf"
if [ ! -f "$CONF" ]; then
    echo "No config found for SoC '$SOC_NAME' at $CONF" >&2
    exit 2
fi

# Initialize variables with defaults before sourcing conf.
KNULLI_KERNEL_CONFIG=""
KNULLI_BOARD_DIR=""
BUILD_MODE="from-source"
MANIFEST_SECTION_KNULLI=""

# Load per-SoC variables from conf.
. "$CONF"

KNULLI="$ROOT/third_party/knulli"
SOC_DIR="$ROOT/soc/$SOC_NAME"
SOC_VENDOR="$SOC_DIR/vendor"
MANIFEST="$SOC_DIR/source.manifest.v2"

# Use conf-provided section name if available, otherwise derive from SoC name.
MANIFEST_SECTION="${MANIFEST_SECTION_KNULLI:-knulli-${SOC_NAME}-vendor}"

KNULLI_SHA=$(git -C "$KNULLI" rev-parse HEAD)
echo ">>> Knulli submodule: $KNULLI_SHA"
echo ">>> SoC: $SOC_NAME  build-mode: $BUILD_MODE"

if [ "$BUILD_MODE" = "from-blobs" ]; then
    # Blob-staging mode: copy pre-built binaries verbatim from Knulli into
    # soc/<soc>/vendor/prebuilt/<device>/ and record SHA256 in source.manifest.v2.

    if [ -z "${KNULLI_BLOB_DEVICES[*]:-}" ]; then
        echo "ERROR: KNULLI_BLOB_DEVICES not set in $CONF" >&2
        exit 2
    fi

    if [ -f "$MANIFEST" ] && [ "$FORCE" = 0 ]; then
        if ! check_drift "$MANIFEST" "$ROOT" "$MANIFEST_SECTION"; then
            echo "Use --force to overwrite." >&2; exit 1
        fi
    fi

    TSV=$(mktemp); trap 'rm -f "$TSV"' EXIT

    # --- Per-device blobs ---------------------------------------------------
    for device in "${KNULLI_BLOB_DEVICES[@]}"; do
        DEVICE_SRC="$KNULLI/$KNULLI_BOARD_DIR/$device"
        DEVICE_DEST="$SOC_VENDOR/prebuilt/$device"
        if [ ! -d "$DEVICE_SRC" ]; then
            echo "ERROR: device dir not found: $DEVICE_SRC" >&2
            exit 2
        fi
        echo ">>> staging blobs for $device"
        while IFS= read -r -d '' abs_src; do
            rel_src="${abs_src#$KNULLI/}"   # relative to knulli root
            rel_device="${abs_src#$DEVICE_SRC/}"  # path within device dir
            dest="$DEVICE_DEST/$rel_device"
            mkdir -p "$(dirname "$dest")"
            git -C "$KNULLI" show "$KNULLI_SHA:$rel_src" > "$dest"
            src_sha=$(git_sha256_of "$KNULLI" "$KNULLI_SHA" "$rel_src")
            dest_sha=$(sha256_of "$dest")
            printf '%s\t%s\t%s\t%s\n' "$dest" "$rel_src" "$src_sha" "$dest_sha" >> "$TSV"
        done < <(find "$DEVICE_SRC" -type f -print0 | sort -z)
    done

    # --- Shared SoC-level files (in board dir root, not per-device) ----------
    SHARED_SRC="$KNULLI/$KNULLI_BOARD_DIR"
    SHARED_DEST="$SOC_VENDOR/prebuilt/_shared"
    while IFS= read -r -d '' abs_src; do
        # Only files directly in the SoC board dir (not inside sub-dirs like
        # device dirs, patches/, fsoverlay/).
        rel_file="${abs_src#$SHARED_SRC/}"
        # Skip device dirs, patches, fsoverlay — those are either per-device
        # (already handled above) or not part of the kernel/bootloader blobs.
        first_component="${rel_file%%/*}"
        skip=0
        for device in "${KNULLI_BLOB_DEVICES[@]}"; do
            [ "$first_component" = "$device" ] && skip=1 && break
        done
        [ "$first_component" = "patches" ]   && skip=1
        [ "$first_component" = "fsoverlay" ] && skip=1
        [ "$skip" = 1 ] && continue

        rel_src="${abs_src#$KNULLI/}"
        dest="$SHARED_DEST/$rel_file"
        mkdir -p "$(dirname "$dest")"
        git -C "$KNULLI" show "$KNULLI_SHA:$rel_src" > "$dest"
        src_sha=$(git_sha256_of "$KNULLI" "$KNULLI_SHA" "$rel_src")
        dest_sha=$(sha256_of "$dest")
        printf '%s\t%s\t%s\t%s\n' "$dest" "$rel_src" "$src_sha" "$dest_sha" >> "$TSV"
    done < <(find "$SHARED_SRC" -maxdepth 2 -type f -print0 | sort -z)

    NEW_SECTION=$(mktemp); trap 'rm -f "$TSV" "$NEW_SECTION"' EXIT
    render_manifest_section "$TSV" "$MANIFEST_SECTION" "third_party/knulli" "$KNULLI_SHA" "$ROOT" > "$NEW_SECTION"

    python3 - "$MANIFEST" "$NEW_SECTION" "$MANIFEST_SECTION" <<'PY'
import sys, re
manifest_path, new_section_path, section_name = sys.argv[1], sys.argv[2], sys.argv[3]
new_section = open(new_section_path).read()
try:
    text = open(manifest_path).read()
except FileNotFoundError:
    text = "schema_version: 2\nimports:\n"
text = re.sub(r'(?ms)^  - name: ' + re.escape(section_name) + r'\n.*?(?=^  - name:|\Z)', '', text)
if 'imports:' not in text:
    text += 'imports:\n'
text = text.rstrip() + '\n' + new_section
open(manifest_path, 'w').write(text)
PY

    echo ">>> blob import done for $SOC_NAME"
    exit 0
fi

# from-source mode: import kernel config fragment.
if [ -z "$KNULLI_KERNEL_CONFIG" ]; then
    echo "ERROR: KNULLI_KERNEL_CONFIG is not set in $CONF" >&2
    exit 2
fi

if [ -f "$MANIFEST" ] && [ "$FORCE" = 0 ]; then
    if ! check_drift "$MANIFEST" "$ROOT" "$MANIFEST_SECTION"; then
        echo "Use --force to overwrite." >&2; exit 1
    fi
fi

TSV=$(mktemp); trap 'rm -f "$TSV"' EXIT

import_file "$KNULLI" "$KNULLI_SHA" \
    "$KNULLI_KERNEL_CONFIG" \
    "$SOC_VENDOR/linux/linux.config.fragment" "$TSV"

NEW_SECTION=$(mktemp); trap 'rm -f "$TSV" "$NEW_SECTION"' EXIT
render_manifest_section "$TSV" "$MANIFEST_SECTION" "third_party/knulli" "$KNULLI_SHA" "$ROOT" > "$NEW_SECTION"

python3 - "$MANIFEST" "$NEW_SECTION" "$MANIFEST_SECTION" <<'PY'
import sys, re
manifest_path, new_section_path, section_name = sys.argv[1], sys.argv[2], sys.argv[3]
new_section = open(new_section_path).read()
try:
    text = open(manifest_path).read()
except FileNotFoundError:
    text = "schema_version: 2\nimports:\n"
text = re.sub(r'(?ms)^  - name: ' + re.escape(section_name) + r'\n.*?(?=^  - name:|\Z)', '', text)
if 'imports:' not in text:
    text += 'imports:\n'
text = text.rstrip() + '\n' + new_section
open(manifest_path, 'w').write(text)
PY

echo ">>> done"

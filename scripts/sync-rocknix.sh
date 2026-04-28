#!/usr/bin/env bash
# Reproduces the mainline import from ROCKNIX for a given SoC. Idempotent;
# refuses to clobber locally-modified files unless --force.
#
# Usage: sync-rocknix.sh --soc <soc-name> [--force]
# Cherry-picks listed in ROCKNIX_CHERRY_PICKS pull from beyond the pinned next SHA.

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

# Initialize variables/arrays before sourcing conf so they're always defined.
ROCKNIX_CHERRY_PICKS=()
ROCKNIX_CP_KERNEL_PATCHES=()
ROCKNIX_CP_UBOOT_PATCHES=()
ROCKNIX_SYNTH_DEFCONFIGS=()
ROCKNIX_FIRMWARE_DIRS=()
MANIFEST_SECTION_ROCKNIX=""

# Load per-SoC variables from conf.
. "$CONF"

# If ROCKNIX_DEVICE_DIR is empty, ROCKNIX doesn't support this SoC — nothing to do.
if [ -z "${ROCKNIX_DEVICE_DIR:-}" ]; then
    echo ">>> ROCKNIX does not support SoC '$SOC_NAME' — skipping (no ROCKNIX_DEVICE_DIR)."
    exit 0
fi

ROCKNIX="$ROOT/third_party/rocknix"
SOC_DIR="$ROOT/soc/$SOC_NAME"
SOC_MAIN="$SOC_DIR/mainline"
SOC_UBOOT="$SOC_DIR/uboot"
MANIFEST="$SOC_DIR/source.manifest.v2"

# Use conf-provided section name if available, otherwise derive from SoC name.
MANIFEST_SECTION="${MANIFEST_SECTION_ROCKNIX:-rocknix-${SOC_NAME}-mainline}"

ROCKNIX_SHA=$(git -C "$ROCKNIX" rev-parse HEAD)

echo ">>> ROCKNIX submodule: $ROCKNIX_SHA"
echo ">>> SoC: $SOC_NAME"

if [ -f "$MANIFEST" ] && [ "$FORCE" = 0 ]; then
    if ! check_drift "$MANIFEST" "$ROOT" "$MANIFEST_SECTION"; then
        echo "Use --force to overwrite." >&2; exit 1
    fi
fi

TSV=$(mktemp); trap 'rm -f "$TSV"' EXIT

# ----- kernel patches (3-tier import as in Plan 02) -----
import_patches_dir() {
    local sha="$1" subdir="$2" prefix="$3"
    local i="$prefix"
    while IFS= read -r base; do
        case "$base" in *.disabled) continue ;; esac
        import_file "$ROCKNIX" "$sha" "$subdir/$base" \
            "$SOC_MAIN/linux/patches/$(printf '%04d' $i)-$base" "$TSV"
        i=$((i+1))
    done < <(git -C "$ROCKNIX" ls-tree --name-only "$sha" "$subdir/" \
        2>/dev/null | grep '\.patch$' | sort | xargs -I{} basename {} || true)
}

rm -rf "$SOC_MAIN/linux/patches"
import_patches_dir "$ROCKNIX_SHA" "projects/ROCKNIX/packages/linux/patches/mainline" 100
import_patches_dir "$ROCKNIX_SHA" "$ROCKNIX_DEVICE_DIR/patches/linux" 200
import_patches_dir "$ROCKNIX_SHA" "$ROCKNIX_PATCHES_VERSION_DIR" 900

# Cherry-pick: specific kernel patches from conf
if [ "${#ROCKNIX_CHERRY_PICKS[@]}" -gt 0 ] && [ "${#ROCKNIX_CP_KERNEL_PATCHES[@]}" -gt 0 ]; then
    CHERRY_SHA="${ROCKNIX_CHERRY_PICKS[0]}"
    for entry in "${ROCKNIX_CP_KERNEL_PATCHES[@]}"; do
        src="${entry%%:*}"
        dest_base="${entry##*:}"
        import_file "$ROCKNIX" "$CHERRY_SHA" \
            "$src" \
            "$SOC_MAIN/linux/patches/$dest_base" "$TSV"
    done
fi

# ----- kernel config fragment + DTS -----
import_file "$ROCKNIX" "$ROCKNIX_SHA" \
    "$ROCKNIX_KERNEL_CONFIG_FRAGMENT" \
    "$SOC_MAIN/linux/linux.config.fragment" "$TSV"

dts_subdir=$(basename "$ROCKNIX_DTS_DIR")
rm -rf "$SOC_MAIN/linux/dts/$dts_subdir"
while IFS= read -r base; do
    import_file "$ROCKNIX" "$ROCKNIX_SHA" \
        "$ROCKNIX_DTS_DIR/$base" \
        "$SOC_MAIN/linux/dts/$dts_subdir/$base" "$TSV"
done < <(git -C "$ROCKNIX" ls-tree --name-only "$ROCKNIX_SHA" \
    "$ROCKNIX_DTS_DIR/" 2>/dev/null | grep -E '\.(dts|dtsi)$' | xargs -I{} basename {} || true)

# ----- U-Boot patches (in flavor-independent uboot/) -----
rm -rf "$SOC_UBOOT/patches"
mkdir -p "$SOC_UBOOT/patches"

# Cherry-pick: specific U-Boot patches from conf
if [ "${#ROCKNIX_CHERRY_PICKS[@]}" -gt 0 ] && [ "${#ROCKNIX_CP_UBOOT_PATCHES[@]}" -gt 0 ]; then
    CHERRY_SHA="${ROCKNIX_CHERRY_PICKS[0]}"
    for entry in "${ROCKNIX_CP_UBOOT_PATCHES[@]}"; do
        src="${entry%%:*}"
        dest_base="${entry##*:}"
        import_file "$ROCKNIX" "$CHERRY_SHA" \
            "$src" \
            "$SOC_UBOOT/patches/$dest_base" "$TSV"
    done
fi

# Synthesize defconfig-add patches (from conf)
if [ "${#ROCKNIX_CHERRY_PICKS[@]}" -gt 0 ] && [ "${#ROCKNIX_SYNTH_DEFCONFIGS[@]}" -gt 0 ]; then
    CHERRY_SHA="${ROCKNIX_CHERRY_PICKS[0]}"
    for entry in "${ROCKNIX_SYNTH_DEFCONFIGS[@]}"; do
        prefix="${entry%%:*}"
        name="${entry##*:}"
        src="$ROCKNIX_DEVICE_DIR/packages/u-boot/sources/configs/$name"
        if ! git -C "$ROCKNIX" cat-file -e "$CHERRY_SHA:$src" 2>/dev/null; then
            echo "WARNING: synth-defconfig source not found: $src @ $CHERRY_SHA" >&2
            continue
        fi
        content=$(git -C "$ROCKNIX" show "$CHERRY_SHA:$src")
        nlines=$(printf '%s\n' "$content" | wc -l)
        out="$SOC_UBOOT/patches/$prefix-Add-$name.patch"
        {
            echo "From 0000000000000000000000000000000000000001 Mon Sep 17 00:00:00 2001"
            echo "From: PanicOS <noreply@panicos.local>"
            echo "Subject: [PATCH] Add $name"
            echo ""
            echo "Synthesized from ROCKNIX $CHERRY_SHA"
            echo "---"
            echo " configs/$name | $nlines +"
            echo ""
            echo "diff --git a/configs/$name b/configs/$name"
            echo "new file mode 100644"
            echo "--- /dev/null"
            echo "+++ b/configs/$name"
            echo "@@ -0,0 +1,$nlines @@"
            printf '%s\n' "$content" | sed 's/^/+/'
        } > "$out"
        src_sha=$(git -C "$ROCKNIX" show "$CHERRY_SHA:$src" | sha256sum | awk '{print $1}')
        dest_sha=$(sha256_of "$out")
        printf '%s\t%s\t%s\t%s\n' "$out" "$src" "$src_sha" "$dest_sha" >> "$TSV"
    done
fi

# ----- firmware blobs (rootfs overlay) -----
# Anything under ROCKNIX_FIRMWARE_DIRS gets copied to
# soc/<soc>/mainline/rootfs-overlay/lib/firmware/<relpath>. Required for
# drivers that load via request_firmware() (panel-mipi-dpi-spi panels,
# Realtek BT, Cirrus DSP). Buildroot picks the dir up via BR2_ROOTFS_OVERLAY
# wired in mainline/rootfs-overlay/defconfig.fragment.
FW_TARGET="$SOC_MAIN/rootfs-overlay/usr/lib/firmware"
if [ "${#ROCKNIX_FIRMWARE_DIRS[@]}" -gt 0 ]; then
    rm -rf "$FW_TARGET"
    mkdir -p "$FW_TARGET"
    for src_dir in "${ROCKNIX_FIRMWARE_DIRS[@]}"; do
        while IFS= read -r relpath; do
            [ -n "$relpath" ] || continue
            import_file "$ROCKNIX" "$ROCKNIX_SHA" \
                "$src_dir/$relpath" \
                "$FW_TARGET/$relpath" "$TSV"
        done < <(git -C "$ROCKNIX" ls-tree -r --name-only "$ROCKNIX_SHA" \
            -- "$src_dir/" 2>/dev/null \
            | sed "s|^$src_dir/||" \
            | grep -v '/package\.mk$' \
            | grep -v '^package\.mk$' \
            | grep -v '^patches/' \
            || true)
    done
fi

# ----- write/replace section in manifest -----
NEW_SECTION=$(mktemp); trap 'rm -f "$TSV" "$NEW_SECTION"' EXIT
render_manifest_section "$TSV" "$MANIFEST_SECTION" "third_party/rocknix" "$ROCKNIX_SHA" "$ROOT" > "$NEW_SECTION"

# Replace the section in-place; preserve other sections.
python3 - "$MANIFEST" "$NEW_SECTION" "$MANIFEST_SECTION" <<'PY'
import sys, re
manifest_path, new_section_path, section_name = sys.argv[1], sys.argv[2], sys.argv[3]
new_section = open(new_section_path).read()
try:
    text = open(manifest_path).read()
except FileNotFoundError:
    text = "schema_version: 2\nimports:\n"
# Remove existing section block (from "  - name: <section>..." up to next "  - name:" or EOF).
text = re.sub(r'(?ms)^  - name: ' + re.escape(section_name) + r'\n.*?(?=^  - name:|\Z)', '', text)
if 'imports:' not in text:
    text += 'imports:\n'
text = text.rstrip() + '\n' + new_section
open(manifest_path, 'w').write(text)
PY

echo ">>> done"

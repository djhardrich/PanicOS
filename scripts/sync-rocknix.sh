#!/usr/bin/env bash
# Reproduces the H700 mainline import from ROCKNIX. Idempotent; refuses to
# clobber locally-modified files unless --force.
#
# Cherry-picks listed in CHERRY_PICKS pull from beyond the pinned next SHA.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib/import-common.sh"

ROCKNIX="$ROOT/third_party/rocknix"
SOC="$ROOT/soc/allwinner-h700"
SOC_MAIN="$SOC/mainline"
SOC_UBOOT="$SOC/uboot"
MANIFEST="$SOC/source.manifest.v2"

FORCE=0
for arg in "$@"; do case "$arg" in --force) FORCE=1 ;; *) echo "unknown arg: $arg">&2; exit 2;; esac; done

ROCKNIX_SHA=$(git -C "$ROCKNIX" rev-parse HEAD)
CHERRY_PICKS=( "8d65b60525f54258ec4ab381b4c7f80ec94148c5" )  # LPDDR3 commit

echo ">>> ROCKNIX submodule: $ROCKNIX_SHA"

if [ -f "$MANIFEST" ] && [ "$FORCE" = 0 ]; then
    if ! check_drift "$MANIFEST" "$ROOT" "rocknix-h700-mainline"; then
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
    done < <(git -C "$ROCKNIX" ls-tree --name-only "$sha" "$subdir/" | grep '\.patch$' | sort | xargs -I{} basename {})
}

rm -rf "$SOC_MAIN/linux/patches"
import_patches_dir "$ROCKNIX_SHA" "projects/ROCKNIX/packages/linux/patches/mainline" 100
import_patches_dir "$ROCKNIX_SHA" "projects/ROCKNIX/devices/H700/patches/linux" 200
import_patches_dir "$ROCKNIX_SHA" "projects/ROCKNIX/packages/linux/patches/7.0" 900

# Cherry-pick: kernel patch
import_file "$ROCKNIX" "${CHERRY_PICKS[0]}" \
    "projects/ROCKNIX/devices/H700/patches/linux/9999-Update-sun50i-h700-anbernic-rg35xx-2024.dts.patch" \
    "$SOC_MAIN/linux/patches/0223-9999-Update-sun50i-h700-anbernic-rg35xx-2024.dts.patch" "$TSV"

# ----- kernel config fragment + DTS -----
import_file "$ROCKNIX" "$ROCKNIX_SHA" \
    "projects/ROCKNIX/devices/H700/linux/linux.aarch64.conf" \
    "$SOC_MAIN/linux/linux.config.fragment" "$TSV"

rm -rf "$SOC_MAIN/linux/dts/allwinner"
while IFS= read -r base; do
    import_file "$ROCKNIX" "$ROCKNIX_SHA" \
        "projects/ROCKNIX/devices/H700/linux/dts/allwinner/$base" \
        "$SOC_MAIN/linux/dts/allwinner/$base" "$TSV"
done < <(git -C "$ROCKNIX" ls-tree --name-only "$ROCKNIX_SHA" \
    "projects/ROCKNIX/devices/H700/linux/dts/allwinner/" | grep '\.dts$' | xargs -I{} basename {})

# ----- U-Boot patches + cherry-picks (in flavor-independent uboot/) -----
rm -rf "$SOC_UBOOT/patches"
mkdir -p "$SOC_UBOOT/patches"

import_file "$ROCKNIX" "${CHERRY_PICKS[0]}" \
    "projects/ROCKNIX/devices/H700/packages/u-boot/patches/0001-Update-dram_sun50i_h616.c.patch" \
    "$SOC_UBOOT/patches/0001-Update-dram_sun50i_h616.c.patch" "$TSV"

# Synthesize defconfig-add patches
synth_defconfig_patch() {
    local sha="$1" name="$2" prefix="$3"
    local src="projects/ROCKNIX/devices/H700/packages/u-boot/sources/configs/$name"
    local content; content=$(git -C "$ROCKNIX" show "$sha:$src")
    local nlines; nlines=$(printf '%s\n' "$content" | wc -l)
    local out="$SOC_UBOOT/patches/$prefix-Add-$name.patch"
    {
        echo "From 0000000000000000000000000000000000000001 Mon Sep 17 00:00:00 2001"
        echo "From: PanicOS <noreply@panicos.local>"
        echo "Subject: [PATCH] Add $name"
        echo ""
        echo "Synthesized from ROCKNIX $sha"
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
    local src_sha; src_sha=$(git -C "$ROCKNIX" show "$sha:$src" | sha256sum | awk '{print $1}')
    local dest_sha; dest_sha=$(sha256_of "$out")
    printf '%s\t%s\t%s\t%s\n' "$out" "$src" "$src_sha" "$dest_sha" >> "$TSV"
}
synth_defconfig_patch "${CHERRY_PICKS[0]}" "anbernic_rg35xx_h700_lpddr3_defconfig" "0002"
synth_defconfig_patch "${CHERRY_PICKS[0]}" "anbernic_rg35xx_h700_lpddr4_defconfig" "0003"

# ----- write/replace rocknix section in manifest -----
NEW_SECTION=$(mktemp); trap 'rm -f "$TSV" "$NEW_SECTION"' EXIT
render_manifest_section "$TSV" "rocknix-h700-mainline" "third_party/rocknix" "$ROCKNIX_SHA" "$ROOT" > "$NEW_SECTION"

# Replace the rocknix-h700-mainline section in-place; preserve other sections.
python3 - "$MANIFEST" "$NEW_SECTION" <<'PY'
import sys, re
manifest_path, new_section_path = sys.argv[1], sys.argv[2]
new_section = open(new_section_path).read()
try:
    text = open(manifest_path).read()
except FileNotFoundError:
    text = "schema_version: 2\nimports:\n"
# Remove existing rocknix-h700-mainline block (from "  - name: rocknix-..." up to next "  - name:" or EOF).
text = re.sub(r'(?ms)^  - name: rocknix-h700-mainline\n.*?(?=^  - name:|\Z)', '', text)
if 'imports:' not in text:
    text += 'imports:\n'
text = text.rstrip() + '\n' + new_section
open(manifest_path, 'w').write(text)
PY

echo ">>> done"

#!/usr/bin/env bash
# vendor-sc-community-plugins.sh — Clone community SC plugin repos into
# vendor/sc-community-plugins/ for use by the panicos-sc3-community-plugins
# Buildroot package (SITE_METHOD = local, mirrors build-sc-plugins.sh repos).
#
# Usage: scripts/vendor-sc-community-plugins.sh [--update]
#   --update  re-fetch all repos even if already cloned (default: skip existing)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="$REPO_ROOT/vendor/sc-community-plugins"
FORCE_UPDATE="${1:-}"

echo "=== Vendoring community SC plugins ==="
echo "  Destination: $VENDOR_DIR"
echo ""

mkdir -p "$VENDOR_DIR"

# name|url|ref  (mirrors build-sc-plugins.sh exactly)
PLUGINS="
PortedPlugins|https://github.com/madskjeldgaard/portedplugins.git|main
f0plugins|https://github.com/redFrik/f0plugins.git|master
XPlayBuf|https://github.com/elgiano/XPlayBuf.git|master
NasalDemons|https://github.com/elgiano/NasalDemons.git|main
PulsePTR|https://github.com/robbielyman/pulseptr.git|main
TrianglePTR|https://github.com/robbielyman/triangleptr.git|main
CDSkip|https://github.com/nhthn/supercollider-cd-skip.git|main
mi-UGens|https://github.com/v7b1/mi-UGens.git|master
SuperBuf|https://github.com/esluyter/super-bufrd.git|master
IBufWr|https://github.com/tremblap/IBufWr.git|main
"

while IFS='|' read -r name url ref; do
    [ -z "$name" ] && continue
    dest="$VENDOR_DIR/$name"

    if [ -d "$dest/.git" ] && [ "$FORCE_UPDATE" != "--update" ]; then
        echo "  $name: already cloned (use --update to refresh)"
        continue
    fi

    if [ -d "$dest/.git" ]; then
        echo "  $name: updating to latest $ref"
        git -C "$dest" fetch --depth=1 origin "$ref"
        git -C "$dest" checkout FETCH_HEAD
        git -C "$dest" submodule update --init --recursive 2>/dev/null || true
    else
        echo "  $name: cloning $ref"
        rm -rf "$dest"
        git clone --depth=1 --branch "$ref" --recursive "$url" "$dest" \
            2>/dev/null || git clone --depth=1 --recursive "$url" "$dest"
    fi
done <<< "$PLUGINS"

echo ""
echo "=== Done. Plugins in vendor/sc-community-plugins/:"
ls "$VENDOR_DIR"/
echo ""
echo "Ready for: make pkgs-rebuild PACKAGES=panicos-sc3-community-plugins DEVICE=<dev> FLAVOR=launcher"

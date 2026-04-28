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
    # TODO: blob mode handled in Task 4
    echo ">>> INFO: BUILD_MODE=from-blobs — blob staging not yet implemented (Task 4)."
    echo ">>> Skipping Knulli import for $SOC_NAME."
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

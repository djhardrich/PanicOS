#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib/import-common.sh"

KNULLI="$ROOT/third_party/knulli"
SOC_VENDOR="$ROOT/soc/allwinner-h700/vendor"
MANIFEST="$ROOT/soc/allwinner-h700/source.manifest.v2"

FORCE=0
for arg in "$@"; do case "$arg" in --force) FORCE=1 ;; *) exit 2;; esac; done

KNULLI_SHA=$(git -C "$KNULLI" rev-parse HEAD)
echo ">>> Knulli submodule: $KNULLI_SHA"

if [ -f "$MANIFEST" ] && [ "$FORCE" = 0 ]; then
    if ! check_drift "$MANIFEST" "$ROOT" "knulli-h700-vendor"; then
        echo "Use --force to overwrite." >&2; exit 1
    fi
fi

TSV=$(mktemp); trap 'rm -f "$TSV"' EXIT

import_file "$KNULLI" "$KNULLI_SHA" \
    "board/batocera/allwinner/h700/linux-sunxi64-legacy.config" \
    "$SOC_VENDOR/linux/linux.config.fragment" "$TSV"

NEW_SECTION=$(mktemp); trap 'rm -f "$TSV" "$NEW_SECTION"' EXIT
render_manifest_section "$TSV" "knulli-h700-vendor" "third_party/knulli" "$KNULLI_SHA" "$ROOT" > "$NEW_SECTION"

python3 - "$MANIFEST" "$NEW_SECTION" <<'PY'
import sys, re
manifest_path, new_section_path = sys.argv[1], sys.argv[2]
new_section = open(new_section_path).read()
text = open(manifest_path).read()
text = re.sub(r'(?ms)^  - name: knulli-h700-vendor\n.*?(?=^  - name:|\Z)', '', text)
text = text.rstrip() + '\n' + new_section
open(manifest_path, 'w').write(text)
PY

echo ">>> done"

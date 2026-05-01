#!/usr/bin/env bash
# Copy a ProHandheldTracker dist payload into vendor/pht/ for the
# panicos-pht buildroot package to consume. The payload is too big
# (~64MB of plugins, soundfonts, etc.) to commit to the repo, so we
# vendor a snapshot from the user's local prohandheldtracker-build tree.
#
# Defaults to ~/prohandheldtracker-build/dist/stage/pht; override with --src.
# Strips armv7-only artefacts to keep the vendored copy aarch64-only.

set -euo pipefail

SRC="${HOME}/prohandheldtracker-build/dist/stage/pht"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/vendor/pht"

while [ $# -gt 0 ]; do
    case "$1" in
        --src) SRC="$2"; shift 2 ;;
        --dest) DEST="$2"; shift 2 ;;
        -h|--help)
            cat <<EOF
Usage: $0 [--src <pht-stage-dir>] [--dest <vendor-dir>]
Vendors a PHT payload from --src into --dest for the panicos-pht
buildroot package.

Defaults:
  --src   $HOME/prohandheldtracker-build/dist/stage/pht
  --dest  $ROOT/vendor/pht
EOF
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

[ -d "$SRC" ] || { echo "source not found: $SRC" >&2; exit 1; }
[ -f "$SRC/bin/pht-aarch64" ] || { echo "missing $SRC/bin/pht-aarch64" >&2; exit 1; }

echo ">>> vendor-pht: $SRC → $DEST"
rm -rf "$DEST"
mkdir -p "$DEST"

# Top-level files we want.
for f in README.md control.txt icon.png; do
    [ -f "$SRC/$f" ] && cp "$SRC/$f" "$DEST/"
done

# Whole subtrees we want verbatim.
for d in plugins assets scripts; do
    [ -d "$SRC/$d" ] && cp -a "$SRC/$d" "$DEST/"
done

# bin/: keep aarch64 binaries only, drop armv7 + intel-only helpers.
mkdir -p "$DEST/bin"
for src in "$SRC/bin"/*-aarch64; do
    [ -f "$src" ] || continue
    cp "$src" "$DEST/bin/$(basename "$src")"
done
# yt-dlp.pyz + copyparty-sfx.py are arch-agnostic Python; keep them.
for f in yt-dlp.pyz copyparty-sfx.py; do
    [ -f "$SRC/bin/$f" ] && cp "$SRC/bin/$f" "$DEST/bin/"
done

# libs-aarch64/: shairport-sync's runtime deps (libsoxr, libcrypto, ...).
[ -d "$SRC/libs-aarch64" ] && cp -a "$SRC/libs-aarch64" "$DEST/libs-aarch64"

echo ">>> vendor-pht: vendored $(du -sh "$DEST" | cut -f1) into $DEST"
echo ">>> vendor-pht: files: $(find "$DEST" -type f | wc -l)"

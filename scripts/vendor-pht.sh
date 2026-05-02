#!/usr/bin/env bash
# Copy a ProHandheldTracker dist payload into vendor/pht/ for the
# panicos-pht buildroot package to consume. The payload is too big
# (~100MB of binaries, plugins, soundfonts, etc.) to commit to the
# repo, so we vendor a snapshot from the user's local
# prohandheldtracker-build tree.
#
# DEFAULT BEHAVIOR: invokes the upstream `scripts/license-setup.sh port`
# in $PHT_REPO so the vendored binary has copy-protection embedded
# against the existing signing key. The script REUSES signing.key if
# it's already present (it does NOT regenerate the key), so existing
# licenses keep working. The protected aarch64 build is bundled into
# dist/pht-portmaster.zip — we extract THAT (not the loose
# dist/pht-portmaster/ tree, which may be stale relative to the zip)
# and vendor the contents.
#
# Override paths via --src / --dest. Passing --src skips the
# license-setup invocation (use this for dev/debug builds where you
# want to vendor an unprotected stage/ binary instead).
#
# Strips armv7-only artefacts to keep the vendored copy aarch64-only.

set -euo pipefail

PHT_REPO="${PHT_REPO:-${HOME}/prohandheldtracker-build}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/vendor/pht"
SRC=""                  # set explicitly to skip license-setup.sh
SKIP_LICENSE_SETUP=0    # auto-set when --src is given

while [ $# -gt 0 ]; do
    case "$1" in
        --src) SRC="$2"; SKIP_LICENSE_SETUP=1; shift 2 ;;
        --dest) DEST="$2"; shift 2 ;;
        --skip-license-setup) SKIP_LICENSE_SETUP=1; shift ;;
        -h|--help)
            cat <<EOF
Usage: $0 [--src <pht-dir>] [--dest <vendor-dir>] [--skip-license-setup]

Vendors a PHT payload into --dest for the panicos-pht buildroot package.

Default flow (no --src): runs '\$PHT_REPO/scripts/license-setup.sh port' to
produce a protection-enabled aarch64 build bundled into
\$PHT_REPO/dist/pht-portmaster.zip, then extracts the zip to a temp dir
and vendors from there. Reuses an existing signing.key (does not
regenerate). Set PHT_REPO to point at a non-default checkout.

With --src: skips license-setup.sh entirely and vendors verbatim from the
given path. Use this for unprotected dev builds (e.g.
~/prohandheldtracker-build/dist/stage/pht).

Defaults:
  PHT_REPO  $HOME/prohandheldtracker-build
  --dest    $ROOT/vendor/pht
EOF
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# Default flow: invoke license-setup.sh port to produce the protected build.
if [ "$SKIP_LICENSE_SETUP" -eq 0 ]; then
    [ -d "$PHT_REPO" ] || {
        echo "PHT_REPO not found: $PHT_REPO" >&2
        echo "Set PHT_REPO=<path-to-prohandheldtracker-build> or pass --src" >&2
        exit 1
    }
    [ -f "$PHT_REPO/scripts/license-setup.sh" ] || {
        echo "missing $PHT_REPO/scripts/license-setup.sh" >&2; exit 1
    }
    [ -f "$PHT_REPO/signing.key" ] || {
        echo "no signing.key at $PHT_REPO/signing.key" >&2
        echo "Run scripts/license-setup.sh once manually to generate one;" >&2
        echo "subsequent vendor passes will reuse it." >&2
        exit 1
    }

    echo ">>> vendor-pht: invoking license-setup.sh port (reusing existing signing.key)"
    # Pipe 'n' so the "Re-embed tables from existing key?" prompt is
    # answered no — we want the tables that already match signing.key.
    ( cd "$PHT_REPO" && echo n | ./scripts/license-setup.sh port )

    PORT_ZIP="$PHT_REPO/dist/pht-portmaster.zip"
    [ -f "$PORT_ZIP" ] || {
        echo "license-setup.sh port did not produce $PORT_ZIP" >&2
        exit 1
    }

    # Extract the freshly-built zip to a temp dir and vendor from there.
    # Trusting the zip (not loose dist/pht-portmaster/) since make-port.sh
    # treats the zip as the canonical output.
    EXTRACT_DIR="$(mktemp -d -t panicos-vendor-pht.XXXXXX)"
    trap 'rm -rf "$EXTRACT_DIR"' EXIT
    echo ">>> vendor-pht: extracting $PORT_ZIP → $EXTRACT_DIR"
    unzip -q "$PORT_ZIP" -d "$EXTRACT_DIR"
    SRC="$EXTRACT_DIR/pht"
fi

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

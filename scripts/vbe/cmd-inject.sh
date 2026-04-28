#!/usr/bin/env bash
# vbe inject <archive.tar.gz> <input.squashfs> [--out PATH] [--allow-empty]
set -euo pipefail

ARCHIVE="${1:?usage: vbe inject <archive.tar.gz> <input.squashfs> [--out PATH]}"
SQ="${2:?usage: vbe inject <archive.tar.gz> <input.squashfs> [--out PATH]}"
shift 2
OUT="${SQ%.squashfs}-with-vendor-modules.squashfs"
ALLOW_EMPTY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="$2"; shift 2 ;;
        --allow-empty) ALLOW_EMPTY=1; shift ;;
        *) echo "vbe inject: unknown arg: $1" >&2; exit 2 ;;
    esac
done

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK=$(mktemp -d -p "$ROOT/output/vbe" inject.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# 1. Stage archive
mkdir -p "$WORK/archive"
tar -xzf "$ARCHIVE" -C "$WORK/archive"

# Handle MISSING modules case
if [ -f "$WORK/archive/modules/MISSING.txt" ] || [ ! -f "$WORK/archive/modules/lib-modules.tar.gz" ]; then
    MSG="vbe inject: archive contains no modules — nothing to inject. Output is a copy of the input squashfs."
    if [ "$ALLOW_EMPTY" -eq 0 ]; then
        echo "$MSG" >&2
        echo "vbe inject: pass --allow-empty to produce a verbatim copy of the input squashfs." >&2
        exit 1
    fi
    echo "$MSG"
    cp "$SQ" "$OUT"
    echo ">>> wrote $OUT ($(stat -c%s "$OUT") bytes)"
    exit 0
fi

# 2. Unsquashfs
unsquashfs -d "$WORK/rootfs" "$SQ"

# 3. Read kver and inject modules
# lib-modules.tar.gz paths start with lib/modules/<kver>/; extract into rootfs root.
KVER=$(cat "$WORK/archive/modules/kver.txt")
mkdir -p "$WORK/rootfs/lib/modules"
tar -xzf "$WORK/archive/modules/lib-modules.tar.gz" -C "$WORK/rootfs"

# 4. depmod (host depmod, arch-agnostic)
[ -d "$WORK/rootfs/lib/modules/$KVER" ] || {
    echo "vbe inject: error: expected /lib/modules/$KVER not found after extract" >&2
    ls "$WORK/rootfs/lib/modules/" >&2
    exit 1
}
depmod -b "$WORK/rootfs" "$KVER"

# 5. mksquashfs
mksquashfs "$WORK/rootfs" "$OUT" -comp gzip -no-progress -noappend

echo ">>> wrote $OUT ($(stat -c%s "$OUT") bytes)"

#!/usr/bin/env bash
# PanicOS Vendor Blob Extractor
# Usage:
#   vbe.sh extract <vendor-image> [--out <archive.tar.gz>]
#   vbe.sh inject <archive.tar.gz> <input.squashfs> [--out <output.squashfs>]
#   vbe.sh build-image <archive.tar.gz> <squashfs> --out <flashable.img.gz>
#                       [--system-size 8G] [--overlay-size 64M]
#   vbe.sh port <vendor-image> <panicos-base.squashfs> --out <flashable.img.gz>
#   vbe.sh identify <image>           # diagnostic: print format detection results
#   vbe.sh --help

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VBE_DIR="$ROOT/scripts/vbe"

usage() {
    cat <<EOF >&2
PanicOS Vendor Blob Extractor (VBE)

Subcommands:
  extract <vendor-image> [--out FILE]      Extract blobs into a tar.gz archive
  inject  <archive> <squashfs> [--out FILE]  Inject vendor modules into a squashfs
  build-image <archive> <squashfs> --out FILE  Assemble a flashable image
  port    <vendor-image> <squashfs> --out FILE  extract + inject + build-image (one-shot)
  identify <image>                         Diagnostic: print detection results

Run 'vbe.sh <subcommand> --help' for subcommand-specific help.
EOF
    exit 2
}

[ $# -lt 1 ] && usage

cmd="$1"; shift
case "$cmd" in
    extract|inject|build-image|port|identify)
        exec "$VBE_DIR/cmd-${cmd}.sh" "$@"
        ;;
    --help|-h|help)
        usage
        ;;
    *)
        echo "vbe: unknown subcommand: $cmd" >&2
        usage
        ;;
esac

#!/usr/bin/env bash
# vbe extract <vendor-image> [--out <archive.tar.gz>]
set -euo pipefail
. "$(dirname "$0")/lib-format.sh"

# arg parse: $1 = image, --out <path>
IMAGE="${1:?usage: vbe extract <vendor-image> [--out PATH]}"
shift
OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="$2"; shift 2 ;;
        *) echo "vbe extract: unknown arg: $1" >&2; exit 2 ;;
    esac
done

mkdir -p output/vbe
WORK=$(mktemp -d -p output/vbe extract.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

RAW=$(vbe_unwrap "$IMAGE" "$WORK")
SOC=$(vbe_soc_hint "$RAW")

# Dispatch to extractor
case "$SOC" in
    allwinner-*) "$(dirname "$0")/extract-allwinner.sh" "$RAW" "$WORK" ;;
    rockchip-*)  "$(dirname "$0")/extract-rockchip.sh"  "$RAW" "$WORK" ;;
    *)           "$(dirname "$0")/extract-generic.sh"   "$RAW" "$WORK" ;;
esac

# Auto-derive output filename
if [ -z "$OUT" ]; then
    KVER=$(grep -oP 'Linux version \K[^ ]+' "$WORK/kernel/kernel-info.txt" 2>/dev/null || echo "unknown-kver")
    SHA8=$(sha256sum "$IMAGE" | awk '{print substr($1,1,8)}')
    OUT="output/vbe/vbe-$SOC-$KVER-$SHA8.tar.gz"
    mkdir -p "$(dirname "$OUT")"
fi

# Bundle: cd into WORK so archive paths don't have leading ./extract.XXXXXX/
( cd "$WORK" && tar -czf - . ) > "$OUT"
echo ">>> wrote $OUT ($(stat -c%s "$OUT") bytes)"

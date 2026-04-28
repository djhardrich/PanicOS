#!/usr/bin/env bash
# vbe identify <image>
# Detects wrapper format, partition table, per-partition info, and SoC hint.
# Outputs YAML to stdout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib-format.sh"

IMAGE="${1:?usage: vbe identify <image>}"

# Resolve absolute path for display
IMAGE_ABS="$(realpath "$IMAGE")"

# Working dir under output/vbe (created by caller or we create it)
mkdir -p output/vbe
WORK=$(mktemp -d -p output/vbe identify.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# --- Wrapper format ---
FTYPE=$(file -b "$IMAGE")
case "$FTYPE" in
    *"gzip compressed data"*)  WRAPPER="gzip" ;;
    *"XZ compressed data"*)    WRAPPER="xz"   ;;
    *)                          WRAPPER="raw"  ;;
esac

# --- Unwrap ---
RAW=$(vbe_unwrap "$IMAGE" "$WORK")

# --- Partition table ---
TABLE=$(vbe_partition_table "$RAW")

# --- SoC hint ---
SOC=$(vbe_soc_hint "$RAW")

# --- Size ---
SIZE=$(stat -c%s "$RAW")

# --- YAML output ---
cat <<EOF
image: $IMAGE_ABS
wrapper: $WRAPPER
size_bytes: $SIZE
partition_table: $TABLE
soc_hint: $SOC
partitions:
EOF

vbe_partitions "$RAW" | while IFS=$'\t' read -r num start size_s fstype label; do
    cat <<EOF
  - num: $num
    start_sector: $start
    size_sectors: $size_s
    fstype: ${fstype:-unknown}
    label: ${label:-''}
EOF
done

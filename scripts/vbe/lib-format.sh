#!/usr/bin/env bash
# lib-format.sh — shared VBE format detection helpers
# Source this file; do not execute directly.
#
# Functions:
#   vbe_unwrap    <input> <output_dir>  -> prints path to raw.img
#   vbe_partition_table <raw_img>       -> prints mbr / gpt / none
#   vbe_partitions      <raw_img>       -> TSV: num start_sector size_sectors fstype label
#   vbe_soc_hint        <raw_img>       -> prints allwinner-sunxi / rockchip-rk3xxx / unknown

set -euo pipefail

# ---------------------------------------------------------------------------
# vbe_unwrap <input> <output_dir>
#   Decompresses gzip/xz to <output_dir>/raw.img, or symlinks if already raw.
#   Prints the path to the raw image on stdout.
# ---------------------------------------------------------------------------
vbe_unwrap() {
    local input="$1"
    local output_dir="$2"
    local raw="$output_dir/raw.img"

    local ftype
    ftype=$(file -b "$input")

    case "$ftype" in
        *"gzip compressed data"*)
            echo "  [unwrap] decompressing gzip -> $raw" >&2
            gzip -dc "$input" > "$raw"
            ;;
        *"XZ compressed data"*)
            echo "  [unwrap] decompressing xz -> $raw" >&2
            xz -dc "$input" > "$raw"
            ;;
        *)
            # Assume raw — symlink so callers always get the same path
            echo "  [unwrap] raw image, symlinking -> $raw" >&2
            ln -sf "$(realpath "$input")" "$raw"
            ;;
    esac

    echo "$raw"
}

# ---------------------------------------------------------------------------
# vbe_partition_table <raw_img>
#   Prints: mbr / gpt / none
# ---------------------------------------------------------------------------
vbe_partition_table() {
    local img="$1"
    local parted_out
    parted_out=$(parted -s -m "$img" print 2>&1) || true

    # BYT; line followed by image info line, then table type embedded:
    # /dev/...:SIZE:file:512:512:gpt::;   <- "gpt"
    # /dev/...:SIZE:file:512:512:msdos::; <- "msdos" = MBR
    local label
    label=$(echo "$parted_out" | awk -F: 'NR==2 {print $6}')

    case "$label" in
        gpt)   echo "gpt" ;;
        msdos) echo "mbr" ;;
        *)     echo "none" ;;
    esac
}

# ---------------------------------------------------------------------------
# vbe_partitions <raw_img>
#   Prints TSV lines: num  start_sector  size_sectors  fstype  label
# ---------------------------------------------------------------------------
vbe_partitions() {
    local img="$1"
    local parted_out
    parted_out=$(parted -s -m "$img" unit s print 2>&1) || true

    # Machine-readable parted output (unit s):
    # BYT;
    # /dev/...:17539112s:file:512:512:gpt::;
    # 1:73728s:104447s:30720s::boot-fw:;
    # Fields: num:start:end:size:fstype:name:flags;
    echo "$parted_out" | awk -F: '
    NR <= 2 { next }
    {
        num   = $1
        start = $2; gsub(/s/, "", start)
        # end = $3 (not needed)
        size  = $4; gsub(/s/, "", size)
        fstype = $5
        label  = $6
        # Skip empty lines or non-partition lines
        if (num ~ /^[0-9]+$/) {
            printf "%s\t%s\t%s\t%s\t%s\n", num, start, size, fstype, label
        }
    }'
}

# ---------------------------------------------------------------------------
# vbe_soc_hint <raw_img>
#   Prints: allwinner-sunxi / rockchip-rk3xxx / unknown
#
#   Detection strategy (in order):
#   1. Rockchip idbloader: magic "RKNS" at sector 64 (offset 32768)
#   2. Allwinner SPL: "eGON.BT0" anywhere in first 1 MiB
#   3. fallback: strings scan for SoC identifiers in first 4 MiB
# ---------------------------------------------------------------------------
vbe_soc_hint() {
    local img="$1"

    # --- 1. Rockchip: "RKNS" at byte offset 32768 (sector 64) ---
    # Use grep on the raw bytes rather than command substitution to avoid
    # bash "ignored null byte in input" warnings with binary data.
    if dd if="$img" bs=1 skip=32768 count=4 2>/dev/null | grep -qP '^RKNS'; then
        echo "rockchip-rk3xxx"
        return
    fi

    # --- 2. Allwinner: "eGON.BT0" in first 1 MiB ---
    # The eGON SPL magic is a 4-byte header then "eGON.BT0".
    # It appears at various aligned offsets depending on SoC generation
    # (0x2004, 0x20004, etc.), so we scan the whole first MiB.
    local egon_found
    egon_found=$(dd if="$img" bs=1 count=1048576 2>/dev/null | \
        grep -aob 'eGON.BT0' 2>/dev/null | head -1 || true)
    if [ -n "$egon_found" ]; then
        echo "allwinner-sunxi"
        return
    fi

    # --- 3. Fallback: strings scan in first 4 MiB for known SoC identifiers ---
    local soc_strings
    soc_strings=$(dd if="$img" bs=1M count=4 2>/dev/null | \
        strings 2>/dev/null | grep -Ei 'allwinner|sun50i|sun8i|sun9i|rk3[0-9]|rockchip' | head -5 || true)

    if echo "$soc_strings" | grep -qi 'allwinner\|sun50i\|sun8i\|sun9i'; then
        echo "allwinner-sunxi"
        return
    fi
    if echo "$soc_strings" | grep -qi 'rk3[0-9]\|rockchip'; then
        echo "rockchip-rk3xxx"
        return
    fi

    echo "unknown"
}

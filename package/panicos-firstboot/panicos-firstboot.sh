#!/bin/sh
# PanicOS first-boot: grow the overlay partition + ext4 to fill the SD card.
# Self-disables after success.

set -eu

MARKER=/storage/.panicos-firstboot-done
[ -f "$MARKER" ] && exit 0

DISK=/dev/mmcblk0
OVERLAY_PART_NUM=3
OVERLAY_DEV="${DISK}p${OVERLAY_PART_NUM}"

echo ">>> panicos-firstboot: growing $OVERLAY_DEV"

sfdisk -d "$DISK" > /tmp/parts.dump
awk -v n="$OVERLAY_PART_NUM" -v disk="$DISK" '
    /^[^#]/ && $0 ~ "^"disk"p"n" :" {
        sub(/, size=[^,]+/, "");
    }
    { print }
' /tmp/parts.dump > /tmp/parts.new
sfdisk --no-reread "$DISK" < /tmp/parts.new
partprobe "$DISK" || true
resize2fs "$OVERLAY_DEV"

mkdir -p /storage
touch "$MARKER"

echo ">>> panicos-firstboot: done"

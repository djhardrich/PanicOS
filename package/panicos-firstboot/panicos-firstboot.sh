#!/bin/sh
# PanicOS first-boot: grow the storage partition + ext4 to fill the SD card.
# /storage is the rw ext4 mounted by initramfs, holding user data PLUS the
# overlayfs upper+work dirs under .panicos-overlay/. Self-disables after
# success via marker file.

set -eu
set -x

MARKER=/storage/.panicos-firstboot-done
[ -f "$MARKER" ] && exit 0

# Find the device backing /storage (mounted by initramfs). Read /proc/mounts
# directly — findmnt isn't in the busybox / minimal util-linux subset we ship.
# Works regardless of whether SD enumerates as mmcblk0 (mainline) or mmcblk1
# (Brick).
STORAGE_DEV="$(awk '$2 == "/storage" {print $1; exit}' /proc/mounts)"
[ -n "$STORAGE_DEV" ] || { echo "panicos-firstboot: /storage not mounted" >&2; exit 1; }

DISK="$(echo "$STORAGE_DEV" | sed 's/p[0-9]*$//')"
PARTNUM="$(echo "$STORAGE_DEV" | sed 's|.*p||')"

echo ">>> panicos-firstboot: growing $STORAGE_DEV (disk=$DISK partnum=$PARTNUM)"

# Grow the partition to fill remaining free space (`,+` = keep start, max size).
echo ',+' | sfdisk -N "$PARTNUM" --no-reread --force "$DISK"
partprobe "$DISK" 2>/dev/null || partx -u "$DISK" 2>/dev/null || true

# Online resize the ext4 — works while mounted r/w.
resize2fs "$STORAGE_DEV"

touch "$MARKER"
echo ">>> panicos-firstboot: done"

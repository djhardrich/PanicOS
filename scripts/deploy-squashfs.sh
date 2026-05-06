#!/usr/bin/env bash
# deploy-squashfs.sh — copy a squashfs flavor to the device boot partition.
# Usage: scripts/deploy-squashfs.sh <path/to/file.squashfs> [host]
#
# Remounts /boot rw for the transfer, then restores ro.
# Default host: root@192.168.1.181

set -euo pipefail

SRC="${1:?usage: $0 <file.squashfs> [host]}"
HOST="${2:-root@192.168.1.181}"

[ -f "$SRC" ] || { echo "error: $SRC not found" >&2; exit 1; }
[[ "$SRC" == *.squashfs ]] || { echo "error: $SRC doesn't look like a squashfs" >&2; exit 1; }

FNAME="$(basename "$SRC")"
SIZE="$(du -sh "$SRC" | cut -f1)"

echo ">>> Deploying $FNAME ($SIZE) to $HOST:/boot/"
ssh "$HOST" 'mount -o remount,rw /boot'
scp "$SRC" "$HOST:/boot/$FNAME"
ssh "$HOST" 'mount -o remount,ro /boot'
echo ">>> Done. To boot into it:"
echo "    ssh $HOST \"mount -o remount,rw /boot && echo IMAGE=$FNAME > /boot/panicos-active.cfg && mount -o remount,ro /boot\""

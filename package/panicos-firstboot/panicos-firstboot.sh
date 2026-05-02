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

# Pre-extract PortMaster + bundled ports into /storage/roms/ports/. ES's
# "Ports" system only scans top-level *.sh in this dir (SystemData.cpp:394
# hardcodes a "skip dirs containing 'ports'" rule when recursing), so a
# preinstalled tree gives the user an immediately-populated Ports menu
# without an Install.PortMaster.sh round-trip on first launch. ROCKNIX
# ships PortMaster the same way (vendored at build time, dropped into
# place at boot). zips live in /usr/share/panicos-launcher/portmaster-preload/.
PRELOAD=/usr/share/panicos-launcher/portmaster-preload
if [ -d "$PRELOAD" ]; then
    mkdir -p /storage/roms/ports
    for z in "$PRELOAD"/*.zip; do
        [ -e "$z" ] || continue
        # -n: never overwrite — if a user has already started using a port
        # (saves, configs), we must not stomp on it on a re-firstboot.
        unzip -q -n "$z" -d /storage/roms/ports
    done
    # Top-level launcher shims need executable bits; unzip preserves zip
    # internal modes which are unreliable across platforms.
    find /storage/roms/ports -maxdepth 1 -name "*.sh" -exec chmod +x {} +
    # Inner PortMaster.sh (the GUI's main launcher) too.
    [ -e /storage/roms/ports/PortMaster/PortMaster.sh ] && \
        chmod +x /storage/roms/ports/PortMaster/PortMaster.sh
fi

# Top-level PortMaster.sh launcher shim. PortMaster.zip extracts only
# under PortMaster/ — there's no top-level launcher. Symlink to the
# vendored shim so ES's Ports menu sees a "PortMaster" entry that does
# `cd PortMaster && exec ./PortMaster.sh`.
[ -e /usr/share/panicos-launcher/tools/PortMaster.sh ] && \
    [ ! -e /storage/roms/ports/PortMaster.sh ] && \
    ln -sf /usr/share/panicos-launcher/tools/PortMaster.sh /storage/roms/ports/PortMaster.sh

touch "$MARKER"
echo ">>> panicos-firstboot: done"

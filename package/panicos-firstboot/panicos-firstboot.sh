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
    # PortMaster.zip ships exec bits ONLY on .sh files and pugwash
    # (Python with shebang). gptokeyb, sdl2imgshow.*, xdelta3, etc.
    # come in mode 644. Upstream PortMaster.sh fixes this with
    # `$ESUDO chmod -R +x .`, but a port like Doom Engines.sh that
    # invokes $GPTOKEYB before the user has run PortMaster GUI hits
    # "/roms/ports/PortMaster/gptokeyb: Permission denied". Be eager
    # and chmod the whole tree on first boot. Same for any extracted
    # port subdirs that ship binaries.
    [ -d /storage/roms/ports/PortMaster ] && \
        chmod -R +x /storage/roms/ports/PortMaster
    for portdir in /storage/roms/ports/*/; do
        [ -d "$portdir" ] && [ "$portdir" != "/storage/roms/ports/PortMaster/" ] && \
            find "$portdir" -type f \( -name "*.sh" -o -name "*.so*" \) -exec chmod +x {} + 2>/dev/null || true
    done
fi

# Drop our PortMaster CFW mod into the extracted PortMaster directory.
# PortMaster's PortMaster.sh sources $controlfolder/mod_${CFW_NAME}.txt
# (CFW_NAME=PanicOS, set by device_info.txt's OS_NAME-fallback branch
# reading our /etc/os-release). The mod defines pm_platform_helper +
# LIBGL_DRIVERS_PATH for our environment.
MOD=/usr/share/panicos-launcher/tools/mod_PanicOS.txt
if [ -f "$MOD" ] && [ -d /storage/roms/ports/PortMaster ]; then
    cp -f "$MOD" /storage/roms/ports/PortMaster/mod_PanicOS.txt
fi

# Override PortMaster's bundled gamecontrollerdb.txt with our vendored
# ROCKNIX copy — has the H700 Gamepad mapping (and other handheld pads)
# that PortMaster's generic upstream version is missing. Without this
# A/B come up swapped and Start+Select hotkey combos don't register
# (e.g. Rockbox quit). Symlink rather than copy so a system-package
# upgrade auto-applies.
GCDB=/usr/share/SDL-GameControllerDB/gamecontrollerdb.txt
if [ -f "$GCDB" ] && [ -d /storage/roms/ports/PortMaster ]; then
    ln -sf "$GCDB" /storage/roms/ports/PortMaster/gamecontrollerdb.txt
fi

# Top-level PortMaster.sh launcher shim. PortMaster.zip extracts only
# under PortMaster/ — there's no top-level launcher. Symlink to the
# vendored shim so ES's Ports menu sees a "PortMaster" entry that does
# `cd PortMaster && exec ./PortMaster.sh`.
[ -e /usr/share/panicos-launcher/tools/PortMaster.sh ] && \
    [ ! -e /storage/roms/ports/PortMaster.sh ] && \
    ln -sf /usr/share/panicos-launcher/tools/PortMaster.sh /storage/roms/ports/PortMaster.sh

# /roms compatibility symlink. PortMaster's inner PortMaster.sh + every
# port launcher in the catalog hardcodes /roms/ports/<port>/ paths,
# relying on the host CFW to symlink /roms to wherever the writable
# storage actually lives (ROCKNIX maps /roms -> /storage/roms; ArkOS
# uses /roms directly; etc.). Without this symlink PortMaster errors at
# launch with "/roms/ports/PortMaster/control.txt: No such file or
# directory" before it even finishes parsing its CFW detection. The
# symlink lands in the overlayfs upper, so it persists across reboots
# without rebaking the squashfs.
[ -e /roms ] || ln -sf /storage/roms /roms

touch "$MARKER"
echo ">>> panicos-firstboot: done"

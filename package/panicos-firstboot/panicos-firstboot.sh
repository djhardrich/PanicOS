#!/bin/sh
# PanicOS first-boot: grow the storage partition + ext4 to fill the SD card.
#
# Storage layout (as of storage-v2):
#   /storage      — per-flavor overlayfs (writes go to the flavor's upper dir)
#   /storage-base — raw ext4, exposed for admin/migration use
#
# The marker lives in /storage (the per-flavor overlay), so each squashfs
# flavor runs firstboot independently. ROCKNIX's systemd never runs this
# service; the marker is purely cosmetic isolation.

set -eu
set -x

MARKER=/storage/.panicos-firstboot-done

# Ensure the squashfs staging dir exists on every boot (idempotent, runs even
# when the marker is present so upgrades that add this dir still get it).
mkdir -p /storage/squashfs

# ── Storage-v2 migration (existing devices upgrading from pre-v2 layout) ──────
# Pre-v2: the ext4 was mounted directly at /storage, so user data lived at
# /storage/roms, /storage/.emulationstation, etc. (now accessible via
# /storage-base/ since the raw ext4 is exposed there).
# Post-v2: /storage is a per-flavor overlay; the ext4 root is /storage-base.
# On first boot after upgrade the marker won't exist in the new per-flavor
# overlay even though all the data is already on the ext4. Detect this with
# the old-layout marker at /storage-base/.panicos-firstboot-done and migrate.
OLD_MARKER=/storage-base/.panicos-firstboot-done
if [ -f "$OLD_MARKER" ] && [ ! -f "$MARKER" ]; then
    echo ">>> panicos-firstboot: storage-v2 migration — copying data to per-flavor overlay"
    # Roms (PortMaster, ports, games)
    if [ -d /storage-base/roms ] && [ "$(ls -A /storage-base/roms 2>/dev/null)" ]; then
        mkdir -p /storage/roms
        cp -a /storage-base/roms/. /storage/roms/ 2>/dev/null || true
    fi
    # EmulationStation config (theme selection, system configs)
    [ -d /storage-base/.emulationstation ] && \
        [ ! -d /storage/.emulationstation ] && \
        cp -a /storage-base/.emulationstation /storage/ 2>/dev/null || true
    # Squashfs staging area
    [ -d /storage-base/squashfs ] && \
        cp -a /storage-base/squashfs/. /storage/squashfs/ 2>/dev/null || true
    touch "$MARKER"
    echo ">>> panicos-firstboot: migration done"
    exit 0
fi
# ─────────────────────────────────────────────────────────────────────────────

[ -f "$MARKER" ] && exit 0

# Find the device backing /storage-base (the raw ext4, mounted by initramfs).
# /storage is the overlay; partition resize targets the underlying ext4.
STORAGE_DEV="$(awk '$2 == "/storage-base" {print $1; exit}' /proc/mounts)"
[ -n "$STORAGE_DEV" ] || { echo "panicos-firstboot: /storage-base not mounted" >&2; exit 1; }

DISK="$(echo "$STORAGE_DEV" | sed 's/p[0-9]*$//')"
PARTNUM="$(echo "$STORAGE_DEV" | sed 's|.*p||')"

echo ">>> panicos-firstboot: growing $STORAGE_DEV (disk=$DISK partnum=$PARTNUM)"
echo -ne "\033[1000H\033[2K==> Resizing SD card storage partition..." >/dev/console

echo ',+' | sfdisk -N "$PARTNUM" --no-reread --force "$DISK"
partprobe "$DISK" 2>/dev/null || partx -u "$DISK" 2>/dev/null || true
resize2fs "$STORAGE_DEV"

# Pre-extract PortMaster + bundled ports into /storage/roms/ports/.
PRELOAD=/usr/share/panicos-launcher/portmaster-preload
if [ -d "$PRELOAD" ]; then
    mkdir -p /storage/roms/ports
    for z in "$PRELOAD"/*.zip; do
        [ -e "$z" ] || continue
        echo -ne "\033[1000H\033[2K==> Installing $(basename "$z" .zip)..." >/dev/console
        unzip -q -n "$z" -d /storage/roms/ports
    done
    find /storage/roms/ports -maxdepth 1 -name "*.sh" -exec chmod +x {} +
    for portdir in /storage/roms/ports/*/; do
        [ -d "$portdir" ] && [ "$portdir" != "/storage/roms/ports/PortMaster/" ] && \
            find "$portdir" -type f \( -name "*.sh" -o -name "*.so*" \) -exec chmod +x {} + 2>/dev/null || true
    done
fi

[ -e /usr/share/panicos-launcher/tools/PortMaster.sh ] && \
    [ ! -e /storage/roms/ports/PortMaster.sh ] && \
    ln -sf /usr/share/panicos-launcher/tools/PortMaster.sh /storage/roms/ports/PortMaster.sh

# /roms compatibility symlink for PortMaster's hardcoded paths.
[ -e /roms ] || ln -sf /storage/roms /roms

# Seed ES default theme.
ES_SETTINGS=/storage/.emulationstation/es_settings.cfg
if [ ! -f "$ES_SETTINGS" ]; then
    mkdir -p /storage/.emulationstation
    cat > "$ES_SETTINGS" <<'ESCFG'
<?xml version="1.0"?>
<config>
    <string name="ThemeSet" value="panicos" />
</config>
ESCFG
fi

touch "$MARKER"
echo ">>> panicos-firstboot: done"

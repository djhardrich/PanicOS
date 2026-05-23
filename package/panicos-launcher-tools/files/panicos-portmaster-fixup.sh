#!/bin/sh
# panicos-portmaster-fixup — re-apply our overrides on the extracted
# PortMaster tree before every panicos-es.service start.
#
# Mirrors ROCKNIX's start_portmaster.sh pattern of "always re-apply
# customizations": if the user upgrades PortMaster via the bundled
# Install.PortMaster.sh, our overrides survive the next boot rather
# than living in a one-shot first-boot script that wouldn't fire again.
#
# Idempotent — safe to invoke repeatedly. Three jobs:
#   1. Drop mod_PanicOS.txt so PortMaster's CFW=PanicOS detection finds
#      its sway-fullscreen + LIBGL_DRIVERS_PATH mod.
#   2. Symlink gamecontrollerdb.txt to our vendored system copy (H700
#      Gamepad mapping + ~20 other handheld pads ROCKNIX tracks).
#   3. chmod +x the binaries upstream PortMaster.zip lays down at 644
#      (gptokeyb, sdl2imgshow.*, xdelta3) — without this, ports that
#      call $GPTOKEYB before the user has launched the GUI hit
#      "Permission denied".

set -e

PMDIR=/storage/roms/ports/PortMaster
[ -d "$PMDIR" ] || exit 0   # No PortMaster installed yet — nothing to fix.

MOD=/usr/share/panicos-launcher/tools/mod_PanicOS.txt
[ -f "$MOD" ] && cp -f "$MOD" "$PMDIR/mod_PanicOS.txt"

LIBGL=/usr/share/panicos-launcher/tools/libgl_PanicOS.txt
[ -f "$LIBGL" ] && cp -f "$LIBGL" "$PMDIR/libgl_PanicOS.txt"

GCDB=/usr/share/SDL-GameControllerDB/gamecontrollerdb.txt
PM_ZIP=/usr/share/panicos-launcher/portmaster-preload/PortMaster.zip
PM_GCDB_ORIG=/storage/.config/panicos/portmaster-gcdb-orig.txt
PM_GCDB_MERGED=/storage/.config/panicos/gamecontrollerdb.txt

mkdir -p /storage/.config/panicos

# Cache the original big PortMaster db (6000+ entries for BT controller coverage).
# If the PortMaster runtime file is a plain file (fresh install / self-update),
# save it now before we symlink over it.  Otherwise fall back to the preload zip.
if [ -f "$PMDIR/gamecontrollerdb.txt" ] && [ ! -L "$PMDIR/gamecontrollerdb.txt" ]; then
    cp "$PMDIR/gamecontrollerdb.txt" "$PM_GCDB_ORIG"
elif [ ! -f "$PM_GCDB_ORIG" ] && [ -f "$PM_ZIP" ]; then
    unzip -p "$PM_ZIP" PortMaster/gamecontrollerdb.txt > "$PM_GCDB_ORIG" 2>/dev/null || rm -f "$PM_GCDB_ORIG"
fi

# Build merged db: big db first (BT controller coverage), our custom entries
# appended last so they win for any duplicate GUIDs (SDL uses last-match).
# sdl_controllerconfig must stay empty in mod_PanicOS.txt — never put this
# 472K content in an env var or ports will crash with E2BIG on every exec.
if [ -s "$PM_GCDB_ORIG" ] && [ -f "$GCDB" ]; then
    cat "$PM_GCDB_ORIG" "$GCDB" > "$PM_GCDB_MERGED"
elif [ -f "$GCDB" ]; then
    cp "$GCDB" "$PM_GCDB_MERGED"
fi

if [ -f "$PM_GCDB_MERGED" ]; then
    ln -sf "$PM_GCDB_MERGED" "$PMDIR/gamecontrollerdb.txt"
elif [ -f "$GCDB" ]; then
    ln -sf "$GCDB" "$PMDIR/gamecontrollerdb.txt"
fi

chmod -R +x "$PMDIR" 2>/dev/null || true

exit 0

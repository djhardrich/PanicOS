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
[ -f "$GCDB" ] && ln -sf "$GCDB" "$PMDIR/gamecontrollerdb.txt"

chmod -R +x "$PMDIR" 2>/dev/null || true

exit 0

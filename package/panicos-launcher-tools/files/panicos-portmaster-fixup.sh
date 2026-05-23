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
PM_GCDB_REMAP=/storage/.config/panicos/portmaster-gcdb-remap.txt
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

# Remap the big PortMaster db to Nintendo button convention for BT Linux entries.
# The community db uses Xbox convention (SDL a=south/b0, x=west/b2, y=north/b3).
# H700 needs Nintendo convention (SDL a=east/b1, x=north/b3, y=west/b2).
# Rule: for any BT Linux entry (GUID 05000000…) with a:b0 (south=confirm):
#   - swap a↔b button numbers
#   - swap x↔y button numbers only if x_num < y_num (i.e. x is west, Xbox style)
# Entries already in Nintendo convention (a:b1) are left untouched.
# On failure, fall back to the unmodified orig — GCDB overrides still win
# for the specific controllers listed there.
if [ -s "$PM_GCDB_ORIG" ]; then
    python3 - "$PM_GCDB_ORIG" "$PM_GCDB_REMAP" <<'PYEOF' || cp "$PM_GCDB_ORIG" "$PM_GCDB_REMAP"
import sys, re

def swap_fields(s, key1, key2):
    """Swap the button numbers of two SDL db fields (e.g. 'a' and 'b')."""
    m1 = re.search(r',' + key1 + r':(b\d+),', s)
    m2 = re.search(r',' + key2 + r':(b\d+),', s)
    if not m1 or not m2:
        return s
    v1, v2 = m1.group(1), m2.group(1)
    s = s.replace(f',{key1}:{v1},', f',{key1}:~SW~,', 1)
    s = s.replace(f',{key2}:{v2},', f',{key2}:{v1},', 1)
    s = s.replace(f',{key1}:~SW~,', f',{key1}:{v2},', 1)
    return s

def remap(line):
    s = line.rstrip('\n')
    if not s or s.startswith('#'):
        return line
    if not s.startswith('05'):          # BT GUIDs only
        return line
    if 'platform:Linux' not in s:       # Linux entries only
        return line
    if ',a:b0,' not in s:              # Xbox-convention check (south=confirm)
        return line
    s = swap_fields(s, 'a', 'b')       # a↔b: east face becomes SDL a
    # x↔y only if x_num < y_num (Xbox: x=west=lower-num, y=north=higher-num)
    xm = re.search(r',x:(b(\d+)),', s)
    ym = re.search(r',y:(b(\d+)),', s)
    if xm and ym and int(xm.group(2)) < int(ym.group(2)):
        s = swap_fields(s, 'x', 'y')
    return s + ('\n' if line.endswith('\n') else '')

with open(sys.argv[1]) as f:
    lines = f.readlines()
with open(sys.argv[2], 'w') as f:
    for l in lines:
        f.write(remap(l))
PYEOF
fi

# Build merged db: remapped big db first, our custom ROCKNIX/H700 entries
# appended last (SDL last-match-wins — our entries override any duplicates).
# sdl_controllerconfig must stay empty in mod_PanicOS.txt — never put this
# content in an env var or ports will crash with E2BIG on every exec.
if [ -s "$PM_GCDB_REMAP" ] && [ -f "$GCDB" ]; then
    cat "$PM_GCDB_REMAP" "$GCDB" > "$PM_GCDB_MERGED"
elif [ -s "$PM_GCDB_ORIG" ] && [ -f "$GCDB" ]; then
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

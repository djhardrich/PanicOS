#!/bin/bash
# PanicOS launcher shim — symlinked into /storage/roms/ports/ at first
# boot so ES's Ports menu always has a "PortMaster" entry. Sources
# /etc/profile before exec'ing PortMaster.sh so the sway_fullscreen
# function + UI_SERVICE land in PortMaster's environment (PortMaster.sh
# itself doesn't source /etc/profile, and ES launches us as a non-login
# shell, so we have to do it). Mirrors ROCKNIX's start_portmaster.sh.
# set -e but NOT -u — /etc/profile references $PS1 unguarded which trips
# nounset in a non-interactive shell. ES launches us non-interactively.
set -e

PM=/storage/roms/ports/PortMaster/PortMaster.sh
if [ ! -x "$PM" ]; then
    cat <<EOF
PortMaster is not installed yet.

Run "Install PortMaster" from the same Ports menu (or
/storage/roms/ports/Install.PortMaster.sh) to fetch the latest release,
then come back here.
EOF
    echo
    echo "Press any key to return to EmulationStation..."
    read -r -n 1 _ || true
    exit 1
fi

# /etc/profile pulls in /etc/profile.d/sway-fullscreen.sh which defines
# UI_SERVICE + sway_fullscreen for PortMaster's mod_ROCKNIX.txt path.
[ -f /etc/profile ] && . /etc/profile

cd /storage/roms/ports/PortMaster
exec ./PortMaster.sh "$@"

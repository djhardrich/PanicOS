#!/bin/bash
# PanicOS launcher shim — symlinked into /storage/roms/ports/ at first
# boot so ES's Ports menu always has a "PortMaster" entry. If PortMaster
# itself hasn't been installed yet, point the user at Install.PortMaster.sh.
set -eu

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

cd /storage/roms/ports/PortMaster
exec ./PortMaster.sh "$@"

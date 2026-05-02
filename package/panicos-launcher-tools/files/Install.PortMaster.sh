#!/bin/bash
# PanicOS — fetch + install PortMaster on demand. Runs from the ES "Tools"
# menu so the user opts in when they actually want PortMaster (vs us
# bundling 100MB+ of zip into every flavor's image).
#
# Idempotent — re-running upgrades to the latest release.

set -eu

PORTS_DIR=/storage/roms/ports
RELEASES_API="https://api.github.com/repos/PortsMaster/PortMaster-GUI/releases/latest"

mkdir -p "$PORTS_DIR"

# Resolve the latest release's PortMaster.zip URL via GitHub's API. Falls
# back to the well-known "/releases/latest/download/" redirect if the API
# is unreachable (rate-limit, no internet, etc.).
URL=$(curl -fsSL "$RELEASES_API" 2>/dev/null \
        | sed -n 's/.*"browser_download_url": *"\([^"]*PortMaster\.zip\)".*/\1/p' \
        | head -1)
if [ -z "$URL" ]; then
    URL="https://github.com/PortsMaster/PortMaster-GUI/releases/latest/download/PortMaster.zip"
    echo "(github API unreachable, using fallback URL)"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo ">>> Downloading PortMaster from $URL"
curl -fL --progress-bar -o "$TMP/PortMaster.zip" "$URL"

echo ">>> Extracting to $PORTS_DIR/PortMaster"
# Wipe any previous install so we don't leave stale files behind on upgrade.
rm -rf "$PORTS_DIR/PortMaster"
unzip -q "$TMP/PortMaster.zip" -d "$PORTS_DIR"
chmod +x "$PORTS_DIR/PortMaster/PortMaster.sh"

# Tell ES to refresh its game list — the user can also reload manually.
touch "$PORTS_DIR/.gamelist-needs-refresh"

cat <<EOF

PortMaster installed at $PORTS_DIR/PortMaster

Next: restart EmulationStation (Main Menu → Quit → Restart EmulationStation)
to see the Ports system, then browse PortMaster's catalog from inside the
PortMaster app.
EOF

# Pause so the user sees the output before ES reclaims the screen.
echo
echo "Press any key to return to EmulationStation..."
read -r -n 1 _ || true

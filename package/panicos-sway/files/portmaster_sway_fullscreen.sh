#!/bin/bash
# Vendored from ROCKNIX (apps/portmaster/scripts/portmaster_sway_fullscreen.sh).
# Called by PortMaster's mod_ROCKNIX.txt pm_platform_helper to grab any
# port window sway has just mapped and stretch it to the panel. Stripped
# the dual-display branch — H700 / Allwinner devices we target are all
# single-panel.

. /etc/profile

if echo "${UI_SERVICE}" | grep -q "sway"; then
    sway_fullscreen "${1}" &
fi

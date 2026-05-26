#!/bin/sh
# panicos-output-init: when a connected DRM output has no EDID (typical of
# cheap HDMI-to-VGA adapters), Wayfire defaults to whichever DMT mode the
# kernel listed first — often 85Hz or 75Hz at 1024x768/800x600. Real VGA
# monitors expect 60Hz. This script picks a sane 60Hz mode for EDID-less
# outputs only, leaving real EDID-bearing displays untouched so a real
# HDMI monitor keeps its preferred 1080p60 (or higher) mode.
#
# Runs on session start via Wayfire's autostart. Idempotent — safe to
# re-run on any output hotplug event.

set -u

# Candidate modes in descending order of resolution. wlr-randr will fail
# fast if a mode is unsupported on the connector; we try the next one.
CANDIDATES="1024x768@60 800x600@60 640x480@60"

# wlr-randr needs an active Wayland session. If WAYLAND_DISPLAY is unset
# (e.g. the script was triggered outside a Wayland context), exit cleanly.
[ -n "${WAYLAND_DISPLAY:-}" ] || { echo "no WAYLAND_DISPLAY, skipping"; exit 0; }
command -v wlr-randr >/dev/null || { echo "wlr-randr not installed"; exit 0; }

# Walk every connected DRM connector. Skip DSI (internal panel) and any
# output that has a non-zero EDID (real monitor).
for sysfs in /sys/class/drm/card*-*; do
    [ -d "$sysfs" ] || continue
    name=$(basename "$sysfs" | sed -E "s/^card[0-9]+-//")
    [ "$name" = "DSI-1" ] && continue       # internal panel
    status=$(cat "$sysfs/status" 2>/dev/null || echo unknown)
    [ "$status" = "connected" ] || continue
    edid_size=$(stat -c %s "$sysfs/edid" 2>/dev/null || echo 0)
    if [ "$edid_size" -gt 0 ]; then
        echo "$name has EDID ($edid_size bytes); leaving compositor default"
        continue
    fi
    # No EDID. Try our candidate modes in order until one applies.
    for mode in $CANDIDATES; do
        if wlr-randr --output "$name" --mode "$mode" 2>/dev/null; then
            echo "$name: set $mode (no EDID)"
            break
        fi
    done
done

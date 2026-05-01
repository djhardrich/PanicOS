#!/bin/sh
# Pick a splash image matching the panel's native resolution and paint
# it to the framebuffer via fbv. Holds until systemd kills us
# (Conflicts=getty@tty1.service / panicos-pht.service stops the unit
# when the real UI starts).

set -u

SPLASH_DIR=/opt/panicos-splash
DEFAULT_SPLASH="$SPLASH_DIR/splash-640x480.png"

# Read the active mode from the first DRM connector that's enabled.
# /sys/class/drm/card0-<connector>/modes lists "WIDTHxHEIGHT" lines —
# the first line is the preferred mode. Glob the connectors so this
# works regardless of whether it's HDMI-A-1, DSI-1, etc.
RES=""
for modes in /sys/class/drm/card*-*/modes; do
    [ -r "$modes" ] || continue
    # Skip empty modes files (disconnected outputs).
    head -n1 "$modes" 2>/dev/null | grep -qE '^[0-9]+x[0-9]+' || continue
    RES=$(head -n1 "$modes" | awk -F'i| ' '{print $1}')
    break
done

if [ -n "$RES" ] && [ -f "$SPLASH_DIR/splash-${RES}.png" ]; then
    SPLASH="$SPLASH_DIR/splash-${RES}.png"
else
    # No exact match; fall back to default. fbv will scale-to-fit
    # via its --enlarge option below.
    SPLASH="$DEFAULT_SPLASH"
fi

# fbv flags:
#   --noinfo     — no per-image label overlay
#   --hide-cursor — keep the cursor off (we're a splash, not a viewer)
#   --enlarge    — scale up if image < framebuffer
#   --colour 24  — explicit colour depth
# fbv with no --delay waits for keyboard input (which never comes inside
# a systemd unit), which is exactly what we want — hold until SIGTERM.
exec fbv --noinfo --hide-cursor --enlarge --colour 24 "$SPLASH"

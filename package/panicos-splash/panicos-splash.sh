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

# fbv flags (per its actual usage line — short single-letter only):
#   -i  no per-image label / info bar
#   -e  enlarge to fit
#   -f  fullscreen
#   -d 1  exit after 1 second by default; with --once-style behaviour
#         we want the image to stay painted on the framebuffer after
#         we exit, which it does — fbv just draws once and quits.
#   --hide-cursor / --colour are NOT real flags (last build's diag
#   showed `unrecognized option`); use setterm beforehand to disable
#   the blinking console cursor.

# Disable blinking text cursor on tty1 BEFORE drawing, so it doesn't
# show on top of the splash image. Writes the ANSI sequence directly to
# /dev/tty1 because setterm wants a real TTY.
printf '\033[?25l\033[?17;0;0c' > /dev/tty1 2>/dev/null || true

exec fbv -i -e -f "$SPLASH"

#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Rescan-HDMI-Audio.sh — ES Tools entry for re-detecting an HDMI sink's
# audio path after the user has enabled audio on the sink.
#
# Some HDMI sinks (notably Xreal Air XR glasses) default to video-only and
# only advertise audio in EDID after a physical user action — on the
# Xreal Airs, holding the audio toggle button on the right temple. By
# the time the user does that, the kernel has long since cached the
# no-audio EDID and PipeWire's default sink is the handheld speakers.
#
# Running this from the Tools menu after enabling audio on the sink
# forces a fresh EDID read (so ELD picks up the new audio capabilities)
# and re-runs hdmi_sense to flip the default sink to HDMI.

set -e
[ -f /etc/profile ] && . /etc/profile

echo "=== Rescan HDMI audio ==="
echo

# 1. Force DRM connector off → detect so dw-hdmi re-reads EDID.
echo ">>> forcing HDMI connector re-detect"
for status in /sys/class/drm/card*/card*-HDMI-A-[0-9]/status; do
	[ -w "$status" ] || continue
	conn=$(basename "$(dirname "$status")")
	echo "  $conn: was $(cat "$status")"
	echo off > "$status" 2>/dev/null || true
	sleep 0.3
	echo detect > "$status" 2>/dev/null || true
done
sleep 1
for status in /sys/class/drm/card*/card*-HDMI-A-[0-9]/status; do
	conn=$(basename "$(dirname "$status")")
	echo "  $conn: now $(cat "$status")"
done
echo

# 2. Run hdmi_sense to write /run/hdmi-status.last and pick the right
#    default sink. The hdmi-hotplug.path watcher fires
#    handle-hdmi-hotplug from there.
echo ">>> running hdmi_sense"
/usr/bin/hdmi_sense

# 3. Migrate any active PipeWire sink-input(s) to HDMI directly.
echo ">>> migrating active streams to HDMI sink"
HDMI_SINK=$(pactl list short sinks 2>/dev/null \
	| awk 'tolower($0) ~ /hdmi|ahub1_mach/ {print $2; exit}')
if [ -n "$HDMI_SINK" ]; then
	echo "  HDMI sink: $HDMI_SINK"
	pactl set-default-sink "$HDMI_SINK" >/dev/null 2>&1 || true
	for sid in $(pactl list short sink-inputs 2>/dev/null | awk '{print $1}'); do
		echo "  → moving sink-input $sid"
		pactl move-sink-input "$sid" "$HDMI_SINK" >/dev/null 2>&1 || true
	done
else
	echo "  no HDMI sink registered — is the cable connected and the sink"
	echo "  advertising audio? (Xreal Air: hold the volume button on the"
	echo "  right temple until you see the audio-mode indicator, then re-run)"
fi
echo
echo "default sink: $(pactl get-default-sink 2>/dev/null || echo '(unknown)')"
echo
echo "done."
echo

# Pause so the user sees the output before ES reclaims the screen.
echo "Press any key to return to EmulationStation..."
read -r -n 1 _ || true

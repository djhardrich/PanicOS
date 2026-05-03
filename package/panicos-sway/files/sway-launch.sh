#!/bin/bash
# panicos-sway-launch — start sway with the PanicOS kiosk config.
#
# Invoked by panicos-sway.service. Type=simple, runs in foreground until
# sway exits. systemd will restart on crash.
#
# Symlinks sway's IPC socket to a stable path (/run/panicos-sway/ipc.sock)
# after sway is up, so other systemd units (panicos-es.service, ports
# spawned through ES) can refer to SWAYSOCK at a known location set in
# their Environment= rather than chasing sway's per-PID
# sway-ipc.<uid>.<pid>.sock filename.

set -e

export XDG_RUNTIME_DIR=/var/run/0-runtime-dir
export WLR_BACKENDS=drm,libinput
# WLR_LIBINPUT_NO_DEVICES — start sway even when libinput hasn't enumerated
# any input devices yet (gamepad/keyboard may come up later via udev).
export WLR_LIBINPUT_NO_DEVICES=1

# Point wlroots at the DRM card that has display connectors (DSI/HDMI/DP).
# On H700 there are two cards: card0=panfrost (GPU, no connectors) and
# card1=sun4i-drm (display controller). Without this, wlroots may probe
# card0 first, find no outputs, and render to nothing (black screen).
# Same approach as ROCKNIX's 111-sway-init.
_card_no=$(ls /sys/class/drm/ 2>/dev/null | grep -E "card[0-9]-(DP|HDMI|DSI)" | head -n 1 | cut -c5)
if [ -n "$_card_no" ]; then
    export WLR_DRM_DEVICES=/dev/dri/card${_card_no}
fi
unset _card_no

# Stable path where panicos-es.service expects to find sway's IPC socket.
# Matches `Environment=SWAYSOCK=/run/panicos-sway/ipc.sock` in that unit.
STABLE_SOCK=/run/panicos-sway/ipc.sock
mkdir -p /run/panicos-sway
rm -f "$STABLE_SOCK"

# Background watcher: poll for sway's socket and symlink it. Runs until
# the symlink is in place; then exits. Sway itself replaces this script
# (via exec) once it starts, so the watcher must be a separate child.
(
    for _ in $(seq 1 50); do
        sock=$(ls "$XDG_RUNTIME_DIR"/sway-ipc.*.sock 2>/dev/null | head -1)
        if [ -n "$sock" ] && [ -S "$sock" ]; then
            ln -sf "$sock" "$STABLE_SOCK"
            exit 0
        fi
        sleep 0.2
    done
    echo "panicos-sway-launch: timed out waiting for sway IPC socket" >&2
) &

exec /usr/bin/sway --config /etc/sway/panicos-kiosk.conf "$@"

#!/bin/bash
# panicos-sway-launch — start sway with the PanicOS kiosk config.
# Invoked by panicos-sway.service (Type=simple, runs until sway exits).

set -e

export XDG_RUNTIME_DIR=/var/run/0-runtime-dir
# Pin the Wayland display socket name so sway creates wayland-1 and ES
# (Environment=WAYLAND_DISPLAY=wayland-1) connects to the right socket.
export WAYLAND_DISPLAY=wayland-1
export WLR_BACKENDS=drm,libinput
export WLR_LIBINPUT_NO_DEVICES=1
# sway-100.01-static-ipc-socket.patch makes the socket path predictable.
export SWAYSOCK="${XDG_RUNTIME_DIR}/sway-ipc.0.sock"

# Point wlroots at the DRM card with display connectors (DSI/HDMI/DP).
# On H700: card0=panfrost (GPU, no connectors), card1=sun4i-drm (display).
# Same approach as ROCKNIX's 111-sway-init.
_card_no=$(ls /sys/class/drm/ 2>/dev/null | grep -E "card[0-9]-(DP|HDMI|DSI)" | head -n 1 | cut -c5)
if [ -n "$_card_no" ]; then
    export WLR_DRM_DEVICES=/dev/dri/card${_card_no}
fi
unset _card_no

exec /usr/bin/sway --config /etc/sway/panicos-kiosk.conf "$@"

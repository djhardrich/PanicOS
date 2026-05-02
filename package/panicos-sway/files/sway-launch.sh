#!/bin/sh
# panicos-sway-launch — start sway with the PanicOS kiosk config.
#
# Invoked by panicos-sway.service. Type=simple, runs in foreground until
# sway exits. systemd will restart on crash.

set -e

export XDG_RUNTIME_DIR=/var/run/0-runtime-dir
export WLR_BACKENDS=drm,libinput
# WLR_LIBINPUT_NO_DEVICES — start sway even when libinput hasn't enumerated
# any input devices yet (gamepad/keyboard may come up later via udev).
export WLR_LIBINPUT_NO_DEVICES=1

exec /usr/bin/sway --config /etc/sway/panicos-kiosk.conf "$@"

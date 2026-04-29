#!/usr/bin/env bash
# Fail loudly if a SoC's kernel config fragment is missing options PanicOS
# requires for the on-device console (fbcon over DRM panel) and USB keyboard.
# Catches regressions from re-syncing ROCKNIX (or a future SoC import that
# starts from a smaller config).
#
# Usage: audit-kernel-config.sh <path-to-linux.config.fragment>
# Soft-skips if the file doesn't exist (some SoC trees may not have one).

set -euo pipefail

CFG="${1:-}"
[ -n "$CFG" ] || { echo "usage: $0 <linux.config.fragment>" >&2; exit 2; }

if [ ! -f "$CFG" ]; then
    echo ">>> audit-kernel-config: $CFG not present, skipping"
    exit 0
fi

REQUIRED=(
    CONFIG_FB
    CONFIG_FRAMEBUFFER_CONSOLE
    CONFIG_DRM_FBDEV_EMULATION
    CONFIG_USB_HID
    CONFIG_HID_GENERIC
)

missing=()
for opt in "${REQUIRED[@]}"; do
    if ! grep -qE "^${opt}=y$" "$CFG"; then
        missing+=("$opt")
    fi
done

if [ "${#missing[@]}" -gt 0 ]; then
    echo "ERROR: kernel config fragment $CFG is missing required options:" >&2
    for opt in "${missing[@]}"; do echo "  $opt" >&2; done
    echo "These are needed for on-device tty1 (fbcon over DRM panel) and USB keyboard." >&2
    exit 1
fi

echo ">>> audit-kernel-config: $CFG OK"

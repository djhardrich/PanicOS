#!/usr/bin/env bash
# PanicOS interactive build wizard.
# Run as ./panicos or `make tui`. Walks device + flavor + DRAM + kernel
# choices via whiptail and produces the right make invocation.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v whiptail >/dev/null 2>&1; then
    echo "whiptail not found. Run inside the build container: make shell" >&2
    exit 1
fi

# ---- Device selection ----
# Pull list from list-devices, group by vendor.
DEVICES=()
while IFS= read -r line; do
    DEVICES+=("$line" "")
done < <(make -s list-devices)

device=$(whiptail --title "PanicOS — Device" \
    --menu "Select your device" 20 70 12 \
    "${DEVICES[@]}" 3>&1 1>&2 2>&3) || exit 0

# Strip vendor prefix for the make target (rg35xx-pro from anbernic/rg35xx-pro)
device_name="${device##*/}"

# ---- Flavor selection ----
flavor=$(whiptail --title "PanicOS — Flavor" \
    --menu "Userspace flavor" 15 60 5 \
    minimal "Minimal CLI (BusyBox + systemd)" \
    desktop "Desktop with Wayland (Plan 06; not yet built)" \
    3>&1 1>&2 2>&3) || exit 0

if [ "$flavor" = "desktop" ]; then
    whiptail --title "Coming soon" --msgbox \
        "Desktop flavor isn't built yet (Plan 06). Falling back to minimal." 10 60
    flavor="minimal"
fi

# ---- Kernel-flavor selection (only if device's SoC supports more than one) ----
# The harness-smoke pseudo-device has no SoC; skip the kernel question for it.
KERNEL=""
if [ "$device_name" != "harness-smoke" ]; then
    # Check which kernel flavors have content for this device's SoC.
    # SoC name is derived from board/<vendor>/<device>/Config.in just like the
    # Makefile does it; cheaper to just probe the soc/ tree.
    SOC=$(awk '/select PANICOS_SOC_/ { sub(/^[[:space:]]+/,""); sub(/select PANICOS_SOC_/,""); gsub(/_/,"-"); print tolower($0); exit }' \
        "$ROOT/board/$device/Config.in")
    HAS_MAINLINE=0; HAS_VENDOR=0
    [ -d "$ROOT/soc/$SOC/mainline/linux" ] && HAS_MAINLINE=1
    [ -d "$ROOT/soc/$SOC/vendor/linux" ] && [ -f "$ROOT/soc/$SOC/vendor/linux/source.mk" ] && HAS_VENDOR=1

    if [ "$HAS_MAINLINE$HAS_VENDOR" = "11" ]; then
        kernel=$(whiptail --title "PanicOS — Kernel flavor" \
            --menu "Kernel" 13 60 3 \
            mainline "Linux mainline (kernel.org + ROCKNIX patches)" \
            vendor "Vendor BSP (4.9 or similar)" \
            3>&1 1>&2 2>&3) || exit 0
        KERNEL="$kernel"
    elif [ "$HAS_VENDOR" = "1" ]; then
        KERNEL="vendor"
    fi
    # else: no flavor-specific content, leave KERNEL empty (Makefile defaults)
fi

# ---- Confirmation ----
CMD="make $device_name FLAVOR=$flavor"
[ -n "$KERNEL" ] && CMD="$CMD KERNEL=$KERNEL"

if whiptail --title "PanicOS — Confirm" --yesno \
    "Build command:\n\n  $CMD\n\nProceed?" 12 60; then
    clear
    echo ">>> Running: $CMD"
    eval "$CMD"
else
    echo "Cancelled. To build manually later:"
    echo "  $CMD"
fi

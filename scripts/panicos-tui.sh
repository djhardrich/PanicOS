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

# ---- VBE submenu helpers ----

vbe_run() {
    # Run vbe.sh with given args, capture output, show in textbox.
    local subcmd="$1"; shift
    local tmpout
    tmpout=$(mktemp /tmp/vbe-out.XXXXXX)
    if bash "$ROOT/scripts/vbe.sh" "$subcmd" "$@" >"$tmpout" 2>&1; then
        whiptail --title "VBE — $subcmd — output" \
            --textbox "$tmpout" 22 80 || true
    else
        # Show error output even on failure
        whiptail --title "VBE — $subcmd — ERROR" \
            --textbox "$tmpout" 22 80 || true
    fi
    rm -f "$tmpout"
}

vbe_inputbox() {
    local title="$1" prompt="$2" default="$3"
    whiptail --title "$title" --inputbox "$prompt" 10 70 "$default" \
        3>&1 1>&2 2>&3
}

vbe_submenu() {
    while true; do
        local choice
        choice=$(whiptail --title "PanicOS — Vendor Blob Extractor" \
            --menu "Choose an operation:" 18 72 7 \
            extract    "Extract vendor blobs from a device image" \
            inject     "Inject vendor blobs into a PanicOS squashfs" \
            build-image "Assemble a flashable image from archive + squashfs" \
            port       "Full port (extract + inject + build-image, one-shot)" \
            identify   "Identify / diagnose a device image" \
            back       "Return to main menu" \
            3>&1 1>&2 2>&3) || return 0

        case "$choice" in
            extract)
                local vendor_img
                vendor_img=$(vbe_inputbox "VBE — Extract" \
                    "Path to vendor device image (.img / .img.gz / squashfs …):" \
                    "/work/vendor/rg353p-stock.img") || continue
                [ -z "$vendor_img" ] && continue

                local out_archive
                out_archive=$(vbe_inputbox "VBE — Extract" \
                    "Output archive path (.tar.gz):" \
                    "/work/output/vbe/vendor-blobs.tar.gz") || continue
                [ -z "$out_archive" ] && continue

                vbe_run extract "$vendor_img" --out "$out_archive"
                ;;

            inject)
                local archive
                archive=$(vbe_inputbox "VBE — Inject" \
                    "Vendor blob archive (.tar.gz):" \
                    "/work/output/vbe/vendor-blobs.tar.gz") || continue
                [ -z "$archive" ] && continue

                local squashfs
                squashfs=$(vbe_inputbox "VBE — Inject" \
                    "Input PanicOS squashfs:" \
                    "/work/output/rg353p-minimal-mainline/images/rootfs.squashfs") || continue
                [ -z "$squashfs" ] && continue

                local out_squashfs
                out_squashfs=$(vbe_inputbox "VBE — Inject" \
                    "Output squashfs path:" \
                    "/work/output/vbe/rootfs-injected.squashfs") || continue
                [ -z "$out_squashfs" ] && continue

                vbe_run inject "$archive" "$squashfs" --out "$out_squashfs"
                ;;

            build-image)
                local archive
                archive=$(vbe_inputbox "VBE — Build Image" \
                    "Vendor blob archive (.tar.gz):" \
                    "/work/output/vbe/vendor-blobs.tar.gz") || continue
                [ -z "$archive" ] && continue

                local squashfs
                squashfs=$(vbe_inputbox "VBE — Build Image" \
                    "Input squashfs:" \
                    "/work/output/vbe/rootfs-injected.squashfs") || continue
                [ -z "$squashfs" ] && continue

                local out_img
                out_img=$(vbe_inputbox "VBE — Build Image" \
                    "Output flashable image (.img.gz):" \
                    "/work/output/vbe/panicos-ported.img.gz") || continue
                [ -z "$out_img" ] && continue

                local sys_size
                sys_size=$(vbe_inputbox "VBE — Build Image" \
                    "System partition size (e.g. 8G):" \
                    "8G") || continue
                [ -z "$sys_size" ] && sys_size="8G"

                local ovl_size
                ovl_size=$(vbe_inputbox "VBE — Build Image" \
                    "Overlay partition size (e.g. 64M):" \
                    "64M") || continue
                [ -z "$ovl_size" ] && ovl_size="64M"

                vbe_run build-image "$archive" "$squashfs" \
                    --out "$out_img" \
                    --system-size "$sys_size" \
                    --overlay-size "$ovl_size"
                ;;

            port)
                local vendor_img
                vendor_img=$(vbe_inputbox "VBE — Port" \
                    "Path to vendor device image:" \
                    "/work/vendor/rg353p-stock.img") || continue
                [ -z "$vendor_img" ] && continue

                local squashfs
                squashfs=$(vbe_inputbox "VBE — Port" \
                    "PanicOS base squashfs:" \
                    "/work/output/rg353p-minimal-mainline/images/rootfs.squashfs") || continue
                [ -z "$squashfs" ] && continue

                local out_img
                out_img=$(vbe_inputbox "VBE — Port" \
                    "Output flashable image (.img.gz):" \
                    "/work/output/vbe/panicos-ported.img.gz") || continue
                [ -z "$out_img" ] && continue

                vbe_run port "$vendor_img" "$squashfs" --out "$out_img"
                ;;

            identify)
                local img
                img=$(vbe_inputbox "VBE — Identify" \
                    "Path to image/squashfs to identify:" \
                    "/work/output/rg353p-minimal-mainline/images/rootfs.squashfs") || continue
                [ -z "$img" ] && continue

                vbe_run identify "$img"
                ;;

            back|"")
                return 0
                ;;
        esac
    done
}

# ---- Main menu ----

main_choice=$(whiptail --title "PanicOS" \
    --menu "What do you want to do?" 14 70 3 \
    build "Build a configured device image" \
    vbe   "Vendor Blob Extractor (port to a new device)" \
    3>&1 1>&2 2>&3) || exit 0

if [ "$main_choice" = "vbe" ]; then
    vbe_submenu
    exit 0
fi

# ---- Build flow (existing) ----

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

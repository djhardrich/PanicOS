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
    --menu "What do you want to do?" 16 70 5 \
    build   "Build a configured device image (clean)" \
    rebuild "Incremental rebuild of an existing build (fast)" \
    vbe     "Vendor Blob Extractor (port to a new device)" \
    3>&1 1>&2 2>&3) || exit 0

if [ "$main_choice" = "vbe" ]; then
    vbe_submenu
    exit 0
fi

# ---- Rebuild flow (incremental) ----

if [ "$main_choice" = "rebuild" ]; then
    # List existing per-device-flavor build dirs.
    BUILD_DIRS=()
    while IFS= read -r d; do
        [ -d "$d/build" ] || continue
        name="$(basename "$d")"
        BUILD_DIRS+=("$name" "")
    done < <(find "$ROOT/output" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

    if [ "${#BUILD_DIRS[@]}" -eq 0 ]; then
        whiptail --title "Nothing to rebuild" --msgbox \
            "No existing builds in output/. Run a clean build first via the main menu." 10 60
        exit 0
    fi

    target=$(whiptail --title "Rebuild — pick a build" \
        --menu "Which existing build?" 20 70 12 \
        "${BUILD_DIRS[@]}" 3>&1 1>&2 2>&3) || exit 0

    # Decompose name = <device>-<flavor>[-<kernel>]. The kernel suffix is
    # optional (only present when --kernel was passed). We grep the source
    # tree to enumerate device + flavor candidates and pick the longest
    # match for each so flavor names with dashes still parse cleanly.
    REBUILD_DEVICE=""
    REBUILD_FLAVOR=""
    REBUILD_KERNEL=""
    for dev_candidate in $(make -s list-devices | xargs -n1 basename | sort -r); do
        case "$target" in
            "$dev_candidate"-*) REBUILD_DEVICE="$dev_candidate"; break ;;
        esac
    done
    if [ -n "$REBUILD_DEVICE" ]; then
        rest="${target#${REBUILD_DEVICE}-}"
        # rest is now <flavor>[-<kernel>]; flavor is in flavors/ dir
        for f in "$ROOT"/flavors/*/; do
            fn="$(basename "$f")"
            case "$rest" in
                "$fn") REBUILD_FLAVOR="$fn"; break ;;
                "$fn"-*) REBUILD_FLAVOR="$fn"; REBUILD_KERNEL="${rest#${fn}-}"; break ;;
            esac
        done
    fi

    if [ -z "$REBUILD_DEVICE" ] || [ -z "$REBUILD_FLAVOR" ]; then
        whiptail --title "Rebuild — parse error" --msgbox \
            "Couldn't parse '$target' into device/flavor[/kernel]. Run a fresh build instead." 10 70
        exit 1
    fi

    rebuild_what=$(whiptail --title "Rebuild — what to redo" \
        --menu "What needs to rebuild?" 18 70 6 \
        sync     "Re-run make (picks up package additions/removals)" \
        pkg      "Force-rebuild ONE package + image (PKG=...)" \
        image    "Rebuild squashfs + image only (post-image edits)" \
        3>&1 1>&2 2>&3) || exit 0

    case "$rebuild_what" in
        sync)
            CMD="make $REBUILD_DEVICE FLAVOR=$REBUILD_FLAVOR"
            [ -n "$REBUILD_KERNEL" ] && CMD="$CMD KERNEL=$REBUILD_KERNEL"
            ;;
        pkg)
            # Suggest packages from the existing build dir so the user picks
            # something that actually exists.
            PKG_SUGGESTIONS=()
            while IFS= read -r p; do
                base="$(basename "$p")"
                # Strip trailing -VERSION
                name="${base%-[0-9]*}"
                PKG_SUGGESTIONS+=("$name" "")
            done < <(find "$ROOT/output/$target/build" -mindepth 1 -maxdepth 1 -type d \
                     -not -name 'buildroot-fs' -not -name 'staging' 2>/dev/null \
                     | sort -u | head -40)

            if [ "${#PKG_SUGGESTIONS[@]}" -eq 0 ]; then
                pkg_name=$(vbe_inputbox "Rebuild — package" \
                    "Package name (no version):" "panicos-pht") || exit 0
            else
                pkg_name=$(whiptail --title "Rebuild — pick a package" \
                    --menu "Which package?" 22 70 14 \
                    "${PKG_SUGGESTIONS[@]}" 3>&1 1>&2 2>&3) || exit 0
            fi
            [ -z "$pkg_name" ] && exit 0

            CMD="make pkg-rebuild PKG=$pkg_name DEVICE=$REBUILD_DEVICE FLAVOR=$REBUILD_FLAVOR"
            [ -n "$REBUILD_KERNEL" ] && CMD="$CMD KERNEL=$REBUILD_KERNEL"
            ;;
        image)
            CMD="make image-rebuild DEVICE=$REBUILD_DEVICE FLAVOR=$REBUILD_FLAVOR"
            [ -n "$REBUILD_KERNEL" ] && CMD="$CMD KERNEL=$REBUILD_KERNEL"
            ;;
        *)
            exit 0
            ;;
    esac

    if whiptail --title "Rebuild — Confirm" --yesno \
        "Rebuild command:\n\n  $CMD\n\nProceed?" 12 70; then
        clear
        echo ">>> Running: $CMD"
        eval "$CMD"
    else
        echo "Cancelled. To rebuild manually:"
        echo "  $CMD"
    fi
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
# Enumerate flavors/ dynamically so newly-added ones show up without
# editing this script. Each flavor gets its one-line description from the
# `bool "..."` line in its Config.in.
FLAVOR_ENTRIES=()
for f in "$ROOT"/flavors/*/Config.in; do
    [ -f "$f" ] || continue
    name="$(basename "$(dirname "$f")")"
    desc=$(awk -F'"' '/bool[[:space:]]*"/{print $2; exit}' "$f")
    FLAVOR_ENTRIES+=("$name" "${desc:-flavor: $name}")
done

flavor=$(whiptail --title "PanicOS — Flavor" \
    --menu "Userspace flavor" 18 78 10 \
    "${FLAVOR_ENTRIES[@]}" 3>&1 1>&2 2>&3) || exit 0

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

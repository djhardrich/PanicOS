#!/bin/bash
# PanicOS-SquashFS-Install.sh — toggle the Debian desktop squashfs on/off
# the boot partition. Presence on /boot is all that's needed — the PanicOS
# mbselect menu picks it up automatically.

SQUASHFS_NAME="panicos-debian-desktop.squashfs"
BOOT="/boot"
SQUASHFS_PATH="$BOOT/$SQUASHFS_NAME"
STAGING="/storage/squashfs/$SQUASHFS_NAME"
BAR_WIDTH=36

boot_rw() { mount -o remount,rw  "$BOOT"; }
boot_ro() { mount -o remount,ro  "$BOOT"; }

device_ip() {
    ip -4 addr show scope global 2>/dev/null \
        | awk '/inet /{print $2}' | cut -d/ -f1 | head -1
}

# Portable file-size-in-bytes. busybox on this system has CONFIG_STAT=n
# so `stat` is not available. `ls -la` field 5 is the byte count for
# regular files; awk trims whitespace.
file_bytes() {
    ls -la "$1" 2>/dev/null | awk 'NR==1 {print $5+0}'
}

# Draw a simple progress bar.
# Usage: draw_bar <pct 0-100> <done_mb> <total_mb>
draw_bar() {
    local pct=$1 done_mb=$2 total_mb=$3
    local filled=$(( pct * BAR_WIDTH / 100 ))
    local empty_w=$(( BAR_WIDTH - filled ))
    local full_str="===================================="   # BAR_WIDTH chars
    local empty_str="                                    "  # BAR_WIDTH chars
    local bar="${full_str:0:$filled}${empty_str:0:$empty_w}"
    printf "\r  [%s] %3d%%  %d / %d MB  " "$bar" "$pct" "$done_mb" "$total_mb" >&2
}

# Copy $1 → $2 via a .tmp staging name, printing a live progress bar.
copy_with_progress() {
    local src="$1" dst="$2"
    local dst_tmp="${dst}.panicos-tmp"
    local src_size src_mb

    src_size=$(file_bytes "$src")
    src_mb=$(( src_size / 1048576 ))

    rm -f "$dst_tmp"
    cp "$src" "$dst_tmp" &
    local CP_PID=$!

    printf "\n" >&2
    while kill -0 "$CP_PID" 2>/dev/null; do
        local done_bytes pct done_mb
        done_bytes=$(file_bytes "$dst_tmp")
        pct=$(( src_size > 0 ? done_bytes * 100 / src_size : 0 ))
        done_mb=$(( done_bytes / 1048576 ))
        draw_bar "$pct" "$done_mb" "$src_mb"
        sleep 1
    done
    wait "$CP_PID"
    local rc=$?

    if [ $rc -ne 0 ]; then
        printf "\n  ERROR: copy failed (disk full?)\n" >&2
        rm -f "$dst_tmp"
        return 1
    fi

    draw_bar 100 "$src_mb" "$src_mb"
    printf "\n" >&2

    mv "$dst_tmp" "$dst"
}

# ── Main ──────────────────────────────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║      PanicOS Desktop (Debian Sid)        ║"
echo "╚══════════════════════════════════════════╝"
echo ""

if [ -f "$SQUASHFS_PATH" ]; then
    echo "  Status : INSTALLED"
    echo "  Action : removing from boot partition..."
    boot_rw
    rm -f "$SQUASHFS_PATH"
    boot_ro
    echo "  Done. Debian Desktop removed from boot menu."

elif [ -f "$STAGING" ]; then
    staging_mb=$(( $(file_bytes "$STAGING") / 1048576 ))
    echo "  Status  : NOT INSTALLED"
    echo "  Source  : $STAGING  (${staging_mb} MB)"
    echo "  Target  : $SQUASHFS_PATH"
    echo "  Copying — this may take several minutes..."
    boot_rw
    if copy_with_progress "$STAGING" "$SQUASHFS_PATH"; then
        rm -f "$STAGING"
        boot_ro
        echo "  Done. Reboot to see Debian Desktop in the boot menu."
    else
        boot_ro
        echo "  Install failed. Check available space on /boot."
    fi

else
    IP=$(device_ip)
    echo "  Status: NOT INSTALLED"
    echo ""
    echo "  Build the squashfs on your PC:"
    echo "    make debian-desktop"
    echo ""
    echo "  Copy it to the device:"
    printf "    scp output/debian-desktop/%s \\\n" "$SQUASHFS_NAME"
    printf "        root@%s:/storage/squashfs/\n" "${IP:-<device-ip>}"
    echo ""
    echo "  Then run this tool again to install it."
fi

echo ""
read -r -t 10 -p "  Press Enter to exit..." 2>/dev/null || true
echo ""

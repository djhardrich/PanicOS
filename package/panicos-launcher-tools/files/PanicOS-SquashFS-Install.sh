#!/bin/bash
# PanicOS-Desktop.sh — toggle the Debian desktop squashfs on/off the boot
# partition. Presence on /boot is all that's needed — the PanicOS mbselect
# menu picks it up automatically. No active.cfg editing required.

SQUASHFS_NAME="panicos-debian-desktop.squashfs"
BOOT="/boot"
SQUASHFS_PATH="$BOOT/$SQUASHFS_NAME"
STAGING="/storage/squashfs/$SQUASHFS_NAME"

boot_rw() { mount -o remount,rw  "$BOOT"; }
boot_ro() { mount -o remount,ro  "$BOOT"; }

device_ip() {
    ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1
}

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║      PanicOS Desktop (Debian Sid)        ║"
echo "╚══════════════════════════════════════════╝"
echo ""

if [ -f "$SQUASHFS_PATH" ]; then
    # Toggle OFF — remove from boot partition
    echo "  Status: INSTALLED — removing from boot partition..."
    boot_rw
    rm -f "$SQUASHFS_PATH"
    boot_ro
    echo "  Done. Debian Desktop will no longer appear in the boot menu."
else
    # Toggle ON — install from /tmp if present, otherwise show instructions
    if [ -f "$STAGING" ]; then
        echo "  Found $STAGING — installing to /boot..."
        boot_rw
        mv "$STAGING" "$SQUASHFS_PATH"
        boot_ro
        echo "  Done. Reboot to see Debian Desktop in the boot menu."
    else
        IP=$(device_ip)
        echo "  Status: NOT INSTALLED"
        echo ""
        echo "  Build the squashfs on your PC:"
        echo "    sudo bash scripts/build-debian-desktop.sh"
        echo ""
        echo "  Copy it to the device:"
        echo "    scp output/debian-desktop/$SQUASHFS_NAME \\"
        echo "        root@${IP:-<device-ip>}:/storage/squashfs/"
        echo ""
        echo "  Then run this tool again to install it."
    fi
fi

echo ""
read -r -t 10 -p "  Press Enter to exit..." 2>/dev/null || true

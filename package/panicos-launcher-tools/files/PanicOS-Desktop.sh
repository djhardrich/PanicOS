#!/bin/bash
# PanicOS-Desktop.sh — toggle the Debian desktop multiboot flavor.
#
# Runs as a PortMaster-style tool (terminal launched by ES).
# On first run: checks if the squashfs is on /boot; if not, prints
# instructions for the user to scp it over, then run again.
# On subsequent runs: toggles the squashfs between present and removed,
# and updates panicos-active.cfg accordingly.

SQUASHFS_NAME="panicos-debian-desktop.squashfs"
BOOT="/boot"
ACTIVE_CFG="$BOOT/panicos-active.cfg"
SQUASHFS_PATH="$BOOT/$SQUASHFS_NAME"

# Read current IMAGE from active.cfg
current_image() { grep '^IMAGE=' "$ACTIVE_CFG" 2>/dev/null | cut -d= -f2-; }

boot_rw()  { mount -o remount,rw  "$BOOT" 2>/dev/null; }
boot_ro()  { mount -o remount,ro  "$BOOT" 2>/dev/null; }

# Detect device IP for user-facing instructions
device_ip() {
    ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1
}

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║      PanicOS Desktop (Debian Sid)        ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ── Case 1: squashfs not on /boot ─────────────────────────────────────────────
if [ ! -f "$SQUASHFS_PATH" ]; then
    IP=$(device_ip)
    echo "  Debian desktop squashfs not found on boot partition."
    echo ""
    echo "  Build it on your PC:"
    echo "    sudo bash scripts/build-debian-desktop.sh"
    echo ""
    echo "  Then copy it to the device:"
    if [ -n "$IP" ]; then
        echo "    scp output/debian-desktop/$SQUASHFS_NAME \\"
        echo "        root@$IP:/tmp/"
    else
        echo "    scp output/debian-desktop/$SQUASHFS_NAME \\"
        echo "        root@<device-ip>:/tmp/"
    fi
    echo ""
    echo "  Once copied, run this tool again to install it."
    echo ""

    # If user already scp'd to /tmp, offer to move it now.
    if [ -f "/tmp/$SQUASHFS_NAME" ]; then
        echo "  Found /tmp/$SQUASHFS_NAME — installing now..."
        boot_rw
        mv "/tmp/$SQUASHFS_NAME" "$SQUASHFS_PATH"
        boot_ro
        echo "  Installed. Run this tool again to activate."
    fi

    echo ""
    read -r -t 10 -p "  Press Enter to exit..." 2>/dev/null || true
    exit 0
fi

# ── Case 2: squashfs present — toggle active image ────────────────────────────
CURRENT=$(current_image)

if [ "$CURRENT" = "$SQUASHFS_NAME" ]; then
    # Currently booting Debian — switch back to PanicOS launcher
    PANICOS_SQ=$(ls "$BOOT"/panicos-rg35xx-*.squashfs 2>/dev/null | head -1)
    PANICOS_SQ="${PANICOS_SQ##*/}"
    echo "  Status: Debian Desktop is ACTIVE"
    echo ""
    if [ -n "$PANICOS_SQ" ]; then
        boot_rw
        sed -i "s|^IMAGE=.*|IMAGE=$PANICOS_SQ|" "$ACTIVE_CFG"
        boot_ro
        echo "  Switched back to PanicOS ($PANICOS_SQ)."
        echo "  Reboot to return to the PanicOS launcher."
    else
        echo "  Warning: could not find a PanicOS squashfs to switch back to."
        echo "  Edit /boot/panicos-active.cfg manually."
    fi
else
    # Currently booting PanicOS — activate Debian
    echo "  Status: Debian Desktop is INSTALLED but not active"
    echo ""
    boot_rw
    sed -i "s|^IMAGE=.*|IMAGE=$SQUASHFS_NAME|" "$ACTIVE_CFG"
    boot_ro
    echo "  Activated. Reboot to boot into Debian Sid desktop."
    echo ""
    echo "  Tip: with multiple .squashfs files on /boot, the boot"
    echo "  menu (mbselect) lets you choose at startup — no need"
    echo "  to run this tool just to switch."
fi

echo ""
read -r -t 10 -p "  Press Enter to exit..." 2>/dev/null || true

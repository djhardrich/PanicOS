#!/usr/bin/env bash
# build-debian-desktop.sh — build a Debian Sid ARM64 desktop squashfs
# for PanicOS multiboot.
#
# Output: output/debian-desktop/panicos-debian-desktop.squashfs
#
# Boot: the PanicOS initramfs handles everything. Just copy the squashfs to
# the boot vfat partition (/boot/ on-device). If multiple .squashfs files
# exist, panicos-mbselect shows a 3-second menu at boot. Otherwise update
# /boot/panicos-active.cfg: IMAGE=panicos-debian-desktop.squashfs
#
# Each squashfs gets its own overlayfs namespace automatically
# (/storage/.panicos-overlay/<flavor>/{upper,work}), so Debian and PanicOS
# don't share /etc, package state, etc. /storage outside that directory is
# shared (ROMs, music, documents, etc.).
#
# Requirements on build host:
#   Arch: paru -S mmdebstrap qemu-user-static-bin
#         sudo systemctl restart systemd-binfmt
#   Debian: sudo apt install mmdebstrap qemu-user-static binfmt-support
#           sudo systemctl restart systemd-binfmt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ASSETS="$ROOT/debian-desktop"
OUTPUT="$ROOT/output/debian-desktop"
ROOTFS="$OUTPUT/rootfs"
SQUASHFS_OUT="$OUTPUT/panicos-debian-desktop.squashfs"

ARCH=arm64
SUITE=sid
MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian}"

PACKAGES=(
    # Init + session management
    systemd systemd-sysv dbus dbus-user-session udev

    # Login / session
    sddm

    # Wayland compositor + panel + wallpaper
    wayfire waybar swaybg

    # On-screen keyboard (Wayland-native)
    wvkbd

    # Terminal
    foot

    # File manager
    thunar

    # Text editor
    mousepad

    # NetworkManager
    network-manager network-manager-gnome

    # Notification daemon
    mako

    # Fonts
    fonts-dejavu-core fonts-liberation

    # Audio (pipewire)
    pipewire pipewire-pulse wireplumber

    # Mesa / GPU (panfrost)
    libgl1-mesa-dri mesa-vulkan-drivers

    # GTK themes + icons
    adwaita-icon-theme gnome-themes-extra

    # Gamepad mouse daemon
    python3 python3-evdev

    # Locale + timezone
    locales tzdata

    # System utilities
    sudo curl wget less nano htop procps iproute2
    bash-completion xdg-user-dirs xdg-utils desktop-file-utils

    # Portal support for Wayland
    xdg-desktop-portal xdg-desktop-portal-wlr
)

# ── helpers ──────────────────────────────────────────────────────────────────
info()  { echo -e "\033[1;32m>>> $*\033[0m"; }
warn()  { echo -e "\033[1;33m    $*\033[0m"; }
error() { echo -e "\033[1;31m!!! $*\033[0m" >&2; exit 1; }

check_tools() {
    for t in mmdebstrap mksquashfs; do
        command -v "$t" &>/dev/null || error "Missing: $t"
    done
    # qemu-aarch64-static must exist (from qemu-user-static / qemu-user-static-bin)
    local qemu
    qemu=$(command -v qemu-aarch64-static 2>/dev/null) || \
        error "Missing: qemu-aarch64-static — install qemu-user-static-bin (Arch AUR)"
    # binfmt must be active for aarch64
    [ -e /proc/sys/fs/binfmt_misc/aarch64 ] || \
    [ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || \
        error "binfmt aarch64 not active — run: sudo systemctl restart systemd-binfmt"
    info "Build tools OK (qemu: $qemu)"
}

# ── build ─────────────────────────────────────────────────────────────────────
info "Checking build tools..."
check_tools

info "Creating output directory..."
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS" "$OUTPUT"

PKG_LIST="$(IFS=,; echo "${PACKAGES[*]}")"

info "Bootstrapping Debian $SUITE arm64 rootfs (this takes ~15 min)..."
mmdebstrap \
    --arch="$ARCH" \
    --variant=minbase \
    --include="$PKG_LIST" \
    --components="main contrib non-free non-free-firmware" \
    "$SUITE" \
    "$ROOTFS" \
    "$MIRROR"

info "Configuring rootfs..."

chroot_run() {
    chroot "$ROOTFS" /usr/bin/env \
        DEBIAN_FRONTEND=noninteractive \
        LANG=C.UTF-8 \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        "$@"
}

# Locale + timezone
chroot_run sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen
chroot_run locale-gen
chroot_run update-locale LANG=en_US.UTF-8
echo "UTC" > "$ROOTFS/etc/timezone"
chroot_run ln -sf /usr/share/zoneinfo/UTC /etc/localtime
chroot_run dpkg-reconfigure -f noninteractive tzdata

# Hostname
echo "panicos-desktop" > "$ROOTFS/etc/hostname"
cat > "$ROOTFS/etc/hosts" <<'EOF'
127.0.0.1   localhost
127.0.1.1   panicos-desktop
::1         localhost ip6-localhost ip6-loopback
EOF

# User
chroot_run useradd -m -s /bin/bash -G sudo,audio,video,input,render,netdev panicos
echo "panicos:panicos" | chroot_run chpasswd
echo "root:panicos" | chroot_run chpasswd
echo "panicos ALL=(ALL) NOPASSWD:ALL" > "$ROOTFS/etc/sudoers.d/panicos"
chmod 440 "$ROOTFS/etc/sudoers.d/panicos"

# ── SDDM auto-login via Wayfire ───────────────────────────────────────────────
mkdir -p "$ROOTFS/etc/sddm.conf.d"
cp "$ASSETS/configs/sddm.conf" "$ROOTFS/etc/sddm.conf.d/panicos.conf"

# Wayfire wayland-session entry
mkdir -p "$ROOTFS/usr/share/wayland-sessions"
cp "$ASSETS/configs/wayfire.desktop" "$ROOTFS/usr/share/wayland-sessions/"

chroot_run systemctl enable sddm

# ── Wayfire + waybar config for panicos user ──────────────────────────────────
USER_HOME="$ROOTFS/home/panicos"
USER_CFG="$USER_HOME/.config"

mkdir -p "$USER_CFG/wayfire"
cp "$ASSETS/configs/wayfire.ini"          "$USER_CFG/wayfire/wayfire.ini"

mkdir -p "$USER_CFG/waybar"
cp "$ASSETS/configs/waybar-config.json"   "$USER_CFG/waybar/config"
cp "$ASSETS/configs/waybar-style.css"     "$USER_CFG/waybar/style.css"

# Foot terminal config (minimal, usable on small screen)
mkdir -p "$USER_CFG/foot"
cat > "$USER_CFG/foot/foot.ini" <<'EOF'
[main]
font=monospace:size=9
[colors]
background=1a1a2e
foreground=e0e0e0
EOF

# XDG autostart: nm-applet
mkdir -p "$USER_CFG/autostart"
cat > "$USER_CFG/autostart/nm-applet.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Network Manager Applet
Exec=nm-applet --indicator
X-GNOME-Autostart-enabled=true
EOF

# Pipewire user session autostart
mkdir -p "$USER_HOME/.config/systemd/user/default.target.wants"
for svc in pipewire.service pipewire-pulse.service wireplumber.service; do
    ln -sf "/usr/lib/systemd/user/$svc" \
        "$USER_HOME/.config/systemd/user/default.target.wants/$svc" 2>/dev/null || true
done

chroot_run chown -R panicos:panicos /home/panicos

# ── NetworkManager ────────────────────────────────────────────────────────────
cp "$ASSETS/configs/NetworkManager.conf" \
    "$ROOTFS/etc/NetworkManager/NetworkManager.conf"
chroot_run systemctl enable NetworkManager

# ── Gamepad mouse daemon ──────────────────────────────────────────────────────
mkdir -p "$ROOTFS/usr/local/lib/panicos"
cp "$ASSETS/services/gamepad-mouse.py" \
    "$ROOTFS/usr/local/lib/panicos/gamepad-mouse.py"
chmod +x "$ROOTFS/usr/local/lib/panicos/gamepad-mouse.py"
cp "$ASSETS/services/gamepad-mouse.service" \
    "$ROOTFS/etc/systemd/system/gamepad-mouse.service"
chroot_run systemctl enable gamepad-mouse

# ── fstab ─────────────────────────────────────────────────────────────────────
# Root + overlayfs is handled by the PanicOS initramfs.
# /boot and /storage are moved into the new root by the initramfs too.
cat > "$ROOTFS/etc/fstab" <<'EOF'
# Root handled by PanicOS initramfs (squashfs + overlayfs).
# /boot (vfat) and /storage (ext4) are mounted by the initramfs and
# moved into this rootfs — no fstab entries needed for them.
tmpfs   /tmp    tmpfs   defaults,nosuid,nodev   0 0
EOF

# ── Clean up ──────────────────────────────────────────────────────────────────
info "Cleaning rootfs for squashfs..."
rm -f "$ROOTFS/usr/bin/qemu-aarch64-static"
chroot_run apt-get clean
rm -rf "$ROOTFS/var/cache/apt/archives"/*.deb \
       "$ROOTFS/var/log"/* \
       "$ROOTFS/tmp"/*

# ── Build squashfs ────────────────────────────────────────────────────────────
info "Building squashfs (zstd compression, this takes a few minutes)..."
mksquashfs "$ROOTFS" "$SQUASHFS_OUT" \
    -comp zstd \
    -Xcompression-level 19 \
    -noappend \
    -no-progress

SIZE=$(du -sh "$SQUASHFS_OUT" | cut -f1)
info "Done: $SQUASHFS_OUT ($SIZE)"
echo ""
echo "Deploy:"
echo "  scp $SQUASHFS_OUT root@192.168.1.181:/boot/"
echo "  ssh root@192.168.1.181 'echo IMAGE=panicos-debian-desktop.squashfs > /boot/panicos-active.cfg'"
echo ""
echo "Or: with multiple .squashfs on /boot, mbselect menu appears at boot."
echo "Default login: panicos / panicos"

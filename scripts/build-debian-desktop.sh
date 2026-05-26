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
#   Arch: paru -S mmdebstrap qemu-user-static debian-archive-keyring
#         sudo systemctl restart systemd-binfmt
#         (arch-test not needed — script passes --skip=check/qemu)
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

# Buildroot output dir containing the kernel build tree.
# Override with BOARD_OUTPUT=/path/to/output/<board> if needed.
BOARD_OUTPUT="${BOARD_OUTPUT:-$ROOT/output/rg35xx-pro-launcher-mainline}"

PACKAGES=(
    # Init + session management
    systemd systemd-sysv dbus dbus-user-session udev

    # Login / session (qtvirtualkeyboard-plugin enables OSK on the login screen)
    sddm qtvirtualkeyboard-plugin

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

    # NetworkManager + Bluetooth
    # network-manager-tui: nmtui was split from network-manager in NM 1.56
    # wpasupplicant: only a Recommends of NM, not pulled in by minbase — required for WiFi
    network-manager network-manager-tui network-manager-gnome wpasupplicant
    bluetooth blueman bluez-tools libspa-0.2-bluetooth

    # Notification daemon
    mako-notifier

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
    plocate

    # Network tools (ping, traceroute, dig, ifconfig, netstat, ss, nmap, iwlist)
    iputils-ping net-tools dnsutils traceroute nmap inetutils-telnet wireless-tools

    # Application launcher
    rofi

    # Hardware control
    brightnessctl

    # Developer tools (out-of-tree kernel module building + general dev)
    build-essential git kmod
    libssl-dev flex bison bc pahole

    # Portal support for Wayland
    xdg-desktop-portal xdg-desktop-portal-wlr
)

# ── helpers ──────────────────────────────────────────────────────────────────
info()  { echo -e "\033[1;32m>>> $*\033[0m"; }
warn()  { echo -e "\033[1;33m    $*\033[0m"; }
error() { echo -e "\033[1;31m!!! $*\033[0m" >&2; exit 1; }

DEBIAN_KEYRING=""

check_tools() {
    for t in mmdebstrap mksquashfs; do
        command -v "$t" &>/dev/null || error "Missing: $t"
    done
    # qemu-aarch64-static must exist (from qemu-user-static / qemu-user-static-bin)
    local qemu
    qemu=$(command -v qemu-aarch64-static 2>/dev/null) || \
        error "Missing: qemu-aarch64-static — install qemu-user-static (Arch)"
    # binfmt must be active for aarch64
    [ -e /proc/sys/fs/binfmt_misc/aarch64 ] || \
    [ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || \
        error "binfmt aarch64 not active — run: sudo systemctl restart systemd-binfmt"
    # Debian keyring (needed on non-Debian hosts)
    for k in \
        /usr/share/keyrings/debian-archive-keyring.gpg \
        /usr/share/debhelper/vendor/debian-keyring.gpg; do
        [ -f "$k" ] && DEBIAN_KEYRING="$k" && break
    done
    [ -n "$DEBIAN_KEYRING" ] || \
        error "Debian keyring not found — install debian-archive-keyring (Arch AUR)"
    info "Build tools OK (qemu: $qemu, keyring: $DEBIAN_KEYRING)"
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
    --skip=check/qemu \
    --keyring="$DEBIAN_KEYRING" \
    "$SUITE" \
    "$ROOTFS" \
    "$MIRROR"

info "Configuring rootfs..."

# Bind-mount proc/sys/dev so systemctl enable and other tools work in chroot.
mount -t proc  proc     "$ROOTFS/proc"
mount -t sysfs sysfs    "$ROOTFS/sys"
mount --bind   /dev     "$ROOTFS/dev"
mount --bind   /dev/pts "$ROOTFS/dev/pts"
trap 'umount -lf "$ROOTFS/dev/pts" "$ROOTFS/dev" "$ROOTFS/sys" "$ROOTFS/proc" 2>/dev/null || true' EXIT

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
chroot_run systemctl enable bluetooth

# ── logind: don't immediately poweroff on KEY_POWER ──────────────────────────
mkdir -p "$ROOTFS/etc/systemd/logind.conf.d"
cat > "$ROOTFS/etc/systemd/logind.conf.d/panicos.conf" <<'EOF'
[Login]
HandlePowerKey=ignore
HandleLidSwitch=ignore
HandleLidSwitchDocked=ignore
EOF

# ── Gamepad mouse daemon ──────────────────────────────────────────────────────
mkdir -p "$ROOTFS/usr/local/lib/panicos"
cp "$ASSETS/services/gamepad-mouse.py" \
    "$ROOTFS/usr/local/lib/panicos/gamepad-mouse.py"
chmod +x "$ROOTFS/usr/local/lib/panicos/gamepad-mouse.py"
cp "$ASSETS/services/gamepad-mouse.service" \
    "$ROOTFS/etc/systemd/system/gamepad-mouse.service"
chroot_run systemctl enable gamepad-mouse

# udev rule: tag the virtual mouse with seat+uaccess so logind assigns it to
# the compositor's seat.  Without this, Wayfire never opens the uinput device.
mkdir -p "$ROOTFS/etc/udev/rules.d"
cat > "$ROOTFS/etc/udev/rules.d/99-panicos-uinput.rules" <<'UDEV'
SUBSYSTEM=="input", ATTRS{name}=="PanicOS Gamepad Mouse", TAG+="seat", TAG+="uaccess"
SUBSYSTEM=="input", ATTRS{name}=="PanicOS Gamepad Keys", TAG+="seat", TAG+="uaccess"
UDEV

# ── Kernel headers (for out-of-tree module building) ─────────────────────────
LINUX_BUILD=$(find "$BOARD_OUTPUT/build" -maxdepth 1 -name 'linux-[0-9]*' -type d 2>/dev/null | sort -V | tail -1)
if [ -n "$LINUX_BUILD" ] && [ -f "$LINUX_BUILD/include/config/kernel.release" ]; then
    KVER=$(cat "$LINUX_BUILD/include/config/kernel.release")
    KHEADER_DEST="$ROOTFS/usr/src/linux-headers-$KVER"
    info "Installing kernel headers $KVER from $LINUX_BUILD..."

    mkdir -p "$KHEADER_DEST"

    # Core build files
    cp "$LINUX_BUILD/Makefile" "$KHEADER_DEST/"
    cp "$LINUX_BUILD/.config" "$KHEADER_DEST/"
    [ -f "$LINUX_BUILD/Kbuild" ] && cp "$LINUX_BUILD/Kbuild" "$KHEADER_DEST/"
    cp "$LINUX_BUILD/Module.symvers" "$KHEADER_DEST/" 2>/dev/null || true

    # Headers
    cp -a "$LINUX_BUILD/include" "$KHEADER_DEST/"
    mkdir -p "$KHEADER_DEST/arch/arm64"
    cp -a "$LINUX_BUILD/arch/arm64/include" "$KHEADER_DEST/arch/arm64/"
    cp "$LINUX_BUILD/arch/arm64/Makefile" "$KHEADER_DEST/arch/arm64/" 2>/dev/null || true

    # scripts/ source only — host x86_64 binaries stripped.
    # Users who want to build modules on-device run:
    #   make -C /usr/src/linux-headers-$(uname -r) scripts ARCH=arm64
    cp -a "$LINUX_BUILD/scripts" "$KHEADER_DEST/"
    find "$KHEADER_DEST/scripts" -type f -executable \
        ! -name '*.sh' ! -name '*.pl' ! -name '*.awk' ! -name 'Makefile*' \
        -exec sh -c 'file "$1" 2>/dev/null | grep -q "ELF.*x86" && rm -f "$1"' _ {} \;

    # tools/include (needed by some module Makefiles)
    if [ -d "$LINUX_BUILD/tools/include" ]; then
        mkdir -p "$KHEADER_DEST/tools"
        cp -a "$LINUX_BUILD/tools/include" "$KHEADER_DEST/tools/"
    fi

    # Copy full modules tree from PanicOS build so device drivers load.
    # Note: initramfs also injects modules at boot for any squashfs that lacks
    # them, so this is belt-and-suspenders for the Debian squashfs itself.
    MODULES_SRC="$BOARD_OUTPUT/target/usr/lib/modules/$KVER"
    if [ -d "$MODULES_SRC" ]; then
        mkdir -p "$ROOTFS/lib/modules"
        cp -a "$MODULES_SRC" "$ROOTFS/lib/modules/"
        chroot_run depmod -a "$KVER"
        info "Kernel modules installed from PanicOS build ($KVER)"
    else
        mkdir -p "$ROOTFS/lib/modules/$KVER"
    fi

    # Wire /lib/modules/<kver>/build for out-of-tree module development
    ln -sfT "/usr/src/linux-headers-$KVER" "$ROOTFS/lib/modules/$KVER/build"

    # Autoload PanicOS device drivers at boot
    cat > "$ROOTFS/etc/modules-load.d/panicos-joypad.conf" <<'MODEOF'
# PanicOS H700 handheld gamepad driver (rocknix-joypad project)
rocknix-singleadc-joypad
MODEOF

    # Copy firmware blobs from PanicOS build (wifi, BT, panel init, etc.)
    FW_SRC="$BOARD_OUTPUT/target/usr/lib/firmware"
    if [ -d "$FW_SRC" ]; then
        mkdir -p "$ROOTFS/usr/lib/firmware"
        cp -a "$FW_SRC/." "$ROOTFS/usr/lib/firmware/"
        info "Firmware blobs installed from PanicOS build"
    fi

    info "Kernel headers ready: /usr/src/linux-headers-$KVER"
else
    warn "No kernel build found in $BOARD_OUTPUT/build — skipping headers"
    warn "Set BOARD_OUTPUT=/path/to/output/<board> to include kernel headers"
fi

# ── Bluetooth firmware fix: RTL8821CS SDIO config blob ───────────────────────
# Debian's firmware-realtek ships rtl8821cs_config.bin as a symlink to
# rtl8761b_config.bin (wrong chip). The launcher's SOC overlay has the
# correct 29-byte SDIO blob; install it explicitly. We also `cp -a` of the
# buildroot firmware tree earlier writes THROUGH the bad symlink and
# corrupts rtl8761b_config.bin, so restore that too if present.
SOC_RTL_BLOB="$ROOT/soc/allwinner-h700/mainline/rootfs-overlay/usr/lib/firmware/rtl_bt/rtl8821cs_config.bin"
EXPECTED_MD5="37338e0b8861a20ce877c0a10cbaaae3"
ACTUAL_MD5="$(md5sum "$SOC_RTL_BLOB" 2>/dev/null | cut -d' ' -f1)"
[ "$ACTUAL_MD5" = "$EXPECTED_MD5" ] \
    || error "SOC rtl8821cs_config.bin md5 mismatch: got $ACTUAL_MD5 expected $EXPECTED_MD5"

RTL_FW_DIR="$ROOTFS/lib/firmware/rtl_bt"
mkdir -p "$RTL_FW_DIR"
rm -f "$RTL_FW_DIR/rtl8821cs_config.bin"
install -m 0644 "$SOC_RTL_BLOB" "$RTL_FW_DIR/rtl8821cs_config.bin"
info "Installed correct rtl8821cs_config.bin (29-byte SDIO blob)"

# Restore rtl8761b_config.bin from Debian firmware-realtek if the earlier
# cp -a wrote through the symlink and corrupted it. Re-install from .deb if
# present; otherwise it stays whatever the buildroot firmware tree had.
if dpkg-deb --version >/dev/null 2>&1; then
    chroot_run apt-get install --reinstall -y firmware-realtek 2>&1 \
        | grep -vE '^(Reading|Building|0 upgraded|After this)' || true
fi

# ── Bluetooth UART re-probe workaround service ───────────────────────────────
# With CONFIG_BT_LE=y the hci_uart serdev probe races the rfkill GPIO at boot
# and silently defers, leaving /sys/class/bluetooth empty. This oneshot
# reloads hci_uart after bluetooth.service if hci0 didn't appear. Same
# workaround the launcher image uses.
cp "$ROOT/soc/allwinner-h700/mainline/rootfs-overlay/usr/lib/systemd/system/panicos-bt-wakeup.service" \
    "$ROOTFS/usr/lib/systemd/system/panicos-bt-wakeup.service"
chroot_run systemctl enable panicos-bt-wakeup.service
info "Installed and enabled panicos-bt-wakeup.service"

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

# Unmount bind mounts before mksquashfs — otherwise /proc /sys /dev
# get included as real files in the squashfs.
umount -lf "$ROOTFS/dev/pts" "$ROOTFS/dev" "$ROOTFS/sys" "$ROOTFS/proc" 2>/dev/null || true

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

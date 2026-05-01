#!/usr/bin/env bash
# Build a PanicOS-compatible aarch64 squashfs from a Debian / Ubuntu / Arch
# base distro. Output is a standalone .squashfs that drops onto a flashed
# PanicOS device's boot vfat — edit panicos-active.cfg to point at it.
#
# Why this exists: PanicOS provides the kernel + initramfs + bootloader.
# A "flavor" is just a rootfs squashfs; the same hardware can boot any
# squashfs the user drops on the boot partition. This script lets that
# rootfs be a real distro (Debian Trixie, Ubuntu Noble, Arch ARM) instead
# of buildroot's busybox userland.
#
# Requirements:
#   - root or sudo (chroot, mknod, debootstrap need it)
#   - host must have binfmt_misc registered for aarch64 (qemu-user-static
#     package on most distros sets this up; check with:
#       cat /proc/sys/fs/binfmt_misc/qemu-aarch64)
#
# Usage:
#   distro-bootstrap.sh --distro debian --suite trixie [--out PATH] [--packages "p1 p2"]
#   distro-bootstrap.sh --distro ubuntu --suite noble  [--out PATH] [--packages "p1 p2"]
#   distro-bootstrap.sh --distro arch                  [--out PATH] [--packages "p1 p2"]
#
# Default output: $PANICOS_ROOT/output/distro/panicos-<distro>-<suite>-aarch64.squashfs
# Default cache:  $HOME/.cache/panicos-distro-bootstrap/

set -euo pipefail

# -------------------------------------------------------------------------
# Args + defaults
# -------------------------------------------------------------------------

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

DISTRO=""
SUITE=""
ARCH="arm64"          # debootstrap term; for arch we'd need cross-bootstrap
OUT=""
USER_PACKAGES=""
CACHE_DIR="${PANICOS_DISTRO_CACHE:-$HOME/.cache/panicos-distro-bootstrap}"
ROOT_PASSWORD="panicos"
HOSTNAME=""

usage() {
    cat <<EOF >&2
Usage: $0 --distro <debian|ubuntu|arch> [--suite <name>] [--out PATH]
                                         [--packages "p1 p2 ..."]
                                         [--cache-dir DIR]
                                         [--root-password STR]
                                         [--hostname STR]

Defaults:
  --suite        debian: trixie, ubuntu: noble (Arch ignores)
  --out          $ROOT/output/distro/panicos-<distro>-<suite>-aarch64.squashfs
  --cache-dir    \$HOME/.cache/panicos-distro-bootstrap
  --root-password panicos
  --hostname     panicos-<distro>
EOF
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --distro)        DISTRO="$2";        shift 2 ;;
        --suite)         SUITE="$2";         shift 2 ;;
        --out)           OUT="$2";           shift 2 ;;
        --packages)      USER_PACKAGES="$2"; shift 2 ;;
        --cache-dir)     CACHE_DIR="$2";     shift 2 ;;
        --root-password) ROOT_PASSWORD="$2"; shift 2 ;;
        --hostname)      HOSTNAME="$2";      shift 2 ;;
        -h|--help)       usage ;;
        *)               echo "unknown arg: $1" >&2; usage ;;
    esac
done

[ -n "$DISTRO" ] || { echo "--distro required" >&2; usage; }
case "$DISTRO" in
    debian) [ -n "$SUITE" ] || SUITE="trixie" ;;
    ubuntu) [ -n "$SUITE" ] || SUITE="noble" ;;
    arch)   SUITE="rolling" ;;     # arch has no suites
    *)      echo "unsupported distro: $DISTRO" >&2; exit 1 ;;
esac
[ -n "$HOSTNAME" ] || HOSTNAME="panicos-$DISTRO"
[ -n "$OUT" ] || OUT="$ROOT/output/distro/panicos-$DISTRO-$SUITE-aarch64.squashfs"

# -------------------------------------------------------------------------
# Pre-flight checks
# -------------------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must run as root (or via sudo)." >&2
    echo "       chroot, debootstrap, pacstrap all need root." >&2
    exit 1
fi

if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    echo "ERROR: binfmt_misc missing aarch64 registration." >&2
    echo "       Install qemu-user-static (deb/arch) and ensure binfmt_misc is mounted." >&2
    exit 1
fi

if ! grep -qE '^enabled' /proc/sys/fs/binfmt_misc/qemu-aarch64; then
    echo "ERROR: aarch64 binfmt is registered but disabled." >&2
    echo "       echo 1 > /proc/sys/fs/binfmt_misc/qemu-aarch64" >&2
    exit 1
fi

case "$DISTRO" in
    debian|ubuntu) command -v debootstrap >/dev/null \
                       || { echo "debootstrap not installed" >&2; exit 1; } ;;
    arch)          command -v pacstrap >/dev/null \
                       || { echo "pacstrap not installed (arch-install-scripts)" >&2; exit 1; } ;;
esac
command -v mksquashfs >/dev/null \
    || { echo "mksquashfs not installed (squashfs-tools)" >&2; exit 1; }
command -v qemu-aarch64-static >/dev/null \
    || { echo "qemu-aarch64-static not installed (qemu-user-static)" >&2; exit 1; }

mkdir -p "$CACHE_DIR" "$(dirname "$OUT")"

# -------------------------------------------------------------------------
# Bootstrap stage
# -------------------------------------------------------------------------

STAGE="$CACHE_DIR/stage-$DISTRO-$SUITE-aarch64"
echo ">>> distro-bootstrap: stage = $STAGE"

# Always start clean so re-runs are reproducible.
if [ -d "$STAGE" ]; then
    echo ">>> distro-bootstrap: cleaning previous stage"
    # Defensive umount in case a prior run left binds.
    for m in /dev /dev/pts /proc /sys /run; do
        mountpoint -q "$STAGE$m" 2>/dev/null && umount -lf "$STAGE$m" || true
    done
    rm -rf "$STAGE"
fi
mkdir -p "$STAGE"

bootstrap_debian_ubuntu() {
    local mirror keyring
    case "$DISTRO" in
        debian)
            mirror="http://deb.debian.org/debian"
            keyring="/usr/share/keyrings/debian-archive-keyring.gpg"
            ;;
        ubuntu)
            mirror="http://ports.ubuntu.com/ubuntu-ports"
            keyring="/usr/share/keyrings/ubuntu-archive-keyring.gpg"
            ;;
    esac

    echo ">>> debootstrap --foreign --arch=$ARCH $SUITE $STAGE $mirror"
    debootstrap --foreign --arch="$ARCH" \
        --include=systemd,systemd-sysv,udev,openssh-server,sudo,iproute2,iputils-ping,locales,wpasupplicant,wireless-tools,ca-certificates \
        ${keyring:+--keyring="$keyring"} \
        "$SUITE" "$STAGE" "$mirror"

    cp /usr/bin/qemu-aarch64-static "$STAGE/usr/bin/"

    echo ">>> debootstrap second stage (chroot)"
    chroot "$STAGE" /debootstrap/debootstrap --second-stage
}

bootstrap_arch() {
    # Arch on aarch64 host is straightforward (pacstrap handles it). Cross-
    # bootstrapping arm64 from x86_64 needs archlinux-arm + a custom
    # pacman.conf. For now error with a clear message — user should run
    # this script on aarch64 hardware, or use the distrobuild docker image
    # we plan to ship later.
    echo "ERROR: arch cross-bootstrap from $(uname -m) is not yet implemented." >&2
    echo "       Run this script on aarch64 hardware, or use --distro debian/ubuntu." >&2
    exit 1
}

case "$DISTRO" in
    debian|ubuntu) bootstrap_debian_ubuntu ;;
    arch)          bootstrap_arch ;;
esac

# -------------------------------------------------------------------------
# Mount API filesystems for the chroot work below
# -------------------------------------------------------------------------

mount --bind /dev      "$STAGE/dev"
mount --bind /dev/pts  "$STAGE/dev/pts"
mount -t proc  proc    "$STAGE/proc"
mount -t sysfs sysfs   "$STAGE/sys"
mount -t tmpfs tmpfs   "$STAGE/run"

cleanup_mounts() {
    for m in /run /sys /proc /dev/pts /dev; do
        mountpoint -q "$STAGE$m" 2>/dev/null && umount -lf "$STAGE$m" || true
    done
}
trap cleanup_mounts EXIT

# -------------------------------------------------------------------------
# PanicOS overlay: hostname, root password, sshd config, network defaults
# -------------------------------------------------------------------------

echo ">>> applying PanicOS overlay (hostname=$HOSTNAME, root password set)"

echo "$HOSTNAME" > "$STAGE/etc/hostname"

# Avoid policy-rc.d issues: make sure systemctl etc. inside chroot don't
# try to run real services. dpkg-divert this away after we're done.
cat > "$STAGE/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod +x "$STAGE/usr/sbin/policy-rc.d"

# Set root password.
chroot "$STAGE" /bin/sh -c "echo 'root:$ROOT_PASSWORD' | chpasswd"

# SSH: enable openssh-server (PermitRootLogin yes — we're a developer/handheld
# OS, this is intentional; user can override post-install).
if [ -f "$STAGE/etc/ssh/sshd_config" ]; then
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' "$STAGE/etc/ssh/sshd_config"
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' "$STAGE/etc/ssh/sshd_config"
fi
chroot "$STAGE" systemctl enable ssh.service 2>/dev/null \
    || chroot "$STAGE" systemctl enable sshd.service 2>/dev/null \
    || echo "WARNING: couldn't enable ssh service inside chroot"

# Network: systemd-networkd + a wlan0 DHCP file matching what minimal flavor uses.
mkdir -p "$STAGE/etc/systemd/network"
cat > "$STAGE/etc/systemd/network/30-wlan0.network" <<'EOF'
[Match]
Type=wlan

[Network]
DHCP=yes
EOF
mkdir -p "$STAGE/etc/systemd/network"
cat > "$STAGE/etc/systemd/network/30-eth0.network" <<'EOF'
[Match]
Type=ether

[Network]
DHCP=yes
EOF
chroot "$STAGE" systemctl enable systemd-networkd.service 2>/dev/null || true
chroot "$STAGE" systemctl enable systemd-resolved.service 2>/dev/null || true

# Make /etc/resolv.conf the systemd-resolved stub link.
ln -sf /run/systemd/resolve/stub-resolv.conf "$STAGE/etc/resolv.conf"

# wpa_supplicant@wlan0 — same handheld convention as the minimal flavor.
chroot "$STAGE" systemctl enable wpa_supplicant@wlan0.service 2>/dev/null || true

# fstab — empty; PanicOS overlay+initramfs handles all mounts.
cat > "$STAGE/etc/fstab" <<'EOF'
# PanicOS handles the rootfs / overlay / boot mount via initramfs.
# Don't list any of those here.
proc       /proc     proc      defaults            0 0
sysfs      /sys      sysfs     defaults            0 0
tmpfs      /tmp      tmpfs     mode=1777,nosuid,nodev 0 0
EOF

# -------------------------------------------------------------------------
# Optional: extra user-supplied packages
# -------------------------------------------------------------------------

if [ -n "$USER_PACKAGES" ]; then
    echo ">>> installing user packages: $USER_PACKAGES"
    case "$DISTRO" in
        debian|ubuntu)
            chroot "$STAGE" apt-get update
            chroot "$STAGE" apt-get install -y --no-install-recommends $USER_PACKAGES
            ;;
        arch)
            chroot "$STAGE" pacman -Syu --noconfirm $USER_PACKAGES
            ;;
    esac
fi

# -------------------------------------------------------------------------
# Cleanup before squashfs
# -------------------------------------------------------------------------

echo ">>> cleaning caches"
case "$DISTRO" in
    debian|ubuntu)
        chroot "$STAGE" apt-get clean
        rm -rf "$STAGE/var/lib/apt/lists/"*
        rm -rf "$STAGE/var/cache/apt/archives/"*.deb
        ;;
    arch)
        chroot "$STAGE" pacman -Scc --noconfirm 2>/dev/null || true
        ;;
esac

# Remove our policy-rc.d so the live system doesn't see it.
rm -f "$STAGE/usr/sbin/policy-rc.d"

# Strip the qemu binary — not needed at runtime on real aarch64 hardware.
rm -f "$STAGE/usr/bin/qemu-aarch64-static"

# Remove machine-id so first boot generates a fresh one (otherwise every
# device flashed from the same image gets the same machine-id).
: > "$STAGE/etc/machine-id"
rm -f "$STAGE/var/lib/dbus/machine-id"
ln -sf /etc/machine-id "$STAGE/var/lib/dbus/machine-id"

# -------------------------------------------------------------------------
# Squashfs
# -------------------------------------------------------------------------

cleanup_mounts
trap - EXIT

echo ">>> mksquashfs $STAGE → $OUT"
rm -f "$OUT"
mksquashfs "$STAGE" "$OUT" \
    -comp gzip \
    -no-progress \
    -no-recovery \
    -no-exports \
    -wildcards \
    -e proc/* sys/* dev/* run/* tmp/*

ls -lh "$OUT"
echo ">>> distro-bootstrap: done — $OUT"
echo ">>> drop this onto a flashed PanicOS boot vfat and edit panicos-active.cfg:"
echo ">>>     IMAGE=$(basename "$OUT")"

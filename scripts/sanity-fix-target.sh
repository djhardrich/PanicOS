#!/usr/bin/env bash
# sanity-fix-target.sh — buildroot post-build hook that catches and repairs
# common target/ corruptions before squashfs gen.
#
# Wired via BR2_ROOTFS_POST_BUILD_SCRIPT in gen-defconfig.sh; runs after
# buildroot's target-finalize, before rootfs image creation.
#
# Buildroot calls post-build scripts as: $0 $TARGET_DIR. We don't take
# any other args.

set -euo pipefail

TARGET="${1:-${TARGET_DIR:?TARGET_DIR not set}}"

echo ">>> sanity-fix-target: checking $TARGET"

# Repair: /lib must be a symlink to usr/lib (merged-usr layout). When it's
# a real directory instead, /sbin/init -> ../lib/systemd/systemd resolves
# to /lib/systemd/systemd which doesn't exist (only /usr/lib/systemd/systemd
# does), and the kernel fails to switch_root with "no such file" right after
# the initramfs hands off. Hit on 2026-05-02 after a target/ + per-pkg
# .stamp_target_installed wipe — install order became non-deterministic and
# something (likely linux-modules/firmware) wrote to /lib/ before the
# skeleton-init-systemd package recreated /lib as a symlink, leaving /lib
# as a real dir with the original symlink displaced inside it as
# /lib/lib -> usr/lib.
if [ -d "$TARGET/lib" ] && [ ! -L "$TARGET/lib" ]; then
    echo "    /lib is a directory, expected a symlink to usr/lib — repairing"
    # Move any content to /usr/lib (where it belongs under the merged-usr
    # layout). rsync --remove-source-files leaves only empty dirs behind.
    rsync -a --remove-source-files "$TARGET/lib/" "$TARGET/usr/lib/"
    find "$TARGET/lib" -depth -type d -empty -delete
    rm -rf "$TARGET/lib"
    ln -sf usr/lib "$TARGET/lib"
    echo "    repaired: $(ls -la "$TARGET/lib" | awk '{print $9, $10, $11}')"
fi

# Sanity: /sbin/init must resolve to a real file. If broken, the kernel's
# switch_root fails at boot. Make a noisy abort here rather than shipping
# a brick.
if ! [ -e "$TARGET/sbin/init" ]; then
    echo "    ERROR: $TARGET/sbin/init doesn't resolve — aborting before squashfs gen" >&2
    ls -la "$TARGET/sbin/init" >&2 || true
    exit 1
fi

# Stamp OS_BUILD in /etc/os-release so ES system-info shows the git rev.
# OS_BUILD is read by ES's ApiSystem::getVersion(extra=true) and exported
# by profile.d/999-export so it's available to scripts.
# BR2_EXTERNAL_PANICOS_PATH is set by Buildroot when running post-build scripts.
PANICOS_ROOT="${BR2_EXTERNAL_PANICOS_PATH:-$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)}"
if [ -n "$PANICOS_ROOT" ]; then
    BUILD_REV="$(git -C "$PANICOS_ROOT" describe --always --dirty 2>/dev/null || echo unknown)"
    BUILD_DATE="$(date -u +%Y%m%d)"
    # Remove any stale OS_BUILD line, then append the fresh one.
    sed -i '/^OS_BUILD=/d' "$TARGET/etc/os-release"
    echo "OS_BUILD=\"${BUILD_DATE}-${BUILD_REV}\"" >> "$TARGET/etc/os-release"
    echo ">>> sanity-fix-target: stamped OS_BUILD=${BUILD_DATE}-${BUILD_REV}"
fi

# Redirect libjack.so.0 to PipeWire's JACK compat shim. jack2 installs its
# own libjack.so.0 → libjack.so.0.1.0 (the real jackd client). JACK apps
# (norns/crone) using that lib auto-spawn jackd, which fails because PipeWire
# already owns the ALSA device. PipeWire's compat shim connects directly to
# the PipeWire socket instead of spawning jackd.
# This must be done in post-build (not the rootfs overlay) because Buildroot's
# overlay rsync uses --safe-links which skips absolute symlinks.
if [ -d "$TARGET/usr/lib/pipewire-0.3/jack" ]; then
    ln -sf /usr/lib/pipewire-0.3/jack/libjack.so.0 \
        "$TARGET/usr/lib/libjack.so.0"
    echo ">>> sanity-fix-target: libjack.so.0 → pipewire-0.3/jack/libjack.so.0"
fi

echo ">>> sanity-fix-target: ok"

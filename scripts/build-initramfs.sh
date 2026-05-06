#!/usr/bin/env bash
# Build a small initramfs CPIO for PanicOS.
# Output: $ROOT/output/panicos-initramfs.cpio.gz
#
# busybox-aarch64 is sourced from the Debian arm64 busybox-static package
# (1.37.0-10.1) because busybox.net does not publish a pre-built aarch64
# binary for v1.36.1.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKEL="$ROOT/panicos-initramfs/skeleton"
INIT="$ROOT/panicos-initramfs/init"
OUT_DIR="$ROOT/output"
OUT="$OUT_DIR/panicos-initramfs.cpio.gz"
CACHE_DIR="$ROOT/.cache/initramfs"

# ── Auto-detection fallbacks ─────────────────────────────────────────────────
# The Makefile sets all three env vars explicitly; when the script is run
# standalone (e.g. a developer iterating on init) we auto-detect so the result
# is correct rather than silently empty.
#
# Firmware: collect every soc/*/variant/rootfs-overlay/usr/lib/firmware dir.
# Since the cpio is shared across devices (same SoC family) and panel firmware
# must be present before the squashfs mounts, include all SOC families found.
if [ -z "${PANICOS_INITRAMFS_FIRMWARE_DIRS:-}" ]; then
    _fw=""
    for d in "$ROOT"/soc/*/*/rootfs-overlay/usr/lib/firmware; do
        [ -d "$d" ] && _fw="${_fw:+$_fw:}$d"
    done
    [ -n "$_fw" ] && echo ">>> build-initramfs: auto-detected firmware dirs"
    PANICOS_INITRAMFS_FIRMWARE_DIRS="${_fw}"
fi

# Cross-compiler: pick the first output/*/host with aarch64-gcc.
if [ -z "${PANICOS_INITRAMFS_HOST_DIR:-}" ]; then
    for d in "$ROOT"/output/*/host; do
        if [ -x "$d/bin/aarch64-buildroot-linux-gnu-gcc" ]; then
            echo ">>> build-initramfs: auto-detected host dir: $d"
            PANICOS_INITRAMFS_HOST_DIR="$d"
            break
        fi
    done
fi

# Joypad modules: collect only for the NEWEST kernel version present across
# all output trees.  Without this, stale 7.0.1 build dirs can overwrite the
# correct 7.0.2 .ko (last cp wins in basename-collision mode).
if [ -z "${PANICOS_INITRAMFS_KMOD_PATHS:-}" ]; then
    _best_kver=$(find "$ROOT"/output/*/target/usr/lib/modules/ \
                      -maxdepth 1 -mindepth 1 -type d 2>/dev/null \
                 | xargs -r -I{} basename {} | sort -uV | tail -1)
    _kmods=""
    if [ -n "$_best_kver" ]; then
        for ko in "$ROOT"/output/*/target/usr/lib/modules/"$_best_kver"/updates/rocknix-joypad.ko \
                  "$ROOT"/output/*/target/usr/lib/modules/"$_best_kver"/updates/rocknix-singleadc-joypad.ko; do
            [ -f "$ko" ] && _kmods="${_kmods:+$_kmods:}$ko"
        done
    fi
    [ -n "$_kmods" ] && echo ">>> build-initramfs: auto-detected kmod paths (kver=$_best_kver)"
    PANICOS_INITRAMFS_KMOD_PATHS="${_kmods}"
fi
# ─────────────────────────────────────────────────────────────────────────────

BUSYBOX_VERSION=1.37.0
BUSYBOX_DEB_URL="http://ftp.us.debian.org/debian/pool/main/b/busybox/busybox-static_1.37.0-10.1_arm64.deb"
BUSYBOX_SHA256=d23c0ef6ff6d355df9f3ea34e046010a29ac1ab6d9f8a21744b7c4545669bac5

mkdir -p "$OUT_DIR" "$CACHE_DIR"

BB="$CACHE_DIR/busybox-aarch64-$BUSYBOX_VERSION"
if [ ! -f "$BB" ]; then
    echo ">>> Downloading static busybox $BUSYBOX_VERSION (Debian arm64 package)"
    TMPDIR_DEB=$(mktemp -d)
    trap 'rm -rf "$TMPDIR_DEB"' RETURN
    curl -fL -o "$TMPDIR_DEB/busybox-static_arm64.deb" "$BUSYBOX_DEB_URL"
    ( cd "$TMPDIR_DEB" && ar x busybox-static_arm64.deb && tar xJf data.tar.xz )
    actual=$(sha256sum "$TMPDIR_DEB/usr/bin/busybox" | awk '{print $1}')
    if [ "$actual" != "$BUSYBOX_SHA256" ]; then
        echo "busybox SHA256 mismatch: got $actual" >&2
        exit 1
    fi
    chmod +x "$TMPDIR_DEB/usr/bin/busybox"
    cp "$TMPDIR_DEB/usr/bin/busybox" "$BB"
fi

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

( cd "$SKEL" && find . -type d ) | (cd "$STAGE" && xargs -I{} mkdir -p {})

cp "$INIT" "$STAGE/init"
chmod 755 "$STAGE/init"

cp "$BB" "$STAGE/bin/busybox"
chmod 755 "$STAGE/bin/busybox"
# Applets the /init script (and a recovery shell on panic) actually call.
# Missing any of these is a fatal bug: with `set -e`, /init crashes on the
# first 'command not found' and the kernel panics with a black screen.
APPLETS="ash sh mount umount mkdir mknod losetup switch_root reboot poweroff
         echo cat sed sleep awk head ls grep cp mv rm chmod
         insmod printf seq tr"
for applet in $APPLETS; do
    ln -s busybox "$STAGE/bin/$applet"
done

# Multiboot menu helper. PANICOS_INITRAMFS_HOST_DIR is the device's
# buildroot host/ dir (set by the caller) — has the cross-cc that
# matches the kernel's ABI. Static-link so the binary doesn't need
# any libc on the initramfs (busybox is the only userspace).
if [ -n "${PANICOS_INITRAMFS_HOST_DIR:-}" ]; then
    CC="$PANICOS_INITRAMFS_HOST_DIR/bin/aarch64-buildroot-linux-gnu-gcc"
    if [ -x "$CC" ]; then
        echo ">>> Compiling panicos-mbselect (multiboot menu helper)"
        "$CC" -static -O2 -Wall -o "$STAGE/sbin/panicos-mbselect" \
            "$ROOT/panicos-initramfs/mbselect.c"
        chmod 755 "$STAGE/sbin/panicos-mbselect"
    else
        echo ">>> WARN: no cross-cc at $CC — skipping panicos-mbselect"
    fi
fi

# Multiboot menu needs gamepad input before /init reads
# /boot/panicos-active.cfg, so the rocknix-joypad.ko (the out-of-tree
# H700/RK3399 handheld input driver) has to ship in the initramfs.
# Insmod path is straight at /rocknix-joypad.ko — no depmod runs in
# the initramfs, so a flat path keeps /init's `insmod` invocation
# obvious. Caller passes PANICOS_INITRAMFS_KMOD_PATHS as a
# colon-separated list of .ko absolute paths.
if [ -n "${PANICOS_INITRAMFS_KMOD_PATHS:-}" ]; then
    IFS=':' read -ra _kmod_paths <<<"$PANICOS_INITRAMFS_KMOD_PATHS"
    for ko in "${_kmod_paths[@]}"; do
        [ -f "$ko" ] || { echo ">>> WARN: missing kmod $ko"; continue; }
        cp "$ko" "$STAGE/$(basename "$ko")"
    done
    echo ">>> bundled kmods: $(ls "$STAGE"/*.ko 2>/dev/null | wc -l) files"
fi

# Bundle firmware blobs into the initramfs at /lib/firmware/. Drivers
# whose .probe runs at device_initcall (panel-mipi-dpi-spi, regulator
# helpers, etc.) call request_firmware() synchronously; the kernel's
# firmware loader calls wait_for_initramfs() and searches the initramfs's
# /lib/firmware/. The squashfs isn't mounted yet, so blobs that aren't
# in the initramfs result in -ENOENT → probe fails → black screen.
#
# Source: caller passes PANICOS_INITRAMFS_FIRMWARE_DIRS as a colon-
# separated list of directories whose contents are copied verbatim under
# /lib/firmware/ in the initramfs (preserving subdir layout).
if [ -n "${PANICOS_INITRAMFS_FIRMWARE_DIRS:-}" ]; then
    mkdir -p "$STAGE/lib/firmware"
    IFS=':' read -ra _fw_dirs <<<"$PANICOS_INITRAMFS_FIRMWARE_DIRS"
    for d in "${_fw_dirs[@]}"; do
        [ -d "$d" ] || continue
        cp -a "$d/." "$STAGE/lib/firmware/"
    done
    echo ">>> bundled firmware: $(find "$STAGE/lib/firmware" -type f | wc -l) files"
fi

# Pre-pend a tiny cpio with /dev/console + /dev/null device nodes. Needed
# because `cpio -o` from non-root can't mknod, and without /dev/console
# in the initramfs the kernel's console_on_rootfs() warns "Unable to open
# initial console" — leaving /init with no stdin/stdout, set -e + echo
# fails with EBADF, /init exits, kernel panics with "init exited".
{
    python3 - "$STAGE" <<'PY'
import os, struct, sys
stage = sys.argv[1]
def cpio_entry(out, path, mode, ino, nlink, mtime, size, rmaj, rmin, data=b''):
    name = path.encode() + b'\x00'
    hdr = (b'070701'
        + b''.join(b'%08X' % v for v in
            [ino, mode, 0, 0, nlink, mtime, size, 0, 0, rmaj, rmin, len(name), 0]))
    out.write(hdr + name)
    pad = (-len(hdr + name)) & 3
    out.write(b'\x00' * pad)
    if data:
        out.write(data)
        out.write(b'\x00' * ((-len(data)) & 3))

S_IFDIR=0o040000; S_IFCHR=0o020000
out = sys.stdout.buffer
# /dev directory (already in cpio from skeleton, but harmless to repeat).
cpio_entry(out, 'dev', S_IFDIR | 0o755, ino=10, nlink=2, mtime=0, size=0, rmaj=0, rmin=0)
cpio_entry(out, 'dev/console', S_IFCHR | 0o600, ino=11, nlink=1, mtime=0, size=0, rmaj=5, rmin=1)
cpio_entry(out, 'dev/null',    S_IFCHR | 0o666, ino=12, nlink=1, mtime=0, size=0, rmaj=1, rmin=3)
PY
    ( cd "$STAGE" && find . | cpio --quiet -o -H newc )
} | gzip -9 > "$OUT"
echo ">>> Built $OUT ($(stat -c%s "$OUT") bytes)"

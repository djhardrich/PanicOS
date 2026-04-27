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
for applet in sh mount umount mkdir mknod losetup switch_root reboot echo cat sed; do
    ln -s busybox "$STAGE/bin/$applet"
done

( cd "$STAGE" && find . | cpio --quiet -o -H newc ) | gzip -9 > "$OUT"
echo ">>> Built $OUT ($(stat -c%s "$OUT") bytes)"

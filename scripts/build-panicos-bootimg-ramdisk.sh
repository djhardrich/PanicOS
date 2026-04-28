#!/usr/bin/env bash
# Build a tiny cpio.gz ramdisk for use as an Android bootimg ramdisk.
#
# Usage:
#   build-panicos-bootimg-ramdisk.sh <target_dir> <init_script> <out.cpio.gz>
#
# Picks busybox from <target_dir>/bin/busybox (target-arch static-ish binary
# that Buildroot already built). Stages the panicos-initramfs init script,
# applet symlinks, and required dirs; cpio's it; gzips it.
#
# Used by blob-mode flows (e.g. TrimUI Brick) where we repack a vendor
# Android bootimg with our own ramdisk so the vendor kernel boots PanicOS
# from SD card instead of the vendor's eMMC firmware.
set -euo pipefail

TARGET_DIR="${1:?usage: $0 <target_dir> <init_script> <out.cpio.gz>}"
INIT_SCRIPT="${2:?missing init script}"
OUT="${3:?missing output path}"

[ -x "$TARGET_DIR/bin/busybox" ] || {
    echo "error: $TARGET_DIR/bin/busybox not found or not executable" >&2
    exit 1
}
[ -f "$INIT_SCRIPT" ] || { echo "error: $INIT_SCRIPT not found" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Standard initramfs layout. Mirrors panicos-initramfs/skeleton/.
mkdir -p "$STAGE"/{bin,sbin,dev,proc,sys,run,boot,system,sysroot}

cp "$TARGET_DIR/bin/busybox" "$STAGE/bin/busybox"
chmod 755 "$STAGE/bin/busybox"

# Bundle the dynamic linker + every shared library busybox actually depends
# on. Buildroot's busybox is glibc-linked, not static — so ld-linux + libc
# (and friends) must be present in the ramdisk or the kernel can't exec
# /init. We resolve the needed sonames from the binary itself rather than
# hardcoding a list, since it changes per arch / glibc version.
mkdir -p "$STAGE/lib"
# Mirror buildroot's lib64 → lib symlink when it exists, so any binary that
# was linked with /lib64 in its rpath still resolves. Don't mkdir first —
# ln -sf into an existing dir creates a link INSIDE it.
if [ -L "$TARGET_DIR/lib64" ]; then
    ln -s "$(readlink "$TARGET_DIR/lib64")" "$STAGE/lib64"
fi

needed_libs() {
    local bin="$1"
    # Read DT_NEEDED entries + the program interpreter; resolve each soname
    # against $TARGET_DIR/lib (or lib64) — that's where Buildroot stages them.
    "$TARGET_DIR/usr/bin/readelf" -d "$bin" 2>/dev/null \
        | awk '/NEEDED/ {gsub(/[\[\]]/,"",$NF); print $NF}'
    "$TARGET_DIR/usr/bin/readelf" -l "$bin" 2>/dev/null \
        | awk -F'[][]' '/program interpreter/ {print $2}' \
        | awk -F/ '{print $NF}'
}

# Fall back to host readelf if target's isn't built (host-readelf isn't a
# Buildroot dep we can rely on either way).
if ! [ -x "$TARGET_DIR/usr/bin/readelf" ]; then
    needed_libs() {
        readelf -d "$1" 2>/dev/null \
            | awk '/NEEDED/ {gsub(/[\[\]]/,"",$NF); print $NF}'
        readelf -l "$1" 2>/dev/null \
            | awk -F'[][]' '/program interpreter/ {print $2}' \
            | awk -F/ '{print $NF}'
    }
fi

resolved=""
queue="$(needed_libs "$STAGE/bin/busybox" | sort -u)"
while [ -n "$queue" ]; do
    next=""
    for soname in $queue; do
        case " $resolved " in *" $soname "*) continue ;; esac
        # Find the actual file (follows symlinks). Buildroot puts them in
        # /lib for arm64 + /lib64 → /lib symlink.
        src=""
        for dir in "$TARGET_DIR/lib" "$TARGET_DIR/lib64" "$TARGET_DIR/usr/lib"; do
            if [ -e "$dir/$soname" ]; then src="$dir/$soname"; break; fi
        done
        [ -n "$src" ] || { echo "warn: lib $soname not found in target — skipping" >&2; continue; }
        # Copy the resolved real file under its soname; ld looks up by soname.
        cp -L "$src" "$STAGE/lib/$soname"
        chmod 755 "$STAGE/lib/$soname"
        resolved="$resolved $soname"
        # Recurse: pull this lib's NEEDED entries too.
        next="$next $(needed_libs "$src" | sort -u)"
    done
    queue="$(echo "$next" | tr ' ' '\n' | sort -u)"
done
echo ">>> ramdisk libs: $resolved"

# Applets the init script (and a recovery shell) actually call.
APPLETS_BIN="sh ash mount umount mkdir ls cat echo grep awk sleep head sed cp mv rm chmod"
APPLETS_SBIN="losetup switch_root reboot poweroff"
for a in $APPLETS_BIN; do ln -sf busybox "$STAGE/bin/$a"; done
for a in $APPLETS_SBIN; do ln -sf ../bin/busybox "$STAGE/sbin/$a"; done

install -m 0755 "$INIT_SCRIPT" "$STAGE/init"

# Build cpio.gz. fakeroot/cpio handles ownership; -R 0:0 forces uid/gid 0.
( cd "$STAGE" && find . | cpio --quiet -H newc -R 0:0 -o ) | gzip -9 -n > "$OUT"

echo ">>> wrote $OUT ($(stat -c %s "$OUT") bytes)"

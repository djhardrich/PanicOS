#!/usr/bin/env bash
# Vendor blobs declared in a kernel config's CONFIG_EXTRA_FIRMWARE into the
# rootfs-overlay (= initramfs at runtime). Sourced from the upstream
# linux-firmware tarball pinned by buildroot, with WHENCE-declared symlinks
# materialized so e.g. `rtl_bt/rtl8821cs_config.bin -> rtl8761b_config.bin`
# resolves on disk.
#
# Why: ROCKNIX's kernel configs bake these blobs into vmlinux via
# CONFIG_EXTRA_FIRMWARE — the kernel build pulls them from upstream
# linux-firmware at *their* build time, so they never appear in ROCKNIX's
# git tree. PanicOS deliberately blanks CONFIG_EXTRA_FIRMWARE (so blobs
# stay updateable independent of the kernel image), which means built-in
# drivers like rtw88_8821cs need the firmware in the initramfs at probe
# time. Vendoring into rootfs-overlay/usr/lib/firmware/ is how it gets
# there.

# Reads "LINUX_FIRMWARE_VERSION = NNNNNNNN" from buildroot's package .mk.
linux_firmware_pinned_version() {
    local mk="$1"
    awk -F' *= *' '/^LINUX_FIRMWARE_VERSION /{print $2; exit}' "$mk"
}

# Parse CONFIG_EXTRA_FIRMWARE="path1 path2 ..." from a kernel config fragment.
# One path per line on stdout; empty if absent or empty.
parse_extra_firmware_paths() {
    local cfg="$1"
    awk -F'"' '
        /^CONFIG_EXTRA_FIRMWARE *=/{
            n = split($2, a, /[[:space:]]+/)
            for (i = 1; i <= n; i++) if (length(a[i])) print a[i]
            exit
        }
    ' "$cfg"
}

# Cache the full WHENCE file alongside the tarball (one extract, many lookups).
_lfw_whence_path() {
    local tarball="$1" version="$2"
    local cache="$(dirname "$tarball")/WHENCE.$version"
    if [ ! -f "$cache" ]; then
        tar -xJf "$tarball" -O "linux-firmware-$version/WHENCE" \
            > "$cache.tmp" 2>/dev/null && mv "$cache.tmp" "$cache" || rm -f "$cache.tmp"
    fi
    printf '%s\n' "$cache"
}

# Stage one CONFIG_EXTRA_FIRMWARE path from the tarball into dest_root.
# Handles three cases:
#   1. relpath is a real file in the tarball  → extract directly
#   2. relpath is a WHENCE Link              → extract its target + symlink it
#   3. neither                                → return 1 with a warning
# Returns 0 on success, 1 on failure (caller logs).
linux_firmware_stage_path() {
    local tarball="$1" version="$2" relpath="$3" dest_root="$4"
    local prefix="linux-firmware-$version"
    local destfile="$dest_root/$relpath"

    mkdir -p "$(dirname "$destfile")"

    # Case 1: direct file extraction.
    if tar -xJf "$tarball" -C "$dest_root" --strip-components=1 \
            "$prefix/$relpath" 2>/dev/null && [ -f "$destfile" ] && [ ! -L "$destfile" ]; then
        return 0
    fi
    # Clean up any partial dir created by tar for a non-existent path.
    [ -e "$destfile" ] || rm -f "$destfile"

    # Case 2: WHENCE Link.
    local whence; whence=$(_lfw_whence_path "$tarball" "$version")
    [ -s "$whence" ] || { echo "WARNING: WHENCE missing from $tarball" >&2; return 1; }

    local target
    target=$(awk -v p="$relpath" '$1=="Link:" && $2==p { print $4; exit }' "$whence")
    if [ -z "$target" ]; then
        echo "WARNING: '$relpath' not present (file or WHENCE Link) in linux-firmware-$version" >&2
        return 1
    fi

    # Stage the link target (relative to relpath's directory) too.
    local target_rel="$(dirname "$relpath")/$target"
    local target_dest="$(dirname "$destfile")/$target"
    if [ ! -e "$target_dest" ]; then
        if ! tar -xJf "$tarball" -C "$dest_root" --strip-components=1 \
                "$prefix/$target_rel" 2>/dev/null; then
            echo "WARNING: link target '$target_rel' missing from tarball" >&2
            return 1
        fi
    fi
    ln -sf "$target" "$destfile"
}

# install_extra_firmware_blobs <kernel_cfg> <dest_overlay> <buildroot_root> [tarball_path]
#
# Reads CONFIG_EXTRA_FIRMWARE from kernel_cfg, stages each listed blob into
# dest_overlay (which should be a rootfs-overlay/usr/lib/firmware/ dir), using
# the buildroot-pinned linux-firmware version. If tarball_path is omitted we
# look for it in buildroot's dl/ cache. Echoes (relpath\tabsdest) lines for
# each successfully-staged path so the caller can record manifest entries.
install_extra_firmware_blobs() {
    local cfg="$1" dest="$2" buildroot="$3" tarball="${4:-}"

    local mk="$buildroot/package/linux-firmware/linux-firmware.mk"
    [ -f "$mk" ] || { echo "linux-firmware.mk not found at $mk" >&2; return 1; }
    local version; version=$(linux_firmware_pinned_version "$mk")
    [ -n "$version" ] || { echo "could not read LINUX_FIRMWARE_VERSION from $mk" >&2; return 1; }

    if [ -z "$tarball" ]; then
        tarball="$buildroot/dl/linux-firmware/linux-firmware-$version.tar.xz"
    fi
    if [ ! -f "$tarball" ]; then
        echo "linux-firmware tarball not found: $tarball" >&2
        echo "  run a buildroot build to populate dl/, or supply --tarball." >&2
        return 1
    fi

    local paths; paths=$(parse_extra_firmware_paths "$cfg")
    if [ -z "$paths" ]; then
        echo ">>> CONFIG_EXTRA_FIRMWARE empty — nothing to stage from upstream linux-firmware"
        return 0
    fi

    echo ">>> staging linux-firmware-$version blobs into ${dest#$PWD/}"
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        if [ -e "$dest/$p" ] || [ -L "$dest/$p" ]; then
            echo "    already present: $p"
            continue
        fi
        if linux_firmware_stage_path "$tarball" "$version" "$p" "$dest"; then
            echo "    staged: $p"
        fi
    done <<< "$paths"
}

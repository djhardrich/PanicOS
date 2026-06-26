#!/usr/bin/env bash
# build-rt-extmodules.sh — rebuild out-of-tree (M=) kernel-module packages
# against the RT kernel tree and install their .ko into the RT module staging
# tree, so the RT kernel ships the SAME out-of-tree drivers (gamepad, wifi, …)
# as the non-RT default.
#
# Buildroot compiles `$(eval $(kernel-module))` packages against $(LINUX_DIR)
# (the non-RT kernel). `make kernel-variant` builds only the RT kernel's
# in-tree modules, so without this step the RT tarball has no gamepad driver
# and `modprobe` finds nothing. Mirrors what buildroot does, but points the
# module build at the cloned RT kernel tree.
#
# Args:
#   $1 RT_KSRC      — the RT kernel build dir (has .config, Module.symvers)
#   $2 OUT_BUILD    — buildroot $(O)/build, where the driver source dirs live
#   $3 STAGING_USR  — INSTALL_MOD_PATH/usr, i.e. <staging>/usr (modules under
#                     <staging>/usr/lib/modules/<REL>)
#   $4 REL          — RT kernel release string (e.g. 7.0.2-rt)
#   $5 DEPMOD       — host depmod binary
set -euo pipefail

RT_KSRC="$1"; OUT_BUILD="$2"; STAGING_USR="$3"; REL="$4"; DEPMOD="$5"
PANICOS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

ARCH="${ARCH:-arm64}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-buildroot-linux-gnu-}"
export ARCH CROSS_COMPILE

UPDATES="$STAGING_USR/lib/modules/$REL/updates"
WORKROOT="$(dirname "$RT_KSRC")/extmod"
rm -rf "$WORKROOT"; mkdir -p "$WORKROOT"

# Discover buildroot kernel-module packages (those using $(eval $(kernel-module))).
# -F fixed-string match avoids regex escaping of the parens.
mapfile -t MKS < <(grep -rlF '(kernel-module)' \
    "$PANICOS_ROOT/package" "$PANICOS_ROOT/third_party" --include='*.mk' 2>/dev/null | sort -u || true)

built_any=0
for mk in "${MKS[@]}"; do
    pkg="$(basename "$mk" .mk)"
    # Only rebuild packages that were actually built for this config (have a
    # source/build dir). Others aren't part of this image.
    src="$(find "$OUT_BUILD" -maxdepth 1 -type d -name "$pkg-*" 2>/dev/null | head -1)"
    [ -n "$src" ] || continue
    work="$WORKROOT/$(basename "$src")"
    cp -a "$src" "$work"
    echo ">>> rt-extmodules: building $pkg against RT kernel ($REL)"
    # Clean first: the copied tree carries .o built against the non-RT kernel.
    make -C "$RT_KSRC" M="$work" clean >/dev/null 2>&1 || true
    make -C "$RT_KSRC" M="$work" modules
    mkdir -p "$UPDATES"
    # Install every produced .ko into the RT tree's updates/ dir (matches the
    # non-RT layout buildroot uses).
    find "$work" -name '*.ko' -exec cp -v {} "$UPDATES/" \;
    built_any=1
done

if [ "$built_any" = 1 ]; then
    echo ">>> rt-extmodules: regenerating modules.dep for $REL"
    "$DEPMOD" -b "$STAGING_USR" "$REL"
else
    echo ">>> rt-extmodules: no out-of-tree kernel-module packages built for this config"
fi

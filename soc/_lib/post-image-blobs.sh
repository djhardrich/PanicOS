#!/usr/bin/env bash
# soc/_lib/post-image-blobs.sh
# Blob-staging helper for closed-source vendor SoCs.
#
# Usage — source from a per-device post-image.sh:
#
#     . "$BR2_EXTERNAL_PANICOS_PATH/soc/_lib/post-image-blobs.sh"
#     panicos_blob_mode_stage || exit $?
#
# The function is a no-op (returns 1) when the prebuilt directory is absent
# (i.e. normal build-from-source mode).  When it IS present the function
# stages all blobs and returns 0.
#
# Caller must export (or inherit from Buildroot) the following env vars
# before sourcing this file:
#
#   SOC                        — e.g. allwinner-a133
#   KERNEL_FLAVOR              — usually "vendor"
#   DEVICE_NAME                — e.g. trimui-brick
#   BINARIES_DIR               — exported by Buildroot
#   TARGET_DIR                 — exported by Buildroot
#   BR2_EXTERNAL_PANICOS_PATH  — exported by Buildroot

# ---------------------------------------------------------------------------
# panicos_blob_mode_dir
#   Prints the canonical path to the prebuilt directory for the current device.
# ---------------------------------------------------------------------------
panicos_blob_mode_dir() {
    echo "$BR2_EXTERNAL_PANICOS_PATH/soc/$SOC/$KERNEL_FLAVOR/prebuilt/$DEVICE_NAME"
}

# ---------------------------------------------------------------------------
# panicos_is_blob_mode
#   Returns 0 (true) if blob mode is active for the current device.
# ---------------------------------------------------------------------------
panicos_is_blob_mode() {
    [ -d "$(panicos_blob_mode_dir)" ]
}

# ---------------------------------------------------------------------------
# panicos_blob_mode_stage
#   Copies kernel image, bootloader blobs, and optional modules tarball from
#   the prebuilt directory into BINARIES_DIR / TARGET_DIR.
#
#   Returns 0 on success, 1 when blob mode is not active.
# ---------------------------------------------------------------------------
panicos_blob_mode_stage() {
    local blob_dir
    blob_dir=$(panicos_blob_mode_dir)

    [ -d "$blob_dir" ] || return 1

    echo ">>> blob-mode: staging from $blob_dir"

    # Copy every file in prebuilt/<device>/ to BINARIES_DIR.
    # Preserve subdirectory structure (e.g. partitions/, modules/).
    cp -a "$blob_dir"/. "$BINARIES_DIR/"

    # If a kernel modules tarball is present, extract into TARGET_DIR/lib/modules.
    for tar in \
        "$BINARIES_DIR"/modules*.tar.gz \
        "$BINARIES_DIR"/modules*.tar.xz \
        "$BINARIES_DIR"/modules*.tar.zst \
        "$BINARIES_DIR"/modules*.tar.bz2 \
        "$BINARIES_DIR"/lib-modules*.tar.gz \
        "$BINARIES_DIR"/lib-modules*.tar.xz \
        "$BINARIES_DIR"/lib-modules*.tar.zst \
        "$BINARIES_DIR"/lib-modules*.tar.bz2; do
        [ -f "$tar" ] || continue
        echo ">>> blob-mode: extracting kernel modules from $(basename "$tar")"
        mkdir -p "$TARGET_DIR/lib/modules"
        tar -xf "$tar" -C "$TARGET_DIR/lib/modules/"
    done

    return 0
}

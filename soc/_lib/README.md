# soc/_lib — shared helpers for PanicOS post-image scripts

## post-image-blobs.sh — blob-staging build mode

For closed-source vendor SoCs (e.g. Allwinner A133 / TrimUI Brick) where upstream
does not publish kernel or U-Boot source, PanicOS supports a **blob-staging** build
mode.  Buildroot still builds the rootfs (BusyBox + systemd + panicos-firstboot), but
the kernel `Image` and U-Boot bootloader are pre-built binaries copied verbatim.

### Trigger

Blob mode is active for a device when the directory

```
soc/<soc>/<flavor>/prebuilt/<device>/
```

exists and is non-empty.  The helper functions detect this automatically.

### Expected layout inside `prebuilt/<device>/`

```
prebuilt/<device>/
  Image               # kernel image (or uImage)
  modules-<ver>.tar.gz  # optional — kernel modules tarball (extracted to TARGET_DIR/lib/modules/)
  boot.scr            # optional — U-Boot boot script
  u-boot-sunxi-with-spl.bin  # bootloader blob (name is SoC-specific)
  <any other bootloader blobs required by the device>
```

All files are copied verbatim into `BINARIES_DIR`.  Modules tarballs matching
`modules*.tar.{gz,xz,zst,bz2}` or `lib-modules*.tar.*` are additionally extracted
into `TARGET_DIR/lib/modules/`.

### Buildroot defconfig.fragment for blob-mode devices

Blob-mode devices must disable kernel and U-Boot compilation in their
`defconfig.fragment`:

```
# BR2_LINUX_KERNEL is not set
# BR2_TARGET_UBOOT is not set
```

Buildroot will then skip compiling those components entirely; the blobs are staged
by the post-image hook instead.

### Per-device post-image.sh usage

```bash
#!/usr/bin/env bash
set -euo pipefail

SOC=allwinner-a133
KERNEL_FLAVOR=vendor
DEVICE_NAME=trimui-brick

. "$BR2_EXTERNAL_PANICOS_PATH/soc/_lib/post-image-blobs.sh"

# Stage blobs (no-op if prebuilt dir is absent).
panicos_blob_mode_stage || true

# ... rest of device-specific post-image logic ...
```

### Population

The `prebuilt/<device>/` directory is populated by `scripts/sync-knulli.sh`
(Task 4).  It is intentionally not tracked in git (add to `.gitignore`); blobs
are fetched on demand from the vendor BSP release.

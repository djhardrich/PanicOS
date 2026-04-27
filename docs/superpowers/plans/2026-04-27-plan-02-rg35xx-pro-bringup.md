# Plan 02 — RG35XX Pro Bring-up (Allwinner H700, mainline kernel via ROCKNIX, multi-boot squashfs)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `make rg35xx-pro` produces a flashable disk image for the Anbernic RG35XX Pro:
- Boot FAT32 partition with U-Boot, kernel `Image` (initramfs embedded), DTBs, and `panicos-active.cfg` selecting which squashfs to boot
- "system" ext4 partition holding **one or more `.squashfs` images** the user can switch between by editing `panicos-active.cfg`
- Overlay ext4 partition that **auto-grows on first boot** to fill the SD card

The kernel embeds a small initramfs which loop-mounts the selected squashfs from the system partition and `switch_root`s into it.

**Architecture:** Linux 7.0.1 mainline + ROCKNIX H700 patches. U-Boot v2025.07-rc3 from upstream, ROCKNIX H700 patches. Custom initramfs CPIO (busybox + ~30-line init script) embedded in the kernel. A `panicos-firstboot.service` (in the main rootfs) grows the overlay partition + filesystem on first boot. **Vendor kernel flavor (via Knulli) is left as a Kconfig option but its `soc/allwinner-h700/vendor/` content lands in Plan 03 — building with `KERNEL=vendor` will fail until then.**

**Tech Stack:** Buildroot (existing harness), genimage, mksquashfs, busybox (static aarch64 — pre-built for the initramfs), systemd (in main rootfs), U-Boot v2025.07-rc3, Linux kernel 7.0.1.

**Scope discipline:** Only what's needed for `make rg35xx-pro FLAVOR=minimal` to produce a flashable, multi-boot-capable image with the **mainline** kernel. Booting on real hardware is the user's empirical verification step. Overlayfs mounting (`/etc`, `/var`, `/home` writable) is **deferred** to a later plan; this plan ships a writable overlay partition mounted at `/storage` and that's it.

---

## File Structure

| Path | Responsibility |
|---|---|
| `third_party/rocknix/` | Submodule — pinned SHA, source-of-truth for mainline H700 patches/config/DTS |
| `kconfig/socs.in` | New file. `choice PANICOS_SOC` + kernel-flavor choice |
| `kconfig/devices.in` | Modified. Add RG35XX Pro choice |
| `kconfig/sizes.in` | New file. Image partition size knobs |
| `soc/allwinner-h700/Config.in` | SoC parent — `PANICOS_SOC_ALLWINNER_H700` |
| `soc/allwinner-h700/mainline/Config.in` | Mainline-flavor Kconfig (minimal) |
| `soc/allwinner-h700/mainline/linux/source.mk` | LINUX_VERSION etc. (ref only — not consumed by Buildroot) |
| `soc/allwinner-h700/mainline/linux/linux.config.fragment` | Kernel config fragment (ROCKNIX `linux.aarch64.conf`) |
| `soc/allwinner-h700/mainline/linux/patches/` | Kernel patch series from ROCKNIX (H700 device + mainline-compat shims) |
| `soc/allwinner-h700/mainline/linux/dts/allwinner/` | All H700 DTS files from ROCKNIX |
| `soc/allwinner-h700/mainline/linux/defconfig.fragment` | Buildroot Kconfig: BR2_LINUX_KERNEL_*, kernel config fragments |
| `soc/allwinner-h700/mainline/linux/panicos-extras.config.fragment.in` | PanicOS additions (squashfs/loop builtin, initramfs source) — `@PANICOS_INITRAMFS_PATH@` token rendered at build time |
| `soc/allwinner-h700/mainline/uboot/source.mk` | U-Boot version + source (ref) |
| `soc/allwinner-h700/mainline/uboot/patches/` | U-Boot patches from ROCKNIX |
| `soc/allwinner-h700/mainline/uboot/defconfig.fragment` | Buildroot Kconfig: BR2_TARGET_UBOOT_* |
| `soc/allwinner-h700/source.manifest` | Records ROCKNIX submodule SHA + per-file origin paths |
| `board/anbernic/rg35xx-pro/Config.in` | Device choice. Defaults `PANICOS_KERNEL_FLAVOR_MAINLINE` |
| `board/anbernic/rg35xx-pro/defconfig.fragment` | Hostname, post-image hook |
| `board/anbernic/rg35xx-pro/genimage.cfg.in` | Templated partition layout (envsubst-rendered) |
| `board/anbernic/rg35xx-pro/post-image.sh` | Renders genimage.cfg, stages boot, copies squashfs, runs genimage, gzips |
| `board/anbernic/rg35xx-pro/panicos-active.cfg` | Default config copied to boot partition |
| `panicos-initramfs/init` | Init script — loop-mount + switch_root |
| `panicos-initramfs/skeleton/` | Empty mountpoint dirs |
| `scripts/build-initramfs.sh` | Assembles `output/panicos-initramfs.cpio.gz` |
| `package/Config.in` | New — sources panicos-firstboot Config.in |
| `package/panicos-firstboot/Config.in` | Selects firstboot package |
| `package/panicos-firstboot/panicos-firstboot.mk` | Buildroot package |
| `package/panicos-firstboot/panicos-firstboot.sh` | Overlay-grow script |
| `package/panicos-firstboot/panicos-firstboot.service` | systemd oneshot unit |
| `flavors/minimal/defconfig.fragment` | systemd, squashfs output, panicos-firstboot |

Modified:
- `Config.in` (root) — sources `package/Config.in`
- `kconfig/Config.in` — sources `socs.in` and `sizes.in`
- `Makefile` — `_build` runs `build-initramfs.sh` and renders panicos-extras fragment

---

## Task 1 — Add ROCKNIX submodule

**Files:**
- Create: `third_party/rocknix/` (submodule)
- Modified: `.gitmodules`

- [ ] **Step 1.1: Add ROCKNIX submodule pinned to a recent `next`-branch SHA**

```bash
cd ~/PanicOS
git submodule add -b next https://github.com/ROCKNIX/distribution.git third_party/rocknix
cd third_party/rocknix
PINNED_SHA=$(git rev-parse HEAD)
echo "Pinned ROCKNIX to: $PINNED_SHA"
cd ../..
```

Record `PINNED_SHA` for Task 4's manifest.

- [ ] **Step 1.2: Verify expected paths**

```bash
ls third_party/rocknix/projects/ROCKNIX/devices/H700/linux/dts/allwinner/ | head -5
ls third_party/rocknix/projects/ROCKNIX/devices/H700/patches/linux/ | head -5
ls third_party/rocknix/projects/ROCKNIX/packages/linux/patches/mainline/ | head -5
ls third_party/rocknix/projects/ROCKNIX/devices/H700/packages/u-boot/
```

All four directories should exist and contain files.

- [ ] **Step 1.3: Commit**

```bash
git add .gitmodules third_party/rocknix
git -c user.email=djhardrich@icloud.com -c user.name="djhardrich" \
    commit -m "Add ROCKNIX submodule pinned to current next branch"
```

---

## Task 2 — Translate ROCKNIX kernel + U-Boot source.mk

**Files:**
- `soc/allwinner-h700/mainline/linux/source.mk`
- `soc/allwinner-h700/mainline/uboot/source.mk`

These `.mk` files are documentation/reference only — Buildroot reads version & URL from defconfig fragments later. They exist so a future contributor can see, in one place, what version we tracked at last sync.

- [ ] **Step 2.1: Read ROCKNIX kernel package.mk values**

```bash
cat third_party/rocknix/projects/ROCKNIX/packages/linux/package.mk \
    | grep -E '^(PKG_NAME|PKG_VERSION|PKG_URL|PKG_SITE|PKG_SHA256)='
```

Reference: Linux 7.0.1 was released 2026-04-22, on kernel.org under `pub/linux/kernel/v7.x/`. ROCKNIX H700 always uses kernel.org mainline (no fork).

- [ ] **Step 2.2: Read ROCKNIX H700 U-Boot package.mk values**

```bash
cat third_party/rocknix/projects/ROCKNIX/devices/H700/packages/u-boot/package.mk \
    | grep -E '^(PKG_NAME|PKG_VERSION|PKG_URL|PKG_SITE|PKG_SHA256)='
```

- [ ] **Step 2.3: Write `soc/allwinner-h700/mainline/linux/source.mk`**

```make
# Linux mainline source for the Allwinner H700.
# Translated from third_party/rocknix/projects/ROCKNIX/packages/linux/package.mk
# at the pinned ROCKNIX SHA (see soc/allwinner-h700/source.manifest).
PANICOS_LINUX_VERSION := 7.0.1
PANICOS_LINUX_SITE := https://www.kernel.org/pub/linux/kernel/v7.x
PANICOS_LINUX_SOURCE_TARBALL := linux-$(PANICOS_LINUX_VERSION).tar.xz
# Verify hash before commit:
#   curl -s https://www.kernel.org/pub/linux/kernel/v7.x/sha256sums.asc | grep linux-7.0.1.tar.xz
PANICOS_LINUX_HASH := sha256:<verify-and-fill>
```

If ROCKNIX has bumped to a newer kernel by import time, use ROCKNIX's pinned values and note divergence in `source.manifest`.

- [ ] **Step 2.4: Write `soc/allwinner-h700/mainline/uboot/source.mk`**

```make
# U-Boot source for the Allwinner H700 mainline flavor.
PANICOS_UBOOT_VERSION := v2025.07-rc3
PANICOS_UBOOT_SITE := https://github.com/u-boot/u-boot/archive
PANICOS_UBOOT_SOURCE_TARBALL := $(PANICOS_UBOOT_VERSION).tar.gz
PANICOS_UBOOT_HASH := sha256:<verify-and-fill>
```

Compute U-Boot hash with `curl -L https://github.com/u-boot/u-boot/archive/v2025.07-rc3.tar.gz | sha256sum`.

- [ ] **Step 2.5: Commit**

```bash
git add soc/allwinner-h700/mainline/linux/source.mk \
        soc/allwinner-h700/mainline/uboot/source.mk
git -c user.email=djhardrich@icloud.com -c user.name="djhardrich" \
    commit -m "Record H700 mainline kernel and U-Boot source from ROCKNIX"
```

---

## Task 3 — Manually import H700 kernel patches, config fragment, and DTS files

**Files:** as listed in the structure table.

ROCKNIX applies kernel patches in this resolution order (per their `package.mk`):
1. `projects/ROCKNIX/packages/linux/patches/mainline/` — cross-device mainline-compat shims
2. `projects/ROCKNIX/devices/H700/patches/linux/` — H700 device-specific patches
3. `projects/ROCKNIX/packages/linux/patches/7.0/` — kernel-version-specific patches (Rust build fix etc.)

We import all three into `soc/allwinner-h700/mainline/linux/patches/` with numeric prefixes that preserve the apply order.

- [ ] **Step 3.1: Import mainline-compat shims first**

```bash
mkdir -p soc/allwinner-h700/mainline/linux/patches
i=100
for f in third_party/rocknix/projects/ROCKNIX/packages/linux/patches/mainline/*.patch; do
    cp "$f" "soc/allwinner-h700/mainline/linux/patches/$(printf '%04d' $i)-$(basename "$f")"
    i=$((i+1))
done
```

- [ ] **Step 3.2: Import H700 device-specific patches**

```bash
i=200
for f in third_party/rocknix/projects/ROCKNIX/devices/H700/patches/linux/*.patch; do
    cp "$f" "soc/allwinner-h700/mainline/linux/patches/$(printf '%04d' $i)-$(basename "$f")"
    i=$((i+1))
done
# Drop disabled patches.
rm -f soc/allwinner-h700/mainline/linux/patches/*.disabled
```

- [ ] **Step 3.3: Import 7.0-version-specific patches**

```bash
if [ -d third_party/rocknix/projects/ROCKNIX/packages/linux/patches/7.0 ]; then
    i=900
    for f in third_party/rocknix/projects/ROCKNIX/packages/linux/patches/7.0/*.patch; do
        cp "$f" "soc/allwinner-h700/mainline/linux/patches/$(printf '%04d' $i)-$(basename "$f")"
        i=$((i+1))
    done
fi
ls soc/allwinner-h700/mainline/linux/patches/ | wc -l
```

- [ ] **Step 3.4: Import the kernel config fragment**

```bash
cp third_party/rocknix/projects/ROCKNIX/devices/H700/linux/linux.aarch64.conf \
   soc/allwinner-h700/mainline/linux/linux.config.fragment
head -5 soc/allwinner-h700/mainline/linux/linux.config.fragment
```

- [ ] **Step 3.5: Import all H700 DTS files**

```bash
mkdir -p soc/allwinner-h700/mainline/linux/dts/allwinner
cp third_party/rocknix/projects/ROCKNIX/devices/H700/linux/dts/allwinner/*.dts \
   soc/allwinner-h700/mainline/linux/dts/allwinner/
ls soc/allwinner-h700/mainline/linux/dts/allwinner/ | grep rg35xx-pro
```

- [ ] **Step 3.6: Copy any local `.dtsi` includes**

```bash
grep -h '^#include' soc/allwinner-h700/mainline/linux/dts/allwinner/*.dts \
    | grep -oP '"[^"]+"' | sort -u
```

For each `.dtsi` resolving to a path under ROCKNIX's H700 DTS dir, copy it. Upstream-kernel `.dtsi` (e.g. `sun50i-h616.dtsi`) is part of the kernel tree — leave alone.

- [ ] **Step 3.7: Commit**

```bash
git add soc/allwinner-h700/mainline/linux/
git -c user.email=djhardrich@icloud.com -c user.name="djhardrich" \
    commit -m "Import H700 mainline kernel patches, config fragment, and DTS from ROCKNIX"
```

---

## Task 4 — Manually import H700 U-Boot, write source.manifest

**Files:**
- `soc/allwinner-h700/mainline/uboot/patches/`
- `soc/allwinner-h700/mainline/uboot/defconfig-name`
- `soc/allwinner-h700/source.manifest`

- [ ] **Step 4.1: Copy U-Boot patches**

```bash
mkdir -p soc/allwinner-h700/mainline/uboot/patches
cp third_party/rocknix/projects/ROCKNIX/devices/H700/packages/u-boot/patches/*.patch \
   soc/allwinner-h700/mainline/uboot/patches/
ls soc/allwinner-h700/mainline/uboot/patches/
```

- [ ] **Step 4.2: Record U-Boot defconfig name**

```bash
echo "anbernic_rg35xx_h700_defconfig" > soc/allwinner-h700/mainline/uboot/defconfig-name
```

- [ ] **Step 4.3: Write `soc/allwinner-h700/source.manifest`**

```yaml
rocknix_submodule_sha: "<PINNED_SHA from Task 1>"
rocknix_branch: "next"
imported_at: "<UTC timestamp from `date -u +%FT%TZ`>"
sources:
  - dest: mainline/linux/patches/0100-…/
    origin: third_party/rocknix/projects/ROCKNIX/packages/linux/patches/mainline/
  - dest: mainline/linux/patches/0200-…/
    origin: third_party/rocknix/projects/ROCKNIX/devices/H700/patches/linux/
    note: "*.disabled patches excluded"
  - dest: mainline/linux/patches/0900-…/
    origin: third_party/rocknix/projects/ROCKNIX/packages/linux/patches/7.0/
  - dest: mainline/linux/linux.config.fragment
    origin: third_party/rocknix/projects/ROCKNIX/devices/H700/linux/linux.aarch64.conf
  - dest: mainline/linux/dts/allwinner/
    origin: third_party/rocknix/projects/ROCKNIX/devices/H700/linux/dts/allwinner/
  - dest: mainline/uboot/patches/
    origin: third_party/rocknix/projects/ROCKNIX/devices/H700/packages/u-boot/patches/
  - dest: mainline/uboot/defconfig-name
    value: anbernic_rg35xx_h700_defconfig
```

- [ ] **Step 4.4: Commit**

```bash
git add soc/allwinner-h700/mainline/uboot/ soc/allwinner-h700/source.manifest
git -c user.email=djhardrich@icloud.com -c user.name="djhardrich" \
    commit -m "Import H700 mainline U-Boot from ROCKNIX, record source manifest"
```

---

## Task 5 — Wire SoC + device + size Kconfig

**Files (created):**
- `kconfig/socs.in`
- `kconfig/sizes.in`
- `soc/allwinner-h700/Config.in`
- `soc/allwinner-h700/mainline/Config.in`
- `board/anbernic/rg35xx-pro/Config.in`

**Files (modified):**
- `kconfig/Config.in`
- `kconfig/devices.in`

- [ ] **Step 5.1: Write `kconfig/socs.in`**

```
choice
	prompt "SoC family (selected by device)"
	default PANICOS_SOC_NONE

config PANICOS_SOC_NONE
	bool "(none — harness-smoke / generic)"

source "$BR2_EXTERNAL_PANICOS_PATH/soc/allwinner-h700/Config.in"

endchoice

choice
	prompt "Kernel flavor"
	default PANICOS_KERNEL_FLAVOR_MAINLINE
	depends on !PANICOS_SOC_NONE

config PANICOS_KERNEL_FLAVOR_MAINLINE
	bool "mainline"
	help
	  Linux mainline (kernel.org) + ROCKNIX patches.

config PANICOS_KERNEL_FLAVOR_VENDOR
	bool "vendor"
	help
	  Vendor BSP kernel (Knulli-imported). Requires Plan 03 to be
	  complete; building with this flavor will fail until the
	  soc/<soc>/vendor/ tree exists.

endchoice

config PANICOS_KERNEL_FLAVOR_NAME
	string
	default "mainline" if PANICOS_KERNEL_FLAVOR_MAINLINE
	default "vendor" if PANICOS_KERNEL_FLAVOR_VENDOR
```

- [ ] **Step 5.2: Write `kconfig/sizes.in`**

```
menu "Image partition sizes"
	depends on !PANICOS_SOC_NONE

config PANICOS_BOOT_PARTITION_SIZE_MB
	int "Boot partition size (MB)"
	default 256
	help
	  FAT32 boot partition. Holds U-Boot, kernel, DTBs, and
	  panicos-active.cfg. The initramfs is embedded in the kernel.

config PANICOS_SYSTEM_PARTITION_SIZE_MB
	int "System partition size (MB)"
	default 8192
	help
	  ext4 partition holding one or more .squashfs images. Selection
	  via panicos-active.cfg on the boot partition.

config PANICOS_OVERLAY_PARTITION_INITIAL_SIZE_MB
	int "Overlay partition initial size (MB)"
	default 64
	help
	  ext4 overlay partition, grown to fill free SD space on first
	  boot by the panicos-firstboot service.

endmenu
```

- [ ] **Step 5.3: Write `soc/allwinner-h700/Config.in`**

```
config PANICOS_SOC_ALLWINNER_H700
	bool "Allwinner H700 (sun50i-h700)"
	help
	  Allwinner H700. Used by the Anbernic RG35XX family (H, Plus,
	  Pro, 2024, SP), RG28XX, RG34XX, RG40XX, and RGCubeXX.

if PANICOS_SOC_ALLWINNER_H700
source "$BR2_EXTERNAL_PANICOS_PATH/soc/allwinner-h700/mainline/Config.in"
endif
```

- [ ] **Step 5.4: Write `soc/allwinner-h700/mainline/Config.in`**

```
# Mainline-flavor Kconfig for Allwinner H700.
# Empty — kernel/U-Boot wiring is handled via defconfig.fragment.
```

- [ ] **Step 5.5: Write `board/anbernic/rg35xx-pro/Config.in`**

```
config PANICOS_DEVICE_RG35XX_PRO
	bool "anbernic/rg35xx-pro (Allwinner H700)"
	select PANICOS_SOC_ALLWINNER_H700
	help
	  Anbernic RG35XX Pro. Allwinner H700. Default kernel flavor:
	  mainline (via ROCKNIX). Vendor flavor is reserved for Plan 03.
```

- [ ] **Step 5.6: Modify `kconfig/Config.in`**

```
menu "PanicOS"

source "$BR2_EXTERNAL_PANICOS_PATH/kconfig/devices.in"
source "$BR2_EXTERNAL_PANICOS_PATH/kconfig/socs.in"
source "$BR2_EXTERNAL_PANICOS_PATH/kconfig/flavors.in"
source "$BR2_EXTERNAL_PANICOS_PATH/kconfig/sizes.in"

endmenu
```

- [ ] **Step 5.7: Modify `kconfig/devices.in`**

```
choice
	prompt "Device"
	default PANICOS_DEVICE_HARNESS_SMOKE

source "$BR2_EXTERNAL_PANICOS_PATH/board/panicos/harness-smoke/Config.in"
source "$BR2_EXTERNAL_PANICOS_PATH/board/anbernic/rg35xx-pro/Config.in"

endchoice

config PANICOS_DEVICE_NAME
	string
	default "harness-smoke" if PANICOS_DEVICE_HARNESS_SMOKE
	default "rg35xx-pro" if PANICOS_DEVICE_RG35XX_PRO
```

- [ ] **Step 5.8: Commit**

```bash
git add kconfig/ soc/allwinner-h700/Config.in soc/allwinner-h700/mainline/Config.in \
        board/anbernic/rg35xx-pro/Config.in
git -c user.email=djhardrich@icloud.com -c user.name="djhardrich" \
    commit -m "Add Kconfig for Allwinner H700, RG35XX Pro, partition sizes"
```

---

## Task 6 — Initramfs build script + skeleton init

**Files (created):**
- `panicos-initramfs/init`
- `panicos-initramfs/skeleton/`
- `scripts/build-initramfs.sh`

- [ ] **Step 6.1: Write `panicos-initramfs/init`**

```sh
#!/bin/sh
# PanicOS initramfs — loop-mount the selected squashfs and switch_root.
#
# Reads /boot/panicos-active.cfg of the form:
#     IMAGE=panicos-stable.squashfs
# and mounts /system/$IMAGE.

set -e

PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH

mkdir -p /proc /sys /dev /run /boot /system /sysroot
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mount -t tmpfs tmpfs /run

panic() {
    echo "PANIC: $*" >&2
    echo "Dropping to shell. Type exit to reboot." >&2
    /bin/sh
    reboot -f
}

BOOT_DEV=/dev/mmcblk0p1
SYSTEM_DEV=/dev/mmcblk0p2

mount -o ro -t vfat "$BOOT_DEV" /boot \
    || panic "could not mount boot partition $BOOT_DEV"

IMAGE=panicos-rg35xx-pro-minimal.squashfs
if [ -f /boot/panicos-active.cfg ]; then
    # shellcheck disable=SC1091
    . /boot/panicos-active.cfg
fi
[ -n "$IMAGE" ] || panic "IMAGE not set in panicos-active.cfg"

echo ">>> PanicOS initramfs: booting $IMAGE"

mount -o ro -t ext4 "$SYSTEM_DEV" /system \
    || panic "could not mount system partition $SYSTEM_DEV"

[ -f "/system/$IMAGE" ] || panic "/system/$IMAGE not found"

LOOPDEV=$(losetup -f)
losetup -r "$LOOPDEV" "/system/$IMAGE" \
    || panic "losetup of /system/$IMAGE failed"

mount -o ro -t squashfs "$LOOPDEV" /sysroot \
    || panic "mount of squashfs failed"

for m in proc sys dev run boot system; do
    mkdir -p "/sysroot/$m"
    mount --move "/$m" "/sysroot/$m"
done

exec switch_root /sysroot /sbin/init
```

```bash
chmod +x panicos-initramfs/init
```

- [ ] **Step 6.2: Skeleton dirs**

```bash
mkdir -p panicos-initramfs/skeleton/{bin,sbin,proc,sys,dev,run,boot,system,sysroot}
```

- [ ] **Step 6.3: Write `scripts/build-initramfs.sh`**

```bash
#!/usr/bin/env bash
# Build a small initramfs CPIO for PanicOS.
# Output: $ROOT/output/panicos-initramfs.cpio.gz

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKEL="$ROOT/panicos-initramfs/skeleton"
INIT="$ROOT/panicos-initramfs/init"
OUT_DIR="$ROOT/output"
OUT="$OUT_DIR/panicos-initramfs.cpio.gz"
CACHE_DIR="$ROOT/.cache/initramfs"

BUSYBOX_VERSION=1.36.1
BUSYBOX_URL="https://busybox.net/downloads/binaries/${BUSYBOX_VERSION}-defconfig-multiarch-musl/busybox-aarch64"
BUSYBOX_SHA256=<verify-and-fill-at-execution>

mkdir -p "$OUT_DIR" "$CACHE_DIR"

BB="$CACHE_DIR/busybox-aarch64-$BUSYBOX_VERSION"
if [ ! -f "$BB" ]; then
    echo ">>> Downloading static busybox $BUSYBOX_VERSION"
    curl -fL -o "$BB.tmp" "$BUSYBOX_URL"
    actual=$(sha256sum "$BB.tmp" | awk '{print $1}')
    if [ "$actual" != "$BUSYBOX_SHA256" ]; then
        echo "busybox SHA256 mismatch: got $actual" >&2
        rm -f "$BB.tmp"
        exit 1
    fi
    chmod +x "$BB.tmp"
    mv "$BB.tmp" "$BB"
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
```

```bash
chmod +x scripts/build-initramfs.sh
```

The implementer must replace `<verify-and-fill-at-execution>` with the actual SHA256 (run once, observe the printed actual hash, paste it in). If `busybox.net` is unreachable, fall back to extracting `busybox-static` from a Debian package and document in commit.

- [ ] **Step 6.4: Smoke-test the script (host)**

```bash
./scripts/build-initramfs.sh
ls -lh output/panicos-initramfs.cpio.gz
gunzip -c output/panicos-initramfs.cpio.gz | cpio -t | head -20
```

Expected: ~1MB `.cpio.gz`; listing shows `init`, `bin/busybox`, the symlinks, mountpoint dirs.

- [ ] **Step 6.5: Commit**

```bash
git add panicos-initramfs/ scripts/build-initramfs.sh
git -c user.email=djhardrich@icloud.com -c user.name="djhardrich" \
    commit -m "Add panicos-initramfs build script and init"
```

---

## Task 7 — `panicos-firstboot` Buildroot package

**Files:**
- `package/Config.in` (new)
- `package/panicos-firstboot/Config.in`
- `package/panicos-firstboot/panicos-firstboot.mk`
- `package/panicos-firstboot/panicos-firstboot.sh`
- `package/panicos-firstboot/panicos-firstboot.service`
- `Config.in` (root, modified)

- [ ] **Step 7.1: Write `package/panicos-firstboot/panicos-firstboot.sh`**

```sh
#!/bin/sh
# PanicOS first-boot: grow the overlay partition + ext4 to fill the SD card.
# Self-disables after success.

set -eu

MARKER=/storage/.panicos-firstboot-done
[ -f "$MARKER" ] && exit 0

DISK=/dev/mmcblk0
OVERLAY_PART_NUM=3
OVERLAY_DEV="${DISK}p${OVERLAY_PART_NUM}"

echo ">>> panicos-firstboot: growing $OVERLAY_DEV"

sfdisk -d "$DISK" > /tmp/parts.dump
awk -v n="$OVERLAY_PART_NUM" -v disk="$DISK" '
    /^[^#]/ && $0 ~ "^"disk"p"n" :" {
        sub(/, size=[^,]+/, "");
    }
    { print }
' /tmp/parts.dump > /tmp/parts.new
sfdisk --no-reread "$DISK" < /tmp/parts.new
partprobe "$DISK" || true
resize2fs "$OVERLAY_DEV"

mkdir -p /storage
touch "$MARKER"

echo ">>> panicos-firstboot: done"
```

- [ ] **Step 7.2: systemd unit**

`package/panicos-firstboot/panicos-firstboot.service`:

```
[Unit]
Description=PanicOS first-boot: grow overlay partition
DefaultDependencies=no
After=systemd-remount-fs.service local-fs.target
Before=basic.target sysinit.target
ConditionPathExists=!/storage/.panicos-firstboot-done

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/mount -o rw /dev/mmcblk0p3 /storage
ExecStart=/usr/sbin/panicos-firstboot
StandardOutput=journal+console

[Install]
WantedBy=sysinit.target
```

- [ ] **Step 7.3: Buildroot package files**

`package/panicos-firstboot/Config.in`:

```
config BR2_PACKAGE_PANICOS_FIRSTBOOT
	bool "panicos-firstboot"
	depends on BR2_INIT_SYSTEMD
	help
	  PanicOS first-boot service: grows the overlay partition and
	  ext4 to fill remaining free space. Self-disabling.
```

`package/panicos-firstboot/panicos-firstboot.mk`:

```make
################################################################################
#
# panicos-firstboot
#
################################################################################

PANICOS_FIRSTBOOT_VERSION = 1.0
PANICOS_FIRSTBOOT_SITE = $(BR2_EXTERNAL_PANICOS_PATH)/package/panicos-firstboot
PANICOS_FIRSTBOOT_SITE_METHOD = local
PANICOS_FIRSTBOOT_LICENSE = GPL-2.0
PANICOS_FIRSTBOOT_DEPENDENCIES = util-linux e2fsprogs

define PANICOS_FIRSTBOOT_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(PANICOS_FIRSTBOOT_PKGDIR)/panicos-firstboot.sh \
		$(TARGET_DIR)/usr/sbin/panicos-firstboot
endef

define PANICOS_FIRSTBOOT_INSTALL_INIT_SYSTEMD
	$(INSTALL) -D -m 0644 $(PANICOS_FIRSTBOOT_PKGDIR)/panicos-firstboot.service \
		$(TARGET_DIR)/usr/lib/systemd/system/panicos-firstboot.service
	mkdir -p $(TARGET_DIR)/usr/lib/systemd/system/sysinit.target.wants
	ln -sf ../panicos-firstboot.service \
		$(TARGET_DIR)/usr/lib/systemd/system/sysinit.target.wants/panicos-firstboot.service
endef

$(eval $(generic-package))
```

- [ ] **Step 7.4: Wire `package/Config.in` and root `Config.in`**

`package/Config.in` (new):

```
menu "PanicOS packages"

source "$BR2_EXTERNAL_PANICOS_PATH/package/panicos-firstboot/Config.in"

endmenu
```

Append to root `Config.in`:

```
source "$BR2_EXTERNAL_PANICOS_PATH/package/Config.in"
```

(`external.mk` already wildcards `package/*/*.mk` from Plan 01.)

- [ ] **Step 7.5: Commit**

```bash
git add package/ Config.in
git -c user.email=djhardrich@icloud.com -c user.name="djhardrich" \
    commit -m "Add panicos-firstboot Buildroot package (overlay grow on first boot)"
```

---

## Task 8 — Defconfig fragments

**Files (created):**
- `soc/allwinner-h700/mainline/linux/defconfig.fragment`
- `soc/allwinner-h700/mainline/linux/panicos-extras.config.fragment.in`
- `soc/allwinner-h700/mainline/uboot/defconfig.fragment`
- `flavors/minimal/defconfig.fragment`

- [ ] **Step 8.1: Kernel defconfig fragment**

`soc/allwinner-h700/mainline/linux/defconfig.fragment`:

```
# Linux kernel — Allwinner H700 mainline flavor.

BR2_LINUX_KERNEL=y
BR2_LINUX_KERNEL_CUSTOM_VERSION=y
BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE="7.0.1"
# Buildroot constructs the kernel.org URL from the version string.

BR2_LINUX_KERNEL_PATCH="$(BR2_EXTERNAL_PANICOS_PATH)/soc/allwinner-h700/mainline/linux/patches"

BR2_LINUX_KERNEL_USE_DEFCONFIG=y
BR2_LINUX_KERNEL_DEFCONFIG="defconfig"
BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES="$(BR2_EXTERNAL_PANICOS_PATH)/soc/allwinner-h700/mainline/linux/linux.config.fragment $(O)/panicos-extras.config.fragment"

BR2_LINUX_KERNEL_DTS_SUPPORT=y
BR2_LINUX_KERNEL_CUSTOM_DTS_PATH="$(BR2_EXTERNAL_PANICOS_PATH)/soc/allwinner-h700/mainline/linux/dts/allwinner"

# Build all H700 DTBs. Implementer fills this list with every
# basename(.dts) under soc/.../dts/allwinner/ at execution time:
#   for d in soc/allwinner-h700/mainline/linux/dts/allwinner/*.dts; do
#       printf 'allwinner/%s ' "$(basename "$d" .dts)"
#   done
BR2_LINUX_KERNEL_INTREE_DTS_NAME="<fill-in: allwinner/sun50i-h700-anbernic-rg35xx-pro allwinner/sun50i-h700-anbernic-rg28xx ...>"

BR2_LINUX_KERNEL_GZIP=y
```

- [ ] **Step 8.2: PanicOS-extras kernel CONFIG fragment template**

`soc/allwinner-h700/mainline/linux/panicos-extras.config.fragment.in`:

```
# panicos-extras — additions on top of ROCKNIX's linux.aarch64.conf.
# Rendered to $O/panicos-extras.config.fragment by the Makefile, with
# @PANICOS_INITRAMFS_PATH@ substituted to an absolute path.

CONFIG_SQUASHFS=y
CONFIG_SQUASHFS_XATTR=y
CONFIG_SQUASHFS_ZLIB=y
CONFIG_SQUASHFS_GZIP=y
CONFIG_BLK_DEV_LOOP=y
CONFIG_EXT4_FS=y
CONFIG_VFAT_FS=y
CONFIG_NLS_CODEPAGE_437=y
CONFIG_NLS_ASCII=y
CONFIG_NLS_ISO8859_1=y
CONFIG_NLS_UTF8=y
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y
CONFIG_INITRAMFS_SOURCE="@PANICOS_INITRAMFS_PATH@"
CONFIG_INITRAMFS_COMPRESSION_GZIP=y
```

- [ ] **Step 8.3: U-Boot defconfig fragment**

`soc/allwinner-h700/mainline/uboot/defconfig.fragment`:

```
BR2_TARGET_UBOOT=y
BR2_TARGET_UBOOT_BOARDNAME="anbernic_rg35xx_h700"
BR2_TARGET_UBOOT_CUSTOM_VERSION=y
BR2_TARGET_UBOOT_CUSTOM_VERSION_VALUE="2025.07-rc3"
BR2_TARGET_UBOOT_CUSTOM_TARBALL=y
BR2_TARGET_UBOOT_CUSTOM_TARBALL_LOCATION="https://github.com/u-boot/u-boot/archive/v2025.07-rc3.tar.gz"
BR2_TARGET_UBOOT_PATCH="$(BR2_EXTERNAL_PANICOS_PATH)/soc/allwinner-h700/mainline/uboot/patches"
BR2_TARGET_UBOOT_USE_DEFCONFIG=y
BR2_TARGET_UBOOT_DEFCONFIG="anbernic_rg35xx_h700"
BR2_TARGET_UBOOT_FORMAT_BIN=y
BR2_TARGET_UBOOT_SPL=y
BR2_TARGET_UBOOT_SPL_NAME="spl/sunxi-spl.bin"
```

- [ ] **Step 8.4: Minimal flavor squashfs + firstboot**

`flavors/minimal/defconfig.fragment`:

```
# minimal flavor — BusyBox + systemd init.
BR2_INIT_SYSTEMD=y
BR2_TARGET_ROOTFS_SQUASHFS=y
BR2_TARGET_ROOTFS_SQUASHFS4_GZIP=y
BR2_PACKAGE_PANICOS_FIRSTBOOT=y
# Disable tar; not needed on real devices.
# BR2_TARGET_ROOTFS_TAR is not set
```

- [ ] **Step 8.5: Commit**

```bash
git add soc/allwinner-h700/mainline/linux/defconfig.fragment \
        soc/allwinner-h700/mainline/linux/panicos-extras.config.fragment.in \
        soc/allwinner-h700/mainline/uboot/defconfig.fragment \
        flavors/minimal/defconfig.fragment
git -c user.email=djhardrich@icloud.com -c user.name="djhardrich" \
    commit -m "Add defconfig fragments: H700 mainline kernel, U-Boot, squashfs flavor"
```

---

## Task 9 — RG35XX Pro device files

**Files:**
- `board/anbernic/rg35xx-pro/defconfig.fragment`
- `board/anbernic/rg35xx-pro/genimage.cfg.in`
- `board/anbernic/rg35xx-pro/post-image.sh`
- `board/anbernic/rg35xx-pro/panicos-active.cfg`

- [ ] **Step 9.1: Device defconfig fragment**

`board/anbernic/rg35xx-pro/defconfig.fragment`:

```
BR2_aarch64=y
BR2_TOOLCHAIN_BUILDROOT_GLIBC=y
BR2_TARGET_GENERIC_HOSTNAME="panicos-rg35xx-pro"
BR2_TARGET_GENERIC_ISSUE="PanicOS — RG35XX Pro"

BR2_ROOTFS_POST_IMAGE_SCRIPT="$(BR2_EXTERNAL_PANICOS_PATH)/board/anbernic/rg35xx-pro/post-image.sh"
BR2_ROOTFS_POST_SCRIPT_ARGS="$(BR2_EXTERNAL_PANICOS_PATH)/board/anbernic/rg35xx-pro/genimage.cfg.in"
```

- [ ] **Step 9.2: Default `panicos-active.cfg`**

```bash
cat > board/anbernic/rg35xx-pro/panicos-active.cfg <<'EOF'
# PanicOS active image selector.
# Edit IMAGE= to switch which squashfs the initramfs loads on next boot.
# The named file must exist in the system partition (/system/<IMAGE>).
IMAGE=panicos-rg35xx-pro-minimal.squashfs
EOF
```

- [ ] **Step 9.3: Genimage template**

`board/anbernic/rg35xx-pro/genimage.cfg.in`:

```
# RG35XX Pro disk image. Sizes from PANICOS_*_PARTITION_SIZE_MB Kconfigs,
# substituted at build time by post-image.sh via envsubst.

image boot.vfat {
	vfat {
		files = {
			"Image",
			"dtb.img",
			"dtbs",
			"boot.scr",
			"panicos-active.cfg",
		}
	}
	size = ${PANICOS_BOOT_PARTITION_SIZE_MB}M
}

image system.ext4 {
	ext4 {
		# Files added at image-staging time by post-image.sh.
	}
	size = ${PANICOS_SYSTEM_PARTITION_SIZE_MB}M
}

image overlay.ext4 {
	ext4 { }
	size = ${PANICOS_OVERLAY_PARTITION_INITIAL_SIZE_MB}M
}

image panicos-rg35xx-pro-minimal.img {
	hdimage {
	}

	partition u-boot {
		in-partition-table = "no"
		image = "u-boot-sunxi-with-spl.bin"
		offset = 8K
	}

	partition boot {
		partition-type = 0xC
		bootable = "true"
		image = "boot.vfat"
	}

	partition system {
		partition-type = 0x83
		image = "system.ext4"
	}

	partition overlay {
		partition-type = 0x83
		image = "overlay.ext4"
	}
}
```

- [ ] **Step 9.4: post-image.sh**

`board/anbernic/rg35xx-pro/post-image.sh`:

```bash
#!/usr/bin/env bash
# Buildroot post-image for Anbernic RG35XX Pro.
# $1 = genimage template path (BR2_ROOTFS_POST_SCRIPT_ARGS).
# CWD = BINARIES_DIR (output/<...>/images).

set -euo pipefail

GENIMAGE_TEMPLATE="$1"
BINARIES_DIR="$(pwd)"
SOC="allwinner-h700"
DEFAULT_DTB="sun50i-h700-anbernic-rg35xx-pro.dtb"

echo ">>> post-image: assembling RG35XX Pro disk image"

mkdir -p "$BINARIES_DIR/dtbs/$SOC"
cp "$BINARIES_DIR"/*.dtb "$BINARIES_DIR/dtbs/$SOC/" 2>/dev/null || true

cp "$BINARIES_DIR/dtbs/$SOC/$DEFAULT_DTB" "$BINARIES_DIR/dtb.img"

cp "$BR2_EXTERNAL_PANICOS_PATH/board/anbernic/rg35xx-pro/panicos-active.cfg" \
   "$BINARIES_DIR/panicos-active.cfg"

cat > "$BINARIES_DIR/boot.cmd" <<'EOF'
setenv bootargs "console=ttyS0,115200 panic=10"
fatload mmc 0:1 ${kernel_addr_r} Image
fatload mmc 0:1 ${fdt_addr_r} dtb.img
booti ${kernel_addr_r} - ${fdt_addr_r}
EOF
mkimage -A arm64 -O linux -T script -C none -d "$BINARIES_DIR/boot.cmd" \
    "$BINARIES_DIR/boot.scr" >/dev/null

# Stage the squashfs into a system staging dir for genimage to package.
SYSTEM_STAGE="$BINARIES_DIR/system-staging"
mkdir -p "$SYSTEM_STAGE"
GITREV="$(git -C "$BR2_EXTERNAL_PANICOS_PATH" describe --always --dirty 2>/dev/null || echo unknown)"
cp "$BINARIES_DIR/rootfs.squashfs" \
   "$SYSTEM_STAGE/panicos-rg35xx-pro-minimal.squashfs"

# Pull partition sizes from Buildroot's .config.
read_kconfig() {
    local key="$1" def="$2"
    grep "^${key}=" "$BR2_CONFIG" | head -1 | cut -d= -f2- | tr -d '"' || echo "$def"
}
export PANICOS_BOOT_PARTITION_SIZE_MB="$(read_kconfig PANICOS_BOOT_PARTITION_SIZE_MB 256)"
export PANICOS_SYSTEM_PARTITION_SIZE_MB="$(read_kconfig PANICOS_SYSTEM_PARTITION_SIZE_MB 8192)"
export PANICOS_OVERLAY_PARTITION_INITIAL_SIZE_MB="$(read_kconfig PANICOS_OVERLAY_PARTITION_INITIAL_SIZE_MB 64)"

GENIMAGE_CFG="$BINARIES_DIR/genimage.cfg"
envsubst < "$GENIMAGE_TEMPLATE" > "$GENIMAGE_CFG"

GENIMAGE_TMP="$BINARIES_DIR/genimage.tmp"
rm -rf "$GENIMAGE_TMP"
genimage \
    --rootpath "$SYSTEM_STAGE" \
    --tmppath "$GENIMAGE_TMP" \
    --inputpath "$BINARIES_DIR" \
    --outputpath "$BINARIES_DIR" \
    --config "$GENIMAGE_CFG"

gzip -f -9 "$BINARIES_DIR/panicos-rg35xx-pro-minimal.img"
mv "$BINARIES_DIR/panicos-rg35xx-pro-minimal.img.gz" \
   "$BINARIES_DIR/panicos-rg35xx-pro-minimal-$GITREV.img.gz"

echo ">>> post-image done: $BINARIES_DIR/panicos-rg35xx-pro-minimal-$GITREV.img.gz"
```

```bash
chmod +x board/anbernic/rg35xx-pro/post-image.sh
```

- [ ] **Step 9.5: Commit**

```bash
git add board/anbernic/rg35xx-pro/
git -c user.email=djhardrich@icloud.com -c user.name="djhardrich" \
    commit -m "Add RG35XX Pro device defconfig, genimage template, post-image"
```

---

## Task 10 — Update Dockerfile (genimage, u-boot-tools, gettext)

**Files (modified):** `docker/Dockerfile`

- [ ] **Step 10.1: Inspect**

```bash
grep -E '(u-boot-tools|gettext-base|libconfuse-dev)' docker/Dockerfile || echo "MISSING"
```

- [ ] **Step 10.2: Add `u-boot-tools`, `gettext-base`, build genimage from upstream**

Add `u-boot-tools` and `gettext-base` to the existing apt list. Append a separate RUN block for genimage (not packaged in Bookworm):

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
        autoconf automake libtool pkg-config libconfuse-dev \
    && rm -rf /var/lib/apt/lists/* \
    && git clone --depth 1 --branch v18 https://github.com/pengutronix/genimage /tmp/genimage \
    && cd /tmp/genimage \
    && ./autogen.sh && ./configure && make -j"$(nproc)" && make install \
    && rm -rf /tmp/genimage
```

Pin to genimage v18 (or check https://github.com/pengutronix/genimage/releases for the current latest tag at execution time, and document in commit message).

- [ ] **Step 10.3: Commit**

```bash
git add docker/Dockerfile
git -c user.email=djhardrich@icloud.com -c user.name="djhardrich" \
    commit -m "Add u-boot-tools, gettext-base, genimage to build container"
```

---

## Task 11 — SoC-aware Makefile dispatch + initramfs build hook

**Files (modified):** `Makefile`

- [ ] **Step 11.1: Replace the in-container section of the Makefile**

Below the existing `else  # ---- Inside container ---` line, replace through the matching `endif` with this:

```make
else
# ---- Inside container -----------------------------------------------------

BUILDROOT := $(PANICOS_ROOT)/third_party/buildroot
OUTPUT_BASE := $(PANICOS_ROOT)/output

.PHONY: list-devices
list-devices:
	@find board -mindepth 3 -maxdepth 3 -name Config.in \
		-printf '%h\n' | sed 's|^board/||' | sort

# Resolve <device> -> <soc> by reading board/*/<device>/Config.in.
define _device_soc
$(shell awk '/select PANICOS_SOC_/ { sub(/select PANICOS_SOC_/,""); gsub(/_/,"-"); print tolower($$0); exit }' \
    $(shell find board -mindepth 3 -maxdepth 3 -path "*/$(1)/Config.in" 2>/dev/null | head -1) 2>/dev/null)
endef

FLAVOR ?= minimal
KERNEL ?=

.PHONY: harness-smoke
harness-smoke:
	$(MAKE) _build DEVICE=harness-smoke

.PHONY: rg35xx-pro
rg35xx-pro:
	$(MAKE) _build DEVICE=rg35xx-pro

.PHONY: _build
_build:
	@test -n "$(DEVICE)" || (echo "DEVICE not set" >&2; exit 1)
	@SOC="$(call _device_soc,$(DEVICE))"; \
	K="$(KERNEL)"; \
	if [ -n "$$SOC" ] && [ -z "$$K" ]; then K="mainline"; fi; \
	OUT="$(OUTPUT_BASE)/$(DEVICE)-$(FLAVOR)$${K:+-$$K}"; \
	mkdir -p "$$OUT"; \
	if [ -n "$$SOC" ]; then \
		echo ">>> Building initramfs"; \
		$(PANICOS_ROOT)/scripts/build-initramfs.sh; \
		EXTRAS_IN="$(PANICOS_ROOT)/soc/$$SOC/$$K/linux/panicos-extras.config.fragment.in"; \
		EXTRAS_OUT="$$OUT/panicos-extras.config.fragment"; \
		if [ -f "$$EXTRAS_IN" ]; then \
			sed "s|@PANICOS_INITRAMFS_PATH@|$(PANICOS_ROOT)/output/panicos-initramfs.cpio.gz|" \
				"$$EXTRAS_IN" > "$$EXTRAS_OUT"; \
		fi; \
	fi; \
	scripts/gen-defconfig.sh \
		--device "$(DEVICE)" \
		--flavor "$(FLAVOR)" \
		$${SOC:+--soc "$$SOC"} \
		$${K:+--kernel "$$K"} \
		--output "$$OUT/.defconfig"; \
	$(MAKE) -C "$(BUILDROOT)" \
		BR2_EXTERNAL=$(PANICOS_ROOT) \
		O="$$OUT" \
		defconfig BR2_DEFCONFIG="$$OUT/.defconfig"; \
	$(MAKE) -C "$(BUILDROOT)" \
		BR2_EXTERNAL=$(PANICOS_ROOT) \
		O="$$OUT"

.PHONY: clean-%
clean-%:
	rm -rf $(OUTPUT_BASE)/$*-*

endif
```

The default kernel flavor is now **mainline** (was implicitly absent before).

- [ ] **Step 11.2: Verify `make harness-smoke` still passes**

```bash
make harness-smoke
ls -lh output/harness-smoke-minimal/images/rootfs.tar
```

- [ ] **Step 11.3: Commit**

```bash
git add Makefile
git -c user.email=djhardrich@icloud.com -c user.name="djhardrich" \
    commit -m "Wire SoC + kernel-flavor + initramfs build into _build target"
```

---

## Task 12 — End-to-end build of RG35XX Pro mainline image

Buildroot will: download Linux 7.0.1 + U-Boot v2025.07-rc3 + BusyBox, apply ROCKNIX patches, copy DTS files, compile kernel + 13+ DTBs (with embedded initramfs), build U-Boot, build systemd + BusyBox + panicos-firstboot, build squashfs, run post-image, produce `.img.gz`.

Expect 60–120 minutes on first run.

- [ ] **Step 12.1: Run the build**

```bash
set -o pipefail
make rg35xx-pro 2>&1 | tee /tmp/panicos-rg35xx-pro.log
echo "EXIT=${PIPESTATUS[0]}"
```

- [ ] **Step 12.2: Verify the artifact**

```bash
ls -lh output/rg35xx-pro-minimal-mainline/images/panicos-rg35xx-pro-minimal-*.img.gz
```

Expected: ~50–150 MB compressed.

- [ ] **Step 12.3: Inspect partition layout**

```bash
gunzip -k output/rg35xx-pro-minimal-mainline/images/panicos-rg35xx-pro-minimal-*.img.gz
IMG=$(ls output/rg35xx-pro-minimal-mainline/images/panicos-rg35xx-pro-minimal-*.img | head -1)
fdisk -l "$IMG" | head -20
```

Expected: 3 partitions (boot ~256MB FAT, system ~8GB ext4, overlay ~64MB ext4). U-Boot SPL at 8K offset.

- [ ] **Step 12.4: Inspect boot partition contents**

```bash
BOOT_OFFSET=$(fdisk -l "$IMG" | awk '$2 ~ /^[0-9]+$/ && /\*/ {print $2 * 512; exit}')
mkdir -p /tmp/panicos-boot-mnt
sudo mount -o loop,offset="$BOOT_OFFSET" "$IMG" /tmp/panicos-boot-mnt
ls /tmp/panicos-boot-mnt/
ls /tmp/panicos-boot-mnt/dtbs/allwinner-h700/ | head -10
cat /tmp/panicos-boot-mnt/panicos-active.cfg
sudo umount /tmp/panicos-boot-mnt
```

Expected: `Image`, `dtb.img`, `boot.scr`, `panicos-active.cfg`, `dtbs/allwinner-h700/` with all H700 DTBs (13+). `IMAGE=` in `panicos-active.cfg` matches a real squashfs name.

- [ ] **Step 12.5: Inspect system partition**

```bash
SYS_OFFSET=$(sfdisk -d "$IMG" | awk '/p2/ {for (i=1;i<=NF;i++) if ($i ~ /^start=/) {gsub(/start=/,"",$i); print $i*512; exit}}')
sudo mount -o loop,offset="$SYS_OFFSET" "$IMG" /tmp/panicos-boot-mnt
ls /tmp/panicos-boot-mnt/
file /tmp/panicos-boot-mnt/*.squashfs
sudo umount /tmp/panicos-boot-mnt
```

Expected: `panicos-rg35xx-pro-minimal.squashfs` present, valid squashfs.

- [ ] **Step 12.6: Verify embedded initramfs**

```bash
KERNEL_IMG=output/rg35xx-pro-minimal-mainline/build/linux-*/arch/arm64/boot/Image
strings "$KERNEL_IMG" | grep -i "panicos-active.cfg" | head -3
```

Expected: `panicos-active.cfg` string appears (proves the init script is embedded).

- [ ] **Step 12.7: No commit — verification only.**

---

## Done criteria for Plan 02

All true:

- [ ] `make harness-smoke` still passes
- [ ] `make rg35xx-pro` succeeds end-to-end on a clean clone
- [ ] `output/rg35xx-pro-minimal-mainline/images/panicos-rg35xx-pro-minimal-*.img.gz` exists, ~50–150 MB
- [ ] Image has 3 partitions (boot/system/overlay) plus U-Boot at 8KB
- [ ] Boot partition contains `Image`, `dtb.img`, `boot.scr`, `panicos-active.cfg`, `dtbs/allwinner-h700/` with all H700 DTBs
- [ ] System partition contains the squashfs file matching `panicos-active.cfg`'s `IMAGE=`
- [ ] Kernel `Image` has the panicos init script's strings embedded
- [ ] `panicos-firstboot` package is installed in the squashfs
- [ ] `soc/allwinner-h700/source.manifest` records the ROCKNIX submodule SHA
- [ ] All commits land cleanly on a `plan-02-rg35xx-pro` branch

When all checked, Plan 02 is complete.

---

## Out of scope (deferred)

- **Booting on real hardware** — empirical verification by user
- **Vendor kernel support (Knulli)** — Plan 03. Adds Knulli submodule + `soc/allwinner-h700/vendor/` import (BSP kernel 4.9.170, pre-built bootloader blobs).
- **Overlayfs mounting** of `/etc`, `/var`, `/home` — Plan 06 (with desktop flavor)
- **Automated importers** (`scripts/sync-rocknix.sh`, `scripts/sync-knulli.sh`) — folded into Plan 03 alongside the Knulli import
- **U-Boot boot menu** for image selection — currently file-based via `panicos-active.cfg`
- **Second device on same SoC family** — Plan 04 (RG353P/V on Rockchip RK3566 — different SoC, exercises the kernel-flavor matrix on its own hardware)
- **TrimUI Brick (Knulli-only device)** — Plan 04 / 05
- **Desktop flavor** — Plan 06
- **TUI wizard** — Plan 07

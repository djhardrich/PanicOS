# Plan 02 — RG35XX Pro Bring-up (Allwinner H700, vendor kernel)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `make rg35xx-pro FLAVOR=minimal` produces a flashable squashfs+overlay image for the Anbernic RG35XX Pro, using ROCKNIX's vendor H700 kernel + U-Boot. The image's boot partition contains every H700 DTB under `dtbs/allwinner-h700/`, plus the Pro's DTB as `dtb.img` at root.

**Architecture:** ROCKNIX is added as a pinned submodule. H700 kernel/U-Boot patches, the kernel config fragment, and all H700 DTS files are **manually imported** from the submodule into `soc/allwinner-h700/vendor/`. The `rg35xx-pro` board entry adds Buildroot Kconfig that selects the H700 SoC, sets the default DTB, and configures squashfs + ext4 overlay + FAT32 boot partitioning via genimage. No automated importer yet — that's Plan 03.

**Tech Stack:** Buildroot (existing harness), genimage, mksquashfs, dosfstools, U-Boot (vendor v2025.07-rc3 from ROCKNIX), Linux kernel (vendor — version per ROCKNIX `package.mk`).

**Scope discipline:** Only what's needed for `make rg35xx-pro FLAVOR=minimal` to produce a flashable image whose partition layout and boot files are correct. Booting on real hardware is the user's empirical verification step — out of scope for automated verification.

---

## File Structure

| Path | Responsibility |
|---|---|
| `third_party/rocknix/` | Submodule — pinned SHA, source-of-truth for SoC patches |
| `kconfig/socs.in` | New file. `choice PANICOS_SOC` + sources for each SoC |
| `kconfig/devices.in` | Modified. Add RG35XX Pro choice + sourcing |
| `soc/allwinner-h700/Config.in` | SoC parent Kconfig — owns `PANICOS_SOC_ALLWINNER_H700` |
| `soc/allwinner-h700/vendor/Config.in` | Vendor flavor Kconfig — selects kernel/uboot version vars |
| `soc/allwinner-h700/vendor/linux/source.mk` | Sets LINUX_VERSION / source / hash (translated from ROCKNIX) |
| `soc/allwinner-h700/vendor/linux/linux.config.fragment` | Kernel config fragment (copy of ROCKNIX `linux.aarch64.conf`) |
| `soc/allwinner-h700/vendor/linux/patches/` | Kernel patch series (copy of ROCKNIX H700 `patches/linux/`) |
| `soc/allwinner-h700/vendor/linux/dts/allwinner/` | All H700 DTS files (copy of ROCKNIX H700 DTS dir) |
| `soc/allwinner-h700/vendor/linux/defconfig.fragment` | Buildroot fragment: BR2_LINUX_KERNEL_* options pointing at the above |
| `soc/allwinner-h700/vendor/uboot/source.mk` | U-Boot version + source (translated from ROCKNIX) |
| `soc/allwinner-h700/vendor/uboot/patches/` | U-Boot patches (copy from ROCKNIX) |
| `soc/allwinner-h700/vendor/uboot/defconfig.fragment` | Buildroot fragment: BR2_TARGET_UBOOT_* |
| `soc/allwinner-h700/source.manifest` | Records ROCKNIX submodule SHA + per-file origin paths |
| `board/anbernic/rg35xx-pro/Config.in` | RG35XX Pro device choice — selects allwinner-h700 SoC |
| `board/anbernic/rg35xx-pro/defconfig.fragment` | Picks default DTB, kernel version, image options |
| `board/anbernic/rg35xx-pro/genimage.cfg` | Image partition layout (boot FAT32 + rootfs squashfs + overlay ext4) |
| `board/anbernic/rg35xx-pro/post-image.sh` | Stage `dtbs/allwinner-h700/`, `dtb.img`, `Image`, U-Boot artifacts on boot partition; invoke genimage; rename final `.img` to `panicos-<...>.img.gz` |
| `flavors/minimal/defconfig.fragment` | New file — sets `BR2_TARGET_ROOTFS_SQUASHFS=y` and disables tar (overrides harness-smoke's `BR2_TARGET_ROOTFS_TAR=y`) |

Modified files in the harness:
- `kconfig/Config.in` — source `socs.in`
- `kconfig/devices.in` — add Anbernic vendor source
- `Makefile` — no changes expected; it already supports `make <device>` via the wildcard

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
# Pin to the current tip of `next` so the import is reproducible.
PINNED_SHA=$(git rev-parse HEAD)
echo "Pinned ROCKNIX to: $PINNED_SHA"
cd ../..
```

Record `PINNED_SHA` — it goes into `soc/allwinner-h700/source.manifest` in Task 4.

- [ ] **Step 1.2: Verify the H700 device dir exists at the expected path**

```bash
ls third_party/rocknix/projects/ROCKNIX/devices/H700/linux/dts/allwinner/ | head -5
ls third_party/rocknix/projects/ROCKNIX/devices/H700/patches/linux/ | head -5
ls third_party/rocknix/projects/ROCKNIX/devices/H700/packages/u-boot/
```
Expected: DTS files visible, kernel patches visible, U-Boot package.mk and patches dir visible.

- [ ] **Step 1.3: Commit**

```bash
git add .gitmodules third_party/rocknix
git -c user.email=djhardrich@icloud.com -c user.name="djhardrich" \
    commit -m "Add ROCKNIX submodule pinned to current next branch"
```

---

## Task 2 — Translate ROCKNIX kernel + U-Boot package.mk into Buildroot vars

**Files (created in this task):**
- `soc/allwinner-h700/vendor/linux/source.mk` — small Make include for `LINUX_*` strings
- `soc/allwinner-h700/vendor/uboot/source.mk` — same for `UBOOT_*`

These files capture the kernel/U-Boot **source** (version, URL, hash) that ROCKNIX uses, in a format Plan 02's later tasks will reference. They're not consumed by Buildroot directly — Task 3's `defconfig.fragment` files reference these strings via copy-paste once you've established them here.

- [ ] **Step 2.1: Read ROCKNIX's kernel package.mk**

```bash
cat third_party/rocknix/projects/ROCKNIX/packages/linux/package.mk \
    | grep -E '^(PKG_NAME|PKG_VERSION|PKG_URL|PKG_SITE|PKG_SHA256)='
```

Note the `PKG_VERSION`, `PKG_URL`, and (if present) `PKG_SHA256`.

- [ ] **Step 2.2: Read ROCKNIX's H700 U-Boot package.mk**

```bash
cat third_party/rocknix/projects/ROCKNIX/devices/H700/packages/u-boot/package.mk \
    | grep -E '^(PKG_NAME|PKG_VERSION|PKG_URL|PKG_SITE|PKG_SHA256)='
```

- [ ] **Step 2.3: Determine which Buildroot mechanism applies**

For each (kernel and U-Boot), one of:
- **Tarball from kernel.org or a known site** → use Buildroot's `..._VERSION` + the upstream `..._SITE` (kernel.org `v7.x/`, denx, etc.)
- **GitHub release tarball** → `..._VERSION` + `..._SITE` pointing at the release tarball URL
- **Git checkout at a tag/SHA** → `..._VERSION` + `..._SITE` with `..._SITE_METHOD=git`

For reference at the time of this plan: Linux **7.0.1** (released 2026-04-22) is current stable on kernel.org under `pub/linux/kernel/v7.x/`. U-Boot **v2025.07-rc3** is a real GitHub release tarball. Both URLs in ROCKNIX's `package.mk` should resolve directly — no version translation needed. If either URL is unreachable at execution time, fall back to the closest stable release at kernel.org / U-Boot's GitHub releases and document the substitution in `source.manifest`.

- [ ] **Step 2.4: Write `soc/allwinner-h700/vendor/linux/source.mk`**

```make
# Linux kernel source for the Allwinner H700 vendor flavor.
# Translated from third_party/rocknix/projects/ROCKNIX/packages/linux/package.mk
# at the pinned ROCKNIX SHA recorded in source.manifest.
PANICOS_LINUX_VERSION := <fill-in>
PANICOS_LINUX_SITE := <fill-in>
PANICOS_LINUX_SITE_METHOD := <wget|git>
# Hash if applicable (tarball method only):
# PANICOS_LINUX_HASH := sha256:<...>
```

Replace the `<fill-in>` placeholders with the actual values. If the value is "unknown" or "must be hosted elsewhere," explain inline as a comment so the next task can pick up.

- [ ] **Step 2.5: Write `soc/allwinner-h700/vendor/uboot/source.mk`**

Same pattern for U-Boot.

- [ ] **Step 2.6: Commit**

```bash
git add soc/allwinner-h700/vendor/linux/source.mk soc/allwinner-h700/vendor/uboot/source.mk
git -c user.email=djhardrich@icloud.com -c user.name="djhardrich" \
    commit -m "Record H700 vendor kernel and U-Boot source from ROCKNIX"
```

---

## Task 3 — Manually import H700 kernel patches, config fragment, and DTS files

**Files (created):**
- `soc/allwinner-h700/vendor/linux/patches/` (directory of `.patch` files)
- `soc/allwinner-h700/vendor/linux/linux.config.fragment`
- `soc/allwinner-h700/vendor/linux/dts/allwinner/` (directory of `.dts` files)

- [ ] **Step 3.1: Copy kernel patches from ROCKNIX**

```bash
mkdir -p soc/allwinner-h700/vendor/linux/patches
cp third_party/rocknix/projects/ROCKNIX/devices/H700/patches/linux/*.patch \
   soc/allwinner-h700/vendor/linux/patches/
# Skip files with .disabled extension; ROCKNIX leaves disabled patches in-tree:
rm -f soc/allwinner-h700/vendor/linux/patches/*.disabled
ls soc/allwinner-h700/vendor/linux/patches/ | wc -l
```

Expected: a non-zero count (around 23–24 patches as of ROCKNIX `next` at this writing).

- [ ] **Step 3.2: Copy the kernel config fragment**

```bash
cp third_party/rocknix/projects/ROCKNIX/devices/H700/linux/linux.aarch64.conf \
   soc/allwinner-h700/vendor/linux/linux.config.fragment
head -5 soc/allwinner-h700/vendor/linux/linux.config.fragment
```

Expected: `CONFIG_*=y` lines, kernel-config-fragment style.

- [ ] **Step 3.3: Copy all H700 DTS files**

```bash
mkdir -p soc/allwinner-h700/vendor/linux/dts/allwinner
cp third_party/rocknix/projects/ROCKNIX/devices/H700/linux/dts/allwinner/*.dts \
   soc/allwinner-h700/vendor/linux/dts/allwinner/
# Confirm RG35XX Pro is among them:
ls soc/allwinner-h700/vendor/linux/dts/allwinner/ | grep rg35xx-pro
```

Expected: `sun50i-h700-anbernic-rg35xx-pro.dts` is one of the listed files.

- [ ] **Step 3.4: Copy any DTS includes referenced**

DTS files often `#include` other `.dtsi` headers. Verify which are referenced from any of the copied `.dts` files and copy them too:

```bash
grep -h '^#include' soc/allwinner-h700/vendor/linux/dts/allwinner/*.dts \
    | grep -oP '"[^"]+"' | sort -u
```

For any `.dtsi` listed that lives at `third_party/rocknix/projects/ROCKNIX/devices/H700/linux/dts/allwinner/`, copy it alongside the `.dts` files. (DTS files referenced from upstream kernel paths e.g. `sun50i-h616.dtsi` are already in the kernel tree — leave those alone.)

- [ ] **Step 3.5: Commit**

```bash
git add soc/allwinner-h700/vendor/linux/
git -c user.email=djhardrich@icloud.com -c user.name="djhardrich" \
    commit -m "Import H700 vendor kernel patches, config fragment, and DTS from ROCKNIX"
```

---

## Task 4 — Manually import H700 U-Boot from ROCKNIX, write source.manifest

**Files (created):**
- `soc/allwinner-h700/vendor/uboot/patches/` (directory)
- `soc/allwinner-h700/vendor/uboot/defconfig-name` (one-line file: the U-Boot defconfig name)
- `soc/allwinner-h700/source.manifest` (provenance)

- [ ] **Step 4.1: Copy U-Boot patches**

```bash
mkdir -p soc/allwinner-h700/vendor/uboot/patches
cp third_party/rocknix/projects/ROCKNIX/devices/H700/packages/u-boot/patches/*.patch \
   soc/allwinner-h700/vendor/uboot/patches/
ls soc/allwinner-h700/vendor/uboot/patches/
```

Expected: at least `anbernic_rg35xx_h700_defconfig.patch`.

- [ ] **Step 4.2: Record U-Boot defconfig name**

ROCKNIX uses `anbernic_rg35xx_h700_defconfig` for all H700 variants (per the device map). Save this:

```bash
echo "anbernic_rg35xx_h700_defconfig" > soc/allwinner-h700/vendor/uboot/defconfig-name
```

- [ ] **Step 4.3: Write `soc/allwinner-h700/source.manifest`**

```yaml
# Provenance for files imported into soc/allwinner-h700/.
# Regenerated by scripts/sync-rocknix.sh in Plan 03.
rocknix_submodule_sha: "<the PINNED_SHA from Task 1>"
rocknix_branch: "next"
imported_at: "<UTC timestamp from `date -u +%FT%TZ`>"
sources:
  - dest: linux/patches/
    origin: third_party/rocknix/projects/ROCKNIX/devices/H700/patches/linux/
    note: "*.disabled patches excluded"
  - dest: linux/linux.config.fragment
    origin: third_party/rocknix/projects/ROCKNIX/devices/H700/linux/linux.aarch64.conf
  - dest: linux/dts/allwinner/
    origin: third_party/rocknix/projects/ROCKNIX/devices/H700/linux/dts/allwinner/
  - dest: vendor/uboot/patches/
    origin: third_party/rocknix/projects/ROCKNIX/devices/H700/packages/u-boot/patches/
  - dest: vendor/uboot/defconfig-name
    origin: "ROCKNIX devices/H700/packages/u-boot/package.mk PKG_BUILD_FLAGS"
    value: "anbernic_rg35xx_h700_defconfig"
```

Replace `<the PINNED_SHA from Task 1>` and `<UTC timestamp>` with real values.

- [ ] **Step 4.4: Commit**

```bash
git add soc/allwinner-h700/vendor/uboot/ soc/allwinner-h700/source.manifest
git -c user.email=djhardrich@icloud.com -c user.name="djhardrich" \
    commit -m "Import H700 vendor U-Boot from ROCKNIX, record source manifest"
```

---

## Task 5 — Wire SoC + device Kconfig

**Files (created):**
- `kconfig/socs.in`
- `soc/allwinner-h700/Config.in`
- `soc/allwinner-h700/vendor/Config.in`
- `board/anbernic/rg35xx-pro/Config.in`

**Files (modified):**
- `kconfig/Config.in` — source the new SoC Kconfig
- `kconfig/devices.in` — source the RG35XX Pro device

- [ ] **Step 5.1: Write `kconfig/socs.in`**

```
choice
	prompt "SoC family (selected by device)"
	default PANICOS_SOC_NONE

config PANICOS_SOC_NONE
	bool "(none — harness-smoke / generic)"
	help
	  Default for non-real devices. Selects no SoC-specific patches.

source "$BR2_EXTERNAL_PANICOS_PATH/soc/allwinner-h700/Config.in"

endchoice

choice
	prompt "Kernel flavor"
	default PANICOS_KERNEL_FLAVOR_VENDOR
	depends on !PANICOS_SOC_NONE

config PANICOS_KERNEL_FLAVOR_VENDOR
	bool "vendor"

config PANICOS_KERNEL_FLAVOR_MAINLINE
	bool "mainline"

endchoice

config PANICOS_KERNEL_FLAVOR_NAME
	string
	default "vendor" if PANICOS_KERNEL_FLAVOR_VENDOR
	default "mainline" if PANICOS_KERNEL_FLAVOR_MAINLINE
```

- [ ] **Step 5.2: Write `soc/allwinner-h700/Config.in`**

```
config PANICOS_SOC_ALLWINNER_H700
	bool "Allwinner H700 (sun50i-h700)"
	help
	  Allwinner H700 (a.k.a. sun50i-h700). Used by the Anbernic
	  RG35XX family (H, Plus, Pro, 2024, SP), RG28XX, RG34XX,
	  RG40XX, and RGCubeXX.

if PANICOS_SOC_ALLWINNER_H700
source "$BR2_EXTERNAL_PANICOS_PATH/soc/allwinner-h700/vendor/Config.in"
endif
```

- [ ] **Step 5.3: Write `soc/allwinner-h700/vendor/Config.in`**

```
# Vendor-flavor-specific Kconfig for Allwinner H700.
# Currently empty — kernel/U-Boot wiring is handled via defconfig.fragment
# files referenced from the device's defconfig.fragment.
```

(Yes, intentionally minimal. Kconfig nesting is for selection; Buildroot
defconfig fragments do the actual wiring.)

- [ ] **Step 5.4: Write `board/anbernic/rg35xx-pro/Config.in`**

```
config PANICOS_DEVICE_RG35XX_PRO
	bool "anbernic/rg35xx-pro (Allwinner H700, vendor)"
	select PANICOS_SOC_ALLWINNER_H700
	help
	  Anbernic RG35XX Pro. Allwinner H700 with vendor kernel.
```

- [ ] **Step 5.5: Modify `kconfig/Config.in` to source `socs.in`**

Update so it reads:

```
menu "PanicOS"

source "$BR2_EXTERNAL_PANICOS_PATH/kconfig/devices.in"
source "$BR2_EXTERNAL_PANICOS_PATH/kconfig/socs.in"
source "$BR2_EXTERNAL_PANICOS_PATH/kconfig/flavors.in"

endmenu
```

- [ ] **Step 5.6: Modify `kconfig/devices.in` to add the RG35XX Pro choice**

The existing file looks like:

```
choice
	prompt "Device"
	default PANICOS_DEVICE_HARNESS_SMOKE

source "$BR2_EXTERNAL_PANICOS_PATH/board/panicos/harness-smoke/Config.in"

endchoice

config PANICOS_DEVICE_NAME
	string
	default "harness-smoke" if PANICOS_DEVICE_HARNESS_SMOKE
```

Update to:

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

- [ ] **Step 5.7: Commit**

```bash
git add kconfig/ soc/allwinner-h700/Config.in soc/allwinner-h700/vendor/Config.in \
        board/anbernic/rg35xx-pro/Config.in
git -c user.email=djhardrich@icloud.com -c user.name="djhardrich" \
    commit -m "Add Kconfig for Allwinner H700 SoC and RG35XX Pro device"
```

---

## Task 6 — Defconfig fragments for H700 vendor kernel & U-Boot, and minimal flavor squashfs

**Files (created):**
- `soc/allwinner-h700/vendor/linux/defconfig.fragment`
- `soc/allwinner-h700/vendor/uboot/defconfig.fragment`
- `flavors/minimal/defconfig.fragment` (new)

These are the actual Buildroot Kconfig snippets that `gen-defconfig.sh` concatenates.

- [ ] **Step 6.1: Compose the kernel `defconfig.fragment`**

`soc/allwinner-h700/vendor/linux/defconfig.fragment`:

```
# Linux kernel — Allwinner H700 vendor flavor.
# Source values come from soc/allwinner-h700/vendor/linux/source.mk;
# Buildroot can't read .mk includes directly from a defconfig, so we duplicate
# the resolved values here. Update both files together when bumping versions.

BR2_LINUX_KERNEL=y
BR2_LINUX_KERNEL_CUSTOM_VERSION=y
BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE="<fill-in from source.mk>"
# If ROCKNIX uses a custom tarball / git source, switch to:
#   BR2_LINUX_KERNEL_CUSTOM_TARBALL=y
#   BR2_LINUX_KERNEL_CUSTOM_TARBALL_LOCATION="..."
# (The implementer should pick whichever matches the resolution from Task 2.)

# ROCKNIX patch series imported under soc/.../patches/.
BR2_LINUX_KERNEL_PATCH="$(BR2_EXTERNAL_PANICOS_PATH)/soc/allwinner-h700/vendor/linux/patches"

# Use Buildroot's in-tree defconfig as base, plus our fragment on top.
BR2_LINUX_KERNEL_USE_DEFCONFIG=y
BR2_LINUX_KERNEL_DEFCONFIG="defconfig"
BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES="$(BR2_EXTERNAL_PANICOS_PATH)/soc/allwinner-h700/vendor/linux/linux.config.fragment"

# Custom DTS files copied in pre-build.
BR2_LINUX_KERNEL_DTS_SUPPORT=y
BR2_LINUX_KERNEL_CUSTOM_DTS_PATH="$(BR2_EXTERNAL_PANICOS_PATH)/soc/allwinner-h700/vendor/linux/dts/allwinner"
# Build EVERY H700 DTB so the boot partition's dtbs/allwinner-h700/ folder is complete.
# The implementer must populate the full list at build time. Use:
#   for d in soc/allwinner-h700/vendor/linux/dts/allwinner/*.dts; do
#       printf 'allwinner/%s ' "$(basename "$d" .dts)"
#   done
# and place the result inside the quotes below.
BR2_LINUX_KERNEL_INTREE_DTS_NAME="<fill-in: space-separated list of allwinner/<basename> entries>"

# Compress kernel image (smaller boot partition).
BR2_LINUX_KERNEL_GZIP=y
```

The implementer must replace both `<fill-in>` markers using actual values resolved in Task 2 / from the DTS file list, then verify Buildroot accepts the fragment via `make rg35xx-pro FLAVOR=minimal` in Task 8.

- [ ] **Step 6.2: Compose the U-Boot `defconfig.fragment`**

`soc/allwinner-h700/vendor/uboot/defconfig.fragment`:

```
BR2_TARGET_UBOOT=y
BR2_TARGET_UBOOT_BOARDNAME="anbernic_rg35xx_h700"
BR2_TARGET_UBOOT_CUSTOM_VERSION=y
BR2_TARGET_UBOOT_CUSTOM_VERSION_VALUE="<fill-in from source.mk>"
BR2_TARGET_UBOOT_PATCH="$(BR2_EXTERNAL_PANICOS_PATH)/soc/allwinner-h700/vendor/uboot/patches"
BR2_TARGET_UBOOT_USE_CUSTOM_CONFIG=n
BR2_TARGET_UBOOT_USE_DEFCONFIG=y
BR2_TARGET_UBOOT_DEFCONFIG="anbernic_rg35xx_h700"
# Allwinner sunxi-fel/U-Boot SPL outputs
BR2_TARGET_UBOOT_FORMAT_BIN=y
BR2_TARGET_UBOOT_SPL=y
BR2_TARGET_UBOOT_SPL_NAME="spl/sunxi-spl.bin"
```

If ROCKNIX uses a different version mechanism (git clone vs tarball), replace the `BR2_TARGET_UBOOT_CUSTOM_VERSION*` lines with `BR2_TARGET_UBOOT_CUSTOM_TARBALL*` or `_GIT*` per Buildroot docs.

- [ ] **Step 6.3: Update `flavors/minimal/defconfig.fragment` to use squashfs**

`flavors/minimal/defconfig.fragment`:

```
# minimal flavor — BusyBox + init only.
# Real-device images use squashfs (read-only) + ext4 overlay (writable).
BR2_TARGET_ROOTFS_SQUASHFS=y
BR2_TARGET_ROOTFS_SQUASHFS4_GZIP=y
# Disable tar (was used for harness-smoke; not needed on real devices).
# BR2_TARGET_ROOTFS_TAR is not set
```

(Note: the harness-smoke device's own `defconfig.fragment` keeps `BR2_TARGET_ROOTFS_TAR=y` — gen-defconfig.sh concatenates fragments, and Buildroot defconfig honors the **last** assignment, which means flavor fragment can override device fragment. Verify ordering in Task 8 if harness-smoke breaks; if it does, move the squashfs flag from the flavor to the rg35xx-pro device fragment.)

- [ ] **Step 6.4: Commit**

```bash
git add soc/allwinner-h700/vendor/linux/defconfig.fragment \
        soc/allwinner-h700/vendor/uboot/defconfig.fragment \
        flavors/minimal/defconfig.fragment
git -c user.email=djhardrich@icloud.com -c user.name="djhardrich" \
    commit -m "Add defconfig fragments for H700 vendor kernel/U-Boot and squashfs minimal"
```

---

## Task 7 — RG35XX Pro device defconfig, genimage.cfg, post-image.sh

**Files (created):**
- `board/anbernic/rg35xx-pro/defconfig.fragment`
- `board/anbernic/rg35xx-pro/genimage.cfg`
- `board/anbernic/rg35xx-pro/post-image.sh` (executable)

- [ ] **Step 7.1: Write `board/anbernic/rg35xx-pro/defconfig.fragment`**

```
# Anbernic RG35XX Pro — device-level defconfig fragment.
# SoC-level wiring (kernel/U-Boot) lives under soc/allwinner-h700/vendor/.

BR2_aarch64=y
BR2_TOOLCHAIN_BUILDROOT_GLIBC=y
BR2_TARGET_GENERIC_HOSTNAME="panicos-rg35xx-pro"
BR2_TARGET_GENERIC_ISSUE="PanicOS — RG35XX Pro"

# Pull the H700 vendor kernel + U-Boot defconfig fragments.
# (gen-defconfig.sh handles this when --soc + --kernel are passed; the build
# wrapper Makefile adds those flags automatically based on the selected SoC.)

# Image generation: genimage.cfg + post-image.sh assemble the final disk image.
BR2_ROOTFS_POST_IMAGE_SCRIPT="$(BR2_EXTERNAL_PANICOS_PATH)/board/anbernic/rg35xx-pro/post-image.sh"
BR2_ROOTFS_POST_SCRIPT_ARGS="$(BR2_EXTERNAL_PANICOS_PATH)/board/anbernic/rg35xx-pro/genimage.cfg"
```

The default DTB filename (`sun50i-h700-anbernic-rg35xx-pro.dtb`) is hard-coded in `post-image.sh` as `DEFAULT_DTB="..."` for now. A later plan can introduce a Kconfig string for it if more devices want to share the same post-image script.

- [ ] **Step 7.2: Write `board/anbernic/rg35xx-pro/genimage.cfg`**

```
# Image layout for Anbernic RG35XX Pro.
# Partition table:
#   - boot:    FAT32, 256 MB         (kernel Image, U-Boot artifacts, dtbs/, dtb.img)
#   - rootfs:  squashfs, ~size        (read-only PanicOS root)
#   - overlay: ext4, 1 GB             (persistent /etc, /var, user data)

image boot.vfat {
	vfat {
		files = {
			"Image",
			"dtb.img",
			"dtbs",
			"boot.scr",
		}
	}
	size = 256M
}

image overlay.ext4 {
	ext4 {
		# Empty; resize2fs grows it on first boot to fill the SD card.
	}
	size = 1024M
}

image panicos-rg35xx-pro-minimal.img {
	hdimage {
	}

	# U-Boot SPL on Allwinner sun50i-h700 lives at offset 8 KB on the
	# raw image, preceding the partition table.
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

	partition rootfs {
		partition-type = 0x83
		image = "rootfs.squashfs"
	}

	partition overlay {
		partition-type = 0x83
		image = "overlay.ext4"
	}
}
```

The `rootfs.squashfs` referenced under the `rootfs` partition is produced by Buildroot in `BINARIES_DIR` (because the minimal flavor sets `BR2_TARGET_ROOTFS_SQUASHFS=y` in Task 6.3). genimage picks it up directly — no separate `image rootfs.squashfs { ... }` block is needed in genimage.cfg.

- [ ] **Step 7.3: Write `board/anbernic/rg35xx-pro/post-image.sh`**

```bash
#!/usr/bin/env bash
# Buildroot post-image script for Anbernic RG35XX Pro.
#
# Buildroot calls this with $1 = path passed in BR2_ROOTFS_POST_SCRIPT_ARGS
# (our genimage.cfg path) and the working directory set to BINARIES_DIR
# (output/<...>/images).

set -euo pipefail

GENIMAGE_CFG="$1"
BINARIES_DIR="$(pwd)"
SOC="allwinner-h700"
DEFAULT_DTB="sun50i-h700-anbernic-rg35xx-pro.dtb"

echo ">>> post-image: assembling RG35XX Pro boot partition contents"

# 1. Stage all H700 DTBs into a dtbs/<soc>/ folder.
mkdir -p "$BINARIES_DIR/dtbs/$SOC"
cp "$BINARIES_DIR"/*.dtb "$BINARIES_DIR/dtbs/$SOC/" 2>/dev/null || true

# 2. The default DTB also gets copied to the boot partition root as dtb.img.
cp "$BINARIES_DIR/dtbs/$SOC/$DEFAULT_DTB" "$BINARIES_DIR/dtb.img"

# 3. Generate a minimal U-Boot boot script.
cat > "$BINARIES_DIR/boot.cmd" <<'EOF'
setenv bootargs "console=ttyS0,115200 root=/dev/mmcblk0p2 ro panic=10 rw rootwait"
fatload mmc 0:1 ${kernel_addr_r} Image
fatload mmc 0:1 ${fdt_addr_r} dtb.img
booti ${kernel_addr_r} - ${fdt_addr_r}
EOF
mkimage -A arm64 -O linux -T script -C none -d "$BINARIES_DIR/boot.cmd" "$BINARIES_DIR/boot.scr" >/dev/null

# 4. Build the image.
genimage \
	--rootpath "$TARGET_DIR" \
	--tmppath "$BINARIES_DIR/genimage.tmp" \
	--inputpath "$BINARIES_DIR" \
	--outputpath "$BINARIES_DIR" \
	--config "$GENIMAGE_CFG"

# 5. Compress the final image.
gzip -f -9 "$BINARIES_DIR/panicos-rg35xx-pro-minimal.img"

# 6. Final filename with git-describe.
GITREV="$(git -C "$BR2_EXTERNAL_PANICOS_PATH" describe --always --dirty 2>/dev/null || echo "unknown")"
mv "$BINARIES_DIR/panicos-rg35xx-pro-minimal.img.gz" \
   "$BINARIES_DIR/panicos-rg35xx-pro-minimal-$GITREV.img.gz"

echo ">>> post-image done: $BINARIES_DIR/panicos-rg35xx-pro-minimal-$GITREV.img.gz"
```

Make it executable:

```bash
chmod +x board/anbernic/rg35xx-pro/post-image.sh
```

Notes:
- `TARGET_DIR` and `BR2_EXTERNAL_PANICOS_PATH` are exported by Buildroot during post-image.
- The script depends on `mkimage` (in `u-boot-tools`) and `genimage`. `genimage` will be installed automatically by Buildroot when the device's defconfig requests it; `mkimage` should already be in our Docker image (`apt install u-boot-tools`). **Update the Dockerfile in this same task** to install `u-boot-tools` if it's not already there, and rebuild the container image.

- [ ] **Step 7.4: Add `u-boot-tools` and `genimage` to the Dockerfile if missing**

Inspect:
```bash
grep -E '(u-boot-tools|genimage)' docker/Dockerfile || echo "MISSING"
```

If `MISSING`, edit `docker/Dockerfile`'s `apt-get install` block to include both packages. Note: `genimage` is **not** packaged in Debian Bookworm. Install it from upstream by adding a small build step to the Dockerfile, e.g.:

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
        u-boot-tools libconfuse-dev pkg-config autoconf automake libtool \
    && rm -rf /var/lib/apt/lists/* \
    && git clone --depth 1 --branch v18 https://github.com/pengutronix/genimage /tmp/genimage \
    && cd /tmp/genimage \
    && ./autogen.sh && ./configure && make -j"$(nproc)" && make install \
    && rm -rf /tmp/genimage
```

(Pin to genimage v18 or whatever's current at execution time — verify on https://github.com/pengutronix/genimage/releases. Adjust the apt deps if `autogen.sh` complains.)

After updating the Dockerfile, re-build the image: `docker build -t panicos-build:dev -f docker/Dockerfile .` (or just rely on the Makefile's content-hash rebuild).

- [ ] **Step 7.5: Commit**

```bash
git add board/anbernic/rg35xx-pro/ docker/Dockerfile
git -c user.email=djhardrich@icloud.com -c user.name="djhardrich" \
    commit -m "Add RG35XX Pro device defconfig, genimage layout, and post-image script"
```

---

## Task 8 — Wire SoC-aware build dispatch in the Makefile

The current Makefile invokes `gen-defconfig.sh --device <X> --flavor <Y>`. To use SoC fragments and kernel-flavor fragments, the Makefile needs to pass `--soc <X>` and `--kernel <Y>` when the device declares them.

**Files (modified):**
- `Makefile`

- [ ] **Step 8.1: Determine the device's SoC + default kernel from its `Config.in`**

The implementer adds a small helper rule (inside the container branch of the Makefile) that resolves a device name to its SoC + default kernel by grepping the device's `Config.in`. Concrete approach:

Add to the in-container section of the Makefile, before `_build`:

```make
# Resolve <device> -> <soc> by reading board/*/<device>/Config.in.
# Looks for `select PANICOS_SOC_<NAME>` and emits a hyphenated SoC name
# that maps to the soc/<soc>/ directory.
define _device_soc
$(shell awk '/select PANICOS_SOC_/ { sub(/select PANICOS_SOC_/,""); gsub(/_/,"-"); print tolower($$0); exit }' \
        $(shell find board -mindepth 3 -maxdepth 3 -path "*/$(1)/Config.in" 2>/dev/null | head -1))
endef
```

And update `_build` to:

```make
.PHONY: _build
_build:
	@test -n "$(DEVICE)" || (echo "DEVICE not set" >&2; exit 1)
	@SOC="$(call _device_soc,$(DEVICE))"; \
	K="$(KERNEL)"; \
	if [ -n "$$SOC" ] && [ -z "$$K" ]; then K="vendor"; fi; \
	OUT="$(OUTPUT_BASE)/$(DEVICE)-$(FLAVOR)$${K:+-$$K}"; \
	mkdir -p "$$OUT"; \
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
```

And add a top-level convenience:

```make
.PHONY: rg35xx-pro
rg35xx-pro:
	$(MAKE) _build DEVICE=rg35xx-pro
```

(Yes, named per-device aliases are fine for a small device count; we'll outgrow them later.)

- [ ] **Step 8.2: Verify Kconfig changes don't break harness-smoke**

```bash
make harness-smoke
```

Should still produce `output/harness-smoke-minimal/images/rootfs.tar` (verifying the new Kconfig didn't break the harness path).

- [ ] **Step 8.3: Commit**

```bash
git add Makefile
git -c user.email=djhardrich@icloud.com -c user.name="djhardrich" \
    commit -m "Pass SoC + kernel flavor to gen-defconfig.sh based on selected device"
```

---

## Task 9 — End-to-end build of RG35XX Pro minimal image

This is the real validation. Buildroot will: download the kernel source, apply 24 patches, copy the DTS files, compile the kernel + 13+ DTBs, build U-Boot, build BusyBox, build squashfs, run our post-image, produce a flashable `.img.gz`.

Expect 60–120 minutes on first run depending on host and kernel build size.

- [ ] **Step 9.1: Run the build**

```bash
make rg35xx-pro
```

Or in background:

```bash
set -o pipefail
make rg35xx-pro 2>&1 | tee /tmp/panicos-rg35xx-pro.log
echo "EXIT=${PIPESTATUS[0]}"
```

- [ ] **Step 9.2: Verify the artifact**

```bash
ls -lh output/rg35xx-pro-minimal-vendor/images/panicos-rg35xx-pro-minimal-*.img.gz
```

Expected: a `.img.gz` on the order of ~50–100 MB.

- [ ] **Step 9.3: Inspect the image's partition layout**

```bash
gunzip -k output/rg35xx-pro-minimal-vendor/images/panicos-rg35xx-pro-minimal-*.img.gz
IMG=output/rg35xx-pro-minimal-vendor/images/panicos-rg35xx-pro-minimal-*.img
fdisk -l "$IMG" | head -20
```

Expected: 3 partitions — boot (FAT, ~256MB), rootfs (Linux/squashfs), overlay (ext4, ~1GB). U-Boot offset at 8KB.

- [ ] **Step 9.4: Inspect the boot partition contents**

```bash
# Find boot partition offset
BOOT_OFFSET=$(fdisk -l "$IMG" | awk '/boot/ {print $2 * 512; exit}')
mkdir -p /tmp/panicos-boot-mnt
sudo mount -o loop,offset="$BOOT_OFFSET" "$IMG" /tmp/panicos-boot-mnt
ls /tmp/panicos-boot-mnt/
ls /tmp/panicos-boot-mnt/dtbs/allwinner-h700/ | head -10
sudo umount /tmp/panicos-boot-mnt
```

Expected files at boot root: `Image`, `dtb.img`, `boot.scr`, `dtbs/`. Inside `dtbs/allwinner-h700/`: every `sun50i-h700-anbernic-*.dtb` (13+ entries).

- [ ] **Step 9.5: Inspect the rootfs partition is a valid squashfs**

```bash
ROOTFS_OFFSET=$(fdisk -l "$IMG" | awk '$1 ~ /\.img.*p2/ {print $2 * 512; exit}')
# Or read partition 2 from sfdisk:
sfdisk -d "$IMG" | awk '/start=/ && NR==3 {print $0}'
file output/rg35xx-pro-minimal-vendor/images/rootfs.squashfs
```

Expected: `rootfs.squashfs: Squashfs filesystem, little endian, version 4.0, ...`

- [ ] **Step 9.6: No commit — Task 9 only verifies.**

If any verification fails, fix the underlying task (likely Task 6 fragment values or Task 7 post-image) and re-run `make rg35xx-pro`. Commit fixes; do not retroactively edit prior task commits.

---

## Done criteria for Plan 02

All true:

- [ ] `make harness-smoke` still passes (didn't break the harness)
- [ ] `make rg35xx-pro` succeeds end-to-end on a clean clone (post-Plan-01 commits)
- [ ] `output/rg35xx-pro-minimal-vendor/images/panicos-rg35xx-pro-minimal-*.img.gz` exists, ~50–100 MB
- [ ] Image has 3 partitions (boot/rootfs/overlay) plus U-Boot at 8KB offset
- [ ] Boot partition contains `Image`, `dtb.img`, `boot.scr`, and a `dtbs/allwinner-h700/` folder with all H700 DTBs
- [ ] `dtb.img` matches `dtbs/allwinner-h700/sun50i-h700-anbernic-rg35xx-pro.dtb` (use `cmp`)
- [ ] `rootfs.squashfs` is a valid squashfs filesystem
- [ ] `soc/allwinner-h700/source.manifest` records the ROCKNIX submodule SHA used for the import
- [ ] All commits land cleanly on a `plan-02-rg35xx-pro` branch; no uncommitted files

When all checked, Plan 02 is complete and Plan 03 (ROCKNIX & Knulli importers — automating what Plan 02 did manually) is the next plan.

## Out of scope (explicitly deferred)

- Booting the image on real hardware — empirical verification by user
- Automated ROCKNIX importer (Plan 03)
- Automated Knulli importer (Plan 03)
- Mainline-kernel-flavor support for H700 (no complete mainline H700 BSP exists yet — vendor only for now)
- A second device on the same SoC family — Plan 04 (RG353P/V)
- A device on a different vendor — Plan 04 / 05
- Userspace beyond minimal (desktop flavor lands in Plan 06)
- TUI wizard (Plan 07)

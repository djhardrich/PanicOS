# Plan 04 — RG353P/V (Rockchip RK3566) + TrimUI Brick (Allwinner A133)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Two new devices, two new SoC families, exercising every architectural axis on hardware that isn't H700:

1. **Anbernic RG353P/V** — Rockchip RK3566 — both **mainline** (via ROCKNIX) and **vendor** (via Knulli or ROCKNIX's vendor track if it has one). Validates the kernel-flavor matrix on a non-Allwinner SoC. Built **from source**, like the H700 flow.
2. **TrimUI Brick** — Allwinner A133 — **vendor blobs only**. **CRITICAL CONSTRAINT:** TrimUI does NOT release source for their A133 U-Boot or kernel (despite GPL obligations; they're in China and refuse requests). Knulli has the same constraint and ships TrimUI's pre-built bootloader + kernel binaries verbatim. PanicOS must do the same for any A133 device — build from source is not possible. Validates a **third build mode** (blob-staging) in our harness.

**Architecture:** Reuses Plans 01–03 for the from-source path. **Adds blob-staging build mode** for closed-source vendor SoCs (A133 today; potentially Qualcomm devices in the far future). The blob mode bypasses Buildroot's kernel and U-Boot packages entirely; only the rootfs (BusyBox + systemd + panicos-firstboot) is built by Buildroot. post-image.sh stages the imported blobs (kernel `Image`, DTBs, U-Boot blobs, kernel modules) into the boot partition + rootfs.

**Tech Stack:** Buildroot harness (existing), `scripts/sync-rocknix.sh` + `scripts/sync-knulli.sh` (Plan 03 importers, generalized to take a SoC argument).

**Scope discipline:** Only the two devices named. No additional H700 hardware, no additional Rockchip or Allwinner devices in this plan. Importers gain a SoC argument so they can be used per-SoC instead of being H700-hardcoded.

---

## File Structure

| Path | Responsibility |
|---|---|
| `kconfig/socs.in` | Modified — add `PANICOS_SOC_ROCKCHIP_RK3566`, `PANICOS_SOC_ALLWINNER_A133` |
| `soc/rockchip-rk3566/` | New SoC tree (mainline + vendor) |
| `soc/rockchip-rk3566/uboot/` | RK3566-specific U-Boot config (different from H700) |
| `soc/rockchip-rk3566/mainline/linux/` | Imported via sync-rocknix.sh (RK3566 path) |
| `soc/rockchip-rk3566/vendor/linux/` | Imported via sync-knulli.sh (vendor BSP) |
| `soc/allwinner-a133/` | New SoC tree (vendor only) |
| `soc/allwinner-a133/uboot/` | A133-specific U-Boot config |
| `soc/allwinner-a133/vendor/linux/` | Imported from Knulli |
| `board/anbernic/rg353p/` | Device entry (and rg353v sibling if they share enough) |
| `board/trimui/brick/` | Device entry |
| `scripts/sync-rocknix.sh` | Modified — accept `--soc <name>` to scope the import |
| `scripts/sync-knulli.sh` | Modified — accept `--soc <name>` |
| `Makefile` | Add `rg353p`, `rg353v`, `trimui-brick` device targets |

---

## Task 1 — Generalize importers to take a `--soc` argument

The Plan 03 importers are H700-hardcoded. Before adding new SoCs, refactor them to:
- Read SoC name from `--soc <name>` (e.g. `--soc rockchip-rk3566`)
- Walk SoC-specific paths in ROCKNIX/Knulli derived from that name
- Update only that SoC's manifest section

A small mapping table inside each importer (or a config file under `scripts/imports/<soc>.conf`) defines per-SoC source paths.

- [ ] **Step 1.1: Add `scripts/imports/<soc>.conf` per-SoC configs**

`scripts/imports/allwinner-h700.conf`:
```bash
ROCKNIX_DEVICE_DIR="projects/ROCKNIX/devices/H700"
ROCKNIX_PATCHES_VERSION_DIR="projects/ROCKNIX/packages/linux/patches/7.0"
KNULLI_BOARD_DIR="board/batocera/allwinner/h700"
KNULLI_DEFCONFIG="configs/knulli-h700_defconfig"
```

`scripts/imports/rockchip-rk3566.conf`:
```bash
ROCKNIX_DEVICE_DIR="projects/ROCKNIX/devices/RK3566"
ROCKNIX_PATCHES_VERSION_DIR="projects/ROCKNIX/packages/linux/patches/<TBD; verify ROCKNIX's RK3566 kernel version>"
KNULLI_BOARD_DIR="board/batocera/rockchip/rk3566"
KNULLI_DEFCONFIG="configs/knulli-rk3566_defconfig"
```

`scripts/imports/allwinner-a133.conf`:
```bash
ROCKNIX_DEVICE_DIR=""    # ROCKNIX doesn't support A133; importer skips ROCKNIX
KNULLI_BOARD_DIR="board/batocera/allwinner/a133"
KNULLI_DEFCONFIG="configs/knulli-a133_defconfig"
```

The implementer verifies actual paths in each upstream repo at execution time and adjusts.

- [ ] **Step 1.2: Refactor sync-rocknix.sh and sync-knulli.sh to source the conf**

```bash
#!/usr/bin/env bash
SOC=""; FORCE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --soc) SOC="$2"; shift 2 ;;
        --force) FORCE=1; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done
[ -n "$SOC" ] || { echo "--soc <name> required" >&2; exit 2; }

CONF="$ROOT/scripts/imports/$SOC.conf"
[ -f "$CONF" ] || { echo "no import config for SoC: $SOC" >&2; exit 1; }
. "$CONF"

# ... use $ROCKNIX_DEVICE_DIR etc. instead of hardcoded paths ...
```

- [ ] **Step 1.3: Re-run sync-rocknix.sh / sync-knulli.sh for H700 to verify no regression**

```bash
./scripts/sync-rocknix.sh --soc allwinner-h700
./scripts/sync-knulli.sh --soc allwinner-h700
git status --short
```

Expected: minimal or no diff (we're regenerating what's already there).

- [ ] **Step 1.4: Commit**

```bash
git add scripts/sync-rocknix.sh scripts/sync-knulli.sh scripts/imports/
git -c user.email=djhardrich@icloud.com -c user.name="djhardrich" \
    commit -m "Importers: take --soc argument; per-SoC config in scripts/imports/"
```

---

## Task 2 — Reconnaissance: ROCKNIX RK3566 + Knulli RK3566 + Knulli A133

This is investigation. The implementer reads the upstream repos via WebFetch or local submodule walks to map structure. **Do not assume**.

- [ ] **Step 2.1: ROCKNIX RK3566 structure**

```bash
ls third_party/rocknix/projects/ROCKNIX/devices/RK3566/
cat third_party/rocknix/projects/ROCKNIX/devices/RK3566/options 2>/dev/null
grep -E "PKG_VERSION|PKG_URL" third_party/rocknix/projects/ROCKNIX/devices/RK3566/packages/u-boot/package.mk 2>/dev/null
```

Record: kernel version (likely 6.x or 7.x mainline, but verify), DTS file list, U-Boot source + version.

ROCKNIX's RK3566 may use a Rockchip-specific kernel (e.g. armbian's rk-6.1-rkr3 fork) — earlier reconnaissance showed `RK3588 → armbian fork`, RK3566 may also use a fork. **Verify and use whatever ROCKNIX actually uses.**

- [ ] **Step 2.2: Knulli RK3566 structure**

```bash
ls third_party/knulli/board/batocera/rockchip/rk3566/ 2>/dev/null
cat third_party/knulli/configs/knulli-rk3566_defconfig 2>/dev/null
```

- [ ] **Step 2.3: Knulli A133 structure**

```bash
ls third_party/knulli/board/batocera/allwinner/a133/ 2>/dev/null
cat third_party/knulli/configs/knulli-a133_defconfig 2>/dev/null
```

Find the TrimUI Brick device dir specifically.

- [ ] **Step 2.4: Write recon notes**

`soc/rockchip-rk3566/RECON.md` and `soc/allwinner-a133/RECON.md` with the verified facts. Commit.

---

## Task 3 — Import RK3566 SoC content + add RG353P device

Mostly mechanical: apply the importers, then create a board entry.

- [ ] **Step 3.1: Run the importers**

```bash
./scripts/sync-rocknix.sh --soc rockchip-rk3566
./scripts/sync-knulli.sh --soc rockchip-rk3566
```

- [ ] **Step 3.2: Write `soc/rockchip-rk3566/{Config.in,uboot/...,mainline/...,vendor/...}` defconfig fragments**

Mirror the H700 layout. RK3566 has a different U-Boot board (`rk3566` boardname class — verify the actual defconfig name in U-Boot's `configs/`), different TF-A platform (`rk3566`, `rk3568`, etc.), and different DTS organization (`arch/arm64/boot/dts/rockchip/`).

The kernel vs U-Boot details surface during execution; the implementer fills them in based on Task 2's recon.

- [ ] **Step 3.3: Add `board/anbernic/rg353p/` (and rg353v if simply a sibling)**

Mirror the rg35xx-pro layout. The default DTB is whatever Anbernic RG353P uses (likely `rk3566-anbernic-rg353p.dtb`). Image partition layout same as H700 (boot 256M FAT + system 8G ext4 + overlay 64M ext4) with RK3566's bootloader at the appropriate offset (NOT 8K — Rockchip uses different SPL load addresses; verify).

- [ ] **Step 3.4: Build mainline**

```bash
make rg353p KERNEL=mainline
ls -lh output/rg353p-minimal-mainline/images/panicos-rg353p-minimal-*.img.gz
```

- [ ] **Step 3.5: Build vendor**

```bash
make rg353p KERNEL=vendor
ls -lh output/rg353p-minimal-vendor/images/panicos-rg353p-minimal-*.img.gz
```

- [ ] **Step 3.6: User flashes both, reports**

---

## Task 4 — A133 / TrimUI Brick (BLOB-STAGING build mode)

A133 is **closed-source** — no kernel source, no U-Boot source. Any device on this SoC uses TrimUI/Allwinner's pre-built blobs verbatim. Knulli does this; we do this.

This task introduces a **new build mode** in our harness: blob-staging. It bypasses Buildroot's kernel and U-Boot builds entirely; only the rootfs (BusyBox + systemd + panicos-firstboot) is compiled by Buildroot. The boot partition gets the imported blobs verbatim.

### Sub-task 4a: Reconnaissance

- [ ] **Step 4a.1: Map Knulli's A133 / TrimUI Brick assets**

```bash
# Find the Knulli device dir for TrimUI Brick (might be under a sub-vendor)
find third_party/knulli/board -type d -name "*brick*" -o -name "*trimui*" 2>/dev/null
find third_party/knulli/board -type d -name "*a133*" 2>/dev/null
ls third_party/knulli/configs/ | grep -iE "a133|trimui"
```

Find: device dir, defconfig, partition blob locations.

- [ ] **Step 4a.2: Inventory the blobs**

For TrimUI Brick's device dir, list every file:

```bash
find third_party/knulli/board/.../trimui-brick -type f
file third_party/knulli/board/.../trimui-brick/partitions/*
```

Expected (typical Allwinner BSP layout):
- `boot0.img` — SPL (Allwinner-signed)
- `boot_package.fex` — packed U-Boot + ATF + DTB blob
- `env.img` — U-Boot environment
- Possibly `Image` (pre-built kernel) somewhere — find it
- Possibly modules tarball

Check the Knulli `genimage.cfg` to learn where on disk each blob goes.

- [ ] **Step 4a.3: Determine the kernel binary's location**

Knulli/Batocera might:
- Ship a pre-built `Image` for A133 in their tree
- Or download a kernel image at build time from somewhere
- Or extract one from a vendor stock firmware image

Check their build scripts; record findings in `soc/allwinner-a133/RECON.md`.

If the kernel binary is NOT in Knulli's tree, this task is **blocked** until we find a source for it (TrimUI's vendor download, Knulli's CI artifacts, etc.). Document the blocker.

- [ ] **Step 4a.4: Commit recon**

```bash
git add soc/allwinner-a133/RECON.md
git -c user.email=djhardrich@icloud.com -c user.name="djhardrich" \
    commit -m "Recon: TrimUI Brick A133 blob-staging requirements"
```

### Sub-task 4b: Blob-staging build mode in harness

- [ ] **Step 4b.1: Define `from-blobs` build-mode convention**

Convention: if `soc/<soc>/<flavor>/prebuilt/` exists and contains files, the build is in **blob-staging mode**. The harness:
- Skips kernel build (`# BR2_LINUX_KERNEL is not set`)
- Skips U-Boot build (`# BR2_TARGET_UBOOT is not set`, `# BR2_TARGET_ARM_TRUSTED_FIRMWARE is not set`)
- Still builds rootfs.squashfs as normal
- post-image.sh detects the `prebuilt/` dir and stages from there instead of from `output/.../images/`

- [ ] **Step 4b.2: Update Makefile or post-image.sh to dispatch on prebuilt-dir presence**

In `_build` or in board-specific post-image.sh, check whether `$BR2_EXTERNAL_PANICOS_PATH/soc/$SOC/$KERNEL/prebuilt/` exists; if so, the build is blob-staging.

- [ ] **Step 4b.3: Generic blob-staging post-image helper**

Add a shared helper at `soc/_lib/post-image-blobs.sh` that the per-device post-image.sh sources. It:
- Copies blobs from `soc/<soc>/<flavor>/prebuilt/<device>/` into `BINARIES_DIR`
- Generates the boot.scr appropriate for blob-mode boot (likely a specific ATF/SPL handoff sequence — A133 needs investigation)
- Stages kernel `Image` into the boot partition

### Sub-task 4c: Import A133 blobs

- [ ] **Step 4c.1: Knulli importer extension**

Update `scripts/sync-knulli.sh` to also copy binary blobs (not just config files) for SoCs marked "blob-staging" in `scripts/imports/<soc>.conf`. Add a `BLOB_DEVICES=( ... )` list and per-device blob-file globs.

```bash
# Example for allwinner-a133.conf
BLOB_DEVICES=( "trimui-brick" )
BLOB_FILES=( "partitions/*" "Image" "modules.tar.*" )
```

- [ ] **Step 4c.2: Run the importer**

```bash
./scripts/sync-knulli.sh --soc allwinner-a133
ls soc/allwinner-a133/vendor/prebuilt/trimui-brick/
```

### Sub-task 4d: Add TrimUI Brick device entry

- [ ] **Step 4d.1: `board/trimui/brick/`**

Same pattern as RG35XX Pro but with a vendor-blob-mode `defconfig.fragment`:

```
BR2_aarch64=y
BR2_TOOLCHAIN_BUILDROOT_GLIBC=y
BR2_TARGET_GENERIC_HOSTNAME="panicos-trimui-brick"
BR2_TARGET_GENERIC_ISSUE="PanicOS — TrimUI Brick"

# Blob mode — kernel and U-Boot are pre-built, not compiled.
# BR2_LINUX_KERNEL is not set
# BR2_TARGET_UBOOT is not set
# BR2_TARGET_ARM_TRUSTED_FIRMWARE is not set

BR2_ROOTFS_POST_IMAGE_SCRIPT="$(BR2_EXTERNAL_PANICOS_PATH)/board/trimui/brick/post-image.sh"
BR2_ROOTFS_POST_SCRIPT_ARGS="$(BR2_EXTERNAL_PANICOS_PATH)/board/trimui/brick/genimage.cfg.in"
```

The post-image.sh sources `soc/_lib/post-image-blobs.sh` and stages the prebuilt blobs.

### Sub-task 4e: Build + verify

- [ ] **Step 4e.1: Build**

```bash
make trimui-brick
ls -lh output/trimui-brick-minimal-vendor/images/panicos-trimui-brick-minimal-*.img.gz
```

Expected: produces flashable image. Smaller than H700 builds (no kernel compilation).

- [ ] **Step 4e.2: User flashes and reports**

If the device boots, we've validated blob-mode end-to-end. If not, debug the boot blob layout (offsets, signatures, etc.).

---

## Done criteria

- [ ] `make rg353p KERNEL=mainline` produces a flashable image
- [ ] `make rg353p KERNEL=vendor` produces a flashable image
- [ ] `make trimui-brick` produces a flashable image (vendor-only)
- [ ] `make rg35xx-pro` and `make rg35xx-pro-lpddr3` still work (no regression)
- [ ] All three new devices appear in `make list-devices`
- [ ] All new SoC content tracked under `soc/allwinner-h700/source.manifest.v2`-style v2 manifests (one manifest per SoC, or one shared)
- [ ] User confirms hardware boots for at least one new device (RG353P most likely)

## Out of scope

- Other Rockchip variants (RK3588, RK3326)
- Other Allwinner variants (H616 raw boards, H313, A64)
- Qualcomm devices (deferred — different SoC family with significantly different bring-up)
- Per-flavor patch overlays (RT, multiboot menu — Plan 03 created the dirs; they're populated when needed)

# Plan 06 — Universal Vendor Blob Extractor (VBE) + module injection

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.
>
> **Status: SKETCH** — design captured during Plan 04 execution; full plan to be written when ready to start Plan 06.

**Goal:** Port PanicOS userspace to **any ARM handheld** by extracting the vendor kernel + modules + DTB + U-Boot blobs directly from a stock vendor SD-card image, then pairing them with a PanicOS squashfs (with vendor modules injected). Removes the requirement that ROCKNIX or Knulli already supports the device.

**Why:** Many cheap-Chinese handhelds ship a working Linux but the manufacturer never publishes source. ROCKNIX and Knulli only port to devices they have time for. With VBE, **anyone with a vendor image** can produce a PanicOS image for that device.

---

## Architecture

A new build mode (third — alongside `from-source` and `from-blobs`):

- **`from-extracted-vendor`** — input is a vendor SD-card image (or recovery firmware archive). VBE produces a `soc/<extracted-soc>/vendor/prebuilt/<device>/` layout identical to what `sync-knulli.sh` produces in blob mode. From there the existing blob-staging build path takes over.

VBE is a CLI tool (`scripts/vbe.sh`) plus a TUI wizard integrated into Plan 05's `panicos-tui.sh`. The CLI exposes **three independent user-facing operations** that can be used standalone or chained:

### Operation A — `vbe extract` (extract + archive)

```sh
./scripts/vbe.sh extract <vendor-image> [--out vbe-<device>-<sha>.tar.gz]
```

- Identifies the image format (raw / gz / xz / zip / rar / RKImage / sparse-android)
- Extracts: kernel `Image`/`uImage`/`zImage`, all DTBs, U-Boot blob(s), `/lib/modules/<kver>/` tree, initrd if present, any boot scripts
- Bundles into a single tar.gz with a manifest (`vbe-manifest.yaml`) listing what's inside, kernel version, DTB compatibles, U-Boot strings, source-image SHA256
- Output filename auto-derived: `vbe-<auto-detected-device-or-soc>-<source-sha8>.tar.gz`
- This artifact is **shareable** between users (everything except licensing — see open questions)

### Operation B — `vbe inject` (modules into a squashfs)

```sh
./scripts/vbe.sh inject <vbe-archive.tar.gz> <input.squashfs> [--out output.squashfs]
```

- Unpacks the user-supplied PanicOS squashfs (built from `make rg35xx-pro` etc., or any compatible PanicOS build)
- Copies `/lib/modules/<kver>/` from the VBE archive into the rootfs
- Runs `depmod -a -b <rootfs> <kver>`
- Re-packs squashfs (preserves UID/GID, compression settings)
- Output: a squashfs that pairs with the vendor kernel's modules — boots on vendor kernel with full peripheral support

This is the killer operation — lets users build a PanicOS squashfs ONCE, then inject different vendor modules to target different devices.

### Operation C — `vbe build-image` (assemble flashable image)

```sh
./scripts/vbe.sh build-image \
    <vbe-archive.tar.gz> \
    <squashfs.squashfs> \
    --out panicos-<device>-vendor-extracted.img.gz \
    [--system-size 8G] [--overlay-size 64M]
```

- Combines: vendor U-Boot blobs + vendor kernel + (our compiled) initramfs + user-supplied squashfs
- Builds the full disk image with PanicOS's standard partition layout (boot FAT + system ext4 + overlay ext4)
- Works for devices that fit a "U-Boot + Image + DTB + initramfs + squashfs" boot chain (most ARM handhelds)
- For Allwinner sunxi-pattern devices: stages boot0.img/boot_package.fex at the right offsets
- For Rockchip devices: stages idbloader + u-boot.itb at the right offsets
- For exotic boot patterns (e.g. Android-style boot.img with embedded ramdisk): the extractor preserves the original initrd; this op chains kernel→vendor-initrd→PanicOS-rootfs (vendor-initrd doesn't switch_root; PanicOS initrd takes over)

### Operation D (composite shortcut) — `vbe port`

```sh
./scripts/vbe.sh port <vendor-image> <panicos-base-squashfs> --out <flashable.img.gz>
```

Convenience: runs A → B → C in one shot. Most users will use this.

---

The TUI wizard surfaces all four operations as menu items.

### VBE pipeline

```
   vendor.img.gz
        ↓
   1. Identify wrapper format (raw, .gz, .zip, .rar, .7z, .img.xz)
        ↓
   2. Recognize partition table (MBR / GPT)
        ↓
   3. Per-partition role detection (FAT boot / ext4 rootfs / raw bootloader)
        ↓
   4. Extract kernel (Image, uImage, zImage), DTB(s), modules tree, U-Boot blob(s),
      initrd (if any)
        ↓
   5. Detect SoC family from kernel cmdline / DTB compatible string / U-Boot strings
        ↓
   6. Stage into soc/<soc>/vendor/prebuilt/<device>/
        ↓
   7. (Optional) Inject /lib/modules/<kver>/ from extracted modules into a
      built PanicOS squashfs via unsquashfs + edit + mksquashfs
        ↓
   PanicOS image with vendor kernel + PanicOS userspace
```

### Format-recognition heuristics

VBE handles common patterns:

- **Allwinner (sunxi)**: boot0.img signature `eGON.BT0` at offset 0x2000 of disk. boot_package.fex at higher offset (TOC1 magic).
- **Rockchip**: idbloader at sector 64 (32K). u-boot.itb at sector 16384 (8M). Or RKImage update.img wrapper (needs `rkdeveloptool`).
- **Qualcomm**: typically Android boot.img + abootimg unpack.
- **Mediatek (rare in handhelds)**: lk.bin + boot.img.
- **Raw kernel + DTB on a FAT partition** (Raspberry Pi-style boards): trivial.

Per-format extractor module under `scripts/vbe/` so the right one is invoked based on detected magic.

### SoC + device naming

When VBE doesn't know the device:
- Auto-suggest a SoC name from the U-Boot strings (e.g. `sun50i-h616`, `rk3566`)
- Prompt the user (in TUI) for vendor + device-shortname (e.g. `magicx-zero-28`)
- Stage into `soc/<auto-detected-soc>/vendor/prebuilt/<user-named-device>/`

### Module injection

The trickiest piece. Vendor kernel = vendor modules. PanicOS squashfs has no modules baked in. Without modules, vendor-kernel features (Wi-Fi, audio, GPU, joystick controllers, USB-OTG, suspend, …) won't work.

Injection process:
1. `unsquashfs` the built PanicOS rootfs.squashfs
2. Copy extracted `/lib/modules/<kver>/` from VBE output into the unpacked rootfs
3. Run `depmod` on the result
4. `mksquashfs` back into a new squashfs

This is a `post-image` step: the device's `post-image.sh` for VBE-extracted devices invokes a `panicos-inject-modules.sh` helper.

---

## Task sketch

### Task 1 — Format identification + partition extraction

`scripts/vbe/identify.sh` — given an input image, prints:
```
WRAPPER=raw|gzip|xz|zip|rar|7z
PARTITION_TABLE=mbr|gpt|none
PARTITIONS=<jsonl: name | start | size | fstype>
SOC_HINT=allwinner-h616|rockchip-rk3566|...|unknown
```

### Task 2 — Per-format extractors

`scripts/vbe/extract-allwinner.sh`, `scripts/vbe/extract-rockchip.sh`, etc. Each takes the image + identification output, produces a `prebuilt/` dir.

### Task 3 — Module injection helper

`scripts/panicos-inject-modules.sh`: unsquashfs → copy modules → depmod → mksquashfs.

### Task 4 — TUI integration

Plan 05's `panicos-tui.sh` gains a top-level "Extract from vendor image" path:
1. Pick image file
2. Run identification, show results to user
3. Prompt for SoC + device name (with auto-suggestion)
4. Run extractor
5. Show staged files
6. Offer to build a PanicOS image now (paired with their existing PanicOS userspace)

### Task 5 — Documentation + example

Walk through extracting one known device's stock image (e.g. one of TrimUI's — easy validation since we already know what should come out). Document the workflow in `docs/vbe-walkthrough.md`.

---

## Open design questions (resolve when writing the full plan)

- **Licensing**: extracted vendor blobs are usually under unclear licenses. PanicOS must NOT redistribute them. VBE outputs go to a user's local `prebuilt/` and stay out of git (add to `.gitignore`). Source manifest records `source: <user-local-extraction>` not a URL.
- **Format coverage**: which wrappers to support in v1? Raw `.img` and `.img.gz` are essentials. `.zip` and `.rar` are common for distribution; can defer.
- **DTS handling**: extracted DTBs (binary) can be decompiled with `dtc` for inspection but PanicOS uses the binary as-is in `prebuilt/`.
- **Multi-device images**: some vendor images contain multiple device variants. VBE may need a "which device?" prompt.
- **Initrd handling**: many vendor kernels need their original initrd to bring up DRAM/USB. VBE preserves it as a blob; our boot script chains to it.

---

## Out of scope (for VBE itself)

- Reverse-engineering vendor kernel sources from binary blobs
- License laundering (we're transparent: extracted blobs are vendor's)
- Mainline-conversion attempts (that's ROCKNIX/Knulli's lane, not ours)
- Auto-PR'ing extracted device support into upstream ROCKNIX/Knulli

---

## When to write the full plan

Plan 06 is on hold until Plans 04 and 05 ship. VBE is genuinely useful only once the rest of the harness is solid. Defer until then.

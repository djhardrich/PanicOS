# VBE Walkthrough: Porting PanicOS to a New Device

## What VBE is

The Vendor Blob Extractor (VBE) pulls the kernel, bootloader blobs, and kernel
modules from a stock device image. It then pairs those vendor blobs with a
PanicOS rootfs to produce a flashable image for any ARM handheld — even devices
not yet supported by ROCKNIX or Knulli.

## Prerequisites

- Docker installed and runnable by your user (the same requirement as a normal
  PanicOS build)
- An SD card containing the device's stock firmware, or a raw `.img`/`.img.gz`
  dump of one
- A `rootfs.squashfs` from any successful PanicOS build, e.g.:
  ```sh
  make rg35xx-pro   # produces output/rg35xx-pro-minimal-mainline/images/rootfs.squashfs
  ```

## Worked Example: Hypothetical Anbernic RG ARC-D

This walks through every step of porting PanicOS to a device that has no
existing PanicOS support.

### Step 1 — Dump the vendor SD card to a file

```sh
sudo dd if=/dev/sdX of=~/rg-arc-d-vendor.img bs=4M status=progress
gzip ~/rg-arc-d-vendor.img
```

Replace `/dev/sdX` with the correct block device. The resulting
`rg-arc-d-vendor.img.gz` is your source image.

### Step 2 — Identify the image format

```sh
./scripts/vbe.sh identify ~/rg-arc-d-vendor.img.gz
```

Sample output:

```yaml
image: /home/user/rg-arc-d-vendor.img.gz
wrapper: gzip
partition_table: gpt
soc_hint: rockchip-rk3xxx
size_bytes: 7516192768
partitions:
  - name: uboot
    ...
```

Check `soc_hint` and `partition_table`. If either is `unknown`, see the
failure-mode section below before continuing.

### Step 3 — Port (one-shot)

```sh
./scripts/vbe.sh port \
    ~/rg-arc-d-vendor.img.gz \
    output/rg35xx-pro-minimal-mainline/images/rootfs.squashfs \
    --out ~/panicos-rg-arc-d.img.gz \
    --default-dtb rk3566-anbernic-rg-arc-d.dtb \
    --allow-empty-modules
```

`port` runs extract → inject → build-image in one shot and writes a
gzip-compressed flashable disk image to `--out`.

`--default-dtb` names the device tree blob (from the vendor boot partition)
that the bootloader should load. Omit it if the vendor u-boot already selects
the right DTB automatically.

`--allow-empty-modules` is needed when the base squashfs came from a
PanicOS build (which ships no vendor kernel modules by default). Without it,
`inject` exits with an error when the modules archive is absent.

The intermediate VBE archive lands in `output/vbe/` and is gitignored.

### Step 4 — Flash the result

```sh
sudo dd if=~/panicos-rg-arc-d.img.gz of=/dev/sdX bs=4M status=progress
```

Insert the SD card and power on.

## Subcommand Reference

**`identify <image>`** — Prints YAML: wrapper (raw/gzip/xz), partition table
(gpt/mbr), per-partition info, SoC hint. Use as a first diagnostic step.
`./scripts/vbe.sh identify <image>`

**`extract <vendor-image> [--out FILE]`** — Unwraps the vendor image, copies
out bootloader blobs, kernel `Image`, DTBs, and modules, and bundles them into
a tar.gz archive. Defaults to `output/vbe/<auto-name>.tar.gz`.
`./scripts/vbe.sh extract <vendor-image> [--out FILE]`

**`inject <archive.tar.gz> <squashfs> [--out FILE] [--allow-empty]`** — Unpacks
the squashfs, overlays vendor kernel modules, and re-packs. Pass `--allow-empty`
when the archive has no modules and you want a verbatim copy.
`./scripts/vbe.sh inject <archive.tar.gz> <squashfs> [--out FILE] [--allow-empty]`

**`build-image <archive> <squashfs> --out FILE`** — Assembles the full disk
image: bootloader staging area, boot partition (kernel + DTBs), and a system
partition. Accepts `--system-size`, `--overlay-size`, `--boot-size`,
`--default-dtb`.
`./scripts/vbe.sh build-image <archive> <squashfs> --out FILE [--default-dtb NAME]`

**`port <vendor-image> <squashfs> --out FILE`** — Composite shortcut: runs
`extract` → `inject` → `build-image` in one shot. Accepts all flags of those
three subcommands.
`./scripts/vbe.sh port <vendor-image> <squashfs> --out FILE [--default-dtb NAME] [--allow-empty-modules]`

## Common Failure Modes

- **Encrypted vendor images** — Some manufacturers encrypt firmware. VBE has no
  decryption support; you need to find an unencrypted dump or use the OTA
  payload extractor appropriate for that vendor.

- **`parted: unrecognised disk label`** — The unwrapped file is not a valid raw
  disk image. Verify the source SD card was read cleanly and the image is not
  truncated. Run `file` on the raw image to confirm it looks like a disk image.

- **`kpartx: no partitions`** — The image may be in Android sparse format
  (`.simg`). Sparse images must be converted to raw first with `simg2img`.
  Android sparse support is out of scope for VBE v1.

- **Modules MISSING in archive** — The VBE archive contains a `MISSING.txt`
  sentinel instead of a modules tarball. This is expected when the base
  squashfs was produced by PanicOS (which builds its own in-tree modules).
  Pass `--allow-empty-modules` to `port` or `--allow-empty` to `inject`.

- **Boot partition has no kernel `Image`** — The vendor uses a non-standard
  boot layout (e.g. FIT images named differently, or a signed Android boot
  image). Inspect the boot partition manually and extract the kernel by hand,
  then use `extract` + `inject` + `build-image` individually instead of `port`.

- **Generated image does not boot** — Bootloader offsets may differ from those
  VBE expects for this SoC. VBE v1 supports Allwinner sunxi (8 KB SPL at
  sector 16) and Rockchip rk3xxx (32 KB idbloader + 8 MB ITB). Other SoCs fall
  through to a generic path with no bootloader staging; you will need to stage
  the bootloader manually with `dd` after flashing.

## TUI Alternative

If you prefer a menu-driven interface, run `make tui` from the repository root
to open the PanicOS interactive wizard. The **Vendor Blob Extractor** submenu
exposes all five VBE operations (`identify`, `extract`, `inject`,
`build-image`, `port`) as selectable menu items with guided prompts for each
required argument.

## Limitations (v1)

- **Input formats**: raw `.img` and gzip/xz-compressed images only. ZIP, RAR,
  RKImage (Rockchip upgrade tool), Allwinner LiveSuit `.img`, and Android
  sparse `.simg` are not supported.
- **Bootloader staging**: Allwinner sunxi and Rockchip rk3xxx only. Other SoCs
  fall through to a generic path with no automatic bootloader staging.
- **Legal/license**: extracted vendor blobs are written to `output/vbe/`, which
  is gitignored. They are never committed to the repository. It is your
  responsibility to comply with the license terms of your device's firmware
  before distributing any resulting image.

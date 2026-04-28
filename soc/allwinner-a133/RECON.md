## A133 (TrimUI Brick) Recon — Plan 04

Generated: 2026-04-27

---

### C. Knulli A133 Layout (TrimUI Brick)

#### C1. A133 board root
  third_party/knulli/board/batocera/allwinner/a133/

  Top-level contents:
    fsoverlay/         — shared A133 rootfs overlay
    magicx-zero-28/    — device-specific dir
    patches/           — A133-level patches
    powkiddy-v20/      — device-specific dir
    powkiddy-v90s/     — device-specific dir
    trimui-brick/      — TrimUI Brick device dir (primary target)
    trimui-smart-pro/  — TrimUI Smart Pro device dir (different device; config reused)

  Config files:
    third_party/knulli/configs/knulli-a133_defconfig
    third_party/knulli/configs/knulli-a133.board

#### C2. TrimUI Brick device dir — all files
  Path: third_party/knulli/board/batocera/allwinner/a133/trimui-brick/

  Files:
    batocera-boot.conf            — boot configuration
    boot/asound.state             — ALSA saved state
    boot/bat/*.bmp                — battery indicator bitmaps (16 files)
    boot/boot.cmd                 — U-Boot boot script source
    boot/boot.scr                 — compiled U-Boot boot script (binary)
    boot/extlinux.conf            — extlinux config
    boot/font24.sft / font32.sft  — fonts for boot splash
    boot/magic.bin                — unknown binary (possibly display magic)
    boot/bootlogo.bmp / bootlogo.bmp — boot logos
    create-boot-script.sh         — build script; assembles BATOCERA_BINARIES_DIR/boot/
    genimage.cfg                  — top-level genimage config (5G boot.vfat)
    knulli_bootlogo_768p.bmp      — 768p boot logo
    linux-sunxi64-legacy.config   — kernel config (for 4.9.191 vendor kernel; same as Smart Pro)
    logo-768p.png                 — 768p logo
    partitions/boot0.img          — pre-built Allwinner BROM stage1 blob (64KB)
    partitions/boot_package.fex   — pre-built Allwinner TOC1 boot package (4.6MB)
    partitions/boot.img           — pre-built Android bootimg with vendor kernel (15MB)
    partitions/env.img            — pre-built U-Boot env partition (128KB)
    partitions/genimage.cfg       — partition-level genimage config
    patches/batocera-emulationstation/001_fix_battery_path.patch
    patches/batocera-emulationstation/002-add-custom-powerooff-reboot.patch
    patches/libcec/001-disable-linux-api.patch
    patches/sdl2/001-add-pvr-ge8300-mali-driver.patch
    patches/sdl2/001-add-pvr-ge8300-mali-driver.patch.disabled
    uImage     — PRE-BUILT Linux arm64 kernel image (17MB, committed to repo)
    uInitrd    — PRE-BUILT initrd (2.5MB, committed to repo)

#### C3. Kernel source — critical finding
  STATUS: CLOSED-SOURCE / PRE-BUILT BLOBS — no git repo, no source build.

  The knulli-a133_defconfig sets:
    BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE="4.9.191"
    BR2_LINUX_KERNEL_USE_CUSTOM_CONFIG=y
    BR2_LINUX_KERNEL_CUSTOM_CONFIG_FILE="...allwinner/a133/trimui-smart-pro/linux-sunxi64-legacy.config"
  There is NO BR2_LINUX_KERNEL_CUSTOM_GIT entry — no git repo URL.
  The defconfig has no CUSTOM_REPO_URL or CUSTOM_TARBALL setting.

  The actual kernel is delivered two ways (both pre-built):
    1. trimui-brick/uImage (17MB ARM64 Image) — committed directly to the Knulli repo.
       This is the TrimUI vendor kernel binary.
    2. trimui-brick/partitions/boot.img (15MB) — Android bootimg format containing:
       kernel loaded at 0x40080000, ramdisk at 0x42000000.
       cmdline: "loglevel=0 initcall_debug=0 console=tty0 console=ttyS0,115200
                 rootwait root=/dev/mmcblk0p4 init=/sbin/init"
       This appears to be TrimUI's stock firmware boot.img.

  boot/boot.cmd loads /boot/linux (not uImage) with sun50i-h616-x96-mate.dtb —
  this looks like a placeholder/wrong DTS for the TrimUI Brick (h616 != a133).
  The actual boot path uses boot.scr (compiled from boot.cmd).

  Kernel version: 4.9.191 (TrimUI vendor BSP, closed-source).
  Modules: unknown — likely extracted from vendor firmware or bundled in boot.img ramdisk.

#### C4. Kernel modules sourcing
  No BR2_LINUX_KERNEL_CUSTOM_GIT in defconfig — kernel not compiled by Buildroot.
  No modules tarball found in the Knulli repo for trimui-brick.
  Likely scenario: modules are inside the pre-built boot.img ramdisk or loaded from
  the vendor rootfs. Could not determine module source from repo files alone.
  STATUS: unknown — needs runtime investigation or vendor firmware extraction.

#### C5. U-Boot / bootloader blob layout
  ALL bootloader components are pre-built blobs committed to the repo:

  partitions/boot0.img (64KB):
    Allwinner eGON.BT0 Boot Image (ARM) — this is Allwinner BROM stage (boot0).
    Written at offset 0x20000 (131072 bytes = 256KB) in genimage.cfg.
    (Note: there's a discrepancy — top-level genimage.cfg uses offset 131072,
     partitions/genimage.cfg uses offset 262144; the top-level is authoritative.)

  partitions/boot_package.fex (4.6MB):
    Allwinner TOC1 Boot Image, "sunxi-package", 4 items:
      u-boot    at offset 0x800,   size 0xc0000  (~768KB)
      monitor   at offset 0xc0800, size 0x1130c  (ATF/secure monitor)
      scp       at offset 0xd1c00, size 0x14008  (System Control Processor firmware)
      dtb       at offset 0xe6000, size 0x25600  (~150KB device tree)
    Written at offset 16793600 (0x1004000) — standard Allwinner position.

  partitions/env.img (128KB):
    U-Boot environment partition (raw binary, opaque data).
    Written as two copies: "env" and "env-redund" partitions.

  partitions/boot.img (15MB):
    Android bootimg with vendor kernel + ramdisk.
    Written at offset 37748736 (0x2400000).

  Disk layout (GPT, from top-level genimage.cfg):
    GPT header at offset 81920 (0x14000)
    boot0.img   (in-partition-table=no) at offset 131072  (0x20000)
    boot_package.fex (in-partition-table=no) at offset 16793600
    boot.img    partition at offset 37748736
    env         partition (after boot)
    env-redund  partition (redundant env)
    boot-resource (VFAT, bootable, 5G) — holds batocera rootfs + kernel
    userdata    (ext4, 512M)

  IMPLICATION FOR PANICOS:
    All four binary blobs (boot0.img, boot_package.fex, env.img, boot.img) must be
    staged verbatim from Knulli's repo. There is no "build from source" path.
    The uImage and uInitrd in the device root are the kernel and initrd to be placed
    on the boot-resource VFAT partition (alongside batocera.update squashfs).
    PanicOS must implement a "blob-staging" build mode for A133.

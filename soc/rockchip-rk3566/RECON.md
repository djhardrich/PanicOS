## RK3566 Recon — Plan 04

Generated: 2026-04-27

---

### A. ROCKNIX RK3566 Layout

#### A1. Device root path
  third_party/rocknix/projects/ROCKNIX/devices/RK3566/

  Contents (top-level subdirs):
    bootloader/       — update.sh (copies DTBs to /flash/device_trees, writes UPDATE hint)
    linux/dts/rockchip/ — extra DTS files (see A3)
    linux/linux.aarch64.conf — kernel config (auto-generated, arm64 7.0.1)
    packages/linux/   — modprobe.d/rtw88.conf
    packages/u-boot/  — dispatcher package.mk (iterates SUBDEVICES)
    packages/u-boot-Generic/ — mainline U-Boot for auto-detected devices
    packages/u-boot-Specific/ — mainline U-Boot for extlinux FDT-specified devices
    patches/linux/    — ~20 RK3566-specific kernel patches (0001..1011 series)
    patches/mali-bifrost/ — one mali interrupt patch
    options           — device defaults (CPU cortex-a55, MALI bifrost-g52, kernel 7.0.1)

#### A2. Kernel: source and version
  Version:   7.0.1 (mainline, kernel.org)
  URL:       https://www.kernel.org/pub/linux/kernel/v7.x/linux-7.0.1.tar.xz
  Set in:    third_party/rocknix/projects/ROCKNIX/packages/linux/package.mk
  Case arm:  H700|SM8250|RK3399|RK3576|SM8650|SM8550|SM6115|RK3566 -> PKG_VERSION="7.0.1"
  NOTE:      RK3566 uses mainline 7.0.x, NOT the armbian rk-6.1-rkr3 fork
             (that fork is RK3588-only in ROCKNIX)
  Kernel config:
    third_party/rocknix/projects/ROCKNIX/devices/RK3566/linux/linux.aarch64.conf

#### A3. DTS files (extra, added on top of mainline tree)
  Path: third_party/rocknix/projects/ROCKNIX/devices/RK3566/linux/dts/rockchip/
  Files:
    rk3566-powkiddy-rk2023.dtsi
    rk3568-anbernic-rg-ds.dts
  These are rsynced into arch/arm64/boot/dts/ at post_patch() time.
  Note: DTS dir is rockchip/ (not allwinner/). Standard location.
  Note: RG353P has no extra DTS here — it relies on in-tree mainline DTS.

#### A4. U-Boot source
  Two variants built from mainline U-Boot v2026.01:
    URL: https://github.com/u-boot/u-boot/archive/refs/tags/v2026.01.tar.gz

  u-boot-Generic (devices auto-detected via DTSOC):
    defconfig:    anbernic-rgxx3-rk3566_defconfig
    BL31:         rkbin/bin/rk35/rk3568_bl31_v1.45.elf
    DDR TPL:      rkbin/bin/rk35/rk3568_ddr_1056MHz_v1.23.bin

  u-boot-Specific (devices with explicit FDT in extlinux.conf):
    defconfig:    quartz64-a-rk3566_defconfig
    BL31:         rkbin/bin/rk35/rk3568_bl31_v1.45.elf
    DDR TPL:      rkbin/bin/rk35/rk3568_ddr_1056MHz_v1.23.bin

  Patches applied from:
    third_party/rocknix/projects/ROCKNIX/devices/RK3566/packages/u-boot-Generic/patches/
    third_party/rocknix/projects/ROCKNIX/devices/RK3566/packages/u-boot-Specific/patches/

#### A5. ATF / TF-A platform name for RK3566
  ROCKNIX uses rkbin pre-built BL31 (not compiled TF-A) for RK3566.
  The BL31 binary used is: rk3568_bl31_v1.45.elf
  ATF_PLATFORM would be "rk3568" (RK3566 and RK3568 share the same platform).
  The base packages/tools/atf/package.mk exists but RK3566 uses rkbin BL31, not compiled ATF.

#### A6. U-Boot defconfig for RG353P (ROCKNIX track)
  Generic track:  anbernic-rgxx3-rk3566_defconfig  (covers RG353P/V and other rgxx3 devices)
  Specific track: quartz64-a-rk3566_defconfig       (fallback for extlinux FDT devices)
  The "Generic" path is what RG353P uses since it has no FDT line in extlinux.conf.

#### A7. Kernel patch directories (mainline + version-specific + device-specific)
  Generic mainline shims:
    third_party/rocknix/projects/ROCKNIX/packages/linux/patches/mainline/
      (5 patches: gpiolib, input-polldev, pwm_set_period, adc-keys, BTrtl RTL8733BU)
  Version-specific (7.0):
    third_party/rocknix/projects/ROCKNIX/packages/linux/patches/7.0/
      (1 patch: fix-rust-build-error)
  RK3566-device-specific:
    third_party/rocknix/projects/ROCKNIX/devices/RK3566/patches/linux/
      (~20 patches numbered 0001..1011: OPP, rk817 battery, st7703 panel, wifi SDIO,
       anbernic controls, nv3051d timings, mali bifrost, shoulders/triggers, etc.)
  Also (mainline-rockchip — shared RK patches, applied when DEVICE==RK*):
    third_party/rocknix/projects/Rockchip/patches/linux/default/
      (v4l2/rockchip decode patches)

---

### B. Knulli RK3566 Layout

#### B1. Board root path
  third_party/knulli/board/batocera/rockchip/rk3566/

  Top-level contents:
    config-6.6.21-current-rockchip64  — BSP kernel config snapshot (reference)
    dts/                              — extra DTS + pre-built DTB files
    fsoverlay/                        — rootfs overlay (init scripts, power mgmt, etc.)
    linux-bsp-defconfig.config        — BSP kernel defconfig
    linux-bsp-libs-defconfig.config   — BSP libs variant
    linux-defconfig.config            — mainline kernel defconfig
    linux-defconfig-fragment.config   — mainline fragment
    linux_patches/                    — patches for mainline kernel track
    miyoo-flip/                       — device-specific dir
    patches/                          — global patches
    powkiddy-rgb30/                   — device-specific dir
    powkiddy-x55/                     — device-specific dir
    rg-arc-s/                         — device-specific dir

  Note: no rg353p/ subdirectory — the RG353P/V is covered by the anbernic-rgxx3 defconfig
  and the rg353v-v2 DTS (dts/rk3566-anbernic-rg353v-v2.dts).

#### B2. Per-device dirs for Anbernic devices
  DTS files present:
    dts/rk3566-anbernic-rg353v-v2.dts    — RG353V v2 device tree source
    dts/rk3566-anbernic-rg-arc-s.dtb     — pre-built DTB for RG ARC-S
  S96rg353 init script found in:
    rk3566/powkiddy-rgb30/fsoverlay/etc/init.d/S96rg353
    rk3566/powkiddy-x55/fsoverlay/etc/init.d/S96rg353
    rk3566/rg-arc-s/fsoverlay/etc/init.d/S96rg353
  No dedicated rg353p/ directory — RG353P is handled generically via anbernic-rgxx3 config.

#### B3. Knulli RK3566 kernel (mainline track)
  Config file:   third_party/knulli/configs/knulli-rk3566.board
  Track:         BSP (vendor BSP Linux 5.10 fork)
  Source:        https://github.com/TheGammaSqueeze/5.10-linux-rockchip.git
  Branch:        GammaOS
  Kernel patches: board/batocera/rockchip/rk3566/linux_bsp_patches/
  Kernel config:  board/batocera/rockchip/rk3566/linux-bsp-defconfig.config
  Config fragment: board/batocera/rockchip/rk3566/linux-defconfig-fragment.config
  Note: knulli-rk3566.board uses BSP 5.10 fork, NOT mainline

  BSP-track variant (knulli-rk3566-bsp.board):
  Source:        https://github.com/TheGammaSqueeze/jelos_rk3566-x55-kernel.git
  Branch:        main
  Kernel patches: board/batocera/rockchip/rk3566/linux_patches_bsp/
  Kernel config:  board/batocera/rockchip/rk3566/linux-bsp-defconfig.config

#### B4. Knulli RK3566 U-Boot
  Built from source — Kwiboo's downstream fork:
    URL:     https://github.com/Kwiboo/u-boot-rockchip
    Branch:  rk3xxx-2024.07
  Default defconfig: anbernic-rgxx3-rk3566
  BSP-track defconfig: powkiddy-x55-rk3566 (in knulli-rk3566-bsp.board)
  BL31 (rkbin): bin/rk35/rk3568_bl31_v1.44.elf
  DDR TPL:      bin/rk35/rk3566_ddr_1056MHz_v1.21.bin
  Not pre-built blobs; compiled at build time.

#### B5. RK3566 boot blob layout
  Knulli RK3566 produces standard Rockchip image layout:
    idbloader.img = SPL (u-boot-spl.bin) + TPL (rk3566 DDR bin)
    u-boot.itb    = FIT image: U-Boot proper + BL31 + DTB
  These are standard Rockchip eMMC/SD layout; written at MBR offset 64 (idbloader)
  and offset 16384 (u-boot.itb). Knulli uses genimage to assemble the final SD image.
  Note: Knulli doesn't ship pre-built idbloader/u-boot blobs for RK3566 — all compiled.

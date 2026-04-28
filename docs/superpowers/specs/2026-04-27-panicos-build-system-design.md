# PanicOS Build System — Design

**Status:** Draft for user review
**Date:** 2026-04-27
**Owner:** djhardrich@icloud.com

## 1. Goals

A single Buildroot-derived build system that produces flashable Linux images for the **full ARM handheld landscape** — both ROCKNIX-supported devices and Knulli-only devices — with a per-device choice of mainline or vendor kernel, and a desktop-first userspace.

PanicOS is the successor to PocketDesktop-v1. PocketDesktop-v1 was based on the LibreELEC/JELOS/ROCKNIX build system; PanicOS instead forks Buildroot directly, importing the parts of ROCKNIX (and Knulli) that PanicOS needs — kernel patches, DTS files, board configs — rather than carrying their entire build framework.

## 2. Non-goals (v1)

- **OTA / atomic updates.** Updates ship by re-flashing. Revisit after the device matrix is stable.
- **Gaming-frontend flavor.** A `gaming` Kconfig stub is reserved but not implemented.
- **Architectures other than ARM64.** No x86, no 32-bit ARM in v1.
- **Per-device runtime tuning UIs.** Performance governors, controller mappings, etc. live as static rootfs-overlay files in v1.

## 3. Architecture

### 3.1 Buildroot relationship

Upstream Buildroot is consumed via:

1. A pinned **LTS submodule** at `third_party/buildroot/` (e.g., `2025.02.x`). Master is never used.
2. PanicOS extensions delivered through Buildroot's **`BR2_EXTERNAL`** mechanism. The repo root is a `BR2_EXTERNAL` tree.
3. A **maintained patch series** at `buildroot-patches/` applied to the submodule before each build, covering the small set of changes that don't fit the external-API surface (e.g., handheld-specific hooks in `package/linux/`).

Buildroot bumps are intentional and reviewed; the patch series stays small by design, with fixes pushed upstream where feasible.

### 3.2 Repository layout

```
~/PanicOS/
├── board/<vendor>/<device>/        # per-device assets
│   ├── Config.in                   # PANICOS_DEVICE_<NAME>, defaults, deps
│   ├── linux-vendor/               # device-specific kernel patches/config (vendor)
│   ├── linux-mainline/             # device-specific kernel patches/config (mainline)
│   ├── uboot/                      # U-Boot defconfig fragment, env
│   ├── rootfs-overlay/             # files copied verbatim into rootfs
│   ├── post-build.sh               # rootfs tweaks (permissions, symlinks)
│   ├── post-image.sh               # boot partition assembly, dtbs/<soc>/, dtb.img
│   └── genimage.cfg                # partition layout
├── soc/<soc>/<flavor>/             # SoC-shared kernel patches/config/DTS bases
│   ├── linux/source.mk             # LINUX_VERSION, LINUX_SITE, LINUX_TARBALL_HASH
│   ├── linux/patches/              # base SoC patch series
│   ├── linux/config-fragment       # CONFIG_* fragment
│   ├── linux/dts/                  # SoC family DTS files (all device DTBs in family)
│   └── source.manifest             # importer-tracked (origin SHA + paths)
├── package/                        # PanicOS-only Buildroot packages
├── flavors/<flavor>/               # userspace flavor meta-packages
│   ├── Config.in
│   ├── package-list                # Kconfig selects driving the flavor
│   └── rootfs-overlay/             # flavor-level overlay (e.g., default labwc cfg)
├── kconfig/                        # PANICOS_* Kconfig fragments
├── configs/                        # generated defconfigs (one per device-flavor-kernel)
├── third_party/
│   ├── buildroot/                  # submodule, pinned LTS
│   ├── rocknix/                    # submodule, source-of-truth for SoC patches
│   └── knulli/                     # submodule, source-of-truth for device configs
├── buildroot-patches/              # patches applied to buildroot submodule pre-build
├── scripts/
│   ├── sync-rocknix.sh             # ROCKNIX -> soc/ importer
│   ├── sync-knulli.sh              # Knulli -> board/ importer
│   ├── apply-buildroot-patches.sh
│   ├── gen-defconfig.sh            # composes device + flavor + kernel into a defconfig
│   └── panicos-tui.sh              # interactive build wizard
├── docker/Dockerfile               # build environment
├── Makefile                        # top-level wrapper
├── panicos                         # convenience launcher (./panicos == make panicos-tui)
└── docs/
```

### 3.3 Device representation

Each device has a Kconfig fragment at `board/<vendor>/<device>/Config.in` declaring:

- `PANICOS_DEVICE_<NAME>` boolean
- `select PANICOS_SOC_<SOC>` to pull the right SoC tree
- A default for `PANICOS_KERNEL_FLAVOR` (`vendor` or `mainline`) appropriate for that hardware
- `depends on` lines hiding flavor/kernel combinations that don't work on that device

The top-level `kconfig/` defines:

- `choice PANICOS_DEVICE` — exactly one device per build
- `choice PANICOS_FLAVOR` — `minimal` | `desktop` | (stub) `gaming`
- `choice PANICOS_KERNEL_FLAVOR` — `vendor` | `mainline`

### 3.4 Kernel matrix

`PANICOS_KERNEL_FLAVOR` overrides per-device defaults. The Buildroot `linux` package is wrapped (via a small post-extract hook in `buildroot-patches/`) to source patches and config fragments from:

1. `soc/<soc>/<flavor>/linux/` — base SoC support
2. `board/<vendor>/<device>/linux-<flavor>/` — device-specific overlay (often just a DTS reference)

Kernel source URL/version is selected by `soc/<soc>/<flavor>/linux/source.mk` (a small fragment defining `LINUX_VERSION`, `LINUX_SITE`, `LINUX_TARBALL_HASH`).

A device that lacks one flavor (e.g., RG35XX Pro has no upstream mainline support) hides the `mainline` choice via `depends on`.

### 3.5 Userspace flavors

`flavors/<flavor>/` is a meta-package contributing:

- A `Config.in` fragment that `select`s the packages comprising the flavor
- A `package-list` (or equivalent in Kconfig) — the actual `BR2_PACKAGE_*` selects
- A `rootfs-overlay/` providing default config (e.g., a default `labwc` config under `~/.config/labwc/`)

**Desktop flavor — desktop environment choice.** When `PANICOS_FLAVOR=desktop`, a sub-choice `PANICOS_DESKTOP_ENV` selects the environment. Each option is a thin Kconfig wrapper that selects the right Buildroot packages and contributes its own `rootfs-overlay/` for sane defaults. Buildroot already packages most of these — PanicOS only owns the *grouping* and defaults.

Initial options:
- `xfce` — XFCE 4 (Buildroot's `BR2_PACKAGE_XFCE4`); X11
- `lxqt` — LXQt (`BR2_PACKAGE_LXQT`); X11
- `labwc` — labwc Wayland compositor + minimal Wayland session (lightest option, good for low-RAM handhelds)
- additional environments addable later as their own Kconfig wrappers under `flavors/desktop/desktop-env/<name>/`

Shared across all desktop envs:
- Audio: `pipewire` + `wireplumber`
- Browser: `firefox` (default; `chromium` selectable)
- Terminal: env-appropriate default (`xfce4-terminal`, `qterminal`, `foot` for labwc)
- Seat management: `seatd` (Wayland envs) or appropriate display manager / startx (X11 envs)

The default `PANICOS_DESKTOP_ENV` is `xfce` (most universally familiar; works on the widest range of devices). All choices remain user-overridable via Kconfig, and individual packages within a chosen env are still individually selectable.

**Init:** `systemd` for every flavor (including `minimal`). Consistency over a few MB.

### 3.6 Image strategy

- **Rootfs:** squashfs, read-only. Buildroot's `BR2_TARGET_ROOTFS_SQUASHFS=y`.
- **Persistent overlay:** ext4 partition mounted early at boot. An overlay-mount provides writability for `/etc`, `/var`, parts of `/usr/local`, and user home dirs. Layout follows Knulli/ROCKNIX convention so end-users encounter familiar semantics.
- **Boot partition:** FAT32, containing:
  - U-Boot artifacts (per device)
  - Kernel `Image`
  - `dtb.img` — copy of the device's default DTB
  - `dtbs/<soc>/` — **every DTB built for the same SoC family**, so an end-user can swap hardware within an SoC family by copying a different DTB over `dtb.img`
- **Final artifact:** `panicos-<device>-<flavor>-<kernel>-<git-describe>.img.gz`

### 3.7 ROCKNIX / Knulli ingestion

Both ROCKNIX and Knulli are tracked as **git submodules**. We don't symlink into them; we **copy** their relevant files into our `soc/` and `board/` trees, with a manifest recording origin so we can re-run the import.

**`scripts/sync-rocknix.sh`:**
- Walks `third_party/rocknix/projects/ROCKNIX/devices/<device>/` (current ROCKNIX layout)
- For each device entry, classifies its SoC and copies kernel patches, config fragments, DTS files, U-Boot configs into the appropriate `soc/<soc>/<flavor>/`
- Writes/updates `soc/<soc>/<flavor>/source.manifest` recording: ROCKNIX submodule SHA, source path, dest path, checksum per file
- On re-run, computes diff against the working tree and prints a summary; refuses to overwrite locally modified files unless `--force` is passed
- ROCKNIX layout changes break the importer **loudly** (failed lookup of expected paths) rather than producing silent partial imports

**`scripts/sync-knulli.sh`:**
- Same pattern, walking Knulli's `board/<vendor>/<device>/` into our `board/<vendor>/<device>/`
- Same manifest discipline

After importing, the user reviews the diff, can layer their own patches (which the importer will not clobber on next sync), and commits.

### 3.8 Build interface (top-level Makefile)

```
make list-devices                              # enumerate supported devices
make rg35xx-pro                                # default flavor (desktop), default kernel (per-device default)
make rg35xx-pro FLAVOR=minimal                 # explicit flavor
make rg353p KERNEL=mainline                    # override kernel flavor
make rg353p FLAVOR=desktop DESKTOP_ENV=lxqt    # choose desktop env
make rg35xx-pro-minimal                        # shorthand equivalent to FLAVOR=minimal
make all-devices                               # CI helper, parallel jobs
make shell                                     # interactive shell inside the build container
make clean-rg35xx-pro                          # per-device clean
make panicos-tui                               # launch interactive build wizard (see 3.9)
```

- Per-device output dirs: `output/<device>-<flavor>-<kernel>/`. Switching devices does **not** require `make clean`.
- The wrapper composes `configs/<device>-<flavor>-<kernel>.defconfig` on the fly from device + flavor + soc + kernel Kconfig fragments via `scripts/gen-defconfig.sh`, then invokes Buildroot with `BR2_EXTERNAL=$PWD O=output/<...>`.
- Final output renamed to `panicos-<device>-<flavor>-<kernel>-<git-describe>.img.gz`.

### 3.9 Interactive TUI (`scripts/panicos-tui.sh`)

A `whiptail`/`dialog`-based wizard for users (and the maintainer) who don't want to memorize make targets. Invoked as `./panicos`, `make panicos-tui`, or directly. Lives in the build container so dependencies are guaranteed.

**Flow:**
1. **Welcome** screen with current PanicOS version (git-describe) and a one-line summary
2. **Device selection** — `whiptail --menu` listing devices grouped by SoC vendor (Allwinner / Rockchip / etc.). Pulls list from `make list-devices`.
3. **Flavor selection** — `desktop` / `minimal` (and `gaming` once it exists), with a one-line description of each.
4. **Desktop env selection** — only shown if flavor is `desktop`. Lists `xfce` / `lxqt` / `labwc` (and any future additions) with one-line descriptions. Default highlighted.
5. **Kernel selection** — only shown if the chosen device supports more than one kernel flavor; otherwise auto-selected and the screen is skipped. Default highlighted per device's `Config.in`.
6. **Confirmation** — shows the resolved `make` invocation (e.g., `make rg353p FLAVOR=desktop DESKTOP_ENV=xfce KERNEL=mainline`) and asks Build / Edit / Cancel.
7. **Build** — exec's the resolved make command; output streams to the terminal. On completion, prints the path to the produced image and a one-liner `dd` example for flashing (with device-name placeholder, never autodetected).

**Constraints:**
- Pure POSIX shell + `whiptail` (Buildroot-friendly, container-friendly, no Python/Node deps)
- Non-interactive fallback: `panicos --device rg353p --flavor desktop --desktop-env xfce --kernel mainline` skips menus and runs the equivalent build
- The TUI never *generates* configurations not also expressible on the make command line — it's a UX layer, not a parallel control plane

### 3.10 Host build environment

Container-first, with an escape hatch:

- `docker/Dockerfile` based on `debian:bookworm-slim`, pinning Buildroot's documented host deps plus PanicOS additions (`squashfs-tools`, `dosfstools`, `mtools`, `python3`, `git`, `bc`, `cpio`, `whiptail`, ...)
- The top-level `Makefile`, on every invocation, checks for `IN_CONTAINER` env var. If unset and Docker is available, it `exec`s `docker run --rm -it -v $PWD:/work -w /work panicos-build:<dockerfile-hash> make $@`.
- `IN_CONTAINER=1` skips the re-exec for users who already manage their own sandbox / native environment / CI.
- The image tag is derived from a content hash of the Dockerfile so changes invalidate caches automatically.
- `make shell` drops the user into an interactive container.

## 4. v1 device scope

| Device | SoC | Kernel(s) supported | Source of truth |
|---|---|---|---|
| Anbernic RG35XX Pro | Allwinner H700 | vendor | ROCKNIX |
| Anbernic RG353P/V | Rockchip RK3566 | mainline + vendor | ROCKNIX |
| TrimUI Brick | Allwinner A133 | vendor | Knulli |

This set validates every architectural axis: ROCKNIX import path, Knulli port path, kernel-flavor toggle on a single device, two-SoC isolation under one vendor (H700 vs A133), and two SoC vendors.

The primary bring-up driver is the **RG35XX Pro**.

## 5. Risks and open items

- **Buildroot patch series rot.** Mitigation: keep small; push fixes upstream; gate Buildroot bumps on review.
- **ROCKNIX/Knulli layout changes.** Mitigation: importers fail loudly when expected paths vanish; manifests catch drift.
- **U-Boot bring-up specifics** for each v1 device — assumed straightforward via ROCKNIX/Knulli config import; confirm during impl.
- **Desktop env packaging gaps.** XFCE / LXQt are well-supported in Buildroot; small per-env glue (autostart, default theme, session file) likely needed. Discoverable during impl, low architectural risk.
- **Multi-source U-Boot per SoC.** Some SoCs (notably Rockchip RK3326) need TWO U-Boot variants in one image: legacy U-Boot for older device variants and mainline for newer, with runtime selection at boot install time (ROCKNIX uses a `SUBDEVICE` shell variable). Our current architecture supports **one U-Boot source per SoC** with per-device defconfig override of that single source. Multi-source U-Boot will require either (a) splitting into per-device-variant entries with one U-Boot source each, or (b) custom Buildroot package wrapping that builds multiple U-Boots in one config + multi-bootloader genimage staging + runtime selector. Decision deferred to whichever plan first introduces RK3326 (or a similarly bifurcated SoC).

## 6. Out of scope (deferred to future work)

- A/B partition scheme and OTA updates
- `gaming` flavor implementation (Kconfig stub only in v1)
- Multi-arch (x86, 32-bit ARM)
- On-device package installation (no `apt`/`opkg`-style runtime package management)
- Cross-distribution package compatibility shims
- Web-based or graphical configurator (TUI is the only configurator in v1)

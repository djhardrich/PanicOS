# Dual RT / non-RT kernel with TOOLS switcher (H700)

**Date:** 2026-06-25
**Status:** Approved design, pre-implementation
**Branch:** `feature/dual-rt-kernel-switch`

## Goal

Ship **two kernels in one H700 image** — a default non-RT (`CONFIG_PREEMPT`/CFS)
kernel and an opt-in full-`PREEMPT_RT` kernel — and let the user switch between
them from the launcher's **TOOLS** menu by rewriting `extlinux.conf` on the
PANICOS FAT partition, then rebooting.

## Background / current state (verified 2026-06-25)

- The H700 build loads **exactly one** kernel, `/Image`, via U-Boot +
  `extlinux.conf` (single `LABEL PanicOS`). The kernel is on the **PANICOS FAT**
  boot partition, not in the rootfs. See
  `board/anbernic/rg35xx-pro/post-image.sh` (extlinux emission, lines ~52–61)
  and `board/anbernic/rg35xx-pro/genimage.cfg.in` (FAT `files = { … }`).
- **Every mainline build is currently `PREEMPT_RT`.** The base
  `soc/allwinner-h700/mainline/linux/linux.config.fragment` is non-RT
  (`CONFIG_PREEMPT=y`); RT exists only because
  `soc/allwinner-h700/mainline/linux/panicos-extras.config.fragment.in`
  force-appends `CONFIG_PREEMPT_RT=y` **last**. So "non-RT default" is largely
  *stop forcing RT in the base build*.
- Existing runtime switchers (`mbselect`, `panicos-active.cfg`) only pick a
  **squashfs userspace flavor** *after* the kernel is up — they **cannot**
  reload the kernel. A kernel switch must happen one layer down, in
  `extlinux.conf`, before the initramfs runs.
- Precedent for editing the boot FAT from a Tools script:
  `package/panicos-launcher-tools/files/PanicOS-SquashFS-Install.sh`
  (`mount -o remount,rw /boot`, copy, remount ro).
- Tools menu auto-registers any `*.sh` in `/usr/share/panicos-launcher/tools/`
  via the `tools` system in
  `package/panicos-emulationstation/files/es_systems.cfg`.

## Decisions

- **"Realtime" = full `PREEMPT_RT`** (hard real-time). Cannot be toggled at
  runtime → genuinely needs a second compiled kernel. (`PREEMPT_DYNAMIC`
  runtime switching was considered and rejected: it does not provide full RT.)
- **Default kernel = non-RT (CFS)**, matching ROCKNIX general-purpose
  scheduling. RT is the opt-in alternative.
- **Switcher rewrites `extlinux.conf` and does NOT auto-reboot** — it flips the
  selection and tells the user to reboot themselves.
- **Switch is driven by the extlinux `DEFAULT` keyword**, not an interactive
  U-Boot bootmenu (sunxi v2026.01 U-Boot has no `MENU`/`TIMEOUT`/bootmenu
  config today; avoid depending on unverified menu support).

## Architecture

One image, two kernels on the PANICOS FAT, selected by U-Boot via
`extlinux.conf`:

| Artifact | Kernel | `uname -r` | extlinux LABEL |
|---|---|---|---|
| `/Image` (default) | `CONFIG_PREEMPT` (CFS) | `7.0.2` | `PanicOS` (DEFAULT) |
| `/Image-rt` | `CONFIG_PREEMPT_RT` | `7.0.2-rt` | `PanicOS-RT` |

Both share the same kernel version, patches, `dtb.img`, DTB set, and `APPEND`
cmdline. They differ only in the preemption Kconfig and `LOCALVERSION`.

### Why distinct `LOCALVERSION`

`PREEMPT_RT` changes module vermagic and locking ABI, so RT-built modules will
not load on the non-RT kernel and vice-versa. Distinct `LOCALVERSION`
(`""` vs `-rt`) gives `/lib/modules/7.0.2` and `/lib/modules/7.0.2-rt`, which
coexist without collision. Each kernel ships its own module tarball.

## Components

### 1. Kernel config split
- **Base (default, non-RT):** keep `linux.config.fragment` (`CONFIG_PREEMPT=y`);
  **remove** `CONFIG_PREEMPT_RT=y` from `panicos-extras.config.fragment.in`.
  → `Image`, `LOCALVERSION=""`, `/lib/modules/7.0.2`.
- **RT variant:** new fragment
  `soc/allwinner-h700/mainline/linux/panicos-rt.config.fragment` setting
  `CONFIG_PREEMPT_RT=y` + `CONFIG_LOCALVERSION="-rt"`.
  → `Image-rt`, `/lib/modules/7.0.2-rt`.

### 2. Build mechanism — new `kernel-variant` Makefile target
Mirrors the `image-variant` mental model ("build base, fold the differing piece
in"). `make kernel-variant DEVICE=rg35xx-pro FLAVOR=launcher RT=1`, run after
the base image build:
1. Clone `build/linux-7.0.2` → `build/linux-7.0.2-rt`, reconfigure with the RT
   fragment + `-rt` LOCALVERSION, rebuild **kernel only** (~10–20 min).
2. Harvest `Image-rt`; pack `panicos-modules-rt.tar.gz` from the `7.0.2-rt`
   modules tree.
3. Re-run the base's `post-image.sh` / genimage so **both** Images + **both**
   module tarballs land in one FAT.

Avoids a second toolchain/rootfs build. Chosen over extending the existing
`KERNEL=` axis (which produces two *separate* images) because we need both
kernels folded into one FAT.

### 3. Boot + module plumbing
- `post-image.sh`: emit a **two-`LABEL`** `extlinux.conf` with
  `DEFAULT PanicOS` (non-RT) and `TIMEOUT 0`; copy in `Image-rt`. The RT label
  reuses the same `FDT /dtb.img` and `APPEND`.
- `genimage.cfg.in`: add `Image-rt` and `panicos-modules-rt.tar.gz` to the FAT
  `files = { … }`.
- `package/panicos-initramfs/.../init`: extract **both** module tarballs (they
  unpack to distinct `/lib/modules/<ver>` dirs → no collision), so whichever
  kernel boots finds its matching modules.

### 4. TOOLS switcher — `Switch-Kernel.sh`
`package/panicos-launcher-tools/files/Switch-Kernel.sh`, modeled on
`PanicOS-SquashFS-Install.sh`:
1. Read current `DEFAULT` from `/boot/extlinux/extlinux.conf`; show active
   kernel + `uname -r`.
2. Let the user flip RT ↔ non-RT.
3. `mount -o remount,rw /boot`, rewrite the `DEFAULT` line, remount ro.
4. Print **"Reboot to apply — <kernel> will be active on next boot."**
   (no auto-reboot).
Installed by `package/panicos-launcher-tools/*.mk` into
`/usr/share/panicos-launcher/tools/`; auto-registered via `es_systems.cfg`.

## Data flow (switch)

```
TOOLS menu → Switch-Kernel.sh
  → read DEFAULT from /boot/extlinux/extlinux.conf
  → user picks RT or non-RT
  → remount,rw /boot → rewrite DEFAULT line → remount,ro
  → message: reboot to apply
[user reboots]
  → U-Boot reads extlinux.conf → loads selected Image (+ shared dtb.img)
  → initramfs has already extracted both /lib/modules trees
  → running kernel loads /lib/modules/<its uname -r>
```

## Build / iteration workflow

- Full: `make rg35xx-pro FLAVOR=launcher`
  → `make kernel-variant DEVICE=rg35xx-pro FLAVOR=launcher RT=1`
  → `make image-variant DEVICE=rg35xx-pro-lpddr3 BASE=rg35xx-pro FLAVOR=launcher`
  (lpddr3 symlinks the base FAT → inherits **both** kernels for free).
- Tool-script-only edits:
  `make pkg-rebuild PACKAGE=panicos-launcher-tools DEVICE=rg35xx-pro FLAVOR=launcher`
  then `make image-rebuild DEVICE=rg35xx-pro FLAVOR=launcher`.
- Kernel-config fragment change: `make pkgs-rebuild PACKAGES=linux …`
  (defconfig fragment changed → `pkgs-rebuild`, not `pkg-rebuild`), then
  re-run `kernel-variant` for the RT side.

## Files touched

- `soc/allwinner-h700/mainline/linux/panicos-extras.config.fragment.in` — drop
  the `CONFIG_PREEMPT_RT=y` line (base becomes non-RT).
- `soc/allwinner-h700/mainline/linux/panicos-rt.config.fragment` — **new**, RT +
  `-rt` LOCALVERSION.
- `Makefile` — **new** `kernel-variant` target.
- `board/anbernic/rg35xx-pro/post-image.sh` — two-LABEL extlinux, copy
  `Image-rt`, harvest RT artifacts.
- `board/anbernic/rg35xx-pro/genimage.cfg.in` — add `Image-rt`,
  `panicos-modules-rt.tar.gz` to FAT.
- `package/panicos-initramfs/.../init` — extract both module tarballs.
- `package/panicos-launcher-tools/files/Switch-Kernel.sh` — **new** switcher.
- `package/panicos-launcher-tools/*.mk` — install the switcher.

## Testing / verification

- **Build:** confirm one FAT contains `Image`, `Image-rt`,
  `panicos-modules.tar.gz`, `panicos-modules-rt.tar.gz`, and a two-LABEL
  `extlinux.conf` with `DEFAULT PanicOS`.
- **Boot default:** fresh flash boots non-RT; `uname -r` = `7.0.2`;
  `cat /sys/kernel/realtime` absent or `0`.
- **Switch:** run `Switch-Kernel.sh` → flip to RT → reboot → `uname -r` =
  `7.0.2-rt`; `uname -v` shows `PREEMPT_RT`; modules load (no vermagic errors in
  `dmesg`); WiFi/BT/controllers/audio functional under both kernels.
- **lpddr3 variant:** confirm `image-variant` output FAT also carries both
  kernels.
- **Idempotency:** running the switcher twice to the same target is a no-op;
  switching back restores `DEFAULT PanicOS`.

## Out of scope / non-goals

- Interactive U-Boot boot menu (`MENU`/`TIMEOUT` prompt at power-on).
- Runtime preemption switching (`PREEMPT_DYNAMIC`) — does not provide full RT.
- Vendor (Linux 4.9) kernel RT variant — mainline only.
- Per-userspace-flavor kernel selection.

## Post-implementation follow-ups (requested by user)

- Update project documentation (README / build docs) to describe the dual-kernel
  layout and the `Switch-Kernel.sh` tool.
- Write/refresh auto-memory: a `project` memory for the dual-kernel layout +
  `kernel-variant` target, and a `feedback`/`project` note that the H700 default
  scheduler is now CFS (non-RT) with RT opt-in (supersedes the prior
  "every mainline build is PREEMPT_RT" assumption).

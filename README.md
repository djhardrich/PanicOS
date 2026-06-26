# PanicOS

Linux images for H700 handhelds. Buildroot-based.

## Quick start

```sh
git clone --recurse-submodules <repo-url> PanicOS
cd PanicOS
make harness-smoke   # smoke-test the build harness; ~30 min on first run
```

The output rootfs lands in `output/harness-smoke-minimal/images/rootfs.tar`.

## Interactive build (TUI)

If you don't want to memorize `make` flags, run:

```sh
make tui
```

The wizard walks through device → flavor → kernel and dispatches the
right build. It also includes a **Vendor Blob Extractor** submenu for
porting PanicOS to unsupported devices — see below.

## Porting to a new device with VBE

The Vendor Blob Extractor lets you pull the kernel, bootloader blobs, and
modules from a stock device SD card image and combine them with a PanicOS
rootfs to produce a flashable image for any ARM handheld.

Full walkthrough: [`docs/vbe-walkthrough.md`](docs/vbe-walkthrough.md)

## Real device builds

Working today (kernel + bootloader + minimal flavor squashfs all built from
source, plus per-device wifi/BT firmware vendored from upstream linux-firmware
or the device vendor BSP):

| Target            | SoC family            | Build command                |
|-------------------|-----------------------|------------------------------|
| `rg35xx-pro`      | Allwinner H700 (LPDDR4) | `make rg35xx-pro`          |
| `rg35xx-pro-lpddr3` | Allwinner H700 (LPDDR3) | see below — **do not** `make rg35xx-pro-lpddr3` to iterate |
| `rg353p` (Currently Broken)         | Rockchip RK3566       | `make rg353p`                |
| `trimui-brick` (Currently Broken)   | Allwinner A133 (vendor BSP) | `make trimui-brick`    |

Each writes its image to `output/<device>-<flavor>-<kernel>/images/panicos-<device>-<flavor>-<rev>.img.gz`.

### U-Boot-only variants (`rg35xx-pro-lpddr3`)

`rg35xx-pro-lpddr3` differs from `rg35xx-pro` in **only the U-Boot SPL** (LPDDR3
vs LPDDR4 RAM training) — same SoC, same kernel, same rootfs. Running
`make rg35xx-pro-lpddr3` builds an entire second buildroot tree from scratch
(toolchain, kernel, every package) for what is effectively a swapped SPL blob.
Don't.

Use `image-variant` instead. Build the base once, then produce variant images
by rebuilding only u-boot against the variant's defconfig and symlinking the
base's kernel/DTBs/rootfs:

```
make rg35xx-pro FLAVOR=launcher                                      # base
make image-variant DEVICE=rg35xx-pro-lpddr3 BASE=rg35xx-pro \        # variant
                   FLAVOR=launcher
```

Variant builds finish in minutes (one u-boot compile) instead of an hour+.
Caveat: the rootfs is shared with `BASE`, so `/etc/hostname` and `/etc/issue`
say `panicos-rg35xx-pro` rather than `-lpddr3` — cosmetic. If you need a
fully variant-correct rootfs, fall back to `make rg35xx-pro-lpddr3` and
accept the cold-build time (ccache helps).

### Dual kernel (RT / non-RT)

Each H700 image ships **two kernels** on the PANICOS FAT and lets you switch
between them on the device:

- **`/Image`** — the default, non-RT kernel (`CONFIG_PREEMPT`, CFS scheduler),
  matching ROCKNIX. `uname -r` → `7.0.2`.
- **`/Image-rt`** — an opt-in full-`PREEMPT_RT` kernel (priority inheritance,
  threaded IRQ handlers) for latency-sensitive audio/controller workloads.
  `uname -r` → `7.0.2-rt`.

Both kernels are built from the same source with the same patch set; they
differ only in the preemption Kconfig and `LOCALVERSION`. Their module trees
sit side by side (`/usr/lib/modules/7.0.2` and `/usr/lib/modules/7.0.2-rt`) so
they never collide.

The base build produces the non-RT kernel. Add the RT kernel with
`kernel-variant` (it clones the base's already-patched kernel tree, flips the
preemption config, and folds `Image-rt` + an RT module tarball into the same
FAT). `image-variant` then carries both kernels into U-Boot variants:

```
make rg35xx-pro FLAVOR=launcher                                      # base (non-RT)
make kernel-variant DEVICE=rg35xx-pro FLAVOR=launcher RT=1           # add the RT kernel
make image-variant DEVICE=rg35xx-pro-lpddr3 BASE=rg35xx-pro \        # lpddr3 inherits both
                   FLAVOR=launcher
```

U-Boot boots whichever kernel the `DEFAULT` label in `/extlinux/extlinux.conf`
points at (default `PanicOS` = non-RT). On the device, **Tools → Switch-Kernel**
flips that label; reboot to apply (it does not auto-reboot). You can also edit
`extlinux.conf` on the FAT from a PC without reflashing.

## Logging in

After flashing and first boot, the device shows a `panicos login:` prompt on
the built-in screen (any USB-OTG keyboard works) and listens on SSH (port 22,
dropbear). Default credentials:

| Field    | Value     |
|----------|-----------|
| Username | `root`    |
| Password | `panicos` |

Change with `passwd` once logged in — the new hash lands on the overlay and
survives reboots. SSH host keys are generated per device on first boot and
stored on the overlay too, so every flashed SD card ends up with a unique
identity (no key reuse across devices).

### Autologin

To skip the password prompt for kiosk-style flavors (retro launcher, signage,
etc.), enable autologin on tty1 by adding this line to the flavor's
`defconfig.fragment`:

```
BR2_PACKAGE_PANICOS_AUTOLOGIN=y
```

Off by default — minimal flavor wants the prompt. The autologin package
ships a systemd drop-in to `/etc/systemd/system/getty@tty1.service.d/`,
which means an end user can disable autologin on a flashed device by
deleting that file via the overlay (`rm /etc/systemd/system/getty@tty1.service.d/autologin.conf`)
and rebooting — no rebuild needed.

SSH still requires the password regardless of the tty1 autologin setting.

## Wifi setup (no rebuild required)

Wifi credentials live in a plain-text file on the boot partition (FAT32),
so you set them by editing the SD card on a PC after flashing — no rebuild,
no SSH-over-ethernet bootstrap.

Mount the boot partition (Windows / macOS / Linux all see it as a normal
FAT volume) and edit `panicos-wifi.cfg`:

```
SSID=MyHomeNetwork
PSK=mysecretpassword
COUNTRY=US        # ISO 3166. REQUIRED on some hardware before wifi will start.
HIDDEN=0          # 1 for hidden SSIDs
```

Save, eject, boot. The PSK is hashed into a runtime config on tmpfs each
boot — the cleartext stays only in the file you control. Edit the file
again any time to switch networks or update credentials; takes effect on
next reboot.

If `panicos-wifi.cfg` is left commented out (the default), the device
boots fine with no wifi — useful for ethernet-only or offline use.

**Power users**: drop a full `wpa_supplicant.conf` next to `panicos-wifi.cfg`
on the boot partition. It takes priority and is used verbatim — useful for
EAP / enterprise wifi or anything past plain WPA2-PSK.

Wifi can be disabled per-flavor by removing `BR2_PACKAGE_PANICOS_WIFI_CONFIG=y`
from the flavor's `defconfig.fragment`. Same for SSH (`BR2_PACKAGE_DROPBEAR=y`,
`BR2_PACKAGE_PANICOS_SSHKEYS=y`).

## Flavors and image authoring

A "flavor" is a userspace squashfs that the initramfs loop-mounts as the
root filesystem. The kernel + bootloader + initramfs are device-specific
and stay the same; the flavor is what makes the device feel like a
different OS (busybox console vs. Debian desktop vs. EmulationStation
launcher).

The boot vfat partition can hold **multiple `.squashfs` files at once**.
A small text file `panicos-active.cfg` on the same partition picks which
one to boot:

```
IMAGE=panicos-rg35xx-pro-minimal.squashfs
# FLAVOR=  (optional; defaults to IMAGE without .squashfs)
```

Drop a new `.squashfs` onto the boot vfat from a PC, edit `IMAGE=` to
point at it, reboot — that's the whole switch flow. No reflash.

### Per-flavor overlays

Each unique `FLAVOR` (defaults to the squashfs filename) gets its own
`/storage/.panicos-overlay/<FLAVOR>/{upper,work}` directory on the storage
partition. So Debian's `/etc` doesn't pollute Arch's `/etc`, the dropbear
host keys generated under one flavor stay isolated, etc. To wipe a single
flavor's state without touching the others, SSH in and:

```sh
rm -rf /storage/.panicos-overlay/<flavor-name>
reboot
```

User data (ROMs, saves, anything outside `.panicos-overlay/`) on `/storage`
is intentionally shared across flavors — it's *user* state, not *system*
state.

### Building a different flavor

Pass `FLAVOR=<name>` on the make command line:

```sh
make rg35xx-pro FLAVOR=launcher  # EmulationStation + PortMaster kiosk
make rg353p FLAVOR=minimal       # default, can omit FLAVOR=
```

Each flavor lives at `flavors/<name>/{Config.in,defconfig.fragment}`.
Adding a new one is a 2-file pattern — see `flavors/minimal/` and
`flavors/launcher/` as references.

### `launcher` flavor (PortMaster + Rockbox + Doom Engines)

Boots into a panicos-launcher TUI under sway, with PortMaster, Rockbox
(themed with PodOne), and Doom Engines pre-installed via
`panicos-portmaster-preload`. No first-boot install round-trip — the GUI
appears on first launch.

Two non-obvious integration fixes worth documenting because the symptoms
were misleading:

#### A/B (and X/Y) reversed in PortMaster ports

Symptom: every PortMaster port came up with A and B swapped — pressing
the bottom physical button gave "A" instead of "B" — and Rockbox's
Start+Select quit combo never registered (because it was actually
firing as Start+different-button).

Root cause: PortMaster's upstream `get_controls()` in `control.txt`
hardcodes `/dev/input/by-path/platform-*` device-detection for known
handhelds (Anbernic-rg351v, OdroidGo, GameForce, etc.). None of those
match our `rocknix-singleadc-joypad` device path, so `DEVICE` falls
through empty and PortMaster writes an **empty**
`/tmp/gamecontrollerdb.txt`. SDL2 then has no mapping for the H700
Gamepad GUID `1900f6a24b480000df14000000010000` and falls back to its
built-in default — which is Xbox-positional (`A=south`). Our system
gamecontrollerdb (vendored from ROCKNIX) is Nintendo-positional
(`a:b1, b:b0` — A=east, the right physical button), so SDL's fallback
inverts every face button vs. what our DB says, and gptokeyb hotkey
combos like Start+Select fail to match because the IDs don't line up.

Fix: `mod_PanicOS.txt` overrides PortMaster's `get_controls()` with a
4-line replacement that just `cp`s our system gamecontrollerdb
(`/usr/share/SDL-GameControllerDB/gamecontrollerdb.txt`) into
`/tmp/gamecontrollerdb.txt`. `mod_*.txt` is sourced by `PortMaster.sh`
*after* `control.txt` and *before* `get_controls` is called, so our
override wins.

ROCKNIX solves the same problem with a 5-line `get_controls` that
synthesises the DB from EmulationStation config via their `mapper.txt`.
We don't ship ES, so we just stuff the system DB in directly. Same
outcome.

#### Rockbox boots with PodOne colors but stock layout

Symptom: PodOne's color scheme applied (dark text on tan background)
but the WPS/SBS/FMS layout reverted to stock cabbiev2.

Root cause: PortMaster's bundled `Rockbox.sh` bind-mounts the port dir
to `/tmp/rockbox` at launch and runs
`sed -i 's#/.rockbox#/tmp/rockbox#g'` on every `themes/*.cfg` before
starting Rockbox. Our `panicos-portmaster-preload` writes a default
`config.cfg` at the port root (`rockbox/config.cfg`, NOT under
`themes/`) that contains the upstream PodOne paths
(`wps: /.rockbox/wps/PodOne.wps`, etc). The `themes/*.cfg` sed loop
never touches it. At runtime Rockbox loads `config.cfg`, fails to
resolve the literal `/.rockbox/...` paths (those don't exist on the
SDL App build — only `/tmp/rockbox/...` does), and silently falls back
to defaults for each individual setting (wps, sbs, fms, font, iconset).
Colors apply because they're path-free.

Fix: apply the same `/.rockbox` → `/tmp/rockbox` sed transformation to
our generated `config.cfg` at build time in
`panicos-portmaster-preload.mk`, mirroring what PortMaster's runtime
does to themes/*.cfg.

#### SDL audio crashes in RockBox ("Audio target not available")

Symptom: RockBox (and other SDL2-pulseaudio apps) exited immediately
with `Error: sdl audio / Audio target 'pulseaudio' not available`,
even after SDL2 was built with `--enable-pulseaudio`.

Root cause: SDL2 loads PulseAudio at runtime via `dlopen("libpulse.so.0")`.
`libpulse.so.0` has `RUNPATH=/usr/lib/pulseaudio` to find
`libpulsecommon-17.0.so`, but the dlopen chain inside SDL2 doesn't inherit
the RUNPATH walk, so the secondary `dlopen` for `libpulsecommon` fails and
SDL silently marks the pulseaudio driver unavailable.

Fix: `Environment=SDL_AUDIODRIVER=pipewire` in `panicos-es.service` (and
mirrored in `profile.d/sway-fullscreen.sh` so it survives PortMaster's
`control.txt` re-sourcing `/etc/profile`). SDL 2.32.10 has a native PipeWire
driver; `libpipewire-0.3.so.0` lives in `/usr/lib/` directly so dlopen finds
it without any RUNPATH indirection.

### Kiosk-flavor checklist (KMSDRM apps: EmulationStation, …)

Anything that grabs the panel via KMSDRM (ES, future kiosks) needs
the same two pieces of plumbing. The launcher flavor hit this
class of bug when either was missing — symptoms are misleading ("No
available video device", or `ExecStart` never firing, or app stdout
painted on top of the splash) so this is worth getting right up front.

**1. SDL2 KMSDRM backend in the flavor's `defconfig.fragment`.** SDL2
silently builds with no video driver if KMSDRM isn't selected, and any
SDL2 app then fails at startup with `Error initializing SDL! No
available video device`. Required:

```kconfig
BR2_PACKAGE_SDL2_KMSDRM=y
BR2_PACKAGE_SDL2_OPENGLES=y
BR2_PACKAGE_MESA3D=y
BR2_PACKAGE_MESA3D_GBM=y
BR2_PACKAGE_MESA3D_OPENGL_EGL=y
BR2_PACKAGE_MESA3D_OPENGL_ES=y
BR2_PACKAGE_MESA3D_GALLIUM_DRIVER_PANFROST=y     # for Mali G31 (H700)
```

**2. systemd service must NOT claim `/dev/tty1`.** Don't set `TTYPath=`,
`StandardInput=tty`, `StandardOutput=tty`, or `Conflicts=getty@tty1` —
those create TTY-ownership tangles between the splash, fbcon, and the
KMSDRM app. The kernel already arbitrates DRM master, just let it. Use:

```ini
[Unit]
After=basic.target sound.target network.target
# NOT After=multi-user.target — combined with WantedBy=multi-user.target
# that creates an ordering loop and systemd silently drops the unit.

[Service]
StandardInput=null
StandardOutput=journal
StandardError=journal
# (no TTYPath, no Conflicts=getty@tty1)
```

`flavors/launcher/` follows this pattern;
`package/panicos-emulationstation/files/panicos-es.service` is the
canonical service-file reference.

### Building a real-distro squashfs (Debian / Ubuntu)

PanicOS isn't tied to buildroot userland. The distro-bootstrap pipeline
produces a fully-formed Debian Trixie or Ubuntu Noble aarch64 squashfs
that drops onto a flashed PanicOS device's boot vfat and boots under
the same kernel + initramfs.

**Recommended (containerised)** — no host setup required beyond docker
+ qemu-user-static (for the binfmt registration):

```sh
./scripts/docker-distro-bootstrap.sh --distro debian
# → output/distro/panicos-debian-trixie-aarch64.squashfs

./scripts/docker-distro-bootstrap.sh --distro ubuntu --packages "neovim htop tmux"
# → output/distro/panicos-ubuntu-noble-aarch64.squashfs
```

The wrapper builds `docker/Dockerfile.distro-bootstrap` on demand
(debian:trixie-slim base with debootstrap + qemu-user-static +
squashfs-tools + arch-install-scripts pre-installed) and runs the
bootstrap inside `--privileged` so `chroot`/bind-mounts work. CLI args
pass through verbatim. Cache lives at
`$HOME/.cache/panicos-distro-bootstrap/` and is reused across runs.

**Bare-metal** (skip the docker wrapper if you'd rather install the
toolchain directly):

```sh
sudo ./scripts/distro-bootstrap.sh --distro debian
```

Bare-metal requires `debootstrap`, `qemu-user-static`, `squashfs-tools`,
`mksquashfs`, and root. The docker path needs only docker +
qemu-user-static (the latter for the host kernel's binfmt registration —
verify with `cat /proc/sys/fs/binfmt_misc/qemu-aarch64`).

The script bakes in a PanicOS overlay: hostname (`panicos-debian` or
`panicos-ubuntu` by default), root password (default `panicos`,
override with `--root-password`), `sshd` enabled with PermitRootLogin,
systemd-networkd configured for both wlan0 and eth0, machine-id zeroed
so first boot generates a unique one per device.

After the script finishes, copy the `.squashfs` onto a flashed PanicOS
device's boot vfat (next to the existing minimal one), edit
`panicos-active.cfg`'s `IMAGE=` to point at it, reboot. The per-flavor
overlay system kicks in automatically — Debian's state lives in
`/storage/.panicos-overlay/panicos-debian-trixie-aarch64/`, completely
separate from the minimal flavor's overlay.

Arch is scaffolded but not implemented for cross-bootstrap from x86_64
yet — see the script's `bootstrap_arch()` for status.

## Build iteration tips

Full clean rebuilds (`make clean-<device> && make <device>`) take 30-45 min
because the toolchain + kernel + mesa3d all rebuild from scratch. **Almost
nothing genuinely needs a full clean.** Buildroot tracks dependencies
correctly — if you add a new package, only that package builds; if you
edit kernel patches, only the kernel rebuilds. The one case that's broken
is buildroot's `local`-method packages (our `package/panicos-*/` ones)
don't track source mtimes, so editing a script in there doesn't trigger a
rebuild without clearing stamps. The `pkg-rebuild` helper handles that
exact case.

| Edit type | Command | Time |
|---|---|---|
| Source change in `package/<pkg>/` (our local packages) | `make pkg-rebuild PKG=<pkg> DEVICE=<dev> [FLAVOR=<fl>]` | 1-3 min |
| Kernel config fragment / DTS / kernel patches | `make pkg-rebuild PKG=linux DEVICE=<dev> [FLAVOR=<fl>]` | 10-20 min |
| Third-party package edit (mesa3d, sdl2, etc.) | `make pkg-rebuild PKG=<pkg> DEVICE=<dev> [FLAVOR=<fl>]` | varies (matches that package's build size) |
| Add a new package to a flavor (any size) | `make <device> [FLAVOR=<fl>]` (no clean) | only the new package + downstream rebuilds — toolchain/kernel cached |
| Change extlinux APPEND, genimage layout, post-image | `make image-rebuild DEVICE=<dev> [FLAVOR=<fl>]` | 1-2 min |
| Toolchain Kconfig knob (`BR2_TOOLCHAIN_BUILDROOT_CXX`, `_FORTRAN`, etc.) | `make pkg-rebuild PKG=host-gcc-final DEVICE=<dev> [FLAVOR=<fl>]` then `make <device>` | ~10 min for toolchain + downstream rebuilds |
| Switch libc (glibc ↔ musl), arch (aarch64 ↔ armhf), or upgrade glibc | `make clean-<device> && make <device>` | genuinely ABI-incompatible; sysroot is unrecoverable |

A heavier flavor that adds 50 packages doesn't need a clean — just
`make <device> FLAVOR=<heavy>`. Buildroot will cache-hit on every package
that's already been built for any other flavor on the same device, and
build only the new ones.

`pkg-rebuild` clears the package's stamp files (which buildroot's local
package infrastructure doesn't auto-invalidate when source mtimes change)
plus the squashfs/image stamps so the change actually lands in a new
flashable artifact. Same mechanism works for any buildroot package, not
just ours — `PKG=linux`, `PKG=mesa3d`, `PKG=host-gcc-final`, etc.

## Requirements

- Linux host with Docker installed and runnable by your user
- About 30GB of disk for the build tree (per device-flavor combination)
- Decent internet for the first Buildroot download

`IN_CONTAINER=1` on the make command line skips the Docker re-exec for users
who manage their own sandbox.

## Repository layout

See `docs/superpowers/specs/2026-04-27-panicos-build-system-design.md`.

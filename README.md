# PanicOS

Linux images for ARM handhelds. Buildroot-based.

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
| `rg35xx-pro-lpddr3` | Allwinner H700 (LPDDR3) | `make rg35xx-pro-lpddr3` |
| `rg353p`          | Rockchip RK3566       | `make rg353p`                |
| `trimui-brick`    | Allwinner A133 (vendor BSP) | `make trimui-brick`    |

Each writes its image to `output/<device>-<flavor>-<kernel>/images/panicos-<device>-<flavor>-<rev>.img.gz`.

Mainline-kernel builds run with `CONFIG_PREEMPT_RT=y` (mainlined in 6.12;
we're on 7.0.1 so it's a Kconfig-only switch). Adds priority inheritance +
threaded IRQ handlers; safe for non-RT workloads, dramatically improves
audio/controller-poll latency for the `pht` flavor.

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
different OS (busybox console vs. Debian desktop vs. PHT autostart kiosk).

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
make rg35xx-pro FLAVOR=pht       # ProHandheldTracker autostart kiosk
make rg353p FLAVOR=minimal       # default, can omit FLAVOR=
```

Each flavor lives at `flavors/<name>/{Config.in,defconfig.fragment}`.
Adding a new one is a 2-file pattern — see `flavors/minimal/` and
`flavors/pht/` as references.

### `pht` flavor (ProHandheldTracker)

Boots straight into [ProHandheldTracker](https://prohandheldtracker.com/)
under `chrt -f 50` so the audio thread gets RT scheduling on the
PREEMPT_RT kernel. The systemd service `Conflicts=getty@tty1.service`,
so PHT owns the panel via KMSDRM cleanly.

Prerequisite: the PHT payload (binary + 50MB plugins + assets) is too big
to commit to git. Vendor a snapshot from your local
`~/prohandheldtracker-build/dist/stage/pht/` once before building:

```sh
./scripts/vendor-pht.sh                    # uses default ~ path
./scripts/vendor-pht.sh --src /other/path  # override
```

Then:

```sh
make rg35xx-pro FLAVOR=pht
```

SSH still works in the pht flavor (we kept all the subsystem-A
networking/SSH bring-up). Drop into a shell from your laptop if you need
to poke around or read logs while PHT is running on the panel.

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

## Requirements

- Linux host with Docker installed and runnable by your user
- About 30GB of disk for the build tree (per device-flavor combination)
- Decent internet for the first Buildroot download

`IN_CONTAINER=1` on the make command line skips the Docker re-exec for users
who manage their own sandbox.

## Repository layout

See `docs/superpowers/specs/2026-04-27-panicos-build-system-design.md`.

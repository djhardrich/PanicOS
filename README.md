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

Coming in Plan 02 (Anbernic RG35XX Pro bring-up). Until then, `harness-smoke`
is the only target.

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

## Requirements

- Linux host with Docker installed and runnable by your user
- About 30GB of disk for the build tree (per device-flavor combination)
- Decent internet for the first Buildroot download

`IN_CONTAINER=1` on the make command line skips the Docker re-exec for users
who manage their own sandbox.

## Repository layout

See `docs/superpowers/specs/2026-04-27-panicos-build-system-design.md`.

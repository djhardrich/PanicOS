# Console + Wifi Bootstrap — Design

**Status**: Draft, brainstormed 2026-04-28
**Scope**: Subsystem **A** of the image-authoring roadmap (A console → C packages → D multi-flavor overlays → E TUI)

## Goal

Make a freshly flashed PanicOS image immediately interactive on real hardware:
the user can log in on the device's built-in display with a USB keyboard, and
optionally SSH in over wifi using credentials they configured by editing a
plain-text file on the boot vfat — no rebuild required.

This is the smallest piece of work that unblocks everything that follows.
Until you can log into the device and run `dmesg`, `lsmod`, `iw dev`, etc.
with normal hands-on tools, every other subsystem is built blind.

## Non-goals

- Desktop/GUI greeter — that lives with the desktop flavor work (subsystem C+).
- Custom kernel modules build path — out of tree (subsystem B, deprioritised).
- USB-gadget console — explicitly rejected by the user.
- Enterprise wifi (EAP, 802.1x) via the friendly key=value path — power
  users get full `wpa_supplicant.conf` drop-in instead.

## Components

### 1. Login on tty1

- Set `BR2_TARGET_GENERIC_ROOT_PASSWD="panicos"` in the non-desktop flavor's
  defconfig fragment so `/etc/shadow` ships with a known root password.
- systemd's stock `getty@tty1.service` handles the prompt — no extra config
  for the default flow.
- Keep the current cmdline `console=ttyS0,115200 console=tty1` so both UART
  and tty1 are valid getty targets (UART stays useful for early-boot dev).
- Per-flavor opt-in autologin via a systemd drop-in:
  `/etc/systemd/system/getty@tty1.service.d/autologin.conf` rendered from a
  per-flavor knob (see §6). Default for the minimal flavor: **no autologin,
  always prompt**.

### 2. Display side (framebuffer console)

The DRM panel is already initialised at boot — its firmware ships in the
initramfs and the device boots without errors today. To get the kernel and
userland TTYs to actually paint onto the panel, the kernel must have:

- `CONFIG_FB=y`
- `CONFIG_FRAMEBUFFER_CONSOLE=y`
- `CONFIG_DRM_FBDEV_EMULATION=y`
- `CONFIG_FRAMEBUFFER_CONSOLE_DETECT_PRIMARY=y` (preferred)

Inject any missing options via `panicos-extras.config.fragment.in` (the same
mechanism that already overrides `CONFIG_EXTRA_FIRMWARE` etc.) — that keeps
the kernel-config divergence from ROCKNIX in one place.

Verification step (build-time): grep the final `.config` for the four
options above and fail the build if any are absent.

### 3. USB keyboard

USB host + HID. Required kernel options:

- `CONFIG_USB_HID=y`, `CONFIG_HID_GENERIC=y`
- `CONFIG_USB_OHCI_HCD=y`/`CONFIG_USB_EHCI_HCD=y` for the H700 USB controllers
- `CONFIG_USB_OTG=y` (handhelds use OTG → host with adapter)

These are almost certainly already enabled in the imported ROCKNIX config —
the audit step grep-asserts them.

### 4. SSH over wifi

- Add `BR2_PACKAGE_DROPBEAR=y` to the non-desktop flavor (smaller than
  openssh; sufficient for shell + scp).
- Enable the systemd unit so it autostarts.
- Same root/panicos credentials as tty1 (until user changes via `passwd`).
- Disabled per-flavor with a flag for image authors who don't want SSH
  exposed (see §6).

### 5. SSH host keys (first-boot generation)

- Bake nothing — every flashed image must end up with unique host keys.
- Add a service `panicos-sshkeys.service`, ordered before `dropbear.service`,
  with `ConditionPathExists=!/storage/.panicos-sshkeys-done`.
- Generates keys to `/etc/dropbear/` (which sits on the overlay → persists
  across reboots without per-flavor namespacing weirdness, since SSH host
  identity is genuinely per-device, not per-flavor).
- Touches the marker after success and self-disables.

### 6. Wifi auto-connect from boot vfat

#### Source-of-truth files (on boot vfat)

Lookup order, first hit wins:

1. `/boot/wpa_supplicant.conf` — raw drop-in, used verbatim. Power-user path
   for EAP/enterprise/anything fancy.
2. `/boot/panicos-wifi.cfg` — friendly key=value:
   ```
   SSID=MyHomeNetwork
   PSK=mysecretpassword
   COUNTRY=US      # ISO 3166. REQUIRED on some hardware.
   HIDDEN=0        # 1 for hidden SSID
   ```
3. Neither present → service exits 0, no error, no wifi.

The boot vfat ships a commented-out `/boot/panicos-wifi.cfg` template so
users see the format without us trying to connect to placeholder creds.

#### Boot service (`panicos-wifi-config.service`)

- New buildroot package `package/panicos-wifi-config/`.
- Type=oneshot, ordered `Before=wpa_supplicant@wlan0.service`,
  `After=local-fs.target` (needs `/boot` mounted).
- Renders the chosen source into `/run/wpa_supplicant.conf` on tmpfs each
  boot — credentials never touch the overlay, so editing the file on the
  vfat just-works on next reboot.
- Calls `wpa_passphrase` for the key=value path so the PSK gets hashed
  before landing in the runtime conf.

#### Network stack

- `wpa_supplicant@wlan0.service` (already in the systemd package)
- `systemd-networkd` (already enabled) handles DHCP via a stock
  `/etc/systemd/network/wlan0.network`:
  ```
  [Match]
  Name=wlan0
  [Network]
  DHCP=yes
  ```

### 7. Per-flavor configuration model

Each flavor's `Config.in`/defconfig fragment can override:

| Knob                                  | Default (non-desktop minimal) | Used by                  |
|---------------------------------------|-------------------------------|--------------------------|
| `BR2_PACKAGE_PANICOS_AUTOLOGIN_TTY1`  | n                             | tty1 drop-in             |
| `BR2_PACKAGE_PANICOS_SSHD`            | y                             | dropbear + key gen       |
| `BR2_PACKAGE_PANICOS_WIFI_CONFIG`     | y                             | wifi-config service      |
| `BR2_TARGET_GENERIC_ROOT_PASSWD`      | `panicos`                     | shadow                   |

These get wired so a future "kiosk" flavor can flip autologin=y, SSH=n with
a one-line change in its fragment, and a desktop flavor (subsystem C work)
can disable all of these in favour of its own greeter.

## Boot-time data flow

```
kernel
  → initramfs init mounts boot vfat at /boot, storage ext4 at /storage,
    sets up overlayfs, switch_root
  → systemd starts:
      sysinit.target
        → panicos-firstboot.service (grow storage)  [conditional]
        → panicos-sshkeys.service (gen SSH host keys) [conditional]
        → panicos-wifi-config.service (read /boot files → /run conf)
      basic.target
        → wpa_supplicant@wlan0.service [if wifi config rendered]
        → systemd-networkd → DHCP on wlan0
        → dropbear.service                          [if PANICOS_SSHD=y]
        → getty@tty1.service (with optional autologin drop-in)
        → serial-getty@ttyS0.service (UART, dev convenience)
```

## Security considerations

- Default credentials are public knowledge — anyone with the image can SSH
  in if they're on the same network. Users who care must change with
  `passwd` (persists on overlay) or rebuild with a different default.
- The wifi PSK on `/boot/panicos-wifi.cfg` is plaintext on a FAT partition —
  same trust level as a Raspberry Pi's `wpa_supplicant.conf` setup. Document
  it explicitly in the file's header comment.
- SSH host keys live on the overlay, generated per device. Wiping a flavor's
  overlay (subsystem D's "reset" operation) regenerates them on next boot —
  caller's expected behaviour.

## Testing

- Build the minimal flavor; flash; verify on hardware:
  - tty1 shows login prompt on the panel
  - root/panicos works
  - USB keyboard input works (handheld will need an OTG cable)
  - With no wifi.cfg: boot completes, no errors, no wpa_supplicant
    spinning
  - With key=value wifi.cfg: device joins network, gets DHCP
  - With raw wpa_supplicant.conf: same
  - SSH from laptop: `ssh root@<dhcp-ip>`, password prompt, works
  - `ssh-keygen -F <ip>` shows a fresh key, not a baked-in one
- A second flashed image of the same build must have *different* SSH host
  keys (proves first-boot gen, not bake-in).

## Open questions deferred to later subsystems

- Per-flavor overlay namespace (subsystem D) — affects where SSH keys live
  if a user runs multiple flavors on the same device. The first-boot service
  will need to know the active flavor's overlay path, which D will define.
- Image-author-defined initial password (subsystem C/E) — the TUI should
  let an author set a custom default password instead of "panicos" when
  building. Current spec assumes "panicos" baked in; later work parameterises.

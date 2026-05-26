# Debian squashfs: Bluetooth controller fix + hold-menu auto-pair

**Date:** 2026-05-26
**Status:** Design approved, awaiting implementation plan
**Target image:** `output/debian-desktop/panicos-debian-desktop.squashfs`
**Hardware:** Allwinner H700 (RG35XX Pro) with RTL8821CS combo chip

---

## Problem

### Bug — no Bluetooth controller

`bluetoothctl scan on` on the live Debian image returns **"No default
controller available"** even though the kernel has BlueZ enabled and
the same kernel powers a working BT stack on the launcher image.

Direct inspection on `root@192.168.1.181`:

- `/sys/class/bluetooth/` — empty (no `hci0`).
- `dmesg` shows `Bluetooth: HCI UART driver ver 2.3` and
  `HCI UART protocol Three-wire (H5) registered`, but no `btrtl` /
  `rtl_bt` firmware-load lines. The serdev probe never bound.
- `/lib/firmware/rtl_bt/rtl8821cs_config.bin` is a symlink to
  `rtl8761b_config.bin` (wrong chip; 10 bytes, md5 `783db791…`).
- `bluetoothd 5.85-4` is running cleanly; it just has no adapter.

This is the **same probe race** documented in
`docs/rtl8821cs-bluetooth-fixes.md` and fixed for the launcher image.
The Debian build script never picked up the launcher's two artifacts
(firmware blob + `panicos-bt-wakeup.service`).

### Feature — hold-menu auto-pair

Today the Menu button (gamepad `BTN_MODE`) emits `KEY_MENU` via
uinput; Wayfire's `binding_menu` runs a wvkbd toggle command. The
binding is single-action and Wayfire-specific.

We want:
1. Short press (<5s): toggle on-screen keyboard, as today.
2. Hold ≥5s: enter auto-pair mode — discover for 30s, automatically
   pair/trust/connect the first HID or audio device that becomes
   visible, notify the user of progress and outcome.
3. Both behaviors must work on any desktop environment, not only
   Wayfire (GNOME, KDE, sway are realistic future targets).

---

## Out of scope

- Multi-user sessions (device is single-user appliance).
- Bluetooth on the launcher image (already fixed).
- Kernel changes — `CONFIG_BT_LE=y`, `CONFIG_UHID=y`, and the H5
  serdev DT node are already in place from the launcher work.
- BT auto-reconnect after reboot (BlueZ handles it once paired/trusted).
- Pairing UI for advanced cases (multiple devices, profile picker) —
  power users can still open `blueman-manager`.

---

## Design

### Part 1 — Fix BT controller in `build-debian-desktop.sh`

Three mechanical additions to `scripts/build-debian-desktop.sh`:

**1a. Add packages** to the apt install list:

- `libspa-0.2-bluetooth` — PipeWire BT codec/profile plugin (A2DP/HSP/HFP).
- `bluez-tools` — `bt-agent`, `bt-network`, `bt-obex` CLI helpers.

`bluez`, `bluez-obexd`, and `blueman` are already installed via the
`bluetooth` metapackage.

**1b. Replace the broken firmware symlink.** After the chroot package
install completes, inside the build script:

```bash
RTL_FW_DIR="$ROOTFS/lib/firmware/rtl_bt"
SRC_BLOB="$ROOT/soc/allwinner-h700/mainline/rootfs-overlay/usr/lib/firmware/rtl_bt/rtl8821cs_config.bin"

# Verify source blob is the canonical 29-byte SDIO variant
[ "$(md5sum "$SRC_BLOB" | cut -d' ' -f1)" = "37338e0b8861a20ce877c0a10cbaaae3" ] \
    || error "rtl8821cs_config.bin source blob has wrong md5"

# Remove broken Debian symlink, install correct blob
rm -f "$RTL_FW_DIR/rtl8821cs_config.bin"
install -m 0644 "$SRC_BLOB" "$RTL_FW_DIR/rtl8821cs_config.bin"
```

The md5 guard ensures a future SOC-overlay change can't silently push a
bad blob into the Debian image.

**1c. Install `panicos-bt-wakeup.service`** by copying the existing
launcher file:

```bash
cp "$ROOT/soc/allwinner-h700/mainline/rootfs-overlay/usr/lib/systemd/system/panicos-bt-wakeup.service" \
    "$ROOTFS/usr/lib/systemd/system/panicos-bt-wakeup.service"
chroot_run systemctl enable panicos-bt-wakeup.service
```

The service runs once after `bluetooth.service`; if `hci0` is missing
it reloads `hci_uart` (unloading `hci_uart` then `btrtl` first — order
matters, documented in the existing service file).

**1d. Add `panicos` user to `bluetooth` group** (needed for Part 2 so
the per-user agent can talk to bluez over the system bus):

```bash
chroot_run usermod -aG bluetooth panicos
```

### Part 2 — Hold-menu auto-pair (cross-DE)

Architecture:

```
              writes commands
gamepad-mouse ────────────────► /run/panicos/menu.sock ◄──── panicos-session-agent
(system, root)                       unix socket                (per-user, autostart)
                                                                  │
                                                                  ├─ short → toggle OSK
                                                                  └─ long  → auto-pair
                                                                            ├─ bluez (system bus)
                                                                            └─ notify-send
```

**2a. `gamepad-mouse.py` — slim down to socket producer.**

Remove the virtual keyboard creation and `KEY_MENU` emit entirely
(no more `create_virtual_keyboard` / `KEY_MENU` write paths). Add:

- `/run/panicos/menu.sock` — datagram unix socket, mode `0666`,
  created at daemon startup. Parent dir owned `root:root` mode `0755`,
  ensured by `RuntimeDirectory=panicos` in the systemd unit (creates
  on start, cleans up on stop — preferred over `tmpfiles.d`).
- `BTN_MODE` press: record monotonic timestamp, schedule a 5s timer.
- `BTN_MODE` release before 5s: send `b"short\n"` to the socket.
  Cancel the timer.
- 5s timer fires while still held: send `b"long\n"`, mark the press
  consumed so the eventual release sends nothing.

Mouse / R1 / R2 / d-pad logic is untouched. Drop the
`PanicOS Gamepad Keys` uinput device — gone.

Remove `panicos-gamepad-keys` from the udev rules file.

**2b. `panicos-session-agent.py` — new per-user agent.**

Installed to `/usr/local/lib/panicos/panicos-session-agent.py`.

Started via XDG autostart:
`/etc/xdg/autostart/panicos-session-agent.desktop`. This file is
honored by Wayfire, GNOME, KDE, sway, XFCE — any DE following the
XDG autostart spec.

```ini
[Desktop Entry]
Type=Application
Name=PanicOS Session Agent
Exec=/usr/local/lib/panicos/panicos-session-agent.py
X-GNOME-Autostart-enabled=true
NoDisplay=true
```

Agent behavior:

- At startup, decide OSK command:
  `wvkbd-mobintl -L 160` if `XDG_SESSION_TYPE=wayland` and `wvkbd-mobintl`
  is on `PATH`; otherwise `onboard` if present; otherwise log a warning
  and keep going (short-press will no-op).
- Open `/run/panicos/menu.sock` as a datagram client; retry on
  `ECONNREFUSED` for up to 5s at startup.
- Read loop, dispatch each line:
  - `short` — `pkill -x <osk_basename>`; on non-zero exit, spawn the
    OSK command in background. Inherits session env naturally so
    Wayland/X11 connection works.
  - `long` — call `do_autopair()` inline (single-threaded; second
    `long` while one runs is ignored via lock file).

`do_autopair()`:

1. Acquire `~/.cache/panicos/bt-autopair.lock` (`flock`, non-blocking);
   skip if held.
2. `notify-send -t 3000 "Pairing mode" "Put your device in pairing mode now…"`
3. Connect to bluez on the system bus (`org.bluez`). Retry every 0.5s
   for up to 5s; if still not present, notify error and return.
4. Power on the adapter; register an agent with capability
   `NoInputNoOutput` and set it as default.
5. Subscribe to `InterfacesAdded` on `/`. Call
   `org.bluez.Adapter1.StartDiscovery` on the adapter object.
6. For each new `org.bluez.Device1`:
   - Read `Class` property. Major-device-class bits are `(Class >> 8) & 0x1F`.
     Accept `0x05` (peripheral/HID) and `0x04` (audio/video).
   - If `Class` is missing (LE-only): read `Appearance`. Accept values
     in `0x03C0..0x03C4` (HID generic, keyboard, mouse, joystick,
     gamepad).
   - Otherwise ignore.
7. First match wins:
   - `StopDiscovery`.
   - `Pair`. Default agent NoInputNoOutput auto-confirms.
   - `Trust = true`.
   - `Connect`.
   - On success: `notify-send "Connected: <Alias>"`.
   - On any D-Bus exception in steps above:
     `notify-send -u critical "Pair failed: <reason>"`.
8. Overall 30s budget (wall-clock from step 5). If timer expires with
   no match: `StopDiscovery`, `notify-send "No device found"`, return.
9. Release lock.

Uses `python3-dbus` and `python3-gi` for the GLib main loop (both
already in Debian, no new packages needed).

**2c. udev cleanup.**

Remove the `PanicOS Gamepad Keys` line from
`/etc/udev/rules.d/99-panicos-uinput.rules` (the virtual keyboard
uinput device is gone).

**2d. Wayfire config cleanup.**

Remove `binding_menu` and `command_menu` from
`debian-desktop/configs/wayfire.ini`. Volume/brightness/power/launcher
bindings stay — those bind to real keyboard keys (`KEY_VOLUMEUP` etc.)
that any DE handles equivalently.

---

## Files touched

**New:**
- `debian-desktop/services/panicos-session-agent.py`
- `debian-desktop/services/panicos-session-agent.desktop`

**Modified:**
- `scripts/build-debian-desktop.sh` (Part 1 a–d + Part 2 install steps)
- `debian-desktop/services/gamepad-mouse.py` (drop kbd uinput; socket I/O)
- `debian-desktop/services/gamepad-mouse.service` (add `RuntimeDirectory=panicos`)
- `debian-desktop/configs/wayfire.ini` (remove `binding_menu`)
- `debian-desktop/configs/99-panicos-uinput.rules` content in
  build-debian-desktop.sh heredoc (remove `Gamepad Keys` line)

**No changes to:**
- Kernel config (already correct).
- Buildroot / SOC overlay (already correct).
- The launcher image.

---

## Validation plan

1. `scripts/build-debian-desktop.sh` rebuilds without error.
2. Deploy via `scripts/deploy-squashfs.sh` to the device.
3. Reboot. SSH in.
4. `ls /sys/class/bluetooth/` — must show `hci0`.
5. `bluetoothctl show` — must list a controller with a MAC.
6. `bluetoothctl scan on` for ~10s — must list nearby devices.
7. From a paired BT keyboard in pairing mode: hold device's Menu
   button (gamepad `BTN_MODE`) for 5s. Expect:
   - Mako notification "Pairing mode" within ~5s of holding.
   - Within ~10s of pressing the BT device's pair button: notification
     "Connected: <name>".
   - `bluetoothctl devices Paired` lists the device.
   - Typing on the BT keyboard works in `foot` terminal.
8. Short-press Menu — wvkbd appears. Short-press again — wvkbd hides.
9. Reboot — `panicos-bt-wakeup.service` status `active (exited)`,
   `hci0` present.

---

## Failure modes addressed in design

| Scenario | Behavior |
|---|---|
| `hci0` missing because serdev race | `panicos-bt-wakeup.service` reloads `hci_uart` once after boot. |
| User holds Menu with no DE running (e.g. SSH-only session) | Daemon writes to socket; no listener; harmless. |
| User holds Menu twice in quick succession | Second auto-pair sees flock held, exits silently. |
| BlueZ not yet up when agent starts | Agent retries system-bus connection for up to 5s before notifying error. |
| No device responds within 30s | "No device found" notification, discovery stops cleanly. |
| Pairing fails (wrong PIN model, etc.) | Critical-urgency notification with bluez error reason; lock released. |
| Bad blob silently slipped into SOC overlay | Build script aborts on md5 mismatch. |
| User on X11 instead of Wayland | Agent picks `onboard` (or skips with a logged warning) at startup. |

---

## Risks and unknowns

- **`libspa-0.2-bluetooth` integration**: enables BT audio profiles but
  PipeWire may need a service restart to pick up the codec module on
  first connect; if `notify-send "Connected"` arrives but no audio
  device appears in `wpctl status`, document `systemctl --user
  restart pipewire pipewire-pulse wireplumber` as a one-time fix and
  consider auto-restarting after first successful audio-class pair.
- **CoD filter false negatives**: some BT controllers (notably cheap
  8BitDo-style gamepads) advertise as audio/AV or with unusual CoDs.
  Spec accepts the standard 0x04/0x05 majors plus LE Appearance HID
  range; broader devices can still be paired via `blueman-manager`.
- **30s window**: long enough for typical BT keyboards/mice but tight
  for some controllers that take 10+ seconds to enter pairing mode.
  If feedback shows this is too short we can raise to 60s without
  redesign.

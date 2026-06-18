# H700 USB HID Gamepad Gadget (Allwinner RG35XX Pro)

**Platform:** Allwinner H700 (sun50i-h616 family), rg35xx-pro / rg35xx-pro-lpddr3
**Kernel:** mainline 7.0.2
**UDC:** `musb-hdrc.5.auto` (USB-C, dual-role; gadget/peripheral side)
**Input source:** `H700 Gamepad` evdev node from the `rocknix-singleadc-joypad` driver
**Gadget path:** evdev (`/dev/input/eventN`) → userspace bridge → configfs `f_hid` → `/dev/hidgN` → host
**Helper:** `/usr/bin/panicos-hid-gamepad` (shipped via
`soc/allwinner-h700/mainline/rootfs-overlay/usr/bin/`)

This exposes the handheld's physical controls to a connected USB host as a
standard USB HID gamepad — plug the device's USB-C port into a PC/console and
it enumerates as a 16-button / 2-stick / D-pad gamepad with no host-side driver.

---

## Background — why this needed a kernel change

The musb UDC and the configfs composite framework (`libcomposite`,
`USB_CONFIGFS`) were already enabled — that is how the existing `cdc` and `mtp`
gadgets work. But the **HID function was not compiled**:

```
# CONFIG_USB_CONFIGFS_F_HID is not set
```

and `usb_f_hid` was not even available as a module, so there was no way to
present a HID device from userspace. The fix enables the full USB gadget
function set so this class of request never hits a missing-function wall again.

### Kernel config (`soc/allwinner-h700/mainline/linux/linux.config.fragment`)

- **All configfs functions `=y`**: `USB_CONFIGFS_F_HID` (pulls in `USB_F_HID`
  via `select`), plus UAC1/UAC1_LEGACY/UAC2, MIDI/MIDI2, UVC, PRINTER, and
  SERIAL/ACM/OBEX/ECM_SUBSET/F_LB_SS. These are composable functions that are
  only instantiated when you `mkdir` them under configfs — they never bind the
  UDC on their own, so building them in is free.
- **`USB_GADGETFS=y`, `USB_RAW_GADGET=y`**: userspace-driven gadget APIs that
  stay inert until a userspace client opens them.
- **Legacy "precomposed" gadgets `=m`** (g_zero, g_audio, g_ether, g_ncm,
  g_ffs, g_mass_storage, g_serial, midi, g_printer, cdc_composite, g_acm_ms,
  g_multi, g_hid, g_dbgp, g_webcam): built as **modules on purpose**.

> **Why the legacy gadgets must be `=m`, not `=y`:** each legacy gadget driver
> auto-binds the UDC at kernel init via `usb_composite_probe()`. Built `=y`,
> one of them would seize `musb-hdrc.5.auto` at boot and the configfs
> `cdc`/`mtp`/HID gadgets would then fail to bind with `-EBUSY`. As modules they
> are available to `modprobe` but do nothing until loaded. (They are independent
> tristate symbols, not a Kconfig `choice`, so all can coexist.)

The kernel-config change is picked up automatically by buildroot — the
`pkg-kconfig` stamp depends on the fragment's mtime, so it re-merges and runs
`olddefconfig` (resolving the `select`'d `USB_F_HID`) without a re-patch:

```
make pkg-rebuild PACKAGE=linux DEVICE=rg35xx-pro FLAVOR=launcher
make image-rebuild DEVICE=rg35xx-pro FLAVOR=launcher
make image-variant DEVICE=rg35xx-pro-lpddr3 BASE=rg35xx-pro FLAVOR=launcher
```

---

## The bridge

`panicos-hid-gamepad` does three things:

1. **Finds the gamepad** by walking `/dev/input/event*` and matching the
   `EVIOCGNAME` against `"H700 Gamepad"` (no hard-coded event number — the node
   index is not stable across boots).
2. **Builds the gadget** under `/sys/kernel/config/usb_gadget/hidpad`: a single
   `hid.usb0` function carrying the report descriptor below, linked into one
   configuration, then bound to the first free UDC by writing its name to `UDC`.
   `/dev/hidg0` appears once the bind succeeds.
3. **Bridges events**: reads `input_event` structs from the evdev node, keeps
   axis/button/hat state, and writes a 7-byte HID report to `/dev/hidg0` on
   every change.

### HID report descriptor

Standard Generic-Desktop **Gamepad** (Usage Page 0x01, Usage 0x05):

| Byte | Field | Encoding |
|------|-------|----------|
| 0 | X (left stick X) | `int8` −127..127 |
| 1 | Y (left stick Y) | `int8` |
| 2 | Rx (right stick X) | `int8` |
| 3 | Ry (right stick Y) | `int8` |
| 4 | Hat switch (D-pad) | low nibble 0..7, `0xF` = centred; high nibble padding |
| 5 | Buttons 1–8 | bitfield |
| 6 | Buttons 9–16 | bitfield |

`report_length = 7`, `protocol = 0` / `subclass = 0` (a plain gamepad, not a
boot keyboard/mouse). Hosts (Linux `js`/`evdev`, Windows, consoles) recognise
this as a generic gamepad without any custom driver.

### Control mapping

The `H700 Gamepad` exposes 17 keys + 4 absolute axes (`±1800`). Axes are scaled
to `±127`; the four D-pad keys are folded into the hat switch; the rest map to
HID buttons:

| evdev code | meaning | HID button |
|------------|---------|------------|
| 0x130 BTN_SOUTH | A | 1 |
| 0x131 BTN_EAST | B | 2 |
| 0x133 BTN_NORTH | X | 3 |
| 0x134 BTN_WEST | Y | 4 |
| 0x136 BTN_TL | L1 | 5 |
| 0x137 BTN_TR | R1 | 6 |
| 0x138 BTN_TL2 | L2 | 7 |
| 0x139 BTN_TR2 | R2 | 8 |
| 0x13a BTN_SELECT | Select | 9 |
| 0x13b BTN_START | Start | 10 |
| 0x13c BTN_MODE | Guide | 11 |
| 0x13d BTN_THUMBL | L3 | 12 |
| 0x13e BTN_THUMBR | R3 | 13 |
| 0x220–0x223 BTN_DPAD_* | D-pad | hat switch |
| ABS 0/1 | left stick X/Y | X / Y |
| ABS 3/4 | right stick X/Y | Rx / Ry |

L2/R2 are digital on this hardware (no analog trigger axes), so they map to
plain buttons.

---

## Usage

```sh
panicos-hid-gamepad             # set up the gadget and bridge input (Ctrl-C to stop)
panicos-hid-gamepad --teardown  # remove the hidpad gadget, free the UDC
```

It is **not** wired to start automatically. There is a single UDC, so an
always-on HID gadget would conflict with the `cdc`/`mtp` gadgets (and any other
gadget) that also want it — start it on demand.

### Verifying from a host

```
$ lsusb | grep 1209
Bus 001 Device 013: ID 1209:0001 Generic pid.codes Test PID
$ ls /dev/input/by-id/ | grep -i panicos
usb-PanicOS_H700_Gamepad_panicos-hidpad-0001-event-joystick
usb-PanicOS_H700_Gamepad_panicos-hidpad-0001-joystick   # -> js0
```

The host parses it as 16 buttons + X/Y/Rx/Ry axes + a D-pad hat. The VID/PID is
`1209:0001` (pid.codes community test ID); change `idVendor`/`idProduct` in the
script if a specific identity is required.

---

## Files

- `soc/allwinner-h700/mainline/linux/linux.config.fragment` — gadget kernel config
- `soc/allwinner-h700/mainline/rootfs-overlay/usr/bin/panicos-hid-gamepad` — bridge

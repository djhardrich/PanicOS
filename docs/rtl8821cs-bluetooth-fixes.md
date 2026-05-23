# RTL8821CS Bluetooth Fixes on Allwinner H700 (RG35XX Pro)

**Platform:** Allwinner H700 (sun50i-h616 family), RTL8821CS combo chip  
**Kernel:** mainline 7.0.x with ROCKNIX patches  
**BlueZ:** 5.79  
**Symptoms fixed:** hci-out-of-order dmesg spam, hci0 missing at boot,
BLE scan/pair completely non-functional, classic BT gamepads failing
with `br-connection-profile-unavailable`, BR/EDR HID devices not
creating `/dev/input/` nodes.

---

## Fix 1 — `rtl8821cs_config.bin`: wrong firmware config blob

**Root cause:** The RTL8821CS ships in two variants — USB and SDIO.
The SDIO variant (used on H700) requires a different `rtl8821cs_config`
firmware blob to configure H5 (3-wire) UART flow control. The
out-of-tree firmware package was shipping a USB-variant 19-byte blob
(and in some distros a generic 25-byte `rtl8761b_config` via symlink),
which left the H5 flow-control TLV entry absent, producing
`hci0: Recv frame when recv_evt is not set` / `hci-out-of-order` errors
in dmesg.

**Fix:** Replace `rtl_bt/rtl8821cs_config.bin` with the correct
29-byte SDIO-variant blob sourced from the ROCKNIX RTL8821CS-firmware
package. If your distro symlinks `rtl8821cs_config.bin` →
`rtl8761b_config.bin`, break the symlink — these are distinct chips
and configs should be independent.

**Correct blob (29 bytes, md5: 37338e0b8861a20ce877c0a10cbaaae3):**
```
55ab 2387 1700 0c00 1002 8092 0450 c5ea
19e1 1bfd af5f 01a4 0be4 0001 08
```

Source: `ROCKNIX/packages/linux-firmware/RTL8821CS-firmware/firmware/rtl8821cs_config`

---

## Fix 2 — `CONFIG_BT_LE`: BLE completely disabled in kernel

**Root cause:** `# CONFIG_BT_LE is not set` was explicit in the kernel
config. BLE scanning, advertising, and pairing were entirely
non-functional. `bluetoothctl scan on` would not discover BLE devices;
`btmgmt` would report LE unsupported.

**Fix:**
```
CONFIG_BT_LE=y
```

This is the master switch for Bluetooth Low Energy support. Without it
no BLE profiles (HoG, A2DP over LE, etc.) can function and modern
controllers that use BLE for pairing advertisement won't be
discoverable.

**Side effect:** Enabling `CONFIG_BT_LE=y` triggers a boot-time probe
race — see Fix 3.

---

## Fix 3 — `hci_uart` serdev probe race at boot (hci0 never appears)

**Root cause:** With `CONFIG_BT_LE=y` enabled, the `hci_uart` serdev
driver performs additional chip feature queries during probe (LE feature
pages, LE states, etc.). This extends the probe window enough that it
races the RTL8821CS rfkill GPIO de-assertion at boot and the probe
silently defers. The result: `hci0` never appears in
`/sys/class/bluetooth/` and bluetoothd starts with no adapter.

This does not affect kernels with `CONFIG_BT_LE` disabled because the
probe is shorter and wins the race.

**Fix:** A oneshot systemd service that runs after `bluetooth.service`,
checks whether `hci0` already exists, and if not, force-reloads the
`hci_uart` module:

```ini
[Unit]
Description=RTL8821CS Bluetooth UART re-probe workaround
After=bluetooth.service
Wants=bluetooth.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c '[ -d /sys/class/bluetooth/hci0 ] && exit 0; modprobe -r hci_uart btrtl 2>/dev/null; modprobe hci_uart'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

**Critical detail — module unload order:** `btrtl` cannot be unloaded
while `hci_uart` holds a reference to it. The unload order **must** be
`hci_uart` first, then `btrtl`. Reversing the order (`modprobe -r btrtl
hci_uart`) causes `btrtl` to fail silently; `hci_uart` remains loaded
with the deferred probe and `hci0` still never appears.

Enable the service: `systemctl enable bt-wakeup.service`

---

## Fix 4 — `CONFIG_UHID`: BLE HID devices have no input node

**Root cause:** BlueZ's HOG (HID over GATT) plugin creates virtual HID
devices via the UHID kernel interface (`/dev/uhid`). Without
`CONFIG_UHID=y`, `/dev/uhid` does not exist and BLE HID peripherals
(gamepads, keyboards, mice using BLE) connect at the BlueZ layer but
produce no `/dev/input/eventN` node — they are invisible to the input
subsystem.

**Fix:**
```
CONFIG_UHID=y
```

---

## Fix 5 — `CONFIG_BT_HIDP`: BR/EDR HID plugin race with module load

**Root cause:** `CONFIG_BT_HIDP=m` (compiled as a module). BlueZ's
`input` plugin calls into the HIDP kernel socket interface at init time.
If `hidp.ko` is not loaded before `bluetoothd` starts, the plugin's
`hidp_init()` call fails silently — `init_plugin()` does **not** log
"System does not support input plugin" for HIDP failures the way it
does for missing kernel features. The plugin appears to load, but the
HID profile driver is never registered.

Consequence: classic BR/EDR HID devices (Nintendo Pro Controller,
PS3/PS4/PS5 controllers over BR/EDR, any Bluetooth keyboard or mouse)
connect at the link layer (`ServicesResolved: yes`) but immediately
return `org.bluez.Error.NotAvailable br-connection-profile-unavailable`
because no BlueZ profile handler claimed the `Human Interface Device`
UUID (0x1124).

Confirmed via debug: bluetoothd started, listed every plugin load, but
`input` never appeared in the load list. `strings bluetoothd | grep
input` showed the symbol present — the binary was correct, the kernel
wasn't ready.

**Fix (preferred):** Build HIDP into the kernel so it is always
available before any userspace starts:
```
CONFIG_BT_HIDP=y
```

**Fix (belt-and-suspenders for =m kernels):** Add a
`/etc/modules-load.d/bt-hid.conf` with `hidp` so systemd-modules-load
loads it before bluetooth.service:
```
# BR/EDR HID — must be loaded before bluetoothd
hidp
```

---

## Fix 6 — BlueZ `input` / `hog` / `sixaxis` plugins not built

**Root cause:** BlueZ is often packaged without the HID/HOG/sixaxis
plugins compiled in. These are gated by separate build flags
(`--enable-hid`, `--enable-hog`, `--enable-sixaxis` in BlueZ's
configure script, or `BR2_PACKAGE_BLUEZ5_UTILS_PLUGINS_HID=y` in
Buildroot). The default BlueZ build in many embedded distros omits them.

Without `input`: BR/EDR HID (gamepads, keyboards) fail with
`br-connection-profile-unavailable`.

Without `hog`: BLE HID (BLE gamepads, BLE keyboards/mice) connect at
the GATT layer but no virtual `/dev/input/` node is created.

Without `sixaxis`: Sony DualShock 3/4 controllers using the native
Sony HID protocol (distinct from standard HID) are not handled.

**Fix:** Build BlueZ with all HID-related plugins enabled. In Buildroot:
```
BR2_PACKAGE_BLUEZ5_UTILS_PLUGINS_HID=y      # input + hog (HOG selects HID)
BR2_PACKAGE_BLUEZ5_UTILS_PLUGINS_SIXAXIS=y  # Sony DS3/DS4
```

**Dependency chain:**
- `PLUGINS_HID` selects `PLUGINS_HOG` automatically
- `PLUGINS_SIXAXIS` selects `PLUGINS_HID` automatically
- `PLUGINS_HOG` requires kernel headers ≥ 3.18
- `PLUGINS_SIXAXIS` requires udev (`BR2_PACKAGE_HAS_UDEV` — provided by systemd)

---

## Summary — Checklist for RTL8821CS BT on H700

| # | What | How |
|---|------|-----|
| 1 | Correct firmware config blob | `rtl_bt/rtl8821cs_config.bin` = 29-byte SDIO variant |
| 2 | Enable BLE in kernel | `CONFIG_BT_LE=y` |
| 3 | Fix hci0 boot race (caused by #2) | Oneshot systemd service: reload `hci_uart` after `bluetooth.service` if hci0 absent; unload order: `hci_uart` then `btrtl` |
| 4 | BLE HID input nodes | `CONFIG_UHID=y` |
| 5 | BR/EDR HID input nodes | `CONFIG_BT_HIDP=y` (built-in); or load `hidp` before bluetoothd via modules-load.d |
| 6 | BlueZ profile handlers | Build BlueZ with `--enable-hid --enable-hog --enable-sixaxis` |

All six are required for full functionality. Fixes 1–4 are kernel/firmware
level and apply regardless of BlueZ build options. Fixes 5–6 are the
userspace layer that actually routes connected devices into
`/dev/input/`.

---

## Verification

After applying all fixes, a Nintendo Pro Controller (BR/EDR) should:

```
$ bluetoothctl connect E4:17:D8:33:9C:A9
Connection successful

$ cat /proc/bus/input/devices | grep -A5 "Pro Controller"
N: Name="Pro Controller"
P: Phys=68:8f:c9:b5:3b:b7
S: Sysfs=/devices/virtual/misc/uhid/0005:057E:2009.0001/input/input4
U: Uniq=e4:17:d8:33:9c:a9
H: Handlers=event4
```

And bluetoothd startup should log `Bluetooth management interface X.Y
initialized` without any `hci-out-of-order` errors in dmesg.

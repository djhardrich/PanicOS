# H700 Lid Sleep, Display Resolution & Audio Output Settings

**Platform:** Allwinner H700 (RG34XX-SP, RG35XX SP, RG35XX Plus, RG35XX Pro)  
**Affected packages:** `panicos-input-sense`, `panicos-emulationstation`, `panicos-quirks`

---

## Overview

This document covers three related features added to PanicOS for H700 devices:

1. **Lid sleep fix** — `gpio-keys-lid` was not discovered by `input_sense` because it is an EV_SW-only device, so lid close/open events were silently dropped.
2. **`displayoff` lid sleep mode** — a new soft-suspend mode that only zeroes the backlight, without touching CPU governors, audio, or input blocking.
3. **ES system settings** — `AUDIO OUTPUT` and `VIDEO MODE` (HDMI resolution) selectors now appear in ES System Settings, backed by new `set-audio`, `batocera-resolution`, and `rocknix-resolution` scripts.

---

## 1. Lid Sleep Fix (`input_sense`)

### Root cause

`gpio-keys-lid` is a kernel input device that only generates `EV_SW / SW_LID` events. Because it carries no `EV_KEY` events, udev classifies it as `ID_INPUT_SWITCH=1` rather than `ID_INPUT_KEY=1`. The `get_devices()` function in `input_sense` only matched `ID_INPUT_KEY`, `ID_INPUT_JOYSTICK`, and `ID_INPUT_TOUCHSCREEN`, so the lid switch device was never monitored.

### Fix

Added `ID_INPUT_SWITCH=` to the udevadm awk filter in `get_devices()`:

```bash
# package/panicos-input-sense/files/scripts/input_sense
SUPPORTS=$(udevadm info ${DEV} | awk \
  '/ID_INPUT_KEY=|ID_INPUT_JOYSTICK=|ID_INPUT_TOUCHSCREEN=|ID_INPUT_SWITCH=/ {print $2}')
```

---

## 2. `displayoff` Lid Sleep Mode

### Motivation

Full fake-suspend (CPU powersave governors, audio mute, input blocking, LED disable) is disruptive when closing a clamshell device briefly. The `displayoff` mode only zeroes the backlight and restores it on open — no other side effects.

### Implementation (`rocknix-fake-suspend`)

Two helper functions were added:

```bash
lid_display_off() {
  for dev in /sys/class/backlight/*/brightness; do
    echo 0 > "${dev}"
  done
  touch "${LID_DISPLAY_OFF_FLAG_FILE}"
}

lid_display_on() {
  rm -f "${LID_DISPLAY_OFF_FLAG_FILE}"
  local PCT=$(get_setting display.brightness)
  [[ -z "${PCT}" ]] && PCT=80
  brightness set "${PCT}"
}
```

`brightness set 0` is intentionally avoided — the `brightness` script clamps to a 5% minimum. Writing directly to sysfs bypasses this.

### Setting

Controlled by `system.lid.sleep.mode` in `system.cfg`:

| Value | Behaviour |
|---|---|
| `fake` (default) | Full fake-suspend: display off, audio mute, CPU powersave, core parking, input block |
| `displayoff` | Backlight zeroed only; CPU/audio/input unaffected |

The lid close handler branches on this setting; the lid open handler checks for `LID_DISPLAY_OFF_FLAG_FILE` (`/var/run/lid-display-off.flag`) to decide whether to call `lid_display_on()` or the full `resume()`.

### Default for hinge devices

`package/panicos-quirks/files/devices/Anbernic RG34XX-SP/030-lid-mode` and the equivalent for `Anbernic RG35XX SP` set `system.lid.sleep.mode=displayoff` at autostart if the setting is unset. This runs once on first boot; subsequent user changes via ES are preserved.

### ES UI

The `LID SLEEP MODE` dropdown appears in ES → System Settings → SUSPEND (the fake-suspend section, active for H700). Implemented as a patch to `GuiMenu.cpp` (`package/panicos-emulationstation/0001-guimenu-add-lid-sleep-mode-setting.patch`).

---

## 3. AUDIO OUTPUT Selector (`set-audio`)

### Interface

ES calls `set-audio` with the following subcommands:

| Call | Purpose |
|---|---|
| `set-audio list` | Print `node.name\tnode.description` per PipeWire sink |
| `set-audio get` | Print the active sink's `node.name` |
| `set-audio set 'node.name'` | Set default sink; persist to `audio.device` |
| `set-audio list-profiles` | No-op (PipeWire has no profile concept at this level) |
| `set-audio get-profile` | Returns `default` |
| `set-audio set-profile` | No-op |

### Implementation

Uses `pw-dump` (JSON) + Python 3 to enumerate `Audio/Sink` nodes. `node.name` is used as the stable ID (derived from the ALSA device path or Bluetooth MAC), not the numeric PipeWire node ID which changes across reboots.

`wpctl set-default <numeric-id>` is used to apply the change in the current session; the `node.name` is stored in `system.cfg` via `set_setting audio.device` and re-applied on the next boot by re-running `set-audio set`.

### Typical sinks on H700

| node.name (abbreviated) | Description |
|---|---|
| `alsa_output...card1.stereo-fallback` | Built-in Audio Stereo (HDMI) |
| `alsa_output...card0.HiFi__Speaker__sink` | Built-in Audio Internal Speaker |
| `bluez_output.<MAC>.1` | Bluetooth device |
| `alsa_output.usb-...` | USB audio device |

---

## 4. HDMI Resolution Selector (`batocera-resolution` / `rocknix-resolution`)

### Background

PanicOS runs ES as a **Wayland client of Sway** (`SDL_VIDEODRIVER=wayland`), not in KMSDRM mode. Display resolution changes therefore go through `swaymsg`, not DRM sysfs.

### Scripts

**`rocknix-resolution`** — existence gate; ES calls `isScriptingSupported(RESOLUTION)` which checks for `/usr/bin/rocknix-resolution`. Also serves `rocknix-config lsoutputs` via `listOutputs`, querying `swaymsg -t get_outputs`.

**`batocera-resolution`** — actual mode lister and applier:

| Call | Behaviour |
|---|---|
| `batocera-resolution listModes` | List `WxH@R:WxH @ RHz` for the connected HDMI/DP output |
| `batocera-resolution --screen <output> listModes` | Same, for a specific Sway output name |
| `batocera-resolution apply` | Read `es.resolution` from `system.cfg`; call `swaymsg output <HDMI> resolution WxH refresh R` |

Mode format stored in `es.resolution`: `1920x1080@60`

### Boot application

`panicos-es.service` runs `batocera-resolution apply` as an `ExecStartPre` step after the Wayland socket is confirmed available but before ES initialises:

```ini
ExecStartPre=-/usr/bin/batocera-resolution apply
```

The `-` prefix means a non-zero exit (e.g. HDMI not connected) is silently ignored.

---

## Files Changed

| File | Change |
|---|---|
| `package/panicos-input-sense/files/scripts/input_sense` | Add `ID_INPUT_SWITCH=` to `get_devices()` udevadm filter |
| `package/panicos-input-sense/files/scripts/rocknix-fake-suspend` | Add `displayoff` lid mode, `lid_display_off/on` helpers, `LID_SLEEP_MODE` setting, `LID_DISPLAY_OFF_FLAG_FILE` |
| `package/panicos-input-sense/files/scripts/set-audio` | New: PipeWire audio output selector |
| `package/panicos-input-sense/files/scripts/batocera-resolution` | New: Sway display mode lister and applier |
| `package/panicos-input-sense/files/scripts/rocknix-resolution` | New: ES RESOLUTION feature gate + output lister |
| `package/panicos-emulationstation/files/panicos-es.service` | Add `ExecStartPre=-batocera-resolution apply` |
| `package/panicos-emulationstation/0001-guimenu-add-lid-sleep-mode-setting.patch` | New: LID SLEEP MODE dropdown in ES SUSPEND section |
| `package/panicos-quirks/files/devices/Anbernic RG34XX-SP/030-lid-mode` | New: default `system.lid.sleep.mode=displayoff` for RG34XX-SP |
| `package/panicos-quirks/files/devices/Anbernic RG35XX SP/030-lid-mode` | New: default `system.lid.sleep.mode=displayoff` for RG35XX SP |

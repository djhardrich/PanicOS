# ES: BT Controller Post-Pair Visibility + CPU Governor Persistence Fixes

**Platform:** Allwinner H700 (RG35XX Pro)  
**Affected:** EmulationStation — Controller & Bluetooth Settings, System Settings  
**Symptoms:**
- Bluetooth controllers paired in ES work for UI navigation but never appear in
  Player Assignments (Controller & Bluetooth Settings → Player 1–8 dropdowns)
- CPU Governor setting can't be changed from "Default" — selection doesn't apply
  or persist across reboots

---

## Fix 1 — BT controllers invisible in Player Assignments after pairing

### Root cause

`GuiControllersSettings` builds its player-assignment dropdown lists once, at
construction time, by calling `InputManager::getInputConfigs()`. This returns
only joysticks that are already configured (i.e., already present when the
settings screen opened).

`GuiBluetoothPair` runs the pairing flow in a background thread via `ApiSystem`.
On success it called `delete this` and returned — no notification back to
`GuiControllersSettings`. The parent stayed open with its stale controller list.
The newly paired device was already attached (SDL had fired `SDL_JOYDEVICEADDED`
→ `rebuildAllJoysticks()` → auto-configured via SDL GameControllerDB), but the
UI never refreshed to show it.

### Fix

`GuiBluetoothPair` now accepts an optional `std::function<void()> onPairSuccess`
callback. In `onPairDevice` the result lambda captures `mOnPairSuccess` before
`delete this`, then invokes it after deletion:

```cpp
auto cb = mOnPairSuccess;
delete this;
if (cb)
    cb();
```

`GuiControllersSettings` passes a callback that closes itself and immediately
reopens a fresh instance (which re-queries `getInputConfigs()` against the now
up-to-date controller list):

```cpp
window->pushGui(new GuiBluetoothPair(window, [cs, window]()
{
    Window* parent = window;
    cs->setSave(false);
    delete cs;
    openControllersSettings(parent);
}));
```

The `setSave(false)` call prevents `GuiControllersSettings` from writing a
partial save on its way out. The re-opened instance picks up all connected
controllers including the one just paired.

### Files changed

- `es-app/src/guis/GuiBluetoothPair.h` — added `onPairSuccess` param + `mOnPairSuccess` member
- `es-app/src/guis/GuiBluetoothPair.cpp` — constructor stores callback; `onPairDevice` calls it post-`delete this`
- `es-app/src/guis/GuiControllersSettings.cpp` — passes refresh callback from the "PAIR A BLUETOOTH DEVICE MANUALLY" entry

---

## Fix 2 — CPU Governor setting doesn't apply or persist

Two separate bugs, both needed to be fixed:

### Bug A — applying "Default" exited 127 (command not found)

`GuiMenu.cpp` applies the CPU governor by sourcing `099-freqfunctions` and
calling the selected value as a shell function:

```bash
. /etc/profile.d/099-freqfunctions; default
```

`099-freqfunctions` defined `performance()`, `ondemand()`, `schedutil()`, and
`powersave()` — but **no `default()` function**. The shell call exited 127.

**Fix:** Added `default()` to `package/panicos-input-sense/files/profile.d/099-freqfunctions`:

```bash
default() {
  set_cpu_gov schedutil
  set_dmc_gov ondemand
}
```

This matches the H700 kernel defaults (`schedutil` on all CPU policies,
`ondemand` on the DMC DRAM frequency controller).

### Bug B — "Default" written to system.cfg as a literal value and re-applied at boot

`SystemConf::saveSystemConf()` has two code paths for updating a key:

1. **Existing line found** — replaces it (or removes it if value is "default")
2. **No existing line** — appends `key=value`

The new-line append path only excluded `"auto"`:

```cpp
// Before:
if (!val.empty() && val != "auto")
    fileLines.push_back(key + val);
```

Selecting "Default" on a device that had never saved a governor preference
(no existing `system.cpugovernor` line) caused `system.cpugovernor=default`
to be written. On next boot the boot scripts read this value and called
`default` as a shell command — which failed at 127 until Bug A was fixed,
and was semantically wrong regardless (the intent of "default" is to use the
kernel default, i.e., write nothing).

**Fix:** Exclude `"default"` the same way `"auto"` is excluded:

```cpp
// After:
if (!val.empty() && val != "auto" && val != "default")
    fileLines.push_back(key + val);
```

### Files changed

- `package/panicos-input-sense/files/profile.d/099-freqfunctions` — added `default()`
- `es-core/src/SystemConf.cpp` — exclude `"default"` from new-line creation

---

## ES fork

These ES-side changes live on the `panicos-main` branch of
`https://github.com/djhardrich/emulationstation-next`. The upstream is
`ROCKNIX/emulationstation-next`; we forked at `5890d64` to carry our patches.

`package/panicos-emulationstation/panicos-emulationstation.mk` now pins to:

```makefile
PANICOS_EMULATIONSTATION_VERSION = 4a6c9f2f2a8e030dec8c6e108236f79ad38072b9
PANICOS_EMULATIONSTATION_SITE = https://github.com/djhardrich/emulationstation-next.git
```

### Workflow for future ES changes

1. Edit source in `third_party/buildroot/dl/panicos-emulationstation/git/`
2. Commit to `panicos-main` in that repo and push to `djhardrich/emulationstation-next`
3. Update `PANICOS_EMULATIONSTATION_VERSION` in the `.mk` to the new commit SHA
4. `pkg-rebuild panicos-emulationstation` + `image-variant DEVICE=rg35xx-pro-lpddr3 BASE=rg35xx-pro FLAVOR=launcher`

When pulling upstream ROCKNIX updates: merge or rebase `ROCKNIX/master` into
`panicos-main`, resolve conflicts, push, bump the SHA.

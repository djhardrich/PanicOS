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

## Fix 3 — completing the governor function set (per-game / runemu path)

> **Correction:** an earlier revision of this section claimed adding
> `conservative()`/`userspace()` fixed the *System Settings* governor menu. That
> was wrong — see **Fix 4** for the actual ES-menu root cause. The function
> additions below are still valid, but they only matter for the **per-game**
> governor path: `runemu.sh` applies the per-game governor by calling the value
> as a shell function (`${CPU_GOVERNOR}`) after sourcing `099-freqfunctions`,
> and that path *does* run in a normal shell context. Without these functions,
> selecting `conservative`/`userspace` as a per-game governor was a no-op.

### Root cause (per-game path)

The governor list in the menu comes straight from the kernel via
`ApiSystem::getAvailableCpuGovernors()`:

```cpp
// es-app/src/ApiSystem.cpp
sh -lc "echo default; tr ' ' '\n' < /sys/devices/system/cpu/cpufreq/policy0/scaling_available_governors" | grep [a-z]
```

On H700 that yields all six standard cpufreq governors plus `default`:
`conservative ondemand userspace powersave performance schedutil`. The menu
therefore *exposes* every governor type already (no ES change needed for that).

`runemu.sh` applies the per-game governor by calling the value as a shell
function after sourcing `099-freqfunctions` (`${CPU_GOVERNOR}`).
`099-freqfunctions` defined functions only for `performance`, `ondemand`,
`schedutil`, `powersave`, and `default` — so a per-game governor of
**`conservative` or `userspace`** ran `conservative: command not found` and was
a no-op.

### Fix

Added the two missing functions to
`package/panicos-input-sense/files/profile.d/099-freqfunctions`, completing the
full set of six standard cpufreq governors. DRAM (DMC) is mapped to `ondemand`
to match the dynamic-governor convention already used by `schedutil`/`default`
(no-op on H700, which does not export a DMC devfreq node):

```bash
conservative() {
  set_cpu_gov conservative
  set_dmc_gov ondemand
}

userspace() {
  set_cpu_gov userspace
  set_dmc_gov ondemand
}
```

### Files changed

- `package/panicos-input-sense/files/profile.d/099-freqfunctions` — added `conservative()` and `userspace()`

---

## Fix 4 — System Settings governor menu never applied ANY governor

This is the real cause of "I pick a governor in ES and nothing changes, even
after a reboot." It is **not** the missing functions (Fix 3) — it affected every
governor, including `performance`/`powersave`.

### Root cause

`GuiMenu.cpp` applied the *System Settings* governor by handing this string to
`Utils::Platform::runSystemCommand` (`GuiMenu.cpp:1945`):

```
/usr/bin/sh -lc ". /etc/profile.d/099-freqfunctions; <selected>"
```

`runSystemCommand` double-forks and `execl("/usr/bin/sh","sh","-c",<whole string>,NULL)`,
running the selected value as a `099-freqfunctions` shell function in a login shell.

> **Correction — this command was never even reached.** An earlier revision of
> this section blamed login-shell sourcing failing in ES's environment. That was
> wrong. ES *aborts* (SIGABRT) the instant you back out of the menu, inside
> `OptionListComponent::getSelected()`, **before any save function body runs** —
> that is the true root cause, documented in **Fix 5**. The echo change below is
> still worth keeping (it drops the fragile login-shell + per-governor-function
> indirection and is verified to apply every governor via a direct sysfs write),
> but on its own it fixed nothing, because ES crashed before it ran.

### Fix

Replace the login-shell + function-call indirection with a direct sysfs write —
the exact command verified working on-device (`echo <gov> | tee
scaling_governor`). No profile sourcing, no per-governor functions, works for
every governor the kernel lists:

```cpp
// es-app/src/guis/GuiMenu.cpp  (System Settings "DEFAULT SCALING GOVERNOR")
std::string gov = optionsGovernors->getSelected();
if (!gov.empty() && gov != "default")
    Utils::Platform::runSystemCommand(
        "echo " + gov + " | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor > /dev/null 2>&1",
        "", nullptr);
```

`default` is treated as "leave the kernel default in place" (and `SystemConf`
already excludes `default`/`auto` from persistence — Fix 2 Bug B).

The menu list itself was never the problem: `getAvailableCpuGovernors()` reads
`scaling_available_governors` directly, so all six governors are already exposed.

### Files changed

- `es-app/src/guis/GuiMenu.cpp` — System Settings governor now echoes to sysfs instead of sourcing `099-freqfunctions` in a login shell

### Verification

Rebuilt ES, confirmed the binary embeds the `tee … scaling_governor` command
(and no longer the `099-freqfunctions` CPU call), deployed to device. Final
confirmation is interactive (pick a governor in System Settings → governor
changes live).

---

## Fix 5 — ES crashes (SIGABRT) on menu exit → the TRUE root cause

This is why the governor (and any System Settings change) "did nothing, even after
a reboot": **EmulationStation was crashing every time you backed out of the
settings menu after changing the governor.** It predates all the above changes.

### Evidence

`journalctl -u panicos-es.service`:

```
panicos-es.service: Main process exited, code=dumped, status=6/ABRT
panicos-es.service: Failed with result 'core-dump'
emulationstation[…]: terminate called after throwing an instance of 'std::exception'
```

Backtrace (gdb, break on `std::__throw_out_of_range_fmt`, unstripped binary):

```
#1 OptionListComponent<std::string>::getSelected()
#2 GuiMenu::openSystemSettings()::{lambda()#4}   (the governor save func)
#3 GuiSettings::close()                           (runs save funcs on back-out)
#4 GuiSettings::input()
```

### Root cause

`OptionListComponent`'s single-select **popup pick handler** captured the
loop-local reference `OptionListData& e = *it` (`[this, &e]`) in a lambda that
outlives the loop, then did `getSelectedId()`-deselect + `e.selected = true`. The
net result was that after a pick **zero** entries were left flagged `selected`.

On menu close, `GuiSettings::close()` runs the governor save lambda, which calls
`optionsGovernors->getSelected()`. `getSelected()` did `getSelectedObjects().at(0)`
with **no guard** — `.at(0)` on an empty vector throws `std::out_of_range`. The
`TRYCATCH` macro around the event loop (`Log.h`) logs the error and then
**re-throws** (`throw e;`), and `main`'s event loop has no handler →
`std::terminate` → SIGABRT. (`assert(selected.size()==1)` above the `.at(0)` is
compiled out under `NDEBUG`.)

### Fix

`es-core/src/components/OptionListComponent.h`:

1. **Both single-select popup pick handlers** now capture the entry **index by
   value** and do an explicit "deselect all → select the chosen index", instead of
   capturing a loop-local reference. Guarantees exactly one entry is selected:

   ```cpp
   size_t selIdx = (size_t)(it - mParent->mEntries.begin());
   row.makeAcceptInputHandler([this, selIdx] {
       for (auto& en : mParent->mEntries) en.selected = false;
       mParent->mEntries.at(selIdx).selected = true;
       mParent->onSelectedChanged();
       delete this;
   });
   ```

2. **`getSelected()` no longer aborts on an empty selection** (defense in depth) —
   returns `firstSelected` instead of `.at(0)`-throwing.

### Files changed

- `es-core/src/components/OptionListComponent.h` — index-based popup selection (×2) + non-throwing `getSelected()`

### Verification (on-device)

Set governor to `powersave` in System Settings → back out:
`scaling_governor` = `powersave` (changed live), `NRestarts=0` (no crash), no core
dump, and `system.cpugovernor=powersave` persisted to `system.cfg`.

---

## Fix 6 — "Pair Bluetooth Pads Automatically" never pairs

Manual pairing worked; **auto-pair did nothing**. This is a script-side fix
(`panicos-input-sense`), not an ES code change.

### Flow

```
ES: Controller Settings -> "PAIR BLUETOOTH PADS AUTOMATICALLY"
  -> ThreadedBluetooth::start -> ApiSystem::scanNewBluetooth()
  -> rocknix-bluetooth trust input            (es-app/src/ApiSystem.cpp)
```

`rocknix-bluetooth trust input` writes `input` to `/run/bt_device`, then polls
`/run/bt_status` for 60 s. The actual scanning/pairing is done by the Python
`rocknix-bluetooth-agent` (`bluetooth-agent.service`).

### Root cause

The agent only scans/pairs **while the adapter is in discovery**, and discovery
is started *only* by writing `start` to `/run/bt_discovery_control`.
`do_devlist` (the manual "live devices" scan) does this — but **`do_trust` did
not**. So `trust input` set the mode flag but never started a scan; the adapter
stayed `Discovering: no` and the agent found nothing.

Confirmed on-device: after `trust input`, `bluetoothctl show` → `Discovering: no`,
and `/var/log/bluetooth-agent.log` showed only repeated `bt_dev: input`, never
`Interface added`.

### Fix

`package/panicos-input-sense/files/scripts/rocknix-bluetooth` — `do_trust` now
starts/stops discovery for auto-pair mode (mirrors `do_devlist`):

```sh
echo "${TRUSTDEV}" > "${BT_DEVICE_FILE}" || return 1
if [ "${TRUSTDEV}" = "input" ]; then
    echo "start" > "${BT_CONTROL_FILE}"     # begin scan
fi
# ... 60 s poll loop ...
if [ "${TRUSTDEV}" = "input" ]; then
    echo "stop" > "${BT_CONTROL_FILE}"      # end scan
fi
```

### Controller filter (already correct — matches ROCKNIX)

The agent pairs a discovered device only if its BlueZ `Icon` property
`startswith("input")` (so audio devices like `Core400s` are skipped). During
early discovery `Icon` is often unresolved → log shows
`Skipping device … (no type, needed for 'input' filter)`; the device pairs once
`Icon` resolves (e.g. `input-gaming`) via a later PropertiesChanged event. No
change was needed here.

### Notes / gotchas

- `rocknix-bluetooth` and `rocknix-bluetooth-agent` are shipped by **both**
  `panicos-input-sense` and `panicos-net-tools`; the **input-sense** copy is the
  one that lands on-device (`CACHE_PATH=/var/lib`). Edit that one.
- Pure script change: `pkg-rebuild PACKAGE=panicos-input-sense` + lpddr3
  `image-variant`. No ES recompile.
- Debug live: `bluetoothctl show | grep Discovering` and tail
  `/var/log/bluetooth-agent.log`.

### Verification (on-device)

Controller in pairing mode → ES "PAIR BLUETOOTH PADS AUTOMATICALLY" → adapter
enters discovery, agent scans, controller pairs/trusts/connects. (Committed
`d12aa59`.)

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

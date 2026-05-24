# PortMaster BT Controller Button Mapping Fixes (H700 / Nintendo-layout devices)

**Platform:** Allwinner H700 (RG35XX Pro) and any Nintendo-layout ARM handheld  
**Affected:** All PortMaster ports when using an external Bluetooth controller  
**Symptoms:** A/B and X/Y buttons inverted on all BT controllers; some ports
crash immediately when any controller is connected.

---

## Background — two button layout conventions in SDL

SDL's `SDL_GameControllerDB` assigns logical button names (`a`, `b`, `x`, `y`)
that mean different things depending on convention:

| Convention | SDL `a` (south) | SDL `b` (east) |
|------------|-----------------|----------------|
| **Xbox / SDL default** | ⓐ south face | ⓑ east face |
| **Nintendo** | east face (A) | south face (B) |

Handheld devices like the RG35XX Pro use **Nintendo layout** — the
`rocknix-joypad` kernel driver reports button 0 as south (physical B),
button 1 as east (physical A). A custom `gamecontrollerdb.txt` entry
maps these correctly: `a:b1,b:b0,x:b3,y:b2`.

External Bluetooth controllers (Xbox One, PS3/PS4/PS5, Switch Pro, 8BitDo)
use **Xbox convention** — their Bluetooth GUIDs (`05000000...`) map
`a:b0,b:b1,x:b2,y:b3` in the community SDL database. PortMaster ships
this ~1800-entry community database unchanged.

When a BT controller connects, SDL finds its GUID in the PortMaster
database and maps buttons Xbox-style. PortMaster then re-maps those SDL
buttons using its Nintendo-convention A/B/X/Y action map — two wrong
remaps in series that produce inverted controls.

---

## Fix 1 — E2BIG crash in all ports with any controller connected

**Root cause:** PortMaster's `mod_PanicOS.txt` `get_controls()` function
read the entire `gamecontrollerdb.txt` (472 KB) into a shell variable and
assigned it to `sdl_controllerconfig`. Port launch scripts then did:

```bash
export SDL_GAMECONTROLLERCONFIG="$sdl_controllerconfig"
```

`SDL_GAMECONTROLLERCONFIG` is a per-process environment variable. At
~472 KB it pushes the total environment over the kernel's `ARG_MAX` limit
(128 KB on Linux). Every subsequent `exec` call — including the game
binary itself — returns `E2BIG` and the port crashes immediately.

This crash only triggered when a controller was connected because
`get_controls()` conditionally reads the db only in that branch.

**Fix:** Set `sdl_controllerconfig=""` unconditionally. SDL does not need
the db in the environment — it reads it from a file path. External
controllers still work because SDL reads `SDL_GAMECONTROLLERCONFIG_FILE`
(or its built-in db) at runtime. The env var stays empty.

```bash
# mod_PanicOS.txt get_controls() — WRONG:
sdl_controllerconfig="$(cat /path/to/gamecontrollerdb.txt)"

# CORRECT — point at the file, never copy content into env:
sdl_controllerconfig=""
export SDL_GAMECONTROLLERCONFIG_FILE="/path/to/gamecontrollerdb.txt"
```

**Key constraint:** Never put `gamecontrollerdb.txt` content into any
environment variable. Any variable that port scripts may re-export is
subject to the same `ARG_MAX` limit. Even if the current port doesn't
crash, the pattern will break the next port that adds entries to the db.

---

## Fix 2 — A/B/X/Y inverted on BT controllers

**Root cause:** The device's custom `gamecontrollerdb.txt` had only
~25 entries covering ARM handheld GUIDs (wired joypad). Bluetooth
controllers have separate GUIDs with prefix `05000000` that were not in
the file. SDL fell back to its built-in Xbox-convention mapping for all
unrecognised BT GUIDs.

Simply adding the full PortMaster community database would fix coverage
but not the inversion — the community database uses Xbox convention,
which is wrong for Nintendo-layout devices.

**Fix (two parts):**

**Part A — build a merged database at runtime.**

`panicos-portmaster-fixup.sh` (runs before EmulationStation starts):

1. Caches the PortMaster community database to a stable path:
   ```
   /storage/.config/panicos/portmaster-gcdb-orig.txt
   ```
2. Builds a merged database:
   ```
   /storage/.config/panicos/gamecontrollerdb.txt
   = portmaster-gcdb-orig.txt       (BT coverage, Xbox convention)
   + custom gamecontrollerdb.txt    (Nintendo-remapped overrides)
   ```
   SDL uses the **last** matching entry for a given GUID. Appending the
   custom entries after the community database ensures overrides win.

3. Symlinks `$PMDIR/gamecontrollerdb.txt` → merged file so PortMaster
   and all ports see a single consistent path.

This survives PortMaster self-updates: the next boot re-caches and
re-merges from whatever PortMaster installed.

**Part B — add Nintendo-remapped BT overrides.**

The custom `gamecontrollerdb.txt` needed BT-GUID entries for every common
controller family, with A/B and X/Y swapped relative to the Xbox convention:

```
# H700 button numbering (rocknix-joypad driver):
#   b0 = south (physical B),  b1 = east (physical A)
#   b2 = west  (physical Y),  b3 = north (physical X)
# Nintendo target: SDL a=east(A), SDL b=south(B), SDL x=north(X), SDL y=west(Y)
# → a:b1,b:b0,x:b3,y:b2
```

Controller families added:

| Family | Bluetooth GUIDs | Change needed |
|--------|----------------|---------------|
| Xbox One BT (x:b2,y:b3 group) | `05000000...` | swap a↔b, swap x↔y |
| Xbox One/Elite/Series BT (x:b3,y:b4 group) | `05000000...` | swap a↔b, swap x↔y |
| PS3 BT | `05000000...` | swap a↔b only (x/y already correct) |
| PS4 BT | `05000000...` | swap a↔b only |
| PS5 BT | `05000000...` | swap a↔b only |
| Switch Pro (hid-nintendo) | `05000000...` | already Nintendo layout — confirm no-op |
| 8BitDo (hid-nintendo path) | `05000000...` | already Nintendo layout — confirm no-op |

**Why PS controllers need only a↔b:**  
Sony controllers report `Cross=b0(south), Circle=b1(east)`, matching
the H700's physical B/A position. Only the SDL label assignment is wrong
(SDL calls south `a`; Nintendo calls east `A`), so a single a↔b swap
corrects it without touching X/Y.

**Why Xbox controllers need both a↔b and x↔y:**  
Xbox `X=b2/b3` (west) and `Y=b3/b4` (north), but H700 has west=b2=Y and
north=b3=X, so both pairs need swapping.

---

## Fix 3 — BT controller overrides reverted by PortMaster self-update

**Root cause (regression after Fix 2):** After Fix 2 was deployed, a
PortMaster self-update replaced `$PMDIR/gamecontrollerdb.txt` with the
upstream community file, breaking the symlink and reverting to Xbox
convention.

**Root cause (second attempt — per-GUID entries in custom db):** The
per-GUID BT entries in `gamecontrollerdb.txt` had to be updated every
time a new controller variant was released, and any GUID not explicitly
listed fell back to Xbox convention.

**Fix:** Move from per-GUID overrides to a **Python-based remapping pass**
run at merge time in `panicos-portmaster-fixup.sh`:

```python
# For every entry in the PortMaster db whose GUID starts with '05000000'
# (Bluetooth), apply Nintendo remapping:
#   a:bN → a:b(N_remapped)  etc.
# Output: portmaster-gcdb-remap.txt
# Merge: remap.txt + custom entries (custom wins for any explicit GUID)
```

The remapping script iterates all ~1800 entries and rewrites button
assignments for BT GUIDs in bulk, so new controller models added by
PortMaster upstream are automatically remapped on the next boot without
any manual GUID tracking.

The per-GUID override entries in `gamecontrollerdb.txt` were then removed
(they were redundant with the bulk remap and cluttered the file).

---

## Summary — Checklist for PortMaster BT Controllers

| # | What | How |
|---|------|-----|
| 1 | E2BIG crash with any controller | Set `sdl_controllerconfig=""` in `get_controls()`; never copy db content into env vars |
| 2 | A/B/X/Y inverted on BT controllers | Merge PortMaster community db + Nintendo-remapped overrides; symlink PortMaster's db path to merged file |
| 3 | Overrides lost after PM self-update | Bulk-remap all `05000000` GUIDs with a Python pass at merge time; drop per-GUID override entries |

---

## File locations (PanicOS tree)

```
package/panicos-launcher-tools/files/
  gamecontrollerdb.txt           # small custom db (Nintendo handheld GUIDs + explicit BT overrides)
  panicos-portmaster-fixup.sh    # runs at boot; caches, bulk-remaps, merges, and symlinks
```

Runtime paths:
```
/storage/.config/panicos/portmaster-gcdb-orig.txt    # PortMaster community db (cached)
/storage/.config/panicos/portmaster-gcdb-remap.txt   # bulk-remapped BT entries
/storage/.config/panicos/gamecontrollerdb.txt        # final merged db (SDL reads this)
$PMDIR/gamecontrollerdb.txt → (symlink to above)
```

---

## Notes for ROCKNIX / other Nintendo-layout distros

Any distro on a Nintendo-layout handheld that ships PortMaster will have
the A/B inversion problem with BT controllers. The root cause is not
device-specific: it is a mismatch between SDL's Xbox-convention default
fallback and any device that remaps the physical buttons to Nintendo
convention.

The bulk-remap approach (Fix 3) is the most robust solution because it
requires no GUID maintenance. The merge-at-runtime pattern (Fix 2) is
required regardless — hard-coding overrides into the bundled db is fragile
against PortMaster self-updates.

The `E2BIG` crash (Fix 1) will affect any distro that reads db content
into `sdl_controllerconfig` when the db grows large. The community
PortMaster db is currently ~472 KB and growing. The fix is to use
`SDL_GAMECONTROLLERCONFIG_FILE` instead.

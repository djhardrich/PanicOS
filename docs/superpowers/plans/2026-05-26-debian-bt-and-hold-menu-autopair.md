# Debian squashfs: BT controller fix + hold-menu auto-pair — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Bluetooth functional on the Debian squashfs image and add a 5-second-hold Menu-button gesture that auto-pairs the first HID/audio Bluetooth device discovered.

**Architecture:** Two independent parts. **Part 1** is a mechanical port of the launcher image's existing BT fixes (firmware blob + `panicos-bt-wakeup.service`) into `build-debian-desktop.sh`. **Part 2** splits the existing `gamepad-mouse.py` into a thin system daemon that writes short/long-press events to a **Linux abstract unix datagram socket** (`\0panicos-menu`), plus a new per-user XDG-autostart agent that handles OSK toggle and BlueZ pairing. The abstract namespace sidesteps filesystem permissions entirely (no `/run/panicos` directory, no `RuntimeDirectory=`, no chmod), so the root daemon and unprivileged agent can communicate without setup. The split makes both behaviors DE-agnostic.

**Tech Stack:** bash (build script), Python 3 (`evdev`, `dbus`, `gi.repository.GLib`), systemd (`RuntimeDirectory=`), BlueZ 5.85 D-Bus API, XDG autostart spec.

**Spec:** [`docs/superpowers/specs/2026-05-26-debian-bt-and-hold-menu-autopair-design.md`](../specs/2026-05-26-debian-bt-and-hold-menu-autopair-design.md)

**Device under test:** `panicos@192.168.1.181` (sshpass password `panicos`).

---

## File Structure

**New files:**
- `debian-desktop/services/panicos-session-agent.py` — per-user agent, ~150 lines
- `debian-desktop/services/panicos-session-agent.desktop` — XDG autostart entry

**Modified files:**
- `scripts/build-debian-desktop.sh` — apt list, firmware blob fix, service install, user group, swapfile setup
- `debian-desktop/services/gamepad-mouse.py` — drop kbd uinput, add socket producer
- `debian-desktop/configs/wayfire.ini` — remove `binding_menu`

**Existing files referenced (read-only):**
- `soc/allwinner-h700/mainline/rootfs-overlay/usr/lib/firmware/rtl_bt/rtl8821cs_config.bin` (29-byte SDIO blob, md5 `37338e0b8861a20ce877c0a10cbaaae3`)
- `soc/allwinner-h700/mainline/rootfs-overlay/usr/lib/systemd/system/panicos-bt-wakeup.service`

---

## Important context

- **No unit-test framework** exists for `build-debian-desktop.sh` or the runtime daemons. "Testing" in this plan means a combination of (a) `bash -n` / `python3 -m py_compile` syntax checks, (b) a tiny stand-alone Python test for the socket protocol that can run on the dev host, and (c) on-device validation by SSH-ing into 192.168.1.181 after a rebuild.
- **Incremental rebuilds**: a full `build-debian-desktop.sh` run takes ~15–25 minutes. Group commits before a rebuild so we don't pay that cost more than once per logical chunk. The script is idempotent only if you `rm -rf output/debian-desktop/rootfs` first — it does this itself (`rm -rf "$ROOTFS"` at the top of the build), so each invocation is a clean rebuild.
- **Why `cp -a` of buildroot firmware clobbers `rtl8761b_config.bin`**: the broken Debian-side symlink `rtl8821cs_config.bin → rtl8761b_config.bin` already exists in the rootfs by the time the buildroot firmware tree is copied. `cp -a` follows the existing dest symlink and writes the source content **through** the symlink, so the launcher's correct 29-byte blob ends up at `rtl8761b_config.bin` (corrupting it) and `rtl8821cs_config.bin` remains a symlink. Task 1 explicitly removes the symlink and writes a real file to fix both sides.
- **Why a per-user agent and not just `notify-send` from root**: notifications need `DBUS_SESSION_BUS_ADDRESS` from the active user session. Wvkbd similarly needs `WAYLAND_DISPLAY`. An XDG-autostart agent inherits both naturally and works on any DE.

---

## Part 1 — Fix Bluetooth controller in `build-debian-desktop.sh`

### Task 1: Add `libspa-0.2-bluetooth` and `bluez-tools` to apt package list

**Files:**
- Modify: `scripts/build-debian-desktop.sh` (the `PACKAGES=( … )` array, around lines 50–110)

- [ ] **Step 1: Edit the package list**

Find the line `bluetooth blueman` in the `PACKAGES=( ... )` array and replace it with:

```bash
    # NetworkManager + Bluetooth
    # network-manager-tui: nmtui was split from network-manager in NM 1.56
    # wpasupplicant: only a Recommends of NM, not pulled in by minbase — required for WiFi
    network-manager network-manager-tui network-manager-gnome wpasupplicant
    bluetooth blueman bluez-tools libspa-0.2-bluetooth
```

- [ ] **Step 2: Syntax check the script**

Run: `bash -n scripts/build-debian-desktop.sh`
Expected: no output, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add scripts/build-debian-desktop.sh
git commit -m "debian-desktop: add bluez-tools and libspa-0.2-bluetooth packages"
```

---

### Task 2: Replace broken RTL8821CS firmware blob during build

**Files:**
- Modify: `scripts/build-debian-desktop.sh` (insert a new step *after* the firmware-copy block, around line 353, i.e. after the `if [ -d "$FW_SRC" ]; then ... fi` block but *before* the `# ── fstab ──` section)

- [ ] **Step 1: Add the firmware-fix block**

Insert this block just before the `# ── fstab ──` comment line (around line 357):

```bash
# ── Bluetooth firmware fix: RTL8821CS SDIO config blob ───────────────────────
# Debian's firmware-realtek ships rtl8821cs_config.bin as a symlink to
# rtl8761b_config.bin (wrong chip). The launcher's SOC overlay has the
# correct 29-byte SDIO blob; install it explicitly. We also `cp -a` of the
# buildroot firmware tree earlier writes THROUGH the bad symlink and
# corrupts rtl8761b_config.bin, so restore that too if present.
SOC_RTL_BLOB="$ROOT/soc/allwinner-h700/mainline/rootfs-overlay/usr/lib/firmware/rtl_bt/rtl8821cs_config.bin"
EXPECTED_MD5="37338e0b8861a20ce877c0a10cbaaae3"
ACTUAL_MD5="$(md5sum "$SOC_RTL_BLOB" 2>/dev/null | cut -d' ' -f1)"
[ "$ACTUAL_MD5" = "$EXPECTED_MD5" ] \
    || error "SOC rtl8821cs_config.bin md5 mismatch: got $ACTUAL_MD5 expected $EXPECTED_MD5"

RTL_FW_DIR="$ROOTFS/lib/firmware/rtl_bt"
mkdir -p "$RTL_FW_DIR"
rm -f "$RTL_FW_DIR/rtl8821cs_config.bin"
install -m 0644 "$SOC_RTL_BLOB" "$RTL_FW_DIR/rtl8821cs_config.bin"
info "Installed correct rtl8821cs_config.bin (29-byte SDIO blob)"

# Restore rtl8761b_config.bin from Debian firmware-realtek if the earlier
# cp -a wrote through the symlink and corrupted it. Re-install from .deb if
# present; otherwise it stays whatever the buildroot firmware tree had.
if dpkg-deb --version >/dev/null 2>&1; then
    chroot_run apt-get install --reinstall -y firmware-realtek 2>&1 \
        | grep -vE '^(Reading|Building|0 upgraded|After this)' || true
fi
```

- [ ] **Step 2: Syntax check**

Run: `bash -n scripts/build-debian-desktop.sh`
Expected: no output, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add scripts/build-debian-desktop.sh
git commit -m "debian-desktop: install correct RTL8821CS SDIO firmware blob

Debian's firmware-realtek ships rtl8821cs_config.bin as a symlink to
the wrong-chip rtl8761b_config.bin. Replace with the canonical 29-byte
SDIO blob from the H700 SOC overlay; md5-guard against silent drift."
```

---

### Task 3: Install and enable `panicos-bt-wakeup.service`

**Files:**
- Modify: `scripts/build-debian-desktop.sh` (insert immediately after the firmware-fix block from Task 2)

- [ ] **Step 1: Add the bt-wakeup install block**

Append directly after the Task 2 block (still before `# ── fstab ──`):

```bash
# ── Bluetooth UART re-probe workaround service ───────────────────────────────
# With CONFIG_BT_LE=y the hci_uart serdev probe races the rfkill GPIO at boot
# and silently defers, leaving /sys/class/bluetooth empty. This oneshot
# reloads hci_uart after bluetooth.service if hci0 didn't appear. Same
# workaround the launcher image uses.
cp "$ROOT/soc/allwinner-h700/mainline/rootfs-overlay/usr/lib/systemd/system/panicos-bt-wakeup.service" \
    "$ROOTFS/usr/lib/systemd/system/panicos-bt-wakeup.service"
chroot_run systemctl enable panicos-bt-wakeup.service
info "Installed and enabled panicos-bt-wakeup.service"
```

- [ ] **Step 2: Verify the source file exists and is valid**

Run: `ls -la soc/allwinner-h700/mainline/rootfs-overlay/usr/lib/systemd/system/panicos-bt-wakeup.service && head -5 soc/allwinner-h700/mainline/rootfs-overlay/usr/lib/systemd/system/panicos-bt-wakeup.service`
Expected: file exists, first line is `[Unit]`.

- [ ] **Step 3: Syntax check**

Run: `bash -n scripts/build-debian-desktop.sh`
Expected: no output, exit code 0.

- [ ] **Step 4: Commit**

```bash
git add scripts/build-debian-desktop.sh
git commit -m "debian-desktop: install panicos-bt-wakeup.service

Ports the hci_uart re-probe oneshot from the launcher image so hci0
appears on the Debian squashfs after the CONFIG_BT_LE serdev race."
```

---

### Task 4: Add `panicos` user to `bluetooth` group

**Files:**
- Modify: `scripts/build-debian-desktop.sh` (the `useradd ... -G sudo,audio,...` line, around line 197)

- [ ] **Step 1: Add `bluetooth` to the supplementary groups**

Find this line:

```bash
chroot_run useradd -m -s /bin/bash -G sudo,audio,video,input,render,netdev panicos
```

Replace with:

```bash
chroot_run useradd -m -s /bin/bash -G sudo,audio,video,input,render,netdev,bluetooth panicos
```

- [ ] **Step 2: Syntax check**

Run: `bash -n scripts/build-debian-desktop.sh`
Expected: no output, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add scripts/build-debian-desktop.sh
git commit -m "debian-desktop: add panicos user to bluetooth group

Needed so the per-user session agent (added in Part 2) can talk to
bluez on the system bus without sudo."
```

---

## Part 2 — Hold-menu auto-pair (cross-DE)

### Task 5: Define and test the socket protocol (stand-alone unit test)

This task introduces the protocol between the system daemon and the per-user agent before touching either side. The unit test runs on the dev host; no device or build needed.

**Files:**
- Create: `debian-desktop/services/test_menu_socket.py` (will be moved/deleted at end of Part 2)

- [ ] **Step 1: Write the failing test**

```python
#!/usr/bin/env python3
"""Stand-alone test for the gamepad-mouse / session-agent socket protocol.

The daemon writes one line per gesture to a unix DGRAM socket. The agent
reads lines and dispatches. This test asserts the agreed protocol shape
without booting either real component.

Protocol:
- Transport: AF_UNIX, SOCK_DGRAM
- Production path: abstract namespace "\0panicos-menu" (no filesystem)
- Test path: any filesystem path (verifies stale-socket cleanup + 0666 perm)
- Payloads: ASCII bytes, exactly one of b"short\n" or b"long\n"
- Any other payload MUST be ignored by the agent.
"""
import os, socket, tempfile, unittest

# Importable helper we are about to write
import menu_socket


class MenuSocketTest(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.sock_path = os.path.join(self.tmpdir, "menu.sock")

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_send_short_filesystem(self):
        srv = menu_socket.bind_server(self.sock_path)
        menu_socket.send_event("short", self.sock_path)
        data, _ = srv.recvfrom(64)
        self.assertEqual(data, b"short\n")
        srv.close()

    def test_send_long_filesystem(self):
        srv = menu_socket.bind_server(self.sock_path)
        menu_socket.send_event("long", self.sock_path)
        data, _ = srv.recvfrom(64)
        self.assertEqual(data, b"long\n")
        srv.close()

    def test_send_short_abstract(self):
        # Use a unique abstract name per test to avoid collisions
        abs_path = f"\0menu-socket-test-{os.getpid()}"
        srv = menu_socket.bind_server(abs_path)
        menu_socket.send_event("short", abs_path)
        data, _ = srv.recvfrom(64)
        self.assertEqual(data, b"short\n")
        srv.close()

    def test_reject_unknown_event(self):
        with self.assertRaises(ValueError):
            menu_socket.send_event("bogus", self.sock_path)

    def test_filesystem_socket_mode_is_0666(self):
        srv = menu_socket.bind_server(self.sock_path)
        mode = os.stat(self.sock_path).st_mode & 0o777
        self.assertEqual(mode, 0o666)
        srv.close()

    def test_send_before_server_bound_does_not_raise(self):
        # Daemon may write before agent is up; should silently no-op
        menu_socket.send_event("short", self.sock_path)

    def test_stale_socket_file_is_replaced(self):
        # Pre-create a regular file at the target path; bind_server must
        # remove it before binding (only for filesystem paths).
        with open(self.sock_path, "w") as f:
            f.write("stale")
        srv = menu_socket.bind_server(self.sock_path)
        # If bind succeeded, the file is now a socket
        import stat
        self.assertTrue(stat.S_ISSOCK(os.stat(self.sock_path).st_mode))
        srv.close()


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test, see import failure**

Run: `cd debian-desktop/services && python3 -m unittest test_menu_socket -v`
Expected: `ModuleNotFoundError: No module named 'menu_socket'`

- [ ] **Step 3: Write the minimal `menu_socket.py` helper**

Create `debian-desktop/services/menu_socket.py`:

```python
"""Tiny shared helper for the PanicOS menu-event datagram socket.

Production uses the Linux abstract unix-socket namespace (path starts
with NUL byte) so there is no filesystem object — no directory to
create, no perms to manage, root daemon and user agent can talk freely.

The system daemon (gamepad-mouse.py) calls send_event(). The per-user
session agent (panicos-session-agent.py) calls bind_server() and recvfrom().

Tests pass an explicit filesystem path so they can exercise stale-socket
cleanup behavior; that path is chmod 0666. Abstract paths skip chmod.
"""
import os
import socket

# Leading NUL → Linux abstract namespace (no filesystem entry).
SOCK_PATH = "\0panicos-menu"
VALID_EVENTS = ("short", "long")
SOCK_MODE = 0o666


def _is_abstract(path: str) -> bool:
    return path.startswith("\0")


def bind_server(path: str = SOCK_PATH) -> socket.socket:
    """Bind the receiving end. For filesystem paths, replace any stale file."""
    if not _is_abstract(path):
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
    s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    s.bind(path)
    if not _is_abstract(path):
        os.chmod(path, SOCK_MODE)
    return s


def send_event(event: str, path: str = SOCK_PATH) -> None:
    """Send one event; silently no-op if no one is listening."""
    if event not in VALID_EVENTS:
        raise ValueError(f"invalid event {event!r}; expected one of {VALID_EVENTS}")
    s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    try:
        s.sendto(f"{event}\n".encode("ascii"), path)
    except (ConnectionRefusedError, FileNotFoundError):
        pass
    finally:
        s.close()
```

- [ ] **Step 4: Run tests, see them pass**

Run: `cd debian-desktop/services && python3 -m unittest test_menu_socket -v`
Expected: `Ran 7 tests in <1s` and `OK`.

- [ ] **Step 5: Commit**

```bash
git add debian-desktop/services/menu_socket.py debian-desktop/services/test_menu_socket.py
git commit -m "debian-desktop: add menu_socket helper with protocol tests

Tiny shared module for the daemon→agent unix-datagram channel. Tests
lock down the wire format (short/long lines), 0666 perms, and graceful
no-op when the agent isn't listening."
```

---

### Task 6: Modify `gamepad-mouse.py` — replace KEY_MENU emit with socket events

**Files:**
- Modify: `debian-desktop/services/gamepad-mouse.py` (drop the virtual keyboard; add 5s timer + socket producer)

- [ ] **Step 1: Replace the file with the new implementation**

Replace the entire contents of `debian-desktop/services/gamepad-mouse.py` with:

```python
#!/usr/bin/env python3
"""
gamepad-mouse: maps gamepad input to mouse for PanicOS Debian desktop.

Left stick   → mouse movement (REL_X / REL_Y)
D-pad        → mouse movement (REL_X / REL_Y, slower)
R1 (BTN_TR)  → left click   (BTN_LEFT)
R2 (BTN_TR2) → right click  (BTN_RIGHT)
Menu (BTN_MODE):
    short press (<5s) → write b"short\n" to /run/panicos/menu.sock
    hold >= 5s        → write b"long\n"  to /run/panicos/menu.sock

The per-user session agent (panicos-session-agent.py) consumes those
events and runs OSK toggle / Bluetooth auto-pair in the user session,
which keeps the daemon DE-agnostic.

Runs as root system service. Creates only one uinput device (the
virtual mouse); the keyboard device is gone.
"""

import asyncio
import logging
import time

import evdev
from evdev import InputDevice, UInput, ecodes

import menu_socket  # sibling module, installed alongside this file

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("gamepad-mouse")

# ── tunables ────────────────────────────────────────────────────────────────
MOUSE_SPEED        = 6      # max pixels/tick at full stick deflection
DPAD_SPEED         = 3      # pixels/tick while d-pad held
POLL_INTERVAL      = 0.008  # 125 Hz
STICK_IDLE_TIMEOUT = 0.1    # zero ax/ay if no ABS event for this long
LONG_PRESS_SECONDS = 5.0    # hold duration that fires the "long" event
# ────────────────────────────────────────────────────────────────────────────


def find_gamepad():
    for path in evdev.list_devices():
        try:
            dev = InputDevice(path)
            cap = dev.capabilities()
            abs_codes = {code for code, _ in cap.get(ecodes.EV_ABS, [])}
            key_codes = set(cap.get(ecodes.EV_KEY, []))
            if ecodes.ABS_X in abs_codes and ecodes.BTN_SOUTH in key_codes:
                log.info(f"Found gamepad: {dev.name} at {path}")
                return dev
        except Exception:
            pass
    return None


def create_virtual_mouse():
    cap = {
        ecodes.EV_REL: [ecodes.REL_X, ecodes.REL_Y],
        ecodes.EV_KEY: [ecodes.BTN_LEFT, ecodes.BTN_RIGHT, ecodes.BTN_MIDDLE],
    }
    return UInput(cap, name="PanicOS Gamepad Mouse", version=0x1)


def stick_to_delta(raw, deadzone, max_val, speed):
    if abs(raw) < deadzone:
        return 0
    sign = 1 if raw > 0 else -1
    magnitude = (abs(raw) - deadzone) / (max_val - deadzone)
    return int(sign * magnitude * speed)


async def run():
    gamepad = None
    while gamepad is None:
        gamepad = find_gamepad()
        if gamepad is None:
            log.warning("No gamepad found, retrying in 2s...")
            await asyncio.sleep(2)

    abs_dict = dict(gamepad.capabilities()[ecodes.EV_ABS])
    abs_info = abs_dict[ecodes.ABS_X]
    stick_max = abs_info.max
    stick_deadzone = max(abs_info.flat * 3, stick_max // 20)
    log.info(f"Stick range ±{stick_max}, deadzone {stick_deadzone}")

    mouse = create_virtual_mouse()
    gamepad.grab()

    # State
    ax, ay = 0, 0
    last_abs_t = 0.0
    dx_dpad, dy_dpad = 0, 0

    # Menu (BTN_MODE) state machine
    menu_down_at = None        # monotonic timestamp of press, or None
    menu_long_fired = False    # True once we've emitted "long" for this press
    menu_long_task = None      # asyncio.Task for the 5s timer

    async def fire_long_after_delay():
        nonlocal menu_long_fired
        try:
            await asyncio.sleep(LONG_PRESS_SECONDS)
            menu_long_fired = True
            menu_socket.send_event("long")
            log.info("menu long press → sent 'long'")
        except asyncio.CancelledError:
            pass

    async def read_events():
        nonlocal ax, ay, last_abs_t, dx_dpad, dy_dpad
        nonlocal menu_down_at, menu_long_fired, menu_long_task
        async for ev in gamepad.async_read_loop():
            if ev.type == ecodes.EV_ABS:
                if ev.code == ecodes.ABS_X:
                    ax = ev.value
                    last_abs_t = time.monotonic()
                elif ev.code == ecodes.ABS_Y:
                    ay = ev.value
                    last_abs_t = time.monotonic()

            elif ev.type == ecodes.EV_KEY:
                if ev.code == ecodes.BTN_TR:
                    mouse.write(ecodes.EV_KEY, ecodes.BTN_LEFT, 1 if ev.value else 0)
                    mouse.syn()
                elif ev.code == ecodes.BTN_TR2:
                    mouse.write(ecodes.EV_KEY, ecodes.BTN_RIGHT, 1 if ev.value else 0)
                    mouse.syn()
                elif ev.code == ecodes.BTN_DPAD_LEFT:
                    dx_dpad = -1 if ev.value else 0
                elif ev.code == ecodes.BTN_DPAD_RIGHT:
                    dx_dpad = 1 if ev.value else 0
                elif ev.code == ecodes.BTN_DPAD_UP:
                    dy_dpad = -1 if ev.value else 0
                elif ev.code == ecodes.BTN_DPAD_DOWN:
                    dy_dpad = 1 if ev.value else 0

                elif ev.code == ecodes.BTN_MODE:
                    if ev.value:  # press
                        menu_down_at = time.monotonic()
                        menu_long_fired = False
                        menu_long_task = asyncio.create_task(fire_long_after_delay())
                    else:  # release
                        if menu_long_task and not menu_long_task.done():
                            menu_long_task.cancel()
                        if not menu_long_fired and menu_down_at is not None:
                            menu_socket.send_event("short")
                            log.info("menu short press → sent 'short'")
                        menu_down_at = None
                        menu_long_task = None

    async def move_loop():
        while True:
            if time.monotonic() - last_abs_t > STICK_IDLE_TIMEOUT:
                dx, dy = 0, 0
            else:
                dx = stick_to_delta(ax, stick_deadzone, stick_max, MOUSE_SPEED)
                dy = stick_to_delta(ay, stick_deadzone, stick_max, MOUSE_SPEED)
            dx += dx_dpad * DPAD_SPEED
            dy += dy_dpad * DPAD_SPEED
            if dx or dy:
                if dx:
                    mouse.write(ecodes.EV_REL, ecodes.REL_X, dx)
                if dy:
                    mouse.write(ecodes.EV_REL, ecodes.REL_Y, dy)
                mouse.syn()
            await asyncio.sleep(POLL_INTERVAL)

    await asyncio.gather(read_events(), move_loop())


if __name__ == "__main__":
    asyncio.run(run())
```

- [ ] **Step 2: Syntax check**

Run: `python3 -m py_compile debian-desktop/services/gamepad-mouse.py`
Expected: exit code 0, no output.

- [ ] **Step 3: Commit**

```bash
git add debian-desktop/services/gamepad-mouse.py
git commit -m "debian-desktop: replace KEY_MENU uinput with menu-socket events

Daemon now writes short/long press events to /run/panicos/menu.sock;
the per-user agent (added next task) consumes them. Removes the
PanicOS Gamepad Keys virtual keyboard. 5s hold = long; sub-5s = short."
```

---

### Task 7: Create the per-user session agent

**Files:**
- Create: `debian-desktop/services/panicos-session-agent.py`

- [ ] **Step 1: Write the agent**

Create `debian-desktop/services/panicos-session-agent.py`:

```python
#!/usr/bin/env python3
"""PanicOS per-user session agent.

Started via XDG autostart in any desktop environment. Reads menu
events from the system daemon's unix socket and dispatches:

    short → toggle on-screen keyboard
    long  → run Bluetooth auto-pair (HID + audio class filter)

Runs in the user's session so it inherits WAYLAND_DISPLAY / DISPLAY /
DBUS_SESSION_BUS_ADDRESS / XDG_RUNTIME_DIR naturally — required for
wvkbd and notify-send to work.
"""
import fcntl
import logging
import os
import shutil
import subprocess
import time
from pathlib import Path

import dbus
import dbus.mainloop.glib
import dbus.service
from gi.repository import GLib

import menu_socket  # installed alongside this file

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("session-agent")

BLUEZ_SERVICE = "org.bluez"
ADAPTER_IFACE = "org.bluez.Adapter1"
DEVICE_IFACE  = "org.bluez.Device1"
AGENT_IFACE   = "org.bluez.Agent1"
OM_IFACE      = "org.freedesktop.DBus.ObjectManager"
PROPS_IFACE   = "org.freedesktop.DBus.Properties"

AGENT_PATH = "/org/panicos/BTAgent"
DISCOVERY_WINDOW_SECONDS = 30
LOCK_PATH = Path.home() / ".cache" / "panicos" / "bt-autopair.lock"

# Class-of-Device major device classes we accept
MAJOR_AUDIO_VIDEO = 0x04
MAJOR_PERIPHERAL  = 0x05
# BLE Appearance values for HID category
APPEARANCE_HID_MIN = 0x03C0
APPEARANCE_HID_MAX = 0x03C4


# ── OSK helpers ─────────────────────────────────────────────────────────────

def pick_osk_command():
    """Return (cmd_list, basename) for the on-screen keyboard, or None."""
    session_type = os.environ.get("XDG_SESSION_TYPE", "")
    if session_type == "wayland" and shutil.which("wvkbd-mobintl"):
        return (["wvkbd-mobintl", "-L", "160"], "wvkbd-mobintl")
    if shutil.which("onboard"):
        return (["onboard"], "onboard")
    log.warning("No supported OSK found; short-press will no-op")
    return None


def toggle_osk(osk_cmd, osk_name):
    """Toggle the OSK: kill if running, spawn if not."""
    if osk_cmd is None:
        return
    # pkill returns 0 if it killed something, 1 if not
    result = subprocess.run(["pkill", "-x", osk_name])
    if result.returncode != 0:
        subprocess.Popen(osk_cmd, start_new_session=True,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


# ── notify helper ────────────────────────────────────────────────────────────

def notify(summary, body="", urgency="normal", timeout=3000):
    if not shutil.which("notify-send"):
        log.info(f"[notify] {summary}: {body}")
        return
    subprocess.run([
        "notify-send",
        "-u", urgency,
        "-t", str(timeout),
        summary, body,
    ])


# ── BlueZ agent (auto-confirm) ──────────────────────────────────────────────

class BTAgent(dbus.service.Object):
    """NoInputNoOutput pairing agent: auto-confirms everything."""
    @dbus.service.method(AGENT_IFACE, in_signature="", out_signature="")
    def Release(self): pass

    @dbus.service.method(AGENT_IFACE, in_signature="os", out_signature="")
    def AuthorizeService(self, device, uuid): return

    @dbus.service.method(AGENT_IFACE, in_signature="o", out_signature="s")
    def RequestPinCode(self, device): return "0000"

    @dbus.service.method(AGENT_IFACE, in_signature="o", out_signature="u")
    def RequestPasskey(self, device): return dbus.UInt32(0)

    @dbus.service.method(AGENT_IFACE, in_signature="ouq", out_signature="")
    def DisplayPasskey(self, device, passkey, entered): pass

    @dbus.service.method(AGENT_IFACE, in_signature="os", out_signature="")
    def DisplayPinCode(self, device, pincode): pass

    @dbus.service.method(AGENT_IFACE, in_signature="ou", out_signature="")
    def RequestConfirmation(self, device, passkey): return

    @dbus.service.method(AGENT_IFACE, in_signature="o", out_signature="")
    def RequestAuthorization(self, device): return

    @dbus.service.method(AGENT_IFACE, in_signature="", out_signature="")
    def Cancel(self): pass


# ── BlueZ helpers ────────────────────────────────────────────────────────────

def get_bus_with_retry(timeout=5.0):
    deadline = time.monotonic() + timeout
    last_err = None
    while time.monotonic() < deadline:
        try:
            bus = dbus.SystemBus()
            # Probe for org.bluez
            bus.get_object(BLUEZ_SERVICE, "/")
            return bus
        except dbus.DBusException as e:
            last_err = e
            time.sleep(0.5)
    raise RuntimeError(f"bluez not reachable on system bus: {last_err}")


def find_adapter(bus):
    om = dbus.Interface(bus.get_object(BLUEZ_SERVICE, "/"), OM_IFACE)
    objects = om.GetManagedObjects()
    for path, ifaces in objects.items():
        if ADAPTER_IFACE in ifaces:
            return path
    return None


def device_is_acceptable(props):
    """True if device looks like HID or audio per CoD / Appearance."""
    cls = props.get("Class")
    if cls is not None:
        major = (int(cls) >> 8) & 0x1F
        if major in (MAJOR_PERIPHERAL, MAJOR_AUDIO_VIDEO):
            return True
    appearance = props.get("Appearance")
    if appearance is not None:
        if APPEARANCE_HID_MIN <= int(appearance) <= APPEARANCE_HID_MAX:
            return True
    return False


def do_autopair():
    """Run one auto-pair session. Returns when discovery ends."""
    LOCK_PATH.parent.mkdir(parents=True, exist_ok=True)
    lock_fd = os.open(str(LOCK_PATH), os.O_CREAT | os.O_RDWR, 0o600)
    try:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            log.info("auto-pair already running; skipping")
            return

        notify("Pairing mode", "Put your device in pairing mode now…",
               urgency="normal", timeout=3000)

        try:
            bus = get_bus_with_retry()
        except RuntimeError as e:
            notify("Pair failed", f"BlueZ unavailable: {e}", urgency="critical")
            return

        adapter_path = find_adapter(bus)
        if adapter_path is None:
            notify("Pair failed", "No Bluetooth adapter found",
                   urgency="critical")
            return

        adapter = bus.get_object(BLUEZ_SERVICE, adapter_path)
        adapter_props = dbus.Interface(adapter, PROPS_IFACE)
        adapter_iface = dbus.Interface(adapter, ADAPTER_IFACE)

        # Power on
        try:
            adapter_props.Set(ADAPTER_IFACE, "Powered", dbus.Boolean(True))
        except dbus.DBusException as e:
            notify("Pair failed", f"Cannot power adapter: {e}",
                   urgency="critical")
            return

        # Register agent (idempotent: unregister first if it already exists)
        agent = BTAgent(bus, AGENT_PATH)
        agent_mgr = dbus.Interface(
            bus.get_object(BLUEZ_SERVICE, "/org/bluez"),
            "org.bluez.AgentManager1")
        try:
            agent_mgr.UnregisterAgent(AGENT_PATH)
        except dbus.DBusException:
            pass
        agent_mgr.RegisterAgent(AGENT_PATH, "NoInputNoOutput")
        agent_mgr.RequestDefaultAgent(AGENT_PATH)

        loop = GLib.MainLoop()
        result = {"matched": None, "error": None}

        def on_interfaces_added(path, ifaces):
            if DEVICE_IFACE not in ifaces:
                return
            props = ifaces[DEVICE_IFACE]
            if not device_is_acceptable(props):
                return
            result["matched"] = (path, dict(props))
            loop.quit()

        bus.add_signal_receiver(
            on_interfaces_added,
            dbus_interface=OM_IFACE,
            signal_name="InterfacesAdded")

        # Also check devices already present from a prior scan
        om = dbus.Interface(bus.get_object(BLUEZ_SERVICE, "/"), OM_IFACE)
        for path, ifaces in om.GetManagedObjects().items():
            if DEVICE_IFACE in ifaces \
                    and not ifaces[DEVICE_IFACE].get("Paired", False) \
                    and device_is_acceptable(ifaces[DEVICE_IFACE]):
                result["matched"] = (path, dict(ifaces[DEVICE_IFACE]))
                GLib.idle_add(loop.quit)
                break

        try:
            adapter_iface.StartDiscovery()
        except dbus.DBusException as e:
            notify("Pair failed", f"StartDiscovery: {e}", urgency="critical")
            return

        timeout_source = GLib.timeout_add_seconds(
            DISCOVERY_WINDOW_SECONDS, lambda: (loop.quit() or False))

        loop.run()
        GLib.source_remove(timeout_source)

        try:
            adapter_iface.StopDiscovery()
        except dbus.DBusException:
            pass

        if result["matched"] is None:
            notify("No device found",
                   f"No HID/audio device appeared in {DISCOVERY_WINDOW_SECONDS}s")
            return

        path, props = result["matched"]
        name = props.get("Alias") or props.get("Name") or path.rsplit("/", 1)[-1]
        log.info(f"auto-pair: matched {name} at {path}")

        device = bus.get_object(BLUEZ_SERVICE, path)
        device_iface = dbus.Interface(device, DEVICE_IFACE)
        device_props = dbus.Interface(device, PROPS_IFACE)

        try:
            device_iface.Pair(timeout=20000)
        except dbus.DBusException as e:
            notify("Pair failed", f"{name}: {e.get_dbus_message()}",
                   urgency="critical")
            return

        try:
            device_props.Set(DEVICE_IFACE, "Trusted", dbus.Boolean(True))
        except dbus.DBusException as e:
            log.warning(f"trust failed: {e}")

        try:
            device_iface.Connect(timeout=20000)
        except dbus.DBusException as e:
            notify("Pair failed",
                   f"{name} paired but Connect failed: {e.get_dbus_message()}",
                   urgency="critical")
            return

        notify("Connected", str(name))
    finally:
        os.close(lock_fd)


# ── socket reader ───────────────────────────────────────────────────────────

def main():
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    osk_cmd, osk_name = (None, None)
    picked = pick_osk_command()
    if picked:
        osk_cmd, osk_name = picked
    log.info(f"OSK command: {osk_cmd}")

    # Bind the abstract-namespace socket. No filesystem, no perms, no
    # dependency on the daemon being up first — the daemon's sendto()
    # silently no-ops if we're not bound yet, and we'll catch its very
    # next event once we are. Linux abstract sockets are per-network-
    # namespace so single-user appliance scope is safe.
    srv = menu_socket.bind_server()
    log.info(f"listening on abstract socket {menu_socket.SOCK_PATH!r}")

    while True:
        try:
            data, _ = srv.recvfrom(64)
        except OSError as e:
            log.error(f"recv failed: {e}")
            time.sleep(1)
            continue
        line = data.decode("ascii", errors="replace").strip()
        if line == "short":
            toggle_osk(osk_cmd, osk_name)
        elif line == "long":
            do_autopair()
        else:
            log.warning(f"ignoring unknown event {line!r}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Syntax check**

Run: `python3 -m py_compile debian-desktop/services/panicos-session-agent.py`
Expected: exit code 0.

- [ ] **Step 3: Reconcile with the test suite's protocol assumption**

The test in Task 5 has `send_event` write and `bind_server` read. The roles are: **agent binds (reader); daemon sends (writer)**. This matches the agent code we just wrote (agent calls `menu_socket.bind_server()`) and the daemon code in Task 6 (daemon calls `menu_socket.send_event(...)`). Verify:

Run: `grep -n "bind_server\|send_event" debian-desktop/services/*.py`
Expected output should include:
- `panicos-session-agent.py` calling `menu_socket.bind_server()`
- `gamepad-mouse.py` calling `menu_socket.send_event(...)`
- `menu_socket.py` defining both

- [ ] **Step 4: Commit**

```bash
git add debian-desktop/services/panicos-session-agent.py
git commit -m "debian-desktop: add per-user session agent

XDG-autostart Python daemon that reads /run/panicos/menu.sock and:
  short → toggle wvkbd/onboard
  long  → bluez D-Bus auto-pair with NoInputNoOutput agent,
          accepting first HID (CoD 0x05) or audio (0x04) device,
          or BLE HID by Appearance, within 30s.

Notifications via notify-send. Idempotent via ~/.cache flock."
```

---

### Task 8: Add the XDG autostart desktop file

**Files:**
- Create: `debian-desktop/services/panicos-session-agent.desktop`

- [ ] **Step 1: Create the file**

```ini
[Desktop Entry]
Type=Application
Name=PanicOS Session Agent
Comment=Handles Menu-button OSK toggle and Bluetooth auto-pair
Exec=/usr/local/lib/panicos/panicos-session-agent.py
NoDisplay=true
X-GNOME-Autostart-enabled=true
OnlyShowIn=GNOME;KDE;XFCE;LXDE;LXQt;MATE;Cinnamon;Wayfire;sway;
```

- [ ] **Step 2: Validate with desktop-file-validate if available**

Run: `desktop-file-validate debian-desktop/services/panicos-session-agent.desktop 2>&1 || true`
Expected: either no output, or warnings about `OnlyShowIn` non-registered values (acceptable — Wayfire/sway aren't in the freedesktop registry but the entry is read by them).

- [ ] **Step 3: Commit**

```bash
git add debian-desktop/services/panicos-session-agent.desktop
git commit -m "debian-desktop: XDG autostart entry for session agent"
```

---

### Task 9: Update `build-debian-desktop.sh` to install Part 2 files and rewire udev

**Files:**
- Modify: `scripts/build-debian-desktop.sh` (the existing gamepad-mouse install block around lines 268–286)

- [ ] **Step 1: Locate the existing block**

Run: `grep -n "Gamepad mouse daemon\|99-panicos-uinput" scripts/build-debian-desktop.sh`
Expected: shows the header comment line and the udev heredoc line near line ~268.

- [ ] **Step 2: Replace the block**

Replace the existing block (from the `# ── Gamepad mouse daemon ──` comment line through the closing `UDEV` heredoc terminator) with:

```bash
# ── Gamepad mouse daemon + per-user session agent ────────────────────────────
mkdir -p "$ROOTFS/usr/local/lib/panicos"
install -m 0755 "$ASSETS/services/gamepad-mouse.py" \
    "$ROOTFS/usr/local/lib/panicos/gamepad-mouse.py"
install -m 0755 "$ASSETS/services/panicos-session-agent.py" \
    "$ROOTFS/usr/local/lib/panicos/panicos-session-agent.py"
install -m 0644 "$ASSETS/services/menu_socket.py" \
    "$ROOTFS/usr/local/lib/panicos/menu_socket.py"

# System service
install -m 0644 "$ASSETS/services/gamepad-mouse.service" \
    "$ROOTFS/etc/systemd/system/gamepad-mouse.service"
chroot_run systemctl enable gamepad-mouse

# XDG autostart for the user-session agent (any DE that honors the spec)
mkdir -p "$ROOTFS/etc/xdg/autostart"
install -m 0644 "$ASSETS/services/panicos-session-agent.desktop" \
    "$ROOTFS/etc/xdg/autostart/panicos-session-agent.desktop"

# python-dbus + python-gi for the session agent
chroot_run apt-get install -y --no-install-recommends \
    python3-dbus python3-gi 2>&1 | tail -5

# udev rule: only the virtual mouse exists now (Gamepad Keys is gone).
mkdir -p "$ROOTFS/etc/udev/rules.d"
cat > "$ROOTFS/etc/udev/rules.d/99-panicos-uinput.rules" <<'UDEV'
SUBSYSTEM=="input", ATTRS{name}=="PanicOS Gamepad Mouse", TAG+="seat", TAG+="uaccess"
UDEV
```

- [ ] **Step 3: Syntax check**

Run: `bash -n scripts/build-debian-desktop.sh`
Expected: no output, exit code 0.

- [ ] **Step 4: Commit**

```bash
git add scripts/build-debian-desktop.sh
git commit -m "debian-desktop: install session agent and menu_socket helper

Build script now installs panicos-session-agent.py + .desktop +
menu_socket.py alongside the existing gamepad-mouse.py. Adds the
python3-dbus / python3-gi runtime deps and trims the udev rules to
the single remaining virtual device."
```

---

### Task 10: Remove `binding_menu` from `wayfire.ini`

**Files:**
- Modify: `debian-desktop/configs/wayfire.ini`

- [ ] **Step 1: Delete the menu binding lines**

Remove these three lines from the `[command]` section:

```ini
# Menu button → toggle OSK: kill if running, start if not
binding_menu     = KEY_MENU
command_menu     = pkill -x wvkbd-mobintl || wvkbd-mobintl -L 160 &
```

- [ ] **Step 2: Verify the file still parses (light check)**

Run: `python3 -c "import configparser; c=configparser.ConfigParser(); c.read('debian-desktop/configs/wayfire.ini'); print('sections:', c.sections())"`
Expected: lists sections including `[core]`, `[command]`, etc., no exception.

- [ ] **Step 3: Commit**

```bash
git add debian-desktop/configs/wayfire.ini
git commit -m "debian-desktop: drop binding_menu from wayfire.ini

OSK toggle is now handled cross-DE by panicos-session-agent."
```

---

### Task 11: Move the protocol test out of the runtime services dir

The protocol test from Task 5 was useful during design but it imports `menu_socket` from the working directory, not from the install path, so it doesn't belong in the image. Keep the source but move the test out of the runtime services dir.

**Files:**
- Move: `debian-desktop/services/test_menu_socket.py` → `debian-desktop/services/tests/test_menu_socket.py`

- [ ] **Step 1: Move the file**

```bash
mkdir -p debian-desktop/services/tests
git mv debian-desktop/services/test_menu_socket.py debian-desktop/services/tests/test_menu_socket.py
```

- [ ] **Step 2: Make the test still runnable from the new location**

Edit `debian-desktop/services/tests/test_menu_socket.py` and replace the import block at the top:

```python
import os, socket, tempfile, threading, unittest, time

# Importable helper we are about to write
import menu_socket
```

with:

```python
import os, socket, sys, tempfile, threading, unittest, time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import menu_socket
```

- [ ] **Step 3: Re-run tests from the new location**

Run: `python3 -m unittest debian-desktop.services.tests.test_menu_socket -v`
(If that fails with module-path issues, fall back to: `cd debian-desktop/services/tests && python3 -m unittest test_menu_socket -v`)
Expected: `Ran 5 tests` and `OK`.

- [ ] **Step 4: Commit**

```bash
git add debian-desktop/services/tests/
git commit -m "debian-desktop: move menu_socket tests out of runtime services dir"
```

---

## Part 3 — Build and on-device validation

### Task 12: First-boot 1GB swapfile on `/storage`

**Files:**
- Create: `debian-desktop/services/panicos-swapfile.service`
- Modify: `scripts/build-debian-desktop.sh` (install + enable the new unit)

**Context:** the squashfs root is overlay-on-ext4. The ext4 partition is mounted at `/storage` (212G persistent, survives image swaps). Put the swapfile there so (a) image rebuilds don't blow it away, (b) other PanicOS images can pick it up too if desired, (c) it lives outside the overlay's upper dir which keeps overlay size bounded.

- [ ] **Step 1: Create the systemd unit**

Create `debian-desktop/services/panicos-swapfile.service`:

```ini
[Unit]
Description=PanicOS 1GB swapfile on /storage (creates on first boot, then swapon)
DefaultDependencies=no
After=local-fs.target
Before=swap.target
RequiresMountsFor=/storage

[Service]
Type=oneshot
RemainAfterExit=yes
# Create /storage/swapfile if missing or wrong size, then swapon.
# ext4 supports fallocate for swap on modern kernels (>= 4.18-ish).
# Idempotent: re-running just swapon's the existing file.
ExecStart=/bin/sh -c '\
    set -e; \
    SWAP=/storage/swapfile; \
    NEED_BYTES=$((1024*1024*1024)); \
    if [ ! -f "$SWAP" ] || [ "$(stat -c %s "$SWAP")" -lt "$NEED_BYTES" ]; then \
        echo "Creating 1GB swapfile at $SWAP"; \
        rm -f "$SWAP"; \
        fallocate -l 1G "$SWAP" || dd if=/dev/zero of="$SWAP" bs=1M count=1024; \
        chmod 0600 "$SWAP"; \
        mkswap "$SWAP"; \
    fi; \
    swapon "$SWAP" 2>/dev/null || true'
ExecStop=/bin/sh -c 'swapoff /storage/swapfile 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 2: Add install/enable lines to `build-debian-desktop.sh`**

Append directly after the `panicos-bt-wakeup.service` install block from Task 3 (still before `# ── fstab ──`):

```bash
# ── 1GB swapfile on /storage (first-boot setup) ──────────────────────────────
install -m 0644 "$ASSETS/services/panicos-swapfile.service" \
    "$ROOTFS/usr/lib/systemd/system/panicos-swapfile.service"
chroot_run systemctl enable panicos-swapfile.service
info "Installed and enabled panicos-swapfile.service"
```

- [ ] **Step 3: Syntax check**

Run: `bash -n scripts/build-debian-desktop.sh && systemd-analyze verify debian-desktop/services/panicos-swapfile.service 2>&1 || true`
Expected: bash returns 0; systemd-analyze either no output or non-fatal warnings about RequiresMountsFor (acceptable — `/storage` is mounted at runtime by the initramfs, not declared in fstab).

- [ ] **Step 4: Commit**

```bash
git add debian-desktop/services/panicos-swapfile.service scripts/build-debian-desktop.sh
git commit -m "debian-desktop: create + enable 1GB swapfile on /storage at first boot

Oneshot systemd unit creates /storage/swapfile if missing or smaller
than 1GB, then swapon's it. Lives on the persistent ext4 partition so
it survives image swaps and stays out of the overlay upper dir."
```

---

### Task 13: Full rebuild

- [ ] **Step 1: Confirm device output exists**

Run: `ls -la output/rg35xx-pro-launcher-mainline/target/usr/lib/firmware/rtl_bt/rtl8821cs_config.bin`
Expected: 29 bytes, regular file.

- [ ] **Step 2: Run the build**

Run: `sudo scripts/build-debian-desktop.sh 2>&1 | tee /tmp/debian-desktop-build.log`
Expected: completes with `Done.` after ~15–25 minutes; output file at `output/debian-desktop/panicos-debian-desktop.squashfs`. If the build aborts on the md5 check, the SOC blob has drifted — investigate before continuing.

- [ ] **Step 3: Verify the squashfs contains the new files**

Run:
```bash
sudo unsquashfs -l output/debian-desktop/panicos-debian-desktop.squashfs \
    | grep -E 'panicos-session-agent|menu_socket|panicos-bt-wakeup|rtl8821cs_config'
```
Expected: all four paths listed:
- `/etc/xdg/autostart/panicos-session-agent.desktop`
- `/etc/systemd/system/multi-user.target.wants/panicos-bt-wakeup.service` (or `/usr/lib/systemd/...` enabled symlink)
- `/usr/local/lib/panicos/menu_socket.py`
- `/usr/local/lib/panicos/panicos-session-agent.py`
- `/lib/firmware/rtl_bt/rtl8821cs_config.bin`

- [ ] **Step 4: Confirm the firmware blob is correct inside the squashfs**

Run:
```bash
sudo unsquashfs -d /tmp/check-debsq -e /lib/firmware/rtl_bt/rtl8821cs_config.bin \
    output/debian-desktop/panicos-debian-desktop.squashfs
md5sum /tmp/check-debsq/lib/firmware/rtl_bt/rtl8821cs_config.bin
sudo rm -rf /tmp/check-debsq
```
Expected: md5 `37338e0b8861a20ce877c0a10cbaaae3`.

---

### Task 14: Deploy and on-device validation (also tests swapfile)

- [ ] **Step 1: Deploy the squashfs**

Run: `scripts/deploy-squashfs.sh output/debian-desktop/panicos-debian-desktop.squashfs root@192.168.1.181`
(If that script doesn't auto-handle the active.cfg switch, follow the script's printed instructions; deploy-squashfs.sh is the project-standard route.)

- [ ] **Step 2: Reboot device and wait**

Run: `sshpass -p panicos ssh root@192.168.1.181 reboot; sleep 45`
Expected: device comes back on the network within ~45s.

- [ ] **Step 3a: Verify the 1GB swapfile was created and is active**

Run:
```bash
sshpass -p panicos ssh root@192.168.1.181 \
    'ls -la /storage/swapfile; free -h; swapon --show; systemctl status panicos-swapfile.service --no-pager | head -10'
```
Expected: `/storage/swapfile` is exactly 1073741824 bytes mode `-rw-------`; `free -h` shows ~1.0G swap; `swapon --show` lists `/storage/swapfile`; service status is `active (exited)`. Reboot once more and confirm the swapfile persists (oneshot re-runs `swapon` without recreating the file).

- [ ] **Step 3b: Verify hci0 appears**

Run:
```bash
sshpass -p panicos ssh root@192.168.1.181 \
    'ls /sys/class/bluetooth/; systemctl status panicos-bt-wakeup.service --no-pager | head -10; bluetoothctl show'
```
Expected: `hci0` listed, `panicos-bt-wakeup.service` status `active (exited)`, `bluetoothctl show` reports a controller with a MAC address.

- [ ] **Step 4: Verify scan works**

Run:
```bash
sshpass -p panicos ssh root@192.168.1.181 \
    'timeout 10 bluetoothctl --timeout 8 scan on 2>&1 | tail -20'
```
Expected: at least one `[NEW] Device …` line (nearby BT devices visible).

- [ ] **Step 5: Verify the menu socket exists and the agent is running**

Run:
```bash
sshpass -p panicos ssh root@192.168.1.181 \
    'ls -la /run/panicos/; pgrep -af panicos-session-agent; pgrep -af gamepad-mouse'
```
Expected: `/run/panicos/menu.sock` listed mode `srw-rw-rw-`; both processes present.

- [ ] **Step 6: Smoke-test short-press**

On the device, press the Menu button briefly. The on-screen keyboard should appear. Press again — it should disappear.

- [ ] **Step 7: Smoke-test long-press auto-pair**

On a BT keyboard or mouse, enter pairing mode. On the handheld, hold Menu for 5 seconds. Within ~5s of releasing you should see a "Pairing mode" notification. Within ~10s of the BT device entering pairing mode you should see "Connected: <name>". Verify:

```bash
sshpass -p panicos ssh root@192.168.1.181 \
    'bluetoothctl devices Paired'
```
Expected: the BT device appears in the list.

- [ ] **Step 8: Confirm OSK does NOT appear on long-press**

Repeat the 5-second hold with a different BT device (or just abort by not having one in pairing mode). The OSK must NOT toggle when the press is consumed as a long-press.

- [ ] **Step 9: If everything works, commit a docs update**

Append a short section to `docs/rtl8821cs-bluetooth-fixes.md`:

```markdown
---

## Debian squashfs (2026-05-26)

The Debian image previously suffered from the same probe race plus
a separate broken Debian-side `rtl8821cs_config.bin → rtl8761b_config.bin`
symlink that `cp -a` of the buildroot firmware tree corrupted further.
`build-debian-desktop.sh` now explicitly installs the canonical 29-byte
SDIO blob (md5-guarded) and enables `panicos-bt-wakeup.service`, same
as the launcher image. Validated on `root@192.168.1.181` 2026-05-26.
```

Then:
```bash
git add docs/rtl8821cs-bluetooth-fixes.md
git commit -m "docs: note RTL8821CS fix landing on Debian squashfs"
```

---

## Self-review

**Spec coverage:**
- Part 1 firmware fix: Tasks 1, 2 ✓
- Part 1 wakeup service: Task 3 ✓
- Part 1 bluetooth group: Task 4 ✓
- Part 1 packages incl. libspa-0.2-bluetooth and bluez-tools: Task 1 ✓
- Part 2 protocol + tests: Task 5 ✓
- Part 2 gamepad-mouse changes (drop kbd, socket, 5s timer): Task 6 ✓
- Part 2 session agent: Task 7 ✓
- Part 2 XDG autostart: Task 8 ✓
- Part 2 build-script wiring: Task 9 ✓
- Part 2 wayfire.ini cleanup: Task 10 ✓
- Part 2 test relocation: Task 11 ✓
- Out-of-spec but user-requested: 1GB first-boot swapfile: Task 12 ✓
- Validation: Tasks 13, 14 ✓

**Placeholder scan:** No TBD/TODO/"appropriate"/"similar to" — every step contains actual code or commands.

**Type consistency:** `menu_socket.bind_server()` / `menu_socket.send_event(event, path=...)` signatures are consistent across `menu_socket.py`, `test_menu_socket.py`, `gamepad-mouse.py`, and `panicos-session-agent.py` — note the agreed signature is `(event, path)` not `(path, event)`. Socket path constant `SOCK_PATH = "\0panicos-menu"` (Linux abstract namespace) is defined once in `menu_socket.py` and used implicitly in both daemon and agent (neither passes a custom path; only tests do). Class-of-Device major constants and BLE Appearance range are defined once in the agent.

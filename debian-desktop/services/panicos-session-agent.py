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
    """Return (cmd_list, basename) for the on-screen keyboard, or None.

    Candidates are ordered by session type: Wayland-native OSKs first when
    XDG_SESSION_TYPE=wayland, X11 OSKs first otherwise. We always try the
    other set as a fallback because XWayland and Xorg-on-Wayland mean an
    X11 keyboard may work in a Wayland session and vice versa with the
    right compositor support. shutil.which() is the only test; we trust
    that an installed binary works in its declared session type.
    """
    session_type = os.environ.get("XDG_SESSION_TYPE", "")
    wayland_candidates = [
        (["wvkbd-mobintl", "-L", "160"], "wvkbd-mobintl"),
        (["svkbd-mobile-intl"],          "svkbd-mobile-intl"),
    ]
    x11_candidates = [
        (["onboard"],                    "onboard"),
        (["florence"],                   "florence"),
        (["matchbox-keyboard"],          "matchbox-keyboard"),
    ]
    if session_type == "wayland":
        candidates = wayland_candidates + x11_candidates
    else:
        candidates = x11_candidates + wayland_candidates
    for cmd, name in candidates:
        if shutil.which(cmd[0]):
            log.info(f"OSK candidate selected: {name}")
            return (cmd, name)
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
    agent = None
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
        agent_mgr = dbus.Interface(
            bus.get_object(BLUEZ_SERVICE, "/org/bluez"),
            "org.bluez.AgentManager1")
        try:
            agent_mgr.UnregisterAgent(AGENT_PATH)
        except dbus.DBusException:
            pass
        agent = BTAgent(bus, AGENT_PATH)
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

        sig_match = bus.add_signal_receiver(
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
            if e.get_dbus_name() == "org.bluez.Error.InProgress":
                log.info("StartDiscovery: already scanning, continuing")
            else:
                notify("Pair failed", f"StartDiscovery: {e}", urgency="critical")
                return

        timeout_source = GLib.timeout_add_seconds(
            DISCOVERY_WINDOW_SECONDS, lambda: (loop.quit() or False))

        loop.run()
        sig_match.remove()
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
        if agent is not None:
            agent.remove_from_connection()
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
            try:
                do_autopair()
            except Exception:
                log.exception("auto-pair raised; staying alive")
        else:
            log.warning(f"ignoring unknown event {line!r}")


if __name__ == "__main__":
    main()

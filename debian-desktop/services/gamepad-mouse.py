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

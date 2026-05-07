#!/usr/bin/env python3
"""
gamepad-mouse: maps gamepad input to mouse + OSK toggle for PanicOS Debian desktop.

Left stick  → mouse movement (REL_X / REL_Y)
R1 (BTN_TR) → left click   (BTN_LEFT)
R2 (BTN_TR2 or ABS_RZ > threshold) → right click (BTN_RIGHT)
Menu (BTN_START) → toggle wvkbd OSK (sends SIGUSR1 to wvkbd)

Runs as a systemd service as root; creates a virtual /dev/input/event* mouse
via uinput that the Wayland compositor picks up automatically.
"""

import asyncio
import evdev
from evdev import InputDevice, UInput, ecodes, AbsInfo
import subprocess
import os
import signal
import logging
import time

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
log = logging.getLogger('gamepad-mouse')

# ── tunables ────────────────────────────────────────────────────────────────
MOUSE_SPEED      = 20      # max pixels/tick at full deflection
POLL_INTERVAL    = 0.008   # 125 Hz
# STICK_MAX and STICK_DEADZONE are derived from the device's AbsInfo at runtime
# so they work regardless of driver axis range (e.g. H700 uses ±1800, not ±32767)
# ────────────────────────────────────────────────────────────────────────────

def find_gamepad():
    for path in evdev.list_devices():
        try:
            dev = InputDevice(path)
            cap = dev.capabilities()
            # EV_ABS values are (code, AbsInfo) tuples — extract codes before checking.
            abs_codes = {code for code, _ in cap.get(ecodes.EV_ABS, [])}
            key_codes = set(cap.get(ecodes.EV_KEY, []))
            if (ecodes.ABS_X in abs_codes and ecodes.BTN_SOUTH in key_codes):
                log.info(f'Found gamepad: {dev.name} at {path}')
                return dev
        except Exception:
            pass
    return None

def create_virtual_mouse():
    cap = {
        ecodes.EV_REL: [ecodes.REL_X, ecodes.REL_Y],
        ecodes.EV_KEY: [ecodes.BTN_LEFT, ecodes.BTN_RIGHT, ecodes.BTN_MIDDLE],
    }
    return UInput(cap, name='PanicOS Gamepad Mouse', version=0x1)

def wvkbd_toggle():
    """Send SIGUSR1 to wvkbd to toggle visibility.
    wvkbd is started hidden by Wayfire autostart (needs Wayland session env);
    this daemon only signals it — never spawns it from the root service.
    """
    try:
        subprocess.run(['pkill', '-USR1', '-x', 'wvkbd-mobintl'],
                       capture_output=True)
    except Exception as e:
        log.warning(f'wvkbd toggle failed: {e}')

def stick_to_delta(raw, deadzone, max_val, speed):
    """Convert raw stick value to mouse pixel delta."""
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
            log.warning('No gamepad found, retrying in 2s...')
            await asyncio.sleep(2)

    # Derive axis range from the device so deadzone works regardless of driver
    abs_dict = dict(gamepad.capabilities()[ecodes.EV_ABS])
    abs_info = abs_dict[ecodes.ABS_X]
    stick_max = abs_info.max
    # Deadzone: 3x the hardware flat zone, at least 5% of max range
    stick_deadzone = max(abs_info.flat * 3, stick_max // 20)
    r2_threshold = stick_max // 2
    log.info(f'Stick range ±{stick_max}, deadzone {stick_deadzone}, R2 threshold {r2_threshold}')

    mouse = create_virtual_mouse()
    gamepad.grab()

    # State
    ax, ay = 0, 0          # raw stick values
    r1_held = False
    r2_held = False
    menu_prev = False

    async def read_events():
        nonlocal ax, ay, r1_held, r2_held, menu_prev
        async for ev in gamepad.async_read_loop():
            if ev.type == ecodes.EV_ABS:
                if ev.code == ecodes.ABS_X:
                    ax = ev.value
                elif ev.code == ecodes.ABS_Y:
                    ay = ev.value
                elif ev.code == ecodes.ABS_RZ:
                    new_r2 = ev.value > r2_threshold
                    if new_r2 != r2_held:
                        r2_held = new_r2
                        mouse.write(ecodes.EV_KEY, ecodes.BTN_RIGHT,
                                    1 if r2_held else 0)
                        mouse.syn()
            elif ev.type == ecodes.EV_KEY:
                if ev.code == ecodes.BTN_TR:       # R1
                    r1_held = bool(ev.value)
                    mouse.write(ecodes.EV_KEY, ecodes.BTN_LEFT,
                                1 if r1_held else 0)
                    mouse.syn()
                elif ev.code == ecodes.BTN_START:  # Menu
                    pressed = bool(ev.value)
                    if pressed and not menu_prev:
                        wvkbd_toggle()
                    menu_prev = pressed

    async def move_loop():
        while True:
            dx = stick_to_delta(ax, stick_deadzone, stick_max, MOUSE_SPEED)
            dy = stick_to_delta(ay, stick_deadzone, stick_max, MOUSE_SPEED)
            if dx or dy:
                if dx:
                    mouse.write(ecodes.EV_REL, ecodes.REL_X, dx)
                if dy:
                    mouse.write(ecodes.EV_REL, ecodes.REL_Y, dy)
                mouse.syn()
            await asyncio.sleep(POLL_INTERVAL)

    await asyncio.gather(read_events(), move_loop())

if __name__ == '__main__':
    asyncio.run(run())

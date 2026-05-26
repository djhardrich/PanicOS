#!/usr/bin/env python3
"""panicos-output-init: pick the best 60Hz mode for each connected output.

Many cheap HDMI-to-VGA adapters either strip the EDID entirely or pass
through one that lacks 60Hz timings at common VGA resolutions
(1024x768, 800x600). The kernel/compositor then picks whatever the
EDID does call "preferred" — frequently 85Hz or 75Hz — and the analog
monitor sync-fails (black screen, "out of range").

Heuristic, in order:

1. Check the EDID-preferred mode (the one wlr-randr marks "(preferred)").
   If preferred is in [59, 61] Hz, the EDID is trustworthy — a real
   digital monitor that knows its native rate. Leave whatever mode
   the compositor selected alone.

2. If preferred is OUT of that range (typically 85Hz or 75Hz at
   1024x768/800x600 — telltale of HDMI-to-VGA adapter passthrough
   of an analog monitor's DDC), switch to the highest 60Hz mode
   that fits within a VGA-safe area cap (1280x1024 ≈ 1.31 MP).
   Pushing higher black-screens common analog CRT/LCD displays.

3. If no 60Hz mode <= the cap exists, leave alone (let the user fix
   it manually via kanshi).

This avoids fighting real HDMI monitors that legitimately want 4K/60
or 1440p/144 (preferred mode is 60Hz → step 1 passes through) while
catching the common bad case of analog-via-adapter overshoot.

Runs on session start via the compositor's autostart. Idempotent on
re-run (no-op if every output is already at 60Hz).

OPT-OUT (any of these disables all automatic switching):

  - Environment variable:   PANICOS_NO_OUTPUT_INIT=1
  - User flag file:         ~/.config/panicos/no-output-init
  - System-wide flag file:  /etc/panicos/no-output-init

Run with --status (or -s) to see what it would do without changing
anything. Run with --help (or -h) for usage.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

# Maximum mode area we'll auto-select for a non-EDID-trustworthy output.
# 1280x1024 is the practical ceiling for analog VGA on common CRT/LCD
# monitors driven through HDMI-to-VGA adapters. Above this, monitor
# sync-fails are common. Override per-output via kanshi if needed.
MAX_AREA_PX = 1280 * 1024

OPT_OUT_PATHS = (
    Path.home() / ".config/panicos/no-output-init",
    Path("/etc/panicos/no-output-init"),
)


def opt_out_reason():
    """Return a human-readable reason for skipping, or None to proceed."""
    if os.environ.get("PANICOS_NO_OUTPUT_INIT"):
        return "PANICOS_NO_OUTPUT_INIT set in environment"
    for p in OPT_OUT_PATHS:
        if p.exists():
            return f"opt-out flag present: {p}"
    return None


def main():
    parser = argparse.ArgumentParser(
        description="PanicOS output mode auto-init (60Hz cap for VGA adapters)",
        epilog="Disable: PANICOS_NO_OUTPUT_INIT=1, "
               "~/.config/panicos/no-output-init, or /etc/panicos/no-output-init",
    )
    parser.add_argument("-s", "--status", action="store_true",
                        help="Show what would be done; make no changes.")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--disable", action="store_true",
                       help="Persistently disable for this user "
                            "(touches ~/.config/panicos/no-output-init).")
    group.add_argument("--enable", action="store_true",
                       help="Re-enable for this user (removes that flag file).")
    args = parser.parse_args()

    user_flag = OPT_OUT_PATHS[0]  # ~/.config/panicos/no-output-init
    if args.disable:
        user_flag.parent.mkdir(parents=True, exist_ok=True)
        user_flag.touch()
        print(f"disabled (created {user_flag})")
        return 0
    if args.enable:
        try:
            user_flag.unlink()
            print(f"enabled (removed {user_flag})")
        except FileNotFoundError:
            print(f"already enabled ({user_flag} did not exist)")
        # Don't touch system-wide flag — only root should manage that
        if OPT_OUT_PATHS[1].exists():
            print(f"note: system-wide flag still present: {OPT_OUT_PATHS[1]}")
        return 0

    reason = opt_out_reason()
    if reason:
        print(f"opt-out: {reason}")
        return 0

    if not os.environ.get("WAYLAND_DISPLAY"):
        print("no WAYLAND_DISPLAY, skipping")
        return 0
    if not shutil.which("wlr-randr"):
        print("wlr-randr not installed")
        return 0

    try:
        out = subprocess.check_output(["wlr-randr"], text=True, timeout=5)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
        print(f"wlr-randr query failed: {e}")
        return 0

    # Parse wlr-randr output into
    #   {output_name: {"current": mode, "preferred": mode, "modes": [mode...]}}
    # where mode = (w, h, hz)
    outputs: dict[str, dict] = {}
    current_output: str | None = None
    in_modes = False
    mode_re = re.compile(r"\s*(\d+)x(\d+) px,\s*([\d.]+) Hz(?:\s*\((.*?)\))?")

    for line in out.splitlines():
        if line and not line.startswith(" ") and " " in line:
            current_output = line.split(" ", 1)[0]
            outputs[current_output] = {
                "current": None, "preferred": None, "modes": []}
            in_modes = False
            continue
        if current_output is None:
            continue
        stripped = line.lstrip()
        if stripped.startswith("Modes:"):
            in_modes = True
            continue
        if line.startswith("  ") and not line.startswith("   "):
            in_modes = False
            continue
        if not in_modes:
            continue
        m = mode_re.match(line)
        if not m:
            continue
        w, h, hz = int(m.group(1)), int(m.group(2)), float(m.group(3))
        flags = (m.group(4) or "").lower()
        mode = (w, h, hz)
        outputs[current_output]["modes"].append(mode)
        if "current" in flags:
            outputs[current_output]["current"] = mode
        if "preferred" in flags:
            outputs[current_output]["preferred"] = mode

    rc = 0
    for name, info in outputs.items():
        if name.startswith("DSI-"):
            continue
        cur = info["current"]
        pref = info["preferred"]
        if cur is None:
            print(f"{name}: no current mode reported; skipping")
            continue

        # Trust the EDID if its preferred mode is at ~60Hz — that's a real
        # digital monitor that knows its native rate. Leave whatever the
        # compositor chose alone (might be the preferred, might be user
        # selection via kanshi — both are intentional).
        if pref is not None and 59.0 <= pref[2] <= 61.0:
            print(f"{name}: EDID preferred is {pref[0]}x{pref[1]}@{pref[2]:g}Hz "
                  f"(60Hz); trusting EDID, leaving current "
                  f"{cur[0]}x{cur[1]}@{cur[2]:g}Hz alone")
            continue

        # Preferred is missing or non-60Hz → likely HDMI-VGA adapter
        # passing analog DDC modes. Pick the highest 60Hz mode within
        # the VGA-safe area cap.
        sixty = [
            (w, h, hz) for (w, h, hz) in info["modes"]
            if 59.0 <= hz <= 61.0 and w * h <= MAX_AREA_PX
        ]
        if not sixty:
            print(f"{name}: no 60Hz mode <= {MAX_AREA_PX}px area; "
                  f"leaving at {cur[0]}x{cur[1]}@{cur[2]:g}Hz")
            continue
        sixty.sort(key=lambda m: (-m[0] * m[1], abs(m[2] - 60.0)))
        bw, bh, bhz = sixty[0]
        target = f"{bw}x{bh}@{bhz:g}Hz"

        # Already on the chosen target? No-op.
        if cur == (bw, bh, bhz):
            print(f"{name}: already at {target}; leaving alone")
            continue

        if args.status:
            print(f"{name}: would switch {cur[0]}x{cur[1]}@{cur[2]:g}Hz → "
                  f"{target} (dry-run)")
            continue

        try:
            subprocess.run(
                ["wlr-randr", "--output", name, "--mode", target],
                check=True, timeout=5,
            )
            print(f"{name}: {cur[0]}x{cur[1]}@{cur[2]:g}Hz → {target}")
        except subprocess.CalledProcessError as e:
            print(f"{name}: wlr-randr rejected {target}: {e}")
            rc = 1
        except subprocess.TimeoutExpired:
            print(f"{name}: wlr-randr timed out applying {target}")
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())

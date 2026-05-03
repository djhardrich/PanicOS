# /etc/profile.d/sway-fullscreen.sh — sourced by login bash shells
# (PortMaster.sh + every port launcher does `. /etc/profile`).
#
# Defines:
#   * UI_SERVICE — used by ROCKNIX-style helpers as the "is sway running?"
#     marker. PortMaster's portmaster_sway_fullscreen.sh greps this for
#     "sway" before issuing swaymsg fullscreen calls.
#   * sway_fullscreen — bash function that polls swaymsg up to 5x to
#     fullscreen a window matching the given app_id (or pid via pidof /
#     pgrep). Vendored verbatim from ROCKNIX
#     packages/rocknix/profile.d/001-functions:180-235.

export UI_SERVICE="panicos-sway.service"

# swaymsg looks at $SWAYSOCK first; if unset it falls back to $I3SOCK
# then `i3 --get-socketpath`, with no XDG_RUNTIME_DIR autoscan. systemd
# launches panicos-es.service (and therefore every port we spawn) with
# only XDG_RUNTIME_DIR set — sway's own SWAYSOCK never propagates.
# Discover the running socket on shell startup and export it. We only
# do the find when SWAYSOCK is unset to avoid clobbering anything sway
# itself set for its own subshells.
if [ -z "${SWAYSOCK:-}" ] && [ -d "${XDG_RUNTIME_DIR:-/var/run/0-runtime-dir}" ]; then
    for sock in "${XDG_RUNTIME_DIR:-/var/run/0-runtime-dir}"/sway-ipc.*.sock; do
        [ -S "$sock" ] || continue
        export SWAYSOCK="$sock"
        break
    done
fi

# OpenAL backend preference. Default backend list picks alsa first,
# which routes through the pipewire-alsa shim and produces "Wait
# timeout... buffer size too low?" spam from ALSOFT under load
# (visible in the Doom Engines / Wolf3D logs). Native pipewire backend
# avoids the shim. Falls through to alsa / sdl2 if pipewire isn't
# available for whatever reason.
export ALSOFT_DRIVERS="pipewire,alsa,sdl2"

# Wayland / SDL2 env, mirroring ROCKNIX's profile.d/050-sway.conf.
# These need to live in profile.d (not just panicos-es.service
# Environment=) because PortMaster ports spawn fresh login shells via
# `Doom Engines.sh` / `Rockbox.sh` style wrappers that source
# /etc/profile — env that lives only in the parent service unit can be
# lost across the chain.
#
# SDL_VIDEODRIVER=wayland is critical: without it, SDL2 binaries fall
# back to KMSDRM, try to grab DRM master sway already holds, hang
# silently, and the user gets a black screen. Doom Engines' Crispy/
# GZDoom/PrBoom binaries all hit this — Crispy's last log line is
# `I_SDL_InitSound` and the next step `I_InitGraphics` never produces
# output. Ports that genuinely want X11 or kmsdrm can override
# per-launcher.
#
# WAYLAND_DISPLAY=wayland-1 is sway's default socket name. Setting it
# explicitly so systemd-spawned children of panicos-es.service can
# connect even if sway hasn't pushed it into their env.
#
# XKB_CONFIG_ROOT pins where xkbcommon looks for keymap data. Without
# it we get `xkbcommon: ERROR: couldn't find a Compose file for locale`
# in port logs.
export SDL_VIDEODRIVER=wayland
export WAYLAND_DISPLAY=wayland-1
export XKB_CONFIG_ROOT=/usr/share/X11/xkb

# XDG_RUNTIME_DIR — also set as Environment= in panicos-sway.service,
# but PortMaster ports that go through `bash --login` chains can drop
# parent service env. Belt-and-suspenders, matches ROCKNIX's
# profile.d/001-functions which exports the same.
export XDG_RUNTIME_DIR=/var/run/0-runtime-dir

# SDL_GAMECONTROLLERCONFIG_FILE — points SDL2 at our system-wide
# gamecontrollerdb (vendored from ROCKNIX, contains the H700 Gamepad
# Nintendo-positional mapping). PortMaster ports override this to
# /tmp/gamecontrollerdb.txt via mod_PanicOS.txt's get_controls — that
# override happens after this export so it wins inside PortMaster.
# Non-PortMaster SDL2 apps (ES itself, anything launched outside the
# port wrapper) get our system db here.
export SDL_GAMECONTROLLERCONFIG_FILE=/usr/share/SDL-GameControllerDB/gamecontrollerdb.txt

function sway_fullscreen {
  local VALUE="${1}"
  local ATTRIBUTE="${2:-app_id}"
  local QUERY_LIMIT=5
  local QUERY_COUNT=0

  if echo "${UI_SERVICE}" | grep -q "sway"; then
    while [ $QUERY_COUNT -lt $QUERY_LIMIT ]; do
      ((QUERY_COUNT++))

      if [[ "${ATTRIBUTE}" = @(pidof|pgrep) ]]; then
        local PID=""
        case "${ATTRIBUTE}" in
          "pidof") PID=$(pidof "${VALUE}") ;;
          "pgrep") PID=$(pgrep "${VALUE}") ;;
        esac
        if [ -z "${PID}" ]; then
          sleep 1
          continue
        fi
        ATTRIBUTE="pid"
        VALUE="${PID}"
      fi

      swaymsg '['"${ATTRIBUTE}"'='"${VALUE}"'] fullscreen enable' && break
      sleep 1
    done
  fi
}

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

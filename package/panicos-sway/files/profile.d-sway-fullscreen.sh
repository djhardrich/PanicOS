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

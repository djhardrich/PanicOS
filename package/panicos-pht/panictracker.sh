#!/bin/sh
# Launch ProHandheldTracker (PHT) under PanicOS.
#
# Replacement for the upstream PortMaster-flavor PanicTracker.sh. We drop
# the PortMaster integration (control.txt, gptokeyb, pm_platform_helper)
# and the multi-arch dispatch since PanicOS targets aarch64 only.

set -u

GAMEDIR=/opt/pht
cd "$GAMEDIR"

# Persistent config / data / plugin overrides live on the rw overlay.
# Place them under /storage so they survive a flavor switch (the user's
# pht state is genuinely user data, not system state).
export PORTMASTER_CONFIG=/storage/pht/cfg
export PORTMASTER_DATA=/storage/pht/data
export PORTMASTER_PLUGINS=/storage/pht/plugins
mkdir -p "$PORTMASTER_CONFIG" "$PORTMASTER_DATA" "$PORTMASTER_PLUGINS"

# SDL2 controller mappings — bundled gamecontrollerdb covers the common
# handheld layouts (RG35XX, RG353, TrimUI etc.). Use the FILE form
# (SDL_GAMECONTROLLERCONFIG_FILE, available since SDL 2.0.10) rather than
# inlining the file content into SDL_GAMECONTROLLERCONFIG — the bundled
# db is ~600KB which overflows the kernel's per-process env+arg limit
# (~128KB on aarch64) and causes every subprocess (date/uname/tee/even
# pht itself) to fail with E2BIG / "Argument list too long".
if [ -f "$GAMEDIR/assets/gamecontrollerdb.txt" ]; then
    export SDL_GAMECONTROLLERCONFIG_FILE="$GAMEDIR/assets/gamecontrollerdb.txt"
fi

# pipewire-pulse socket lives at $XDG_RUNTIME_DIR/pulse/native.
# Mirrors ROCKNIX's global SDL_AUDIODRIVER=pulseaudio (sway profile.d).
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/var/run/0-runtime-dir}
export SDL_AUDIODRIVER=pipewire

# Optional bundled helpers that PHT picks up via env vars. Only export the
# ones that exist so PHT cleanly disables the matching feature when absent.
[ -f "$GAMEDIR/bin/ffmpeg-aarch64" ]          && export PHT_FFMPEG_PATH="$GAMEDIR/bin/ffmpeg-aarch64"
[ -f "$GAMEDIR/bin/shairport-sync-aarch64" ]  && export PHT_SHAIRPORT_PATH="$GAMEDIR/bin/shairport-sync-aarch64"
[ -d "$GAMEDIR/libs-aarch64" ]                && export PHT_SHAIRPORT_LIBS="$GAMEDIR/libs-aarch64"
[ -f "$GAMEDIR/bin/yt-dlp.pyz" ]              && export PHT_YTDLP_PATH="$GAMEDIR/bin/yt-dlp.pyz"
[ -f "$GAMEDIR/scripts/cdig_daemon.py" ]      && export PHT_CDIG_DAEMON="$GAMEDIR/scripts/cdig_daemon.py"
[ -f "$GAMEDIR/scripts/cdig_fetch.py" ]       && export PHT_CDIG_FETCHER="$GAMEDIR/scripts/cdig_fetch.py"
[ -f "$GAMEDIR/scripts/cdig_proxy.py" ]       && export PHT_CDIG_PROXY="$GAMEDIR/scripts/cdig_proxy.py"
[ -f "$GAMEDIR/bin/copyparty-sfx.py" ]        && export PHT_COPYPARTY="$GAMEDIR/bin/copyparty-sfx.py"

LOG="$PORTMASTER_DATA/pht.log"
echo "=== PHT $(date -u +'%Y-%m-%dT%H:%M:%SZ') uname=$(uname -m) ===" >> "$LOG"

# Run under chrt -f 50 if available (CAP_SYS_NICE — process must be root,
# which it is during boot/launch). Falls back to plain exec if chrt is
# missing so the script still works on a stripped-down system.
if command -v chrt >/dev/null 2>&1; then
    exec chrt -f 50 "$GAMEDIR/bin/pht-aarch64" "$@" 2>&1 | tee -a "$LOG"
else
    exec "$GAMEDIR/bin/pht-aarch64" "$@" 2>&1 | tee -a "$LOG"
fi

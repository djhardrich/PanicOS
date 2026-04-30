#!/bin/sh
# Dump enough boot state to /boot/diag/ that a flat-on-the-table device
# (no UART, no SSH, no working console) can be triaged by popping the
# SD card and reading text files on a PC. Sanitises the wifi PSK before
# writing the rendered wpa conf.

set -u

OUT=/boot/diag
mkdir -p "$OUT"

# Wipe stale outputs from a previous boot so the user isn't reading a mix
# of two runs. The marker file is written last; its absence means either
# this run hasn't finished or it crashed mid-dump.
rm -f "$OUT/done.txt"
rm -f "$OUT"/*.log "$OUT"/*.txt 2>/dev/null

# Stamp the run.
date -u +'%Y-%m-%dT%H:%M:%SZ' > "$OUT/timestamp.txt"
uname -a > "$OUT/uname.txt" 2>&1
cat /proc/cmdline > "$OUT/cmdline.txt" 2>&1

# Kernel ring buffer + systemd journal — most of the answer lives here.
dmesg --no-pager > "$OUT/dmesg.log" 2>&1
journalctl -b --no-pager > "$OUT/journal.log" 2>&1

# Failed services + status of every subsystem-A piece individually so you
# don't have to grep through the journal.
systemctl --failed --no-pager > "$OUT/failed.log" 2>&1
systemctl status \
    panicos-wifi-config.service \
    panicos-sshkeys.service \
    'wpa_supplicant@*.service' \
    systemd-networkd.service \
    'getty@tty1.service' \
    dropbear.service \
    --no-pager > "$OUT/services.log" 2>&1

# Network state.
ip addr > "$OUT/ip-addr.log" 2>&1
ip route > "$OUT/ip-route.log" 2>&1
ls -la /sys/class/net /sys/class/ieee80211 > "$OUT/net-class.log" 2>&1

# DRM / fbcon — diagnoses the panel-freeze story.
ls -la /sys/class/drm > "$OUT/drm-class.log" 2>&1
for f in /sys/class/vtconsole/vtcon*/name; do
    [ -e "$f" ] && printf '%s: %s\n' "$f" "$(cat "$f")"
done > "$OUT/vtcon.log" 2>&1

# Modules (most are built-in, but list anyway).
lsmod > "$OUT/lsmod.log" 2>&1

# Block + mount state.
lsblk > "$OUT/lsblk.log" 2>&1
cat /proc/mounts > "$OUT/mounts.log" 2>&1

# Source-of-truth wifi config files on the boot vfat (so we can verify
# the user's edits parsed the way we expected).
{
    echo "=== /boot/panicos-wifi.cfg (PSK redacted) ==="
    if [ -f /boot/panicos-wifi.cfg ]; then
        sed 's/^\(PSK=\).*/\1<REDACTED>/' /boot/panicos-wifi.cfg
    else
        echo "(absent)"
    fi
    echo
    echo "=== /boot/wpa_supplicant.conf (raw drop-in, PSK redacted) ==="
    if [ -f /boot/wpa_supplicant.conf ]; then
        sed 's/psk=".*"/psk="<REDACTED>"/' /boot/wpa_supplicant.conf
    else
        echo "(absent)"
    fi
} > "$OUT/wifi-source.log" 2>&1

# Rendered wpa_supplicant.conf — sanitise the hashed PSK too, even though
# a hash is less sensitive than the cleartext.
{
    if [ -f /run/wpa_supplicant.conf ]; then
        sed 's/psk=[a-fA-F0-9]\{1,\}/psk=<REDACTED-HASH>/' /run/wpa_supplicant.conf
    else
        echo "(no /run/wpa_supplicant.conf — wifi-config skipped or failed)"
    fi
} > "$OUT/wpa-runtime.log" 2>&1

# Dropbear host keys exist?
ls -la /etc/dropbear 2>&1 > "$OUT/dropbear-keys.log"

sync

# Marker — only appears if we got this far. Absence = mid-dump crash.
{
    echo "boot-diagnostic complete"
    echo "stopped at: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    echo "uptime: $(cut -d' ' -f1 /proc/uptime) seconds"
} > "$OUT/done.txt"
sync

echo ">>> panicos-bootdiag: wrote $(ls "$OUT" | wc -l) files to $OUT"

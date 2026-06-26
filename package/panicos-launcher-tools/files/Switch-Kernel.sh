#!/bin/bash
# Switch-Kernel.sh — flip the active kernel (non-RT default <-> PREEMPT_RT)
# by rewriting the DEFAULT label in extlinux.conf on the PANICOS FAT.
# Does NOT reboot; the new kernel takes effect on the next manual reboot.
#
# Test/non-interactive hooks:
#   PANICOS_EXTLINUX   override path to extlinux.conf (default /boot/extlinux/...)
#   PANICOS_NO_REMOUNT skip the /boot rw remount (for tests on a temp file)
#   $1 == --set rt|nonrt   non-interactive flip (used by the test)

EXTLINUX="${PANICOS_EXTLINUX:-/boot/extlinux/extlinux.conf}"
BOOT="/boot"

boot_rw() { [ -n "${PANICOS_NO_REMOUNT:-}" ] || mount -o remount,rw "$BOOT"; }
boot_ro() { [ -n "${PANICOS_NO_REMOUNT:-}" ] || mount -o remount,ro "$BOOT"; }

current_default() { awk '/^DEFAULT /{print $2; exit}' "$EXTLINUX"; }
has_label()       { grep -q "^LABEL $1\$" "$EXTLINUX"; }

# Rewrite the single DEFAULT line to point at $1. Remount /boot rw FIRST (the
# temp file lives on the FAT), write+rename inside the rw window, sync (FAT has
# no journal), then restore ro. Returns non-zero if the write/rename failed.
set_default() {
    local target="$1" tmp="${EXTLINUX}.panicos-tmp" rc=0
    boot_rw || { echo "  ERROR: could not remount $BOOT read-write." >&2; return 1; }
    if sed "s|^DEFAULT .*|DEFAULT ${target}|" "$EXTLINUX" > "$tmp" \
         && mv "$tmp" "$EXTLINUX"; then
        sync
    else
        rc=1
    fi
    rm -f "$tmp" 2>/dev/null
    boot_ro || true
    return $rc
}

# Non-interactive path for tests / scripting.
if [ "${1:-}" = "--set" ]; then
    case "$2" in
        rt)    set_default "PanicOS-RT" ;;
        nonrt) set_default "PanicOS" ;;
        *) echo "usage: $0 --set rt|nonrt" >&2; exit 2 ;;
    esac
    exit $?
fi

# Interactive: re-exec inside foot when launched from ES (no visible TTY).
if [ ! -t 1 ]; then
    [ -f /etc/profile ] && . /etc/profile
    if command -v foot >/dev/null 2>&1; then
        exec foot --app-id=panicos-tool -- "$0" "$@"
    fi
fi

if ! has_label "PanicOS-RT"; then
    echo ""
    echo "  This image ships only the default kernel — no RT kernel present."
    echo "  (Build one with: make kernel-variant DEVICE=<dev> FLAVOR=<fl> RT=1)"
    echo ""
    read -r -t 10 -p "  Press Enter to exit..." 2>/dev/null || true
    exit 0
fi

CUR="$(current_default)"
RUNNING="$(uname -r)"
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║          PanicOS Kernel Switcher         ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "  Running now : $RUNNING"
case "$CUR" in
    PanicOS-RT) echo "  Next boot   : PanicOS-RT (PREEMPT_RT)";;
    *)          echo "  Next boot   : PanicOS (non-RT / CFS)";;
esac
echo ""

if [ "$CUR" = "PanicOS-RT" ]; then
    echo "  Switch to the NON-RT (CFS) kernel?"
    NEW="PanicOS"; NEWDESC="non-RT / CFS"
else
    echo "  Switch to the PREEMPT_RT kernel?"
    NEW="PanicOS-RT"; NEWDESC="PREEMPT_RT"
fi
read -r -p "  [y/N] " ans
case "$ans" in
    y|Y)
        if set_default "$NEW"; then
            echo ""
            echo "  Done. '$NEWDESC' kernel will be active on next boot."
            echo "  Reboot when ready to apply."
        else
            echo "  ERROR: could not update $EXTLINUX (read-only /boot?)."
        fi
        ;;
    *) echo "  Cancelled — no change.";;
esac
echo ""
read -r -t 10 -p "  Press Enter to exit..." 2>/dev/null || true
echo ""

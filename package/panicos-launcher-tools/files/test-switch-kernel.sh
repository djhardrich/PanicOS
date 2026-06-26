#!/usr/bin/env bash
# Unit test for Switch-Kernel.sh's DEFAULT-line rewrite. No /boot needed.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOL="$HERE/Switch-Kernel.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CONF="$TMP/extlinux.conf"

cat > "$CONF" <<'EOF'
DEFAULT PanicOS
TIMEOUT 0

LABEL PanicOS
  LINUX /Image
  FDT /dtb.img
  APPEND console=tty1

LABEL PanicOS-RT
  LINUX /Image-rt
  FDT /dtb.img
  APPEND console=tty1
EOF

run() { PANICOS_EXTLINUX="$CONF" PANICOS_NO_REMOUNT=1 bash "$TOOL" "$@" >/dev/null; }

# Flip to RT.
run --set rt
grep -q '^DEFAULT PanicOS-RT$' "$CONF" || { echo "FAIL: did not switch to RT"; exit 1; }
# Exactly one DEFAULT line remains.
[ "$(grep -c '^DEFAULT ' "$CONF")" = "1" ] || { echo "FAIL: DEFAULT line count != 1"; exit 1; }
# Flip back to non-RT.
run --set nonrt
grep -q '^DEFAULT PanicOS$' "$CONF" || { echo "FAIL: did not switch to non-RT"; exit 1; }
# Idempotent.
run --set nonrt
[ "$(grep -c '^DEFAULT ' "$CONF")" = "1" ] || { echo "FAIL: idempotency broke DEFAULT count"; exit 1; }
# Other labels untouched.
grep -q '^LABEL PanicOS-RT$' "$CONF" || { echo "FAIL: clobbered a LABEL"; exit 1; }

# Failure path: on a real device /boot is read-only until remount, and the temp
# file lives on /boot. Simulate a write-failure location with a chmod a-w dir
# (can't mount in a unit test). The tool must report failure AND leave DEFAULT
# unchanged. Skipped as root (root bypasses the permission bit).
if [ "$(id -u)" != 0 ]; then
    RODIR="$TMP/ro"
    mkdir -p "$RODIR"
    cp "$CONF" "$RODIR/extlinux.conf"
    grep -q '^DEFAULT PanicOS$' "$RODIR/extlinux.conf" || { echo "FAIL: ro test setup"; exit 1; }
    chmod a-w "$RODIR"
    rc=0
    PANICOS_EXTLINUX="$RODIR/extlinux.conf" PANICOS_NO_REMOUNT=1 bash "$TOOL" --set rt >/dev/null 2>&1 || rc=$?
    chmod u+w "$RODIR"
    [ "$rc" -ne 0 ] || { echo "FAIL: tool reported success writing to a read-only location"; exit 1; }
    grep -q '^DEFAULT PanicOS$' "$RODIR/extlinux.conf" || { echo "FAIL: DEFAULT changed despite write failure"; exit 1; }
fi

echo "PASS"

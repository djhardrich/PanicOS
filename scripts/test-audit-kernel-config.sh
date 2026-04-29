#!/usr/bin/env bash
# Tests for audit-kernel-config.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
AUDIT="$HERE/audit-kernel-config.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# Test 1: a fragment with all required options passes.
mkdir -p "$tmpdir/good/linux"
cat > "$tmpdir/good/linux/linux.config.fragment" <<EOF
CONFIG_FB=y
CONFIG_FRAMEBUFFER_CONSOLE=y
CONFIG_DRM_FBDEV_EMULATION=y
CONFIG_USB_HID=y
CONFIG_HID_GENERIC=y
EOF
"$AUDIT" "$tmpdir/good/linux/linux.config.fragment" >/dev/null \
    || fail "test 1: good fragment should pass"
pass "test 1: complete fragment passes"

# Test 2: missing CONFIG_FRAMEBUFFER_CONSOLE makes it fail.
mkdir -p "$tmpdir/bad/linux"
cat > "$tmpdir/bad/linux/linux.config.fragment" <<EOF
CONFIG_FB=y
# CONFIG_FRAMEBUFFER_CONSOLE is not set
CONFIG_DRM_FBDEV_EMULATION=y
CONFIG_USB_HID=y
CONFIG_HID_GENERIC=y
EOF
if "$AUDIT" "$tmpdir/bad/linux/linux.config.fragment" 2>/dev/null; then
    fail "test 2: missing FRAMEBUFFER_CONSOLE should fail"
fi
pass "test 2: missing required option fails"

# Test 3: nonexistent fragment is a soft pass (some SoCs don't have one yet).
"$AUDIT" "$tmpdir/no-such-file" >/dev/null \
    || fail "test 3: missing file should pass (soft skip)"
pass "test 3: missing file soft-skips"

echo "all tests passed"

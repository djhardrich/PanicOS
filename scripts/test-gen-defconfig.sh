#!/usr/bin/env bash
# Tests for gen-defconfig.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GEN="$HERE/gen-defconfig.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# Test 1: composes harness-smoke + minimal into a defconfig containing
# the device fragment lines.
out="$tmpdir/test1.defconfig"
"$GEN" --device harness-smoke --flavor minimal --output "$out"
grep -q '^BR2_aarch64=y$' "$out" || fail "test 1: missing BR2_aarch64=y"
grep -q '^BR2_TARGET_GENERIC_HOSTNAME="panicos-smoke"$' "$out" || fail "test 1: missing hostname"
pass "test 1: harness-smoke + minimal composition"

# Test 2: missing device errors out.
if "$GEN" --device nonexistent --flavor minimal --output "$tmpdir/x" 2>/dev/null; then
	fail "test 2: should have failed for missing device"
fi
pass "test 2: missing device fails"

# Test 3: required args enforced.
if "$GEN" --output "$tmpdir/x" 2>/dev/null; then
	fail "test 3: should have required --device and --flavor"
fi
pass "test 3: required args enforced"

echo "all gen-defconfig tests passed"

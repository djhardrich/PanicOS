#!/usr/bin/env bash
# Tests for panicos-wifi-config.sh. Mocks /boot and /run via env-var
# overrides (PANICOS_WIFI_BOOT_DIR, PANICOS_WIFI_OUT) so the script can
# run on the host without root.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT="$ROOT/package/panicos-wifi-config/panicos-wifi-config.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

run_script() {
    local boot="$1" out="$2"
    PANICOS_WIFI_BOOT_DIR="$boot" PANICOS_WIFI_OUT="$out" \
        sh "$SCRIPT"
}

# Test 1: neither file present → exit 0, no output file written.
boot="$tmpdir/t1/boot"; out="$tmpdir/t1/run/wpa.conf"
mkdir -p "$boot" "$(dirname "$out")"
run_script "$boot" "$out" >/dev/null
[ ! -e "$out" ] || fail "test 1: should not have written $out"
pass "test 1: missing config files → no output, no error"

# Test 2: raw wpa_supplicant.conf present → copied verbatim.
boot="$tmpdir/t2/boot"; out="$tmpdir/t2/run/wpa.conf"
mkdir -p "$boot" "$(dirname "$out")"
cat > "$boot/wpa_supplicant.conf" <<EOF
ctrl_interface=/var/run/wpa_supplicant
network={
    ssid="PowerUserNet"
    psk="hunter2"
}
EOF
run_script "$boot" "$out" >/dev/null
diff "$boot/wpa_supplicant.conf" "$out" \
    || fail "test 2: raw drop-in should be copied verbatim"
pass "test 2: raw wpa_supplicant.conf used verbatim"

# Test 3: key=value rendered, PSK runs through wpa_passphrase.
boot="$tmpdir/t3/boot"; out="$tmpdir/t3/run/wpa.conf"
mkdir -p "$boot" "$(dirname "$out")"
cat > "$boot/panicos-wifi.cfg" <<EOF
SSID=MyHomeNetwork
PSK=correcthorsebatterystaple
COUNTRY=US
HIDDEN=0
EOF
run_script "$boot" "$out" >/dev/null
[ -s "$out" ] || fail "test 3: should have written $out"
grep -q 'country=US' "$out" || fail "test 3: missing country=US"
grep -q 'ssid="MyHomeNetwork"' "$out" || fail "test 3: missing ssid"
grep -q '^[[:space:]]*psk=' "$out" || fail "test 3: missing psk= line"
# PSK must be hashed, not stored in plaintext — wpa_passphrase replaces
# the cleartext key with a 64-char hex hash.
if grep -q 'correcthorsebatterystaple' "$out"; then
    fail "test 3: cleartext PSK leaked into rendered conf"
fi
pass "test 3: key=value rendered + PSK hashed"

# Test 4: HIDDEN=1 sets scan_ssid=1.
boot="$tmpdir/t4/boot"; out="$tmpdir/t4/run/wpa.conf"
mkdir -p "$boot" "$(dirname "$out")"
cat > "$boot/panicos-wifi.cfg" <<EOF
SSID=HiddenNet
PSK=mypassword
COUNTRY=GB
HIDDEN=1
EOF
run_script "$boot" "$out" >/dev/null
grep -q 'scan_ssid=1' "$out" || fail "test 4: HIDDEN=1 should set scan_ssid=1"
pass "test 4: HIDDEN=1 → scan_ssid=1"

# Test 5: raw wpa_supplicant.conf wins over key=value.
boot="$tmpdir/t5/boot"; out="$tmpdir/t5/run/wpa.conf"
mkdir -p "$boot" "$(dirname "$out")"
cat > "$boot/wpa_supplicant.conf" <<EOF
# raw
network={
    ssid="RawNet"
}
EOF
cat > "$boot/panicos-wifi.cfg" <<EOF
SSID=KeyValueNet
PSK=irrelevant
COUNTRY=US
EOF
run_script "$boot" "$out" >/dev/null
grep -q 'RawNet' "$out" || fail "test 5: raw should have won"
grep -q 'KeyValueNet' "$out" && fail "test 5: key=value should have been ignored"
pass "test 5: raw drop-in priority"

# Test 6: empty SSID line in panicos-wifi.cfg → treated as no config (skip).
boot="$tmpdir/t6/boot"; out="$tmpdir/t6/run/wpa.conf"
mkdir -p "$boot" "$(dirname "$out")"
cat > "$boot/panicos-wifi.cfg" <<EOF
# All commented out.
# SSID=
# PSK=
EOF
run_script "$boot" "$out" >/dev/null
[ ! -e "$out" ] || fail "test 6: commented-out cfg should produce no output"
pass "test 6: blank/commented cfg → skip"

# Test 7: short PSK (wpa_passphrase rejects <8 chars) → script exits non-zero,
# no broken conf written.
boot="$tmpdir/t7/boot"; out="$tmpdir/t7/run/wpa.conf"
mkdir -p "$boot" "$(dirname "$out")"
cat > "$boot/panicos-wifi.cfg" <<EOF
SSID=ShortPskNet
PSK=1234567
COUNTRY=US
EOF
if run_script "$boot" "$out" 2>/dev/null; then
    fail "test 7: short PSK should make script fail"
fi
[ ! -e "$out" ] || fail "test 7: should not have written a broken conf"
pass "test 7: short PSK fails clean (no broken conf)"

# Test 8: SSID with embedded double-quote → script exits non-zero, no conf.
boot="$tmpdir/t8/boot"; out="$tmpdir/t8/run/wpa.conf"
mkdir -p "$boot" "$(dirname "$out")"
cat > "$boot/panicos-wifi.cfg" <<EOF
SSID=My"BadSSID
PSK=avalidpassword
COUNTRY=US
EOF
if run_script "$boot" "$out" 2>/dev/null; then
    fail "test 8: SSID with double-quote should fail"
fi
[ ! -e "$out" ] || fail "test 8: should not have written conf"
pass "test 8: SSID with quote rejected"

# Test 9: rendered conf has mode 0600 (security-relevant: contains hashed PSK).
boot="$tmpdir/t9/boot"; out="$tmpdir/t9/run/wpa.conf"
mkdir -p "$boot" "$(dirname "$out")"
cat > "$boot/panicos-wifi.cfg" <<EOF
SSID=ModeTestNet
PSK=avalidpassword
COUNTRY=US
EOF
run_script "$boot" "$out" >/dev/null
[ "$(stat -c '%a' "$out")" = "600" ] || fail "test 9: output not mode 0600"
pass "test 9: rendered conf is mode 0600"

echo "all tests passed"

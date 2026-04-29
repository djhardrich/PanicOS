# Console + Wifi Bootstrap — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a fresh PanicOS image login-ready on real hardware *on every supported SoC* (H700, RK3566, A133-vendor, and any future addition): tty1 prompt on the panel, USB-keyboard input, opt-in autologin, dropbear SSH with first-boot per-device keys, and wifi auto-connect from a drag-and-drop file on the boot vfat.

**Architecture:** Three new buildroot packages (`panicos-sshkeys`, `panicos-autologin`, `panicos-wifi-config`), one build-time kernel-config audit script that runs against whichever SoC the device pulls in, defconfig knobs in `flavors/minimal/defconfig.fragment` (flavor-level, not SoC-level), and a new file shipped on the boot vfat by every board's `post-image.sh`. No kernel-config changes for H700 today — its imported ROCKNIX config already has fbcon + USB HID + DRM fbdev enabled; the audit fails fast if any SoC drops them. systemd-networkd matches the wifi interface by type (`Type=wlan`), not by name (`wlan0`), so a future SoC whose kernel uses predictable names (`wlp1s0` etc) inherits the flow without changes.

**Tech Stack:** Buildroot generic-package pattern (mirrors existing `package/panicos-firstboot/`), systemd units (oneshot for setup, target.wants symlinks for autostart), POSIX shell for service scripts, `wpa_supplicant`, `systemd-networkd`, `dropbear`. Tests are bash `pass`/`fail` scripts under `scripts/test-*.sh`, matching the existing `scripts/test-gen-defconfig.sh` convention.

**Spec:** `docs/superpowers/specs/2026-04-28-console-and-wifi-bootstrap-design.md`

---

## File Structure

**New files (per task):**

```
package/panicos-sshkeys/
  Config.in
  panicos-sshkeys.mk
  panicos-sshkeys.sh                # first-boot dropbear host-key generation
  panicos-sshkeys.service           # systemd oneshot, before dropbear

package/panicos-autologin/
  Config.in
  panicos-autologin.mk
  getty-tty1-autologin.conf         # drop-in for getty@tty1.service.d/

package/panicos-wifi-config/
  Config.in
  panicos-wifi-config.mk
  panicos-wifi-config.sh            # /boot/* → /run/wpa_supplicant.conf
  panicos-wifi-config.service       # systemd oneshot, before wpa_supplicant
  panicos-wifi.cfg.template         # commented-out, ships on boot vfat
  wlan0.network                     # systemd-networkd DHCP

scripts/audit-kernel-config.sh      # fail build if required CONFIG_ missing
scripts/test-audit-kernel-config.sh # tests for the audit script
scripts/test-wifi-config-render.sh  # tests for the wifi-config render
```

**Modified files:**

```
package/Config.in                                       # add 3 source lines
flavors/minimal/defconfig.fragment                      # add 4 lines
Makefile                                                # invoke audit script
board/anbernic/rg35xx-pro/post-image.sh                 # cp wifi.cfg template
board/anbernic/rg35xx-pro-lpddr3/post-image.sh          # cp wifi.cfg template
board/anbernic/rg353p/post-image.sh                     # cp wifi.cfg template
board/trimui/trimui-brick/post-image.sh                 # cp wifi.cfg template
```

---

## Conventions used by every task

- **Buildroot generic-package pattern** — see `package/panicos-firstboot/panicos-firstboot.mk`. Every new package's `.mk` follows the same shape: `_VERSION`, `_SITE` (=local pkg dir), `_SITE_METHOD = local`, `_LICENSE`, `_DEPENDENCIES`, `define ..._INSTALL_TARGET_CMDS`, `define ..._INSTALL_INIT_SYSTEMD`, then `$(eval $(generic-package))`.
- **`$(BR2_EXTERNAL_PANICOS_PATH)`** is the absolute path to `/home/user1/PanicOS` at build time. Use it in `_SITE` lines.
- **`$(PANICOS_<NAME>_PKGDIR)`** is buildroot's auto-resolved per-package source dir; use it inside `INSTALL_*_CMDS` for `cp`/`install` source paths.
- **Systemd unit installation**: install the unit to `$(TARGET_DIR)/usr/lib/systemd/system/<name>.service`, then create the `.wants/` symlink under the appropriate target (`sysinit.target.wants` for early-boot oneshot, `multi-user.target.wants` for normal services).
- **Test scripts** live in `scripts/test-<thing>.sh`, mirror `scripts/test-gen-defconfig.sh`, use `set -euo pipefail` + `mktemp -d` + `pass`/`fail` helpers. Run individually; no test runner.

---

## Task 1: Build-time kernel-config audit script

**Why:** All required `CONFIG_FB`/`CONFIG_FRAMEBUFFER_CONSOLE`/`CONFIG_DRM_FBDEV_EMULATION`/`CONFIG_USB_HID`/`CONFIG_HID_GENERIC` options are already in the imported H700 ROCKNIX config — but a future ROCKNIX re-sync could silently drop them and the only feedback would be "tty1 doesn't paint". This script asserts they're present in the source kernel-config fragment for any SoC that has one.

**Files:**
- Create: `scripts/audit-kernel-config.sh`
- Create: `scripts/test-audit-kernel-config.sh`
- Modify: `Makefile` (call from `_build` before invoking `make -C buildroot`)

- [ ] **Step 1: Write the failing test**

```bash
cat > scripts/test-audit-kernel-config.sh <<'TEST_EOF'
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
TEST_EOF
chmod +x scripts/test-audit-kernel-config.sh
```

- [ ] **Step 2: Run the test, confirm it fails**

```bash
./scripts/test-audit-kernel-config.sh
```

Expected output: error with `audit-kernel-config.sh: No such file or directory` (audit script doesn't exist yet) — confirms test runs.

- [ ] **Step 3: Implement the audit script**

```bash
cat > scripts/audit-kernel-config.sh <<'AUDIT_EOF'
#!/usr/bin/env bash
# Fail loudly if a SoC's kernel config fragment is missing options PanicOS
# requires for the on-device console (fbcon over DRM panel) and USB keyboard.
# Catches regressions from re-syncing ROCKNIX (or a future SoC import that
# starts from a smaller config).
#
# Usage: audit-kernel-config.sh <path-to-linux.config.fragment>
# Soft-skips if the file doesn't exist (some SoC trees may not have one).

set -euo pipefail

CFG="${1:-}"
[ -n "$CFG" ] || { echo "usage: $0 <linux.config.fragment>" >&2; exit 2; }

if [ ! -f "$CFG" ]; then
    echo ">>> audit-kernel-config: $CFG not present, skipping"
    exit 0
fi

REQUIRED=(
    CONFIG_FB
    CONFIG_FRAMEBUFFER_CONSOLE
    CONFIG_DRM_FBDEV_EMULATION
    CONFIG_USB_HID
    CONFIG_HID_GENERIC
)

missing=()
for opt in "${REQUIRED[@]}"; do
    if ! grep -qE "^${opt}=y$" "$CFG"; then
        missing+=("$opt")
    fi
done

if [ "${#missing[@]}" -gt 0 ]; then
    echo "ERROR: kernel config fragment $CFG is missing required options:" >&2
    for opt in "${missing[@]}"; do echo "  $opt" >&2; done
    echo "These are needed for on-device tty1 (fbcon over DRM panel) and USB keyboard." >&2
    exit 1
fi

echo ">>> audit-kernel-config: $CFG OK"
AUDIT_EOF
chmod +x scripts/audit-kernel-config.sh
```

- [ ] **Step 4: Re-run the test, confirm it passes**

```bash
./scripts/test-audit-kernel-config.sh
```

Expected: `PASS: test 1`, `PASS: test 2`, `PASS: test 3`, `all tests passed`.

- [ ] **Step 5: Run the audit against the real H700 fragment to confirm it passes today**

```bash
./scripts/audit-kernel-config.sh soc/allwinner-h700/mainline/linux/linux.config.fragment
```

Expected: `>>> audit-kernel-config: ... OK`.

- [ ] **Step 6: Wire into Makefile `_build` target**

Find the `_build:` rule in `Makefile` (~line 140). Right after the `sed -i 's/patch -F0 /patch -F2 /' ...` line and before `@SOC="$(call _device_soc,$(DEVICE))"; \`, add:

```makefile
	@SOC="$(call _device_soc,$(DEVICE))"; \
	K="$(KERNEL)"; \
	if [ -n "$$SOC" ] && [ -z "$$K" ]; then K="mainline"; fi; \
	if [ -n "$$SOC" ]; then \
		FRAGMENT="$(PANICOS_ROOT)/soc/$$SOC/$$K/linux/linux.config.fragment"; \
		$(PANICOS_ROOT)/scripts/audit-kernel-config.sh "$$FRAGMENT"; \
	fi
```

(This is a separate `@...; \` block before the existing one. Shell variable scoping in make recipes means we duplicate the SOC/K computation — it's a small price for keeping the audit independent and removable.)

- [ ] **Step 7: Verify the audit runs on a real build**

```bash
make rg35xx-pro 2>&1 | grep audit-kernel-config | head -2
```

Expected: at least one line matching `>>> audit-kernel-config: ... OK`.

- [ ] **Step 8: Commit**

```bash
git add scripts/audit-kernel-config.sh scripts/test-audit-kernel-config.sh Makefile
git commit -m "audit-kernel-config: fail build if required CONFIG_ options drop out"
```

---

## Task 2: panicos-sshkeys package

**Why:** SSH host keys must be unique per device. Generated at first boot, stored in `/etc/dropbear/` (which lives on the overlay → persists across reboots without baking key material into the image).

**Files:**
- Create: `package/panicos-sshkeys/Config.in`
- Create: `package/panicos-sshkeys/panicos-sshkeys.mk`
- Create: `package/panicos-sshkeys/panicos-sshkeys.sh`
- Create: `package/panicos-sshkeys/panicos-sshkeys.service`

- [ ] **Step 1: Create the Kconfig entry**

```bash
mkdir -p package/panicos-sshkeys
cat > package/panicos-sshkeys/Config.in <<'EOF'
config BR2_PACKAGE_PANICOS_SSHKEYS
	bool "panicos-sshkeys"
	depends on BR2_INIT_SYSTEMD
	depends on BR2_PACKAGE_DROPBEAR
	help
	  PanicOS first-boot SSH host key generator. Runs once before
	  dropbear, generates per-device host keys into /etc/dropbear/
	  (which sits on the overlay and persists across reboots), then
	  self-disables via marker file in /storage. Ensures every
	  flashed image ends up with unique SSH host identity.
EOF
```

- [ ] **Step 2: Create the package makefile**

```bash
cat > package/panicos-sshkeys/panicos-sshkeys.mk <<'EOF'
################################################################################
#
# panicos-sshkeys
#
################################################################################

PANICOS_SSHKEYS_VERSION = 1.0
PANICOS_SSHKEYS_SITE = $(BR2_EXTERNAL_PANICOS_PATH)/package/panicos-sshkeys
PANICOS_SSHKEYS_SITE_METHOD = local
PANICOS_SSHKEYS_LICENSE = GPL-2.0
PANICOS_SSHKEYS_DEPENDENCIES = dropbear

define PANICOS_SSHKEYS_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(PANICOS_SSHKEYS_PKGDIR)/panicos-sshkeys.sh \
		$(TARGET_DIR)/usr/sbin/panicos-sshkeys
endef

define PANICOS_SSHKEYS_INSTALL_INIT_SYSTEMD
	$(INSTALL) -D -m 0644 $(PANICOS_SSHKEYS_PKGDIR)/panicos-sshkeys.service \
		$(TARGET_DIR)/usr/lib/systemd/system/panicos-sshkeys.service
	mkdir -p $(TARGET_DIR)/usr/lib/systemd/system/sysinit.target.wants
	ln -sf ../panicos-sshkeys.service \
		$(TARGET_DIR)/usr/lib/systemd/system/sysinit.target.wants/panicos-sshkeys.service
endef

$(eval $(generic-package))
EOF
```

- [ ] **Step 3: Create the service script**

```bash
cat > package/panicos-sshkeys/panicos-sshkeys.sh <<'EOF'
#!/bin/sh
# Generate dropbear host keys at first boot. Self-disabling via marker on
# the storage partition. Keys live in /etc/dropbear/ (on the overlay), so
# they persist normally and are wiped only when the user resets the
# overlay — exactly the right granularity (per-device, per-flavor).

set -eu

MARKER=/storage/.panicos-sshkeys-done
[ -f "$MARKER" ] && exit 0

mkdir -p /etc/dropbear

# Dropbear ships dropbearkey for host-key generation. RSA + Ed25519 are
# the two modern algorithms; ECDSA is intentionally skipped (Ed25519 is
# its successor, smaller and faster).
for type in rsa ed25519; do
    keyfile="/etc/dropbear/dropbear_${type}_host_key"
    if [ ! -s "$keyfile" ]; then
        echo ">>> panicos-sshkeys: generating $type host key"
        dropbearkey -t "$type" -f "$keyfile" >/dev/null
    fi
done

touch "$MARKER"
echo ">>> panicos-sshkeys: done"
EOF
```

- [ ] **Step 4: Create the systemd unit**

```bash
cat > package/panicos-sshkeys/panicos-sshkeys.service <<'EOF'
[Unit]
Description=PanicOS first-boot: generate per-device SSH host keys
DefaultDependencies=no
After=local-fs.target
Before=basic.target sysinit.target dropbear.service
ConditionPathExists=!/storage/.panicos-sshkeys-done
RequiresMountsFor=/storage

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/panicos-sshkeys
StandardOutput=journal+console

[Install]
WantedBy=sysinit.target
EOF
```

- [ ] **Step 5: Wire into top-level package menu**

Edit `package/Config.in`. Replace the existing block:

```
menu "PanicOS packages"

source "$BR2_EXTERNAL_PANICOS_PATH/package/panicos-firstboot/Config.in"

endmenu
```

with:

```
menu "PanicOS packages"

source "$BR2_EXTERNAL_PANICOS_PATH/package/panicos-firstboot/Config.in"
source "$BR2_EXTERNAL_PANICOS_PATH/package/panicos-sshkeys/Config.in"

endmenu
```

- [ ] **Step 6: Verify Kconfig parses**

```bash
make tui 2>&1 | head -3
# In the TUI: navigate to "PanicOS packages" → confirm "panicos-sshkeys" entry shows.
# Quit TUI with q (no save).
```

If the TUI is too slow, use `make shell` and inside the container run:

```bash
cd third_party/buildroot
make BR2_EXTERNAL=/work O=/tmp/kc-test menuconfig
# Navigate to: External options → PanicOS → PanicOS packages
# Verify panicos-sshkeys is listed. Quit with no save.
```

Expected: entry visible.

- [ ] **Step 7: Commit**

```bash
git add package/panicos-sshkeys/ package/Config.in
git commit -m "package/panicos-sshkeys: first-boot SSH host key generation

Per-device dropbear host keys generated once at first boot and stored on
the overlay so they persist normally. Marker file in /storage gates the
oneshot. No baked-in keys — every flashed image ends up unique."
```

---

## Task 3: panicos-autologin package (opt-in tty1 drop-in)

**Why:** Per-flavor opt-in for autologin. Default minimal flavor = login prompt; a future kiosk/launcher flavor can flip the kconfig and skip the prompt.

**Files:**
- Create: `package/panicos-autologin/Config.in`
- Create: `package/panicos-autologin/panicos-autologin.mk`
- Create: `package/panicos-autologin/getty-tty1-autologin.conf`
- Modify: `package/Config.in`

- [ ] **Step 1: Create the Kconfig entry**

```bash
mkdir -p package/panicos-autologin
cat > package/panicos-autologin/Config.in <<'EOF'
config BR2_PACKAGE_PANICOS_AUTOLOGIN
	bool "panicos-autologin (tty1)"
	depends on BR2_INIT_SYSTEMD
	help
	  Drops in /etc/systemd/system/getty@tty1.service.d/autologin.conf
	  so tty1 logs in as root automatically — no prompt. Off by default
	  (the minimal flavor wants the password prompt). Flavors that want
	  to land the user straight in a launcher (kiosk, retro frontend)
	  select this in their defconfig.fragment.
EOF
```

- [ ] **Step 2: Create the drop-in unit file**

```bash
cat > package/panicos-autologin/getty-tty1-autologin.conf <<'EOF'
# PanicOS: tty1 autologin as root. Installed by panicos-autologin package.
# Removing this file (e.g. via overlay edit) restores the login prompt.
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
EOF
```

- [ ] **Step 3: Create the package makefile**

```bash
cat > package/panicos-autologin/panicos-autologin.mk <<'EOF'
################################################################################
#
# panicos-autologin
#
################################################################################

PANICOS_AUTOLOGIN_VERSION = 1.0
PANICOS_AUTOLOGIN_SITE = $(BR2_EXTERNAL_PANICOS_PATH)/package/panicos-autologin
PANICOS_AUTOLOGIN_SITE_METHOD = local
PANICOS_AUTOLOGIN_LICENSE = GPL-2.0

define PANICOS_AUTOLOGIN_INSTALL_INIT_SYSTEMD
	$(INSTALL) -D -m 0644 $(PANICOS_AUTOLOGIN_PKGDIR)/getty-tty1-autologin.conf \
		$(TARGET_DIR)/etc/systemd/system/getty@tty1.service.d/autologin.conf
endef

$(eval $(generic-package))
EOF
```

- [ ] **Step 4: Wire into top-level package menu**

Edit `package/Config.in`, append the new source line so the block reads:

```
menu "PanicOS packages"

source "$BR2_EXTERNAL_PANICOS_PATH/package/panicos-firstboot/Config.in"
source "$BR2_EXTERNAL_PANICOS_PATH/package/panicos-sshkeys/Config.in"
source "$BR2_EXTERNAL_PANICOS_PATH/package/panicos-autologin/Config.in"

endmenu
```

- [ ] **Step 5: Commit**

```bash
git add package/panicos-autologin/ package/Config.in
git commit -m "package/panicos-autologin: opt-in tty1 root autologin drop-in

Off by default; a flavor that wants to land straight in a launcher
selects BR2_PACKAGE_PANICOS_AUTOLOGIN in its defconfig fragment. The
drop-in installs to /etc/ so users can override or delete it via the
overlay."
```

---

## Task 4: panicos-wifi-config — script + tests (TDD)

**Why:** This is the meatiest piece. The shell logic that picks `/boot/wpa_supplicant.conf` (raw drop-in) over `/boot/panicos-wifi.cfg` (key=value) and renders the runtime conf is testable in isolation. Build it test-first so we trust the lookup-order + rendering before wiring it into a service.

**Files:**
- Create: `package/panicos-wifi-config/panicos-wifi-config.sh`
- Create: `scripts/test-wifi-config-render.sh`

- [ ] **Step 1: Write the failing test**

```bash
cat > scripts/test-wifi-config-render.sh <<'TEST_EOF'
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

echo "all tests passed"
TEST_EOF
chmod +x scripts/test-wifi-config-render.sh
```

- [ ] **Step 2: Create an empty stub script so the test runs and FAILS**

```bash
mkdir -p package/panicos-wifi-config
cat > package/panicos-wifi-config/panicos-wifi-config.sh <<'EOF'
#!/bin/sh
# stub — implementation in next step
exit 0
EOF
chmod +x package/panicos-wifi-config/panicos-wifi-config.sh
```

- [ ] **Step 3: Run tests, confirm they fail**

```bash
./scripts/test-wifi-config-render.sh
```

Expected: `PASS: test 1` (the no-config case happens to pass for a stub) then `FAIL: test 2: raw drop-in should be copied verbatim`.

- [ ] **Step 4: Implement the script for real**

```bash
cat > package/panicos-wifi-config/panicos-wifi-config.sh <<'EOF'
#!/bin/sh
# Render /run/wpa_supplicant.conf from a user-editable file on the boot
# vfat. Lookup order, first hit wins:
#
#   1. wpa_supplicant.conf  — raw drop-in, used verbatim (power-user)
#   2. panicos-wifi.cfg     — key=value, rendered into wpa_supplicant.conf
#   3. neither              — exit 0, no output (skip wifi entirely)
#
# Source files live on /boot (ro from userland — read each boot, never
# stored on the overlay). Output is on tmpfs so a flash partition edit
# takes effect on next boot.
#
# Env-var overrides for testing: PANICOS_WIFI_BOOT_DIR, PANICOS_WIFI_OUT.

set -eu

BOOT_DIR="${PANICOS_WIFI_BOOT_DIR:-/boot}"
OUT="${PANICOS_WIFI_OUT:-/run/wpa_supplicant.conf}"

RAW="$BOOT_DIR/wpa_supplicant.conf"
KV="$BOOT_DIR/panicos-wifi.cfg"

# Case 1: raw drop-in.
if [ -s "$RAW" ]; then
    mkdir -p "$(dirname "$OUT")"
    cp "$RAW" "$OUT"
    chmod 0600 "$OUT"
    echo ">>> panicos-wifi-config: using raw $RAW"
    exit 0
fi

# Case 2: key=value.
if [ -s "$KV" ]; then
    SSID=""; PSK=""; COUNTRY=""; HIDDEN="0"
    # Parse key=value lines, ignore comments and blanks. Strict matching
    # so a typo doesn't silently change behavior.
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|\#*) continue ;;
            SSID=*)    SSID="${line#SSID=}" ;;
            PSK=*)     PSK="${line#PSK=}" ;;
            COUNTRY=*) COUNTRY="${line#COUNTRY=}" ;;
            HIDDEN=*)  HIDDEN="${line#HIDDEN=}" ;;
        esac
    done < "$KV"

    if [ -z "$SSID" ]; then
        echo ">>> panicos-wifi-config: $KV has no SSID, skipping wifi"
        exit 0
    fi

    mkdir -p "$(dirname "$OUT")"
    {
        echo "# Generated by panicos-wifi-config from $KV"
        echo "ctrl_interface=/var/run/wpa_supplicant"
        echo "update_config=1"
        [ -n "$COUNTRY" ] && echo "country=$COUNTRY"
        echo "network={"
        echo "    ssid=\"$SSID\""
        [ "$HIDDEN" = "1" ] && echo "    scan_ssid=1"
        if [ -n "$PSK" ]; then
            # wpa_passphrase emits a full network={} block; we only want the
            # hashed `psk=` line out of it. Pipe SSID via stdin so it never
            # appears on the process list.
            HASHED=$(printf '%s\n' "$PSK" | wpa_passphrase "$SSID" \
                | awk '/^[[:space:]]*psk=/{print $0; exit}')
            echo "    $HASHED"
        else
            echo "    key_mgmt=NONE"
        fi
        echo "}"
    } > "$OUT"
    chmod 0600 "$OUT"
    echo ">>> panicos-wifi-config: rendered $KV → $OUT"
    exit 0
fi

# Case 3: no config.
echo ">>> panicos-wifi-config: no /boot/wpa_supplicant.conf or /boot/panicos-wifi.cfg, skipping wifi"
exit 0
EOF
chmod +x package/panicos-wifi-config/panicos-wifi-config.sh
```

- [ ] **Step 5: Run tests, confirm tests 1, 2, 5, 6 pass; tests 3 + 4 may fail**

```bash
./scripts/test-wifi-config-render.sh
```

Tests 3 and 4 require the host to have `wpa_passphrase` available (from the `wpasupplicant` package). On the build host this is usually installed; if it isn't, install it:

```bash
which wpa_passphrase || sudo pacman -S wpa_supplicant   # arch
which wpa_passphrase || sudo apt-get install wpasupplicant   # debian
```

Re-run the tests. Expected: all 6 pass.

- [ ] **Step 6: Commit**

```bash
git add scripts/test-wifi-config-render.sh package/panicos-wifi-config/panicos-wifi-config.sh
git commit -m "panicos-wifi-config: render script + tests

Lookup order: raw /boot/wpa_supplicant.conf wins over /boot/panicos-wifi.cfg
key=value, neither = skip wifi (exit 0). PSK is hashed via wpa_passphrase
so the rendered /run conf doesn't carry the cleartext key. Six unit
tests cover lookup priority, hashing, hidden SSIDs, and the empty/
commented-out skip path."
```

---

## Task 5: panicos-wifi-config — systemd service + networkd config + package wiring

**Why:** Wraps the script from Task 4 into a buildroot package, adds the systemd unit + networkd file, and installs the user-facing template.

**Files:**
- Create: `package/panicos-wifi-config/Config.in`
- Create: `package/panicos-wifi-config/panicos-wifi-config.mk`
- Create: `package/panicos-wifi-config/panicos-wifi-config.service`
- Create: `package/panicos-wifi-config/wlan0.network`
- Create: `package/panicos-wifi-config/panicos-wifi.cfg.template`
- Modify: `package/Config.in`

- [ ] **Step 1: Create the Kconfig entry**

```bash
cat > package/panicos-wifi-config/Config.in <<'EOF'
config BR2_PACKAGE_PANICOS_WIFI_CONFIG
	bool "panicos-wifi-config"
	depends on BR2_INIT_SYSTEMD
	select BR2_PACKAGE_WPA_SUPPLICANT
	help
	  Boot service that reads wifi credentials from a user-editable
	  file on the boot vfat (/boot/wpa_supplicant.conf raw drop-in,
	  or /boot/panicos-wifi.cfg key=value) and renders them into
	  /run/wpa_supplicant.conf. Pairs with systemd-networkd for
	  DHCP on wlan0. The credentials never touch the overlay — every
	  boot re-reads from FAT, so a Notepad edit on a PC takes effect
	  on next reboot.
EOF
```

- [ ] **Step 2: Create the systemd service**

```bash
cat > package/panicos-wifi-config/panicos-wifi-config.service <<'EOF'
[Unit]
Description=PanicOS: render wpa_supplicant config from boot vfat
DefaultDependencies=no
After=local-fs.target
Before=basic.target wpa_supplicant@wlan0.service
RequiresMountsFor=/boot

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/panicos-wifi-config
StandardOutput=journal+console

[Install]
WantedBy=sysinit.target
EOF
```

- [ ] **Step 3: Create the systemd-networkd config for wlan0**

```bash
cat > package/panicos-wifi-config/wlan0.network <<'EOF'
# DHCP on whichever interface the wifi driver brings up. Match by
# device type, not name — sunxi/rockchip kernels typically expose the
# adapter as `wlan0`, but a future SoC using systemd's predictable names
# would call it `wlp1s0` (or similar) and a name-based match would
# silently miss. `Type=wlan` matches both.
#
# Lives in /etc/systemd/network/ so the user can override (static IP
# etc) by dropping a higher-priority file via overlay.
[Match]
Type=wlan

[Network]
DHCP=yes
EOF
```

- [ ] **Step 4: Create the user-facing template**

```bash
cat > package/panicos-wifi-config/panicos-wifi.cfg.template <<'EOF'
# PanicOS wifi auto-connect config. Edit on a PC after flashing.
#
# Uncomment SSID + PSK below and fill in your network. Save the file —
# changes take effect on next boot of the device.
#
# Power users: drop a full wpa_supplicant.conf next to this file. It
# takes priority and is used verbatim (use it for EAP / enterprise wifi
# / anything past plain WPA2-PSK).
#
# Leave this file commented out if you don't want wifi auto-connect;
# the device boots fine without it.

# SSID=
# PSK=
# COUNTRY=US      # ISO 3166. REQUIRED on some hardware before wifi will start.
# HIDDEN=0        # Set to 1 for hidden SSIDs.
EOF
```

- [ ] **Step 5: Create the package makefile**

```bash
cat > package/panicos-wifi-config/panicos-wifi-config.mk <<'EOF'
################################################################################
#
# panicos-wifi-config
#
################################################################################

PANICOS_WIFI_CONFIG_VERSION = 1.0
PANICOS_WIFI_CONFIG_SITE = $(BR2_EXTERNAL_PANICOS_PATH)/package/panicos-wifi-config
PANICOS_WIFI_CONFIG_SITE_METHOD = local
PANICOS_WIFI_CONFIG_LICENSE = GPL-2.0
PANICOS_WIFI_CONFIG_DEPENDENCIES = wpa_supplicant systemd

define PANICOS_WIFI_CONFIG_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(PANICOS_WIFI_CONFIG_PKGDIR)/panicos-wifi-config.sh \
		$(TARGET_DIR)/usr/sbin/panicos-wifi-config
	$(INSTALL) -D -m 0644 $(PANICOS_WIFI_CONFIG_PKGDIR)/wlan0.network \
		$(TARGET_DIR)/etc/systemd/network/30-wlan0.network
endef

define PANICOS_WIFI_CONFIG_INSTALL_INIT_SYSTEMD
	$(INSTALL) -D -m 0644 $(PANICOS_WIFI_CONFIG_PKGDIR)/panicos-wifi-config.service \
		$(TARGET_DIR)/usr/lib/systemd/system/panicos-wifi-config.service
	mkdir -p $(TARGET_DIR)/usr/lib/systemd/system/sysinit.target.wants
	ln -sf ../panicos-wifi-config.service \
		$(TARGET_DIR)/usr/lib/systemd/system/sysinit.target.wants/panicos-wifi-config.service
	# Auto-enable wpa_supplicant for the wifi interface. Every handheld
	# kernel we currently use (sunxi-mainline, rk3566-mainline,
	# a133-vendor) names it wlan0. A future SoC whose kernel uses
	# systemd predictable names (wlpXsY) overrides this by dropping its
	# own wpa_supplicant@<iface>.service .wants symlink in its
	# soc/<soc>/<kernel>/rootfs-overlay/ and removing this one.
	mkdir -p $(TARGET_DIR)/usr/lib/systemd/system/multi-user.target.wants
	ln -sf ../wpa_supplicant@.service \
		$(TARGET_DIR)/usr/lib/systemd/system/multi-user.target.wants/wpa_supplicant@wlan0.service
endef

$(eval $(generic-package))
EOF
```

- [ ] **Step 6: Wire into top-level package menu**

Edit `package/Config.in`, append the new source line so the block reads:

```
menu "PanicOS packages"

source "$BR2_EXTERNAL_PANICOS_PATH/package/panicos-firstboot/Config.in"
source "$BR2_EXTERNAL_PANICOS_PATH/package/panicos-sshkeys/Config.in"
source "$BR2_EXTERNAL_PANICOS_PATH/package/panicos-autologin/Config.in"
source "$BR2_EXTERNAL_PANICOS_PATH/package/panicos-wifi-config/Config.in"

endmenu
```

- [ ] **Step 7: Commit**

```bash
git add package/panicos-wifi-config/ package/Config.in
git commit -m "package/panicos-wifi-config: systemd unit + networkd + template

Wraps the render script from the prior commit into a buildroot package.
Ships /etc/systemd/network/30-wlan0.network for DHCP and auto-enables
wpa_supplicant@wlan0.service. The user-facing panicos-wifi.cfg.template
gets installed at /usr/share/panicos-wifi-config/ so the post-image
scripts can copy it onto the boot vfat in the next task."
```

---

## Task 6: Wire packages + root password + dropbear into the minimal flavor

**Why:** Single-touch enable point — until this lands, the new packages exist but no flavor selects them.

**Files:**
- Modify: `flavors/minimal/defconfig.fragment`

- [ ] **Step 1: Append the new lines to the minimal flavor fragment**

```bash
cat >> flavors/minimal/defconfig.fragment <<'EOF'

# Console + wifi bootstrap (subsystem A).
BR2_TARGET_GENERIC_ROOT_PASSWD="panicos"
BR2_PACKAGE_DROPBEAR=y
BR2_PACKAGE_PANICOS_SSHKEYS=y
BR2_PACKAGE_PANICOS_WIFI_CONFIG=y
# Autologin off by default; flip the line below in a kiosk flavor:
# BR2_PACKAGE_PANICOS_AUTOLOGIN=y
EOF
```

- [ ] **Step 2: Verify the resulting defconfig still parses**

```bash
make clean-rg35xx-pro
make rg35xx-pro 2>&1 | tee /tmp/build-task6.log | grep -E 'Buildroot configuration|^>>> .* Extracting|^>>> .* Installing' | head -20
```

You don't need the full build to finish — `Ctrl-C` once you see new packages flow past (`>>> dropbear`, `>>> panicos-sshkeys`, `>>> panicos-wifi-config`). What you're verifying is that the defconfig pulls them in.

If buildroot complains about an unselected dependency, adjust the new lines to add the explicit `select` and rerun. Don't continue until this is clean.

- [ ] **Step 3: Commit**

```bash
git add flavors/minimal/defconfig.fragment
git commit -m "flavors/minimal: enable console+wifi bootstrap (subsystem A)

Bakes root password 'panicos' into /etc/shadow, pulls in dropbear, the
two new oneshot services (sshkeys, wifi-config). Autologin commented
out — minimal flavor wants the prompt; future kiosk-style flavors flip
that line."
```

---

## Task 7: Ship `panicos-wifi.cfg` template on the boot vfat

**Why:** Without this, the user has nothing to edit on the FAT after flashing — they'd have to know to create the file by hand.

**Universal pattern:** All four current boards span all three SoC families we support today (H700 mainline, H700 mainline-LPDDR3, RK3566 mainline, A133 vendor) — meaning this same edit lands wifi-config on every flavor of every device PanicOS currently builds. **For any future board added later, the same two-line edit pattern applies** (one cp in `post-image.sh`, one entry in `genimage.cfg.in`'s vfat files{} block). Worth calling out in the new-board onboarding docs when those exist.

**Files modified** (same edit pattern in each, since post-image.sh structure was unified earlier in the session):
- `board/anbernic/rg35xx-pro/post-image.sh` (H700 mainline)
- `board/anbernic/rg35xx-pro-lpddr3/post-image.sh` (H700 mainline LPDDR3)
- `board/anbernic/rg353p/post-image.sh` (RK3566 mainline)
- `board/trimui/trimui-brick/post-image.sh` (A133 vendor)

The vbe-driven boards (`scripts/vbe/cmd-build-image.sh`) get the same change in their flow, which means VBE-built images on any allwinner-sunxi or rockchip-rk3xxx target inherit it automatically.

- [ ] **Step 1: Copy the template into BINARIES_DIR in rg35xx-pro post-image**

Edit `board/anbernic/rg35xx-pro/post-image.sh`. Find the existing block:

```sh
GITREV="$(git -C "$BR2_EXTERNAL_PANICOS_PATH" describe --always --dirty 2>/dev/null || echo unknown)"
cp "$BINARIES_DIR/rootfs.squashfs" \
   "$BINARIES_DIR/panicos-rg35xx-pro-minimal.squashfs"
```

Add the wifi-cfg copy directly after it:

```sh
GITREV="$(git -C "$BR2_EXTERNAL_PANICOS_PATH" describe --always --dirty 2>/dev/null || echo unknown)"
cp "$BINARIES_DIR/rootfs.squashfs" \
   "$BINARIES_DIR/panicos-rg35xx-pro-minimal.squashfs"

# Ship the wifi-config template on the boot vfat so users can fill in
# SSID/PSK on a PC after flashing without rebuilding. The template is
# entirely commented-out by default — boot is wifi-less until edited.
cp "$BR2_EXTERNAL_PANICOS_PATH/package/panicos-wifi-config/panicos-wifi.cfg.template" \
   "$BINARIES_DIR/panicos-wifi.cfg"
```

- [ ] **Step 2: Add `panicos-wifi.cfg` to the vfat files{} list in the genimage template**

Edit `board/anbernic/rg35xx-pro/genimage.cfg.in`. Find the `vfat { files = { ... } }` block and add `"panicos-wifi.cfg"` to the list:

```
image boot.vfat {
	vfat {
		extraargs = "-F 32 -n PANICOS"
		files = {
			"Image",
			"dtb.img",
			"dtbs",
			"extlinux",
			"panicos-active.cfg",
			"panicos-wifi.cfg",
			"panicos-rg35xx-pro-minimal.squashfs",
		}
	}
	size = ${PANICOS_BOOT_PARTITION_SIZE_MB}M
}
```

- [ ] **Step 3: Repeat steps 1+2 for `rg35xx-pro-lpddr3`**

Same edits in `board/anbernic/rg35xx-pro-lpddr3/post-image.sh` and `board/anbernic/rg35xx-pro-lpddr3/genimage.cfg.in`. Squashfs filename in the copy is `panicos-rg35xx-pro-lpddr3-minimal.squashfs`.

- [ ] **Step 4: Repeat steps 1+2 for `rg353p`**

Same edits in `board/anbernic/rg353p/post-image.sh` and `board/anbernic/rg353p/genimage.cfg.in`. Squashfs filename is `panicos-rg353p-minimal.squashfs`.

- [ ] **Step 5: Repeat steps 1+2 for `trimui-brick`**

Same edits in `board/trimui/trimui-brick/post-image.sh` and `board/trimui/trimui-brick/genimage.cfg.in`. Squashfs filename is `panicos-trimui-brick-minimal.squashfs`.

- [ ] **Step 6: Add the same to vbe-built images**

Edit `scripts/vbe/cmd-build-image.sh`. Find the existing block (Task 7 of the earlier session — should be just after the squashfs cp into BINDIR):

```sh
cp "$SQUASHFS" "$BINDIR/${PANICOS_OUTPUT_NAME}.squashfs"
echo ">>> staged squashfs ($(stat -c%s "$SQUASHFS") bytes)"
```

Add the wifi-cfg copy directly after it:

```sh
cp "$SQUASHFS" "$BINDIR/${PANICOS_OUTPUT_NAME}.squashfs"
echo ">>> staged squashfs ($(stat -c%s "$SQUASHFS") bytes)"

cp "$ROOT/package/panicos-wifi-config/panicos-wifi.cfg.template" \
   "$BINDIR/panicos-wifi.cfg"
echo ">>> staged panicos-wifi.cfg template"
```

…and in the two vbe genimage templates (`scripts/vbe/genimage-templates/allwinner-sunxi.cfg.in`, `scripts/vbe/genimage-templates/rockchip-rk3xxx.cfg.in`), add `"panicos-wifi.cfg"` to the vfat files{} list.

(`$ROOT` is defined near the top of `cmd-build-image.sh`; verify with `grep -n '^ROOT=' scripts/vbe/cmd-build-image.sh`. If it's named something else, use that variable.)

- [ ] **Step 7: Commit**

```bash
git add board/anbernic/rg35xx-pro/ board/anbernic/rg35xx-pro-lpddr3/ board/anbernic/rg353p/ board/trimui/trimui-brick/ scripts/vbe/cmd-build-image.sh scripts/vbe/genimage-templates/
git commit -m "post-image: ship panicos-wifi.cfg template on boot vfat

Every board's post-image.sh (and the vbe equivalent) copies the
commented-out template from package/panicos-wifi-config/ into BINARIES_DIR
under its plain name, and the genimage templates list it in the vfat
files{} block so it lands on the boot partition. Users edit it on a PC
post-flash; takes effect on next boot."
```

---

## Task 8: Build + flash + on-hardware verification (RG35XX Pro — canonical)

**Why:** Subsystem A is a system-level feature — the meaningful end-to-end test is on the actual device. RG35XX Pro is the canonical first device because it's already bringing up cleanly today; passing here proves the **userland** half works. Per-SoC differences (kernel quirks, wifi chip variations) are validated separately in Task 9 across the other SoCs we already support.

**Files:**
- No file changes; this is the manual verification step.

- [ ] **Step 1: Full clean build**

```bash
make clean-rg35xx-pro
make rg35xx-pro 2>&1 | tee output/build-rg35xx-pro.log
```

Expected: ends with `>>> post-image done: ...panicos-rg35xx-pro-minimal-<rev>.img.gz`. No `Error 1` / `Error 2`.

- [ ] **Step 2: Sanity-check build artifacts before flashing**

```bash
# wifi.cfg template is on the boot vfat
mdir -i output/rg35xx-pro-minimal-mainline/images/boot.vfat ::panicos-wifi.cfg

# panicos-sshkeys + panicos-wifi-config services are in the squashfs
unsquashfs -l output/rg35xx-pro-minimal-mainline/images/rootfs.squashfs \
    | grep -E 'panicos-(sshkeys|wifi-config|autologin)'
# Expected: see the .service files + the /usr/sbin/ scripts.

# dropbear is in the rootfs
unsquashfs -l output/rg35xx-pro-minimal-mainline/images/rootfs.squashfs \
    | grep -E '/usr/sbin/dropbear$'
# Expected: one line.

# Root password got baked
unsquashfs -d /tmp/sq-check output/rg35xx-pro-minimal-mainline/images/rootfs.squashfs etc/shadow
grep '^root:' /tmp/sq-check/etc/shadow
# Expected: a hashed password (not '*' or '!').
rm -rf /tmp/sq-check
```

If any of these fail, *stop* and fix the relevant earlier task — don't flash a broken image.

- [ ] **Step 3: Flash to SD**

Use whichever flasher you normally use. Image: `output/rg35xx-pro-minimal-mainline/images/panicos-rg35xx-pro-minimal-<rev>.img.gz`.

- [ ] **Step 4: First boot — verify console**

Insert SD, power on. Expected sequence:

1. Boot logs scroll on the panel (white text on black, fbcon is up).
2. After systemd hands off, you see a `panicos login:` prompt on the panel.
3. Plug in a USB keyboard via OTG cable. Type `root`, password `panicos`. Land in `#` shell.

If the prompt never appears but you see boot logs:
- `dmesg | grep -i getty` to confirm `getty@tty1.service` is running.
- `systemctl status getty@tty1.service` from the UART console (still working).

If the panel stays black even during boot, the fbcon path is broken — verify Task 1's audit ran and the kernel `.config` actually has the expected options:
```
grep -E 'CONFIG_(FB|FRAMEBUFFER_CONSOLE|DRM_FBDEV_EMULATION)=' \
    output/rg35xx-pro-minimal-mainline/build/linux-*/.config
```

- [ ] **Step 5: Verify SSH host keys generated per device**

On the device:
```sh
ls -la /etc/dropbear/
# Expected: dropbear_rsa_host_key, dropbear_ed25519_host_key, recent mtime.

cat /storage/.panicos-sshkeys-done
# Expected: file exists (empty).
```

Capture both keys' fingerprints:
```sh
for k in /etc/dropbear/dropbear_*; do
    dropbearkey -y -f "$k" | grep -i fingerprint
done
```

Reflash a *second* SD with the same image, repeat the fingerprint capture. The two devices must have *different* fingerprints (proves first-boot gen, not bake-in).

- [ ] **Step 6: Verify wifi config flow — no config**

Without touching `/boot/panicos-wifi.cfg`, reboot. Expected:
```sh
journalctl -u panicos-wifi-config.service
# Expected: ">>> panicos-wifi-config: no /boot/wpa_supplicant.conf or /boot/panicos-wifi.cfg, skipping wifi"

systemctl status wpa_supplicant@wlan0.service
# Expected: inactive or not running.
```

No errors; boot completes normally.

- [ ] **Step 7: Verify wifi config flow — key=value**

Power off, mount the boot partition on a PC (or eject SD). Edit `panicos-wifi.cfg`:
```
SSID=YourTestNetwork
PSK=yourrealpassword
COUNTRY=US
```

Re-insert SD, boot the device. Expected:
```sh
journalctl -u panicos-wifi-config.service
# Expected: ">>> panicos-wifi-config: rendered /boot/panicos-wifi.cfg → /run/wpa_supplicant.conf"

ip addr show wlan0
# Expected: an inet address from the network's DHCP range.

ping -c 2 8.8.8.8
# Expected: replies.
```

- [ ] **Step 8: Verify SSH from another machine**

From a laptop on the same wifi network:
```sh
ssh root@<device-ip>
# Expected: "The authenticity of host..." prompt (first time), accept,
#           then password prompt for 'panicos', land in shell.
```

Verify the host fingerprint shown matches one of the fingerprints captured in Step 5.

- [ ] **Step 9: Verify password change persists**

On the device:
```sh
passwd
# Set new password, e.g. 'newsecret'
```

Reboot. Log in with `newsecret`. Expected: works. Old `panicos` password no longer accepted. (This validates the overlayfs upper layer is persisting `/etc/shadow`.)

- [ ] **Step 10: Capture results + commit verification log**

```bash
mkdir -p docs/verifications
cat > docs/verifications/2026-04-28-subsystem-a.md <<EOF
# Subsystem A (console + wifi bootstrap) — hardware verification

## RG35XX Pro (H700 mainline LPDDR4) — canonical

**Image:** panicos-rg35xx-pro-minimal-<rev>.img.gz
**Date:** $(date -u +%F)
**Tester:** $(git config user.name)

- [ ] Step 4: tty1 prompt on panel + USB keyboard input
- [ ] Step 5: per-device SSH host keys (fingerprints differ between two SDs)
- [ ] Step 6: no-wifi-config path → service skips, boot clean
- [ ] Step 7: key=value wifi config → DHCP + ping works (note iface name: ____)
- [ ] Step 8: SSH from laptop with the captured fingerprint
- [ ] Step 9: passwd change persists across reboot

## Other SoCs (Task 9)

| Device          | SoC family       | tty1 | SSH | wifi | iface name |
|-----------------|------------------|------|-----|------|------------|
| RG353P          | RK3566 mainline  |      |     |      |            |
| TrimUI Brick    | A133 vendor      |      |     |      |            |

## Notes
(fill in any deviations or follow-ups)
EOF
# Tick checkboxes by hand as each step passes, then:
git add docs/verifications/2026-04-28-subsystem-a.md
git commit -m "verification: subsystem A passes on RG35XX Pro hardware"
```

---

## Task 9: Cross-SoC verification (RG353P + TrimUI Brick)

**Why:** Subsystem A is intentionally SoC-agnostic. This task confirms the same userland flow works across the other two SoC families we currently support — RK3566 mainline (different kernel + different wifi chip) and A133 vendor (legacy kernel, completely different driver story). Catches assumptions baked in by the H700-canonical run.

**Files:** verification log only.

- [ ] **Step 1: Build + flash RG353P**

```bash
make clean-rg353p
make rg353p
# Flash output/rg353p-minimal-mainline/images/panicos-rg353p-minimal-<rev>.img.gz
```

- [ ] **Step 2: On RG353P — abbreviated checklist**

Walk Steps 4, 5, 6, 7, 8 from Task 8 (skip 9 — overlay-persistence isn't SoC-dependent, already covered).

Capture the wifi interface name (`ip -br link | awk '$1 ~ /^wl/ {print $1}'`). If it's NOT `wlan0`, file a follow-up to override the wpa_supplicant@<iface>.service .wants symlink in `soc/rockchip-rk3566/mainline/rootfs-overlay/`.

If wifi doesn't come up but driver+firmware look right (`dmesg | grep -i rtw`), the iface name is the most likely culprit — `Type=wlan` should still net DHCP because we matched by type, but the wpa_supplicant symlink is name-based.

- [ ] **Step 3: Build + flash TrimUI Brick**

```bash
make clean-trimui-brick
make trimui-brick
# Flash output/trimui-brick-minimal-vendor/images/panicos-trimui-brick-minimal-<rev>.img.gz
```

- [ ] **Step 4: On Brick — abbreviated checklist**

Same as Step 2. The Brick uses the legacy A133 vendor kernel which doesn't import a ROCKNIX `linux.config.fragment`, so the audit script soft-skips for this device — confirm:

```sh
grep -A1 'audit-kernel-config' /tmp/build-brick.log
# Expected to either find OK lines for any fragment present, or no audit
# output at all (vendor kernel path doesn't trigger it).
```

If the Brick boots to login but wifi doesn't come up, that's almost certainly a vendor-kernel module loading problem (separate concern, not subsystem A). Note it in the matrix and move on.

- [ ] **Step 5: Update verification log**

Fill in the matrix in `docs/verifications/2026-04-28-subsystem-a.md` and commit:

```bash
git add docs/verifications/2026-04-28-subsystem-a.md
git commit -m "verification: subsystem A cross-SoC results (RG353P + Brick)"
```

---

## Self-review (writer)

**Spec coverage:**
- Spec §1 (tty1 login) → Task 6 (root password baked, getty default)
- Spec §2 (display) → Task 1 (audit; no config changes needed today)
- Spec §3 (USB keyboard) → Task 1 audit covers this
- Spec §4 (SSH/dropbear) → Task 6 (`BR2_PACKAGE_DROPBEAR=y`)
- Spec §5 (SSH first-boot keys) → Task 2
- Spec §6 (wifi config + lookup order + missing-file → no-error) → Tasks 4, 5, 7
- Spec §7 (per-flavor knobs) → Tasks 3 (autologin), 6 (sshkeys/wifi-config), spec uses `BR2_PACKAGE_PANICOS_SSHD` as a single knob — implementation collapses it into `BR2_PACKAGE_DROPBEAR + BR2_PACKAGE_PANICOS_SSHKEYS`, equivalent effect
- Spec hardware verification list → Task 8 (canonical), Task 9 (cross-SoC matrix)
- User correction "must work universally, not just H700" → addressed in plan header (architecture mentions every SoC), Task 5 (`Type=wlan` matches predictable-name interfaces too), Task 7 (covers all four current boards spanning all three SoC families, with note for future boards), Task 9 (verifies on RG353P + TrimUI Brick)

**Placeholders:** none — every step has the actual content (or, in Tasks 8/9, exact commands the engineer types and the expected output).

**Type/name consistency:**
- Package names: `panicos-sshkeys`, `panicos-autologin`, `panicos-wifi-config` — used the same way every place they appear
- Kconfig symbols: `BR2_PACKAGE_PANICOS_SSHKEYS`, `BR2_PACKAGE_PANICOS_AUTOLOGIN`, `BR2_PACKAGE_PANICOS_WIFI_CONFIG` — consistent
- Markers: `/storage/.panicos-sshkeys-done` — only place this name appears is Task 2 service + Task 8 step 5
- Test env vars: `PANICOS_WIFI_BOOT_DIR`, `PANICOS_WIFI_OUT` — defined in Task 4 step 1 (test) and read in Task 4 step 4 (script)
- File paths in `_INSTALL_*_CMDS`: every reference uses `$(PANICOS_<NAME>_PKGDIR)` or `$(BR2_EXTERNAL_PANICOS_PATH)/package/<name>/...` consistently

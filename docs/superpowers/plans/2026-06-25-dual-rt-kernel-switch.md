# Dual RT / non-RT Kernel Switch — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship two kernels in one H700 image — a default non-RT (`CONFIG_PREEMPT`/CFS) kernel and an opt-in full-`PREEMPT_RT` kernel — switchable from the launcher TOOLS menu by rewriting `extlinux.conf` on the PANICOS FAT.

**Architecture:** The base build produces the non-RT kernel (today's RT override is removed). A new `kernel-variant` Makefile target clones the base's already-patched/configured kernel tree, flips preemption + `LOCALVERSION=-rt`, rebuilds kernel-only, and folds a second `Image-rt` + `panicos-modules-rt.tar.gz` into the same FAT. `post-image.sh` emits a two-`LABEL` `extlinux.conf` (`DEFAULT PanicOS`, `TIMEOUT 0`). A `Switch-Kernel.sh` TOOL rewrites the `DEFAULT` line; the initramfs injects the RT module tree when the RT kernel boots.

**Tech Stack:** Buildroot, GNU Make, sunxi mainline Linux 7.0.2 + U-Boot 2026.01, busybox initramfs, bash.

**Project testing note:** This is a Buildroot/shell codebase with no unit-test framework. "Tests" here are (a) a real bash test for the one piece of pure logic worth isolating (the `extlinux.conf` rewrite in Task 6), and (b) concrete verification commands with expected output for config/build steps. Each task ends with a commit.

---

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `soc/allwinner-h700/mainline/linux/panicos-extras.config.fragment.in` | Drop the unconditional `CONFIG_PREEMPT_RT=y` → base build is non-RT | Modify |
| `soc/allwinner-h700/mainline/linux/panicos-rt.config.fragment` | RT delta (PREEMPT_RT + `-rt` LOCALVERSION) merged by `kernel-variant` | Create |
| `board/anbernic/rg35xx-pro/post-image.sh` | RT-aware two-LABEL extlinux + RT files in FAT + non-RT-only base module tarball | Modify |
| `board/anbernic/rg35xx-pro/genimage.cfg.in` | Add `${PANICOS_RT_FILES}` to the vfat file list | Modify |
| `Makefile` | New `kernel-variant` target | Modify |
| `panicos-initramfs/init` | Select module tarball by `-rt` suffix | Modify |
| `package/panicos-launcher-tools/files/Switch-Kernel.sh` | TOOLS switcher (rewrites `DEFAULT`, no auto-reboot) | Create |
| `package/panicos-launcher-tools/files/test-switch-kernel.sh` | Bash test for the rewrite logic | Create |
| `package/panicos-launcher-tools/panicos-launcher-tools.mk` | Install the switcher | Modify |

---

## Task 1: Make non-RT the default kernel; add the RT fragment

**Files:**
- Modify: `soc/allwinner-h700/mainline/linux/panicos-extras.config.fragment.in:28-37`
- Create: `soc/allwinner-h700/mainline/linux/panicos-rt.config.fragment`

- [ ] **Step 1: Remove the unconditional RT override from the base extras fragment**

In `soc/allwinner-h700/mainline/linux/panicos-extras.config.fragment.in`, replace the whole RT block (lines 28-37, beginning `# PREEMPT_RT: full real-time preemption.` and ending `CONFIG_PREEMPT_RT=y`) with:

```
# Preemption model: base/default kernel uses CONFIG_PREEMPT=y (low-latency
# desktop), matching ROCKNIX. The opt-in PREEMPT_RT kernel is built as a
# separate Image by `make kernel-variant ... RT=1`, which merges
# panicos-rt.config.fragment on top of this config. Do NOT set
# CONFIG_PREEMPT_RT here — that would make every build RT again.
```

The base `linux.config.fragment` already has `CONFIG_PREEMPT=y` and `# CONFIG_PREEMPT_RT is not set`, so removing the override is all that's needed for a non-RT default.

- [ ] **Step 2: Create the RT fragment**

Create `soc/allwinner-h700/mainline/linux/panicos-rt.config.fragment`:

```
# RT variant delta — merged onto the base kernel .config by
# `make kernel-variant DEVICE=... RT=1`. Produces a second kernel image
# (Image-rt) whose modules live under /lib/modules/<ver>-rt so they never
# collide with the non-RT default's /lib/modules/<ver> tree.
CONFIG_LOCALVERSION="-rt"
# CONFIG_PREEMPT is not set
# CONFIG_PREEMPT_DYNAMIC is not set
CONFIG_PREEMPT_RT=y
```

- [ ] **Step 3: Verify the base fragment no longer forces RT**

Run: `grep -n 'PREEMPT_RT' soc/allwinner-h700/mainline/linux/panicos-extras.config.fragment.in`
Expected: only the comment line mentioning it ("Do NOT set `CONFIG_PREEMPT_RT` here"), and **no** active `CONFIG_PREEMPT_RT=y`.

Run: `grep -c '^CONFIG_PREEMPT_RT=y' soc/allwinner-h700/mainline/linux/panicos-rt.config.fragment`
Expected: `1`

- [ ] **Step 4: Commit**

```bash
git add soc/allwinner-h700/mainline/linux/panicos-extras.config.fragment.in \
        soc/allwinner-h700/mainline/linux/panicos-rt.config.fragment
git commit -m "h700: make non-RT the default kernel; add opt-in RT fragment"
```

---

## Task 2: RT-aware `post-image.sh`

`post-image.sh` must (a) keep the base module tarball strictly non-RT, (b) emit a two-`LABEL` `extlinux.conf` with `DEFAULT PanicOS`/`TIMEOUT 0` when an `Image-rt` is present, and (c) expose `PANICOS_RT_FILES` to genimage. When no `Image-rt` exists (plain base build) it stays single-LABEL exactly as today.

**Files:**
- Modify: `board/anbernic/rg35xx-pro/post-image.sh:52-61` (extlinux block)
- Modify: `board/anbernic/rg35xx-pro/post-image.sh:84-85` (KVER glob)
- Modify: `board/anbernic/rg35xx-pro/post-image.sh:105-109` (export `PANICOS_RT_FILES` before envsubst)

- [ ] **Step 1: Make the base module tarball ignore any `-rt` build dir**

Replace line 84-85 (the `KVER=$(ls ...)` assignment) with:

```bash
# Base (default, non-RT) module tarball only. Exclude any linux-*-rt build
# tree so the RT kernel's modules never end up in panicos-modules.tar.gz.
KVER=$(ls "${BUILD_DIR:-$(dirname "$BINARIES_DIR")/build}/linux-"*/include/config/kernel.release 2>/dev/null \
    | grep -v -- '-rt/' \
    | sort -V | tail -1 | xargs cat 2>/dev/null || true)
```

- [ ] **Step 2: Replace the extlinux block with an RT-aware version**

Replace lines 52-61 (from the `# Use extlinux.conf` comment through the closing `EOF`) with:

```bash
# Use extlinux.conf (plain text, editable on the FAT without reflashing)
# rather than a compiled boot.scr. U-Boot's distro_bootcmd scans for
# /extlinux/extlinux.conf via CONFIG_CMD_SYSBOOT — same path ROCKNIX uses.
#
# Two kernels can coexist on the FAT: /Image (default, non-RT) and
# /Image-rt (opt-in PREEMPT_RT, dropped in by `make kernel-variant`). When
# Image-rt is present we emit a second LABEL and a DEFAULT/TIMEOUT header so
# Switch-Kernel.sh can flip the active kernel by rewriting the DEFAULT line.
APPEND_LINE="console=ttyS0,115200 console=tty1 quiet loglevel=3 panic=0 pause_on_oops=300 rtw88_core.disable_lps_deep=Y"
mkdir -p "$BINARIES_DIR/extlinux"
RT_LABEL=""
export PANICOS_RT_FILES=""
if [ -f "$BINARIES_DIR/Image-rt" ]; then
    RT_LABEL=$(printf '\nLABEL PanicOS-RT\n  LINUX /Image-rt\n  FDT /dtb.img\n  APPEND %s' "$APPEND_LINE")
    # Tab-indented to match the genimage.cfg.in files block.
    export PANICOS_RT_FILES=$(printf '\t\t\t"Image-rt",\n\t\t\t"panicos-modules-rt.tar.gz",')
fi
cat > "$BINARIES_DIR/extlinux/extlinux.conf" <<EOF
DEFAULT PanicOS
TIMEOUT 0

LABEL PanicOS
  LINUX /Image
  FDT /dtb.img
  APPEND $APPEND_LINE$RT_LABEL
EOF
```

(Note: heredoc delimiter changed from quoted `'EOF'` to unquoted `EOF` so `$APPEND_LINE`/`$RT_LABEL` expand.)

- [ ] **Step 3: Verify the script still parses and is non-RT by default**

Run: `bash -n board/anbernic/rg35xx-pro/post-image.sh && echo OK`
Expected: `OK`

Run: `grep -n 'PANICOS_RT_FILES\|Image-rt\|DEFAULT PanicOS' board/anbernic/rg35xx-pro/post-image.sh`
Expected: shows the new `DEFAULT PanicOS`, `Image-rt` guard, and two `PANICOS_RT_FILES` lines.

- [ ] **Step 4: Commit**

```bash
git add board/anbernic/rg35xx-pro/post-image.sh
git commit -m "h700 post-image: RT-aware two-LABEL extlinux + non-RT-only base modules"
```

---

## Task 3: Add `${PANICOS_RT_FILES}` to the genimage FAT list

**Files:**
- Modify: `board/anbernic/rg35xx-pro/genimage.cfg.in:15-24`

- [ ] **Step 1: Insert the RT files placeholder**

In `board/anbernic/rg35xx-pro/genimage.cfg.in`, change the `files = { … }` block so the line after `"panicos-modules.tar.gz",` adds the placeholder:

```
		files = {
			"Image",
			"dtb.img",
			"dtbs",
			"extlinux",
			"panicos-active.cfg",
			"panicos-wifi.cfg",
			"panicos-modules.tar.gz",
${PANICOS_RT_FILES}
			"${PANICOS_OUTPUT_NAME}.squashfs",
		}
```

`post-image.sh` already runs `envsubst < template > genimage.cfg`. When `PANICOS_RT_FILES` is empty (plain base build) the line collapses to whitespace, which genimage's list parser ignores. When set, it expands to the two tab-indented `"Image-rt",` / `"panicos-modules-rt.tar.gz",` entries.

- [ ] **Step 2: Verify both envsubst outcomes**

Run (empty case):
```bash
PANICOS_OUTPUT_NAME=test PANICOS_RT_FILES="" \
PANICOS_BOOT_PARTITION_SIZE_MB=6144 PANICOS_STORAGE_PARTITION_INITIAL_SIZE_MB=64 \
envsubst < board/anbernic/rg35xx-pro/genimage.cfg.in | grep -c 'Image-rt'
```
Expected: `0`

Run (RT case):
```bash
PANICOS_OUTPUT_NAME=test PANICOS_RT_FILES=$'\t\t\t"Image-rt",\n\t\t\t"panicos-modules-rt.tar.gz",' \
PANICOS_BOOT_PARTITION_SIZE_MB=6144 PANICOS_STORAGE_PARTITION_INITIAL_SIZE_MB=64 \
envsubst < board/anbernic/rg35xx-pro/genimage.cfg.in | grep -c 'Image-rt'
```
Expected: `1`

- [ ] **Step 3: Commit**

```bash
git add board/anbernic/rg35xx-pro/genimage.cfg.in
git commit -m "h700 genimage: include RT kernel + module tarball in FAT when present"
```

---

## Task 4: `kernel-variant` Makefile target

Clone the base's already-patched/configured kernel tree to a sibling dir **outside** `$OUT/build/` (so `post-image.sh`'s `linux-*` glob never sees it), merge the RT fragment, rebuild kernel + modules with the base toolchain, harvest `Image-rt` + `panicos-modules-rt.tar.gz`, then re-run `post-image.sh` to fold both into the FAT.

**Files:**
- Modify: `Makefile` — add target after `image-variant` (before the closing `endif` at line 549)

- [ ] **Step 1: Add the target**

Insert immediately before the `endif` at `Makefile:549`:

```makefile
# kernel-variant: build a SECOND kernel (PREEMPT_RT) from BASE's already-built,
# patched, configured kernel tree and fold it into BASE's image FAT — yielding
# ONE image that carries two kernels: /Image (default, non-RT) and /Image-rt
# (opt-in RT). Reuses BASE's cross-toolchain and kernel source; only the
# preemption Kconfig + LOCALVERSION differ. Kernel rebuild only (~10-20 min).
#
# The RT tree is built at $OUT/kernel-rt/ (NOT under $OUT/build/) so
# post-image.sh's linux-* module glob keeps producing a non-RT base tarball.
#
# Usage (after a base build):
#   make rg35xx-pro FLAVOR=launcher
#   make kernel-variant DEVICE=rg35xx-pro FLAVOR=launcher RT=1
.PHONY: kernel-variant
kernel-variant:
	@test -n "$(DEVICE)" || (echo "DEVICE not set" >&2; exit 1)
	@test -n "$(RT)"     || (echo "RT not set (use RT=1 for the PREEMPT_RT variant)" >&2; exit 1)
	@FL="$${FLAVOR:-minimal}"; K="$(KERNEL)"; \
	SOC="$(call _device_soc,$(DEVICE))"; \
	if [ -n "$$SOC" ] && [ -z "$$K" ]; then K="mainline"; fi; \
	OUT="$(OUTPUT_BASE)/$(DEVICE)-$$FL$${K:+-$$K}"; \
	test -d "$$OUT/images" || (echo "no base build at $$OUT — run 'make $(DEVICE) FLAVOR=$$FL' first" >&2; exit 1); \
	RT_FRAG="$(PANICOS_ROOT)/soc/$$SOC/$$K/linux/panicos-rt.config.fragment"; \
	test -f "$$RT_FRAG" || (echo "no RT fragment at $$RT_FRAG" >&2; exit 1); \
	BASE_KSRC=$$(find "$$OUT/build" -maxdepth 1 -type d -name 'linux-*' ! -name '*-rt' | head -1); \
	test -n "$$BASE_KSRC" || (echo "no kernel build dir under $$OUT/build — base build incomplete?" >&2; exit 1); \
	RT_KSRC="$$OUT/kernel-rt/$$(basename $$BASE_KSRC)"; \
	echo ">>> kernel-variant: cloning $$BASE_KSRC -> $$RT_KSRC"; \
	rm -rf "$$OUT/kernel-rt"; mkdir -p "$$OUT/kernel-rt"; \
	rsync -a --delete "$$BASE_KSRC/" "$$RT_KSRC/"; \
	export PATH="$$OUT/host/bin:$$OUT/host/sbin:$$PATH"; \
	export ARCH=arm64 CROSS_COMPILE="aarch64-buildroot-linux-gnu-"; \
	echo ">>> kernel-variant: merging RT fragment into .config"; \
	( cd "$$RT_KSRC" && ./scripts/kconfig/merge_config.sh -m .config "$$RT_FRAG" && $(MAKE) olddefconfig ); \
	REL=$$(cat "$$RT_KSRC/include/config/kernel.release"); \
	echo "$$REL" | grep -q -- '-rt$$' || (echo "RT kernel.release ($$REL) missing -rt suffix — LOCALVERSION not applied" >&2; exit 1); \
	echo ">>> kernel-variant: building RT kernel ($$REL)"; \
	$(MAKE) -C "$$RT_KSRC" -j$$(nproc) Image modules; \
	STAGING="$$OUT/kernel-rt/modstaging"; rm -rf "$$STAGING"; mkdir -p "$$STAGING/usr"; \
	$(MAKE) -C "$$RT_KSRC" INSTALL_MOD_PATH="$$STAGING/usr" DEPMOD="$$OUT/host/sbin/depmod" modules_install; \
	echo ">>> kernel-variant: harvesting Image-rt + module tarball"; \
	cp "$$RT_KSRC/arch/arm64/boot/Image" "$$OUT/images/Image-rt"; \
	tar -czf "$$OUT/images/panicos-modules-rt.tar.gz" -C "$$STAGING" "usr/lib/modules/$$REL"; \
	echo ">>> kernel-variant: re-running post-image to fold both kernels into the FAT"; \
	BOARD_DIR=$$(find $(PANICOS_ROOT)/board -mindepth 3 -maxdepth 3 -path "*/$(DEVICE)/Config.in" -printf '%h\n' 2>/dev/null | head -1); \
	test -n "$$BOARD_DIR" || (echo "no board dir for $(DEVICE)" >&2; exit 1); \
	cd $(PANICOS_ROOT) && \
	  BR2_EXTERNAL_PANICOS_PATH=$(PANICOS_ROOT) \
	  BR2_CONFIG="$$OUT/.config" \
	  BINARIES_DIR="$$OUT/images" \
	  BUILD_DIR="$$OUT/build" \
	  TARGET_DIR="$$OUT/target" \
	  HOST_DIR="$$OUT/host" \
	  "$$BOARD_DIR/post-image.sh" "$$OUT/images" "$$BOARD_DIR/genimage.cfg.in"
```

- [ ] **Step 2: Verify the target is recognized and guards work**

Run: `make kernel-variant DEVICE=rg35xx-pro FLAVOR=launcher 2>&1 | head -1`
Expected: `RT not set (use RT=1 for the PREEMPT_RT variant)` (the `RT` guard fires before any work).

Run: `make -n kernel-variant DEVICE=rg35xx-pro FLAVOR=launcher RT=1 >/dev/null 2>&1; echo $?`
Expected: `0` (parses; actual execution is exercised in Task 7).

- [ ] **Step 3: Commit**

```bash
git add Makefile
git commit -m "build: add kernel-variant target (folds a PREEMPT_RT kernel into the base FAT)"
```

---

## Task 5: initramfs picks the module tarball by kernel suffix

The launcher squashfs bakes in only the non-RT `<ver>` modules. Booting `Image-rt` (`uname -r` = `<ver>-rt`) finds no matching `/lib/modules` in the lower and must inject from `panicos-modules-rt.tar.gz`, not the non-RT `panicos-modules.tar.gz`.

**Files:**
- Modify: `panicos-initramfs/init:189`

- [ ] **Step 1: Select the tarball by `-rt` suffix**

Replace line 189 (`_modules_tar="/boot/panicos-modules.tar.gz"`) with:

```bash
# Match the running kernel: the RT kernel (uname -r ends in -rt) has its own
# module tree shipped as panicos-modules-rt.tar.gz; the non-RT default uses
# panicos-modules.tar.gz. Picking the wrong one leaves the kernel with no
# loadable modules (vermagic mismatch).
case "$_kver" in
    *-rt) _modules_tar="/boot/panicos-modules-rt.tar.gz" ;;
    *)    _modules_tar="/boot/panicos-modules.tar.gz" ;;
esac
```

- [ ] **Step 2: Verify**

Run: `grep -n 'panicos-modules-rt.tar.gz\|case "\$_kver"' panicos-initramfs/init`
Expected: shows the new `case` and the `-rt` tarball path.

Run: `bash -n panicos-initramfs/init && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add panicos-initramfs/init
git commit -m "initramfs: inject the RT module tree when the -rt kernel boots"
```

---

## Task 6: `Switch-Kernel.sh` TOOL (with a real rewrite test)

The switcher's one piece of fragile logic is rewriting the `DEFAULT` line of `extlinux.conf`. Isolate it behind env overrides (`PANICOS_EXTLINUX`, `PANICOS_NO_REMOUNT`) and a non-interactive `--set` mode so it is testable without `/boot`.

**Files:**
- Create: `package/panicos-launcher-tools/files/Switch-Kernel.sh`
- Create: `package/panicos-launcher-tools/files/test-switch-kernel.sh`

- [ ] **Step 1: Write the failing test**

Create `package/panicos-launcher-tools/files/test-switch-kernel.sh`:

```bash
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

echo "PASS"
```

- [ ] **Step 2: Run the test, watch it fail (tool doesn't exist yet)**

Run: `bash package/panicos-launcher-tools/files/test-switch-kernel.sh; echo "exit=$?"`
Expected: fails (e.g. `Switch-Kernel.sh: No such file or directory`), non-zero exit.

- [ ] **Step 3: Write `Switch-Kernel.sh`**

Create `package/panicos-launcher-tools/files/Switch-Kernel.sh`:

```bash
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

# Rewrite the single DEFAULT line to point at $1. Atomic via temp + mv.
set_default() {
    local target="$1" tmp="${EXTLINUX}.panicos-tmp"
    sed "s|^DEFAULT .*|DEFAULT ${target}|" "$EXTLINUX" > "$tmp" || return 1
    boot_rw
    mv "$tmp" "$EXTLINUX"
    boot_ro
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
```

- [ ] **Step 4: Run the test, watch it pass**

Run: `bash package/panicos-launcher-tools/files/test-switch-kernel.sh`
Expected: `PASS`

- [ ] **Step 5: Commit**

```bash
chmod +x package/panicos-launcher-tools/files/Switch-Kernel.sh
git add package/panicos-launcher-tools/files/Switch-Kernel.sh \
        package/panicos-launcher-tools/files/test-switch-kernel.sh
git commit -m "launcher-tools: add Switch-Kernel.sh (RT<->non-RT via extlinux DEFAULT)"
```

---

## Task 7: Install the switcher; build & integration

**Files:**
- Modify: `package/panicos-launcher-tools/panicos-launcher-tools.mk:42-43`

- [ ] **Step 1: Add the install line**

In `package/panicos-launcher-tools/panicos-launcher-tools.mk`, immediately after the `PanicOS-SquashFS-Install.sh` install (line 43), add:

```makefile
	# Switch-Kernel.sh — flip non-RT default <-> PREEMPT_RT by rewriting the
	# extlinux DEFAULT label on the PANICOS FAT (no auto-reboot).
	$(INSTALL) -m 0755 $(PANICOS_LAUNCHER_TOOLS_PKGDIR)/files/Switch-Kernel.sh \
		$(TARGET_DIR)/usr/share/panicos-launcher/tools/Switch-Kernel.sh
```

(The `test-switch-kernel.sh` file is intentionally **not** installed — it is a build-host test only.)

- [ ] **Step 2: Build base (non-RT), then the RT variant, then the lpddr3 variant**

Run:
```bash
make rg35xx-pro FLAVOR=launcher
make kernel-variant DEVICE=rg35xx-pro FLAVOR=launcher RT=1
make image-variant DEVICE=rg35xx-pro-lpddr3 BASE=rg35xx-pro FLAVOR=launcher
```
Expected: all three succeed. `kernel-variant` prints `building RT kernel (<ver>-rt)` and `folding both kernels into the FAT`.

(If only the `.mk`/tool changed later, the fast path is
`make pkg-rebuild PACKAGE=panicos-launcher-tools DEVICE=rg35xx-pro FLAVOR=launcher`
then `make image-rebuild DEVICE=rg35xx-pro FLAVOR=launcher` — and **always** re-run the `image-variant` lpddr3 step afterward.)

- [ ] **Step 3: Verify the FAT carries both kernels and a two-LABEL extlinux**

Run:
```bash
ls -la output/rg35xx-pro-launcher-mainline/images/Image \
       output/rg35xx-pro-launcher-mainline/images/Image-rt \
       output/rg35xx-pro-launcher-mainline/images/panicos-modules.tar.gz \
       output/rg35xx-pro-launcher-mainline/images/panicos-modules-rt.tar.gz
cat output/rg35xx-pro-launcher-mainline/images/extlinux/extlinux.conf
```
Expected: all four files exist; extlinux.conf has `DEFAULT PanicOS`, `TIMEOUT 0`, and **two** `LABEL`s (`PanicOS`, `PanicOS-RT`).

Run (confirm the RT tarball really holds `-rt` modules and the base one does not):
```bash
tar tzf output/rg35xx-pro-launcher-mainline/images/panicos-modules-rt.tar.gz | head -1
tar tzf output/rg35xx-pro-launcher-mainline/images/panicos-modules.tar.gz   | grep -m1 'lib/modules'
```
Expected: first path contains `-rt`; second does **not**.

- [ ] **Step 4: Commit**

```bash
git add package/panicos-launcher-tools/panicos-launcher-tools.mk
git commit -m "launcher-tools: install Switch-Kernel.sh into the Tools menu"
```

---

## Task 8: On-device verification (real hardware)

> Device SSH: `sshpass -p panicos ssh root@192.168.1.181` (per project memory).

- [ ] **Step 1: Flash and boot the default kernel**

Flash the gzipped image, boot, then:
Run: `sshpass -p panicos ssh root@192.168.1.181 'uname -r; uname -v | grep -o PREEMPT_RT || echo NON-RT'`
Expected: `uname -r` has **no** `-rt`; second line `NON-RT`.

- [ ] **Step 2: Switch to RT via the Tools script logic, reboot, verify**

Run:
```bash
sshpass -p panicos ssh root@192.168.1.181 \
  'PANICOS_EXTLINUX=/boot/extlinux/extlinux.conf /usr/share/panicos-launcher/tools/Switch-Kernel.sh --set rt; grep ^DEFAULT /boot/extlinux/extlinux.conf'
```
Expected: `DEFAULT PanicOS-RT`. Then reboot the device and:
Run: `sshpass -p panicos ssh root@192.168.1.181 'uname -r; uname -v | grep -o PREEMPT_RT'`
Expected: `uname -r` ends in `-rt`; `PREEMPT_RT` printed.

- [ ] **Step 3: Confirm RT modules loaded (no vermagic errors) and hardware works**

Run:
```bash
sshpass -p panicos ssh root@192.168.1.181 \
  'ls -d /usr/lib/modules/$(uname -r); dmesg | grep -i "version magic" | head; lsmod | grep -E "rocknix|rtw" | head'
```
Expected: a `/usr/lib/modules/<ver>-rt` dir exists; **no** "version magic" mismatch errors; joypad/wifi modules listed. Spot-check controller, WiFi, and audio in the launcher under RT.

- [ ] **Step 4: Switch back, reboot, confirm non-RT returns**

Run: `… Switch-Kernel.sh --set nonrt` then reboot; `uname -r` has no `-rt`.

(No commit — verification only. If a defect surfaces, fix in the relevant task above and re-verify.)

---

## Task 9: Documentation & memory (post-implementation, user-requested)

- [ ] **Step 1: Document the feature in the repo**

Add a short "Dual kernel (RT / non-RT)" section to `README.md` (or the build docs) covering: non-RT is the default; `make kernel-variant … RT=1` produces the second kernel; the Tools → `Switch-Kernel.sh` flow; that switching needs a manual reboot. Commit:

```bash
git add README.md
git commit -m "docs: dual RT/non-RT kernel layout and Switch-Kernel tool"
```

- [ ] **Step 2: Update auto-memory** (`/home/user1/.claude/projects/-home-user1-PanicOS/memory/`)

- Create `project_h700_dual_kernel_rt_switch.md` (type: project): one image now ships two kernels — `/Image` (non-RT/`CONFIG_PREEMPT`, default, `uname -r` = `<ver>`) and `/Image-rt` (`PREEMPT_RT`, `<ver>-rt`); built via `make kernel-variant DEVICE=… RT=1` after the base build; switched by `Switch-Kernel.sh` rewriting the `extlinux.conf` `DEFAULT` label; initramfs injects `panicos-modules-rt.tar.gz` for the `-rt` kernel. Link `[[feedback_lpddr3_image_variant]]` (lpddr3 inherits both kernels via image-variant) and `[[project_h700_one_image_all_dtbs]]`.
- **Correct the superseded assumption:** the old understanding "every mainline build is PREEMPT_RT" is no longer true. Add a one-line note (in the new memory) that the H700 default scheduler is now non-RT/CFS with RT opt-in, and reference it so future sessions don't reintroduce the unconditional RT override.
- Add the `- [Title](file.md) — hook` pointer line to `MEMORY.md`.

---

## Self-Review

**Spec coverage** (against `2026-06-25-dual-rt-kernel-switch-design.md`):
- §2 kernel config split → Task 1 ✓
- §3 `kernel-variant` build mechanism → Task 4 ✓
- §4 two-LABEL extlinux + genimage FAT → Tasks 2, 3 ✓
- §4 initramfs extracts the matching module tree → Task 5 (improved over the spec's "extract both": select by `-rt` suffix — cleaner, avoids the launcher squashfs already owning the non-RT tree) ✓
- §5 `Switch-Kernel.sh` + `.mk` install → Tasks 6, 7 ✓
- § Build/iteration workflow (base → kernel-variant → image-variant lpddr3) → Task 7 ✓
- § Testing/verification (FAT contents, boot both, modules, lpddr3, idempotency) → Tasks 7, 8 ✓
- § Post-implementation docs + memory → Task 9 ✓

**Deviation from spec (intentional):** the spec §4 said the initramfs should "extract both module tarballs." During implementation research the init turned out to gate injection on `uname -r` and the launcher squashfs already bakes in the non-RT tree, so selecting the single matching tarball by suffix is simpler and correct. Noted in Task 5.

**Placeholder scan:** no TBD/TODO; every code step has complete content.

**Type/name consistency:** `PANICOS_RT_FILES` (Tasks 2↔3), `Image-rt` / `panicos-modules-rt.tar.gz` (Tasks 2,3,4,5,7), `DEFAULT PanicOS`/`PanicOS-RT` labels and `set_default`/`current_default`/`has_label` (Tasks 2,6), `kernel-variant` + `RT=1` (Tasks 4,7) — all consistent.

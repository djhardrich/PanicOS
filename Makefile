# PanicOS top-level wrapper.
# Run on host: re-execs into the Docker build container.
# Run inside container (IN_CONTAINER=1): dispatches to Buildroot.

SHELL := /bin/bash
PANICOS_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
DOCKER_IMAGE := panicos-build
DOCKER_TAG := $(shell sha1sum docker/Dockerfile 2>/dev/null | cut -c1-12)
ifeq ($(DOCKER_TAG),)
DOCKER_TAG := dev
endif

# Pass -t to docker only when stdout is a TTY (interactive shell).
# Without this, non-interactive invocations (CI, background, piped) fail with
# "cannot attach stdin to a TTY-enabled container".
DOCKER_TTY := $(shell test -t 1 && echo -t)

# Run docker as the host user so Buildroot doesn't refuse (it bails on root).
DOCKER_USER := $(shell id -u):$(shell id -g)

# ---- Container re-exec ----------------------------------------------------
ifeq ($(IN_CONTAINER),)

.DEFAULT_GOAL := help

# Build container image on demand.
.PHONY: container-image
container-image:
	@docker image inspect $(DOCKER_IMAGE):$(DOCKER_TAG) >/dev/null 2>&1 || \
		docker build -t $(DOCKER_IMAGE):$(DOCKER_TAG) -f docker/Dockerfile .

# Prevent Make from trying to remake itself via the pattern rule below.
Makefile: ;

# Re-exec any other goal inside the container.
# $(MAKEOVERRIDES) propagates user-supplied command-line var assignments
# (e.g. KERNEL=vendor, FLAVOR=desktop) into the container's make.
%: container-image
	@docker run --rm -i $(DOCKER_TTY) \
		--user $(DOCKER_USER) \
		-v $(PANICOS_ROOT):/work \
		-w /work \
		-e IN_CONTAINER=1 \
		-e HOME=/tmp \
		$(DOCKER_IMAGE):$(DOCKER_TAG) \
		make $@ $(MAKEOVERRIDES)

.PHONY: tui
tui: container-image
	@docker run --rm -i $(DOCKER_TTY) \
		--user $(DOCKER_USER) \
		-v $(PANICOS_ROOT):/work \
		-w /work \
		-e IN_CONTAINER=1 \
		-e HOME=/tmp \
		$(DOCKER_IMAGE):$(DOCKER_TAG) \
		bash scripts/panicos-tui.sh

.PHONY: shell
shell: container-image
	@docker run --rm -i $(DOCKER_TTY) \
		--user $(DOCKER_USER) \
		-v $(PANICOS_ROOT):/work \
		-w /work \
		-e IN_CONTAINER=1 \
		-e HOME=/tmp \
		$(DOCKER_IMAGE):$(DOCKER_TAG) \
		bash

.PHONY: vbe
# `--privileged` is required for kpartx/losetup inside the container.
# Mounting loop devices needs elevated kernel capabilities; vbe runs as the
# host user for everything else (output/vbe/ is owned by the host user).
vbe: container-image
	@docker run --rm -i $(DOCKER_TTY) \
		--user $(DOCKER_USER) \
		-v $(PANICOS_ROOT):/work \
		-w /work \
		-e IN_CONTAINER=1 \
		-e HOME=/tmp \
		--privileged \
		$(DOCKER_IMAGE):$(DOCKER_TAG) \
		bash scripts/vbe.sh $(filter-out $@,$(MAKECMDGOALS))

.PHONY: help
help:
	@echo "PanicOS build (host wrapper)"
	@echo
	@echo "  make list-devices            List supported devices"
	@echo "  make harness-smoke           Build the smoke-test rootfs"
	@echo "  make <device>                Build a device image (later plans)"
	@echo "  make tui                     Interactive build wizard"
	@echo "  make shell                   Interactive shell in the build container"
	@echo "  make vbe                     Vendor Blob Extractor (run make shell first for args)"
	@echo "  make clean-<device>          Clean a device's output dir"
	@echo
	@echo "Iteration helpers (avoid full clean rebuilds):"
	@echo "  make pkg-rebuild PACKAGE=<pkg> DEVICE=<dev> [FLAVOR=<fl>]"
	@echo "                               Rebuild ONE buildroot package + image"
	@echo "                               (e.g. PACKAGE=panicos-pht, PACKAGE=linux, PACKAGE=mesa3d)"
	@echo "  make pkgs-rebuild PACKAGES='a b c' DEVICE=<dev> [FLAVOR=<fl>]"
	@echo "                               Rebuild multiple packages; re-runs defconfig"
	@echo "                               so newly-added packages land in .config first"
	@echo "  make image-rebuild DEVICE=<dev> [FLAVOR=<fl>]"
	@echo "                               Rebuild squashfs + flashable image only"
	@echo
	@echo "Set IN_CONTAINER=1 to skip the Docker re-exec."

else
# ---- Inside container -----------------------------------------------------

BUILDROOT := $(PANICOS_ROOT)/third_party/buildroot
OUTPUT_BASE := $(PANICOS_ROOT)/output

.PHONY: list-devices
list-devices:
	@find board -mindepth 3 -maxdepth 3 -name Config.in \
		-printf '%h\n' | sed 's|^board/||' | sort

# Resolve <device> -> <soc> by reading board/*/<device>/Config.in.
define _device_soc
$(shell awk '/select PANICOS_SOC_/ { sub(/^[[:space:]]+/,""); sub(/select PANICOS_SOC_/,""); gsub(/_/,"-"); print tolower($$0); exit }' \
    $(shell find board -mindepth 3 -maxdepth 3 -path "*/$(1)/Config.in" 2>/dev/null | head -1) 2>/dev/null)
endef

FLAVOR ?= minimal
KERNEL ?=

.PHONY: harness-smoke
harness-smoke:
	$(MAKE) _build DEVICE=harness-smoke FLAVOR=$(FLAVOR) KERNEL=$(KERNEL)

.PHONY: rg35xx-pro
rg35xx-pro:
	$(MAKE) _build DEVICE=rg35xx-pro FLAVOR=$(FLAVOR) KERNEL=$(KERNEL)

.PHONY: rg35xx-pro-lpddr3
rg35xx-pro-lpddr3:
	$(MAKE) _build DEVICE=rg35xx-pro-lpddr3 FLAVOR=$(FLAVOR) KERNEL=$(KERNEL)

.PHONY: rg353p
rg353p:
	$(MAKE) _build DEVICE=rg353p FLAVOR=$(FLAVOR) KERNEL=$(KERNEL)

.PHONY: trimui-brick
trimui-brick:
	$(MAKE) _build DEVICE=trimui-brick FLAVOR=$(FLAVOR) KERNEL=vendor

.PHONY: _build
_build:
	@test -n "$(DEVICE)" || (echo "DEVICE not set" >&2; exit 1)
	@# Relax Buildroot's apply-patches.sh from fuzz=0 to fuzz=2. Handheld-distro
	@# kernel patches drift against upstream kernel point releases; strict fuzz=0
	@# rejects them on cosmetic context shifts. Idempotent — sed is a no-op once
	@# applied.
	@sed -i 's/patch -F0 /patch -F2 /' "$(BUILDROOT)/support/scripts/apply-patches.sh"
	@# Flip Buildroot's SDL2 from --disable-video-wayland to --enable-video-wayland.
	@# Stock buildroot hard-disables Wayland regardless of BR2_PACKAGE_WAYLAND
	@# being on; flavors that boot under sway (launcher, future kiosk variants)
	@# need ES to come up as a Wayland client. Idempotent.
	@sed -i 's/--disable-video-wayland/--enable-video-wayland/' "$(BUILDROOT)/package/sdl2/sdl2.mk"
	@# Flip --disable-video-vulkan → --enable-video-vulkan, same rationale.
	@# SDL2 picks up Vulkan automatically when vulkan-headers are present at
	@# build time; the loader (libvulkan.so.1) is dlopen'd at runtime by any
	@# port that asks for Vulkan rendering. Without the configure flip, SDL2
	@# refuses to even probe for Vulkan and apps fall back to GLES.
	@sed -i 's/--disable-video-vulkan/--enable-video-vulkan/' "$(BUILDROOT)/package/sdl2/sdl2.mk"
	@# Pull SDL2's vulkan-headers dep through buildroot's dependency graph
	@# so vulkan-headers is built/staged before SDL2 configures. Without
	@# this, SDL2's autoconf check for Vulkan fails (headers missing) and
	@# Vulkan support is silently dropped even with --enable-video-vulkan.
	@grep -q '^SDL2_DEPENDENCIES += vulkan-headers' "$(BUILDROOT)/package/sdl2/sdl2.mk" || \
		sed -i '/^\$$(eval \$$(autotools-package))/i SDL2_DEPENDENCIES += vulkan-headers' "$(BUILDROOT)/package/sdl2/sdl2.mk"
	@# libsamplerate dep — SDL2's autoconf probes for it via pkg-config and
	@# enables `--enable-libsamplerate` by default; we just need the lib
	@# present at SDL2 build time. Without this dep ordering, libsamplerate
	@# may not be staged when SDL2 configures and the resampler silently
	@# falls back to SDL2's built-in lower-quality version.
	@grep -q '^SDL2_DEPENDENCIES += libsamplerate' "$(BUILDROOT)/package/sdl2/sdl2.mk" || \
		sed -i '/^\$$(eval \$$(autotools-package))/i SDL2_DEPENDENCIES += libsamplerate' "$(BUILDROOT)/package/sdl2/sdl2.mk"
	@# SDL2's autoconf detects WAYLAND_SCANNER via pkg-config, but ends up
	@# baking in the build-host's /usr/bin/wayland-scanner path (which
	@# doesn't exist on most build hosts). Force it to use the host-wayland
	@# tool buildroot itself builds. Also explicitly depend on host-wayland
	@# so it's present before SDL2 configures. Both inserted just before
	@# the autotools-package eval so they take effect; idempotent guards.
	@grep -q '^SDL2_DEPENDENCIES += host-wayland' "$(BUILDROOT)/package/sdl2/sdl2.mk" || \
		sed -i '/^\$$(eval \$$(autotools-package))/i SDL2_DEPENDENCIES += host-wayland' "$(BUILDROOT)/package/sdl2/sdl2.mk"
	@grep -q '^SDL2_CONF_ENV += WAYLAND_SCANNER=' "$(BUILDROOT)/package/sdl2/sdl2.mk" || \
		sed -i '/^\$$(eval \$$(autotools-package))/i SDL2_CONF_ENV += WAYLAND_SCANNER=$$(HOST_DIR)/bin/wayland-scanner' "$(BUILDROOT)/package/sdl2/sdl2.mk"
	@# SDL2's autoconf takes WAYLAND_SCANNER unconditionally from
	@# `pkg-config --variable=wayland_scanner wayland-scanner`. Buildroot's
	@# sysroot wayland-scanner.pc has bindir=/usr/bin (target-side path),
	@# so SDL2's generated Makefile bakes in /usr/bin/wayland-scanner —
	@# which doesn't exist on the build host, so the SDL2 build fails at
	@# the protocol-header gen step. Post-configure hook rewrites the
	@# Makefile to point at the host's wayland-scanner.
	@grep -q 'SDL2_FIX_WAYLAND_SCANNER_PATH' "$(BUILDROOT)/package/sdl2/sdl2.mk" || \
		sed -i '/^\$$(eval \$$(autotools-package))/i define SDL2_FIX_WAYLAND_SCANNER_PATH\n\tsed -i "s|^WAYLAND_SCANNER = .*|WAYLAND_SCANNER = $$(HOST_DIR)/bin/wayland-scanner|" $$(@D)/Makefile\nendef\nSDL2_POST_CONFIGURE_HOOKS += SDL2_FIX_WAYLAND_SCANNER_PATH\n' "$(BUILDROOT)/package/sdl2/sdl2.mk"
	@# Buildroot 2026.02.1 ships xz 5.8.3 with four backport patches
	@# (mt-dec comment fix + 3 CVE backports) that are already in 5.8.3
	@# upstream. patch -F2 still fails because the upstream code has
	@# moved on past where the patches were context-anchored. Skip all
	@# four — buildroot only applies *.patch (not *.patch.skip).
	@# Idempotent.
	@# Buildroot 2026.02.1 ships several CVE / bugfix backport patches
	@# that are already in the version-bumped upstream tarballs. patch(1)
	@# detects this with "Reversed (or previously applied) patch detected!"
	@# and exits non-zero — buildroot's apply-patches.sh treats that as
	@# fatal. Pre-skipping each by hand was whack-a-mole (xz had 4,
	@# fakeroot 1, alsa-lib 1, ncurses 1, ...).
	@#
	@# Instead, patch apply-patches.sh once to tolerate that specific
	@# exit. Real patch failures (hunk offset too large, malformed patch,
	@# etc.) still exit 1. Idempotent — the python script no-ops if the
	@# lenience block is already present.
	@$(PANICOS_ROOT)/scripts/buildroot-apply-patches-lenient.py \
		"$(BUILDROOT)/support/scripts/apply-patches.sh"
	@# Patch pyinstaller.py to retry on FileExistsError from orphaned host
	@# scripts left by previously-interrupted installs. Idempotent.
	@$(PANICOS_ROOT)/scripts/buildroot-pyinstaller-fix-overwrite.py \
		"$(BUILDROOT)/support/scripts/pyinstaller.py"
	@# host-python-packaging uses a flit-bootstrap setup type that invokes
	@# pyinstaller.py, which does "from installer import install".  With
	@# buildroot master the host-python-installer dep is missing from
	@# python-packaging.mk, so a clean build hits ModuleNotFoundError when
	@# packaging is the first wheel to install.  Idempotent.
	@grep -q 'HOST_PYTHON_PACKAGING_DEPENDENCIES' \
		"$(BUILDROOT)/package/python-packaging/python-packaging.mk" || \
		sed -i '/^\$$(eval \$$(host-python-package))/i HOST_PYTHON_PACKAGING_DEPENDENCIES = host-python-installer\n' \
		"$(BUILDROOT)/package/python-packaging/python-packaging.mk"
	@# wlroots 0.20.0 in buildroot master is incompatible with sway 1.11 which
	@# requires wlroots >=0.19.0,<0.20.0. Pin to 0.19.3. Idempotent.
	@grep -q 'WLROOTS_VERSION = 0.19' \
		"$(BUILDROOT)/package/wlroots/wlroots.mk" || \
		sed -i 's/WLROOTS_VERSION = 0.20.0/WLROOTS_VERSION = 0.19.3/' \
		"$(BUILDROOT)/package/wlroots/wlroots.mk"
	@grep -q 'wlroots-0.19.3.tar.gz' \
		"$(BUILDROOT)/package/wlroots/wlroots.hash" || \
		sed -i 's/sha256  33f52414e1b280839aeb70786f0ae2c9f54e27ad4873108d86270a2f89c4934b  wlroots-0.20.0.tar.gz/sha256  5d02693175e5afd9af5f10e3e4976d6e9249dc39a90eb17d23fa5f54b125ccc5  wlroots-0.19.3.tar.gz/' \
		"$(BUILDROOT)/package/wlroots/wlroots.hash"
	@# A few buildroot 2026.02.1 patches are HARD failures (not "Reversed")
	@# because the upstream tarball drifted too much for fuzz=2. The
	@# lenience above can't help — we just rename them out of the patches
	@# dir. Each entry needs a comment explaining what we're skipping +
	@# what the consequence is.
	@for p in \
	  $(BUILDROOT)/package/ncurses/0001-fix-XOPEN_SOURCE-detection.patch ; \
	do \
	  [ -f "$$p" ] && mv "$$p" "$$p.skip"; \
	done; true
	@# Rationale per skipped patch:
	@# * ncurses 0001-fix-XOPEN_SOURCE-detection — patches the autotools-
	@#   generated `configure` script at line 10411; recent ncurses snapshots
	@#   have a substantially different configure (autoconf bumped). The
	@#   underlying issue (host XOPEN_SOURCE detection) doesn't bite us
	@#   on a 2025-vintage Ubuntu/Debian build host.
	@# Buildroot host-python3.14 is built without the _ssl extension (Python
	@# 3.14's OpenSSL detection regressed vs the host's libssl-dev). Samba4's
	@# waf does `import ssl` at configure time and hard-fails without it.
	@# Use the system Python3 from the Debian Bookworm base image (3.11,
	@# has _ssl) for samba4 only. Idempotent.
	@grep -q 'samba4_syspython_applied' "$(BUILDROOT)/package/samba4/samba4.mk" || \
		sed -i \
		's|SAMBA4_PYTHON = PYTHON="$$(HOST_DIR)/bin/python3"|SAMBA4_PYTHON = PYTHON="/usr/bin/python3" # samba4_syspython_applied|' \
		"$(BUILDROOT)/package/samba4/samba4.mk"
	@# Audit kernel config: fail fast if required CONFIG_ symbols have dropped out.
	@SOC="$(call _device_soc,$(DEVICE))"; \
	K="$(KERNEL)"; \
	if [ -n "$$SOC" ] && [ -z "$$K" ]; then K="mainline"; fi; \
	if [ -n "$$SOC" ]; then \
		FRAGMENT="$(PANICOS_ROOT)/soc/$$SOC/$$K/linux/linux.config.fragment"; \
		$(PANICOS_ROOT)/scripts/audit-kernel-config.sh "$$FRAGMENT"; \
	fi
	@SOC="$(call _device_soc,$(DEVICE))"; \
	K="$(KERNEL)"; \
	if [ -n "$$SOC" ] && [ -z "$$K" ]; then K="mainline"; fi; \
	OUT="$(OUTPUT_BASE)/$(DEVICE)-$(FLAVOR)$${K:+-$$K}"; \
	mkdir -p "$$OUT"; \
	if [ -n "$$SOC" ]; then \
		echo ">>> Building initramfs"; \
		FW_DIR="$(PANICOS_ROOT)/soc/$$SOC/$$K/rootfs-overlay/usr/lib/firmware"; \
		HOST_DIR="$$OUT/host"; \
		KMODS=""; \
		for ko in "$$OUT/target/usr/lib/modules/"*"/updates/rocknix-joypad.ko" \
		          "$$OUT/target/usr/lib/modules/"*"/updates/rocknix-singleadc-joypad.ko"; do \
			[ -f "$$ko" ] && KMODS="$${KMODS:+$$KMODS:}$$ko"; \
		done; \
		PANICOS_INITRAMFS_FIRMWARE_DIRS="$$([ -d "$$FW_DIR" ] && echo "$$FW_DIR")" \
		PANICOS_INITRAMFS_HOST_DIR="$$([ -d "$$HOST_DIR" ] && echo "$$HOST_DIR")" \
		PANICOS_INITRAMFS_KMOD_PATHS="$$KMODS" \
			$(PANICOS_ROOT)/scripts/build-initramfs.sh; \
		EXTRAS_IN="$(PANICOS_ROOT)/soc/$$SOC/$$K/linux/panicos-extras.config.fragment.in"; \
		EXTRAS_OUT="$$OUT/panicos-extras.config.fragment"; \
		if [ -f "$$EXTRAS_IN" ]; then \
			sed "s|@PANICOS_INITRAMFS_PATH@|$(PANICOS_ROOT)/output/panicos-initramfs.cpio.gz|" \
				"$$EXTRAS_IN" > "$$EXTRAS_OUT"; \
		fi; \
		if [ "$$K" = "vendor" ]; then \
			BASE="$(PANICOS_ROOT)/soc/$$SOC/vendor/linux/linux.config.fragment"; \
			if [ -f "$$BASE" ]; then \
				{ cat "$$BASE"; [ -f "$$EXTRAS_OUT" ] && cat "$$EXTRAS_OUT" || true; } > "$$OUT/vendor-linux.config"; \
			fi; \
		fi; \
	fi; \
	scripts/gen-defconfig.sh \
		--device "$(DEVICE)" \
		--flavor "$(FLAVOR)" \
		$${SOC:+--soc "$$SOC"} \
		$${K:+--kernel "$$K"} \
		--output "$$OUT/.defconfig"; \
	$(MAKE) -C "$(BUILDROOT)" \
		BR2_EXTERNAL=$(PANICOS_ROOT) \
		O="$$OUT" \
		defconfig BR2_DEFCONFIG="$$OUT/.defconfig"; \
	$(MAKE) -C "$(BUILDROOT)" \
		BR2_EXTERNAL=$(PANICOS_ROOT) \
		O="$$OUT"

.PHONY: clean-%
clean-%:
	rm -rf $(OUTPUT_BASE)/$*-*

# ---- Iteration helpers ----------------------------------------------------
# Buildroot's local-package infrastructure (SITE_METHOD=local) doesn't track
# source-file mtimes — editing a file under package/<pkg>/ won't trigger a
# rebuild. These targets clear stamps surgically so changes propagate without
# a full clean. Use:
#
#   make pkg-rebuild PACKAGE=panicos-pht DEVICE=rg35xx-pro FLAVOR=pht
#   make pkg-rebuild PACKAGE=linux DEVICE=rg35xx-pro   # rebuild kernel only
#   make image-rebuild DEVICE=rg35xx-pro FLAVOR=pht    # squashfs + image only
#
#   make pkgs-rebuild PACKAGES="a b c" DEVICE=rg35xx-pro FLAVOR=pht
#                              Rebuild multiple packages + re-run defconfig
#                              (needed when adding new packages to defconfig)
#                              then a single image rebuild.
#
# DEVICE is required; FLAVOR defaults to minimal; KERNEL defaults to mainline.

# Resolve OUT dir from DEVICE/FLAVOR/KERNEL.
define _outdir
$(OUTPUT_BASE)/$(DEVICE)-$(FLAVOR)$(if $(KERNEL),-$(KERNEL),-mainline)
endef

# initramfs-rebuild: regenerate output/panicos-initramfs.cpio.gz for DEVICE.
# Called automatically by pkg-rebuild PACKAGE=linux; also useful standalone
# when only panicos-initramfs/init or panicos-initramfs/skeleton changes.
.PHONY: initramfs-rebuild
initramfs-rebuild:
	@test -n "$(DEVICE)" || (echo "DEVICE not set" >&2; exit 1)
	@SOC="$(call _device_soc,$(DEVICE))"; \
	K="$(KERNEL)"; \
	if [ -n "$$SOC" ] && [ -z "$$K" ]; then K="mainline"; fi; \
	[ -n "$$SOC" ] || { echo "initramfs-rebuild: no SOC for $(DEVICE)" >&2; exit 1; }; \
	OUT="$(_outdir)"; \
	FW_DIR="$(PANICOS_ROOT)/soc/$$SOC/$$K/rootfs-overlay/usr/lib/firmware"; \
	HOST_DIR="$$OUT/host"; \
	KMODS=""; \
	_KVER=$$(find "$$OUT/target/usr/lib/modules/" \
	              -maxdepth 1 -mindepth 1 -type d 2>/dev/null \
	         | xargs -r -I{} basename {} | sort -V | tail -1); \
	for ko in "$$OUT/target/usr/lib/modules/$${_KVER}/updates/rocknix-joypad.ko" \
	          "$$OUT/target/usr/lib/modules/$${_KVER}/updates/rocknix-singleadc-joypad.ko"; do \
		[ -f "$$ko" ] && KMODS="$${KMODS:+$$KMODS:}$$ko"; \
	done; \
	PANICOS_INITRAMFS_FIRMWARE_DIRS="$$([ -d "$$FW_DIR" ] && echo "$$FW_DIR")" \
	PANICOS_INITRAMFS_HOST_DIR="$$([ -d "$$HOST_DIR" ] && echo "$$HOST_DIR")" \
	PANICOS_INITRAMFS_KMOD_PATHS="$$KMODS" \
		$(PANICOS_ROOT)/scripts/build-initramfs.sh

.PHONY: pkg-rebuild
pkg-rebuild:
	@test -n "$(PACKAGE)" || (echo "PACKAGE not set" >&2; exit 1)
	@test -n "$(DEVICE)"  || (echo "DEVICE not set"  >&2; exit 1)
	@[ "$(PACKAGE)" != "linux" ] || \
		$(MAKE) initramfs-rebuild DEVICE=$(DEVICE) FLAVOR=$(FLAVOR) $(if $(KERNEL),KERNEL=$(KERNEL))
	@OUT="$(_outdir)"; \
	_PKG="$(PACKAGE)"; \
	test -d "$$OUT" || (echo "no build dir at $$OUT — run a full make first" >&2; exit 1); \
	echo ">>> pkg-rebuild: $$_PKG-rebuild in $$OUT"; \
	$(MAKE) -C "$(BUILDROOT)" BR2_EXTERNAL=$(PANICOS_ROOT) O="$$OUT" $$_PKG-rebuild; \
	rm -rf "$$OUT/build/buildroot-fs/full/.stamp_"* \
	       "$$OUT/build/buildroot-fs/squashfs/.stamp_"*; \
	$(MAKE) -C "$(BUILDROOT)" BR2_EXTERNAL=$(PANICOS_ROOT) O="$$OUT"

# pkgs-rebuild: like pkg-rebuild but for a space-separated list of packages,
# plus a defconfig re-run so newly-added packages land in .config.
# All stamp clearing happens before the single final make, so the image is
# only assembled once.
.PHONY: pkgs-rebuild
pkgs-rebuild:
	@test -n "$(PACKAGES)" || (echo "PACKAGES not set" >&2; exit 1)
	@test -n "$(DEVICE)"   || (echo "DEVICE not set"   >&2; exit 1)
	@OUT="$(_outdir)"; \
	SOC="$(call _device_soc,$(DEVICE))"; \
	K="$(KERNEL)"; \
	test -d "$$OUT" || (echo "no build dir at $$OUT — run a full make first" >&2; exit 1); \
	if [ -n "$$SOC" ] && [ -z "$$K" ]; then K="mainline"; fi; \
	echo ">>> pkgs-rebuild: regenerating defconfig in $$OUT"; \
	scripts/gen-defconfig.sh \
		--device "$(DEVICE)" \
		--flavor "$(FLAVOR)" \
		$${SOC:+--soc "$$SOC"} \
		$${K:+--kernel "$$K"} \
		--output "$$OUT/.defconfig"; \
	$(MAKE) -C "$(BUILDROOT)" BR2_EXTERNAL=$(PANICOS_ROOT) O="$$OUT" \
		defconfig BR2_DEFCONFIG="$$OUT/.defconfig"; \
	for _pkg in $(PACKAGES); do \
		echo ">>> pkgs-rebuild: clearing stamps for $$_pkg"; \
		find "$$OUT/build" -maxdepth 1 -type d -name "$$_pkg-*" \
			-exec sh -c 'rm -rf "$$1"/.stamp_*' _ {} \;; \
	done; \
	rm -rf "$$OUT/build/buildroot-fs/full/.stamp_"* \
	       "$$OUT/build/buildroot-fs/squashfs/.stamp_"*; \
	echo ">>> pkgs-rebuild: building"; \
	$(MAKE) -C "$(BUILDROOT)" BR2_EXTERNAL=$(PANICOS_ROOT) O="$$OUT"

.PHONY: image-rebuild
image-rebuild:
	@test -n "$(DEVICE)" || (echo "DEVICE not set" >&2; exit 1)
	@OUT="$(_outdir)"; \
	test -d "$$OUT" || (echo "no build dir at $$OUT — run a full make first" >&2; exit 1); \
	echo ">>> image-rebuild: clearing rootfs + image stamps in $$OUT"; \
	rm -rf "$$OUT/build/buildroot-fs"; \
	$(MAKE) -C "$(BUILDROOT)" BR2_EXTERNAL=$(PANICOS_ROOT) O="$$OUT"

# image-variant: produce a same-SoC u-boot variant image without redoing
# the heavy work (toolchain, kernel, rootfs). Use case: rg35xx-pro vs
# rg35xx-pro-lpddr3 — same kernel + same userspace, only the U-Boot SPL
# differs (LPDDR3 vs LPDDR4 RAM training). Bypasses buildroot for the
# variant — directly rebuilds u-boot with the variant's defconfig using
# BASE's already-built cross-toolchain, then symlinks BASE's kernel +
# DTBs + rootfs.squashfs into the variant's images dir and runs the
# variant's post-image.sh.
#
# Usage:
#   make rg35xx-pro FLAVOR=launcher                                  # 1) base build
#   make image-variant DEVICE=rg35xx-pro-lpddr3 BASE=rg35xx-pro \    # 2) variant
#                      FLAVOR=launcher
#
# Caveat: rootfs is shared with BASE, so /etc/hostname and /etc/issue
# come from BASE's defconfig (cosmetic; "panicos-rg35xx-pro" not
# "-lpddr3"). For a fully variant-correct rootfs, fall back to a normal
# `make rg35xx-pro-lpddr3 FLAVOR=launcher` — slower but ccache should
# still keep it well under the cold-build time.
.PHONY: image-variant
image-variant:
	@test -n "$(DEVICE)" || (echo "DEVICE not set" >&2; exit 1)
	@test -n "$(BASE)"   || (echo "BASE not set"   >&2; exit 1)
	@FL="$${FLAVOR:-minimal}"; K="$(KERNEL)"; \
	SOC_B="$(call _device_soc,$(BASE))"; \
	SOC_V="$(call _device_soc,$(DEVICE))"; \
	test "$$SOC_B" = "$$SOC_V" || \
	  (echo "SoC mismatch: $(BASE)=$$SOC_B vs $(DEVICE)=$$SOC_V — image-variant only handles same-SoC U-Boot variants. For different SoCs run a normal full build." >&2; exit 1); \
	if [ -n "$$SOC_V" ] && [ -z "$$K" ]; then K="mainline"; fi; \
	BASE_OUT="$(OUTPUT_BASE)/$(BASE)-$$FL$${K:+-$$K}"; \
	VAR_OUT="$(OUTPUT_BASE)/$(DEVICE)-$$FL$${K:+-$$K}"; \
	test -d "$$BASE_OUT/images" || \
	  (echo "no base build at $$BASE_OUT — run 'make $(BASE) FLAVOR=$$FL' first" >&2; exit 1); \
	BOARD_DIR=$$(find $(PANICOS_ROOT)/board -mindepth 3 -maxdepth 3 -path "*/$(DEVICE)/Config.in" -printf '%h\n' 2>/dev/null | head -1); \
	test -n "$$BOARD_DIR" || (echo "no board dir for $(DEVICE)" >&2; exit 1); \
	UBOOT_BOARD=$$(awk -F'"' '/BR2_TARGET_UBOOT_BOARDNAME/ {print $$2}' "$$BOARD_DIR/defconfig.fragment"); \
	test -n "$$UBOOT_BOARD" || (echo "no BR2_TARGET_UBOOT_BOARDNAME in $$BOARD_DIR/defconfig.fragment — image-variant requires the variant defconfig.fragment to override the U-Boot boardname" >&2; exit 1); \
	UBOOT_BASE_BUILD="$$BASE_OUT/build/uboot-custom"; \
	test -d "$$UBOOT_BASE_BUILD" || (echo "no u-boot source at $$UBOOT_BASE_BUILD — base build incomplete?" >&2; exit 1); \
	echo ">>> image-variant: $(DEVICE) (uboot=$$UBOOT_BOARD) on $(BASE)'s kernel/rootfs"; \
	mkdir -p "$$VAR_OUT/build" "$$VAR_OUT/images"; \
	UBOOT_VAR_BUILD="$$VAR_OUT/build/uboot-custom"; \
	echo ">>> rsyncing u-boot source to $$UBOOT_VAR_BUILD"; \
	rsync -a --delete "$$UBOOT_BASE_BUILD/" "$$UBOOT_VAR_BUILD/"; \
	echo ">>> rebuilding u-boot for $$UBOOT_BOARD"; \
	export PATH="$$BASE_OUT/host/bin:$$BASE_OUT/host/sbin:$$PATH"; \
	export CROSS_COMPILE="aarch64-buildroot-linux-gnu-"; \
	$(MAKE) -C "$$UBOOT_VAR_BUILD" distclean >/dev/null 2>&1 || true; \
	$(MAKE) -C "$$UBOOT_VAR_BUILD" "$${UBOOT_BOARD}_defconfig"; \
	$(MAKE) -C "$$UBOOT_VAR_BUILD" -j$$(nproc); \
	test -f "$$UBOOT_VAR_BUILD/u-boot-sunxi-with-spl.bin" || \
	  (echo "u-boot build did not produce u-boot-sunxi-with-spl.bin — variant unsupported by this u-boot tree?" >&2; exit 1); \
	echo ">>> staging variant images dir from $(BASE)"; \
	rm -rf "$$VAR_OUT/images"; mkdir -p "$$VAR_OUT/images"; \
	ln -sf "$$BASE_OUT/images/Image" "$$VAR_OUT/images/Image"; \
	for f in "$$BASE_OUT/images"/*.dtb; do \
	  [ -e "$$f" ] && ln -sf "$$f" "$$VAR_OUT/images/$$(basename $$f)"; \
	done; \
	for d in "$$BASE_OUT/images/rtl_bt" "$$BASE_OUT/images/rtw88"; do \
	  [ -d "$$d" ] && ln -sfn "$$d" "$$VAR_OUT/images/$$(basename $$d)"; \
	done; \
	ln -sf "$$BASE_OUT/images/rootfs.squashfs" "$$VAR_OUT/images/rootfs.squashfs"; \
	cp -L "$$UBOOT_VAR_BUILD/u-boot-sunxi-with-spl.bin" \
	      "$$VAR_OUT/images/u-boot-sunxi-with-spl.bin"; \
	cp "$$BASE_OUT/.config" "$$VAR_OUT/.config"; \
	echo ">>> running variant post-image"; \
	cd $(PANICOS_ROOT) && \
	  BR2_EXTERNAL_PANICOS_PATH=$(PANICOS_ROOT) \
	  BR2_CONFIG="$$VAR_OUT/.config" \
	  BINARIES_DIR="$$VAR_OUT/images" \
	  BUILD_DIR="$$VAR_OUT/build" \
	  TARGET_DIR="$$BASE_OUT/target" \
	  HOST_DIR="$$BASE_OUT/host" \
	  "$$BOARD_DIR/post-image.sh" "$$VAR_OUT/images" "$$BOARD_DIR/genimage.cfg.in"

endif

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
	@echo "  make pkg-rebuild PKG=<pkg> DEVICE=<dev> [FLAVOR=<fl>]"
	@echo "                               Rebuild ONE buildroot package + image"
	@echo "                               (e.g. PKG=panicos-pht, PKG=linux, PKG=mesa3d)"
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
		PANICOS_INITRAMFS_FIRMWARE_DIRS="$$([ -d "$$FW_DIR" ] && echo "$$FW_DIR")" \
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
#   make pkg-rebuild PKG=panicos-pht DEVICE=rg35xx-pro FLAVOR=pht
#   make pkg-rebuild PKG=linux DEVICE=rg35xx-pro     # rebuild kernel only
#   make image-rebuild DEVICE=rg35xx-pro FLAVOR=pht  # squashfs + image only
#
# DEVICE is required; FLAVOR defaults to minimal; KERNEL defaults to mainline.

# Resolve OUT dir from DEVICE/FLAVOR/KERNEL.
define _outdir
$(OUTPUT_BASE)/$(DEVICE)-$(FLAVOR)$(if $(KERNEL),-$(KERNEL),-mainline)
endef

.PHONY: pkg-rebuild
pkg-rebuild:
	@test -n "$(PKG)"    || (echo "PKG not set"    >&2; exit 1)
	@test -n "$(DEVICE)" || (echo "DEVICE not set" >&2; exit 1)
	@OUT="$(_outdir)"; \
	test -d "$$OUT" || (echo "no build dir at $$OUT — run a full make first" >&2; exit 1); \
	echo ">>> pkg-rebuild: $(PKG)-rebuild in $$OUT"; \
	$(MAKE) -C "$(BUILDROOT)" BR2_EXTERNAL=$(PANICOS_ROOT) O="$$OUT" $(PKG)-rebuild; \
	rm -rf "$$OUT/build/buildroot-fs/full/.stamp_"* \
	       "$$OUT/build/buildroot-fs/squashfs/.stamp_"*; \
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

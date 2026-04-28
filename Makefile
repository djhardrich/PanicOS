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

.PHONY: help
help:
	@echo "PanicOS build (host wrapper)"
	@echo
	@echo "  make list-devices            List supported devices"
	@echo "  make harness-smoke           Build the smoke-test rootfs"
	@echo "  make <device>                Build a device image (later plans)"
	@echo "  make shell                   Interactive shell in the build container"
	@echo "  make clean-<device>          Clean a device's output dir"
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
	@SOC="$(call _device_soc,$(DEVICE))"; \
	K="$(KERNEL)"; \
	if [ -n "$$SOC" ] && [ -z "$$K" ]; then K="mainline"; fi; \
	OUT="$(OUTPUT_BASE)/$(DEVICE)-$(FLAVOR)$${K:+-$$K}"; \
	mkdir -p "$$OUT"; \
	if [ -n "$$SOC" ]; then \
		echo ">>> Building initramfs"; \
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

endif

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
%: container-image
	@docker run --rm -i $(DOCKER_TTY) \
		--user $(DOCKER_USER) \
		-v $(PANICOS_ROOT):/work \
		-w /work \
		-e IN_CONTAINER=1 \
		-e HOME=/tmp \
		$(DOCKER_IMAGE):$(DOCKER_TAG) \
		make $@

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
$(shell awk '/select PANICOS_SOC_/ { sub(/select PANICOS_SOC_/,""); gsub(/_/,"-"); print tolower($$0); exit }' \
    $(shell find board -mindepth 3 -maxdepth 3 -path "*/$(1)/Config.in" 2>/dev/null | head -1) 2>/dev/null)
endef

FLAVOR ?= minimal
KERNEL ?=

.PHONY: harness-smoke
harness-smoke:
	$(MAKE) _build DEVICE=harness-smoke

.PHONY: rg35xx-pro
rg35xx-pro:
	$(MAKE) _build DEVICE=rg35xx-pro

.PHONY: _build
_build:
	@test -n "$(DEVICE)" || (echo "DEVICE not set" >&2; exit 1)
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

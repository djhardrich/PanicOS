# Plan 01 — Build Harness Foundation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the PanicOS build harness so `make harness-smoke` produces a generic Buildroot rootfs inside a Docker container, end-to-end. No real device support yet — that's Plan 02. This plan proves the plumbing.

**Architecture:** Pinned Buildroot LTS as a submodule, consumed via `BR2_EXTERNAL`. A small Make wrapper auto-re-execs into a Debian-based Docker container, then runs `buildroot/Makefile` with our defconfig. Defconfigs are composed from Kconfig fragments at build time so we don't grow a `configs/*` cartesian explosion.

**Tech Stack:** Buildroot (LTS, e.g. `2025.02.x`), GNU Make, POSIX shell, Docker (Debian Bookworm base), Kconfig.

**Scope discipline:** This plan does **only** what's needed for `make harness-smoke` to succeed. No squashfs, no overlay, no kernel matrix, no DTB packaging, no importers, no TUI, no desktop flavors. Those land in later plans.

---

## File Structure

Files this plan creates (all under `~/PanicOS/`):

| Path | Responsibility |
|---|---|
| `.gitignore` | Ignore `output/`, `.cache/`, etc. |
| `.gitmodules` | Pin Buildroot submodule |
| `third_party/buildroot/` | Submodule (not stored in repo) |
| `external.desc` | `BR2_EXTERNAL` identification |
| `external.mk` | Hooks our `package/*.mk` into Buildroot's build (empty placeholder for now) |
| `Config.in` | Top-level Kconfig included by Buildroot |
| `kconfig/Config.in` | PanicOS root menu — sources flavor & device fragments |
| `kconfig/flavors.in` | `choice PANICOS_FLAVOR` (just `minimal` in v1) |
| `kconfig/devices.in` | `choice PANICOS_DEVICE` (just `harness-smoke`) |
| `flavors/minimal/Config.in` | Minimal flavor — no extra packages, BusyBox only |
| `board/panicos/harness-smoke/Config.in` | Pseudo-device for plumbing smoke test |
| `board/panicos/harness-smoke/defconfig.fragment` | Buildroot defconfig snippet for ARM64 generic build |
| `scripts/gen-defconfig.sh` | Composes a final defconfig from `flavor + device + soc + kernel` fragments |
| `scripts/test-gen-defconfig.sh` | Shell test for the generator |
| `docker/Dockerfile` | Build environment |
| `Makefile` | Top-level wrapper: container reexec, target dispatch, `make <device>` |
| `README.md` | Quick start (one section, ten lines) |

---

## Task 1 — Repo scaffolding & Buildroot submodule

**Files:**
- Create: `.gitignore`
- Create: `.gitmodules` (via `git submodule add`)
- Create: `third_party/buildroot` submodule

- [ ] **Step 1.1: Write `.gitignore`**

```
output/
.cache/
*.swp
.env.local
```

- [ ] **Step 1.2: Add Buildroot submodule pinned to latest 2025.02.x LTS**

```bash
cd ~/PanicOS
git submodule add https://gitlab.com/buildroot.org/buildroot.git third_party/buildroot
cd third_party/buildroot
# Use the most recent 2025.02.x tag at the time of execution.
# Verify with: git tag -l '2025.02.*' | sort -V | tail -1
LATEST_LTS=$(git tag -l '2025.02.*' | sort -V | tail -1)
git checkout "$LATEST_LTS"
cd ../..
git add .gitmodules third_party/buildroot
```

- [ ] **Step 1.3: Verify submodule resolves**

Run:
```bash
git submodule status
ls third_party/buildroot/Makefile
```
Expected: a SHA prefixed by ` ` (clean), and `third_party/buildroot/Makefile` exists.

- [ ] **Step 1.4: Commit**

```bash
git add .gitignore .gitmodules
git commit -m "Scaffold repo and pin Buildroot LTS submodule"
```

---

## Task 2 — Docker build environment

**Files:**
- Create: `docker/Dockerfile`

- [ ] **Step 2.1: Write `docker/Dockerfile`**

```dockerfile
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# Buildroot host deps per https://buildroot.org/downloads/manual/manual.html#requirement
# plus PanicOS additions.
RUN apt-get update && apt-get install -y --no-install-recommends \
        bash \
        bc \
        binutils \
        build-essential \
        bzip2 \
        ca-certificates \
        cpio \
        dosfstools \
        file \
        git \
        gzip \
        libncurses-dev \
        locales \
        make \
        mtools \
        patch \
        perl \
        python3 \
        rsync \
        sed \
        squashfs-tools \
        tar \
        unzip \
        wget \
        whiptail \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# Build user mirrors host UID/GID at runtime via --user; default to root for now.
WORKDIR /work
```

- [ ] **Step 2.2: Build the image and confirm**

Run:
```bash
docker build -t panicos-build:dev -f docker/Dockerfile .
docker run --rm panicos-build:dev bash -lc 'make --version && python3 --version && which whiptail'
```
Expected: `GNU Make 4.x`, Python 3.11+, `/usr/bin/whiptail`.

- [ ] **Step 2.3: Commit**

```bash
git add docker/Dockerfile
git commit -m "Add Debian Bookworm build container"
```

---

## Task 3 — Top-level Makefile with container re-exec

**Files:**
- Create: `Makefile`

- [ ] **Step 3.1: Write `Makefile`**

```make
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

# ---- Container re-exec ----------------------------------------------------
ifeq ($(IN_CONTAINER),)

.DEFAULT_GOAL := help

# Build container image on demand.
.PHONY: container-image
container-image:
	@docker image inspect $(DOCKER_IMAGE):$(DOCKER_TAG) >/dev/null 2>&1 || \
		docker build -t $(DOCKER_IMAGE):$(DOCKER_TAG) -f docker/Dockerfile .

# Re-exec any other goal inside the container.
%: container-image
	@docker run --rm -it \
		-v $(PANICOS_ROOT):/work \
		-w /work \
		-e IN_CONTAINER=1 \
		$(DOCKER_IMAGE):$(DOCKER_TAG) \
		make $@

.PHONY: shell
shell: container-image
	@docker run --rm -it \
		-v $(PANICOS_ROOT):/work \
		-w /work \
		-e IN_CONTAINER=1 \
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

# Per-device target: build with a generated defconfig.
# Usage: make <device> [FLAVOR=minimal] [KERNEL=vendor]
FLAVOR ?= minimal
KERNEL ?=

.PHONY: harness-smoke
harness-smoke:
	$(MAKE) _build DEVICE=harness-smoke

.PHONY: _build
_build:
	@test -n "$(DEVICE)" || (echo "DEVICE not set" >&2; exit 1)
	@OUT="$(OUTPUT_BASE)/$(DEVICE)-$(FLAVOR)$(if $(KERNEL),-$(KERNEL))"; \
	mkdir -p "$$OUT"; \
	scripts/gen-defconfig.sh \
		--device "$(DEVICE)" \
		--flavor "$(FLAVOR)" \
		$(if $(KERNEL),--kernel "$(KERNEL)") \
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
```

- [ ] **Step 3.2: Sanity-check the wrapper**

Run on host:
```bash
make help
```
Expected: prints the help block (no container build triggered yet because `help` is a host-side target).

- [ ] **Step 3.3: Commit**

```bash
git add Makefile
git commit -m "Add top-level Makefile with container re-exec"
```

---

## Task 4 — `BR2_EXTERNAL` skeleton

**Files:**
- Create: `external.desc`
- Create: `external.mk`
- Create: `Config.in`

- [ ] **Step 4.1: Write `external.desc`**

```
name: PANICOS
desc: PanicOS — handheld Linux images
```

- [ ] **Step 4.2: Write `external.mk`**

```make
# Hook PanicOS package fragments into Buildroot.
# Empty for now — packages get added in later plans.

include $(sort $(wildcard $(BR2_EXTERNAL_PANICOS_PATH)/package/*/*.mk))
```

- [ ] **Step 4.3: Write `Config.in`**

```
source "$BR2_EXTERNAL_PANICOS_PATH/kconfig/Config.in"
```

- [ ] **Step 4.4: Commit**

```bash
git add external.desc external.mk Config.in
git commit -m "Add BR2_EXTERNAL skeleton"
```

---

## Task 5 — Kconfig structure

**Files:**
- Create: `kconfig/Config.in`
- Create: `kconfig/flavors.in`
- Create: `kconfig/devices.in`

- [ ] **Step 5.1: Write `kconfig/Config.in`**

```
menu "PanicOS"

source "$BR2_EXTERNAL_PANICOS_PATH/kconfig/devices.in"
source "$BR2_EXTERNAL_PANICOS_PATH/kconfig/flavors.in"

endmenu
```

- [ ] **Step 5.2: Write `kconfig/devices.in`**

```
choice
	prompt "Device"
	default PANICOS_DEVICE_HARNESS_SMOKE

source "$BR2_EXTERNAL_PANICOS_PATH/board/panicos/harness-smoke/Config.in"

endchoice

config PANICOS_DEVICE_NAME
	string
	default "harness-smoke" if PANICOS_DEVICE_HARNESS_SMOKE
```

- [ ] **Step 5.3: Write `kconfig/flavors.in`**

```
choice
	prompt "Userspace flavor"
	default PANICOS_FLAVOR_MINIMAL

source "$BR2_EXTERNAL_PANICOS_PATH/flavors/minimal/Config.in"

endchoice

config PANICOS_FLAVOR_NAME
	string
	default "minimal" if PANICOS_FLAVOR_MINIMAL
```

- [ ] **Step 5.4: Commit**

```bash
git add kconfig/
git commit -m "Add PanicOS Kconfig root, flavor and device choices"
```

---

## Task 6 — `minimal` flavor and `harness-smoke` pseudo-device

**Files:**
- Create: `flavors/minimal/Config.in`
- Create: `board/panicos/harness-smoke/Config.in`
- Create: `board/panicos/harness-smoke/defconfig.fragment`

- [ ] **Step 6.1: Write `flavors/minimal/Config.in`**

```
config PANICOS_FLAVOR_MINIMAL
	bool "minimal — BusyBox only, useful for bring-up"
	help
	  Smallest possible userspace. BusyBox + init. No X, no Wayland,
	  no extra packages. Used for new-device bring-up and the build
	  harness smoke test.
```

- [ ] **Step 6.2: Write `board/panicos/harness-smoke/Config.in`**

```
config PANICOS_DEVICE_HARNESS_SMOKE
	bool "harness-smoke (generic ARM64, no real device)"
	help
	  Pseudo-device used to smoke-test the PanicOS build harness.
	  Builds a generic AArch64 rootfs with BusyBox. Not flashable
	  to any real hardware.
```

- [ ] **Step 6.3: Write `board/panicos/harness-smoke/defconfig.fragment`**

```
# harness-smoke: minimum to make Buildroot produce a rootfs.
BR2_aarch64=y
BR2_TOOLCHAIN_BUILDROOT_GLIBC=y
BR2_TARGET_GENERIC_HOSTNAME="panicos-smoke"
BR2_TARGET_GENERIC_ISSUE="PanicOS smoke"
BR2_TARGET_ROOTFS_TAR=y
# No kernel, no bootloader: smoke test only validates the harness.
# BR2_LINUX_KERNEL is not set
# BR2_TARGET_UBOOT is not set
```

- [ ] **Step 6.4: Commit**

```bash
git add flavors/minimal board/panicos/harness-smoke
git commit -m "Add minimal flavor and harness-smoke pseudo-device"
```

---

## Task 7 — `gen-defconfig.sh` with a real test

**Files:**
- Create: `scripts/gen-defconfig.sh`
- Create: `scripts/test-gen-defconfig.sh`

- [ ] **Step 7.1: Write the failing test first**

`scripts/test-gen-defconfig.sh`:

```bash
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
```

Make it executable:
```bash
chmod +x scripts/test-gen-defconfig.sh
```

- [ ] **Step 7.2: Run the test — expect failure**

Run inside container:
```bash
./scripts/test-gen-defconfig.sh
```
Expected: fails because `gen-defconfig.sh` doesn't exist yet.

- [ ] **Step 7.3: Implement `gen-defconfig.sh`**

`scripts/gen-defconfig.sh`:

```bash
#!/usr/bin/env bash
# Compose a Buildroot defconfig from PanicOS fragments.
#
# A defconfig = concatenation of:
#   board/*/<device>/defconfig.fragment
#   flavors/<flavor>/defconfig.fragment   (optional, may not exist yet)
#   soc/<soc>/<kernel>/defconfig.fragment (optional, only when --kernel given)
#
# Empty fragments are tolerated. Missing device fragment is an error.

set -euo pipefail

usage() {
	cat >&2 <<EOF
Usage: $0 --device <name> --flavor <name> [--kernel <vendor|mainline>] [--soc <name>] --output <path>
EOF
	exit 2
}

DEVICE=""; FLAVOR=""; KERNEL=""; SOC=""; OUTPUT=""
while [ $# -gt 0 ]; do
	case "$1" in
		--device)  DEVICE="$2"; shift 2 ;;
		--flavor)  FLAVOR="$2"; shift 2 ;;
		--kernel)  KERNEL="$2"; shift 2 ;;
		--soc)     SOC="$2"; shift 2 ;;
		--output)  OUTPUT="$2"; shift 2 ;;
		*) usage ;;
	esac
done

[ -n "$DEVICE" ] && [ -n "$FLAVOR" ] && [ -n "$OUTPUT" ] || usage

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Locate the device fragment under any vendor dir.
DEVICE_FRAGMENT="$(find "$ROOT/board" -mindepth 3 -maxdepth 3 \
	-path "*/$DEVICE/defconfig.fragment" 2>/dev/null | head -1 || true)"
if [ -z "$DEVICE_FRAGMENT" ] || [ ! -f "$DEVICE_FRAGMENT" ]; then
	echo "error: no defconfig.fragment found for device '$DEVICE'" >&2
	exit 1
fi

FLAVOR_FRAGMENT="$ROOT/flavors/$FLAVOR/defconfig.fragment"
SOC_FRAGMENT=""
if [ -n "$KERNEL" ] && [ -n "$SOC" ]; then
	SOC_FRAGMENT="$ROOT/soc/$SOC/$KERNEL/defconfig.fragment"
fi

mkdir -p "$(dirname "$OUTPUT")"
{
	echo "# Generated by gen-defconfig.sh on $(date -u +%FT%TZ)"
	echo "# device=$DEVICE flavor=$FLAVOR${KERNEL:+ kernel=$KERNEL}${SOC:+ soc=$SOC}"
	echo
	cat "$DEVICE_FRAGMENT"
	[ -f "$FLAVOR_FRAGMENT" ] && { echo; cat "$FLAVOR_FRAGMENT"; } || true
	[ -n "$SOC_FRAGMENT" ] && [ -f "$SOC_FRAGMENT" ] && { echo; cat "$SOC_FRAGMENT"; } || true
} > "$OUTPUT"
```

Make it executable:
```bash
chmod +x scripts/gen-defconfig.sh
```

- [ ] **Step 7.4: Run the test again — expect pass**

Run inside container:
```bash
./scripts/test-gen-defconfig.sh
```
Expected: three `PASS` lines and `all gen-defconfig tests passed`.

- [ ] **Step 7.5: Commit**

```bash
git add scripts/gen-defconfig.sh scripts/test-gen-defconfig.sh
git commit -m "Add gen-defconfig.sh defconfig composer with tests"
```

---

## Task 8 — End-to-end smoke test: `make harness-smoke`

This is the real validation that the whole harness works. Buildroot will download a toolchain and BusyBox, compile, and produce `output/harness-smoke-minimal/images/rootfs.tar`. Expect 20–60 minutes on first run depending on host and network.

- [ ] **Step 8.1: Run `make harness-smoke` from the host**

```bash
cd ~/PanicOS
make harness-smoke
```

This will:
1. Build the Docker image if missing.
2. Re-exec inside the container.
3. Generate the defconfig.
4. Run Buildroot.

- [ ] **Step 8.2: Verify the artifact exists**

```bash
ls -lh output/harness-smoke-minimal/images/rootfs.tar
file output/harness-smoke-minimal/images/rootfs.tar
```
Expected: a non-empty `tar` archive.

- [ ] **Step 8.3: Spot-check rootfs contents**

```bash
tar -tf output/harness-smoke-minimal/images/rootfs.tar | head -20
tar -xOf output/harness-smoke-minimal/images/rootfs.tar ./etc/issue 2>/dev/null
```
Expected: standard `/bin`, `/etc`, `/usr` paths; `/etc/issue` contains "PanicOS smoke".

- [ ] **Step 8.4: Verify `make list-devices` works**

```bash
make list-devices
```
Expected: prints `panicos/harness-smoke`.

- [ ] **Step 8.5: Verify `make clean-harness-smoke` works**

```bash
make clean-harness-smoke
ls output/ 2>/dev/null || true
```
Expected: `output/harness-smoke-*` removed.

- [ ] **Step 8.6: Commit nothing — this task only verifies, no code changes.**

If any verification failed, fix the underlying task and revisit. No commit required for verification.

---

## Task 9 — README quick start

**Files:**
- Create: `README.md`

- [ ] **Step 9.1: Write `README.md`**

```markdown
# PanicOS

Linux images for ARM handhelds. Buildroot-based.

## Quick start

```sh
git clone --recurse-submodules <repo-url> PanicOS
cd PanicOS
make harness-smoke   # smoke-test the build harness; ~30 min on first run
```

The output rootfs lands in `output/harness-smoke-minimal/images/rootfs.tar`.

## Real device builds

Coming in Plan 02 (Anbernic RG35XX Pro bring-up). Until then, `harness-smoke`
is the only target.

## Requirements

- Linux host with Docker installed and runnable by your user
- About 30GB of disk for the build tree (per device-flavor combination)
- Decent internet for the first Buildroot download

`IN_CONTAINER=1` on the make command line skips the Docker re-exec for users
who manage their own sandbox.

## Repository layout

See `docs/superpowers/specs/2026-04-27-panicos-build-system-design.md`.
```

- [ ] **Step 9.2: Commit**

```bash
git add README.md
git commit -m "Add README quick start"
```

---

## Done criteria for Plan 01

All true:

- [ ] `make help` prints the help block on the host without invoking Docker.
- [ ] `make harness-smoke` succeeds on a clean clone (one-shot from `git clone`).
- [ ] `output/harness-smoke-minimal/images/rootfs.tar` is a non-empty tarball with `/etc/issue` containing "PanicOS smoke".
- [ ] `./scripts/test-gen-defconfig.sh` passes inside the container.
- [ ] `make list-devices` prints `panicos/harness-smoke`.
- [ ] All commits land cleanly on `main`; no uncommitted files.

When all six are checked, Plan 01 is complete and Plan 02 (RG35XX Pro bring-up) becomes the next plan.

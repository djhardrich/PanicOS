# Plan 06 — Universal Vendor Blob Extractor (VBE) + module injection

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port PanicOS userspace to **any ARM handheld** by extracting the vendor kernel + modules + DTB(s) + U-Boot bootloader blobs from a stock vendor SD-card image, then either staging them as a `from-blobs` build (per Plan 04) or assembling a flashable image directly.

**Architecture:** A new tool `scripts/vbe.sh` with four subcommands (`extract`, `inject`, `build-image`, `port`) and TUI integration. The tool is a CLI shell+python script that runs inside our existing Docker container (where we already have `unsquashfs`, `mksquashfs`, `mkimage`, `genimage`, `python3`, etc.). Output of `extract` is a single `.tar.gz` archive with a manifest — shareable, replayable.

**Tech stack:** POSIX shell + python3, existing container deps, `binwalk` (added to Dockerfile), `kpartx`/`losetup`/`mount` for partition extraction, squashfs-tools for module injection, our existing `genimage` for image assembly.

**Scope discipline (v1):** Format coverage is **raw `.img` and `.img.gz`/`.img.xz` with MBR or GPT partition tables, FAT boot + ext4 rootfs**. That covers ~90% of handheld vendor images (Allwinner sunxi, Rockchip, generic ARM SBCs). RKImage `update.img`, Allwinner LiveSuit `.img` (sparse), Android sparse `.img`, .zip/.rar wrappers — **deferred** to a v2 plan. Round-trip test (extract our own RG353P image, port it back, compare) is the validation strategy.

**Out of scope:**
- Reverse-engineering vendor source from binaries
- License laundering — extracted blobs stay in user's local `output/vbe/` (gitignored), never committed
- Cross-architecture (only aarch64)
- Mainline-conversion attempts

---

## File Structure

| Path | Responsibility |
|---|---|
| `scripts/vbe.sh` | Main CLI dispatcher: `vbe.sh <subcommand> ...` |
| `scripts/vbe/identify.sh` | Detect wrapper, partition layout, SoC hints |
| `scripts/vbe/extract-allwinner.sh` | sunxi-specific extraction (boot0.img, boot_package.fex) |
| `scripts/vbe/extract-rockchip.sh` | Rockchip-specific (idbloader.img, u-boot.itb) |
| `scripts/vbe/extract-generic.sh` | Fallback: FAT-boot + ext4-rootfs extraction |
| `scripts/vbe/inject-modules.sh` | unsquashfs → copy modules → depmod → mksquashfs |
| `scripts/vbe/build-image.sh` | Assemble flashable .img.gz from blobs + squashfs |
| `scripts/vbe/manifest.py` | YAML manifest reader/writer (used by all subcommands) |
| `scripts/vbe/test/` | Test fixtures + smoke tests |
| `output/vbe/` | gitignored — local extraction working dirs |
| `docs/vbe-walkthrough.md` | End-user documentation with one full worked example |
| `Makefile` | Add `.PHONY: vbe` target that re-execs into container |
| `docker/Dockerfile` | Add `binwalk`, `parted`, `kpartx` if missing |
| `.gitignore` | `output/vbe/` |

---

## Task 1 — CLI scaffold + Dockerfile additions

**Files:**
- Create: `scripts/vbe.sh` (skeleton with subcommand dispatch + `--help`)
- Modified: `docker/Dockerfile` (add `binwalk`, `parted`, `kpartx`, `python3-yaml`)
- Modified: `Makefile` (add `vbe` target re-execing into container)
- Modified: `.gitignore` (add `output/vbe/`)

- [ ] **Step 1.1: `scripts/vbe.sh` skeleton**

```bash
#!/usr/bin/env bash
# PanicOS Vendor Blob Extractor
# Usage:
#   vbe.sh extract <vendor-image> [--out <archive.tar.gz>]
#   vbe.sh inject <archive.tar.gz> <input.squashfs> [--out <output.squashfs>]
#   vbe.sh build-image <archive.tar.gz> <squashfs> --out <flashable.img.gz>
#                       [--system-size 8G] [--overlay-size 64M]
#   vbe.sh port <vendor-image> <panicos-base.squashfs> --out <flashable.img.gz>
#   vbe.sh identify <image>           # diagnostic: print format detection results
#   vbe.sh --help

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VBE_DIR="$ROOT/scripts/vbe"

usage() {
    cat <<EOF >&2
PanicOS Vendor Blob Extractor (VBE)

Subcommands:
  extract <vendor-image> [--out FILE]      Extract blobs into a tar.gz archive
  inject  <archive> <squashfs> [--out FILE]  Inject vendor modules into a squashfs
  build-image <archive> <squashfs> --out FILE  Assemble a flashable image
  port    <vendor-image> <squashfs> --out FILE  extract + inject + build-image (one-shot)
  identify <image>                         Diagnostic: print detection results

Run 'vbe.sh <subcommand> --help' for subcommand-specific help.
EOF
    exit 2
}

[ $# -lt 1 ] && usage

cmd="$1"; shift
case "$cmd" in
    extract|inject|build-image|port|identify)
        exec "$VBE_DIR/cmd-${cmd}.sh" "$@"
        ;;
    --help|-h|help)
        usage
        ;;
    *)
        echo "vbe: unknown subcommand: $cmd" >&2
        usage
        ;;
esac
```

```bash
chmod +x scripts/vbe.sh
```

The per-subcommand scripts (`scripts/vbe/cmd-*.sh`) are stubbed in this task and filled in by Tasks 4–7.

- [ ] **Step 1.2: Stub subcommand scripts**

For each of `extract inject build-image port identify`, create `scripts/vbe/cmd-<subcommand>.sh`:

```bash
#!/usr/bin/env bash
# vbe <subcommand> — TODO: implemented in Task N
echo "vbe <subcommand>: not yet implemented" >&2
exit 1
```

Make them executable.

- [ ] **Step 1.3: Dockerfile additions**

Add to the existing apt-get block in `docker/Dockerfile` (alphabetical order):

```
        binwalk \
        kpartx \
        parted \
        python3-yaml \
```

Build the new container.

- [ ] **Step 1.4: Makefile `vbe` target**

In the host-side section, before `help`:

```make
.PHONY: vbe
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
# `--privileged` is required for kpartx/losetup. Mounting is risky;
# vbe runs as root inside the container but our tree is mounted from
# the host as our user — extracted artifacts go to /work/output/vbe/
# which is owned by us.
```

Update `make help` to mention `make vbe`.

- [ ] **Step 1.5: .gitignore**

Append:
```
output/vbe/
```

- [ ] **Step 1.6: Smoke test**

```bash
make vbe -- --help    # should print usage
make vbe -- identify  # should print "not yet implemented" + exit 1
```

(The `--` and `-- subcmd` syntax is awkward through Make's argument parsing. Simpler: just run `./scripts/vbe.sh --help` directly inside the container via `make shell`.)

- [ ] **Step 1.7: Commit**

```bash
git add scripts/vbe.sh scripts/vbe/ docker/Dockerfile Makefile .gitignore
git -c user.email=djhardrich@icloud.com -c user.name="djhardrich" \
    commit -m "VBE: CLI scaffold, Dockerfile additions, Makefile target, gitignore"
```

---

## Task 2 — Format identification

**Files:**
- Create: `scripts/vbe/cmd-identify.sh`
- Create: `scripts/vbe/lib-format.sh` (shared helpers)

`vbe identify <image>` walks an image and prints (to stdout, in YAML):
- Wrapper format (raw / gzip / xz)
- Partition table (mbr / gpt / none)
- Per-partition: number, start sector, size, fstype, role (boot / rootfs / bootloader / unknown)
- SoC hint (allwinner-sunxi / rockchip-rk3xxx / unknown), based on:
  - `eGON.BT0` magic at offset 0x2000 → Allwinner sunxi
  - `idbloader` magic or `RKxx` magic → Rockchip
  - DTB compatibles (if a FAT boot partition has a .dtb file, dtc -I dtb -O dts | grep "compatible")
  - Kernel version from `Image` strings

- [ ] **Step 2.1: Write `scripts/vbe/lib-format.sh`**

Detection helpers callable from cmd-identify.sh and per-format extractors. Functions:
- `vbe_unwrap(input, output_dir)` — auto-decompress gzip/xz to `output_dir/raw.img`; if input is already raw, just symlink
- `vbe_partition_table(raw_img)` — print `mbr` or `gpt` or `none` (using `parted -s -m <img> print` or `fdisk -l`)
- `vbe_partitions(raw_img)` — TSV: number, start_sector, size_sectors, fstype, label
- `vbe_soc_hint(raw_img)` — detect SoC family by examining bootloader bytes and embedded strings

Each function is a small shell function ~10 lines. Keep them straightforward.

- [ ] **Step 2.2: Write `scripts/vbe/cmd-identify.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib-format.sh"

IMAGE="${1:?usage: vbe identify <image>}"
WORK=$(mktemp -d -p output/vbe identify.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

RAW=$(vbe_unwrap "$IMAGE" "$WORK")
TABLE=$(vbe_partition_table "$RAW")
SOC=$(vbe_soc_hint "$RAW")

cat <<EOF
image: $IMAGE
unwrapped_to: $RAW
size_bytes: $(stat -c%s "$RAW")
partition_table: $TABLE
soc_hint: $SOC
partitions:
EOF
vbe_partitions "$RAW" | while IFS=$'\t' read -r num start size fstype label; do
    cat <<EOF
  - num: $num
    start_sector: $start
    size_sectors: $size
    fstype: $fstype
    label: $label
EOF
done
```

- [ ] **Step 2.3: Test with our own RG353P image**

```bash
./scripts/vbe.sh identify output/rg353p-minimal-mainline/images/panicos-rg353p-minimal-*.img.gz
```

Expected output (approximately):
```
image: ...
size_bytes: ...
partition_table: gpt
soc_hint: rockchip-rk35xx
partitions:
  - num: 1
    fstype: vfat
    label: boot
  - num: 2
    fstype: ext4
  - num: 3
    fstype: ext4
```

- [ ] **Step 2.4: Test with TrimUI Brick image**

```bash
./scripts/vbe.sh identify output/trimui-brick-minimal-vendor/images/panicos-trimui-brick-minimal-*.img.gz
```

Expected: `soc_hint: allwinner-sunxi`, gpt table.

- [ ] **Step 2.5: Commit**

```bash
git add scripts/vbe/lib-format.sh scripts/vbe/cmd-identify.sh
git -c user.email=djhardrich@icloud.com -c user.name="djhardrich" \
    commit -m "VBE: format identification (vbe identify)"
```

---

## Task 3 — Per-format extractors (Allwinner + Rockchip + generic)

**Files:**
- Create: `scripts/vbe/extract-allwinner.sh`
- Create: `scripts/vbe/extract-rockchip.sh`
- Create: `scripts/vbe/extract-generic.sh`

Each takes a raw `.img` + a working dir + a partitions TSV (from identify), and writes a structured output:
```
$work/
├── kernel/
│   ├── Image                  # or uImage / zImage / boot.img
│   ├── *.dtb                  # all DTBs found
│   └── kernel-info.txt        # version string from `strings Image | grep "^Linux version"`
├── modules/
│   ├── lib-modules.tar.gz     # tarball of /lib/modules/<kver>/
│   └── kver.txt               # kernel version from modules dir
├── bootloader/
│   ├── allwinner/             # boot0.img, boot_package.fex, env.img (Allwinner)
│   └── rockchip/              # idbloader.img, u-boot.itb (Rockchip)
└── extract-meta.yaml          # what came from where
```

- [ ] **Step 3.1: Allwinner extractor**

`extract-allwinner.sh`: knows about `eGON.BT0` at 0x2000, TOC1 magic for boot_package.fex, GPT layout typical of TrimUI/Anbernic. Pulls boot blobs by offset (using `dd skip=...`), and pulls kernel/modules from FAT boot + ext4 rootfs partitions via `kpartx -av $img` + mounts.

Test against TrimUI Brick image — should produce a directory whose contents match what we already have in `soc/allwinner-a133/vendor/prebuilt/trimui-brick/`.

- [ ] **Step 3.2: Rockchip extractor**

`extract-rockchip.sh`: idbloader at sector 64 (32K offset), u-boot.itb at sector 16384 (8M offset). Kernel + DTBs from FAT boot partition. Modules from ext4 rootfs.

Test against our RG353P image.

- [ ] **Step 3.3: Generic fallback**

`extract-generic.sh`: no SoC-specific bootloader extraction. Just FAT boot + ext4 rootfs partition mounting and pulling kernel/DTBs/modules. For unfamiliar SoCs the user has to handle bootloader staging manually.

- [ ] **Step 3.4: Commit**

```bash
git add scripts/vbe/extract-*.sh
git -c user.email=djhardrich@icloud.com -c user.name="djhardrich" \
    commit -m "VBE: per-format extractors (Allwinner, Rockchip, generic)"
```

---

## Task 4 — `vbe extract` operation

**File:** `scripts/vbe/cmd-extract.sh`

Orchestration: identify → dispatch to right extractor → bundle into tar.gz with manifest.

- [ ] **Step 4.1: Write `cmd-extract.sh`**

```bash
#!/usr/bin/env bash
# vbe extract <vendor-image> [--out <archive.tar.gz>]
set -euo pipefail
. "$(dirname "$0")/lib-format.sh"

# arg parse: $1 = image, --out <path>
IMAGE="${1:?usage: vbe extract <vendor-image> [--out PATH]}"
shift
OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="$2"; shift 2 ;;
        *) echo "vbe extract: unknown arg: $1" >&2; exit 2 ;;
    esac
done

WORK=$(mktemp -d -p output/vbe extract.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

RAW=$(vbe_unwrap "$IMAGE" "$WORK")
SOC=$(vbe_soc_hint "$RAW")

# Dispatch to extractor
case "$SOC" in
    allwinner-*) "$(dirname "$0")/extract-allwinner.sh" "$RAW" "$WORK" ;;
    rockchip-*)  "$(dirname "$0")/extract-rockchip.sh"  "$RAW" "$WORK" ;;
    *)           "$(dirname "$0")/extract-generic.sh"   "$RAW" "$WORK" ;;
esac

# Auto-derive output filename
if [ -z "$OUT" ]; then
    KVER=$(cat "$WORK/kernel/kernel-info.txt" | grep -oP 'Linux version \K[^ ]+' || echo "unknown-kver")
    SHA8=$(sha256sum "$IMAGE" | awk '{print substr($1,1,8)}')
    OUT="output/vbe/vbe-$SOC-$KVER-$SHA8.tar.gz"
    mkdir -p "$(dirname "$OUT")"
fi

# Bundle
( cd "$WORK" && tar -czf - . ) > "$OUT"
echo ">>> wrote $OUT ($(stat -c%s "$OUT") bytes)"
```

- [ ] **Step 4.2: Round-trip test on RG353P**

```bash
./scripts/vbe.sh extract output/rg353p-minimal-mainline/images/panicos-rg353p-minimal-*.img.gz
ls -lh output/vbe/vbe-rockchip-*.tar.gz
tar -tzf output/vbe/vbe-rockchip-*.tar.gz | head -20
```

Expected: archive contains `kernel/Image`, `kernel/rk3566-anbernic-rg353p.dtb` etc., `modules/lib-modules.tar.gz`, `bootloader/rockchip/idbloader.img`, `bootloader/rockchip/u-boot.itb`, `extract-meta.yaml`.

- [ ] **Step 4.3: Commit**

```bash
git add scripts/vbe/cmd-extract.sh
git -c user.email=djhardrich@icloud.com -c user.name="djhardrich" \
    commit -m "VBE: extract operation (vbe extract)"
```

---

## Task 5 — `vbe inject` operation

**File:** `scripts/vbe/cmd-inject.sh`

`vbe inject <archive.tar.gz> <input.squashfs> [--out output.squashfs]`

Process:
1. Stage archive into a temp dir
2. unsquashfs the input squashfs into another temp dir
3. Extract `modules/lib-modules.tar.gz` into the unpacked rootfs at `/lib/modules/<kver>/`
4. Run `depmod -a -b <unpacked-rootfs> <kver>` to regenerate module dependency files
5. mksquashfs back into the output path
6. Clean up

- [ ] **Step 5.1: Write `cmd-inject.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

ARCHIVE="${1:?usage: vbe inject <archive.tar.gz> <input.squashfs> [--out PATH]}"
SQ="${2:?usage: vbe inject <archive.tar.gz> <input.squashfs> [--out PATH]}"
shift 2
OUT="${SQ%.squashfs}-with-vendor-modules.squashfs"
while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

WORK=$(mktemp -d -p output/vbe inject.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# 1. Stage archive
mkdir -p "$WORK/archive"
tar -xzf "$ARCHIVE" -C "$WORK/archive"

# 2. Unsquashfs
unsquashfs -d "$WORK/rootfs" "$SQ"

# 3. Inject modules
KVER=$(cat "$WORK/archive/modules/kver.txt")
mkdir -p "$WORK/rootfs/lib/modules"
tar -xzf "$WORK/archive/modules/lib-modules.tar.gz" -C "$WORK/rootfs/lib/modules/"

# 4. depmod (host depmod must support cross-arch — use `depmod -b`)
# Verify the right kver dir exists
[ -d "$WORK/rootfs/lib/modules/$KVER" ] || {
    echo "error: expected /lib/modules/$KVER not found after extract" >&2
    ls "$WORK/rootfs/lib/modules/" >&2
    exit 1
}
depmod -b "$WORK/rootfs" "$KVER"

# 5. mksquashfs
mksquashfs "$WORK/rootfs" "$OUT" -comp gzip -no-progress -noappend

echo ">>> wrote $OUT ($(stat -c%s "$OUT") bytes)"
```

- [ ] **Step 5.2: Round-trip test**

```bash
./scripts/vbe.sh inject output/vbe/vbe-rockchip-*.tar.gz \
    output/rg353p-minimal-mainline/images/rootfs.squashfs
ls -lh output/rg353p-minimal-mainline/images/rootfs-with-vendor-modules.squashfs
unsquashfs -ll output/rg353p-minimal-mainline/images/rootfs-with-vendor-modules.squashfs \
    | grep "lib/modules/" | head
```

Expected: modules tree is present in the new squashfs.

- [ ] **Step 5.3: Commit**

```bash
git add scripts/vbe/cmd-inject.sh
git -c user.email=djhardrich@icloud.com -c user.name="djhardrich" \
    commit -m "VBE: inject operation (vendor modules into squashfs)"
```

---

## Task 6 — `vbe build-image` operation

**File:** `scripts/vbe/cmd-build-image.sh`

Combines a VBE archive + a squashfs into a flashable .img.gz with PanicOS's standard partition layout (boot FAT + system ext4 + overlay ext4) plus the SoC-specific bootloader staging.

This is the most complex subcommand because bootloader offsets vary by SoC. v1 supports Allwinner sunxi and Rockchip layouts; generic-SoC images skip the bootloader staging and require manual flashing of the bootloader by the user.

- [ ] **Step 6.1: Write `cmd-build-image.sh`**

The script generates a `genimage.cfg` on the fly based on the archive's `extract-meta.yaml` (which records the detected SoC), invokes `genimage`, gzips the output. Reuses the existing `panicos-initramfs.cpio.gz` (built via `scripts/build-initramfs.sh`).

Concrete content: ~80 lines of shell composing genimage.cfg from a per-SoC template (Allwinner offset 8K for SPL; Rockchip offset 32K for idbloader, 8M for u-boot.itb).

Templates live under `scripts/vbe/genimage-templates/<soc>.cfg.in`.

- [ ] **Step 6.2: Per-SoC genimage templates**

Create `scripts/vbe/genimage-templates/allwinner-sunxi.cfg.in` (mirrors our existing rg35xx-pro/genimage.cfg.in) and `scripts/vbe/genimage-templates/rockchip-rk35xx.cfg.in` (mirrors rg353p/genimage.cfg.in). Templates use `${...}` envsubst tokens for sizes and image filename.

- [ ] **Step 6.3: Round-trip validation**

```bash
./scripts/vbe.sh build-image \
    output/vbe/vbe-rockchip-*.tar.gz \
    output/rg353p-minimal-mainline/images/rootfs.squashfs \
    --out /tmp/rg353p-vbe-rebuilt.img.gz

# Compare structure to original
fdisk -l <(zcat /tmp/rg353p-vbe-rebuilt.img.gz)
fdisk -l <(zcat output/rg353p-minimal-mainline/images/panicos-rg353p-minimal-*.img.gz)
```

Expected: same partition layout, same number of DTBs, mostly-identical boot partition.

- [ ] **Step 6.4: Commit**

```bash
git add scripts/vbe/cmd-build-image.sh scripts/vbe/genimage-templates/
git -c user.email=djhardrich@icloud.com -c user.name="djhardrich" \
    commit -m "VBE: build-image operation (assemble flashable image)"
```

---

## Task 7 — `vbe port` composite

**File:** `scripts/vbe/cmd-port.sh`

Convenience wrapper: runs extract → inject → build-image, with intermediates in `$WORK`.

- [ ] **Step 7.1: Write `cmd-port.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

VENDOR_IMG="${1:?usage: vbe port <vendor-image> <panicos-base.squashfs> --out PATH}"
SQ="${2:?...}"
shift 2
# parse --out + other build-image options, pass through

WORK=$(mktemp -d -p output/vbe port.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

ARCHIVE="$WORK/extracted.tar.gz"
INJECTED="$WORK/with-vendor-modules.squashfs"

"$(dirname "$0")/cmd-extract.sh" "$VENDOR_IMG" --out "$ARCHIVE"
"$(dirname "$0")/cmd-inject.sh" "$ARCHIVE" "$SQ" --out "$INJECTED"
"$(dirname "$0")/cmd-build-image.sh" "$ARCHIVE" "$INJECTED" "$@"
```

- [ ] **Step 7.2: Test**

```bash
./scripts/vbe.sh port \
    output/rg353p-minimal-mainline/images/panicos-rg353p-minimal-*.img.gz \
    output/rg353p-minimal-mainline/images/rootfs.squashfs \
    --out /tmp/rg353p-ported.img.gz
```

Round-trip should produce something mostly equivalent to the input.

- [ ] **Step 7.3: Commit**

```bash
git add scripts/vbe/cmd-port.sh
git -c user.email=djhardrich@icloud.com -c user.name="djhardrich" \
    commit -m "VBE: port shortcut (extract + inject + build-image)"
```

---

## Task 8 — TUI integration

**File:** Modified `scripts/panicos-tui.sh`

Add a top-level menu choice "Port to a new device (Vendor Blob Extractor)" that drops into a sub-wizard with the four operations as menu items.

Each operation prompts for inputs via `whiptail --inputbox` and `whiptail --fselect`.

- [ ] **Step 8.1: Add VBE submenu to panicos-tui.sh**

After the existing device-selection menu, add a "What do you want to do?" top-level prompt with:
- Build a configured device image (existing flow)
- Vendor Blob Extractor (new — drops into `vbe-*` operations)

VBE submenu has: Extract / Inject / Build image / Port (composite) / Identify (diagnostic).

- [ ] **Step 8.2: Test interactively**

```bash
make tui
# Click through to VBE submenu and Identify; verify it runs.
```

- [ ] **Step 8.3: Commit**

```bash
git add scripts/panicos-tui.sh
git -c user.email=djhardrich@icloud.com -c user.name="djhardrich" \
    commit -m "TUI: add Vendor Blob Extractor submenu"
```

---

## Task 9 — Documentation + walkthrough

**File:** Create `docs/vbe-walkthrough.md`

End-user docs with one full worked example. The example: a hypothetical user has a Magicx Zero 28 (A133, supported by Knulli but pretend they have a vendor image instead of using Knulli's blobs). Walk them through:

1. Download or `dd`-extract their vendor SD card to a `.img.gz`
2. `make vbe -- identify <image>` — show what we detected
3. `make vbe -- port <image> output/.../rootfs.squashfs --out my-zero28.img.gz` — full pipeline
4. `dd if=my-zero28.img.gz | gunzip | dd of=/dev/sdX bs=4M` to flash

Include common-failure-modes section (encrypted vendor images, weird partition layouts, missing modules, etc.) and how to debug.

- [ ] **Step 9.1: Write `docs/vbe-walkthrough.md`**

~80 lines, one worked example, common-failures list.

- [ ] **Step 9.2: Update README.md**

Add a section pointing at the doc.

- [ ] **Step 9.3: Commit**

```bash
git add docs/vbe-walkthrough.md README.md
git -c user.email=djhardrich@icloud.com -c user.name="djhardrich" \
    commit -m "VBE: end-user walkthrough doc"
```

---

## Done criteria

- [ ] `make vbe -- identify <our own image>` correctly classifies SoC + partitions
- [ ] `make vbe -- extract <our own image>` produces a tar.gz archive whose contents match what we already have in `soc/<soc>/vendor/prebuilt/<device>/` (round-trip)
- [ ] `make vbe -- inject <archive> <our squashfs>` produces a squashfs with vendor modules merged in
- [ ] `make vbe -- build-image <archive> <squashfs>` produces a flashable .img.gz with the same partition layout as the original
- [ ] `make vbe -- port <vendor-image> <squashfs>` round-trip produces an image that **boots to the same point** as the original on the same hardware
- [ ] TUI exposes all 4+identify operations as menu items
- [ ] `docs/vbe-walkthrough.md` walks through a complete worked example
- [ ] Output files in `output/vbe/` are gitignored
- [ ] All existing builds (`make rg35xx-pro`, `make rg353p`, etc.) still work — VBE is additive

## Risks / open items

- **Cross-arch depmod:** depmod is generally arch-agnostic (operates on .ko metadata, not architecture). Should work fine cross-arch but verify.
- **Vendor kernel module ABI:** modules built against a vendor kernel with vendor-specific symbol versions won't load if the kernel is rebuilt. We don't rebuild the kernel — VBE preserves the vendor `Image` exactly. Should be fine.
- **Encrypted vendor images:** some vendor images use OEM-specific encryption/signing. v1 fails loudly with a meaningful error rather than silently corrupting. v2 can add encrypted-format support per OEM.
- **Sparse `.img` files (Android-style):** common with Qualcomm. v1 surfaces the issue; v2 adds simg2img invocation.

## Out of scope (deferred to future plans)

- Wrapper formats: .zip, .rar, .7z, .tar
- RKImage `update.img` (Rockchip recovery format)
- Allwinner LiveSuit `.img` (sparse/signed)
- Android sparse `.img` (simg2img)
- Per-OEM encryption/signing support
- Auto-PR'ing extracted device support upstream into ROCKNIX/Knulli
- Multi-architecture (32-bit ARM, RISC-V handhelds)

# Plan 03 — Vendor kernel flavor (Knulli BSP from source) + automated importers

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:**
1. **`make rg35xx-pro KERNEL=vendor`** produces a flashable image where the kernel is **Linux 4.9.170 BSP** (Orange Pi Xunlong fork, same source Knulli uses) but **everything else is built from source by us** — including U-Boot. No pre-built bootloader blobs.
2. **Re-runnable importers** — `scripts/sync-rocknix.sh` and `scripts/sync-knulli.sh` reproduce the manual cherry-picks done in Plan 02 against new submodule SHAs, with per-file SHA256 manifest tracking.

**Architecture pivot (vs the original Plan 03 sketch):** U-Boot is **hardware-specific**, not kernel-flavor-specific. The same U-Boot v2026.01 we built for mainline works with any kernel via the standard FIT/booti handoff. So the `uboot/` tree moves out of `soc/<soc>/<flavor>/uboot/` to `soc/<soc>/uboot/` (flavor-independent). The vendor flavor only differs from mainline in the **kernel** — different version (4.9.170 vs 7.0.1), different source (BSP git vs kernel.org tarball), different config (Knulli's full custom config vs ROCKNIX's defconfig+fragment).

This unlocks future work cleanly: RT-patching the vendor kernel = adding patches to `soc/<soc>/vendor/linux/patches/`. U-Boot multiboot menus = patches/config in `soc/<soc>/uboot/`. Both stay clean because we own the source.

**Tech Stack:** Buildroot harness (existing), Knulli submodule (reference for kernel config + repo URL), `BR2_LINUX_KERNEL_CUSTOM_GIT` for vendor kernel checkout, same U-Boot v2026.01 + TF-A as mainline.

**Scope discipline:** Vendor flavor for **RG35XX Pro only** (both LPDDR3 and LPDDR4). Other H700 devices and other SoCs (TrimUI Brick, RG353P/V) land in Plan 04. Importers cover both ROCKNIX and Knulli but only exercise H700 imports.

---

## File Structure

| Path | Responsibility |
|---|---|
| `third_party/knulli/` | Submodule pinned to a recent SHA |
| `soc/allwinner-h700/uboot/` | **Refactored** — moved from `mainline/uboot/`. Flavor-independent. |
| `soc/allwinner-h700/uboot/source.mk` | (moved) |
| `soc/allwinner-h700/uboot/patches/` | (moved) |
| `soc/allwinner-h700/uboot/defconfig.fragment` | (moved) |
| `soc/allwinner-h700/mainline/uboot/` | **Deleted** — content moved up one level |
| `soc/allwinner-h700/vendor/Config.in` | (already exists) |
| `soc/allwinner-h700/vendor/linux/source.mk` | LINUX_VERSION/repo/branch from Orange Pi Xunlong |
| `soc/allwinner-h700/vendor/linux/linux.config.fragment` | Imported from Knulli's `linux-sunxi64-legacy.config` |
| `soc/allwinner-h700/vendor/linux/defconfig.fragment` | `BR2_LINUX_KERNEL_CUSTOM_GIT=y` + custom config |
| `soc/allwinner-h700/vendor/linux/panicos-extras.config.fragment.in` | Same template token as mainline |
| `soc/allwinner-h700/vendor/linux/patches/` | (empty for now — RT patches and other tweaks land here later) |
| `soc/allwinner-h700/source.manifest.v2` | New manifest format with per-file SHA256 |
| `scripts/sync-rocknix.sh` | Re-runnable ROCKNIX importer |
| `scripts/sync-knulli.sh` | Re-runnable Knulli importer (kernel config only — no blobs) |
| `scripts/lib/import-common.sh` | Shared importer helpers |
| `kconfig/socs.in` | Update help text for vendor option (no longer "Plan 03 placeholder") |
| `Makefile` | Concat panicos-extras onto vendor's USE_CUSTOM_CONFIG kernel config |

The mainline + vendor + lpddr3 layout post-Plan-03:

```
soc/allwinner-h700/
├── Config.in
├── source.manifest          (legacy v1, kept for reference)
├── source.manifest.v2       (new, per-file SHA256)
├── uboot/                   ← flavor-independent (refactored)
│   ├── source.mk
│   ├── defconfig.fragment
│   └── patches/
├── mainline/
│   ├── Config.in
│   └── linux/
│       ├── source.mk
│       ├── linux.config.fragment
│       ├── panicos-extras.config.fragment.in
│       ├── defconfig.fragment
│       ├── dts/allwinner/
│       └── patches/
└── vendor/
    ├── Config.in
    └── linux/
        ├── source.mk
        ├── linux.config.fragment      ← Knulli's
        ├── panicos-extras.config.fragment.in
        ├── defconfig.fragment
        └── patches/                    ← empty; RT patches go here later
```

---

## Task 1 — Refactor: move `mainline/uboot/` → `uboot/`

**Files:**
- Move: `soc/allwinner-h700/mainline/uboot/` → `soc/allwinner-h700/uboot/`
- Modified: defconfig fragments and the Makefile that reference the old path

- [ ] **Step 1.1: Move the directory**

```bash
cd ~/PanicOS
git mv soc/allwinner-h700/mainline/uboot soc/allwinner-h700/uboot
ls soc/allwinner-h700/uboot/
```

- [ ] **Step 1.2: Update path references**

```bash
grep -rl "mainline/uboot" soc/ board/ Makefile scripts/ 2>/dev/null
```

For each match, replace `mainline/uboot` with `uboot`. The expected hits are:
- `soc/allwinner-h700/uboot/defconfig.fragment` (the moved file): replace `BR2_TARGET_UBOOT_PATCH="$(BR2_EXTERNAL_PANICOS_PATH)/soc/allwinner-h700/mainline/uboot/patches"` with `.../uboot/patches`
- Any `panicos-extras` references using `$O/...` paths — these are in mainline/linux/, leave alone.

```bash
sed -i 's|/soc/allwinner-h700/mainline/uboot/|/soc/allwinner-h700/uboot/|g' \
    soc/allwinner-h700/uboot/defconfig.fragment
```

- [ ] **Step 1.3: Update `gen-defconfig.sh` if it has flavor-specific path logic**

Recall from Plan 02 that `gen-defconfig.sh` does:
```bash
SOC_DIR="$ROOT/soc/$SOC/$KERNEL"
find "$SOC_DIR" -name 'defconfig.fragment'
```

That walks `soc/allwinner-h700/mainline/` for mainline builds — the move makes `uboot/defconfig.fragment` no longer found. We need to also walk `soc/<soc>/` for flavor-independent fragments.

Update `scripts/gen-defconfig.sh` to additionally include `soc/<soc>/uboot/defconfig.fragment` and any other flavor-independent fragments:

```bash
# Where the old single SOC_DIR walk was, replace with:
if [ -n "$KERNEL" ] && [ -n "$SOC" ]; then
    # Flavor-specific fragments
    SOC_DIR="$ROOT/soc/$SOC/$KERNEL"
    if [ -d "$SOC_DIR" ]; then
        while IFS= read -r f; do SOC_FRAGMENTS+=("$f"); done \
            < <(find "$SOC_DIR" -name 'defconfig.fragment' -type f | LC_ALL=C sort)
    fi
    # Flavor-independent fragments (e.g. uboot — same on all flavors)
    SOC_SHARED="$ROOT/soc/$SOC"
    while IFS= read -r f; do SOC_FRAGMENTS+=("$f"); done \
        < <(find "$SOC_SHARED" -mindepth 2 -maxdepth 3 -name 'defconfig.fragment' -type f \
            -not -path "*/mainline/*" -not -path "*/vendor/*" \
            | LC_ALL=C sort)
fi
```

The `-not -path` excludes the per-flavor subdirs we already walked above; the result is just `soc/<soc>/uboot/defconfig.fragment` and any future flavor-independent additions.

- [ ] **Step 1.4: Verify mainline still builds**

```bash
rm -rf output/rg35xx-pro-minimal-mainline
make rg35xx-pro 2>&1 | tee /tmp/test-mainline.log
echo "EXIT=${PIPESTATUS[0]}"
ls -lh output/rg35xx-pro-minimal-mainline/images/panicos-rg35xx-pro-minimal-*.img.gz
```

Expected: clean build, image produced.

- [ ] **Step 1.5: Commit**

```bash
git add -A soc/ scripts/gen-defconfig.sh
git -c user.email=djhardrich@icloud.com -c user.name="djhardrich" \
    commit -m "Refactor: move uboot tree out of <flavor>/ — it's flavor-independent"
```

---

## Task 2 — Add Knulli submodule

- [ ] **Step 2.1: Add submodule**

```bash
cd ~/PanicOS
git submodule add -b knulli-main https://github.com/knulli-cfw/distribution.git third_party/knulli
KNULLI_SHA=$(git -C third_party/knulli rev-parse HEAD)
echo "Pinned Knulli to: $KNULLI_SHA"
```

Record `KNULLI_SHA` for the importer manifest.

- [ ] **Step 2.2: Verify expected paths**

```bash
ls third_party/knulli/board/batocera/allwinner/h700/linux-sunxi64-legacy.config
grep -E "BR2_LINUX_KERNEL_CUSTOM_REPO" third_party/knulli/configs/knulli-h700_defconfig
```

Expected: kernel config file resolves; defconfig has `BR2_LINUX_KERNEL_CUSTOM_REPO_URL=...orangepi-xunlong/linux-orangepi.git` and `..._VERSION="orange-pi-4.9-sun50iw9"`.

- [ ] **Step 2.3: Commit**

```bash
git add .gitmodules third_party/knulli
git -c user.email=djhardrich@icloud.com -c user.name="djhardrich" \
    commit -m "Add Knulli submodule pinned to current knulli-main"
```

---

## Task 3 — Manifest v2 + shared importer helpers

**Files:**
- Create: `scripts/lib/import-common.sh`
- Create: `soc/allwinner-h700/source.manifest.v2`

The v1 manifest from Plan 02 (`soc/allwinner-h700/source.manifest`) is high-level. v2 records per-file SHA256 so re-runs can detect locally-modified files.

- [ ] **Step 3.1: Write `scripts/lib/import-common.sh`**

```bash
#!/usr/bin/env bash
# Shared helpers for sync-rocknix.sh and sync-knulli.sh.
set -euo pipefail

sha256_of() {
    [ -f "$1" ] && sha256sum "$1" | awk '{print $1}' || echo ""
}

git_sha256_of() {
    local repo="$1" sha="$2" path="$3"
    git -C "$repo" show "$sha:$path" 2>/dev/null | sha256sum | awk '{print $1}'
}

# Copy submodule:sha:path -> dest, append (dest, src, src_sha, dest_sha) to TSV.
import_file() {
    local repo="$1" sha="$2" src_path="$3" dest="$4" tsv="$5"
    mkdir -p "$(dirname "$dest")"
    git -C "$repo" show "$sha:$src_path" > "$dest"
    local src_sha; src_sha=$(git_sha256_of "$repo" "$sha" "$src_path")
    local dest_sha; dest_sha=$(sha256_of "$dest")
    printf '%s\t%s\t%s\t%s\n' "$dest" "$src_path" "$src_sha" "$dest_sha" >> "$tsv"
}

# Render a manifest section from TSV.
render_manifest_section() {
    local tsv="$1" name="$2" repo_path="$3" sha="$4" root="$5"
    echo "  - name: $name"
    echo "    submodule: $repo_path"
    echo "    sha: $sha"
    echo "    files:"
    while IFS=$'\t' read -r dest src src_sha dest_sha; do
        echo "      - dest: ${dest#$root/}"
        echo "        src: $src"
        echo "        src_sha256: $src_sha"
        echo "        dest_sha256: $dest_sha"
    done < "$tsv"
}

# Drift check: walk a manifest's recorded dest+dest_sha, compare to current
# on-disk SHA. Returns 0 if all match, prints DRIFT lines and returns 1 otherwise.
check_drift() {
    local manifest="$1" root="$2" name_filter="${3:-}"
    [ -f "$manifest" ] || return 0
    local in_section=0 d="" expected=""
    local drifted=0
    while IFS= read -r line; do
        case "$line" in
            "  - name: "*)
                if [ -z "$name_filter" ] || [ "${line#*name: }" = "$name_filter" ]; then
                    in_section=1
                else
                    in_section=0
                fi
                ;;
            "      - dest: "*) [ "$in_section" = 1 ] && d="${line#*dest: }" ;;
            "        dest_sha256: "*)
                [ "$in_section" = 1 ] || continue
                expected="${line#*dest_sha256: }"
                if [ -f "$root/$d" ]; then
                    actual=$(sha256_of "$root/$d")
                    if [ "$actual" != "$expected" ]; then
                        echo "DRIFT: $d (locally modified)" >&2
                        drifted=$((drifted+1))
                    fi
                fi
                ;;
        esac
    done < "$manifest"
    return $((drifted == 0 ? 0 : 1))
}
```

```bash
chmod +x scripts/lib/import-common.sh
```

- [ ] **Step 3.2: Commit**

```bash
git add scripts/lib/import-common.sh
git -c user.email=djhardrich@icloud.com -c user.name="djhardrich" \
    commit -m "Add shared importer helpers + manifest v2 schema"
```

---

## Task 4 — `scripts/sync-rocknix.sh`

Reproduces the H700 mainline import from ROCKNIX, **including the `8d65b605` LPDDR3 cherry-pick**.

- [ ] **Step 4.1: Write the importer**

`scripts/sync-rocknix.sh`:

```bash
#!/usr/bin/env bash
# Reproduces the H700 mainline import from ROCKNIX. Idempotent; refuses to
# clobber locally-modified files unless --force.
#
# Cherry-picks listed in CHERRY_PICKS pull from beyond the pinned next SHA.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib/import-common.sh"

ROCKNIX="$ROOT/third_party/rocknix"
SOC="$ROOT/soc/allwinner-h700"
SOC_MAIN="$SOC/mainline"
SOC_UBOOT="$SOC/uboot"
MANIFEST="$SOC/source.manifest.v2"

FORCE=0
for arg in "$@"; do case "$arg" in --force) FORCE=1 ;; *) echo "unknown arg: $arg">&2; exit 2;; esac; done

ROCKNIX_SHA=$(git -C "$ROCKNIX" rev-parse HEAD)
CHERRY_PICKS=( "8d65b60525f54258ec4ab381b4c7f80ec94148c5" )  # LPDDR3 commit

echo ">>> ROCKNIX submodule: $ROCKNIX_SHA"

if [ -f "$MANIFEST" ] && [ "$FORCE" = 0 ]; then
    if ! check_drift "$MANIFEST" "$ROOT" "rocknix-h700-mainline"; then
        echo "Use --force to overwrite." >&2; exit 1
    fi
fi

TSV=$(mktemp); trap 'rm -f "$TSV"' EXIT

# ----- kernel patches (3-tier import as in Plan 02) -----
import_patches_dir() {
    local sha="$1" subdir="$2" prefix="$3"
    local i="$prefix"
    while IFS= read -r base; do
        case "$base" in *.disabled) continue ;; esac
        import_file "$ROCKNIX" "$sha" "$subdir/$base" \
            "$SOC_MAIN/linux/patches/$(printf '%04d' $i)-$base" "$TSV"
        i=$((i+1))
    done < <(git -C "$ROCKNIX" ls-tree --name-only "$sha" "$subdir/" | grep '\.patch$' | sort)
}

rm -rf "$SOC_MAIN/linux/patches"
import_patches_dir "$ROCKNIX_SHA" "projects/ROCKNIX/packages/linux/patches/mainline" 100
import_patches_dir "$ROCKNIX_SHA" "projects/ROCKNIX/devices/H700/patches/linux" 200
import_patches_dir "$ROCKNIX_SHA" "projects/ROCKNIX/packages/linux/patches/7.0" 900

# Cherry-pick: kernel patch
import_file "$ROCKNIX" "${CHERRY_PICKS[0]}" \
    "projects/ROCKNIX/devices/H700/patches/linux/9999-Update-sun50i-h700-anbernic-rg35xx-2024.dts.patch" \
    "$SOC_MAIN/linux/patches/0223-9999-Update-sun50i-h700-anbernic-rg35xx-2024.dts.patch" "$TSV"

# ----- kernel config fragment + DTS -----
import_file "$ROCKNIX" "$ROCKNIX_SHA" \
    "projects/ROCKNIX/devices/H700/linux/linux.aarch64.conf" \
    "$SOC_MAIN/linux/linux.config.fragment" "$TSV"

rm -rf "$SOC_MAIN/linux/dts/allwinner"
while IFS= read -r base; do
    import_file "$ROCKNIX" "$ROCKNIX_SHA" \
        "projects/ROCKNIX/devices/H700/linux/dts/allwinner/$base" \
        "$SOC_MAIN/linux/dts/allwinner/$base" "$TSV"
done < <(git -C "$ROCKNIX" ls-tree --name-only "$ROCKNIX_SHA" \
    "projects/ROCKNIX/devices/H700/linux/dts/allwinner/" | grep '\.dts$')

# ----- U-Boot patches + cherry-picks (in flavor-independent uboot/) -----
rm -rf "$SOC_UBOOT/patches"
mkdir -p "$SOC_UBOOT/patches"

import_file "$ROCKNIX" "${CHERRY_PICKS[0]}" \
    "projects/ROCKNIX/devices/H700/packages/u-boot/patches/0001-Update-dram_sun50i_h616.c.patch" \
    "$SOC_UBOOT/patches/0001-Update-dram_sun50i_h616.c.patch" "$TSV"

# Synthesize defconfig-add patches
synth_defconfig_patch() {
    local sha="$1" name="$2" prefix="$3"
    local src="projects/ROCKNIX/devices/H700/packages/u-boot/sources/configs/$name"
    local content; content=$(git -C "$ROCKNIX" show "$sha:$src")
    local nlines; nlines=$(printf '%s\n' "$content" | wc -l)
    local out="$SOC_UBOOT/patches/$prefix-Add-$name.patch"
    {
        echo "From 0000000000000000000000000000000000000001 Mon Sep 17 00:00:00 2001"
        echo "From: PanicOS <noreply@panicos.local>"
        echo "Subject: [PATCH] Add $name"
        echo ""
        echo "Synthesized from ROCKNIX $sha"
        echo "---"
        echo " configs/$name | $nlines +"
        echo ""
        echo "diff --git a/configs/$name b/configs/$name"
        echo "new file mode 100644"
        echo "--- /dev/null"
        echo "+++ b/configs/$name"
        echo "@@ -0,0 +1,$nlines @@"
        printf '%s\n' "$content" | sed 's/^/+/'
    } > "$out"
    local src_sha; src_sha=$(git -C "$ROCKNIX" show "$sha:$src" | sha256sum | awk '{print $1}')
    local dest_sha; dest_sha=$(sha256_of "$out")
    printf '%s\t%s\t%s\t%s\n' "$out" "$src" "$src_sha" "$dest_sha" >> "$TSV"
}
synth_defconfig_patch "${CHERRY_PICKS[0]}" "anbernic_rg35xx_h700_lpddr3_defconfig" "0002"
synth_defconfig_patch "${CHERRY_PICKS[0]}" "anbernic_rg35xx_h700_lpddr4_defconfig" "0003"

# ----- write/replace rocknix section in manifest -----
NEW_SECTION=$(mktemp); trap 'rm -f "$TSV" "$NEW_SECTION"' EXIT
render_manifest_section "$TSV" "rocknix-h700-mainline" "third_party/rocknix" "$ROCKNIX_SHA" "$ROOT" > "$NEW_SECTION"

# Replace the rocknix-h700-mainline section in-place; preserve other sections.
python3 - "$MANIFEST" "$NEW_SECTION" <<'PY'
import sys, re
manifest_path, new_section_path = sys.argv[1], sys.argv[2]
new_section = open(new_section_path).read()
try:
    text = open(manifest_path).read()
except FileNotFoundError:
    text = "schema_version: 2\nimports:\n"
# Remove existing rocknix-h700-mainline block (from "  - name: rocknix-..." up to next "  - name:" or EOF).
text = re.sub(r'(?ms)^  - name: rocknix-h700-mainline\n.*?(?=^  - name:|\Z)', '', text)
if 'imports:' not in text:
    text += 'imports:\n'
text = text.rstrip() + '\n' + new_section
open(manifest_path, 'w').write(text)
PY

echo ">>> done"
```

```bash
chmod +x scripts/sync-rocknix.sh
```

- [ ] **Step 4.2: Run + idempotency check**

```bash
./scripts/sync-rocknix.sh
git status --short soc/allwinner-h700/
```

Expected: only `source.manifest.v2` is new. Patch contents should match what's already on disk (synthesized patches' minor "From" header line will differ — accept as known).

- [ ] **Step 4.3: Drift-detection check**

```bash
echo "# local mod" >> soc/allwinner-h700/mainline/linux/linux.config.fragment
./scripts/sync-rocknix.sh   # should error with DRIFT
git checkout -- soc/allwinner-h700/mainline/linux/linux.config.fragment
```

- [ ] **Step 4.4: Commit**

```bash
git add scripts/sync-rocknix.sh soc/allwinner-h700/source.manifest.v2
git -c user.email=djhardrich@icloud.com -c user.name="djhardrich" \
    commit -m "Add scripts/sync-rocknix.sh — re-runnable ROCKNIX importer"
```

---

## Task 5 — `scripts/sync-knulli.sh` (kernel config only)

Knulli's importable content for vendor flavor is a single kernel config file (`linux-sunxi64-legacy.config`). The repo URL + branch + version are already encoded in `soc/<soc>/vendor/linux/source.mk` and `defconfig.fragment` — Knulli is the **reference**, not a patch source. So sync-knulli.sh imports just the config file.

- [ ] **Step 5.1: Write the importer**

`scripts/sync-knulli.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib/import-common.sh"

KNULLI="$ROOT/third_party/knulli"
SOC_VENDOR="$ROOT/soc/allwinner-h700/vendor"
MANIFEST="$ROOT/soc/allwinner-h700/source.manifest.v2"

FORCE=0
for arg in "$@"; do case "$arg" in --force) FORCE=1 ;; *) exit 2;; esac; done

KNULLI_SHA=$(git -C "$KNULLI" rev-parse HEAD)
echo ">>> Knulli submodule: $KNULLI_SHA"

if [ -f "$MANIFEST" ] && [ "$FORCE" = 0 ]; then
    if ! check_drift "$MANIFEST" "$ROOT" "knulli-h700-vendor"; then
        echo "Use --force to overwrite." >&2; exit 1
    fi
fi

TSV=$(mktemp); trap 'rm -f "$TSV"' EXIT

import_file "$KNULLI" "$KNULLI_SHA" \
    "board/batocera/allwinner/h700/linux-sunxi64-legacy.config" \
    "$SOC_VENDOR/linux/linux.config.fragment" "$TSV"

NEW_SECTION=$(mktemp); trap 'rm -f "$TSV" "$NEW_SECTION"' EXIT
render_manifest_section "$TSV" "knulli-h700-vendor" "third_party/knulli" "$KNULLI_SHA" "$ROOT" > "$NEW_SECTION"

python3 - "$MANIFEST" "$NEW_SECTION" <<'PY'
import sys, re
manifest_path, new_section_path = sys.argv[1], sys.argv[2]
new_section = open(new_section_path).read()
text = open(manifest_path).read()
text = re.sub(r'(?ms)^  - name: knulli-h700-vendor\n.*?(?=^  - name:|\Z)', '', text)
text = text.rstrip() + '\n' + new_section
open(manifest_path, 'w').write(text)
PY

echo ">>> done"
```

```bash
chmod +x scripts/sync-knulli.sh
```

- [ ] **Step 5.2: Run**

```bash
./scripts/sync-knulli.sh
ls -lh soc/allwinner-h700/vendor/linux/linux.config.fragment
head -5 soc/allwinner-h700/vendor/linux/linux.config.fragment
```

Expected: file present, content starts with kernel config header.

- [ ] **Step 5.3: Commit**

```bash
git add scripts/sync-knulli.sh soc/allwinner-h700/vendor/linux/linux.config.fragment soc/allwinner-h700/source.manifest.v2
git -c user.email=djhardrich@icloud.com -c user.name="djhardrich" \
    commit -m "Add scripts/sync-knulli.sh and import vendor kernel config"
```

---

## Task 6 — Vendor kernel source.mk + defconfig fragment

**Files:**
- Create: `soc/allwinner-h700/vendor/linux/source.mk`
- Create: `soc/allwinner-h700/vendor/linux/defconfig.fragment`
- Create: `soc/allwinner-h700/vendor/linux/panicos-extras.config.fragment.in`
- Create: `soc/allwinner-h700/vendor/linux/patches/.gitkeep`

- [ ] **Step 6.1: source.mk**

```make
# Knulli vendor BSP kernel — Allwinner sun50iw9 (H700) on Linux 4.9.
# Source: Orange Pi Xunlong's BSP fork; same as Knulli uses.
PANICOS_LINUX_CUSTOM_REPO_URL := https://github.com/orangepi-xunlong/linux-orangepi.git
PANICOS_LINUX_CUSTOM_REPO_VERSION := orange-pi-4.9-sun50iw9
PANICOS_LINUX_VERSION := 4.9.170
```

- [ ] **Step 6.2: defconfig.fragment**

`soc/allwinner-h700/vendor/linux/defconfig.fragment`:

```
# Linux kernel — Allwinner H700 vendor (Knulli BSP) flavor.

BR2_LINUX_KERNEL=y
BR2_LINUX_KERNEL_CUSTOM_GIT=y
BR2_LINUX_KERNEL_CUSTOM_REPO_URL="https://github.com/orangepi-xunlong/linux-orangepi.git"
BR2_LINUX_KERNEL_CUSTOM_REPO_VERSION="orange-pi-4.9-sun50iw9"
BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE="4.9.170"

# Patches (initially empty; RT and other tweaks land here later).
BR2_LINUX_KERNEL_PATCH="$(BR2_EXTERNAL_PANICOS_PATH)/soc/allwinner-h700/vendor/linux/patches"

# Vendor BSP has no upstream defconfig that matches our needs — use
# Knulli's full kernel config (concatenated with panicos-extras at build
# time by the Makefile; see Task 7).
BR2_LINUX_KERNEL_USE_CUSTOM_CONFIG=y
BR2_LINUX_KERNEL_CUSTOM_CONFIG_FILE="$(O)/vendor-linux.config"

BR2_LINUX_KERNEL_DTS_SUPPORT=y
# DTBs come from the BSP kernel's own arch/arm64/boot/dts/allwinner/.
# Implementer fills with Knulli's BR2_LINUX_KERNEL_INTREE_DTS_NAME at
# execution time (verified against Knulli's defconfig + actual files in
# the kernel tree once it's checked out).
BR2_LINUX_KERNEL_INTREE_DTS_NAME="<fill-in>"

BR2_LINUX_KERNEL_GZIP=y

# Toolchain headers — the closest pre-defined Buildroot LTS that doesn't
# patch-conflict with our vendor source. 4.9 → 5.10 should be safe.
BR2_KERNEL_HEADERS_5_10=y
```

- [ ] **Step 6.3: panicos-extras template**

Same content as the mainline version but a separate file (in case the symbol names diverge between 4.9 and 7.0):

```
CONFIG_SQUASHFS=y
CONFIG_SQUASHFS_XATTR=y
CONFIG_SQUASHFS_ZLIB=y
CONFIG_BLK_DEV_LOOP=y
CONFIG_EXT4_FS=y
CONFIG_VFAT_FS=y
CONFIG_NLS_CODEPAGE_437=y
CONFIG_NLS_ASCII=y
CONFIG_NLS_ISO8859_1=y
CONFIG_NLS_UTF8=y
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y
CONFIG_INITRAMFS_SOURCE="@PANICOS_INITRAMFS_PATH@"
CONFIG_INITRAMFS_COMPRESSION_GZIP=y
```

- [ ] **Step 6.4: Empty patches dir + .gitkeep**

```bash
mkdir -p soc/allwinner-h700/vendor/linux/patches
touch soc/allwinner-h700/vendor/linux/patches/.gitkeep
```

- [ ] **Step 6.5: Commit**

```bash
git add soc/allwinner-h700/vendor/linux/
git -c user.email=djhardrich@icloud.com -c user.name="djhardrich" \
    commit -m "Add H700 vendor (Knulli BSP) kernel source + defconfig fragments"
```

---

## Task 7 — Makefile: handle USE_CUSTOM_CONFIG concat for vendor flavor

The vendor flavor uses `BR2_LINUX_KERNEL_USE_CUSTOM_CONFIG` (single-file), which can't combine with `_CONFIG_FRAGMENT_FILES`. We must concat Knulli's full config + our `panicos-extras` into a single file and point Buildroot at that.

The mainline flavor uses `BR2_LINUX_KERNEL_USE_DEFCONFIG=y` + `_CONFIG_FRAGMENT_FILES`, which DOES support fragments — no concat needed.

- [ ] **Step 7.1: Update `_build` recipe**

In `Makefile`'s in-container `_build` target, after rendering `panicos-extras.config.fragment`, add a vendor-specific concat step:

```make
		# Vendor flavor uses USE_CUSTOM_CONFIG (single-file). Concat
		# Knulli's full config + our extras into $O/vendor-linux.config;
		# defconfig.fragment points BR2_LINUX_KERNEL_CUSTOM_CONFIG_FILE
		# at $(O)/vendor-linux.config.
		if [ "$$K" = "vendor" ]; then \
			BASE="$(PANICOS_ROOT)/soc/$$SOC/vendor/linux/linux.config.fragment"; \
			cat "$$BASE" "$$EXTRAS_OUT" > "$$OUT/vendor-linux.config"; \
		fi; \
```

(Inserted after the `if [ -f "$$EXTRAS_IN" ]; then ... fi;` block, before `gen-defconfig.sh` invocation.)

- [ ] **Step 7.2: Commit**

```bash
git add Makefile
git -c user.email=djhardrich@icloud.com -c user.name="djhardrich" \
    commit -m "Makefile: concat Knulli's config + panicos-extras for vendor build"
```

---

## Task 8 — Update Kconfig + per-device Config.in for vendor

- [ ] **Step 8.1: kconfig/socs.in — drop the "Plan 03 placeholder" caveat**

Update the help text on `PANICOS_KERNEL_FLAVOR_VENDOR` to remove "will fail until Plan 03 is complete":

```
config PANICOS_KERNEL_FLAVOR_VENDOR
	bool "vendor"
	help
	  Vendor BSP kernel — Linux 4.9.170 from Orange Pi Xunlong's
	  fork (the same source Knulli uses), built from source by us.
	  Useful for devices where mainline support is incomplete or
	  where vendor-only features (RT patches, certain peripherals)
	  are needed.
```

- [ ] **Step 8.2: Verify rg35xx-pro and rg35xx-pro-lpddr3 Config.in already work**

These select PANICOS_SOC_ALLWINNER_H700 which works for both kernel flavors. No change needed to per-device Config.in — kernel flavor is selected at the top level via `PANICOS_KERNEL_FLAVOR` choice.

- [ ] **Step 8.3: Commit**

```bash
git add kconfig/socs.in
git -c user.email=djhardrich@icloud.com -c user.name="djhardrich" \
    commit -m "Kconfig: vendor kernel flavor is no longer a placeholder"
```

---

## Task 9 — End-to-end vendor build

- [ ] **Step 9.1: Fill in `BR2_LINUX_KERNEL_INTREE_DTS_NAME` for vendor**

Before building, the implementer must determine which DTBs the 4.9 BSP kernel can build. After the kernel git-clones (first build attempt), inspect:

```bash
ls output/rg35xx-pro-minimal-vendor/build/linux-custom/arch/arm64/boot/dts/allwinner/sun50i-h*-anbernic*.dts
```

Pick the entries that exist in the BSP tree and put them (basename without `.dts`, prefixed with `allwinner/`) into `soc/allwinner-h700/vendor/linux/defconfig.fragment`. Likely they'll be similar to mainline's list but **without** the panel-revision suffixes (`-rev6-panel`, `-v2-panel`) since those are recent additions only in mainline DTS.

- [ ] **Step 9.2: Build**

```bash
set -o pipefail
make rg35xx-pro KERNEL=vendor 2>&1 | tee /tmp/panicos-vendor.log
echo "EXIT=${PIPESTATUS[0]}"
```

Expected: 30–60 min (smaller kernel than 7.0.1, but git clone is slower than tarball).

- [ ] **Step 9.3: Verify image**

```bash
ls -lh output/rg35xx-pro-minimal-vendor/images/panicos-rg35xx-pro-minimal-*.img.gz
```

- [ ] **Step 9.4: Inspect partition layout**

```bash
gunzip -k output/rg35xx-pro-minimal-vendor/images/panicos-rg35xx-pro-minimal-*.img.gz
IMG=$(ls output/rg35xx-pro-minimal-vendor/images/panicos-rg35xx-pro-minimal-*.img | head -1)
fdisk -l "$IMG" | head
```

Expected: same partition layout as the mainline build (boot 256M FAT + system 8G ext4 + overlay 64M ext4 + U-Boot SPL at 8K offset). Only the kernel inside differs.

- [ ] **Step 9.5: User flashes and verifies on hardware**

User confirms: vendor kernel boots, key peripherals work (or note which don't). Record observations for future RT-patch / multiboot work.

---

## Done criteria

- [ ] U-Boot tree refactored to `soc/<soc>/uboot/`; mainline build still works
- [ ] Knulli submodule pinned at `third_party/knulli/`
- [ ] `scripts/sync-rocknix.sh` reproduces the manual ROCKNIX import + LPDDR3 cherry-pick; idempotent; aborts on local drift
- [ ] `scripts/sync-knulli.sh` imports Knulli's vendor kernel config
- [ ] `make rg35xx-pro KERNEL=vendor` succeeds end-to-end
- [ ] Resulting image flashes and boots on hardware (user verified)
- [ ] `make rg35xx-pro` (mainline LPDDR4) and `make rg35xx-pro-lpddr3` (mainline LPDDR3) still work
- [ ] `soc/allwinner-h700/source.manifest.v2` records both rocknix and knulli imports with per-file SHA256

## Out of scope (deferred)

- Vendor flavor for any device other than RG35XX Pro (Plan 04)
- Vendor flavor for LPDDR3 (Knulli's config is single — would need a separate vendor BSP for LPDDR3 timings, which doesn't appear to exist in the Allwinner BSP. May not be possible; user can investigate.)
- RT patches on the vendor kernel — drop them into `soc/allwinner-h700/vendor/linux/patches/` (this Plan creates the dir; the patches are a future piece of work)
- U-Boot multiboot menu — patches/config in `soc/<soc>/uboot/` (this plan refactors uboot/ to be flavor-independent so multiboot config is a clean addition)
- Knulli importer for non-H700 SoCs (Plan 04+)
- Migrating the legacy v1 manifest to v2

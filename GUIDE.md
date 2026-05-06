# PanicOS Build Guide

Practical reference for agents and contributors working on the build pipeline.
Covers the day-to-day incremental workflow — read README.md first for project
overview, INTERNAL.md for vendor/signing pipeline details.

---

## Build system overview

All builds run inside a Docker container (`panicos-build:<tag>`). The outer
`make` targets are thin wrappers that exec into the container and re-run the
same target with `IN_CONTAINER=1`. You never need to touch Docker directly.

```
make <target> [DEVICE=...] [FLAVOR=...] [KERNEL=...]
```

The container image is rebuilt automatically when `docker/Dockerfile` changes
(keyed by SHA1). If the container image is stale run `make container-image`
explicitly.

Output lands at:

```
output/<device>-<flavor>-<kernel>/
  .config                  # active buildroot config
  .defconfig               # merged defconfig (source of truth for this build)
  build/<pkg>-<version>/   # per-package build trees
  images/                  # flashable artifacts
    panicos-<device>-<flavor>-<rev>.img.gz
    panicos-<device>-<flavor>.squashfs
    boot.vfat
```

---

## Full builds

For a first build, or when you genuinely need a clean tree (toolchain change,
libc swap — rare):

```sh
make rg35xx-pro FLAVOR=launcher     # ~45 min cold; ~15 min with ccache warm
make rg353p FLAVOR=launcher
make trimui-brick FLAVOR=minimal
```

`FLAVOR` defaults to `minimal` if omitted. The full build: generates a merged
defconfig from `flavors/<flavor>/defconfig.fragment` +
`board/<soc>/<device>/defconfig.fragment`, regenerates `.config`, builds
everything, packages a squashfs, and gzips a flashable `.img`.

---

## Incremental builds (the normal workflow)

Full clean rebuilds are almost never needed. Buildroot tracks dependencies;
only changed packages rebuild. Use one of these patterns:

### `pkg-rebuild` — one package

Clears that package's stamp files and rebuilds. Use for single-package edits
(our local `package/panicos-*/` packages, kernel, mesa3d, etc.):

```sh
make pkg-rebuild PACKAGE=panicos-pht DEVICE=rg35xx-pro FLAVOR=pht
make pkg-rebuild PACKAGE=linux       DEVICE=rg35xx-pro FLAVOR=launcher
make pkg-rebuild PACKAGE=mesa3d      DEVICE=rg35xx-pro FLAVOR=launcher
```

Produces a new flashable image at the end. Time scales with that package's
build cost (local packages: 1-3 min; kernel: ~15 min; mesa3d: ~20 min).

### `pkgs-rebuild` — multiple packages at once

Like `pkg-rebuild` but takes a space-separated list AND re-runs defconfig
generation first. Use when you've added a new package to a defconfig.fragment
or are rebuilding several packages in one shot:

```sh
make pkgs-rebuild PACKAGES="mesa3d panicos-ffmpeg4-compat" \
                  DEVICE=rg35xx-pro FLAVOR=launcher
```

The defconfig regeneration ensures newly-added `BR2_PACKAGE_*=y` entries land
in `.config` before the stamps are cleared. Single final build pass, so the
image is assembled only once regardless of how many packages you list.

### `image-rebuild` — squashfs + image only, no package rebuild

Re-rolls the squashfs and image without touching any package. Use when only
post-image scripts, genimage layout, or `extlinux.conf` changed:

```sh
make image-rebuild DEVICE=rg35xx-pro FLAVOR=launcher    # ~2 min
```

### Shortcut: just `make <device>`

If the build tree already exists and you want buildroot to figure out what
needs rebuilding (e.g. you added a new package to defconfig.fragment and
already ran `make ... defconfig`), you can run the full target without clean
and buildroot will only build the delta:

```sh
make rg35xx-pro FLAVOR=launcher
```

Buildroot won't rebuild packages whose stamps are present and up-to-date.

---

## LPDDR3 image variant (`rg35xx-pro-lpddr3`)

`rg35xx-pro-lpddr3` differs from `rg35xx-pro` in **only the U-Boot SPL**
(LPDDR3 vs LPDDR4 RAM training parameters). The kernel, DTBs, and entire
rootfs are byte-for-byte identical. Running `make rg35xx-pro-lpddr3` would
rebuild the full tree from scratch — ~45 min for a swapped SPL blob. Don't.

Use `image-variant` instead. It:
1. Reuses the base device's already-built kernel, DTBs, rootfs
2. Recompiles only U-Boot against the variant's board config (~3-5 min)
3. Symlinks everything into a fresh `output/rg35xx-pro-lpddr3-*/images/` dir
4. Runs the variant's post-image script to produce the final `.img.gz`

```sh
# Step 1 (only once, or after any package change):
make rg35xx-pro FLAVOR=launcher

# Step 2 (always after step 1):
make image-variant DEVICE=rg35xx-pro-lpddr3 BASE=rg35xx-pro FLAVOR=launcher
```

**Always run both.** After any incremental rebuild of the base
(`pkg-rebuild`, `pkgs-rebuild`, etc.), re-run `image-variant` to pick up the
change in the LPDDR3 image. Skipping this is a common mistake.

The `image-variant` target validates that BASE and DEVICE share the same SoC
before doing anything, so it will error out loudly if called with mismatched
devices.

---

## Adding a new package

1. Create `package/<pkg-name>/Config.in` and `package/<pkg-name>/<pkg-name>.mk`
2. Add `source "$BR2_EXTERNAL_PANICOS_PATH/package/<pkg-name>/Config.in"` to
   `package/Config.in` (before `endmenu`)
3. Add `BR2_PACKAGE_<PKG_NAME>=y` to the relevant `flavors/<fl>/defconfig.fragment`
4. Build:
   ```sh
   make pkgs-rebuild PACKAGES="<pkg-name>" DEVICE=rg35xx-pro FLAVOR=launcher
   ```

`pkgs-rebuild` (not `pkg-rebuild`) is required here because it re-generates
the defconfig so the new `BR2_PACKAGE_*=y` lands in `.config` before any
stamps are cleared.

---

## Adding a patch to a third-party package

Patches go under `patches/<pkgname>/`. Buildroot applies them in filename
order during the package's patch step.

```
patches/
  mesa3d/
    0001-...patch
    0004-...patch    ← new patch; filename sort order determines application order
  linux/
    0001-...patch
```

`BR2_GLOBAL_PATCH_DIR` in the build config points at the top-level `patches/`
directory, so Buildroot finds them automatically.

**Patch format gotcha — hunk line counts must be exact:**

The `@@ -a,b +c,d @@` counts must match the actual line counts in the hunk.
If the `+c,d` count is wrong (e.g. says 48 but the hunk has 52 lines),
`git apply` silently truncates the new file at line `d`. The truncated file
may still look correct at first glance but will fail later when a tool
tries to read it. Always verify with:

```sh
patch --dry-run -p1 < patches/<pkg>/<name>.patch
```

from inside the package's source tree, or generate the patch via `diff -u`
rather than writing it by hand.

**`.applied_patches_list` gotcha — never half-clear a patched package:**

Buildroot maintains `build/<pkg>-<ver>/.applied_patches_list` tracking which
patches have been applied. `pkgs-rebuild` clears `.stamp_*` files but does NOT
clear `.applied_patches_list`. If you clear stamps on an already-patched
package, Buildroot will try to re-patch and error with "duplicate filename".

Safe approach: when iterating on a patch for a third-party package, delete
the entire build directory before rebuilding:

```sh
rm -rf output/rg35xx-pro-launcher-mainline/build/mesa3d-26.0.5
make pkgs-rebuild PACKAGES="mesa3d" DEVICE=rg35xx-pro FLAVOR=launcher
```

The package tarball is cached in `third_party/buildroot/dl/`, so the
re-extract is fast (no network round-trip).

---

## Cheat sheet

| Goal | Command | Time |
|---|---|---|
| Full build | `make rg35xx-pro FLAVOR=launcher` | ~45 min cold |
| Rebuild one local package | `make pkg-rebuild PACKAGE=panicos-pht DEVICE=rg35xx-pro FLAVOR=pht` | 1-3 min |
| Rebuild several packages + pick up new defconfig entries | `make pkgs-rebuild PACKAGES="mesa3d sdl2" DEVICE=rg35xx-pro FLAVOR=launcher` | varies |
| Re-roll squashfs/image only | `make image-rebuild DEVICE=rg35xx-pro FLAVOR=launcher` | ~2 min |
| LPDDR3 variant (after any base change) | `make image-variant DEVICE=rg35xx-pro-lpddr3 BASE=rg35xx-pro FLAVOR=launcher` | ~5 min |
| Kernel only | `make pkg-rebuild PACKAGE=linux DEVICE=rg35xx-pro FLAVOR=launcher` | ~15 min |
| Mesa3d only (with clean dir) | `rm -rf output/.../build/mesa3d-*` then `pkgs-rebuild` | ~20 min |

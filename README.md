# PanicOS

Linux images for ARM handhelds. Buildroot-based.

## Quick start

```sh
git clone --recurse-submodules <repo-url> PanicOS
cd PanicOS
make harness-smoke   # smoke-test the build harness; ~30 min on first run
```

The output rootfs lands in `output/harness-smoke-minimal/images/rootfs.tar`.

## Interactive build (TUI)

If you don't want to memorize `make` flags, run:

```sh
make tui
```

The wizard walks through device → flavor → kernel and dispatches the
right build. It also includes a **Vendor Blob Extractor** submenu for
porting PanicOS to unsupported devices — see below.

## Porting to a new device with VBE

The Vendor Blob Extractor lets you pull the kernel, bootloader blobs, and
modules from a stock device SD card image and combine them with a PanicOS
rootfs to produce a flashable image for any ARM handheld.

Full walkthrough: [`docs/vbe-walkthrough.md`](docs/vbe-walkthrough.md)

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

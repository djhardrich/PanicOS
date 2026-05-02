# PanicOS Internal Notes

Build-time gotchas, vendor workflows, and other things that aren't user-facing
documentation but matter when working on the build system itself. Things in
README.md are for users / contributors; things here are for whoever maintains
the build pipeline.

---

## PHT vendoring (panicos-pht package)

The `panicos-pht` Buildroot package ships a prebuilt aarch64 PHT binary at
`/opt/pht/`. The binary comes from `vendor/pht/`, which is populated by
`scripts/vendor-pht.sh`.

### TL;DR

```
./scripts/vendor-pht.sh             # default: protected build, uses license-setup.sh port
./scripts/vendor-pht.sh --src ...   # dev override: vendor an unprotected dir as-is
```

Default mode is what you almost always want. `--src` is for debugging — for
example, when a license-protected binary is hiding a crash and you want to
verify the unprotected one behaves the same.

### Default flow (what `vendor-pht.sh` does)

1. cd into `$PHT_REPO` (default `~/prohandheldtracker-build`)
2. Verify `signing.key` exists. **DO NOT regenerate it.** It's the Ed25519
   signing key whose pubkey is baked (via cipher tables) into every protected
   PHT binary that has ever shipped. Regenerating invalidates every license
   that has ever been issued for any device.
3. Run `./scripts/license-setup.sh port`, piping `n` to the
   "Re-embed tables from existing key?" prompt — we want the tables matching
   the existing signing.key.
4. license-setup.sh port:
   - Cross-compiles `pht-app` for `aarch64-unknown-linux-gnu` with
     `--features protection`. The protection feature compiles in the cipher
     tables (and the runtime CRC check that detects table tampering),
     plus the gate that refuses to start without a valid `pht.lic` matching
     the device's HWID.
   - Best-effort cross for armv7 (we don't ship armv7).
   - Bundles `dist/pht-portmaster.zip` via `tools/make-port.sh`.
5. vendor-pht.sh extracts the freshly-built zip into `mktemp -d` and copies
   the relevant subtrees into `vendor/pht/`:
   - `bin/*-aarch64` (drops armv7 binaries)
   - `bin/yt-dlp.pyz`, `bin/copyparty-sfx.py` (arch-agnostic Python)
   - `plugins/`, `assets/`, `scripts/`, `libs-aarch64/` whole subtrees
6. The Buildroot package's `INSTALL_TARGET_CMDS` then `cp -a`s
   `vendor/pht/*` into `$(TARGET_DIR)/opt/pht/`.

### Why we trust the zip, not `dist/pht-portmaster/`

Both `dist/pht-portmaster.zip` and `dist/pht-portmaster/` may exist after
running license-setup.sh, but `make-port.sh` treats the zip as the canonical
output. The loose directory can lag, contain debris from a prior run, or
contain artifacts from a different target. Extracting the zip into a fresh
tempdir guarantees the source matches what license-setup.sh just produced.

### Why NOT vendor from `dist/stage/pht/`

`stage/` is the upstream PHT build's pre-bundle staging tree. Its
`bin/pht-aarch64` is whatever was last cross-compiled — by default, **without**
`--features protection`. A PanicOS image built from stage/ would ship a binary
that ignores `pht.lic` entirely. Don't.

(Note: as a side effect of running license-setup.sh port, `dist/stage/pht/`
also picks up the protected aarch64 build — but only because cross/cargo
overwrites the same target/ tree that stage/ pulls from. Don't rely on that.
Always go through the zip.)

### Why not just unzip `dist/pht-portmaster.zip` directly?

You can — `--src $(unzip-dir)/pht` works. The reason vendor-pht.sh re-runs
license-setup.sh by default is that the upstream PHT source tree is volatile
(the user is the upstream author and rebuilds frequently). Re-running ensures
the binary in vendor/pht/ is the binary that matches the current source +
current signing.key. If you know the zip is fresh and you want to skip the
~30-60s build, run `./scripts/vendor-pht.sh --src ~/prohandheldtracker-build/dist/pht-portmaster/pht`
manually after extracting.

### Don't compare md5s of binaries in vendor/ vs target/

`size vendor/pht/bin/pht-aarch64 target/opt/pht/bin/pht-aarch64` is the
right check, not md5sum. Buildroot's target-finalize stage strips section
headers and debug info from installed binaries, so the bytes (and md5)
differ between vendor/ and target/ even though the text/data/bss segments
are byte-identical and the code is the same. To verify a vendored payload
landed in the rootfs:

- `size` should match (text/data/bss bytes equal)
- `strings ... | grep <known-symbol>` should find expected strings
  (e.g. `license activated`, `hwid mismatch` for the protected pht build)

### Buildroot `cp -a` quirk: prefer dirclean for stale local-source pkgs

`panicos-pht.mk` installs via `cp -a $(PAYLOAD)/bin $(TARGET_DIR)/opt/pht/`.
When pkg-rebuild runs without dirclean, `cp -a` should overwrite existing
files but historically has had issues if the prior build left immutable
attrs or the file was strip'd to a different size. Symptoms: new image
rolled, but pht-aarch64 strings/size suggest old vendor.

Workaround: when in doubt, run `panicos-pht-dirclean` before
`panicos-pht-rebuild`:

```
docker run --rm --user 1000:1000 -v $(pwd):/work -w /work \
    -e IN_CONTAINER=1 -e HOME=/tmp panicos-build:<tag> sh -c '
        make -C /work/third_party/buildroot O=/work/output/<flavor> panicos-pht-dirclean
        make -C /work/third_party/buildroot O=/work/output/<flavor> panicos-pht
        rm -rf /work/output/<flavor>/build/buildroot-fs/{full,squashfs}/.stamp_*
        make -C /work/third_party/buildroot O=/work/output/<flavor>
'
```

`make pkg-rebuild PKG=panicos-pht` should mostly work but historically has
had issues with `.files-list.after: Permission denied` from the wrapper layer.
The above direct invocation is the reliable fallback.

---

## License signing for new devices

To activate PHT on a new handheld:

```bash
# On the device (or read /etc/machine-id directly):
pht --print-hwid
# → 64-char hex string

# On the build host, in $PHT_REPO:
cargo run -p pht-license --features tools --bin pht-license-keygen -- \
    --hwid <64-char-hex> \
    --name "User Name" --email "user@example.com" \
    --key-file ~/prohandheldtracker-build/signing.key \
    --out user.lic

# Deploy to the device at:
# $XDG_DATA_HOME/prohandheldtracker/pht.lic
# (typically /root/.local/share/prohandheldtracker/pht.lic on PanicOS,
#  since pht runs as root)
```

The `--key-file` MUST be the same `signing.key` that was used when license-setup.sh
embedded the cipher tables into the binary. If signing.key was rotated since
the user's binary was built, their license will fail validation.

---

## Build wrappers

- `make <device>` — full clean build of a flavor (30-45 min)
- `make pkg-rebuild PKG=<pkg> DEVICE=<dev>` — incremental rebuild of a single
  package + image reroll (~3-5 min). Has occasional `.files-list` permission
  glitches; falls back to direct buildroot invocation (see PHT section).
- `make image-rebuild DEVICE=<dev>` — re-roll only the image (no package
  rebuilds), ~1-2 min
- `scripts/panicos-tui.sh` — interactive TUI wrapping all of the above with
  flavor enumeration

Default `FLAVOR` is `minimal`; pass `FLAVOR=pht` or `FLAVOR=launcher` etc.

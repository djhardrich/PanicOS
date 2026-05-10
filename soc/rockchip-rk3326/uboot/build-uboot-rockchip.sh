#!/usr/bin/env bash
# Assemble a Rockchip combined u-boot.bin for RK3326 using ROCKNIX's
# proven build flow. Called from board/anbernic/rk3326-{a,b}/post-image.sh.
#
# Why we do this instead of letting Buildroot/binman produce u-boot-rockchip.bin:
#   The mainline binman layout for RK3326 in U-Boot v2025.10 produces a
#   bootloader that BootROM does not accept on real RK3326 handhelds (e.g.
#   gameconsole-eeclone — device powers off, no power LED). ROCKNIX uses a
#   simpler Rockchip-format combined image built from rkbin blobs + a tiny
#   u-boot-dtb.bin, which BootROM accepts. See ROCKNIX
#   projects/ROCKNIX/bootloader/rkhelper for the upstream of this script.
#
# Inputs (positional environment, set by caller):
#   BUILD_DIR     — Buildroot build directory
#   BINARIES_DIR  — Buildroot output/images directory
#
# Output:
#   $BINARIES_DIR/uboot.bin  (sparse-ish file; idbloader at sector 0 of file,
#                             uboot.img at sector 16320, trust.img at 24512.
#                             Written to disk at sector 64 by genimage.)

set -euo pipefail

: "${BUILD_DIR:?BUILD_DIR not set}"
: "${BINARIES_DIR:?BINARIES_DIR not set}"

RKBIN_DIR=$(echo "${BUILD_DIR}"/rockchip-rkbin-* | awk '{print $1}')
[ -d "$RKBIN_DIR" ] || { echo "error: rkbin not at ${BUILD_DIR}/rockchip-rkbin-*" >&2; exit 1; }

UBOOT_BUILD_DIR="${BUILD_DIR}/uboot-custom"
UBOOT_DTB_BIN="${UBOOT_BUILD_DIR}/u-boot-dtb.bin"
[ -f "$UBOOT_DTB_BIN" ] || { echo "error: u-boot-dtb.bin missing at $UBOOT_DTB_BIN" >&2; exit 1; }

MKIMAGE="${UBOOT_BUILD_DIR}/tools/mkimage"
LOADERIMAGE="${RKBIN_DIR}/tools/loaderimage"
TRUST_MERGER="${RKBIN_DIR}/tools/trust_merger"

DDR_BIN="${RKBIN_DIR}/bin/rk33/rk3326_ddr_333MHz_v2.11.bin"
MINILOADER="${RKBIN_DIR}/bin/rk33/rk3326_miniloader_v1.40.bin"
BL31_ELF="${RKBIN_DIR}/bin/rk33/rk3326_bl31_v1.34.elf"

for f in "$MKIMAGE" "$LOADERIMAGE" "$TRUST_MERGER" "$DDR_BIN" "$MINILOADER" "$BL31_ELF"; do
    [ -f "$f" ] || { echo "error: missing input $f" >&2; exit 1; }
done

WORK="${BINARIES_DIR}/uboot.work"
rm -rf "$WORK" && mkdir -p "$WORK"
cd "$WORK"

# 1. idbloader.img: mkimage rksd of DDR blob + appended miniloader.
#    rk3326's mkimage -T rksd needs -n px30 (the chip family that includes RK3326).
"$MKIMAGE" -n px30 -T rksd -d "$DDR_BIN" -C bzip2 idbloader.img
cat "$MINILOADER" >> idbloader.img

# 2. uboot.img: Rockchip-format wrap of u-boot-dtb.bin loaded at 0x00200000.
"$LOADERIMAGE" --pack --uboot "$UBOOT_DTB_BIN" uboot.img 0x00200000

# 3. trust.img: bl31 wrapped at addr 0x00010000.
cat > trust.ini <<EOF
[VERSION]
MAJOR=1
MINOR=0
[BL30_OPTION]
SEC=0
[BL31_OPTION]
SEC=1
PATH=${BL31_ELF}
ADDR=0x00010000
[BL32_OPTION]
SEC=0
[BL33_OPTION]
SEC=0
[OUTPUT]
PATH=trust.img
EOF
"$TRUST_MERGER" --verbose trust.ini >/dev/null

# 4. Combine: idbloader at file sector 0, uboot.img at 16320, trust.img at 24512.
#    When this file is written at disk sector 64 (32K offset) by genimage,
#    uboot.img lands at disk sector 16384 (8 MiB) and trust.img at 24576
#    (12 MiB) — the offsets the rkbin miniloader expects.
> uboot.bin
dd if=idbloader.img of=uboot.bin bs=512 seek=0     conv=notrunc status=none
dd if=uboot.img    of=uboot.bin bs=512 seek=16320 conv=notrunc status=none
dd if=trust.img    of=uboot.bin bs=512 seek=24512 conv=notrunc status=none

mv uboot.bin "${BINARIES_DIR}/uboot.bin"
cd "$BINARIES_DIR"
rm -rf "$WORK"

echo ">>> assembled uboot.bin: $(stat -c %s "${BINARIES_DIR}/uboot.bin") bytes"

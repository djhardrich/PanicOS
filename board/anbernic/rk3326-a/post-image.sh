#!/usr/bin/env bash
# Buildroot post-image for RK3326-a (legacy-device variant, mainline U-Boot).
# Devices: OGA, OGS (ODROID-GO Super), RG351M, RG351V, R33S, XU10, Chi.
#
# Uses mainline U-Boot v2025.10 (fully supports these SoCs) with a_boot.scr
# for ADC-based DTB selection. Same binary as rk3326-b; only boot.scr differs.
#
# Boot flow: U-Boot → boot.scr (ADC-based DTB select) → extlinux/ → kernel.

set -euo pipefail

shift  # drop BINARIES_DIR arg; use the env var.
GENIMAGE_TEMPLATE="$1"
: "${BINARIES_DIR:?BINARIES_DIR not set by Buildroot}"
BOARD_DIR="$(dirname "$0")"
SOC="rockchip-rk3326"
VARIANT="a"

read_kconfig() {
    local key="$1" def="$2"
    grep "^${key}=" "$BR2_CONFIG" | head -1 | cut -d= -f2- | tr -d '"' || echo "$def"
}

echo ">>> post-image: assembling RK3326-a disk image"

# Verify u-boot-rockchip.bin
if [ ! -f "$BINARIES_DIR/u-boot-rockchip.bin" ]; then
    UBOOT_BUILD_DIR="${BUILD_DIR:-$(dirname "$BINARIES_DIR")/build}/uboot-custom"
    if [ -f "$UBOOT_BUILD_DIR/u-boot-rockchip.bin" ]; then
        cp "$UBOOT_BUILD_DIR/u-boot-rockchip.bin" "$BINARIES_DIR/"
    else
        echo "error: u-boot-rockchip.bin not found" >&2
        exit 1
    fi
fi

# Compile a_boot.ini → boot.scr.
MKIMAGE=""
for candidate in \
    "${HOST_DIR:-}/bin/mkimage" \
    "$(find "${BUILD_DIR:-$(dirname "$BINARIES_DIR")/build}" -name mkimage -path "*/uboot-custom/*" 2>/dev/null | head -1)"; do
    if [ -x "$candidate" ]; then
        MKIMAGE="$candidate"
        break
    fi
done

BOOT_INI="$BR2_EXTERNAL_PANICOS_PATH/board/anbernic/rk3326-a/a_boot.ini"
if [ -z "$MKIMAGE" ]; then
    echo "error: mkimage not found; cannot compile boot.scr" >&2
    exit 1
fi
"$MKIMAGE" -T script -d "$BOOT_INI" "$BINARIES_DIR/boot.scr"
echo ">>> compiled a_boot.ini → boot.scr"

# Place all RK3326 DTBs in dtbs/ (no rockchip/ prefix — FDTDIR /dtbs/).
mkdir -p "$BINARIES_DIR/dtbs"
cp "$BINARIES_DIR"/rk3326-*.dtb "$BINARIES_DIR/dtbs/" 2>/dev/null || true
echo ">>> copied $(ls "$BINARIES_DIR/dtbs/" | wc -l) DTBs to dtbs/"

# extlinux.conf: FDTDIR /dtbs/ lets U-Boot resolve $fdtfile set by boot.scr.
mkdir -p "$BINARIES_DIR/extlinux"
cat > "$BINARIES_DIR/extlinux/extlinux.conf" <<'EOF'
LABEL PanicOS
  LINUX /Image
  FDTDIR /dtbs/
  APPEND console=ttyS2,1500000 console=tty1 quiet loglevel=3 panic=0 pause_on_oops=300
EOF

cp "$BOARD_DIR/panicos-active.cfg" "$BINARIES_DIR/panicos-active.cfg"

GITREV="$(git -C "$BR2_EXTERNAL_PANICOS_PATH" describe --always --dirty 2>/dev/null || echo unknown)"
FLAVOR="$(read_kconfig PANICOS_FLAVOR_NAME minimal)"
export PANICOS_OUTPUT_NAME="panicos-rk3326-a-${FLAVOR}"
cp "$BINARIES_DIR/rootfs.squashfs" "$BINARIES_DIR/${PANICOS_OUTPUT_NAME}.squashfs"

sed -i "s|^IMAGE=.*|IMAGE=${PANICOS_OUTPUT_NAME}.squashfs|" "$BINARIES_DIR/panicos-active.cfg"

cp "$BR2_EXTERNAL_PANICOS_PATH/package/panicos-wifi-config/panicos-wifi.cfg.template" \
   "$BINARIES_DIR/panicos-wifi.cfg"

export PANICOS_BOOT_PARTITION_SIZE_MB="$(read_kconfig PANICOS_BOOT_PARTITION_SIZE_MB 6144)"
export PANICOS_STORAGE_PARTITION_INITIAL_SIZE_MB="$(read_kconfig PANICOS_STORAGE_PARTITION_INITIAL_SIZE_MB 64)"

GENIMAGE_CFG="$BINARIES_DIR/genimage.cfg"
envsubst < "$GENIMAGE_TEMPLATE" > "$GENIMAGE_CFG"

GENIMAGE_TMP="$BINARIES_DIR/genimage.tmp"
GENIMAGE_ROOT="$BINARIES_DIR/genimage.root"
rm -rf "$GENIMAGE_TMP" "$GENIMAGE_ROOT"
mkdir -p "$GENIMAGE_ROOT"
genimage \
    --rootpath "$GENIMAGE_ROOT" \
    --tmppath "$GENIMAGE_TMP" \
    --inputpath "$BINARIES_DIR" \
    --outputpath "$BINARIES_DIR" \
    --config "$GENIMAGE_CFG"

mv "$BINARIES_DIR/${PANICOS_OUTPUT_NAME}.img" \
   "$BINARIES_DIR/${PANICOS_OUTPUT_NAME}-$GITREV.img"
gzip -f -9 "$BINARIES_DIR/${PANICOS_OUTPUT_NAME}-$GITREV.img"

echo ">>> post-image done: $BINARIES_DIR/${PANICOS_OUTPUT_NAME}-$GITREV.img.gz"

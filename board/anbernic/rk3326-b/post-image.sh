#!/usr/bin/env bash
# Buildroot post-image for RK3326-b (mainline U-Boot variant).
# Devices: Powkiddy RGB10X, MagicX XU-Mini-M, GameConsole EEClone.
#
# Boot flow: U-Boot → boot.scr (ADC-based DTB select) → extlinux/ → kernel.
# DTBs live at the FAT root; extlinux.conf uses FDTDIR / (matching ROCKNIX)
# so U-Boot resolves the DTB using the $fdtfile env set by boot.scr.

set -euo pipefail

shift  # drop BINARIES_DIR arg; use the env var.
GENIMAGE_TEMPLATE="$1"
: "${BINARIES_DIR:?BINARIES_DIR not set by Buildroot}"
BOARD_DIR="$(dirname "$0")"
SOC="rockchip-rk3326"
VARIANT="b"

read_kconfig() {
    local key="$1" def="$2"
    grep "^${key}=" "$BR2_CONFIG" | head -1 | cut -d= -f2- | tr -d '"' || echo "$def"
}

echo ">>> post-image: assembling RK3326-b disk image"

# Assemble uboot.bin via the ROCKNIX-style rkhelper flow. Mainline binman
# u-boot-rockchip.bin does not boot on real RK3326 handhelds; see
# soc/rockchip-rk3326/uboot/build-uboot-rockchip.sh for the why.
: "${BUILD_DIR:?BUILD_DIR not set by Buildroot}"
BUILD_DIR="$BUILD_DIR" BINARIES_DIR="$BINARIES_DIR" \
    "$BR2_EXTERNAL_PANICOS_PATH/soc/rockchip-rk3326/uboot/build-uboot-rockchip.sh"

# Compile b_boot.ini → boot.scr using mkimage from the U-Boot build.
# mkimage is built as part of the U-Boot tools target.
MKIMAGE=""
for candidate in \
    "${HOST_DIR:-}/bin/mkimage" \
    "$(find "${BUILD_DIR:-$(dirname "$BINARIES_DIR")/build}" -type f -name mkimage -path "*/uboot-custom/*" 2>/dev/null | head -1)"; do
    if [ -x "$candidate" ] && [ -f "$candidate" ]; then
        MKIMAGE="$candidate"
        break
    fi
done

BOOT_INI="$BR2_EXTERNAL_PANICOS_PATH/board/anbernic/rk3326-b/b_boot.ini"
if [ -z "$MKIMAGE" ]; then
    echo "error: mkimage not found; cannot compile boot.scr" >&2
    exit 1
fi
"$MKIMAGE" -T script -d "$BOOT_INI" "$BINARIES_DIR/boot.scr"
echo ">>> compiled b_boot.ini → boot.scr"

# Build the DTB file list for genimage (DTBs sit at FAT root, FDTDIR /).
# Kernel places rk3326-*.dtb directly in BINARIES_DIR; enumerate them now
# so envsubst can inject the list into genimage.cfg.in.
PANICOS_DTB_FILES=""
for _dtb in "$BINARIES_DIR"/rk3326-*.dtb; do
    [ -f "$_dtb" ] || continue
    PANICOS_DTB_FILES="${PANICOS_DTB_FILES}			\"$(basename "$_dtb")\","$'\n'
done
export PANICOS_DTB_FILES
echo ">>> found $(echo "$PANICOS_DTB_FILES" | grep -c '"') DTBs for FAT root"

# extlinux.conf: FDTDIR / matches ROCKNIX layout (DTBs at FAT root).
mkdir -p "$BINARIES_DIR/extlinux"
cat > "$BINARIES_DIR/extlinux/extlinux.conf" <<'EOF'
LABEL PanicOS
  LINUX /Image
  FDTDIR /
  FDTOVERLAYS /overlays/mipi-panel.dtbo
  APPEND console=ttyS2,1500000 console=tty1 quiet loglevel=3 panic=0 pause_on_oops=300
EOF

cp "$BOARD_DIR/panicos-active.cfg" "$BINARIES_DIR/panicos-active.cfg"

GITREV="$(git -C "$BR2_EXTERNAL_PANICOS_PATH" describe --always --dirty 2>/dev/null || echo unknown)"
FLAVOR="$(read_kconfig PANICOS_FLAVOR_NAME minimal)"
export PANICOS_OUTPUT_NAME="panicos-rk3326-b-${FLAVOR}"
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

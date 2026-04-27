# U-Boot source for the Allwinner H700 mainline flavor.
# Translated from third_party/rocknix/projects/ROCKNIX/devices/H700/packages/u-boot/package.mk
# at the pinned ROCKNIX SHA (see soc/allwinner-h700/source.manifest), with
# additional content cherry-picked from ROCKNIX commit 8d65b60 (LPDDR3 split).
PANICOS_UBOOT_VERSION := v2026.01
PANICOS_UBOOT_SITE := https://github.com/u-boot/u-boot/archive
PANICOS_UBOOT_SOURCE_TARBALL := $(PANICOS_UBOOT_VERSION).tar.gz
PANICOS_UBOOT_HASH := sha256:03bb43c58d2343ee48dd191e0f181f0108425b179d84519add3a977071c3f654

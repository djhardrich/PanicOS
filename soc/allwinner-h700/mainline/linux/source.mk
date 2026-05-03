# Linux mainline source for the Allwinner H700.
# Translated from third_party/rocknix/projects/ROCKNIX/packages/linux/package.mk
# at the pinned ROCKNIX SHA (see soc/allwinner-h700/source.manifest).
PANICOS_LINUX_VERSION := 7.0.2
PANICOS_LINUX_SITE := https://www.kernel.org/pub/linux/kernel/v7.x
PANICOS_LINUX_SOURCE_TARBALL := linux-$(PANICOS_LINUX_VERSION).tar.xz
# Verify hash before commit:
#   curl -s https://www.kernel.org/pub/linux/kernel/v7.x/sha256sums.asc | grep linux-7.0.2.tar.xz
PANICOS_LINUX_HASH := sha256:53591a03294527a48ccb0b9e559e922df8a38554745a1206827ca751d2ca7662

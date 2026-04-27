# Linux mainline source for the Allwinner H700.
# Translated from third_party/rocknix/projects/ROCKNIX/packages/linux/package.mk
# at the pinned ROCKNIX SHA (see soc/allwinner-h700/source.manifest).
PANICOS_LINUX_VERSION := 7.0.1
PANICOS_LINUX_SITE := https://www.kernel.org/pub/linux/kernel/v7.x
PANICOS_LINUX_SOURCE_TARBALL := linux-$(PANICOS_LINUX_VERSION).tar.xz
# Verify hash before commit:
#   curl -s https://www.kernel.org/pub/linux/kernel/v7.x/sha256sums.asc | grep linux-7.0.1.tar.xz
PANICOS_LINUX_HASH := sha256:b2c935a36d24980e11e59bed3ca558ea6d67619ec0065faa335cdc0b64d887bf

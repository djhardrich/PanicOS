################################################################################
#
# panicos-rtl8852bs
#
# Out-of-tree Realtek RTL8852BS SDIO WiFi kernel module.
# Used by the TrimUI Brick (Allwinner A133) with the mainline kernel.
# The WiFi chip is an AW859A (Allwinner part number for RTL8852BS).
#
# With the vendor kernel (4.9.191): WiFi is handled by the sunxi SDIO
# framework baked into the kernel blob — this package is NOT needed.
#
# With the mainline kernel: the in-tree rtw89 driver supports RTL8852B
# over PCIe/USB but not the SDIO variant. This out-of-tree driver fills
# the gap until SDIO support is upstreamed into rtw89.
#
# Firmware: rtl8852b_fw.bin is provided by linux-firmware (already in
# BR2_PACKAGE_LINUX_FIRMWARE_RTL_RTW88 selected by the mainline fragment).
#
################################################################################

PANICOS_RTL8852BS_VERSION = 89d53901ef9e5f3d5ec4048a60b43ba8af68de06
PANICOS_RTL8852BS_SITE = https://github.com/lwfinger/rtl8852bs.git
PANICOS_RTL8852BS_SITE_METHOD = git

PANICOS_RTL8852BS_LICENSE = GPL-2.0
PANICOS_RTL8852BS_LICENSE_FILES = LICENSE

PANICOS_RTL8852BS_MODULE_MAKE_OPTS = \
	KVER=$(LINUX_VERSION_PROBED) \
	CONFIG_RTW89=m

$(eval $(kernel-module))
$(eval $(generic-package))

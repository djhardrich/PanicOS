################################################################################
#
# panicos-launcher-tools
#
################################################################################

PANICOS_LAUNCHER_TOOLS_VERSION = 1.0
PANICOS_LAUNCHER_TOOLS_SITE = $(BR2_EXTERNAL_PANICOS_PATH)/package/panicos-launcher-tools
PANICOS_LAUNCHER_TOOLS_SITE_METHOD = local
PANICOS_LAUNCHER_TOOLS_LICENSE = GPL-2.0
PANICOS_LAUNCHER_TOOLS_DEPENDENCIES = curl

define PANICOS_LAUNCHER_TOOLS_INSTALL_TARGET_CMDS
	mkdir -p $(TARGET_DIR)/usr/share/panicos-launcher/tools
	$(INSTALL) -m 0755 $(PANICOS_LAUNCHER_TOOLS_PKGDIR)/files/Install.PortMaster.sh \
		$(TARGET_DIR)/usr/share/panicos-launcher/tools/Install.PortMaster.sh
endef

$(eval $(generic-package))

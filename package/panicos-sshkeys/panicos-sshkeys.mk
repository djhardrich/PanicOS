################################################################################
#
# panicos-sshkeys
#
################################################################################

PANICOS_SSHKEYS_VERSION = 1.0
PANICOS_SSHKEYS_SITE = $(BR2_EXTERNAL_PANICOS_PATH)/package/panicos-sshkeys
PANICOS_SSHKEYS_SITE_METHOD = local
PANICOS_SSHKEYS_LICENSE = GPL-2.0
PANICOS_SSHKEYS_DEPENDENCIES = dropbear

define PANICOS_SSHKEYS_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(PANICOS_SSHKEYS_PKGDIR)/panicos-sshkeys.sh \
		$(TARGET_DIR)/usr/sbin/panicos-sshkeys
endef

define PANICOS_SSHKEYS_INSTALL_INIT_SYSTEMD
	$(INSTALL) -D -m 0644 $(PANICOS_SSHKEYS_PKGDIR)/panicos-sshkeys.service \
		$(TARGET_DIR)/usr/lib/systemd/system/panicos-sshkeys.service
	mkdir -p $(TARGET_DIR)/usr/lib/systemd/system/sysinit.target.wants
	ln -sf ../panicos-sshkeys.service \
		$(TARGET_DIR)/usr/lib/systemd/system/sysinit.target.wants/panicos-sshkeys.service
endef

$(eval $(generic-package))

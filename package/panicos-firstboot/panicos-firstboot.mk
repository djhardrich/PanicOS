################################################################################
#
# panicos-firstboot
#
################################################################################

PANICOS_FIRSTBOOT_VERSION = 1.0
PANICOS_FIRSTBOOT_SITE = $(BR2_EXTERNAL_PANICOS_PATH)/package/panicos-firstboot
PANICOS_FIRSTBOOT_SITE_METHOD = local
PANICOS_FIRSTBOOT_LICENSE = GPL-2.0
PANICOS_FIRSTBOOT_DEPENDENCIES = util-linux e2fsprogs

define PANICOS_FIRSTBOOT_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(PANICOS_FIRSTBOOT_PKGDIR)/panicos-firstboot.sh \
		$(TARGET_DIR)/usr/sbin/panicos-firstboot
endef

define PANICOS_FIRSTBOOT_INSTALL_INIT_SYSTEMD
	$(INSTALL) -D -m 0644 $(PANICOS_FIRSTBOOT_PKGDIR)/panicos-firstboot.service \
		$(TARGET_DIR)/usr/lib/systemd/system/panicos-firstboot.service
	mkdir -p $(TARGET_DIR)/usr/lib/systemd/system/sysinit.target.wants
	ln -sf ../panicos-firstboot.service \
		$(TARGET_DIR)/usr/lib/systemd/system/sysinit.target.wants/panicos-firstboot.service
endef

$(eval $(generic-package))

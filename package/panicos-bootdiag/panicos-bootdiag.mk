################################################################################
#
# panicos-bootdiag
#
################################################################################

PANICOS_BOOTDIAG_VERSION = 1.0
PANICOS_BOOTDIAG_SITE = $(BR2_EXTERNAL_PANICOS_PATH)/package/panicos-bootdiag
PANICOS_BOOTDIAG_SITE_METHOD = local
PANICOS_BOOTDIAG_LICENSE = GPL-2.0
# util-linux for lsblk; iproute2 for ip; the rest is shell + systemd.
PANICOS_BOOTDIAG_DEPENDENCIES = util-linux iproute2 systemd

define PANICOS_BOOTDIAG_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(PANICOS_BOOTDIAG_PKGDIR)/panicos-bootdiag.sh \
		$(TARGET_DIR)/usr/sbin/panicos-bootdiag
endef

define PANICOS_BOOTDIAG_INSTALL_INIT_SYSTEMD
	$(INSTALL) -D -m 0644 $(PANICOS_BOOTDIAG_PKGDIR)/panicos-bootdiag.service \
		$(TARGET_DIR)/usr/lib/systemd/system/panicos-bootdiag.service
	mkdir -p $(TARGET_DIR)/usr/lib/systemd/system/multi-user.target.wants
	ln -sf ../panicos-bootdiag.service \
		$(TARGET_DIR)/usr/lib/systemd/system/multi-user.target.wants/panicos-bootdiag.service
endef

$(eval $(generic-package))

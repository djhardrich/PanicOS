################################################################################
#
# panicos-autologin
#
################################################################################

PANICOS_AUTOLOGIN_VERSION = 1.0
PANICOS_AUTOLOGIN_SITE = $(BR2_EXTERNAL_PANICOS_PATH)/package/panicos-autologin
PANICOS_AUTOLOGIN_SITE_METHOD = local
PANICOS_AUTOLOGIN_LICENSE = GPL-2.0

define PANICOS_AUTOLOGIN_INSTALL_INIT_SYSTEMD
	$(INSTALL) -D -m 0644 $(PANICOS_AUTOLOGIN_PKGDIR)/getty-tty1-autologin.conf \
		$(TARGET_DIR)/etc/systemd/system/getty@tty1.service.d/autologin.conf
endef

$(eval $(generic-package))

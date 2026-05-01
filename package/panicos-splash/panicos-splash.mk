################################################################################
#
# panicos-splash
#
################################################################################

PANICOS_SPLASH_VERSION = 1.0
PANICOS_SPLASH_SITE = $(BR2_EXTERNAL_PANICOS_PATH)/package/panicos-splash
PANICOS_SPLASH_SITE_METHOD = local
PANICOS_SPLASH_LICENSE = GPL-2.0
PANICOS_SPLASH_DEPENDENCIES = fbv

define PANICOS_SPLASH_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(PANICOS_SPLASH_PKGDIR)/panicos-splash.sh \
		$(TARGET_DIR)/usr/sbin/panicos-splash
	mkdir -p $(TARGET_DIR)/opt/panicos-splash
	cp $(PANICOS_SPLASH_PKGDIR)/payload/splash-640x480.png \
		$(TARGET_DIR)/opt/panicos-splash/splash-640x480.png
	cp $(PANICOS_SPLASH_PKGDIR)/payload/splash-1024x768.png \
		$(TARGET_DIR)/opt/panicos-splash/splash-1024x768.png
endef

define PANICOS_SPLASH_INSTALL_INIT_SYSTEMD
	$(INSTALL) -D -m 0644 $(PANICOS_SPLASH_PKGDIR)/panicos-splash.service \
		$(TARGET_DIR)/usr/lib/systemd/system/panicos-splash.service
	mkdir -p $(TARGET_DIR)/usr/lib/systemd/system/sysinit.target.wants
	ln -sf ../panicos-splash.service \
		$(TARGET_DIR)/usr/lib/systemd/system/sysinit.target.wants/panicos-splash.service
endef

$(eval $(generic-package))

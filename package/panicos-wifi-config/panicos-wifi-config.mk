################################################################################
#
# panicos-wifi-config
#
################################################################################

PANICOS_WIFI_CONFIG_VERSION = 1.0
PANICOS_WIFI_CONFIG_SITE = $(BR2_EXTERNAL_PANICOS_PATH)/package/panicos-wifi-config
PANICOS_WIFI_CONFIG_SITE_METHOD = local
PANICOS_WIFI_CONFIG_LICENSE = GPL-2.0
PANICOS_WIFI_CONFIG_DEPENDENCIES = wpa_supplicant systemd

define PANICOS_WIFI_CONFIG_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(PANICOS_WIFI_CONFIG_PKGDIR)/panicos-wifi-config.sh \
		$(TARGET_DIR)/usr/sbin/panicos-wifi-config
	$(INSTALL) -D -m 0644 $(PANICOS_WIFI_CONFIG_PKGDIR)/wlan0.network \
		$(TARGET_DIR)/etc/systemd/network/30-wlan0.network
endef

define PANICOS_WIFI_CONFIG_INSTALL_INIT_SYSTEMD
	$(INSTALL) -D -m 0644 $(PANICOS_WIFI_CONFIG_PKGDIR)/panicos-wifi-config.service \
		$(TARGET_DIR)/usr/lib/systemd/system/panicos-wifi-config.service
	$(INSTALL) -D -m 0644 $(PANICOS_WIFI_CONFIG_PKGDIR)/wpa_supplicant-runtime-conf.conf \
		$(TARGET_DIR)/etc/systemd/system/wpa_supplicant@.service.d/runtime-conf.conf
	mkdir -p $(TARGET_DIR)/usr/lib/systemd/system/sysinit.target.wants
	ln -sf ../panicos-wifi-config.service \
		$(TARGET_DIR)/usr/lib/systemd/system/sysinit.target.wants/panicos-wifi-config.service
	# Auto-enable wpa_supplicant for the wifi interface. Every handheld
	# kernel we currently use (sunxi-mainline, rk3566-mainline,
	# a133-vendor) names it wlan0. A future SoC whose kernel uses
	# systemd predictable names (wlpXsY) overrides this by dropping its
	# own wpa_supplicant@<iface>.service .wants symlink in its
	# soc/<soc>/<kernel>/rootfs-overlay/ and removing this one.
	mkdir -p $(TARGET_DIR)/usr/lib/systemd/system/multi-user.target.wants
	ln -sf ../wpa_supplicant@.service \
		$(TARGET_DIR)/usr/lib/systemd/system/multi-user.target.wants/wpa_supplicant@wlan0.service
endef

$(eval $(generic-package))

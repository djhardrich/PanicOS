################################################################################
#
# panicos-sway
#
# Kiosk-mode sway config + systemd unit for PanicOS launcher flavors.
# Sway acts as the display manager; ES (or other foreground app) runs
# as a Wayland client that sway composes onto the panel.
#
################################################################################

PANICOS_SWAY_VERSION = 1.0
PANICOS_SWAY_SITE = $(PANICOS_SWAY_PKGDIR)/files
PANICOS_SWAY_SITE_METHOD = local
PANICOS_SWAY_LICENSE = MIT
PANICOS_SWAY_DEPENDENCIES = sway

define PANICOS_SWAY_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0644 $(@D)/panicos-kiosk.conf \
		$(TARGET_DIR)/etc/sway/panicos-kiosk.conf
	$(INSTALL) -D -m 0755 $(@D)/sway-launch.sh \
		$(TARGET_DIR)/usr/bin/panicos-sway-launch
	# /var/run/0-runtime-dir is the XDG_RUNTIME_DIR sway expects (matches
	# ROCKNIX so vendored scripts that reference it work). systemd-tmpfiles
	# creates it on every boot.
	$(INSTALL) -D -m 0644 $(@D)/panicos-sway.tmpfiles \
		$(TARGET_DIR)/usr/lib/tmpfiles.d/panicos-sway.conf
endef

define PANICOS_SWAY_INSTALL_INIT_SYSTEMD
	$(INSTALL) -D -m 0644 $(@D)/panicos-sway.service \
		$(TARGET_DIR)/usr/lib/systemd/system/panicos-sway.service
	mkdir -p $(TARGET_DIR)/usr/lib/systemd/system/multi-user.target.wants
	ln -sf ../panicos-sway.service \
		$(TARGET_DIR)/usr/lib/systemd/system/multi-user.target.wants/panicos-sway.service
endef

$(eval $(generic-package))

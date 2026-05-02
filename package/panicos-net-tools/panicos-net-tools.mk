################################################################################
#
# panicos-net-tools
#
# Vendored ROCKNIX network + bluetooth backend scripts that ES shells
# out to. See third_party/rocknix submodule for upstream sources.
#
################################################################################

PANICOS_NET_TOOLS_VERSION = 1.0
PANICOS_NET_TOOLS_SITE = $(PANICOS_NET_TOOLS_PKGDIR)/files
PANICOS_NET_TOOLS_SITE_METHOD = local
PANICOS_NET_TOOLS_LICENSE = GPL-2.0
PANICOS_NET_TOOLS_DEPENDENCIES = bash iwd bluez5_utils

define PANICOS_NET_TOOLS_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/wifictl              $(TARGET_DIR)/usr/bin/wifictl
	$(INSTALL) -D -m 0755 $(@D)/rocknix-bluetooth    $(TARGET_DIR)/usr/bin/rocknix-bluetooth
	$(INSTALL) -D -m 0755 $(@D)/rocknix-bluetooth-agent $(TARGET_DIR)/usr/bin/rocknix-bluetooth-agent
	# get_setting/set_setting + friends, sourced from /etc/profile.
	# Renamed slightly so it doesn't collide if upstream ROCKNIX is
	# layered on top later.
	$(INSTALL) -D -m 0644 $(@D)/profile.d/001-functions \
		$(TARGET_DIR)/etc/profile.d/001-panicos-functions.sh
	# Default settings store. 001-functions seeds it onto /storage
	# on first boot if /storage/.config/system/configs/system.cfg
	# doesn't exist.
	$(INSTALL) -D -m 0644 $(@D)/system.cfg \
		$(TARGET_DIR)/usr/config/system/configs/system.cfg
endef

define PANICOS_NET_TOOLS_INSTALL_INIT_SYSTEMD
	$(INSTALL) -D -m 0644 $(@D)/system.d/bluetooth-agent.service \
		$(TARGET_DIR)/usr/lib/systemd/system/bluetooth-agent.service
	# bluetooth-agent.service has WantedBy=bluetooth.service, so
	# enable that unit's wants dir so the agent comes up alongside
	# bluetoothd. Also enable bluetooth.service + iwd.service so
	# the backends actually run on boot.
	mkdir -p $(TARGET_DIR)/usr/lib/systemd/system/bluetooth.service.wants
	ln -sf ../bluetooth-agent.service \
		$(TARGET_DIR)/usr/lib/systemd/system/bluetooth.service.wants/bluetooth-agent.service
	mkdir -p $(TARGET_DIR)/usr/lib/systemd/system/multi-user.target.wants
	ln -sf ../bluetooth.service \
		$(TARGET_DIR)/usr/lib/systemd/system/multi-user.target.wants/bluetooth.service
	ln -sf ../iwd.service \
		$(TARGET_DIR)/usr/lib/systemd/system/multi-user.target.wants/iwd.service
endef

$(eval $(generic-package))

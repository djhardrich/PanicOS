################################################################################
#
# panicos-quirks
#
# Vendored ROCKNIX hardware quirks system. See Config.in for full design.
#
# Layout in target:
#   /usr/lib/autostart/quirks/{autostart,devices,platforms,system.d}/  ← quirk scripts
#   /etc/profile.d/045-hw-device.sh         ← derives HW_DEVICE from DT
#   /etc/profile.d/002-autostart.sh         ← sets QUIRK_DEVICE from DT model
#   /etc/profile.d/999-quirks-export.sh     ← exports DEVICE_* vars
#   /usr/bin/autostart                      ← runner
#   /usr/bin/daemons                        ← (whatever ROCKNIX does with this)
#   /usr/lib/systemd/system/panicos-quirks-autostart.service
#   /usr/lib/systemd/system/{led-poweroff,volume-fixup}.service
#
################################################################################

PANICOS_QUIRKS_VERSION = 1.0
PANICOS_QUIRKS_SITE = $(BR2_EXTERNAL_PANICOS_PATH)/package/panicos-quirks
PANICOS_QUIRKS_SITE_METHOD = local
PANICOS_QUIRKS_LICENSE = GPL-2.0
PANICOS_QUIRKS_DEPENDENCIES = bash

define PANICOS_QUIRKS_INSTALL_TARGET_CMDS
	# 1. Quirks tree → /usr/lib/autostart/quirks/{autostart,devices,platforms,system.d}/
	#    cp -a preserves the +x bits on quirk scripts (they're executable).
	mkdir -p $(TARGET_DIR)/usr/lib/autostart/quirks
	cp -a $(PANICOS_QUIRKS_PKGDIR)/files/autostart   $(TARGET_DIR)/usr/lib/autostart/quirks/
	cp -a $(PANICOS_QUIRKS_PKGDIR)/files/devices     $(TARGET_DIR)/usr/lib/autostart/quirks/
	cp -a $(PANICOS_QUIRKS_PKGDIR)/files/platforms   $(TARGET_DIR)/usr/lib/autostart/quirks/
	# system.d (led-poweroff.service, volume-fixup.service) — ship as-is to
	# /usr/lib/systemd/system/ so they're available; not enabled by default.
	$(INSTALL) -D -m 0644 $(PANICOS_QUIRKS_PKGDIR)/files/system.d/led-poweroff.service \
		$(TARGET_DIR)/usr/lib/systemd/system/led-poweroff.service
	$(INSTALL) -D -m 0644 $(PANICOS_QUIRKS_PKGDIR)/files/system.d/volume-fixup.service \
		$(TARGET_DIR)/usr/lib/systemd/system/volume-fixup.service
	# Make quirk scripts and bin/ helpers executable. cp -a preserves but
	# git checkouts can drop the +x bit; belt-and-suspenders.
	chmod -R u+rwX,go+rX $(TARGET_DIR)/usr/lib/autostart/quirks
	find $(TARGET_DIR)/usr/lib/autostart/quirks -type f -name "[0-9]*" -exec chmod +x {} \;
	find $(TARGET_DIR)/usr/lib/autostart/quirks/*/*/bin -type f 2>/dev/null \
		-exec chmod +x {} \; || true

	# 2. Quirks export profile.d → /etc/profile.d/999-quirks-export.sh
	$(INSTALL) -D -m 0644 $(PANICOS_QUIRKS_PKGDIR)/files/profile.d/999-export \
		$(TARGET_DIR)/etc/profile.d/999-quirks-export.sh

	# 3. HW_DEVICE detection profile.d → /etc/profile.d/045-hw-device.sh
	$(INSTALL) -D -m 0644 $(PANICOS_QUIRKS_PKGDIR)/files/045-hw-device.sh \
		$(TARGET_DIR)/etc/profile.d/045-hw-device.sh

	# 4. Autostart runner → /usr/bin/autostart (+ daemons/ subdir if used)
	$(INSTALL) -D -m 0755 $(PANICOS_QUIRKS_PKGDIR)/files/autostart-runner-sources/autostart \
		$(TARGET_DIR)/usr/bin/autostart
	# `daemons` is a directory in the upstream sources; copy verbatim if non-empty.
	if [ -d "$(PANICOS_QUIRKS_PKGDIR)/files/autostart-runner-sources/daemons" ] \
	   && [ "$$(ls -A $(PANICOS_QUIRKS_PKGDIR)/files/autostart-runner-sources/daemons)" ]; then \
		mkdir -p $(TARGET_DIR)/usr/lib/autostart/daemons; \
		cp -a $(PANICOS_QUIRKS_PKGDIR)/files/autostart-runner-sources/daemons/* \
			$(TARGET_DIR)/usr/lib/autostart/daemons/; \
	fi

	# 5. Autostart-runner profile.d → /etc/profile.d/002-autostart.sh
	#    (This sets QUIRK_DEVICE from /sys/firmware/devicetree/base/model.)
	$(INSTALL) -D -m 0644 $(PANICOS_QUIRKS_PKGDIR)/files/autostart-runner-profile.d/002-autostart \
		$(TARGET_DIR)/etc/profile.d/002-autostart.sh
endef

define PANICOS_QUIRKS_INSTALL_INIT_SYSTEMD
	# Use our adapted unit (WantedBy=multi-user.target etc.) instead of
	# ROCKNIX's rocknix-autostart.service which depends on rocknix.target.
	$(INSTALL) -D -m 0644 $(PANICOS_QUIRKS_PKGDIR)/files/panicos-quirks-autostart.service \
		$(TARGET_DIR)/usr/lib/systemd/system/panicos-quirks-autostart.service
	mkdir -p $(TARGET_DIR)/usr/lib/systemd/system/multi-user.target.wants
	ln -sf ../panicos-quirks-autostart.service \
		$(TARGET_DIR)/usr/lib/systemd/system/multi-user.target.wants/panicos-quirks-autostart.service
endef

$(eval $(generic-package))

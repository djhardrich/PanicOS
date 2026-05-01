################################################################################
#
# panicos-pht
#
# Bundles the prebuilt aarch64 ProHandheldTracker binary, plugins, assets,
# and a launcher into /opt/pht/. Source payload comes from vendor/pht/ in
# the repo (populated by scripts/vendor-pht.sh — see Config.in help).
#
################################################################################

PANICOS_PHT_VERSION = 1.0
PANICOS_PHT_SITE = $(BR2_EXTERNAL_PANICOS_PATH)/package/panicos-pht
PANICOS_PHT_SITE_METHOD = local
PANICOS_PHT_LICENSE = Proprietary
PANICOS_PHT_DEPENDENCIES = sdl2 alsa-lib

PANICOS_PHT_PAYLOAD = $(BR2_EXTERNAL_PANICOS_PATH)/vendor/pht

define PANICOS_PHT_INSTALL_TARGET_CMDS
	@if [ ! -f $(PANICOS_PHT_PAYLOAD)/bin/pht-aarch64 ]; then \
		echo "ERROR: panicos-pht payload missing at $(PANICOS_PHT_PAYLOAD)" >&2; \
		echo "       Run scripts/vendor-pht.sh first (see package/panicos-pht/Config.in)." >&2; \
		exit 1; \
	fi
	mkdir -p $(TARGET_DIR)/opt/pht
	cp -a $(PANICOS_PHT_PAYLOAD)/bin     $(TARGET_DIR)/opt/pht/
	cp -a $(PANICOS_PHT_PAYLOAD)/plugins $(TARGET_DIR)/opt/pht/
	cp -a $(PANICOS_PHT_PAYLOAD)/assets  $(TARGET_DIR)/opt/pht/
	cp -a $(PANICOS_PHT_PAYLOAD)/scripts $(TARGET_DIR)/opt/pht/ 2>/dev/null || true
	cp -a $(PANICOS_PHT_PAYLOAD)/libs-aarch64 $(TARGET_DIR)/opt/pht/ 2>/dev/null || true
	# Install our launcher (overrides the upstream PortMaster-flavour one).
	$(INSTALL) -D -m 0755 $(PANICOS_PHT_PKGDIR)/panictracker.sh \
		$(TARGET_DIR)/opt/pht/panictracker.sh
	# Convenience symlink so /usr/bin/panictracker is in $$PATH.
	mkdir -p $(TARGET_DIR)/usr/bin
	ln -sf /opt/pht/panictracker.sh $(TARGET_DIR)/usr/bin/panictracker
endef

ifeq ($(BR2_PACKAGE_PANICOS_PHT_AUTOSTART),y)
define PANICOS_PHT_INSTALL_INIT_SYSTEMD
	$(INSTALL) -D -m 0644 $(PANICOS_PHT_PKGDIR)/panicos-pht.service \
		$(TARGET_DIR)/usr/lib/systemd/system/panicos-pht.service
	mkdir -p $(TARGET_DIR)/usr/lib/systemd/system/multi-user.target.wants
	ln -sf ../panicos-pht.service \
		$(TARGET_DIR)/usr/lib/systemd/system/multi-user.target.wants/panicos-pht.service
endef
endif

$(eval $(generic-package))

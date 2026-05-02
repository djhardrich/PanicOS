################################################################################
#
# panicos-pht-portmaster
#
# Stages vendor/pht.zip — the protection-enabled PortMaster-format
# PanicTracker (PHT) port zip — under
# /usr/share/panicos-launcher/portmaster-preload/. panicos-firstboot
# unzips it into /storage/roms/ports/ at first boot so PanicTracker
# shows up in ES's Ports menu next to Rockbox / Doom Engines.
#
# Source: scripts/vendor-pht.sh produces both vendor/pht/ (the loose
# tree consumed by panicos-pht's /opt-style install) and vendor/pht.zip
# (consumed here). The zip is the same artifact license-setup.sh port
# bundles into $PHT_REPO/dist/pht-portmaster.zip.
#
# vendor/pht.zip is gitignored — each user's protected build is
# specific to their signing key, so it doesn't belong in the repo.
#
################################################################################

PANICOS_PHT_PORTMASTER_VERSION = 1.0
PANICOS_PHT_PORTMASTER_SITE = $(BR2_EXTERNAL_PANICOS_PATH)/package/panicos-pht-portmaster
PANICOS_PHT_PORTMASTER_SITE_METHOD = local
PANICOS_PHT_PORTMASTER_LICENSE = Proprietary

PANICOS_PHT_PORTMASTER_ZIP = $(BR2_EXTERNAL_PANICOS_PATH)/vendor/pht.zip

define PANICOS_PHT_PORTMASTER_INSTALL_TARGET_CMDS
	@if [ ! -f $(PANICOS_PHT_PORTMASTER_ZIP) ]; then \
		echo "ERROR: panicos-pht-portmaster: missing $(PANICOS_PHT_PORTMASTER_ZIP)" >&2; \
		echo "       Run scripts/vendor-pht.sh first (it produces both vendor/pht/" >&2; \
		echo "       and vendor/pht.zip from PHT_REPO/dist/pht-portmaster.zip)." >&2; \
		exit 1; \
	fi
	mkdir -p $(TARGET_DIR)/usr/share/panicos-launcher/portmaster-preload
	# Use the upstream zip basename (PanicTracker.zip rather than
	# pht-portmaster.zip) so that ES + PortMaster see the same name they
	# would for a normally-installed version of this port. firstboot's
	# unzip just iterates *.zip in the preload dir, so the filename
	# itself doesn't matter for our flow — but keep it consistent.
	$(INSTALL) -m 0644 $(PANICOS_PHT_PORTMASTER_ZIP) \
		$(TARGET_DIR)/usr/share/panicos-launcher/portmaster-preload/PanicTracker.zip
endef

$(eval $(generic-package))

################################################################################
#
# panicos-portmaster-preload
#
# Stages PortMaster + bundled port zips under
# /usr/share/panicos-launcher/portmaster-preload/. panicos-firstboot
# unzips each one directly into /storage/roms/ports/ on first boot,
# producing a fully preinstalled Ports menu (PortMaster GUI + Rockbox
# + Doom Engines) without an Install.PortMaster.sh round-trip.
#
# Three zips:
#   * PortMaster.zip — PortMaster GUI itself (~24MB). firstboot extracts
#     this into /storage/roms/ports/PortMaster/, replacing the on-demand
#     Install.PortMaster.sh flow with a fully preinstalled GUI on first
#     boot. Tracks PortsMaster/PortMaster-GUI release `2026.04.01-1426`.
#   * rockbox.zip — PortMaster's Rockbox port, repackaged to merge in the
#     vendored PodOne theme and a config.cfg that selects PodOne as the
#     default theme. Ships with the optional Nimbus fonts already bundled
#     by upstream.
#   * doomengines.zip — chocolate-doom + prboom-plus + gzdoom + crispy-doom,
#     with iwads/DOOM19S.WAD (canonical Doom 1.9 shareware), FREEDOOM1.WAD
#     and FREEDOOM2.WAD already bundled inside.
#
# We don't use buildroot's _EXTRA_DOWNLOADS because SITE_METHOD=local
# bypasses the download phase entirely (no .stamp_downloaded rule fires
# for rsync-only packages, so EXTRA_DOWNLOADS aren't fetched). Instead we
# wget+sha256-check in a PRE_BUILD_HOOK, caching at $(@D)/dl/. PodOne is
# vendored locally because themes.rockbox.org is behind Anubis bot
# protection and can't be auto-fetched.
#
################################################################################

PANICOS_PORTMASTER_PRELOAD_VERSION = 1.0
PANICOS_PORTMASTER_PRELOAD_SITE = $(BR2_EXTERNAL_PANICOS_PATH)/package/panicos-portmaster-preload
PANICOS_PORTMASTER_PRELOAD_SITE_METHOD = local
PANICOS_PORTMASTER_PRELOAD_LICENSE = MIT

# Buildroot needs zip + unzip on the host to repackage rockbox with PodOne.
PANICOS_PORTMASTER_PRELOAD_DEPENDENCIES = host-zip

# (URL,sha256) pairs we download into $(@D)/dl/. Edit BOTH the URL and
# the sha256 when bumping versions — sha256 mismatch aborts the build,
# preventing silent supply-chain swaps.
PANICOS_PORTMASTER_PRELOAD_FETCH = \
	https://github.com/PortsMaster/PortMaster-GUI/releases/download/2026.04.01-1426/PortMaster.zip,3f6c23f752e5b5ec688ab0f20a94365dd124cd19ed0f22b8a5ef0b11429dc28b \
	https://github.com/PortsMaster/PortMaster-New/releases/download/2025-09-23_1014/rockbox.zip,a557aa23cc48c1cd0376862665786e0532ae60f87b53c5b797b9089654949123 \
	https://github.com/PortsMaster/PortMaster-New/releases/download/2026-04-28_1830/doomengines.zip,4b29914f768eba5222f370654af79e34b0a36ca3c280c8abd6b1c9c6803f5a1e

define PANICOS_PORTMASTER_PRELOAD_DOWNLOAD_ZIPS
	mkdir -p $(@D)/dl
	for entry in $(PANICOS_PORTMASTER_PRELOAD_FETCH); do \
		url=$${entry%,*}; want=$${entry##*,}; name=$$(basename $$url); \
		dst=$(@D)/dl/$$name; \
		if [ ! -f "$$dst" ]; then \
			echo ">>> panicos-portmaster-preload: fetching $$name"; \
			wget -q -O "$$dst.tmp" "$$url" || { rm -f "$$dst.tmp"; exit 1; }; \
			mv "$$dst.tmp" "$$dst"; \
		fi; \
		got=$$(sha256sum "$$dst" | awk '{print $$1}'); \
		if [ "$$got" != "$$want" ]; then \
			echo "ERROR: sha256 mismatch for $$name" >&2; \
			echo "  got:  $$got" >&2; \
			echo "  want: $$want" >&2; \
			exit 1; \
		fi; \
	done
endef
PANICOS_PORTMASTER_PRELOAD_PRE_BUILD_HOOKS += PANICOS_PORTMASTER_PRELOAD_DOWNLOAD_ZIPS

define PANICOS_PORTMASTER_PRELOAD_INSTALL_TARGET_CMDS
	mkdir -p $(TARGET_DIR)/usr/share/panicos-launcher/portmaster-preload

	# PortMaster.zip — the GUI/runtime itself. firstboot extracts at /storage/roms/ports/.
	$(INSTALL) -m 0644 \
		$(@D)/dl/PortMaster.zip \
		$(TARGET_DIR)/usr/share/panicos-launcher/portmaster-preload/PortMaster.zip

	# doomengines.zip — ships verbatim. Already has the shareware WAD inside.
	$(INSTALL) -m 0644 \
		$(@D)/dl/doomengines.zip \
		$(TARGET_DIR)/usr/share/panicos-launcher/portmaster-preload/doomengines.zip

	# rockbox.zip — repackage with PodOne theme + default config.cfg merged in.
	rm -rf $(@D)/rockbox-stage
	mkdir -p $(@D)/rockbox-stage
	cd $(@D)/rockbox-stage && unzip -q $(@D)/dl/rockbox.zip
	# PodOne ships .rockbox/ paths (the iPod-target layout). The Rockbox
	# SDL App build PortMaster ships uses rockbox/ (no leading dot) as
	# the data dir name, so flatten the prefix when copying.
	rm -rf $(@D)/podone-stage
	mkdir -p $(@D)/podone-stage
	cd $(@D)/podone-stage && \
		unzip -q $(PANICOS_PORTMASTER_PRELOAD_PKGDIR)/files/PodOne-r75-themesite.zip
	cp -a $(@D)/podone-stage/.rockbox/. $(@D)/rockbox-stage/rockbox/
	# Default config: select PodOne as the theme on first launch. Inside
	# Rockbox config the data dir is always referenced as /.rockbox/
	# regardless of on-disk name (Rockbox virtual filesystem).
	echo "selected theme: /.rockbox/themes/PodOne.cfg" \
		> $(@D)/rockbox-stage/rockbox/config.cfg
	# Re-zip with deterministic ordering so the output is reproducible
	# across rebuilds (-X strips extra metadata, sort by name). Use the
	# absolute path to host-zip's binary — buildroot's package recipe
	# environment doesn't reliably include $(HOST_DIR)/bin in PATH for
	# the recipe's child shells (one of the build hosts hit Error 127
	# without this).
	rm -f $(@D)/rockbox-with-podone.zip
	cd $(@D)/rockbox-stage && \
		find . -type f | LC_ALL=C sort | \
		$(HOST_DIR)/bin/zip -X -q $(@D)/rockbox-with-podone.zip -@
	$(INSTALL) -m 0644 $(@D)/rockbox-with-podone.zip \
		$(TARGET_DIR)/usr/share/panicos-launcher/portmaster-preload/rockbox.zip
endef

$(eval $(generic-package))

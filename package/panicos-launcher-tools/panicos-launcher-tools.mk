################################################################################
#
# panicos-launcher-tools
#
################################################################################

PANICOS_LAUNCHER_TOOLS_VERSION = 1.0
PANICOS_LAUNCHER_TOOLS_SITE = $(BR2_EXTERNAL_PANICOS_PATH)/package/panicos-launcher-tools
PANICOS_LAUNCHER_TOOLS_SITE_METHOD = local
PANICOS_LAUNCHER_TOOLS_LICENSE = GPL-2.0
PANICOS_LAUNCHER_TOOLS_DEPENDENCIES = libcurl bash

define PANICOS_LAUNCHER_TOOLS_INSTALL_TARGET_CMDS
	mkdir -p $(TARGET_DIR)/usr/share/panicos-launcher/tools
	$(INSTALL) -m 0755 $(PANICOS_LAUNCHER_TOOLS_PKGDIR)/files/Install.PortMaster.sh \
		$(TARGET_DIR)/usr/share/panicos-launcher/tools/Install.PortMaster.sh
	$(INSTALL) -m 0755 $(PANICOS_LAUNCHER_TOOLS_PKGDIR)/files/PortMaster.sh \
		$(TARGET_DIR)/usr/share/panicos-launcher/tools/PortMaster.sh
	# mod_PanicOS.txt — PortMaster's runtime contract for our CFW
	# (CFW_NAME comes from /etc/os-release's OS_NAME field). firstboot
	# drops this into /storage/roms/ports/PortMaster/ after extracting
	# PortMaster.zip so PortMaster.sh sources it on launch.
	$(INSTALL) -m 0644 $(PANICOS_LAUNCHER_TOOLS_PKGDIR)/files/mod_PanicOS.txt \
		$(TARGET_DIR)/usr/share/panicos-launcher/tools/mod_PanicOS.txt
	# libgl_PanicOS.txt — overrides libgl_default.txt's LIBGL_FB=4 (GBM).
	# We skip gl4es entirely and let ports use system mesa3d (panfrost +
	# Wayland EGL) which actually works on the H700's split DRM topology.
	$(INSTALL) -m 0644 $(PANICOS_LAUNCHER_TOOLS_PKGDIR)/files/libgl_PanicOS.txt \
		$(TARGET_DIR)/usr/share/panicos-launcher/tools/libgl_PanicOS.txt
	# SDL_GameControllerDB entry for our hardware. Vendored from ROCKNIX's
	# apps/gamecontrollerdb so PortMaster + ports get the right A/B/X/Y
	# mapping for the H700 Gamepad (and other handheld pads ROCKNIX
	# tracks). PortMaster ships a generic gamecontrollerdb.txt that
	# doesn't have an H700 entry — without ours, A and B come up swapped
	# and start+select hotkeys don't register. firstboot drops a symlink
	# to this file at /storage/roms/ports/PortMaster/gamecontrollerdb.txt
	# overriding PortMaster's bundled one.
	mkdir -p $(TARGET_DIR)/usr/share/SDL-GameControllerDB
	$(INSTALL) -m 0644 $(PANICOS_LAUNCHER_TOOLS_PKGDIR)/files/gamecontrollerdb.txt \
		$(TARGET_DIR)/usr/share/SDL-GameControllerDB/gamecontrollerdb.txt
	# PanicOS-SquashFS-Install.sh — on-device toggle for the Debian multiboot flavor.
	$(INSTALL) -m 0755 $(PANICOS_LAUNCHER_TOOLS_PKGDIR)/files/PanicOS-SquashFS-Install.sh \
		$(TARGET_DIR)/usr/share/panicos-launcher/tools/PanicOS-SquashFS-Install.sh
	# Rescan-HDMI-Audio.sh — manual re-detect for sinks like Xreal Air glasses
	# that don't advertise audio in EDID until the user enables it physically.
	$(INSTALL) -m 0755 $(PANICOS_LAUNCHER_TOOLS_PKGDIR)/files/Rescan-HDMI-Audio.sh \
		$(TARGET_DIR)/usr/share/panicos-launcher/tools/Rescan-HDMI-Audio.sh
	# panicos-portmaster-fixup re-applies our overrides on every ES
	# start (mirror's ROCKNIX's start_portmaster.sh approach). Lives
	# at /usr/sbin/.
	$(INSTALL) -D -m 0755 $(PANICOS_LAUNCHER_TOOLS_PKGDIR)/files/panicos-portmaster-fixup.sh \
		$(TARGET_DIR)/usr/sbin/panicos-portmaster-fixup
endef

define PANICOS_LAUNCHER_TOOLS_INSTALL_INIT_SYSTEMD
	$(INSTALL) -D -m 0644 $(PANICOS_LAUNCHER_TOOLS_PKGDIR)/files/panicos-portmaster-fixup.service \
		$(TARGET_DIR)/usr/lib/systemd/system/panicos-portmaster-fixup.service
	mkdir -p $(TARGET_DIR)/usr/lib/systemd/system/panicos-es.service.wants
	ln -sf ../panicos-portmaster-fixup.service \
		$(TARGET_DIR)/usr/lib/systemd/system/panicos-es.service.wants/panicos-portmaster-fixup.service
endef
# /usr/bin/sh -> bash is wired via the launcher flavor's rootfs-overlay
# rather than this package's install step — avoids ordering races
# against busybox's symlinks.

$(eval $(generic-package))

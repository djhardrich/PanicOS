################################################################################
#
# panicos-emulationstation
#
# ROCKNIX's emulationstation-next fork, built from git for aarch64 with
# KMSDRM/GLES2 rendering. Heavy build (~30+ min first time on this hardware
# due to boost + freeimage + the ES source itself); subsequent incremental
# builds are fast.
#
################################################################################

# Pin to the same SHA ROCKNIX ships at — they cherry-pick fixes, this gives
# us their working state. Bump when we want to track upstream.
PANICOS_EMULATIONSTATION_VERSION = 5890d64a33d7eef1815e4740a484ffe3c1e3a813
PANICOS_EMULATIONSTATION_SITE = $(call github,ROCKNIX,emulationstation-next,$(PANICOS_EMULATIONSTATION_VERSION))
PANICOS_EMULATIONSTATION_LICENSE = MIT
PANICOS_EMULATIONSTATION_LICENSE_FILES = LICENSE.md

PANICOS_EMULATIONSTATION_DEPENDENCIES = \
	sdl2 sdl2_mixer freetype freeimage libcurl openssl rapidjson pugixml \
	boost vlc bash fping p7zip xmlstarlet mesa3d

# CMake options tracking ROCKNIX's package.mk verbatim except:
#  * GL=0 (we don't have desktop OpenGL on these handhelds, only GLES2)
#  * GLES2=1 (Mali via panfrost via mesa3d)
#  * ENABLE_PULSE=0 (no PulseAudio in the launcher flavor; SDL2_mixer ALSA)
#  * USE_SYSTEM_PUGIXML=1 (saves ~2min not building the bundled copy)
PANICOS_EMULATIONSTATION_CONF_OPTS = \
	-DROCKNIX=1 \
	-DDISABLE_KODI=1 \
	-DENABLE_FILEMANAGER=0 \
	-DCEC=0 \
	-DGL=0 \
	-DGLES=1 \
	-DGLES2=1 \
	-DENABLE_PULSE=0 \
	-DUSE_SYSTEM_PUGIXML=1

define PANICOS_EMULATIONSTATION_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/emulationstation $(TARGET_DIR)/usr/bin/emulationstation
	# Resources (themes, fonts) ship alongside the binary.
	cp -a $(@D)/resources $(TARGET_DIR)/usr/share/emulationstation/
	# Our minimal es_systems.cfg overrides whatever default ES picks; lives
	# under /etc so users can override via the overlay.
	$(INSTALL) -D -m 0644 $(PANICOS_EMULATIONSTATION_PKGDIR)/files/es_systems.cfg \
		$(TARGET_DIR)/etc/emulationstation/es_systems.cfg
	# Pre-create the ports + tools rom dirs on the persistent storage so
	# ES doesn't complain on first boot.
	mkdir -p $(TARGET_DIR)/storage/roms/ports
endef

define PANICOS_EMULATIONSTATION_INSTALL_INIT_SYSTEMD
	$(INSTALL) -D -m 0644 $(PANICOS_EMULATIONSTATION_PKGDIR)/files/panicos-es.service \
		$(TARGET_DIR)/usr/lib/systemd/system/panicos-es.service
	mkdir -p $(TARGET_DIR)/usr/lib/systemd/system/multi-user.target.wants
	ln -sf ../panicos-es.service \
		$(TARGET_DIR)/usr/lib/systemd/system/multi-user.target.wants/panicos-es.service
endef

$(eval $(cmake-package))

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
# Use git + submodules (NOT the github tarball) because external/pugixml
# is a submodule pointing at github.com/zeux/pugixml.git and the source
# code unconditionally `#include <pugixml/src/pugixml.hpp>` from that
# path. Tarballs don't carry submodule contents, so the build fails with
# "fatal error: pugixml/src/pugixml.hpp: No such file" without this.
PANICOS_EMULATIONSTATION_VERSION = 5890d64a33d7eef1815e4740a484ffe3c1e3a813
PANICOS_EMULATIONSTATION_SITE = https://github.com/ROCKNIX/emulationstation-next.git
PANICOS_EMULATIONSTATION_SITE_METHOD = git
PANICOS_EMULATIONSTATION_GIT_SUBMODULES = YES
PANICOS_EMULATIONSTATION_LICENSE = MIT
PANICOS_EMULATIONSTATION_LICENSE_FILES = LICENSE.md

PANICOS_EMULATIONSTATION_DEPENDENCIES = \
	sdl2 sdl2_mixer alsa-lib freetype libfreeimage libcurl openssl rapidjson \
	boost vlc bash fping p7zip xmlstarlet mesa3d

# CMake options tracking ROCKNIX's package.mk verbatim except:
#  * GL=0 (no desktop OpenGL on these handhelds)
#  * GLES=0 + GLES2=1 (Mali via panfrost via mesa3d). GLES must be 0:
#    upstream picks GLSystem with `if(GLES) ... elseif(GLES2)`, so any
#    truthy GLES short-circuits and selects the legacy "Embedded OpenGL"
#    path (Renderer_GLES10.cpp). That file uses fixed-function
#    glBegin/glVertex2f/glEnd which don't exist in <GLES/gl.h>, so the
#    build fails with "glBegin was not declared in this scope".
#  * ENABLE_PULSE=0 (no PulseAudio in the launcher flavor; SDL2_mixer ALSA)
# (Dropped USE_SYSTEM_PUGIXML — ES source `#include <pugixml/src/...>`
# unconditionally, so it needs the bundled submodule copy regardless.)
PANICOS_EMULATIONSTATION_CONF_OPTS = \
	-DROCKNIX=1 \
	-DDISABLE_KODI=1 \
	-DENABLE_FILEMANAGER=0 \
	-DCEC=0 \
	-DGL=0 \
	-DGLES=0 \
	-DGLES2=1 \
	-DENABLE_PULSE=0

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

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
PANICOS_EMULATIONSTATION_VERSION = c22bb6892a5f175d3c59187073b88a0a574a75af
PANICOS_EMULATIONSTATION_SITE = https://github.com/djhardrich/emulationstation-next.git
PANICOS_EMULATIONSTATION_SITE_METHOD = git
PANICOS_EMULATIONSTATION_GIT_SUBMODULES = YES
PANICOS_EMULATIONSTATION_LICENSE = MIT
PANICOS_EMULATIONSTATION_LICENSE_FILES = LICENSE.md

PANICOS_EMULATIONSTATION_DEPENDENCIES = \
	sdl2 sdl2_mixer alsa-lib freetype panicos-libfreeimage libcurl openssl rapidjson \
	boost vlc bash fping p7zip xmlstarlet \
	$(if $(BR2_PACKAGE_MESA3D),mesa3d)

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
	# Bundled pugixml lives in external/pugixml/ as a git submodule; the
	# CMake build links ES against the resulting libpugixml.so.1 (vs. a
	# system pugixml). The .so lands at the top of the build dir; ship it
	# alongside the binary so the runtime loader actually finds it (ES
	# crashes at startup with "libpugixml.so.1: cannot open shared object
	# file" otherwise — the failure that broke the launcher flavor on
	# 2026-05-02). cp -a preserves the so.X / so.X.Y symlink chain.
	mkdir -p $(TARGET_DIR)/usr/lib
	cp -a $(@D)/libpugixml.so* $(TARGET_DIR)/usr/lib/
	# Resources (themes, fonts, on/off/checkbox SVGs, scroll_gradient,
	# button.png, etc.) ship at /usr/bin/resources/ — next to the
	# binary. Important: when ES is built with -DROCKNIX=1 (which we
	# do, for the storage-paths split it gives us), Paths.cpp:78 sets
	# mEmulationStationPath = getExePath() → /usr/bin. The
	# ResourceManager's `:/foo.svg` resolver then ONLY checks
	# $mEmulationStationPath/resources/foo.svg (and a few user paths
	# under /storage). If we install to /usr/share/emulationstation/
	# instead, every embedded `:/` reference fails to resolve — switches
	# render invisible, menu fade scrim never paints, etc.
	# Mirror ROCKNIX's install layout: drop them next to the binary.
	# Use SRC/. + DST/ form so a re-install merges into existing
	# /usr/bin/resources/ instead of nesting a /usr/bin/resources/resources/
	# (which `cp -a SRC DST` does when DST already exists — produced a
	# stale joystick logo.png in the nested copy on incremental builds).
	mkdir -p $(TARGET_DIR)/usr/bin/resources
	cp -a $(@D)/resources/. $(TARGET_DIR)/usr/bin/resources/
	rm -rf $(TARGET_DIR)/usr/bin/resources/resources
	# Replace upstream's branding. Linux ES uses ":/logo.png" as
	# DEFAULT_SPLASH_IMAGE (Splash.h:14 — :/splash.svg is WIN32-only),
	# resolved by ResourceManager to /usr/bin/resources/logo.png. The
	# upstream PNG is a 1920x1080 batocera joystick/vaporwave hero
	# image (~880KB). Reuse the panicos-splash payload (the same logo
	# the bootloader/PHT splash service shows) so ES + boot stay visually
	# coherent and the artwork has one source of truth.
	$(INSTALL) -m 0644 \
		$(BR2_EXTERNAL_PANICOS_PATH)/package/panicos-splash/payload/splash-1024x768.png \
		$(TARGET_DIR)/usr/bin/resources/logo.png
	# Our minimal es_systems.cfg overrides whatever default ES picks; lives
	# under /etc so users can override via the overlay.
	$(INSTALL) -D -m 0644 $(PANICOS_EMULATIONSTATION_PKGDIR)/files/es_systems.cfg \
		$(TARGET_DIR)/etc/emulationstation/es_systems.cfg
	# System-level input config (ROCKNIX build: mEmulationStationPath = getExePath()
	# = /usr/bin, so the shared path ES checks is /usr/bin/es_input.cfg).
	# Sourced verbatim from ROCKNIX's canonical es_input.cfg — covers every device
	# ROCKNIX ships (H700, RK3566, S922X, SM6115, …). Pre-seeds all known gamepads
	# so ES never shows the "configure controller" wizard on first boot or after an
	# ES restart. The user's /storage/.config/emulationstation/es_input.cfg wins.
	$(INSTALL) -D -m 0644 \
		$(BR2_EXTERNAL_PANICOS_PATH)/third_party/rocknix/projects/ROCKNIX/packages/ui/emulationstation/config/common/es_input.cfg \
		$(TARGET_DIR)/usr/bin/es_input.cfg
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

################################################################################
#
# panicos-gl4es
#
# OpenGL 1.x/2.x → OpenGL ES translation layer for legacy ports.
# Installed to /usr/lib/ (system-wide) and mirrored to /usr/lib/gl4es/
# via symlinks for the LD_LIBRARY_PATH override in libgl_PanicOS.txt.
# Also installed to staging so libglu can link against libGL at build time.
#
# We are a Wayland-only device (no X11/GLX), so mesa3d never sets
# BR2_PACKAGE_HAS_LIBGL; Config.in selects it here instead.
#
# Build options:
#   DEFAULT_ES=3  — use GLES 3.x backend (panfrost supports GLES 3.2)
#   NOX11=1       — no X11; we run Wayland-native (SDL2 backend suffices)
#
################################################################################

PANICOS_GL4ES_VERSION = v1.1.6
PANICOS_GL4ES_SITE = $(call github,ptitSeb,gl4es,$(PANICOS_GL4ES_VERSION))
PANICOS_GL4ES_LICENSE = MIT
PANICOS_GL4ES_LICENSE_FILES = LICENSE
PANICOS_GL4ES_DEPENDENCIES = mesa3d sdl2

PANICOS_GL4ES_CONF_OPTS = \
	-DDEFAULT_ES=3 \
	-DNOX11=1 \
	-DSTATICLIB=OFF

define PANICOS_GL4ES_INSTALL_STAGING_CMDS
	# libglu and any other build-time consumer need libGL.so in staging.
	find $(@D) -name 'libGL.so.1' ! -path '*/CMakeFiles/*' | \
		head -1 | xargs -I{} $(INSTALL) -m 755 {} $(STAGING_DIR)/usr/lib/libGL.so.1
	ln -sf libGL.so.1 $(STAGING_DIR)/usr/lib/libGL.so
endef

define PANICOS_GL4ES_INSTALL_TARGET_CMDS
	# System-wide install: PortMaster's gl_check looks for /usr/lib/libGL.so.1;
	# without it, ports print "vital systems failed to initialize".
	find $(@D) -name 'libGL.so.1' ! -path '*/CMakeFiles/*' | \
		head -1 | xargs -I{} $(INSTALL) -m 755 {} $(TARGET_DIR)/usr/lib/libGL.so.1
	ln -sf libGL.so.1 $(TARGET_DIR)/usr/lib/libGL.so
	# /usr/lib/gl4es/ symlinks: libgl_PanicOS.txt prepends this dir so our
	# gl4es overrides any port-bundled gl4es 1.1.7 (DEFAULT_ES=3 vs 2).
	mkdir -p $(TARGET_DIR)/usr/lib/gl4es
	ln -sf ../libGL.so.1 $(TARGET_DIR)/usr/lib/gl4es/libGL.so.1
	ln -sf ../libGL.so.1 $(TARGET_DIR)/usr/lib/gl4es/libGL.so
endef

$(eval $(cmake-package))

################################################################################
#
# panicos-gl4es
#
# OpenGL 1.x/2.x → OpenGL ES translation layer for legacy ports.
# Installed to /usr/lib/gl4es/ (not system-wide) so it doesn't interfere with
# libglvnd's libGL.so.1.  libgl_PanicOS.txt prepends /usr/lib/gl4es to
# LD_LIBRARY_PATH so it overrides port-bundled gl4es 1.1.7.
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

define PANICOS_GL4ES_INSTALL_TARGET_CMDS
	mkdir -p $(TARGET_DIR)/usr/lib/gl4es
	# cmake places the library under lib/ relative to the build dir
	find $(@D) -name 'libGL.so.1' ! -path '*/CMakeFiles/*' | \
		head -1 | xargs -I{} $(INSTALL) -m 755 {} $(TARGET_DIR)/usr/lib/gl4es/libGL.so.1
	ln -sf libGL.so.1 $(TARGET_DIR)/usr/lib/gl4es/libGL.so
endef

$(eval $(cmake-package))

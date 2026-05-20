################################################################################
#
# panicos-gl4es
#
# OpenGL 1.x/2.x → OpenGL ES translation layer for legacy ports.
# Installed to /usr/lib/ (system-wide) so PortMaster's gl_check
# finds /usr/lib/libGL.so.1, and mirrored to /usr/lib/gl4es/ via
# symlinks for the LD_LIBRARY_PATH override in libgl_PanicOS.txt.
#
# Staging install provides libGL.so, GL headers, and a gl.pc so that
# panicos-libglu's meson build can find OpenGL via pkg-config without
# using buildroot's libgl virtual package (which requires X11/GLX).
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
PANICOS_GL4ES_INSTALL_STAGING = YES

PANICOS_GL4ES_CONF_OPTS = \
	-DDEFAULT_ES=3 \
	-DNOX11=1 \
	-DSTATICLIB=OFF

define PANICOS_GL4ES_INSTALL_STAGING_CMDS
	# libGL.so — panicos-libglu (and any other staging consumer) links against it.
	find $(@D) -name 'libGL.so.1' ! -path '*/CMakeFiles/*' | \
		head -1 | xargs -I{} $(INSTALL) -m 755 {} $(STAGING_DIR)/usr/lib/libGL.so.1
	ln -sf libGL.so.1 $(STAGING_DIR)/usr/lib/libGL.so
	# GL headers from the gl4es source tree (include/GL/gl.h, glext.h).
	# Mesa3d on a GLES-only build (no GLX) doesn't install these; libglu
	# needs <GL/gl.h> at compile time.
	mkdir -p $(STAGING_DIR)/usr/include/GL
	$(INSTALL) -m 644 $(@D)/include/GL/gl.h $(STAGING_DIR)/usr/include/GL/gl.h
	$(INSTALL) -m 644 $(@D)/include/GL/glext.h $(STAGING_DIR)/usr/include/GL/glext.h
	# gl.pc — panicos-libglu's meson build uses `dependency('gl')` which
	# resolves via pkg-config; provide a minimal .pc pointing to our libGL.
	mkdir -p $(STAGING_DIR)/usr/lib/pkgconfig
	printf 'prefix=/usr\nexec_prefix=$${prefix}\nlibdir=$${exec_prefix}/lib\nincludedir=$${prefix}/include\n\nName: gl\nDescription: OpenGL (gl4es)\nVersion: $(PANICOS_GL4ES_VERSION)\nLibs: -L$${libdir} -lGL\nCflags: -I$${includedir}\n' \
		> $(STAGING_DIR)/usr/lib/pkgconfig/gl.pc
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

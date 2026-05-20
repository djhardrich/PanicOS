################################################################################
#
# panicos-libglu
#
# OpenGL Utility Library built against panicos-gl4es.  Bypasses buildroot's
# libglu (which depends on the libgl virtual package / X11/GLX) by depending
# on panicos-gl4es directly.  panicos-gl4es installs libGL.so + GL headers +
# gl.pc to the staging tree so this meson build finds them via pkg-config.
#
################################################################################

PANICOS_LIBGLU_VERSION = 9.0.3
PANICOS_LIBGLU_SITE = https://mesa.freedesktop.org/archive/glu
PANICOS_LIBGLU_SOURCE = glu-$(PANICOS_LIBGLU_VERSION).tar.xz
PANICOS_LIBGLU_LICENSE = SGI-B-2.0
PANICOS_LIBGLU_LICENSE_FILES = include/GL/glu.h
PANICOS_LIBGLU_INSTALL_STAGING = YES
PANICOS_LIBGLU_DEPENDENCIES = panicos-gl4es host-pkgconf
PANICOS_LIBGLU_CONF_OPTS = -Dgl_provider=gl

$(eval $(meson-package))

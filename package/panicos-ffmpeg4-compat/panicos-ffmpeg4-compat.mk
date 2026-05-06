################################################################################
#
# panicos-ffmpeg4-compat
#
# Installs FFmpeg 4.4.x shared libraries (libavcodec.so.58 etc.) alongside
# the system FFmpeg 6.x so that PortMaster ports pre-compiled against FFmpeg
# 4.x can dlopen/link against the correct SONAME.
#
# Only the major-versioned .so files are installed; no headers, pkg-config
# or binaries, avoiding conflicts with BR2_PACKAGE_FFMPEG (6.x).
#
################################################################################

PANICOS_FFMPEG4_COMPAT_VERSION = 4.4.4
PANICOS_FFMPEG4_COMPAT_SITE = https://ffmpeg.org/releases
PANICOS_FFMPEG4_COMPAT_SOURCE = ffmpeg-$(PANICOS_FFMPEG4_COMPAT_VERSION).tar.xz
PANICOS_FFMPEG4_COMPAT_LICENSE = LGPL-2.1+
PANICOS_FFMPEG4_COMPAT_LICENSE_FILES = LICENSE.md COPYING.LGPLv2.1

# Do not install to staging; only the target .so.MAJOR files are needed.
PANICOS_FFMPEG4_COMPAT_INSTALL_STAGING = NO

# GCC 13/14 treats implicit-function-declaration as an error; suppress
# the warnings that FFmpeg 4.x triggers with newer compilers.
PANICOS_FFMPEG4_COMPAT_CFLAGS = \
	-Wno-implicit-function-declaration \
	-Wno-int-conversion \
	-Wno-incompatible-pointer-types \
	-Wno-error

PANICOS_FFMPEG4_COMPAT_CONF_OPTS = \
	--enable-shared \
	--disable-static \
	--disable-programs \
	--disable-doc \
	--disable-debug \
	--enable-optimizations \
	--disable-stripping

# Override configure: FFmpeg does not use autoconf-style configure.
define PANICOS_FFMPEG4_COMPAT_CONFIGURE_CMDS
	(cd $(@D) && rm -rf config.cache && \
	$(TARGET_CONFIGURE_OPTS) \
	$(TARGET_CONFIGURE_ARGS) \
	CFLAGS="$(TARGET_CFLAGS) $(PANICOS_FFMPEG4_COMPAT_CFLAGS)" \
	./configure \
		--enable-cross-compile \
		--cross-prefix=$(TARGET_CROSS) \
		--sysroot=$(STAGING_DIR) \
		--host-cc="$(HOSTCC)" \
		--arch=$(BR2_ARCH) \
		--target-os="linux" \
		--pkg-config="$(PKG_CONFIG_HOST_BINARY)" \
		$(PANICOS_FFMPEG4_COMPAT_CONF_OPTS) \
	)
endef

define PANICOS_FFMPEG4_COMPAT_BUILD_CMDS
	$(MAKE) -C $(@D)
endef

# Install only the versioned shared libs; skip headers and unversioned
# .so symlinks so nothing conflicts with system ffmpeg (6.x, .so.60).
define PANICOS_FFMPEG4_COMPAT_INSTALL_TARGET_CMDS
	find $(@D) -maxdepth 2 -name "lib*.so.[0-9]*" \
		-exec cp -P {} $(TARGET_DIR)/usr/lib/ \;
endef

$(eval $(generic-package))

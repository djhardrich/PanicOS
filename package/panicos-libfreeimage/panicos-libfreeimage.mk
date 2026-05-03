################################################################################
#
# libfreeimage
#
################################################################################

PANICOS_LIBFREEIMAGE_VERSION = 3.18.0
PANICOS_LIBFREEIMAGE_SITE = http://downloads.sourceforge.net/freeimage
PANICOS_LIBFREEIMAGE_SOURCE = FreeImage$(subst .,,$(PANICOS_LIBFREEIMAGE_VERSION)).zip
PANICOS_LIBFREEIMAGE_LICENSE = GPL-2.0 or GPL-3.0 or FreeImage Public License
PANICOS_LIBFREEIMAGE_LICENSE_FILES = license-gplv2.txt license-gplv3.txt license-fi.txt
PANICOS_LIBFREEIMAGE_CPE_ID_VENDOR = freeimage_project
PANICOS_LIBFREEIMAGE_CPE_ID_PRODUCT = freeimage
PANICOS_LIBFREEIMAGE_INSTALL_STAGING = YES

# 0007-CVE-2019-12211_2019-12213.patch
PANICOS_LIBFREEIMAGE_IGNORE_CVES += CVE-2019-12211 CVE-2019-12213

# 0008-CVE-2020-24292.patch
PANICOS_LIBFREEIMAGE_IGNORE_CVES += CVE-2020-24292

# 0009-CVE-2020-24293.patch
PANICOS_LIBFREEIMAGE_IGNORE_CVES += CVE-2020-24293

# 0010-CVE-2020-24295.patch
PANICOS_LIBFREEIMAGE_IGNORE_CVES += CVE-2020-24295

# 0011-CVE-2021-33367.patch
PANICOS_LIBFREEIMAGE_IGNORE_CVES += CVE-2021-33367

# 0012-CVE-2021-40263.patch
PANICOS_LIBFREEIMAGE_IGNORE_CVES += CVE-2021-40263

# 0013-CVE-2021-40266.patch
PANICOS_LIBFREEIMAGE_IGNORE_CVES += CVE-2021-40266

# 0014-CVE-2023-47995.patch
PANICOS_LIBFREEIMAGE_IGNORE_CVES += CVE-2023-47995

# 0016-CVE-2023-47997.patch
PANICOS_LIBFREEIMAGE_IGNORE_CVES += CVE-2023-47997

define PANICOS_LIBFREEIMAGE_EXTRACT_CMDS
	$(UNZIP) $(PANICOS_LIBFREEIMAGE_DL_DIR)/$(PANICOS_LIBFREEIMAGE_SOURCE) -d $(@D)
	mv $(@D)/FreeImage/* $(@D)
	rmdir $(@D)/FreeImage
endef

define PANICOS_LIBFREEIMAGE_BUILD_CMDS
	grep -q '__builtin_bswap32' $(@D)/Source/LibJXR/image/sys/windowsmediaphoto.h || \
		printf '\n#ifndef _MSC_VER\n#define _byteswap_ushort(x) __builtin_bswap16(x)\n#define _byteswap_ulong(x)  __builtin_bswap32(x)\n#define _byteswap_uint64(x) __builtin_bswap64(x)\n#endif\n' \
		>> $(@D)/Source/LibJXR/image/sys/windowsmediaphoto.h
	grep -q 'Wno-implicit-function-declaration' $(@D)/Makefile.gnu || \
		sed -i 's/^CFLAGS += -DDISABLE_PERF_MEASUREMENT/CFLAGS += -DDISABLE_PERF_MEASUREMENT \\\n\t-Wno-implicit-function-declaration -Wno-implicit-int/' \
		$(@D)/Makefile.gnu
	sed -i 's/ -o root -g root//' $(@D)/Makefile.gnu
	grep -q 'system-libpng' $(@D)/Makefile.gnu || { \
		sed -i 's|Source/LibPNG/[^ ]*.c ||g' $(@D)/Makefile.srcs; \
		sed -i 's/LIBRARIES = -lstdc++/LIBRARIES = -lstdc++ -lpng  # system-libpng/' $(@D)/Makefile.gnu; \
		cp $(STAGING_DIR)/usr/include/pnglibconf.h $(@D)/Source/LibPNG/pnglibconf.h; \
		rm -f $(@D)/libfreeimage-3.18.0.so $(@D)/libfreeimage.so $(@D)/libfreeimage.a; \
	}
	$(TARGET_MAKE_ENV) $(TARGET_CONFIGURE_OPTS) \
		CXXFLAGS="$(TARGET_CXXFLAGS) -std=c++11 -Wno-deprecated-declarations" $(MAKE) -C $(@D)
endef

define PANICOS_LIBFREEIMAGE_INSTALL_STAGING_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) DESTDIR=$(STAGING_DIR) install
endef

define PANICOS_LIBFREEIMAGE_INSTALL_TARGET_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) DESTDIR=$(TARGET_DIR) install
endef

$(eval $(generic-package))

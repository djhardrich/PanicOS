################################################################################
#
# panicos-lib32
#
# Populates /usr/lib32 with the armhf runtime libraries that box86 needs to
# satisfy shared-library lookups when translating 32-bit x86 games.
#
# Source: /usr/arm-linux-gnueabihf/lib/ inside the Docker build image
# (installed by gcc-arm-linux-gnueabihf + g++-arm-linux-gnueabihf).
# Both glibc and libgcc_s/libstdc++ live there — NOT in gcc-cross/.
#
################################################################################

PANICOS_LIB32_VERSION = 1.0
PANICOS_LIB32_SITE = $(PANICOS_LIB32_PKGDIR)/src
PANICOS_LIB32_SITE_METHOD = local
PANICOS_LIB32_LICENSE = LGPL-2.1+ (glibc), GPL-3.0+ with runtime exception (libstdc++)

# All installed files are armhf (32-bit) — intentionally not matching the
# aarch64 target arch. Tell Buildroot's check-bin-arch to skip them.
# /lib entry is only symlinks (already auto-skipped), so only /usr/lib32 needed.
PANICOS_LIB32_BIN_ARCH_EXCLUDE = /usr/lib32

ARMHF_SYSROOT_LIB = /usr/arm-linux-gnueabihf/lib

define PANICOS_LIB32_BUILD_CMDS
	true
endef

define PANICOS_LIB32_INSTALL_TARGET_CMDS
	mkdir -p $(TARGET_DIR)/usr/lib32 $(TARGET_DIR)/lib
	# glibc fundamentals
	cp -dP $(ARMHF_SYSROOT_LIB)/libc.so.6           $(TARGET_DIR)/usr/lib32/ 2>/dev/null || true
	cp -dP $(ARMHF_SYSROOT_LIB)/libc-*.so            $(TARGET_DIR)/usr/lib32/ 2>/dev/null || true
	cp -dP $(ARMHF_SYSROOT_LIB)/libm.so.6            $(TARGET_DIR)/usr/lib32/ 2>/dev/null || true
	cp -dP $(ARMHF_SYSROOT_LIB)/libm-*.so            $(TARGET_DIR)/usr/lib32/ 2>/dev/null || true
	cp -dP $(ARMHF_SYSROOT_LIB)/libdl.so.2           $(TARGET_DIR)/usr/lib32/ 2>/dev/null || true
	cp -dP $(ARMHF_SYSROOT_LIB)/libdl-*.so           $(TARGET_DIR)/usr/lib32/ 2>/dev/null || true
	cp -dP $(ARMHF_SYSROOT_LIB)/librt.so.1           $(TARGET_DIR)/usr/lib32/ 2>/dev/null || true
	cp -dP $(ARMHF_SYSROOT_LIB)/librt-*.so           $(TARGET_DIR)/usr/lib32/ 2>/dev/null || true
	cp -dP $(ARMHF_SYSROOT_LIB)/libpthread.so.0      $(TARGET_DIR)/usr/lib32/ 2>/dev/null || true
	cp -dP $(ARMHF_SYSROOT_LIB)/libpthread-*.so      $(TARGET_DIR)/usr/lib32/ 2>/dev/null || true
	cp -dP $(ARMHF_SYSROOT_LIB)/libresolv.so.2       $(TARGET_DIR)/usr/lib32/ 2>/dev/null || true
	cp -dP $(ARMHF_SYSROOT_LIB)/libresolv-*.so       $(TARGET_DIR)/usr/lib32/ 2>/dev/null || true
	cp -dP $(ARMHF_SYSROOT_LIB)/libnss_dns.so.2      $(TARGET_DIR)/usr/lib32/ 2>/dev/null || true
	cp -dP $(ARMHF_SYSROOT_LIB)/libnss_files.so.2    $(TARGET_DIR)/usr/lib32/ 2>/dev/null || true
	# armhf dynamic linker — the kernel looks here
	cp -dP $(ARMHF_SYSROOT_LIB)/ld-linux-armhf.so.3 $(TARGET_DIR)/usr/lib32/ 2>/dev/null || true
	cp -dP $(ARMHF_SYSROOT_LIB)/ld-*.so              $(TARGET_DIR)/usr/lib32/ 2>/dev/null || true
	ln -sf /usr/lib32/ld-linux-armhf.so.3            $(TARGET_DIR)/lib/ld-linux-armhf.so.3 2>/dev/null || true
	# libgcc_s and libstdc++ — also in /usr/arm-linux-gnueabihf/lib/
	cp -dP $(ARMHF_SYSROOT_LIB)/libgcc_s.so.1        $(TARGET_DIR)/usr/lib32/ 2>/dev/null || true
	cp -dP $(ARMHF_SYSROOT_LIB)/libstdc++.so.6        $(TARGET_DIR)/usr/lib32/ 2>/dev/null || true
	cp -dP $(ARMHF_SYSROOT_LIB)/libstdc++.so.6.*      $(TARGET_DIR)/usr/lib32/ 2>/dev/null || true
endef

$(eval $(generic-package))

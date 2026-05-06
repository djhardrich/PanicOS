################################################################################
#
# panicos-box86
#
# box86 translates x86 (32-bit) Linux binaries to armhf at runtime.  On
# aarch64 the CPU executes armhf code in AArch32 mode, so box86 itself must
# be compiled as an armhf binary — we use the host arm-linux-gnueabihf
# cross-compiler (gcc-arm-linux-gnueabihf in the Docker image) rather than
# the Buildroot aarch64 cross-compiler.
#
################################################################################

PANICOS_BOX86_VERSION = 0579f8b9c47d87d700724f4cce559b06cbd2b0f5
PANICOS_BOX86_SITE = $(call github,ptitSeb,box86,$(PANICOS_BOX86_VERSION))
PANICOS_BOX86_LICENSE = MIT
PANICOS_BOX86_LICENSE_FILES = LICENSE

# box86 and bash-x86 are armhf binaries. Buildroot's check-bin-arch rejects
# non-target-arch ELFs; /usr/share is in the built-in ignore list, so we
# install the real binaries there and symlink from /usr/bin.

BOX86_CROSS = arm-linux-gnueabihf-
BOX86_BUILD_DIR = $(@D)/build-armhf

define PANICOS_BOX86_CONFIGURE_CMDS
	mkdir -p $(BOX86_BUILD_DIR)
	cmake -S $(@D) -B $(BOX86_BUILD_DIR) \
		-DCMAKE_BUILD_TYPE=Release \
		-DARM_DYNAREC=On \
		-DRPI4ARM64=On \
		-DNOGIT=On \
		-DCMAKE_SYSTEM_NAME=Linux \
		-DCMAKE_SYSTEM_PROCESSOR=arm \
		-DCMAKE_C_COMPILER=$(BOX86_CROSS)gcc \
		-DCMAKE_CXX_COMPILER=$(BOX86_CROSS)g++ \
		-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
		-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
		-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
endef

define PANICOS_BOX86_BUILD_CMDS
	$(MAKE) -C $(BOX86_BUILD_DIR) -j$(PARALLEL_JOBS)
endef

define PANICOS_BOX86_INSTALL_TARGET_CMDS
	mkdir -p $(TARGET_DIR)/usr/share/box86/bin
	$(INSTALL) -m 755 $(BOX86_BUILD_DIR)/box86 $(TARGET_DIR)/usr/share/box86/bin/box86
	ln -sf /usr/share/box86/bin/box86 $(TARGET_DIR)/usr/bin/box86
	if [ -d $(@D)/x86lib ]; then \
		mkdir -p $(TARGET_DIR)/usr/share/box86/lib; \
		cp -r $(@D)/x86lib/. $(TARGET_DIR)/usr/share/box86/lib/; \
	fi
	if [ -f $(@D)/tests/bash ]; then \
		$(INSTALL) -m 755 $(@D)/tests/bash $(TARGET_DIR)/usr/share/box86/bin/bash-x86; \
		ln -sf /usr/share/box86/bin/bash-x86 $(TARGET_DIR)/usr/bin/bash-x86; \
	fi
	$(INSTALL) -D -m 644 $(PANICOS_BOX86_PKGDIR)/binfmt-box86.conf \
		$(TARGET_DIR)/usr/lib/binfmt.d/box86.conf
	$(INSTALL) -D -m 644 $(PANICOS_BOX86_PKGDIR)/box86.profile \
		$(TARGET_DIR)/etc/profile.d/box86.sh
endef

$(eval $(generic-package))

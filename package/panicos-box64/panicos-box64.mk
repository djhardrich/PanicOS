################################################################################
#
# panicos-box64
#
################################################################################

PANICOS_BOX64_VERSION = 3ec5de03c786333ed8d5a51c5b35a8bd6e22b229
PANICOS_BOX64_SITE = $(call github,ptitSeb,box64,$(PANICOS_BOX64_VERSION))
PANICOS_BOX64_LICENSE = MIT
PANICOS_BOX64_LICENSE_FILES = LICENSE

PANICOS_BOX64_CONF_OPTS = \
	-DCMAKE_BUILD_TYPE=Release \
	-DARM_DYNAREC=On \
	-DNOGIT=On

# Install box64 binary + x64libs (bundled x86_64 shims that box64 ships)
define PANICOS_BOX64_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 755 $(@D)/box64 $(TARGET_DIR)/usr/bin/box64
	if [ -d $(@D)/x64lib ]; then \
		mkdir -p $(TARGET_DIR)/usr/share/box64/lib; \
		cp -r $(@D)/x64lib/. $(TARGET_DIR)/usr/share/box64/lib/; \
	fi
endef

# binfmt_misc registration — loaded by systemd-binfmt on boot
define PANICOS_BOX64_INSTALL_INIT_SYSTEMD
	$(INSTALL) -D -m 644 $(PANICOS_BOX64_PKGDIR)/binfmt-box64.conf \
		$(TARGET_DIR)/usr/lib/binfmt.d/box64.conf
endef

# profile.d env — picked up by every login shell / ES launch
define PANICOS_BOX64_INSTALL_TARGET_FIXUP
	$(INSTALL) -D -m 644 $(PANICOS_BOX64_PKGDIR)/box64.profile \
		$(TARGET_DIR)/etc/profile.d/box64.sh
endef

PANICOS_BOX64_POST_INSTALL_TARGET_HOOKS += PANICOS_BOX64_INSTALL_TARGET_FIXUP

$(eval $(cmake-package))

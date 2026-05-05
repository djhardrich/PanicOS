################################################################################
#
# panicos-umtprd
#
# Lightweight USB MTP responder daemon used by usbgadget file_transfer mode.
# Source: https://github.com/viveris/uMTP-Responder
# Version matched to ROCKNIX's vendored copy (sysutils/umtprd/package.mk).
#
################################################################################

PANICOS_UMTPRD_VERSION = umtprd-1.6.8
PANICOS_UMTPRD_SITE = $(call github,viveris,uMTP-Responder,$(PANICOS_UMTPRD_VERSION))
PANICOS_UMTPRD_LICENSE = GPL-3.0+
PANICOS_UMTPRD_LICENSE_FILES = LICENSE

define PANICOS_UMTPRD_BUILD_CMDS
	$(MAKE) -C $(@D) \
		CC="$(TARGET_CC)" \
		CFLAGS="$(TARGET_CFLAGS) -I./inc" \
		LDFLAGS="$(TARGET_LDFLAGS)"
endef

define PANICOS_UMTPRD_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/umtprd \
		$(TARGET_DIR)/usr/sbin/umtprd
	$(INSTALL) -D -m 0644 $(PANICOS_UMTPRD_PKGDIR)/files/umtprd.conf \
		$(TARGET_DIR)/etc/umtprd/umtprd.conf
endef

$(eval $(generic-package))

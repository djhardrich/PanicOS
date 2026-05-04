################################################################################
#
# panicos-samba
#
# Installs a minimal Samba (smbd) configuration that shares /storage over
# the local network. Disabled by default — the ES network settings toggle
# enables it by `touch /storage/.cache/services/smb.conf` and calls
# `systemctl start smbd`. The smbd.service has a ConditionPathExists on
# that touch file so it auto-restores the user's choice on next boot.
#
################################################################################

PANICOS_SAMBA_VERSION = 1.0
PANICOS_SAMBA_SITE = $(BR2_EXTERNAL_PANICOS_PATH)/package/panicos-samba
PANICOS_SAMBA_SITE_METHOD = local
PANICOS_SAMBA_LICENSE = GPL-2.0
PANICOS_SAMBA_DEPENDENCIES = samba4

define PANICOS_SAMBA_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0644 $(PANICOS_SAMBA_PKGDIR)/files/smb.conf \
		$(TARGET_DIR)/etc/samba/smb.conf
	$(INSTALL) -D -m 0644 $(PANICOS_SAMBA_PKGDIR)/files/panicos-samba.conf \
		$(TARGET_DIR)/usr/lib/tmpfiles.d/panicos-samba.conf
endef

define PANICOS_SAMBA_INSTALL_INIT_SYSTEMD
	$(INSTALL) -D -m 0644 $(PANICOS_SAMBA_PKGDIR)/files/smbd.service \
		$(TARGET_DIR)/usr/lib/systemd/system/smbd.service
	# Enable smbd so systemd attempts to start it at boot — the
	# ConditionPathExists in the unit suppresses startup when the user
	# hasn't toggled samba on, so this is safe to always enable.
	mkdir -p $(TARGET_DIR)/usr/lib/systemd/system/multi-user.target.wants
	ln -sf ../smbd.service \
		$(TARGET_DIR)/usr/lib/systemd/system/multi-user.target.wants/smbd.service
endef

$(eval $(generic-package))

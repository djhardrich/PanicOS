################################################################################
#
# panicos-sshkeys
#
# Generates per-device OpenSSH host keys at first boot via a one-shot
# systemd service. Keys live in /etc/ssh/ (on the overlay) and persist
# across normal reboots; wiped only when the user resets the overlay.
#
################################################################################

PANICOS_SSHKEYS_VERSION = 1.0
PANICOS_SSHKEYS_SITE = $(BR2_EXTERNAL_PANICOS_PATH)/package/panicos-sshkeys
PANICOS_SSHKEYS_SITE_METHOD = local
PANICOS_SSHKEYS_LICENSE = GPL-2.0
PANICOS_SSHKEYS_DEPENDENCIES = openssh

define PANICOS_SSHKEYS_INSTALL_TARGET_CMDS
	install -D -m 0755 $(PANICOS_SSHKEYS_PKGDIR)/files/panicos-sshkeys \
		$(TARGET_DIR)/usr/sbin/panicos-sshkeys
	install -D -m 0644 $(PANICOS_SSHKEYS_PKGDIR)/files/panicos-sshkeys.service \
		$(TARGET_DIR)/usr/lib/systemd/system/panicos-sshkeys.service
	# Allow root password logins. OpenSSH 10.x defaults to prohibit-password
	# which blocks ES's SSH toggle (the user has no other login mechanism).
	# UseDNS no avoids 5-10 s delay on connection when no DNS is reachable.
	$(SED) 's|^#PermitRootLogin.*|PermitRootLogin yes|' \
		$(TARGET_DIR)/etc/ssh/sshd_config
	$(SED) 's|^#UseDNS.*|UseDNS no|' \
		$(TARGET_DIR)/etc/ssh/sshd_config
endef

define PANICOS_SSHKEYS_INSTALL_INIT_SYSTEMD
	mkdir -p $(TARGET_DIR)/usr/lib/systemd/system/sysinit.target.wants
	ln -sf ../panicos-sshkeys.service \
		$(TARGET_DIR)/usr/lib/systemd/system/sysinit.target.wants/panicos-sshkeys.service
	mkdir -p $(TARGET_DIR)/usr/lib/systemd/system/multi-user.target.wants
	ln -sf ../sshd.service \
		$(TARGET_DIR)/usr/lib/systemd/system/multi-user.target.wants/sshd.service
endef

$(eval $(generic-package))

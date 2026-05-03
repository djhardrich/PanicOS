################################################################################
#
# panicos-sshkeys
#
# Drives PanicOS's SSH server lifecycle. Used to generate per-device
# dropbear host keys at first boot — but we switched to OpenSSH (SFTP
# works properly, dropbear's SFTP support is flaky), and OpenSSH's own
# sshd.service ships an ExecStartPre=`ssh-keygen -A` that handles host
# keys idempotently. So this package now just enables sshd.service at
# multi-user.target. Name kept for compatibility with existing flavor
# fragments.
#
################################################################################

PANICOS_SSHKEYS_VERSION = 1.0
PANICOS_SSHKEYS_SITE = $(BR2_EXTERNAL_PANICOS_PATH)/package/panicos-sshkeys
PANICOS_SSHKEYS_SITE_METHOD = local
PANICOS_SSHKEYS_LICENSE = GPL-2.0
PANICOS_SSHKEYS_DEPENDENCIES = openssh

define PANICOS_SSHKEYS_INSTALL_INIT_SYSTEMD
	# OpenSSH ships /usr/lib/systemd/system/sshd.service but doesn't
	# enable it by default. Symlink into multi-user.target.wants/ so it
	# starts at boot. Host keys auto-generate on first start via the
	# unit's ExecStartPre=ssh-keygen -A.
	mkdir -p $(TARGET_DIR)/usr/lib/systemd/system/multi-user.target.wants
	ln -sf ../sshd.service \
		$(TARGET_DIR)/usr/lib/systemd/system/multi-user.target.wants/sshd.service
endef

$(eval $(generic-package))

################################################################################
#
# networkmanager
#
# NetworkManager 1.51.4 with iwd Wi-Fi backend, vendored from ROCKNIX
# (commit beb5d8a239). Buildroot 2026.02.1 doesn't ship a networkmanager
# package, so we build it from the upstream gnome.org tarball using the
# same meson option set ROCKNIX uses.
#
# Layout in target:
#   /usr/sbin/NetworkManager                                — daemon
#   /usr/bin/nmcli                                          — CLI client
#   /etc/NetworkManager/NetworkManager.conf                 — main config
#   /etc/dbus-1/system.d/org.freedesktop.NetworkManager.conf — bus policy
#   /usr/lib/systemd/system/NetworkManager.service          — systemd unit
#   /usr/lib/systemd/system/network-online.service          — wait-online unit
#   /usr/lib/tmpfiles.d/z_02_networkmanager.conf            — /storage skel
#   /etc/iwd/main.conf                                      — iwd configured to
#                                                             let NM do DHCP/IP
#
################################################################################

NETWORKMANAGER_VERSION = 1.51.4
NETWORKMANAGER_SOURCE = NetworkManager-$(NETWORKMANAGER_VERSION).tar.xz
NETWORKMANAGER_SITE = https://download.gnome.org/sources/NetworkManager/1.51
NETWORKMANAGER_LICENSE = GPL-2.0+
NETWORKMANAGER_LICENSE_FILES = COPYING

# sha256 from https://download.gnome.org/sources/NetworkManager/1.51/NetworkManager-1.51.4.sha256sum
# Note this isn't a buildroot-style .hash file — we keep the hash inline + a
# matching .hash file below for the host-fetcher.

NETWORKMANAGER_DEPENDENCIES = \
	host-pkgconf \
	dbus \
	libglib2 \
	libndp \
	libnss \
	systemd \
	util-linux \
	readline \
	ncurses

# Disable everything we don't ship — keeps the build fast and the binary lean.
# Mirrors ROCKNIX's package.mk (commit beb5d8a239) meson option set.
NETWORKMANAGER_CONF_OPTS = \
	-Dsystemdsystemunitdir=/usr/lib/systemd/system \
	-Dudev_dir=/usr/lib/udev \
	-Ddbus_conf_dir=/etc/dbus-1/system.d \
	-Dsession_tracking=no \
	-Dsession_tracking_consolekit=false \
	-Dsuspend_resume=auto \
	-Dpolkit=false \
	-Dselinux=false \
	-Dsystemd_journal=false \
	-Dlibaudit=no \
	-Dlibpsl=false \
	-Dwifi=true \
	-Dwext=false \
	-Diwd=true \
	-Dconfig_wifi_backend_default=iwd \
	-Dppp=false \
	-Dmodem_manager=false \
	-Dofono=false \
	-Dconcheck=false \
	-Dteamdctl=false \
	-Dovs=false \
	-Dnmcli=true \
	-Dnmtui=false \
	-Dnm_cloud_setup=false \
	-Dbluez5_dun=false \
	-Debpf=false \
	-Difcfg_rh=false \
	-Difupdown=false \
	-Ddhclient=no \
	-Ddhcpcd=no \
	-Dconfig_dhcp_default=internal \
	-Dintrospection=false \
	-Dvapi=false \
	-Ddocs=false \
	-Dtests=no \
	-Dfirewalld_zone=false \
	-Dmore_logging=false \
	-Dvalgrind=no \
	-Dqt=false \
	-Dreadline=auto \
	-Dconfig_plugins_default=keyfile \
	-Dcrypto=nss

define NETWORKMANAGER_INSTALL_TARGET_CMDS_EXTRA
	# Drop ROCKNIX-vendored config files into the target rootfs.
	$(INSTALL) -D -m 0644 $(NETWORKMANAGER_PKGDIR)/files/NetworkManager.conf \
		$(TARGET_DIR)/etc/NetworkManager/NetworkManager.conf
	$(INSTALL) -D -m 0644 $(NETWORKMANAGER_PKGDIR)/files/org.freedesktop.NetworkManager.conf \
		$(TARGET_DIR)/etc/dbus-1/system.d/org.freedesktop.NetworkManager.conf
	$(INSTALL) -D -m 0644 $(NETWORKMANAGER_PKGDIR)/files/z_02_networkmanager.conf \
		$(TARGET_DIR)/usr/lib/tmpfiles.d/z_02_networkmanager.conf

	# Override iwd's main.conf so iwd hands off DHCP/IP to NetworkManager.
	# ROCKNIX's iwd config (vendored verbatim from their main.conf):
	#   EnableNetworkConfiguration=false  ← we want this; lets NM own DHCP
	# Without this, both iwd AND NM try to manage IP and they fight.
	$(INSTALL) -D -m 0644 $(NETWORKMANAGER_PKGDIR)/files/iwd-main.conf \
		$(TARGET_DIR)/etc/iwd/main.conf
endef
NETWORKMANAGER_POST_INSTALL_TARGET_HOOKS += NETWORKMANAGER_INSTALL_TARGET_CMDS_EXTRA

define NETWORKMANAGER_INSTALL_INIT_SYSTEMD
	# NetworkManager.service from ROCKNIX (vendored verbatim).
	# WantedBy=multi-user.target — auto-enable.
	$(INSTALL) -D -m 0644 $(NETWORKMANAGER_PKGDIR)/files/NetworkManager.service \
		$(TARGET_DIR)/usr/lib/systemd/system/NetworkManager.service
	$(INSTALL) -D -m 0644 $(NETWORKMANAGER_PKGDIR)/files/network-online.service \
		$(TARGET_DIR)/usr/lib/systemd/system/network-online.service
	mkdir -p $(TARGET_DIR)/usr/lib/systemd/system/multi-user.target.wants
	ln -sf ../NetworkManager.service \
		$(TARGET_DIR)/usr/lib/systemd/system/multi-user.target.wants/NetworkManager.service
	ln -sf ../network-online.service \
		$(TARGET_DIR)/usr/lib/systemd/system/multi-user.target.wants/network-online.service
endef

$(eval $(meson-package))

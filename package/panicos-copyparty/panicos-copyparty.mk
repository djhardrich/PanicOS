################################################################################
#
# panicos-copyparty
#
# Installs copyparty as a user-togglable HTTP file server for /storage.
# Ships the upstream single-file .pyz distribution — no compilation.
# Port 3923 (copyparty's default). Disabled by default; the ES network
# settings toggle touches /storage/.cache/services/copyparty.conf and
# starts/stops the service.
#
# Bump COPYPARTY_VERSION + SHA256 to track upstream releases.
#
################################################################################

PANICOS_COPYPARTY_VERSION = 1.0
PANICOS_COPYPARTY_SITE = $(BR2_EXTERNAL_PANICOS_PATH)/package/panicos-copyparty
PANICOS_COPYPARTY_SITE_METHOD = local
PANICOS_COPYPARTY_LICENSE = MIT
PANICOS_COPYPARTY_DEPENDENCIES = python3

COPYPARTY_VERSION = 1.20.14
COPYPARTY_URL = https://github.com/9001/copyparty/releases/download/v$(COPYPARTY_VERSION)/copyparty.pyz
COPYPARTY_SHA256 = e90c6e5da31fd1288c1c5f99633325045409b8790d26fa6a880266c95c11760f

define PANICOS_COPYPARTY_DOWNLOAD
	mkdir -p $(@D)/dl
	if [ ! -f "$(@D)/dl/copyparty.pyz" ]; then \
		echo ">>> panicos-copyparty: fetching copyparty $(COPYPARTY_VERSION)"; \
		wget -q -O "$(@D)/dl/copyparty.pyz.tmp" "$(COPYPARTY_URL)" || \
			{ rm -f "$(@D)/dl/copyparty.pyz.tmp"; exit 1; }; \
		mv "$(@D)/dl/copyparty.pyz.tmp" "$(@D)/dl/copyparty.pyz"; \
	fi; \
	got=$$(sha256sum "$(@D)/dl/copyparty.pyz" | awk '{print $$1}'); \
	if [ "$$got" != "$(COPYPARTY_SHA256)" ]; then \
		echo "ERROR: sha256 mismatch for copyparty.pyz" >&2; \
		echo "  got:  $$got" >&2; \
		echo "  want: $(COPYPARTY_SHA256)" >&2; \
		rm -f "$(@D)/dl/copyparty.pyz"; \
		exit 1; \
	fi
endef
PANICOS_COPYPARTY_PRE_BUILD_HOOKS += PANICOS_COPYPARTY_DOWNLOAD

define PANICOS_COPYPARTY_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/dl/copyparty.pyz \
		$(TARGET_DIR)/usr/bin/copyparty.pyz
endef

define PANICOS_COPYPARTY_INSTALL_INIT_SYSTEMD
	# ES calls `systemctl enable --now simple-http-server` /
	# `systemctl disable --now simple-http-server` — the enable/disable
	# cycle manages the multi-user.target.wants symlink itself, so we
	# only install the unit; we do NOT pre-enable it.
	$(INSTALL) -D -m 0644 $(PANICOS_COPYPARTY_PKGDIR)/files/simple-http-server.service \
		$(TARGET_DIR)/usr/lib/systemd/system/simple-http-server.service
endef

$(eval $(generic-package))

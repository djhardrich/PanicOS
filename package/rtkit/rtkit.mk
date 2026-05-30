################################################################################
#
# rtkit
#
# RealtimeKit D-Bus service (PipeWire-hosted fork). Grants RT scheduling
# priority to PipeWire / JACK clients on request.
#
################################################################################

RTKIT_VERSION = v0.14
RTKIT_SITE = https://gitlab.freedesktop.org/pipewire/rtkit/-/archive/$(RTKIT_VERSION)
RTKIT_SOURCE = rtkit-$(RTKIT_VERSION).tar.gz
RTKIT_LICENSE = GPL-3.0+, BSD-3-Clause
RTKIT_LICENSE_FILES = LICENSE
RTKIT_DEPENDENCIES = host-pkgconf dbus libcap

# rtkit-daemon drops privileges to a dedicated unprivileged user.
define RTKIT_USERS
	rtkit -1 rtkit -1 * - - - RealtimeKit daemon
endef

# rtkit's meson uses `xxd -i` to embed org.freedesktop.RealtimeKit1.xml into
# xml-introspection.h; when xxd is absent it falls back to a pre-existing
# xml-introspection.h that the tarball does NOT ship. xxd isn't in the build
# environment, so pre-generate that header ourselves (coreutils only). The .c
# includes it inside `{ ... ,0x00 }`, so it must be a comma-separated hex byte
# list with no trailing comma — exactly what `xxd -i < file` emits.
define RTKIT_GEN_INTROSPECTION
	od -An -v -tx1 $(@D)/org.freedesktop.RealtimeKit1.xml \
		| tr -s ' \n' '\n' | grep -v '^$$' | sed 's/^/0x/' \
		| paste -sd, > $(@D)/xml-introspection.h
endef
RTKIT_PRE_CONFIGURE_HOOKS += RTKIT_GEN_INTROSPECTION

RTKIT_CONF_OPTS = -Dinstalled_tests=false

ifeq ($(BR2_PACKAGE_SYSTEMD),y)
RTKIT_DEPENDENCIES += systemd
RTKIT_CONF_OPTS += -Dlibsystemd=enabled
else
RTKIT_CONF_OPTS += -Dlibsystemd=disabled
endif

$(eval $(meson-package))

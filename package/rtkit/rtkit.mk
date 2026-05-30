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

# NOTE: rtkit's meson embeds org.freedesktop.RealtimeKit1.xml into
# xml-introspection.h via `xxd -i`; the no-xxd fallback expects a pre-existing
# header the tarball doesn't ship. xxd is provided in the build image
# (docker/Dockerfile), so the native codepath is used — no workaround needed.

RTKIT_CONF_OPTS = -Dinstalled_tests=false

ifeq ($(BR2_PACKAGE_SYSTEMD),y)
RTKIT_DEPENDENCIES += systemd
RTKIT_CONF_OPTS += -Dlibsystemd=enabled
else
RTKIT_CONF_OPTS += -Dlibsystemd=disabled
endif

$(eval $(meson-package))

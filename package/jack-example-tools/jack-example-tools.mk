################################################################################
#
# jack-example-tools
#
# JACK CLI tools (jack_lsp, jack_connect, jack_transport, ...). Split out of
# jack2 1.9.22+; jack2 no longer ships them, only jackd.
#
################################################################################

JACK_EXAMPLE_TOOLS_VERSION = 4
JACK_EXAMPLE_TOOLS_SITE = $(call github,jackaudio,jack-example-tools,$(JACK_EXAMPLE_TOOLS_VERSION))
JACK_EXAMPLE_TOOLS_LICENSE = GPL-2.0+
JACK_EXAMPLE_TOOLS_DEPENDENCIES = host-pkgconf jack2

# Optional deps we already ship — listing them makes meson's `auto` features
# (jack_rec, alsa_in/out, opus netsource, readline jack_transport) build.
JACK_EXAMPLE_TOOLS_DEPENDENCIES += \
	alsa-lib \
	libsamplerate \
	libsndfile \
	ncurses \
	opus \
	readline

# zalsa needs zita-alsa-pcmi, which we don't package.
JACK_EXAMPLE_TOOLS_CONF_OPTS = -Dzalsa=disabled

$(eval $(meson-package))

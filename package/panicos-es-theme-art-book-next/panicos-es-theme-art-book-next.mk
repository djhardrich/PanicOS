################################################################################
#
# panicos-es-theme-art-book-next
#
# Anthony Caccese's "Art Book Next" EmulationStation theme. Pinned to
# the same SHA ROCKNIX ships at so we match their (and Knulli's) look
# verbatim — handheld-distro users expect this theme as default.
#
################################################################################

PANICOS_ES_THEME_ART_BOOK_NEXT_VERSION = c7e8ff1c887ac76445ef90ffa4007c15b4e0cadf
PANICOS_ES_THEME_ART_BOOK_NEXT_SITE = $(call github,anthonycaccese,art-book-next-es,$(PANICOS_ES_THEME_ART_BOOK_NEXT_VERSION))
# Upstream LICENSE.md is a custom no-commercial license. Track but don't
# enforce — it's distributable in non-commercial handheld distros, which
# is what PanicOS is.
PANICOS_ES_THEME_ART_BOOK_NEXT_LICENSE = CUSTOM (Art Book Next, non-commercial)
PANICOS_ES_THEME_ART_BOOK_NEXT_LICENSE_FILES = LICENSE.md

# Install under /etc/emulationstation/themes/ — ThemeData.cpp:2370 adds
# this path unconditionally as a Retropie-compat fallback, so ES finds
# the theme regardless of which distro #define is active. With
# -DROCKNIX=1 (which we do compile with), Paths.cpp picks
# /storage/.config/emulationstation/themes as the primary themes path,
# which is empty on first boot — installing there would mean shipping
# nothing in the rootfs. The /etc fallback dodges that whole dance.
PANICOS_ES_THEME_ART_BOOK_NEXT_THEMEDIR = /etc/emulationstation/themes/es-theme-art-book-next

define PANICOS_ES_THEME_ART_BOOK_NEXT_INSTALL_TARGET_CMDS
	mkdir -p $(TARGET_DIR)$(PANICOS_ES_THEME_ART_BOOK_NEXT_THEMEDIR)
	cp -a $(@D)/. $(TARGET_DIR)$(PANICOS_ES_THEME_ART_BOOK_NEXT_THEMEDIR)/
	# ROCKNIX trim: drop subthemes we don't ship and de-reference them
	# from theme.xml so ES doesn't error on missing includes.
	rm -rf $(TARGET_DIR)$(PANICOS_ES_THEME_ART_BOOK_NEXT_THEMEDIR)/_inc/systems/artwork-circuit
	rm -rf $(TARGET_DIR)$(PANICOS_ES_THEME_ART_BOOK_NEXT_THEMEDIR)/_inc/systems/artwork-classic
	rm -rf $(TARGET_DIR)$(PANICOS_ES_THEME_ART_BOOK_NEXT_THEMEDIR)/_inc/systems/artwork-nintendont
	rm -rf $(TARGET_DIR)$(PANICOS_ES_THEME_ART_BOOK_NEXT_THEMEDIR)/_inc/systems/artwork-noir
	rm -rf $(TARGET_DIR)$(PANICOS_ES_THEME_ART_BOOK_NEXT_THEMEDIR)/_inc/systems/artwork-outline
	sed -i '/<include name="\(noir\|nintendont\|circuit\|outline\)"/d' \
		$(TARGET_DIR)$(PANICOS_ES_THEME_ART_BOOK_NEXT_THEMEDIR)/theme.xml
endef

$(eval $(generic-package))

################################################################################
#
# panicos-es-theme
#
# PanicOS's own monochrome terminal-style EmulationStation theme.
# No external downloads — fonts are vendored (Noto Sans Mono, SIL OFL 1.1).
# License: MIT
#
################################################################################

PANICOS_ES_THEME_VERSION = 1.0
PANICOS_ES_THEME_SITE = $(BR2_EXTERNAL_PANICOS_PATH)/package/panicos-es-theme
PANICOS_ES_THEME_SITE_METHOD = local
PANICOS_ES_THEME_LICENSE = MIT AND OFL-1.1
PANICOS_ES_THEME_LICENSE_FILES =

ES_THEMES_DIR = $(TARGET_DIR)/etc/emulationstation/themes

define PANICOS_ES_THEME_INSTALL_TARGET_CMDS
	mkdir -p $(ES_THEMES_DIR)/panicos
	cp -a $(@D)/files/panicos/. $(ES_THEMES_DIR)/panicos/
endef

$(eval $(generic-package))

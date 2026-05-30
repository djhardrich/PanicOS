################################################################################
#
# sc3-plugins
#
# Official SC UGen plugin collection. Version is kept in lock-step with
# supercollider so plugin ABI always matches.
#
################################################################################

SC3_PLUGINS_VERSION = Version-3.13.0
SC3_PLUGINS_SITE = https://github.com/supercollider/sc3-plugins
SC3_PLUGINS_SITE_METHOD = git
SC3_PLUGINS_GIT_SUBMODULES = YES
SC3_PLUGINS_LICENSE = GPL-3.0+
SC3_PLUGINS_LICENSE_FILES = LICENSE

SC3_PLUGINS_DEPENDENCIES = supercollider fftw-single

SC3_PLUGINS_CONF_OPTS = \
	-DCMAKE_BUILD_TYPE=Release \
	-DSC_PATH=$(SUPERCOLLIDER_SRC_DIR) \
	-DSUPERNOVA=OFF \
	-DCMAKE_INSTALL_PREFIX=/usr

$(eval $(cmake-package))

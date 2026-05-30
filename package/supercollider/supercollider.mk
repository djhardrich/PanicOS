################################################################################
#
# supercollider
#
# Headless build: scsynth (synthesis server) + sclang (language interpreter).
# No Qt, no X11, no IDE. JACK via pipewire-jack (libjack.so auto-detected
# by cmake via pkg-config).
#
################################################################################

SUPERCOLLIDER_VERSION = Version-3.13.0
SUPERCOLLIDER_SITE = https://github.com/supercollider/supercollider
SUPERCOLLIDER_SITE_METHOD = git
SUPERCOLLIDER_GIT_SUBMODULES = YES
SUPERCOLLIDER_LICENSE = GPL-3.0+
SUPERCOLLIDER_LICENSE_FILES = COPYING

SUPERCOLLIDER_DEPENDENCIES = \
	alsa-lib \
	boost \
	fftw-single \
	host-pkgconf \
	libsndfile \
	readline

# Expose SC source tree path for sc3-plugins and community plugin packages.
# Plugin cmake builds require -DSC_PATH to point at the source tree
# (include/plugin_interface/ etc.) — the installed headers are insufficient.
SUPERCOLLIDER_SRC_DIR = $(BUILD_DIR)/supercollider-$(SUPERCOLLIDER_VERSION)

SUPERCOLLIDER_CONF_OPTS = \
	-DCMAKE_BUILD_TYPE=Release \
	-DSUPERNOVA=OFF \
	-DNO_X11=ON \
	-DSC_IDE=OFF \
	-DSC_QT=OFF \
	-DSC_EL=OFF \
	-DSC_ED=OFF \
	-DSC_VIM=OFF \
	-DINSTALL_HELP=OFF \
	-DINSTALL_OLD_HELP=OFF \
	-DINSTALL_EXAMPLE_PROJECTS=OFF \
	-DSC_HIDAPI=OFF \
	-DSC_ABLETON_LINK=OFF \
	-DSCLANG_SERVER_INTERFACE=ON \
	-DSOUNDFILE=ON

$(eval $(cmake-package))

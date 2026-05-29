################################################################################
#
# panicos-powervr-ge8300
#
# PowerVR GE8300 userspace GPU driver blobs for the TrimUI Brick.
# Source: knulli-cfw/ge8300-drivers (userspace-only; fbdev ABI).
#
# The kernel component (pvrsrvkm.ko) is ABI-locked to Linux 4.9.191 and
# is pre-built into the vendor kernel blob — this package provides only
# the userspace side:
#   libEGL.so, libGLESv2.so, libGLESv1_CM.so, libVK_IMG.so
#   pvrsrvctl (user-space daemon launcher)
#   rgx.fw.22.102.54.38 (GPU firmware, loaded by pvrsrvkm at runtime)
#
# Only meaningful with the vendor kernel flavor (KERNEL=vendor).
# With the mainline kernel, pvrsrvkm.ko is not present and pvrsrvctl
# will fail to initialize; install is gated on BR2_PACKAGE_PANICOS_POWERVR_GE8300.
#
################################################################################

PANICOS_POWERVR_GE8300_VERSION = 3334cfc9f363dae79c9107d43f8073e0c9db12e5
PANICOS_POWERVR_GE8300_SITE = https://github.com/knulli-cfw/ge8300-drivers.git
PANICOS_POWERVR_GE8300_SITE_METHOD = git

PANICOS_POWERVR_GE8300_LICENSE = Proprietary
PANICOS_POWERVR_GE8300_REDISTRIBUTE = NO
PANICOS_POWERVR_GE8300_INSTALL_STAGING = YES
PANICOS_POWERVR_GE8300_PROVIDES = libegl libgles

define PANICOS_POWERVR_GE8300_INSTALL_STAGING_CMDS
	mkdir -p $(STAGING_DIR)/usr/lib/pkgconfig $(STAGING_DIR)/usr/include
	cp -rf $(@D)/3rdparty/include/khronos/* $(STAGING_DIR)/usr/include/
	cp -rf $(@D)/fbdev/glibc/lib64/* $(STAGING_DIR)/usr/lib/
	ln -sf libGLES_CM.so $(STAGING_DIR)/usr/lib/libGLESv1_CM.so
	$(INSTALL) -D -m 0644 $(BR2_EXTERNAL_PANICOS_PATH)/package/panicos-powervr-ge8300/egl.pc \
		$(STAGING_DIR)/usr/lib/pkgconfig/egl.pc
	$(INSTALL) -D -m 0644 $(BR2_EXTERNAL_PANICOS_PATH)/package/panicos-powervr-ge8300/glesv2.pc \
		$(STAGING_DIR)/usr/lib/pkgconfig/glesv2.pc
endef

PANICOS_POWERVR_GE8300_KMOD_SRC = \
	$(BR2_EXTERNAL_PANICOS_PATH)/third_party/knulli/board/batocera/allwinner/a133/fsoverlay/lib/modules/4.9.191

define PANICOS_POWERVR_GE8300_INSTALL_TARGET_CMDS
	mkdir -p $(TARGET_DIR)/usr/lib $(TARGET_DIR)/usr/bin $(TARGET_DIR)/lib/firmware
	mkdir -p $(TARGET_DIR)/lib/modules/4.9.191
	cp -rf $(@D)/fbdev/glibc/lib64/* $(TARGET_DIR)/usr/lib/
	$(INSTALL) -D -m 0755 $(@D)/fbdev/glibc/bin/pvrsrvctl $(TARGET_DIR)/usr/bin/pvrsrvctl
	# GPU firmware blob — loaded by pvrsrvkm.ko at first GPU access
	if [ -f $(@D)/firmware/rgx.fw.22.102.54.38 ]; then \
		$(INSTALL) -D -m 0644 $(@D)/firmware/rgx.fw.22.102.54.38 \
			$(TARGET_DIR)/lib/firmware/rgx.fw.22.102.54.38; \
	fi
	# pvrsrvkm.ko — GPU kernel module pre-built for Linux 4.9.191 (ABI-locked).
	# Sourced from the Knulli submodule (shared fsoverlay across all A133 devices).
	# Note: xradio_*.ko from the same fsoverlay are for the TrimUI Smart Pro
	# (confirmed XR829). The Brick's WiFi chip is unconfirmed — do NOT include
	# xradio blindly. Add a device-specific WiFi package once confirmed on HW.
	if [ -f $(PANICOS_POWERVR_GE8300_KMOD_SRC)/pvrsrvkm.ko ]; then \
		$(INSTALL) -D -m 0644 $(PANICOS_POWERVR_GE8300_KMOD_SRC)/pvrsrvkm.ko \
			$(TARGET_DIR)/lib/modules/4.9.191/pvrsrvkm.ko; \
	else \
		echo "WARNING: pvrsrvkm.ko not found in knulli submodule — GPU will not initialise"; \
	fi
endef

$(eval $(generic-package))

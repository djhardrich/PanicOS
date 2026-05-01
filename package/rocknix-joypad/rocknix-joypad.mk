################################################################################
#
# rocknix-joypad — out-of-tree handheld-gamepad kernel module
#
################################################################################

ROCKNIX_JOYPAD_VERSION = 7647fdb0fc89cd69b284903bf7707e861df5dc7e
ROCKNIX_JOYPAD_SITE = $(call github,ROCKNIX,rocknix-joypad,$(ROCKNIX_JOYPAD_VERSION))
ROCKNIX_JOYPAD_LICENSE = GPL-2.0
ROCKNIX_JOYPAD_LICENSE_FILES = CREDITS

# Upstream Makefile chooses obj-m based on DEVICE env. We override to
# build BOTH variants (singleadc for H700/RK3399, regular for S922X/RK3588) —
# udev autoloads whichever matches the DT compatible at runtime, so no
# harm in shipping both. Patching out the Makefile's DEVICE switch keeps
# this driver source-compatible with the upstream Makefile pattern.
define ROCKNIX_JOYPAD_PATCH_MAKEFILE
	printf 'obj-m := rocknix-joypad.o rocknix-singleadc-joypad.o\n' \
		> $(@D)/Makefile
endef
ROCKNIX_JOYPAD_POST_EXTRACT_HOOKS += ROCKNIX_JOYPAD_PATCH_MAKEFILE

$(eval $(kernel-module))
$(eval $(generic-package))

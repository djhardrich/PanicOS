################################################################################
#
# dtbocfg — configfs-based runtime device-tree overlay loader
#
################################################################################

DTBOCFG_VERSION = 0.1.0
DTBOCFG_SITE = $(call github,ikwzm,dtbocfg,v$(DTBOCFG_VERSION))
DTBOCFG_LICENSE = BSD-2-Clause
DTBOCFG_LICENSE_FILES = LICENSE

$(eval $(kernel-module))
$(eval $(generic-package))

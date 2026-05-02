################################################################################
#
# python-dbussy
#
# Pure-Python libdbus wrapper. The upstream repo ships TWO modules in
# one setup.py:
#   - dbussy.py — low-level libdbus binding (via ctypes)
#   - ravel.py  — higher-level asyncio helper
# The rocknix-bluetooth-agent imports both. Pinned to the same SHA
# ROCKNIX uses (see third_party/rocknix/.../python/system/dbussy/).
#
################################################################################

PYTHON_DBUSSY_VERSION = 691a8a8a1914416b7ea1545fb931d74f2e381f09
PYTHON_DBUSSY_SITE = $(call github,ldo,dbussy,$(PYTHON_DBUSSY_VERSION))
PYTHON_DBUSSY_SETUP_TYPE = setuptools
PYTHON_DBUSSY_LICENSE = LGPL-2.1+
PYTHON_DBUSSY_LICENSE_FILES = COPYING
# dbus is the runtime libdbus dep; host-python-setuptools is the build dep.
PYTHON_DBUSSY_DEPENDENCIES = dbus

$(eval $(python-package))

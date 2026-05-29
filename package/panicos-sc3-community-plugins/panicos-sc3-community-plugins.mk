################################################################################
#
# panicos-sc3-community-plugins
#
# Builds 10 community SC UGen plugin collections from vendor/ against the
# supercollider source tree so plugin ABI matches exactly.
#
# Source: vendor/sc-community-plugins/ (populated by
#         scripts/vendor-sc-community-plugins.sh)
#
################################################################################

PANICOS_SC3_COMMUNITY_PLUGINS_VERSION = 1
PANICOS_SC3_COMMUNITY_PLUGINS_SITE = $(BR2_EXTERNAL_PANICOS_PATH)/vendor/sc-community-plugins
PANICOS_SC3_COMMUNITY_PLUGINS_SITE_METHOD = local
PANICOS_SC3_COMMUNITY_PLUGINS_LICENSE = Various (GPL/MIT/BSD/Apache per plugin)
PANICOS_SC3_COMMUNITY_PLUGINS_DEPENDENCIES = supercollider

PANICOS_SC3_COMMUNITY_PLUGINS_EXT_DIR = /usr/share/SuperCollider/Extensions

# All plugin directories (order matches build-sc-plugins.sh)
PANICOS_SC3_COMMUNITY_PLUGINS_LIST = \
	PortedPlugins f0plugins XPlayBuf NasalDemons PulsePTR \
	TrianglePTR CDSkip mi-UGens SuperBuf IBufWr

define PANICOS_SC3_COMMUNITY_PLUGINS_BUILD_CMDS
	@if [ -z "$$(ls -A $(@D) 2>/dev/null)" ]; then \
		echo "ERROR: vendor/sc-community-plugins/ is empty." >&2; \
		echo "       Run scripts/vendor-sc-community-plugins.sh first." >&2; \
		exit 1; \
	fi
	for plugin in $(PANICOS_SC3_COMMUNITY_PLUGINS_LIST); do \
		[ -d "$(@D)/$$plugin" ] || { echo "  SKIP: $$plugin (not in vendor/)"; continue; }; \
		_cxx_std=17; \
		[ "$$plugin" = "IBufWr" ] && _cxx_std=20; \
		echo "  >>> Building $$plugin (C++$$_cxx_std)"; \
		mkdir -p "$(@D)/$$plugin/build"; \
		$(HOST_DIR)/bin/cmake -S "$(@D)/$$plugin" -B "$(@D)/$$plugin/build" \
			-DCMAKE_BUILD_TYPE=Release \
			-DCMAKE_TOOLCHAIN_FILE=$(HOST_DIR)/share/buildroot/toolchainfile.cmake \
			-DSC_PATH="$(SUPERCOLLIDER_SRC_DIR)" \
			-DSUPERNOVA=OFF \
			-DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
			-DCMAKE_CXX_STANDARD=$$_cxx_std \
			-DCMAKE_INSTALL_PREFIX="$(PANICOS_SC3_COMMUNITY_PLUGINS_EXT_DIR)/$$plugin" \
		|| { echo "  WARN: cmake configure failed for $$plugin, skipping"; continue; }; \
		$(HOST_DIR)/bin/cmake --build "$(@D)/$$plugin/build" \
			-j$(PARALLEL_JOBS) \
		|| { echo "  WARN: cmake build failed for $$plugin, skipping"; continue; }; \
	done
endef

define PANICOS_SC3_COMMUNITY_PLUGINS_INSTALL_TARGET_CMDS
	for plugin in $(PANICOS_SC3_COMMUNITY_PLUGINS_LIST); do \
		[ -d "$(@D)/$$plugin/build" ] || continue; \
		_ext_dir="$(TARGET_DIR)$(PANICOS_SC3_COMMUNITY_PLUGINS_EXT_DIR)/$$plugin"; \
		mkdir -p "$$_ext_dir"; \
		DESTDIR="$(TARGET_DIR)" \
			$(HOST_DIR)/bin/cmake --build "$(@D)/$$plugin/build" \
			--target install 2>/dev/null || true; \
		_count=$$(find "$$_ext_dir" -name "*.so" 2>/dev/null | wc -l); \
		if [ "$$_count" -eq 0 ]; then \
			find "$(@D)/$$plugin/build" -name "*_scsynth.so" \
				-exec cp {} "$$_ext_dir/" \; 2>/dev/null || true; \
			find "$(@D)/$$plugin/build" -name "*.so" \
				-not -name "*_supernova.so" \
				-exec cp {} "$$_ext_dir/" \; 2>/dev/null || true; \
			find "$(@D)/$$plugin" -name "*.sc" \
				-not -path "*/HelpSource/*" \
				-exec cp {} "$$_ext_dir/" \; 2>/dev/null || true; \
		fi; \
		_final=$$(find "$$_ext_dir" -name "*.so" 2>/dev/null | wc -l); \
		echo "  $$plugin: $$_final .so file(s) installed to $$_ext_dir"; \
	done
endef

$(eval $(generic-package))

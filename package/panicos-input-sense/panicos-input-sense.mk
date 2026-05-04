################################################################################
#
# panicos-input-sense
#
# Vendors ROCKNIX's full /usr/bin and /etc/profile.d script set verbatim
# (54 scripts + 4 profile.d files), so input_sense can call all the
# helpers it expects (rocknix-fake-suspend, ledcontrol, brightness,
# headphone_sense, controller-layout, etc.) and they in turn can call
# each other / look up settings via get_setting from 001-functions.
#
# This package effectively brings ROCKNIX's userspace base over to
# PanicOS. As we add more handheld devices that ROCKNIX already supports
# (S922X, RK3566, SM6115...), the per-device behavior comes along for
# free because the same scripts dispatch on $QUIRK_DEVICE / $DEVICE_*
# env vars set by ROCKNIX's quirks profile.d.
#
# One minimal install-time patch (the script files themselves are
# byte-for-byte verbatim; only the rendered copies in the rootfs are
# tweaked):
#   1. 001-functions' SDL_GAMECONTROLLERCONFIG_FILE export points at
#      ROCKNIX's /storage/.config/SDL-GameControllerDB path, which doesn't
#      exist on PanicOS. Repoint to /usr/share/SDL-GameControllerDB
#      where panicos-launcher-tools installs the H700 Gamepad mapping.
#
################################################################################

PANICOS_INPUT_SENSE_VERSION = 1.0
PANICOS_INPUT_SENSE_SITE = $(BR2_EXTERNAL_PANICOS_PATH)/package/panicos-input-sense
PANICOS_INPUT_SENSE_SITE_METHOD = local
PANICOS_INPUT_SENSE_LICENSE = GPL-2.0
PANICOS_INPUT_SENSE_DEPENDENCIES = bash evtest

define PANICOS_INPUT_SENSE_INSTALL_TARGET_CMDS
	# All ROCKNIX scripts → /usr/bin/. 0755 so they're executable.
	mkdir -p $(TARGET_DIR)/usr/bin
	for f in $(PANICOS_INPUT_SENSE_PKGDIR)/files/scripts/*; do \
		$(INSTALL) -m 0755 "$$f" $(TARGET_DIR)/usr/bin/; \
	done
	# All ROCKNIX profile.d → /etc/profile.d/ without .sh suffix, matching
	# ROCKNIX's install layout. Scripts source ". /etc/profile.d/001-functions"
	# directly; adding .sh broke get_setting/set_setting in brightness,
	# input_sense, and every other helper that calls these functions.
	# Our /etc/profile overlay sources /etc/profile.d/* (no *.sh restriction).
	mkdir -p $(TARGET_DIR)/etc/profile.d
	for f in $(PANICOS_INPUT_SENSE_PKGDIR)/files/profile.d/*; do \
		$(INSTALL) -m 0644 "$$f" "$(TARGET_DIR)/etc/profile.d/$$(basename $$f)"; \
	done
	# Patch (1): SDL gamecontrollerdb path → /usr/share location.
	sed -i 's|/storage/.config/SDL-GameControllerDB/gamecontrollerdb.txt|/usr/share/SDL-GameControllerDB/gamecontrollerdb.txt|' \
		$(TARGET_DIR)/etc/profile.d/001-functions
	# tmpfiles.d to create the /storage skeleton on every boot. ROCKNIX
	# initializes /storage in busybox/scripts/init at first boot before
	# systemd starts; we use stock systemd init so we go via tmpfiles.d.
	# Without these dirs, quirk scripts that write to
	# /storage/.config/profile.d/001-device_config silently fail and
	# DEVICE_* exports never propagate.
	$(INSTALL) -D -m 0644 $(PANICOS_INPUT_SENSE_PKGDIR)/files/tmpfiles.d/panicos-storage-skel.conf \
		$(TARGET_DIR)/usr/lib/tmpfiles.d/panicos-storage-skel.conf
	# udev rule: kill+restart input_sense whenever input devices are added,
	# removed, or changed. input_sense's get_devices() scans at startup only;
	# without this, volume-key and gpio-keys devices that enumerate after
	# service start are never picked up. Verbatim from ROCKNIX:
	#   packages/sysutils/system-utils/udev.d/99-input.rules
	$(INSTALL) -D -m 0644 $(PANICOS_INPUT_SENSE_PKGDIR)/files/udev.d/99-input.rules \
		$(TARGET_DIR)/etc/udev/rules.d/99-input.rules
	$(INSTALL) -D -m 0644 $(PANICOS_INPUT_SENSE_PKGDIR)/files/udev.d/80-usbgadget.rules \
		$(TARGET_DIR)/etc/udev/rules.d/80-usbgadget.rules

	# python → python3 symlink. ROCKNIX scripts (e.g. rocknix-bluetooth-agent)
	# call /usr/bin/python; we ship python3 only. Symlink avoids patching
	# every shebang.
	ln -sf python3 $(TARGET_DIR)/usr/bin/python
	# Patch (3): rocknix-fake-suspend INPUT_WHITELIST — add "H700 Gamepad" so
	# block_input does not grab the joystick during fake-sleep. Without this,
	# evtest --grab on the joystick can cause SDL in ES to fire
	# SDL_JOYDEVICEREMOVED/JOYDEVICEADDED, which ES interprets as a new device
	# and shows the "configure controller" wizard on the next button press.
	sed -i 's|# H700$$|# H700\n  "H700 Gamepad" \\|' \
		$(TARGET_DIR)/usr/bin/rocknix-fake-suspend
endef

define PANICOS_INPUT_SENSE_INSTALL_INIT_SYSTEMD
	# input.service (the daemon proper) renamed to panicos-input-sense.service.
	# Source unit has Before=rocknix.target which doesn't exist on PanicOS;
	# sed-strip on install. headphones.service exists (we ship it), so the
	# After= dep stays valid.
	$(INSTALL) -D -m 0644 $(PANICOS_INPUT_SENSE_PKGDIR)/files/input.service \
		$(TARGET_DIR)/usr/lib/systemd/system/panicos-input-sense.service
	sed -i '/^Before=rocknix.target/d' \
		$(TARGET_DIR)/usr/lib/systemd/system/panicos-input-sense.service
	mkdir -p $(TARGET_DIR)/usr/lib/systemd/system/multi-user.target.wants
	ln -sf ../panicos-input-sense.service \
		$(TARGET_DIR)/usr/lib/systemd/system/multi-user.target.wants/panicos-input-sense.service

	# All other supporting ROCKNIX systemd units. Each gets dropped into
	# /usr/lib/systemd/system/ verbatim, then sed-adapted: rocknix.target
	# refs are stripped (we don't have it), Before=autostart.service
	# becomes Before=panicos-quirks-autostart.service to match our renamed
	# autostart unit.
	for unit in \
		batteryledstatus.service \
		fancontrol.service \
		headphones.service \
		bluetooth-agent.service \
		hdmi-hotplug.service \
		hdmi-hotplug.path \
		rocknix-automount.service \
		rocknix-memory-manager.service \
		save-sysconfig.service \
		panicos-brightness-init.service \
	; do \
		$(INSTALL) -D -m 0644 "$(PANICOS_INPUT_SENSE_PKGDIR)/files/system.d/$$unit" \
			"$(TARGET_DIR)/usr/lib/systemd/system/$$unit"; \
		sed -i '/^Before=rocknix.target/d; \
		        s|^Before=autostart.service|Before=panicos-quirks-autostart.service|; \
		        s|^WantedBy=rocknix.target|WantedBy=multi-user.target|' \
			"$(TARGET_DIR)/usr/lib/systemd/system/$$unit"; \
	done

	# Enable the ones that should auto-start at boot.
	#
	# rocknix-automount.service is INTENTIONALLY excluded — ROCKNIX's
	# automount assumes an internal-vs-external SD storage split where
	# /storage/games-internal/roms is the underlying real path and
	# /storage/roms is a bind/overlay target. PanicOS puts roms directly
	# in /storage/roms (panicos-firstboot extracts PortMaster + bundled
	# ports there), so rocknix-automount's bind-mount of
	# /storage/games-internal/roms (empty after first boot) over
	# /storage/roms MASKS everything firstboot put there — the Ports
	# menu in ES disappears, every PortMaster port path 404s. Script
	# stays installed at /usr/bin/automount for users who explicitly
	# want the ROCKNIX merged-storage layout, but the service is left
	# disabled.
	#
	# Explicit `rm -f` of the rocknix-automount.service enable symlink
	# is critical: prior package versions DID install it, so on
	# incremental rebuilds the symlink survives in TARGET_DIR even
	# after we stop creating it. Without this rm, fixing the bug in
	# source has no effect on incremental rebuilds — only a clean
	# rebuild picks up the change. Bit by this on rb35 (user flashed,
	# Ports menu still missing).
	rm -f $(TARGET_DIR)/usr/lib/systemd/system/multi-user.target.wants/rocknix-automount.service
	for unit in batteryledstatus.service fancontrol.service \
	            headphones.service rocknix-memory-manager.service \
	            hdmi-hotplug.path panicos-brightness-init.service; do \
		ln -sf "../$$unit" \
			"$(TARGET_DIR)/usr/lib/systemd/system/multi-user.target.wants/$$unit"; \
	done
	# bluetooth-agent.service is wired by bluetooth.service via PartOf=,
	# auto-starts when bluetooth.service starts; no symlink needed.
	# save-sysconfig.service WantedBy=shutdown.target — enable separately.
	mkdir -p $(TARGET_DIR)/usr/lib/systemd/system/shutdown.target.wants
	ln -sf ../save-sysconfig.service \
		$(TARGET_DIR)/usr/lib/systemd/system/shutdown.target.wants/save-sysconfig.service
	# Preset file so `systemctl preset-all` (run by buildroot fakeroot) explicitly
	# disables rocknix-automount.service. Without this, preset-all's default "enable"
	# action re-creates the multi-user.target.wants symlink we rm -f above.
	$(INSTALL) -D -m 0644 $(PANICOS_INPUT_SENSE_PKGDIR)/files/system-preset/90-panicos-disable.preset \
		$(TARGET_DIR)/usr/lib/systemd/system-preset/90-panicos-disable.preset
endef

$(eval $(generic-package))

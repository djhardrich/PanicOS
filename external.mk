# Hook PanicOS package fragments into Buildroot.
# Empty for now — packages get added in later plans.

include $(sort $(wildcard $(BR2_EXTERNAL_PANICOS_PATH)/package/*/*.mk))

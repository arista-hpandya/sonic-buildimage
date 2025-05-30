# Pensando Platform modules

PENSANDO_DPU_PLATFORM_MODULE_VERSION = 1.0

export PENSANDO_DPU_PLATFORM_MODULE_VERSION

PENSANDO_DPU_PLATFORM_MODULE = sonic-platform-pensando-dpu_$(PENSANDO_DPU_PLATFORM_MODULE_VERSION)_arm64.deb
$(PENSANDO_DPU_PLATFORM_MODULE)_SRC_PATH = $(PLATFORM_PATH)/sonic-platform-modules-dpu
$(PENSANDO_DPU_PLATFORM_MODULE)_DEPENDS += $(LINUX_HEADERS) $(LINUX_HEADERS_COMMON)
$(PENSANDO_DPU_PLATFORM_MODULE)_MACHINE = pensando
$(PENSANDO_DPU_PLATFORM_MODULE)_IMAGE_TYPE = dsc
SONIC_DPKG_DEBS += $(PENSANDO_DPU_PLATFORM_MODULE)


$(eval $(call add_extra_package,$(PENSANDO_DPU_PLATFORM_MODULE)))
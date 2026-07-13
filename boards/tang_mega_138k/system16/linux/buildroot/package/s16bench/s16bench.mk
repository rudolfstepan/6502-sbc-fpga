################################################################################
# s16bench
################################################################################

S16BENCH_VERSION = 1.0
S16BENCH_SITE = $(BR2_EXTERNAL_SYSTEM16_PATH)/package/s16bench/src
S16BENCH_SITE_METHOD = local

define S16BENCH_BUILD_CMDS
	$(TARGET_CC) $(TARGET_CFLAGS) -std=c11 -Wall -Wextra -O2 \
		-o $(@D)/s16bench $(@D)/s16bench.c
endef

define S16BENCH_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/s16bench $(TARGET_DIR)/usr/bin/s16bench
endef

$(eval $(generic-package))

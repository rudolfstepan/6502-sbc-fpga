################################################################################
# native-gcc -- GCC which executes on the target
################################################################################
NATIVE_GCC_VERSION = $(GCC_VERSION)
NATIVE_GCC_SOURCE = gcc-$(NATIVE_GCC_VERSION).tar.xz
NATIVE_GCC_SITE = $(BR2_GNU_MIRROR)/gcc/gcc-$(NATIVE_GCC_VERSION)
NATIVE_GCC_LICENSE = GPL-3.0+
NATIVE_GCC_DEPENDENCIES = binutils gmp mpfr mpc zlib
NATIVE_GCC_CONF_ENV = \
	CC_FOR_BUILD="/usr/bin/gcc" CXX_FOR_BUILD="/usr/bin/g++" \
	CC_FOR_TARGET="$(TARGET_CC)" CXX_FOR_TARGET="$(TARGET_CXX)" \
	AR_FOR_TARGET="$(TARGET_AR)" AS_FOR_TARGET="$(TARGET_AS)" \
	LD_FOR_TARGET="$(TARGET_LD)" RANLIB_FOR_TARGET="$(TARGET_RANLIB)"
NATIVE_GCC_CONF_OPTS = \
	--target=$(GNU_TARGET_NAME) \
	--with-sysroot=/ \
	--with-native-system-header-dir=/usr/include \
	--enable-languages=c \
	--disable-bootstrap --disable-libsanitizer --disable-libquadmath \
	--disable-libssp --disable-lto --disable-multilib --disable-nls \
	--disable-plugin --without-isl \
	--with-gmp=$(STAGING_DIR)/usr --with-mpfr=$(STAGING_DIR)/usr \
	--with-mpc=$(STAGING_DIR)/usr --with-system-zlib
$(eval $(autotools-package))

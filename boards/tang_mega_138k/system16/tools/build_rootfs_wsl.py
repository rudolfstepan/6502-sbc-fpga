#!/usr/bin/env python3
"""Build the busybox initramfs with Buildroot in WSL (rv32ima, ilp32).

Idempotent: downloads Buildroot into ~/buildroot-2025.02 once, writes the
system16 defconfig (32-bit RISC-V, M+A only, soft-float, plain cpio) and
builds. The resulting output/images/rootfs.cpio is what
CONFIG_INITRAMFS_SOURCE in linux/system16.config points at; both Linux
profiles (VexRiscv and GoRV32 Plus) share it.

Statically linked (BR2_STATIC_LIBS) against uClibc-ng, not the default
glibc: Buildroot's default glibc toolchain installs the full dynamic
runtime (libc.so, ld.so) into the rootfs, which alone was ~4.3 MB - too
big for the GoRV32 Plus primary flash slot (2.9 MB total for
OpenSBI+DTB+kernel+initramfs). BR2_STATIC_LIBS is silently dropped from
the config when glibc is selected (Buildroot disallows fully static
glibc due to NSS/dlopen); uClibc-ng supports it and produces a much
smaller static busybox besides.
"""
import subprocess

script = r'''
set -eu
# Drop the inherited Windows PATH entries; their spaces upset Buildroot.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
cd ~
if [ ! -d buildroot-2025.02 ]; then
  (wget -q https://buildroot.org/downloads/buildroot-2025.02.tar.gz ||
   curl -sLO https://buildroot.org/downloads/buildroot-2025.02.tar.gz)
  tar xf buildroot-2025.02.tar.gz
fi
cd buildroot-2025.02
cat > configs/system16_defconfig <<'EOF'
BR2_riscv=y
BR2_RISCV_32=y
BR2_riscv_custom=y
BR2_RISCV_ISA_RVM=y
BR2_RISCV_ISA_RVA=y
BR2_TOOLCHAIN_BUILDROOT_UCLIBC=y
BR2_STATIC_LIBS=y
# Static /dev nodes in the cpio: with an initramfs the kernel skips the
# devtmpfs automount (prepare_namespace path), so /dev/null etc. must
# already exist or init/getty spin on open errors.
BR2_ROOTFS_DEVICE_CREATION_STATIC=y
BR2_TARGET_ROOTFS_CPIO=y
# BR2_TARGET_ROOTFS_TAR is not set
EOF
make system16_defconfig
grep -q "^BR2_RISCV_ISA_RVA=y" .config || { echo "defconfig rejected"; exit 1; }
grep -q "^BR2_TOOLCHAIN_BUILDROOT_UCLIBC=y" .config || { echo "uclibc rejected"; exit 1; }
grep -q "^BR2_STATIC_LIBS=y" .config || { echo "static-libs rejected"; exit 1; }
grep -E "BR2_RISCV_ABI|BR2_RISCV_ISA_RV[MA]|BR2_STATIC_LIBS|BR2_TOOLCHAIN_BUILDROOT_[A-Z]+=y" .config
# Force one clean rebuild whenever the toolchain ABI/libc/link-mode
# marker changes: Buildroot does not always re-trigger the
# toolchain-wrapper and busybox link mode from an in-place defconfig
# change alone.
marker=output/.system16-uclibc-static
if [ ! -f "$marker" ]; then
  make clean
  make system16_defconfig
  mkdir -p output && touch "$marker"
fi
# GCC 15 defaults to C23, which breaks the old gnulib in several host
# packages (m4, bison, gettext); pin the host builds to gnu17.
make -j"$(nproc)" HOSTCC="/usr/bin/gcc -std=gnu17" HOSTCXX="/usr/bin/g++"
ls -la output/images/
'''
raise SystemExit(subprocess.run(["wsl.exe", "--", "sh", "-lc", script]).returncode)

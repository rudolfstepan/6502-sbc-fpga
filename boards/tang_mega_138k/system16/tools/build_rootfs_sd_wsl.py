#!/usr/bin/env python3
"""Build the 512 MiB SD-root profile with a native development toolchain."""
from __future__ import annotations
import subprocess
from pathlib import Path

assets = Path(__file__).resolve().parent.parent / "linux" / "buildroot"
resolved = assets.resolve()
if not resolved.drive:
    raise SystemExit(f"cannot convert repository path to WSL: {resolved}")
drive = resolved.drive[0].lower()
tail = resolved.as_posix()[2:].lstrip("/")
assets_wsl = f"/mnt/{drive}/{tail}"

home_result = subprocess.run(
    ["wsl.exe", "--", "sh", "-lc", "printf '%s' ~"],
    check=True, text=True, capture_output=True)
wsl_home = home_result.stdout.strip()
if not wsl_home.startswith("/"):
    raise SystemExit(f"cannot determine WSL home directory: {wsl_home!r}")
source_dir = f"{wsl_home}/buildroot-2025.02"
output_dir = f"{wsl_home}/system16-buildroot-sd"

setup_script = rf'''
set -eu
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
cd ~
if [ ! -d buildroot-2025.02 ]; then
  (wget -q https://buildroot.org/downloads/buildroot-2025.02.tar.gz ||
   curl -sLO https://buildroot.org/downloads/buildroot-2025.02.tar.gz)
  tar xf buildroot-2025.02.tar.gz
fi
# The System16 additions are a normal BR2_EXTERNAL tree in the repository.
# The downloaded Buildroot source can therefore be read-only/root-owned.
make -C '{source_dir}' O='{output_dir}' \
  BR2_EXTERNAL='{assets_wsl}' system16_sd_defconfig
'''
setup = subprocess.run(["wsl.exe", "--", "sh", "-lc", setup_script])
if setup.returncode:
    raise SystemExit(setup.returncode)

config_result = subprocess.run(
    ["wsl.exe", "--", "cat", f"{output_dir}/.config"],
    check=True, text=True, capture_output=True)
required = (
    "BR2_RISCV_ISA_RVA",
    "BR2_TOOLCHAIN_BUILDROOT_UCLIBC",
    "BR2_TOOLCHAIN_BUILDROOT_CXX",
    "BR2_USE_WCHAR",
    "BR2_PACKAGE_BINUTILS",
    "BR2_PACKAGE_BINUTILS_TARGET",
    "BR2_PACKAGE_NATIVE_GCC",
    "BR2_PACKAGE_S16BENCH",
    "BR2_PACKAGE_MAKE",
    "BR2_TARGET_ROOTFS_EXT2",
)
missing = [symbol for symbol in required
           if f"{symbol}=y" not in config_result.stdout.splitlines()]
if missing:
    raise SystemExit("Buildroot rejected: " + ", ".join(missing))

build_script = rf'''
set -eu
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Toolchain feature changes do not invalidate Buildroot's existing stamps.
# Rebuild once if this output tree was created before C++ was enabled.
if [ -d '{output_dir}/host' ] && \
   ! ls '{output_dir}/host/bin/'*-g++ >/dev/null 2>&1; then
  echo 'Existing Buildroot toolchain has no C++; rebuilding the output tree'
  make -C '{source_dir}' O='{output_dir}' \
    BR2_EXTERNAL='{assets_wsl}' clean
  make -C '{source_dir}' O='{output_dir}' \
    BR2_EXTERNAL='{assets_wsl}' system16_sd_defconfig
fi
# A failed GCC configure keeps config.log and generated state. Re-extract only
# that failed package; successful incremental builds remain untouched.
if ls -d '{output_dir}/build/native-gcc-'* >/dev/null 2>&1 && \
   ! ls '{output_dir}/build/native-gcc-'*/.stamp_configured >/dev/null 2>&1; then
  make -C '{source_dir}' O='{output_dir}' \
    BR2_EXTERNAL='{assets_wsl}' native-gcc-dirclean
fi
make -C '{source_dir}' O='{output_dir}' \
  BR2_EXTERNAL='{assets_wsl}' -j4 \
  HOSTCC="/usr/bin/gcc -std=gnu17" HOSTCXX="/usr/bin/g++"
ls -lh '{output_dir}/images/rootfs.ext2'
'''
raise SystemExit(subprocess.run(
    ["wsl.exe", "--", "sh", "-lc", build_script]).returncode)

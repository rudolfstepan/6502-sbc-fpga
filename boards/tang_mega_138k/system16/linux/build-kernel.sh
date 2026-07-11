#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../../../.." && pwd)
kernel=${KERNEL_SRC:-"$root/third_party/linux-6.12.95"}
out=${KERNEL_OUT:-"$root/build/system16-linux"}
cross=${CROSS_COMPILE:-riscv32-linux-gnu-}
make -C "$kernel" O="$out" ARCH=riscv CROSS_COMPILE="$cross" allnoconfig
"$kernel/scripts/kconfig/merge_config.sh" -m -O "$out" "$out/.config" "$root/boards/tang_mega_138k/system16/linux/system16.config"
make -C "$kernel" O="$out" ARCH=riscv CROSS_COMPILE="$cross" olddefconfig
make -C "$kernel" O="$out" ARCH=riscv CROSS_COMPILE="$cross" -j"${JOBS:-4}" Image
dtc -I dts -O dtb -o "$out/system16-rv32.dtb" "$root/boards/tang_mega_138k/system16/linux/system16-rv32.dts"
echo "Kernel: $out/arch/riscv/boot/Image (load at 0x00400000)"
echo "DTB:    $out/system16-rv32.dtb"

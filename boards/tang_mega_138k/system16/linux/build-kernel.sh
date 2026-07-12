#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../../../.." && pwd)
kernel=${KERNEL_SRC:-"$root/third_party/linux-6.12.95"}
profile=${SYSTEM16_PROFILE:-${1:-flash}}
case "$profile" in
  flash)
    out=${KERNEL_OUT:-"$HOME/system16-out"}
    fragments=("$root/boards/tang_mega_138k/system16/linux/system16-flash.config")
    dts="$root/boards/tang_mega_138k/system16/linux/gorv32plus.dts"
    dtb=gorv32plus.dtb
    ;;
  sd)
    out=${KERNEL_OUT:-"$HOME/system16-out-sd"}
    fragments=("$root/boards/tang_mega_138k/system16/linux/system16-sd.config")
    dts="$root/boards/tang_mega_138k/system16/linux/gorv32plus-sd.dts"
    dtb=gorv32plus-sd.dtb
    ;;
  rescue)
    out=${KERNEL_OUT:-"$HOME/system16-out-rescue"}
    fragments=(
      "$root/boards/tang_mega_138k/system16/linux/system16-flash.config"
      "$root/boards/tang_mega_138k/system16/linux/system16-rescue.config"
    )
    dts="$root/boards/tang_mega_138k/system16/linux/gorv32plus-rescue.dts"
    dtb=gorv32plus-rescue.dtb
    ;;
  qemu-sd)
    out=${KERNEL_OUT:-"$HOME/system16-out-qemu-sd"}
    fragments=(
      "$root/boards/tang_mega_138k/system16/linux/system16-sd.config"
      "$root/boards/tang_mega_138k/system16/linux/system16-qemu-sd.config"
    )
    dts="$root/boards/tang_mega_138k/system16/linux/gorv32plus-sd.dts"
    dtb=gorv32plus-qemu-sd.dtb
    ;;
  *) echo "usage: $0 [flash|sd|rescue|qemu-sd]" >&2; exit 2 ;;
esac
cross=${CROSS_COMPILE:-riscv64-linux-gnu-}

if [ "$profile" != qemu-sd ]; then
  cp "$root/boards/tang_mega_138k/system16/linux/kernel/gorv32_ps2.c" \
     "$kernel/drivers/input/keyboard/gorv32_ps2.c"
  cp "$root/boards/tang_mega_138k/system16/linux/kernel/Kconfig.ps2" \
     "$kernel/drivers/input/keyboard/Kconfig.ps2"
  grep -q 'Kconfig.ps2' "$kernel/drivers/input/keyboard/Kconfig" || \
    printf '\nsource "drivers/input/keyboard/Kconfig.ps2"\n' >> \
      "$kernel/drivers/input/keyboard/Kconfig"
  grep -q 'CONFIG_GORV32_PS2' "$kernel/drivers/input/keyboard/Makefile" || \
    printf '\nobj-$(CONFIG_GORV32_PS2) += gorv32_ps2.o\n' >> \
      "$kernel/drivers/input/keyboard/Makefile"

  # System16 hardware text console (built-in consw driver). Idempotent.
  cp "$root/boards/tang_mega_138k/system16/linux/kernel/s16text_con.c" \
     "$kernel/drivers/video/console/s16text_con.c"
  cp "$root/boards/tang_mega_138k/system16/linux/kernel/Kconfig.s16text" \
     "$kernel/drivers/video/console/Kconfig.s16text"
  grep -q 'Kconfig.s16text' "$kernel/drivers/video/console/Kconfig" || \
    printf '\nsource "drivers/video/console/Kconfig.s16text"\n' >> \
      "$kernel/drivers/video/console/Kconfig"
  grep -q 'CONFIG_SYS16_TEXTCON' "$kernel/drivers/video/console/Makefile" || \
    printf '\nobj-$(CONFIG_SYS16_TEXTCON) += s16text_con.o\n' >> \
      "$kernel/drivers/video/console/Makefile"
fi

if [ "$profile" = sd ] || [ "$profile" = rescue ]; then
  # Keep the board-specific driver in the repository while making it a
  # normal built-in Linux driver. These three operations are idempotent.
  cp "$root/boards/tang_mega_138k/system16/linux/kernel/gorv32_sd.c" \
     "$kernel/drivers/block/gorv32_sd.c"
  cp "$root/boards/tang_mega_138k/system16/linux/kernel/Kconfig.gorv32" \
     "$kernel/drivers/block/Kconfig.gorv32"
  grep -q 'Kconfig.gorv32' "$kernel/drivers/block/Kconfig" || \
    printf '\nsource "drivers/block/Kconfig.gorv32"\n' >> "$kernel/drivers/block/Kconfig"
  grep -q 'CONFIG_GORV32_SD' "$kernel/drivers/block/Makefile" || \
    printf '\nobj-$(CONFIG_GORV32_SD) += gorv32_sd.o\n' >> "$kernel/drivers/block/Makefile"
fi

make -C "$kernel" O="$out" ARCH=riscv CROSS_COMPILE="$cross" allnoconfig
"$kernel/scripts/kconfig/merge_config.sh" -m -O "$out" "$out/.config" "${fragments[@]}"
make -C "$kernel" O="$out" ARCH=riscv CROSS_COMPILE="$cross" olddefconfig
make -C "$kernel" O="$out" ARCH=riscv CROSS_COMPILE="$cross" -j"${JOBS:-4}" Image
dtc -i "$(dirname "$dts")" -I dts -O dtb -o "$out/$dtb" "$dts"
echo "Kernel: $out/arch/riscv/boot/Image (load at 0x00400000)"
echo "DTB:    $out/$dtb"

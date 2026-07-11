#!/usr/bin/env bash
# Build the GoRV32 Plus ZSBL. Runs inside WSL or any Linux with a riscv
# cross compiler; CROSS_COMPILE overrides the default kernel toolchain.
set -euo pipefail
cd "$(dirname "$0")"
# The rv64 cross compiler generates rv32 code with -mabi=ilp32; the linker
# just needs the elf32 emulation. Matches the OpenSBI build in this repo.
cross=${CROSS_COMPILE:-riscv64-linux-gnu-}
cflags="-march=rv32ima_zicsr_zifencei -mabi=ilp32 -mcmodel=medany \
  -Os -ffreestanding -fno-builtin -fno-pie -Wall -Wextra"
"${cross}gcc" $cflags -nostdlib -no-pie -Wl,-melf32lriscv \
  -T zsbl.lds -o zsbl.elf crt.S main.c
"${cross}objcopy" -O binary zsbl.elf zsbl.bin
"${cross}objdump" -h zsbl.elf | grep -E "\.text|\.data|\.bss"
echo "ZSBL: $(pwd)/zsbl.bin ($(stat -c%s zsbl.bin) bytes), burn at flash 0x500000"

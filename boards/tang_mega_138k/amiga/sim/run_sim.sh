#!/bin/sh
# Boot-copy simulation: fake ROM, compile with Icarus Verilog, run.
set -e
cd "$(dirname "$0")"

python make_fake_kick.py

IVERILOG=${IVERILOG:-/c/msys64/mingw64/bin/iverilog}
VVP=${VVP:-/c/msys64/mingw64/bin/vvp}

# Icarus rejects default_nettype directives inside a module body; strip them
# from a throwaway copy, the logic is unchanged.
sed 's/`default_nettype/\/\/ `default_nettype/' \
    ../../../../third_party/NanoMig/src/misc/sdram.sv > sdram_under_test.sv

"$IVERILOG" -g2012 -o tb_boot_copy.vvp \
    tb_boot_copy.sv \
    sdram_chip_model.sv \
    ../rtl/sdram_boot_verify.sv \
    ../rtl/kickstart_bram.sv \
    sdram_under_test.sv

"$VVP" tb_boot_copy.vvp

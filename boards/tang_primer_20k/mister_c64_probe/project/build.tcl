set_device GW2A-LV18PG256C8/I7 -name GW2A-18C

# Shared Tang HDMI/audio support.
add_file -type vhdl {../../../../rtl/core/sbc_pkg.vhd}
add_file -type vhdl {../../../../rtl/core/hdmi/tmds_encoder.vhd}
add_file -type vhdl {../../../../rtl/core/hdmi/hdmi_data_island_pkg.vhd}
add_file -type vhdl {../../../../rtl/core/hdmi/hdmi_encoder.vhd}
add_file -type vhdl {../../../../rtl/core/peripherals/pt8211_dac.vhd}
add_file -type vhdl {../../rtl/tang20k_hdmi_tx.vhd}

# MiSTer C64 core files vendored under third_party/mister_c64.
add_file -type vhdl {../../../../third_party/mister_c64/rtl/t65/T65_Pack.vhd}
add_file -type vhdl {../../../../third_party/mister_c64/rtl/t65/T65_ALU.vhd}
add_file -type vhdl {../../../../third_party/mister_c64/rtl/t65/T65_MCode.vhd}
add_file -type vhdl {../../../../third_party/mister_c64/rtl/t65/T65.vhd}

add_file -type vhdl {../../../../rtl/c64/c64_roms.vhd}
add_file -type vhdl {../../../../third_party/mister_c64/rtl/dprom.vhd}
add_file -type vhdl {../../../../third_party/mister_c64/rtl/spram.vhd}
add_file -type vhdl {../rtl/cpu_6510_gowin.vhd}
add_file -type verilog {../../../../third_party/mister_c64/rtl/mos6526.v}
add_file -type vhdl {../../../../third_party/mister_c64/rtl/video_sync.vhd}
add_file -type vhdl {../../../../third_party/mister_c64/rtl/fpga64_rgbcolor.vhd}
add_file -type vhdl {../rtl/fpga64_keyboard_simple.vhd}
add_file -type vhdl {../rtl/fpga64_buslogic_gowin.vhd}
add_file -type vhdl {../../../../third_party/mister_c64/rtl/video_vicII_656x.vhd}

add_file -type verilog {../rtl/sid_top_stub.sv}

add_file -type vhdl {../rtl/fpga64_sid_iec_gowin.vhd}

# Minimal MiSTer 1541 IEC responder.
add_file -type vhdl {../../../../rtl/c64/c1541_rom.vhd}
add_file -type vhdl {../../../../third_party/mister_c64/rtl/iec_drive/iecdrv_via6522.vhd}
add_file -type verilog {../../../../third_party/mister_c64/rtl/iec_drive/iecdrv_misc.sv}
add_file -type verilog {../../../../third_party/mister_c64/rtl/iec_drive/c1541_logic.sv}
add_file -type verilog {../rtl/c1541_static_dir_gcr.sv}
add_file -type vhdl {../../../../rtl/c64/mister_c1541_iec.vhd}

# Tang probe top.
add_file -type vhdl {../rtl/ps2_to_mister_key.vhd}
add_file -type vhdl {../rtl/tang20k_mister_c64_probe_top.vhd}

# Reuse the native C64 board pinout.
add_file -type cst {../../c64/constraints/tang20k_c64.cst}
add_file -type sdc {../constraints/tang20k_mister_c64_probe.sdc}

set_option -top_module tang20k_mister_c64_probe_top
set_option -use_sspi_as_gpio 1
set_option -use_mspi_as_gpio 1
set_option -output_base_name tang_mister_c64_probe
set_option -vhdl_std vhd2019
set_option -verilog_std sysv2017
set_option -timing_driven 1
set_option -route_maxfan 23

run all

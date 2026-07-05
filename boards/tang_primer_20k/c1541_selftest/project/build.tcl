set_device GW2A-LV18PG256C8/I7 -name GW2A-18C

# Standalone 1541/D64 SD write selftest.  No C64, no HDMI.
add_file -type vhdl {../../../../rtl/core/peripherals/d64_sector_map.vhd}
add_file -type vhdl {../../../../rtl/core/peripherals/uart_tx_ser.vhd}

add_file -type verilog {../../../../third_party/alinx_sd/spi_master.v}
add_file -type verilog {../../../../third_party/alinx_sd/sd_card_cmd.v}
add_file -type verilog {../../../../third_party/alinx_sd/sd_card_sec_read_write.v}
add_file -type verilog {../../../../third_party/alinx_sd/sd_card_top.v}

add_file -type vhdl {../../mister_c64_probe/rtl/c1541_static_dir_gcr.vhd}
add_file -type vhdl {../../mister_c64_probe/rtl/c1541_sd_d64_sector_source.vhd}
add_file -type vhdl {../rtl/tang20k_c1541_selftest_top.vhd}

add_file -type cst {../constraints/tang20k_c1541_selftest.cst}
add_file -type sdc {../constraints/tang20k_c1541_selftest.sdc}

set_option -top_module tang20k_c1541_selftest_top
set_option -use_sspi_as_gpio 1
set_option -use_mspi_as_gpio 1
set_option -output_base_name tang_c1541_selftest
set_option -vhdl_std vhd2019
set_option -verilog_std sysv2017
set_option -timing_driven 1
set_option -route_maxfan 23

run all

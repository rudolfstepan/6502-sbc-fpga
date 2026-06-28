set_device GW2A-LV18PG256C8/I7 -name GW2A-18C

# SBC package (only sid6581 / pt8211_dac depend on it)
add_file -type vhdl {../../../../rtl/core/sbc_pkg.vhd}

# T65 6502 core
add_file -type vhdl {../../../../third_party/t65/rtl/T65_Pack.vhd}
add_file -type vhdl {../../../../third_party/t65/rtl/T65_MCode.vhd}
add_file -type vhdl {../../../../third_party/t65/rtl/T65_ALU.vhd}
add_file -type vhdl {../../../../third_party/t65/rtl/T65.vhd}

# C64 package + generated ROMs
add_file -type vhdl {../../../../rtl/c64/c64_pkg.vhd}
add_file -type vhdl {../../../../rtl/c64/c64_roms.vhd}

# C64 memories
add_file -type vhdl {../../../../rtl/c64/c64_ram.vhd}
add_file -type vhdl {../../../../rtl/c64/colour_ram.vhd}

# C64 chips
add_file -type vhdl {../../../../rtl/c64/cpu6510.vhd}
add_file -type vhdl {../../../../rtl/c64/cia6526_full.vhd}
add_file -type verilog {../../../../rtl/c64/mos6526_mist.v}
add_file -type vhdl {../../../../rtl/c64/c64_keyboard_matrix.vhd}
add_file -type vhdl {../../../../rtl/c64/vic_ii.vhd}
add_file -type vhdl {../../../../rtl/core/audio/sid/sid6581.vhd}
add_file -type vhdl {../../../../rtl/core/peripherals/pt8211_dac.vhd}

# Host disk UART (PC runs a 1541 server over the CH340 link)
add_file -type vhdl {../../../../rtl/core/peripherals/uart_tx_ser.vhd}
add_file -type vhdl {../../../../rtl/core/peripherals/uart_rx_ser.vhd}

# C64 core
add_file -type vhdl {../../../../rtl/c64/c64_core.vhd}
add_file -type vhdl {../../../../rtl/c64/c64_dbg_uart.vhd}

# HDMI
add_file -type vhdl {../../../../rtl/core/hdmi/tmds_encoder.vhd}
add_file -type vhdl {../../../../rtl/core/hdmi/hdmi_data_island_pkg.vhd}
add_file -type vhdl {../../../../rtl/core/hdmi/hdmi_encoder.vhd}

# Board top + HDMI TX
add_file -type vhdl {../../rtl/tang20k_hdmi_tx.vhd}
add_file -type vhdl {../rtl/tang20k_c64_top.vhd}

# Constraints
add_file -type cst {../constraints/tang20k_c64.cst}
add_file -type sdc {../constraints/tang20k_c64.sdc}

set_option -top_module tang20k_c64_top
set_option -use_sspi_as_gpio 1
set_option -use_mspi_as_gpio 1
set_option -output_base_name tang_c64
set_option -vhdl_std vhd1993
set_option -timing_driven 1
set_option -route_maxfan 23

run all

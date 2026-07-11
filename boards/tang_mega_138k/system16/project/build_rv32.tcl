set_device GW5AST-LV138PG484AC1/I0 -name GW5AST-138C

add_file -type verilog {../../../../third_party/fx68k/fx68kAlu.sv}
add_file -type verilog {../../../../third_party/fx68k/uaddrPla.sv}
add_file -type verilog {../../../../third_party/fx68k/fx68k.sv}
add_file -type verilog {../../../../third_party/alinx_sd/spi_master.v}
add_file -type verilog {../../../../third_party/alinx_sd/sd_card_cmd.v}
add_file -type verilog {../../../../third_party/alinx_sd/sd_card_sec_read_write.v}
add_file -type verilog {../../../../third_party/alinx_sd/sd_card_top.v}
add_file -type vhdl {../rtl/sys16_pkg.vhd}
add_file -type vhdl {../rtl/sys16_bram.vhd}
add_file -type vhdl {../rtl/sys16_boot_rom_image_pkg.vhd}
add_file -type vhdl {../rtl/sys16_boot_rom.vhd}
add_file -type vhdl {../../../../rtl/core/peripherals/uart_tx_ser.vhd}
add_file -type vhdl {../../../../rtl/core/peripherals/uart_rx_ser.vhd}
add_file -type vhdl {../rtl/sys16_uart.vhd}
add_file -type vhdl {../rtl/sys16_uart16550.vhd}
add_file -type vhdl {../rtl/sys16_uart_probe.vhd}
add_file -type vhdl {../rtl/sys16_uart_pc_reporter.vhd}
add_file -type vhdl {../../../../rtl/core/mem/sdram_ctrl.vhd}
add_file -type vhdl {../rtl/sys16_sdram_bridge.vhd}
add_file -type vhdl {../rtl/sys16_sdram_probe.vhd}
add_file -type vhdl {../rtl/sys16_sd_bootloader.vhd}
add_file -type vhdl {../rtl/sys16_soc.vhd}
# RV32/Sv32 profile sources. The m68k top remains selected until the RV32 board
# top is enabled, but keeping these in synthesis catches interface regressions.
add_file -type verilog {../rtl/VexRiscvSystem16.v}
add_file -type verilog {../rtl/sys16_vex_bridge.v}
add_file -type vhdl {../rtl/sys16_bus32_pkg.vhd}
add_file -type vhdl {../rtl/sys16_bus32_to_sdram16.vhd}
add_file -type vhdl {../rtl/sys16_timer32.vhd}
add_file -type vhdl {../rtl/sys16_rv32_soc.vhd}
add_file -type verilog {../../hdmi_test/project/src/gowin_pll/gowin_hdmi_720p_pll.v}
add_file -type verilog {../../sbc/project/src/dvi-tx/dvi_tx_clk_drv.v}
add_file -type verilog {../../sbc/project/src/dvi-tx/dvi_tx_tmds_enc.v}
add_file -type verilog {../../sbc/project/src/dvi-tx/dvi_tx_tmds_phy.v}
add_file -type verilog {../../sbc/project/src/dvi-tx/dvi_tx_top.v}
add_file -type vhdl {../rtl/sys16_hdmi_720p.vhd}
add_file -type vhdl {../rtl/tang138k_system16_top.vhd}
add_file -type vhdl {../rtl/tang138k_system16_rv32_top.vhd}
add_file -type cst {../constraints/tang138k_system16.cst}
add_file -type sdc {../constraints/tang138k_system16.sdc}

set_option -top_module tang138k_system16_rv32_top
set_option -output_base_name tang138k_system16_rv32
set_option -vhdl_std vhd1993
set_option -verilog_std sysv2017
set_option -timing_driven 1
set_option -route_maxfan 23
set_option -use_cpu_as_gpio 1
set_option -use_sspi_as_gpio 1

run all

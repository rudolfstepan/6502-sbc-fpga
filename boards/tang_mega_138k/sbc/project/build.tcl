set_device GW5AST-LV138PG484AC1/I0 -name GW5AST-138C

add_file -type vhdl {../../../../rtl/core/sbc_pkg.vhd}
add_file -type vhdl {../../../../third_party/t65/rtl/T65_Pack.vhd}
add_file -type vhdl {../../../../third_party/t65/rtl/T65_MCode.vhd}
add_file -type vhdl {../../../../third_party/t65/rtl/T65_ALU.vhd}
add_file -type vhdl {../../../../third_party/t65/rtl/T65.vhd}
add_file -type vhdl {../../../../rtl/core/peripherals/via6522.vhd}
add_file -type vhdl {../../../../rtl/core/peripherals/math_copro.vhd}
add_file -type vhdl {../../../../rtl/core/peripherals/uart_tx_ser.vhd}
add_file -type vhdl {../../../../rtl/core/peripherals/uart_rx_ser.vhd}
add_file -type vhdl {../../../../rtl/core/peripherals/uart6551.vhd}
add_file -type vhdl {../../../../rtl/core/peripherals/uart_keyboard.vhd}
add_file -type vhdl {../../../../rtl/core/peripherals/vic_vga.vhd}
add_file -type vhdl {../../../../rtl/core/peripherals/vic_blit.vhd}
add_file -type vhdl {../../../../rtl/core/peripherals/vic_blit_regs.vhd}
add_file -type vhdl {../../../../rtl/core/peripherals/vic_fb_ddr3.vhd}
add_file -type vhdl {../../../../rtl/core/audio/legacy_sound/sound_voice_full.vhd}
add_file -type vhdl {../../../../rtl/core/audio/legacy_sound/sound_chip4.vhd}
add_file -type vhdl {../../../../rtl/core/audio/sid/sid6581.vhd}
add_file -type vhdl {../../../../rtl/core/peripherals/cia6526.vhd}
add_file -type vhdl {../../../../rtl/core/peripherals/pt8211_dac.vhd}
add_file -type vhdl {../../../../rtl/core/peripherals/d64_sector_map.vhd}
add_file -type vhdl {../../../../rtl/core/peripherals/d64_drive.vhd}
add_file -type vhdl {../../../../rtl/core/peripherals/d64_subsystem.vhd}
add_file -type vhdl {../../../../rtl/core/peripherals/sd_disk_ctrl.vhd}
add_file -type vhdl {../rtl/sync_ram.vhd}
add_file -type vhdl {../../../../rtl/core/mem/fb_ram.vhd}
add_file -type vhdl {../../../../rtl/core/mem/char_rom.vhd}
add_file -type vhdl {../../../../rtl/core/boot/boot_vga_debug.vhd}
# Kernel/BASIC are loaded from SD for this board; keep the generated ROM package
# out of the synthesis image.
# add_file -type vhdl {../../../../rtl/core/mem/boot_rom_init_pkg.vhd}
add_file -type vhdl {../../../../rtl/core/mem/boot_shadow_rom.vhd}
add_file -type vhdl {../../../../rtl/core/mem/sdram_if.vhd}
add_file -type vhdl {../../../../rtl/core/mem/sdram_ctrl.vhd}
add_file -type verilog {../../../../rtl/core/boot/sd_rom_loader.v}
add_file -type vhdl {../../../../rtl/core/ps2/ps2_keyboard.vhd}
add_file -type verilog {../../../../third_party/usb_hid_host/usb_hid_host_rom.v}
add_file -type verilog {../../../../third_party/usb_hid_host/usb_hid_host_nm.v}
add_file -type vhdl {../../../../rtl/core/usb/usb_hid_host.vhd}
add_file -type vhdl {../../../../boards/tang_primer_20k/mister_c64_probe/rtl/c64_prg_upload_monitor.vhd}
add_file -type verilog {../../../../third_party/alinx_sd/spi_master.v}
add_file -type verilog {../../../../third_party/alinx_sd/sd_card_cmd.v}
add_file -type verilog {../../../../third_party/alinx_sd/sd_card_sec_read_write.v}
add_file -type verilog {../../../../third_party/alinx_sd/sd_card_top.v}
add_file -type vhdl {../../../../rtl/core/cpu/t65_adapter.vhd}
add_file -type vhdl {../../../../rtl/core/bus_decode.vhd}
add_file -type vhdl {../../../../rtl/core/sbc_t65_boot_monitor_top.vhd}
add_file -type verilog {src/gowin_pll/gowin_ddr_pll.v}
add_file -type verilog {src/gowin_pll/gowin_usb_pll.v}
add_file -type verilog {src/gowin_pll/gowin_pll_mod.v}
add_file -type verilog {src/gowin_pll/gowin_hdmi_pll.v}
add_file -type verilog {../../hdmi_test/project/src/gowin_pll/gowin_hdmi_720p_pll.v}
add_file -type verilog {src/pll_init.v}
add_file -type verilog {src/ddr3_memory_interface/ddr3_memory_interface.v}
add_file -type verilog {src/dvi-tx/dvi_tx_clk_drv.v}
add_file -type verilog {src/dvi-tx/dvi_tx_tmds_enc.v}
add_file -type verilog {src/dvi-tx/dvi_tx_tmds_phy.v}
add_file -type verilog {src/dvi-tx/dvi_tx_top.v}
add_file -type vhdl {../rtl/bram_byte_bridge.vhd}
add_file -type vhdl {../rtl/sdram_byte_bridge.vhd}
add_file -type vhdl {../rtl/sdram_fb.vhd}
add_file -type vhdl {../rtl/tang138k_hdmi_tx.vhd}
add_file -type vhdl {../rtl/tang138k_sbc_top.vhd}
add_file -type cst {../constraints/tang138k_sbc.cst}
add_file -type sdc {../constraints/tang138k_sbc.sdc}

set_option -top_module tang138k_sbc_top
set_option -output_base_name tang138k_sbc
set_option -vhdl_std vhd1993
set_option -timing_driven 1
set_option -route_maxfan 23
set_option -use_cpu_as_gpio 1
set_option -use_sspi_as_gpio 1

run all

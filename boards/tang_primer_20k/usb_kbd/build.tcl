## ============================================================================
## gw_sh build script -- standalone USB HID keyboard bring-up (Tang Primer 20K).
## Run from THIS directory:  gw_sh build.tcl
##
## Note: usb_hid_host_rom.v does `$readmemh("usb_hid_host_rom.hex", ...)` with a
## bare relative path, so a copy of the .hex lives in this directory and gw_sh
## must be launched from here (its CWD is where $readmemh resolves the file).
## ============================================================================
set_device GW2A-LV18PG256C8/I7 -name GW2A-18C

# 12 MHz rPLL for the nand2mario bit-bang engine
add_file -type verilog {src/gowin_rpll_usb/gowin_rpll_usb.v}

# nand2mario / hi631 USB HID host core (Verilog) + its microcode ROM
add_file -type verilog {../../../third_party/usb_hid_host/usb_hid_host_rom.v}
add_file -type verilog {../../../third_party/usb_hid_host/usb_hid_host_nm.v}

# VHDL wrapper + UART serializer, then the board top
add_file -type vhdl {../../../rtl/core/usb/usb_hid_host.vhd}
add_file -type vhdl {../../../rtl/core/peripherals/uart_tx_ser.vhd}
add_file -type vhdl {rtl/usb_kbd_top.vhd}

add_file -type cst {usb_kbd.cst}
add_file -type sdc {usb_kbd.sdc}

set_option -top_module usb_kbd_top
set_option -output_base_name usb_kbd
set_option -vhdl_std vhd1993
set_option -timing_driven 1

run all

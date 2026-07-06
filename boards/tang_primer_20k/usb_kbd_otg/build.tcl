## ============================================================================
## gw_sh build script -- USB keyboard on OTG port, Stage 1 (host up + detect).
## Run from THIS directory:  gw_sh build.tcl
##
## usbh_host.v does `include "usbh_host_defs.v"`, so the core src_v directory is
## added to the include path (the defs file is macros-only and is NOT added as a
## compile unit, to avoid duplicate macro definitions).
## ============================================================================
set_device GW2A-LV18PG256C8/I7 -name GW2A-18C

# Vendored transaction layer (GPLv3): ULPI<->UTMI wrapper + USB 1.1 host core
add_file -type verilog {../../../third_party/ultraembedded/core_ulpi_wrapper/ulpi_wrapper.v}
add_file -type verilog {../../../third_party/ultraembedded/core_usb_host/src_v/usbh_crc5.v}
add_file -type verilog {../../../third_party/ultraembedded/core_usb_host/src_v/usbh_crc16.v}
add_file -type verilog {../../../third_party/ultraembedded/core_usb_host/src_v/usbh_fifo.v}
add_file -type verilog {../../../third_party/ultraembedded/core_usb_host/src_v/usbh_sie.v}
add_file -type verilog {../../../third_party/ultraembedded/core_usb_host/src_v/usbh_host.v}

# Our VHDL: UART, host sequencer, board top
# (rtl/ulpi_vbus_init.vhd removed from the build -- wrapper owns ULPI from reset)
add_file -type vhdl {../../../rtl/core/peripherals/uart_tx_ser.vhd}
add_file -type vhdl {rtl/usb_host_seq.vhd}
add_file -type vhdl {rtl/ulpi_rec.vhd}
add_file -type vhdl {rtl/usb_kbd_otg_top.vhd}

add_file -type cst {usb_kbd_otg.cst}
add_file -type sdc {usb_kbd_otg.sdc}

set_option -include_path {../../../third_party/ultraembedded/core_usb_host/src_v}
set_option -top_module usb_kbd_otg_top
set_option -output_base_name usb_kbd_otg
set_option -vhdl_std vhd1993
set_option -timing_driven 1

run all

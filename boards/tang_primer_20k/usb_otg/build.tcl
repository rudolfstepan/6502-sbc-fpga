## ============================================================================
## gw_sh build script -- USB-OTG (USB3317 ULPI PHY) bring-up (Tang Primer 20K).
## Run from THIS directory:  gw_sh build.tcl
##
## Reads the four USB3317 ULPI ID registers over the on-board ULPI bus and
## reports them + a status byte over UART. Proves the OTG port / PHY is alive.
## No external wiring; no PLL (the 60 MHz ULPI clock comes from the PHY).
## ============================================================================
set_device GW2A-LV18PG256C8/I7 -name GW2A-18C

# ULPI diagnostic sampler + UART serializer, then the board top
add_file -type vhdl {../../../rtl/core/boot/usb_ulpi_diag.vhd}
add_file -type vhdl {../../../rtl/core/peripherals/uart_tx_ser.vhd}
add_file -type vhdl {rtl/usb_otg_diag_top.vhd}

add_file -type cst {usb_otg.cst}
add_file -type sdc {usb_otg.sdc}

set_option -top_module usb_otg_diag_top
set_option -output_base_name usb_otg
set_option -vhdl_std vhd1993
set_option -timing_driven 1

run all

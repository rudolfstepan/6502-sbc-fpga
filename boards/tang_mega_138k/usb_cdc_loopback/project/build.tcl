set_device GW5AST-LV138PG484AC1/I0 -name GW5AST-138C
add_file -type verilog {src/usb_device_controller/usb_device_controller.v}
add_file -type verilog {src/usb_softphy/usb_softphy.v}
add_file -type verilog {../rtl/usb_fs_pll.v}
add_file -type verilog {../rtl/usb_cdc_descriptor.v}
add_file -type verilog {../rtl/usb_cdc_acm_control.v}
add_file -type verilog {../rtl/usb_packet_echo_fifo.v}
add_file -type verilog {../rtl/tang138k_usb_cdc_loopback_top.v}
add_file -type cst {../constraints/tang138k_usb_cdc_loopback.cst}
add_file -type sdc {../constraints/tang138k_usb_cdc_loopback.sdc}
set_option -top_module tang138k_usb_cdc_loopback_top
set_option -output_base_name tang138k_usb_cdc_loopback
set_option -verilog_std sysv2017
set_option -timing_driven 1
set_option -route_maxfan 23
set_option -use_cpu_as_gpio 1
set_option -use_sspi_as_gpio 1
run all

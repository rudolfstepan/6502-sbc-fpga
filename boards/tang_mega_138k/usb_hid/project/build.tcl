set_device GW5AST-LV138PG484AC1/I0 -name GW5AST-138C
add_file -type verilog {src/usb20_host_controller/usb20_host_controller.v}
add_file -type verilog {src/usb2_0_softphy/usb2_0_softphy.v}
add_file -type verilog {../rtl/usb20_phy_pll.v}
add_file -type verilog {../rtl/tang138k_usb_hid_top.v}
add_file -type cst {../constraints/tang138k_usb_hid.cst}
add_file -type sdc {../constraints/tang138k_usb_hid.sdc}
set_option -top_module tang138k_usb_hid_top
set_option -output_base_name tang138k_usb_hid
set_option -timing_driven 1
set_option -route_maxfan 23
set_option -use_cpu_as_gpio 1
set_option -use_sspi_as_gpio 1
run all

set_device GW5AST-LV138PG484AC1/I0 -name GW5AST-138C

add_file -type verilog {src/gowin_pll/gowin_hdmi_720p_pll.v}
add_file -type verilog {../../sbc/project/src/dvi-tx/dvi_tx_clk_drv.v}
add_file -type verilog {../../sbc/project/src/dvi-tx/dvi_tx_tmds_enc.v}
add_file -type verilog {../../sbc/project/src/dvi-tx/dvi_tx_tmds_phy.v}
add_file -type verilog {../../sbc/project/src/dvi-tx/dvi_tx_top.v}
add_file -type verilog {../rtl/tang138k_hdmi_colorbar_top.v}
add_file -type cst {../constraints/tang138k_hdmi_colorbar.cst}
add_file -type sdc {../constraints/tang138k_hdmi_colorbar.sdc}

set_option -top_module tang138k_hdmi_colorbar_top
set_option -output_base_name tang138k_hdmi_colorbar
set_option -timing_driven 1
set_option -route_maxfan 23
set_option -use_cpu_as_gpio 1
set_option -use_sspi_as_gpio 1

run all

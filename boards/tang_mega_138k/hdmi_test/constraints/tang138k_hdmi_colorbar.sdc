create_clock -name clk_50mhz -period 20 [get_ports {clk_50mhz}]
create_clock -name clk_pix -period 13.333 [get_nets {clk_pix}]
create_clock -name clk_tmds -period 2.666 [get_nets {clk_5x}]

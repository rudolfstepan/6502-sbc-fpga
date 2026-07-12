create_clock -name clk_50mhz -period 20.000 [get_ports {clk}] -add
create_clock -name usb_clk480 -period 2.083 [get_pins {phy_pll_i/PLL_inst/CLKOUT0}] -add
create_clock -name usb_clk60 -period 16.667 [get_pins {phy_pll_i/PLL_inst/CLKOUT1}] -add

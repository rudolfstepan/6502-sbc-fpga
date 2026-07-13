create_clock -name clk_50mhz -period 20.000 [get_ports {clk}] -add
create_clock -name usb_clk60 -period 16.667 [get_pins {phy_pll_i/PLL_inst/CLKOUT0}] -add
set_clock_groups -asynchronous -group [get_clocks {clk_50mhz}] -group [get_clocks {usb_clk60}]

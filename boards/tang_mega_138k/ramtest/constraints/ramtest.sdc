create_clock -name clk_osc -period 20 -waveform {0 10} [get_ports {clk}] -add
create_clock -name clk85 -period 11.764 -waveform {0 5.882} [get_pins {pll/u_pll/PLL_inst/CLKOUT1}] -add
# Only toggle-synchronized handshakes cross between the two domains.
set_false_path -from [get_clocks {clk_osc}] -to [get_clocks {clk85}]
set_false_path -from [get_clocks {clk85}] -to [get_clocks {clk_osc}]

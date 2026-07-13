create_clock -name clk50m -period 20.000 -waveform {0 10.000} [get_ports {clk_50mhz}]

create_clock -name ae350_ddr_clk -period 10.000 -waveform {0 5.000} [get_pins {u_Gowin_PLL_AE350_ITCM/u_pll/PLL_inst/CLKOUT0}]
create_clock -name ae350_ahb_clk -period 10.000 -waveform {0 5.000} [get_pins {u_Gowin_PLL_AE350_ITCM/u_pll/PLL_inst/CLKOUT2}]
create_clock -name ae350_apb_clk -period 10.000 -waveform {0 5.000} [get_pins {u_Gowin_PLL_AE350_ITCM/u_pll/PLL_inst/CLKOUT3}]

set_clock_groups -exclusive -group [get_clocks {ae350_ahb_clk}] -group [get_clocks {ae350_apb_clk}] -group [get_clocks {ae350_ddr_clk}]

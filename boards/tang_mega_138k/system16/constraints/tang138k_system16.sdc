# 50 MHz board oscillator.
create_clock -name clk_50mhz -period 20 [get_ports {clk_50mhz}]

# Proven 720p HDMI PLL: 75 MHz pixel and 375 MHz DDR bit clock.
create_clock -name clk_pix -period 13.333 [get_pins {hdmi_i/pll_i/PLL_inst/CLKOUT0}]
create_clock -name clk_5x  -period 2.667  [get_pins {hdmi_i/pll_i/PLL_inst/CLKOUT1}]

# The first bring-up has only quasi-static status signals crossing sys -> pixel.
set_false_path -hold -from [get_clocks {clk_50mhz}] -to [get_clocks {clk_pix}]

# OSER10 reset is a reset/control path into the HDMI serializer.
set_false_path -from [get_pins {hdmi_i/dvi_i/gen_enc[*].dvi_tx_tmds_phy_inst/reset_5x_sr*/Q}] -to [get_pins {hdmi_i/dvi_i/gen_enc[*].dvi_tx_tmds_phy_inst/tmds_serdes_inst0/RESET}]

// Timing constraints -- USB keyboard on OTG port.
//   clk27   = 27 MHz on-board oscillator (PHY-reset timer only)
//   ulpiclk = 60 MHz CLKOUT from the USB3317 PHY (main design clock)
create_clock -name clk27    -period 37.037 [get_ports {clk_27mhz}]
create_clock -name ulpiclk  -period 16.667 [get_ports {ulpi_clk}]

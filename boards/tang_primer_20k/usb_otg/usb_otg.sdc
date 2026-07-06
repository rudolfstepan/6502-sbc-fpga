// Timing constraints -- USB-OTG (USB3317 ULPI) bring-up.
//   clk27  = 27 MHz on-board oscillator
//   ulpiclk = 60 MHz CLKOUT driven by the USB3317 PHY
// The two domains are asynchronous; usb_ulpi_diag crosses them with 2-FF
// synchronisers, so no cross-clock timing path needs to be met.
create_clock -name clk27    -period 37.037 [get_ports {clk_27mhz}]
create_clock -name ulpiclk  -period 16.667 [get_ports {ulpi_clk}]

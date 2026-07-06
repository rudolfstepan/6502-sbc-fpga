// Timing constraints -- USB HID keyboard bring-up.
// The 12 MHz USB domain is derived by the rPLL and easily met; only the
// 27 MHz input oscillator is constrained here.
create_clock -name clk27 -period 37.037 [get_ports {clk_27mhz}]

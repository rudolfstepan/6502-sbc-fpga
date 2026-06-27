// Timing constraints — REIST benchmark engine.
// Single 27 MHz clock domain (37.037 ns period).
create_clock -name clk -period 37.037 -waveform {0 18.5} [get_ports {clk}]

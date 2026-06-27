// Tight clock so the timing report reveals the real maximum frequency of the
// reduction unit (250 MHz target = 4 ns). Read "Max Frequency" from the report.
create_clock -name clk -period 4.0 -waveform {0 2.0} [get_ports {clk}]

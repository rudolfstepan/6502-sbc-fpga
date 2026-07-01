# Tang Primer 20K MiSTer C64 probe.
# Keep this deliberately simple.  The native C64 SDC references instance names
# that do not exist in the MiSTer core hierarchy.
create_clock -name clk_27mhz -period 37.037 [get_ports {clk_27mhz}]

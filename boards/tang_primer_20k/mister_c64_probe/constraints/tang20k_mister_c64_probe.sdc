# Tang Primer 20K MiSTer C64 probe.
# Keep this deliberately simple.  The native C64 SDC references instance names
# that do not exist in the MiSTer core hierarchy.
create_clock -name clk_27mhz -period 37.037 [get_ports {clk_27mhz}]
create_clock -name clk_c64 -period 31.250 [get_nets {clk_c64}]
create_clock -name clk_hdmi_pix -period 37.037 [get_nets {hdmi_i/clk_pix_i}]

# The MiSTer C64 core runs from its own 32 MHz PLL output, while the HDMI
# serializer samples pixels in tang20k_hdmi_tx's independently generated 27 MHz
# pixel domain. The video handoff is source-registered in clk_c64 before this
# crossing; treat the two domains as asynchronous so timing analysis does not
# report impossible phase-related clk_c64 -> clk_pix paths.
set_clock_groups -asynchronous -group [get_clocks {clk_c64}] -group [get_clocks {clk_hdmi_pix}]

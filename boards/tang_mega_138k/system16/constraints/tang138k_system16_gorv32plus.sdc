# Initial GoRV32Plus core/board-shell timing. AXI-SDRAM and HDMI generated
# clocks are added when those blocks are connected to the vendor CPU.
create_clock -name clk_50mhz -period 20 [get_ports {clk_50mhz}]

# The vendor QSPI controller loops the pad clock back in and samples MISO
# with it (TA1132/PR1014 otherwise: unconstrained clock on generic routing).
# 20 ns is the worst case; the real SCLK is divided down from ahb_clk.
# The handoff between the SCLK capture domain and the system clock is by
# vendor design; without the async group the timer invents same-edge
# cross-domain paths that fail by several ns and mislead the router.
create_clock -name flash_clk -period 20 [get_ports {flash_clk}]
set_clock_groups -asynchronous -group [get_clocks {flash_clk}] -group [get_clocks {clk_50mhz}]

# The SD host engines run on the divided card clock, 25 MHz worst case
# (divider register minimum). Unconstrained, the timer guesses 100 MHz
# and reports false violations; the register file crosses into this
# domain through the controller's own bistable/monostable synchronizers.
create_clock -name sd_clk_d -period 40 [get_pins {cpu/u_gorv32_plus/u_gw_sdhc/clock_divider0/SD_CLK_O_s2/Q}]
set_clock_groups -asynchronous -group [get_clocks {sd_clk_d}] -group [get_clocks {clk_50mhz}]

# The HDMI pixel/serializer clocks only receive the quasi-static status
# word through a two-stage synchronizer; without the async group the
# first stage shows bogus hold violations against clk_50mhz. The timer
# already auto-derives these as "hdmi_i/pll_i/PLL_inst/CLKOUT{0,1}.
# default_gen_clk", but that synthetic name cannot be looked up in SDC
# (TA2004) and this parser also rejects get_clocks -of_objects; naming
# them explicitly on the same pins (periods from the P&R clock report)
# gives a name usable in set_clock_groups, same as flash_clk/sd_clk_d.
create_clock -name pix_clk -period 13.333 [get_pins {hdmi_i/pll_i/PLL_inst/CLKOUT0}]
create_clock -name pix_clk_5x -period 2.667 [get_pins {hdmi_i/pll_i/PLL_inst/CLKOUT1}]
set_clock_groups -asynchronous -group [get_clocks {pix_clk pix_clk_5x}] -group [get_clocks {clk_50mhz}]

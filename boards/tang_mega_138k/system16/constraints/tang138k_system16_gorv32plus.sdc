# Initial GoRV32Plus core/board-shell timing. AXI-SDRAM and HDMI generated
# clocks are added when those blocks are connected to the vendor CPU.
create_clock -name clk_50mhz -period 20 [get_ports {clk_50mhz}]

# USB 1.1 SoftPHY and device controller run at 60 MHz. All CPU/USB payload
# crossings use explicit dual-clock FIFOs; status crosses through 2FF syncs.
create_clock -name usb_clk60 -period 16.667 [get_pins {usb_phy_pll_i/PLL_inst/CLKOUT0}]
# Keep every 50/60-MHz CDC route below one USB period. This protects Gray
# pointer coherency and bundled mailbox data; a blanket async clock group
# would have higher precedence than these Gowin max-delay constraints.
set_max_delay -from [get_clocks {clk_50mhz}] -to [get_clocks {usb_clk60}] 16.0
set_max_delay -from [get_clocks {usb_clk60}] -to [get_clocks {clk_50mhz}] 16.0
set_false_path -hold -from [get_clocks {clk_50mhz}] -to [get_clocks {usb_clk60}]
set_false_path -hold -from [get_clocks {usb_clk60}] -to [get_clocks {clk_50mhz}]

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
# CEA 1280x720p: 75 MHz pixel, 375 MHz DDR serializer clock.
create_clock -name pix_clk -period 13.333 [get_pins {hdmi_i/pll_i/PLL_inst/CLKOUT0}]
create_clock -name pix_clk_5x -period 2.667 [get_pins {hdmi_i/pll_i/PLL_inst/CLKOUT1}]
set_clock_groups -asynchronous -group [get_clocks {pix_clk pix_clk_5x}] -group [get_clocks {clk_50mhz}]
set_clock_groups -asynchronous -group [get_clocks {usb_clk60}] -group [get_clocks {pix_clk pix_clk_5x}]

# OSER10 RESET is an asynchronous control input.  Its synchronizers are
# preserved per lane and physically anchored beside the three serializers in
# the CST, matching the hardware-proven colorbar design.  Exclude the
# asynchronous assertion path into those three-stage synchronizers and the
# half-cycle OSER recovery analysis. Deassertion is made synchronous by the
# shift registers themselves, so neither path is an ordinary timed data path.
set_false_path -from [get_pins {hdmi_i/reset_sr*/Q}] -to [get_pins {hdmi_i/dvi_i/gen_enc[*].dvi_tx_tmds_phy_inst/reset_5x_sr*/PRESET}]
set_false_path -from [get_pins {hdmi_i/dvi_i/gen_enc[*].dvi_tx_tmds_phy_inst/reset_5x_sr*/Q}] -to [get_pins {hdmi_i/dvi_i/gen_enc[*].dvi_tx_tmds_phy_inst/tmds_serdes_inst0/RESET}]

# DDR3 main-memory backend: hard 400 MHz memory clock and 100 MHz app clock.
# These constraints are the proven SBC/old framebuffer set, with the current
# top-level hierarchy. The DDR clocks are unrelated to the CPU/HDMI domains;
# all crossings use explicit toggle synchronizers.
create_clock -name ddr_mem -period 2.5 -waveform {0 1.25} [get_pins {ddr_mem_pll_i/u_pll/PLL_inst/CLKOUT2}]
create_clock -name ddr_clk_x1 -period 10 [get_pins {ddr3_ip_i/gw3_top/u_ddr_phy_top/fclkdiv/CLKOUT}]
set_clock_groups -asynchronous -group [get_clocks {ddr_mem ddr_clk_x1}] -group [get_clocks {clk_50mhz}]
set_clock_groups -asynchronous -group [get_clocks {ddr_mem ddr_clk_x1}] -group [get_clocks {pix_clk pix_clk_5x}]
set_clock_groups -asynchronous -group [get_clocks {usb_clk60}] -group [get_clocks {ddr_mem ddr_clk_x1}]

# Quasi-static vendor PHY calibration controls. These are written by the init
# FSM and stable when consumed; timing them as ordinary synchronous paths can
# route the calibration network badly enough that hardware training fails.
set_false_path -from [get_pins {ddr3_ip_i/gw3_top/u_ddr_phy_top/u_ddr_init/read_rclksel_conf*/Q}] -to [get_pins {ddr3_ip_i/gw3_top/u_ddr_phy_top/u_ddr_phy_wds/data_lane_gen[*].u_ddr_phy_data_lane/u_ddr_phy_data_io/u_dqs/HOLD}]
set_false_path -from [get_pins {ddr3_ip_i/gw3_top/u_ddr_phy_top/u_ddr_init/hold_gen[*].hold_i*/Q}] -to [get_pins {ddr3_ip_i/gw3_top/u_ddr_phy_top/u_ddr_phy_wds/data_lane_gen[*].u_ddr_phy_data_lane/u_ddr_phy_data_io/u_dqs/HOLD}]
set_false_path -from [get_pins {ddr3_ip_i/gw3_top/u_ddr_phy_top/u_ddr_phy_wds/data_lane_gen[*].u_ddr_phy_data_lane/u_ddr_phy_data_io/ides_calib_d*/Q}] -to [get_pins {ddr3_ip_i/gw3_top/u_ddr_phy_top/u_ddr_phy_wds/data_lane_gen[*].u_ddr_phy_data_lane/u_ddr_phy_data_io/iserdes_gen[*].u_ides8_mem/CALIB}]

# PS/2 clock and data are asynchronous external open-collector signals. The
# receiver synchronizes ps2_clk into clk_50mhz before detecting its falling
# edge; exclude only the asynchronous pad-to-first-stage paths.
set_false_path -from [get_ports {ps2_clk ps2_data}]

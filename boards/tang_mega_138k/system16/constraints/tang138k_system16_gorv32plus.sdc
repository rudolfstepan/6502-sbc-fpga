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

# OSER10 RESET is an asynchronous control input.  Its synchronizers are
# preserved per lane and physically anchored beside the three serializers in
# the CST, matching the hardware-proven colorbar design.  Exclude the
# half-cycle recovery analysis so timing-driven routing spends its effort on
# the real pixel, CPU and DDR data paths.
set_false_path -from [get_pins {hdmi_i/dvi_i/gen_enc[*].dvi_tx_tmds_phy_inst/reset_5x_sr*/Q}] -to [get_pins {hdmi_i/dvi_i/gen_enc[*].dvi_tx_tmds_phy_inst/tmds_serdes_inst0/RESET}]

# DDR3 framebuffer backend: 400 MHz memory clock from the free-running DDR
# PLL and the 100 MHz app clock from the PHY's fclkdiv (objects per Sipeed's
# ddr_memory_test_uart example; same entries as the proven tang138k_sbc SDC,
# minus its generate-scope prefix). The DDR tree is asynchronous to both the
# oscillator and the HDMI tree; every boundary in sys16_fb_ddr3 is a toggle
# handshake through 3-stage synchronisers, the line buffer and the calib
# flag are synchronised likewise.
create_clock -name ddr_mem    -period 2.5 -waveform {0 1.25} [get_pins {ddr_mem_pll_i/u_pll/PLL_inst/CLKOUT2}]
create_clock -name ddr_clk_x1 -period 10 [get_pins {ddr3_ip_i/gw3_top/u_ddr_phy_top/fclkdiv/CLKOUT}]
set_clock_groups -asynchronous -group [get_clocks {ddr_mem ddr_clk_x1}] -group [get_clocks {clk_50mhz}]
set_clock_groups -asynchronous -group [get_clocks {ddr_mem ddr_clk_x1}] -group [get_clocks {pix_clk pix_clk_5x}]

# The compact USB HID core runs from its own 11.94 MHz PLL. Its VHDL wrapper
# crosses reports into clk_50mhz with toggle handshakes and two-flop data
# synchronisers; reset is asynchronous by design. Do not time these CDC paths
# as if the unrelated PLL edges had a fixed phase relationship.
create_clock -name usb_clk -period 83.752 [get_pins {usb_pll_i/PLL_inst/CLKOUT0}]
set_clock_groups -asynchronous -group [get_clocks {usb_clk}] -group [get_clocks {clk_50mhz}]
set_clock_groups -asynchronous -group [get_clocks {usb_clk}] -group [get_clocks {pix_clk pix_clk_5x}]
set_clock_groups -asynchronous -group [get_clocks {usb_clk}] -group [get_clocks {ddr_mem ddr_clk_x1}]

# Quasi-static DDR3 PHY calibration/config registers: written by the init
# FSM, stable when consumed (vendor-flow false paths, copied from the SBC).
set_false_path -from [get_pins {ddr3_ip_i/gw3_top/u_ddr_phy_top/u_ddr_init/read_rclksel_conf*/Q}] -to [get_pins {ddr3_ip_i/gw3_top/u_ddr_phy_top/u_ddr_phy_wds/data_lane_gen[*].u_ddr_phy_data_lane/u_ddr_phy_data_io/u_dqs/HOLD}]
set_false_path -from [get_pins {ddr3_ip_i/gw3_top/u_ddr_phy_top/u_ddr_init/hold_gen[*].hold_i*/Q}] -to [get_pins {ddr3_ip_i/gw3_top/u_ddr_phy_top/u_ddr_phy_wds/data_lane_gen[*].u_ddr_phy_data_lane/u_ddr_phy_data_io/u_dqs/HOLD}]
set_false_path -from [get_pins {ddr3_ip_i/gw3_top/u_ddr_phy_top/u_ddr_phy_wds/data_lane_gen[*].u_ddr_phy_data_lane/u_ddr_phy_data_io/ides_calib_d*/Q}] -to [get_pins {ddr3_ip_i/gw3_top/u_ddr_phy_top/u_ddr_phy_wds/data_lane_gen[*].u_ddr_phy_data_lane/u_ddr_phy_data_io/iserdes_gen[*].u_ides8_mem/CALIB}]

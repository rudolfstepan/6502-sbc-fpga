# 50 MHz board oscillator
create_clock -name clk_50mhz -period 20 [get_ports {clk_50mhz}]

# Without user clocks Gowin auto-derives every PLL output as a
# "*.default_gen_clk" with clk_50mhz as master and times ALL domains as
# synchronous to each other -- the timing report then shows impossible CDC
# paths (worst slack -6.4 ns on the long_reset synchroniser) and the router
# burns its budget on them instead of the real paths, which is how the DDR3
# calibration logic ended up untimed. User clocks on the exact PLL output
# pins replace those defaults; the async clock groups below restore the real
# domain relationships.

# HDMI PLL (tang138k_hdmi_tx): 25 MHz pixel, 125 MHz TMDS bit, 50 MHz system.
create_clock -name clk_pix -period 40 [get_pins {hdmi_i/pll_i/PLL_inst/CLKOUT0}]
create_clock -name clk_5x  -period 8  [get_pins {hdmi_i/pll_i/PLL_inst/CLKOUT1}]
create_clock -name clk_sys -period 20 [get_pins {hdmi_i/pll_i/PLL_inst/CLKOUT2}]
set_false_path -hold -from [get_clocks {clk_sys}] -to [get_clocks {clk_pix}]

# DDR3 clocks: 400 MHz memory clock from the free-running DDR PLL and the
# 100 MHz app clock from the PHY's fclkdiv (objects per Sipeed's
# ddr_memory_test_uart example for this device).
create_clock -name ddr_mem    -period 2.5 -waveform {0 1.25} [get_pins {ddr_backend_g.ddr_mem_pll_i/u_pll/PLL_inst/CLKOUT2}]
create_clock -name ddr_clk_x1 -period 10 [get_pins {ddr_backend_g.ddr3_ip_i/gw3_top/u_ddr_phy_top/fclkdiv/CLKOUT}]

# The DDR clock tree is asynchronous to the oscillator/HDMI tree; every
# boundary uses explicit synchronisers (vic_fb_ddr3 CDC toggles,
# ddr_calib_sys_sync, ddr_lock/cal_sync).
set_clock_groups -asynchronous -group [get_clocks {ddr_mem ddr_clk_x1}] -group [get_clocks {clk_50mhz clk_sys clk_pix clk_5x}]

# First stage of the long-reset synchroniser from the system domain into the
# oscillator-clocked DDR reset sequencer (clk_sys -> clk_50mhz, same group).
set_false_path -from [get_pins {long_reset_s0/Q}] -to [get_pins {long_reset_27_sync_0_s0/D}]

# Quasi-static DDR3 PHY calibration/config registers: written by the init FSM,
# stable when consumed. The vendor flow treats these cross-domain control
# paths as false paths (GW5AST equivalents of the proven 20K/c64_ddr set);
# they were the only violated endpoints left after the clock cleanup.
set_false_path -from [get_pins {ddr_backend_g.ddr3_ip_i/gw3_top/u_ddr_phy_top/u_ddr_init/read_rclksel_conf*/Q}] -to [get_pins {ddr_backend_g.ddr3_ip_i/gw3_top/u_ddr_phy_top/u_ddr_phy_wds/data_lane_gen[*].u_ddr_phy_data_lane/u_ddr_phy_data_io/u_dqs/HOLD}]
set_false_path -from [get_pins {ddr_backend_g.ddr3_ip_i/gw3_top/u_ddr_phy_top/u_ddr_init/hold_gen[*].hold_i*/Q}] -to [get_pins {ddr_backend_g.ddr3_ip_i/gw3_top/u_ddr_phy_top/u_ddr_phy_wds/data_lane_gen[*].u_ddr_phy_data_lane/u_ddr_phy_data_io/u_dqs/HOLD}]
set_false_path -from [get_pins {ddr_backend_g.ddr3_ip_i/gw3_top/u_ddr_phy_top/u_ddr_phy_wds/data_lane_gen[*].u_ddr_phy_data_lane/u_ddr_phy_data_io/ides_calib_d*/Q}] -to [get_pins {ddr_backend_g.ddr3_ip_i/gw3_top/u_ddr_phy_top/u_ddr_phy_wds/data_lane_gen[*].u_ddr_phy_data_lane/u_ddr_phy_data_io/iserdes_gen[*].u_ides8_mem/CALIB}]

# OSER10 reset is a reset/control path into the HDMI serializer. It is held
# until the HDMI PLL is locked and synchronously released by the PHY wrapper.
set_false_path -from [get_pins {hdmi_i/dvi_i/gen_enc[*].dvi_tx_tmds_phy_inst/reset_5x_sr*/Q}] -to [get_pins {hdmi_i/dvi_i/gen_enc[*].dvi_tx_tmds_phy_inst/tmds_serdes_inst0/RESET}]

# The T65 state registers are clock-enabled on alternating system cycles.
set_multicycle_path 2 -setup -from [get_pins {sbc_i/cpu_i/core_i/*/Q}] -to [get_pins {sbc_i/cpu_i/core_i/*/D}]
set_multicycle_path 1 -hold -from [get_pins {sbc_i/cpu_i/core_i/*/Q}] -to [get_pins {sbc_i/cpu_i/core_i/*/D}]

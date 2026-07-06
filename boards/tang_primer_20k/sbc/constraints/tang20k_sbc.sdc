# 27 MHz board oscillator
create_clock -name clk_27mhz -period 37.037 [get_ports {clk_27mhz}]

# Internal clocks are generated from the 270 MHz PLL root in
# tang20k_hdmi_tx: 54 MHz SBC and 27 MHz pixel clocks.
create_clock -name clk_sys -period 18.518 [get_nets {clk_sys}]
create_clock -name clk_pix -period 37.037 [get_nets {hdmi_i/clk_pix_i}]
set_false_path -hold -from [get_clocks {clk_sys}] -to [get_clocks {clk_pix}]

# First stage of the long-reset synchroniser from the 54 MHz system domain into
# the 27 MHz DDR reset sequencer domain.
set_false_path -from [get_pins {long_reset_s0/Q}] -to [get_pins {long_reset_27_sync_0_s0/D}]

# DDR3 IP clocks. The DDR app/memory clocks come from their own Gowin PLL and
# are asynchronous to the HDMI/SBC clock tree; the framebuffer bridge uses
# explicit toggle/level synchronisers at the boundary.
create_clock -name ddr_clk_x1 -period 10  [get_nets {ddr_clk_x1}]
create_clock -name ddr_mem    -period 2.5 [get_nets {ddr_memory_clk}]
set_clock_groups -asynchronous -group [get_clocks {ddr_clk_x1 ddr_mem}] -group [get_clocks {clk_27mhz clk_sys clk_pix}]

# Gowin's DDR3 PHY calibration logic crosses internally between the app clock
# and memory-clock IOLOGIC controls. The generated IP has no companion SDC for
# these implementation paths; match the proven c64_ddr constraints with the SBC
# hierarchy prefix.
set_false_path -from [get_pins {ddr_backend_g.ddr3_ip_i/gw3_top/i4/u_ddr_phy_init/ides_calib_reg_*_s0/Q}] -to [get_pins {ddr_backend_g.ddr3_ip_i/gw3_top/i4/u_ddr_phy_wd/data_lane_gen[*].u_ddr3_phy_data_lane/u_ddr3_phy_data_io/iserdes_gen[*].u_ides8_mem/CALIB}]
set_false_path -from [get_pins {ddr_backend_g.ddr3_ip_i/gw3_top/i4/u_ddr_phy_init/hold_s0/Q}] -to [get_pins {ddr_backend_g.ddr3_ip_i/gw3_top/i4/u_ddr_phy_wd/data_lane_gen[*].u_ddr3_phy_data_lane/u_ddr3_phy_data_io/u_dqs/HOLD}]
set_false_path -to [get_pins {ddr_backend_g.ddr3_ip_i/gw3_top/i4/dll_step_*_s0/D ddr_backend_g.ddr3_ip_i/gw3_top/i4/dll_step_base_*_s0/D}]

# The T65 state registers are clock-enabled on alternating 54 MHz cycles.
# Internal T65 register-to-register paths therefore have two system-clock
# periods. External bus paths deliberately remain single-cycle constrained.
set_multicycle_path 2 -setup -from [get_pins {sbc_i/cpu_i/core_i/*/Q}] -to [get_pins {sbc_i/cpu_i/core_i/*/D}]
set_multicycle_path 1 -hold -from [get_pins {sbc_i/cpu_i/core_i/*/Q}] -to [get_pins {sbc_i/cpu_i/core_i/*/D}]

# PS/2 keyboard clock is asynchronous input (~10-16.7 kHz from keyboard).
# Sampled through a 3-FF synchroniser; no setup/hold constraints needed.

# DDR3 app/SBC CDC details live in vic_fb_ddr3; review the generated timing
# report after each DDR-facing change.

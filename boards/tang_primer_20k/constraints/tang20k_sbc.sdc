# 27 MHz board oscillator
create_clock -name clk_27mhz -period 37.037 [get_ports {clk_27mhz}]

# Internal clocks are generated from the 270 MHz PLL root in
# tang20k_hdmi_tx: 54 MHz SBC and 27 MHz pixel clocks.

# The T65 state registers are clock-enabled on alternating 54 MHz cycles.
# Internal T65 register-to-register paths therefore have two system-clock
# periods. External bus paths deliberately remain single-cycle constrained.
set_multicycle_path 2 -setup -from [get_pins {sbc_i/cpu_i/core_i/*/Q}] -to [get_pins {sbc_i/cpu_i/core_i/*/D}]
set_multicycle_path 1 -hold -from [get_pins {sbc_i/cpu_i/core_i/*/Q}] -to [get_pins {sbc_i/cpu_i/core_i/*/D}]

# PS/2 keyboard clock is asynchronous input (~10-16.7 kHz from keyboard).
# Sampled through a 3-FF synchroniser; no setup/hold constraints needed.

# DDR3 clock profile (official Gowin DDR3 Memory Interface IP). The PLL
# (ddr_pll_i) makes ddr_memory_clk 99 MHz (DDR3 CK); the IP divides it by 4 to
# clk_out ~25 MHz (ddr_clk_x1, the user/app clock). Both nets always exist (PLL
# at top level). The IP's own generated timing handles its internal PHY clocks.
create_clock -name ddr_memory_clk -period 10 [get_nets {ddr_memory_clk}]
create_clock -name ddr_clk_x1     -period 40 [get_nets {ddr_clk_x1}]
set_clock_groups -asynchronous -group [get_clocks {ddr_memory_clk ddr_clk_x1}] -group [get_clocks {clk_27mhz}]

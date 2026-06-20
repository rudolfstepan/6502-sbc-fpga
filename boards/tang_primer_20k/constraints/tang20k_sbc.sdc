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

# ── DDR3 memory interface clocks (from the Sipeed DDR-test ddr3.sdc) ─────────
# The Gowin DDR3 IP runs its user interface (clk_x1) at 100 MHz and the memory
# clock at 400 MHz (DDR-800). These are asynchronous to the 54 MHz SBC clock;
# the ddr3_byte_bridge crosses between clk_sys and clk_x1 with a req/ack
# handshake, so the two domains are declared as separate asynchronous groups.
create_clock -name ddr_clk_x1 -period 10    [get_nets {ddr_clk_x1}]
create_clock -name ddr_mem    -period 2.5   [get_nets {ddr_memory_clk}]
set_clock_groups -asynchronous -group [get_clocks {ddr_clk_x1 ddr_mem}] -group [get_clocks {clk_27mhz}]
report_timing -hold -from_clock [get_clocks {ddr_mem}] -to_clock [get_clocks {ddr_clk_x1}] -max_paths 25 -max_common_paths 1
report_timing -setup -from_clock [get_clocks {ddr_mem}] -to_clock [get_clocks {ddr_clk_x1}] -max_paths 25 -max_common_paths 1

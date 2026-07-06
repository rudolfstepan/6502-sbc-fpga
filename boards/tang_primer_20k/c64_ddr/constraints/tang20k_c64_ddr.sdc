# 27 MHz board oscillator (also the C64 core/pixel clock after the PLL).
create_clock -name clk_27mhz -period 37.037 [get_ports {clk_27mhz}]

# Internal 135 MHz TMDS + 27 MHz pixel/system clocks are generated in
# tang20k_hdmi_tx from the 270 MHz PLL root.

# DDR3 IP clocks. The 100 MHz app clock and 400 MHz memory clock are generated
# by the local Gowin DDR PLL and are asynchronous to the 27 MHz C64/HDMI PLL
# domain; ddr3_byte_bridge contains the explicit CDC.
create_clock -name ddr_clk_x1 -period 10 [get_nets {ddr_clk_x1}]
create_clock -name ddr_mem -period 2.5 [get_nets {ddr_memory_clk}]
set_clock_groups -asynchronous -group [get_clocks {ddr_clk_x1 ddr_mem}] -group [get_clocks {clk_27mhz}]

# Gowin's DDR3 hard/soft PHY drives IDELAY/DQS calibration controls from the
# app-clock-side init FSM into IOLOGIC cells in the memory-clock domain. The IP
# generator does not emit a companion SDC here, so constrain only those internal
# calibration/control pins explicitly; otherwise the report shows impossible
# ddr_clk_x1 -> ddr_mem setup paths on CALIB/HOLD pins.
set_false_path -from [get_pins {ddr3_ip_i/gw3_top/i4/u_ddr_phy_init/ides_calib_reg_*_s0/Q}] -to [get_pins {ddr3_ip_i/gw3_top/i4/u_ddr_phy_wd/data_lane_gen[*].u_ddr3_phy_data_lane/u_ddr3_phy_data_io/iserdes_gen[*].u_ides8_mem/CALIB}]
set_false_path -from [get_pins {ddr3_ip_i/gw3_top/i4/u_ddr_phy_init/hold_s0/Q}] -to [get_pins {ddr3_ip_i/gw3_top/i4/u_ddr_phy_wd/data_lane_gen[*].u_ddr3_phy_data_lane/u_ddr3_phy_data_io/u_dqs/HOLD}]
set_false_path -to [get_pins {ddr3_ip_i/gw3_top/i4/dll_step_*_s0/D ddr3_ip_i/gw3_top/i4/dll_step_base_*_s0/D}]

# The T65 CPU is clock-enabled at the ~1 MHz PHI2 rate (27 pixel clocks per CPU
# cycle), so its INTERNAL register-to-register paths have many pixel clocks to
# settle -- multicycle only those (both -from and -to are core_i registers).
#
# IMPORTANT: do NOT multicycle the data-IN paths (-> core_i/D from the RAM read
# mux). main RAM is single-port and time-shared with the VIC, so dram_dout changes
# EVERY pixel clock (the steal address mux). A multicycle there is a false
# relaxation -- the post-steal read must settle in ~1 cycle, so it must stay
# single-cycle constrained or the placer leaves it marginal (worked only by luck
# of placement; e.g. when the removed UART snoop happened to help routing).
set_multicycle_path 8 -setup -from [get_pins {c64_i/cpu_i/core_i/*/Q}] -to [get_pins {c64_i/cpu_i/core_i/*/D}]
set_multicycle_path 7 -hold  -from [get_pins {c64_i/cpu_i/core_i/*/Q}] -to [get_pins {c64_i/cpu_i/core_i/*/D}]

# Relax the ROM and I/O read-mux paths into the CPU (basic/kernal/chargen ROM,
# CIA/VIC/SID). These feed cpu_din through a long combinational mux and were
# placement-marginal at single-cycle -> the per-reset "38911 vs 6285" banner
# lottery (FP table reads from BASIC ROM) and a marginal CIA ICR read (cursor/
# keys). They are NOT time-shared with the VIC (no steal address mux), so the
# read has the full ~27-clock CPU cycle to settle -- multicycling is correct.
# Deliberately EXCLUDED: ram_i and colram_i, which ARE stolen (their dout changes
# at the steal boundary) and must stay single-cycle (the 4-clock cpu_en guard
# handles their post-steal settle instead).
set_multicycle_path 4 -setup -from [get_pins {c64_i/basic_i/*/Q c64_i/kernal_i/*/Q c64_i/chargen_i/*/Q c64_i/cia1_i/*/Q c64_i/cia2_i/*/Q c64_i/vic_i/*/Q c64_i/sid_i/*/Q}] -to [get_pins {c64_i/cpu_i/core_i/*/D}]
set_multicycle_path 3 -hold  -from [get_pins {c64_i/basic_i/*/Q c64_i/kernal_i/*/Q c64_i/chargen_i/*/Q c64_i/cia1_i/*/Q c64_i/cia2_i/*/Q c64_i/vic_i/*/Q c64_i/sid_i/*/Q}] -to [get_pins {c64_i/cpu_i/core_i/*/D}]

# (The $DE00 host-disk UART read into the CPU is a short register->mux path, not
# steal-coupled, so it needs no special constraint.)

# PS/2 keyboard clock is an asynchronous ~10-16.7 kHz input, sampled through a
# 3-FF synchroniser; no setup/hold constraints needed.

# DDR3 app clock and the C64/pixel clock are separate domains. The byte bridge
# crosses them through explicit toggle/level synchronizers and stable payload
# registers; review the generated timing report after each DDR change.
set_false_path -from [get_pins {c64_i/ram_req_reg*/Q c64_i/ram_we_lat*/Q c64_i/ram_addr_lat*/Q c64_i/ram_din_lat*/Q ddr_bridge_i/req_tgl_sys*/Q}] -to [get_pins {ddr_bridge_i/req_tgl_x1*/D ddr_bridge_i/op_we*/D ddr_bridge_i/op_addr*/D ddr_bridge_i/op_din*/D}]
set_false_path -from [get_pins {ddr_bridge_i/ack_tgl_x1*/Q ddr_bridge_i/op_dout*/Q ddr_bridge_i/ready_x1*/Q ddr_bridge_i/t_active_x1*/Q ddr_bridge_i/t_done_x1*/Q ddr_bridge_i/t_error_x1*/Q}] -to [get_pins {ddr_bridge_i/ack_tgl_sys*/D ddr_bridge_i/dout_reg*/D ddr_bridge_i/ready_sync_sys*/D ddr_bridge_i/test_active_sync_sys*/D ddr_bridge_i/test_done_sync_sys*/D ddr_bridge_i/test_error_sync_sys*/D}]

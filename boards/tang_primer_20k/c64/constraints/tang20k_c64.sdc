# 27 MHz board oscillator (also the C64 core/pixel clock after the PLL).
create_clock -name clk_27mhz -period 37.037 [get_ports {clk_27mhz}]

# Internal 135 MHz TMDS + 27 MHz pixel/system clocks are generated in
# tang20k_hdmi_tx from the 270 MHz PLL root.

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

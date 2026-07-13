create_clock -name clk50m -period 20.000 -waveform {0 10.000} [get_ports {clk_50mhz}]

create_clock -name ae350_ddr_clk -period 20.000 -waveform {0 10.000} [get_pins {u_Gowin_PLL_AE350/u_pll/PLL_inst/CLKOUT0}]
create_clock -name ae350_ahb_clk -period 20.000 -waveform {0 10.000} [get_pins {u_Gowin_PLL_AE350/u_pll/PLL_inst/CLKOUT2}]
create_clock -name ae350_apb_clk -period 20.000 -waveform {0 10.000} [get_pins {u_Gowin_PLL_AE350/u_pll/PLL_inst/CLKOUT3}]
create_clock -name ddr3_memory_clk -period 5.000 -waveform {0 2.500} [get_pins {u_Gowin_PLL_DDR3/u_pll/PLL_inst/CLKOUT2}]
create_clock -name ddr3_clkin -period 20.000 -waveform {0 10.000} [get_pins {u_Gowin_PLL_DDR3/u_pll/PLL_inst/CLKOUT0}]
create_clock -name ddr3_sysclk -period 20.000 -waveform {0 10.000} [get_pins {u_RiscV_AE350_SOC_Top/u_RiscV_AE350_SOC/u_riscv_ae350_ddr3_top/u_ddr3_memory_ahb_top/u_ddr3/gw3_top/u_ddr_phy_top/fclkdiv/CLKOUT}]
create_clock -name flash_sysclk -period 20.000 -waveform {0 10.000} [get_nets {u_RiscV_AE350_SOC_Top/FLASH_SPI_CLK_in}]
create_clock -name flash_spi_clk_i -period 20.000 -waveform {0 10.000} [get_pins {u_RiscV_AE350_SOC_Top/FLASH_SPI_CLK_iobuf/I}]
create_clock -name flash_spi_clk -period 20.000 -waveform {0 10.000} [get_ports {flash_clk}]

set_clock_groups -exclusive -group [get_clocks {flash_sysclk}] -group [get_clocks {ae350_ahb_clk}] -group [get_clocks {ae350_apb_clk}] -group [get_clocks {ae350_ddr_clk}]
set_clock_groups -asynchronous -group [get_clocks {ddr3_clkin}] -group [get_clocks {ddr3_sysclk}]
set_clock_groups -asynchronous -group [get_clocks {ddr3_sysclk}] -group [get_clocks {ddr3_memory_clk}]
set_clock_groups -exclusive -group [get_clocks {ddr3_memory_clk}] -group [get_clocks {ddr3_clkin}]
set_clock_groups -exclusive -group [get_clocks {clk50m}] -group [get_clocks {ddr3_sysclk}]


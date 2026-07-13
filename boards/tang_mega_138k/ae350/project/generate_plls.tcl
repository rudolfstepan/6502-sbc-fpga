open_project tang138k_ae350.gprj

create_ipc -force -name clock_plladv -module_name Gowin_PLL_AE350 -language Verilog -file_name gowin_pll_ae350
set_property -dict {
  CONFIG.CLKIN_FREQ 50
  CONFIG.Clock_Enable_Ports true
  CONFIG.CLKOUT0_FREQ 50
  CONFIG.CLKOUT1_EN true
  CONFIG.CLKOUT1_FREQ 800
  CONFIG.CLKOUT2_EN true
  CONFIG.CLKOUT2_FREQ 50
  CONFIG.CLKOUT3_EN true
  CONFIG.CLKOUT3_FREQ 50
  CONFIG.CLKOUT4_EN true
  CONFIG.CLKOUT4_FREQ 10
} [get_ips Gowin_PLL_AE350]
generate_target [get_ips Gowin_PLL_AE350]

create_ipc -force -name clock_plladv -module_name Gowin_PLL_DDR3 -language Verilog -file_name gowin_pll_ddr3
set_property -dict {
  CONFIG.CLKIN_FREQ 50
  CONFIG.Clock_Enable_Ports true
  CONFIG.PLL_Reset true
  CONFIG.LOCK_EN true
  CONFIG.CLKOUT0_FREQ 50
  CONFIG.CLKOUT2_EN true
  CONFIG.CLKOUT2_FREQ 200
} [get_ips Gowin_PLL_DDR3]
generate_target [get_ips Gowin_PLL_DDR3]

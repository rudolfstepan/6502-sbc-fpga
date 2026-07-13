open_project tang138k_ae350_itcm.gprj

create_ipc -force -name clock_plladv -module_name Gowin_PLL_AE350_ITCM -language Verilog -file_name gowin_pll_ae350_itcm
set_property -dict {
  CONFIG.CLKIN_FREQ 50
  CONFIG.Clock_Enable_Ports true
  CONFIG.CLKOUT0_FREQ 100
  CONFIG.CLKOUT1_EN true
  CONFIG.CLKOUT1_FREQ 800
  CONFIG.CLKOUT2_EN true
  CONFIG.CLKOUT2_FREQ 100
  CONFIG.CLKOUT3_EN true
  CONFIG.CLKOUT3_FREQ 100
  CONFIG.CLKOUT4_EN true
  CONFIG.CLKOUT4_FREQ 10
  CONFIG.LOCK_EN true
} [get_ips Gowin_PLL_AE350_ITCM]
generate_target [get_ips Gowin_PLL_AE350_ITCM]

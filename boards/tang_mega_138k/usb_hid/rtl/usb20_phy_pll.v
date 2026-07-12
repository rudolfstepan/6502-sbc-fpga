// 50 MHz -> 480 MHz (CLKOUT0) and 60 MHz (CLKOUT1), VCO = 1200 MHz.
// CLKOUT0 uses the GW5 fractional output divider: 1200 / 2.5 = 480 MHz.
module usb20_phy_pll(output lock, output clk60, output clk480, input clkin);
  wire vcc = 1'b1, gnd = 1'b0;
  wire c2,c3,c4,c5,c6,fb;
  PLL PLL_inst (
    .LOCK(lock), .CLKOUT0(clk480), .CLKOUT1(clk60), .CLKOUT2(c2),
    .CLKOUT3(c3), .CLKOUT4(c4), .CLKOUT5(c5), .CLKOUT6(c6),
    .CLKFBOUT(fb), .CLKIN(clkin), .CLKFB(gnd), .RESET(gnd), .PLLPWD(gnd),
    .RESET_I(gnd), .RESET_O(gnd),
    .FBDSEL(6'b0), .IDSEL(6'b0), .MDSEL(7'b0), .MDSEL_FRAC(3'b0),
    .ODSEL0(7'b0), .ODSEL0_FRAC(3'b0), .ODSEL1(7'b0), .ODSEL2(7'b0),
    .ODSEL3(7'b0), .ODSEL4(7'b0), .ODSEL5(7'b0), .ODSEL6(7'b0),
    .DT0(4'b0), .DT1(4'b0), .DT2(4'b0), .DT3(4'b0),
    .ICPSEL(6'b0), .LPFRES(3'b0), .LPFCAP(2'b0),
    .PSSEL(3'b0), .PSDIR(gnd), .PSPULSE(gnd),
    .ENCLK0(vcc), .ENCLK1(vcc), .ENCLK2(vcc), .ENCLK3(vcc),
    .ENCLK4(vcc), .ENCLK5(vcc), .ENCLK6(vcc),
    .SSCPOL(gnd), .SSCON(gnd), .SSCMDSEL(7'b0), .SSCMDSEL_FRAC(3'b0)
  );
  defparam PLL_inst.FCLKIN = "50";
  defparam PLL_inst.IDIV_SEL = 1;
  defparam PLL_inst.FBDIV_SEL = 1;
  defparam PLL_inst.MDIV_SEL = 24;
  defparam PLL_inst.MDIV_FRAC_SEL = 0;
  defparam PLL_inst.ODIV0_SEL = 2;
  defparam PLL_inst.ODIV1_SEL = 20;
  defparam PLL_inst.ODIV0_FRAC_SEL = 4;
  defparam PLL_inst.CLKOUT0_EN = "TRUE";
  defparam PLL_inst.CLKOUT1_EN = "TRUE";
  defparam PLL_inst.CLKOUT2_EN = "FALSE";
  defparam PLL_inst.CLKOUT3_EN = "FALSE";
  defparam PLL_inst.CLKOUT4_EN = "FALSE";
  defparam PLL_inst.CLKOUT5_EN = "FALSE";
  defparam PLL_inst.CLKOUT6_EN = "FALSE";
  defparam PLL_inst.CLKFB_SEL = "INTERNAL";
  defparam PLL_inst.DYN_IDIV_SEL = "FALSE";
  defparam PLL_inst.DYN_FBDIV_SEL = "FALSE";
  defparam PLL_inst.DYN_MDIV_SEL = "FALSE";
  defparam PLL_inst.DYN_ODIV0_SEL = "FALSE";
  defparam PLL_inst.DYN_ODIV1_SEL = "FALSE";
  defparam PLL_inst.SSC_EN = "FALSE";
endmodule

// Board shell for the vendor GoRV32 Plus Linux CPU on the Tang Console 138K.
// The CPU reset-fetches at 0x80000000; the IP's QSPI controller maps that
// window to SPI-flash offset FLASH_BURN_ADDR (0x500000 in this project).
// The self-built ZSBL burned there (linux/zsbl) copies OpenSBI, DTB and
// kernel from the same XIP window into SDRAM (the AXI DDR window at CPU
// address 0x00000000) and jumps to OpenSBI. Console is UART1, a 16550 at
// 0xF0200020 (Andes-style +0x20 offset), 115200 8N1 at 50 MHz APB clock.
module sys16_gorv32plus_top(
  input wire clk_50mhz,
  input wire [1:0] key,
  output wire [3:0] led,
  input wire uart_rx,
  output wire uart_tx,
  // Tang Console USB-A HID host (official Sipeed direct-GPIO pinout).
  inout wire usb_dm, inout wire usb_dp,
  // On-board 128Mbit NOR flash on the MSPI pins; boot code source.
  inout wire flash_cs_n, inout wire flash_clk,
  inout wire flash_mosi, inout wire flash_miso,
  inout wire flash_wp_n, inout wire flash_hold_n,
  // TF slot in native 4-bit SD mode for the vendor SD_Card controller.
  output wire sd_clk, inout wire sd_cmd, inout wire [3:0] sd_dat,
  output wire dvi_a_psv, input wire dvi_a_hpd,
  inout wire dvi_ddc_clk, inout wire dvi_ddc_dat,
  output wire tmds_clk_p, output wire tmds_clk_n,
  output wire [2:0] tmds_d_p, output wire [2:0] tmds_d_n,
  output wire sdram0_clk, output wire sdram0_cs_n,
  output wire sdram0_ras_n, output wire sdram0_cas_n,
  output wire sdram0_we_n, output wire [1:0] sdram0_ba,
  output wire [12:0] sdram0_addr, output wire [1:0] sdram0_dqm,
  inout wire [15:0] sdram0_dq,
  // On-board DDR3 (32-bit, on the core module): framebuffer backend.
  // Pins and bring-up copied from the proven tang138k_sbc port.
  output wire [14:0] ddr_addr, output wire [2:0] ddr_bank,
  output wire ddr_cs, output wire ddr_ras, output wire ddr_cas,
  output wire ddr_we, output wire ddr_ck, output wire ddr_ck_n,
  output wire ddr_cke, output wire ddr_odt, output wire ddr_reset_n,
  output wire [3:0] ddr_dm, inout wire [31:0] ddr_dq,
  inout wire [3:0] ddr_dqs, inout wire [3:0] ddr_dqs_n
);
  reg [15:0] por = 0;
  always @(posedge clk_50mhz)
    if(!key[0]) por <= 16'h0000;
    else if(por != 16'hffff) por <= por + 1'b1;
  wire resetn = &por;
  wire jtag_tdo;
  wire [31:0] araddr,awaddr,wdata,rdata;
  wire [1:0] arburst,awburst,bresp,rresp;wire [3:0] arcache,awcache,wstrb;
  wire [7:0] arid,arlen,awid,awlen,bid,rid;wire arlock,awlock;
  wire [2:0] arprot,arsize,awprot,awsize;
  wire arready,arvalid,awready,awvalid,bready,bvalid,rlast,rready,rvalid,wlast,wready,wvalid;
  wire [31:0] sb_addr,sb_wdata,sb_rdata;wire [3:0] sb_be;wire sb_req,sb_we,sb_ready;
  wire mem_req,mem_we,mem_ready;wire [22:0] mem_addr;wire [1:0] mem_be;
  wire [15:0] mem_wdata,mem_rdata;
  // AXI slave extension window (0xE8000000): framebuffer "graphics card".
  wire [31:0] s_araddr,s_awaddr,s_wdata,s_rdata;
  wire [1:0] s_arburst,s_awburst,s_bresp,s_rresp;wire [3:0] s_arcache,s_awcache,s_wstrb;
  wire [7:0] s_arid,s_arlen,s_awid,s_awlen,s_bid,s_rid;wire s_arlock,s_awlock;
  wire [2:0] s_arprot,s_arsize,s_awprot,s_awsize;
  wire s_arready,s_arvalid,s_awready,s_awvalid,s_bready,s_bvalid,s_rlast,s_rready,s_rvalid,s_wlast,s_wready,s_wvalid;
  wire [31:0] fb_addr,fb_wdata,fb_rdata;wire [3:0] fb_be;wire fb_req,fb_we,fb_ready;
  wire hdmi_req,hdmi_ready; wire [31:0] hdmi_rdata;
  wire usb_sel,usb_cs,usb_irq; wire [7:0] usb_dout;
  wire usb_connected,usb_key_event,usb_polling; wire [7:0] usb_keycode,usb_modif,usb_ascii;
  wire [3:0] usb_phase; wire usb_clk_12;
  wire cpu_uart_tx,probe_tx,probe_active,probe_done;
  reg uart_tx_r=1'b1;
  wire hdmi_pll_lock;
  wire ddr_calib;  // DDR3 init_calib_complete (declared here for the LED)

  Gowin_GoRV32_Plus_Top cpu(
    .axi_clk(clk_50mhz),.ahb_clk(clk_50mhz),.apb_clk(clk_50mhz),
    .axi_resetn(resetn),.ahb_resetn(resetn),.apb_resetn(resetn),
    .FLASH_QSPI_CSN(flash_cs_n),.FLASH_QSPI_MISO(flash_miso),
    .FLASH_QSPI_MOSI(flash_mosi),.FLASH_QSPI_CLK(flash_clk),
    .FLASH_QSPI_HOLDN(flash_hold_n),.FLASH_QSPI_WPN(flash_wp_n),
    .SD_CLK(sd_clk),.SD_CMD(sd_cmd),.SD_DATA(sd_dat),
    .EXT_INT(16'b0),
    .UART1_CTSN(1'b0),.UART1_DCDN(1'b1),.UART1_DSRN(1'b1),.UART1_RIN(1'b1),
    .UART1_SIN(uart_rx),.UART1_DTRN(),.UART1_OUT1N(),.UART1_OUT2N(),
    .UART1_RTSN(),.UART1_SOUT(cpu_uart_tx),
    .DDR_ARADDR(araddr),.DDR_ARBURST(arburst),.DDR_ARCACHE(arcache),.DDR_ARID(arid),
    .DDR_ARLEN(arlen),.DDR_ARLOCK(arlock),.DDR_ARPROT(arprot),.DDR_ARREADY(arready),
    .DDR_ARSIZE(arsize),.DDR_ARVALID(arvalid),
    .DDR_AWADDR(awaddr),.DDR_AWBURST(awburst),.DDR_AWCACHE(awcache),.DDR_AWID(awid),
    .DDR_AWLEN(awlen),.DDR_AWLOCK(awlock),.DDR_AWPROT(awprot),.DDR_AWREADY(awready),
    .DDR_AWSIZE(awsize),.DDR_AWVALID(awvalid),
    .DDR_BID(bid),.DDR_BREADY(bready),.DDR_BRESP(bresp),.DDR_BVALID(bvalid),
    .DDR_RDATA(rdata),.DDR_RID(rid),.DDR_RLAST(rlast),.DDR_RREADY(rready),
    .DDR_RRESP(rresp),.DDR_RVALID(rvalid),
    .DDR_WDATA(wdata),.DDR_WLAST(wlast),.DDR_WREADY(wready),
    .DDR_WSTRB(wstrb),.DDR_WVALID(wvalid),
    .SLV_ARADDR(s_araddr),.SLV_ARBURST(s_arburst),.SLV_ARCACHE(s_arcache),.SLV_ARID(s_arid),
    .SLV_ARLEN(s_arlen),.SLV_ARLOCK(s_arlock),.SLV_ARPROT(s_arprot),.SLV_ARREADY(s_arready),
    .SLV_ARSIZE(s_arsize),.SLV_ARVALID(s_arvalid),
    .SLV_AWADDR(s_awaddr),.SLV_AWBURST(s_awburst),.SLV_AWCACHE(s_awcache),.SLV_AWID(s_awid),
    .SLV_AWLEN(s_awlen),.SLV_AWLOCK(s_awlock),.SLV_AWPROT(s_awprot),.SLV_AWREADY(s_awready),
    .SLV_AWSIZE(s_awsize),.SLV_AWVALID(s_awvalid),
    .SLV_BID(s_bid),.SLV_BREADY(s_bready),.SLV_BRESP(s_bresp),.SLV_BVALID(s_bvalid),
    .SLV_RDATA(s_rdata),.SLV_RID(s_rid),.SLV_RLAST(s_rlast),.SLV_RREADY(s_rready),
    .SLV_RRESP(s_rresp),.SLV_RVALID(s_rvalid),
    .SLV_WDATA(s_wdata),.SLV_WLAST(s_wlast),.SLV_WREADY(s_wready),
    .SLV_WSTRB(s_wstrb),.SLV_WVALID(s_wvalid),
    .JTAG_TMS(1'b0),.JTAG_TDI(1'b0),.JTAG_TDO(jtag_tdo),.JTAG_TCK(1'b0)
  );

  sys16_axi32_to_bus32 axi_fb(
    .clk(clk_50mhz),.resetn(resetn),
    .araddr(s_araddr),.arburst(s_arburst),.arid(s_arid),.arlen(s_arlen),.arsize(s_arsize),
    .arvalid(s_arvalid),.arready(s_arready),.rdata(s_rdata),.rid(s_rid),.rlast(s_rlast),
    .rresp(s_rresp),.rvalid(s_rvalid),.rready(s_rready),
    .awaddr(s_awaddr),.awburst(s_awburst),.awid(s_awid),.awlen(s_awlen),.awsize(s_awsize),
    .awvalid(s_awvalid),.awready(s_awready),.wdata(s_wdata),.wlast(s_wlast),.wstrb(s_wstrb),
    .wvalid(s_wvalid),.wready(s_wready),.bid(s_bid),.bresp(s_bresp),.bvalid(s_bvalid),.bready(s_bready),
    .bus_req(fb_req),.bus_we(fb_we),.bus_addr(fb_addr),.bus_wdata(fb_wdata),
    .bus_be(fb_be),.bus_rdata(fb_rdata),.bus_ready(fb_ready));

  sys16_axi32_to_bus32 axi_sdram(
    .clk(clk_50mhz),.resetn(resetn),
    .araddr(araddr),.arburst(arburst),.arid(arid),.arlen(arlen),.arsize(arsize),
    .arvalid(arvalid),.arready(arready),.rdata(rdata),.rid(rid),.rlast(rlast),
    .rresp(rresp),.rvalid(rvalid),.rready(rready),
    .awaddr(awaddr),.awburst(awburst),.awid(awid),.awlen(awlen),.awsize(awsize),
    .awvalid(awvalid),.awready(awready),.wdata(wdata),.wlast(wlast),.wstrb(wstrb),
    .wvalid(wvalid),.wready(wready),.bid(bid),.bresp(bresp),.bvalid(bvalid),.bready(bready),
    .bus_req(sb_req),.bus_we(sb_we),.bus_addr(sb_addr),.bus_wdata(sb_wdata),
    .bus_be(sb_be),.bus_rdata(sb_rdata),.bus_ready(sb_ready));

  sys16_bus32_to_sdram16 width_bridge(
    .clk(clk_50mhz),.reset_n(resetn),.req(sb_req),.we(sb_we),.addr(sb_addr),
    .be(sb_be),.wdata(sb_wdata),.rdata(sb_rdata),.ready(sb_ready),
    .mem_req(mem_req),.mem_we(mem_we),.mem_addr(mem_addr),.mem_be(mem_be),
    .mem_wdata(mem_wdata),.mem_rdata(mem_rdata),.mem_ready(mem_ready));

  sys16_sdram_bridge dram(
    .clk(clk_50mhz),.reset_n(resetn),.req(mem_req),.we(mem_we),.addr(mem_addr),
    .be(mem_be),.wdata(mem_wdata),.rdata(mem_rdata),.ready(mem_ready),.init_done(),
    .sdram_cs_n(sdram0_cs_n),.sdram_ras_n(sdram0_ras_n),.sdram_cas_n(sdram0_cas_n),
    .sdram_we_n(sdram0_we_n),.sdram_ba(sdram0_ba),.sdram_addr(sdram0_addr),
    .sdram_dqm(sdram0_dqm),.sdram_dq(sdram0_dq));

  // Board-level sign of life independent of flash contents. The whole
  // console chain (probe, ZSBL, OpenSBI, Linux) runs 115200 8N1.
  sys16_uart_probe probe(
    .clk(clk_50mhz),.reset_n(resetn),.start(resetn),.tx(probe_tx),
    .active(probe_active),.done(probe_done));
  // Keep the final mux off the package pin. With the DDR3 PHY present the
  // unconstrained combinational output route became placement-sensitive and
  // corrupted even the pre-CPU "FPGA BOOT OK" probe. A single 50 MHz output
  // register makes every UART edge synchronous and gives P&R an IOB-packable
  // endpoint. One clock of latency has no effect on 115200-baud framing.
  always @(posedge clk_50mhz) begin
    if (!resetn)
      uart_tx_r <= 1'b1;
    else
      uart_tx_r <= probe_active ? probe_tx : cpu_uart_tx;
  end
  assign uart_tx = uart_tx_r;

  // Official Sipeed Tang Mega 138K low-speed USB HID host.  It is a tiny
  // self-contained host (not a generic USB controller) and talks directly to
  // the USB-A D+/D- pins at 1.5 Mbit/s.  Linux sees its four registers at
  // 0xE8800100 through the existing AXI extension window.
  Gowin_USB_PLL usb_pll_i(.clkout0(usb_clk_12),.clkin(clk_50mhz));
  assign usb_sel = (fb_addr[23:8] == 16'h8001);
  assign usb_cs  = fb_req && usb_sel;
  assign hdmi_req = fb_req && !usb_sel;
  assign fb_ready = usb_sel ? fb_req : hdmi_ready;
  assign fb_rdata = usb_sel ? {24'h000000,usb_dout} : hdmi_rdata;
  usb_hid_host usb_hid_i(
    .clk(clk_50mhz),.reset_n(resetn),.usb_clk(usb_clk_12),
    .usb_dm(usb_dm),.usb_dp(usb_dp),.cs(usb_cs),.we(fb_we),
    .addr(fb_addr[3:2]),.dout(usb_dout),.irq(usb_irq),
    .diag_connected(usb_connected),.diag_keycode(usb_keycode),
    .diag_modif(usb_modif),.diag_ascii(usb_ascii),.diag_phase(usb_phase),
    .diag_key_event(usb_key_event),.diag_polling(usb_polling));

  // The vendor IP owns the IOBUFs on the FLASH_QSPI and SD pads; fabric
  // logic must not tap those nets (EX0339). CPU liveness is observable on
  // fabric nets instead: led[0] shows the DDR3 calibration (framebuffer
  // backing store ready), led[1] latches once UART1 transmitted a start bit
  // (ZSBL banner sent), led[2] latches on the first DDR AXI transfer (ZSBL
  // copy loop reached), led[3] blinks as heartbeat/polarity reference.
  reg saw_cpu_tx=1'b0, saw_ar=1'b0, saw_aw=1'b0; reg [24:0] beat=0;
  always @(posedge clk_50mhz)
    if(!resetn) begin saw_cpu_tx<=1'b0; saw_ar<=1'b0; saw_aw<=1'b0; end
    else begin
      if(!cpu_uart_tx) saw_cpu_tx<=1'b1;
      if(arvalid) saw_ar<=1'b1;
      if(awvalid) saw_aw<=1'b1;
      beat<=beat+1'b1;
    end
  assign led = {beat[24],saw_aw|saw_ar,saw_cpu_tx,ddr_calib};

  // Diagnosis on the HDMI status stripe (top 48 lines). A trapped CPU that
  // executes garbage only ever READS DDR; the ZSBL copy loop WRITES it.
  //   red     = CPU silent: no UART, no DDR at all (QSPI fetch dead)
  //   blue    = DDR reads only, no UART: CPU runs garbage, trap loop at $0
  //   magenta = DDR writes without UART: ZSBL copies but UART path is dead
  //   yellow  = UART sent, no DDR yet
  //   cyan    = UART + reads, no writes yet
  //   green   = UART + writes: boot chain healthy up to the OpenSBI jump
  reg [15:0] diag_status=16'hF800;
  always @(posedge clk_50mhz)
    casez({saw_aw,saw_ar,saw_cpu_tx})
      3'b000: diag_status<=16'hF800; // red
      3'b010: diag_status<=16'h001F; // blue
      3'b1?0: diag_status<=16'hF81F; // magenta
      3'b001: diag_status<=16'hFFE0; // yellow
      3'b011: diag_status<=16'h07FF; // cyan
      default: diag_status<=16'h07E0; // green
    endcase

  // Video graphics card behind the AXI slave window (0xE8000000): a fast
  // hardware TEXT CONSOLE (80x22 cells, 8x16 VGA font, scaled 2x to
  // 1280x704 centred in 720p). Character cells and the font ROM live in
  // BSRAM, so no external memory is used -- the DDR3 IP that backed the old
  // RGB565 framebuffer is unwired here (its sources stay in the project),
  // reclaiming its resources and build time. Registers at 0xE8800000 (ID
  // reads "S16T"); cell array at 0xE8000000. To go back to the DDR3 RGB565
  // framebuffer, restore the sys16_hdmi_fb + DDR3 block from git history.
  sys16_hdmi_text hdmi_i(
    .clk_in(clk_50mhz),.reset_n(resetn),
    .req(hdmi_req),.we(fb_we),.addr(fb_addr[23:0]),.be(fb_be),
    .wdata(fb_wdata),.rdata(hdmi_rdata),.ready(hdmi_ready),
    .status_word(diag_status),
    .pll_lock(hdmi_pll_lock),.tmds_clk_p(tmds_clk_p),.tmds_clk_n(tmds_clk_n),
    .tmds_d_p(tmds_d_p),.tmds_d_n(tmds_d_n));

  // On-board DDR3 unused in text mode: hold the SDRAM device in reset and
  // park its bus at benign levels so the 1.5 V SSTL pins are not left
  // floating. led[0] is repurposed to plain resetn (no calibration to show).
  assign ddr_addr = 15'd0;
  assign ddr_bank = 3'd0;
  assign ddr_cs = 1'b1;
  assign ddr_ras = 1'b1;
  assign ddr_cas = 1'b1;
  assign ddr_we = 1'b1;
  assign ddr_ck = 1'b0;
  assign ddr_ck_n = 1'b1;
  assign ddr_cke = 1'b0;
  assign ddr_odt = 1'b0;
  assign ddr_reset_n = 1'b0;
  assign ddr_dm = 4'b1111;
  assign ddr_dq = 32'bz;
  assign ddr_dqs = 4'bz;
  assign ddr_dqs_n = 4'bz;
  assign ddr_calib = resetn;

  assign dvi_a_psv=1'b0; assign dvi_ddc_clk=1'bz; assign dvi_ddc_dat=1'bz;
  assign sdram0_clk=clk_50mhz;
endmodule

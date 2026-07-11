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
  inout wire [15:0] sdram0_dq
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
  wire cpu_uart_tx,probe_tx,probe_active,probe_done;
  wire hdmi_pll_lock;

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
    .JTAG_TMS(1'b0),.JTAG_TDI(1'b0),.JTAG_TDO(jtag_tdo),.JTAG_TCK(1'b0)
  );

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
  assign uart_tx = probe_active ? probe_tx : cpu_uart_tx;

  // The vendor IP owns the IOBUFs on the FLASH_QSPI and SD pads; fabric
  // logic must not tap those nets (EX0339). CPU liveness is observable on
  // fabric nets instead: led[1] latches once UART1 transmitted a start bit
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
  assign led = {beat[24],saw_aw|saw_ar,saw_cpu_tx,resetn};

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

  sys16_hdmi_720p hdmi_i(
    .clk_in(clk_50mhz),.reset_n(resetn),.status_word(diag_status),
    .pll_lock(hdmi_pll_lock),.tmds_clk_p(tmds_clk_p),.tmds_clk_n(tmds_clk_n),
    .tmds_d_p(tmds_d_p),.tmds_d_n(tmds_d_n));
  assign dvi_a_psv=1'b0; assign dvi_ddc_clk=1'bz; assign dvi_ddc_dat=1'bz;
  assign sdram0_clk=clk_50mhz;
endmodule

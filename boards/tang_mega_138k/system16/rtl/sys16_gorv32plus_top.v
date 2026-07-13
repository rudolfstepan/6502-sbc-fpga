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
  // External PS/2 keyboard connector on spare 3.3-V GPIO header pins.
  input wire ps2_clk, input wire ps2_data,
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
  // On-board DDR3 (32-bit, on the core module): Linux main memory.
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
  wire cpu_resetn;
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
  wire ps2_sel,ps2_cs,ps2_irq; wire [7:0] ps2_dout;
  wire ps2_connected,ps2_key_event,ps2_polling; wire [7:0] ps2_keycode,ps2_modif,ps2_ascii;
  wire [3:0] ps2_phase;
  wire cpu_uart_tx,probe_tx,probe_active,probe_done;
  wire [7:0] boot_uart_data; wire boot_uart_valid;
  wire ddr_report_tx,ddr_report_active,ddr_report_done;
  wire ddr_progress_tx,ddr_progress_active;
  reg uart_tx_r=1'b1;
  wire hdmi_pll_lock;
  wire ddr_calib;
  wire ddr_pll_lock,ddr_pll_stop,ddr_memory_clk,ddr_clk_x1;
  wire [2:0] app_cmd; wire app_cmd_en,app_cmd_ready;
  wire [27:0] app_addr; wire [255:0] app_wdata,app_rdata;
  wire [31:0] app_wmask; wire app_wren,app_wend,app_wready,app_rvalid;
  wire ddr_test_active,ddr_test_done,ddr_test_fail;
  wire [29:0] ddr_test_fail_addr; wire [2:0] ddr_test_phase;
  wire [6:0] ddr_test_progress;
  reg [2:0] ddr_done_sync=0,ddr_fail_sync=0;
  always @(posedge clk_50mhz) begin
    ddr_done_sync<={ddr_done_sync[1:0],ddr_test_done};
    ddr_fail_sync<={ddr_fail_sync[1:0],ddr_test_fail};
  end
  // Hold reset after the memory PLL locks and retry calibration after 50 ms.
  localparam DDR_RST_HOLD=1023, DDR_CAL_WAIT=2500000;
  reg [1:0] ddr_lock_sync=0,ddr_cal_sync=0;
  reg ddr_rst_wait=0,ddr_rst_n=0; reg [21:0] ddr_rst_cnt=0;
  reg [4:0] ddr_retry_count=0; reg ddr_cal_failed=0;
  wire ddr_result_done=ddr_done_sync[2] || ddr_cal_failed;
  wire ddr_result_fail=ddr_fail_sync[2] || ddr_cal_failed;
  assign cpu_resetn=resetn && ddr_result_done && !ddr_result_fail && ddr_report_done;
  always @(posedge clk_50mhz) begin
    ddr_lock_sync<={ddr_lock_sync[0],ddr_pll_lock};
    ddr_cal_sync<={ddr_cal_sync[0],ddr_calib};
    if(!resetn || !ddr_lock_sync[1]) begin
      ddr_rst_wait<=0;ddr_rst_cnt<=0;ddr_rst_n<=0;
      ddr_retry_count<=0;ddr_cal_failed<=0;
    end else if(ddr_cal_failed) begin
      ddr_rst_n<=0;
    end
    else if(!ddr_rst_wait) begin
      ddr_rst_n<=0;
      if(ddr_rst_cnt==DDR_RST_HOLD) begin ddr_rst_cnt<=0;ddr_rst_n<=1;ddr_rst_wait<=1; end
      else ddr_rst_cnt<=ddr_rst_cnt+1'b1;
    end else begin
      ddr_rst_n<=1;
      if(ddr_cal_sync[1]) ddr_rst_cnt<=0;
      else if(ddr_rst_cnt==DDR_CAL_WAIT) begin
        ddr_rst_cnt<=0;ddr_rst_wait<=0;
        if(ddr_retry_count==15) ddr_cal_failed<=1;
        else ddr_retry_count<=ddr_retry_count+1'b1;
      end
      else ddr_rst_cnt<=ddr_rst_cnt+1'b1;
    end
  end

  Gowin_GoRV32_Plus_Top cpu(
    .axi_clk(clk_50mhz),.ahb_clk(clk_50mhz),.apb_clk(clk_50mhz),
    .axi_resetn(cpu_resetn),.ahb_resetn(cpu_resetn),.apb_resetn(cpu_resetn),
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

  sys16_bus32_to_ddr3 main_ddr(
    .bus_clk(clk_50mhz),.bus_resetn(resetn),.bus_req(sb_req),.bus_we(sb_we),
    .bus_addr(sb_addr),.bus_be(sb_be),.bus_wdata(sb_wdata),
    .bus_rdata(sb_rdata),.bus_ready(sb_ready),
    .app_clk(ddr_clk_x1),.app_calib(ddr_calib),.app_cmd(app_cmd),
    .app_cmd_en(app_cmd_en),.app_cmd_ready(app_cmd_ready),.app_addr(app_addr),
    .app_wdata(app_wdata),.app_wmask(app_wmask),.app_wren(app_wren),
    .app_wend(app_wend),.app_wready(app_wready),.app_rdata(app_rdata),
    .app_rvalid(app_rvalid),.test_active(ddr_test_active),
    .test_done(ddr_test_done),.test_fail(ddr_test_fail),
    .test_fail_addr(ddr_test_fail_addr),.test_phase(ddr_test_phase),
    .test_progress(ddr_test_progress));

  // Board-level sign of life independent of flash contents. The whole
  // console chain (probe, ZSBL, OpenSBI, Linux) runs 115200 8N1.
  sys16_uart_probe probe(
    .clk(clk_50mhz),.reset_n(resetn),.start(resetn),.tx(probe_tx),
    .active(probe_active),.done(probe_done));
  sys16_ddr_test_reporter ddr_report(
    .clk(clk_50mhz),.reset_n(resetn),
    .start(ddr_result_done && probe_done && !ddr_progress_active),
    .failed(ddr_result_fail),.calib_failed(ddr_cal_failed),
    .tx(ddr_report_tx),.active(ddr_report_active),.done(ddr_report_done));
  sys16_ddr_progress_reporter ddr_progress(
    .clk(clk_50mhz),.reset_n(resetn),.enable(ddr_test_active && probe_done),
    .progress(ddr_test_progress),.tx(ddr_progress_tx),.active(ddr_progress_active));
  // Keep the final mux off the package pin. With the DDR3 PHY present the
  // unconstrained combinational output route became placement-sensitive and
  // corrupted even the pre-CPU "FPGA BOOT OK" probe. A single 50 MHz output
  // register makes every UART edge synchronous and gives P&R an IOB-packable
  // endpoint. One clock of latency has no effect on 115200-baud framing.
  always @(posedge clk_50mhz) begin
    if (!resetn)
      uart_tx_r <= 1'b1;
    else
      uart_tx_r <= probe_active ? probe_tx :
                   ddr_progress_active ? ddr_progress_tx :
                   ddr_report_active ? ddr_report_tx : cpu_uart_tx;
  end
  assign uart_tx = uart_tx_r;

  // Decode the actual outgoing serial stream and mirror it to HDMI until the
  // Linux text-console driver takes ownership of the character RAM.
  uart_rx_ser #(.CLK_HZ(50000000),.BAUD(115200)) boot_uart_tap(
    .clk(clk_50mhz),.reset_n(resetn),.rx(uart_tx_r),
    .data(boot_uart_data),.valid(boot_uart_valid));

  // PS/2 Set-2 keyboard receiver. Linux sees its four registers at
  // 0xE8800100 through the existing AXI extension window.
  assign ps2_sel = (fb_addr[23:8] == 16'h8001);
  assign ps2_cs  = fb_req && ps2_sel;
  assign hdmi_req = fb_req && !ps2_sel;
  assign fb_ready = ps2_sel ? fb_req : hdmi_ready;
  assign fb_rdata = ps2_sel ? {24'h000000,ps2_dout} : hdmi_rdata;
  ps2_keyboard #(.CLK_HZ(50000000),.KBD_LAYOUT("DE")) ps2_keyboard_i(
    .clk(clk_50mhz),.reset_n(resetn),.ps2_clk(ps2_clk),.ps2_data(ps2_data),
    .cs(ps2_cs),.we(fb_we),.addr(fb_addr[3:2]),.dout(ps2_dout),.irq(ps2_irq),
    .diag_connected(ps2_connected),.diag_keycode(ps2_keycode),
    .diag_modif(ps2_modif),.diag_ascii(ps2_ascii),.diag_phase(ps2_phase),
    .diag_key_event(ps2_key_event),.diag_polling(ps2_polling));

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
  // LED3 heartbeat, LED2 test failure, LED1 test pass, LED0 calibration.
  assign led = {beat[24],ddr_result_fail,ddr_result_done&&!ddr_result_fail,ddr_calib};

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
    .boot_data(boot_uart_data),.boot_valid(boot_uart_valid),
    .status_word(diag_status),
    .pll_lock(hdmi_pll_lock),.tmds_clk_p(tmds_clk_p),.tmds_clk_n(tmds_clk_n),
    .tmds_d_p(tmds_d_p),.tmds_d_n(tmds_d_n));

  Gowin_DDR_PLL ddr_mem_pll_i(
    .lock(ddr_pll_lock),.clkout0(),.clkout1(),.clkout2(ddr_memory_clk),
    .clkin(clk_50mhz),.init_clk(clk_50mhz),.reset(1'b0),
    .enclk0(1'b1),.enclk1(1'b1),.enclk2(ddr_pll_stop));

  DDR3_Memory_Interface_Top ddr3_ip_i(
    .clk(clk_50mhz),.memory_clk(ddr_memory_clk),.pll_lock(ddr_pll_lock),.rst_n(ddr_rst_n),
    .cmd_ready(app_cmd_ready),.cmd(app_cmd),.cmd_en(app_cmd_en),.addr({1'b0,app_addr}),
    .wr_data_rdy(app_wready),.wr_data(app_wdata),.wr_data_en(app_wren),
    .wr_data_end(app_wend),.wr_data_mask(app_wmask),.rd_data(app_rdata),
    .rd_data_valid(app_rvalid),.rd_data_end(),.sr_req(1'b0),.ref_req(1'b0),
    .sr_ack(),.ref_ack(),.init_calib_complete(ddr_calib),.clk_out(ddr_clk_x1),
    .ddr_rst(),.pll_stop(ddr_pll_stop),.burst(1'b1),
    .O_ddr_addr(ddr_addr),.O_ddr_ba(ddr_bank),.O_ddr_cs_n(ddr_cs),
    .O_ddr_ras_n(ddr_ras),.O_ddr_cas_n(ddr_cas),.O_ddr_we_n(ddr_we),
    .O_ddr_clk(ddr_ck),.O_ddr_clk_n(ddr_ck_n),.O_ddr_cke(ddr_cke),
    .O_ddr_odt(ddr_odt),.O_ddr_reset_n(ddr_reset_n),.O_ddr_dqm(ddr_dm),
    .IO_ddr_dq(ddr_dq),.IO_ddr_dqs(ddr_dqs),.IO_ddr_dqs_n(ddr_dqs_n));

  // The external SDRAM0 module is no longer needed by Linux.
  assign sdram0_cs_n=1'b1; assign sdram0_ras_n=1'b1; assign sdram0_cas_n=1'b1;
  assign sdram0_we_n=1'b1; assign sdram0_ba=0; assign sdram0_addr=0;
  assign sdram0_dqm=2'b11; assign sdram0_dq=16'bz;

  assign dvi_a_psv=1'b0; assign dvi_ddc_clk=1'bz; assign dvi_ddc_dat=1'bz;
  assign sdram0_clk=1'b0;
endmodule

module tang138k_ae350_top (
    input  wire        clk_50mhz,
    input  wire        reset_n,

    output wire        uart_tx,
    input  wire        uart_rx,

    inout  wire        flash_cs_n,
    inout  wire        flash_miso,
    inout  wire        flash_mosi,
    inout  wire        flash_clk,
    inout  wire        flash_hold_n,
    inout  wire        flash_wp_n,

    output wire [2:0]  ddr3_bank,
    output wire        ddr3_cs_n,
    output wire        ddr3_ras_n,
    output wire        ddr3_cas_n,
    output wire        ddr3_we_n,
    output wire        ddr3_ck,
    output wire        ddr3_ck_n,
    output wire        ddr3_cke,
    output wire        ddr3_reset_n,
    output wire        ddr3_odt,
    output wire [13:0] ddr3_addr,
    output wire [1:0]  ddr3_dm,
    inout  wire [15:0] ddr3_dq,
    inout  wire [1:0]  ddr3_dqs,
    inout  wire [1:0]  ddr3_dqs_n,

    input  wire        jtag_tck,
    input  wire        jtag_tms,
    input  wire        jtag_tdi,
    inout  wire        jtag_tdo
);
    wire core_clk;
    wire ddr_bus_clk;
    wire ahb_clk;
    wire apb_clk;
    wire rtc_clk;

    wire ddr3_memory_clk;
    wire ddr3_clk_in;
    wire ddr3_pll_lock;
    wire ddr3_stop;
    wire ddr3_init_completed;

    wire ddr3_reset_sync_n;
    wire ae350_reset_n;

    wire jtag_tdo_data;
    wire jtag_tdo_oe;
    wire [31:0] gpio_unused;

    Gowin_PLL_AE350 u_Gowin_PLL_AE350 (
        .clkout0(ddr_bus_clk),
        .clkout1(core_clk),
        .clkout2(ahb_clk),
        .clkout3(apb_clk),
        .clkout4(rtc_clk),
        .clkin(clk_50mhz),
        .init_clk(clk_50mhz),
        .enclk0(1'b1),
        .enclk1(1'b1),
        .enclk2(1'b1),
        .enclk3(1'b1),
        .enclk4(1'b1)
    );

    Gowin_PLL_DDR3 u_Gowin_PLL_DDR3 (
        .lock(ddr3_pll_lock),
        .clkout0(ddr3_clk_in),
        .clkout2(ddr3_memory_clk),
        .clkin(clk_50mhz),
        .init_clk(clk_50mhz),
        .reset(1'b0),
        .enclk0(1'b1),
        .enclk2(ddr3_stop)
    );

    key_debounce u_key_debounce_ddr3 (
        .out(ddr3_reset_sync_n),
        .in(reset_n),
        .clk(clk_50mhz),
        .rstn(1'b1)
    );

    // Keep the CPU reset asserted until DDR3 training has remained valid for
    // 20 ms. This follows Gowin's AE350 reference reset sequence.
    key_debounce u_key_debounce_ae350 (
        .out(ae350_reset_n),
        .in(ddr3_init_completed),
        .clk(clk_50mhz),
        .rstn(reset_n)
    );

    assign jtag_tdo = jtag_tdo_oe ? jtag_tdo_data : 1'bz;

    RiscV_AE350_SOC_Top u_RiscV_AE350_SOC_Top (
        .FLASH_SPI_CSN(flash_cs_n),
        .FLASH_SPI_MISO(flash_miso),
        .FLASH_SPI_MOSI(flash_mosi),
        .FLASH_SPI_CLK(flash_clk),
        .FLASH_SPI_HOLDN(flash_hold_n),
        .FLASH_SPI_WPN(flash_wp_n),

        .DDR3_MEMORY_CLK(ddr3_memory_clk),
        .DDR3_CLK_IN(ddr3_clk_in),
        .DDR3_RSTN(ddr3_reset_sync_n),
        .DDR3_LOCK(ddr3_pll_lock),
        .DDR3_STOP(ddr3_stop),
        .DDR3_INIT(ddr3_init_completed),
        .DDR3_BANK(ddr3_bank),
        .DDR3_CS_N(ddr3_cs_n),
        .DDR3_RAS_N(ddr3_ras_n),
        .DDR3_CAS_N(ddr3_cas_n),
        .DDR3_WE_N(ddr3_we_n),
        .DDR3_CK(ddr3_ck),
        .DDR3_CK_N(ddr3_ck_n),
        .DDR3_CKE(ddr3_cke),
        .DDR3_RESET_N(ddr3_reset_n),
        .DDR3_ODT(ddr3_odt),
        .DDR3_ADDR(ddr3_addr),
        .DDR3_DM(ddr3_dm),
        .DDR3_DQ(ddr3_dq),
        .DDR3_DQS(ddr3_dqs),
        .DDR3_DQS_N(ddr3_dqs_n),

        .TCK_IN(jtag_tck),
        .TMS_IN(jtag_tms),
        .TRST_IN(1'b1),
        .TDI_IN(jtag_tdi),
        .TDO_OUT(jtag_tdo_data),
        .TDO_OE(jtag_tdo_oe),

        .UART2_TXD(uart_tx),
        .UART2_RTSN(),
        .UART2_RXD(uart_rx),
        .UART2_CTSN(1'b0),
        .UART2_DCDN(1'b1),
        .UART2_DSRN(1'b1),
        .UART2_RIN(1'b1),
        .UART2_DTRN(),
        .UART2_OUT1N(),
        .UART2_OUT2N(),

        .GPIO(gpio_unused),
        .CORE_CLK(core_clk),
        .DDR_CLK(ddr_bus_clk),
        .AHB_CLK(ahb_clk),
        .APB_CLK(apb_clk),
        .RTC_CLK(rtc_clk),
        .POR_RSTN(ae350_reset_n),
        .HW_RSTN(ae350_reset_n)
    );

endmodule

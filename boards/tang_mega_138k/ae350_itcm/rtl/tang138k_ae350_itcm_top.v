module tang138k_ae350_itcm_top (
    input  wire clk_50mhz,
    input  wire reset_n,

    output wire uart_tx,
    input  wire uart_rx,

    input  wire jtag_tck,
    input  wire jtag_tms,
    input  wire jtag_tdi,
    inout  wire jtag_tdo
);
    wire core_clk;
    wire ddr_bus_clk;
    wire ahb_clk;
    wire apb_clk;
    wire rtc_clk;
    wire pll_lock;
    wire ae350_reset_n;
    wire ae350_uart_tx;
    wire diag_uart_tx;
    wire diag_done;
    wire pll_reset_n;

    reg pll_release_meta;
    reg pll_ready_50mhz;

    wire jtag_tdo_data;
    wire jtag_tdo_oe;
    wire [31:0] gpio_unused;

    Gowin_PLL_AE350_ITCM u_Gowin_PLL_AE350_ITCM (
        .clkout0(ddr_bus_clk),
        .clkout1(core_clk),
        .clkout2(ahb_clk),
        .clkout3(apb_clk),
        .clkout4(rtc_clk),
        .lock(pll_lock),
        .clkin(clk_50mhz),
        .init_clk(clk_50mhz),
        .enclk0(1'b1),
        .enclk1(1'b1),
        .enclk2(1'b1),
        .enclk3(1'b1),
        .enclk4(1'b1)
    );

    ae350_boot_diag u_ae350_boot_diag (
        .clk(clk_50mhz),
        .reset_n(reset_n),
        .pll_lock(pll_lock),
        .tx(diag_uart_tx),
        .done(diag_done)
    );

    // Assert immediately if reset or PLL lock is lost, but release the
    // 50 MHz reset supervisor only on clock edges. The following debounce
    // then keeps the AE350 reset active for another 20 ms.
    assign pll_reset_n = reset_n & pll_lock;

    always @(posedge clk_50mhz or negedge pll_reset_n) begin
        if (!pll_reset_n) begin
            pll_release_meta <= 1'b0;
            pll_ready_50mhz  <= 1'b0;
        end else begin
            pll_release_meta <= 1'b1;
            pll_ready_50mhz  <= pll_release_meta;
        end
    end

    // Do not expose the unknown reset value of the protected AE350 UART.
    // Keep TX at idle between the diagnostic stop bit and CPU release.
    assign uart_tx = !diag_done       ? diag_uart_tx :
                     !ae350_reset_n   ? 1'b1         : ae350_uart_tx;

    key_debounce u_key_debounce_ae350 (
        .out(ae350_reset_n),
        .in(diag_done),
        .clk(clk_50mhz),
        .rstn(pll_ready_50mhz)
    );

    assign jtag_tdo = jtag_tdo_oe ? jtag_tdo_data : 1'bz;

    RiscV_AE350_SOC_Top u_RiscV_AE350_SOC_Top (
        .TCK_IN(jtag_tck),
        .TMS_IN(jtag_tms),
        .TRST_IN(1'b1),
        .TDI_IN(jtag_tdi),
        .TDO_OUT(jtag_tdo_data),
        .TDO_OE(jtag_tdo_oe),

        .UART2_TXD(ae350_uart_tx),
        .UART2_RTSN(),
        .UART2_RXD(uart_rx),
        .UART2_CTSN(1'b0),
        .UART2_DCDN(1'b0),
        .UART2_DSRN(1'b0),
        .UART2_RIN(1'b0),
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

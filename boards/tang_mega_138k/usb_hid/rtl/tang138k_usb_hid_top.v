// Bring-up harness for Gowin's encrypted USB 2.0 host core and ULPI SoftPHY.
// Uses the Tang Console's dedicated USB-C SoftPHY circuit, not the USB-A GPIO
// pins used by the old low-speed third-party HID implementation.
module tang138k_usb_hid_top (
    input  wire clk,
    inout  wire usb_dxp_io,
    inout  wire usb_dxn_io,
    input  wire usb_rxdp_p,
    input  wire usb_rxdp_n,
    input  wire usb_rxdn_p,
    input  wire usb_rxdn_n,
    output wire uart_tx
);
  reg [23:0] reset_count = 0;
  wire reset_n = reset_count[23];
  always @(posedge clk) if (!reset_n) reset_count <= reset_count + 1'b1;

  wire clk60, clk480, pll_lock;
  usb20_phy_pll phy_pll_i(.lock(pll_lock), .clk60(clk60), .clk480(clk480), .clkin(clk));

  wire [7:0] host_data_out;
  wire host_data_oe, host_dreq, host_irq, phy_reset, ulpi_stp;
  wire [7:0] ulpi_link_to_phy, ulpi_phy_to_link;
  wire ulpi_dir, ulpi_nxt;
  wire phy_pullup;
  wire phy_reset_active = ~reset_n | ~pll_lock | phy_reset;
  wire usb_rxdp, usb_rxdn;
  TLVDS_IBUF usb_rxdp_ibuf(.O(usb_rxdp), .I(usb_rxdp_p), .IB(usb_rxdp_n));
  TLVDS_IBUF usb_rxdn_ibuf(.O(usb_rxdn), .I(usb_rxdn_p), .IB(usb_rxdn_n));

  USB20_Host_Controller_Top usb20_i (
      .clk_i(clk60),
      .rst_n_i(reset_n & pll_lock),
      .cs_n_i(1'b1),
      .rd_n_i(1'b1),
      .wr_n_i(1'b1),
      .addr_i(8'h00),
      .dat_i(8'h00),
      .dat_o(host_data_out),
      .dat_o_en(host_data_oe),
      .dreq_o(host_dreq),
      .dack_i(1'b1),
      .hardware_interrupt_o(host_irq),
      .phy_rst_o(phy_reset),
      .ulpi_dir_i(ulpi_dir),
      .ulpi_nxt_i(ulpi_nxt),
      .ulpi_data_out_i(ulpi_phy_to_link),
      .ulpi_data_in_o(ulpi_link_to_phy),
      .ulpi_stp_o(ulpi_stp)
  );

  USB2_0_SoftPHY_Top softphy_i (
      .clk_i(clk60), .rst_i(phy_reset_active), .fclk_i(clk480),
      .pll_locked_i(pll_lock),
      .ulpi_txdata_i(ulpi_link_to_phy), .ulpi_rxdata_o(ulpi_phy_to_link),
      .ulpi_dir_o(ulpi_dir), .ulpi_stp_i(ulpi_stp), .ulpi_nxt_o(ulpi_nxt),
      .usb_dxp_io(usb_dxp_io), .usb_dxn_io(usb_dxn_io),
      .usb_rxdp_i(usb_rxdp), .usb_rxdn_i(usb_rxdn),
      .usb_pullup_en_o(phy_pullup),
      .usb_term_dp_io(), .usb_term_dn_io()
  );

  wire uart_busy;
  reg uart_start = 0;
  reg [7:0] uart_data = 0;
  uart_tx_115200 uart_i (
      .clk(clk), .reset_n(reset_n), .data(uart_data), .start(uart_start),
      .tx(uart_tx), .busy(uart_busy));

  // "Gowin USB20 core active irq=X dma=X rst=X\r\n"
  function [7:0] message_char(input [5:0] index);
    case (index)
      0:message_char="G"; 1:message_char="o"; 2:message_char="w";
      3:message_char="i"; 4:message_char="n"; 5:message_char=" ";
      6:message_char="U"; 7:message_char="S"; 8:message_char="B";
      9:message_char="2"; 10:message_char="0"; 11:message_char=" ";
      12:message_char="c"; 13:message_char="o"; 14:message_char="r";
      15:message_char="e"; 16:message_char=" "; 17:message_char="a";
      18:message_char="c"; 19:message_char="t"; 20:message_char="i";
      21:message_char="v"; 22:message_char="e"; 23:message_char=" ";
      24:message_char="i"; 25:message_char="r"; 26:message_char="q";
      27:message_char="="; 28:message_char=8'h30+host_irq; 29:message_char=" ";
      30:message_char="d"; 31:message_char="m"; 32:message_char="a";
      33:message_char="="; 34:message_char=8'h30+host_dreq; 35:message_char=" ";
      36:message_char="r"; 37:message_char="s"; 38:message_char="t";
      39:message_char="="; 40:message_char=8'h30+phy_reset;
      41:message_char=8'h0d; default:message_char=8'h0a;
    endcase
  endfunction

  reg sending = 0, wait_busy = 0, message_done = 0;
  reg [5:0] char_index = 0;
  always @(posedge clk) begin
    uart_start <= 1'b0;
    if (!reset_n) begin
      sending <= 1'b0; wait_busy <= 1'b0;
      message_done <= 1'b0; char_index <= 0;
    end else if (!message_done) begin
      if (!sending) sending <= 1'b1;
      else if (wait_busy) begin
        if (uart_busy) wait_busy <= 1'b0;
      end else if (!uart_busy) begin
        uart_data <= message_char(char_index);
        uart_start <= 1'b1;
        wait_busy <= 1'b1;
        if (char_index == 42) begin
          sending <= 1'b0;
          message_done <= 1'b1;
        end else char_index <= char_index + 1'b1;
      end
    end
  end
endmodule

module uart_tx_115200 (
    input wire clk, input wire reset_n, input wire [7:0] data, input wire start,
    output wire tx, output wire busy
);
  localparam integer BAUD_DIV = 434;
  reg [9:0] shift = 10'h3ff;
  reg [8:0] baud_count = 0;
  reg [3:0] bit_count = 0;
  reg active = 0;
  assign tx = active ? shift[0] : 1'b1;
  assign busy = active;
  always @(posedge clk) begin
    if (!reset_n) begin
      shift <= 10'h3ff; baud_count <= 0; bit_count <= 0; active <= 0;
    end else if (!active) begin
      if (start) begin
        shift <= {1'b1, data, 1'b0};
        baud_count <= 0; bit_count <= 0; active <= 1'b1;
      end
    end else if (baud_count == BAUD_DIV-1) begin
      baud_count <= 0;
      shift <= {1'b1, shift[9:1]};
      if (bit_count == 9) active <= 1'b0;
      else bit_count <= bit_count + 1'b1;
    end else baud_count <= baud_count + 1'b1;
  end
endmodule

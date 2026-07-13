`timescale 1ns/1ps

module tb_usb_cdc_acm_control;
  reg clk = 0;
  always #8 clk = ~clk;

  reg reset = 1;
  reg setup = 0;
  reg [3:0] endpoint = 0;
  reg rx_active = 0;
  reg rx_valid = 0;
  reg [7:0] rx_data = 0;
  reg tx_active = 0;
  reg tx_pop = 0;
  wire [7:0] tx_data;
  wire tx_valid;
  wire [11:0] tx_length;
  wire [31:0] line_baud;
  wire [7:0] line_stop_bits;
  wire [7:0] line_parity;
  wire [7:0] line_data_bits;
  wire [15:0] control_lines;
  integer errors = 0;

  usb_cdc_acm_control dut(
      .clk(clk),.reset(reset),.setup(setup),.endpoint(endpoint),
      .rx_active(rx_active),.rx_valid(rx_valid),.rx_data(rx_data),
      .tx_active(tx_active),.tx_pop(tx_pop),.tx_data(tx_data),
      .tx_valid(tx_valid),.tx_length(tx_length),.line_baud(line_baud),
      .line_stop_bits(line_stop_bits),.line_parity(line_parity),
      .line_data_bits(line_data_bits),.control_lines(control_lines));

  task send_rx_byte;
    input [7:0] value;
    begin
      @(negedge clk);
      rx_data = value;
      rx_valid = 1;
      @(posedge clk);
      @(negedge clk);
      rx_valid = 0;
    end
  endtask

  task fail;
    input [8*100-1:0] message;
    begin
      $display("FAIL: %0s",message);
      errors = errors + 1;
    end
  endtask

  initial begin
    repeat (4) @(posedge clk);
    reset = 0;
    repeat (2) @(posedge clk);

    if (line_baud !== 32'd115200 || line_stop_bits !== 0 ||
        line_parity !== 0 || line_data_bits !== 8)
      fail("initial line coding");

    // bmRequestType=0x21, SET_LINE_CODING=0x20, wValue=0,
    // wIndex=0, wLength=7.
    setup = 1;
    send_rx_byte(8'h21);
    send_rx_byte(8'h20);
    send_rx_byte(8'h00);
    send_rx_byte(8'h00);
    send_rx_byte(8'h00);
    send_rx_byte(8'h00);
    send_rx_byte(8'h07);
    send_rx_byte(8'h00);
    setup = 0;

    rx_active = 1;
    endpoint = 0;
    send_rx_byte(8'h00); // 230400 = 0x00038400, little endian
    send_rx_byte(8'h84);
    send_rx_byte(8'h03);
    send_rx_byte(8'h00);
    send_rx_byte(8'h02);
    send_rx_byte(8'h01);

    // No transaction-intermediate line coding may escape before byte 7.
    if (line_baud !== 32'd115200 || line_stop_bits !== 0 ||
        line_parity !== 0 || line_data_bits !== 8)
      fail("line coding changed before final byte");

    send_rx_byte(8'h07);
    rx_active = 0;
    repeat (2) @(posedge clk);
    if (line_baud !== 32'd230400 || line_stop_bits !== 8'h02 ||
        line_parity !== 8'h01 || line_data_bits !== 8'h07)
      fail("line coding was not committed atomically");

    if (errors == 0)
      $display("PASS: CDC ACM line coding commits atomically");
    else
      $display("FAIL: %0d error(s)",errors);
    $finish;
  end
endmodule

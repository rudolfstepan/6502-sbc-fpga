`timescale 1ns/1ps

module tb_sys16_usb_cdc_mmio;
  reg cpu_clk = 0;
  reg usb_clk = 0;
  always #10 cpu_clk = ~cpu_clk; // 50 MHz
  always #8  usb_clk = ~usb_clk; // unrelated 62.5 MHz test clock

  reg reset_n = 0;
  reg usb_datapath_reset = 0;
  reg bus_req = 0;
  reg bus_we = 0;
  reg [7:0] bus_addr = 0;
  reg [3:0] bus_be = 0;
  reg [31:0] bus_wdata = 0;
  wire [31:0] bus_rdata;
  wire bus_ready;
  wire irq;

  reg usb_online = 0;
  reg usb_suspend = 0;
  reg usb_bus_reset = 0;
  reg pad_diag = 0;
  reg [31:0] usb_line_baud = 115200;
  reg [7:0] usb_line_stop_bits = 0;
  reg [7:0] usb_line_parity = 0;
  reg [7:0] usb_line_data_bits = 8;
  reg [15:0] usb_control_lines = 0;

  reg [3:0] endpoint = 0;
  reg rx_active = 0;
  reg rx_valid = 0;
  reg rx_packet_valid = 0;
  reg [7:0] rx_data = 0;
  wire ep2_rx_ready;
  reg tx_active = 0;
  reg tx_pop = 0;
  reg tx_packet_finished = 0;
  wire ep2_tx_cork;
  wire [7:0] ep2_tx_data;
  wire [11:0] ep2_tx_length;

  integer errors = 0;
  integer i;
  reg [31:0] value;
  reg [7:0] tx_expect [0:127];
  reg [9:0] previous_tx_rd_gray = 0;

  function gray_onehot0;
    input [9:0] delta;
    begin
      gray_onehot0 = (delta == 0) ||
                     ((delta & (delta - 1'b1)) == 0);
    end
  endfunction

  sys16_usb_cdc_mmio #(.FIFO_ADDR_WIDTH(9)) dut (
      .cpu_clk(cpu_clk), .cpu_reset_n(reset_n),
      .usb_clk(usb_clk), .usb_datapath_reset(usb_datapath_reset),
      .bus_req(bus_req), .bus_we(bus_we), .bus_addr(bus_addr),
      .bus_be(bus_be), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
      .bus_ready(bus_ready), .irq(irq),
      .usb_online(usb_online), .usb_suspend(usb_suspend),
      .usb_bus_reset(usb_bus_reset), .pad_diag(pad_diag),
      .usb_line_baud(usb_line_baud),
      .usb_line_stop_bits(usb_line_stop_bits),
      .usb_line_parity(usb_line_parity),
      .usb_line_data_bits(usb_line_data_bits),
      .usb_control_lines(usb_control_lines),
      .endpoint(endpoint), .rx_active(rx_active), .rx_valid(rx_valid),
      .rx_packet_valid(rx_packet_valid), .rx_data(rx_data),
      .ep2_rx_ready(ep2_rx_ready), .tx_active(tx_active),
      .tx_pop(tx_pop), .tx_packet_finished(tx_packet_finished),
      .ep2_tx_cork(ep2_tx_cork), .ep2_tx_data(ep2_tx_data),
      .ep2_tx_length(ep2_tx_length));

  task fail;
    input [8*120-1:0] message;
    begin
      $display("FAIL: %0s", message);
      errors = errors + 1;
    end
  endtask

  task bus_read;
    input [7:0] address;
    output [31:0] data;
    begin
      @(negedge cpu_clk);
      bus_addr = address;
      bus_we = 0;
      bus_be = 4'hf;
      bus_req = 1;
      #1;
      if (!bus_ready)
        fail("bus_ready was not immediate on read");
      // The real AXI adapter samples bus_rdata on the accepting edge, before
      // RX_DATA's nonblocking pointer update.  Sample the same pre-edge word.
      data = bus_rdata;
      @(posedge cpu_clk);
      @(negedge cpu_clk);
      bus_req = 0;
      bus_be = 0;
      @(posedge cpu_clk);
    end
  endtask

  task bus_write;
    input [7:0] address;
    input [31:0] data;
    input [3:0] be;
    begin
      @(negedge cpu_clk);
      bus_addr = address;
      bus_wdata = data;
      bus_we = 1;
      bus_be = be;
      bus_req = 1;
      #1;
      if (!bus_ready)
        fail("bus_ready was not immediate on write");
      @(posedge cpu_clk);
      @(negedge cpu_clk);
      bus_req = 0;
      bus_we = 0;
      bus_be = 0;
      @(posedge cpu_clk);
    end
  endtask

  task send_out_byte;
    input [7:0] data;
    input good_last;
    begin
      @(negedge usb_clk);
      if (!ep2_rx_ready)
        fail("EP2 unexpectedly backpressured a reserved packet");
      rx_data = data;
      rx_valid = 1;
      rx_packet_valid = good_last;
      @(posedge usb_clk);
    end
  endtask

  // Model the Gowin controller: it starts an OUT transaction only after the
  // endpoint advertised rxrdy while rxact was still low.
  task start_out;
    integer timeout;
    begin
      @(negedge usb_clk);
      endpoint = 2;
      rx_active = 0;
      rx_valid = 0;
      rx_packet_valid = 0;
      timeout = 0;
      while (!ep2_rx_ready && timeout < 80) begin
        @(posedge usb_clk);
        @(negedge usb_clk);
        timeout = timeout + 1;
      end
      if (timeout == 80)
        fail("EP2 idle-ready deadlock before OUT transaction");
      if (!ep2_rx_ready)
        fail("controller attempted OUT without idle rx_ready");
      rx_active = 1;
      @(posedge usb_clk);
    end
  endtask

  task finish_out;
    begin
      @(negedge usb_clk);
      rx_valid = 0;
      rx_packet_valid = 0;
      rx_active = 0;
      @(posedge usb_clk);
      @(negedge usb_clk);
      endpoint = 0;
    end
  endtask

  task wait_rx_level;
    input integer wanted;
    integer timeout;
    begin
      timeout = 0;
      while ((dut.cpu_rx_level != wanted) && timeout < 300) begin
        @(posedge cpu_clk);
        timeout = timeout + 1;
      end
      if (timeout == 300)
        fail("RX FIFO level timeout");
    end
  endtask

  task wait_tx_packet;
    input integer wanted;
    integer timeout;
    begin
      timeout = 0;
      while ((ep2_tx_cork || ep2_tx_length != wanted) && timeout < 500) begin
        @(posedge usb_clk);
        timeout = timeout + 1;
      end
      if (timeout == 500)
        fail("TX packet preparation timeout");
    end
  endtask

  task wait_tx_level;
    input integer wanted;
    integer timeout;
    begin
      timeout = 0;
      while ((dut.cpu_tx_level != wanted) && timeout < 1200) begin
        @(posedge cpu_clk);
        timeout = timeout + 1;
      end
      if (timeout == 1200)
        fail("TX FIFO level/flush timeout");
    end
  endtask

  task pop_tx_byte;
    input [7:0] expected;
    input finish;
    begin
      @(negedge usb_clk);
      if (ep2_tx_data !== expected) begin
        $display("TX expected %02x, got %02x", expected, ep2_tx_data);
        fail("retry-safe TX byte mismatch");
      end
      tx_pop = 1;
      tx_packet_finished = finish;
      @(posedge usb_clk);
      @(negedge usb_clk);
      tx_pop = 0;
      tx_packet_finished = 0;
    end
  endtask

  // Every read-pointer transition crossing back to the writer must remain a
  // legal Gray-code hold or one-bit step, including a full 512-byte flush.
  always @(posedge usb_clk) begin
    #1;
    if (!reset_n || !dut.ep2_i.tx_fifo_i.rd_reset_n) begin
      previous_tx_rd_gray = dut.ep2_i.tx_fifo_i.rd_gray;
    end else begin
      if (!gray_onehot0(dut.ep2_i.tx_fifo_i.rd_gray ^
                        previous_tx_rd_gray))
        fail("TX FIFO read Gray pointer changed by multiple bits");
      previous_tx_rd_gray = dut.ep2_i.tx_fifo_i.rd_gray;
    end
  end

  initial begin
    $display("System16 USB CDC MMIO self-test");
    repeat (6) @(posedge cpu_clk);
    reset_n = 1;
    repeat (8) @(posedge cpu_clk);

    bus_read(8'h00, value);
    if (value !== 32'h53313655) fail("ID register");
    bus_read(8'h04, value);
    if (value !== 32'h01000909) fail("CAPS register");

    // Release global reset while an OUT transaction is already active.  The
    // complete in-flight transaction must remain NAKed; readiness may arm only
    // after a low rxact phase has been observed.
    @(negedge usb_clk);
    endpoint = 2;
    rx_active = 1;
    rx_valid = 1;
    rx_data = 8'he1;
    repeat (2) @(posedge usb_clk);
    @(negedge usb_clk);
    reset_n = 0;
    repeat (3) @(posedge usb_clk);
    @(negedge usb_clk);
    reset_n = 1;
    for (i = 0; i < 10; i = i + 1) begin
      @(negedge usb_clk);
      rx_data = rx_data + 1'b1;
      if (ep2_rx_ready)
        fail("EP2 ready rose in the middle of reset-spanning rxact");
      @(posedge usb_clk);
    end
    @(negedge usb_clk);
    rx_active = 0;
    rx_valid = 0;
    repeat (6) @(posedge usb_clk);
    if (!ep2_rx_ready)
      fail("EP2 did not advertise idle-ready after reset and rxact-low");
    if (dut.cpu_rx_level != 0)
      fail("reset-spanning OUT transaction leaked into RX FIFO");

    // The first complete packet after the observed idle phase is accepted.
    start_out();
    send_out_byte(8'h5c, 1);
    finish_out();
    wait_rx_level(1);
    bus_read(8'h0c, value);
    if (value[7:0] !== 8'h5c)
      fail("first complete OUT packet after reset was not accepted");
    wait_rx_level(0);

    // Coherent line-coding snapshot and synchronized status inputs.
    @(negedge usb_clk);
    usb_online = 1;
    pad_diag = 1;
    usb_control_lines = 16'h0003;
    usb_line_baud = 32'd115200;
    usb_line_stop_bits = 2;
    usb_line_parity = 1;
    usb_line_data_bits = 7;
    repeat (12) @(posedge cpu_clk);
    // Two source changes before a destination round trip used to cancel an
    // unacknowledged toggle.  The mailbox must deliver the latest value.
    @(negedge usb_clk);
    usb_line_baud = 32'd111111;
    @(posedge usb_clk);
    @(negedge usb_clk);
    usb_line_baud = 32'd230400;
    repeat (24) @(posedge cpu_clk);
    bus_read(8'h08, value);
    if ((value & 32'h0000040d) !== 32'h0000040d)
      fail("online/DTR/RTS/pad status synchronization");
    bus_read(8'h28, value);
    if (value !== 32'd230400) fail("LINE_BAUD snapshot");
    bus_read(8'h2c, value);
    if (value !== 32'h00020107) fail("LINE_FORMAT snapshot");
    bus_read(8'h30, value);
    if (value !== 32'h00000003) fail("MODEM snapshot");

    // Enable RX IRQ, then deliver a CRC-valid three-byte OUT packet.
    bus_write(8'h20, 32'h00000001, 4'h1);
    start_out();
    send_out_byte(8'h41, 0);
    send_out_byte(8'h42, 0);
    send_out_byte(8'h43, 1);
    finish_out();
    wait_rx_level(3);
    repeat (3) @(posedge cpu_clk);
    if (!irq) fail("RX available IRQ");
    bus_read(8'h14, value);
    if (value[15:0] !== 16'd3) fail("RX_LEVEL after valid packet");
    bus_read(8'h0c, value);
    if (value[7:0] !== 8'h41) fail("RX_DATA byte 0");
    bus_read(8'h0c, value);
    if (value[7:0] !== 8'h42) fail("RX_DATA byte 1");
    bus_read(8'h0c, value);
    if (value[7:0] !== 8'h43) fail("RX_DATA byte 2");
    wait_rx_level(0);
    bus_write(8'h1c, 32'h00000001, 4'h1);
    if (irq) fail("RX IRQ W1C");

    // Some Gowin controller revisions assert rxpktval only after rxact fell.
    // A two-cycle delayed validation pulse must still commit the packet.
    start_out();
    send_out_byte(8'h77, 0);
    finish_out();
    repeat (2) @(posedge usb_clk);
    @(negedge usb_clk);
    rx_packet_valid = 1;
    @(posedge usb_clk);
    @(negedge usb_clk);
    rx_packet_valid = 0;
    wait_rx_level(1);
    bus_read(8'h0c, value);
    if (value[7:0] !== 8'h77) fail("delayed rxpktval packet commit");
    wait_rx_level(0);

    // A packet without rx_packet_valid must disappear completely.
    start_out();
    send_out_byte(8'hde, 0);
    send_out_byte(8'had, 0);
    finish_out();
    repeat (20) @(posedge cpu_clk);
    if (dut.cpu_rx_level != 0) fail("CRC-failed OUT packet leaked to CPU");

    // Holding req for several clocks may perform only one TX_DATA write.
    usb_datapath_reset = 1;
    @(negedge cpu_clk);
    bus_addr = 8'h10;
    bus_wdata = 32'h0000005a;
    bus_be = 4'h1;
    bus_we = 1;
    bus_req = 1;
    repeat (4) @(posedge cpu_clk);
    @(negedge cpu_clk);
    bus_req = 0;
    bus_we = 0;
    bus_be = 0;
    repeat (4) @(posedge cpu_clk);
    if (dut.cpu_tx_level != 1) fail("held req duplicated TX_DATA side effect");
    bus_write(8'h24, 32'h00000002, 4'h1); // flush TX
    repeat (12) @(posedge usb_clk);
    // Flush cannot run while the USB packet domain is held in reset.
    if (dut.cpu_tx_level != 1) fail("FLUSH_TX was not deferred during reset");
    usb_datapath_reset = 0;
    wait_tx_level(0);

    // Build a 20-byte IN packet, abort after five bytes, then verify that the
    // retry begins again at byte zero and only successful txpktfin commits it.
    for (i = 0; i < 20; i = i + 1) begin
      tx_expect[i] = i + 8'h20;
      bus_write(8'h10, i + 8'h20, 4'h1);
    end
    wait_tx_packet(20);
    @(negedge usb_clk);
    endpoint = 2;
    tx_active = 1;
    for (i = 0; i < 5; i = i + 1)
      pop_tx_byte(tx_expect[i], 0);
    // A byte written during the first attempt belongs to the following USB
    // packet and must not extend or mutate the locked retry snapshot.
    bus_write(8'h10, 32'h00000099, 4'h1);
    if ((ep2_tx_length != 20) || ep2_tx_cork)
      fail("CPU TX write changed active snapshot length/cork");
    if (ep2_tx_data !== tx_expect[5])
      fail("CPU TX write changed active snapshot payload");
    @(negedge usb_clk);
    tx_active = 0;
    repeat (4) @(posedge usb_clk);
    if ((ep2_tx_length != 20) || ep2_tx_cork)
      fail("aborted transaction did not retain locked length");

    @(negedge usb_clk);
    tx_active = 1;
    for (i = 0; i < 20; i = i + 1)
      pop_tx_byte(tx_expect[i], i == 19);
    @(negedge usb_clk);
    tx_active = 0;
    wait_tx_packet(1);
    if (ep2_tx_data !== 8'h99)
      fail("byte queued during retry did not remain for following packet");
    @(negedge usb_clk);
    tx_active = 1;
    pop_tx_byte(8'h99, 1);
    @(negedge usb_clk);
    tx_active = 0;
    repeat (6) @(posedge usb_clk);
    if (!ep2_tx_cork) fail("following IN packet was not committed");

    // Request FLUSH_TX while an IN packet is active, then abort.  Length,
    // payload and cork must stay locked across both the active phase and the
    // retry-pending idle gap.  Flush applies only after successful txpktfin.
    for (i = 0; i < 4; i = i + 1) begin
      tx_expect[i] = 8'ha0 + i;
      bus_write(8'h10, 8'ha0 + i, 4'h1);
    end
    wait_tx_packet(4);
    @(negedge usb_clk);
    tx_active = 1;
    pop_tx_byte(8'ha0, 0);
    bus_write(8'h10, 32'h000000ee, 4'h1); // queued behind snapshot
    bus_write(8'h24, 32'h00000002, 4'h1); // deferred flush request
    repeat (8) @(posedge usb_clk);
    if ((ep2_tx_length != 4) || ep2_tx_cork ||
        (ep2_tx_data !== 8'ha1))
      fail("FLUSH_TX changed an active transaction");
    @(negedge usb_clk);
    tx_active = 0;
    repeat (8) @(posedge usb_clk);
    if ((ep2_tx_length != 4) || ep2_tx_cork ||
        !dut.ep2_i.tx_packet_locked || !dut.ep2_i.tx_flush_pending)
      fail("FLUSH_TX destroyed a retry-pending snapshot");
    @(negedge usb_clk);
    tx_active = 1;
    for (i = 0; i < 4; i = i + 1)
      pop_tx_byte(8'ha0 + i, i == 3);
    @(negedge usb_clk);
    tx_active = 0;
    wait_tx_level(0);
    repeat (8) @(posedge usb_clk);
    if (!ep2_tx_cork || dut.ep2_i.tx_flush_pending)
      fail("deferred FLUSH_TX did not apply after commit/idle");

    // Exact 64-byte software writes must appear as 63 + 1 short packets.
    for (i = 0; i < 64; i = i + 1) begin
      tx_expect[i] = i;
      bus_write(8'h10, i, 4'h1);
    end
    wait_tx_packet(63);
    @(negedge usb_clk);
    tx_active = 1;
    for (i = 0; i < 63; i = i + 1)
      pop_tx_byte(tx_expect[i], i == 62);
    @(negedge usb_clk);
    tx_active = 0;
    wait_tx_packet(1);
    if (ep2_tx_length > 63) fail("Bulk IN exceeded 63-byte cap");
    @(negedge usb_clk);
    tx_active = 1;
    pop_tx_byte(tx_expect[63], 1);
    @(negedge usb_clk);
    tx_active = 0;
    repeat (6) @(posedge usb_clk);

    // With USB loading stopped, the 513th byte is dropped and sets both the
    // sticky STATUS flag and ERROR interrupt source without stalling the bus.
    usb_datapath_reset = 1;
    for (i = 0; i < 513; i = i + 1)
      bus_write(8'h10, i, 4'h1);
    bus_read(8'h08, value);
    if (!value[7]) fail("TX_OVERFLOW sticky status");
    bus_read(8'h1c, value);
    if (!value[4]) fail("ERROR IRQ status after TX overflow");
    bus_write(8'h24, 32'h00000006, 4'h1); // flush TX + clear errors
    usb_datapath_reset = 0;
    // This is also the full-FIFO Gray-walk regression: 512 discarded entries
    // must advance one pointer step per USB clock, never one multi-bit jump.
    wait_tx_level(0);
    repeat (8) @(posedge cpu_clk);
    bus_read(8'h08, value);
    if (value[7:6] != 0) fail("CLEAR_ERRORS_EVENTS");

    if (errors == 0)
      $display("PASS: System16 USB CDC MMIO, async FIFO and retry tests");
    else
      $fatal(1,"FAIL: %0d error(s)", errors);
    $finish;
  end

  initial begin
    #2000000;
    $fatal(1,"global simulation timeout");
  end
endmodule

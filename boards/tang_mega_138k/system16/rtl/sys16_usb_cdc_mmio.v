// System16 USB CDC ACM MMIO front-end (base address decoded by the top level).
// All registers are 32-bit little endian; bus_addr is the byte offset from
// 0xE8800300.  bus_req may remain asserted until ready drops, so req_seen
// guarantees that FIFO and W1C side effects happen exactly once per request.
module sys16_usb_cdc_mmio #(
    parameter FIFO_ADDR_WIDTH = 9
) (
    input  wire                         cpu_clk,
    input  wire                         cpu_reset_n,
    input  wire                         usb_clk,
    input  wire                         usb_datapath_reset,

    input  wire                         bus_req,
    input  wire                         bus_we,
    input  wire [7:0]                   bus_addr,
    input  wire [3:0]                   bus_be,
    input  wire [31:0]                  bus_wdata,
    output reg  [31:0]                  bus_rdata,
    output wire                         bus_ready,
    output wire                         irq,

    input  wire                         usb_online,
    input  wire                         usb_suspend,
    input  wire                         usb_bus_reset,
    input  wire                         pad_diag,
    input  wire [31:0]                  usb_line_baud,
    input  wire [7:0]                   usb_line_stop_bits,
    input  wire [7:0]                   usb_line_parity,
    input  wire [7:0]                   usb_line_data_bits,
    input  wire [15:0]                  usb_control_lines,

    input  wire [3:0]                   endpoint,
    input  wire                         rx_active,
    input  wire                         rx_valid,
    input  wire                         rx_packet_valid,
    input  wire [7:0]                   rx_data,
    output wire                         ep2_rx_ready,
    input  wire                         tx_active,
    input  wire                         tx_pop,
    input  wire                         tx_packet_finished,
    output wire                         ep2_tx_cork,
    output wire [7:0]                   ep2_tx_data,
    output wire [11:0]                  ep2_tx_length
);
  localparam [31:0] REG_ID = 32'h53313655; // "S16U"
  localparam [31:0] REG_CAPS =
      (32'h01 << 24) | (FIFO_ADDR_WIDTH << 8) | FIFO_ADDR_WIDTH;
  localparam [FIFO_ADDR_WIDTH:0] FIFO_DEPTH_VALUE =
      {1'b1,{FIFO_ADDR_WIDTH{1'b0}}};

  reg req_seen;
  wire bus_accept = bus_req && !req_seen;
  assign bus_ready = bus_req;

  wire rx_data_read = bus_accept && !bus_we && (bus_addr[7:2] == 6'h03);
  wire tx_data_write = bus_accept && bus_we && (bus_addr[7:2] == 6'h04) &&
                       bus_be[0];
  wire irq_status_write = bus_accept && bus_we &&
                          (bus_addr[7:2] == 6'h07) && bus_be[0];
  wire irq_enable_write = bus_accept && bus_we &&
                          (bus_addr[7:2] == 6'h08) && bus_be[0];
  wire control_write = bus_accept && bus_we && (bus_addr[7:2] == 6'h09);

  wire cpu_rx_empty;
  wire [7:0] cpu_rx_data;
  wire [FIFO_ADDR_WIDTH:0] cpu_rx_level;
  wire cpu_tx_full;
  wire [FIFO_ADDR_WIDTH:0] cpu_tx_level;
  wire cpu_rx_pop = rx_data_read && !cpu_rx_empty;
  wire cpu_tx_push = tx_data_write && !cpu_tx_full;
  wire cpu_flush_rx = control_write && bus_be[0] && bus_wdata[0];
  wire cpu_flush_tx = control_write && bus_be[0] && bus_wdata[1];
  wire clear_errors_events = control_write && bus_be[0] && bus_wdata[2];
  wire irq_test = control_write && bus_be[3] && bus_wdata[31];
  wire [FIFO_ADDR_WIDTH:0] cpu_tx_free =
      FIFO_DEPTH_VALUE - cpu_tx_level;

  wire rx_available = !cpu_rx_empty;
  wire tx_space = !cpu_tx_full;

  wire rx_overflow_toggle_usb;
  sys16_usb_cdc_ep2 #(.FIFO_ADDR_WIDTH(FIFO_ADDR_WIDTH)) ep2_i (
      .reset_n(cpu_reset_n), .cpu_clk(cpu_clk), .usb_clk(usb_clk),
      .usb_datapath_reset(usb_datapath_reset),
      .endpoint(endpoint), .rx_active(rx_active), .rx_valid(rx_valid),
      .rx_packet_valid(rx_packet_valid), .rx_data(rx_data),
      .ep2_rx_ready(ep2_rx_ready), .tx_active(tx_active), .tx_pop(tx_pop),
      .tx_packet_finished(tx_packet_finished),
      .ep2_tx_cork(ep2_tx_cork), .ep2_tx_data(ep2_tx_data),
      .ep2_tx_length(ep2_tx_length),
      .cpu_rx_pop(cpu_rx_pop), .cpu_rx_data(cpu_rx_data),
      .cpu_rx_empty(cpu_rx_empty), .cpu_rx_level(cpu_rx_level),
      .cpu_tx_push(cpu_tx_push), .cpu_tx_data(bus_wdata[7:0]),
      .cpu_tx_full(cpu_tx_full), .cpu_tx_level(cpu_tx_level),
      .cpu_flush_rx(cpu_flush_rx), .cpu_flush_tx(cpu_flush_tx),
      .rx_overflow_toggle(rx_overflow_toggle_usb));

  // Slowly changing CDC class settings cross as one coherent snapshot.
  wire [71:0] usb_line_snapshot =
      {usb_control_lines, usb_line_stop_bits, usb_line_parity,
       usb_line_data_bits, usb_line_baud};
  wire [71:0] cpu_line_snapshot;
  wire cpu_line_update;
  sys16_cdc_snapshot #(.WIDTH(72)) line_snapshot_i (
      .reset_n(cpu_reset_n), .src_clk(usb_clk),
      .src_data(usb_line_snapshot), .dst_clk(cpu_clk),
      .dst_data(cpu_line_snapshot), .dst_update(cpu_line_update));

  wire [31:0] line_baud_cpu = cpu_line_snapshot[31:0];
  wire [7:0] line_data_cpu = cpu_line_snapshot[39:32];
  wire [7:0] line_parity_cpu = cpu_line_snapshot[47:40];
  wire [7:0] line_stop_cpu = cpu_line_snapshot[55:48];
  wire [15:0] control_lines_cpu = cpu_line_snapshot[71:56];

  // Single-bit levels use ordinary two-flop synchronizers.  Events which may
  // be shorter than a CPU clock are converted to toggles in the USB domain.
  (* syn_preserve = 1, syn_keep = 1 *) reg online_meta, online_sync;
  (* syn_preserve = 1, syn_keep = 1 *) reg suspend_meta, suspend_sync;
  (* syn_preserve = 1, syn_keep = 1 *) reg pad_diag_meta, pad_diag_sync;
  reg usb_reset_d;
  reg usb_reset_toggle;
  (* syn_preserve = 1, syn_keep = 1 *) reg reset_toggle_meta;
  (* syn_preserve = 1, syn_keep = 1 *) reg reset_toggle_sync;
  reg reset_toggle_seen;
  (* syn_preserve = 1, syn_keep = 1 *) reg overflow_toggle_meta;
  (* syn_preserve = 1, syn_keep = 1 *) reg overflow_toggle_sync;
  reg overflow_toggle_seen;
  wire usb_reset_event = reset_toggle_sync != reset_toggle_seen;
  wire rx_overflow_event = overflow_toggle_sync != overflow_toggle_seen;

  always @(posedge usb_clk or negedge cpu_reset_n) begin
    if (!cpu_reset_n) begin
      usb_reset_d <= 1'b0;
      usb_reset_toggle <= 1'b0;
    end else begin
      usb_reset_d <= usb_bus_reset;
      if (usb_bus_reset && !usb_reset_d)
        usb_reset_toggle <= ~usb_reset_toggle;
    end
  end

  reg online_d;
  reg rx_available_d;
  reg tx_space_d;
  reg rx_overflow_sticky;
  reg tx_overflow_sticky;
  reg usb_reset_sticky;
  reg online_change_sticky;
  reg [4:0] irq_pending;
  reg [4:0] irq_enable;

  wire online_change_event = online_sync != online_d;
  wire tx_overflow_event = tx_data_write && cpu_tx_full;
  assign irq = |(irq_pending & irq_enable);

  always @(posedge cpu_clk or negedge cpu_reset_n) begin
    if (!cpu_reset_n) begin
      req_seen <= 1'b0;
      online_meta <= 1'b0;
      online_sync <= 1'b0;
      suspend_meta <= 1'b0;
      suspend_sync <= 1'b0;
      pad_diag_meta <= 1'b0;
      pad_diag_sync <= 1'b0;
      reset_toggle_meta <= 1'b0;
      reset_toggle_sync <= 1'b0;
      reset_toggle_seen <= 1'b0;
      overflow_toggle_meta <= 1'b0;
      overflow_toggle_sync <= 1'b0;
      overflow_toggle_seen <= 1'b0;
      online_d <= 1'b0;
      rx_available_d <= 1'b0;
      tx_space_d <= 1'b1;
      rx_overflow_sticky <= 1'b0;
      tx_overflow_sticky <= 1'b0;
      usb_reset_sticky <= 1'b0;
      online_change_sticky <= 1'b0;
      irq_pending <= 5'd0;
      irq_enable <= 5'd0;
    end else begin
      online_meta <= usb_online;
      online_sync <= online_meta;
      suspend_meta <= usb_suspend;
      suspend_sync <= suspend_meta;
      pad_diag_meta <= pad_diag;
      pad_diag_sync <= pad_diag_meta;
      reset_toggle_meta <= usb_reset_toggle;
      reset_toggle_sync <= reset_toggle_meta;
      overflow_toggle_meta <= rx_overflow_toggle_usb;
      overflow_toggle_sync <= overflow_toggle_meta;
      online_d <= online_sync;
      rx_available_d <= rx_available;
      tx_space_d <= tx_space;

      if (!bus_req)
        req_seen <= 1'b0;
      else if (!req_seen)
        req_seen <= 1'b1;

      // W1C and explicit clear happen before new events below, so a real event
      // coincident with software acknowledgement is never lost.
      if (irq_status_write)
        irq_pending <= irq_pending & ~bus_wdata[4:0];
      if (irq_enable_write) begin
        irq_enable <= bus_wdata[4:0];
        // Enabling a currently serviceable level produces an initial event.
        if (bus_wdata[0] && rx_available)
          irq_pending[0] <= 1'b1;
        if (bus_wdata[1] && tx_space)
          irq_pending[1] <= 1'b1;
      end
      if (clear_errors_events) begin
        rx_overflow_sticky <= 1'b0;
        tx_overflow_sticky <= 1'b0;
        usb_reset_sticky <= 1'b0;
        online_change_sticky <= 1'b0;
        irq_pending <= 5'd0;
      end

      if (rx_available && !rx_available_d)
        irq_pending[0] <= 1'b1;
      if (tx_space && !tx_space_d)
        irq_pending[1] <= 1'b1;
      if (online_change_event) begin
        online_change_sticky <= 1'b1;
        irq_pending[2] <= 1'b1;
      end
      if (usb_reset_event) begin
        reset_toggle_seen <= reset_toggle_sync;
        usb_reset_sticky <= 1'b1;
        irq_pending[3] <= 1'b1;
      end
      if (rx_overflow_event) begin
        overflow_toggle_seen <= overflow_toggle_sync;
        rx_overflow_sticky <= 1'b1;
        irq_pending[4] <= 1'b1;
      end
      if (tx_overflow_event) begin
        tx_overflow_sticky <= 1'b1;
        irq_pending[4] <= 1'b1;
      end
      if (irq_test)
        irq_pending[4] <= 1'b1;
    end
  end

  wire [31:0] status_word = {
      21'd0, pad_diag_sync,
      online_change_sticky, usb_reset_sticky,
      tx_overflow_sticky, rx_overflow_sticky,
      tx_space, rx_available,
      control_lines_cpu[1], control_lines_cpu[0],
      suspend_sync, online_sync
  };

  always @* begin
    case (bus_addr[7:2])
      6'h00: bus_rdata = REG_ID;                                      // 0x00
      6'h01: bus_rdata = REG_CAPS;                                    // 0x04
      6'h02: bus_rdata = status_word;                                 // 0x08
      6'h03: bus_rdata = cpu_rx_empty ? 32'd0 : {24'd0,cpu_rx_data};   // 0x0c
      6'h04: bus_rdata = 32'd0;                                       // 0x10
      6'h05: bus_rdata = {{(16-(FIFO_ADDR_WIDTH+1)){1'b0}},
                           cpu_rx_level};                              // 0x14
      6'h06: bus_rdata = {
          {(16-(FIFO_ADDR_WIDTH+1)){1'b0}}, cpu_tx_free,
          {(16-(FIFO_ADDR_WIDTH+1)){1'b0}}, cpu_tx_level};             // 0x18
      6'h07: bus_rdata = {27'd0,irq_pending};                          // 0x1c
      6'h08: bus_rdata = {27'd0,irq_enable};                           // 0x20
      6'h09: bus_rdata = 32'd0;                                       // 0x24
      6'h0a: bus_rdata = line_baud_cpu;                               // 0x28
      6'h0b: bus_rdata = {8'd0,line_stop_cpu,line_parity_cpu,
                          line_data_cpu};                              // 0x2c
      6'h0c: bus_rdata = {30'd0,control_lines_cpu[1:0]};              // 0x30
      default: bus_rdata = 32'd0;
    endcase
  end

  // Update strobe is intentionally not part of the ABI; it remains visible
  // for debug while the coherent snapshot itself feeds the registers above.
  wire unused_line_update = cpu_line_update;
endmodule
